import SwiftUI

struct MobileBTPlaybackView: View {
    @State private var serverAddress = ""
    @State private var torrentAddress = ""
    @State private var request: Request?
    @State private var loaded: Loaded?
    @State private var busy = false
    @State private var failure: MobileBTError?
    @State private var session: PlaybackSession?
    @FocusState private var focused: Field?

    private enum Field { case server, torrent }
    private struct Request: Equatable { let id = UUID(); let server: URL; let input: String }
    private struct Loaded { let server: URL; let torrent: MobileBTTorrent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                connectionCard
                if busy {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Waiting for torrent files…").font(.subheadline)
                        Spacer()
                        Button("Cancel") { cancel() }.frame(minHeight: 44)
                            .accessibilityIdentifier("bt-cancel")
                    }.padding()
                }
                if let failure {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Unable to load torrent", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(LocalizedStringKey(failure.message)).font(.subheadline).foregroundStyle(.secondary)
                        Button("Retry") { submit() }.buttonStyle(.bordered).frame(minHeight: 44)
                            .accessibilityIdentifier("bt-retry")
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityIdentifier("bt-error")
                }
                if let loaded { filesCard(loaded) }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("TorrServer handles torrent downloads and uploads. This app plays its video stream; it does not run a torrent engine on your device.")
                        Text("Use a trusted HTTPS endpoint accessible without a login. Server and torrent addresses are kept only for this screen. Closing this screen does not remove transfers from your server.")
                    }.font(.footnote).foregroundStyle(.secondary).padding(.bottom, 8)
                } label: {
                    Label("About BT playback", systemImage: "info.circle")
                        .font(.subheadline).frame(minHeight: 44)
                }
            }
            .padding(16).frame(maxWidth: 800).frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("BT playback")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: request) {
            guard let request else { return }
            await load(request)
        }
        .onChange(of: serverAddress) { _, _ in invalidate() }
        .onChange(of: torrentAddress) { _, _ in invalidate() }
        .onDisappear { cancel() }
        .playbackPresentation(session: $session)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Requires an HTTPS TorrServer without login.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Server URL").font(.subheadline.bold())
                TextField("https://server.example", text: $serverAddress)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textContentType(.URL).focused($focused, equals: .server)
                    .padding(12).frame(minHeight: 44)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("bt-server-url")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Magnet or torrent URL").font(.subheadline.bold())
                TextField("magnet:?xt=…", text: $torrentAddress, axis: .vertical)
                    .lineLimit(1...4).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused, equals: .torrent)
                    .padding(12).frame(minHeight: 44)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("bt-torrent-url")
            }
            Button(action: submit) {
                Label("Load torrent files", systemImage: "tray.and.arrow.down")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent)
                .disabled(busy || serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || torrentAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("bt-load")
        }.padding(16).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func filesCard(_ loaded: Loaded) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Label("Choose a video", systemImage: "film.stack").font(.headline)
            if let title = loaded.torrent.title ?? loaded.torrent.name, !title.isEmpty {
                Text(verbatim: title).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(loaded.torrent.videoFiles) { file in
                Button { play(file, loaded: loaded) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: file.title).font(.headline).foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            if let length = file.length {
                                Text(verbatim: ByteCountFormatter.string(fromByteCount: length, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 44).padding(12)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityIdentifier("bt-file-\(file.id)")
            }
        }.padding(16).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func invalidate() {
        cancel()
        loaded = nil
        failure = nil
    }

    private func cancel() {
        request = nil
        busy = false
    }

    private func submit() {
        focused = nil
        loaded = nil
        failure = nil
        guard let server = MobileBTAddress.server(serverAddress) else { failure = .invalidServer; return }
        guard let input = MobileBTAddress.torrent(torrentAddress) else { failure = .invalidTorrent; return }
        busy = true
        request = Request(server: server, input: input)
    }

    @MainActor private func load(_ target: Request) async {
        defer { if request?.id == target.id { busy = false } }
        do {
            let torrent: MobileBTTorrent
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-bt-ui-fixture") {
                torrent = try MobileBTTorrent.decode(Data(#"{"hash":"1111111111111111111111111111111111111111","title":"BT playback fixture","file_stats":[{"id":1,"path":"Episode 01.mp4","length":1024000},{"id":2,"path":"Episode 02.mp4","length":2048000}]}"#.utf8))
            } else {
                torrent = try await MobileBTClient().load(server: target.server, input: target.input)
            }
            #else
            torrent = try await MobileBTClient().load(server: target.server, input: target.input)
            #endif
            try Task.checkCancellation()
            guard request?.id == target.id else { return }
            loaded = Loaded(server: target.server, torrent: torrent)
        } catch {
            guard !Task.isCancelled, request?.id == target.id else { return }
            failure = error as? MobileBTError ?? .unavailable
        }
    }

    private func play(_ file: MobileBTFile, loaded: Loaded) {
        do {
            let url: URL
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-bt-ui-fixture"),
               let fixture = Bundle.main.url(forResource: "player-fixture-0\(file.id)", withExtension: "mp4") {
                url = fixture
            } else {
                url = try MobileBTClient.stream(server: loaded.server, torrent: loaded.torrent, file: file)
            }
            #else
            url = try MobileBTClient.stream(server: loaded.server, torrent: loaded.torrent, file: file)
            #endif
            session = PlaybackSession(url: url, title: file.title)
        } catch { failure = error as? MobileBTError ?? .unavailable }
    }
}
