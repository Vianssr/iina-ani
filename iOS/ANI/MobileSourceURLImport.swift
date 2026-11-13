import SourceCore
import SourceRuntime
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
    private let searchFetch: SourceHTTPTransport.Fetch?

    init(searchFetch: SourceHTTPTransport.Fetch? = nil, fetchResponse: @escaping Fetch = { url in
        try await MobileSourceImportTransport.fetchResponse(url)
    }) {
        self.fetch = fetchResponse
        self.searchFetch = searchFetch
    }

    convenience init(searchFetch: SourceHTTPTransport.Fetch? = nil, fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.init(searchFetch: searchFetch, fetchResponse: { .init(data: try await fetch($0), url: $0) })
    }

    deinit { task?.cancel() }

    static func forApp() -> MobileSourceURLImport {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-source-import-ui-fixture") {
            return MobileSourceURLImport { url in
                let data = try MobileSourceFixtures.configurationData()
                guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw MobileSourceImportFailure.download
                }
                object["id"] = "fixture-url-source"
                object["name"] = "URL configuration fixture"
                switch url.absoluteString {
                case "https://configuration.example/static.json":
                    return try MobileSourceFixtures.staticSubscriptionData()
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
                case SourceSubscriptionTransport.endpoint.absoluteString:
                    return try await MobileSourceSubscription.download()
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
        busy = true
        task = Task { [weak self] in
            do {
                let response = try await fetch(url)
                try Task.checkCancellation()
                let content = try await Self.decode(response, fetch: fetch)
                try Task.checkCancellation()
                guard let self, self.generation == expected else { return }
                switch content {
                case .single(let draft): self.draft = draft
                case .batch(let batch): self.batch = batch
                case .subscription(let data):
                    guard let library else { throw MobileSourceImportFailure.requiresSources }
                    library.reload()
                    let prepared = try await MobileSourceSubscription.prepare(
                        baselines: library.subscriptionBaselines, current: library.sources, fetch: { data },
                        searchFetch: self.searchFetch ?? MobileSourceSubscription.fixtureSearchFetch)
                    guard self.generation == expected else { return }
                    try library.validateSubscriptionRevisions(prepared.revisions)
                    self.subscriptionPreview = prepared
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


    private enum Content {
        case single(MobileSourceDraft), batch(MobileSourceBatchDraft), subscription(Data)
    }

    private static func decode(_ response: MobileSourceImportResponse, fetch: Fetch) async throws -> Content {
        let data = response.data
        guard MobileSourceImportTransport.allows(response.url), !data.isEmpty,
              data.count <= MobileSourceImportTransport.maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) else { throw MobileSourceImportFailure.invalidConfiguration }
        // Valid configured JSON remains a single import even if an exporter adds a `sources` key.
        if let configuration = try? MobileSourceLibrary.validate(data) {
            return .single(.init(configuration: configuration, data: data))
        }
        let entries: [Any]
        if let list = object as? [Any] { entries = list }
        else if let root = object as? [String: Any] {
            if root["mediaSources"] != nil || (root["exportedMediaSourceDataList"] as? [String: Any])?["mediaSources"] != nil {
                return .subscription(data)
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

/// The same anonymous HTTPS download policy is used for configuration files and subscriptions.
/// Neither the entered URL nor credentials are persisted.
enum MobileSourceImportTransport {
    static let maximumBytes = SourceSubscriptionTransport.maximumBytes

    static func parse(_ input: String) -> URL? { SourceSubscriptionTransport.parse(input) }
    static func allows(_ url: URL) -> Bool { SourceSubscriptionTransport.allows(url) }

    static func fetch(_ url: URL) async throws -> Data { try await fetchResponse(url).data }

    static func fetchResponse(_ url: URL) async throws -> MobileSourceImportResponse {
        do {
            let response = try await SourceSubscriptionTransport.response(from: url)
            return .init(data: response.data, url: response.url)
        } catch SourceSubscriptionFailure.invalidAddress { throw MobileSourceImportFailure.invalidAddress }
        catch SourceSubscriptionFailure.oversized { throw MobileSourceImportFailure.invalidConfiguration }
        catch is CancellationError { throw CancellationError() }
        catch { throw MobileSourceImportFailure.download }
    }
}
