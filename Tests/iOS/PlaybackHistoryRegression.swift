import Foundation

@main struct MobilePlaybackHistoryRegression {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ani-mobile-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let configuration = try SourceConfiguration.load(fileURL: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))
        let selection = PlayableSelection(
            item: SourceItemRef(sourceID: "fqdm", pageURL: "https://www.fqdm.cc/index.php/vod/detail/id/42.html?token=discard-work", kind: .work),
            episode: SourceItemRef(sourceID: "fqdm", pageURL: "https://www.fqdm.cc/index.php/vod/play/id/42/sid/1/nid/2.html?signature=discard-episode", kind: .episode),
            lineID: "1", accountID: UUID())
        let context = PlaybackContext(work: .bangumi(42), episode: .bangumi(4202, type: 0, sort: 2),
            selection: selection, configurationRevision: configuration.configurationRevision)
        let file = temporary.appendingPathComponent("history.json")
        let history = MobilePlaybackHistory(file: file)
        precondition(history.isReadable && history.entries.isEmpty)
        let firstID = PlaybackLoadIdentity(sessionID: UUID())
        let first = history.begin(context: context, localReference: nil, title: "Fixture · Episode 2",
            configuration: configuration, identity: firstID)!
        var sequence: UInt64 = 0
        @MainActor func send(_ recorder: MobilePlaybackHistoryRecorder, _ identity: PlaybackLoadIdentity, _ kind: PlaybackEvent.Kind,
                  at time: Date = Date(timeIntervalSince1970: 100)) -> Bool {
            sequence += 1
            return recorder.receive(PlaybackEvent(identity: identity, sequence: sequence, kind: kind), now: time)
        }
        _ = send(first, firstID, .resolved)
        _ = send(first, firstID, .loading)
        _ = send(first, firstID, .progress(.init(position: 13, duration: 100)))
        precondition(history.entries.isEmpty) // Resolution and loading are not a viewed episode.
        _ = send(first, firstID, .failed(.mediaPlayback))
        first.flush()
        precondition(history.entries.isEmpty && !FileManager.default.fileExists(atPath: file.path))

        let loadedID = PlaybackLoadIdentity(sessionID: UUID())
        let loaded = history.begin(context: context, localReference: nil, title: "Fixture · Episode 2",
            configuration: configuration, identity: loadedID)!
        _ = send(loaded, loadedID, .resolved)
        _ = send(loaded, loadedID, .loading)
        _ = send(loaded, loadedID, .loaded)
        _ = send(loaded, loadedID, .progress(.init(position: 0, duration: 100)))
        _ = send(loaded, loadedID, .progress(.init(position: 80, duration: 100, origin: .seekPreview)))
        precondition(history.entries.isEmpty)
        _ = send(loaded, loadedID, .progress(.init(position: 23.5, duration: 100)))
        precondition(history.entries.count == 1 && history.entries[0].position == 23.5 && !history.entries[0].completed)
        let saved = history.entries[0]
        let bytes = try Data(contentsOf: file)
        let text = String(decoding: bytes, as: UTF8.self)
        precondition(!text.contains("discard-work") && !text.contains("discard-episode") && !text.contains("accountID"))
        precondition(!text.contains("media.example") && !text.contains("cookie"))
        let reopened = MobilePlaybackHistory(file: file)
        precondition(reopened.entries == history.entries && reopened.continuing == reopened.entries)
        precondition(reopened.entries[0].context?.selection.item.pageURL == "https://www.fqdm.cc/index.php/vod/detail/id/42.html")

        // A resume cannot overwrite the saved position with time-pos=0 or queued pre-seek facts.
        let resumeID = PlaybackLoadIdentity(sessionID: UUID())
        let resumed = history.begin(context: context, localReference: nil, title: saved.title,
            configuration: configuration, identity: resumeID, resumePosition: saved.position)!
        _ = send(resumed, resumeID, .resolved)
        _ = send(resumed, resumeID, .loading)
        precondition(send(resumed, resumeID, .loaded))
        _ = send(resumed, resumeID, .progress(.init(position: 0.1, duration: 100)))
        _ = send(resumed, resumeID, .paused(true))
        resumed.flush()
        precondition(history.entries == [saved])
        _ = send(resumed, resumeID, .failed(.mediaPlayback))
        resumed.flush()
        precondition(history.entries == [saved])

        let currentID = PlaybackLoadIdentity(sessionID: UUID())
        let current = history.begin(context: context, localReference: nil, title: saved.title,
            configuration: configuration, identity: currentID, resumePosition: saved.position)!
        _ = send(current, currentID, .resolved)
        _ = send(current, currentID, .loading)
        precondition(send(current, currentID, .loaded))
        current.confirmResume(currentID)
        _ = send(current, currentID, .progress(.init(position: 24, duration: 100)))
        precondition(history.entries[0].position == 24)
        _ = send(loaded, loadedID, .progress(.init(position: 90, duration: 100)), at: Date(timeIntervalSince1970: 110))
        loaded.flush()
        precondition(history.entries[0].position == 24) // An older same-episode player has lost its lease.
        let wrongLoad = PlaybackLoadIdentity(sessionID: currentID.sessionID)
        _ = send(current, wrongLoad, .progress(.init(position: 95, duration: 100)))
        precondition(history.entries[0].position == 24)
        _ = send(current, currentID, .progress(.init(position: 26, duration: 100)), at: Date(timeIntervalSince1970: 101))
        precondition(history.entries[0].position == 24) // Periodic save interval has not elapsed.
        _ = send(current, currentID, .paused(true), at: Date(timeIntervalSince1970: 102))
        precondition(history.entries[0].position == 26)

        // Failed atomic replacement does not advance committed UI or destroy old bytes.
        let beforeFailure = history.entries
        let beforeFailureBytes = try Data(contentsOf: file)
        let staged = file.appendingPathExtension("staged")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("block".utf8).write(to: staged.appendingPathComponent("blocker"))
        _ = send(current, currentID, .progress(.init(position: 31, duration: 100)), at: Date(timeIntervalSince1970: 110))
        precondition(history.storageError && history.entries == beforeFailure)
        let failedWriteBytes = try Data(contentsOf: file)
        precondition(failedWriteBytes == beforeFailureBytes)
        current.flush(now: Date(timeIntervalSince1970: 111))
        precondition(!history.storageError && history.entries[0].position == 31)
        _ = send(current, currentID, .naturalEOF, at: Date(timeIntervalSince1970: 112))
        precondition(history.entries[0].completed && history.continuing == history.entries)
        precondition(history.entries[0].position == 31) // EOF never fabricates duration as progress or starts another episode.

        let deleted = history.entries[0]
        history.remove(deleted)
        precondition(history.entries.isEmpty)
        current.flush()
        let replay = PlaybackLoadIdentity(sessionID: currentID.sessionID)
        _ = send(current, replay, .resolved)
        _ = send(current, replay, .loading)
        _ = send(current, replay, .replayStarted(previousLoad: currentID))
        _ = send(current, replay, .progress(.init(position: 10, duration: 100)))
        current.flush()
        precondition(history.entries.isEmpty && MobilePlaybackHistory(file: file).entries.isEmpty)
        precondition(history.begin(context: nil, localReference: nil, title: "https://media.example.test/raw.mp4?token=secret",
            configuration: nil, identity: PlaybackLoadIdentity(sessionID: UUID())) == nil)
        precondition(!history.storageError && history.entries.isEmpty)

        for invalid in [Data("broken json".utf8), Data("{\"version\":999,\"entries\":[]}".utf8)] {
            try invalid.write(to: file, options: .atomic)
            let blocked = MobilePlaybackHistory(file: file)
            precondition(!blocked.isReadable && blocked.storageError)
            blocked.remove(saved)
            precondition(blocked.begin(context: context, localReference: nil, title: saved.title,
                configuration: configuration, identity: PlaybackLoadIdentity(sessionID: UUID())) == nil)
            let protectedBytes = try Data(contentsOf: file)
            precondition(protectedBytes == invalid)
        }
        try bytes.write(to: file, options: .atomic)
        history.retryLoad()
        precondition(history.isReadable && !history.storageError && history.entries == [saved])

        // Config-declared query identity survives, while credentials/tracking do not.
        let archiveConfig = try SourceConfiguration.load(fileURL: root.appendingPathComponent("Examples/MobileSources/internet-archive.json"))
        let archiveContext = PlaybackContext(work: .bangumi(43), episode: .bangumi(4301, type: 0, sort: 1),
            selection: PlayableSelection(item: SourceItemRef(sourceID: archiveConfig.id, pageURL: "https://archive.org/details/fixture?utm_source=discard", kind: .work),
                episode: SourceItemRef(sourceID: archiveConfig.id, pageURL: "https://archive.org/details/fixture?file=movie.mp4&token=discard", kind: .episode)),
            configurationRevision: archiveConfig.configurationRevision)
        let archiveID = PlaybackLoadIdentity(sessionID: UUID())
        let archiveRecorder = history.begin(context: archiveContext, localReference: nil, title: "Archive",
            configuration: archiveConfig, identity: archiveID)!
        _ = send(archiveRecorder, archiveID, .resolved)
        _ = send(archiveRecorder, archiveID, .loading)
        _ = send(archiveRecorder, archiveID, .loaded)
        _ = send(archiveRecorder, archiveID, .progress(.init(position: 7, duration: 100)))
        let archiveEntry = history.entries.first { $0.context?.work == archiveContext.work }!
        precondition(archiveEntry.context?.selection.episode?.pageURL == "https://archive.org/details/fixture?file=movie.mp4")
        precondition(history.begin(context: archiveContext, localReference: nil, title: "Wrong config",
            configuration: configuration, identity: PlaybackLoadIdentity(sessionID: UUID())) == nil)
        try await localFiles(in: temporary, history: history, file: file)
        try shortResumesAndLatestWork(in: temporary, context: context, configuration: configuration)
        print("PASS: mobile durable history, actual progress, resume/session/delete guards, fail-closed archives, configured identities and local content authorization")
    }

    @MainActor static func shortResumesAndLatestWork(in temporary: URL, context: PlaybackContext,
                                                    configuration: SourceConfiguration) throws {
        let file = temporary.appendingPathComponent("short-resume-history.json")
        let history = MobilePlaybackHistory(file: file)
        let initialID = PlaybackLoadIdentity(sessionID: UUID())
        let initial = history.begin(context: context, localReference: nil, title: "Short resume",
            configuration: configuration, identity: initialID)!
        for (offset, kind) in [PlaybackEvent.Kind.resolved, .loading, .loaded, .progress(.init(position: 1.1, duration: 100))].enumerated() {
            initial.receive(PlaybackEvent(identity: initialID, sequence: UInt64(offset + 1), kind: kind))
        }
        let saved = history.entries
        let bytes = try Data(contentsOf: file)
        for terminal in [PlaybackEvent.Kind.failed(.mediaPlayback), .stopped, .cancelled] {
            let identity = PlaybackLoadIdentity(sessionID: UUID())
            let recorder = history.begin(context: context, localReference: nil, title: "Short resume",
                configuration: configuration, identity: identity, resumePosition: 1.1)!
            // A confirmation before loading, or for a retired load, cannot open the gate.
            recorder.confirmResume(identity)
            let events: [PlaybackEvent.Kind] = [
                .resolved, .loading, .loaded,
                .progress(.init(position: 0.2, duration: 100)),
                .progress(.init(position: 1.1, duration: 100)), .paused(true), terminal
            ]
            for (offset, kind) in events.enumerated() {
                recorder.receive(PlaybackEvent(identity: identity, sequence: UInt64(offset + 1), kind: kind))
            }
            recorder.confirmResume(identity)
            recorder.flush()
            let after = try Data(contentsOf: file)
            precondition(history.entries == saved && after == bytes)
            precondition(MobilePlaybackHistory(file: file).entries == saved)
        }
        let identity = PlaybackLoadIdentity(sessionID: UUID())
        let recorder = history.begin(context: context, localReference: nil, title: "Short resume",
            configuration: configuration, identity: identity, resumePosition: 1.1)!
        for (offset, kind) in [PlaybackEvent.Kind.resolved, .loading, .loaded].enumerated() {
            recorder.receive(PlaybackEvent(identity: identity, sequence: UInt64(offset + 1), kind: kind))
        }
        recorder.confirmResume(PlaybackLoadIdentity(sessionID: identity.sessionID))
        recorder.receive(PlaybackEvent(identity: identity, sequence: 4, kind: .progress(.init(position: 1.1, duration: 100))))
        precondition(history.entries == saved)
        recorder.confirmResume(identity)
        recorder.receive(PlaybackEvent(identity: identity, sequence: 5, kind: .progress(.init(position: 1.2, duration: 100))))
        precondition(history.entries[0].position == 1.2)
        recorder.receive(PlaybackEvent(identity: identity, sequence: 6, kind: .naturalEOF))
        precondition(history.continuing.count == 1 && history.continuing[0].completed)

        var selection = context.selection
        selection.episode = SourceItemRef(sourceID: configuration.id,
            pageURL: "https://www.fqdm.cc/index.php/vod/play/id/42/sid/1/nid/3.html", kind: .episode)
        let nextContext = PlaybackContext(work: context.work, episode: .bangumi(4203, type: 0, sort: 3),
            selection: selection, configurationRevision: context.configurationRevision)
        let nextID = PlaybackLoadIdentity(sessionID: UUID())
        let next = history.begin(context: nextContext, localReference: nil, title: "Next episode",
            configuration: configuration, identity: nextID)!
        let later = Date.now.addingTimeInterval(10)
        for (offset, kind) in [PlaybackEvent.Kind.resolved, .loading, .loaded, .progress(.init(position: 8, duration: 100))].enumerated() {
            next.receive(PlaybackEvent(identity: nextID, sequence: UInt64(offset + 1), kind: kind), now: later)
        }
        precondition(history.entries.count == 2 && history.continuing.count == 1)
        precondition(history.continuing[0].context?.episode == nextContext.episode && !history.continuing[0].completed)
        next.receive(PlaybackEvent(identity: nextID, sequence: 5, kind: .naturalEOF), now: later)
        precondition(history.continuing.count == 1 && history.continuing[0].completed)
    }

    @MainActor static func localFiles(in temporary: URL, history: MobilePlaybackHistory, file: URL) async throws {
        let original = temporary.appendingPathComponent("original.mp4")
        let renamed = temporary.appendingPathComponent("renamed.mp4")
        let otherDirectory = temporary.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        let sameNameDifferentContent = otherDirectory.appendingPathComponent("original.mp4")
        let payload = Data(repeating: 0x5a, count: 2_200_001)
        try payload.write(to: original)
        try Data(repeating: 0x6b, count: payload.count).write(to: sameNameDifferentContent)
        let authorization = try await MobileLocalMedia.authorize(original)
        precondition(authorization.reference.identity.size == UInt64(payload.count))
        let identity = authorization.reference.identity
        let load = PlaybackLoadIdentity(sessionID: UUID())
        let recorder = history.begin(context: nil, localReference: authorization.reference, title: "Local fixture",
            configuration: nil, identity: load)!
        for (offset, kind) in [PlaybackEvent.Kind.resolved, .loading, .loaded, .progress(.init(position: 17, duration: 60))].enumerated() {
            recorder.receive(PlaybackEvent(identity: load, sequence: UInt64(offset + 1), kind: kind))
        }
        let entry = history.entries.first { $0.id == identity.id }!
        let revision = try history.authorizationRevision(for: entry)
        try FileManager.default.moveItem(at: original, to: renamed)
        let moved = try await MobileLocalMedia.authorize(renamed, matching: identity)
        precondition(moved.reference.identity == identity)
        let replaced = try history.replaceLocalReference(moved.reference, for: entry, expectedRevision: revision)
        precondition(replaced.id == entry.id && replaced.position == 17 && replaced.title == entry.title)
        let resolved = try await MobileLocalMedia.resolve(replaced.localReference!)
        let reopened = MobilePlaybackHistory(file: file)
        precondition(reopened.isReadable && reopened.entries.first(where: { $0.id == identity.id }) == replaced)
        precondition(resolved.reference.identity == identity)
        let committed = history.entries
        do {
            _ = try await MobileLocalMedia.authorize(sameNameDifferentContent, matching: identity)
            fatalError("A same-name different movie was accepted")
        } catch MobileLocalMediaError.differentContent {}
        precondition(history.entries == committed)
        let cancelled = Task { try await MobileLocalMedia.authorize(renamed, matching: identity) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled authorization succeeded") }
        catch is CancellationError {}
        precondition(history.entries == committed)
        let deletingRevision = try history.authorizationRevision(for: replaced)
        history.remove(replaced)
        do {
            _ = try history.replaceLocalReference(moved.reference, for: replaced, expectedRevision: deletingRevision)
            fatalError("Post-delete authorization resurrected history")
        } catch MobileLocalMediaError.staleHistory {}
        recorder.receive(PlaybackEvent(identity: load, sequence: 5, kind: .progress(.init(position: 50, duration: 60))))
        recorder.flush()
        precondition(!history.entries.contains { $0.id == identity.id })
    }
}
