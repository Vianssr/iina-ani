import CryptoKit
import Foundation

/// Content, not a filename or provider path, is the durable local episode identity.
struct MobileLocalMediaIdentity: Codable, Hashable, Sendable {
    let sha256: String
    let size: UInt64

    var id: String { "local:sha256:\(sha256):\(size)" }
    var isValid: Bool {
        sha256.utf8.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func read(from url: URL) throws -> Self {
        guard url.isFileURL else { throw MobileLocalMediaError.unavailable }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let expectedSize = values.fileSize, expectedSize >= 0 else {
            throw MobileLocalMediaError.unavailable
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            size += UInt64(chunk.count)
        }
        guard size == UInt64(expectedSize),
              try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == expectedSize else {
            throw MobileLocalMediaError.unavailable
        }
        return Self(sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), size: size)
    }
}

struct MobileLocalMediaReference: Codable, Hashable, Sendable {
    let identity: MobileLocalMediaIdentity
    let bookmark: Data

    var isValid: Bool { identity.isValid && !bookmark.isEmpty }
}

enum MobileLocalMediaError: Error {
    case unavailable, differentContent, staleHistory
}

/// Owns exactly one successful startAccessing call, including when work is cancelled.
final class MobileLocalMediaAccess: @unchecked Sendable {
    let url: URL
    private let scoped: Bool

    init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

struct MobileAuthorizedLocalMedia: Sendable {
    let reference: MobileLocalMediaReference
    let access: MobileLocalMediaAccess
}

enum MobileLocalMedia {
    /// Hashing streams on a worker. The retained authorization is transferred to the player.
    static func authorize(_ url: URL, matching expected: MobileLocalMediaIdentity? = nil,
                          retaining retainedAccess: MobileLocalMediaAccess? = nil) async throws -> MobileAuthorizedLocalMedia {
        let task = Task.detached(priority: .userInitiated) {
            let access = retainedAccess ?? MobileLocalMediaAccess(url: url)
            let identity = try MobileLocalMediaIdentity.read(from: url)
            if let expected, identity != expected { throw MobileLocalMediaError.differentContent }
            try Task.checkCancellation()
            #if os(macOS)
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            #else
            // iOS document-provider bookmarks retain the granted security scope without macOS-only flags.
            let bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            #endif
            return MobileAuthorizedLocalMedia(reference: MobileLocalMediaReference(identity: identity, bookmark: bookmark), access: access)
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    static func resolve(_ reference: MobileLocalMediaReference) async throws -> MobileAuthorizedLocalMedia {
        guard reference.isValid else { throw MobileLocalMediaError.unavailable }
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: reference.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: reference.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        // Always verify bytes. A provider can reuse a path after a deletion or revocation.
        return try await authorize(url, matching: reference.identity)
    }
}
