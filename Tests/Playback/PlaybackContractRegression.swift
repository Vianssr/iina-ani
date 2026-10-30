import Foundation

@main
struct PlaybackContractRegression {
    struct Failure: Error { let message: String }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    static func event(_ identity: PlaybackLoadIdentity, _ sequence: UInt64,
                      _ kind: PlaybackEvent.Kind) -> PlaybackEvent {
        PlaybackEvent(identity: identity, sequence: sequence, kind: kind)
    }

    static func loaded(_ identity: PlaybackLoadIdentity) throws -> PlaybackEventState {
        var state = PlaybackEventState()
        state.beginLoad(identity)
        try require(state.apply(event(identity, 1, .resolved)), "Resolution must be a distinct accepted fact")
        try require(!state.hasLoadedMedia && state.actualPosition == nil, "Resolving a URL must not establish loaded media or viewing progress")
        try require(state.apply(event(identity, 2, .loading)), "Backend loading must follow resolution")
        try require(!state.hasLoadedMedia, "Starting a backend load must not mark success")
        try require(state.apply(event(identity, 3, .loaded)), "Actual backend confirmation must establish loaded success")
        return state
    }

    static func main() throws {
        let identity = PlaybackLoadIdentity(sessionID: UUID())
        var state = PlaybackEventState()
        state.beginLoad(identity)
        let idle = state
        try require(!state.apply(event(identity, 10, .loaded)) && state == idle,
                    "Out-of-order loaded must not skip resolved/loading or consume the sequence")
        try require(!state.apply(event(identity, 11, .progress(.init(position: 20, duration: 100)))) && state == idle,
                    "Preload numeric UI/backend data cannot create viewing progress")
        try require(!state.apply(event(identity, 12, .naturalEOF)) && state == idle,
                    "A preloaded EOF cannot complete the load")

        state = try loaded(identity)
        try require(state.apply(event(identity, 4, .progress(.init(position: 12.5, duration: 100)))),
                    "A loaded player's finite actual time must be accepted")
        let actual = state
        try require(!state.apply(event(identity, 5, .progress(.init(position: 90, duration: 100, origin: .seekPreview)))) && state == actual,
                    "Predicted slider/seek time must never overwrite actual backend progress")
        try require(state.apply(event(identity, 5, .paused(true))) && state.actualPosition == 12.5,
                    "Pause must remain distinct from actual progress and rejected events must not consume sequence")
        let paused = state
        try require(!state.apply(event(identity, 4, .progress(.init(position: 99, duration: 100)))) && state == paused,
                    "Older progress must not overwrite newer state")
        try require(!state.apply(event(identity, 5, .paused(false))) && state == paused,
                    "A duplicate sequence must not change pause state")
        try require(!state.apply(event(identity, 6, .resolved)) && state == paused,
                    "Late URL resolution must not reset an already loaded player")
        for sample in [PlaybackProgressSample(position: .nan, duration: 100),
                       .init(position: .infinity, duration: 100),
                       .init(position: -1, duration: 100),
                       .init(position: 20, duration: .infinity),
                       .init(position: 20, duration: 0)] {
            try require(!state.apply(event(identity, 6, .progress(sample))) && state == paused,
                        "Invalid backend seconds/durations must leave the entire state unchanged")
        }
        try require(state.apply(event(identity, 6, .progress(.init(position: 20, duration: nil)))) && state.duration == 100,
                    "Actual progress without a duration must retain the last valid duration")

        let otherSession = PlaybackLoadIdentity(sessionID: UUID(), loadID: identity.loadID)
        let otherLoad = PlaybackLoadIdentity(sessionID: identity.sessionID)
        let current = state
        for stale in [otherSession, otherLoad] {
            try require(!state.apply(event(stale, 999, .progress(.init(position: 88, duration: 100)))) && state == current,
                        "Both session and load IDs must match; a high sequence cannot adopt another player's state")
            try require(!state.apply(event(stale, 1_000, .naturalEOF)) && state == current,
                        "An old/different player's EOF must not complete this media")
        }

        try require(state.apply(event(identity, 7, .naturalEOF)) && state.phase == .ended,
                    "Only a confirmed loaded file can naturally end")
        let ended = state
        try require(!state.apply(event(identity, 8, .naturalEOF)) && state == ended,
                    "keep-open eof-reached plus end-file must complete at most once")
        try require(!state.apply(event(identity, 9, .progress(.init(position: 100, duration: 100)))) && state == ended,
                    "Queued progress after EOF must not rewrite a terminal load")
        try require(!state.apply(event(identity, 10, .stopped)) && state == ended,
                    "A later stop during EOF cleanup must not rewrite the natural end reason")

        state.beginLoad(identity)
        try require(state == ended, "Reactivating the same load ID must not bypass duplicate EOF or stale-sequence protection")

        state.beginLoad(otherLoad)
        try require(state.phase == .idle && !state.hasLoadedMedia && state.actualPosition == nil && state.duration == nil,
                    "Explicitly activating a replacement must clear prior load facts")
        let replacement = state
        try require(!state.apply(event(identity, 100, .loaded)) && state == replacement,
                    "An old response cannot reactivate the previous load after replacement")
        state = try loaded(otherLoad)
        try require(state.apply(event(otherLoad, 4, .progress(.init(position: 2, duration: 10)))),
                    "A newly activated load must accept its own actual progress")

        for (kind, phase, failure) in [
            (PlaybackEvent.Kind.stopped, PlaybackEventState.Phase.stopped, Optional<PlaybackFailure>.none),
            (.cancelled, .cancelled, .some(.cancelled)),
            (.failed(.network), .failed, .some(.network)),
            (.failed(.mediaPlayback), .failed, .some(.mediaPlayback))
        ] {
            var interrupted = try loaded(identity)
            try require(interrupted.apply(event(identity, 4, kind)) && interrupted.phase == phase && interrupted.failure == failure,
                        "Stop, cancellation and classified failures must retain distinct terminal meanings")
            let terminal = interrupted
            try require(!interrupted.apply(event(identity, 5, .naturalEOF)) && interrupted == terminal,
                        "Stop/cancel/error must suppress a queued natural EOF")
        }

        var failedLoad = PlaybackEventState()
        failedLoad.beginLoad(identity)
        try require(failedLoad.apply(event(identity, 1, .failed(.mediaPlayback))) &&
                    !failedLoad.hasLoadedMedia && failedLoad.actualPosition == nil,
                    "A failed backend startup must terminate without claiming successful loading or viewing")

        let payload = event(identity, 4, .progress(.init(position: 42, duration: 100)))
        let encoded = try JSONEncoder().encode(payload)
        try require(try JSONDecoder().decode(PlaybackEvent.self, from: encoded) == payload,
                    "Shared event facts must round-trip without platform-specific data")
        let text = String(decoding: encoded, as: UTF8.self)
        try require(!text.contains("url") && !text.contains("URL") && !text.contains("header") && !text.contains("token"),
                    "Durable event data must have no media URL/header/credential fields")
        try replayLifecycle(identity)
        print("PASS: playback loaded/progress separation, seek provenance, session/load ordering and EOF-only completion")
    }

    static func replayLifecycle(_ previous: PlaybackLoadIdentity) throws {
        var state = try loaded(previous)
        try require(state.apply(event(previous, 4, .naturalEOF)), "The first playback must naturally finish")
        let ended = state
        try require(!state.beginReplay(previous) && state == ended, "A replay must use a fresh load ID")
        try require(!state.beginReplay(PlaybackLoadIdentity(sessionID: UUID())) && state == ended,
                    "A different player cannot inherit retained loaded-media evidence")

        let replay = PlaybackLoadIdentity(sessionID: previous.sessionID)
        try require(state.beginReplay(replay) && !state.hasLoadedMedia && state.actualPosition == nil,
                    "Replay activation must wait for backend confirmation and clear previous progress")
        try require(state.apply(event(replay, 1, .resolved)) && state.apply(event(replay, 2, .loading)),
                    "A replay must keep its new load lifecycle explicit")
        let waiting = state
        try require(!state.apply(event(replay, 3, .loaded)) && state == waiting,
                    "Retained EOF media must not fabricate a new file-loaded event")
        try require(!state.apply(event(previous, 999, .naturalEOF)) && state == waiting,
                    "Old keep-open/end-file EOF must not terminate the replay")
        try require(!state.apply(event(replay, 3, .replayStarted(previousLoad: replay))) && state == waiting,
                    "Replay confirmation must refer to the exact prior confirmed media")
        try require(!state.apply(event(replay, 3, .progress(.init(position: 0, duration: 100)))) && state == waiting,
                    "Seek prediction or early numeric reports cannot confirm a replay")
        try require(state.apply(event(replay, 3, .replayStarted(previousLoad: previous))) &&
                    state.hasLoadedMedia && state.actualPosition == nil,
                    "Actual retained-media restart may reuse prior loaded evidence without claiming actual seconds")
        try require(state.apply(event(replay, 4, .progress(.init(position: 1.25, duration: 100)))) &&
                    state.actualPosition == 1.25,
                    "A confirmed replay must accept new actual playback progress")
        try require(state.apply(event(replay, 5, .naturalEOF)), "The replay may naturally end once under its new ID")
        let replayEnded = state
        try require(!state.apply(event(replay, 6, .naturalEOF)) && state == replayEnded,
                    "Replay EOF must retain duplicate suppression")

        var fresh = PlaybackEventState()
        fresh.beginLoad(PlaybackLoadIdentity(sessionID: previous.sessionID))
        let freshID = fresh.identity!
        try require(fresh.apply(event(freshID, 1, .resolved)) && fresh.apply(event(freshID, 2, .loading)),
                    "Fresh loads still have their ordinary loading lifecycle")
        try require(!fresh.apply(event(freshID, 3, .replayStarted(previousLoad: previous))) && !fresh.hasLoadedMedia,
                    "A replay event cannot invent loaded evidence on an unrelated fresh load")
    }
}
