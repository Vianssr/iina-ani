import Foundation
import Cocoa
import Security
@testable import IINA_ANI

@main
enum DownloadServiceStateRegression {
    struct Failure: Error { let message: String }
    struct Store: Encodable { let version: Int; let records: [DownloadRecord] }
    final class PolicyFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: DownloadPolicySnapshot
        init(_ value: DownloadPolicySnapshot) { self.value = value }
        func snapshot() -> DownloadPolicySnapshot { lock.withLock { value } }
        func update(_ value: DownloadPolicySnapshot) { lock.withLock { self.value = value } }
    }

    actor ResolutionProbe {
        private(set) var selections: [PlayableSelection] = []
        func recordedSelections() -> [PlayableSelection] { selections }
        func resolve(_ selection: PlayableSelection) async throws -> DownloadResource {
            selections.append(selection)
            do { try await Task.sleep(for: .seconds(60)) } catch { throw CancellationError() }
            throw CancellationError()
        }
    }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "iina-download-state-\(UUID().uuidString)"
        let keychain = "iina-download-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychain]
            SecItemDelete(query as CFDictionary)
        }
        let preferences = Preferences(defaults: defaults)
        let pinnedID = UUID(), defaultID = UUID()
        let accounts = [
            SiteAccount(id: pinnedID, sourceID: "bilibili", displayName: "pinned", enabled: true, status: .valid),
            SiteAccount(id: defaultID, sourceID: "bilibili", displayName: "default", enabled: true, status: .valid)
        ]
        defaults.set(try JSONEncoder().encode(accounts), forKey: "site-account-metadata-v1")
        preferences.setDefaultAccountID(defaultID, for: "bilibili")
        let accountPool = SiteAccounts(preferences: preferences, keychainService: keychain)
        let outputA = root.appendingPathComponent("output-A", isDirectory: true)
        let outputB = root.appendingPathComponent("output-B", isDirectory: true)
        let temporary = root.appendingPathComponent("temporary", isDirectory: true)
        let policy = PolicyFixture(DownloadPolicySnapshot(outputDirectory: outputA, concurrencyLimit: 1, temporaryDirectory: temporary))
        let selection = PlayableSelection(
            item: SourceItemRef(sourceID: "bilibili", pageURL: "https://www.bilibili.com/video/BV-original", kind: .video),
            episode: SourceItemRef(sourceID: "bilibili", pageURL: "https://www.bilibili.com/video/BV-original?p=3", kind: .episode),
            lineID: "line-original", qualityID: "quality-original", accountID: pinnedID,
            classification: MediaClassification(kind: .video, provenance: "fixture.content"))
        let probe = ResolutionProbe()
        let storeURL = root.appendingPathComponent("tasks.json")
        let service = try DownloadService(storeURL: storeURL, accounts: accountPool,
            policy: { policy.snapshot() }, validator: { _ in }, resolver: { try await probe.resolve($0) })
        var live = selection
        live.classification = MediaClassification(kind: .live, provenance: "manual")
        do {
            _ = try await service.create(selection: live, title: "not a recording")
            throw Failure(message: "live content bypassed download admission using a video ref or custom validator")
        } catch DownloadFailure.unsupportedMedia { }
        try require(await service.list().isEmpty, "rejected live download persisted a task")
        let task = try await service.create(selection: selection, title: "pinned")
        try await service.setTorrentUploadLimit(32_768)
        for invalid in [UInt32(0), TorrentUploadPolicy.maximumBytesPerSecond + 1] {
            do {
                try await service.setTorrentUploadLimit(invalid)
                throw Failure(message: "invalid upload cap accepted")
            } catch DownloadFailure.invalidSelection {}
        }
        try await service.stopTorrentTransfers()
        let unaffected = try await service.record(task.id)
        try require(unaffected.state != .paused && unaffected.state != .canceled,
                    "stopping P2P does not stop independent website downloads")
        do {
            try await service.setAcceptingNewTasks(false) {}
            throw Failure(message: "active download must block disable")
        } catch let error as WorkspaceCapabilityFailure {
            try require(error.reasons.contains { $0.contains(task.id.uuidString) }, "disable reports the affected task")
        }
        policy.update(DownloadPolicySnapshot(outputDirectory: outputB, concurrencyLimit: 8, temporaryDirectory: root.appendingPathComponent("new-temp", isDirectory: true)))
        try require(task.selection == selection && task.selection.accountID == pinnedID,
                    "task must persist the exact episode/line/quality/account selection, not the current default")
        try require(task.outputDirectory == outputA && task.temporaryDirectory.deletingLastPathComponent() == temporary && task.concurrencyLimit == 1,
                    "new-task policy must be snapshotted and unaffected by later preference changes")
        var newSelection = selection
        newSelection.accountID = defaultID
        let policyTask = try await service.create(selection: newSelection, title: "new-policy")
        try require(policyTask.selection == newSelection && policyTask.outputDirectory == outputB &&
                    policyTask.temporaryDirectory.deletingLastPathComponent() == root.appendingPathComponent("new-temp", isDirectory: true) &&
                    policyTask.concurrencyLimit == 8,
                    "task created after a preference change must capture the new directory and concurrency policy")
        try await service.cancel(policyTask.id)

        var guestSelection = selection
        guestSelection.accountID = nil
        let guestTask = try await service.create(selection: guestSelection, title: "guest")
        try require(guestTask.selection.accountID == nil, "an explicit guest selection must not adopt the configured default account")
        try await service.cancel(guestTask.id)
        try await accountPool.setEnabled(accountID: defaultID, enabled: false)

        try await service.pause(task.id)
        try await service.setAcceptingNewTasks(false) { preferences.saveCapability(.downloads, enabled: false) }
        do {
            _ = try await service.create(selection: guestSelection, title: "disabled")
            throw Failure(message: "disabled download created a task")
        } catch is WorkspaceCapabilityFailure {}
        do {
            try await service.resume(task.id)
            throw Failure(message: "disabled download resumed")
        } catch is WorkspaceCapabilityFailure {}
        try require(try await service.record(task.id).state == .paused, "disable retains the paused record")
        try await service.setAcceptingNewTasks(true) { preferences.saveCapability(.downloads, enabled: true) }
        try await service.resume(task.id)
        try await service.pause(task.id)
        do {
            try await accountPool.remove(accountID: pinnedID)
            throw Failure(message: "paused task must retain its pinned account lease")
        } catch SiteAccountError.accountInUse {}
        await service.shutdown()

        // A persisted active state is converted to a recoverable pause at load, without starting work.
        var interrupted = task
        interrupted.state = .downloading
        interrupted.needsRecovery = false
        interrupted.bytes = 123
        interrupted.totalBytes = nil
        interrupted.bytesPerSecond = 72
        interrupted.remainingSeconds = 18
        let recoveryStore = root.appendingPathComponent("recovery.json")
        try JSONEncoder().encode(Store(version: 1, records: [interrupted])).write(to: recoveryStore, options: .atomic)
        let recoveryProbe = ResolutionProbe()
        let recoveredService = try DownloadService(storeURL: recoveryStore, accounts: accountPool,
            policy: { policy.snapshot() }, validator: { _ in }, resolver: { try await recoveryProbe.resolve($0) }, acceptingNewTasks: false)
        let recovered = try await recoveredService.record(task.id)
        try require(recovered.state == .paused && recovered.needsRecovery && recovered.bytes == 123 && recovered.totalBytes == nil,
                    "restart must persist the original selection and progress while marking interrupted work recoverable")
        try require(recovered.bytesPerSecond == 0 && recovered.remainingSeconds == nil,
                    "restart must not expose stale transfer rate or ETA")
        await recoveredService.restoreAccountLeases()
        do {
            try await accountPool.remove(accountID: pinnedID)
            throw Failure(message: "recovered task must reacquire its original account lease")
        } catch SiteAccountError.accountInUse {}
        do {
            try await recoveredService.resume(task.id)
            throw Failure(message: "persisted disabled capability was lost during restart")
        } catch is WorkspaceCapabilityFailure {}
        try await recoveredService.setAcceptingNewTasks(true) {}
        try await recoveredService.resume(task.id)
        for _ in 0..<200 {
            if await recoveryProbe.recordedSelections().count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(await recoveryProbe.recordedSelections() == [selection], "resume must resolve only the exact original selection and pinned identity")
        try await recoveredService.pause(task.id)
        await recoveredService.shutdown()

        // An expired or removed pinned identity fails recovery; no resolver call may fall back to guest/default.
        try await accountPool.markExpired(accountID: pinnedID)
        var pausedOriginal = interrupted
        pausedOriginal.state = .paused
        pausedOriginal.needsRecovery = true
        let expiredStore = root.appendingPathComponent("expired-account.json")
        try JSONEncoder().encode(Store(version: 1, records: [pausedOriginal])).write(to: expiredStore, options: .atomic)
        let expiredProbe = ResolutionProbe()
        let expiredService = try DownloadService(storeURL: expiredStore, accounts: accountPool,
            policy: { policy.snapshot() }, validator: { _ in }, resolver: { try await expiredProbe.resolve($0) })
        await expiredService.restoreAccountLeases()
        let expiredRecord = try await expiredService.record(task.id)
        try require(expiredRecord.state == .failed && expiredRecord.failure == .authorization,
                    "expired original account must fail recovery with an authorization reason")
        do {
            try await expiredService.resume(task.id)
            throw Failure(message: "expired pinned identity must not recover by switching accounts")
        } catch SiteAccountError.expired {}
        try require(await expiredProbe.recordedSelections().isEmpty, "expired account recovery must not resolve as a guest/default task")
        await expiredService.shutdown()

        try await accountPool.remove(accountID: pinnedID)
        let missingStore = root.appendingPathComponent("missing-account.json")
        try JSONEncoder().encode(Store(version: 1, records: [pausedOriginal])).write(to: missingStore, options: .atomic)
        let missingProbe = ResolutionProbe()
        let missingService = try DownloadService(storeURL: missingStore, accounts: accountPool,
            policy: { policy.snapshot() }, validator: { _ in }, resolver: { try await missingProbe.resolve($0) })
        await missingService.restoreAccountLeases()
        let missingRecord = try await missingService.record(task.id)
        try require(missingRecord.state == .failed && missingRecord.failure == .authorization,
                    "removed original account must fail recovery rather than become guest")
        try require(await missingProbe.recordedSelections().isEmpty, "missing-account recovery must not invoke the resolver or select a default")
        await missingService.shutdown()

        // Completed-file operations are exercised from an independently persisted completed record.
        let completedPath = root.appendingPathComponent("completed.mp4")
        try Data([0x01, 0x02]).write(to: completedPath)
        var completed = task
        completed.state = .completed
        completed.completedFile = completedPath
        completed.bytes = 2
        let completedStore = root.appendingPathComponent("completed.json")
        try JSONEncoder().encode(Store(version: 1, records: [completed])).write(to: completedStore, options: .atomic)
        let fileService = try DownloadService(storeURL: completedStore, accounts: accountPool,
            policy: { policy.snapshot() }, validator: { _ in }, resolver: { try await probe.resolve($0) })
        let restoredCompleted = await fileService.completedDownloads()
        try require(restoredCompleted.count == 1 && restoredCompleted[0].outputSubdirectory == nil &&
                    restoredCompleted[0].coverURL == nil && restoredCompleted[0].episodeKey == nil,
                    "legacy records without the new optional fields must retain completion and the old output directory")
        try FileManager.default.removeItem(at: completedPath)
        try require(await fileService.completedDownloads().isEmpty, "external removal must immediately clear the completion snapshot")
        try Data([0x01, 0x02]).write(to: completedPath)
        try require(try await fileService.fileForOpening(task.id) == completedPath,
                    "completed file command must return the persisted file for opening")
        try await fileService.deleteFile(task.id)
        let afterDelete = try await fileService.record(task.id)
        try require(afterDelete.state == .completed && afterDelete.completedFile == nil && !FileManager.default.fileExists(atPath: completedPath.path),
                    "delete-file must delete only the file and retain its completed task record")
        try require(await fileService.completedDownloads().isEmpty, "explicit removal must clear the completion snapshot")
        do {
            _ = try await fileService.fileForOpening(task.id)
            throw Failure(message: "deleted completed file must not be openable")
        } catch DownloadFailure.missingFile {}
        await fileService.shutdown()
        print("PASS W7.3/W7.5 offline download state, identity, policy, recovery, leases and completed-file commands")
    }
}
