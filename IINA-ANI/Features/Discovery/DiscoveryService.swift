import Foundation
import CryptoKit

struct DiscoveryScheduledBroadcast: Sendable, Equatable {
    let subject: BangumiSubject
    let weekday: Int
    let coverURL: String?
    /// Schedule evidence does not claim that a source has published an episode.
    let evidence: String
}

struct DiscoveryFavoriteUpdate: Sendable, Equatable {
    let workID: UUID
    let workTitle: String
    let sourceID: String
    let newIdentities: [String]
}

struct DiscoveryRecommendation: Sendable, Equatable {
    let subject: BangumiSubject
    let reasons: [String]
}

struct DiscoverySection<Value: Sendable>: Sendable {
    let items: [Value]
    let failure: String?
}

struct DiscoverySnapshot: Sendable {
    let day: Date
    let weeklyBroadcasts: DiscoverySection<DiscoveryScheduledBroadcast>
    let favoriteUpdates: DiscoverySection<DiscoveryFavoriteUpdate>
    let recommendations: DiscoverySection<DiscoveryRecommendation>
}

@MainActor
final class DiscoveryService {
    typealias CalendarLoader = @Sendable (Bool) async throws -> BangumiResult<[BangumiCalendarDay]>
    typealias TrendsLoader = @Sendable (Bool) async throws -> BangumiResult<[BangumiSubject]>
    typealias CoverLoader = @Sendable (Int, Bool) async throws -> BangumiResult<String>
    typealias CatalogLoader = @Sendable (String) async throws -> [String]
    typealias SourceEnabled = @Sendable (String) -> Bool

    private struct Baselines: Codable {
        let version: Int
        var seenByFavoriteSource: [String: [String]]
        init() { version = 1; seenByFavoriteSource = [:] }
    }
    private let favorites: FavoriteLibrary
    private let works: WorkLibrary
    private let sync: BangumiWorkSync
    private let decoder: VideoDecoder
    private let baselineURL: URL
    private let now: () -> Date
    private let timeZone: TimeZone
    private let calendarLoader: CalendarLoader
    private let trendsLoader: TrendsLoader
    private let coverLoader: CoverLoader
    private let catalogLoader: CatalogLoader?
    private let sourceEnabled: SourceEnabled
    private var baselines = Baselines()
    private var baselineLoadFailure: String?
    private var generation: UInt64 = 0
    private var worker: Task<DiscoverySnapshot, Error>?
    private var workerDay: Date?
    private(set) var snapshot: DiscoverySnapshot?
    private var refreshPolicy = DiscoveryRefreshPolicy()

    func setRefreshPolicy(_ policy: DiscoveryRefreshPolicy) {
        guard policy != refreshPolicy else { return }
        refreshPolicy = policy
        generation &+= 1
        worker?.cancel()
        worker = nil
        workerDay = nil
        snapshot = nil
    }

    /// A disappearing presentation relinquishes its result, not the shared refresh worker.
    func presentationSnapshot(force: Bool = false) async throws -> DiscoverySnapshot {
        let sharedRefresh = Task { try await self.refresh(force: force) }
        return try await sharedRefresh.value
    }

    init(works: WorkLibrary, favorites: FavoriteLibrary, sync: BangumiWorkSync,
         decoder: VideoDecoder, bangumi: BangumiService = .shared, baselineURL: URL,
         now: @escaping () -> Date = { Date() }, timeZone: TimeZone = .current,
         calendarLoader: CalendarLoader? = nil, trendsLoader: TrendsLoader? = nil,
         coverLoader: CoverLoader? = nil,
         catalogLoader: CatalogLoader? = nil, sourceEnabled: SourceEnabled? = nil) {
        self.works = works; self.favorites = favorites; self.sync = sync; self.decoder = decoder
        self.baselineURL = baselineURL; self.now = now; self.timeZone = timeZone
        self.calendarLoader = calendarLoader ?? { force in try await bangumi.calendar(forceRefresh: force) }
        self.trendsLoader = trendsLoader ?? { force in try await bangumi.trendingSubjects(forceRefresh: force) }
        self.coverLoader = coverLoader ?? { id, force in try await bangumi.subjectCover(subjectID: id, forceRefresh: force) }
        self.catalogLoader = catalogLoader
        self.sourceEnabled = sourceEnabled ?? { decoder.isSourceEnabled($0) }
        do {
            if FileManager.default.fileExists(atPath: baselineURL.path) {
                baselines = try JSONDecoder().decode(Baselines.self, from: Data(contentsOf: baselineURL))
                if baselines.version != 1 { throw CocoaError(.fileReadCorruptFile) }
            }
        } catch { baselineLoadFailure = String(localized: "The durable source baseline could not be read.") }
    }

    static func production(works: WorkLibrary, favorites: FavoriteLibrary,
                           decoder: VideoDecoder = VideoDecoder()) throws -> DiscoveryService {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "IINA-ANI", isDirectory: true)
            .appendingPathComponent("Discovery", isDirectory: true)
        return DiscoveryService(works: works, favorites: favorites, sync: BangumiWorkSync(library: works),
                                decoder: decoder, baselineURL: root.appendingPathComponent("source-baselines-v1.json"))
    }

    /// Startup/foreground/day-change use the same-day snapshot; explicit refresh replaces it.
    func refresh(force: Bool = false) async throws -> DiscoverySnapshot {
        try Task.checkCancellation()
        let instant = now()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: instant)
        if !force, let snapshot, snapshot.day == day { return snapshot }
        if !force, workerDay == day, let worker { return try await worker.value }
        worker?.cancel()
        generation &+= 1
        let request = generation
        let task = Task { try await self.compute(day: day, force: force, request: request) }
        worker = task; workerDay = day
        defer { if generation == request { worker = nil; workerDay = nil } }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: { task.cancel() }
    }

    private func compute(day: Date, force: Bool, request: UInt64) async throws -> DiscoverySnapshot {
        let weekly: DiscoverySection<DiscoveryScheduledBroadcast>
        if !refreshPolicy.schedule {
            weekly = DiscoverySection(items: [], failure: String(localized: "排期刷新已停用。"))
        } else {
            do {
                let schedule = try await calendarLoader(force)
                var broadcasts: [(subject: BangumiSubject, weekday: Int)] = []
                var subjectIDs: [Int] = []
                var coverIndexByID: [Int: Int] = [:]
                for weekday in 1...7 {
                    var seen = Set<Int>()
                    for entry in schedule.value where entry.weekday == weekday {
                        for subject in entry.items where subject.type == 2 && subject.id > 0 && seen.insert(subject.id).inserted {
                            broadcasts.append((subject, weekday))
                            if coverIndexByID[subject.id] == nil {
                                coverIndexByID[subject.id] = subjectIDs.count
                                subjectIDs.append(subject.id)
                            }
                        }
                    }
                }
                let covers = try await scheduledCovers(subjectIDs, force: force)
                let items = broadcasts.map { broadcast in
                    DiscoveryScheduledBroadcast(subject: broadcast.subject, weekday: broadcast.weekday,
                        coverURL: coverIndexByID[broadcast.subject.id].flatMap { covers.urls[$0] },
                        evidence: String(localized: "Bangumi 每週放送；排期不代表播放來源已更新"))
                }
                var failures = schedule.failure.map { [String(localized: "Bangumi 日曆刷新失敗，顯示已儲存排期：\($0.localizedDescription)")] } ?? []
                if covers.failures > 0 { failures.append(String(localized: "\(covers.failures) 部作品頭圖刷新失敗；保留排期與可用舊圖。")) }
                weekly = DiscoverySection(items: items, failure: failures.isEmpty ? nil : failures.joined(separator: "\n"))
            } catch {
                try propagateCancellation(error)
                weekly = DiscoverySection(items: [], failure: String(localized: "Bangumi 日曆暫時無法取得。"))
            }
        }
        try Task.checkCancellation()
        let (updates, nextBaselines) = refreshPolicy.favoriteUpdates
            ? try await favoriteSources(force: force)
            : (DiscoverySection<DiscoveryFavoriteUpdate>(items: [], failure: String(localized: "收藏更新刷新已停用。")), baselines)
        try Task.checkCancellation()
        let recommendations = refreshPolicy.recommendations
            ? try await makeRecommendations(force: force)
            : DiscoverySection<DiscoveryRecommendation>(items: [], failure: String(localized: "推薦已停用。"))
        try Task.checkCancellation()
        guard generation == request else { throw CancellationError() }
        var committedUpdates = updates
        if refreshPolicy.favoriteUpdates, baselineLoadFailure == nil {
            do {
                try persist(nextBaselines)
                baselines = nextBaselines
            } catch {
                // Do not consume additions in memory if their durable commit failed.
                committedUpdates = DiscoverySection(items: [], failure: String(localized: "The durable source baseline could not be saved."))
            }
        }
        let value = DiscoverySnapshot(day: day, weeklyBroadcasts: weekly,
                                      favoriteUpdates: committedUpdates, recommendations: recommendations)
        snapshot = value
        return value
    }

    private func scheduledCovers(_ subjectIDs: [Int], force: Bool) async throws -> (urls: [String?], failures: Int) {
        let loader = coverLoader
        return try await withThrowingTaskGroup(of: (Int, String?, Bool).self) { group in
            func enqueue(_ index: Int) {
                let id = subjectIDs[index]
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let result = try await loader(id, force)
                        try Task.checkCancellation()
                        return (index, result.value, result.failure != nil)
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        return (index, nil, true)
                    }
                }
            }
            let limit = min(4, subjectIDs.count)
            for index in 0..<limit { enqueue(index) }
            var next = limit
            var urls = [String?](repeating: nil, count: subjectIDs.count)
            var failures = 0
            for try await (index, url, failed) in group {
                urls[index] = url
                if failed { failures += 1 }
                if next < subjectIDs.count { enqueue(next); next += 1 }
            }
            return (urls, failures)
        }
    }

    private func favoriteSources(force: Bool) async throws -> (DiscoverySection<DiscoveryFavoriteUpdate>, Baselines) {
        if let baselineLoadFailure { return (DiscoverySection(items: [], failure: baselineLoadFailure), baselines) }
        let favoriteWorks: [Work]
        do { favoriteWorks = try favorites.works() }
        catch { return (DiscoverySection(items: [], failure: String(localized: "Favorites could not be read.")), baselines) }
        let reports = try await sync.refreshFavorites(workIDs: favoriteWorks.map(\.id), forceRefresh: force)
        var failures: [String: String] = [:]
        for report in reports where report.failure != nil || report.read?.failure != nil {
            failures["bangumi:\(report.workID.uuidString)"] = String(localized: "Saved metadata retained; Bangumi refresh failed.")
        }
        var next = baselines
        var additions: [DiscoveryFavoriteUpdate] = []
        for work in favoriteWorks {
            try Task.checkCancellation()
            let links: [WorkSourceLink]
            do { links = try works.sourceLinks(forWorkID: work.id) }
            catch { failures[work.id.uuidString] = String(localized: "Source associations could not be read."); continue }
            for link in links where sourceEnabled(link.sourceWork.sourceID) {
                try Task.checkCancellation()
                let source = link.sourceWork.sourceID
                let key = link.id.uuidString
                do {
                    let identities = try await catalogIdentities(link.sourceWork)
                    let previous = next.seenByFavoriteSource[key]
                    let seen = Set(previous ?? [])
                    let hashed = Set(identities.map(Self.fingerprint))
                    let added = previous == nil ? [] : identities.filter { !seen.contains(Self.fingerprint($0)) }.sorted()
                    next.seenByFavoriteSource[key] = Array(seen.union(hashed)).sorted()
                    if !added.isEmpty {
                        additions.append(DiscoveryFavoriteUpdate(workID: work.id, workTitle: work.title,
                                                                  sourceID: source, newIdentities: added))
                    }
                } catch {
                    try propagateCancellation(error)
                    failures["\(source):\(link.id.uuidString)"] = String(localized: "Source catalog unavailable; previous baseline retained.")
                }
            }
        }
        additions.sort {
            if $0.workTitle != $1.workTitle { return $0.workTitle < $1.workTitle }
            if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
            return $0.workID.uuidString < $1.workID.uuidString
        }
        return (DiscoverySection(items: additions, failure: Self.failureSummary(failures)), next)
    }

    private func catalogIdentities(_ sourceWork: SourceItemRef) async throws -> Set<String> {
        if let catalogLoader { return Set(try await catalogLoader(sourceWork.pageURL)) }
        let choice = try await decoder.selection(for: sourceWork.pageURL)
        guard let catalog = try await decoder.catalog(for: choice) else { throw VideoGetError.notFountData }
        let leaves = catalog.nodes.flattened.flatMap { $0.children.filter(\.isLeaf) }
        guard !leaves.isEmpty else { throw VideoGetError.notFountData }
        return try Set(leaves.map { try decoder.episodeIdentity($0) })
    }

    private func makeRecommendations(force: Bool) async throws -> DiscoverySection<DiscoveryRecommendation> {
        do {
            let trends = try await trendsLoader(force)
            try Task.checkCancellation()
            var seen = Set<Int>()
            let items = trends.value.filter { $0.type == 2 && $0.id > 0 && seen.insert($0.id).inserted }
                .map { DiscoveryRecommendation(subject: $0, reasons: [String(localized: "Bangumi 動畫近期注目；依網站熱度順序，不代表可播放")]) }
            return DiscoverySection(items: items, failure: trends.failure.map {
                String(localized: "Bangumi 趨勢刷新失敗，顯示已儲存推薦：\($0.localizedDescription)")
            })
        } catch {
            try propagateCancellation(error)
            return DiscoverySection(items: [], failure: String(localized: "Bangumi 動畫趨勢暫時無法取得。"))
        }
    }
    private func propagateCancellation(_ error: Error) throws {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
    }
    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func failureSummary(_ failures: [String: String]) -> String? {
        failures.isEmpty ? nil : failures.keys.sorted().map { "\($0): \(failures[$0]!)" }.joined(separator: "\n")
    }
    private func persist(_ value: Baselines) throws {
        try FileManager.default.createDirectory(at: baselineURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: baselineURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: baselineURL.path)
    }
}
