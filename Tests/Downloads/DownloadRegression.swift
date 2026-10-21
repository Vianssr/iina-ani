import Cocoa
import Foundation
import Darwin
@testable import IINA_ANI

@main
enum DownloadRegression {
    struct Failure: Error { let message: String }
    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var updates: [DownloadTransferProgress] = []
        func add(_ update: DownloadTransferProgress) { lock.withLock { updates.append(update) } }
        var values: [DownloadTransferProgress] { lock.withLock { updates } }
    }
    actor Resolution {
        let base: URL
        var expired = false
        init(_ base: URL) { self.base = base }
        func setExpired(_ value: Bool) { expired = value }
        func resolve(_ selection: PlayableSelection) throws -> DownloadResource {
            var context = DownloadRequestContext()
            context.allowLoopbackHTTP = true
            context.headers["Referer"] = "https://source.example/episode/2"
            let mode = expired ? "auth" : "slow"
            return DownloadResource(url: URL(string: "blob?mode=\(mode)", relativeTo: base)!.absoluteURL,
                                    format: .direct, context: context, fileExtension: "mp4")
        }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func selection(_ account: UUID? = nil) -> PlayableSelection {
        PlayableSelection(item: SourceItemRef(sourceID: "bilibili", pageURL: "https://www.bilibili.com/video/BVfixture?p=2", kind: .video),
                          lineID: "0", qualityID: "1080p", accountID: account)
    }
    static func waitFor(_ service: DownloadService, id: UUID, predicate: @Sendable (DownloadRecord) -> Bool) async throws -> DownloadRecord {
        for _ in 0..<1_000 {
            let record = try await service.record(id)
            if predicate(record) { return record }
            if record.state == .failed { throw Failure(message: "unexpected failure: \(record.failure?.rawValue ?? "unknown")") }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(message: "download timed out")
    }
    static func main() async throws {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "--group-completed" {
            let root = URL(fileURLWithPath: args[2]), base = URL(string: args[3])!
            let resolver = Resolution(base)
            let service = try DownloadService(storeURL: root.appendingPathComponent("grouped.json"),
                policy: { DownloadPolicySnapshot(outputDirectory: root.appendingPathComponent("grouped-output"), concurrencyLimit: 1, temporaryDirectory: root.appendingPathComponent("grouped-temp")) },
                validator: { _ in }, resolver: { try await resolver.resolve($0) })
            let task = try await service.create(selection: groupedSelection(), title: "../../同名/番劇\n", episodeTitle: "EP/01", bangumiID: 42, episodeKey: "bangumi:101")
            let completed = try await waitFor(service, id: task.id) { $0.state == .completed }
            try require(try Data(contentsOf: completed.completedFile!) == Data(contentsOf: root.appendingPathComponent("blob")), "grouped publication must preserve fixture bytes")
            try require(!task.outputSubdirectory!.contains("/") && !task.outputSubdirectory!.contains("\n"), "work names must never create traversal paths")
            await service.shutdown()
            Darwin._exit(0)
        }
        if args.count > 1, ["--interrupt", "--shutdown"].contains(args[1]) {
            let root = URL(fileURLWithPath: args[2]), base = URL(string: args[3])!
            let resolver = Resolution(base)
            let service = try DownloadService(storeURL: root.appendingPathComponent(args[1] == "--interrupt" ? "restart.json" : "shutdown.json"),
                policy: { DownloadPolicySnapshot(outputDirectory: root.appendingPathComponent("output"), concurrencyLimit: 1, temporaryDirectory: root.appendingPathComponent("temporary")) },
                validator: { _ in }, resolver: { try await resolver.resolve($0) })
            let task = try await service.create(selection: selection(), title: "restart")
            _ = try await waitFor(service, id: task.id) { $0.state == .downloading && $0.bytes > 0 }
            if args[1] == "--shutdown" { await service.shutdown() }
            Darwin._exit(0) // Real process interruption, not a synthetic stored-state fixture.
        }
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let server = Process(), pipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [args[1], root.path]
        server.standardOutput = pipe
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }
            line.append(byte)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else { throw Failure(message: "server did not start") }
        let base = URL(string: "http://127.0.0.1:\(port)/")!
        try await transferBoundaries(root: root, base: base)
        try await lifecycle(root: root, base: base)
        try await restart(root: root, base: base)
        try await grouping(root: root, base: base)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("aes/index.m3u8").path) {
            try await hls(root: root, base: base)
        }
        print("PASS W6: range identity, unknown total, redirects, lifecycle, cancellation, leases, reparse and real process recovery")
    }

    static func groupedSelection(_ page: String = "https://anime.example/work/a") -> PlayableSelection {
        PlayableSelection(item: SourceItemRef(sourceID: "fixture-anime", pageURL: page, kind: .work),
                          episode: SourceItemRef(sourceID: "fixture-anime", pageURL: page + "/episode/1", kind: .episode),
                          classification: MediaClassification(kind: .anime, provenance: "fixture"))
    }

    static func grouping(root: URL, base: URL) async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--group-completed", root.path, base.absoluteString]
        try child.run()
        child.waitUntilExit()
        try require(child.terminationStatus == 0, "real grouped-download child must complete successfully")
        let output = root.appendingPathComponent("grouped-output", isDirectory: true)
        let resolver = Resolution(base)
        let service = try DownloadService(storeURL: root.appendingPathComponent("grouped.json"),
            policy: { DownloadPolicySnapshot(outputDirectory: output, concurrencyLimit: 2, temporaryDirectory: root.appendingPathComponent("grouped-temp")) },
            validator: { _ in }, resolver: { try await resolver.resolve($0) })
        let restored = await service.completedDownloads()
        try require(restored.count == 1 && restored[0].bangumiID == 42 && restored[0].episodeKey == "bangumi:101",
                    "completion markers must survive a real process restart with exact episode identity")
        let first = restored[0]
        try require(first.outputDirectory.standardizedFileURL.path == output.standardizedFileURL.path && first.outputSubdirectory != nil &&
                    first.completedFile!.deletingLastPathComponent().standardizedFileURL.path == output.appendingPathComponent(first.outputSubdirectory!, isDirectory: true).standardizedFileURL.path,
                    "bookmarked output root stays snapshotted while media publishes inside its work directory")
        let same = try await service.create(selection: groupedSelection("https://anime.example/work/other-source"), title: "renamed title", workID: UUID(), bangumiID: 42, episodeKey: "bangumi:102")
        let sameResult = try await waitFor(service, id: same.id) { $0.state == .completed }
        try require(sameResult.outputSubdirectory == first.outputSubdirectory, "Bangumi identity groups episodes across sources, titles and work UUIDs")
        let different = try await service.create(selection: groupedSelection(), title: first.title, bangumiID: 43, episodeKey: "bangumi:101")
        let differentResult = try await waitFor(service, id: different.id) { $0.state == .completed }
        try require(differentResult.outputSubdirectory != first.outputSubdirectory, "same-name unrelated Bangumi works must not collide")
        let localID = UUID()
        let local = try await service.create(selection: groupedSelection(), title: "local", workID: localID)
        let localAgain = try await service.create(selection: groupedSelection("https://anime.example/work/b"), title: "local translated", workID: localID)
        let localOther = try await service.create(selection: groupedSelection(), title: "local", workID: UUID())
        try require(local.outputSubdirectory == localAgain.outputSubdirectory && local.outputSubdirectory != localOther.outputSubdirectory,
                    "local work identity groups sources but isolates unrelated same-name works")
        for id in [local.id, localAgain.id, localOther.id] { try await service.cancel(id) }
        let ref = try await service.create(selection: groupedSelection(), title: "source work")
        let refSame = try await service.create(selection: groupedSelection(), title: "source translated")
        let refOther = try await service.create(selection: groupedSelection("https://anime.example/work/b"), title: "source work")
        try require(ref.outputSubdirectory == refSame.outputSubdirectory && ref.outputSubdirectory != refOther.outputSubdirectory,
                    "source work ref fallback must be stable and collision isolated")
        for id in [ref.id, refSame.id, refOther.id] { try await service.cancel(id) }
        var videoSelection = selection()
        videoSelection.classification = MediaClassification(kind: .video, provenance: "fixture")
        videoSelection.item = SourceItemRef(sourceID: "rebo", pageURL: "https://anime.example/video/1", kind: .work)
        let video = try await service.create(selection: videoSelection, title: "ordinary", workID: UUID())
        let videoResult = try await waitFor(service, id: video.id) { $0.state == .completed }
        try require(video.outputSubdirectory == nil && videoResult.completedFile?.deletingLastPathComponent() == output,
                    "ordinary videos keep the original download root")
        try FileManager.default.removeItem(at: first.completedFile!)
        try require(!(await service.completedDownloads()).contains { $0.id == first.id }, "external file deletion must clear the reconstructed downloaded marker")
        try await service.deleteFile(same.id)
        try require(!(await service.completedDownloads()).contains { $0.id == same.id }, "explicit file deletion must clear the downloaded marker")

        // Existing group symlinks cannot redirect a new episode into another directory.
        let parent = differentResult.completedFile!.deletingLastPathComponent()
        let parked = root.appendingPathComponent("parked-group", isDirectory: true)
        try FileManager.default.moveItem(at: parent, to: parked)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: parked)
        try require(!(await service.completedDownloads()).contains { $0.id == different.id }, "symlinked group directories must not count as completed media")
        let attack = try await service.create(selection: groupedSelection(), title: "attack", bangumiID: 43)
        let rejected = try await waitFor(service, id: attack.id) { $0.state == .failed }
        try require(rejected.failure == .directoryNotWritable, "symlinked output groups must reject publication")
        let filenames = try FileManager.default.contentsOfDirectory(atPath: parked.path)
        try require(filenames.count == 1, "symlink rejection must leave the outside destination unchanged")
        await service.shutdown()
    }


    static func transferBoundaries(root: URL, base: URL) async throws {
        var context = DownloadRequestContext()
        context.allowLoopbackHTTP = true
        context.headers["Referer"] = "https://source.example/episode/2"
        let expected = try Data(contentsOf: root.appendingPathComponent("blob"))
        let destination = root.appendingPathComponent("resume.partial")
        let resource = DownloadResource(url: URL(string: "blob?mode=slow", relativeTo: base)!.absoluteURL, format: .direct, context: context)
        let box = ProgressBox()
        let running = Task { try await DirectDownloader.download(resource: resource, destination: destination, progress: box.add) }
        while !box.values.contains(where: { $0.bytes > 0 }) { try await Task.sleep(for: .milliseconds(10)) }
        running.cancel()
        do { _ = try await running.value; throw Failure(message: "cancel must stop transport") } catch is CancellationError {}
        _ = try await DirectDownloader.download(resource: resource, destination: destination, progress: box.add)
        try require(try Data(contentsOf: destination) == expected, "validated range resume must preserve exact content")
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        try require(requests.contains("bytes="), "resume must exercise an actual HTTP Range response")

        // Changing the resource behind the same URL must never splice new bytes onto an old prefix.
        let changed = root.appendingPathComponent("changed.partial")
        let changeTask = Task { try await DirectDownloader.download(resource: resource, destination: changed, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(150))
        changeTask.cancel()
        do { _ = try await changeTask.value } catch is CancellationError {}
        let replacement = Data(repeating: 0x5a, count: expected.count)
        try replacement.write(to: root.appendingPathComponent("blob"))
        let changes = ProgressBox()
        _ = try await DirectDownloader.download(resource: resource, destination: changed, progress: changes.add)
        try require(try Data(contentsOf: changed) == replacement, "changed ETag must force a clean restart")
        try require(changes.values.contains(where: { $0.restartReason != nil }), "identity restart must be observable")
        try expected.write(to: root.appendingPathComponent("blob"))

        let unknown = ProgressBox()
        let unknownResource = DownloadResource(url: URL(string: "blob?mode=unknown", relativeTo: base)!.absoluteURL, format: .direct, context: context)
        _ = try await DirectDownloader.download(resource: unknownResource, destination: root.appendingPathComponent("unknown.partial"), progress: unknown.add)
        try require(unknown.values.contains(where: { $0.bytes > 0 && $0.totalBytes == nil }), "chunked/close-delimited content must report bytes without invented total")
        context.credentialHosts = ["127.0.0.1"]
        context.cookies = [HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "fixture", .value: "isolated"])!]
        _ = try await DirectDownloader.download(resource: DownloadResource(url: base.appendingPathComponent("redirect"), format: .direct, context: context), destination: root.appendingPathComponent("redirect.partial"), progress: { _ in })
        let rows = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let redirected = rows.last!
        try require(redirected["cookie"] is NSNull && redirected["referer"] as? String == context.headers["Referer"], "redirect must keep source Referer but never leak another host's cookie")
    }

    static func lifecycle(root: URL, base: URL) async throws {
        let suite = "w6-download.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let account = SiteAccount(id: UUID(), sourceID: "bilibili", displayName: "Fixture", enabled: true, status: .valid)
        defaults.set(try JSONEncoder().encode([account]), forKey: "site-account-metadata-v1")
        let accounts = SiteAccounts(preferences: preferences, keychainService: suite)
        let resolver = Resolution(base)
        preferences.downloadDirectory = root.appendingPathComponent("output")
        preferences.downloadConcurrencyLimit = 1
        let service = try DownloadService(storeURL: root.appendingPathComponent("tasks.json"), accounts: accounts,
            policy: { DownloadPolicySnapshot(outputDirectory: preferences.downloadDirectory, concurrencyLimit: preferences.downloadConcurrencyLimit, temporaryDirectory: root.appendingPathComponent("temporary")) },
            validator: { _ in }, resolver: { try await resolver.resolve($0) })
        let first = try await service.create(selection: selection(account.id), title: "same")
        _ = try await waitFor(service, id: first.id) { $0.bytes > 0 }
        do { try await accounts.remove(accountID: account.id); throw Failure(message: "active download must retain account lease") } catch SiteAccountError.accountInUse {}
        try await service.pause(first.id)
        let paused = try await service.record(first.id)
        try require(paused.state == .paused, "pause must wait for the writer to stop")
        try require(paused.bytes > 0 && paused.fractionCompleted == Double(paused.bytes) / Double(paused.totalBytes!),
                    "paused transfers must retain their known determinate byte progress")
        preferences.downloadDirectory = root.appendingPathComponent("new-output")
        preferences.downloadConcurrencyLimit = 2
        let second = try await service.create(selection: selection(), title: "second")
        try require(second.outputDirectory != first.outputDirectory, "new policy must apply only to new tasks")
        try await service.cancel(second.id)
        try require(!FileManager.default.fileExists(atPath: second.temporaryDirectory.path), "cancel must clean only its own temporary directory")
        try require(FileManager.default.fileExists(atPath: first.temporaryDirectory.path), "cancel must preserve a paused neighbor")
        try await service.resume(first.id)
        let completed = try await waitFor(service, id: first.id) { $0.state == .completed }
        try require(try Data(contentsOf: completed.completedFile!) == Data(contentsOf: root.appendingPathComponent("blob")), "completed bytes must equal source")
        try require(completed.fractionCompleted == 1, "completed transfers must not present an indeterminate indicator")
        try await accounts.remove(accountID: account.id)
        let file = completed.completedFile!
        let collisionService = try DownloadService(storeURL: root.appendingPathComponent("collision-tasks.json"),
            policy: { DownloadPolicySnapshot(outputDirectory: root.appendingPathComponent("output"), concurrencyLimit: 1, temporaryDirectory: root.appendingPathComponent("temporary")) },
            validator: { _ in }, resolver: { try await resolver.resolve($0) })
        let collision = try await collisionService.create(selection: selection(), title: "same")
        let distinct = try await waitFor(collisionService, id: collision.id) { $0.state == .completed }
        try require(distinct.completedFile?.path != file.path && Data(contentsOf: file) == Data(contentsOf: root.appendingPathComponent("blob")), "existing directory bookmarks and filename collisions must preserve the original file")
        await collisionService.shutdown()
        let longTitleService = try DownloadService(storeURL: root.appendingPathComponent("long-title-tasks.json"),
            policy: { DownloadPolicySnapshot(outputDirectory: root.appendingPathComponent("output"), concurrencyLimit: 1, temporaryDirectory: root.appendingPathComponent("temporary")) },
            validator: { _ in }, resolver: { try await resolver.resolve($0) })
        let longTask = try await longTitleService.create(selection: selection(), title: String(repeating: "劇", count: 130))
        let longResult = try await waitFor(longTitleService, id: longTask.id) { $0.state == .completed }
        try require(longResult.completedFile!.lastPathComponent.utf8.count <= 255, "long Unicode episode titles must produce valid filesystem names")
        await longTitleService.shutdown()
        try await service.deleteRecord(first.id)
        try require(FileManager.default.fileExists(atPath: file.path), "record deletion must preserve completed media")

        // Expired media stops; resume re-resolves the original choice, without changing identity/quality.
        await resolver.setExpired(true)
        let expired = try await service.create(selection: selection(), title: "expired")
        var failed = try await service.record(expired.id)
        for _ in 0..<500 where failed.state != .failed {
            try await Task.sleep(for: .milliseconds(10)); failed = try await service.record(expired.id)
        }
        try require(failed.state == .failed && failed.failure == .authorization, "401 must stop with an actionable authorization failure")
        await resolver.setExpired(false)
        try await service.resume(expired.id)
        let renewed = try await waitFor(service, id: expired.id) { $0.state == .completed }
        try require(renewed.selection == expired.selection && Data(contentsOf: renewed.completedFile!) == Data(contentsOf: root.appendingPathComponent("blob")), "reparse must retain episode/quality/account and source content")
        try await service.deleteFile(expired.id)
        let deleted = try await service.record(expired.id)
        try require(!FileManager.default.fileExists(atPath: renewed.completedFile!.path) && deleted.state == .completed && deleted.completedFile == nil, "explicit file deletion must retain the record")
        await service.shutdown()
    }

    static func restart(root: URL, base: URL) async throws {
        for mode in ["--interrupt", "--shutdown"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [mode, root.path, base.absoluteString]
            try child.run(); child.waitUntilExit()
            try require(child.terminationStatus == 0, "child must reach an actual transfer before exit")
            let resolver = Resolution(base)
            let service = try DownloadService(storeURL: root.appendingPathComponent(mode == "--interrupt" ? "restart.json" : "shutdown.json"),
                policy: { DownloadPolicySnapshot(outputDirectory: root.appendingPathComponent("output"), concurrencyLimit: 1, temporaryDirectory: root.appendingPathComponent("temporary")) },
                validator: { _ in }, resolver: { try await resolver.resolve($0) })
            let recovered = await service.list().first!
            try require(recovered.state == .paused && recovered.needsRecovery && recovered.bytesPerSecond == 0, "restart must not invent an active worker")
            try await service.resume(recovered.id)
            let completed = try await waitFor(service, id: recovered.id) { $0.state == .completed }
            try require(try Data(contentsOf: completed.completedFile!) == Data(contentsOf: root.appendingPathComponent("blob")), "cross-process recovery must verify identical bytes")
            await service.shutdown()
        }
    }

    static func hls(root: URL, base: URL) async throws {
        var context = DownloadRequestContext(); context.allowLoopbackHTTP = true
        for path in ["aes/index.m3u8", "fmp4/index.m3u8", "range/index.m3u8", "master/index.m3u8"] {
            let directory = root.appendingPathComponent("hls-" + path.components(separatedBy: "/")[0])
            let resource = DownloadResource(url: base.appendingPathComponent(path), format: .hls, context: context)
            let progress = ProgressBox()
            let downloaded = try await HLSDownloader.download(resource: resource, directory: directory, progress: progress.add)
            let output = try await HLSDownloader.finalize(playlist: downloaded.playlist, directory: directory, ffmpegURL: nil)
            let probe = Process(), pipe = Pipe()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            probe.arguments = ["ffprobe", "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", output.path]
            probe.standardOutput = pipe
            try probe.run(); let tracks = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); probe.waitUntilExit()
            try require(tracks.contains("video") && tracks.contains("audio"), "HLS must preserve video and separate audio: \(path)")
            if path == "master/index.m3u8" {
                let master = root.appendingPathComponent(path)
                let original = try String(contentsOf: master, encoding: .utf8)
                try Data(original.replacingOccurrences(of: "BANDWIDTH=1000000", with: "BANDWIDTH=2000000").utf8).write(to: master)
                do {
                    _ = try await HLSDownloader.download(resource: resource, directory: directory, progress: { _ in })
                    throw Failure(message: "resume must not substitute another master quality")
                } catch DownloadFailure.invalidSelection {}
            }
            try require(progress.values.contains(where: { $0.bytes > 0 && $0.completedSegments == $0.totalSegments }), "HLS completion must report actual bytes/segments")
        }
        let sourceFiles = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("fmp4"), includingPropertiesForKeys: [.fileSizeKey])
        let segments = sourceFiles.filter { $0.pathExtension == "m4s" }
        let expectedBytes = try sourceFiles.filter { ["m4s", "mp4"].contains($0.pathExtension) }.reduce(Int64(0)) {
            $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        }
        let resource = DownloadResource(url: base.appendingPathComponent("fmp4/index.m3u8"), format: .hls, context: context)
        let service = try DownloadService(storeURL: root.appendingPathComponent("hls-ledger.json"),
            policy: { DownloadPolicySnapshot(outputDirectory: root.appendingPathComponent("output"), concurrencyLimit: 1, temporaryDirectory: root.appendingPathComponent("temporary")) },
            validator: { _ in }, resolver: { _ in resource })
        let task = try await service.create(selection: selection(), title: "hls-ledger")
        let completed = try await waitFor(service, id: task.id) { $0.state == .completed }
        try require(completed.bytes == expectedBytes && completed.completedSegments == segments.count && completed.totalSegments == segments.count, "completion must retain actual transport bytes and acknowledge every segment, independent of coalesced callbacks and remux size")
        await service.shutdown()
        print("PASS HLS: nonzero implicit AES IV, fMP4 map, implicit byte range and master audio/video")
    }
}
