import SwiftUI

struct TrendingView: View {
    @State private var scope: TrendingScope = .season
    @State private var items: [Anime] = []
    @State private var offset = 0
    @State private var total = 0
    @State private var loading = true
    @State private var failed = false
    @State private var revision = 0
    @State private var requestID = UUID()
    @State private var loadedScope: TrendingScope?
    @State private var completedRevision = -1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Trending period", selection: $scope) {
                    ForEach(TrendingScope.allCases) { value in
                        Text(LocalizedStringKey(value.title)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("trending-scope")

                if failed {
                    CatalogLoadFailure(hasContent: !items.isEmpty) {
                        // Retry refreshes the ranking from its first page, including after
                        // a failed pull-to-refresh that retained the previously loaded items.
                        offset = 0
                        revision += 1
                    }
                }
                if let first = items.first {
                    featured(first)
                    AnimeGrid(items: Array(items.dropFirst()))
                } else if !loading && !failed {
                    ContentUnavailableView("No trending anime yet", systemImage: "flame",
                        description: Text("Try another period or refresh later."))
                }
                if loading { ProgressView("Loading anime…").frame(maxWidth: .infinity).padding() }
                if !loading && !failed && offset < total {
                    Button { revision += 1 } label: {
                        Label("Load more", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.bordered).accessibilityIdentifier("trending-load-more")
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Trending")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scope) { _, _ in
            requestID = UUID()
            items = []; offset = 0; total = 0; failed = false; loading = true
        }
        .task(id: "\(scope.rawValue)#\(revision)") {
            // Returning from a detail keeps the ranking and scroll position intact.
            guard loadedScope != scope || completedRevision != revision || items.isEmpty else { return }
            await load(reset: false)
        }
        .refreshable { await load(reset: true) }
    }

    private func featured(_ anime: Anime) -> some View {
        NavigationLink { AnimeDetailView(anime: anime) } label: {
            HStack(alignment: .top, spacing: 12) {
                CoverView(anime: anime).frame(width: 72, height: 104)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Most collected", systemImage: "crown.fill")
                        .font(.caption.bold()).foregroundStyle(.orange)
                    Text(verbatim: anime.title).font(.title3.bold()).lineLimit(3)
                    if let score = anime.rating?.score, score > 0 {
                        Label { Text(score, format: .number.precision(.fractionLength(1))) }
                              icon: { Image(systemName: "star.fill").foregroundStyle(.orange) }
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            .foregroundStyle(.primary).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("trending-featured")
    }

    @MainActor private func load(reset: Bool) async {
        let id = UUID()
        let requestedScope = scope
        let requestedRevision = revision
        let requestedOffset = reset ? 0 : offset
        requestID = id
        loading = true; failed = false
        defer { if requestID == id { loading = false } }
        do {
            let page = try await CatalogClient().trending(scope: requestedScope, offset: requestedOffset)
            try Task.checkCancellation()
            guard requestID == id, scope == requestedScope, revision == requestedRevision else { return }
            var updated = requestedOffset == 0 ? [] : items
            var seen = Set(updated.map(\.id))
            let additions = page.data.filter { $0.id > 0 && seen.insert($0.id).inserted }
            updated += additions
            items = updated
            offset = requestedOffset + page.data.count
            // A repeated/empty page must not leave an endless Load more button.
            total = additions.isEmpty ? offset : max(offset, page.total)
            loadedScope = requestedScope
            completedRevision = requestedRevision
        } catch {
            guard !Task.isCancelled, requestID == id, scope == requestedScope,
                  revision == requestedRevision else { return }
            failed = true
        }
    }
}

struct CalendarView: View {
    @State private var selectedDay = CalendarDay.today()
    @State private var days: [CalendarDay] = []
    @State private var loading = true
    @State private var failed = false
    @State private var revision = 0
    @State private var requestID = UUID()
    private var items: [Anime] { days.first { $0.id == selectedDay }?.items ?? [] }
    private let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private let shortWeekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                weekdayPicker
                if failed { CatalogLoadFailure(hasContent: !days.isEmpty) { revision += 1 } }
                if loading { ProgressView("Loading schedule…").frame(maxWidth: .infinity).padding() }
                if !loading && !failed && items.isEmpty {
                    ContentUnavailableView("Nothing scheduled", systemImage: "calendar.badge.minus",
                        description: Text("Choose another day to see its anime."))
                }
                AnimeGrid(items: items)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Today") { selectedDay = CalendarDay.today() }
                    .accessibilityIdentifier("calendar-today")
            }
        }
        .task(id: revision) {
            if days.isEmpty || revision > 0 { await load() }
        }
        .refreshable { await load() }
    }

    private var weekdayPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(1...7, id: \.self) { day in
                        Button { selectedDay = day } label: {
                            VStack(spacing: 8) {
                                Text(LocalizedStringKey(shortWeekdays[day - 1])).font(.subheadline.bold())
                                Text(days.first { $0.id == day }?.items.count ?? 0, format: .number)
                                    .font(.caption.monospacedDigit())
                            }
                            .frame(minWidth: 48, minHeight: 56)
                            .padding(.horizontal, 4)
                            .foregroundStyle(selectedDay == day ? Color.white : Color.primary)
                            .background(selectedDay == day ? Color(red: 0, green: 0.40, blue: 0.43) : Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain).id(day)
                        .accessibilityLabel(Text(LocalizedStringKey(weekdays[day - 1])))
                        .accessibilityValue(Text(days.first { $0.id == day }?.items.count ?? 0, format: .number))
                        .accessibilityAddTraits(selectedDay == day ? .isSelected : [])
                        .accessibilityIdentifier("calendar-day-\(day)")
                    }
                }
            }
            .accessibilityIdentifier("calendar-weekdays")
            .onAppear { proxy.scrollTo(selectedDay, anchor: .center) }
            .onChange(of: selectedDay) { _, day in
                withAnimation { proxy.scrollTo(day, anchor: .center) }
            }
        }
    }

    @MainActor private func load() async {
        let id = UUID()
        requestID = id
        loading = true; failed = false
        defer { if requestID == id { loading = false } }
        do {
            let result = try await CatalogClient().calendarDays()
            try Task.checkCancellation()
            guard requestID == id else { return }
            days = result
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            failed = true
        }
    }
}

private struct CatalogLoadFailure: View {
    let hasContent: Bool
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Unable to load", systemImage: "wifi.exclamationmark").font(.headline)
            Text(LocalizedStringKey(hasContent ? "Showing the last loaded results. Try refreshing again." : "Check your connection and try again."))
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Retry", action: retry).buttonStyle(.bordered).frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
