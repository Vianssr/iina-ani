import Foundation
@testable import IINA_ANI

@main
struct WorkspaceDetailEpisodeRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    @MainActor static func main() {
        for title in ["", " \t\n", "\u{3000}", "未知", " 標題未知\n", "标题未知", "Unknown", " UNKNOWN "] {
            check(!WorkspaceDetailEpisodeAvailability.isUpdatedTitle(title), "unknown/blank names are omitted from display and local-only rows")
        }
        for title in ["第一集", "0", "SP", "未來", "未知的旅程", "Unknown World", "  第二集  "] {
            check(WorkspaceDetailEpisodeAvailability.isUpdatedTitle(title), "known names must not be hidden by substring or date guesses")
        }
        let now = Date(timeIntervalSince1970: 1_793_232_000) // 2026-10-29 UTC
        let realUnnamedEpisode = BangumiEpisode(id: 912433, type: 0, sort: 1, name: "", airdate: "")
        check(WorkspaceDetailEpisodeAvailability.isAvailable(realUnnamedEpisode, now: now), "real Big Buck Bunny episode identity remains selectable without a title or date")
        check(WorkspaceDetailEpisodeAvailability.index(for: "bangumi:912433", bangumi: [realUnnamedEpisode], local: []) == 0, "unknown-date episode retains its real ID/type/sort instead of becoming an updating placeholder")
        for date in [nil, "", "unknown", "2026-02-30", "2026-1-01"] as [String?] {
            let episode = BangumiEpisode(id: 12, type: 1, sort: 0, name: "", airdate: date)
            check(WorkspaceDetailEpisodeAvailability.isAvailable(episode, now: now), "absent or invalid airdate cannot be guessed from an empty title")
        }
        check(WorkspaceDetailEpisodeAvailability.isAvailable(BangumiEpisode(id: 13, type: 0, sort: 1, name: "", airdate: "2008-04-10"), now: now), "an aired episode does not require a title")
        check(!WorkspaceDetailEpisodeAvailability.isAvailable(BangumiEpisode(id: 14, type: 0, sort: 1, name: "Named future episode", airdate: "2999-01-01"), now: now), "a known future airdate blocks even a named episode")
        let midnightJST = Date(timeIntervalSince1970: 1_793_199_600) // 2026-10-28 15:00 UTC
        let release = BangumiEpisode(id: 15, type: 0, sort: 1, name: "Release", airdate: "2026-10-29")
        check(!WorkspaceDetailEpisodeAvailability.isAvailable(release, now: midnightJST.addingTimeInterval(-1)), "known future episode remains blocked before its JST release date")
        check(WorkspaceDetailEpisodeAvailability.isAvailable(release, now: midnightJST), "episode becomes selectable at its JST release date")


        let workID = UUID()
        let pendingLocal = Episode(workID: workID, kind: .special, label: "\t", sort: 0)
        let availableLocal = Episode(workID: workID, kind: .opening, label: "Opening", sort: 1)
        let local = [pendingLocal, availableLocal]
        let bangumi = [
            BangumiEpisode(id: 11, type: 0, sort: 1, name: "", airdate: "2999-01-01"),
            BangumiEpisode(id: 22, type: 0, sort: 2, name: "Second"),
            BangumiEpisode(id: 33, type: 1, sort: 1, name: "標題未知", airdate: "2999-01-01"),
            BangumiEpisode(id: 44, type: 0, sort: 4, name: "Fourth", nameCN: "第四集")
        ]
        check(WorkspaceDetailEpisodeAvailability.index(for: "bangumi:11", bangumi: bangumi, local: local) == nil, "known future metadata cannot be selected")
        check(WorkspaceDetailEpisodeAvailability.index(for: "bangumi:33", bangumi: bangumi, local: local) == nil, "known future SP cannot be selected")
        check(WorkspaceDetailEpisodeAvailability.index(for: "bangumi:22", bangumi: bangumi, local: local) == 1, "hidden preceding episodes cannot renumber the selected metadata row")
        check(WorkspaceDetailEpisodeAvailability.index(for: "bangumi:44", bangumi: bangumi, local: local) == 3, "gaps and mixed kinds cannot shift mapping indices")
        check(WorkspaceDetailEpisodeAvailability.index(for: availableLocal.id.uuidString, bangumi: bangumi, local: local) == 5, "local row offset includes all metadata and preceding hidden local episodes")
        check(WorkspaceDetailEpisodeAvailability.index(for: pendingLocal.id.uuidString, bangumi: bangumi, local: local) == nil, "pending local entries cannot be selected")
        check(WorkspaceDetailEpisodeAvailability.index(for: "updating", bangumi: bangumi, local: local) == nil, "the placeholder has no selectable episode identity")
        check(WorkspaceDetailEpisodeAvailability.index(for: "bangumi:999", bangumi: bangumi, local: local) == nil, "removed selections cannot fall back to another episode")

        let reordered = [bangumi[3], bangumi[0], bangumi[2], bangumi[1]]
        check(WorkspaceDetailEpisodeAvailability.index(for: "bangumi:22", bangumi: reordered, local: local) == 3, "selection survives reorder by identity, not previous index")
        let updated = [BangumiEpisode(id: 11, type: 0, sort: 1, name: "First"), bangumi[1]]
        check(WorkspaceDetailEpisodeAvailability.index(for: "bangumi:11", bangumi: updated, local: []) == 0, "newly named episodes become selectable under the same identity")
        let withdrawn = [BangumiEpisode(id: 22, type: 0, sort: 2, name: " \n")]
        check(WorkspaceDetailEpisodeAvailability.index(for: "bangumi:22", bangumi: withdrawn, local: local) == 0, "losing a title must not invalidate an identified unknown-date episode")
        check(WorkspaceDetailEpisodeAvailability.index(for: availableLocal.id.uuidString, bangumi: [], local: [availableLocal]) == 0, "local-only works retain their own row identity")
        check(WorkspaceDetailEpisodeAvailability.index(for: "bangumi:22", bangumi: [], local: []) == nil, "empty metadata cannot retain a stale selection")
        let source = SourceItemRef(sourceID: "senfun", pageURL: "https://example.test/work/1", kind: .work)
        let leaf = SourceItemRef(sourceID: "senfun", pageURL: "https://example.test/episode/1", kind: .episode)
        let selection = PlayableSelection(item: source, episode: leaf, lineID: "1", qualityID: "HD")
        var otherQuality = selection
        otherQuality.qualityID = "SD"
        check(WorkspaceCompletedDownloads.same(selection, otherQuality), "a completed episode remains downloaded across quality choices")
        let anotherEpisode = PlayableSelection(item: source, episode: SourceItemRef(sourceID: "senfun", pageURL: "https://example.test/episode/2", kind: .episode))
        check(!WorkspaceCompletedDownloads.same(selection, anotherEpisode), "adjacent episodes cannot inherit a completion badge")
        let canonical = Episode(workID: workID, externalID: "bangumi:22", label: "Second", sort: 2)
        var link = WorkSourceLink(workID: workID, sourceWork: source, episodeMappings: [.init(episodeID: canonical.id, selection: selection)])
        check(WorkspaceCompletedDownloads.key(for: selection, links: [link], episodes: [canonical]) == "bangumi:22", "confirmed mapping must retain the canonical episode identity")
        check(WorkspaceCompletedDownloads.key(for: anotherEpisode, links: [link], episodes: [canonical]) == nil, "catalog position or title cannot invent a mapping")
        link.episodeMappings.append(.init(episodeID: availableLocal.id, selection: selection))
        check(WorkspaceCompletedDownloads.key(for: selection, links: [link], episodes: [canonical, availableLocal]) == nil, "conflicting mappings cannot mark a different episode downloaded")
        print("PASS: detail episode availability, stable identities, raw mapping indices, refresh, local-only and completion-mapping boundaries")
    }
}
