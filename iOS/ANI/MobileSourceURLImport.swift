import Foundation
import CoreFoundation
import Observation

enum MobileSourceImportFailure: Error {
    case invalidAddress, download, invalidConfiguration, requiresSources, staleSources

    var message: String {
        switch self {
        case .invalidAddress: "Enter an HTTPS configuration URL without embedded credentials."
        case .download: "The configuration could not be downloaded. Check the URL and connection, then try again."
        case .invalidConfiguration: "Use a valid source configuration, source list, or search-rule subscription within the import limits."
        case .requiresSources: "This subscription only contains search rules. Import a complete source configuration first."
        case .staleSources: "Your sources changed during import. Download the subscription again."
        }
    }
}

struct MobileSourceBatchDraft: Identifiable {
    let id = UUID()
    let drafts: [MobileSourceDraft]
    let notices: [String]
    init(drafts: [MobileSourceDraft], notices: [String] = []) {
        self.drafts = drafts
        self.notices = notices
    }
}

struct MobileSourceImportResponse: Sendable {
    let data: Data
    let url: URL
}

/// Download and review are separate from committing a source to the local library.
@MainActor @Observable
final class MobileSourceURLImport {
    typealias Fetch = @Sendable (URL) async throws -> MobileSourceImportResponse
    typealias Probe = @MainActor @Sendable (SourceConfiguration) async throws -> Bool
    static let maximumSources = 100
    static let maximumTotalBytes = 16 * 1024 * 1024
    private(set) var busy = false
    private(set) var failure: MobileSourceImportFailure?
    private(set) var draft: MobileSourceDraft?
    private(set) var batch: MobileSourceBatchDraft?
    private(set) var subscriptionPreview: MobileSubscriptionPreview?
    private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    private let fetch: Fetch
    private let probe: Probe

    init(probe: @escaping Probe = { try await MobileSourceURLImport.probeResolution($0) },
         fetchResponse: @escaping Fetch = { try await MobileSourceImportTransport.fetchResponse($0) }) {
        self.fetch = fetchResponse
        self.probe = probe
    }

    convenience init(probe: @escaping Probe = { try await MobileSourceURLImport.probeResolution($0) },
                     fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.init(probe: probe, fetchResponse: { .init(data: try await fetch($0), url: $0) })
    }

    deinit { task?.cancel() }

    static func forApp() -> MobileSourceURLImport {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-source-import-ui-fixture") {
            return MobileSourceURLImport(probe: { _ in true }) { url in
                let data = try MobileSourceFixtures.configurationData()
                guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw MobileSourceImportFailure.download
                }
                object["id"] = "fixture-url-source"
                object["name"] = "URL configuration fixture"
                switch url.absoluteString {
                case "https://configuration.example/source.json":
                    return try JSONSerialization.data(withJSONObject: object)
                case "https://configuration.example/list.json":
                    var second = object
                    second["id"] = "fixture-list-source"
                    second["name"] = "List configuration fixture"
                    // Keep host matching unambiguous for the following subscription fixture.
                    var encoded = String(decoding: try JSONSerialization.data(withJSONObject: second), as: UTF8.self)
                    encoded = encoded.replacingOccurrences(of: "fqdm.cc", with: "second.example")
                    second = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as! [String: Any]
                    return try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [object, second]])
                case "https://mirror.example/rules.json?version=2":
                    guard let search = try MobileSourceLibrary.validate(data).search else { throw MobileSourceImportFailure.download }
                    let item: [String: Any] = ["id": "fixture-css1", "factoryId": "web-selector", "version": 2,
                        "arguments": ["name": "Mirrored CSS1 fixture", "searchConfig": [
                            "searchUrl": search.url.replacingOccurrences(of: "{query}", with: "{keyword}"),
                            "subjectFormatId": "a", "selectorSubjectFormatA": ["selectLists": search.resultsSelector ?? "a"],
                            "channelFormatId": "index-grouped", "selectorChannelFormatFlattened": [
                                "selectChannelNames": ".module-tab-item span", "selectEpisodeLists": ".module-play-list",
                                "selectEpisodesFromList": "a", "selectEpisodeLinksFromList": ""]]]]
                    return try JSONSerialization.data(withJSONObject: ["mediaSources": [item]])
                default: throw MobileSourceImportFailure.download
                }
            }
        }
        #endif
        return MobileSourceURLImport()
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        busy = false
        failure = nil
        clearPreview()
    }

    func clearPreview() { draft = nil; batch = nil; subscriptionPreview = nil }

    func load(_ address: String, library: MobileSourceLibrary? = nil) {
        cancel()
        guard let url = MobileSourceImportTransport.parse(address) else {
            failure = .invalidAddress
            return
        }
        let expected = generation
        let fetch = fetch
        let probe = probe
        busy = true
        task = Task { [weak self] in
            do {
                let response = try await fetch(url)
                try Task.checkCancellation()
                var content = try await Self.decode(response, fetch: fetch)
                if case .batch(let batch) = content {
                    content = .batch(try await Self.verified(batch, probe: probe))
                }
                try Task.checkCancellation()
                guard let self, self.generation == expected else { return }
                switch content {
                case .single(let draft): self.draft = draft
                case .batch(let batch): self.batch = batch
                }
                self.busy = false
                self.task = nil
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.failure = error as? MobileSourceImportFailure ?? .download
                self.busy = false
                self.task = nil
            }
        }
    }

    /// Only CSS1 conversions need this gate; native configurations retain their import contract.
    /// Failure excludes this update, never deletes or disables an existing source.
    static func verified(_ batch: MobileSourceBatchDraft, probe: @escaping Probe) async throws -> MobileSourceBatchDraft {
        var failures: [Int: String] = [:]
        let candidates = batch.drafts.enumerated().filter { $0.element.configuration.webSelector != nil }
        try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            var next = 0
            func enqueue() {
                guard next < candidates.count else { return }
                let (index, draft) = candidates[next]
                next += 1
                group.addTask {
                    do {
                        let passed = try await probe(draft.configuration)
                        try Task.checkCancellation()
                        return (index, passed ? nil : String(localized: "No sample media URL resolved; skipped this import. Retry later."))
                    } catch {
                        try Task.checkCancellation()
                        let reason = MobileSourceClient.failure(for: error)
                        let message: String
                        switch reason {
                        case .authenticationRequired: message = String(localized: "Site requires authentication or blocked the request; skipped this import.")
                        case .network: message = String(localized: "Source check timed out or failed to connect; skipped this import. Retry later.")
                        default: message = String(localized: "No sample media URL resolved; skipped this import. Retry later.")
                        }
                        return (index, message)
                    }
                }
            }
            for _ in 0..<min(3, candidates.count) { enqueue() }
            for try await (index, reason) in group {
                if let reason { failures[index] = reason }
                enqueue()
            }
        }
        try Task.checkCancellation()
        let notices = failures.keys.sorted().map { batch.drafts[$0].configuration.name + " · " + failures[$0]! }
        return .init(drafts: batch.drafts.enumerated().filter { failures[$0.offset] == nil }.map(\.element),
                     notices: batch.notices + notices)
    }

    /// A resolved sample is a compatibility check, not proof of playback or content identity.
    nonisolated static func probeResolution(_ configuration: SourceConfiguration) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                let client = MobileSourceClient(configuration: configuration)
                var works: [MobileSourceWork] = []
                for query in ["海贼王", "鬼灭之刃"] {
                    works = try await client.search(query).works
                    if !works.isEmpty { break }
                }
                for work in works.prefix(2) {
                    try Task.checkCancellation()
                    do {
                        let catalog = try await client.catalog(work)
                        for line in catalog.lines.prefix(2) {
                            guard let episode = line.episodes.first else { continue }
                            do {
                                _ = try await client.resolve(episode, in: catalog)
                                try Task.checkCancellation()
                                return true
                            } catch {
                                try Task.checkCancellation()
                                if MobileSourceClient.failure(for: error) == .authenticationRequired { throw error }
                            }
                        }
                    } catch {
                        try Task.checkCancellation()
                        if MobileSourceClient.failure(for: error) == .authenticationRequired { throw error }
                    }
                }
                return false
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 45_000_000_000)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
    }

    private enum Content {
        case single(MobileSourceDraft), batch(MobileSourceBatchDraft)
    }

    private static func decode(_ response: MobileSourceImportResponse, fetch: Fetch) async throws -> Content {
        let data = response.data
        guard MobileSourceImportTransport.allows(response.url), !data.isEmpty,
              data.count <= MobileSourceImportTransport.maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) else { throw MobileSourceImportFailure.invalidConfiguration }
        // A valid native configuration remains native even if an exporter adds a `sources` key.
        if let configuration = try? MobileSourceLibrary.validate(data) {
            return .single(.init(configuration: configuration, data: data))
        }
        let entries: [Any]
        if let list = object as? [Any] { entries = list }
        else if let root = object as? [String: Any] {
            if root["mediaSources"] != nil || (root["exportedMediaSourceDataList"] as? [String: Any])?["mediaSources"] != nil {
                do { return .batch(try MobileCSS1Configuration.convert(data: data)) }
                catch { throw MobileSourceImportFailure.invalidConfiguration }
            }
            guard root["id"] == nil, let version = root["version"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1, let list = root["sources"] as? [Any] else {
                throw MobileSourceImportFailure.invalidConfiguration
            }
            entries = list
        } else { throw MobileSourceImportFailure.invalidConfiguration }
        guard !entries.isEmpty, entries.count <= maximumSources else { throw MobileSourceImportFailure.invalidConfiguration }
        var totalBytes = data.count
        var ids = Set<String>()
        var drafts: [MobileSourceDraft] = []
        for entry in entries {
            try Task.checkCancellation()
            let sourceData: Data
            if let reference = entry as? String {
                guard !reference.isEmpty, reference.count <= 8192,
                      !reference.contains(where: { $0.isWhitespace }), !reference.contains("\\"),
                      let resolved = URL(string: reference, relativeTo: response.url)?.absoluteURL,
                      MobileSourceImportTransport.allows(resolved) else { throw MobileSourceImportFailure.invalidConfiguration }
                let source = try await fetch(resolved)
                try Task.checkCancellation()
                guard MobileSourceImportTransport.allows(source.url), source.data.count <= MobileSourceImportTransport.maximumBytes else {
                    throw MobileSourceImportFailure.invalidConfiguration
                }
                sourceData = source.data
                totalBytes += sourceData.count
                guard totalBytes <= maximumTotalBytes else { throw MobileSourceImportFailure.invalidConfiguration }
            } else if let source = entry as? [String: Any] {
                sourceData = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])
            } else { throw MobileSourceImportFailure.invalidConfiguration }
            let configuration: SourceConfiguration
            do { configuration = try MobileSourceLibrary.validate(sourceData) }
            catch { throw MobileSourceImportFailure.invalidConfiguration }
            guard ids.insert(configuration.id).inserted else { throw MobileSourceImportFailure.invalidConfiguration }
            drafts.append(.init(configuration: configuration, data: sourceData))
        }
        return .batch(.init(drafts: drafts))
    }
}

/// Anonymous, bounded HTTPS transport. Neither the URL nor credentials are persisted.
final class MobileSourceImportTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let maximumBytes = 2 * 1024 * 1024

    static func parse(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 8192, !value.contains(where: { $0.isWhitespace }), !value.contains("\\"),
              let url = URL(string: value), allows(url) else { return nil }
        return url
    }

    static func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty &&
            url.user == nil && url.password == nil && url.fragment == nil
    }

    static func anonymousRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.allows(url) else { completionHandler(nil); return }
        // Rebuild instead of forwarding headers supplied by the previous hop.
        completionHandler(Self.anonymousRequest(url))
    }

    static func fetch(_ url: URL) async throws -> Data {
        try await fetchResponse(url).data
    }

    static func fetchResponse(_ url: URL) async throws -> MobileSourceImportResponse {
        guard allows(url) else { throw MobileSourceImportFailure.invalidAddress }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: MobileSourceImportTransport(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: anonymousRequest(url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = response.url, allows(finalURL) else { throw MobileSourceImportFailure.download }
        guard response.expectedContentLength <= maximumBytes else { throw MobileSourceImportFailure.invalidConfiguration }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw MobileSourceImportFailure.invalidConfiguration }
            data.append(byte)
        }
        try Task.checkCancellation()
        return .init(data: data, url: finalURL)
    }
}
