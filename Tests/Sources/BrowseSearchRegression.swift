import Foundation
@testable import IINA_ANI

@main
enum BrowseSearchRegression {
    static func main() async throws {
        try await urlRouteSkipsBangumiAndSourceSearch()
        try await bangumiSubjectURLsRouteWithoutMediaOrKeywordWork()
        try await subjectURLBoundariesPreserveMediaRouting()
        try await sourceMenuListsOnlyEnabledSearchableSources()
        try await filtersAndPaginationStayBoundToQuery()
        try await staleSearchAndExplicitCancellationAreRejected()
        try await paginationDeduplicatesStableResultsAndKeepsPartialResults()
        try await failedGroupsRetainPriorResultsWhileOtherSourcesPaginate()
        try await cancellationStopsTransportWork()
        try await contentFiltersPreserveRemoteCursorsAndClassification()
        try await changingContentFilterRejectsOlderResponses()
        print("Browse search regressions passed")
    }

    private static func urlRouteSkipsBangumiAndSourceSearch() async throws {
        let calls = SearchCalls()
        let selection = PlayableSelection(item: SourceItemRef(sourceID: "site", pageURL: "https://site.test/v/1", kind: .video))
        let service = makeService(
            calls: calls,
            descriptors: { [] },
            bangumi: { _, _, _ in throw Failure.assertion("URL route must not search Bangumi") },
            source: { _, _, _ in throw Failure.assertion("URL route must not search sources") },
            resolver: { input in
                await calls.recordURL(input)
                return selection
            }
        )

        for filter in BrowseContentFilter.allCases {
            let result = try await service.search("  https://site.test/v/1  ", enabledSourceIDs: ["disabled"], contentFilter: filter)
            guard case .url(let resolved) = result.route else { throw Failure.assertion("URL must route directly in every category") }
            try require(resolved == selection && result.contentFilter == filter, "URL must preserve selection rather than apply keyword category")
            try require(result.sources.isEmpty, "URL route has no keyword result groups")
        }
        let urlInputs = await calls.urlInputs
        try require(urlInputs == Array(repeating: "https://site.test/v/1", count: 3), "URL is trimmed and independently resolved in all categories")
    }

    private static func bangumiSubjectURLsRouteWithoutMediaOrKeywordWork() async throws {
        let calls = SearchCalls()
        let service = makeService(descriptors: {
            await calls.recordDescriptors()
            return [descriptor("site")]
        }, bangumi: { _, _, _ in
            throw Failure.assertion("subject URL must not search Bangumi")
        }, source: { _, _, _ in
            throw Failure.assertion("subject URL must not search sources")
        }, resolver: { input in
            await calls.recordURL(input)
            throw Failure.assertion("subject URL must not invoke the media decoder")
        })
        let suffixes = ["", "/", "?from=search", "#episodes", "/?from=search#episodes"]
        for filter in BrowseContentFilter.allCases {
        for host in ["bangumi.tv", "bgm.tv", "chii.in"] {
            for scheme in ["http", "https"] {
                for suffix in suffixes {
                    let url = "\(scheme)://\(host)/subject/390200\(suffix)"
                    let result = try await service.search("  \(url)  ", enabledSourceIDs: ["site"], contentFilter: filter)
                    guard case .bangumi(390200) = result.route else {
                        throw Failure.assertion("supported subject URL must route to its subject ID: \(url)")
                    }
                    try require(result.query == url && result.enabledSourceIDs == ["site"], "subject routing must retain normalized query/filter")
                    try require(result.sources.isEmpty, "subject routing must not create source result groups")
                    do {
                        _ = try await service.loadMore()
                        throw Failure.assertion("subject URL must not paginate")
                    } catch BrowseSearchError.noMoreResults {}
                }
            }
        }
        }
        let uppercased = try await service.search("HTTPS://BGM.TV/subject/0001/", enabledSourceIDs: [])
        guard case .bangumi(1) = uppercased.route else {
            throw Failure.assertion("URL scheme/host are case-insensitive and positive IDs may have leading zeroes")
        }
        let descriptorLoads = await calls.descriptorLoads
        let mediaInputs = await calls.urlInputs
        try require(descriptorLoads == 0 && mediaInputs.isEmpty, "pure subject routing must not depend on the source registry or decoder")
    }

    private static func subjectURLBoundariesPreserveMediaRouting() async throws {
        let calls = SearchCalls()
        let selection = PlayableSelection(item: SourceItemRef(sourceID: "site", pageURL: "https://site.test/v/1", kind: .video))
        let service = makeService(descriptors: { [] }, bangumi: { _, _, _ in
            throw Failure.assertion("non-subject URL must not use keyword search")
        }, source: { _, _, _ in
            throw Failure.assertion("non-subject URL must not search sources")
        }, resolver: { input in
            await calls.recordURL(input)
            return selection
        })
        let urls = [
            "https://bangumi.tv.evil.test/subject/1",
            "https://www.bangumi.tv/subject/1",
            "https://notbangumi.tv/subject/1",
            "https://bangumi.tv@evil.test/subject/1",
            "https://bangumi.tv/subject/",
            "https://bangumi.tv/subject/0",
            "https://bangumi.tv/subject/-1",
            "https://bangumi.tv/subject/+1",
            "https://bangumi.tv/subject/1.0",
            "https://bangumi.tv/subject/999999999999999999999999999999",
            "https://bangumi.tv/subject/1/episodes",
            "https://bangumi.tv/subject/1//",
            "https://bangumi.tv/subjects/1",
            "https://bangumi.tv/subject/%31",
            "https://bangumi.tv/subject/1%2F",
            "ftp://bangumi.tv/subject/1",
            "https://site.test/v/1",
            "http://site.test/v/1",
            "iina://open?url=https://site.test/v/1"
        ]
        for url in urls {
            let result = try await service.search(url, enabledSourceIDs: [])
            guard case .url(let resolved) = result.route, resolved == selection else {
                throw Failure.assertion("unsupported subject URL must retain independent media resolution: \(url)")
            }
        }
        let mediaInputs = await calls.urlInputs
        try require(mediaInputs == urls, "invalid subject URLs and existing media URLs must reach the decoder unchanged")
    }

    private static func sourceMenuListsOnlyEnabledSearchableSources() async throws {
        let calls = SearchCalls()
        let service = makeService(descriptors: {
            await calls.recordDescriptors()
            return [descriptor("zulu"), descriptor("disabled"), descriptor("unsupported", searchable: false), descriptor("alpha")]
        }, bangumi: { _, _, _ in throw Failure.assertion("source menu must not search Bangumi") },
        source: { _, _, _ in throw Failure.assertion("source menu must not search sources") })
        let ids = await service.searchableSourceIDs(enabledSourceIDs: ["zulu", "alpha", "unsupported", "missing"])
        try require(ids == ["alpha", "zulu"], "source menu must be sorted and exclude disabled, unknown and non-searchable sources")
        let descriptorLoads = await calls.descriptorLoads
        try require(descriptorLoads == 1, "source menu must use the current descriptor registry")
    }

    private static func filtersAndPaginationStayBoundToQuery() async throws {
        for contentFilter in BrowseContentFilter.allCases {
            let calls = SearchCalls()
            let service = makeService(descriptors: {
                await calls.recordDescriptors()
                return [descriptor("capable"), descriptor("disabled"), descriptor("unsupported", searchable: false)]
            }, bangumi: { query, limit, offset in
                await calls.recordBangumi(query, limit, offset)
                return BangumiPage(data: [subject(offset + 1)], total: 2, limit: 1, offset: offset)
            }, source: { sourceID, query, page in
                await calls.recordSource(sourceID, query, page)
                if page == 1 { return SourceSearchPage(results: [], nextPage: 2) }
                throw Failure.remote
            })
            let enabled: Set<String> = ["capable", "unsupported"]
            let first = try await service.search("  words  ", enabledSourceIDs: enabled, contentFilter: contentFilter)
            try require(first.query == "words" && first.enabledSourceIDs == enabled && first.contentFilter == contentFilter, "snapshot must preserve normalized query, sources and category")
            let next = try await service.loadMore()
            try require(next.query == first.query && next.enabledSourceIDs == enabled && next.contentFilter == contentFilter, "pagination must retain the complete query context")
            let sourceCalls = await calls.sourceInputs
            let bangumiCalls = await calls.bangumiInputs
            let descriptorLoads = await calls.descriptorLoads
            if contentFilter == .anime {
                guard case .keyword(.results(let values, nextOffset: nil)) = next.route else { throw Failure.assertion("anime pagination must exhaust Bangumi") }
                try require(values.map(\.id) == [1, 2] && first.sources.isEmpty && next.sources.isEmpty, "anime must retain only Bangumi results")
                try require(sourceCalls.isEmpty && descriptorLoads == 0, "anime keywords must not access source registry or playback searches")
                try require(bangumiCalls.count == 2 && bangumiCalls[0].0 == "words" && bangumiCalls[0].2 == 0 && bangumiCalls[1].0 == "words" && bangumiCalls[1].2 == 1, "Bangumi cursor and keyword must remain bound")
            } else {
                guard case .keyword(.empty(nextOffset: nil)) = first.route,
                      case .keyword(.empty(nextOffset: nil)) = next.route,
                      case .empty(nextPage: 2)? = first.sources["capable"],
                      case .failure? = next.sources["capable"] else { throw Failure.assertion("source-only search preserves empty cursors and failures") }
                try require(first.sources.count == 1 && bangumiCalls.isEmpty && descriptorLoads == 1, "video/live must search only enabled searchable sources, never Bangumi")
                try require(sourceCalls.count == 2 && sourceCalls.allSatisfy { $0.0 == "capable" && $0.1 == "words" } && sourceCalls.map { $0.2 } == [1, 2], "source pagination must retain keyword and advance its own cursor")
            }
        }
    }
    private static func paginationDeduplicatesStableResultsAndKeepsPartialResults() async throws {
        for contentFilter in BrowseContentFilter.allCases {
            let firstItem = SourceItemRef(sourceID: "site", pageURL: "https://site.test/v/1", kind: contentFilter == .live ? .live : .video)
            let secondItem = SourceItemRef(sourceID: "site", pageURL: "https://site.test/v/2", kind: firstItem.kind)
            let classification = MediaClassification(kind: contentFilter == .live ? .live : .video, provenance: "fixture type")
            let service = makeService(descriptors: { [descriptor("site")] }, bangumi: { _, _, offset in
                switch offset {
                case 0: return BangumiPage(data: [subject(1), subject(1)], total: 5, limit: 2, offset: 0)
                case 2: return BangumiPage(data: [subject(1), subject(2)], total: 5, limit: 2, offset: 2)
                default: throw Failure.remote
                }
            }, source: { _, _, page in
                if page > 2 { throw Failure.remote }
                let first = SourceSearchResult(item: firstItem, title: "same title", cover: "", classification: classification)
                let second = SourceSearchResult(item: secondItem, title: "same title", cover: "", classification: classification)
                return SourceSearchPage(results: page == 1 ? [first, first] : [first, second], nextPage: page + 1)
            })
            let initial = try await service.search("word", enabledSourceIDs: ["site"], contentFilter: contentFilter)
            let second = try await service.loadMore()
            let failed = try await service.loadMore()
            if contentFilter == .anime {
                guard case .keyword(.results(let first, nextOffset: 2)) = initial.route,
                      case .keyword(.results(let values, nextOffset: 4)) = second.route,
                      case .keyword(.failure(_, let previous)) = failed.route else { throw Failure.assertion("Bangumi must preserve remote cursors and failure state") }
                try require(first.map(\.id) == [1] && values.map(\.id) == [1, 2] && previous.map(\.id) == [1, 2], "Bangumi overlap and failures must preserve stable deduplicated identities")
            } else {
                guard case .results(let first, nextPage: 2)? = initial.sources["site"],
                      case .results(let values, nextPage: 3)? = second.sources["site"],
                      case .failure(_, let previous)? = failed.sources["site"] else { throw Failure.assertion("source must preserve remote cursors and failure state") }
                try require(first.map(\.item) == [firstItem] && values.map(\.item) == [firstItem, secondItem] && previous.map(\.item) == [firstItem, secondItem], "source overlap and failures must preserve stable deduplicated identities")
            }
            do { _ = try await service.loadMore(); throw Failure.assertion("failed cursors must not continue") }
            catch BrowseSearchError.noMoreResults {}
            let fresh = try await service.search("replacement", enabledSourceIDs: [])
            try require(fresh.sources.isEmpty && fresh.contentFilter == .anime, "replacement without category must default to anime and discard source groups")
        }
        let unavailable = makeService(descriptors: { [] }, bangumi: { _, _, _ in throw Failure.remote }, source: { _, _, _ in throw Failure.remote })
        let firstFailure = try await unavailable.search("offline", enabledSourceIDs: [])
        guard case .keyword(.failure(_, let empty)) = firstFailure.route, empty.isEmpty else { throw Failure.assertion("first-page failure must differ from successful empty results") }
    }

    private static func failedGroupsRetainPriorResultsWhileOtherSourcesPaginate() async throws {
        let calls = SearchCalls()
        let failedItem = SourceItemRef(sourceID: "failed", pageURL: "https://failed.test/v/1", kind: .video)
        let activeItem = SourceItemRef(sourceID: "active", pageURL: "https://active.test/v/1", kind: .video)
        let laterItem = SourceItemRef(sourceID: "active", pageURL: "https://active.test/v/2", kind: .video)
        let service = makeService(descriptors: { [descriptor("failed"), descriptor("active")] }, bangumi: { _, _, _ in
            throw Failure.assertion("source-only pagination must never search Bangumi")
        }, source: { id, query, page in
            await calls.recordSource(id, query, page)
            if id == "failed" {
                guard page == 1 else { throw Failure.remote }
                return SourceSearchPage(results: [SourceSearchResult(item: failedItem, title: "failed source result", cover: "", classification: MediaClassification(kind: .video, provenance: "fixture"))], nextPage: 2)
            }
            switch page {
            case 1:
                return SourceSearchPage(results: [SourceSearchResult(item: activeItem, title: "active source result", cover: "", classification: MediaClassification(kind: .video, provenance: "fixture"))], nextPage: 2)
            case 2:
                return SourceSearchPage(results: [], nextPage: 3)
            default:
                return SourceSearchPage(results: [SourceSearchResult(item: laterItem, title: "later result", cover: "", classification: MediaClassification(kind: .video, provenance: "fixture"))], nextPage: nil)
            }
        })
        _ = try await service.search("word", enabledSourceIDs: ["failed", "active"], contentFilter: .video)
        let failed = try await service.loadMore()
        let continued = try await service.loadMore()
        for snapshot in [failed, continued] {
            guard case .keyword(.empty(nextOffset: nil)) = snapshot.route,
                  case .failure(_, let sources)? = snapshot.sources["failed"] else {
                throw Failure.assertion("failed groups must retain their error state while another source paginates")
            }
            try require(sources.map(\.item) == [failedItem], "failed groups must preserve prior results across unrelated pagination")
        }
        guard case .results(let sources, nextPage: nil)? = continued.sources["active"] else {
            throw Failure.assertion("remaining source must continue through its empty page")
        }
        try require(sources.map(\.item) == [activeItem, laterItem], "an empty intermediate page must not discard accumulated results")
        let sourceInputs = await calls.sourceInputs
        let bangumiInputs = await calls.bangumiInputs
        try require(sourceInputs.filter { $0.0 == "failed" }.count == 2 && sourceInputs.filter { $0.0 == "active" }.count == 3 && bangumiInputs.isEmpty, "failed groups must not restart while another source paginates")
    }

    private static func staleSearchAndExplicitCancellationAreRejected() async throws {
        let gate = SearchGate()
        let service = makeService(descriptors: { [descriptor("capable")] }, bangumi: { query, _, _ in
            if query == "old" { try await gate.pause() }
            return BangumiPage(data: [], total: 0, limit: 20, offset: 0)
        }, source: { sourceID, query, _ in
            if query == "old" { try await gate.pause() }
            return SourceSearchPage(results: [], nextPage: nil)
        })

        let stale = Task { try await service.search("old", enabledSourceIDs: ["capable"]) }
        await gate.waitUntilPaused(1)
        _ = try await service.search("new", enabledSourceIDs: [])
        await gate.resumeAll()
        do {
            _ = try await stale.value
            throw Failure.assertion("a superseded query must not publish stale results")
        } catch is CancellationError { }

        let cancelGate = SearchGate()
        let cancellable = makeService(descriptors: { [descriptor("capable")] }, bangumi: { query, _, _ in
            try await cancelGate.pause()
            return BangumiPage(data: [], total: 0, limit: 20, offset: 0)
        }, source: { _, _, _ in SourceSearchPage(results: [], nextPage: nil) })
        let pending = Task { try await cancellable.search("cancel", enabledSourceIDs: []) }
        await cancelGate.waitUntilPaused(1)
        await cancellable.cancel()
        await cancelGate.resumeAll()
        do {
            _ = try await pending.value
            throw Failure.assertion("explicit service cancellation must reject late closure results")
        } catch is CancellationError { }
    }

    private static func cancellationStopsTransportWork() async throws {
        let probe = CancellationProbe()
        let service = makeService(descriptors: { [] }, bangumi: { _, _, _ in
            await probe.started()
            do { try await Task.sleep(for: .seconds(2)) }
            catch { await probe.cancelled(); throw error }
            return BangumiPage(data: [], total: 0, limit: 1, offset: 0)
        }, source: { _, _, _ in SourceSearchPage(results: [], nextPage: nil) })
        let pending = Task { try await service.search("transport", enabledSourceIDs: []) }
        while !(await probe.didStart) { await Task.yield() }
        await service.cancel()
        for _ in 0..<100 {
            if await probe.didCancel { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let stopped = await probe.didCancel
        pending.cancel()
        do { _ = try await pending.value } catch is CancellationError {}
        try require(stopped, "service cancellation must stop the underlying transport task, not only hide its result")
    }

    private actor CancellationProbe {
        private(set) var didStart = false
        private(set) var didCancel = false
        func started() { didStart = true }
        func cancelled() { didCancel = true }
    }
    private static func contentFiltersPreserveRemoteCursorsAndClassification() async throws {
        try require(BrowseContentFilter.allCases.map(\.rawValue) == ["anime", "video", "live"], "search exposes only anime/video/live in default order")
        try require(BrowseContentFilter.allCases.map(\.title) == ["番劇", "視頻", "直播"], "category labels must match the search contract")
        for obsolete in ["", "all", "nonAnime", "unknown", "invalid"] {
            try require((BrowseContentFilter(rawValue: obsolete) ?? .anime) == .anime, "removed or missing persisted categories restore to anime")
        }
        let expected: [(BrowseContentFilter, Set<MediaContentKind>)] = [(.anime, [.anime]), (.video, [.video]), (.live, [.live])]
        for (filter, kinds) in expected {
            try require(Set(MediaContentKind.allCases.filter { filter.includes($0) }) == kinds, "partitions must reject unknown and other kinds")
            let calls = SearchCalls()
            let service = makeService(descriptors: { [descriptor("mixed")] }, bangumi: { query, limit, offset in
                await calls.recordBangumi(query, limit, offset)
                let value = BangumiSubject(id: offset + 1, name: "same title", type: offset == 0 ? 6 : 2)
                return BangumiPage(data: [value], total: 2, limit: 1, offset: offset)
            }, source: { id, query, page in
                await calls.recordSource(id, query, page)
                let kind: MediaContentKind = page == 1 ? .anime : (filter == .live ? .live : .video)
                return SourceSearchPage(results: [SourceSearchResult(
                    item: SourceItemRef(sourceID: id, pageURL: "https://mixed.test/\(page)", kind: .video),
                    title: "same title", cover: "", classification: MediaClassification(kind: kind, provenance: "fixture content type"))], nextPage: page == 1 ? 2 : nil)
            })
            let first = try await service.search("same title", enabledSourceIDs: ["mixed"], contentFilter: filter)
            let second = try await service.loadMore()
            try require(second.query == first.query && second.contentFilter == filter && second.page == 2, "filtered empty pages retain complete pagination context")
            if filter == .anime {
                guard case .keyword(.empty(nextOffset: 1)) = first.route,
                      case .keyword(.results(let values, nextOffset: nil)) = second.route else { throw Failure.assertion("filtered Bangumi pages must retain remote offset") }
                try require(values.count == 1 && values[0].classification.kind == .anime && second.sources.isEmpty, "Bangumi live action subjects must not leak into anime")
            } else {
                guard case .keyword(.empty(nextOffset: nil)) = second.route,
                      case .empty(nextPage: 2)? = first.sources["mixed"],
                      case .results(let values, nextPage: nil)? = second.sources["mixed"] else { throw Failure.assertion("filtered source pages must retain remote cursor without Bangumi") }
                try require(values.count == 1 && values[0].classification.kind == (filter == .live ? .live : .video) && values[0].classification.provenance == "fixture content type", "titles and hosts cannot override concrete content classification")
            }
            let bangumiInputs = await calls.bangumiInputs
            let sourceInputs = await calls.sourceInputs
            try require(filter == .anime ? sourceInputs.isEmpty && bangumiInputs.count == 2 : bangumiInputs.isEmpty && sourceInputs.count == 2, "all pagination must stay within the selected provider partition")
        }
    }

    private static func changingContentFilterRejectsOlderResponses() async throws {
        for oldFilter in BrowseContentFilter.allCases {
            let gate = SearchGate()
            let service = makeService(descriptors: { [descriptor("site")] }, bangumi: { _, _, _ in
                if oldFilter == .anime { try await gate.pause() }
                return BangumiPage(data: [subject(1)], total: 1, limit: 1, offset: 0)
            }, source: { _, _, _ in
                try await gate.pause()
                return SourceSearchPage(results: [], nextPage: nil)
            })
            let pending = Task { try await service.search("same", enabledSourceIDs: ["site"], contentFilter: oldFilter) }
            await gate.waitUntilPaused(1)
            let newFilter: BrowseContentFilter = oldFilter == .anime ? .live : .anime
            let replacement = try await service.search("same", enabledSourceIDs: [], contentFilter: newFilter)
            await gate.resumeAll()
            do { _ = try await pending.value; throw Failure.assertion("old category response must be cancelled") }
            catch is CancellationError {}
            try require(replacement.contentFilter == newFilter, "same-query replacement retains new category")
        }
    }


    private static func makeService(
        calls: SearchCalls = SearchCalls(),
        descriptors: @escaping BrowseSearchService.DescriptorLoader,
        bangumi: @escaping BrowseSearchService.BangumiSearcher,
        source: @escaping BrowseSearchService.SourceSearcher,
        resolver: @escaping BrowseSearchService.URLResolver = { _ in throw Failure.unexpectedURL }
    ) -> BrowseSearchService {
        BrowseSearchService(pageSize: 1, loadDescriptors: descriptors, searchBangumi: bangumi,
                            searchSource: source, resolveURL: resolver)
    }

    private static func descriptor(_ id: String, searchable: Bool = true) -> SourceDescriptor {
        SourceDescriptor(id: id, name: id, version: 1, capabilities: searchable ? [.search] : [])
    }

    private static func subject(_ id: Int) -> BangumiSubject {
        BangumiSubject(id: id, name: "subject-\(id)", type: 2)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }

    private actor SearchCalls {
        private(set) var descriptorLoads = 0
        private(set) var urlInputs: [String] = []
        private(set) var sourceInputs: [(String, String, Int)] = []
        private(set) var bangumiInputs: [(String, Int, Int)] = []

        func recordDescriptors() { descriptorLoads += 1 }
        func recordURL(_ input: String) { urlInputs.append(input) }
        func recordSource(_ id: String, _ query: String, _ page: Int) { sourceInputs.append((id, query, page)) }
        func recordBangumi(_ query: String, _ limit: Int, _ offset: Int) { bangumiInputs.append((query, limit, offset)) }
    }

    private actor SearchGate {
        private var pausedCount = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        
        private var resumed = false

        func pause() async throws {
            pausedCount += 1
            await withCheckedContinuation { continuation in
                if resumed { continuation.resume() }
                else { waiters.append(continuation) }
            }
            try Task.checkCancellation()
        }

        func waitUntilPaused(_ count: Int) async {
            while pausedCount < count { await Task.yield() }
            return
        }

        func resumeAll() {
            resumed = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            
            
        }
    }

    private enum Failure: Error {
        case assertion(String)
        case remote
        case unexpectedURL
    }
}
