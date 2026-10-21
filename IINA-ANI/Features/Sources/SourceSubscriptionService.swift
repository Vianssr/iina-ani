import Foundation

enum SourceSubscriptionFailure: Error, LocalizedError {
    case stalePreview, invalidResponse, oversized
    var errorDescription: String? {
        switch self {
        case .stalePreview: return String(localized: "來源或預覽已變更，請重新檢查訂閱後再套用。")
        case .invalidResponse: return String(localized: "訂閱下載失敗或回應不受支援；原有來源未變更。")
        case .oversized: return String(localized: "訂閱超過大小限制；原有來源未變更。")
        }
    }
}

private final class SubscriptionRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.host == "sub.creamycake.org",
              url.user == nil, url.password == nil, url.port == nil else {
            completionHandler(nil)
            return
        }
        var anonymous = request
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie")
        anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        anonymous.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        anonymous.httpShouldHandleCookies = false
        completionHandler(anonymous)
    }
}

/// Only sanitized, explicitly previewed configuration reaches the registry. No remote credentials
/// or media URLs are saved. Existing selections and active player/download owners are untouched.
@MainActor
final class SourceSubscriptionService {
    nonisolated static let endpoint = URL(string: "https://sub.creamycake.org/v1/css1.json")!
    private let registry: SourceRegistry
    private let fetch: @Sendable () async throws -> Data
    private var pending: (plan: SourceSubscriptionPlan, revision: UInt64)?
    private var checkGeneration: UInt64 = 0
    private(set) var lastError: String?
    var lastApplied: SourceSubscriptionPlan? { registry.snapshot.subscription }

    init(registry: SourceRegistry, fetch: @escaping @Sendable () async throws -> Data = SourceSubscriptionService.download) {
        self.registry = registry
        self.fetch = fetch
    }

    func check() async throws -> SourceSubscriptionPlan {
        checkGeneration &+= 1
        let generation = checkGeneration
        let revision = registry.revision
        pending = nil
        lastError = nil
        do {
            let data = try await fetch()
            try Task.checkCancellation()
            guard generation == checkGeneration, revision == registry.revision else {
                throw SourceSubscriptionFailure.stalePreview
            }
            let converted = try SourceSubscriptionConverter.convert(data: data, registry: registry)
            let plan = try await verifyChangedSearches(converted)
            try Task.checkCancellation()
            guard generation == checkGeneration, revision == registry.revision else {
                throw SourceSubscriptionFailure.stalePreview
            }
            pending = (plan, revision)
            return plan
        } catch {
            if generation == checkGeneration { lastError = error is CancellationError ? nil : error.localizedDescription }
            throw error
        }
    }

    func apply(_ plan: SourceSubscriptionPlan) throws {
        guard let pending, pending.plan.fingerprint == plan.fingerprint,
              pending.plan.checkedAt == plan.checkedAt, pending.plan.overrides == plan.overrides else {
            throw SourceSubscriptionFailure.stalePreview
        }
        do {
            try registry.applySubscription(pending.plan, expectedRevision: pending.revision)
            self.pending = nil
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Changed selectors must produce recognizable work identities before replacing the last usable rule.
    /// Unchanged entries need no network probe; a failed site never blocks the other accepted entries.
    private func verifyChangedSearches(_ plan: SourceSubscriptionPlan) async throws -> SourceSubscriptionPlan {
        var overrides = plan.overrides
        var rejected: Set<String> = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for id in plan.overrides.keys.sorted() {
            try Task.checkCancellation()
            guard let data = overrides[id] else { continue }
            let source = try JSONDecoder().decode(NativeSearchSource.self, from: data)
            let previous = registry.subscriptionSearch(for: id) ?? registry.builtinSearch(for: id)
            if let previous, try encoder.encode(previous) == encoder.encode(source) { continue }
            do {
                let page = try await SourceSearchExecutor.search(query: "海贼王", page: 1,
                    spec: source.search, allowedHosts: Set(source.hosts), item: { [registry] raw in
                        guard let item = try? registry.item(for: raw), item.sourceID == id else { return nil }
                        return item
                    })
                guard !page.results.isEmpty else { throw SourceSearchError.malformedResponse }
            } catch {
                try Task.checkCancellation()
                overrides.removeValue(forKey: id)
                rejected.insert(id)
            }
        }
        let entries = plan.entries.map { entry in
            guard let id = entry.sourceID, rejected.contains(id) else { return entry }
            return SourceSubscriptionEntry(sourceID: id, name: entry.name, status: String(localized: "驗證未通過，已保留"),
                detail: String(localized: "新的搜尋規則未取得可辨識作品（網路／驗證頁／無結果）；本次不覆寫舊規則。未判定站點永久失效。"))
        }
        return SourceSubscriptionPlan(fingerprint: plan.fingerprint, checkedAt: plan.checkedAt,
            overrides: overrides, entries: entries)
    }

    nonisolated private static func download() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request, delegate: SubscriptionRedirectPolicy())
        let limit = 1_000_000
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == endpoint.host else {
            throw SourceSubscriptionFailure.invalidResponse
        }
        guard response.expectedContentLength <= limit else { throw SourceSubscriptionFailure.oversized }
        var data = Data()
        data.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 64_000)
        for try await byte in bytes {
            guard data.count < limit else { throw SourceSubscriptionFailure.oversized }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}
