import SwiftUI
import UIKit

struct DiscoverView: View {
    @State private var search = ""
    @State private var query = ""
    @State private var items: [Anime] = []
    @State private var loading = false
    @State private var failed = false
    @State private var total = 0
    @State private var offset = 0
    @State private var revision = 0
    @State private var requestID = UUID()
    private let client = CatalogClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if query.isEmpty {
                    ContinueWatchingView()
                }
                if failed {
                    ContentUnavailableView {
                        Label("Unable to load", systemImage: "wifi.exclamationmark")
                    } description: { Text("Check your connection and try again.") }
                    actions: { Button("Retry") { revision += 1 }.frame(minHeight: 56).buttonStyle(.bordered) }
                } else if !loading && items.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                if !items.isEmpty && query.isEmpty {
                    Label("On air this week", systemImage: "tv")
                        .font(.headline)
                }
                AnimeGrid(items: items)
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                if !loading && !failed && !query.isEmpty && offset < total {
                    Button("Load more") { revision += 1 }.frame(maxWidth: .infinity, minHeight: 56).buttonStyle(.bordered)
                }
            }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { MobileSourceSettingsView() } label: {
                    Label("Source settings", systemImage: "slider.horizontal.3")
                }.accessibilityIdentifier("source-settings")
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search anime")
        .onSubmit(of: .search) { query = search.trimmingCharacters(in: .whitespacesAndNewlines); offset = 0; items = []; revision += 1 }
        .onChange(of: search) { _, value in
            if value.isEmpty && !query.isEmpty { query = ""; offset = 0; items = []; revision += 1 }
        }
        .task(id: revision) { await load() }
        .refreshable { await load(reset: true) }
    }

    @MainActor private func load(reset: Bool = false) async {
        let id = UUID()
        requestID = id
        let requestedRevision = revision
        let requestedQuery = query
        if reset { offset = 0 }
        let requestedOffset = offset
        loading = true; failed = false
        defer { if requestID == id && revision == requestedRevision { loading = false } }
        do {
            let result: [Anime]
            let count: Int
            if requestedQuery.isEmpty { result = try await client.calendar(); count = result.count }
            else { let page = try await client.search(requestedQuery, offset: requestedOffset); result = page.data; count = page.total }
            try Task.checkCancellation()
            guard requestID == id, revision == requestedRevision else { return }
            var updated = requestedOffset == 0 ? [] : items
            var seen = Set(updated.map(\.id))
            updated += result.filter { seen.insert($0.id).inserted }
            items = updated
            offset = requestedOffset + result.count
            total = result.isEmpty ? offset : count
        } catch {
            guard !Task.isCancelled, requestID == id, revision == requestedRevision else { return }
            failed = true
        }
    }

}

struct AnimeGrid: View {
    let items: [Anime]
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 185 : 145), spacing: 12)], spacing: 16) {
            ForEach(items) { anime in
                NavigationLink { AnimeDetailView(anime: anime) } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        CoverView(anime: anime).aspectRatio(0.70, contentMode: .fit)
                        Text(anime.title).font(.headline).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(8).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    .foregroundStyle(.primary).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

struct CoverView: View {
    let anime: Anime
    @State private var image: UIImage?
    @State private var loadedURL: URL?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.indigo.opacity(0.12)
                if loadedURL == anime.cover, let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.indigo)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped().clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .task(id: anime.cover) {
            let url = anime.cover
            image = nil
            loadedURL = url
            guard let url, let data = await MobileCoverCache.shared.data(for: url),
                  !Task.isCancelled, anime.cover == url else { return }
            image = UIImage(data: data)
        }
        .onDisappear { image = nil; loadedURL = nil }
        .accessibilityHidden(true)
    }
}

struct FavoritesView: View {
    @Environment(MobileLibrary.self) private var library
    @State private var search = ""
    @State private var sort = FavoriteSort.recent
    @State private var filter = CollectionStatusFilter.all
    private var items: [Anime] { library.matching(search, sort: sort, filter: filter) }
    var body: some View {
        VStack(spacing: 16) {
            if !library.isReadable || library.storageError {
                LibraryRecoveryNotice().padding(.horizontal)
            }
            if library.isReadable {
                if library.favorites.isEmpty {
                    ContentUnavailableView("Your next watch starts here", systemImage: "heart",
                        description: Text("Save an anime from Discover to keep it here, even offline."))
                } else if items.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ScrollView { AnimeGrid(items: items).padding() }
                }
            } else {
                Spacer()
            }
        }.navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink {
                        MobileBangumiAccountView()
                    } label: { Label("Bangumi account & sync", systemImage: "person.crop.circle") }
                    .accessibilityIdentifier("library-account")
                    NavigationLink {
                        MobileLinksView()
                    } label: { Label("Link favorites", systemImage: "link") }
                    .accessibilityIdentifier("library-links")
                } label: { Label("Library tools", systemImage: "ellipsis.circle") }
                .accessibilityIdentifier("library-tools")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    filterButton("All statuses", value: .all, id: "all")
                    filterButton("Unclassified", value: .unclassified, id: "unclassified")
                    ForEach(BangumiCollectionStatus.displayOrder, id: \.self) { status in
                        filterButton(status.title, value: .status(status), id: String(status.rawValue))
                    }
                } label: { Label(LocalizedStringKey(filterTitle), systemImage: "line.3.horizontal.decrease.circle") }
                .accessibilityLabel("Filter library")
                .accessibilityValue(Text(LocalizedStringKey(filterTitle)))
                .accessibilityIdentifier("library-filter")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort library", selection: $sort) {
                        Text("Recently saved").tag(FavoriteSort.recent)
                        Text("Title").tag(FavoriteSort.title)
                        Text("Highest rated").tag(FavoriteSort.rating)
                    }
                } label: { Label("Sort library", systemImage: "arrow.up.arrow.down") }
                .accessibilityIdentifier("library-sort")
            }
        }
    }

    private var filterTitle: String {
        switch filter {
        case .all: "All statuses"
        case .unclassified: "Unclassified"
        case .status(let status): status.title
        }
    }

    private func filterButton(_ title: String, value: CollectionStatusFilter, id: String) -> some View {
        Button { filter = value } label: {
            if filter == value { Label(LocalizedStringKey(title), systemImage: "checkmark") }
            else { Text(LocalizedStringKey(title)) }
        }.accessibilityIdentifier("library-filter-" + id)
    }
}

struct AnimeDetailView: View {
    let anime: Anime
    @Environment(MobileLibrary.self) private var library
    @Environment(MobileBangumiAccount.self) private var account
    @State private var detail: Anime?
    @State private var revision = 0
    @State private var loading = false
    @State private var failed = false
    @State private var fetchedAt: Date?
    @State private var showingCached = false
    @State private var requestID = UUID()
    private var item: Anime { detail.flatMap { $0.id == anime.id ? $0 : nil } ?? anime }
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700 && !typeSize.isAccessibilitySize
            ScrollView {
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(spacing: 24))
                layout {
                    VStack(spacing: 18) {
                        CoverView(anime: item)
                            .frame(width: wide ? 240 : 180, height: wide ? 340 : 255)
                        saveButton
                        statusMenu
                    }.frame(width: wide ? 260 : nil)
                    information.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(wide ? 32 : 24)
                .frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("About this anime").navigationBarTitleDisplayMode(.inline)
        .task(id: "\(anime.id)#\(revision)") { await load() }
        .onDisappear { requestID = UUID() }
    }

    @MainActor private func load() async {
        let id = UUID()
        let subjectID = anime.id
        let requestedRevision = revision
        requestID = id
        if detail?.id != subjectID {
            let cached = library.cachedDetail(for: subjectID)
            detail = cached?.anime
            fetchedAt = cached?.fetchedAt
            showingCached = cached != nil
        }
        loading = true
        failed = false
        defer { if requestID == id { loading = false } }
        do {
            let result = try await CatalogClient().detail(subjectID)
            try Task.checkCancellation()
            guard result.id == subjectID else { throw URLError(.badServerResponse) }
            guard requestID == id, anime.id == subjectID, revision == requestedRevision else { return }
            let date = Date.now
            detail = result
            fetchedAt = date
            showingCached = false
            library.cacheDetail(result, fetchedAt: date)
        } catch {
            guard !Task.isCancelled, requestID == id, anime.id == subjectID,
                  revision == requestedRevision else { return }
            failed = true
        }
    }

    private var saveButton: some View {
        Button { library.toggle(item) } label: {
            Label(LocalizedStringKey(library.contains(item) ? "Saved to library" : "Save to library"), systemImage: library.contains(item) ? "heart.fill" : "heart")
                .font(.headline).frame(maxWidth: .infinity, minHeight: 56)
        }.buttonStyle(.borderedProminent)
        .disabled(!library.isReadable)
        .accessibilityIdentifier("favorite-toggle")
        .accessibilityValue(Text(LocalizedStringKey(library.contains(item) ? "Saved to library" : "Save to library")))
    }

    private var statusMenu: some View {
        VStack(spacing: 8) {
            Menu {
                statusButton(nil)
                ForEach(BangumiCollectionStatus.displayOrder, id: \.self) { status in
                    statusButton(status)
                }
            } label: {
                VStack(spacing: 6) {
                    Text("Watching status").font(.subheadline)
                    Text(LocalizedStringKey(library.status(for: item.id)?.title ?? "Unclassified"))
                        .font(.headline).accessibilityIdentifier("collection-status-value")
                }.frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.bordered)
            .disabled(!library.isReadable)
            .accessibilityIdentifier("collection-status-menu")
            .accessibilityValue(Text(LocalizedStringKey(library.status(for: item.id)?.title ?? "Unclassified")))
            Text("Watching status is independent of favorites.")
                .font(.caption).foregroundStyle(.secondary)
            if library.hasPendingCollectionChange(for: item.id) {
                Text("Collection change pending sync").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("collection-sync-pending")
            }
        }
    }

    private func statusButton(_ status: BangumiCollectionStatus?) -> some View {
        Button {
            library.setStatus(status, for: item)
            Task { await account.retrySync() }
        } label: {
            if library.status(for: item.id) == status {
                Label(LocalizedStringKey(status?.title ?? "Unclassified"), systemImage: "checkmark")
            } else {
                Text(LocalizedStringKey(status?.title ?? "Unclassified"))
            }
        }.accessibilityIdentifier("collection-status-" + (status.map { String($0.rawValue) } ?? "unclassified"))
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !library.isReadable || library.storageError { LibraryRecoveryNotice() }
            if library.cacheError {
                Text("Some saved information could not be read or saved. Your favorites and watching statuses are unchanged.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("library-cache-error")
            }
            Text(item.title).font(.largeTitle.bold())
            if item.title != item.name { Text(item.name).foregroundStyle(.secondary) }
            HStack {
                if let date = item.date { Text(date) }
                if let score = item.rating?.score {
                    Label(score.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                }
            }.font(.subheadline).foregroundStyle(.secondary)
            if let summary = item.summary, !summary.isEmpty { Text(summary).textSelection(.enabled).lineSpacing(6) }
            if let fetchedAt {
                CatalogCacheNotice(fetchedAt: fetchedAt, cached: showingCached, stale: failed)
                    .accessibilityIdentifier("detail-cache-notice")
            }
            if loading { ProgressView() }
            if failed {
                Text("Details could not be refreshed. Existing information is still shown.").foregroundStyle(.secondary)
            }
            if failed || library.cacheError {
                Button("Retry") { revision += 1 }
                    .frame(minHeight: 56).buttonStyle(.bordered)
                    .accessibilityIdentifier("detail-retry")
            }
            Link(destination: URL(string: "https://bgm.tv/subject/\(item.id)")!) {
                Label("View on Bangumi", systemImage: "arrow.up.right.square")
                    .frame(minHeight: 56)
            }.buttonStyle(.bordered)
            EpisodeBrowser(anime: item).id(item.id)
            CatalogDetailsLinks(subjectID: item.id).id("extras-\(item.id)")
        }
    }
}

/// Remains visible after dismissing the alert, so an unreadable library never looks empty.
struct LibraryRecoveryNotice: View {
    @Environment(MobileLibrary.self) private var library
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Library unavailable", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(LocalizedStringKey(library.isReadable
                ? "Your change could not be saved. The previous library state is still shown."
                : "Your library could not be loaded. Existing data has been preserved. Retry before making changes."))
                .font(.subheadline)
            Button("Retry") { library.retryLoad() }
                .frame(minHeight: 48).buttonStyle(.bordered)
                .accessibilityIdentifier("library-retry")
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding()
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-storage-error")
    }
}

struct CatalogCacheNotice: View {
    let fetchedAt: Date
    let cached: Bool
    let stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(LocalizedStringKey(stale ? "Update failed. Showing saved information."
                : cached ? "Showing saved information while refreshing." : "Last updated"),
                systemImage: stale ? "clock.badge.exclamationmark" : "clock")
            Text(fetchedAt, format: .dateTime.year().month().day().hour().minute())
        }.font(.footnote).foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
