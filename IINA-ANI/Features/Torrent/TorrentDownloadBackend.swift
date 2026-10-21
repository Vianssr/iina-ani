import Foundation
import Darwin
import TorrentBridge

/// DownloadService-owned native transfers. Piece data remains under its private owned root.
actor TorrentTransferPool {
    private struct Transfer {
        let session: TorrentSession
        let nativeID: UInt32
        let root: URL
        let metadata: TorrentSession.Metadata
        var activeFiles: [UUID: Int] = [:]
        var uploadLimits: [UUID: UInt32] = [:]
        var failure: DownloadFailure?
    }
    private struct Pending {
        let session: TorrentSession
        let nativeID: UInt32
        let root: URL
        let metadata: TorrentSession.Metadata
        let ownsSession: Bool
        let uploadLimit: UInt32
    }

    private var pending: [UUID: Pending] = [:]
    private struct Reader {
        let selected: TorrentSelectedFile
        let session: TorrentSession
        let nativeID: UInt64
    }
    private var readers: [UUID: Reader] = [:]
    private var transfers: [String: Transfer] = [:]
    private var lockedKeys = Set<String>()
    private var lockWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var stopping = false
    private var uploadCeiling: UInt32
    private var importingSessions: [UUID: (session: TorrentSession, limit: UInt32)] = [:]

    init(uploadLimit: UInt32 = TorrentUploadPolicy.maximumBytesPerSecond) {
        uploadCeiling = min(max(uploadLimit, 1), TorrentUploadPolicy.maximumBytesPerSecond)
    }

    func setUploadLimit(_ limit: UInt32) async throws {
        guard (1...TorrentUploadPolicy.maximumBytesPerSecond).contains(limit) else { throw DownloadFailure.invalidSelection }
        uploadCeiling = limit
        for key in Array(transfers.keys) {
            await acquire(key)
            do {
                if let value = transfers[key] {
                    try await value.session.setUploadLimit(min(uploadCeiling, value.uploadLimits.values.min() ?? uploadCeiling))
                }
                unlock(key)
            } catch { unlock(key); throw Self.mapNative(error) }
        }
        for value in importingSessions.values { try await value.session.setUploadLimit(min(uploadCeiling, value.limit)) }
        for value in pending.values where value.ownsSession { try await value.session.setUploadLimit(min(uploadCeiling, value.uploadLimit)) }
    }

    func cancelAllImports() async {
        for id in Array(pending.keys) { await cancelImport(id) }
    }

    func releaseUnownedTransfers() async {
        for key in Array(transfers.keys) {
            await acquire(key)
            if let value = transfers[key], value.activeFiles.isEmpty {
                transfers.removeValue(forKey: key)
                await value.session.close()
            }
            unlock(key)
        }
    }

    func importTorrent(input: URL, raw: String, root: URL, magnetHashes: Set<String>, known: TorrentSelectedFile?, uploadPolicy: TorrentUploadPolicy,
                       timeout: Duration) async throws -> TorrentImport {
        guard !stopping else { throw DownloadFailure.invalidOperation }
        guard uploadPolicy.acknowledged,
              (1...TorrentUploadPolicy.maximumBytesPerSecond).contains(uploadPolicy.bytesPerSecond),
              timeout > .seconds(0), timeout <= .seconds(60) else {
            throw DownloadFailure.invalidSelection
        }
        if !input.isFileURL {
            let hashes = magnetHashes
            if !hashes.isEmpty, transfers.values.first(where: { hashes.isSubset(of: $0.metadata.infoHashes) }) == nil,
               let known, hashes.isSubset(of: known.selection.infoHashes) {
                try await register(selection: known.selection, uploadLimit: uploadPolicy.bytesPerSecond, root: known.storageRoot)
            }
            guard !stopping else { throw DownloadFailure.invalidOperation }
            if !hashes.isEmpty, let existing = transfers.values.first(where: { hashes.isSubset(of: $0.metadata.infoHashes) }) {
                let token = UUID()
                pending[token] = Pending(session: existing.session, nativeID: existing.nativeID,
                                         root: existing.root, metadata: existing.metadata, ownsSession: false,
                                         uploadLimit: uploadPolicy.bytesPerSecond)
                let files = existing.metadata.files.compactMap { file in
                    file.isPad ? nil : TorrentFileCandidate(index: file.index, path: file.path, size: file.size)
                }
                return TorrentImport(id: token, infoHashes: existing.metadata.infoHashes,
                                     isPrivate: existing.metadata.isPrivate, files: files, totalBytes: existing.metadata.totalBytes)
            }
        }
        let privateRoot = root.resolvingSymlinksInPath().appendingPathComponent("TorrentPrivate", isDirectory: true)
        let importRoot = privateRoot.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try Self.validateStorage(importRoot)
        let payloadRoot = importRoot.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let session = try TorrentSession(configuration: .init(publicNetwork: true,
                                                              uploadLimitBytesPerSecond: min(uploadCeiling, uploadPolicy.bytesPerSecond)))
        let importingID = UUID()
        importingSessions[importingID] = (session, uploadPolicy.bytesPerSecond)
        defer { importingSessions.removeValue(forKey: importingID) }
        let scoped = input.isFileURL && input.startAccessingSecurityScopedResource()
        defer { if scoped { input.stopAccessingSecurityScopedResource() } }
        do {
            let nativeID = input.isFileURL ? try await session.add(torrent: input, directory: payloadRoot) :
                try await session.add(magnet: raw, directory: payloadRoot)
            let deadline = ContinuousClock.now + timeout
            var sawPeer = false
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard !stopping else { throw CancellationError() }
                for event in try await session.pollEvents() where event.torrentID == nativeID && event.kind == .failure {
                    throw Self.mapNative(TorrentSession.Failure(code: UInt32(max(0, event.errorCode))))
                }
                if let metadata = try await session.metadata(nativeID) {
                    guard !metadata.files.isEmpty, !metadata.infoHashes.isEmpty else { throw DownloadFailure.torrentMetadataUnavailable }
                    try await session.pause(nativeID)
                    try await session.select(nativeID, fileIndices: [])
                    let metadataFile = importRoot.appendingPathComponent("metadata.torrent")
                    let resumeFile = importRoot.appendingPathComponent("resume.dat")
                    try await session.saveResume(nativeID, resumeFile: resumeFile, metadataFile: metadataFile)
                    guard !stopping else { throw DownloadFailure.invalidOperation }
                    let token = UUID()
                    pending[token] = Pending(session: session, nativeID: nativeID, root: importRoot,
                                             metadata: metadata, ownsSession: true, uploadLimit: uploadPolicy.bytesPerSecond)
                    let files = metadata.files.filter { !$0.isPad }.map {
                        TorrentFileCandidate(index: $0.index, path: $0.path, size: $0.size)
                    }
                    return TorrentImport(id: token, infoHashes: metadata.infoHashes, isPrivate: metadata.isPrivate,
                                         files: files, totalBytes: metadata.totalBytes)
                }
                let status = try await session.status(nativeID)
                sawPeer = sawPeer || status.peers > 0
                try await Task.sleep(for: .milliseconds(200))
            }
            try await session.remove(nativeID, deleteFiles: true)
            await session.close()
            throw sawPeer ? DownloadFailure.torrentMetadataUnavailable : DownloadFailure.torrentNoPeers
        } catch {
            await session.close()
            if (try? Self.validateStorage(importRoot)) != nil { try? FileManager.default.removeItem(at: importRoot) }
            throw Self.mapNative(error)
        }
    }

    func cancelImport(_ id: UUID) async {
        guard let value = pending.removeValue(forKey: id) else { return }
        if value.ownsSession {
            await value.session.close()
            if (try? Self.validateStorage(value.root)) != nil { try? FileManager.default.removeItem(at: value.root) }
        } else {
            let key = Self.key(value.metadata.infoHashes)
            await acquire(key)
            defer { unlock(key) }
            if let transfer = transfers[key], transfer.activeFiles.isEmpty {
                transfers.removeValue(forKey: key)
                await transfer.session.close()
            }
        }
    }

    func select(importID: UUID, fileIndex: Int, uploadPolicy: TorrentUploadPolicy) async throws -> TorrentSelectedFile {
        guard !stopping, uploadPolicy.acknowledged,
              (1...TorrentUploadPolicy.maximumBytesPerSecond).contains(uploadPolicy.bytesPerSecond),
              let value = pending[importID],
              let file = value.metadata.files.first(where: { $0.index == fileIndex && !$0.isPad }),
              let selection = TorrentSelection(infoHashes: value.metadata.infoHashes, fileIndex: file.index,
                                               path: file.path, size: file.size) else {
            throw DownloadFailure.invalidSelection
        }
        guard selection.isPlayableMedia else { throw DownloadFailure.unsupportedMedia }
        let key = Self.key(value.metadata.infoHashes)
        await acquire(key)
        defer { unlock(key) }
        guard !stopping, pending.removeValue(forKey: importID) != nil else { throw DownloadFailure.invalidOperation }
        if !value.ownsSession {
            if transfers[key] == nil {
                transfers[key] = try await Self.loadTransfer(root: value.root, uploadLimit: uploadPolicy.bytesPerSecond)
            }
            guard let transfer = transfers[key], Self.matches(selection, metadata: transfer.metadata) else {
                throw DownloadFailure.resourceChanged
            }
            return TorrentSelectedFile(selection: selection, storageRoot: transfer.root)
        }
        let parent = value.root.deletingLastPathComponent()
        let stableRoot = parent.appendingPathComponent(key, isDirectory: true)
        do {
            try Self.validateStorage(value.root)
            try Self.validateStorage(stableRoot)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if transfers[key] == nil {
                if FileManager.default.fileExists(atPath: stableRoot.path) {
                    try await value.session.remove(value.nativeID, deleteFiles: true)
                    await value.session.close()
                    try? FileManager.default.removeItem(at: value.root)
                    transfers[key] = try await Self.loadTransfer(root: stableRoot, uploadLimit: uploadPolicy.bytesPerSecond)
                } else {
                    try await value.session.pause(value.nativeID)
                    try await value.session.saveResume(value.nativeID,
                        resumeFile: value.root.appendingPathComponent("resume.dat"),
                        metadataFile: value.root.appendingPathComponent("metadata.torrent"))
                    try await value.session.remove(value.nativeID, deleteFiles: false)
                    await value.session.close()
                    try FileManager.default.moveItem(at: value.root, to: stableRoot)
                    transfers[key] = try await Self.loadTransfer(root: stableRoot, uploadLimit: uploadPolicy.bytesPerSecond)
                }
            } else {
                try await value.session.remove(value.nativeID, deleteFiles: true)
                await value.session.close()
                try? FileManager.default.removeItem(at: value.root)
            }
            guard let transfer = transfers[key], transfer.metadata.infoHashes == selection.infoHashes,
                  Self.matches(selection, metadata: transfer.metadata) else { throw DownloadFailure.resourceChanged }
            return TorrentSelectedFile(selection: selection, storageRoot: transfer.root)
        } catch {
            await value.session.close()
            try? FileManager.default.removeItem(at: value.root)
            throw Self.mapNative(error)
        }
    }

    func register(selection: TorrentSelection, uploadLimit: UInt32, root: URL) async throws {
        guard selection.isValid, (1...TorrentUploadPolicy.maximumBytesPerSecond).contains(uploadLimit) else {
            throw DownloadFailure.invalidSelection
        }
        let key = Self.key(selection.infoHashes)
        await acquire(key)
        defer { unlock(key) }
        guard !stopping else { throw DownloadFailure.invalidOperation }
        try Self.validateStorage(root)
        if let transfer = transfers[key] {
            guard transfer.root.standardizedFileURL == root.standardizedFileURL,
                  Self.matches(selection, metadata: transfer.metadata) else { throw DownloadFailure.resourceChanged }
            return
        }
        let base = root.standardizedFileURL
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent("metadata.torrent").path) else {
            throw DownloadFailure.torrentResumeCorrupt
        }
        let transfer = try await Self.loadTransfer(root: base, uploadLimit: uploadLimit)
        guard Self.matches(selection, metadata: transfer.metadata) else {
            await transfer.session.close()
            throw DownloadFailure.resourceChanged
        }
        transfers[key] = transfer
    }

    func download(selection: TorrentSelection, taskID: UUID, root: URL, uploadLimit: UInt32,
                  progress: DownloadProgressHandler) async throws -> URL {
        try await register(selection: selection, uploadLimit: uploadLimit, root: root)
        let key = Self.key(selection.infoHashes)
        await acquire(key)
        guard !stopping, var transfer = transfers[key], Self.matches(selection, metadata: transfer.metadata) else {
            unlock(key)
            throw DownloadFailure.resourceChanged
        }
        transfer.activeFiles[taskID] = selection.fileIndex
        transfer.uploadLimits[taskID] = uploadLimit
        transfers[key] = transfer
        do {
            try await transfer.session.setUploadLimit(min(uploadCeiling, transfer.uploadLimits.values.min() ?? uploadLimit))
            try await transfer.session.select(transfer.nativeID, fileIndices: Set(transfer.activeFiles.values))
            try await transfer.session.resume(transfer.nativeID)
            unlock(key)
        } catch {
            unlock(key)
            throw Self.mapNative(error)
        }

        var previousVerified: UInt64 = 0
        var lastProgress = ContinuousClock.now
        var lastCheckpoint = ContinuousClock.now
        var noPeerSince: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            try await checkFailure(key)
            guard let current = transfers[key], current.activeFiles[taskID] == selection.fileIndex else { throw CancellationError() }
            let status = try await current.session.status(current.nativeID)
            let values = try await current.session.fileProgress(current.nativeID)
            guard values.indices.contains(selection.fileIndex) else { throw DownloadFailure.resourceChanged }
            let verified = min(values[selection.fileIndex], selection.size)
            progress(.init(bytes: Int64(verified), totalBytes: Int64(selection.size)))
            if verified > previousVerified {
                previousVerified = verified
                lastProgress = ContinuousClock.now
                noPeerSince = nil
            }
            if verified == selection.size {
                await acquire(key)
                defer { unlock(key) }
                guard let latest = transfers[key], latest.activeFiles[taskID] == selection.fileIndex else { throw CancellationError() }
                try await latest.session.pause(latest.nativeID)
                try await latest.session.saveResume(latest.nativeID,
                    resumeFile: latest.root.appendingPathComponent("resume.dat"),
                    metadataFile: latest.root.appendingPathComponent("metadata.torrent"))
                try await latest.session.resume(latest.nativeID)
                let file = try Self.safeFile(root: latest.root.appendingPathComponent("data", isDirectory: true), relativePath: selection.path)
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      UInt64(size) == selection.size else { throw DownloadFailure.torrentDataMissing }
                return file
            }
            if status.peers == 0 {
                if noPeerSince == nil { noPeerSince = ContinuousClock.now }
                if let since = noPeerSince, since.duration(to: .now) >= .seconds(45) { throw DownloadFailure.torrentNoPeers }
            } else {
                noPeerSince = nil
                if lastProgress.duration(to: .now) >= .seconds(180) { throw DownloadFailure.torrentDataMissing }
            }
            if lastCheckpoint.duration(to: .now) >= .seconds(5) {
                await acquire(key)
                do {
                    if let latest = transfers[key], latest.activeFiles[taskID] == selection.fileIndex {
                        try await latest.session.saveResume(latest.nativeID,
                            resumeFile: latest.root.appendingPathComponent("resume.dat"),
                            metadataFile: latest.root.appendingPathComponent("metadata.torrent"))
                    }
                } catch {
                    unlock(key)
                    throw Self.mapNative(error)
                }
                unlock(key)
                lastCheckpoint = ContinuousClock.now
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    func openReader(selected: TorrentSelectedFile, uploadPolicy: TorrentUploadPolicy) async throws -> UUID {
        guard !stopping, selected.selection.isPlayableMedia, uploadPolicy.acknowledged, readers.count < 64 else {
            throw DownloadFailure.invalidOperation
        }
        try await register(selection: selected.selection, uploadLimit: uploadPolicy.bytesPerSecond, root: selected.storageRoot)
        let key = Self.key(selected.selection.infoHashes)
        await acquire(key)
        defer { unlock(key) }
        try Task.checkCancellation()
        guard !stopping, readers.count < 64, var transfer = transfers[key] else { throw DownloadFailure.invalidOperation }
        let id = UUID()
        let nativeID = try await transfer.session.openReader(transfer.nativeID, fileIndex: selected.selection.fileIndex)
        do {
            transfer.activeFiles[id] = selected.selection.fileIndex
            transfer.uploadLimits[id] = uploadPolicy.bytesPerSecond
            try await transfer.session.setUploadLimit(min(uploadCeiling, transfer.uploadLimits.values.min() ?? uploadPolicy.bytesPerSecond))
            try await transfer.session.select(transfer.nativeID, fileIndices: Set(transfer.activeFiles.values))
            try await transfer.session.resume(transfer.nativeID)
            transfers[key] = transfer
            readers[id] = Reader(selected: selected, session: transfer.session, nativeID: nativeID)
            return id
        } catch {
            try? await transfer.session.closeReader(nativeID)
            transfer.activeFiles.removeValue(forKey: id)
            transfer.uploadLimits.removeValue(forKey: id)
            try? await transfer.session.select(transfer.nativeID, fileIndices: Set(transfer.activeFiles.values))
            if transfer.activeFiles.isEmpty { try? await transfer.session.pause(transfer.nativeID) }
            throw Self.mapNative(error)
        }
    }

    func readReader(_ id: UUID, offset: UInt64, length: Int) async throws -> Data {
        guard !stopping, let reader = readers[id] else { throw CancellationError() }
        do {
            let data = try await reader.session.readReader(reader.nativeID, offset: offset, length: length)
            try Task.checkCancellation()
            guard readers[id] != nil, !stopping else { throw CancellationError() }
            return data
        } catch {
            if stopping || readers[id] == nil || Task.isCancelled { throw CancellationError() }
            if let failure = error as? TorrentSession.Failure, failure.code == TB_ERROR_TIMEOUT.rawValue,
               let transfer = transfers[Self.key(reader.selected.selection.infoHashes)] {
                let status = try await transfer.session.status(transfer.nativeID)
                throw status.peers == 0 ? DownloadFailure.torrentNoPeers : DownloadFailure.torrentDataMissing
            }
            throw Self.mapNative(error)
        }
    }

    func closeReader(_ id: UUID) async {
        guard let reader = readers.removeValue(forKey: id) else { return }
        try? await reader.session.closeReader(reader.nativeID)
        await release(selection: reader.selected.selection, taskID: id, root: reader.selected.storageRoot)
    }

    func connect(selection: TorrentSelection, taskID: UUID, loopbackPort: UInt16, root: URL) async throws {
        let key = Self.key(selection.infoHashes)
        await acquire(key)
        defer { unlock(key) }
        guard let transfer = transfers[key], transfer.root.standardizedFileURL == root.standardizedFileURL,
              transfer.activeFiles[taskID] == selection.fileIndex else { throw DownloadFailure.invalidOperation }
        try await transfer.session.connect(transfer.nativeID, loopbackPort: loopbackPort)
    }
    func release(selection: TorrentSelection, taskID: UUID, root: URL) async {
        let key = Self.key(selection.infoHashes)
        await acquire(key)
        defer { unlock(key) }
        guard var transfer = transfers[key], transfer.root.standardizedFileURL == root.standardizedFileURL else { return }
        transfer.activeFiles.removeValue(forKey: taskID)
        transfer.uploadLimits.removeValue(forKey: taskID)
        transfers[key] = transfer
        do {
            try await transfer.session.select(transfer.nativeID, fileIndices: Set(transfer.activeFiles.values))
            if let limit = transfer.uploadLimits.values.min() {
                try await transfer.session.setUploadLimit(min(uploadCeiling, limit))
                try await transfer.session.resume(transfer.nativeID)
            } else {
                try await transfer.session.pause(transfer.nativeID)
                try await transfer.session.saveResume(transfer.nativeID,
                    resumeFile: transfer.root.appendingPathComponent("resume.dat"),
                    metadataFile: transfer.root.appendingPathComponent("metadata.torrent"))
                try await transfer.session.remove(transfer.nativeID, deleteFiles: false)
                await transfer.session.close()
                transfers.removeValue(forKey: key)
            }
        } catch {
            try? await transfer.session.pause(transfer.nativeID)
            await transfer.session.close()
            transfers.removeValue(forKey: key)
        }
    }

    func shutdown() async {
        stopping = true
        for id in Array(readers.keys) { await closeReader(id) }
        for key in Set(transfers.keys).union(lockedKeys) {
            await acquire(key)
            if let transfer = transfers.removeValue(forKey: key) {
                try? await transfer.session.pause(transfer.nativeID)
                try? await transfer.session.saveResume(transfer.nativeID,
                    resumeFile: transfer.root.appendingPathComponent("resume.dat"),
                    metadataFile: transfer.root.appendingPathComponent("metadata.torrent"))
                await transfer.session.close()
            }
            unlock(key)
        }
        for id in Array(pending.keys) { await cancelImport(id) }
    }

    private func checkFailure(_ key: String) async throws {
        await acquire(key)
        defer { unlock(key) }
        guard var current = transfers[key] else { throw CancellationError() }
        if let failure = current.failure { throw failure }
        for event in try await current.session.pollEvents() where event.torrentID == current.nativeID && event.kind == .failure {
            current.failure = Self.classifyNativeError(TorrentSession.Failure(code: UInt32(max(0, event.errorCode))))
        }
        transfers[key] = current
        if let failure = current.failure { throw failure }
    }

    private func acquire(_ key: String) async {
        if lockedKeys.insert(key).inserted { return }
        await withCheckedContinuation { continuation in
            lockWaiters[key, default: []].append(continuation)
        }
    }

    private func unlock(_ key: String) {
        if var waiters = lockWaiters[key], !waiters.isEmpty {
            let next = waiters.removeFirst()
            lockWaiters[key] = waiters.isEmpty ? nil : waiters
            next.resume()
        } else {
            lockedKeys.remove(key)
        }
    }

    private static func matches(_ selection: TorrentSelection, metadata: TorrentSession.Metadata) -> Bool {
        selection.infoHashes == metadata.infoHashes && metadata.files.contains {
            $0.index == selection.fileIndex && $0.path == selection.path && $0.size == selection.size && !$0.isPad
        }
    }

    private static func loadTransfer(root: URL, uploadLimit: UInt32) async throws -> Transfer {
        try validateStorage(root)
        let session = try TorrentSession(configuration: .init(publicNetwork: true, uploadLimitBytesPerSecond: uploadLimit))
        do {
            let id = try await session.loadResume(resumeFile: root.appendingPathComponent("resume.dat"),
                                                  metadataFile: root.appendingPathComponent("metadata.torrent"),
                                                  directory: root.appendingPathComponent("data", isDirectory: true))
            guard let metadata = try await session.metadata(id) else { throw DownloadFailure.torrentResumeCorrupt }
            try await session.select(id, fileIndices: [])
            try await session.pause(id)
            return Transfer(session: session, nativeID: id, root: root, metadata: metadata)
        } catch {
            await session.close()
            throw mapNative(error)
        }
    }

    private static func key(_ hashes: Set<String>) -> String {
        hashes.sorted().joined(separator: "_").replacingOccurrences(of: ":", with: "-")
    }

    /// The policy root may use macOS /var aliases; owned descendants may never be symlinks.
    private static func validateStorage(_ root: URL) throws {
        guard root.isFileURL, root.deletingLastPathComponent().lastPathComponent == "TorrentPrivate" else {
            throw DownloadFailure.invalidSelection
        }
        var ancestor = root.standardizedFileURL.deletingLastPathComponent()
        while ancestor.path != "/" {
            var info = stat()
            if lstat(ancestor.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw DownloadFailure.invalidSelection }
            } else if errno != ENOENT {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            ancestor.deleteLastPathComponent()
        }
        for url in [root.deletingLastPathComponent(), root, root.appendingPathComponent("data"),
                    root.appendingPathComponent("metadata.torrent"), root.appendingPathComponent("resume.dat")] {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard (info.st_mode & S_IFMT) != S_IFLNK else { throw DownloadFailure.invalidSelection }
            } else if errno != ENOENT {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
    }

    private static func safeFile(root: URL, relativePath: String) throws -> URL {
        try validateStorage(root.deletingLastPathComponent())
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\\") else { throw DownloadFailure.invalidSelection }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw DownloadFailure.invalidSelection }
        var url = root.standardizedFileURL
        for part in parts {
            url.appendPathComponent(String(part))
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { throw DownloadFailure.invalidSelection }
        }
        let rootPath = root.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(rootPath) else { throw DownloadFailure.invalidSelection }
        return url
    }

    static func classifyNativeError(_ error: any Error) -> DownloadFailure {
        guard let failure = error as? TorrentSession.Failure else { return DownloadFailure.classify(error) }
        switch failure.code {
        case UInt32(TB_ERROR_DISK_FULL.rawValue): return .diskFull
        case UInt32(TB_ERROR_IO.rawValue): return .directoryNotWritable
        case UInt32(TB_ERROR_UNSAFE_PATH.rawValue), UInt32(TB_ERROR_INVALID_ARGUMENT.rawValue): return .invalidSelection
        case UInt32(TB_ERROR_METADATA_PENDING.rawValue), UInt32(TB_ERROR_TORRENT.rawValue): return .torrentMetadataUnavailable
        case UInt32(TB_ERROR_CORRUPT_RESUME.rawValue): return .torrentResumeCorrupt
        case UInt32(TB_ERROR_TIMEOUT.rawValue): return .torrentStorageTimeout
        default: return .network
        }
    }
    private static func mapNative(_ error: any Error) -> Error {
        if error is CancellationError { return error }
        return classifyNativeError(error)
    }
}
