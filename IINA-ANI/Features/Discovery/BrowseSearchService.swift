import Foundation

enum BrowseContentFilter: String, CaseIterable, Sendable {
    case anime, video, live
    var title: String {
        switch self {
        case .anime: return String(localized: "番劇")
        case .video: return String(localized: "視頻")
        case .live: return String(localized: "直播")
        }
    }
    func includes(_ kind: MediaContentKind) -> Bool {
        switch self {
        case .anime: return kind == .anime
        case .video: return kind == .video
        case .live: return kind == .live
        }
    }
}

struct BrowseSearchSnapshot: Sendable {
    enum Route: Sendable {
        case keyword(BangumiSearchOutcome)
        case bangumi(Int)
        case url(PlayableSelection)
    }

    let query: String
    let enabledSourceIDs: Set<String>
    let contentFilter: BrowseContentFilter
    let page: Int
    let route: Route
    let sources: [String: SourceSearchOutcome]
}

enum BangumiSearchOutcome: Sendable {
    case results([BangumiSubject], nextOffset: Int?)
    case empty(nextOffset: Int?)
    case failure(String, previousResults: [BangumiSubject])
}

enum SourceSearchOutcome: Sendable {
    case results([SourceSearchResult], nextPage: Int?)
    case empty(nextPage: Int?)
    case failure(String, previousResults: [SourceSearchResult])
}

actor BrowseSearchService {
    typealias DescriptorLoader = @Sendable () async -> [SourceDescriptor]
    typealias BangumiSearcher = @Sendable (String, Int, Int) async throws -> BangumiPage<BangumiSubject>
    typealias SourceSearcher = @Sendable (String, String, Int) async throws -> SourceSearchPage
    typealias URLResolver = @Sendable (String) async throws -> PlayableSelection

    private struct SearchContext: Sendable {
        let query: String
        let sourceIDs: Set<String>
        let contentFilter: BrowseContentFilter
        var page: Int
        let descriptors: [SourceDescriptor]
        var route: BrowseSearchSnapshot.Route
        var sourceOutcomes: [String: SourceSearchOutcome]
        var sourcePages: [String: Int]
        var bangumiOffset: Int?
        var bangumiSubjects: [BangumiSubject]
    }

    private let loadDescriptors: DescriptorLoader
    private let searchBangumi: BangumiSearcher
    private let searchSource: SourceSearcher
    private let resolveURL: URLResolver
    private let pageSize: Int
    private var generation: UInt64 = 0
    private var currentSearchTask: Task<SearchContext, Error>?
    private var context: SearchContext?
    init(decoder: VideoDecoder = VideoDecoder(), bangumi: BangumiService = .shared, pageSize: Int = 20) {
        self.pageSize = max(1, pageSize)
        loadDescriptors = { await decoder.sourceDescriptors() }
        searchBangumi = { query, limit, offset in
            try await bangumi.search(keyword: query, limit: limit, offset: offset)
        }
        searchSource = { sourceID, query, page in
            try await decoder.searchSource(sourceID: sourceID, query: query, page: page, classifyWithBangumi: false)
        }
        resolveURL = { url in try await decoder.selection(for: url) }
    }

    init(pageSize: Int = 20, loadDescriptors: @escaping DescriptorLoader,
         searchBangumi: @escaping BangumiSearcher, searchSource: @escaping SourceSearcher,
         resolveURL: @escaping URLResolver) {
        self.pageSize = max(1, pageSize)
        self.loadDescriptors = loadDescriptors
        self.searchBangumi = searchBangumi
        self.searchSource = searchSource
        self.resolveURL = resolveURL
    }

    func searchableSourceIDs(enabledSourceIDs: Set<String>) async -> [String] {
        let descriptors = await loadDescriptors()
        return descriptors.lazy
            .filter { enabledSourceIDs.contains($0.id) && $0.capabilities.contains(.search) }
            .map(\.id)
            .sorted()
    }

    func search(_ input: String, enabledSourceIDs: Set<String>, contentFilter: BrowseContentFilter = .anime) async throws -> BrowseSearchSnapshot {
        generation &+= 1
        let requestGeneration = generation
        currentSearchTask?.cancel()
        currentSearchTask = nil
        context = nil
        try Task.checkCancellation()
        let worker = Task { try await self.performSearch(input, enabledSourceIDs: enabledSourceIDs, contentFilter: contentFilter, generation: requestGeneration) }
        currentSearchTask = worker
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try ensureCurrent(requestGeneration)
            context = result
            currentSearchTask = nil
            return snapshot()
        } catch {
            if generation == requestGeneration { currentSearchTask = nil }
            if error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    func loadMore() async throws -> BrowseSearchSnapshot {
        guard let current = context else { throw BrowseSearchError.noSearchToContinue }
        guard case .keyword = current.route else { throw BrowseSearchError.noMoreResults }
        guard current.bangumiOffset != nil || current.sourcePages.values.contains(where: { $0 > 0 }) else {
            throw BrowseSearchError.noMoreResults
        }
        generation &+= 1
        let requestGeneration = generation
        currentSearchTask?.cancel()
        try Task.checkCancellation()
        let worker = Task { try await self.collectSearchPage(current, generation: requestGeneration, firstPage: false) }
        currentSearchTask = worker
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try ensureCurrent(requestGeneration)
            context = result
            currentSearchTask = nil
            return snapshot()
        } catch {
            if generation == requestGeneration { currentSearchTask = nil }
            if error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    func cancel() {
        generation &+= 1
        currentSearchTask?.cancel()
        currentSearchTask = nil
        context = nil
    }

    private func performSearch(_ input: String, enabledSourceIDs: Set<String>, contentFilter: BrowseContentFilter, generation requestGeneration: UInt64) async throws -> SearchContext {
        try Task.checkCancellation()
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw BrowseSearchError.emptyQuery }
        let components = URLComponents(string: query)
        if let subjectID = Self.bangumiSubjectID(components) {
            try ensureCurrent(requestGeneration)
            return SearchContext(query: query, sourceIDs: enabledSourceIDs, contentFilter: contentFilter, page: 0, descriptors: [],
                                 route: .bangumi(subjectID), sourceOutcomes: [:], sourcePages: [:],
                                 bangumiOffset: nil, bangumiSubjects: [])
        }
        if let scheme = components?.scheme, !scheme.isEmpty {
            let selection = try await resolveURL(query)
            try ensureCurrent(requestGeneration)
            return SearchContext(query: query, sourceIDs: enabledSourceIDs, contentFilter: contentFilter, page: 0, descriptors: [],
                                 route: .url(selection), sourceOutcomes: [:], sourcePages: [:],
                                 bangumiOffset: nil, bangumiSubjects: [])
        }
        let descriptors = contentFilter == .anime ? [] : await loadDescriptors()
        try ensureCurrent(requestGeneration)
        let selected = descriptors.filter { enabledSourceIDs.contains($0.id) && $0.capabilities.contains(.search) }
        let initial = SearchContext(query: query, sourceIDs: enabledSourceIDs, contentFilter: contentFilter, page: 0, descriptors: selected,
                                    route: .keyword(.empty(nextOffset: nil)), sourceOutcomes: [:],
                                    sourcePages: [:], bangumiOffset: nil, bangumiSubjects: [])
        return try await collectSearchPage(initial, generation: requestGeneration, firstPage: true)
    }


    private func collectSearchPage(_ input: SearchContext, generation requestGeneration: UInt64,
                                   firstPage: Bool) async throws -> SearchContext {
        let query = input.query
        let pageSize = self.pageSize
        let bangumiSearch = self.searchBangumi
        let sourceSearch = self.searchSource
        let descriptors = input.descriptors
        let sourcePages = input.sourcePages
        let bangumiOffset = input.bangumiOffset

        let received = await withTaskGroup(of: SearchPageResult.self, returning: [SearchPageResult].self) { group in
            if input.contentFilter == .anime, let offset = bangumiOffset {
                group.addTask {
                    do {
                        let page = try await bangumiSearch(query, pageSize, offset)
                        try Task.checkCancellation()
                        let next = page.data.isEmpty || offset + page.data.count >= page.total ? nil : offset + page.limit
                        return .bangumi(.success(page.data, nextOffset: next))
                    } catch { return Self.pageFailure(error) }
                }
            } else if firstPage, input.contentFilter == .anime {
                group.addTask {
                    do {
                        let page = try await bangumiSearch(query, pageSize, 0)
                        try Task.checkCancellation()
                        let next = page.data.isEmpty || page.data.count >= page.total ? nil : page.limit
                        return .bangumi(.success(page.data, nextOffset: next))
                    } catch { return Self.pageFailure(error) }
                }
            }

            for descriptor in descriptors {
                let sourceID = descriptor.id
                let page = sourcePages[sourceID] ?? 1
                guard page > 0 else { continue }
                group.addTask {
                    do {
                        let result = try await sourceSearch(sourceID, query, page)
                        try Task.checkCancellation()
                        return .source(sourceID, .success(result))
                    } catch { return Self.pageFailure(error, sourceID: sourceID) }
                }
            }

            var values: [SearchPageResult] = []
            for await result in group { values.append(result) }
            return values
        }

        try ensureCurrent(requestGeneration)
        var current = input
        current.page += 1
        for result in received {
            switch result {
            case .cancelled:
                throw CancellationError()
            case .bangumi(.success(let subjects, let nextOffset)):
                var identities = Set(current.bangumiSubjects.map(\.id))
                for subject in subjects where current.contentFilter.includes(subject.classification.kind) && identities.insert(subject.id).inserted {
                    current.bangumiSubjects.append(subject)
                }
                current.bangumiOffset = nextOffset
                current.route = .keyword(current.bangumiSubjects.isEmpty
                    ? .empty(nextOffset: nextOffset)
                    : .results(current.bangumiSubjects, nextOffset: nextOffset))
            case .bangumi(.failure(let message)):
                current.bangumiOffset = nil
                current.route = .keyword(.failure(message, previousResults: current.bangumiSubjects))
            case .source(let sourceID, .success(let page)):
                var accumulated = Self.results(in: current.sourceOutcomes[sourceID])
                var identities = Set(accumulated.map(\.item))
                accumulated.append(contentsOf: page.results.filter { current.contentFilter.includes($0.classification.kind) && identities.insert($0.item).inserted })
                current.sourceOutcomes[sourceID] = accumulated.isEmpty
                    ? .empty(nextPage: page.nextPage)
                    : .results(accumulated, nextPage: page.nextPage)
                current.sourcePages[sourceID] = page.nextPage ?? 0
            case .source(let sourceID, .failure(let message)):
                let previousResults = Self.results(in: current.sourceOutcomes[sourceID])
                current.sourceOutcomes[sourceID] = .failure(message, previousResults: previousResults)
                current.sourcePages[sourceID] = 0
            }
        }
        return current
    }

    private func snapshot() -> BrowseSearchSnapshot {
        guard let context else { preconditionFailure("Search context must exist") }
        return BrowseSearchSnapshot(query: context.query, enabledSourceIDs: context.sourceIDs,
                                    contentFilter: context.contentFilter, page: context.page,
                                    route: context.route, sources: context.sourceOutcomes)
    }

    private func ensureCurrent(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw CancellationError() }
    }

    private static func results(in outcome: SourceSearchOutcome?) -> [SourceSearchResult] {
        guard case .results(let results, _) = outcome else { return [] }
        return results
    }

    static func bangumiSubjectID(_ components: URLComponents?) -> Int? {
        guard let components,
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              host == "bangumi.tv" || host == "bgm.tv" || host == "chii.in" else { return nil }
        let path = components.percentEncodedPath
        guard path.hasPrefix("/subject/") else { return nil }
        var digits = path.dropFirst("/subject/".count)
        if digits.last == "/" { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let id = Int(digits), id > 0 else { return nil }
        return id
    }

    private static func failureMessage(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(localized: "Search failed.")
    }

    private static func pageFailure(_ error: Error) -> SearchPageResult {
        if error is CancellationError { return .cancelled }
        return .bangumi(.failure(failureMessage(error)))
    }

    private static func pageFailure(_ error: Error, sourceID: String) -> SearchPageResult {
        if error is CancellationError { return .cancelled }
        return .source(sourceID, .failure(failureMessage(error)))
    }

    private enum SearchPageResult: Sendable {
        enum Bangumi: Sendable {
            case success([BangumiSubject], nextOffset: Int?)
            case failure(String)
        }
        enum Source: Sendable {
            case success(SourceSearchPage)
            case failure(String)
        }
        case bangumi(Bangumi)
        case source(String, Source)
        case cancelled
    }
}

enum BrowseSearchError: Error, Sendable {
    case emptyQuery
    case noSearchToContinue
    case noMoreResults
}
