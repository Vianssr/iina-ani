import AVFAudio
import Libmpv
import Metal
import Observation
import SwiftUI
import UIKit

struct SubtitleTrack: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
}

/// The UI observes snapshots; every libmpv call and destruction stays on one queue.
@MainActor @Observable
final class MPVEngine {
    private(set) var isPaused = true
    private(set) var isLoading = false
    private(set) var isEnded = false
    private(set) var canSeek = false
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var speed = 1.0
    private(set) var subtitleTracks: [SubtitleTrack] = []
    private(set) var selectedSubtitleID: Int?
    var errorMessage: String?
    var subtitleErrorMessage: String?
    private(set) var playbackState = PlaybackEventState()
    private(set) var lastPlaybackEvent: PlaybackEvent?
    private(set) var playbackContext: PlaybackContext?
    @ObservationIgnored let sessionID = UUID()
    @ObservationIgnored var onPlaybackEvent: (@MainActor (PlaybackEvent) -> Void)?
    @ObservationIgnored var onPauseRequested: (@MainActor () -> Void)?
    @ObservationIgnored var onResumeConfirmed: (@MainActor (PlaybackLoadIdentity) -> Void)?
    @ObservationIgnored var onSubtitleImported: (@MainActor (URL) -> Void)?


    @ObservationIgnored private var worker: MPVWorker?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var pendingResumePosition: Double?
    @ObservationIgnored private var pendingSubtitleURL: URL?
    @ObservationIgnored private var pendingSubtitleSelection: Int??
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pauseRevision = 0
    @ObservationIgnored private var requestedPaused = true
    @ObservationIgnored private var subtitlePosition = 100.0
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var workerEvents: Task<Void, Never>?

    init() {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in self?.setPaused(true) }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor [weak self] in self?.setPaused(true) }
        })
        notifications.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setPaused(true)
                self?.worker?.setVideoVisible(false)
            }
        })
        notifications.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.worker?.setVideoVisible(true) }
        })
    }

    func load(url: URL, context: PlaybackContext? = nil, resumePosition: Double? = nil, paused: Bool = false) {
        guard !stopped else { return }
        publish(.cancelled)
        playbackContext = context
        pendingResumePosition = resumePosition.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        playbackState.beginLoad(PlaybackLoadIdentity(sessionID: sessionID))
        publish(.resolved)
        publish(.loading)
        generation += 1
        pauseRevision += 1
        requestedPaused = paused
        pendingURL = url
        position = 0
        duration = 0
        isLoading = true
        isPaused = paused
        isEnded = false
        canSeek = false
        subtitleTracks = []
        selectedSubtitleID = nil
        errorMessage = nil
        subtitleErrorMessage = nil
        pendingSubtitleURL = nil
        pendingSubtitleSelection = nil
        worker?.load(url: url, generation: generation, identity: playbackState.identity!, speed: speed, paused: requestedPaused, pauseRevision: pauseRevision, resumePosition: pendingResumePosition)
    }

    func togglePause() { setPaused(!isPaused) }

    func setPaused(_ paused: Bool) {
        guard !stopped else { return }
        if paused { onPauseRequested?() }
        if !paused && (isEnded || playbackState.phase == .ended) { seek(to: 0) }
        requestedPaused = paused
        pauseRevision += 1
        isPaused = paused
        worker?.setPaused(paused, revision: pauseRevision)
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, canSeek else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        var replayIdentity: PlaybackLoadIdentity?
        var previousLoad: PlaybackLoadIdentity?
        if playbackState.phase == .ended, duration <= 0 || target < duration,
           let previous = playbackState.identity {
            let identity = PlaybackLoadIdentity(sessionID: sessionID)
            if playbackState.beginReplay(identity) {
                generation += 1
                previousLoad = previous
                replayIdentity = identity
                publish(.resolved)
                publish(.loading)
            }
        }
        // Keep displayed/overlay time on backend evidence until mpv confirms the seek.
        isEnded = false
        worker?.seek(to: target, generation: generation, identity: replayIdentity, previousLoad: previousLoad)
    }

    func seek(by seconds: Double) { seek(to: position + seconds) }


    func setSpeed(_ value: Double) {
        guard value.isFinite else { return }
        speed = min(3, max(0.25, value))
        worker?.setSpeed(speed)
    }

    func selectSubtitle(id: Int?) {
        guard id == nil || subtitleTracks.contains(where: { $0.id == id }) else { return }
        selectedSubtitleID = id
        pendingSubtitleSelection = .some(id)
        worker?.selectSubtitle(id: id, generation: generation)
    }

    /// Native mpv positioning: 100 restores the normal position; smaller values move up.
    /// Authored ASS positioning keeps mpv's existing style/override behavior.
    func setSubtitlePosition(_ percentage: Double) {
        guard !stopped, percentage.isFinite else { return }
        let position = min(100, max(0, percentage))
        guard position != subtitlePosition else { return }
        subtitlePosition = position
        worker?.setSubtitlePosition(position)
    }

    func addSubtitle(url: URL) {
        guard !stopped, pendingURL != nil else { return }
        pendingSubtitleURL = url
        pendingSubtitleSelection = nil
        worker?.addSubtitle(url: url, generation: generation)
    }

    func clearSubtitles() {
        pendingSubtitleURL = nil
        pendingSubtitleSelection = nil
        selectedSubtitleID = nil
        subtitleErrorMessage = nil
        worker?.clearSubtitles(generation: generation)
    }

    func stop(onStopped: @escaping @Sendable () -> Void = {}) {
        publish(.stopped)
        stopped = true
        generation += 1
        pendingURL = nil
        pendingSubtitleURL = nil
        pendingSubtitleSelection = nil
        workerEvents?.cancel()
        workerEvents = nil
        if let worker { worker.shutdown(onStopped: onStopped) } else { onStopped() }
        worker = nil
        isPaused = true
        isLoading = false
        isEnded = false
        canSeek = false
    }

    fileprivate func attach(layer: CAMetalLayer) {
        guard !stopped, worker == nil else { return }
        let (updates, continuation) = AsyncStream<MPVWorkerUpdate>.makeStream()
        workerEvents = Task { [weak self] in
            for await update in updates {
                guard let self, !Task.isCancelled else { return }
                switch update {
                case let .snapshot(snapshot): receive(snapshot)
                case let .event(event): receive(event)
                case let .resumeConfirmed(identity):
                    guard playbackState.identity == identity, playbackState.phase == .loaded else { continue }
                    pendingResumePosition = nil
                    onResumeConfirmed?(identity)
                case let .subtitleImported(url, generation):
                    guard !stopped, worker != nil, self.generation == generation else { continue }
                    onSubtitleImported?(url)
                }
            }
        }
        let newWorker = MPVWorker(layer: layer, output: { continuation.yield($0) },
                                  onShutdown: { continuation.finish() })
        worker = newWorker
        newWorker.start()
        newWorker.setSubtitlePosition(subtitlePosition)
        if let pendingURL {
            newWorker.load(url: pendingURL, generation: generation, identity: playbackState.identity!, speed: speed, paused: requestedPaused, pauseRevision: pauseRevision, resumePosition: pendingResumePosition)
            if let pendingSubtitleURL { newWorker.addSubtitle(url: pendingSubtitleURL, generation: generation) }
            if let selection = pendingSubtitleSelection { newWorker.selectSubtitle(id: selection, generation: generation) }
        }
    }

    private func publish(_ kind: PlaybackEvent.Kind) {
        guard let identity = playbackState.identity else { return }
        receive(PlaybackEvent(identity: identity, sequence: playbackState.lastSequence + 1, kind: kind))
    }

    private func receive(_ event: PlaybackEvent) {
        guard playbackState.apply(event) else { return }
        lastPlaybackEvent = event
        onPlaybackEvent?(event)
    }

    private func receive(_ snapshot: MPVSnapshot) {
        guard snapshot.generation == generation, worker != nil else { return }
        // A snapshot queued before a newer Pause/Resume must not undo that request.
        if snapshot.pauseRevision == pauseRevision {
            isPaused = snapshot.paused
            requestedPaused = snapshot.paused
        }
        isLoading = snapshot.loading
        isEnded = snapshot.ended
        canSeek = snapshot.seekable
        position = snapshot.position
        duration = snapshot.duration
        speed = snapshot.speed
        subtitleTracks = snapshot.subtitles
        selectedSubtitleID = snapshot.selectedSubtitle
        errorMessage = snapshot.error
        if let error = snapshot.subtitleError { subtitleErrorMessage = error }
    }

    deinit {
        notifications.forEach(NotificationCenter.default.removeObserver)
        workerEvents?.cancel()
        worker?.shutdown()
    }
}

struct MPVVideoView: UIViewRepresentable {
    let engine: MPVEngine

    func makeUIView(context: Context) -> MPVSurfaceView {
        let view = MPVSurfaceView()
        view.onReady = { [weak engine] layer in engine?.attach(layer: layer) }
        return view
    }

    func updateUIView(_ view: MPVSurfaceView, context: Context) {
        view.onReady = { [weak engine] layer in engine?.attach(layer: layer) }
        view.setNeedsLayout()
    }
}

final class MPVSurfaceView: UIView {
    var onReady: ((CAMetalLayer) -> Void)?
    private let videoLayer = MPVMetalLayer()

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        videoLayer.device = MTLCreateSystemDefaultDevice()
        videoLayer.framebufferOnly = true
        videoLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1, let screen = window?.screen else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if videoLayer.renderCanvasSize == nil {
            // MPVKit's MoltenVK context does not notify mpv about view resizes.
            // Keep its pixel canvas stable, with enough detail for landscape.
            let scale = screen.scale
            let longEdgePixels = max(screen.bounds.width, screen.bounds.height) * scale
            let pixelUnit = 16 * scale
            let width = floor(min(3840, max(320, longEdgePixels)) / pixelUnit) * pixelUnit
            videoLayer.configureRenderCanvas(CGSize(width: width, height: width / 16 * 9), scale: scale)
        }
        // Keep bounds × contentsScale equal to drawableSize. Changing frame
        // would change bounds, making MoltenVK recreate a differently sized
        // swapchain while mpv still has its old pixel destination/OSD geometry.
        // Core Animation uniformly scales the complete canvas, including an
        // already paused frame, without touching media or renderer state.
        let canvas = videoLayer.bounds.size
        let fit = min(bounds.width / canvas.width, bounds.height / canvas.height)
        videoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        videoLayer.setAffineTransform(CGAffineTransform(scaleX: fit, y: fit))
        CATransaction.commit()
        onReady?(videoLayer)
    }
}

/// The stable bounds, drawable and swapchain describe the same pixel canvas.
/// mpv fits any source aspect inside it; only the layer's presentation is scaled.
private final class MPVMetalLayer: CAMetalLayer {
    private(set) var renderCanvasSize: CGSize?

    func configureRenderCanvas(_ size: CGSize, scale: CGFloat) {
        guard renderCanvasSize == nil else { return }
        renderCanvasSize = size
        contentsScale = scale
        bounds = CGRect(origin: .zero, size: CGSize(width: size.width / scale, height: size.height / scale))
        super.drawableSize = size
    }

    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            // Ignore MoltenVK's temporary 1 × 1 completion workaround. Once
            // configured, legitimate swapchain writes match our fixed bounds;
            // never allow another extent to split texture and canvas geometry.
            guard newValue.width > 1, newValue.height > 1 else { return }
            if let canvas = renderCanvasSize {
                guard newValue == canvas else { return }
            }
            super.drawableSize = newValue
        }
    }
}

private enum MPVWorkerUpdate: Sendable {
    case snapshot(MPVSnapshot)
    case event(PlaybackEvent)
    case resumeConfirmed(PlaybackLoadIdentity)
    case subtitleImported(URL, generation: Int)
}

private struct MPVReplay {
    let previousLoad: PlaybackLoadIdentity
    let requestID: UInt64
    var acknowledged = false
    var restarted = false
}

private struct MPVRestore {
    let requestID: UInt64
    let target: Double
    var acknowledged = false
    var seeking = false
    var restarted = false
}

private struct MPVSnapshot: Sendable {
    var generation = 0
    var pauseRevision = 0
    var paused = true
    var loading = false
    var ended = false
    var seekable = false
    var position = 0.0
    var duration = 0.0
    var speed = 1.0
    var subtitles: [SubtitleTrack] = []
    var selectedSubtitle: Int?
    var error: String?
    var subtitleError: String?
}

/// A serial worker also keeps the Metal layer alive until mpv has stopped using it.
/// Polling avoids an unretained C wakeup callback racing with player destruction.
private final class MPVWorker: @unchecked Sendable {
    private static let playbackQueue = DispatchQueue(label: "com.LlS.iina-ani.ios.mpv", qos: .userInitiated)
    // Accessed only on playbackQueue, including during overlapping scene teardown.
    private static var audioUsers = 0
    private let queue = MPVWorker.playbackQueue
    private var layer: CAMetalLayer?
    private var handle: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var state = MPVSnapshot()
    private var fileLoaded = false
    private var stopped = false
    private var startupFailed = false
    private var loadIdentity: PlaybackLoadIdentity?
    private var eventSequence: UInt64 = 2
    private var expectedEntryID: Int64?
    private var activeEntryID: Int64?
    private var reportedPaused: Bool?
    private var reportedEOF = false
    private var pendingReplay: MPVReplay?
    private var pendingRestore: MPVRestore?
    private var pendingResumePosition: Double?
    private var pendingLoadPause: Bool?
    private var pendingSubtitleURL: URL?
    private var pendingSubtitleSelection: Int??
    private var nextSeekRequest: UInt64 = 100
    private var audioActive = false
    private var audioResumeFailed = false
    private let outputUpdate: @Sendable (MPVWorkerUpdate) -> Void
    private let onShutdown: @Sendable () -> Void

    init(layer: CAMetalLayer, output: @escaping @Sendable (MPVWorkerUpdate) -> Void,
         onShutdown: @escaping @Sendable () -> Void) {
        self.layer = layer
        self.outputUpdate = output
        self.onShutdown = onShutdown
    }

    private func output(_ snapshot: MPVSnapshot) { outputUpdate(.snapshot(snapshot)) }

    private func emit(_ kind: PlaybackEvent.Kind) {
        guard let loadIdentity else { return }
        eventSequence += 1
        outputUpdate(.event(PlaybackEvent(identity: loadIdentity, sequence: eventSequence, kind: kind)))
    }

    func start() {
        queue.async { [self] in
            guard !stopped, let layer, let mpv = mpv_create() else {
                startupFailed = true
                return
            }
            handle = mpv
            // Never forward libmpv logs: they may contain signed media URLs.
            let options = [
                "terminal": "no", "msg-level": "all=no", "config": "no",
                "load-scripts": "no", "ytdl": "no", "osc": "no",
                "input-default-bindings": "no", "input-vo-keyboard": "no",
                "vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "moltenvk",
                "hwdec": "videotoolbox", "target-colorspace-hint": "no",
                "keep-open": "yes", "idle": "yes", "force-window": "yes",
                "sub-auto": "no", "audio-file-auto": "no", "osd-level": "0",
                "tls-verify": "yes", "network-timeout": "20",
                "demuxer-max-bytes": "67108864", "demuxer-max-back-bytes": "16777216"
            ]
            for (name, value) in options { mpv_set_option_string(mpv, name, value) }
            mpv_request_log_messages(mpv, "no")
            // libass cannot reliably discover CJK system fonts on iOS. A bundled
            // OFL font gives plain subtitles and missing ASS glyphs a real fallback.
            if let fonts = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true) {
                mpv_set_option_string(mpv, "sub-fonts-dir", fonts.path)
                mpv_set_option_string(mpv, "sub-font", "Noto Sans CJK TC")
            }
            // The static TLS stack cannot rely on the simulator/macOS trust-store path.
            if let caFile = Bundle.main.url(forResource: "cacert", withExtension: "pem") {
                mpv_set_option_string(mpv, "tls-ca-file", caFile.path)
            }
            var windowID = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
            guard mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &windowID) >= 0,
                  mpv_initialize(mpv) >= 0 else {
                startupFailed = true
                mpv_terminate_destroy(mpv)
                handle = nil
                return
            }
            mpv_observe_property(mpv, 1, "track-list", MPV_FORMAT_NONE)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func load(url: URL, generation: Int, identity: PlaybackLoadIdentity, speed: Double, paused: Bool, pauseRevision: Int, resumePosition: Double?) {
        queue.async { [self] in
            guard !stopped else { return }
            state = MPVSnapshot(generation: generation, pauseRevision: pauseRevision, paused: paused, loading: true, speed: speed)
            loadIdentity = identity
            eventSequence = 2
            expectedEntryID = nil
            activeEntryID = nil
            reportedPaused = nil
            reportedEOF = false
            pendingReplay = nil
            pendingRestore = nil
            pendingResumePosition = resumePosition
            pendingLoadPause = paused
            pendingSubtitleURL = nil
            pendingSubtitleSelection = nil
            fileLoaded = false
            audioResumeFailed = false
            guard !startupFailed, let handle else {
                fail(String(localized: "Unable to start the mpv player."))
                return
            }
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playback, mode: .moviePlayback)
                try audio.setActive(true)
                if !audioActive { Self.audioUsers += 1; audioActive = true }
            } catch {
                fail(String(localized: "Unable to start the mpv player."))
                return
            }
            // Discard previous-file events before replacing the current item.
            while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {}
            setProperty("pause", paused ? "yes" : "no")
            setProperty("speed", String(speed))
            // sid is sticky across files; an episode must not inherit Off or a track ID.
            setProperty("sid", "auto")
            loadMedia(url, handle: handle)
            output(state)
        }
    }

    func setPaused(_ paused: Bool, revision: Int) {
        queue.async { [self] in
            guard !stopped else { return }
            state.pauseRevision = revision
            if !fileLoaded { pendingLoadPause = paused }
            guard handle != nil else {
                state.paused = true
                output(state)
                return
            }
            if !paused {
                // An interruption deactivates the system session. libmpv's
                // audio renderer resumes its clock but does not reactivate it.
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    if !audioActive { Self.audioUsers += 1; audioActive = true }
                    if audioResumeFailed { state.error = nil; audioResumeFailed = false }
                } catch {
                    setProperty("pause", "yes")
                    state.paused = true
                    state.error = String(localized: "Unable to start the mpv player.")
                    audioResumeFailed = true
                    output(state)
                    return
                }
            }
            setProperty("pause", paused ? "yes" : "no")
            state.paused = paused
            output(state)
        }
    }

    func setSpeed(_ speed: Double) {
        queue.async { [self] in setProperty("speed", String(speed)) }
    }

    func seek(to seconds: Double, generation: Int, identity: PlaybackLoadIdentity?, previousLoad: PlaybackLoadIdentity?) {
        queue.async { [self] in
            guard !stopped else { return }
            if let identity, let previousLoad {
                // Retire old queued EOF/restart facts before beginning a replay.
                if let handle {
                    while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {}
                }
                loadIdentity = identity
                eventSequence = 2
                state.generation = generation
                state.ended = false
                reportedPaused = nil
                guard fileLoaded, let expectedEntryID, activeEntryID == expectedEntryID else {
                    fail(String(localized: "Unable to open this media."))
                    return
                }
                nextSeekRequest += 1
                pendingReplay = MPVReplay(previousLoad: previousLoad, requestID: nextSeekRequest)
            } else {
                guard state.generation == generation else { return }
                nextSeekRequest += 1
                if let pendingReplay {
                    // A second drag before restart supersedes the pending seek,
                    // not the replay's load identity or its media evidence.
                    self.pendingReplay = MPVReplay(previousLoad: pendingReplay.previousLoad, requestID: nextSeekRequest)
                }
            }
            send(["seek", String(seconds), "absolute+exact"], request: nextSeekRequest)
        }
    }


    func selectSubtitle(id: Int?, generation: Int) {
        queue.async { [self] in
            guard !stopped, state.generation == generation else { return }
            pendingSubtitleSelection = .some(id)
            if fileLoaded { applySubtitleSelection() }
        }
    }

    func clearSubtitles(generation: Int) {
        queue.async { [self] in
            guard !stopped, state.generation == generation else { return }
            pendingSubtitleURL = nil
            pendingSubtitleSelection = nil
            setProperty("sid", "no")
            state.selectedSubtitle = nil
            state.subtitleError = nil
            output(state)
        }
    }

    func setSubtitlePosition(_ percentage: Double) {
        queue.async { [self] in setProperty("sub-pos", String(percentage)) }
    }

    func addSubtitle(url: URL, generation: Int) {
        queue.async { [self] in
            guard !stopped, state.generation == generation else { return }
            pendingSubtitleURL = url
            pendingSubtitleSelection = nil
            if fileLoaded { importPendingSubtitle() }
        }
    }

    private func importPendingSubtitle() {
        guard let url = pendingSubtitleURL, let handle, fileLoaded else { return }
        pendingSubtitleURL = nil
        let arguments = ["sub-add", url.isFileURL ? url.path : url.absoluteString, "select",
                         String(localized: "External subtitle")]
        let pointers = arguments.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var args: [UnsafePointer<CChar>?] = pointers.map { $0.map { UnsafePointer<CChar>($0) } }
        args.append(nil)
        // Complete on the serial worker before a replacement load can begin.
        // An asynchronous sub-add could otherwise attach its result to a later file.
        if mpv_command(handle, &args) < 0 {
            state.subtitleError = String(localized: "Unable to load subtitles.")
        } else {
            outputUpdate(.subtitleImported(url, generation: state.generation))
        }
        readSubtitleTracks()
        output(state)
    }

    private func applySubtitleSelection() {
        guard let selection = pendingSubtitleSelection, fileLoaded else { return }
        pendingSubtitleSelection = nil
        guard selection == nil || state.subtitles.contains(where: { $0.id == selection }) else { return }
        setProperty("sid", selection.map(String.init) ?? "no")
        state.selectedSubtitle = selection
    }

    func setVideoVisible(_ visible: Bool) {
        queue.async { [self] in setProperty("vid", visible ? "auto" : "no") }
    }

    func shutdown(onStopped: @escaping @Sendable () -> Void = {}) {
        queue.async { [self] in
            guard !stopped else { onStopped(); return }
            stopped = true
            timer?.cancel()
            timer = nil
            if let handle { mpv_terminate_destroy(handle) }
            handle = nil
            layer = nil
            if audioActive {
                Self.audioUsers -= 1
                if Self.audioUsers == 0 {
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
                audioActive = false
            }
            onStopped()
            onShutdown()
        }
    }

    private func setProperty(_ name: String, _ value: String) {
        guard !stopped, let handle else { return }
        mpv_set_property_string(handle, name, value)
    }

    private func send(_ arguments: [String], request: UInt64) {
        guard !stopped, let handle else { return }
        let pointers = arguments.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var args: [UnsafePointer<CChar>?] = pointers.map { $0.map { UnsafePointer<CChar>($0) } }
        args.append(nil)
        let status = mpv_command_async(handle, request, &args)
        if status < 0 { commandFailed(request) }
    }

    /// The synchronous command only inserts the playlist entry, not the media load.
    /// Its returned ID keeps delayed stop/error/file-loaded events on the old load.
    private func loadMedia(_ url: URL, handle: OpaquePointer) {
        let arguments = ["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace"]
        let pointers = arguments.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var args: [UnsafePointer<CChar>?] = pointers.map { $0.map { UnsafePointer<CChar>($0) } }
        args.append(nil)
        var result = mpv_node()
        let status = mpv_command_ret(handle, &args, &result)
        defer { mpv_free_node_contents(&result) }
        guard status >= 0, result.format == MPV_FORMAT_NODE_MAP, let map = result.u.list?.pointee else {
            fail(String(localized: "Unable to open this media."))
            return
        }
        for index in 0..<Int(map.num) {
            guard let key = map.keys?[index], String(cString: key) == "playlist_entry_id",
                  let value = map.values?[index], value.format == MPV_FORMAT_INT64 else { continue }
            expectedEntryID = value.u.int64
            return
        }
        fail(String(localized: "Unable to open this media."))
    }

    private func poll() {
        guard !stopped, let handle else { return }
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_START_FILE:
                activeEntryID = event.pointee.data?.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id
            case MPV_EVENT_FILE_LOADED:
                guard let expectedEntryID, activeEntryID == expectedEntryID else { continue }
                fileLoaded = true
                state.error = nil
                // keep-open may re-pause the old EOF after loadfile was submitted.
                // Apply this load's latest intent only once its own file is ready.
                if let paused = pendingLoadPause {
                    setProperty("pause", paused ? "yes" : "no")
                    pendingLoadPause = nil
                }
                if let seconds = pendingResumePosition {
                    guard flag("seekable") else {
                        fail(String(localized: "Unable to open this media."))
                        continue
                    }
                    nextSeekRequest += 1
                    let duration = double("duration") ?? 0
                    let target = duration > 0 ? min(seconds, max(0, duration - 0.1)) : seconds
                    // Install suppression before publishing loaded or any actual sample,
                    // including samples close to very short saved resume positions.
                    pendingRestore = MPVRestore(requestID: nextSeekRequest, target: target)
                    send(["seek", String(target), "absolute+exact"], request: nextSeekRequest)
                    guard fileLoaded else { continue }
                }
                emit(.loaded)
                readSubtitleTracks()
                importPendingSubtitle()
                applySubtitleSelection()
            case MPV_EVENT_SEEK:
                if activeEntryID == expectedEntryID {
                    pendingRestore?.seeking = true
                    pendingRestore?.restarted = false
                }
            case MPV_EVENT_PLAYBACK_RESTART:
                if activeEntryID == expectedEntryID {
                    pendingReplay?.restarted = true
                    if pendingRestore?.seeking == true { pendingRestore?.restarted = true }
                }
            case MPV_EVENT_PROPERTY_CHANGE:
                if fileLoaded { readSubtitleTracks() }
            case MPV_EVENT_END_FILE:
                guard let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self),
                      let expectedEntryID, data.pointee.playlist_entry_id == expectedEntryID else { continue }
                switch data.pointee.reason {
                case MPV_END_FILE_REASON_ERROR:
                    fail(String(localized: "Unable to open this media."))
                case MPV_END_FILE_REASON_EOF:
                    if fileLoaded, pendingRestore == nil, !reportedEOF { reportedEOF = true; emit(.naturalEOF) }
                case MPV_END_FILE_REASON_STOP, MPV_END_FILE_REASON_QUIT:
                    fileLoaded = false
                    state.loading = false
                    emit(.stopped)
                case MPV_END_FILE_REASON_REDIRECT:
                    if data.pointee.playlist_insert_id > 0 {
                        self.expectedEntryID = data.pointee.playlist_insert_id
                        fileLoaded = false
                    }
                default: break
                }
            case MPV_EVENT_COMMAND_REPLY:
                if event.pointee.error < 0 { commandFailed(event.pointee.reply_userdata) }
                if event.pointee.reply_userdata == pendingReplay?.requestID, event.pointee.error >= 0 {
                    pendingReplay?.acknowledged = true
                }
                if event.pointee.reply_userdata == pendingRestore?.requestID, event.pointee.error >= 0 {
                    pendingRestore?.acknowledged = true
                }
            default: break
            }
        }
        if fileLoaded {
            let actualPosition = double("time-pos")
            if let actualPosition, actualPosition >= 0 { state.position = actualPosition }
            state.duration = max(0, double("duration") ?? 0)
            state.speed = double("speed") ?? state.speed
            state.paused = flag("pause")
            let backendEnded = flag("eof-reached")
            if let replay = pendingReplay, replay.acknowledged, replay.restarted, !backendEnded,
               let actualPosition, actualPosition >= 0 {
                // This is an actual restarted seek of the retained, previously
                // FILE_LOADED media—not a second fabricated file-loaded event.
                emit(.replayStarted(previousLoad: replay.previousLoad))
                pendingReplay = nil
                reportedEOF = false
            }
            if let restore = pendingRestore, restore.acknowledged, restore.restarted,
               let actualPosition, abs(actualPosition - restore.target) <= 2, let loadIdentity {
                pendingRestore = nil
                pendingResumePosition = nil
                outputUpdate(.resumeConfirmed(loadIdentity))
            }
            state.ended = pendingReplay == nil && backendEnded
            state.seekable = flag("seekable")
            state.loading = flag("paused-for-cache")
            var sid = Int64(0)
            state.selectedSubtitle = mpv_get_property(handle, "sid", MPV_FORMAT_INT64, &sid) >= 0 && sid > 0 ? Int(sid) : nil
            if pendingReplay == nil, pendingRestore == nil, let actualPosition, actualPosition >= 0 {
                emit(.progress(PlaybackProgressSample(position: actualPosition,
                                                     duration: state.duration > 0 ? state.duration : nil)))
            }
            if pendingReplay == nil, pendingRestore == nil, reportedPaused != state.paused {
                reportedPaused = state.paused
                emit(.paused(state.paused))
            }
            // keep-open retains the EOF frame and need not send END_FILE until
            // a later stop/replacement. Only the actual backend flag can end it.
            if pendingReplay == nil, pendingRestore == nil, state.ended, !reportedEOF {
                reportedEOF = true
                emit(.naturalEOF)
            }
        }
        output(state)
        state.subtitleError = nil
    }

    private func commandFailed(_ request: UInt64) {
        if request == pendingReplay?.requestID || request == pendingRestore?.requestID { fail(String(localized: "Unable to open this media.")) }
    }

    private func fail(_ message: String) {
        setProperty("pause", "yes")
        state.error = message
        state.loading = false
        state.paused = true
        fileLoaded = false
        pendingReplay = nil
        pendingRestore = nil
        pendingResumePosition = nil
        emit(.failed(.mediaPlayback))
        output(state)
    }

    private func double(_ name: String) -> Double? {
        var value = 0.0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return nil }
        return value
    }

    private func flag(_ name: String) -> Bool {
        var value = Int32(0)
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 && value != 0
    }

    private func readSubtitleTracks() {
        var node = mpv_node()
        guard mpv_get_property(handle, "track-list", MPV_FORMAT_NODE, &node) >= 0 else { return }
        defer { mpv_free_node_contents(&node) }
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list?.pointee else { return }
        var tracks: [SubtitleTrack] = []
        for index in 0..<Int(list.num) {
            guard let value = list.values?[index], value.format == MPV_FORMAT_NODE_MAP,
                  let map = value.u.list?.pointee else { continue }
            var id: Int?
            var type = ""
            var title = ""
            var language = ""
            var external = false
            for keyIndex in 0..<Int(map.num) {
                guard let key = map.keys?[keyIndex], let item = map.values?[keyIndex] else { continue }
                switch String(cString: key) {
                case "id": if item.format == MPV_FORMAT_INT64 { id = Int(item.u.int64) }
                case "type": if item.format == MPV_FORMAT_STRING { type = String(cString: item.u.string) }
                case "title": if item.format == MPV_FORMAT_STRING { title = String(cString: item.u.string) }
                case "lang": if item.format == MPV_FORMAT_STRING { language = String(cString: item.u.string) }
                case "external": if item.format == MPV_FORMAT_FLAG { external = item.u.flag != 0 }
                default: break
                }
            }
            guard type == "sub", let id else { continue }
            if external { title = String(localized: "External subtitle") }
            if title.isEmpty { title = String(localized: "Subtitle") + " \(id)" }
            if !language.isEmpty { title += " · \(language)" }
            tracks.append(SubtitleTrack(id: id, title: title))
        }
        state.subtitles = tracks
    }
}
