import Cocoa
import Darwin
@testable import IINA_ANI

/// Opt-in integration, using a real local mpv and the application-owned playback services.
@main enum PlaybackHistoryPlayerSmoke {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(".build/playback-history-smoke")
        let media = root.appendingPathComponent("fixture.mp4")
        if ProcessInfo.processInfo.environment["LOCAL_QUEUE_SMOKE"] == "1" {
            try await localQueueSmoke(root: root)
            return
        }
        if ProcessInfo.processInfo.environment["HISTORY_EOF_ONLY"] == "1" {
            try await eofSmoke(media: media, root: root)
            return
        }
        if ProcessInfo.processInfo.environment["RETAINED_EOF_SMOKE"] == "1" {
            try await retainedEOFSmoke(media: media, root: root)
            return
        }
        try require(FileManager.default.fileExists(atPath: media.path), "Generate the 120-second local fixture first")
        let storage = root.appendingPathComponent(UUID().uuidString)
        let historyURL = storage.appendingPathComponent("Playback/history-v1.json")
        let store = try PlaybackHistoryStore(url: historyURL)
        let choice = PlayableSelection(item: SourceItemRef(sourceID: "local", pageURL: media.absoluteString, kind: .local))
        let recorder = PlaybackProgressRecorder(store: store, selection: choice, title: "續播測試作品", coverURL: nil, episodeTitle: "第1集")
        let observer = try PlayerProgressSession(recorder: recorder, paths: [media.absoluteString, media.path]) { _ in }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mpv")
        process.arguments = ["--no-config", "--vo=null", "--ao=null", "--idle=yes", "--start=37.25", "--input-ipc-server=\(observer.socketURL.path)", media.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); observer.observe()
        defer { if process.isRunning { process.terminate() } }
        try await waitUntil { store.unfinished.first?.position ?? 0 >= 39 }
        let actualFirst = try command(observer.socketURL, ["get_property", "time-pos"])["data"] as? Double ?? -1
        _ = try command(observer.socketURL, ["quit"])
        try await waitUntil { !process.isRunning }
        await observer.stop()
        let reopened = try PlaybackHistoryStore(url: historyURL)
        guard let entry = reopened.unfinished.first else { throw Failure(message: "Real mpv position was not persisted") }
        try require(abs(actualFirst - entry.position) < 2, "Persisted position differs from actual mpv time-pos")
        let suite = "playback-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.livePlayer = .mpv; preferences.enableFlvjs = false; preferences.enableDanmaku = false
        let services = AppServices(preferences: preferences, storage: { AppStoragePaths(applicationSupport: storage) })
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))
        try await services.resumePlayback(entry)
        let owner = try services.playbackHistory()
        try await waitUntil { owner.unfinished.first?.position ?? 0 > entry.position + 1 }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))
        guard let directory = after.subtracting(before).first(where: { $0.hasPrefix("vp-") }) else { throw Failure(message: "Resume did not create an isolated socket") }
        let socket = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(directory).appendingPathComponent("ipc")
        let actualResume = try command(socket, ["get_property", "time-pos"])["data"] as? Double ?? -1
        try require(actualResume >= entry.position && actualResume < entry.position + 10, "AppServices resume did not actually seek to saved seconds")
        _ = try command(socket, ["quit"])
        await services.shutdown()
        let final = try PlaybackHistoryStore(url: historyURL)
        try require(final.unfinished.first?.position ?? 0 >= entry.position, "Resumed playback did not persist")
        let report: [String: Any] = ["initialMPVPosition": actualFirst, "savedPosition": entry.position,
            "resumedMPVPosition": actualResume, "historyPath": historyURL.path, "mediaPath": media.path,
            "result": "PASS real mpv IPC → persistence → new owner → AppServices.resolve/resume → real mpv position"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence.json"), options: .atomic)
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
    @MainActor static func eofSmoke(media: URL, root: URL) async throws {
        let url = root.appendingPathComponent("eof-history.json")
        let store = try PlaybackHistoryStore(url: url)
        let choice = PlayableSelection(item: SourceItemRef(sourceID: "local", pageURL: media.absoluteString, kind: .local))
        let recorder = PlaybackProgressRecorder(store: store, selection: choice, title: "EOF", coverURL: nil)
        let observer = try PlayerProgressSession(recorder: recorder, paths: [media.absoluteString, media.path]) { _ in }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mpv")
        process.arguments = ["--no-config", "--vo=null", "--ao=null", "--start=117", "--input-ipc-server=\(observer.socketURL.path)", media.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); observer.observe()
        defer { if process.isRunning { process.terminate() } }
        try await waitUntil { !store.unfinished.isEmpty }
        try await waitUntil { !process.isRunning && store.unfinished.isEmpty }
        await observer.stop()
        try require(try PlaybackHistoryStore(url: url).unfinished.isEmpty, "Actual mpv EOF must remove completed history after restart")
        try Data("PASS: real mpv end-file/eof removed persisted history; reloaded owner is empty\n".utf8).write(to: root.appendingPathComponent("eof-evidence.txt"))
        print("PASS: real mpv EOF removes history and stays removed after reopening")
    }
    /// Real IPC/session integration; application launch wiring is exercised separately by the parent.
    @MainActor static func localQueueSmoke(root: URL) async throws {
        let fm = FileManager.default
        func executable(_ name: String) throws -> URL {
            let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
                + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            guard let path = directories.map({ URL(fileURLWithPath: $0).appendingPathComponent(name) })
                .first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
                throw Failure(message: "LOCAL_QUEUE_SMOKE requires installed \(name) in PATH or Homebrew bin")
            }
            return path
        }
        let ffmpeg = try executable("ffmpeg"), mpv = try executable("mpv")
        let storage = root.appendingPathComponent("queue-" + UUID().uuidString)
        let fixtures = storage.appendingPathComponent("media")
        try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let names = ["Episode 1 雪.mp4", "Episode 2 \"quoted\".mp4", "Episode 10\nfinal.mp4"]
        let source = fixtures.appendingPathComponent(names[0])
        let generator = Process()
        generator.executableURL = ffmpeg
        generator.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
            "color=c=black:s=64x64:r=10", "-t", "30", "-c:v", "mpeg4", "-y", source.path]
        generator.standardOutput = FileHandle.nullDevice
        try generator.run()
        generator.waitUntilExit()
        try require(generator.terminationStatus == 0, "ffmpeg fixture generation failed")
        for name in names.dropFirst() { try fm.copyItem(at: source, to: fixtures.appendingPathComponent(name)) }
        let suite = "local-queue-smoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let selected = PlayableSelection(item: SourceItemRef(sourceID: "local",
            pageURL: fixtures.appendingPathComponent(names[1]).absoluteString, kind: .local),
            qualityID: "url", classification: MediaClassification(kind: .video, provenance: "manual"))
        let queue = try AutoplaySelection.localQueue(for: selected)
        try require(queue.map { URL(string: $0.item.pageURL)!.lastPathComponent } == names,
                    "Fixture queue is not natural ordered")
        var evidence: [[String: Any]] = []
        for enabled in [true, false] {
            preferences.autoPlayNext = enabled
            let historyURL = storage.appendingPathComponent(enabled ? "enabled/history.json" : "disabled/history.json")
            let store = try PlaybackHistoryStore(url: historyURL)
            func recorder(_ choice: PlayableSelection) -> PlaybackProgressRecorder {
                PlaybackProgressRecorder(store: store, selection: choice,
                    title: URL(string: choice.item.pageURL)!.lastPathComponent, coverURL: nil)
            }
            var eofSelections: [PlayableSelection] = []
            let observer = try PlayerProgressSession(recorder: recorder(selected),
                paths: [selected.item.pageURL, URL(string: selected.item.pageURL)!.path],
                localQueue: queue, nativePlaylist: !enabled, initialStartPosition: 7.25,
                makeRecorder: { recorder($0) }, onQueueEOF: { active in
                    eofSelections.append(active.selection)
                    guard preferences.autoPlayNext else { return nil }
                    return try AutoplaySelection.localNext(after: active.selection)
                }, queueItemOptions: { enabled ? [:] : ["referrer": $0.item.pageURL] }, onFinish: { _ in })
            let process = Process()
            process.executableURL = mpv
            process.arguments = ["--no-config", "--vo=null", "--ao=null", "--idle=yes",
                "--keep-open=always", "--loop-file=no", "--loop-playlist=no", "--pause=yes",
                "--start=7.25", "--force-media-title=INITIAL SELECTED TITLE",
                "--input-ipc-server=\(observer.socketURL.path)"] +
                (observer.playlistURL == nil ? [] : ["--playlist-start=1"]) +
                [observer.playlistURL?.path ?? URL(string: selected.item.pageURL)!.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            observer.observe()
            defer { if process.isRunning { process.terminate() } }
            let socket = observer.socketURL, pid = process.processIdentifier
            func property(_ name: String) throws -> Any? {
                let response = try command(socket, ["get_property", name])
                try require(response["error"] as? String == "success", "mpv get \(name) failed: \(response)")
                return response["data"]
            }
            func send(_ values: [Any]) throws {
                let response = try command(socket, values)
                try require(response["error"] as? String == "success", "mpv command failed: \(response)")
            }
            try await waitUntil {
                guard let playlist = try? property("playlist") as? [[String: Any]] else { return false }
                return playlist.count == queue.count && (try? property("playlist-pos") as? Int) == 1 &&
                    (enabled || (try? property("referrer") as? String) == selected.item.pageURL)
            }
            let playlist = try property("playlist") as? [[String: Any]] ?? []
            try require(playlist.compactMap { $0["filename"] as? String } == queue.map { URL(string: $0.item.pageURL)!.path },
                        "Actual mpv playlist must contain every sibling in natural order")
            try require(try property("playlist-pos") as? Int == 1, "Initial selected middle episode changed")
            try await waitUntil { (try? property("time-pos") as? Double) != nil }
            let initialPosition = try property("time-pos") as? Double ?? -1
            try require(abs(initialPosition - 7.25) < 0.5, "Initial resume offset was lost")
            try send(["set_property", "pause", false])
            try await waitUntil { store.unfinished.contains { $0.selection == selected && $0.position >= 7 } }
            try require(observer.playbackState.hasLoadedMedia &&
                        (observer.playbackState.actualPosition ?? -1) >= 7,
                        "Matched real IPC must confirm shared loaded state and actual progress")
            var previousLoad = observer.playbackState.identity
            for index in (enabled ? [0, 2] : [0, 1, 2]) {
                try send(["set_property", "playlist-pos", index])
                try send(["set_property", "pause", true])
                try await waitUntil {
                    (try? property("path") as? String) == URL(string: queue[index].item.pageURL)!.path &&
                        observer.playbackState.identity != previousLoad && observer.playbackState.phase == .loaded
                }
                try require((try property("time-pos") as? Double ?? 99) < 2,
                            "Manual queue selection inherited the initial resume offset")
                try require(try property("media-title") as? String != "INITIAL SELECTED TITLE",
                            "Following files inherited the previous force-media-title")
                if !enabled {
                    try require(try property("referrer") as? String == queue[index].item.pageURL,
                                "Native playlist import lost per-file playback metadata")
                }
                try send(["seek", 4, "absolute+exact"])
                try send(["set_property", "pause", false])
                try await waitUntil {
                    observer.playbackState.identity != previousLoad &&
                        observer.playbackState.phase == .loaded &&
                        (observer.playbackState.actualPosition ?? -1) >= 4 &&
                        store.unfinished.contains { $0.selection == queue[index] && $0.position >= 4 }
                }
                previousLoad = observer.playbackState.identity
            }
            try require(store.unfinished.contains { $0.selection == selected } &&
                        store.unfinished.contains { $0.selection == queue[0] },
                        "Skipping must preserve independent previous-file history")
            try send(["set_property", "playlist-pos", 0])
            try await waitUntil {
                (try? property("path") as? String) == URL(string: queue[0].item.pageURL)!.path &&
                    observer.playbackState.identity != previousLoad && observer.playbackState.phase == .loaded
            }
            try send(["seek", 29, "absolute+exact"])
            try send(["set_property", "pause", false])
            try await waitUntil { eofSelections.count == 1 }
            if enabled {
                do {
                    try await waitUntil { (try? property("playlist-pos") as? Int) == 1 &&
                        store.unfinished.contains { $0.selection == selected && $0.position > 0 && $0.position < 5 } }
                } catch {
                    throw Failure(message: "Queue EOF failed: index=\(String(describing: try? property("playlist-pos"))) time=\(String(describing: try? property("time-pos"))) pause=\(String(describing: try? property("pause"))) history=\(store.unfinished.map { ($0.selection.item.pageURL, $0.position) })")
                }
                try require(try property("pause") as? Bool == false, "Autoplay must unpause the next file")
            } else {
                try await Task.sleep(for: .seconds(1))
                try require(try property("playlist-pos") as? Int == 0, "Disabled autoplay advanced natively")
                try require(try property("eof-reached") as? Bool == true, "Disabled autoplay did not retain EOF")
                try require(observer.playbackState.phase == .ended,
                            "Actual keep-open EOF must terminate the shared load without advancing")
            }
            try require(eofSelections == [queue[0]], "Natural EOF must be reported exactly once for the active identity")
            try require(process.isRunning && process.processIdentifier == pid && observer.socketURL == socket,
                        "Queue transition replaced the original player process/socket")
            try require(!store.unfinished.contains { $0.selection == queue[0] }, "Completed file history was not removed")
            if !enabled {
                let completedLoad = observer.playbackState.identity
                try send(["seek", 4, "absolute+exact"])
                try send(["set_property", "pause", false])
                try await waitUntil {
                    observer.playbackState.identity != completedLoad && observer.playbackState.phase == .loaded &&
                        store.unfinished.contains { $0.selection == queue[0] && $0.position >= 4 && $0.position < 8 }
                }
                try require(eofSelections == [queue[0]], "Replay was incorrectly completed by the previous EOF")
            }
            _ = try command(socket, ["quit"])
            try await waitUntil { !process.isRunning }
            await observer.stop()
            let reopened = try PlaybackHistoryStore(url: historyURL)
            try require(reopened.unfinished.contains { $0.selection == queue[2] },
                        "Manually selected later-file history did not survive reopening")
            evidence.append(["autoplay": enabled, "pid": pid, "socket": socket.path,
                "initialPosition": initialPosition, "playlist": playlist, "historyPath": historyURL.path])
        }
        for cancel in [true, false] {
            let store = try PlaybackHistoryStore(url: storage.appendingPathComponent("delayed-\(cancel)/history.json"))
            preferences.autoPlayNext = true
            var completion: CheckedContinuation<PlayableSelection?, Never>?
            var callbacks = 0
            func recorder(_ choice: PlayableSelection) -> PlaybackProgressRecorder {
                PlaybackProgressRecorder(store: store, selection: choice, title: "Delayed queue", coverURL: nil)
            }
            let observer = try PlayerProgressSession(recorder: recorder(queue[0]),
                paths: [queue[0].item.pageURL, URL(string: queue[0].item.pageURL)!.path],
                localQueue: queue, autoplayEnabled: { preferences.autoPlayNext }, makeRecorder: { recorder($0) },
                onQueueEOF: { _ in
                    callbacks += 1
                    return await withCheckedContinuation { completion = $0 }
                }, onFinish: { _ in })
            let process = Process()
            process.executableURL = mpv
            process.arguments = ["--no-config", "--vo=null", "--ao=null", "--idle=yes",
                "--keep-open=always", "--start=28", "--input-ipc-server=\(observer.socketURL.path)",
                URL(string: queue[0].item.pageURL)!.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); observer.observe()
            defer { if process.isRunning { process.terminate() } }
            try await waitUntil { completion != nil }
            if cancel { observer.cancelPendingNextEpisode() } else { preferences.autoPlayNext = false }
            completion?.resume(returning: queue[1]); completion = nil
            try await Task.sleep(for: .milliseconds(400))
            let position = try command(observer.socketURL, ["get_property", "playlist-pos"])["data"] as? Int
            try require(position == 0 && callbacks == 1, "Cancelled/disabled delayed EOF advanced the queue")
            try require(!store.unfinished.contains { $0.selection.item == queue[1].item }, "Unplayed next file acquired history")
            try await observer.nextLocalEpisode()
            try await waitUntil {
                observer.selection.item == queue[1].item && observer.playbackState.phase == .loaded &&
                    (observer.playbackState.actualPosition ?? 0) > 0
            }
            _ = try command(observer.socketURL, ["quit"])
            try await waitUntil { !process.isRunning }
            await observer.stop()
        }
        print("PASS real delayed local EOF cancellation/disable, followed by explicit manual next")
        let report: [String: Any] = ["result": "PASS real local queue IPC/history/EOF enabled+disabled",
            "ffmpeg": ffmpeg.path, "mpv": mpv.path, "fixtures": fixtures.path, "runs": evidence]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: storage.appendingPathComponent("queue-evidence.json"), options: .atomic)
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
    @MainActor static func retainedEOFSmoke(media: URL, root: URL) async throws {
        let file = root.appendingPathComponent("retained-" + UUID().uuidString + "/history.json")
        let store = try PlaybackHistoryStore(url: file)
        let choice = PlayableSelection(item: SourceItemRef(sourceID: "local", pageURL: media.absoluteString, kind: .local))
        func recorder() -> PlaybackProgressRecorder {
            PlaybackProgressRecorder(store: store, selection: choice, title: "Retained EOF", coverURL: nil)
        }
        var completions = 0
        var closed = false
        let observer = try PlayerProgressSession(recorder: recorder(), paths: [media.absoluteString, media.path],
            retainsEOF: true, makeRecorder: { _ in recorder() },
            onEOF: { _ in completions += 1 }, onFinish: { _ in closed = true })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/mpv")
        process.arguments = ["--no-config", "--vo=null", "--ao=null", "--keep-open=always",
            "--start=117", "--input-ipc-server=\(observer.socketURL.path)", media.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); observer.observe()
        defer { if process.isRunning { process.terminate() } }
        try await waitUntil { completions == 1 }
        let endedIdentity = observer.playbackState.identity
        try require(process.isRunning && observer.canAdvance && !closed, "EOF lost the cancellable player owner")
        _ = try command(observer.socketURL, ["seek", 12.0, "absolute+exact"])
        _ = try command(observer.socketURL, ["set_property", "pause", false])
        try await waitUntil {
            observer.playbackState.identity != endedIdentity &&
                observer.playbackState.phase == .loaded && (store.unfinished.first?.position ?? 0) >= 12
        }
        let actual = try command(observer.socketURL, ["get_property", "time-pos"])["data"] as? Double ?? -1
        try require(abs(actual - (store.unfinished.first?.position ?? -100)) < 2, "Replay did not own actual history")
        _ = try command(observer.socketURL, ["quit"])
        try await waitUntil { closed && !process.isRunning }
        try require(completions == 1, "Closing replay triggered a second natural EOF")
        print("PASS real retained EOF → new replay load/history → close, one EOF; actual replay position \(actual)")
    }
    @MainActor static func waitUntil(line: Int = #line, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try require(predicate(), "Real-player condition timed out at line \(line)")
    }
    static func command(_ url: URL, _ command: [Any]) throws -> [String: Any] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "Could not create IPC client") }
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [0]
        try require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path), "IPC path is too long")
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        try require(connected == 0, "Could not connect to real mpv IPC")
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
        var data = try JSONSerialization.data(withJSONObject: ["command": command, "request_id": 991])
        data.append(10)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if command.first as? String == "quit" { return [:] }
        var response = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while response.count < 65_536 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            response.append(contentsOf: buffer.prefix(count))
            while let newline = response.firstIndex(of: 10) {
                let line = response[..<newline]; response.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["request_id"] as? Int == 991 { return object }
            }
        }
        throw Failure(message: "No actual mpv IPC response")
    }
}
