import SwiftUI
import UniformTypeIdentifiers

struct OpenMediaView: View {
    @Environment(MobilePlaybackHistory.self) private var history
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var importing = false
    @State private var invalid = false
    @State private var session: PlaybackSession?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let wide = geometry.size.width >= 740 && !typeSize.isAccessibilitySize
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
                    layout {
                        linkCard
                        fileCard
                    }
                    btCard
                    ContinueWatchingView()
                }
                .padding(16).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Play")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { MobileSourceSettingsView() } label: {
                    Label("Source settings", systemImage: "slider.horizontal.3")
                }.accessibilityIdentifier("play-source-settings")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                if !urls.isEmpty { session = PlaybackSession(urls: urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }, securityScoped: true, history: history) }
            case .failure: invalid = true
            }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-player-ui-fixture"), session == nil,
               let first = Bundle.main.url(forResource: "player-fixture-01", withExtension: "mp4"),
               let second = Bundle.main.url(forResource: "player-fixture-02", withExtension: "mp4") {
                session = PlaybackSession(urls: [first, second], history: history)
            }
            #endif
        }
        .playbackPresentation(session: $session)
        .alert("Unable to open media", isPresented: $invalid) { Button("OK", role: .cancel) {} }
        message: { Text("Use a valid HTTPS media link without embedded credentials, or select an accessible video file.") }
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Media link", systemImage: "link").font(.headline)
            TextField("https://…", text: $address)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).frame(minHeight: 44)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                .focused($addressFocused)
                .accessibilityIdentifier("mediaAddress").onSubmit { play() }
            Text("HTTPS video or HLS link")
                .font(.caption).foregroundStyle(.secondary)
            Button(action: play) {
                Label("Play video", systemImage: "play.fill")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var fileCard: some View {
        Button { addressFocused = false; importing = true } label: {
            HStack(spacing: 12) {
                Label("Choose from Files", systemImage: "folder")
                    .font(.headline)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
    }

    private var btCard: some View {
        NavigationLink { MobileBTPlaybackView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2).foregroundStyle(.indigo)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("BT playback").font(.headline)
                    Text("Requires an HTTPS TorrServer without login.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(16)
                .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityIdentifier("bt-playback-entry")
    }

    private func play() {
        addressFocused = false
        guard let url = MediaAddress.parse(address) else { invalid = true; return }
        session = PlaybackSession(url: url, history: history)
        // Signed links stay in memory only and are never written to history or logs.
        address = ""
    }
}
