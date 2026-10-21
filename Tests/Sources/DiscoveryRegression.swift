import CoreData
import Foundation
@testable import IINA_ANI

@main
@MainActor
struct DiscoveryRegression {
    actor LoadCounter {
        private(set) var count = 0
        func increment() { count += 1 }
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
        let works = WorkLibrary(container: container), favorites = FavoriteLibrary(container: container)
        let work = try works.createLocalWork(title: "Local favorite")
        try favorites.addWork(workID: work.id)
        let sourceWork = SourceItemRef(sourceID: "sourceA", pageURL: "https://catalog.invalid/work/17?credential=never-persist", kind: .work)
        try works.upsert(WorkSourceLink(workID: work.id, sourceWork: sourceWork))
        try works.upsert(WorkSourceLink(workID: work.id,
            sourceWork: SourceItemRef(sourceID: "sourceB", pageURL: "https://catalog.invalid/broken/23", kind: .work)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = root.appendingPathComponent("durable/baseline.json")
        var date = ISO8601DateFormatter().date(from: "2026-10-06T03:00:00Z")!
        let zone = TimeZone(identifier: "Asia/Tokyo")!
        let state = CatalogState(["ep-a", "ep-b"])
        let scheduled = BangumiSubject(id: 7, name: "Scheduled", date: "2026-10-06", type: 2)
        let current = BangumiSubject(id: 71, name: "Fall show", date: "2026-10-01", type: 2)
        let old = BangumiSubject(id: 72, name: "Old show", date: "2026-07-01", type: 2)
        let upcoming = BangumiSubject(id: 73, name: "Unannounced date", type: 2)
        let comic = BangumiSubject(id: 74, name: "Comic", type: 1)
        let service = DiscoveryService(works: works, favorites: favorites, sync: BangumiWorkSync(library: works),
            decoder: VideoDecoder(), baselineURL: baseline, now: { date }, timeZone: zone,
            calendarLoader: { _ in result([BangumiCalendarDay(weekday: 2, items: [scheduled, scheduled])]) },
            trendsLoader: { _ in result([old, current, old, upcoming, comic]) },
            coverLoader: cover,
            catalogLoader: { url in
                if url.contains("broken") { throw Failure("Unreachable fixture source") }
                return await state.identities()
            }, sourceEnabled: { _ in true })
        let first = try await service.refresh()
        try require(first.weeklyBroadcasts.items.map(\.subject.id) == [7], "weekday and dedupe must be deterministic")
        try require(first.favoriteUpdates.items.isEmpty && first.favoriteUpdates.failure != nil, "first observation seeds without updates; broken source is isolated")
        try require(first.recommendations.items.map(\.subject.id) == [72, 71, 73],
                    "trends preserve upstream order and include old/undated anime without playable-source matching; duplicate/non-anime subjects are excluded")
        try require(first.recommendations.failure == nil, "a broken playback source must not fail Bangumi recommendations")
        let stored = try String(contentsOf: baseline, encoding: .utf8)
        try require(!stored.contains("credential") && !stored.contains("ep-a"), "persistent baselines contain opaque fingerprints, not page credentials")
        await state.set(["ep-b", "ep-a"])
        let reordered = try await service.refresh(force: true)
        try require(reordered.favoriteUpdates.items.isEmpty, "reorder is not new content")
        await state.set(["ep-b"]); _ = try await service.refresh(force: true)
        await state.set(["ep-a", "ep-b"])
        let readded = try await service.refresh(force: true)
        try require(readded.favoriteUpdates.items.isEmpty, "re-added known identity is not a second event")
        await state.set(["ep-a", "ep-b", "ep-c"])
        let cached = try await service.refresh()
        try require(cached.favoriteUpdates.items.isEmpty, "same-day refresh uses snapshot until forced")
        let added = try await service.refresh(force: true)
        try require(added.favoriteUpdates.items.map(\.newIdentities) == [["ep-c"]], "a new identity must generate one event")
        let repeated = try await service.refresh(force: true)
        try require(repeated.favoriteUpdates.items.isEmpty, "the committed event must not repeat")
        let restored = DiscoveryService(works: works, favorites: favorites, sync: BangumiWorkSync(library: works),
            decoder: VideoDecoder(), baselineURL: baseline, now: { date }, timeZone: zone,
            calendarLoader: { _ in result([BangumiCalendarDay(weekday: 2, items: [scheduled])]) }, trendsLoader: { _ in result([]) },
            coverLoader: cover, catalogLoader: { _ in await state.identities() }, sourceEnabled: { $0 == "sourceA" })
        let reopened = try await restored.refresh()
        try require(reopened.favoriteUpdates.items.isEmpty && reopened.recommendations.items.isEmpty, "reopen retains baseline; no inputs gives no fake recommendations")
        date = ISO8601DateFormatter().date(from: "2026-10-06T15:01:00Z")!
        let nextDay = try await restored.refresh()
        try require(nextDay.day != reopened.day && nextDay.weeklyBroadcasts.items.map(\.subject.id) == [7], "local midnight refreshes the snapshot without hiding other weekdays")
        try nativeEpisodeIdentity()
        let disabledLoads = LoadCounter()
        let disabled = DiscoveryService(works: works, favorites: favorites, sync: BangumiWorkSync(library: works),
            decoder: VideoDecoder(), baselineURL: baseline, now: { date },
            calendarLoader: { _ in await disabledLoads.increment(); return result([]) },
            trendsLoader: { _ in await disabledLoads.increment(); return result([]) },
            coverLoader: { _, _ in await disabledLoads.increment(); return result("https://lain.bgm.tv/pic/cover/l/unused.jpg") },
            catalogLoader: { _ in await disabledLoads.increment(); return [] })
        let beforeDisable = try Data(contentsOf: baseline)
        disabled.setRefreshPolicy(DiscoveryRefreshPolicy(schedule: false, favoriteUpdates: false, recommendations: false))
        let disabledResult = try await disabled.refresh(force: true)
        try require(await disabledLoads.count == 0 && disabledResult.weeklyBroadcasts.failure != nil, "disabled refresh cannot invoke loaders or masquerade as empty success")
        try require(try Data(contentsOf: baseline) == beforeDisable, "disabled updates cannot consume or erase baselines")
        disabled.setRefreshPolicy(DiscoveryRefreshPolicy(schedule: true, favoriteUpdates: false, recommendations: false))
        _ = try await disabled.refresh()
        try require(await disabledLoads.count == 1, "re-enable invalidates same-day disabled snapshot without enabling other loaders")
        try await cancelledRefreshDoesNotCommit(works: works, favorites: favorites, root: root)
        try await detachedPresentationRetainsSharedRefresh(works: works, favorites: favorites, root: root)
        try await bangumiSectionFailures(works: works, favorites: favorites, root: root)
        try await weeklySubjectCovers(works: works, favorites: favorites, root: root)
        print("PASS W7 discovery: Bangumi calendar/trend order, no playback-source dependency, partial/stale failures, durable additions once, local day and cancellation")
    }

    private static func nativeEpisodeIdentity() throws {
        let first = VideoTreeNode(site: .xiFan, index: 2, title: "2", id: "17", url: "https://dm1.xfdm.pro/watch/17/1/2.html")
        let otherLine = VideoTreeNode(site: .xiFan, index: 2, title: "Renamed", id: "17", url: "https://dm1.xfdm.pro/watch/17/2/2.html")
        let next = VideoTreeNode(site: .xiFan, index: 3, title: "3", id: "17", url: "https://dm1.xfdm.pro/watch/17/1/3.html")
        let a = try SourceRegistry.shared.episodeIdentity(for: first), b = try SourceRegistry.shared.episodeIdentity(for: otherLine), c = try SourceRegistry.shared.episodeIdentity(for: next)
        try require(a == b && a != c, "native work ID alone conflates episodes; delivery lines and labels must not invent episodes")
    }

    private static func cancelledRefreshDoesNotCommit(works: WorkLibrary, favorites: FavoriteLibrary, root: URL) async throws {
        let gate = Gate(), baseline = root.appendingPathComponent("cancelled.json")
        let service = DiscoveryService(works: works, favorites: favorites, sync: BangumiWorkSync(library: works),
            decoder: VideoDecoder(), baselineURL: baseline,
            calendarLoader: { _ in await gate.pause(); return result([]) }, trendsLoader: { _ in result([]) },
            coverLoader: cover, catalogLoader: { _ in ["episode"] })
        let pending = Task { try await service.refresh() }
        await gate.waitUntilPaused(); pending.cancel(); await gate.resume()
        do { _ = try await pending.value; throw Failure("Cancellation was swallowed") } catch is CancellationError {}
        try require(!FileManager.default.fileExists(atPath: baseline.path) && service.snapshot == nil,
                    "cancelled refresh must not consume baseline additions or publish a snapshot")
    }
    private static func detachedPresentationRetainsSharedRefresh(works: WorkLibrary, favorites: FavoriteLibrary, root: URL) async throws {
        let gate = Gate()
        let subject = BangumiSubject(id: 700, name: "Shared schedule", date: "2026-10-06", type: 2)
        let service = DiscoveryService(works: works, favorites: favorites, sync: BangumiWorkSync(library: works),
            decoder: VideoDecoder(), baselineURL: root.appendingPathComponent("shared-presentation.json"),
            now: { ISO8601DateFormatter().date(from: "2026-10-06T03:00:00Z")! }, timeZone: TimeZone(secondsFromGMT: 0)!,
            calendarLoader: { _ in await gate.pause(); return Self.result([BangumiCalendarDay(weekday: 2, items: [subject])]) },
            trendsLoader: { _ in Self.result([]) }, coverLoader: cover, catalogLoader: { _ in [] })
        let removedPanel = Task { try await service.presentationSnapshot() }
        await gate.waitUntilPaused()
        let remainingPanel = Task { try await service.presentationSnapshot() }
        removedPanel.cancel()
        await gate.resume()
        let result = try await remainingPanel.value
        _ = try await removedPanel.value
        try require(result.weeklyBroadcasts.items.map(\.subject.id) == [700] && service.snapshot?.weeklyBroadcasts.items.map(\.subject.id) == [700],
                    "removing a presentation cannot cancel another panel or the app-owned refresh")
    }
    nonisolated private static func cover(_ id: Int, _ force: Bool) async throws -> BangumiResult<String> {
        result("https://lain.bgm.tv/pic/cover/l/\(id).jpg")
    }
    private static func weeklySubjectCovers(works: WorkLibrary, favorites: FavoriteLibrary, root: URL) async throws {
        let gate = Gate(), loads = LoadCounter()
        let subjects = (1...8).map { BangumiSubject(id: $0, name: "Show \($0)", coverURL: "https://api.invalid/wrong.jpg", type: 2) }
        let service = DiscoveryService(works: works, favorites: favorites, sync: BangumiWorkSync(library: works),
            decoder: VideoDecoder(), baselineURL: root.appendingPathComponent("subject-covers.json"),
            now: { ISO8601DateFormatter().date(from: "2026-10-06T03:00:00Z")! }, timeZone: TimeZone(secondsFromGMT: 0)!,
            calendarLoader: { _ in result([BangumiCalendarDay(weekday: 7, items: [subjects[6]]),
                                          BangumiCalendarDay(weekday: 3, items: [subjects[0], subjects[0], BangumiSubject(id: 99, name: "Tomorrow", type: 2)]),
                                          BangumiCalendarDay(weekday: 1, items: []),
                                          BangumiCalendarDay(weekday: 5, items: [subjects[4]]),
                                          BangumiCalendarDay(weekday: 2, items: subjects + [subjects[0]]),
                                          BangumiCalendarDay(weekday: 6, items: [subjects[5]]),
                                          BangumiCalendarDay(weekday: 4, items: [subjects[3]]),
                                          BangumiCalendarDay(weekday: 2, items: [subjects[0]])]) },
            trendsLoader: { _ in result([]) }, coverLoader: { id, _ in
                await loads.increment()
                if id == 1 { await gate.pause() }
                if id == 2 { throw BangumiError.httpStatus(503) }
                if id == 3 { return BangumiResult(value: "https://lain.bgm.tv/pic/cover/l/old.jpg", origin: .staleCache, failure: .httpStatus(503)) }
                return try await cover(id, false)
            }, sourceEnabled: { _ in false })
        service.setRefreshPolicy(DiscoveryRefreshPolicy(schedule: true, favoriteUpdates: false, recommendations: false))
        let pending = Task { try await service.refresh() }
        await gate.waitUntilPaused()
        while await loads.count < 9 { await Task.yield() }
        await gate.resume()
        let snapshot = try await pending.value
        try require(snapshot.weeklyBroadcasts.items.map(\.subject.id) == Array(1...8) + [1, 99, 4, 5, 6, 7], "out-of-order covers preserve weekday order, within-day order and cross-day broadcasts while deduplicating each day")
        try require(snapshot.weeklyBroadcasts.items.map(\.weekday) == Array(repeating: 2, count: 8) + [3, 3, 4, 5, 6, 7], "Monday through Sunday ordering includes every populated day and leaves the empty Monday empty")
        try require(await loads.count == 9, "only distinct subjects across the week require introduction pages")
        let covers = snapshot.weeklyBroadcasts.items.map(\.coverURL)
        try require(covers[0] == "https://lain.bgm.tv/pic/cover/l/1.jpg" && covers[1] == nil && covers[2] == "https://lain.bgm.tv/pic/cover/l/old.jpg" && snapshot.weeklyBroadcasts.failure != nil,
                    "weekly artwork uses subject pages, keeps stale covers and reports failures without falling back to API images")
        try require(covers[8] == covers[0] && covers[10] == covers[3], "cross-day broadcasts reuse each subject cover")
        let cached = try await service.refresh()
        try require(await loads.count == 9 && cached.weeklyBroadcasts.items.count == snapshot.weeklyBroadcasts.items.count, "same-day presentation refresh cannot duplicate cover requests")
        let empty = DiscoveryService(works: works, favorites: favorites, sync: BangumiWorkSync(library: works),
            decoder: VideoDecoder(), baselineURL: root.appendingPathComponent("empty-week.json"),
            calendarLoader: { _ in result((1...7).reversed().map { BangumiCalendarDay(weekday: $0, items: []) }) },
            trendsLoader: { _ in result([]) }, coverLoader: { _, _ in
                await loads.increment(); throw Failure("Empty days must not request a cover")
            }, sourceEnabled: { _ in false })
        empty.setRefreshPolicy(DiscoveryRefreshPolicy(schedule: true, favoriteUpdates: false, recommendations: false))
        let emptyWeek = try await empty.refresh()
        try require(await loads.count == 9 && emptyWeek.weeklyBroadcasts.items.isEmpty && emptyWeek.weeklyBroadcasts.failure == nil, "an entirely empty week is an empty success without artwork requests")
    }
    nonisolated private static func result<T: Sendable>(_ value: T) -> BangumiResult<T> {
        BangumiResult(value: value, origin: .network, failure: nil)
    }
    private static func bangumiSectionFailures(works: WorkLibrary, favorites: FavoriteLibrary, root: URL) async throws {
        let subject = BangumiSubject(id: 812, name: "Trending without a playback source", type: 2)
        let instant = ISO8601DateFormatter().date(from: "2026-10-06T03:00:00Z")!
        let failedCalendar = DiscoveryService(works: works, favorites: favorites, sync: BangumiWorkSync(library: works),
            decoder: VideoDecoder(), baselineURL: root.appendingPathComponent("calendar-failure.json"),
            now: { instant }, timeZone: TimeZone(secondsFromGMT: 0)!,
            calendarLoader: { _ in throw BangumiError.httpStatus(503) },
            trendsLoader: { _ in result([subject]) }, coverLoader: cover, sourceEnabled: { _ in false })
        let independent = try await failedCalendar.refresh()
        try require(independent.weeklyBroadcasts.failure != nil && independent.weeklyBroadcasts.items.isEmpty &&
                    independent.recommendations.items.map(\.subject.id) == [812] && independent.recommendations.failure == nil,
                    "calendar failure and disabled playback sources cannot erase trends")
        let failedTrends = DiscoveryService(works: works, favorites: favorites, sync: BangumiWorkSync(library: works),
            decoder: VideoDecoder(), baselineURL: root.appendingPathComponent("trends-failure.json"),
            now: { instant }, timeZone: TimeZone(secondsFromGMT: 0)!,
            calendarLoader: { _ in result([BangumiCalendarDay(weekday: 2, items: [subject])]) },
            trendsLoader: { _ in throw BangumiError.invalidResponse("Missing catalog") }, coverLoader: cover, sourceEnabled: { _ in false })
        let partial = try await failedTrends.refresh()
        try require(partial.weeklyBroadcasts.items.map(\.subject.id) == [812] && partial.weeklyBroadcasts.failure == nil &&
                    partial.recommendations.items.isEmpty && partial.recommendations.failure != nil,
                    "a failed trends page is not an empty success and cannot hide calendar")
        let stale = DiscoveryService(works: works, favorites: favorites, sync: BangumiWorkSync(library: works),
            decoder: VideoDecoder(), baselineURL: root.appendingPathComponent("stale-feeds.json"),
            now: { instant }, timeZone: TimeZone(secondsFromGMT: 0)!,
            calendarLoader: { _ in BangumiResult(value: [BangumiCalendarDay(weekday: 2, items: [subject])],
                                                origin: .staleCache, failure: .httpStatus(503), fetchedAt: instant) },
            trendsLoader: { _ in BangumiResult(value: [subject], origin: .staleCache, failure: .httpStatus(503), fetchedAt: instant) },
            coverLoader: cover, sourceEnabled: { _ in false })
        let retained = try await stale.refresh()
        try require(retained.weeklyBroadcasts.items.map(\.subject.id) == [812] && retained.weeklyBroadcasts.failure != nil &&
                    retained.recommendations.items.map(\.subject.id) == [812] && retained.recommendations.failure != nil,
                    "stale Bangumi data must remain visible together with refresh failures")
    }
    private actor Gate {
        var paused = false
        var continuation: CheckedContinuation<Void, Never>?
        func pause() async { paused = true; await withCheckedContinuation { continuation = $0 } }
        func waitUntilPaused() async { while !paused { await Task.yield() } }
        func resume() { continuation?.resume(); continuation = nil }
    }
    private actor CatalogState {
        var values: [String]
        init(_ values: [String]) { self.values = values }
        func identities() -> [String] { values }
        func set(_ values: [String]) { self.values = values }
    }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
