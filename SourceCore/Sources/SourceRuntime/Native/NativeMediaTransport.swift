import Foundation
import SourceCore

extension AccountHTTP {
    /// Only media probes permit arbitrary HTTPS CDN redirects, never API or player requests.
    static func mediaPrefixResponse(_ request: URLRequest, maximumResponseBytes: Int = 1024,
                                    successPrefixBytes: Int = 64) async throws -> SourceHTTPResponse {
        func safe(_ url: URL) -> Bool {
            url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.port == nil
        }
        guard let url = request.url, safe(url) else { throw PlaybackFailure.unsafeMediaAddress }
        if let fetch = currentFetch {
            let response = try await fetch(request)
            guard safe(response.url) else { throw PlaybackFailure.unsafeMediaAddress }
            let limit = (200..<300).contains(response.statusCode) ? successPrefixBytes : maximumResponseBytes
            return SourceHTTPResponse(data: Data(response.data.prefix(limit)), url: response.url,
                statusCode: response.statusCode, headers: response.headers)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NativeMediaRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var original = request
        original.timeoutInterval = 20
        original.setValue(nil, forHTTPHeaderField: "Cookie")
        original.setValue(nil, forHTTPHeaderField: "Authorization")
        original.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        let (bytes, response) = try await session.bytes(for: original)
        guard let http = response as? HTTPURLResponse, let final = http.url, safe(final) else { throw PlaybackFailure.invalidResponseBody }
        let limit = (200..<300).contains(http.statusCode) ? successPrefixBytes : maximumResponseBytes
        var data = Data(); data.reserveCapacity(limit)
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count == limit { break }
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        return SourceHTTPResponse(data: data, url: final, statusCode: http.statusCode, headers: headers)
    }
}

private final class NativeMediaRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.port == nil else { completionHandler(nil); return }
        var safe = request
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        completionHandler(safe)
    }
}

extension PublicPlayerProtocol {
    static func resolveDesktop(_ payload: [String: Any], page: URL) async throws -> URL {
        guard let originalHost = page.host else { throw PlaybackFailure.unsafeMediaAddress }
        let host = ["www.didahd.pro":"www.didahd.xyz", "www.rebozj.pro":"www.rebozj.cc", "www.2kdm.com":"www.mutedm.com"][originalHost] ?? originalHost
        let policy = Policy(host: host)
        let fetch = AccountHTTP.currentFetch
        let client = Self(host: host) { request in
            guard Self.permits(request, configuration: policy) else { throw PlaybackFailure.unsafeMediaAddress }
            let response: SourceHTTPResponse
            if let fetch { response = try await fetch(request) }
            else { response = try await fixedTransport(request, policy: policy) }
            var redirectedRequest = request
            redirectedRequest.url = response.url
            guard Self.permits(redirectedRequest, configuration: policy) else { throw PlaybackFailure.sourceRedirect }
            if response.statusCode == 403 { throw PlaybackFailure.httpForbidden }
            if response.statusCode == 401 { throw PlaybackFailure.authenticationRequired }
            guard (200..<300).contains(response.statusCode) else { throw PlaybackFailure.playerServiceUnavailable }
            guard response.data.count <= 4 * 1024 * 1024 else { throw PlaybackFailure.invalidResponseBody }
            return response.data
        }
        return try await client.resolve(payload, page: page)
    }
    private static func fixedTransport(_ original: URLRequest, policy: Policy) async throws -> SourceHTTPResponse {
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil; settings.urlCache = nil
        settings.httpShouldSetCookies = false
        let session = URLSession(configuration: settings, delegate: NativePlayerRedirectPolicy(policy), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = original
        request.timeoutInterval = requestTimeout(for: original)
        request.setValue("IINA-ANI-iOS/0.1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let final = http.url else { throw PlaybackFailure.invalidResponseBody }
        let prefix = original.value(forHTTPHeaderField: "Range") == "bytes=0-63"
        guard prefix || response.expectedContentLength <= 4 * 1024 * 1024 else { throw PlaybackFailure.invalidResponseBody }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4 * 1024 * 1024 else { throw PlaybackFailure.invalidResponseBody }
            data.append(byte)
            if prefix && data.count == 64 { break }
        }
        try Task.checkCancellation()
        return SourceHTTPResponse(data: data, url: final, statusCode: http.statusCode)
    }
}
private final class NativePlayerRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: PublicPlayerProtocol.Policy
    init(_ policy: PublicPlayerProtocol.Policy) { self.policy = policy }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(PublicPlayerProtocol.permits(request, configuration: policy) ? request : nil)
    }
}
