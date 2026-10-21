import Foundation
import NIO
import NIOHTTP1

/// Streams a single selected torrent file. No request-controlled filesystem path is accepted.
enum TorrentHTTPHandler {
    private static let chunkSize = 256 * 1_024

    enum RequestedRange: Equatable {
        case absent
        case range(UInt64, UInt64)
        case unsatisfiable
    }

    static func matchesPath(_ uri: String) -> Bool {
        guard let rawPath = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first else { return false }
        let path = String(rawPath)
        if path.hasPrefix("/torrent") { return true }
        guard let decodedPath = path.removingPercentEncoding else { return false }
        return decodedPath == "/torrent" || decodedPath.hasPrefix("/torrent/")
    }

    static func handle(
        uri: String,
        method: HTTPMethod,
        rangeHeader: String?,
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>,
        channel: Channel,
        streamingService: TorrentStreamingService
    ) async throws {
        guard method == .GET || method == .HEAD,
              let token = token(from: uri) else {
            try await respond(status: .notFound, headers: [:], outbound: outbound)
            return
        }

        let reader: TorrentStreamingReader
        do {
            reader = try await streamingService.beginRequest(token: token) {
                channel.close(mode: .all, promise: nil)
            }
        } catch {
            try await respond(status: .notFound, headers: [:], outbound: outbound)
            return
        }
        channel.closeFuture.whenComplete { _ in
            Task { await streamingService.endRequest(token: token, requestID: reader.id) }
        }

        do {
            try await respondMedia(reader, method: method, rangeHeader: rangeHeader, outbound: outbound)
        } catch {
            await streamingService.endRequest(token: token, requestID: reader.id)
            throw error
        }
        await streamingService.endRequest(token: token, requestID: reader.id)
    }

    static func parseRange(_ value: String?, size: UInt64) -> RequestedRange {
        guard let value else { return .absent }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return .absent }
        let spec = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
        // Multipart/byteranges is intentionally ignored; never emit a malformed single-part 206.
        guard !spec.contains(",") else { return .absent }
        let halves = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard halves.count == 2 else { return .absent }
        let first = halves[0].trimmingCharacters(in: .whitespaces)
        let second = halves[1].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let suffix = decimal(second) else { return .absent }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            return .range(size - min(suffix, size), size - 1)
        }
        guard let start = decimal(first) else { return .absent }
        guard size > 0, start < size else { return .unsatisfiable }
        let end: UInt64
        if second.isEmpty {
            end = size - 1
        } else {
            guard let requestedEnd = decimal(second) else { return .absent }
            guard requestedEnd >= start else { return .unsatisfiable }
            end = min(requestedEnd, size - 1)
        }
        return .range(start, end)
    }

    private static func respondMedia(
        _ reader: TorrentStreamingReader,
        method: HTTPMethod,
        rangeHeader: String?,
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        let size = reader.size
        let contentType = mediaType(for: reader.path)
        let requested = method == .GET ? parseRange(rangeHeader, size: size) : .absent
        switch requested {
        case .unsatisfiable:
            try await respond(status: .rangeNotSatisfiable,
                              headers: ["Content-Range": "bytes */\(size)", "Accept-Ranges": "bytes", "Content-Length": "0"],
                              outbound: outbound)
        case .absent:
            let headers: HTTPHeaders = ["Content-Type": contentType, "Accept-Ranges": "bytes",
                                        "Content-Length": String(size)]
            if method == .HEAD {
                try await respond(status: .ok, headers: headers, outbound: outbound)
                return
            }
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)))
            try await stream(reader, offset: 0, count: size, outbound: outbound)
            try await outbound.write(.end(nil))
        case .range(let start, let end):
            let length = end - start + 1
            let headers: HTTPHeaders = ["Content-Type": contentType, "Accept-Ranges": "bytes",
                                        "Content-Range": "bytes \(start)-\(end)/\(size)",
                                        "Content-Length": String(length)]
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .partialContent, headers: headers)))
            try await stream(reader, offset: start, count: length, outbound: outbound)
            try await outbound.write(.end(nil))
        }
    }

    /// Parses decimal byte positions with saturation, so oversized valid values retain RFC range semantics.
    private static func decimal(_ string: String) -> UInt64? {
        guard !string.isEmpty else { return nil }
        var value: UInt64 = 0
        for byte in string.utf8 {
            guard (48...57).contains(byte) else { return nil }
            let digit = UInt64(byte - 48)
            if value > (UInt64.max - digit) / 10 { return .max }
            value = value * 10 + digit
        }
        return value
    }

    private static func token(from uri: String) -> String? {
        let path = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces[0].isEmpty, pieces[1] == "torrent", pieces[3] == "media" else { return nil }
        let token = String(pieces[2])
        guard token.utf8.count == 43, token.utf8.allSatisfy({
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
        }) else { return nil }
        return token
    }

    private static func mediaType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "flv": return "video/x-flv"
        default: return "video/mp4"
        }
    }

    private static func stream(
        _ reader: TorrentStreamingReader,
        offset: UInt64,
        count: UInt64,
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        var position = offset
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let length = Int(min(UInt64(chunkSize), remaining))
            let bytes = try await reader.pool.readReader(reader.readerID, offset: position, length: length)
            guard !bytes.isEmpty, bytes.count <= length else { throw TorrentStreamingError.shortRead }
            var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            try await outbound.write(.body(buffer))
            let sent = UInt64(bytes.count)
            position += sent
            remaining -= sent
        }
    }

    private static func respond(
        status: HTTPResponseStatus,
        headers suppliedHeaders: HTTPHeaders,
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        var headers = suppliedHeaders
        if headers.first(name: "Content-Length") == nil { headers.add(name: "Content-Length", value: "0") }
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        try await outbound.write(.end(nil))
    }
}
