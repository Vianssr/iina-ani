import Foundation

@main
struct TraceMoeSearchRegression {
    struct Failure: Error { let message: String }
    static let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }

    static func main() async throws {
        try await responseVariantsAndRequestPrivacy()
        try await malformedResponses()
        try await safeFailures()
        try await cancellation()
        try await imageBounds()
        try await redirectPolicy()
        print("PASS TraceMoeSearchRegression: response variants, request privacy, numeric validation, safe HTTP/API/network errors, cancellation, upload bounds and redirect rejection")
    }

    static func service(body: String, status: Int = 200) -> TraceMoeSearchService {
        TraceProtocol.state.configure(body: Data(body.utf8), status: status)
        return TraceMoeSearchService(protocolClasses: [TraceProtocol.self])
    }

    static func result(anilist: String = "123", episode: String = "null", filename: String = "fallback.mp4",
                       from: String = "97.7226", to: String = "98.8905", similarity: String = "0.944",
                       video: String = #""https://api.trace.moe/video/123?token=fixture""#) -> String {
        """
        {"anilist":\(anilist),"filename":"\(filename)","episode":\(episode),"from":\(from),"to":\(to),"similarity":\(similarity),"video":\(video)}
        """
    }

    static func payload(_ results: [String]) -> String {
        "{\"error\":\"\",\"result\":[\(results.joined(separator: ","))]}"
    }

    static func responseVariantsAndRequestPrivacy() async throws {
        let variants = [
            result(anilist: #"{"id":99939,"title":{"native":"ネコぱらOVA","romaji":"Nekopara OVA","english":null},"isAdult":false}"#),
            result(episode: "7"),
            result(anilist: #"{"id":124,"title":{"native":null,"romaji":"Romaji title","english":"English title"}}"#, episode: "7.5"),
            result(anilist: #"{"id":125,"title":{"native":"  ","romaji":null,"english":"English title"}}"#, episode: #""SP 1""#),
            result(anilist: "null", episode: #"[1,2,"SP",null]"#),
            result(anilist: #"{"id":126,"title":{"native":null,"romaji":null,"english":null}}"#, episode: "[]", similarity: "0.4"),
            result(anilist: "0", episode: #""  ""#, from: "0", to: "0", similarity: "1")
        ]
        let matches = try await service(body: payload(variants)).search(jpeg: jpeg)
        try require(matches.count == 7, "All genuine anilist and episode variants must survive")
        try require(matches[0].title == "ネコぱらOVA" && matches[0].anilistID == 99939 && matches[0].episode == nil,
                    "Expanded AniList metadata must prefer native title and preserve null episode")
        try require(matches[0].from == 97.7226 && matches[0].to == 98.8905 && matches[0].similarity == 0.944,
                    "Scene interval and similarity must retain precision")
        try require(matches[0].videoURL?.host == "api.trace.moe", "HTTPS preview URL must be available")
        try require(matches[1].title == "fallback.mp4" && matches[1].anilistID == 123 && matches[1].episode == "7",
                    "Numeric AniList ID must fall back to filename; integer episode must not gain decimals")
        try require(matches[2].title == "Romaji title" && matches[2].episode == "7.5", "Romaji fallback and fractional episode must decode")
        try require(matches[3].title == "English title" && matches[3].episode == "SP 1", "English fallback and string episode must decode")
        try require(matches[4].anilistID == nil && matches[4].episode == "1, 2, SP", "Array episodes must remain readable without null elements")
        try require(matches[5].title == "fallback.mp4" && matches[5].episode == nil && matches[5].similarity == 0.4,
                    "Missing titles and empty episodes must fall back; low-confidence valid matches must not be hidden")
        try require(matches[6].anilistID == nil && matches[6].episode == nil, "Nonpositive AniList ID and blank episode must not be displayed")

        let requests = TraceProtocol.state.requests
        try require(requests.count == 1, "One search must perform exactly one upload")
        let request = requests[0]
        try require(!request.httpShouldHandleCookies && request.value(forHTTPHeaderField: "Cookie") == nil,
                    "Screenshot uploads must never carry cookies")
        let empty = try await service(body: payload([])).search(jpeg: jpeg)
        try require(empty.isEmpty, "Valid empty result is not an API failure")

        for unsafe in [#""file:///private/screenshot.jpg""#, #""javascript:alert(1)""#, #""http://api.trace.moe/video/1""#,
                       #""https://user:password@example.invalid/video""#, #""not a URL""#, "null"] {
            let rows = try await service(body: payload([result(video: unsafe)])).search(jpeg: jpeg)
            try require(rows[0].videoURL == nil, "Unsafe preview must not become an actionable URL")
        }
    }

    static func expect(_ expected: TraceMoeSearchError, _ operation: () async throws -> [TraceMoeMatch]) async throws {
        do {
            _ = try await operation()
            throw Failure(message: "Expected search failure: \(expected)")
        } catch let error as TraceMoeSearchError {
            try require(error == expected, "Search error classification must be stable")
        }
    }

    static func malformedResponses() async throws {
        let invalid = [
            "not JSON", "{}", #"{"error":""}"#, #"{"error":"","result":null}"#,
            #"{"error":"","result":[{}]}"#,
            payload([result(similarity: "-0.1")]), payload([result(similarity: "1.01")]),
            payload([result(similarity: "1e999")]), payload([result(similarity: #""NaN""#)]),
            payload([result(from: "-1")]), payload([result(from: "100", to: "99")]),
            payload([result(to: "1e999")]), payload([result(from: #""Infinity""#)]),
            payload([result(anilist: #""wrong type""#)]), payload([result(episode: "true")]),
            payload([result(episode: #"{"number":7}"#)]), payload([result(filename: "  ")]),
            payload([result(), result(similarity: "2")])
        ]
        for body in invalid {
            let client = service(body: body)
            try await expect(.invalidResponse) { try await client.search(jpeg: jpeg) }
        }
    }

    static func safeFailures() async throws {
        for (status, expected) in [(402, TraceMoeSearchError.quotaExceeded), (429, .rateLimited), (413, .imageTooLarge),
                                   (400, .httpStatus(400)), (503, .httpStatus(503)), (307, .httpStatus(307))] {
            let client = service(body: "private response /Users/private/screenshot.jpg?token=secret", status: status)
            try await expect(expected) { try await client.search(jpeg: jpeg) }
            try require(!expected.localizedDescription.contains("private") && !expected.localizedDescription.contains("secret"),
                        "HTTP errors must never expose server body or local paths")
        }
        for (body, expected) in [
            (#"{"error":"Search quota depleted (quota per 24 hours: 100, used: 100)","quota":100,"quotaUsed":100}"#, TraceMoeSearchError.quotaExceeded),
            (#"{"error":"Concurrency limit exceeded"}"#, .rateLimited),
            (#"{"error":"private response /Users/private/screenshot.jpg?token=secret","result":[]}"#, .serviceFailed)
        ] {
            let client = service(body: body)
            try await expect(expected) { try await client.search(jpeg: jpeg) }
            try require(!expected.localizedDescription.contains("private") && !expected.localizedDescription.contains("secret"),
                        "API errors must never expose their raw text")
        }
        TraceProtocol.state.configure(networkError: .cannotConnectToHost)
        let client = TraceMoeSearchService(protocolClasses: [TraceProtocol.self])
        try await expect(.networkFailed) { try await client.search(jpeg: jpeg) }
    }

    static func cancellation() async throws {
        TraceProtocol.state.configure(networkError: .cancelled)
        let client = TraceMoeSearchService(protocolClasses: [TraceProtocol.self])
        do {
            _ = try await client.search(jpeg: jpeg)
            throw Failure(message: "Transport cancellation must escape")
        } catch is CancellationError { }

        TraceProtocol.state.configure(hold: true)
        let pending = Task { try await client.search(jpeg: jpeg) }
        try await waitUntil { !TraceProtocol.state.requests.isEmpty }
        pending.cancel()
        do {
            _ = try await pending.value
            throw Failure(message: "In-flight cancellation must escape")
        } catch is CancellationError { }
        try await waitUntil { TraceProtocol.state.stopCount > 0 }

        TraceProtocol.state.configure(body: Data(payload([]).utf8))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.search(jpeg: jpeg)
        }
        do {
            _ = try await cancelled.value
            throw Failure(message: "Pre-cancelled search must not upload")
        } catch is CancellationError { }
        try require(TraceProtocol.state.requests.isEmpty, "A cancelled caller must not upload image bytes")
    }

    static func imageBounds() async throws {
        let client = service(body: payload([]))
        try await expect(.invalidImage) { try await client.search(jpeg: Data()) }
        try await expect(.imageTooLarge) { try await client.search(jpeg: Data(repeating: 0, count: 25_000_001)) }
        try require(TraceProtocol.state.requests.isEmpty, "Invalid upload bounds must be rejected before networking")
    }

    static func redirectPolicy() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // Invoke the actual task delegate for 301/302/303/307/308, without asking URLProtocol
        // to emulate URLSession's redirect machinery or making a real network request.
        let delegate = TraceMoeRedirectDelegate()
        for code in [301, 302, 303, 307, 308] {
            for destination in ["https://other.example/upload", "https://api.trace.moe/elsewhere"] {
                let request = URLRequest(url: URL(string: destination)!)
                let task = session.dataTask(with: request)
                let response = HTTPURLResponse(url: URL(string: "https://api.trace.moe/search")!, statusCode: code,
                                               httpVersion: nil, headerFields: ["Location": destination])!
                let refused = await withCheckedContinuation { continuation in
                    delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { next in
                        continuation.resume(returning: next == nil)
                    }
                }
                try require(refused, "Every redirect must reject forwarding the screenshot, even on the same host")
                task.cancel()
            }
        }
    }

    static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "Timed out waiting for offline URLProtocol event")
    }
}

private final class TraceProtocol: URLProtocol, @unchecked Sendable {
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fixture = Self.state.start(request)
        if fixture.hold { return }
        if let code = fixture.networkError {
            client?.urlProtocol(self, didFailWithError: URLError(code, userInfo: [NSLocalizedDescriptionKey: "private /Users/private/image.jpg?token=secret"]))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { Self.state.stop() }

    struct Fixture: Sendable {
        let body: Data
        let status: Int
        let networkError: URLError.Code?
        let hold: Bool
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var fixture = Fixture(body: Data(), status: 200, networkError: nil, hold: false)
        private var recordedRequests: [URLRequest] = []
        private var stopped = 0

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }
        var stopCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
        func configure(body: Data = Data(), status: Int = 200, networkError: URLError.Code? = nil, hold: Bool = false) {
            lock.lock()
            defer { lock.unlock() }
            fixture = Fixture(body: body, status: status, networkError: networkError, hold: hold)
            recordedRequests = []
            stopped = 0
        }
        func start(_ request: URLRequest) -> Fixture {
            lock.lock()
            defer { lock.unlock() }
            recordedRequests.append(request)
            return fixture
        }
        func stop() {
            lock.lock()
            defer { lock.unlock() }
            stopped += 1
        }
    }
}
