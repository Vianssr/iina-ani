import Foundation
import Darwin

public enum SourceSubscriptionFailure: Error, LocalizedError, Equatable {
    case stalePreview, invalidAddress, invalidResponse, oversized

    public var errorDescription: String? {
        switch self {
        case .stalePreview: return String(localized: "來源或預覽已變更，請重新檢查訂閱後再套用。")
        case .invalidAddress: return String(localized: "請輸入不含登入資訊的公開 HTTPS 訂閱網址。")
        case .invalidResponse: return String(localized: "訂閱下載失敗或回應不受支援；原有來源未變更。")
        case .oversized: return String(localized: "訂閱超過大小限制；原有來源未變更。")
        }
    }
}

final class SubscriptionRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let validateHost: @Sendable (URL) async throws -> Void
    private let lock = NSLock()
    private var redirects = 0

    init(validateHost: @escaping @Sendable (URL) async throws -> Void) {
        self.validateHost = validateHost
    }

    private func reserveRedirect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        redirects += 1
        return redirects <= 5
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard reserveRedirect(), let url = request.url, SourceSubscriptionTransport.allows(url) else {
            completionHandler(nil)
            return
        }
        Task {
            do {
                try await validateHost(url)
                guard task.state != .canceling && task.state != .completed else { completionHandler(nil); return }
                // A new request prevents credentials or arbitrary headers from crossing hosts.
                completionHandler(SourceSubscriptionTransport.anonymousRequest(url))
            } catch { completionHandler(nil) }
        }
    }
}

/// Anonymous, bounded HTTPS configuration downloads. The default feed remains available,
/// while an explicitly entered public URL can be reviewed through the same import flow.
public enum SourceSubscriptionTransport {
    public static let endpoint = URL(string: "https://sub.creamycake.org/v1/css1.json")!
    public static let maximumBytes = 2 * 1024 * 1024

    public struct Response: Sendable {
        public let data: Data
        public let url: URL
    }

    public static func parse(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8192, !value.contains(where: { $0.isWhitespace }),
              !value.contains("\\"), let url = URL(string: value), allows(url) else { return nil }
        return url
    }

    /// A DNS name is required; resolved addresses are checked separately before each hop.
    public static func allows(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 8192, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, url.fragment == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host.count <= 253,
              host.contains("."), host.contains(where: { $0.isASCII && $0.isLetter }),
              !host.hasSuffix("."),
              !["localhost", "local", "lan", "internal", "home", "home.arpa"].contains(where: {
                  host == $0 || host.hasSuffix("." + $0)
              }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func anonymousRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func download() async throws -> Data { try await download(from: endpoint) }

    public static func download(from url: URL) async throws -> Data {
        try await response(from: url).data
    }

    public static func response(from url: URL) async throws -> Response {
        try await response(from: url, configuration: .ephemeral, validateHost: { url in try await validatePublicHost(url) })
    }

    // The injected host check and URLProtocol configuration keep transport regressions offline.
    static func response(from url: URL, configuration: URLSessionConfiguration,
                         validateHost: @escaping @Sendable (URL) async throws -> Void) async throws -> Response {
        guard allows(url) else { throw SourceSubscriptionFailure.invalidAddress }
        try Task.checkCancellation()
        try await validateHost(url)
        try Task.checkCancellation()
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let policy = SubscriptionRedirectPolicy(validateHost: validateHost)
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: anonymousRequest(url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = response.url, allows(finalURL) else {
            throw SourceSubscriptionFailure.invalidResponse
        }
        guard response.expectedContentLength <= maximumBytes else { throw SourceSubscriptionFailure.oversized }
        var data = Data()
        data.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 64_000)
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw SourceSubscriptionFailure.oversized }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard !data.isEmpty else { throw SourceSubscriptionFailure.invalidResponse }
        return Response(data: data, url: finalURL)
    }

    static func validatePublicHost(_ url: URL) async throws {
        guard allows(url), let host = url.host else { throw SourceSubscriptionFailure.invalidAddress }
        let isPublic: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var addresses: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &addresses) == 0, let first = addresses else {
                    continuation.resume(returning: false)
                    return
                }
                defer { freeaddrinfo(first) }
                var current: UnsafeMutablePointer<addrinfo>? = first
                var found = false
                while let entry = current {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen,
                                      &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                          isPublicAddress(String(cString: buffer)) else {
                        continuation.resume(returning: false)
                        return
                    }
                    found = true
                    current = entry.pointee.ai_next
                }
                continuation.resume(returning: found)
            }
        }
        try Task.checkCancellation()
        guard isPublic else { throw SourceSubscriptionFailure.invalidAddress }
    }

    static func isPublicAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            let a = bytes[0], b = bytes[1], c = bytes[2]
            return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) ||
                (a == 172 && (16...31).contains(b)) ||
                (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99))) ||
                (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
                (a == 203 && b == 0 && c == 113))
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        // Global unicast only; exclude documentation and transition ranges.
        return bytes[0] & 0xe0 == 0x20 &&
            !(bytes[0] == 0x20 && bytes[1] == 0x01 &&
              ((bytes[2] == 0x0d && bytes[3] == 0xb8) || (bytes[2] == 0 && bytes[3] == 0))) &&
            !(bytes[0] == 0x20 && bytes[1] == 0x02) &&
            !(bytes[0] == 0x3f && bytes[1] == 0xff)
    }
}
