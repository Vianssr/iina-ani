import Foundation

/// TorrServer owns the BitTorrent transfer. The mobile player consumes only its HTTPS media stream.
enum MobileBTError: Error, Equatable {
    case invalidServer, invalidTorrent, unavailable, authenticationRequired
    case invalidResponse, metadataTimeout, noVideo, invalidSelection

    var message: String {
        switch self {
        case .invalidServer: "Enter an HTTPS TorrServer address without credentials, query parameters or a fragment."
        case .invalidTorrent: "Enter a valid magnet link or an HTTPS .torrent URL."
        case .authenticationRequired: "This server requires authentication. Use an HTTPS endpoint that your device can access without a login."
        case .invalidResponse: "The server returned an unsupported torrent response. Check that it is a compatible TorrServer."
        case .metadataTimeout: "Torrent metadata is not ready. Check the server and available peers, then try again."
        case .noVideo: "No supported video files were found in this torrent."
        case .invalidSelection: "The selected file is no longer available. Load the torrent again."
        case .unavailable: "Unable to reach TorrServer. Check its HTTPS address and connection, then try again."
        }
    }
}

enum MobileBTAddress {
    static func server(_ input: String) -> URL? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 2048, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !raw.contains("\\"), !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    static func torrent(_ input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.count <= 16 * 1024,
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var parts = URLComponents(string: raw), parts.user == nil, parts.password == nil,
              parts.fragment == nil else { return nil }
        if parts.scheme?.lowercased() == "magnet" {
            guard parts.host == nil, parts.path.isEmpty,
                  parts.queryItems?.contains(where: { $0.name == "xt" && validTopic($0.value ?? "") }) == true else { return nil }
            parts.scheme = "magnet"
            return parts.string
        }
        guard parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              let url = parts.url, url.pathExtension.lowercased() == "torrent" else { return nil }
        parts.scheme = "https"
        return parts.string
    }

    static func validHash(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private static func validTopic(_ value: String) -> Bool {
        let value = value.lowercased()
        if value.hasPrefix("urn:btih:") {
            let hash = String(value.dropFirst(9))
            return (hash.count == 40 && validHash(hash)) ||
                (hash.count == 32 && hash.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
        }
        if value.hasPrefix("urn:btmh:1220") {
            let hash = String(value.dropFirst(13))
            return hash.count == 64 && validHash(hash)
        }
        return false
    }
}

struct MobileBTFile: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    let path: String
    let length: Int64?
    var title: String { (path as NSString).lastPathComponent }
    var isVideo: Bool {
        Self.videoExtensions.contains((path as NSString).pathExtension.lowercased())
    }
    private static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts", "flv", "wmv", "mpg", "mpeg", "ogv"]
}

struct MobileBTTorrent: Decodable, Sendable {
    let hash: String
    let title: String?
    let name: String?
    let file_stats: [MobileBTFile]?

    var videoFiles: [MobileBTFile] { (file_stats ?? []).filter(\.isVideo) }

    static func decode(_ data: Data) throws -> MobileBTTorrent {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else { throw MobileBTError.invalidResponse }
        let torrent: MobileBTTorrent
        do { torrent = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw MobileBTError.invalidResponse }
        let files = torrent.file_stats ?? []
        guard MobileBTAddress.validHash(torrent.hash), files.count <= 10_000,
              (torrent.title?.count ?? 0) <= 4096, (torrent.name?.count ?? 0) <= 4096,
              Set(files.map(\.id)).count == files.count,
              files.allSatisfy({ $0.id > 0 && !$0.path.isEmpty && $0.path.utf8.count <= 4096 && ($0.length ?? 0) >= 0 }) else {
            throw MobileBTError.invalidResponse
        }
        return torrent
    }
}

struct MobileBTClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> Data
    private let transport: Transport
    private let pause: @Sendable () async throws -> Void
    private let attempts: Int

    init(transport: @escaping Transport = { try await MobileBTTransport.fetch($0) },
         pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
         attempts: Int = 45) {
        self.transport = transport
        self.pause = pause
        self.attempts = max(0, min(attempts, 60))
    }

    func load(server: URL, input: String) async throws -> MobileBTTorrent {
        guard MobileBTAddress.server(server.absoluteString) != nil else { throw MobileBTError.invalidServer }
        guard let link = MobileBTAddress.torrent(input) else { throw MobileBTError.invalidTorrent }
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        var torrent = try await request(server: server, body: ["action": "add", "link": link, "save_to_db": false])
        let hash = torrent.hash
        for _ in 0..<attempts {
            if !(torrent.file_stats ?? []).isEmpty { break }
            guard ContinuousClock.now < deadline else { throw MobileBTError.metadataTimeout }
            try await pause()
            try Task.checkCancellation()
            torrent = try await request(server: server, body: ["action": "get", "hash": hash])
            guard torrent.hash == hash else { throw MobileBTError.invalidResponse }
        }
        try Task.checkCancellation()
        guard !(torrent.file_stats ?? []).isEmpty else { throw MobileBTError.metadataTimeout }
        guard !torrent.videoFiles.isEmpty else { throw MobileBTError.noVideo }
        return torrent
    }

    static func stream(server: URL, torrent: MobileBTTorrent, file: MobileBTFile) throws -> URL {
        guard MobileBTAddress.server(server.absoluteString) != nil,
              MobileBTAddress.validHash(torrent.hash), torrent.videoFiles.contains(file) else { throw MobileBTError.invalidSelection }
        var parts = URLComponents(url: server.appendingPathComponent("stream"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "link", value: torrent.hash),
                            URLQueryItem(name: "index", value: String(file.id)), URLQueryItem(name: "play", value: "")]
        guard let url = parts.url else { throw MobileBTError.invalidSelection }
        return url
    }

    private func request(server: URL, body: [String: Any]) async throws -> MobileBTTorrent {
        var request = URLRequest(url: server.appendingPathComponent("torrents"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await transport(request)
        try Task.checkCancellation()
        return try MobileBTTorrent.decode(data)
    }
}

/// Never redirect a request containing a magnet, URL or server-side hash to another endpoint.
private final class MobileBTTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func fetch(_ request: URLRequest) async throws -> Data {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else {
            throw MobileBTError.invalidServer
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: MobileBTTransport(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileBTError.unavailable }
        if http.statusCode == 401 || http.statusCode == 403 { throw MobileBTError.authenticationRequired }
        guard http.statusCode == 200, response.url == url,
              response.expectedContentLength <= 2 * 1024 * 1024 else { throw MobileBTError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1024 * 1024 else { throw MobileBTError.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}
