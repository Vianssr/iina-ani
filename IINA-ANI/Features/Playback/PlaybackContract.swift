import Foundation

/// A player session can replace its media many times; neither identifier is a media URL.
struct PlaybackLoadIdentity: Codable, Hashable, Sendable {
    let sessionID: UUID
    let loadID: UUID

    init(sessionID: UUID, loadID: UUID = UUID()) {
        self.sessionID = sessionID
        self.loadID = loadID
    }
}

enum PlaybackProgressOrigin: String, Codable, Sendable {
    case player
    case seekPreview
}

struct PlaybackProgressSample: Codable, Equatable, Sendable {
    let position: Double
    let duration: Double?
    let origin: PlaybackProgressOrigin

    init(position: Double, duration: Double?, origin: PlaybackProgressOrigin = .player) {
        self.position = position
        self.duration = duration
        self.origin = origin
    }
}

/// Only transport-independent facts belong here. Resolved URLs, headers and credentials
/// remain transient adapter inputs, never event data or a substitute for a loaded event.
struct PlaybackEvent: Codable, Equatable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        case resolved
        case loading
        case loaded
        /// A confirmed seek/restart of already loaded, retained media; not file-loaded.
        case replayStarted(previousLoad: PlaybackLoadIdentity)
        case progress(PlaybackProgressSample)
        case paused(Bool)
        case naturalEOF
        case stopped
        case cancelled
        case failed(PlaybackFailure)
    }

    let identity: PlaybackLoadIdentity
    /// Strictly increasing within a load, assigned before crossing an asynchronous boundary.
    let sequence: UInt64
    let kind: Kind
}

/// Explicit activation prevents a late event from an old load (or another player) from
/// adopting the current state. Replay explicitly carries the prior loaded-media evidence.
struct PlaybackEventState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle, resolved, loading, loaded, ended, stopped, cancelled, failed
    }

    private(set) var identity: PlaybackLoadIdentity?
    private(set) var lastSequence: UInt64 = 0
    private(set) var phase: Phase = .idle
    private(set) var hasLoadedMedia = false
    private(set) var actualPosition: Double?
    private(set) var duration: Double?
    private(set) var isPaused = true
    private(set) var failure: PlaybackFailure?
    private var replayOf: PlaybackLoadIdentity?

    var isTerminal: Bool {
        switch phase {
        case .ended, .stopped, .cancelled, .failed: return true
        default: return false
        }
    }

    mutating func beginLoad(_ identity: PlaybackLoadIdentity) {
        guard self.identity != identity else { return }
        self = Self()
        self.identity = identity
    }

    /// Only naturally ended, actually loaded media may be reused without reloading.
    /// The adapter must still confirm that its seek restarted the same retained file.
    @discardableResult
    mutating func beginReplay(_ identity: PlaybackLoadIdentity) -> Bool {
        guard phase == .ended, hasLoadedMedia, let previous = self.identity,
              previous.sessionID == identity.sessionID, previous.loadID != identity.loadID else { return false }
        self = Self()
        self.identity = identity
        replayOf = previous
        return true
    }

    /// Invalid, duplicate, stale and out-of-order facts leave every field unchanged.
    /// In particular a slider/seek prediction can never become actual viewing progress.
    @discardableResult
    mutating func apply(_ event: PlaybackEvent) -> Bool {
        guard event.identity == identity, event.sequence > lastSequence, !isTerminal else { return false }
        switch event.kind {
        case .resolved:
            guard phase == .idle else { return false }
            phase = .resolved
        case .loading:
            guard phase == .resolved else { return false }
            phase = .loading
        case .loaded:
            guard phase == .loading, replayOf == nil else { return false }
            phase = .loaded
            hasLoadedMedia = true
        case let .replayStarted(previousLoad):
            guard phase == .loading, replayOf == previousLoad else { return false }
            phase = .loaded
            hasLoadedMedia = true
            replayOf = nil
        case let .progress(sample):
            guard phase == .loaded, sample.origin == .player,
                  sample.position.isFinite, sample.position >= 0,
                  sample.duration.map({ $0.isFinite && $0 > 0 }) ?? true else { return false }
            actualPosition = sample.position
            if let duration = sample.duration { self.duration = duration }
        case let .paused(paused):
            guard phase == .loaded else { return false }
            isPaused = paused
        case .naturalEOF:
            guard phase == .loaded else { return false }
            phase = .ended
        case .stopped:
            phase = .stopped
        case .cancelled:
            phase = .cancelled
            failure = .cancelled
        case let .failed(failure):
            phase = failure == .cancelled ? .cancelled : .failed
            self.failure = failure
        }
        lastSequence = event.sequence
        return true
    }
}
