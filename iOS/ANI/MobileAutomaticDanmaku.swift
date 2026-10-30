import Foundation

/// All fields are durable identities, not titles, positions in a catalogue or media URLs.
struct MobileDanmakuTarget: Equatable, Sendable {
    let episodeID: UUID
    let sourceID: String
    let pageURL: String
    let configurationRevision: String
    let aid: Int64
    let cid: Int64
}

enum MobileAutomaticDanmakuFailure: Error, Equatable {
    case network, authenticationRequired, identityMismatch, invalidResponse, configurationChanged

    var message: String {
        switch self {
        case .network: return String(localized: "Danmaku could not be downloaded. Check your connection and retry.")
        case .authenticationRequired: return String(localized: "The danmaku provider requires login or verification. Guest access only; playback can continue.")
        case .identityMismatch: return String(localized: "The provider episode identity did not match. No danmaku was attached.")
        case .invalidResponse: return String(localized: "The provider returned an unsupported danmaku response.")
        case .configurationChanged: return String(localized: "The source configuration changed or was disabled. Reopen the episode to fetch danmaku.")
        }
    }
}

enum MobileAutomaticDanmakuStatus: Equatable {
    case idle, off, unsupported, loading, loaded, empty, manual, cancelled
    case failed(MobileAutomaticDanmakuFailure)

    var message: String {
        switch self {
        case .idle: return String(localized: "Automatic danmaku has not started.")
        case .off: return String(localized: "Automatic danmaku is off.")
        case .unsupported: return String(localized: "This source episode has no verified supported danmaku binding.")
        case .loading: return String(localized: "Verifying episode identity and downloading danmaku…")
        case .loaded: return String(localized: "Danmaku attached from the verified Bilibili episode.")
        case .empty: return String(localized: "The verified episode currently has no supported comments.")
        case .manual: return String(localized: "Using your imported file. Automatic downloads will not replace it.")
        case .cancelled: return String(localized: "Automatic danmaku download cancelled.")
        case .failed(let failure): return failure.message
        }
    }

    var canRetry: Bool {
        switch self {
        case .failed, .cancelled, .empty: return true
        default: return false
        }
    }
}

/// Same public XML contract as desktop VideoDecoder.downloadDMFile. This is NOT
/// Bilibili playback support: only an explicit configured episode binding is used.
/// No account cookies, tokens, signatures, history endpoints or access workarounds.
struct MobileBilibiliDanmakuProvider: Sendable {
    typealias Fetch = @Sendable (URL) async throws -> Data
    private let fetch: Fetch

    init(fetch: Fetch? = nil) {
        self.fetch = fetch ?? { try await MobileDanmakuTransport.fetch($0) }
    }

    func comments(for target: MobileDanmakuTarget) async throws -> [MobileDanmakuEntry] {
        try Task.checkCancellation()
        guard target.aid > 0, target.cid > 0 else { throw MobileAutomaticDanmakuFailure.identityMismatch }
        let metadataURL = URL(string: "https://api.bilibili.com/x/web-interface/view?aid=\(target.aid)")!
        let metadata = try await fetch(metadataURL)
        try Task.checkCancellation()
        try Self.verify(metadata: metadata, target: target)
        let url = URL(string: "https://comment.bilibili.com/\(target.cid).xml")!
        let data = try await fetch(url)
        try Task.checkCancellation()
        return try MobileDanmakuParser.parseBilibili(data: data, expectedCID: target.cid)
    }

    static func verify(metadata: Data, target: MobileDanmakuTarget) throws {
        struct Response: Decodable {
            struct Video: Decodable {
                struct Page: Decodable { let cid: Int64 }
                let aid: Int64
                let pages: [Page]
            }
            let code: Int
            let data: Video?
        }
        guard metadata.count <= MobileDanmakuParser.maximumBytes,
              let response = try? JSONDecoder().decode(Response.self, from: metadata) else {
            throw MobileAutomaticDanmakuFailure.invalidResponse
        }
        if [-101, -111, -403, -412, -352].contains(response.code) {
            throw MobileAutomaticDanmakuFailure.authenticationRequired
        }
        guard response.code == 0, let video = response.data else {
            throw MobileAutomaticDanmakuFailure.invalidResponse
        }
        guard video.aid == target.aid, video.pages.filter({ $0.cid == target.cid }).count == 1 else {
            throw MobileAutomaticDanmakuFailure.identityMismatch
        }
    }
}

private final class MobileDanmakuTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // No redirects: the only supported contracts have fixed public endpoints.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        if url.host == "api.bilibili.com", url.path == "/x/web-interface/view" {
            let query = components.queryItems ?? []
            return query.count == 1 && query[0].name == "aid" && (Int64(query[0].value ?? "").map { $0 > 0 } ?? false)
        }
        guard url.host == "comment.bilibili.com", components.query == nil, url.pathExtension == "xml" else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        return url.path == "/" + name + ".xml" && (Int64(name).map { $0 > 0 } ?? false)
    }

    static func fetch(_ url: URL) async throws -> Data {
        guard allows(url) else { throw MobileAutomaticDanmakuFailure.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: MobileDanmakuTransport(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("IINA-ANI-iOS/0.1", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, response.url == url else {
                throw MobileAutomaticDanmakuFailure.invalidResponse
            }
            if [401, 403, 412].contains(http.statusCode) { throw MobileAutomaticDanmakuFailure.authenticationRequired }
            if [408, 429].contains(http.statusCode) || (500..<600).contains(http.statusCode) { throw MobileAutomaticDanmakuFailure.network }
            guard (200..<300).contains(http.statusCode), response.expectedContentLength <= Int64(MobileDanmakuParser.maximumBytes) else {
                throw MobileAutomaticDanmakuFailure.invalidResponse
            }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < MobileDanmakuParser.maximumBytes else { throw MobileAutomaticDanmakuFailure.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if [.userAuthenticationRequired, .userCancelledAuthentication].contains(error.code) {
                throw MobileAutomaticDanmakuFailure.authenticationRequired
            }
            throw MobileAutomaticDanmakuFailure.network
        }
    }
}
