import Foundation
import TorrentBridge

/// Serial owner for one persistent libtorrent session. DownloadService owns its lifetime.
actor TorrentSession {
    struct Failure: Error, Equatable {
        let code: UInt32
        static let closed = Failure(code: UInt32.max)
    }

    struct Configuration: Sendable {
        let publicNetwork: Bool
        let uploadLimitBytesPerSecond: UInt32
    }

    struct File: Sendable, Equatable {
        let index: Int
        let path: String
        let size: UInt64
        let isPad: Bool
    }

    struct Metadata: Sendable, Equatable {
        let infoHashes: Set<String>
        let isPrivate: Bool
        let files: [File]
        let totalBytes: UInt64
    }

    struct Status: Sendable {
        let totalBytes: UInt64
        let verifiedBytes: UInt64
        let peers: UInt32
        let finished: Bool
        let hasMetadata: Bool
        let isPrivate: Bool
    }

    struct Event: Sendable {
        enum Kind: Sendable { case finished, failure, stateChanged, peerConnected, metadataReceived, resumeSaved }
        let kind: Kind
        let torrentID: UInt32
        let errorCode: Int32
        let verifiedBytes: UInt64
        let totalBytes: UInt64
    }

    private final class Owner: @unchecked Sendable {
        private let condition = NSCondition()
        private var handle: OpaquePointer?
        private var closing = false
        private var activeReads = 0

        init(_ handle: OpaquePointer) { self.handle = handle }

        func currentHandle() throws -> OpaquePointer {
            condition.lock()
            defer { condition.unlock() }
            guard !closing, let handle else { throw Failure.closed }
            return handle
        }

        func read(readerID: UInt64, requestID: UInt64, offset: UInt64, length: Int, timeoutMilliseconds: UInt32) throws -> Data {
            condition.lock()
            guard !closing, let handle else { condition.unlock(); throw Failure.closed }
            activeReads += 1
            condition.unlock()
            defer {
                condition.lock()
                activeReads -= 1
                condition.broadcast()
                condition.unlock()
            }

            var data = Data(count: length)
            var count: UInt32 = 0
            var error = tb_error()
            let code = data.withUnsafeMutableBytes { bytes in
                tb_reader_read(handle, readerID, requestID, offset, UInt32(length), timeoutMilliseconds,
                               bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), UInt32(bytes.count), &count, &error)
            }
            guard code == TB_OK else { throw Failure(code: code.rawValue) }
            data.removeSubrange(Int(count)..<data.count)
            return data
        }

        func cancelRead(_ readerID: UInt64, requestID: UInt64) {
            condition.lock()
            guard let handle, !closing else { condition.unlock(); return }
            activeReads += 1
            condition.unlock()
            var error = tb_error()
            _ = tb_reader_cancel_read(handle, readerID, requestID, &error)
            condition.lock()
            activeReads -= 1
            condition.broadcast()
            condition.unlock()
        }

        func close() {
            condition.lock()
            if closing {
                while handle != nil { condition.wait() }
                condition.unlock()
                return
            }
            guard let handle else { condition.unlock(); return }
            closing = true
            condition.unlock()
            tb_session_cancel_readers(handle)
            condition.lock()
            while activeReads != 0 { condition.wait() }
            condition.unlock()
            tb_session_close(handle)
            condition.lock()
            self.handle = nil
            condition.broadcast()
            condition.unlock()
        }

        deinit { close() }
    }

    private let owner: Owner
    private var nextReadRequestID: UInt64 = 1
    private var eventBuffer = [tb_event](repeating: tb_event(), count: 64)

    nonisolated static var coreVersion: String {
        var major: UInt32 = 0, minor: UInt32 = 0, patch: UInt32 = 0
        tb_version(&major, &minor, &patch)
        return "\(major).\(minor).\(patch)"
    }

    init(configuration: Configuration) throws {
        var handle: OpaquePointer?
        var error = tb_error()
        let code = tb_session_create(&handle, configuration.publicNetwork ? 1 : 0,
                                     configuration.uploadLimitBytesPerSecond, &error)
        guard code == TB_OK, let handle else { throw Failure(code: code.rawValue) }
        owner = Owner(handle)
    }

    private func handle() throws -> OpaquePointer {
        try owner.currentHandle()
    }

    private func check(_ code: tb_error_code) throws {
        guard code == TB_OK else { throw Failure(code: code.rawValue) }
    }

    func add(torrent: URL, directory: URL) throws -> UInt32 {
        guard torrent.isFileURL, directory.isFileURL else { throw Failure(code: TB_ERROR_INVALID_ARGUMENT.rawValue) }
        var id: UInt32 = 0
        var error = tb_error()
        try check(tb_add_torrent(try handle(), torrent.path, directory.path, &id, &error))
        return id
    }

    func add(magnet: String, directory: URL) throws -> UInt32 {
        guard directory.isFileURL, magnet.hasPrefix("magnet:?") else { throw Failure(code: TB_ERROR_INVALID_ARGUMENT.rawValue) }
        var id: UInt32 = 0
        var error = tb_error()
        try check(tb_add_magnet(try handle(), magnet, directory.path, &id, &error))
        return id
    }

    static func magnetIdentity(_ magnet: String) throws -> Set<String> {
        var info = tb_metadata_info()
        var error = tb_error()
        let code = tb_magnet_identity(magnet, &info, &error)
        guard code == TB_OK else { throw Failure(code: code.rawValue) }
        return hashes(from: &info)
    }

    private static func hashes(from info: inout tb_metadata_info) -> Set<String> {
        var result = Set<String>()
        if info.has_v1 != 0 {
            result.insert(withUnsafePointer(to: &info.v1_hash) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 45) { String(cString: $0) }
            })
        }
        if info.has_v2 != 0 {
            result.insert(withUnsafePointer(to: &info.v2_hash) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 69) { String(cString: $0) }
            })
        }
        return result
    }

    func metadata(_ id: UInt32) throws -> Metadata? {
        let session = try handle()
        var info = tb_metadata_info()
        var error = tb_error()
        let first = tb_get_metadata(session, id, &info, nil, 0, &error)
        if first == TB_ERROR_METADATA_PENDING { return nil }
        try check(first)
        var files = [tb_file_info](repeating: tb_file_info(), count: Int(info.file_count))
        let code = files.withUnsafeMutableBufferPointer {
            tb_get_metadata(session, id, &info, $0.baseAddress, UInt32($0.count), &error)
        }
        try check(code)
        let hashes = Self.hashes(from: &info)
        let listed = files.enumerated().map { index, file in
            let path = withUnsafePointer(to: file.path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            return File(index: index, path: path, size: file.size, isPad: file.pad_file != 0)
        }
        return Metadata(infoHashes: hashes, isPrivate: info.is_private != 0, files: listed,
                        totalBytes: listed.reduce(UInt64(0)) { $0 + ($1.isPad ? 0 : $1.size) })
    }

    /// Caller supplies the union of all live consumers' file selections.
    func select(_ id: UInt32, fileIndices: Set<Int>) throws {
        guard let metadata = try metadata(id), fileIndices.allSatisfy({ metadata.files.indices.contains($0) && !metadata.files[$0].isPad }) else {
            throw Failure(code: TB_ERROR_INVALID_ARGUMENT.rawValue)
        }
        var priorities = [UInt8](repeating: 0, count: metadata.files.count)
        for index in fileIndices { priorities[index] = 4 }
        var error = tb_error()
        try priorities.withUnsafeBufferPointer {
            try check(tb_set_file_priorities(try handle(), id, $0.baseAddress, UInt32($0.count), &error))
        }
    }

    func fileProgress(_ id: UInt32) throws -> [UInt64] {
        guard let metadata = try metadata(id) else { throw Failure(code: TB_ERROR_METADATA_PENDING.rawValue) }
        var count = UInt32(metadata.files.count)
        var error = tb_error()
        var progress = [UInt64](repeating: 0, count: Int(count))
        try progress.withUnsafeMutableBufferPointer {
            try check(tb_get_file_progress(try handle(), id, $0.baseAddress, UInt32($0.count), &count, &error))
        }
        return progress
    }

    func setUploadLimit(_ bytesPerSecond: UInt32) throws {
        var error = tb_error()
        try check(tb_session_set_upload_limit(try handle(), bytesPerSecond, &error))
    }

    func connect(_ id: UInt32, loopbackPort: UInt16) throws {
        var error = tb_error()
        try check(tb_connect_loopback_peer(try handle(), id, loopbackPort, &error))
    }

    func listenPort() throws -> UInt16 {
        var port: UInt16 = 0
        var error = tb_error()
        try check(tb_listen_port(try handle(), &port, &error))
        return port
    }

    func status(_ id: UInt32) throws -> Status {
        var status = tb_torrent_status()
        var error = tb_error()
        try check(tb_get_status(try handle(), id, &status, &error))
        return Status(totalBytes: status.total_bytes, verifiedBytes: status.verified_bytes,
                      peers: status.peers_connected, finished: status.is_finished != 0,
                      hasMetadata: status.has_metadata != 0, isPrivate: status.is_private != 0)
    }

    func pause(_ id: UInt32) throws {
        var error = tb_error()
        try check(tb_pause_torrent(try handle(), id, &error))
    }

    func resume(_ id: UInt32) throws {
        var error = tb_error()
        try check(tb_resume_torrent(try handle(), id, &error))
    }

    func remove(_ id: UInt32, deleteFiles: Bool) throws {
        var error = tb_error()
        try check(tb_remove_torrent(try handle(), id, deleteFiles ? 1 : 0, &error))
    }

    func saveResume(_ id: UInt32, resumeFile: URL, metadataFile: URL) throws {
        guard resumeFile.isFileURL, metadataFile.isFileURL else { throw Failure(code: TB_ERROR_INVALID_ARGUMENT.rawValue) }
        var error = tb_error()
        try check(tb_save_resume(try handle(), id, resumeFile.path, metadataFile.path, &error))
    }

    func loadResume(resumeFile: URL, metadataFile: URL, directory: URL) throws -> UInt32 {
        guard resumeFile.isFileURL, metadataFile.isFileURL, directory.isFileURL else {
            throw Failure(code: TB_ERROR_INVALID_ARGUMENT.rawValue)
        }
        var id: UInt32 = 0
        var error = tb_error()
        try check(tb_load_resume(try handle(), resumeFile.path, metadataFile.path, directory.path, &id, &error))
        return id
    }

    /// Single poll consumer; native alert memory never escapes this call.
    func pollEvents() throws -> [Event] {
        let session = try handle()
        var count: UInt32 = 0
        var error = tb_error()
        let code = eventBuffer.withUnsafeMutableBufferPointer {
            tb_poll_events(session, $0.baseAddress, UInt32($0.count), &count, &error)
        }
        try check(code)
        return eventBuffer.prefix(Int(count)).map { event in
            let kind: Event.Kind
            switch event.type {
            case TB_EVENT_TORRENT_FINISHED: kind = .finished
            case TB_EVENT_TORRENT_ERROR: kind = .failure
            case TB_EVENT_PEER_CONNECTED: kind = .peerConnected
            case TB_EVENT_METADATA_RECEIVED: kind = .metadataReceived
            case TB_EVENT_RESUME_SAVED: kind = .resumeSaved
            default: kind = .stateChanged
            }
            return Event(kind: kind, torrentID: event.torrent_id, errorCode: event.error_code,
                         verifiedBytes: event.verified_bytes, totalBytes: event.total_bytes)
        }
    }
    func openReader(_ torrentID: UInt32, fileIndex: Int) throws -> UInt64 {
        guard fileIndex >= 0, fileIndex <= Int(UInt32.max) else { throw Failure(code: TB_ERROR_INVALID_ARGUMENT.rawValue) }
        var readerID: UInt64 = 0
        var error = tb_error()
        try check(tb_reader_open(try handle(), torrentID, UInt32(fileIndex), &readerID, &error))
        return readerID
    }

    func readReader(_ readerID: UInt64, offset: UInt64, length: Int, timeout: Duration = .seconds(30)) async throws -> Data {
        guard length > 0 else { throw Failure(code: TB_ERROR_INVALID_ARGUMENT.rawValue) }
        guard timeout >= .zero else { throw Failure(code: TB_ERROR_INVALID_ARGUMENT.rawValue) }
        let operationOwner = owner
        let requestID = nextReadRequestID
        nextReadRequestID &+= 1
        if nextReadRequestID == 0 { nextReadRequestID = 1 }
        let boundedLength = min(length, 256 * 1024)
        let parts = timeout.components
        let seconds = UInt64(max(0, parts.seconds))
        let subsecond = UInt64(max(0, parts.attoseconds / 1_000_000_000_000_000))
        let timeoutMilliseconds = seconds > UInt64(UInt32.max) / 1_000
            ? UInt32.max : UInt32(min(UInt64(UInt32.max), seconds * 1_000 + subsecond))
        do {
            let data = try await withTaskCancellationHandler {
                try await Task.detached(priority: .utility) {
                    try operationOwner.read(readerID: readerID, requestID: requestID, offset: offset,
                                            length: boundedLength, timeoutMilliseconds: timeoutMilliseconds)
                }.value
            } onCancel: {
                operationOwner.cancelRead(readerID, requestID: requestID)
            }
            if Task.isCancelled { throw CancellationError() }
            return data
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func closeReader(_ readerID: UInt64) throws {
        var error = tb_error()
        try check(tb_reader_close(try handle(), readerID, &error))
    }



    /// Idempotent; native abort joins session and disk workers before returning.
    func close() { owner.close() }
}
