import CoreData
import Foundation
@testable import IINA_ANI

@main
@MainActor
struct AnimeSourceRegression {
    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    actor Calls {
        var searches = 0, catalogs = 0, decodes = 0, prepares = 0
        var active = 0, peak = 0
        var guest = true
        func search() { searches += 1; active += 1; peak = max(peak, active) }
        func finish() { active -= 1 }
        func catalog(_ choice: PlayableSelection) { catalogs += 1; guest = guest && choice.accountID == nil }
        func decode(_ choice: PlayableSelection) { decodes += 1; guest = guest && choice.accountID == nil }
        func prepare(_ json: YouGetJSON) { prepares += 1; guest = guest && json.selection != nil && json.selection?.accountID == nil }
        func snapshot() -> (searches: Int, catalogs: Int, decodes: Int, prepares: Int, active: Int, peak: Int, guest: Bool) {
            (searches, catalogs, decodes, prepares, active, peak, guest)
        }
    }
    final class Authority: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = true
        private var revision = "native-fixture:mapping-v1"
        let configured: Bool
        init(configured: Bool = false) { self.configured = configured }
        func setEnabled(_ value: Bool) { lock.lock(); defer { lock.unlock() }; enabled = value }
        func setRevision(_ value: String) { lock.lock(); defer { lock.unlock() }; revision = value }
        func isEnabled() -> Bool { lock.lock(); defer { lock.unlock() }; return enabled }
        func currentRevision() throws -> String {
            lock.lock(); defer { lock.unlock() }
            guard enabled else { throw PlaybackFailure.sourceDisabled }
            return revision
        }
        func mapping(_ selection: PlayableSelection) throws -> (selection: PlayableSelection, revision: String, configured: Bool) {
            let revision = try currentRevision()
            guard let episode = selection.episode ?? (selection.item.kind == .episode ? selection.item : nil),
                  episode.kind == .episode, episode.sourceID == selection.item.sourceID,
                  selection.torrent == nil else { throw PlaybackFailure.missingEpisode }
            var safe = selection
            safe.accountID = nil
            return (safe, revision, configured)
        }
    }

    nonisolated static let anime = MediaClassification(kind: .anime, provenance: "fixture.source.anime")
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
    static func source(_ id: String) -> SourceDescriptor {
        SourceDescriptor(id: id, name: id, version: 1, capabilities: [.search, .resolve, .episodes, .iina])
    }
    nonisolated static func ref(_ id: String = "a", _ page: String = "one", kind: SourceItemRef.Kind = .work) -> SourceItemRef {
        SourceItemRef(sourceID: id, pageURL: "https://\(id).invalid/\(kind.rawValue)/\(page)", kind: kind)
    }
    static func hit(_ title: String, _ id: String = "a", _ page: String = "one", classification: MediaClassification = anime) -> SourceSearchResult {
        SourceSearchResult(item: ref(id, page), title: title, cover: "", classification: classification)
    }
    static func leaf(_ title: String, _ id: String = "a", _ page: String = "one", index: Int = 999) -> VideoTreeNode {
        VideoTreeNode(site: .configured(id), index: index, title: title, id: page,
                      url: ref(id, page, kind: .episode).pageURL)
    }
    static func work(_ title: String = "Sample 第2季", platform: String = "TV", year: Int = 2026) -> Work {
        let subject = BangumiSubject(id: 7, name: title, date: "\(year)-01-01", type: 2, platform: platform)
        return Work(title: title, year: year,
                    bangumiMetadata: BangumiMetadata(subject: subject, episodes: [], fetchedAt: .now), classification: anime)
    }
    static func episode(_ work: Work, kind: Episode.Kind = .main, sort: Double = 1, label: String = "第一集") -> Episode {
        Episode(workID: work.id, kind: kind, label: label, sort: sort)
    }
    static func numberedWork(_ title: String, rows: [(Int, Double, Double, String)]) throws -> Work {
        let payload = rows.map { id, sort, ep, name -> [String: Any] in
            ["id": id, "type": 0, "sort": sort, "ep": ep, "name": name, "name_cn": name]
        }
        let episodes = try JSONDecoder().decode([BangumiEpisode].self, from: JSONSerialization.data(withJSONObject: payload))
        let subject = BangumiSubject(id: 568244, name: title, date: "2026-10-02", type: 2, platform: "TV")
        return Work(title: title, year: 2026, bangumiMetadata: .init(subject: subject, episodes: episodes, fetchedAt: .now), classification: anime)
    }
    static func numberedEpisode(_ work: Work, id: Int, sort: Double) -> Episode {
        Episode(workID: work.id, externalID: "bangumi:\(id)", kind: .main, label: "selected", sort: sort)
    }

    static func dependencies(hits: [SourceSearchResult], nodes: [VideoTreeNode], calls: Calls = Calls(),
                             delay: UInt64 = 0, failSource: String? = nil, requiredQuery: String? = nil,
                             media: String? = "https://media.invalid/actual.mp4",
                             authority: Authority = Authority()) -> AnimeSourceService.Dependencies {
        let ids = Set(hits.map { $0.item.sourceID }).union(failSource.map { [$0] } ?? [])
        let descriptors = ids.sorted().map(source)
        return AnimeSourceService.Dependencies(descriptors: { descriptors }, enabled: { _ in authority.isEnabled() }, search: { id, query in
            await calls.search()
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                try Task.checkCancellation()
                await calls.finish()
                if id == failSource { throw Failure("Fixture failure must not leak URLs") }
                let results = requiredQuery == nil || requiredQuery == query ? hits.filter { $0.item.sourceID == id } : []
                return SourceSearchPage(results: results, nextPage: 2)
            } catch {
                if Task.isCancelled || error is CancellationError { await calls.finish(); throw CancellationError() }
                throw error
            }
        }, selection: { raw in
            let url = URL(string: raw)!
            let id = String(url.host!.split(separator: ".")[0])
            return PlayableSelection(item: SourceItemRef(sourceID: id, pageURL: raw,
                kind: url.path.hasPrefix("/episode/") ? .episode : .work), accountID: UUID(), classification: anime)
        }, catalog: { choice in
            await calls.catalog(choice)
            return VideoSelectionCatalog(nodes: nodes, current: 999, selection: choice)
        }, decode: { choice in
            await calls.decode(choice)
            var json = YouGetJSON(rawUrl: choice.item.pageURL)
            json.streams = ["HD": Stream(url: "")]
            json.selection = choice
            return json
        }, prepare: { json, key in
            await calls.prepare(json)
            var json = json
            if let media { json.streams[key]?.url = media }
            json.selection?.qualityID = key
            return json
        }, mappingSelection: { try authority.mapping($0) }, mappingRevision: { _ in try authority.currentRevision() })
    }

    static func main() async throws {
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else { throw Failure("Missing model") }
        let container = NSPersistentContainer(name: "DataModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription(); description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let library = WorkLibrary(container: container)
        let target = work(), selected = episode(target)
        try library.upsert(target); try library.upsert(selected)
        let calls = Calls()
        let exactNodes = [VideoTreeNode(title: "line A", children: [leaf("SP1", "a", "sp"), leaf("第01集", "a", "actual"), leaf("02", "a", "two")])]
        let unique = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: exactNodes, calls: calls))
        let report = try await unique.discover(work: target, episode: selected, links: [])
        try require(report.automaticCandidates.count == 1, "independent year/subtype plus title and exact episode can corroborate a unique work")
        let candidate = report.automaticCandidates[0]
        try require(candidate.selection?.episode?.pageURL.hasSuffix("/actual") == true, "catalog index/current/first SP cannot choose episode")
        try require(try library.sourceLinks(forWorkID: target.id).isEmpty, "discovery never persists")
        do {
            try unique.confirm(candidate, work: target, episode: selected, library: library)
            throw Failure("unresolved candidate persisted")
        } catch AnimeSourceService.SourceError.unresolved { }
        _ = try await unique.resolve(candidate)
        try unique.confirm(candidate, work: target, episode: selected, library: library)
        try unique.confirm(candidate, work: target, episode: selected, library: library)
        let stored = try library.sourceLinks(forWorkID: target.id)
        try require(stored.count == 1 && stored[0].episodeMappings.count == 1 && stored[0].episodeMappings[0].episodeID == selected.id, "confirmation upserts stable episode and link rather than appending duplicates")
        let resolvedCalls = await calls.snapshot()
        try require(stored[0].episodeMappings[0].selection.accountID == nil && resolvedCalls.guest, "inherited account IDs cannot escape guest boundaries")

        let sameTitle = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季")], nodes: exactNodes))
        let weak = try await sameTitle.discover(work: target, episode: selected, links: [])
        try require(weak.automaticCandidates.isEmpty && weak.candidates.contains { $0.selection != nil && $0.failure == nil }, "same title and episode number remain manually selectable, never trusted")
        let weakChoice = weak.candidates.first { $0.selection != nil }!
        _ = try await sameTitle.resolve(weakChoice)
        try sameTitle.confirm(weakChoice, work: target, episode: selected, library: library)
        try require(try library.sourceLinks(forWorkID: target.id).count == 1, "manual confirmation reuses existing work link")

        var preferred = stored[0].episodeMappings[0].selection
        preferred.lineID = "2"
        let preferredLink = WorkSourceLink(workID: target.id, sourceWork: stored[0].sourceWork,
            episodeMappings: [EpisodeSourceMapping(episodeID: selected.id, selection: preferred)])
        let refresh = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季")], nodes: exactNodes))
        let refreshed = try await refresh.discover(work: target, episode: selected, links: [preferredLink], forceSearch: true)
        let refreshedChoices = refreshed.candidates.compactMap(\.selection)
        try require(refreshedChoices == [preferred], "refresh deduplicates saved/search episode identity and preserves saved quality/line")

        let ambiguous = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]", "a", "one"), hit("Sample 第2季 [2026 TV]", "a", "alternate")], nodes: exactNodes))
        let ambiguousReport = try await ambiguous.discover(work: target, episode: selected, links: [])
        try require(ambiguousReport.automaticCandidates.isEmpty && ambiguousReport.candidates.filter { $0.selection != nil }.count == 2, "multiple independently plausible works require manual confirmation")
        try require(Set(ambiguousReport.matchedCandidates.map { $0.selection!.item }) == Set([ref("a", "one"), ref("a", "alternate")]), "foreground choices retain both exact episode candidates without treating ambiguous works as trusted")

        let conflicts = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第1季 [2026 TV]", "a", "season"), hit("Sample 第2季 [2025 TV]", "a", "year"), hit("Sample 第2季 [2026 Movie]", "a", "movie"), hit("Sample 第2季 [2026 TV]", "a", "video", classification: MediaClassification(kind: .video, provenance: "fixture.video"))], nodes: exactNodes))
        let blocked = try await conflicts.discover(work: target, episode: selected, links: [])
        try require(blocked.candidates.allSatisfy { $0.selection == nil && $0.failure != nil }, "wrong season/year/subtype and non-anime results are disabled, not confirmable")
        try require(blocked.matchedCandidates.isEmpty, "wrong season, year, subtype and non-anime hits never become foreground source choices")

        let splitSubject = BangumiSubject(id: 639938, name: "スティール・ボール・ラン ジョジョの奇妙な冒険 2nd & 3rd STAGE",
            nameCN: "飙马野郎 JOJO的奇妙冒险 第二&第三赛段",
            aliases: ["飙马野郎 JOJO的奇妙冒险 第2、3阶段", "SBR"], date: "2026-09-25", type: 2, platform: "WEB")
        let splitWork = Work(title: splitSubject.title, year: 2026,
            bangumiMetadata: BangumiMetadata(subject: splitSubject, episodes: [], fetchedAt: .now), classification: anime)
        let splitEpisode = episode(splitWork, sort: 2)
        let splitNodes = [VideoTreeNode(title: "line", children: [leaf("第01集", "a", "stage-one"), leaf("第02集", "a", "stage-two")])]
        for title in ["飙马野郎 JOJO的奇妙冒险", "JOJO的奇妙冒险 飙马野郎", "JOJO的奇妙冒险飙马野郎",
                      "JOJO的奇妙冒险 飙马野郎 [2026 WEB]"] {
            let service = AnimeSourceService(dependencies: dependencies(hits: [hit(title)], nodes: splitNodes))
            let report = try await service.discover(work: splitWork, episode: splitEpisode, links: [])
            try require(report.matchedCandidates.count == 1 && report.automaticCandidates.isEmpty,
                        "merged source titles with complete rotated components remain manual split-stage candidates: \(title)")
            let candidate = report.matchedCandidates[0]
            try require(candidate.selection?.episode == ref("a", "stage-two", kind: .episode),
                        "an unqualified stage candidate must select exact main episode two")
            _ = try await service.resolve(candidate)
        }
        for title in ["飙马野郎 JOJO的奇妙冒险 第一赛段", "JOJO的奇妙冒险 飙马野郎 1st STAGE",
                      "JOJO的奇妙冒险 不灭钻石", "JOJO的奇妙冒险 石之海", "JOJO的奇妙冒险",
                      "JOJO的奇妙冒险 飙马野郎 4th STAGE", "JOJO的奇妙冒险 飙马野郎 第2季",
                      "JOJO的奇妙冒险 飙马野郎 [2025 WEB]", "JOJO的奇妙冒险 飙马野郎 [2026 Movie]"] {
            let service = AnimeSourceService(dependencies: dependencies(hits: [hit(title)], nodes: splitNodes))
            let report = try await service.discover(work: splitWork, episode: splitEpisode, links: [])
            try require(report.matchedCandidates.isEmpty, "different stages, parts, incomplete components and release conflicts remain rejected: \(title)")
        }
        let numericStages = AnimeSourceService(dependencies: dependencies(hits: [hit("JOJO的奇妙冒险 飙马野郎 第2、3阶段 [2026 WEB]")], nodes: splitNodes))
        let numericStagesReport = try await numericStages.discover(work: splitWork, episode: splitEpisode, links: [])
        try require(numericStagesReport.matchedCandidates.count == 1, "equivalent explicit Chinese stage sets survive component rotation")
        let englishStages = AnimeSourceService(dependencies: dependencies(hits: [hit("スティール・ボール・ラン ジョジョの奇妙な冒険 2nd-3rd STAGE")], nodes: splitNodes))
        let englishStagesReport = try await englishStages.discover(work: splitWork, episode: splitEpisode, links: [])
        try require(englishStagesReport.matchedCandidates.count == 1, "equivalent English stage separators identify the same split work")
        let noSecond = AnimeSourceService(dependencies: dependencies(hits: [hit("JOJO的奇妙冒险 飙马野郎")], nodes: [leaf("第01集")]))
        let noSecondReport = try await noSecond.discover(work: splitWork, episode: splitEpisode, links: [])
        try require(noSecondReport.matchedCandidates.isEmpty, "relaxed work formatting never substitutes episode one for selected episode two")
        let crowdedHits = (0..<8).map { hit("JOJO的奇妙冒险 石之海 \($0)", "a", "unrelated-\($0)") } + [hit("JOJO的奇妙冒险 飙马野郎", "a", "merged") ]
        let crowded = AnimeSourceService(dependencies: dependencies(hits: crowdedHits, nodes: splitNodes))
        let crowdedReport = try await crowded.discover(work: splitWork, episode: splitEpisode, links: [])
        try require(crowdedReport.matchedCandidates.count == 1, "unrelated results cannot consume the eight plausible-work slots")

        let fuzzyWork = work("ChronicleAdventure", platform: "TV")
        for title in ["ChronicleAdventur [2026 TV]", "ChronicleAdventvre [2026 TV]", "ChronicleAdventure版 [2026 TV]"] {
            let service = AnimeSourceService(dependencies: dependencies(hits: [hit(title)], nodes: exactNodes))
            let report = try await service.discover(work: fuzzyWork, episode: episode(fuzzyWork), links: [])
            try require(report.matchedCandidates.count == 1 && report.automaticCandidates.isEmpty,
                        "small spelling/suffix differences only suggest a manual candidate")
        }
        for (targetTitle, sourceTitle) in [("Short", "Shore"), ("ChronicleAdventure", "UnrelatedAdventure"),
                                         ("ChronicleAdventure 2", "ChronicleAdventure 3"),
                                         ("ChronicleAdventure 第二季", "ChronicleAdventure 第三季"),
                                         ("ChronicleAdventure Season II", "ChronicleAdventure Season III"),
                                         ("ChronicleAdventure 第Ⅱ季", "ChronicleAdventure 第Ⅲ季")] {
            let targetWork = work(targetTitle)
            let service = AnimeSourceService(dependencies: dependencies(hits: [hit(sourceTitle)], nodes: exactNodes))
            let report = try await service.discover(work: targetWork, episode: episode(targetWork), links: [])
            try require(report.matchedCandidates.isEmpty, "fuzzy title matching cannot swallow short names, unrelated subtitles, numbers or explicit ordinals")
        }
        let traditionalWork = work("關於我們的冒險旅程", platform: "TV")
        let traditional = AnimeSourceService(dependencies: dependencies(hits: [hit("关于我们的冒险旅程 [2026 TV]")], nodes: exactNodes))
        let traditionalReport = try await traditional.discover(work: traditionalWork, episode: episode(traditionalWork), links: [])
        try require(traditionalReport.matchedCandidates.count == 1, "traditional/simplified script differences are normalized")
        let queryService = AnimeSourceService(dependencies: dependencies(hits: [hit("JOJO的奇妙冒险 飙马野郎")],
            nodes: splitNodes, requiredQuery: "飙马野郎"))
        let shortQueryReport = try await queryService.discover(work: splitWork, episode: splitEpisode, links: [])
        try require(shortQueryReport.matchedCandidates.first?.selection?.episode == ref("a", "stage-two", kind: .episode),
                    "a source requiring a short keyword can still supply the exact selected episode")
        let pirateSubject = BangumiSubject(id: 975, name: "ONE PIECE", nameCN: "航海王", aliases: ["ワンピース", "海贼王"], type: 2, platform: "TV")
        let pirateWork = Work(title: pirateSubject.title, bangumiMetadata: BangumiMetadata(subject: pirateSubject, episodes: [], fetchedAt: .now), classification: anime)
        let pirateService = AnimeSourceService(dependencies: dependencies(hits: [hit("海贼王")],
            nodes: exactNodes, requiredQuery: "海贼王"))
        let pirateReport = try await pirateService.discover(work: pirateWork, episode: episode(pirateWork), links: [])
        try require(pirateReport.matchedCandidates.first?.selection?.episode == ref("a", "actual", kind: .episode),
                    "an alternate source title remains discoverable alongside shortened official names")
        let continued = try numberedWork("药屋少女的呢喃 第三季", rows: [(1738548, 50, 2, "火鼠的皮衣"), (1738547, 49, 1, "蝗虫")])
        let continuedFirst = numberedEpisode(continued, id: 1738547, sort: 49)
        let scopedRelativeNodes = [VideoTreeNode(title: "line", children: [leaf("SP1", "a", "wrong-sp"), leaf("第02集", "a", "third-two"), leaf("第01集", "a", "third-one")])]
        let continuedService = AnimeSourceService(dependencies: dependencies(hits: [hit(continued.title)], nodes: scopedRelativeNodes))
        let continuedReport = try await continuedService.discover(work: continued, episode: continuedFirst, links: [])
        try require(continuedReport.matchedCandidates.first?.selection?.episode == ref("a", "third-one", kind: .episode),
                    "Bangumi absolute 49 maps to official subject ordinal one in a season-scoped source despite reordered nodes and SP1")
        let secondNumbered = try await continuedService.discover(work: continued, episode: numberedEpisode(continued, id: 1738548, sort: 50), links: [])
        try require(secondNumbered.matchedCandidates.first?.selection?.episode == ref("a", "third-two", kind: .episode),
                    "Bangumi absolute 50 maps to ordinal two without changing episode identity")
        let longRelative = AnimeSourceService(dependencies: dependencies(hits: [hit(continued.title)], nodes: [VideoTreeNode(title: "line", children: [leaf("第49集", "a", "wrong-fortynine"), leaf("第01集", "a", "local-first")])]))
        let longRelativeReport = try await longRelative.discover(work: continued, episode: continuedFirst, links: [])
        try require(longRelativeReport.matchedCandidates.first?.selection?.episode == ref("a", "local-first", kind: .episode),
                    "a scoped reset-numbered line cannot substitute its own episode 49 for season episode one")
        let mergedSeasons = AnimeSourceService(dependencies: dependencies(hits: [hit("药屋少女的呢喃")], nodes: [VideoTreeNode(title: "line", children: [leaf("第01集", "a", "previous-season"), leaf("第49集", "a", "all-fortynine")])]))
        let mergedSeasonsReport = try await mergedSeasons.discover(work: continued, episode: continuedFirst, links: [])
        try require(mergedSeasonsReport.matchedCandidates.first?.selection?.episode == ref("a", "all-fortynine", kind: .episode),
                    "an unmarked combined source keeps the absolute episode number rather than its first episode")
        let longSeason = try numberedWork("LongSeries 第二季", rows: [(121, 13, 1, "Start of the sequel"), (122, 32, 20, "Later in the sequel")])
        let overlapLine = AnimeSourceService(dependencies: dependencies(hits: [hit(longSeason.title)], nodes: [VideoTreeNode(title: "line", children: [leaf("第13集", "a", "absolute-start"), leaf("第20集", "a", "wrong-twenty"), leaf("第32集", "a", "absolute-thirtytwo")])]))
        let overlapReport = try await overlapLine.discover(work: longSeason, episode: numberedEpisode(longSeason, id: 122, sort: 32), links: [])
        try require(overlapReport.matchedCandidates.first?.selection?.episode == ref("a", "absolute-thirtytwo", kind: .episode),
                    "a scoped continuously numbered line remains absolute even when the local ordinal also exists")
        let actualSplit = try numberedWork(splitWork.title, rows: [(1663677, 2, 1, "警长对曼登提姆的要求"), (1663678, 3, 2, "沙漠中诞生的法外之徒")])
        let actualSplitFirst = numberedEpisode(actualSplit, id: 1663677, sort: 2)
        let mergedSplit = AnimeSourceService(dependencies: dependencies(hits: [hit("JOJO的奇妙冒险 飙马野郎")], nodes: splitNodes))
        let mergedSplitReport = try await mergedSplit.discover(work: actualSplit, episode: actualSplitFirst, links: [])
        try require(mergedSplitReport.matchedCandidates.first?.selection?.episode == ref("a", "stage-two", kind: .episode),
                    "JOJO split subject ep1 remains combined source episode two, never replaying first stage")
        let scopedSplit = AnimeSourceService(dependencies: dependencies(hits: [hit(actualSplit.title)], nodes: splitNodes))
        let scopedSplitReport = try await scopedSplit.discover(work: actualSplit, episode: actualSplitFirst, links: [])
        try require(scopedSplitReport.matchedCandidates.first?.selection?.episode == ref("a", "stage-one", kind: .episode),
                    "an explicitly split second-stage source can use its own ordinal one")
        let namedWork = try numberedWork("药屋少女的呢喃 第二季", rows: [(1415053, 25, 1, "猫猫和毛毛"), (1415054, 26, 2, "商队的来访"), (1415055, 27, 3, "冬人夏草")])
        let namedEpisode = numberedEpisode(namedWork, id: 1415053, sort: 25)
        let namedSource = AnimeSourceService(dependencies: dependencies(hits: [hit("药屋少女的呢喃")], nodes: [VideoTreeNode(title: "line", children: [leaf("第01集 猫猫和毛毛", "a", "named-first"), leaf("第25集", "a", "wrong-number")])]))
        let namedReport = try await namedSource.discover(work: namedWork, episode: namedEpisode, links: [])
        try require(namedReport.matchedCandidates.first?.selection?.episode == ref("a", "named-first", kind: .episode) && namedReport.automaticCandidates.isEmpty,
                    "a unique official episode name can anchor an unmarked reset line, without automatic binding")
        let anchoredLine = AnimeSourceService(dependencies: dependencies(hits: [hit("药屋少女的呢喃")], nodes: [VideoTreeNode(title: "line", children: [leaf("第01集 猫猫和毛毛", "a", "anchor"), leaf("第02集", "a", "anchor-selected"), leaf("第26集", "a", "wrong-global")])]))
        let anchoredReport = try await anchoredLine.discover(work: namedWork, episode: numberedEpisode(namedWork, id: 1415054, sort: 26), links: [])
        try require(anchoredReport.matchedCandidates.first?.selection?.episode == ref("a", "anchor-selected", kind: .episode),
                    "another episode's unique name establishes the numbering scheme for an unnamed selected episode")
        let conflictingLine = AnimeSourceService(dependencies: dependencies(hits: [hit(namedWork.title)], nodes: [VideoTreeNode(title: "line", children: [leaf("第25集 猫猫和毛毛", "a", "absolute-anchor"), leaf("第02集 商队的来访", "a", "relative-anchor"), leaf("第03集", "a", "unproven")])]))
        let conflictingReport = try await conflictingLine.discover(work: namedWork, episode: numberedEpisode(namedWork, id: 1415055, sort: 27), links: [])
        try require(conflictingReport.matchedCandidates.isEmpty, "contradictory episode-name anchors never guess a numbering scheme")
        let mixedLines = AnimeSourceService(dependencies: dependencies(hits: [hit(continued.title)], nodes: [VideoTreeNode(title: "absolute line", children: [leaf("第49集", "a", "absolute-line")]), VideoTreeNode(title: "relative line", children: [leaf("第01集", "a", "relative-line")])]))
        let mixedReport = try await mixedLines.discover(work: continued, episode: continuedFirst, links: [])
        try require(mixedReport.matchedCandidates.first?.selection?.episode == ref("a", "absolute-line", kind: .episode),
                    "each line's numbering can differ while representing the same selected Bangumi identity")
        let groupedSeasons = AnimeSourceService(dependencies: dependencies(hits: [hit("药屋少女的呢喃")], nodes: [VideoTreeNode(title: "第一季", children: [leaf("第49集", "a", "wrong-group")]), VideoTreeNode(title: "第三季", children: [leaf("第01集", "a", "right-group")])]))
        let groupedReport = try await groupedSeasons.discover(work: continued, episode: continuedFirst, links: [])
        try require(groupedReport.matchedCandidates.first?.selection?.episode == ref("a", "right-group", kind: .episode),
                    "an explicit season group excludes other seasons even if their numeric label coincides")
        let clippedOverlap = AnimeSourceService(dependencies: dependencies(hits: [hit(longSeason.title)], nodes: [VideoTreeNode(title: "line", children: [leaf("第20集", "a", "overlap-only")])]))
        let clippedReport = try await clippedOverlap.discover(work: longSeason, episode: numberedEpisode(longSeason, id: 122, sort: 32), links: [])
        try require(clippedReport.matchedCandidates.isEmpty, "a clipped overlapping numbering range cannot prove local twenty versus absolute twenty")

        let missingCombined = AnimeSourceService(dependencies: dependencies(hits: [hit("JOJO的奇妙冒险 飙马野郎")], nodes: [leaf("第01集", "a", "old-stage")]))
        let missingCombinedReport = try await missingCombined.discover(work: actualSplit, episode: actualSplitFirst, links: [])
        try require(missingCombinedReport.matchedCandidates.isEmpty, "a merged JOJO source missing episode two cannot reinterpret first stage as relative ep1")
        let rangedSource = AnimeSourceService(dependencies: dependencies(hits: [hit(continued.title)], nodes: [leaf("第01-02集", "a", "range")]))
        let rangedReport = try await rangedSource.discover(work: continued, episode: continuedFirst, links: [])
        try require(rangedReport.matchedCandidates.isEmpty, "a combined episode range is not a precise individual episode")
        let unlinked = episode(continued, sort: 49)
        let unlinkedReport = try await continuedService.discover(work: continued, episode: unlinked, links: [])
        try require(unlinkedReport.matchedCandidates.isEmpty, "sort coincidence without a Bangumi episode identity cannot activate ordinal conversion")
        try library.upsert(continued); try library.upsert(continuedFirst)
        let persistedReport = try await continuedService.discover(work: continued, episode: continuedFirst, links: [])
        let shiftedCandidate = persistedReport.matchedCandidates[0]
        _ = try await continuedService.resolve(shiftedCandidate)
        try continuedService.confirm(shiftedCandidate, work: continued, episode: continuedFirst, library: library)
        let preservedMapping = try library.sourceLinks(forWorkID: continued.id)[0].episodeMappings[0]
        try require(preservedMapping.episodeID == continuedFirst.id && preservedMapping.selection.episode == ref("a", "third-one", kind: .episode),
                    "persisted relative source mapping retains the original Bangumi-linked local episode UUID")

        let sp = episode(target, kind: .special)
        let spReport = try await unique.discover(work: target, episode: sp, links: [])
        try require(spReport.automaticCandidates.first?.selection?.episode?.pageURL.hasSuffix("/sp") == true, "SP1 is distinct from main episode 1")
        let missing = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: [VideoTreeNode(title: "line", children: [leaf("02")])]))
        let missingReport = try await missing.discover(work: target, episode: selected, links: [])
        try require(missingReport.candidates.allSatisfy { $0.selection == nil && $0.failure != nil }, "no first/nearest/list-index fallback for missing episode")
        try require(missingReport.matchedCandidates.isEmpty, "a source missing the primary page episode is hidden rather than asking for a different episode")
        let duplicateEpisodes = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: [VideoTreeNode(title: "line", children: [leaf("01", "a", "first"), leaf("01", "a", "second")])]))
        let duplicateReport = try await duplicateEpisodes.discover(work: target, episode: selected, links: [])
        try require(duplicateReport.automaticCandidates.isEmpty && duplicateReport.candidates.allSatisfy { $0.selection == nil }, "duplicate same-line episode identities cannot be guessed")
        let lines = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: [VideoTreeNode(title: "line A", children: [leaf("01", "a", "lineA")]), VideoTreeNode(title: "line B", children: [leaf("01", "a", "lineB")])]))
        let linesReport = try await lines.discover(work: target, episode: selected, links: [])
        try require(linesReport.automaticCandidates.count == 1, "same typed episode on separate lines is not a conflicting work")

        let movie = work("Feature", platform: "劇場版"), movieEpisode = episode(movie)
        let movieService = AnimeSourceService(dependencies: dependencies(hits: [hit("Feature [2026 Movie]")], nodes: [VideoTreeNode(title: "line", children: [leaf("正片", "a", "feature")])]))
        let movieReport = try await movieService.discover(work: movie, episode: movieEpisode, links: [])
        try require(movieReport.automaticCandidates.count == 1, "a movie's explicit full-feature label can match its stable episode without TV index assumptions")
        let tvService = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: [VideoTreeNode(title: "line", children: [leaf("正片")])]))
        let tvReport = try await tvService.discover(work: target, episode: selected, links: [])
        try require(tvReport.automaticCandidates.isEmpty && tvReport.candidates.allSatisfy { $0.selection == nil }, "TV cannot reinterpret an unlabeled movie as episode one")

        let savedCalls = Calls()
        var savedChoice = stored[0].episodeMappings[0].selection; savedChoice.accountID = UUID()
        let savedLink = WorkSourceLink(workID: target.id, sourceWork: stored[0].sourceWork,
                                      episodeMappings: [EpisodeSourceMapping(episodeID: selected.id, selection: savedChoice)])
        let saved = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季")], nodes: exactNodes, calls: savedCalls))
        let savedReport = try await saved.discover(work: target, episode: selected, links: [savedLink])
        try require(savedReport.automaticCandidates.count == 1 && savedReport.automaticCandidates[0].selection?.accountID == nil, "explicit saved episode mapping is preferred and sanitized")
        let savedStats = await savedCalls.snapshot()
        try require(savedStats.searches == 0 && savedStats.catalogs == 1, "saved exact mapping skips alternate searches but revalidates the fresh exact catalog")
        _ = try await saved.resolve(savedReport.automaticCandidates[0])
        try require(await savedCalls.guest, "saved account cannot become an implicit decode/prepare credential")

        let partial = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: exactNodes, failSource: "failed"))
        let partialReport = try await partial.discover(work: target, episode: selected, links: [])
        try require(partialReport.automaticCandidates.count == 1 && partialReport.candidates.contains { $0.sourceName == "failed" && $0.failure != nil }, "per-station failures remain visible without masking a usable candidate")
        try require(partialReport.matchedCandidates.map { $0.selection?.episode } == [ref("a", "actual", kind: .episode)], "foreground exposes only the exact selected episode while failed stations remain diagnostic")
        let emptyURL = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: exactNodes, media: nil))
        let emptyReport = try await emptyURL.discover(work: target, episode: selected, links: [])
        do {
            _ = try await emptyURL.resolve(emptyReport.automaticCandidates[0])
            throw Failure("empty quality produced fake playable result")
        } catch AnimeSourceService.SourceError.unavailable { }
        do {
            try emptyURL.confirm(emptyReport.automaticCandidates[0], work: target, episode: selected, library: library)
            throw Failure("failed resolution persisted")
        } catch AnimeSourceService.SourceError.unresolved { }

        let boundCalls = Calls()
        var aliasWork = target; aliasWork.aliases = ["Sample 第2季", "Alias A", "Alias B", "Alias C", "Alias D", "Alias E"]
        let manyHits = (0..<7).map { hit("Sample 第2季", "s\($0)") }
        let bounded = AnimeSourceService(dependencies: dependencies(hits: manyHits, nodes: exactNodes, calls: boundCalls, delay: 1_000_000))
        _ = try await bounded.discover(work: aliasWork, episode: selected, links: [])
        let boundStats = await boundCalls.snapshot()
        try require(boundStats.peak <= 3 && boundStats.searches <= 28, "source concurrency and distinct alias attempts are bounded")
        let cancelledCalls = Calls()
        let cancellable = AnimeSourceService(dependencies: dependencies(hits: manyHits, nodes: exactNodes, calls: cancelledCalls, delay: 10_000_000_000))
        let pending = Task { try await cancellable.discover(work: target, episode: selected, links: []) }
        while await cancelledCalls.searches == 0 { await Task.yield() }
        pending.cancel()
        do { _ = try await pending.value; throw Failure("cancelled discovery returned candidates") }
        catch is CancellationError { }
        let cancelledStats = await cancelledCalls.snapshot()
        try require(cancelledStats.catalogs == 0 && cancelledStats.active == 0, "cancellation terminates pending search tasks before catalogs or persistence")
        let forced = try await saved.discover(work: target, episode: selected, links: [savedLink], forceSearch: true)
        let forcedStats = await savedCalls.snapshot()
        try require(forcedStats.searches > 0 && !forced.automaticCandidates.isEmpty, "explicit re-search bypasses saved shortcut without forgetting confirmed mapping")
        do {
            _ = try await saved.resolve(savedReport.automaticCandidates[0])
            throw Failure("previous discovery candidate resolved after context replacement")
        } catch AnimeSourceService.SourceError.unavailable { }
        var disabledDependencies = dependencies(hits: [hit("Sample 第2季")], nodes: exactNodes)
        disabledDependencies.enabled = { _ in false }
        let disabledService = AnimeSourceService(dependencies: disabledDependencies)
        let disabledReport = try await disabledService.discover(work: target, episode: selected, links: [savedLink])
        try require(disabledReport.automaticCandidates.isEmpty && disabledReport.candidates.allSatisfy { $0.selection == nil && $0.failure != nil }, "disabled saved mapping cannot search or play")
        let ova = work("Original", platform: "OVA"), ovaEpisode = episode(ova)
        let ovaService = AnimeSourceService(dependencies: dependencies(hits: [hit("Original [2026 OVA]")], nodes: [VideoTreeNode(title: "line", children: [leaf("01")])]))
        let ovaReport = try await ovaService.discover(work: ova, episode: ovaEpisode, links: [])
        try require(ovaReport.automaticCandidates.count == 1, "OVA work retains subtype and its own main episode identity")
        var qualityDependencies = dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: exactNodes)
        qualityDependencies.prepare = { json, key in
            var json = json
            json.streams[key]?.url = "https://media.invalid/primary.mp4"
            json.streams[key]?.src = ["https://media.invalid/backup.mp4"]
            return json
        }
        let qualityService = AnimeSourceService(dependencies: qualityDependencies)
        let qualityReport = try await qualityService.discover(work: target, episode: selected, links: [])
        let original = qualityReport.automaticCandidates[0]
        var chosen = original.selection!; chosen.qualityID = "HD"; chosen.lineID = "1"; chosen.accountID = UUID()
        let withQuality = AnimeSourceCandidate(id: original.id, sourceName: original.sourceName, title: original.title, selection: chosen, evidence: original.evidence, failure: nil, trusted: original.trusted)
        let qualityResult = try await qualityService.resolve(withQuality)
        try require(qualityResult.selection?.lineID == "1" && qualityResult.selection?.accountID == nil, "quality and backup-line changes retain exact identity and cannot inject an account")
        try qualityService.confirm(withQuality, work: target, episode: selected, library: library)
        var ordinary = target; ordinary.classification = MediaClassification(kind: .video, provenance: "fixture.video")
        do {
            _ = try await qualityService.discover(work: ordinary, episode: selected, links: [])
            throw Failure("ordinary video entered anime sourcing")
        } catch AnimeSourceService.SourceError.invalidContext { }
        try await mappingSafetyRegressions(library: library, target: target, episode: selected,
            nodes: exactNodes, nativeMapping: stored[0])
        print("AnimeSourceRegression passed")
    }

    static func mappingSafetyRegressions(library: WorkLibrary, target: Work, episode: Episode,
                                        nodes: [VideoTreeNode], nativeMapping: WorkSourceLink) async throws {
        let configured = Authority(configured: true)
        let calls = Calls()
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "episodeID": episode.id.uuidString,
            "selection": try JSONSerialization.jsonObject(with: JSONEncoder().encode(nativeMapping.episodeMappings[0].selection))
        ])
        let legacy = try JSONDecoder().decode(EpisodeSourceMapping.self, from: legacyData)
        try require(legacy.confirmation == nil, "version-compatible legacy records are retained without invented confirmation metadata")
        let oldLink = WorkSourceLink(workID: target.id, sourceWork: legacy.selection.item, episodeMappings: [legacy])
        let oldService = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]"), hit("Sample 第2季 [2026 TV]", "b")],
            nodes: nodes, calls: calls, authority: configured))
        let oldReport = try await oldService.discover(work: target, episode: episode, links: [oldLink])
        try require(oldReport.matchedCandidates.isEmpty && oldReport.automaticCandidates.isEmpty,
                    "configured legacy mapping cannot silently become trusted")
        let legacyStats = await calls.snapshot()
        try require(legacyStats.searches == 0 && legacyStats.decodes == 0, "invalid stored mapping cannot search or decode another source")
        let explicit = try await oldService.discover(work: target, episode: episode, links: [oldLink], forceSearch: true)
        guard let selected = explicit.matchedCandidates.first(where: { $0.selection?.item.sourceID == "a" }) else {
            throw Failure("explicit reconfirmation must offer the original exact source")
        }
        _ = try await oldService.resolve(selected)
        try oldService.confirm(selected, work: target, episode: episode, library: library)
        let confirmed = try library.sourceLinks(forWorkID: target.id).first { $0.sourceWork == selected.selection?.item }!
        try require(confirmed.episodeMappings[0].confirmation?.context.configurationRevision == configured.currentRevision(),
                    "only successfully resolved mappings gain the current configuration revision")
        configured.setRevision("configured-fixture:changed")
        let changed = try await oldService.discover(work: target, episode: episode, links: [confirmed])
        try require(changed.matchedCandidates.isEmpty && changed.automaticCandidates.isEmpty,
                    "same-ID configuration replacement invalidates a saved confirmation")
        let preserved = try library.sourceLinks(forWorkID: target.id).first { $0.id == confirmed.id }
        try require(preserved == confirmed, "invalid configuration never deletes or rewrites the saved record")
        configured.setRevision("native-fixture:mapping-v1")

        let missingCalls = Calls()
        let missing = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]", "b")],
            nodes: [leaf("02", "a", "actual")], calls: missingCalls, authority: configured))
        let missingReport = try await missing.discover(work: target, episode: episode, links: [confirmed])
        try require(missingReport.matchedCandidates.isEmpty && missingReport.automaticCandidates.isEmpty,
                    "a saved page relabeled to a different episode cannot be reused")
        try require(await missingCalls.searches == 0, "missing exact saved episode never triggers alternate-source search")
        let moved = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]")],
            nodes: [leaf("01", "a", "replacement")], authority: configured))
        let movedReport = try await moved.discover(work: target, episode: episode, links: [confirmed])
        try require(movedReport.matchedCandidates.isEmpty, "matching number with another exact page is not a replacement mapping")
        let regrouped = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]")],
            nodes: [VideoTreeNode(title: "different group", children: [leaf("01", "a", "actual")])], authority: configured))
        let regroupedReport = try await regrouped.discover(work: target, episode: episode, links: [confirmed])
        try require(regroupedReport.matchedCandidates.isEmpty, "the same exact page moved to another catalog group requires reconfirmation")
        var wrongMetadata = episode
        wrongMetadata.sort = 1.5
        let changedEpisode = try await oldService.discover(work: target, episode: wrongMetadata, links: [confirmed])
        try require(changedEpisode.matchedCandidates.isEmpty, "same UUID with changed raw sort cannot reuse confirmed identity")
        for phase in ["search", "catalog"] {
            let state = Authority(configured: true)
            var deps = dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: nodes, authority: state)
            if phase == "search" {
                let search = deps.search
                deps.search = { id, query in
                    let result = try await search(id, query)
                    state.setEnabled(false)
                    return result
                }
            } else {
                let catalog = deps.catalog
                deps.catalog = { choice in
                    let result = try await catalog(choice)
                    state.setRevision("configured-fixture:changed-during-catalog")
                    return result
                }
            }
            let service = AnimeSourceService(dependencies: deps)
            let report = try await service.discover(work: target, episode: episode, links: [])
            try require(report.matchedCandidates.isEmpty && !report.candidates.isEmpty,
                        "stale \(phase) result stays diagnostic-only")
        }

        for phase in ["decode", "prepare"] {
            let state = Authority(configured: true)
            var deps = dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: nodes, authority: state)
            if phase == "decode" {
                let decode = deps.decode
                deps.decode = { choice in
                    let result = try await decode(choice)
                    state.setEnabled(false)
                    return result
                }
            } else {
                let prepare = deps.prepare
                deps.prepare = { result, quality in
                    let result = try await prepare(result, quality)
                    state.setRevision("configured-fixture:changed-during-prepare")
                    return result
                }
            }
            let service = AnimeSourceService(dependencies: deps)
            let report = try await service.discover(work: target, episode: episode, links: [])
            let candidate = report.automaticCandidates[0]
            do {
                _ = try await service.resolve(candidate)
                throw Failure("stale async \(phase) result escaped")
            } catch AnimeSourceService.SourceError.failure(let failure) {
                try require(failure == (phase == "decode" ? .sourceDisabled : .configurationChanged),
                            "authority loss retains its specific recovery category")
            }
            do {
                try service.confirm(candidate, work: target, episode: episode, library: library)
                throw Failure("stale \(phase) result persisted")
            } catch AnimeSourceService.SourceError.unresolved { }
        }

        let finalState = Authority(configured: true)
        let finalService = AnimeSourceService(dependencies: dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: nodes, authority: finalState))
        let finalReport = try await finalService.discover(work: target, episode: episode, links: [])
        let finalCandidate = finalReport.automaticCandidates[0]
        let finalResult = try await finalService.resolve(finalCandidate)
        var presented = finalResult.selection!
        presented.classification = MediaClassification(kind: .anime, provenance: "manual-work")
        try finalService.validateHandoff(presented)
        for changed in ["quality", "line", "episode", "account", "kind"] {
            var invalid = presented
            switch changed {
            case "quality": invalid.qualityID = "another-quality"
            case "line": invalid.lineID = "99"
            case "episode": invalid.episode = ref("a", "different", kind: .episode)
            case "account": invalid.accountID = UUID()
            default: invalid.classification.kind = .video
            }
            do {
                try finalService.validateHandoff(invalid)
                throw Failure("changed \(changed) choice passed the actual handoff boundary")
            } catch AnimeSourceService.SourceError.unresolved {}
        }
        finalState.setEnabled(false)
        do {
            try finalService.confirm(finalCandidate, work: target, episode: episode, library: library)
            throw Failure("disable after preparation persisted")
        } catch AnimeSourceService.SourceError.failure(.sourceDisabled) { }
        do {
            try finalService.validateHandoff(finalResult.selection!)
            throw Failure("disable at actual handoff escaped")
        } catch AnimeSourceService.SourceError.failure(.sourceDisabled) { }
        finalState.setEnabled(true)
        finalState.setRevision("changed-after-resolve")
        do {
            try finalService.confirm(finalCandidate, work: target, episode: episode, library: library)
            throw Failure("configuration replacement after preparation persisted")
        } catch AnimeSourceService.SourceError.failure(.configurationChanged) { }

        var wrongDecodeDeps = dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: nodes)
        let decode = wrongDecodeDeps.decode
        wrongDecodeDeps.decode = { choice in
            var result = try await decode(choice)
            result.selection?.episode = ref("a", "two", kind: .episode)
            return result
        }
        let wrongDecode = AnimeSourceService(dependencies: wrongDecodeDeps)
        let wrongReport = try await wrongDecode.discover(work: target, episode: episode, links: [])
        do {
            _ = try await wrongDecode.resolve(wrongReport.automaticCandidates[0])
            throw Failure("wrong decoded identity accepted")
        } catch AnimeSourceService.SourceError.failure(.missingEpisode) { }
        for kind in [MediaContentKind.video, .live] {
            var incompatibleDependencies = dependencies(hits: [hit("Sample 第2季 [2026 TV]")], nodes: nodes)
            let mappingSelection = incompatibleDependencies.mappingSelection
            incompatibleDependencies.mappingSelection = { choice in
                let authority = try mappingSelection(choice)
                var incompatible = authority.selection
                incompatible.classification = MediaClassification(kind: kind, provenance: "fixture.explicit-source-kind")
                return (incompatible, authority.revision, true)
            }
            let incompatible = AnimeSourceService(dependencies: incompatibleDependencies)
            do {
                _ = try incompatible.candidate(for: nativeMapping.episodeMappings[0].selection,
                    work: target, episode: episode, title: target.title)
                throw Failure("explicit incompatible source classification was silently relabeled")
            } catch AnimeSourceService.SourceError.invalidContext { }
            let incompatibleReport = try await incompatible.discover(work: target, episode: episode, links: [])
            try require(incompatibleReport.matchedCandidates.isEmpty && incompatibleReport.candidates.contains { $0.failure != nil },
                        "explicit video/live source mismatch rejects before resolution or storage")
        }

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let archive = try SourceConfiguration.load(fileURL: root.appendingPathComponent("Tests/Fixtures/Sources/internet-archive.json"))
        let raw = "https://archive.org/details/BigBuckBunny_328?file=BigBuckBunny_512kb.mp4&utm_source=fixture&token=secret#ignored"
        var archiveChoice = PlayableSelection(item: try archive.item("https://archive.org/details/BigBuckBunny_328"),
            accountID: UUID(), classification: anime)
        archiveChoice.episode = SourceItemRef(sourceID: archive.id, pageURL: raw, kind: .episode)
        let safe = try archive.mappingSelection(archiveChoice)
        try require(safe.classification.kind == .unknown, "mixed-content fixture intentionally supplies no source classification evidence")
        try require(safe.episode?.pageURL == "https://archive.org/details/BigBuckBunny_328?file=BigBuckBunny_512kb.mp4" && safe.accountID == nil,
                    "configured safe public file query identity survives while tracking, fragments and credentials are removed")
        var archiveDependencies = dependencies(hits: [], nodes: [])
        archiveDependencies.mappingSelection = {
            (try archive.mappingSelection($0), archive.configurationRevision, true)
        }
        archiveDependencies.mappingRevision = { _ in archive.configurationRevision }
        archiveDependencies.selection = {
            PlayableSelection(item: try archive.item($0), classification: anime)
        }
        let archiveNode = VideoTreeNode(site: .configured(archive.id), title: "01", id: "BigBuckBunny_512kb.mp4",
            url: safe.episode!.pageURL)
        archiveDependencies.catalog = {
            VideoSelectionCatalog(nodes: [archiveNode], current: 999, selection: $0)
        }
        let archiveService = AnimeSourceService(dependencies: archiveDependencies)
        let archiveCandidate = try archiveService.candidate(for: archiveChoice, work: target, episode: episode, title: target.title)
        do {
            try archiveService.confirm(archiveCandidate, work: target, episode: episode, library: library)
            throw Failure("manual mapping saved before real resolution")
        } catch AnimeSourceService.SourceError.unresolved { }
        _ = try await archiveService.resolve(archiveCandidate)
        try archiveService.confirm(archiveCandidate, work: target, episode: episode, library: library)
        let archiveLink = try library.sourceLinks(forWorkID: target.id).first { $0.sourceWork.sourceID == archive.id }!
        let preferredMappings = try library.sourceLinks(forWorkID: target.id).flatMap(\.episodeMappings)
            .filter { $0.episodeID == episode.id }
        try require(preferredMappings.count == 1 && preferredMappings[0].selection.item.sourceID == archive.id,
                    "successful explicit source replacement commits one preferred mapping without stale alternate mappings")
        let archiveMapping = archiveLink.episodeMappings[0]
        try require(archiveMapping.selection.episode == safe.episode && archiveMapping.selection.accountID == nil,
                    "successful manual mapping persists exact file identity, not transient media or credentials")
        try require(archiveMapping.selection.classification == anime &&
                    archiveMapping.confirmation?.context.selection.classification == anime,
                    "safe unknown-source normalization retains confirmed anime-work evidence through successful persistence")
        let archiveReloaded = try await archiveService.discover(work: target, episode: episode, links: [archiveLink])
        try require(archiveReloaded.automaticCandidates.first?.selection?.episode == safe.episode,
                    "confirmed file query mapping reloads through exact fresh catalog validation")
        let userSources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: userSources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: userSources) }
        let registry = SourceRegistry(builtinDirectory: root.appendingPathComponent("IINA-ANI/Sources"), userDirectory: userSources)
        let sourceState = Authority()
        let decoder = VideoDecoder(registry: registry, sourceEnabled: { _ in sourceState.isEnabled() })
        let fqdm = registry.source(for: "fqdm")!
        let fqdmChoice = PlayableSelection(
            item: try fqdm.item("https://www.fqdm.cc/index.php/vod/detail/id/12.html"),
            episode: try fqdm.item("https://www.fqdm.cc/index.php/vod/play/id/12/sid/2/nid/1.html"),
            lineID: "0", accountID: UUID(), classification: anime)
        let fqdmSafe = try decoder.mappingSelection(fqdmChoice)
        try require(fqdmSafe.selection.episode == fqdmChoice.episode && fqdmSafe.selection.lineID == "0" &&
                    fqdmSafe.selection.accountID == nil && fqdmSafe.revision == fqdm.configurationRevision,
                    "real decoder authority preserves configured page sid and independent desktop backup-stream index")
        sourceState.setEnabled(false)
        do {
            _ = try decoder.mappingSelection(fqdmChoice)
            throw Failure("real decoder authority ignored source disablement")
        } catch PlaybackFailure.sourceDisabled { }
        sourceState.setEnabled(true)
        try Data("invalid configuration".utf8).write(to: userSources.appendingPathComponent("broken.json"))
        do { try registry.reloadCurrent(); throw Failure("bad registry reload unexpectedly succeeded") }
        catch { if error is Failure { throw error } }
        do {
            _ = try decoder.mappingRevision("fqdm")
            throw Failure("retained configuration after bad reload was treated as authoritative")
        } catch PlaybackFailure.configurationChanged { }
        try require(try decoder.mappingRevision("bilibili").hasPrefix("native-adapter:"),
                    "a malformed configured source must not disable native adapter identities")
    }
}
