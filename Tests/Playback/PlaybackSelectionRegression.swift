import Foundation
@testable import IINA_ANI

@main
struct PlaybackSelectionRegression {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    @MainActor static func main() async throws {
        let video = BiliVideo()
        let playInfo = Data(#"{"data":{"accept_quality":[80],"accept_description":["HD"],"quality":80,"timelength":10000,"durl":[{"url":"https://media.invalid/part.mp4","length":10000}]}}"#.utf8)
        let state = Data(#"{"p":1,"videoData":{"title":"Video","duration":10,"cid":101,"pages":[{"page":1,"cid":101,"part":"First"},{"page":2,"cid":202,"part":"Second"}]}}"#.utf8)
        do {
            _ = try await video.decodeBilibiliDatas("https://www.bilibili.com/video/BV1xx411c7mD?p=2", playInfoData: playInfo, initialStateData: state)
            throw Failure(message: "HTML returned first-part media for an explicit second-part request")
        } catch VideoGetError.notFountData {}
        let secondState = Data(#"{"p":2,"videoData":{"title":"Video","duration":10,"cid":202,"pages":[{"page":2,"cid":202,"part":"Second"},{"page":1,"cid":101,"part":"First"}]}}"#.utf8)
        let decoded = try await video.decodeBilibiliDatas("https://www.bilibili.com/video/BV1xx411c7mD?p=2", playInfoData: playInfo, initialStateData: secondState)
        try require(decoded.id == 202 && decoded.title == "Second", "HTML parts must use stable page identity, not array position")
        let singleState = Data(#"{"videoData":{"title":"Video title","duration":10,"cid":101,"pages":[{"page":1,"cid":101,"part":"P1"}]}}"#.utf8)
        let single = try await video.decodeBilibiliDatas("https://www.bilibili.com/video/BV1xx411c7mD", playInfoData: playInfo, initialStateData: singleState)
        try require(single.id == 101 && single.title == "Video title", "single-part playback must preserve the video title")
        do {
            _ = try await video.decodeBilibiliDatas("https://www.bilibili.com/video/BV1xx411c7mD?p=3", playInfoData: playInfo, initialStateData: secondState)
            throw Failure(message: "missing HTML part fell back to the current media")
        } catch VideoGetError.notFountData {}

        let catalogData = Data(#"{"data":{"bvid":"BV1xx411c7mD","title":"Video","pages":[{"cid":202,"page":2,"part":"Second","duration":20},{"cid":101,"page":1,"part":"First","duration":10}]}}"#.utf8)
        for id in ["BV1xx411c7mD", "av123"] {
            let catalog = try await video.videoCatalog(catalogData, url: "https://www.bilibili.com/video/" + id + "?p=2")
            try require(catalog.current == 0 && catalog.selected.id == "202" && catalog.selected.bvid == "BV1xx411c7mD", "BV and resolved av aliases must retain the requested part after reordering")
        }
        for query in ["BV1xx411c7mD?p=3", "BV1xx411c7mD?p=0", "BVwrong?p=1"] {
            do {
                _ = try await video.videoCatalog(catalogData, url: "https://www.bilibili.com/video/" + query)
                throw Failure(message: "missing or mismatched catalog identity fell back to another part")
            } catch VideoGetError.notFountData {}
        }
        let collectionData = Data(#"{"data":{"bvid":"BV1xx411c7mD","ugc_season":{"sections":[{"episodes":[{"bvid":"BVother","cid":303,"title":"Other","arc":{"pic":"https://image.invalid/other","duration":10}},{"bvid":"BV1xx411c7mD","cid":101,"title":"Chosen","arc":{"pic":"https://image.invalid/chosen","duration":10}}]}]}}}"#.utf8)
        let collection = try await video.videoCatalog(collectionData, url: "https://www.bilibili.com/video/BV1xx411c7mD")
        try require(collection.current == 1 && collection.selected.id == "101", "single-part collection entries must select the requested BV, not the first row")
        let episodes = [VideoTreeNode(site: .bangumi, title: "Second", id: "2"), VideoTreeNode(site: .bangumi, title: "First", id: "1")]
        let explicit = BilibiliUrl(url: "https://www.bilibili.com/bangumi/play/ep1")!
        let series = BilibiliUrl(url: "https://www.bilibili.com/bangumi/play/ss42")!
        try require(try explicit.episodeIndex(in: episodes) == 1, "explicit episodes must survive catalog reordering")
        try require(try series.episodeIndex(in: episodes) == 0, "series URLs must still open a catalog without an explicit episode")
        do {
            _ = try explicit.episodeIndex(in: [episodes[0]])
            throw Failure(message: "missing Bangumi episode fell back to the first episode")
        } catch VideoGetError.notFountData {}
        try autoplayCatalogs()
        try autoplayLocalFiles()
        try autoplayEOF()
        try retainedEOF()
        print("PASS: exact playback identities and autoplay sibling groups, source boundaries, local natural order and EOF-only completion")
    }

    static func autoplayCatalogs() throws {
        let registry = SourceRegistry()
        let work = try registry.item(for: "https://senfun.in/voddetail/42.html")
        func leaf(_ episode: Int, line: Int = 1) -> VideoTreeNode {
            VideoTreeNode(site: .senfun, index: episode, title: "第\(episode)集", id: "42",
                          url: "https://senfun.in/vodwatch/42/line\(line)_ep\(episode).html")
        }
        let first = leaf(1), second = leaf(2), otherLine = leaf(1, line: 2)
        let nested = [VideoTreeNode(title: "作品", children: [
            VideoTreeNode(title: "線路一", children: [first, second]),
            VideoTreeNode(title: "線路二", children: [otherLine, leaf(2, line: 2)])
        ])]
        let selected = PlayableSelection(item: work, episode: try registry.item(for: first.selectionURL),
            lineID: "pinned-line", qualityID: "HD", accountID: UUID(),
            classification: MediaClassification(kind: .anime, provenance: "manual"))
        let next = AutoplaySelection.next(after: selected, in: nested, registry: registry)
        var expected = selected
        expected.episode = try registry.item(for: second.selectionURL)
        try require(next == expected, "Autoplay must preserve work, account, classification, line and exact quality")
        try require(AutoplaySelection.next(after: expected, in: nested, registry: registry) == nil,
                    "The final sibling must stop instead of crossing to another line")
        try require(AutoplaySelection.completedItems(after: selected, in: nested, registry: registry) == nil,
                    "An intermediate episode cannot complete a season")
        try require(AutoplaySelection.completedItems(after: expected, in: nested, registry: registry) == [selected.episode!, expected.episode!],
                    "Season completion includes only the exact final episode's sibling group")
        try require(AutoplaySelection.completedItems(after: expected, in: [first, second, second], registry: registry) == nil,
                    "Ambiguous final identities cannot clear a season")
        var missing = selected
        missing.episode = try registry.item(for: leaf(99).selectionURL)
        try require(AutoplaySelection.next(after: missing, in: nested, registry: registry) == nil,
                    "Missing exact identity must not fall back to matching episode title/index or catalog current")
        try require(AutoplaySelection.completedItems(after: missing, in: nested, registry: registry) == nil,
                    "An unresolved next episode is not proof of season completion")
        let reordered = [VideoTreeNode(title: "線路", children: [second, first, leaf(3)])]
        try require(AutoplaySelection.next(after: selected, in: reordered, registry: registry)?.episode?.pageURL == leaf(3).selectionURL,
                    "The current identity, not a stale row number, determines the next sibling")
        try require(AutoplaySelection.next(after: selected, in: [first, second, first], registry: registry) == nil,
                    "Repeated current identities must not choose an arbitrary group")
        try require(AutoplaySelection.next(after: selected, in: [first, second, second], registry: registry) == nil,
                    "Repeated next identities must not create an ambiguous loop")
        let foreign = VideoTreeNode(site: .bangumi, title: "第2集", id: "2")
        try require(AutoplaySelection.next(after: selected, in: [first, foreign], registry: registry) == nil,
                    "Mixed-source catalogs must never cross to another source")
        var mismatched = selected
        mismatched.episode = SourceItemRef(sourceID: "bilibili", pageURL: first.selectionURL, kind: .episode)
        try require(AutoplaySelection.next(after: mismatched, in: nested, registry: registry) == nil,
                    "An episode source ID must agree with its work")
        let wrongSite = VideoTreeNode(site: .bangumi, title: "Forged", id: "2", url: first.selectionURL)
        try require(AutoplaySelection.next(after: selected, in: [wrongSite, second], registry: registry) == nil,
                    "A foreign leaf cannot claim the current source identity")
        var live = selected
        live.classification = MediaClassification(kind: .live, provenance: "manual")
        try require(AutoplaySelection.next(after: live, in: nested, registry: registry) == nil, "Live media never autoplays")
        let parts = [VideoTreeNode(site: .bilibili, index: 1, title: "P1", id: "101", bvid: "BV1xx411c7mD"),
                     VideoTreeNode(site: .bilibili, index: 2, title: "P2", id: "202", bvid: "BV1xx411c7mD")]
        let bili = PlayableSelection(item: try registry.item(for: "https://www.bilibili.com/video/BV1xx411c7mD"))
        try require(AutoplaySelection.next(after: bili, in: parts, registry: registry)?.item == (try registry.item(for: parts[1].selectionURL)),
                    "Canonical single-video URLs must match exactly the first Bilibili part")
    }

    static func autoplayLocalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("autoplay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Episode 10.mp4", "Episode 2.MKV", "Episode 1.mp4", "Episode 3.xml", "Episode 4.mp3", ".hidden.mp4"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let nested = root.appendingPathComponent("Episode 3.mp4", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("Episode 4.mp4"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Episode 5.mp4"),
                                                  withDestinationURL: nested.appendingPathComponent("Episode 4.mp4"))
        func local(_ name: String) -> PlayableSelection {
            PlayableSelection(item: SourceItemRef(sourceID: "local", pageURL: root.appendingPathComponent(name).absoluteString, kind: .local),
                              qualityID: "url", classification: MediaClassification(kind: .video, provenance: "manual"))
        }
        let first = local("Episode 1.mp4"), second = local("Episode 2.MKV"), last = local("Episode 10.mp4")
        try require(try AutoplaySelection.localNext(after: first) == second, "Local videos must use natural 1, 2, 10 order, not lexicographic order")
        try require(try AutoplaySelection.localNext(after: second) == last, "Only regular sibling video files may follow; no XML, audio, directories, symlinks or recursive files")
        try require(try AutoplaySelection.localNext(after: last) == nil, "The final local video must stop")
        try require(try AutoplaySelection.localNext(after: local("Episode 99.mp4")) == nil, "A missing local identity must never restart at the first file")
        try require(try AutoplaySelection.localCompletedItems(after: last) == [first.item, second.item, last.item],
                    "Local completion clears only eligible sibling videos")
        try require(try AutoplaySelection.localCompletedItems(after: second) == nil,
                    "A nonfinal local episode cannot clear the folder's history")
        try require(try AutoplaySelection.localCompletedItems(after: local("Episode 99.mp4")) == nil,
                    "A missing file cannot be mistaken for the end of a season")
        let ordered = [first, second, last]
        for selected in ordered {
            try require(try AutoplaySelection.localQueue(for: selected) == ordered,
                        "A local queue includes all eligible siblings, including files before middle/last selection")
        }
        var accountBound = second
        accountBound.accountID = UUID()
        try require(try AutoplaySelection.localQueue(for: accountBound).isEmpty,
                    "An account-bound selection cannot become an anonymous local queue")
        try require(try AutoplaySelection.localQueue(for: local("Episode 99.mp4")).isEmpty,
                    "A missing local selection must produce no queue")
        for name in ["Episode 3.xml", "Episode 4.mp3", ".hidden.mp4", "Episode 3.mp4", "Episode 5.mp4"] {
            try require(try AutoplaySelection.localQueue(for: local(name)).isEmpty,
                        "Ineligible selected files must not borrow the folder's video queue")
        }
        try Data("<i/>".utf8).write(to: root.appendingPathComponent("Episode 1.xml"))
        try require(AutoplaySelection.localDanmakuURL(for: first)?.lastPathComponent == "Episode 1.xml", "Local companion XML must use the same file stem")
        try require(AutoplaySelection.localDanmakuURL(for: second) == nil, "A next local episode must never inherit the previous episode XML")
        try Data("<i/>".utf8).write(to: root.appendingPathComponent("Episode 2.xml"))
        try require(AutoplaySelection.localDanmakuURL(for: second)?.lastPathComponent == "Episode 2.xml", "A next episode may use only its own companion XML")
    }

    final class Ends: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(failed: Bool, completed: Bool)] = []
        func append(_ failed: Bool, _ completed: Bool) { lock.lock(); defer { lock.unlock() }; values.append((failed, completed)) }
        var snapshot: [(failed: Bool, completed: Bool)] { lock.lock(); defer { lock.unlock() }; return values }
    }

    final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var positions: [Double] = []
        private var replies: [Int] = []
        func append(_ position: Double) { lock.lock(); defer { lock.unlock() }; positions.append(position) }
        func reply(_ id: Int) { lock.lock(); defer { lock.unlock() }; replies.append(id) }
        var count: Int { lock.lock(); defer { lock.unlock() }; return positions.count }
        var acknowledged: [Int] { lock.lock(); defer { lock.unlock() }; return replies }
    }

    static func autoplayEOF() throws {
        let path = "file:///isolated/Episode%201.mp4"
        func observer(_ events: Ends) -> PlaybackIPCHandler {
            PlaybackIPCHandler(paths: [path], progress: { _, _ in }, ended: { events.append($0, $1) })
        }
        func loaded(_ handler: PlaybackIPCHandler) {
            handler.receive(["event": "property-change", "name": "path", "data": path])
            handler.receive(["event": "property-change", "name": "duration", "data": 100.0])
            handler.receive(["event": "property-change", "name": "time-pos", "data": 99.99])
        }
        for reason in ["eof", "stop", "quit", "error", "unknown"] {
            let events = Ends(), handler = observer(events)
            loaded(handler)
            handler.receive(["event": "end-file", "reason": reason])
            handler.receive(["event": "end-file", "reason": "eof"])
            handler.receive(["event": "shutdown"])
            try require(events.snapshot.count == 1 && events.snapshot.first?.completed == (reason == "eof"),
                        "Only a real EOF may complete exactly once; proximity to duration, stop, quit or errors cannot autoplay")
        }
        let switched = Ends(), switchedHandler = observer(switched)
        loaded(switchedHandler)
        switchedHandler.receive(["event": "property-change", "name": "path", "data": "file:///another/episode.mp4"])
        switchedHandler.receive(["event": "end-file", "reason": "eof"])
        try require(switched.snapshot.count == 1 && switched.snapshot.first?.completed == false, "Changing media paths must suppress autoplay")
        for event in ["shutdown", "idle-active"] {
            let ended = Ends(), handler = observer(ended)
            loaded(handler)
            if event == "idle-active" { handler.receive(["event": "property-change", "name": event, "data": true]) }
            else { handler.receive(["event": event]) }
            handler.receive(["event": "end-file", "reason": "eof"])
            try require(ended.snapshot.count == 1 && ended.snapshot.first?.completed == false, "Shutdown and idle/closed windows must suppress later EOF")
        }
        let unseen = Ends(), unseenHandler = observer(unseen)
        unseenHandler.receive(["event": "property-change", "name": "path", "data": "file:///another/episode.mp4"])
        unseenHandler.receive(["event": "end-file", "reason": "eof"])
        try require(unseen.snapshot.isEmpty, "Another media window's EOF cannot complete the selected media")
        let redirected = Ends(), redirectHandler = observer(redirected)
        loaded(redirectHandler)
        redirectHandler.receive(["event": "end-file", "reason": "redirect"])
        try require(redirected.snapshot.isEmpty, "A load-hook redirect is not EOF")
        redirectHandler.receive(["event": "end-file", "reason": "eof"])
        try require(redirected.snapshot.first?.completed == true && unseen.snapshot.isEmpty, "Independent observers must remain isolated")
        let failed = Ends(), samples = Samples()
        let failedHandler = PlaybackIPCHandler(paths: [path], progress: { position, _ in samples.append(position) },
            ended: { failed.append($0, $1) }, requestReply: { id, _ in samples.reply(id) })
        failedHandler.receive(["event": "property-change", "name": "time-pos", "data": 30.0])
        failedHandler.receive(["event": "property-change", "name": "path", "data": path])
        failedHandler.receive(["event": "property-change", "name": "duration", "data": 100.0])
        failedHandler.receive(["event": "end-file", "reason": "error"])
        failedHandler.receive(["event": "end-file", "reason": "eof"])
        failedHandler.receive(["request_id": 7, "error": "success"])
        try require(samples.count == 0 && failed.snapshot.count == 1 &&
                    failed.snapshot.first?.failed == true && failed.snapshot.first?.completed == false,
                    "Unmatched/preload time and a failed load must not produce successful progress or natural completion")
        try require(samples.acknowledged == [7],
                    "Nonqueue resume seek acknowledgements must reach the request owner, even during teardown")
        let unloaded = Ends(), unloadedHandler = observer(unloaded)
        unloadedHandler.receive(["event": "property-change", "name": "path", "data": path])
        unloadedHandler.receive(["event": "end-file", "reason": "eof"])
        try require(unloaded.snapshot.first?.completed == false,
                    "EOF before file-loaded or actual backend time cannot complete an unconfirmed load")
    }
}

extension PlaybackSelectionRegression {
    static func retainedEOF() throws {
        let path = "file:///isolated/retained.mp4"
        let events = Ends()
        let handler = PlaybackIPCHandler(paths: [path], retainsEOF: true,
            progress: { _, _ in }, ended: { events.append($0, $1) })
        handler.receive(["event": "property-change", "name": "path", "data": path])
        handler.receive(["event": "property-change", "name": "time-pos", "data": 90.0])
        handler.receive(["event": "property-change", "name": "eof-reached", "data": true])
        handler.receive(["event": "end-file", "reason": "eof"])
        try require(events.snapshot.map(\.completed) == [true], "Retained EOF must advance once despite duplicate reports")
        handler.receive(["event": "seek"])
        handler.receive(["event": "property-change", "name": "eof-reached", "data": false])
        handler.receive(["event": "property-change", "name": "time-pos", "data": 12.0])
        handler.receive(["event": "property-change", "name": "eof-reached", "data": true])
        try require(events.snapshot.map(\.completed) == [true, true], "A real replay gets its own single EOF")
        handler.receive(["event": "shutdown"])
        handler.receive(["event": "end-file", "reason": "eof"])
        try require(events.snapshot.map(\.completed) == [true, true, false],
                    "Close remains observable after retained EOF and permanently suppresses late EOF")

        let stopped = Ends()
        let replacement = PlaybackIPCHandler(paths: [path], retainsEOF: true,
            progress: { _, _ in }, ended: { stopped.append($0, $1) })
        replacement.receive(["event": "property-change", "name": "path", "data": path])
        replacement.receive(["event": "property-change", "name": "time-pos", "data": 90.0])
        replacement.receive(["event": "end-file", "reason": "eof"])
        replacement.receive(["event": "start-file", "playlist_entry_id": 2])
        replacement.receive(["event": "end-file", "reason": "eof", "playlist_entry_id": 1])
        try require(stopped.snapshot.map(\.completed) == [true, false],
                    "Manual file replacement cancels the old retained owner instead of continuing it")
    }
}
