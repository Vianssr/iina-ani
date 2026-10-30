import SwiftUI

/// Supplemental information is opt-in and never gates the episode browser or playback.
struct CatalogDetailsLinks: View {
    let subjectID: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More about this work").font(.title2.bold())
            NavigationLink { CatalogTagsView(subjectID: subjectID).id(subjectID) } label: {
                Label("Tags", systemImage: "tag")
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }.accessibilityIdentifier("detail-tags")
            NavigationLink { CatalogRelatedView(subjectID: subjectID).id(subjectID) } label: {
                Label("Related works", systemImage: "square.stack")
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }.accessibilityIdentifier("detail-related")
            NavigationLink { CatalogPeopleView(subjectID: subjectID, kind: .character).id(subjectID) } label: {
                Label("Characters", systemImage: "person.2")
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }.accessibilityIdentifier("detail-characters")
            NavigationLink { CatalogPeopleView(subjectID: subjectID, kind: .person).id(subjectID) } label: {
                Label("Staff", systemImage: "person.3")
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }.accessibilityIdentifier("detail-staff")
            NavigationLink { CatalogCommentsView(subjectID: subjectID).id(subjectID) } label: {
                Label("Comments (read-only)", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            }.accessibilityIdentifier("detail-comments")
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CatalogResourceStatus<Value: Sendable>: View {
    let resource: MobileDetailResource<Value>
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if resource.loading {
                HStack {
                    ProgressView()
                    Spacer()
                    Button("Cancel") { resource.cancel() }.frame(minHeight: 56)
                        .accessibilityIdentifier("detail-section-cancel")
                }
            } else if resource.failed {
                Text("This section could not be loaded. Playback is still available.").foregroundStyle(.secondary)
                Button("Retry", action: retry).frame(minHeight: 56).buttonStyle(.bordered)
                    .accessibilityIdentifier("detail-section-retry")
            } else if resource.cancelled {
                Text("Loading cancelled.").foregroundStyle(.secondary)
                Button("Load information", action: retry).frame(minHeight: 56).buttonStyle(.bordered)
                    .accessibilityIdentifier("detail-section-load")
            }
        }
    }
}

private struct CatalogTagsView: View {
    let subjectID: Int
    @State private var resource = MobileDetailResource<[MobileCatalogTag]>()
    var body: some View {
        List {
            CatalogResourceStatus(resource: resource, retry: load)
            if let tags = resource.value {
                if tags.isEmpty { Text("No tags available.").foregroundStyle(.secondary) }
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    HStack {
                        Text(tag.name).textSelection(.enabled)
                        Spacer()
                        Text(tag.count.formatted()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Tags")
        .accessibilityIdentifier("detail-tags-list")
        .onAppear { if resource.value == nil && !resource.loading { load() } }
        .onDisappear { resource.cancel() }
    }
    private func load() {
        let id = subjectID
        resource.load { try await MobileCatalogDetailClient().tags(id) }
    }
}

private struct CatalogRelatedView: View {
    let subjectID: Int
    @State private var resource = MobileDetailResource<[MobileRelatedWork]>()
    var body: some View {
        List {
            CatalogResourceStatus(resource: resource, retry: load)
            if let works = resource.value {
                if works.isEmpty { Text("No related works available.").foregroundStyle(.secondary) }
                ForEach(Array(works.enumerated()), id: \.offset) { _, work in
                    if work.type == 2 {
                        NavigationLink { AnimeDetailView(anime: work.anime) } label: { row(work) }
                    } else {
                        Link(destination: URL(string: "https://bgm.tv/subject/\(work.id)")!) {
                            HStack { row(work); Image(systemName: "arrow.up.right.square") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Related works")
        .accessibilityIdentifier("detail-related-list")
        .onAppear { if resource.value == nil && !resource.loading { load() } }
        .onDisappear { resource.cancel() }
    }
    private func row(_ work: MobileRelatedWork) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(work.anime.title).foregroundStyle(.primary)
            Text(work.relation).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
    private func load() {
        let id = subjectID
        resource.load { try await MobileCatalogDetailClient().related(id) }
    }
}

private struct CatalogPeopleView: View {
    let subjectID: Int
    let kind: MobilePersonKind
    @State private var resource = MobileDetailResource<[MobileCatalogPerson]>()
    var body: some View {
        List {
            CatalogResourceStatus(resource: resource, retry: load)
            if let people = resource.value {
                if people.isEmpty { Text("No people available.").foregroundStyle(.secondary) }
                // A staff member may hold multiple positions; row identity must not collapse those roles.
                ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                    Section {
                        NavigationLink {
                            CatalogPersonInfoView(personID: person.id, name: person.name, kind: kind)
                                .id("\(kind.rawValue)-\(person.id)")
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(person.name)
                                if let relation = person.relation, !relation.isEmpty {
                                    Text(relation).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(minHeight: 56)
                        }
                        if let actors = person.actors, !actors.isEmpty {
                            Text("Voice actors").font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(actors.enumerated()), id: \.offset) { _, actor in
                                NavigationLink {
                                    CatalogPersonInfoView(personID: actor.id, name: actor.name, kind: .person)
                                        .id("person-\(actor.id)")
                                } label: { Text(actor.name).frame(minHeight: 56) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(LocalizedStringKey(kind == .character ? "Characters" : "Staff"))
        .accessibilityIdentifier("detail-people-list")
        .onAppear { if resource.value == nil && !resource.loading { load() } }
        .onDisappear { resource.cancel() }
    }
    private func load() {
        let id = subjectID
        let type = kind
        resource.load { try await MobileCatalogDetailClient().people(id, kind: type) }
    }
}

private struct CatalogPersonInfoView: View {
    let personID: Int
    let name: String
    let kind: MobilePersonKind
    @State private var resource = MobileDetailResource<MobilePersonDetail>()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(resource.value?.name ?? name).font(.title.bold())
                CatalogResourceStatus(resource: resource, retry: load)
                if let person = resource.value {
                    if let summary = person.summary, !summary.isEmpty {
                        Text(summary).textSelection(.enabled).lineSpacing(6)
                            .accessibilityIdentifier("detail-person-summary")
                    } else { Text("No introduction available.").foregroundStyle(.secondary) }
                    if let entries = person.infobox {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            if !entry.value.text.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(entry.key).font(.headline)
                                    Text(entry.value.text).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                Link(destination: URL(string: "https://bgm.tv/\(kind == .character ? "character" : "person")/\(personID)")!) {
                    Label("View on Bangumi", systemImage: "arrow.up.right.square").frame(minHeight: 56)
                }
            }.padding().frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle(LocalizedStringKey(kind == .character ? "Character information" : "Person information"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if resource.value == nil && !resource.loading { load() } }
        .onDisappear { resource.cancel() }
    }
    private func load() {
        let id = personID
        let type = kind
        resource.load { try await MobileCatalogDetailClient().person(id, kind: type) }
    }
}

private struct CatalogCommentsView: View {
    let subjectID: Int
    @State private var resource = MobileDetailResource<MobileCommentFeed>()
    var body: some View {
        List {
            Text("Public Bangumi comments. Reading only; ratings and comments are not synced.")
                .font(.footnote).foregroundStyle(.secondary)
            if let feed = resource.value {
                if feed.comments.isEmpty { Text("No comments available.").foregroundStyle(.secondary) }
                ForEach(feed.comments) { comment in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(comment.author).font(.headline)
                        if let rating = comment.rating {
                            Label("\(rating) / 10", systemImage: "star").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(comment.text).textSelection(.enabled)
                        if !comment.dateText.isEmpty { Text(comment.dateText).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 8)
                }
            }
            CatalogResourceStatus(resource: resource, retry: load)
            if !resource.loading && !resource.failed && !resource.cancelled, resource.value?.nextPage != nil {
                Button("Load more", action: load).frame(minHeight: 56)
                    .accessibilityIdentifier("detail-comments-more")
            }
        }
        .navigationTitle("Comments (read-only)")
        .accessibilityIdentifier("detail-comments-list")
        .onAppear { if resource.value == nil && !resource.loading { load() } }
        .onDisappear { resource.cancel() }
    }
    private func load() {
        guard !resource.loading else { return }
        let previous = resource.value
        guard previous == nil || previous?.nextPage != nil else { return }
        let page = previous?.nextPage ?? 1
        let id = subjectID
        resource.load {
            let response = try await MobileCatalogDetailClient().comments(id, page: page)
            return try MobileCommentFeed.appending(response, to: previous, requestedPage: page)
        }
    }
}
