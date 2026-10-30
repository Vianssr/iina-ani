import Foundation
@testable import IINA_ANI

@main enum PlaybackHistoryRegression {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Playback/history.json")
        let store = try PlaybackHistoryStore(url: url)
        let work = SourceItemRef(sourceID: "senfun", pageURL: "https://www.senfun.in/voddetail/42.html", kind: .work)
        var first = PlayableSelection(item: work, episode: SourceItemRef(sourceID: work.sourceID,
            pageURL: "https://www.senfun.in/vodplay/42-1-1.html", kind: .episode), lineID: "1", qualityID: "HD", accountID: UUID(),
            classification: MediaClassification(kind: .anime, provenance: "fixture"))
        let neverLoaded = PlaybackProgressRecorder(store: store, selection: first, title: "動畫", coverURL: nil)
        neverLoaded.finish()
        try require(store.unfinished.isEmpty, "A submitted or failed launch must not invent playback")
        let player = PlaybackProgressRecorder(store: store, selection: first, title: "動畫", coverURL: "https://images.invalid/42.jpg?token=secret", episodeTitle: "第1集")
        player.update(position: 71.125, duration: 600)
        player.finish()
        let reopened = try PlaybackHistoryStore(url: url)
        let entry = try reopened.unfinished.first.unwrap()
        try require(entry.position == 71.125 && entry.duration == 600, "Fractional actual seconds must survive owner recreation")
        try require(entry.awaitingUpdates == nil, "Ordinary history without the optional EOF marker must remain compatible")
        try require(entry.episodeTitle == "第1集" && entry.selection.accountID == nil, "Episode label survives without account identity")
        try require(entry.coverURL == "https://images.invalid/42.jpg", "Cover signatures must not reach disk")
        first.qualityID = "4K"; first.lineID = "2"
        try reopened.record(selection: first, title: "動畫", coverURL: nil, position: 79.75, duration: 600, completed: false)
        try require(reopened.unfinished.count == 1, "Quality and line changes retain the same episode")
        var second = first
        second.episode = SourceItemRef(sourceID: work.sourceID, pageURL: "https://www.senfun.in/vodplay/42-1-2.html", kind: .episode)
        let secondPlayer = PlaybackProgressRecorder(store: reopened, selection: second, title: "動畫", coverURL: nil)
        secondPlayer.update(position: 2.5, duration: 600)
        try require(reopened.unfinished.count == 2, "Concurrent episode windows have independent entries")
        try require(reopened.unfinished.first?.position == 2.5, "A new episode never inherits another episode's progress")
        try reopened.record(selection: first, title: "動畫", coverURL: nil, position: 600, duration: 600, completed: true)
        try require(reopened.unfinished.count == 1 && reopened.unfinished.first?.selection.episode == second.episode, "Completion removes only its episode")
        var sensitive = first
        sensitive.item = SourceItemRef(sourceID: "senfun", pageURL: "https://www.senfun.in/watch?token=secret", kind: .video)
        do {
            try reopened.record(selection: sensitive, title: "secret", coverURL: nil, position: 20, duration: nil, completed: false)
            throw Failure(message: "Sensitive page URL was accepted")
        } catch is CocoaError {}
        let bytes = try String(contentsOf: url, encoding: .utf8)
        try require(!bytes.contains("secret") && !bytes.contains("accountID"), "Credentials and account data must never be serialized")
        try require(try PlaybackHistoryStore(url: url).unfinished.count == 1, "Completion survives restart")
        var live = second
        live.classification = MediaClassification(kind: .live, provenance: "source")
        try reopened.record(selection: live, title: "直播", coverURL: nil, position: 200, duration: nil, completed: false)
        try reopened.record(selection: second, title: "無效", coverURL: nil, position: .nan, duration: nil, completed: false)
        try require(reopened.unfinished.count == 1 && reopened.unfinished.first?.position == 2.5, "Live and invalid values cannot replace VOD progress")
        let local = PlayableSelection(item: SourceItemRef(sourceID: "local", pageURL: root.appendingPathComponent("動畫 第三集.mp4").absoluteString, kind: .local))
        let resolvedLocal = try await VideoDecoder().resolve(local)
        try require(resolvedLocal.title == "動畫 第三集.mp4", "Local resolution must emit the real file name, not an empty media title")
        try reopened.record(selection: local, title: " \n", coverURL: nil, position: 13.75, duration: 120, completed: false, episodeTitle: "  ")
        let localEntry = try reopened.unfinished.first.unwrap()
        try require(localEntry.title == "動畫 第三集.mp4" && localEntry.episodeTitle == nil, "Empty local metadata must use the real file name and absent episode label")
        let localReloaded = try PlaybackHistoryStore(url: url).unfinished.first.unwrap()
        try require(localReloaded.title == localEntry.title && localReloaded.episodeTitle == nil && localReloaded.position == 13.75, "Metadata normalization must survive reload without touching seconds")
        var archive = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var savedEntries = archive["entries"] as! [[String: Any]]
        let localIndex = savedEntries.firstIndex { $0["id"] as? String == localEntry.id }!
        savedEntries[localIndex]["title"] = ""; savedEntries[localIndex]["episodeTitle"] = " "
        archive["entries"] = savedEntries
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        let migrated = try PlaybackHistoryStore(url: url).unfinished.first.unwrap()
        try require(migrated.title == "動畫 第三集.mp4" && migrated.episodeTitle == nil && migrated.position == 13.75 &&
                    migrated.awaitingUpdates == nil, "Reopening pre-fix metadata without the optional EOF marker must preserve ordinary progress")
        var download = DownloadRecord(id: UUID(), selection: first, workID: UUID(), title: "本地作品",
            episodeTitle: "第1集", outputDirectory: root, temporaryDirectory: root, concurrencyLimit: 1,
            createdAt: Date(), updatedAt: Date())
        download.completedFile = URL(string: local.item.pageURL)
        download.coverURL = "https://images.invalid/local.jpg"
        let shelf = reopened.continuing(downloads: [download])
        let localCard = try shelf.first(where: { $0.id == localEntry.id }).unwrap()
        try require(localCard.title == "本地作品" && localCard.episodeTitle == "第1集" && localCard.coverURL == download.coverURL, "Old local history must receive downloaded episode metadata")
        try require(localCard.position == 13.75 && localCard.selection == localEntry.selection, "Enrichment must preserve exact local resume target and seconds")
        var otherDownload = download
        otherDownload.completedFile = root.appendingPathComponent("episode2.mp4")
        let otherLocal = PlayableSelection(item: SourceItemRef(sourceID: "local", pageURL: otherDownload.completedFile!.absoluteString, kind: .local))
        try reopened.record(selection: otherLocal, title: "file2", coverURL: nil, position: 42, duration: 120, completed: false)
        let latest = reopened.continuing(downloads: [download, otherDownload])
        try require(latest.filter { $0.title == "本地作品" }.count == 1 && latest.first?.position == 42, "One work must show only its latest watched local episode")
        try reopened.record(selection: local, title: "file1", coverURL: nil, position: 9, duration: 120, completed: false)
        try require(reopened.continuing(downloads: [download, otherDownload]).first?.position == 9, "Rewatching an earlier episode wins by time, never episode number or furthest position")
        try require(reopened.unfinished.first(where: { $0.selection == otherLocal })?.position == 42, "Hidden episodes retain independent progress")
        try animeOnlyShelf(root: root)
        try awaitingUpdateProgress(root: root)
        try manualDeletion(root: root)
        try await completedSeason(root: root)
        try staleRecorders(root: root)
        try configuredHistory(root: root)
        try localFileReferences(root: root)
        print("Playback history regressions passed: exact seconds, restart, native/source resume identity, configured file/revision safety, recorder/delete races, retained EOF, local bookmarks and reauthorization")
    }

    @MainActor static func staleRecorders(root: URL) throws {
        let url = root.appendingPathComponent("recorder-ownership/history.json")
        let store = try PlaybackHistoryStore(url: url)
        let selection = PlayableSelection(item: SourceItemRef(sourceID: "senfun",
            pageURL: "https://www.senfun.in/vodplay/42-1-1.html", kind: .episode))
        let older = PlaybackProgressRecorder(store: store, selection: selection, title: "Older", coverURL: nil)
        older.update(position: 10, duration: 120)
        let newer = PlaybackProgressRecorder(store: store, selection: selection, title: "Newer", coverURL: nil)
        newer.update(position: 40, duration: 120)
        older.update(position: 11, duration: 120, flush: true)
        older.finish(completed: true)
        try older.retainForUpdates(through: Date())
        try require(store.unfinished.first?.position == 40 && store.unfinished.first?.title == "Newer",
                    "Old actual progress, flush, EOF and delayed retention must not replace a newer same-episode player")
        let deleted = try store.unfinished.first.unwrap()
        try store.remove(id: deleted.id)
        newer.update(position: 45, duration: 120, flush: true)
        newer.finish()
        try newer.retainForUpdates(through: Date())
        try require(try PlaybackHistoryStore(url: url).unfinished.isEmpty,
                    "Deleting history must invalidate the old player's periodic update, close flush and EOF retention")
        do {
            _ = try store.selectionForResume(deleted)
            throw Failure(message: "A pending resume survived manual history deletion")
        } catch PlaybackFailure.cancelled {}
        let restarted = PlaybackProgressRecorder(store: store, selection: selection, title: "Explicit replay", coverURL: nil)
        restarted.update(position: 3, duration: 120)
        let recreated = try store.unfinished.first.unwrap()
        try require(recreated.id == deleted.id && recreated.position == 3,
                    "A fresh explicit player may recreate progress without changing persisted episode IDs")
        do {
            _ = try store.selectionForResume(deleted)
            throw Failure(message: "An old resume overwrote a newer replay of the same episode")
        } catch PlaybackFailure.cancelled {}
        let failed = PlaybackProgressRecorder(store: store, selection: selection, title: "Failed launch", coverURL: nil)
        failed.finish(completed: true)
        restarted.update(position: 4, duration: 120)
        try require(store.unfinished.first?.position == 4,
                    "A failed launch without actual samples must not take progress ownership from a real player")
        let directory = url.deletingLastPathComponent()
        let backup = root.appendingPathComponent("recorder-ownership-backup")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data().write(to: directory)
        do {
            try store.remove(id: recreated.id)
            throw Failure(message: "History deletion unexpectedly succeeded with inaccessible storage")
        } catch is CocoaError {}
        try require(store.unfinished.first?.position == 4,
                    "Failed deletion must retain the visible history transaction")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
        restarted.update(position: 5, duration: 120)
        try require(store.unfinished.first?.position == 5,
                    "Failed deletion must not revoke recorder ownership after storage recovers")
    }

    @MainActor static func configuredHistory(root: URL) throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repository.appendingPathComponent("Examples/MobileSources/internet-archive.json"))
        let directory = root.appendingPathComponent("configured-history/sources")
        let users = root.appendingPathComponent("configured-history/users")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("archive.json")
        try data.write(to: file)
        let registry = SourceRegistry(builtinDirectory: directory, userDirectory: users)
        let config = try SourceConfiguration.load(data: data)
        let work = try config.item("https://archive.org/details/season-one")
        let episode = try config.item(work.pageURL + "?file=episode%201.mp4")
        let classification = BangumiSubject(id: 400602, name: "Frieren", type: 2).classification
        let selection = PlayableSelection(item: work, episode: episode, lineID: "0", qualityID: "MP4",
            classification: classification)
        let url = root.appendingPathComponent("configured-history/history.json")
        let store = try PlaybackHistoryStore(url: url, registry: registry)
        let recorder = PlaybackProgressRecorder(store: store, selection: selection, title: "Archive", coverURL: nil)
        recorder.update(position: 25.5, duration: 120)
        let entry = try store.unfinished.first.unwrap()
        try require(entry.selection.episode == episode && entry.context?.configurationRevision == config.configurationRevision &&
                    entry.selection.classification == classification && store.continuing(downloads: []).first?.id == entry.id,
                    "Confirmed anime classification and exact configured identity must persist and appear in Continue Watching")
        try require(try store.selectionForResume(entry) == entry.selection,
                    "Unchanged configured history must retain its exact saved source and episode for resume")
        func leaf(_ ref: SourceItemRef, index: Int) -> VideoTreeNode {
            VideoTreeNode(site: .configured(config.id), index: index, title: "Same title", id: ref.pageURL, url: ref.pageURL)
        }
        let other = try config.item(work.pageURL + "?file=episode%202.mp4")
        let catalog = VideoSelectionCatalog(nodes: [VideoTreeNode(title: "Line", children: [leaf(other, index: 0), leaf(episode, index: 1)])],
                                            current: 0, selection: selection)
        try store.validateResumeCatalog(catalog, selection: entry.selection)
        try store.validateResolvedSelection(entry.selection, requested: entry.selection)
        do {
            try store.validateResumeCatalog(VideoSelectionCatalog(nodes: [leaf(other, index: 0)], current: 0, selection: selection),
                                            selection: entry.selection)
            throw Failure(message: "Missing saved file silently resumed another catalog entry")
        } catch PlaybackFailure.missingEpisode {}
        var wrong = selection
        wrong.episode = other
        do {
            try store.validateResolvedSelection(wrong, requested: entry.selection)
            throw Failure(message: "Resolved wrong file was accepted for resume")
        } catch PlaybackFailure.missingEpisode {}
        var changed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        changed["mediaHosts"] = ["archive.org", "cdn.archive.org"]
        try JSONSerialization.data(withJSONObject: changed).write(to: file)
        try registry.reload(builtinDirectory: directory, userDirectory: users)
        recorder.update(position: 26.5, duration: 120)
        let reopened = try PlaybackHistoryStore(url: url, registry: registry)
        let preserved = try reopened.unfinished.first.unwrap()
        try require(preserved.id == entry.id && preserved.context == entry.context && preserved.position == 26.5,
                    "An active recorder and archive reload must preserve original IDs and original configuration context")
        do {
            _ = try reopened.selectionForResume(preserved)
            throw Failure(message: "Changed source configuration silently adopted old history")
        } catch PlaybackFailure.configurationChanged {}
        do {
            try recorder.validateForLaunch()
            throw Failure(message: "Changed configuration was accepted at the final player handoff")
        } catch PlaybackFailure.configurationChanged {}
        var unsafe = changed
        var route = unsafe["route"] as! [String: Any]
        route["queryIdentityParameter"] = "access_token"
        unsafe["route"] = route
        try JSONSerialization.data(withJSONObject: unsafe).write(to: file)
        try registry.reload(builtinDirectory: directory, userDirectory: users)
        let unsafeConfig = try registry.source(for: config.id).unwrap()
        let sensitive = PlayableSelection(item: try unsafeConfig.item(work.pageURL),
            episode: try unsafeConfig.item(work.pageURL + "?access_token=private-value"))
        do {
            try reopened.record(selection: sensitive, title: "Unsafe", coverURL: nil, position: 10, duration: 120, completed: false)
            throw Failure(message: "Configuration expanded history into credential query persistence")
        } catch PlaybackFailure.unsupportedResponse {}
        try require(!String(decoding: Data(contentsOf: url), as: UTF8.self).contains("private-value"),
                    "Configured query identity must never expand the credential boundary")
        // Optional context fields do not change old native identities; old configured
        // records remain visible but cannot pretend their format version is a revision.
        var legacy = preserved
        legacy.context = nil
        do {
            _ = try reopened.selectionForResume(legacy)
            throw Failure(message: "Legacy configured progress without a revision silently resumed")
        } catch PlaybackFailure.configurationChanged {}
    }

    @MainActor static func localFileReferences(root: URL) throws {
        let folder = root.appendingPathComponent("local-references")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("episode.mp4")
        try Data("original media".utf8).write(to: original)
        let storeURL = folder.appendingPathComponent("state/history.json")
        let store = try PlaybackHistoryStore(url: storeURL)
        let selection = PlayableSelection(item: SourceItemRef(sourceID: "local", pageURL: original.absoluteString, kind: .local))
        try store.record(selection: selection, title: "Local", coverURL: nil, position: 12, duration: 120, completed: false)
        let entry = try store.unfinished.first.unwrap()
        try require(entry.localFile != nil, "Real desktop local progress must retain a durable file access reference")
        let impostor = folder.appendingPathComponent("other/episode.mp4")
        try FileManager.default.createDirectory(at: impostor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("another media".utf8).write(to: impostor)
        do {
            _ = try store.localFileForResume(entry, authorizedURL: impostor)
            throw Failure(message: "Same filename was accepted as local file identity")
        } catch is CocoaError {}
        let moved = folder.appendingPathComponent("renamed.mp4")
        try FileManager.default.moveItem(at: original, to: moved)
        let resumed = try store.localFileForResume(entry, authorizedURL: moved)
        let reopened = try PlaybackHistoryStore(url: storeURL)
        let preserved = try reopened.unfinished.first.unwrap()
        try require(resumed == moved && preserved.id == entry.id && preserved.selection == entry.selection &&
                    preserved.position == 12 && (try preserved.localFile?.matches(moved)) == true,
                    "Reauthorizing the actual moved file must renew access without migrating its history ID or progress")
        try Data("replacement at the old path".utf8).write(to: original)
        var actual = selection
        actual.item = SourceItemRef(sourceID: "local", pageURL: moved.absoluteString, kind: .local)
        let recorder = PlaybackProgressRecorder(store: store, selection: actual, title: "Moved local", coverURL: nil)
        recorder.update(position: 13, duration: 120)
        recorder.finish()
        let latest = try store.unfinished.first.unwrap()
        try require(store.unfinished.count == 1 && latest.id == entry.id && latest.position == 13 &&
                    (try latest.localFile?.matches(moved)) == true &&
                    (try latest.localFile?.matches(original)) == false,
                    "Actual moved-file queue loads must retain their original history ID and never recapture a replacement at the old path")
        let directory = storeURL.deletingLastPathComponent()
        let backup = folder.appendingPathComponent("state-backup")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data().write(to: directory)
        do {
            _ = try store.localFileForResume(latest)
            throw Failure(message: "History bookmark renewal unexpectedly saved into unavailable storage")
        } catch is CocoaError {}
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: backup, to: directory)
    }

    @MainActor static func manualDeletion(root: URL) throws {
        let url = root.appendingPathComponent("manual-deletion/history.json")
        let store = try PlaybackHistoryStore(url: url)
        let work = SourceItemRef(sourceID: "senfun", pageURL: "https://www.senfun.in/voddetail/42.html", kind: .work)
        let first = PlayableSelection(item: work, episode: SourceItemRef(sourceID: work.sourceID,
            pageURL: "https://www.senfun.in/vodplay/42-1-1.html", kind: .episode),
            classification: MediaClassification(kind: .anime, provenance: "fixture"))
        var second = first
        second.episode = SourceItemRef(sourceID: work.sourceID,
            pageURL: "https://www.senfun.in/vodplay/42-1-2.html", kind: .episode)
        let player = PlaybackProgressRecorder(store: store, selection: second, title: "動畫", coverURL: nil)
        try store.record(selection: first, title: "動畫", coverURL: nil, position: 12.5, duration: 120, completed: false)
        player.update(position: 120, duration: 120)
        let completedAt = Date()
        try player.retainForUpdates(through: completedAt)
        let deleted = try store.continuing(downloads: []).first.unwrap()
        try require(deleted.selection.episode == second.episode && deleted.awaitingUpdates == true,
                    "Deletion fixture must target the displayed retained EOF episode")
        try store.remove(id: deleted.id)
        try player.retainForUpdates(through: completedAt)
        let reopened = try PlaybackHistoryStore(url: url)
        try require(reopened.unfinished.map(\.selection.episode) == [first.episode] &&
                    reopened.unfinished.first?.position == 12.5,
                    "Manual deletion must survive restart and stale EOF lookup without deleting another episode")
        try store.remove(id: deleted.id)
        try require(store.continuing(downloads: []).first?.selection.episode == first.episode,
                    "Deleting an already removed identity must preserve the remaining work progress")
    }

    @MainActor static func animeOnlyShelf(root: URL) throws {
        let url = root.appendingPathComponent("anime-only/history.json")
        let store = try PlaybackHistoryStore(url: url)
        let anime = PlayableSelection(item: SourceItemRef(sourceID: "bilibili",
            pageURL: "https://www.bilibili.com/video/BVanime", kind: .video),
            classification: MediaClassification(kind: .anime, provenance: "fixture"))
        let video = PlayableSelection(item: SourceItemRef(sourceID: "bilibili",
            pageURL: "https://www.bilibili.com/video/BVordinary", kind: .video),
            classification: MediaClassification(kind: .video, provenance: "fixture"))
        let unknown = PlayableSelection(item: SourceItemRef(sourceID: "local",
            pageURL: root.appendingPathComponent("番劇名稱.mp4").absoluteString, kind: .local))
        for choice in [anime, video, unknown] {
            try store.record(selection: choice, title: "番劇名稱", coverURL: nil,
                position: 30, duration: 120, completed: false)
        }
        try require(store.continuing(downloads: []).map(\.selection) == [anime],
            "Continue Watching must use anime classification, not site, title or local filename")
        let reopened = try PlaybackHistoryStore(url: url)
        try require(reopened.continuing(downloads: []).map(\.selection) == [anime] && reopened.unfinished.count == 3,
            "Existing ordinary and unknown progress must remain stored but hidden after restart")
    }

    @MainActor static func awaitingUpdateProgress(root: URL) throws {
        let url = root.appendingPathComponent("awaiting-updates/history.json")
        let store = try PlaybackHistoryStore(url: url)
        let selection = PlayableSelection(item: SourceItemRef(sourceID: "local",
            pageURL: root.appendingPathComponent("awaiting-updates.mp4").absoluteString, kind: .local),
            classification: MediaClassification(kind: .anime, provenance: "fixture"))
        let empty = PlaybackProgressRecorder(store: store, selection: selection, title: "未播放", coverURL: nil)
        try empty.retainForUpdates(through: Date())
        try require(store.unfinished.isEmpty, "Retention must not invent progress for a never-loaded player")

        let eof = PlaybackProgressRecorder(store: store, selection: selection, title: "追更作品",
            coverURL: "https://images.invalid/awaiting.jpg?token=secret", episodeTitle: "第12集")
        eof.update(position: 120.25, duration: 120.25)
        eof.finish(completed: true)
        try require(store.unfinished.isEmpty, "Ordinary completion must still remove its episode before policy retention")
        let cutoff = Date()
        try eof.retainForUpdates(through: cutoff)
        try eof.retainForUpdates(through: cutoff)
        let retained = try store.unfinished.first.unwrap()
        try require(retained.awaitingUpdates == true && retained.position == 120.25 && retained.duration == 120.25,
                    "Retained EOF must keep real completed seconds, never fabricate an unfinished offset")
        try require(retained.title == "追更作品" && retained.episodeTitle == "第12集" &&
                    retained.coverURL == "https://images.invalid/awaiting.jpg" && retained.updatedAt == cutoff,
                    "Retention must preserve recorder metadata with the original EOF cutoff")
        let reloaded = try PlaybackHistoryStore(url: url)
        let card = try reloaded.continuing(downloads: []).first.unwrap()
        try require(card.awaitingUpdates == true && card.position == 120.25 && card.duration == 120.25,
                    "EOF at the exact duration and its Continue Watching marker must survive restart")

        let replay = PlaybackProgressRecorder(store: reloaded, selection: selection, title: "重播", coverURL: nil)
        replay.update(position: 3.5, duration: 120.25)
        let replayed = try reloaded.unfinished.first.unwrap()
        try require(replayed.awaitingUpdates == nil && replayed.position == 3.5,
                    "Real replay progress must clear the EOF flag without inheriting completed seconds")
        let replayReloaded = try PlaybackHistoryStore(url: url).unfinished.first.unwrap()
        try require(replayReloaded.awaitingUpdates == nil && replayReloaded.position == 3.5,
                    "Cleared replay markers must remain ordinary history after restart")

        replay.finish(completed: true)
        let replayCutoff = Date()
        let restarting = PlaybackProgressRecorder(store: reloaded, selection: selection, title: "重新開始", coverURL: nil)
        restarting.update(position: 0, duration: 120.25)
        try replay.retainForUpdates(through: replayCutoff)
        try require(reloaded.unfinished.isEmpty, "A stale completion must not restore EOF over a newer zero-position restart")
        restarting.update(position: 0.25, duration: 120.25)
        try replay.retainForUpdates(through: replayCutoff)
        try require(reloaded.unfinished.isEmpty, "Even throttled progress must prevent an older EOF from replacing a replay")
        restarting.update(position: 8, duration: 120.25)
        try replay.retainForUpdates(through: replayCutoff)
        try require(reloaded.unfinished.first?.position == 8 && reloaded.unfinished.first?.awaitingUpdates == nil,
                    "A newer persisted replay must never be overwritten by an older completion")

        let overshoot = PlaybackProgressRecorder(store: reloaded, selection: selection, title: "EOF", coverURL: nil)
        overshoot.update(position: 120.5, duration: 120.25, completed: true)
        try overshoot.retainForUpdates(through: Date())
        let overshot = try PlaybackHistoryStore(url: url).unfinished.first.unwrap()
        try require(overshot.awaitingUpdates == true && overshot.position == 120.5 && overshot.duration == 120.25,
                    "Real EOF positions beyond duration must also reload unchanged when awaiting updates")
    }

    @MainActor static func completedSeason(root: URL) async throws {
        let suite = "season-history." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.autoPlayNext = false
        let storage = root.appendingPathComponent("season-store")
        let services = AppServices(preferences: preferences, storage: { AppStoragePaths(applicationSupport: storage) })
        let store = try services.playbackHistory()
        let folder = root.appendingPathComponent("season")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func local(_ name: String) -> PlayableSelection {
            PlayableSelection(item: SourceItemRef(sourceID: "local", pageURL: folder.appendingPathComponent(name).absoluteString, kind: .local),
                classification: MediaClassification(kind: .anime, provenance: "fixture"))
        }
        let first = local("01.mp4"), last = local("02.mp4"), missing = local("03.mp4")
        for choice in [first, last] { try Data().write(to: URL(string: choice.item.pageURL)!) }
        let unrelated = PlayableSelection(item: SourceItemRef(sourceID: "local", pageURL: root.appendingPathComponent("other-season/01.mp4").absoluteString, kind: .local))
        for choice in [first, last, unrelated] {
            try store.record(selection: choice, title: "Same title", coverURL: nil, position: 12, duration: 120, completed: false)
        }
        _ = try await services.player.completeEpisode(after: missing)
        _ = try await services.player.completeEpisode(after: first)
        try require(store.unfinished.count == 3, "Missing and intermediate episodes must retain the season's earlier progress")
        let eof = PlaybackProgressRecorder(store: store, selection: last, title: "Same title", coverURL: nil)
        eof.update(position: 120, duration: 120, completed: true)
        let next = try await services.player.completeEpisode(after: last, recorder: eof)
        try require(next == nil && store.unfinished.count == 3 &&
                    store.unfinished.contains { $0.selection == first && $0.position == 12 } &&
                    store.unfinished.contains { $0.selection == unrelated && $0.position == 12 },
                    "An unlinked local folder's last file must not prove that a season finished or erase earlier progress")
        let retainedEOF = try store.unfinished.first(where: { $0.selection == last }).unwrap()
        try require(retainedEOF.awaitingUpdates == true && retainedEOF.position == 120 && retainedEOF.duration == 120,
                    "An unconfirmed final episode must retain its real EOF card even with autoplay disabled")
        let reloaded = try PlaybackHistoryStore(url: storage.appendingPathComponent("Playback/history-v1.json"))
        let reopenedEOF = try reloaded.continuing(downloads: []).first(where: { $0.selection == last }).unwrap()
        try require(reloaded.unfinished.count == 3 && reopenedEOF.awaitingUpdates == true &&
                    reopenedEOF.position == 120 && reopenedEOF.duration == 120,
                    "Unconfirmed EOF and earlier local progress must survive restarting Continue Watching")

        let middleEOF = PlaybackProgressRecorder(store: store, selection: first, title: "Ongoing season", coverURL: nil)
        middleEOF.update(position: 120, duration: 120, completed: true)
        let disabledNext = try await services.player.completeEpisode(after: first, recorder: middleEOF)
        try require(disabledNext == nil &&
                    store.unfinished.contains { $0.selection == first && $0.awaitingUpdates == true },
                    "With autoplay off, finishing an intermediate episode must retain the season card rather than erase it")

        let missingEOF = PlaybackProgressRecorder(store: store, selection: missing, title: "Missing catalog episode", coverURL: nil)
        missingEOF.update(position: 120, duration: 120, completed: true)
        let missingNext = try await services.player.completeEpisode(after: missing, recorder: missingEOF)
        try require(missingNext == nil &&
                    store.unfinished.contains { $0.selection == missing && $0.awaitingUpdates == true && $0.position == 120 },
                    "A completed episode absent from its current catalog must retain its EOF record")
        try require(FileManager.default.fileExists(atPath: URL(string: first.item.pageURL)!.path),
                    "History completion must not delete downloaded/local media")

        let registry = SourceRegistry()
        let one = try registry.item(for: "https://senfun.in/vodwatch/42/line1_ep1.html")
        let two = try registry.item(for: "https://senfun.in/vodwatch/42/line1_ep2.html")
        let otherLine = try registry.item(for: "https://senfun.in/vodwatch/42/line2_ep1.html")
        for item in [one, two, otherLine] {
            try store.record(selection: PlayableSelection(item: item), title: "Same title", coverURL: nil, position: 9, duration: 120, completed: false)
        }
        let cutoff = Date()
        try store.record(selection: PlayableSelection(item: one), title: "Rewatch", coverURL: nil, position: 21, duration: 120, completed: false)
        try store.removeCompletedSeason([one, two], through: cutoff, registry: registry)
        try require(store.unfinished.contains { $0.selection.item == one && $0.position == 21 },
                    "A newer update during catalog resolution must not be deleted")
        try require(!store.unfinished.contains { $0.selection.item == two } &&
                    store.unfinished.contains { $0.selection.item == otherLine },
                    "Cleanup must remove only exact season page identities, not matching titles or other lines")
        await services.shutdown()
    }
}
private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw PlaybackHistoryRegression.Failure(message: "Missing history entry") }
        return self
    }
}
