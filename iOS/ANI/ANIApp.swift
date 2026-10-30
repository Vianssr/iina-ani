import SwiftUI

@main
struct ANIApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var library: MobileLibrary
    @State private var account: MobileBangumiAccount
    @State private var history = MobilePlaybackHistory()
    @State private var links = MobileLinkLibrary()
    @State private var sources = MobileSourceLibrary.forApp()

    init() {
        let library = MobileLibrary()
        _library = State(initialValue: library)
        _account = State(initialValue: MobileBangumiAccount(library: library))
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    TabletWorkspace()
                } else {
                    TabView {
                        NavigationStack { DiscoverView() }
                            .tabItem { Label("Discover", systemImage: "sparkles") }
                        NavigationStack { TrendingView() }
                            .tabItem { Label("Trending", systemImage: "chart.line.uptrend.xyaxis") }
                        NavigationStack { CalendarView() }
                            .tabItem { Label("Calendar", systemImage: "calendar") }
                        NavigationStack { FavoritesView() }
                            .tabItem { Label("Library", systemImage: "heart.fill") }
                        NavigationStack { OpenMediaView() }
                            .tabItem { Label("Play", systemImage: "play.circle.fill") }
                    }
                }
            }
            .tint(.indigo)
            .environment(library)
            .environment(history)
            .environment(links)
            .environment(account)
            .environment(sources)
            .task { await account.retrySync() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await account.retrySync() } }
            }
            .alert("Library unavailable", isPresented: $library.storageError) {
                Button("Retry") { library.retryLoad() }
                    .accessibilityIdentifier("library-alert-retry")
                Button("OK", role: .cancel) {}
            } message: {
                Text(LocalizedStringKey(library.isReadable
                    ? "Your change could not be saved. The previous library state is still shown."
                    : "Your library could not be loaded. Existing data has been preserved. Retry before making changes."))
            }
        }
    }
}

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case discover, trending, calendar, library, play
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .discover: "Discover"
        case .trending: "Trending"
        case .calendar: "Calendar"
        case .library: "Library"
        case .play: "Play"
        }
    }
    var symbol: String {
        switch self {
        case .discover: "square.grid.2x2"
        case .trending: "chart.line.uptrend.xyaxis"
        case .calendar: "calendar"
        case .library: "heart"
        case .play: "play.rectangle"
        }
    }
}

/// Keep the split view on iPad even in a narrow window, so the system can collapse its columns.
private struct TabletWorkspace: View {
    @State private var selection: WorkspaceSection? = .discover
    @State private var visibility: NavigationSplitViewVisibility = .all
    @Environment(MobileLibrary.self) private var library

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: $selection) {
                Section {
                    ForEach(WorkspaceSection.allCases) { section in
                        NavigationLink(value: section) {
                            HStack(spacing: 16) {
                                Image(systemName: section.symbol).font(.title3).frame(width: 28)
                                Text(section.title).font(.headline)
                                Spacer(minLength: 0)
                                if section == .library {
                                    if library.isReadable {
                                        Text(library.favorites.count, format: .number)
                                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: "exclamationmark.triangle")
                                            .accessibilityLabel("Library unavailable")
                                    }
                                }
                            }
                            .frame(minHeight: 56).contentShape(Rectangle())
                        }.accessibilityIdentifier("workspace-" + section.rawValue)
                    }
                } header: { Text("Workspace") }
            }
            .listStyle(.sidebar)
            .navigationTitle("IINA-ANI")
            .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 300)
        } detail: {
            NavigationStack {
                Group {
                    switch selection ?? .discover {
                    case .discover: DiscoverView()
                    case .trending: TrendingView()
                    case .calendar: CalendarView()
                    case .library: FavoritesView()
                    case .play: OpenMediaView()
                    }
                }
            }.id(selection)
        }
        .navigationSplitViewStyle(.balanced)
        .controlSize(.large)
    }
}
