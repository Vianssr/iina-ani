import Foundation
import Darwin
import CryptoKit

/// Owns records, worker lifetime and task-private temporary files. No UI owns a transfer.
actor DownloadService {
    typealias Resolver = @Sendable (PlayableSelection) async throws -> DownloadResource
    typealias Validator = @Sendable (PlayableSelection) throws -> Void

    private struct Store: Codable {
        let version: Int
        let records: [DownloadRecord]
    }
    enum Event: Sendable {
        case snapshot([DownloadRecord])
        case changed(DownloadRecord)
        case removed(UUID)
    }

    private let storeURL: URL
    private let lockFD: Int32
    private let resolve: Resolver
    private let validate: Validator
    private let accounts: SiteAccounts
    private let policy: @Sendable () -> DownloadPolicySnapshot
    private let ffmpegURL: URL?
    private let torrentEnabled: @Sendable () -> Bool
    private var records: [UUID: DownloadRecord]
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var coverWorkers: [String: Task<Void, Never>] = [:]
    private var torrentImports: [UUID: Task<TorrentImport, Error>] = [:]
    private var leases: [UUID: AccountUseLease] = [:]
    private var observers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var samples: [UUID: (date: Date, bytes: Int64)] = [:]
    private var stopping = false
    private let torrentPool: TorrentTransferPool
    private var stoppingTorrentTransfers = false
    private let streaming: TorrentStreamingService

    private var acceptingNewTasks = true
    private var pendingAdmissions = 0
    private var torrentAdmissionDrain: CheckedContinuation<Void, Never>?
    private var pendingTorrentAdmissions = 0 {
        didSet {
            if pendingTorrentAdmissions == 0 {
                torrentAdmissionDrain?.resume()
                torrentAdmissionDrain = nil
            }
        }
    }

    /// Serialized with admission, including awaits for account and Torrent leases.
    func setAcceptingNewTasks(_ enabled: Bool, persist: @Sendable () -> Void) throws {
        if !enabled {
            let active = records.values.filter { workers[$0.id] != nil || [.queued, .resolving, .downloading, .finalizing].contains($0.state) }
            var reasons = active.map { String(localized: "活動下載：\($0.title)（\($0.id.uuidString)）") }
            if pendingAdmissions > 0 || !torrentImports.isEmpty { reasons.append(String(localized: "下載／Torrent 匯入操作尚在進行。")) }
            guard reasons.isEmpty else { throw WorkspaceCapabilityFailure(reasons: reasons) }
        }
        acceptingNewTasks = enabled
        persist()
    }

    init(storeURL: URL, accounts: SiteAccounts = .shared,
         policy: @escaping @Sendable () -> DownloadPolicySnapshot,
         validator: @escaping Validator, resolver: @escaping Resolver, ffmpegURL: URL? = nil,
         streaming: TorrentStreamingService = .shared, acceptingNewTasks: Bool = true,
         torrentUploadLimit: UInt32 = TorrentUploadPolicy.maximumBytesPerSecond,
         torrentEnabled: @escaping @Sendable () -> Bool = { Preferences.shared.isSourceEnabled("torrent") }) throws {
        self.storeURL = storeURL
        self.streaming = streaming
        torrentPool = TorrentTransferPool(uploadLimit: torrentUploadLimit)
        self.accounts = accounts
        self.policy = policy
        self.validate = validator
        self.resolve = resolver
        self.ffmpegURL = ffmpegURL
        self.torrentEnabled = torrentEnabled
        self.acceptingNewTasks = acceptingNewTasks
        let manager = FileManager.default
        try manager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(storeURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw DownloadFailure.persistence }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw DownloadFailure.persistence }
        do {
            var loaded: [UUID: DownloadRecord] = [:]
            if manager.fileExists(atPath: storeURL.path) {
                guard (try? manager.destinationOfSymbolicLink(atPath: storeURL.path)) == nil else { throw DownloadFailure.persistence }
                let saved = try JSONDecoder().decode(Store.self, from: Data(contentsOf: storeURL))
                guard saved.version == 1 else { throw DownloadFailure.persistence }
                for var record in saved.records {
                    guard loaded[record.id] == nil else { throw DownloadFailure.persistence }
                    if [.queued, .resolving, .downloading, .finalizing].contains(record.state) {
                        record.state = .paused
                        record.needsRecovery = true
                        record.restartReason = String(localized: "工作已中斷；恢復時重新解析原始選擇並驗證續傳身份。")
                    }
                    record.bytesPerSecond = 0
                    record.coverURL = ImageCacheService.publicCoverURL(record.coverURL)
                    record.remainingSeconds = nil
                    loaded[record.id] = record
                }
            }
            self.records = loaded
            self.lockFD = fd
            try Self.save(loaded, to: storeURL)
        } catch {
            close(fd)
            throw DownloadFailure.persistence
        }
    }

    deinit { close(lockFD) }

    static func production(decoder: VideoDecoder, storage: AppStoragePaths, preferences: Preferences,
                           streaming: TorrentStreamingService) throws -> DownloadService {
        let source = DownloadSourceResolver(decoder: decoder)
        return try DownloadService(storeURL: storage.downloadTaskStore, accounts: decoder.accounts,
            policy: { preferences.downloadPolicySnapshot(temporaryDirectory: storage.downloadTemporaryDirectory) },
            validator: { try source.validate($0) }, resolver: { try await source.resolve($0) },
            streaming: streaming, acceptingNewTasks: preferences.capabilityEnabled(.downloads),
            torrentUploadLimit: preferences.torrentUploadLimitBytesPerSecond,
            torrentEnabled: { preferences.isSourceEnabled("torrent") })
    }

    func list() -> [DownloadRecord] { records.values.sorted { $0.createdAt < $1.createdAt } }
    /// Rebuildable completion metadata; externally removed files are never marked downloaded.
    func completedDownloads() -> [DownloadRecord] {
        list().filter { value in
            guard value.state == .completed, let file = value.completedFile else { return false }
            var stale = false
            let root = value.outputDirectoryBookmark.flatMap {
                try? URL(resolvingBookmarkData: $0, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            } ?? value.outputDirectory
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            var info = stat()
            if value.outputSubdirectory != nil {
                guard let output = try? openOutputDirectory(value, create: false) else { return false }
                defer { close(output.fd) }
                guard file.deletingLastPathComponent().standardizedFileURL == output.url.standardizedFileURL,
                      fstatat(output.fd, file.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            } else if lstat(file.path, &info) != 0 { return false }
            return info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        }
    }
    func record(_ id: UUID) throws -> DownloadRecord {
        guard let value = records[id] else { throw DownloadFailure.invalidOperation }
        return value
    }
    func events() -> AsyncStream<Event> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(256))
        observers[id] = continuation
        continuation.yield(.snapshot(list()))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    /// Called at startup, without starting any interrupted transfer.
    func restoreAccountLeases() async {
        for value in list() { cacheCover(value.coverURL) }
        for value in list() where value.state == .paused {
            do { try await acquireLease(value) }
            catch {
                guard var current = records[value.id], current.state == .paused else { continue }
                current.state = .failed
                current.failure = .authorization
                records[value.id] = current
                do { try persist(); emit(current) } catch { stopping = true }
            }
        }
    }

    /// Fetch metadata into owned storage only; no files are selected or downloaded yet.
    func importTorrent(raw: String, uploadPolicy: TorrentUploadPolicy, timeout: Duration = .seconds(45)) async throws -> TorrentImport {
        guard !stopping, !stoppingTorrentTransfers else { throw DownloadFailure.invalidOperation }
        guard uploadPolicy.acknowledged, (1...TorrentUploadPolicy.maximumBytesPerSecond).contains(uploadPolicy.bytesPerSecond),
              torrentEnabled(), let input = try SourceRegistry.shared.torrentInput(for: raw) else { throw DownloadFailure.invalidSelection }
        let known: TorrentSelectedFile?
        let hashes: Set<String>
        if input.isFileURL {
            known = nil
            hashes = []
        } else {
            do { hashes = try TorrentSession.magnetIdentity(raw) }
            catch { throw TorrentTransferPool.classifyNativeError(error) }
            let existing = records.values.first { record in
                guard let selection = record.selection.torrent else { return false }
                return !hashes.isEmpty && hashes.isSubset(of: selection.infoHashes)
            }
            known = existing.flatMap { record in
                guard let selection = record.selection.torrent, let root = record.torrentStorageDirectory else { return nil }
                return TorrentSelectedFile(selection: selection, storageRoot: root)
            }
        }
        let root = policy().temporaryDirectory, pool = torrentPool, id = UUID()
        let worker = Task { try await pool.importTorrent(input: input, raw: raw, root: root, magnetHashes: hashes, known: known, uploadPolicy: uploadPolicy, timeout: timeout) }
        torrentImports[id] = worker
        defer { torrentImports.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            if stopping || Task.isCancelled {
                await pool.cancelImport(result.id)
                throw CancellationError()
            }
            return result
        } onCancel: { worker.cancel() }
    }

    func cancelTorrentImport(importID: UUID) async {
        await torrentPool.cancelImport(importID)
    }

    func selectTorrentFile(importID: UUID, fileIndex: Int, uploadPolicy: TorrentUploadPolicy) async throws -> TorrentSelectedFile {
        guard !stopping, !stoppingTorrentTransfers, torrentEnabled() else { throw DownloadFailure.invalidOperation }
        pendingAdmissions += 1; pendingTorrentAdmissions += 1
        defer { pendingAdmissions -= 1; pendingTorrentAdmissions -= 1 }
        return try await torrentPool.select(importID: importID, fileIndex: fileIndex, uploadPolicy: uploadPolicy)
    }

    func releaseTorrentSelection(_ selected: TorrentSelectedFile) async {
        await torrentPool.release(selection: selected.selection, taskID: UUID(), root: selected.storageRoot)
    }

    func torrentPlayback(selected: TorrentSelectedFile, uploadPolicy: TorrentUploadPolicy, port: Int) async throws -> TorrentPlaybackGrant {
        guard !stopping, !stoppingTorrentTransfers, torrentEnabled() else { throw DownloadFailure.invalidOperation }
        pendingAdmissions += 1; pendingTorrentAdmissions += 1
        defer { pendingAdmissions -= 1; pendingTorrentAdmissions -= 1 }
        return try await streaming.grant(selected: selected, uploadPolicy: uploadPolicy, pool: torrentPool, port: port)
    }

    func torrentPlayback(selection: TorrentSelection, uploadPolicy: TorrentUploadPolicy, port: Int) async throws -> TorrentPlaybackGrant {
        let root = records.values.first(where: { $0.selection.torrent == selection })?.torrentStorageDirectory ??
            policy().temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TorrentPrivate", isDirectory: true)
                .appendingPathComponent(selection.infoHashes.sorted().joined(separator: "_").replacingOccurrences(of: ":", with: "-"), isDirectory: true)
        return try await torrentPlayback(selected: TorrentSelectedFile(selection: selection, storageRoot: root),
                                        uploadPolicy: uploadPolicy, port: port)
    }

    func setTorrentUploadLimit(_ bytesPerSecond: UInt32) async throws {
        try await torrentPool.setUploadLimit(bytesPerSecond)
    }

    /// Stop P2P ownership without deleting records, completed files or resumable pieces.
    func stopTorrentTransfers() async throws {
        guard !stoppingTorrentTransfers else { throw DownloadFailure.invalidOperation }
        stoppingTorrentTransfers = true
        defer { stoppingTorrentTransfers = false }
        if pendingTorrentAdmissions > 0 {
            await withCheckedContinuation { torrentAdmissionDrain = $0 }
        }
        let imports = Array(torrentImports.values)
        imports.forEach { $0.cancel() }
        for worker in imports {
            if let imported = try? await worker.value { await torrentPool.cancelImport(imported.id) }
        }
        await torrentPool.cancelAllImports()
        await streaming.revokeAll(pool: torrentPool)
        for value in list() where value.selection.torrent != nil && value.allowedOperations.contains(.pause) {
            try await pause(value.id)
        }
        for value in list() {
            if let selection = value.selection.torrent, let root = value.torrentStorageDirectory {
                await torrentPool.release(selection: selection, taskID: value.id, root: root)
            }
        }
        await torrentPool.releaseUnownedTransfers()
    }

    /// Creates a persistent task only after the user explicitly chose a file index.
    func createTorrentTask(importID: UUID, fileIndex: Int, uploadPolicy: TorrentUploadPolicy,
                           title: String, episodeTitle: String? = nil, workID: UUID? = nil,
                           coverURL: String? = nil, bangumiID: Int? = nil, episodeKey: String? = nil) async throws -> DownloadRecord {
        guard !stopping, !stoppingTorrentTransfers, torrentEnabled() else { throw DownloadFailure.invalidOperation }
        guard acceptingNewTasks else { throw WorkspaceCapabilityFailure(reasons: [String(localized: "新增下載已停用；既有資料保留。 ")]) }
        pendingAdmissions += 1; pendingTorrentAdmissions += 1
        defer { pendingAdmissions -= 1; pendingTorrentAdmissions -= 1 }
        let selected = try await torrentPool.select(importID: importID, fileIndex: fileIndex, uploadPolicy: uploadPolicy)
        let item = SourceItemRef(sourceID: "torrent", pageURL: selected.selection.identityURL.absoluteString, kind: .video)
        return try await create(selection: PlayableSelection(item: item, torrent: selected.selection), title: title,
                                episodeTitle: episodeTitle, workID: workID, torrentUploadPolicy: uploadPolicy,
                                torrentStorageDirectory: selected.storageRoot, coverURL: coverURL,
                                bangumiID: bangumiID, episodeKey: episodeKey)
    }

    /// Playback leases share native storage, but never change a download task's state.
    func torrentPlayback(_ id: UUID, port: Int) async throws -> TorrentPlaybackGrant {
        guard !stopping, !stoppingTorrentTransfers, torrentEnabled() else { throw DownloadFailure.invalidOperation }
        pendingAdmissions += 1; pendingTorrentAdmissions += 1
        defer { pendingAdmissions -= 1; pendingTorrentAdmissions -= 1 }
        let value = try record(id)
        guard let selection = value.selection.torrent, let root = value.torrentStorageDirectory,
              value.torrentUploadPolicyAcknowledged == true, let limit = value.torrentUploadBytesPerSecond else {
            throw DownloadFailure.invalidSelection
        }
        return try await streaming.grant(
            selected: TorrentSelectedFile(selection: selection, storageRoot: root),
            uploadPolicy: try TorrentUploadPolicy(bytesPerSecond: limit, acknowledged: true), pool: torrentPool, port: port)
    }

    /// Playback-only selection does not manufacture a persistent download record.
    func torrentPlayback(importID: UUID, fileIndex: Int, uploadPolicy: TorrentUploadPolicy, port: Int) async throws -> TorrentPlaybackGrant {
        guard !stopping, !stoppingTorrentTransfers, torrentEnabled() else { throw DownloadFailure.invalidOperation }
        pendingAdmissions += 1; pendingTorrentAdmissions += 1
        defer { pendingAdmissions -= 1; pendingTorrentAdmissions -= 1 }
        let selected = try await torrentPool.select(importID: importID, fileIndex: fileIndex, uploadPolicy: uploadPolicy)
        return try await streaming.grant(selected: selected, uploadPolicy: uploadPolicy, pool: torrentPool, port: port)
    }

    func connectTorrentPeer(_ id: UUID, loopbackPort: UInt16) async throws {
        let value = try record(id)
        guard let torrent = value.selection.torrent, let root = value.torrentStorageDirectory else { throw DownloadFailure.invalidOperation }
        try await torrentPool.connect(selection: torrent, taskID: id, loopbackPort: loopbackPort, root: root)
    }

    @discardableResult
    func create(selection: PlayableSelection, title: String, episodeTitle: String? = nil,
                workID: UUID? = nil, torrentUploadPolicy: TorrentUploadPolicy? = nil,
                torrentStorageDirectory: URL? = nil, coverURL: String? = nil,
                bangumiID: Int? = nil, episodeKey: String? = nil) async throws -> DownloadRecord {
        guard !stopping else { throw DownloadFailure.persistence }
        guard selection.classification.kind != .live else { throw DownloadFailure.unsupportedMedia }
        guard acceptingNewTasks else { throw WorkspaceCapabilityFailure(reasons: [String(localized: "新增下載已停用；既有資料保留。 ")]) }
        pendingAdmissions += 1
        if selection.torrent != nil { pendingTorrentAdmissions += 1 }
        defer {
            pendingAdmissions -= 1
            if selection.torrent != nil { pendingTorrentAdmissions -= 1 }
        }
        let captured = policy()
        let storageRoot: URL?
        if let torrent = selection.torrent {
            storageRoot = torrentStorageDirectory ?? records.values.first(where: { $0.selection.torrent?.infoHashes == torrent.infoHashes })?.torrentStorageDirectory ??
                captured.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TorrentPrivate", isDirectory: true)
                    .appendingPathComponent(torrent.infoHashes.sorted().joined(separator: "_").replacingOccurrences(of: ":", with: "-"), isDirectory: true)
        } else { storageRoot = nil }
        if let torrent = selection.torrent {
            guard !stoppingTorrentTransfers else { throw DownloadFailure.invalidOperation }
            guard torrent.isValid, torrent.isPlayableMedia, selection.item.sourceID == "torrent",
                  selection.item.pageURL == torrent.identityURL.absoluteString,
                  selection.accountID == nil, selection.episode == nil,
                  let torrentUploadPolicy, torrentUploadPolicy.acknowledged, let storageRoot,
                  storageRoot.isFileURL else { throw DownloadFailure.invalidSelection }
            guard torrentEnabled() else { throw SiteAccountError.disabled }
        } else {
            guard torrentUploadPolicy == nil, torrentStorageDirectory == nil else { throw DownloadFailure.invalidSelection }
            try validate(selection)
        }
        let now = Date(), id = UUID()
        var value = DownloadRecord(id: id, selection: selection, workID: workID, title: title,
            episodeTitle: episodeTitle, outputDirectory: captured.outputDirectory,
            temporaryDirectory: captured.temporaryDirectory.appendingPathComponent(id.uuidString, isDirectory: true),
            concurrencyLimit: captured.concurrencyLimit, createdAt: now, updatedAt: now)
        value.outputDirectoryBookmark = try? captured.outputDirectory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        value.coverURL = ImageCacheService.publicCoverURL(coverURL)
        value.bangumiID = bangumiID.flatMap { $0 > 0 ? $0 : nil }
        value.episodeKey = episodeKey
        value.outputSubdirectory = groupedSubdirectory(selection: selection, title: title, workID: workID, bangumiID: value.bangumiID)
        if let torrentUploadPolicy {
            value.torrentUploadBytesPerSecond = torrentUploadPolicy.bytesPerSecond
            value.torrentUploadPolicyAcknowledged = torrentUploadPolicy.acknowledged
        }
        if let torrent = selection.torrent, let storageRoot {
            value.torrentStorageDirectory = storageRoot
            try await torrentPool.register(selection: torrent, uploadLimit: torrentUploadPolicy!.bytesPerSecond, root: storageRoot)
        }
        try await acquireLease(value)
        guard !stopping, selection.torrent == nil || !stoppingTorrentTransfers else { await releaseLease(id); throw DownloadFailure.invalidOperation }
        records[id] = value
        do { try persist() }
        catch { records.removeValue(forKey: id); await releaseLease(id); throw error }
        emit(value)
        cacheCover(value.coverURL)
        schedule()
        return value
    }

    func pause(_ id: UUID) async throws {
        var value = try record(id)
        guard value.allowedOperations.contains(.pause) else { throw DownloadFailure.invalidOperation }
        value.state = .paused
        value.bytesPerSecond = 0
        value.remainingSeconds = nil
        try commit(value)
        if let worker = workers[id] { worker.cancel(); await worker.value }
        else if let torrent = value.selection.torrent, let root = value.torrentStorageDirectory {
            await torrentPool.release(selection: torrent, taskID: id, root: root)
        }
        // Paused records retain their pinned account lease; cancel stops the task completely.
        schedule()
    }

    func resume(_ id: UUID) async throws {
        guard !stopping else { throw DownloadFailure.persistence }
        guard acceptingNewTasks else { throw WorkspaceCapabilityFailure(reasons: [String(localized: "恢復下載已停用；請先啟用下載能力。 ")]) }
        pendingAdmissions += 1
        defer { pendingAdmissions -= 1 }
        var value = try record(id)
        let isTorrent = value.selection.torrent != nil
        if isTorrent { pendingTorrentAdmissions += 1 }
        defer { if isTorrent { pendingTorrentAdmissions -= 1 } }
        guard value.allowedOperations.contains(.resume), workers[id] == nil else { throw DownloadFailure.invalidOperation }
        if let torrent = value.selection.torrent {
            guard !stoppingTorrentTransfers else { throw DownloadFailure.invalidOperation }
            guard torrent.isValid, value.torrentUploadPolicyAcknowledged == true,
                  let limit = value.torrentUploadBytesPerSecond,
                  (1...TorrentUploadPolicy.maximumBytesPerSecond).contains(limit), torrentEnabled() else {
                throw DownloadFailure.torrentResumeCorrupt
            }
        } else {
            try validate(value.selection)
        }
        try await acquireLease(value)
        guard value.selection.torrent == nil || !stoppingTorrentTransfers else { await releaseLease(id); throw DownloadFailure.invalidOperation }
        // Actor reentrancy cannot overwrite a concurrent cancel.
        guard records[id]?.allowedOperations.contains(.resume) == true else { await releaseLease(id); throw DownloadFailure.invalidOperation }
        value = try record(id)
        value.state = .queued
        value.needsRecovery = false
        value.failure = nil
        do { try commit(value) } catch { await releaseLease(id); throw error }
        schedule()
    }

    func cancel(_ id: UUID) async throws {
        var value = try record(id)
        guard value.allowedOperations.contains(.cancel) else { throw DownloadFailure.invalidOperation }
        value.state = .canceled
        value.bytesPerSecond = 0
        value.remainingSeconds = nil
        try commit(value)
        if let worker = workers[id] { worker.cancel(); await worker.value }
        else if let torrent = value.selection.torrent, let root = value.torrentStorageDirectory {
            await torrentPool.release(selection: torrent, taskID: id, root: root)
        }
        try removeTemporary(value)
        await releaseLease(id)
        schedule()
    }

    /// Record deletion never deletes a completed file; file deletion is a separate command.
    func deleteRecord(_ id: UUID) async throws {
        let value = try record(id)
        guard value.allowedOperations.contains(.deleteRecord), workers[id] == nil else { throw DownloadFailure.invalidOperation }
        if let torrent = value.selection.torrent, let root = value.torrentStorageDirectory {
            await torrentPool.release(selection: torrent, taskID: id, root: root)
        }
        try removeTemporary(value)
        records.removeValue(forKey: id)
        do { try persist() } catch { records[id] = value; throw error }
        await releaseLease(id)
        for observer in observers.values { observer.yield(.removed(id)) }
    }

    func deleteFile(_ id: UUID) throws {
        var value = try record(id)
        guard value.allowedOperations.contains(.deleteFile), let file = value.completedFile else { throw DownloadFailure.invalidOperation }
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        value.completedFile = nil
        try commit(value)
    }

    func fileForOpening(_ id: UUID) throws -> URL {
        let value = try record(id)
        guard value.allowedOperations.contains(.openFile), let file = value.completedFile,
              FileManager.default.fileExists(atPath: file.path) else { throw DownloadFailure.missingFile }
        return file
    }

    /// Explicit lifecycle command for an orderly host shutdown; abrupt exits recover from disk.
    func shutdown() async {
        stopping = true
        await streaming.shutdown(pool: torrentPool)
        let importing = Array(torrentImports.values)
        for worker in importing { worker.cancel() }
        for worker in importing { _ = try? await worker.value }
        let running = Array(workers.values)
        for worker in running { worker.cancel() }
        for worker in running { await worker.value }
        let caching = Array(coverWorkers.values)
        for worker in caching { worker.cancel() }
        for worker in caching { await worker.value }
        for value in list() where [.queued, .resolving, .downloading].contains(value.state) {
            var paused = value
            paused.state = .paused
            paused.needsRecovery = true
            paused.bytesPerSecond = 0
            paused.remainingSeconds = nil
            records[value.id] = paused
            emit(paused)
        }
        await torrentPool.shutdown()
        do { try persist() } catch { /* The last atomic snapshot still marks work interrupted on reload. */ }
        for id in Array(leases.keys) { await releaseLease(id) }
    }

    private func cacheCover(_ value: String?) {
        guard !stopping, let cover = ImageCacheService.publicCoverURL(value), coverWorkers[cover] == nil else { return }
        coverWorkers[cover] = Task {
            await ImageCacheService.cacheDownloadCover(cover)
            self.coverWorkers.removeValue(forKey: cover)
        }
    }

    private func acquireLease(_ value: DownloadRecord) async throws {
        guard let accountID = value.selection.accountID, leases[value.id] == nil else { return }
        let lease = try await accounts.acquireUse(accountID: accountID, sourceID: value.selection.item.sourceID)
        if leases[value.id] == nil { leases[value.id] = lease }
        else { await accounts.releaseUse(lease) }
    }
    private func releaseLease(_ id: UUID) async {
        if let lease = leases.removeValue(forKey: id) { await accounts.releaseUse(lease) }
    }
    private func schedule() {
        guard !stopping else { return }
        for value in list() where value.state == .queued && workers[value.id] == nil {
            if stoppingTorrentTransfers && value.selection.torrent != nil { continue }
            // Old active tasks keep their captured limit. New policy never interrupts them.
            let limit = workers.keys.compactMap { records[$0]?.concurrencyLimit }.min() ?? value.concurrencyLimit
            guard workers.count < min(limit, value.concurrencyLimit) else { break }
            workers[value.id] = Task { await self.run(value.id) }
        }
    }

    private func run(_ id: UUID) async {
        do {
            var value = try record(id)
            guard value.state == .queued else { throw CancellationError() }
            var stale = false
            let scopedDirectory: URL
            if let bookmark = value.outputDirectoryBookmark {
                scopedDirectory = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard scopedDirectory.standardizedFileURL.path == value.outputDirectory.standardizedFileURL.path else { throw DownloadFailure.directoryNotWritable }
            } else { scopedDirectory = value.outputDirectory }
            let scoped = scopedDirectory.startAccessingSecurityScopedResource()
            defer { if scoped { scopedDirectory.stopAccessingSecurityScopedResource() } }
            value.state = .resolving
            try commit(value)
            try prepareDirectories(value)
            let resource: DownloadResource?
            if value.selection.torrent == nil { resource = try await resolve(value.selection) }
            else { resource = nil }
            try Task.checkCancellation()
            guard records[id]?.state == .resolving else { throw CancellationError() }
            value = try record(id)
            value.state = .downloading
            value.bytesPerSecond = 0
            value.remainingSeconds = nil
            try commit(value)
            samples[id] = (Date(), value.bytes)
            let progress: DownloadProgressHandler = { [weak self] update in
                Task { await self?.updateProgress(id, update) }
            }
            let transferred: URL
            let finalProgress: DownloadTransferProgress
            var outputExtension = "bin"
            var isHLS = false
            if let torrent = value.selection.torrent {
                guard value.torrentUploadPolicyAcknowledged == true, let limit = value.torrentUploadBytesPerSecond,
                      let storageRoot = value.torrentStorageDirectory else { throw DownloadFailure.invalidSelection }
                let file = try await torrentPool.download(selection: torrent, taskID: id, root: storageRoot,
                                                          uploadLimit: limit, progress: progress)
                try Task.checkCancellation()
                transferred = value.temporaryDirectory.appendingPathComponent("torrent-selected.partial")
                if FileManager.default.fileExists(atPath: transferred.path) { try FileManager.default.removeItem(at: transferred) }
                try FileManager.default.copyItem(at: file, to: transferred)
                let size = ((try FileManager.default.attributesOfItem(atPath: transferred.path)[.size]) as? NSNumber)?.uint64Value ?? 0
                guard size == torrent.size else { throw DownloadFailure.torrentDataMissing }
                await torrentPool.release(selection: torrent, taskID: id, root: storageRoot)
                finalProgress = .init(bytes: Int64(size), totalBytes: Int64(size))
                guard torrent.isPlayableMedia else { throw DownloadFailure.unsupportedMedia }
                outputExtension = URL(fileURLWithPath: torrent.path).pathExtension.lowercased()
            } else {
                guard let resolved = resource else { throw DownloadFailure.invalidSelection }
                isHLS = resolved.format == .hls
                outputExtension = resolved.fileExtension
                if resolved.format == .direct {
                    transferred = value.temporaryDirectory.appendingPathComponent("media.partial")
                    _ = try await DirectDownloader.download(resource: resolved, destination: transferred, progress: progress)
                    let size = ((try FileManager.default.attributesOfItem(atPath: transferred.path)[.size]) as? NSNumber)?.int64Value ?? 0
                    finalProgress = .init(bytes: size, totalBytes: size)
                } else {
                    let hls = value.temporaryDirectory.appendingPathComponent("HLS", isDirectory: true)
                    let downloaded = try await HLSDownloader.download(resource: resolved, directory: hls, progress: progress)
                    transferred = downloaded.playlist
                    finalProgress = downloaded.progress
                }
            }
            try Task.checkCancellation()
            guard records[id]?.state == .downloading else { throw CancellationError() }
            value = try record(id)
            // The writer result is authoritative; queued/coalesced callbacks may trail its return.
            value.bytes = finalProgress.bytes
            value.totalBytes = finalProgress.totalBytes
            value.completedSegments = finalProgress.completedSegments
            value.totalSegments = finalProgress.totalSegments
            value.state = .finalizing
            value.bytesPerSecond = 0
            value.remainingSeconds = nil
            try commit(value)
            // Finalization is deliberately non-interruptible; operations are empty in this state.
            let ready = isHLS ? try await HLSDownloader.finalize(playlist: transferred, directory: value.temporaryDirectory, ffmpegURL: ffmpegURL) : transferred
            let completed = try publish(ready, record: value, extension: outputExtension)
            value = try record(id)
            value.completedFile = completed
            value.state = .completed
            value.failure = nil
            do { try commit(value) }
            catch { try? FileManager.default.removeItem(at: completed); throw error }
            try removeTemporary(value)
            await releaseLease(id)
        } catch {
            if let value = records[id], let torrent = value.selection.torrent, let root = value.torrentStorageDirectory {
                await torrentPool.release(selection: torrent, taskID: id, root: root)
            }
            if var value = records[id], ![.paused, .canceled, .completed, .failed].contains(value.state) {
                if stopping && Task.isCancelled {
                    value.state = .paused
                    value.needsRecovery = true
                } else {
                    value.state = .failed
                    value.failure = Self.failure(error)
                }
                value.bytesPerSecond = 0
                value.remainingSeconds = nil
                do { try commit(value) } catch { value.failure = .persistence; records[id] = value; emit(value); stopping = true }
            }
            if records[id]?.state != .paused { await releaseLease(id) }
        }
        workers.removeValue(forKey: id)
        samples.removeValue(forKey: id)
        schedule()
    }

    private func updateProgress(_ id: UUID, _ update: DownloadTransferProgress) {
        guard var value = records[id], value.state == .downloading else { return }
        let now = Date(), previous = samples[id] ?? (now, update.bytes)
        let elapsed = now.timeIntervalSince(previous.date)
        if elapsed < 0.25, update.restartReason == nil, update.completedSegments == value.completedSegments, update.totalBytes == nil || update.bytes != update.totalBytes { return }
        let delta = max(0, update.bytes - previous.bytes)
        value.bytes = update.bytes
        value.totalBytes = update.totalBytes
        value.completedSegments = update.completedSegments
        value.totalSegments = update.totalSegments
        if let reason = update.restartReason { value.restartReason = reason }
        value.bytesPerSecond = elapsed > 0 ? Double(delta) / elapsed : 0
        value.remainingSeconds = update.totalBytes.flatMap { total in
            value.bytesPerSecond > 0 ? Double(max(0, total - update.bytes)) / value.bytesPerSecond : nil
        }
        samples[id] = (now, update.bytes)
        do { try commit(value) }
        catch {
            value.state = .failed
            value.failure = .persistence
            records[id] = value
            emit(value)
            stopping = true
            workers[id]?.cancel()
        }
    }

    private func commit(_ input: DownloadRecord) throws {
        var value = input
        value.updatedAt = Date()
        let old = records[value.id]
        records[value.id] = value
        do { try persist() } catch { records[value.id] = old; throw error }
        emit(value)
    }
    private func emit(_ value: DownloadRecord) { for observer in observers.values { observer.yield(.changed(value)) } }
    private func persist() throws { try Self.save(records, to: storeURL) }
    private static func save(_ records: [UUID: DownloadRecord], to url: URL) throws {
        do {
            let data = try JSONEncoder().encode(Store(version: 1, records: records.values.sorted { $0.createdAt < $1.createdAt }))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw DownloadFailure.persistence }
    }
    private static func failure(_ error: any Error) -> DownloadFailure {
        if error is SiteAccountError { return .authorization }
        if let error = error as? VideoGetError {
            switch error {
            case .needLogin, .needVip, .cantWatch: return .authorization
            case .notSupported: return .unsupportedSource
            default: return .mediaUnavailable
            }
        }
        if let error = error as? TorrentSession.Failure { return TorrentTransferPool.classifyNativeError(error) }
        return DownloadFailure.classify(error)
    }

    private static func groupingIdentity(selection: PlayableSelection, workID: UUID?, bangumiID: Int?) -> String? {
        if let bangumiID, bangumiID > 0 { return "bangumi-\(bangumiID)" }
        guard selection.classification.kind != .video else { return nil }
        let anime = selection.classification.kind == .anime || MediaClassification.requiresBangumiLookup(for: selection.item) ||
            selection.item.kind == .work || selection.torrent != nil && workID != nil
        guard anime else { return nil }
        if let workID { return "work-\(workID.uuidString.lowercased())" }
        guard selection.item.kind == .work else { return nil }
        let ref = selection.item
        let identity = "\(ref.sourceID.utf8.count):\(ref.sourceID)\(ref.pageURL.utf8.count):\(ref.pageURL)"
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "source-" + hash
    }

    private func groupedSubdirectory(selection: PlayableSelection, title: String, workID: UUID?, bangumiID: Int?) -> String? {
        guard let identity = Self.groupingIdentity(selection: selection, workID: workID, bangumiID: bangumiID) else { return nil }
        // Retain the first name even when another source has a different display title.
        if let existing = list().first(where: {
            $0.outputSubdirectory != nil && Self.groupingIdentity(selection: $0.selection, workID: $0.workID, bangumiID: $0.bangumiID) == identity
        })?.outputSubdirectory { return existing }
        return "\(Self.safeName(title, maximumBytes: 100)) [\(identity)]"
    }

    private static func safeName(_ value: String, maximumBytes: Int) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "_")
        var end = cleaned.startIndex, count = 0
        while end < cleaned.endIndex {
            let next = cleaned.index(after: end), bytes = cleaned[end..<next].utf8.count
            guard count + bytes <= maximumBytes else { break }
            count += bytes
            end = next
        }
        let name = String(cleaned[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "Download" : name
    }

    /// Pin the destination with directory descriptors; no child symlink can redirect publication.
    private func openOutputDirectory(_ value: DownloadRecord, create: Bool) throws -> (fd: Int32, url: URL) {
        guard value.outputDirectory.isFileURL else { throw DownloadFailure.directoryNotWritable }
        if create { try FileManager.default.createDirectory(at: value.outputDirectory, withIntermediateDirectories: true) }
        // Foundation preserves macOS /var aliases; realpath is required before O_NOFOLLOW traversal.
        guard let resolved = realpath(value.outputDirectory.path, nil) else { throw DownloadFailure.directoryNotWritable }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DownloadFailure.directoryNotWritable }
        do {
            for component in root.pathComponents.dropFirst() {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw DownloadFailure.directoryNotWritable }
                close(fd)
                fd = next
            }
            guard let child = value.outputSubdirectory else { return (fd, value.outputDirectory) }
            guard !child.isEmpty, child != ".", child != "..", child.utf8.count <= 255,
                  !child.contains("/"), !child.contains("\\"), !child.contains(":"),
                  !child.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw DownloadFailure.directoryNotWritable
            }
            if create, mkdirat(fd, child, 0o755) != 0, errno != EEXIST {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let next = openat(fd, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw DownloadFailure.directoryNotWritable }
            close(fd)
            return (next, value.outputDirectory.appendingPathComponent(child, isDirectory: true))
        } catch { close(fd); throw error }
    }


    private func prepareDirectories(_ value: DownloadRecord) throws {
        do {
            let manager = FileManager.default
            let output = try openOutputDirectory(value, create: true)
            defer { close(output.fd) }
            try manager.createDirectory(at: value.temporaryDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let probe = ".iina-write-\(value.id.uuidString)"
            let fd = openat(output.fd, probe, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            close(fd)
            unlinkat(output.fd, probe, 0)
        } catch {
            let failure = DownloadFailure.classify(error)
            throw failure == .diskFull ? failure : DownloadFailure.directoryNotWritable
        }
    }
    private func removeTemporary(_ value: DownloadRecord) throws {
        if FileManager.default.fileExists(atPath: value.temporaryDirectory.path) {
            try FileManager.default.removeItem(at: value.temporaryDirectory)
        }
    }
    private func publish(_ ready: URL, record: DownloadRecord, extension ext: String) throws -> URL {
        let output = try openOutputDirectory(record, create: false)
        defer { close(output.fd) }
        let stage = ".iina-\(record.id.uuidString).partial"
        if unlinkat(output.fd, stage, 0) != 0, errno != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { unlinkat(output.fd, stage, 0) }
        // Rename on the same filesystem; use descriptor-based copying only across volumes.
        if Darwin.renameatx_np(AT_FDCWD, ready.path, output.fd, stage, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EXDEV else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let source = Darwin.open(ready.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard source >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(source) }
            let target = openat(output.fd, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard target >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(target) }
            guard fcopyfile(source, target, nil, copyfile_flags_t(COPYFILE_DATA)) == 0, fsync(target) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            try FileManager.default.removeItem(at: ready)
        }
        let rawTitle = record.title + (record.episodeTitle.map { " - " + $0 } ?? "")
        let title = Self.safeName(rawTitle, maximumBytes: 180)
        guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw DownloadFailure.unsupportedMedia }
        var suffix = 0
        while true {
            let name = suffix == 0 ? "\(title).\(ext)" : "\(title) (\(suffix)).\(ext)"
            // Exclusive descriptor-relative publication cannot follow or replace a symlink.
            if Darwin.renameatx_np(output.fd, stage, output.fd, name, UInt32(RENAME_EXCL)) == 0 {
                return output.url.appendingPathComponent(name)
            }
            guard errno == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            suffix += 1
        }
    }
}
