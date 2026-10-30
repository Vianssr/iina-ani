import SwiftUI

struct EpisodeBrowser: View {
    let anime: Anime
    @Environment(MobileLibrary.self) private var library
    @State private var episodes: [CatalogEpisode] = []
    @State private var loading = false
    @State private var failed = false
    @State private var revision = 0
    @State private var selection: CatalogEpisode?
    @State private var fetchedAt: Date?
    @State private var showingCached = false
    @State private var requestID = UUID()
    @ScaledMetric(relativeTo: .body) private var cellWidth = 64
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Episodes and sources").font(.title2.bold())
            Text("Select an episode, then confirm a source and its episode before playback.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Saved episode information is not downloaded video. Sources must be checked online before playback.")
                .font(.footnote).foregroundStyle(.secondary)
            if let fetchedAt {
                CatalogCacheNotice(fetchedAt: fetchedAt, cached: showingCached, stale: failed)
                    .accessibilityIdentifier("episodes-cache-notice")
            }
            if loading { ProgressView() }
            if failed {
                Text("Episodes could not be loaded.").foregroundStyle(.secondary)
            }
            if failed || library.cacheError {
                Button("Retry") { revision += 1 }.frame(minHeight: 48).buttonStyle(.bordered)
                    .accessibilityIdentifier("episodes-retry")
            } else if !loading && episodes.isEmpty {
                Text("No episodes listed yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(Set(episodes.map(\.type))).sorted(), id: \.self) { type in
                let group = episodes.filter { $0.type == type }
                Text(LocalizedStringKey(group.first?.group ?? "Other episodes")).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth), spacing: 8)], spacing: 8) {
                    ForEach(group) { episode in
                        EpisodeNumberButton(number: episode.number, title: episode.title,
                                            disabled: episode.isUpcoming()) { selection = episode }
                            .accessibilityHint(episode.isUpcoming() ? Text("Not aired yet") : Text("Find sources"))
                            .accessibilityIdentifier("catalog-episode-\(episode.id)")
                    }
                }
            }
        }
        .task(id: "\(anime.id)#\(revision)") { await load() }
        .onDisappear { requestID = UUID() }
        .sheet(item: $selection) { episode in SourcePicker(anime: anime, episode: episode) }
    }

    @MainActor private func load() async {
        let id = UUID()
        let subjectID = anime.id
        let requestedRevision = revision
        requestID = id
        if fetchedAt == nil, let cached = library.cachedEpisodes(for: subjectID) {
            episodes = cached.episodes
            fetchedAt = cached.fetchedAt
            showingCached = true
        }
        loading = true
        failed = false
        defer { if requestID == id { loading = false } }
        do {
            let values = try await CatalogClient().episodes(subjectID)
            try Task.checkCancellation()
            guard requestID == id, anime.id == subjectID, revision == requestedRevision else { return }
            let date = Date.now
            episodes = values
            fetchedAt = date
            showingCached = false
            library.cacheEpisodes(values, for: subjectID, fetchedAt: date)
        } catch {
            guard !Task.isCancelled, requestID == id, anime.id == subjectID,
                  revision == requestedRevision else { return }
            failed = true
        }
    }
}

struct SourcePicker: View {
    let anime: Anime
    let episode: CatalogEpisode
    @Environment(\.dismiss) private var dismiss
    @Environment(MobileLibrary.self) private var library
    @Environment(MobileSourceLibrary.self) private var sources
    @State private var sourceID = ""
    @State private var revision = 0
    @State private var importing = false
    @State private var mappingWriteFailed = false
    @State private var session: PlaybackSession?
    @State private var discovery = MobileSourceDiscovery()
    @State private var candidate: MobileSourceCandidate?
    @State private var automaticPlayback = false
    private var requestedWork: PlaybackWorkIdentity { .bangumi(anime.id) }
    private var requestedEpisode: PlaybackEpisodeIdentity { .bangumi(episode.id, type: episode.type, sort: episode.sort) }
    private var savedMapping: ConfirmedSourceMapping? { library.storedMapping(for: requestedWork, episode: requestedEpisode) }
    private var selectedSourceID: String {
        savedMapping?.context.selection.item.sourceID ?? (sourceID.isEmpty ? sources.sources.first?.id ?? "" : sourceID)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(anime.title).font(.title2.bold())
                    Text(episode.number + " · " + episode.title).foregroundStyle(.secondary)
                    if !library.isReadable {
                        Button("Reload saved selections") { library.retryLoad(); revision += 1 }
                            .frame(minHeight: 48).buttonStyle(.bordered)
                            .accessibilityIdentifier("source-mapping-storage-retry")
                    }
                    if sources.sources.contains(where: { $0.id == selectedSourceID }) {
                        Picker("Source", selection: Binding(get: { selectedSourceID }, set: { sourceID = $0 })) {
                            ForEach(sources.sources) { source in
                                Text(verbatim: source.configuration.name).tag(source.id)
                            }
                        }.pickerStyle(.menu).accessibilityIdentifier("source-picker")
                            .disabled(savedMapping != nil)
                    }
                    Button { importing = true } label: { Label("Import from URL", systemImage: "link.badge.plus") }
                        .frame(minHeight: 48).buttonStyle(.bordered).accessibilityIdentifier("source-import")
                    if savedMapping == nil, library.isReadable {
                        Button("Automatically find this episode") {
                            candidate = nil
                            discovery.find(anime: anime, episode: episode,
                                sources: sources.sources.map(\.configuration), library: library,
                                authority: { try sources.configurationRevision(for: $0) })
                        }.frame(minHeight: 48).buttonStyle(.borderedProminent)
                            .disabled(discovery.busy).accessibilityIdentifier("source-automatic-find")
                        Text("Only one exact work, season and episode with independent year and format evidence can start automatically. Other matches require confirmation.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if discovery.busy {
                            ProgressView("Loading source…")
                            Button("Cancel request") { discovery.cancel() }.frame(minHeight: 48)
                        }
                        if discovery.searched && discovery.automatic == nil {
                            Text("Confirm a source match manually.").font(.headline)
                            if discovery.candidates.isEmpty { Text(PlaybackFailure.noCandidates.mobileMessage) }
                            ForEach(discovery.candidates) { match in
                                Button {
                                    automaticPlayback = false; candidate = match; sourceID = match.configuration.id
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(verbatim: match.catalog.work.title)
                                        Text(verbatim: match.configuration.name).font(.caption)
                                        if match.episode == nil { Text("Exact episode evidence is missing; confirm the catalogue manually.").font(.caption) }
                                    }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                }.buttonStyle(.bordered).accessibilityIdentifier("source-automatic-candidate")
                            }
                            ForEach(discovery.failures, id: \.rawValue) { Text($0.mobileMessage).foregroundStyle(.secondary) }
                        }
                    }
                    if !sources.issues.isEmpty {
                        Text("Some source files could not be loaded. Existing files were preserved.").foregroundStyle(.secondary)
                        ForEach(sources.issues, id: \.self) { Text(verbatim: $0).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let source = sources.sources.first(where: { $0.id == selectedSourceID }) {
                        SourceContent(configuration: source.configuration, anime: anime, episode: episode,
                                      library: library, sources: sources, candidate: candidate,
                                      automatically: automaticPlayback, session: $session)
                            .id(source.id + "#" + source.configuration.configurationRevision + "#" + String(revision) + "#" + (candidate?.id ?? "manual"))
                    } else if let savedMapping {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Saved source selection").font(.headline)
                            Text(verbatim: savedMapping.sourceTitle)
                            Text(PlaybackFailure.configurationChanged.mobileMessage).accessibilityIdentifier("source-error")
                            Button("Choose source again") { removeUnavailableMapping() }
                                .frame(minHeight: 48).buttonStyle(.bordered).accessibilityIdentifier("source-reconfirm")
                        }.accessibilityElement(children: .contain).accessibilityIdentifier("source-saved-mapping")
                    } else {
                        Text("No sources configured. Import a configuration URL to get started.").foregroundStyle(.secondary)
                    }
                    if mappingWriteFailed {
                        Text("The saved source selection could not be changed. Existing data was preserved. Retry choosing the source again.")
                            .foregroundStyle(.secondary).accessibilityIdentifier("source-mapping-storage-error")
                    }
                }.padding(24)
            }
            .navigationTitle("Find sources").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            if sourceID.isEmpty { sourceID = savedMapping?.context.selection.item.sourceID ?? sources.sources.first?.id ?? "" }
            recordUnavailableMapping()
        }
        .onChange(of: discovery.automatic?.id) { _, _ in
            guard let match = discovery.automatic else { return }
            automaticPlayback = true; candidate = match; sourceID = match.configuration.id
        }
        .onChange(of: selectedSourceID) { _, _ in discovery.cancel() }
        .onDisappear { discovery.cancel() }
        .sheet(isPresented: $importing) {
            MobileSourceURLImportView(sources: sources, onSubscriptionApplied: {
                discovery.cancel(); candidate = nil; revision += 1
                recordUnavailableMapping()
            }) { id in
                discovery.cancel(); candidate = nil
                sourceID = savedMapping?.context.selection.item.sourceID ?? id
                revision += 1
                recordUnavailableMapping()
            }
        }
        .playbackPresentation(session: $session)
    }

    private func recordUnavailableMapping() {
        guard let savedMapping, !sources.sources.contains(where: { $0.id == savedMapping.context.selection.item.sourceID }) else { return }
        do { try library.invalidateMapping(for: requestedWork, episode: requestedEpisode, failure: .configurationChanged) }
        catch { mappingWriteFailed = true }
    }

    private func removeUnavailableMapping() {
        do {
            try library.removeMapping(for: requestedWork, episode: requestedEpisode)
            mappingWriteFailed = false
            sourceID = sources.sources.first?.id ?? ""
        } catch { mappingWriteFailed = true }
    }
}

struct SourceImportPreview: View {
    let draft: MobileSourceDraft
    let replaces: Bool
    let currentRevision: String?
    let apply: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    Text(verbatim: draft.configuration.name)
                    Text(verbatim: draft.configuration.id).foregroundStyle(.secondary)
                    ForEach(draft.configuration.hosts, id: \.self) { Text(verbatim: $0) }
                }
                Section("Capabilities available on iOS") {
                    ForEach(draft.configuration.effectiveCapabilities(on: .iOS).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) {
                        Text(verbatim: $0.rawValue)
                    }
                }
                if !draft.configuration.capabilities.subtracting(draft.configuration.effectiveCapabilities(on: .iOS)).isEmpty {
                    Section("Declared capabilities unavailable on iOS") {
                        ForEach(draft.configuration.capabilities.subtracting(draft.configuration.effectiveCapabilities(on: .iOS))
                            .sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) {
                            Text($0.displayTitle)
                        }
                    }
                }
                if draft.configuration.danmaku != nil {
                    Section("Danmaku") {
                        Text("iOS can attach declared exact-episode Bilibili XML danmaku. Generic configured-source attachment is not supported on desktop.")
                    }
                }
                Section("Configuration fingerprint") {
                    Text(verbatim: draft.configuration.configurationRevision).font(.caption.monospaced()).textSelection(.enabled)
                    if let currentRevision {
                        Text(LocalizedStringKey(currentRevision == draft.configuration.configurationRevision ?
                            "The configuration rules are unchanged." : "The configuration rules changed. Saved selections must be confirmed again."))
                    }
                }
                Section {
                    Text(LocalizedStringKey(replaces ? "This replaces the configuration with the same source ID." : "This adds a new source to your list."))
                    Text("The source remains disabled until you enable it. Import only downloads the configuration; it does not search or play media.")
                    Button(LocalizedStringKey(replaces ? "Replace configuration" : "Add source")) {
                        do { try apply(); dismiss() } catch { failed = true }
                    }.frame(minHeight: 48).accessibilityIdentifier("source-import-apply")
                }
            }
            .navigationTitle("Review source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("source-import-preview-cancel")
                }
            }
            .alert("Unable to save source", isPresented: $failed) { Button("OK", role: .cancel) {} }
            message: { Text("The configuration could not be saved. Existing sources were preserved.") }
        }
    }
}

private struct SourceContent: View {
    let configuration: SourceConfiguration
    private let continuation: MobileSourceContinuation
    @Environment(MobilePlaybackHistory.self) private var history
    @AppStorage private var enabled: Bool
    private let candidate: MobileSourceCandidate?
    private let automatically: Bool
    @State private var query: String
    @State private var address = ""
    @State private var flow: MobileSourceFlow
    @Binding private var session: PlaybackSession?
    @ScaledMetric(relativeTo: .body) private var cellWidth = 64

    init(configuration: SourceConfiguration, anime: Anime, episode: CatalogEpisode,
         library: MobileLibrary, sources: MobileSourceLibrary, candidate: MobileSourceCandidate?,
         automatically: Bool, session: Binding<PlaybackSession?>) {
        self.configuration = configuration
        self.candidate = candidate
        self.automatically = automatically
        _session = session
        continuation = MobileSourceContinuation(client: .make(configuration: configuration),
            authority: { try sources.configurationRevision(for: configuration.id) })
        capabilities = configuration.effectiveCapabilities(on: .iOS)
        let enabledKey = "mobile.sources." + configuration.id + ".enabled"
        _enabled = AppStorage(wrappedValue: false, enabledKey)
        _query = State(initialValue: anime.title)
        _flow = State(initialValue: MobileSourceFlow(client: .make(configuration: configuration),
            requestedWork: .bangumi(anime.id),
            requestedEpisode: .bangumi(episode.id, type: episode.type, sort: episode.sort),
            enabled: UserDefaults.standard.bool(forKey: enabledKey), library: library,
            authority: { try sources.configurationRevision(for: configuration.id) }))
    }

    private let capabilities: Set<SourceCapability>

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Enable source", isOn: $enabled).accessibilityIdentifier("source-enabled")
            Text("Search sends the title to this third-party source. Confirm the season and episode; Bangumi does not provide video.")
                .font(.footnote).foregroundStyle(.secondary)
            if let mapping = flow.savedMapping {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Saved source selection").font(.headline)
                    Text(verbatim: mapping.sourceTitle)
                    Text("Playback checks this exact episode, line and quality online again. No saved video URL is reused.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if flow.requiresReconfirmation {
                        Text("This saved selection is no longer valid. Choose the source again to confirm the work and episode.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Play saved source") { flow.playSaved() }
                        .frame(minHeight: 48).buttonStyle(.borderedProminent)
                        .disabled(!enabled || !flow.canPlaySaved).accessibilityIdentifier("source-play-saved")
                    Button("Choose source again") { flow.chooseSourceAgain() }
                        .frame(minHeight: 48).buttonStyle(.bordered).accessibilityIdentifier("source-reconfirm")
                }.accessibilityElement(children: .contain).accessibilityIdentifier("source-saved-mapping")
            } else if enabled {
                if !capabilities.isSuperset(of: [.resolve, .mpv]) {
                    Text(PlaybackFailure.unsupportedResponse.mobileMessage).foregroundStyle(.secondary)
                }
                if let catalog = flow.catalog {
                    Button("Back to results") { flow.back() }.frame(minHeight: 48)
                    Text(catalog.work.title).font(.headline)
                    Text("Confirm the source episode. Numbering can differ; missing episodes are never replaced automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(catalog.lines) { line in
                        Text(line.title).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cellWidth), spacing: 8)], spacing: 8) {
                            ForEach(line.episodes) { sourceEpisode in
                                EpisodeNumberButton(number: String(sourceEpisode.number), title: sourceEpisode.title,
                                                    disabled: flow.busy || !capabilities.isSuperset(of: [.resolve, .mpv]) ||
                                                        (catalog.lines.count > 1 && !capabilities.contains(.lines))) { flow.play(sourceEpisode) }
                                    .accessibilityIdentifier("source-episode-\(line.id)-\(sourceEpisode.number)")
                            }
                        }
                    }
                } else {
                    if capabilities.contains(.search) {
                        TextField("Search source titles", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder).submitLabel(.search)
                            .onSubmit { flow.search(query) }.accessibilityIdentifier("source-query")
                        Button("Find sources") { flow.search(query) }
                            .frame(minHeight: 48).buttonStyle(.borderedProminent)
                            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        ForEach(flow.results) { work in
                            Button { flow.open(work) } label: {
                                HStack { Text(work.title).multilineTextAlignment(.leading); Spacer(); Image(systemName: "chevron.right") }
                                    .frame(maxWidth: .infinity, minHeight: 56)
                            }.buttonStyle(.bordered).disabled(flow.busy).accessibilityIdentifier("source-work")
                        }
                        if flow.nextPage != nil { Button("Load more") { flow.loadMore() }.frame(minHeight: 48).disabled(flow.busy) }
                    }
                    DisclosureGroup("Open source page") {
                        TextField("Source page URL", text: $address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button("Open source page") { flow.openPage(address) }.frame(minHeight: 48)
                            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || flow.busy)
                    }
                }
            }
            if flow.busy {
                ProgressView("Loading source…")
                Button("Cancel request") { flow.cancel() }.frame(minHeight: 48)
            }
            if let failure = flow.failure {
                Text(failure.mobileMessage)
                    .foregroundStyle(.secondary).accessibilityIdentifier("source-error")
                if flow.canRetry { Button("Retry") { flow.retry() }.frame(minHeight: 48).buttonStyle(.bordered) }
            }
            if let storageFailure = flow.storageFailure {
                Text(storageFailure.mobileMessage)
                    .foregroundStyle(.secondary).accessibilityIdentifier("source-mapping-storage-error")
            }
        }
        .task {
            flow.updateAccess(enabled: enabled, configurationRevision: configuration.configurationRevision)
            if let candidate { flow.acceptCandidate(candidate, automatically: automatically) }
        }
        .onChange(of: enabled) { _, value in
            flow.updateAccess(enabled: value, configurationRevision: configuration.configurationRevision)
        }
        .onChange(of: flow.resolved?.id) { _, _ in
            guard let result = flow.takeResolved() else { return }
            #if DEBUG
            let url = SourceFixtures.playerURL(result.url)
            #else
            let url = result.url
            #endif
            session = PlaybackSession(url: url, title: result.title, context: result.context,
                                      history: history, configuration: configuration, continuation: continuation)
        }
        .onDisappear { flow.cancel() }
    }
}


private struct EpisodeNumberButton: View {
    let number: String
    let title: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(number).font(.headline.monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle)
        .disabled(disabled)
        .accessibilityValue(Text(title))
    }
}
