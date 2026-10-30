import SwiftUI
import UniformTypeIdentifiers

private enum PlayerPanel: String, Identifiable {
    case speed, subtitles, danmaku, episodes, settings
    var id: String { rawValue }
}

private struct PlayerIdleKey: Equatable {
    let immersive: Bool
    let paused: Bool
    let loading: Bool
    let scrubbing: Bool
    let panel: PlayerPanel?
    let voiceOver: Bool
    let interaction: Int
}

extension View {
    func playbackPresentation(session: Binding<PlaybackSession?>) -> some View {
        fullScreenCover(isPresented: Binding(get: { session.wrappedValue != nil }, set: { presented in
            if !presented {
                session.wrappedValue?.stop()
                session.wrappedValue = nil
            }
        })) {
            if let current = session.wrappedValue { PlayerScreen(session: current).id(current.id) }
        }
    }
}

struct PlayerScreen: View {
    let session: PlaybackSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("mobile.player.seekSeconds") private var seekSeconds = 10
    @State private var orientation = PlayerOrientationController()
    @State private var panel: PlayerPanel?
    @State private var immersive = false
    @State private var tabletPresentation: Bool?
    @State private var controlsVisible = true
    @State private var interaction = 0
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var seekFeedback: Int?
    @State private var feedbackSequence = 0

    private let accent = Color(red: 0.40, green: 0.88, blue: 0.80)
    private let canvas = Color(red: 0.045, green: 0.057, blue: 0.078)
    private var engine: MPVEngine { session.engine }
    private var step: Int { [5, 10, 15, 30, 60].contains(seekSeconds) ? seekSeconds : 10 }
    private var chromeVisible: Bool {
        controlsVisible || engine.isPaused || engine.isLoading || engine.errorMessage != nil || session.isAdvancing || session.nextError != nil || panel != nil || scrubbing || voiceOver
    }
    private var idleKey: PlayerIdleKey {
        PlayerIdleKey(immersive: immersive, paused: engine.isPaused, loading: engine.isLoading,
                      scrubbing: scrubbing, panel: panel, voiceOver: voiceOver, interaction: interaction)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let actualLandscape = geometry.size.width > geometry.size.height
                let wide = (UIDevice.current.userInterfaceIdiom == .pad ? tabletPresentation : nil) ?? actualLandscape
                let stageHeight = wide ? geometry.size.height : min(geometry.size.width * 9 / 16, geometry.size.height * 0.54)
                let controlsClearance = geometry.size.width < 480 ? 180.0 : 120.0
                let subtitlePosition = wide && chromeVisible ? max(50, 100 - controlsClearance / max(1, stageHeight) * 100) : 100
                VStack(spacing: 0) {
                    HistoryStorageNotice().padding(.horizontal)
                    // Keep this surface in the same structural position when rotating.
                    // Moving it between conditional branches would detach libmpv's Metal layer.
                    videoStage(wide: wide, actualLandscape: actualLandscape)
                        .frame(height: stageHeight)
                    if !wide { portraitDetails }
                }
                .onChange(of: wide, initial: true) { _, value in
                    immersive = value
                    showControls()
                }
                .onChange(of: actualLandscape) { _, _ in
                    tabletPresentation = nil
                    showControls()
                }
                .overlay(alignment: .topLeading) {
                    Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
                        .accessibilityElement().accessibilityLabel("Player presentation")
                        .accessibilityIdentifier("playerPresentation")
                        .accessibilityValue(wide ? "fullscreen" : "inline")
                }
                .onChange(of: subtitlePosition, initial: true) { _, value in engine.setSubtitlePosition(value) }
            }
            .background(canvas.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.isAdvancing || session.nextError != nil {
                    NextEpisodeStatus(session: session).padding(12).background(canvas)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .background(PlayerOrientationObserver(controller: orientation).allowsHitTesting(false))
            .sheet(item: $panel) { selected in
                NavigationStack {
                    Group {
                        switch selected {
                        case .speed: SpeedPanel(engine: engine)
                        case .subtitles: SubtitlePanel(session: session)
                        case .danmaku: DanmakuPanel(session: session)
                        case .episodes: EpisodePanel(session: session)
                        case .settings: PlayerSettings(seekSeconds: $seekSeconds)
                        }
                    }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil }.accessibilityIdentifier("playerSheetDone") } }
                }
                .alert("Unable to import file", isPresented: Binding(get: { session.importFailed && panel != nil }, set: { session.importFailed = $0 })) {
                    Button("OK", role: .cancel) {}
                } message: { Text("Choose a supported subtitle or danmaku file. Existing comments have been kept.") }
                .presentationDetents(selected == .danmaku ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
                .tint(accent)
            }
            .alert("Unable to import file", isPresented: Binding(get: { session.importFailed && panel == nil }, set: { session.importFailed = $0 })) {
                Button("OK", role: .cancel) {}
            } message: { Text("Choose a supported subtitle or danmaku file. Existing comments have been kept.") }
            .alert("Unable to rotate", isPresented: Binding(get: { orientation.errorMessage != nil }, set: { if !$0 { orientation.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(orientation.errorMessage ?? "") }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onChange(of: engine.subtitleErrorMessage) { _, message in
            if message != nil { session.importFailed = true; engine.subtitleErrorMessage = nil }
        }
        .onChange(of: panel) { _, _ in showControls() }
        .onChange(of: engine.isPaused) { _, paused in if paused { showControls() } }
        .onAppear { session.setForeground(scenePhase == .active); session.start() }
        .onChange(of: scenePhase) { _, value in session.setForeground(value == .active) }
        .task(id: idleKey) {
            guard immersive, !engine.isPaused, !engine.isLoading, !session.isAdvancing, session.nextError == nil, !scrubbing, panel == nil, !voiceOver else { return }
            do {
                try await Task.sleep(for: .milliseconds(3500))
                controlsVisible = false
            } catch {}
        }
        .task(id: feedbackSequence) {
            guard seekFeedback != nil else { return }
            do { try await Task.sleep(for: .milliseconds(800)); seekFeedback = nil } catch {}
        }
    }

    private func videoStage(wide: Bool, actualLandscape: Bool) -> some View {
        ZStack {
            MPVVideoView(engine: engine).accessibilityIdentifier("playerVideo")
            MobileDanmakuOverlay(store: session.danmaku, position: engine.position)
                .allowsHitTesting(false)
            HStack(spacing: 0) {
                seekRegion(forward: false)
                seekRegion(forward: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Show playback controls")
            .accessibilityAction { showControls() }
            .accessibilityIdentifier("playerControlsToggle")
            if engine.isLoading || session.isPreparing { ProgressView().tint(.white).allowsHitTesting(false) }
            if let error = engine.errorMessage {
                ContentUnavailableView("Playback unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                    .foregroundStyle(.white).allowsHitTesting(false)
            }
            ZStack {
                LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(wide ? 0.82 : 0.2)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    if wide {
                        VStack(spacing: 0) {
                            timeline
                            ViewThatFits(in: .horizontal) {
                                HStack {
                                    timeReadout
                                    Spacer(minLength: 12)
                                    featureBar(compact: true)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    timeReadout
                                    featureGrid(compact: true)
                                }
                            }
                        }.padding(.horizontal, 20).padding(.bottom, 8)
                    }
                }
                transport
            }
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)
            .accessibilityHidden(!chromeVisible)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: chromeVisible)
            if let seekFeedback {
                Text("\(seekFeedback > 0 ? "+" : "")\(seekFeedback)s")
                    .font(.headline.monospacedDigit()).padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.black.opacity(0.8), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: seekFeedback > 0 ? .trailing : .leading)
                    .padding(.horizontal, 22).allowsHitTesting(false)
            }
        }
        .background(.black)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playerLayout")
        .accessibilityValue(actualLandscape ? "landscape" : "portrait")
        .overlay(alignment: .topLeading) {
            // A stable accessibility status remains available when the chrome is hidden.
            Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
                .accessibilityElement().accessibilityLabel("Playback controls")
                .accessibilityIdentifier("playerChrome")
                .accessibilityValue(chromeVisible ? "visible" : "hidden")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { session.stop(); dismiss() } label: {
                Image(systemName: "chevron.down").font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44).background(.black.opacity(0.35), in: Circle())
            }.accessibilityLabel("Done").accessibilityIdentifier("playerClose")
            Text(session.current.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Text(LocalizedStringKey(engine.isPaused ? "Paused" : "Playing"))
                .font(.caption).foregroundStyle(.white.opacity(0.7))
                .accessibilityIdentifier("playerPlaybackState")
                .accessibilityValue(engine.isPaused ? "paused" : "playing")
        }.padding(.horizontal, 12).padding(.top, 4).foregroundStyle(.white)
    }

    private var transport: some View {
        HStack(spacing: 30) {
            seekButton(forward: false)
            Button { engine.togglePause(); showControls() } label: {
                Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .offset(x: engine.isPaused ? 2 : 0)
                    .foregroundStyle(.black).frame(width: 64, height: 64)
                    .background(.white, in: Circle())
            }
            .accessibilityLabel(engine.isPaused ? Text("Resume playback") : Text("Pause playback"))
            .accessibilityValue(engine.isPaused ? "paused" : "playing")
            .accessibilityIdentifier("playerTogglePause")
            seekButton(forward: true)
        }.buttonStyle(.plain)
    }

    private func seekButton(forward: Bool) -> some View {
        Button { skip(forward ? step : -step) } label: {
            VStack(spacing: 0) {
                Image(systemName: forward ? "goforward" : "gobackward").font(.system(size: 22, weight: .medium))
                Text("\(step)s").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
            }.frame(width: 52, height: 52).background(.black.opacity(0.5), in: Circle())
        }
        .foregroundStyle(.white).disabled(!engine.canSeek)
        .accessibilityLabel(forward ? Text("Seek forward") : Text("Seek backward"))
        .accessibilityIdentifier(forward ? "playerSeekForward" : "playerSeekBackward")
    }

    private func seekRegion(forward: Bool) -> some View {
        Color.clear.contentShape(Rectangle())
            .frame(maxWidth: .infinity)
            .onTapGesture(count: 2) { skip(forward ? step : -step) }
            .onTapGesture { toggleControls() }
            .accessibilityElement()
            .accessibilityLabel(forward ? Text("Double tap to seek forward") : Text("Double tap to seek backward"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { skip(forward ? step : -step) }
            .accessibilityIdentifier(forward ? "playerDoubleTapForward" : "playerDoubleTapBackward")
    }

    private var portraitDetails: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                VStack(spacing: 0) {
                    timeline
                    timeReadout
                }
                featureBar(compact: false)
            }.padding(.horizontal, 20).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Now playing").font(.caption.weight(.semibold)).foregroundStyle(accent)
                        Text(session.current.title).font(.title3.weight(.semibold)).lineLimit(2)
                    }.padding(.top, 6)
                    Divider().overlay(.white.opacity(0.08))
                    HStack {
                        Text("Playback queue").font(.headline)
                        Text(session.episodes.count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Button { open(.episodes) } label: {
                            Image(systemName: "plus").frame(width: 44, height: 44)
                        }.accessibilityLabel("Add episodes")
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(Array(session.episodes.enumerated()), id: \.element.id) { index, episode in
                            Button {
                                session.selectEpisode(index)
                                showControls()
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10).fill(index == session.selectedIndex ? accent.opacity(0.18) : .white.opacity(0.06))
                                        Image(systemName: index == session.selectedIndex ? "play.fill" : "play.rectangle")
                                            .foregroundStyle(index == session.selectedIndex ? accent : .secondary)
                                    }.frame(width: 64, height: 44)
                                    Text(episode.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Spacer(minLength: 8)
                                    if index == session.selectedIndex {
                                        Image(systemName: "waveform").foregroundStyle(accent)
                                    }
                                }.padding(10).frame(minHeight: 64)
                                    .background(index == session.selectedIndex ? .white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 14))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("queue-episode-\(index)")
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }
        }.background(canvas)
    }

    private var timeline: some View {
        Slider(value: Binding(get: { scrubbing ? scrubPosition : min(engine.position, max(1, engine.duration)) },
                              set: { scrubPosition = $0 }), in: 0...max(1, engine.duration)) { editing in
            if editing { scrubPosition = engine.position }
            scrubbing = editing
            showControls()
            if !editing { engine.seek(to: scrubPosition) }
        }
        .disabled(!engine.canSeek || engine.duration <= 0)
        .frame(minHeight: 44)
        .accessibilityLabel("Playback position").accessibilityIdentifier("playerTimeline")
    }

    private var timeReadout: some View {
        HStack(spacing: 4) {
            Text(time(scrubbing ? scrubPosition : engine.position))
                .foregroundStyle(.white)
                .accessibilityIdentifier("playerElapsedSeconds")
                .accessibilityValue(String(format: "%.1f", engine.playbackState.actualPosition ?? 0))
            Text("/").foregroundStyle(.secondary)
            Text(time(engine.duration)).foregroundStyle(.secondary)
            if !immersive { Spacer() }
        }.font(.caption.monospacedDigit()).fixedSize(horizontal: immersive, vertical: false)
    }

    private func featureBar(compact: Bool) -> some View {
        Group {
            if compact {
                HStack(spacing: 8) { featureButtons(compact: true) }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { featureButtons(compact: false) }
                    featureGrid(compact: false)
                }
            }
        }.buttonStyle(.plain).foregroundStyle(.white)
    }

    private func featureGrid(compact: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: 8), count: 3), spacing: 6) {
            featureButtons(compact: compact)
        }.buttonStyle(.plain).foregroundStyle(.white)
    }

    @ViewBuilder private func featureButtons(compact: Bool) -> some View {
            Button { open(.speed) } label: {
                featureLabel("Speed", symbol: nil, compact: compact, text: rate(engine.speed))
            }.accessibilityIdentifier("playerSpeed").accessibilityValue(String(engine.speed))
            featureButton("Subtitles", symbol: "captions.bubble", panel: .subtitles, id: "playerSubtitles", compact: compact)
            featureButton("Danmaku", symbol: session.danmaku.enabled ? "text.bubble.fill" : "text.bubble", panel: .danmaku, id: "playerDanmaku", compact: compact)
            featureButton("Episodes", symbol: "rectangle.stack", panel: .episodes, id: "playerEpisodes", compact: compact)
            Button { session.nextEpisode(); showControls() } label: {
                featureLabel("Next episode", symbol: "forward.end", compact: compact)
            }
            .disabled(!session.canRequestNext || session.isAdvancing)
            .accessibilityLabel("Next episode").accessibilityIdentifier("playerNextEpisode")
            featureButton("Settings", symbol: "gearshape", panel: .settings, id: "playerSettings", compact: compact)
            Button {
                showControls()
                if UIDevice.current.userInterfaceIdiom == .pad {
                    // iPad windowing can forbid programmatic orientation changes.
                    // Expand within this window while retaining natural rotation/multitasking.
                    tabletPresentation = !immersive
                } else {
                    orientation.toggleOrientation()
                }
            } label: {
                featureLabel(immersive ? "Exit fullscreen" : "Fullscreen", symbol: immersive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", compact: compact)
            }.accessibilityLabel(immersive ? Text("Exit fullscreen") : Text("Enter fullscreen"))
                .accessibilityIdentifier("playerFullscreen")
    }

    private func featureButton(_ title: LocalizedStringKey, symbol: String, panel: PlayerPanel, id: String, compact: Bool) -> some View {
        Button { open(panel) } label: { featureLabel(title, symbol: symbol, compact: compact) }
            .accessibilityLabel(Text(title))
            .accessibilityIdentifier(id)
            .accessibilityValue(panel == .subtitles ? (engine.selectedSubtitleID.map(String.init) ?? "off") : panel == .episodes ? String(session.selectedIndex) : "")
    }

    private func featureLabel(_ title: LocalizedStringKey, symbol: String?, compact: Bool, text: String? = nil) -> some View {
        VStack(spacing: 6) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 19, weight: .medium)) }
                else { Text(text ?? "").font(.system(size: 16, weight: .semibold, design: .rounded)) }
            }.frame(height: 22)
            if !compact { Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8) }
        }
        .frame(minWidth: 44, maxWidth: compact ? nil : .infinity)
        .frame(width: compact ? 44 : nil, height: compact ? 44 : 62)
        .background(.white.opacity(compact ? 0 : 0.055), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private func open(_ selected: PlayerPanel) { showControls(); panel = selected }
    private func showControls() { controlsVisible = true; interaction += 1 }
    private func toggleControls() {
        if chromeVisible && !engine.isPaused && !voiceOver { controlsVisible = false }
        else { showControls() }
    }
    private func skip(_ amount: Int) {
        guard engine.canSeek else { return }
        engine.seek(by: Double(amount)); seekFeedback = amount; feedbackSequence += 1
        showControls()
    }
    private func rate(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) + "×" }
    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let value = Int(seconds)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct SpeedPanel: View {
    let engine: MPVEngine
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { value in
                    Button {
                        engine.setSpeed(value)
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Text(value.formatted(.number.precision(.fractionLength(0...2))) + "×")
                            if abs(engine.speed - value) < 0.01 { Image(systemName: "checkmark") }
                        }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                        .background(.white.opacity(abs(engine.speed - value) < 0.01 ? 0.15 : 0.06), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityIdentifier("speed-\(value)")
                }
            }.padding(20)
        }.navigationTitle("Playback speed")
    }
}

private struct SubtitlePanel: View {
    let session: PlaybackSession
    @State private var importing = false
    @State private var importEpisodeID: UUID?
    var body: some View {
        List {
            Button { session.engine.selectSubtitle(id: nil) } label: {
                HStack { Text("Subtitles off"); Spacer(); if session.engine.selectedSubtitleID == nil { Image(systemName: "checkmark") } }.frame(minHeight: 44)
            }.accessibilityIdentifier("subtitle-off")
            ForEach(session.engine.subtitleTracks) { track in
                Button { session.engine.selectSubtitle(id: track.id) } label: {
                    HStack { Text(track.title); Spacer(); if session.engine.selectedSubtitleID == track.id { Image(systemName: "checkmark") } }.frame(minHeight: 44)
                }.accessibilityIdentifier("subtitle-\(track.id)")
            }
            Button("Import subtitles…") { importEpisodeID = session.current.id; importing = true }.frame(minHeight: 44)
            Text("Supports embedded tracks and local SRT, ASS or WebVTT imports for this episode. Online subtitle search is not available.").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Subtitles")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.text, .data]) { result in
                guard importEpisodeID == session.current.id else { return }
                if case .success(let url) = result { session.importSubtitle(url) }
                else if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled { session.importFailed = true }
            }
    }
}

private struct DanmakuPanel: View {
    let session: PlaybackSession
    @State private var importing = false
    @State private var importEpisodeID: UUID?
    var body: some View {
        @Bindable var store = session.danmaku
        Form {
            Toggle("Show danmaku", isOn: $store.enabled).accessibilityIdentifier("danmaku-enabled")
            Section("Automatic danmaku") {
                Toggle("Fetch verified episode danmaku", isOn: $store.automaticEnabled)
                    .accessibilityIdentifier("danmaku-automatic")
                Text(store.automaticStatus.message).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("danmaku-automaticStatus")
                if store.automaticStatus == .loading {
                    HStack {
                        ProgressView()
                        Button("Cancel download") { store.cancelAutomatic() }
                            .accessibilityIdentifier("danmaku-cancel")
                    }
                } else if store.automaticStatus.canRetry {
                    Button("Retry danmaku") { store.retryAutomatic() }
                        .accessibilityIdentifier("danmaku-retry")
                }
                Text("Only explicit source episode bindings to public Bilibili XML are supported. No title matching or login bypass. The public comment pool may be incomplete.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Filter") {
                TextField("Blocked words, separated by commas", text: $store.blockedWords)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("danmaku-filter")
                Toggle("Hide scrolling comments", isOn: $store.hideScrolling).accessibilityIdentifier("danmaku-hideScrolling")
                Toggle("Hide top comments", isOn: $store.hideTop).accessibilityIdentifier("danmaku-hideTop")
                Toggle("Hide bottom comments", isOn: $store.hideBottom).accessibilityIdentifier("danmaku-hideBottom")
            }
            Section {
                Button("Import danmaku…") { importEpisodeID = session.current.id; importing = true }.frame(minHeight: 44)
                LabeledContent("Loaded comments", value: String(store.entries.count)).accessibilityIdentifier("playerDanmakuCount").accessibilityValue(String(store.entries.count))
                LabeledContent("Comments after filtering", value: String(store.filteredCount)).accessibilityIdentifier("playerDanmakuFilteredCount").accessibilityValue(String(store.filteredCount))
                Text("Import a local Bilibili XML or compatible JSON file. Imports are kept separately for each episode and take priority over automatic downloads.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Danmaku")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.xml, .json]) { result in
                guard importEpisodeID == session.current.id else { return }
                if case .success(let url) = result { session.importDanmaku(url) }
                else if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled { session.importFailed = true }
            }
    }
}

private struct EpisodePanel: View {
    let session: PlaybackSession
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var importing = false
    @State private var invalid = false
    var body: some View {
        List {
            Section("Next episode") {
                @Bindable var playback = session
                Toggle("Auto-play next episode", isOn: $playback.autoPlayNext).accessibilityIdentifier("playerAutoPlayNext")
                Button("Next episode") { session.nextEpisode() }
                    .disabled(!session.canRequestNext || session.isAdvancing)
                    .accessibilityIdentifier("episode-next")
                if session.isAdvancing || session.nextError != nil { NextEpisodeStatus(session: session) }
                Text("Next uses your playback queue or stays within the same source, catalog group, line and quality. If no matching next episode is available, playback stops.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Playback queue") {
                ForEach(Array(session.episodes.enumerated()), id: \.element.id) { index, episode in
                    Button { session.selectEpisode(index); dismiss() } label: {
                        HStack { Text(episode.title); Spacer(); if index == session.selectedIndex { Image(systemName: "checkmark") } }.frame(minHeight: 48)
                    }.accessibilityIdentifier("episode-\(index)")
                }
            }
            Section("Add episodes") {
                TextField("https://…", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Add media link") {
                    guard let url = MediaAddress.parse(address) else { invalid = true; return }
                    session.append(urls: [url]); address = ""
                }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).frame(minHeight: 44)
                Button("Choose video files…") { importing = true }.frame(minHeight: 44)
                Text("Add files or media links to this queue. Bangumi does not supply playback URLs.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Episodes")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { session.append(urls: urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }, securityScoped: true) }
                else if case .failure = result { session.importFailed = true }
            }
            .alert("Unable to open media", isPresented: $invalid) { Button("OK", role: .cancel) {} }
    }
}

private struct NextEpisodeStatus: View {
    let session: PlaybackSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.isAdvancing {
                HStack {
                    ProgressView()
                    Text("Preparing next episode…")
                    Spacer()
                    Button("Cancel") { session.cancelNextEpisode() }
                        .accessibilityIdentifier("playerCancelNext")
                }
            } else if let error = session.nextError {
                Text("Unable to play next episode").font(.headline)
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("playerNextError")
                HStack {
                    Button("Retry") { session.nextEpisode() }.disabled(!session.canRequestNext)
                        .accessibilityIdentifier("playerRetryNext")
                    Spacer()
                    Button("Cancel") { session.cancelNextEpisode() }
                        .accessibilityIdentifier("playerCancelNext")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct PlayerSettings: View {
    @Binding var seekSeconds: Int
    var body: some View {
        Form {
            Section("Double-tap seek interval") {
                ForEach([5, 10, 15, 30, 60], id: \.self) { seconds in
                    Button { seekSeconds = seconds } label: {
                        HStack { Text("\(seconds) seconds"); Spacer(); if seekSeconds == seconds { Image(systemName: "checkmark") } }.frame(minHeight: 44)
                    }.accessibilityIdentifier("seekStep-\(seconds)")
                }
                Text("Double-tap the right half of the video to seek forward, or the left half to seek backward. The same interval applies to the seek buttons.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
    }
}
