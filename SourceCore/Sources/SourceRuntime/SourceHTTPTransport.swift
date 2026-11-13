import Foundation

public struct SourceHTTPResponse: Sendable {
    public let data: Data
    public let url: URL
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, url: URL, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
    }
}

public enum SourceHTTPTransportError: Error, Sendable {
    case invalidURL
    case invalidResponse
    case oversizedResponse
}

/// The desktop source request policy without any application account state.
public struct SourceHTTPTransport: Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> SourceHTTPResponse
    public static let maximumResponseBytes = 16_000_000
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    /// Cookies are opt-in, scoped to explicitly approved credential hosts. The
    /// immutable Foundation cookie values are snapshotted; no cookie store is read.
    public struct CookiePolicy: @unchecked Sendable {
        public let credentialHosts: Set<String>
        fileprivate let cookies: [HTTPCookie]

        public init(credentialHosts: Set<String>, cookies: [HTTPCookie]) {
            self.credentialHosts = Set(credentialHosts.map { $0.lowercased() })
            self.cookies = cookies.filter { $0.isSecure }
        }

        /// Snapshot a caller-supplied public challenge header, never a shared
        /// account/session cookie jar. Redirect replay stays host allowlisted.
        public init(credentialHosts: Set<String>, request: URLRequest) {
            let hosts = Set(credentialHosts.map { $0.lowercased() })
            guard let url = request.url, SourceHTTPTransport.permits(url, allowedHosts: hosts),
                  let host = url.host?.lowercased(),
                  let header = request.value(forHTTPHeaderField: "Cookie") else {
                self.init(credentialHosts: hosts, cookies: [])
                return
            }
            let cookies = header.split(separator: ";").compactMap { part -> HTTPCookie? in
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { return nil }
                let name = pair[0].trimmingCharacters(in: .whitespaces)
                let value = pair[1].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                return HTTPCookie(properties: [.domain: host, .path: "/", .name: name, .value: value, .secure: "TRUE"])
            }
            self.init(credentialHosts: hosts, cookies: cookies)
        }
    }

    private let cookiePolicy: CookiePolicy?

    public init(cookiePolicy: CookiePolicy? = nil) {
        self.cookiePolicy = cookiePolicy
    }

    public static func fetch(_ request: URLRequest, allowedHosts: Set<String>) async throws -> SourceHTTPResponse {
        try await SourceHTTPTransport().response(for: request, allowedHosts: allowedHosts)
    }

    /// Set successPrefixBytes only for media probes: success reads that prefix,
    /// other statuses read at most maximumResponseBytes. Complete page requests
    /// reject oversized bodies rather than passing truncated data to a parser.
    public func response(for request: URLRequest, allowedHosts: Set<String>,
                         maximumResponseBytes: Int = SourceHTTPTransport.maximumResponseBytes,
                         successPrefixBytes: Int? = nil) async throws -> SourceHTTPResponse {
        try Task.checkCancellation()
        guard let url = request.url, Self.permits(url, allowedHosts: allowedHosts) else {
            throw SourceHTTPTransportError.invalidURL
        }
        guard maximumResponseBytes > 0, successPrefixBytes.map({ $0 > 0 }) ?? true else {
            throw SourceHTTPTransportError.invalidResponse
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let policy = SourceHTTPRedirectPolicy(allowedHosts: allowedHosts, cookiePolicy: cookiePolicy)
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var safe = policy.sanitized(request, url: url)
        safe.cachePolicy = .reloadIgnoringLocalCacheData
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: safe)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            throw SourceHTTPTransportError.invalidResponse
        }
        guard Self.permits(finalURL, allowedHosts: allowedHosts) else {
            throw SourceHTTPTransportError.invalidURL
        }
        let prefixOnly = successPrefixBytes != nil
        let limit = (200..<300).contains(http.statusCode) ? (successPrefixBytes ?? maximumResponseBytes) : maximumResponseBytes
        guard prefixOnly || response.expectedContentLength <= Int64(limit) else {
            throw SourceHTTPTransportError.oversizedResponse
        }
        var data = Data()
        data.reserveCapacity(response.expectedContentLength > 0 ? min(Int(response.expectedContentLength), limit) : min(64_000, limit))
        do {
            for try await byte in bytes {
                guard data.count < limit else { throw SourceHTTPTransportError.oversizedResponse }
                data.append(byte)
                if prefixOnly && data.count == limit { break }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return SourceHTTPResponse(data: data, url: finalURL, statusCode: http.statusCode, headers: headers)
    }

    static func permits(_ url: URL, allowedHosts: Set<String>) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && url.port == nil &&
            url.host.map { allowedHosts.contains($0.lowercased()) } == true
    }
}

private final class SourceHTTPRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>
    private let cookiePolicy: SourceHTTPTransport.CookiePolicy?

    init(allowedHosts: Set<String>, cookiePolicy: SourceHTTPTransport.CookiePolicy?) {
        self.allowedHosts = allowedHosts
        self.cookiePolicy = cookiePolicy
    }

    func sanitized(_ request: URLRequest, url: URL) -> URLRequest {
        var safe = request
        safe.httpShouldHandleCookies = false
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        if let policy = cookiePolicy, let host = url.host?.lowercased(), policy.credentialHosts.contains(host) {
            let eligible = policy.cookies.filter { cookie in
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                return cookie.isSecure && (host == domain || host.hasSuffix("." + domain)) &&
                    (url.path == cookie.path || url.path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/"))
            }
            if !eligible.isEmpty {
                safe.setValue(HTTPCookie.requestHeaderFields(with: eligible)["Cookie"], forHTTPHeaderField: "Cookie")
            }
        }
        return safe
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, SourceHTTPTransport.permits(url, allowedHosts: allowedHosts) else {
            completionHandler(nil)
            return
        }
        completionHandler(sanitized(request, url: url))
    }
}
