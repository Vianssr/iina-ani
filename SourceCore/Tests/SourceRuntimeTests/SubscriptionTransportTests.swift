import Foundation
import XCTest
@testable import SourceRuntime

private final class SubscriptionFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var headers = ["Content-Type": "application/json"]
        let data: Data
        switch url.path {
        case "/empty": data = Data()
        case "/oversized-header":
            headers["Content-Length"] = String(SourceSubscriptionTransport.maximumBytes + 1)
            data = Data("{}".utf8)
        case "/oversized-body": data = Data(repeating: 32, count: SourceSubscriptionTransport.maximumBytes + 1)
        default: data = Data(#"{"mediaSources":[]}"#.utf8)
        }
        let responseURL = url.path == "/unsafe-final" ? URL(string: "https://127.0.0.1/config")! : url
        let response = HTTPURLResponse(url: responseURL, statusCode: url.path == "/forbidden" ? 403 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SubscriptionTransportTests: XCTestCase {
    func testCustomHTTPSURLPolicy() {
        for raw in [SourceSubscriptionTransport.endpoint.absoluteString,
                    "https://ghfast.top/raw.githubusercontent.com/MajoSissi/animeko-source/main/dist/online.json",
                    "https://raw.githubusercontent.com/owner/repo/main/sources.json",
                    "https://public.example:443/config?version=2"] {
            XCTAssertNotNil(SourceSubscriptionTransport.parse(raw), raw)
        }
        for raw in ["http://public.example/config", "file:///tmp/config", "https://user:secret@public.example/config",
                    "https://public.example/config#fragment", "https://public.example:8443/config",
                    "https://127.0.0.1/config", "https://127.1/config", "https://2130706433/config",
                    "https://0x7f000001/config", "https://[::1]/config", "https://[::ffff:127.0.0.1]/config",
                    "https://192.168.1.1/config", "https://localhost/config", "https://router.local/config",
                    "https://service.internal/config", "https://router.home.arpa/config", "https://public..example/config",
                    "https://public.example/config path", "https://public.example\\config"] {
            XCTAssertNil(SourceSubscriptionTransport.parse(raw), raw)
        }
    }

    func testResolvedAddressPolicy() {
        for address in ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111", "2001:4860:4860::8888"] {
            XCTAssertTrue(SourceSubscriptionTransport.isPublicAddress(address), address)
        }
        for address in ["0.0.0.0", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.169.254",
                        "172.16.0.1", "192.168.1.1", "192.0.2.1", "198.18.0.1", "198.51.100.1",
                        "203.0.113.1", "224.0.0.1", "255.255.255.255", "::", "::1", "fc00::1", "fe80::1",
                        "::ffff:127.0.0.1", "2001:db8::1", "2002:7f00:1::1", "ff02::1", "not-an-address"] {
            XCTAssertFalse(SourceSubscriptionTransport.isPublicAddress(address), address)
        }
    }

    func testAnonymousBoundedDownload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionFixtureProtocol.self]
        let url = URL(string: "https://feed.example/online.json")!
        let request = SourceSubscriptionTransport.anonymousRequest(url)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let response = try await SourceSubscriptionTransport.response(from: url, configuration: configuration,
                                                                      validateHost: { XCTAssertEqual($0.host, "feed.example") })
        XCTAssertEqual(response.url, url)
        XCTAssertEqual(response.data, Data(#"{"mediaSources":[]}"#.utf8))
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        for (path, expected) in [("empty", SourceSubscriptionFailure.invalidResponse), ("forbidden", .invalidResponse),
                                 ("unsafe-final", .invalidResponse), ("oversized-header", .oversized), ("oversized-body", .oversized)] {
            do {
                _ = try await SourceSubscriptionTransport.response(from: URL(string: "https://feed.example/" + path)!,
                    configuration: configuration, validateHost: { _ in })
                XCTFail("Accepted \(path)")
            } catch { XCTAssertEqual(error as? SourceSubscriptionFailure, expected, path) }
        }
    }

    func testRedirectsAreAnonymousBoundedAndValidated() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://feed.example/start")!)
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let policy = SubscriptionRedirectPolicy(validateHost: { url in
            if url.host == "private-dns.example" { throw SourceSubscriptionFailure.invalidAddress }
        })
        var request = URLRequest(url: URL(string: "https://cdn.example/online.json")!)
        request.setValue("private-cookie", forHTTPHeaderField: "Cookie")
        request.setValue("private-auth", forHTTPHeaderField: "Authorization")
        request.setValue("private-proxy", forHTTPHeaderField: "Proxy-Authorization")
        let redirected = await redirect(policy, session, task, response, request)
        XCTAssertEqual(redirected?.url, request.url)
        XCTAssertNil(redirected?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(redirected?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(redirected?.value(forHTTPHeaderField: "Proxy-Authorization"))
        XCTAssertEqual(redirected?.httpShouldHandleCookies, false)
        for raw in ["http://cdn.example/config", "https://localhost/config", "https://private-dns.example/config"] {
            let rejected = await redirect(policy, session, task, response, URLRequest(url: URL(string: raw)!))
            XCTAssertNil(rejected)
        }
        let last = await redirect(policy, session, task, response, request)
        XCTAssertNotNil(last)
        let sixth = await redirect(policy, session, task, response, request)
        XCTAssertNil(sixth)
    }

    private func redirect(_ policy: SubscriptionRedirectPolicy, _ session: URLSession, _ task: URLSessionTask,
                          _ response: HTTPURLResponse, _ request: URLRequest) async -> URLRequest? {
        await withCheckedContinuation { continuation in
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request,
                              completionHandler: { continuation.resume(returning: $0) })
        }
    }
}
