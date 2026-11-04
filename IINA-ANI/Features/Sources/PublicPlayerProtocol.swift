import Foundation
import SourceCore

/// Desktop transport for the shared, fixed public player protocols.
extension PublicPlayerProtocol {
    static func resolveDesktop(_ payload: [String: Any], page: URL) async throws -> URL {
        guard let originalHost = page.host else { throw PlaybackFailure.unsafeMediaAddress }
        let host = ["www.didahd.pro":"www.didahd.xyz", "www.rebozj.pro":"www.rebozj.cc", "www.2kdm.com":"www.mutedm.com"][originalHost] ?? originalHost
        let policy = Policy(host: host)
        let client = Self(host: host) { try await transport($0, policy: policy) }
        return try await client.resolve(payload, page: page)
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        let policy: Policy
        init(_ policy: Policy) { self.policy = policy }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(PublicPlayerProtocol.permits(request, configuration: policy) ? request : nil)
        }
    }
    private static func transport(_ original: URLRequest, policy: Policy) async throws -> Data {
        guard permits(original, configuration: policy) else { throw PlaybackFailure.unsafeMediaAddress }
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil; settings.urlCache = nil
        settings.httpShouldSetCookies = false
        let session = URLSession(configuration: settings, delegate: RedirectPolicy(policy), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = original
        request.timeoutInterval = requestTimeout(for: original)
        request.setValue("IINA-ANI-iOS/0.1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlaybackFailure.invalidResponseBody }
        if http.statusCode == 403 { throw PlaybackFailure.httpForbidden }
        if http.statusCode == 401 { throw PlaybackFailure.authenticationRequired }
        guard (200..<300).contains(http.statusCode) else { throw PlaybackFailure.playerServiceUnavailable }
        let prefix = original.value(forHTTPHeaderField: "Range") == "bytes=0-63"
        guard prefix || response.expectedContentLength <= 4 * 1024 * 1024 else { throw PlaybackFailure.invalidResponseBody }
        var result = Data()
        for try await byte in bytes {
            guard result.count < 4 * 1024 * 1024 else { throw PlaybackFailure.invalidResponseBody }
            result.append(byte)
            if prefix && result.count == 64 { break }
        }
        try Task.checkCancellation()
        return result
    }
}
