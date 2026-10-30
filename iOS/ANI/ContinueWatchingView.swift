import SwiftUI
import UniformTypeIdentifiers

struct HistoryStorageNotice: View {
    @Environment(MobilePlaybackHistory.self) private var history
    var body: some View {
        if history.storageError || !history.isReadable {
            VStack(alignment: .leading, spacing: 8) {
                Text("Playback history unavailable").font(.headline)
                Text("Playback history could not be read or saved. Existing data has been preserved.")
                    .font(.footnote)
                Button("Retry") { history.retryLoad() }
                    .buttonStyle(.bordered).frame(minHeight: 44)
            }.accessibilityIdentifier("history-storage-error")
        }
    }
}

struct ContinueWatchingView: View {
    @Environment(MobilePlaybackHistory.self) private var history
    @State private var selected: MobilePlaybackHistoryEntry?
    @State private var removing: MobilePlaybackHistoryEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HistoryStorageNotice()
            if !history.continuing.isEmpty {
                Text("Continue watching").font(.title2.bold())
                ForEach(history.continuing) { entry in
                    HStack(spacing: 12) {
                        Button { selected = entry } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: entry.title).font(.headline).lineLimit(2)
                                Text(verbatim: time(entry.position)).font(.subheadline.monospacedDigit())
                                if entry.completed {
                                    Text("Finished episode · Replay").font(.caption)
                                }
                            }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("history-resume-" + entry.id)
                        Button { removing = entry } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                        }.accessibilityLabel("Remove playback history")
                            .accessibilityIdentifier("history-remove-" + entry.id)
                    }.padding(16)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .sheet(item: $selected) { entry in ResumeHistoryView(entry: entry) }
        .confirmationDialog("Remove playback history?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove playback history", role: .destructive) {
                if let removing { history.remove(removing) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("This does not remove favorites, source selections or video files.") }
    }

    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ResumeHistoryView: View {
    let entry: MobilePlaybackHistoryEntry
    @Environment(MobilePlaybackHistory.self) private var history
    @Environment(\.dismiss) private var dismiss
    @State private var sources = MobileSourceLibrary.forApp()
    @State private var flow: MobileSourceFlow?
    @State private var configuration: SourceConfiguration?
    @State private var session: PlaybackSession?
    @State private var failure: String?
    @State private var needsFile = false
    @State private var importing = false
    @State private var busy = false
    @State private var request: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(verbatim: entry.title).font(.title2.bold())
                    HistoryStorageNotice()
                    if entry.context != nil {
                        Text("Playback checks this exact episode, line and quality online again. No saved video URL is reused.")
                            .foregroundStyle(.secondary)
                    }
                    if busy || flow?.busy == true {
                        ProgressView("Preparing resume…")
                        Button("Cancel request") { cancel() }.frame(minHeight: 48)
                    }
                    if let message = failure ?? flow?.failure?.mobileMessage {
                        Text(message).foregroundStyle(.secondary).accessibilityIdentifier("history-resume-error")
                    }
                    if needsFile {
                        Text("Choose the original video again. Its contents must match; the filename alone is not enough.")
                        Button("Choose video again") { importing = true }
                            .buttonStyle(.borderedProminent).frame(minHeight: 48)
                            .accessibilityIdentifier("history-reauthorize")
                    }
                    if !busy && flow?.busy != true {
                        Button("Resume playback") { resume() }.frame(minHeight: 48).buttonStyle(.bordered)
                            .disabled(!history.isReadable)
                            .accessibilityIdentifier("history-resume-start")
                    }
                }.padding(24)
            }
            .navigationTitle("Continue watching").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { cancel(); dismiss() } } }
        }
        .task { resume() }
        .onChange(of: flow?.resolved?.id) { _, _ in handoff() }
        .onDisappear { cancel() }
        .playbackPresentation(session: $session)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .data]) { result in
            switch result {
            case .success(let url): resumeLocal(reselected: url)
            case .failure: break // Cancellation never changes the saved entry.
            }
        }
    }

    private func cancel() {
        generation = UUID()
        request?.cancel(); request = nil
        flow?.cancel()
        busy = false
    }

    private func isCurrent() -> Bool {
        history.isReadable && history.entries.contains { $0.id == entry.id && $0.updatedAt == entry.updatedAt }
    }

    private func resume() {
        cancel(); failure = nil
        guard isCurrent() else {
            failure = String(localized: "This playback history changed. Return to the list and choose it again.")
            return
        }
        if entry.localReference != nil { resumeLocal(); return }
        guard let context = entry.context else { return }
        do {
            let revision = try sources.configurationRevision(for: context.selection.item.sourceID)
            guard revision == context.configurationRevision,
                  let config = sources.sources.first(where: { $0.id == context.selection.item.sourceID })?.configuration else {
                throw PlaybackFailure.configurationChanged
            }
            configuration = config
            let sourceID = config.id
            let next = MobileSourceFlow(client: .make(configuration: config),
                requestedWork: context.work, requestedEpisode: context.episode,
                authority: { try sources.configurationRevision(for: sourceID) },
                resumeMapping: ConfirmedSourceMapping(context: context, sourceTitle: entry.title))
            flow = next
            next.playSaved()
        } catch { failure = MobileSourceClient.failure(for: error).mobileMessage }
    }

    private func handoff() {
        guard isCurrent() else {
            cancel()
            failure = String(localized: "This playback history changed. Return to the list and choose it again.")
            return
        }
        guard let result = flow?.takeResolved(), let configuration else { return }
        #if DEBUG
        let url = SourceFixtures.playerURL(result.url)
        #else
        let url = result.url
        #endif
        session = PlaybackSession(url: url, title: entry.title, context: result.context,
                                  history: history, historyEntry: entry, configuration: configuration,
                                  continuation: MobileSourceContinuation(client: .make(configuration: configuration),
                                    authority: { try sources.configurationRevision(for: configuration.id) }))
    }

    private func resumeLocal(reselected url: URL? = nil) {
        cancel(); failure = nil
        guard isCurrent() else {
            failure = String(localized: "This playback history changed. Return to the list and choose it again.")
            return
        }
        busy = true
        let expected = generation
        request = Task { @MainActor in
            do {
                let next: PlaybackSession
                if let url { next = try await PlaybackSession.reauthorizeLocal(entry, url: url, history: history) }
                else { next = try await PlaybackSession.resumeLocal(entry, history: history) }
                guard !Task.isCancelled, expected == generation else { next.stop(); return }
                session = next; busy = false; needsFile = false; request = nil
            } catch {
                guard !Task.isCancelled, expected == generation else { return }
                busy = false; needsFile = true; request = nil
                failure = String(localized: "The original video is unavailable or the selected file does not match. Your playback history was kept.")
            }
        }
    }
}
