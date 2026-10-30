import SwiftUI

struct MobileLinksView: View {
    @Environment(MobileLinkLibrary.self) private var library
    @State private var query = ""
    @State private var draft: LinkDraft?
    @State private var removing: MobileLinkFavorite?
    @State private var failed = false

    var body: some View {
        List {
            Section {
                Text("Link favorites are source pages, separate from anime and watching status. Open them in your browser; saving a link does not start playback.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !library.isReadable || library.storageError {
                Section {
                    Text("Link favorites could not be read or saved. Existing data has been preserved.")
                    Button("Retry") { library.reload() }.accessibilityIdentifier("links-retry")
                }
            }
            if library.isReadable {
                ForEach(library.matching(query)) { link in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: link.title).font(.headline)
                        Text(verbatim: link.item.pageURL).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        HStack {
                            if let url = URL(string: link.item.pageURL) {
                                Link("Open in Browser", destination: url)
                            }
                            Spacer()
                            Button("Edit") { draft = LinkDraft(link: link) }
                                .accessibilityIdentifier("link-edit-" + link.id.uuidString)
                            Button("Remove", role: .destructive) { removing = link }
                                .accessibilityIdentifier("link-remove-" + link.id.uuidString)
                        }.buttonStyle(.borderless).frame(minHeight: 44)
                    }.padding(.vertical, 6)
                }
                if library.links.isEmpty {
                    Text("No saved links").foregroundStyle(.secondary)
                } else if library.matching(query).isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle("Link favorites")
        .searchable(text: $query, prompt: "Search links")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { draft = LinkDraft() } label: { Label("Add link", systemImage: "plus") }
                    .disabled(!library.isReadable).accessibilityIdentifier("links-add")
            }
        }
        .sheet(item: $draft) { value in MobileLinkEditor(draft: value) }
        .confirmationDialog("Remove saved link?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let link = removing else { return }
                do { try library.remove(link.id) } catch { failed = true }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("This only removes the saved link, not anime, history, or media.") }
        .alert("Link could not be saved", isPresented: $failed) { Button("OK", role: .cancel) {} }
    }
}

private struct LinkDraft: Identifiable {
    let id = UUID()
    var linkID: UUID?
    var title = ""
    var address = ""
    init() {}
    init(link: MobileLinkFavorite) {
        linkID = link.id
        title = link.title
        address = link.item.pageURL
    }
}

private struct MobileLinkEditor: View {
    @Environment(MobileLinkLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State var draft: LinkDraft
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $draft.title).accessibilityIdentifier("link-title")
                TextField("HTTPS source page", text: $draft.address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("link-address")
                Text("Use a public HTTPS page, without credentials, signed media, or tracking parameters. A single public identity parameter is supported.")
                    .font(.footnote).foregroundStyle(.secondary)
                if failed {
                    Text("Link could not be saved. Check the public page, title, duplicates, and storage, then try again.")
                        .foregroundStyle(.red).accessibilityIdentifier("link-save-error")
                }
            }
            .navigationTitle(draft.linkID == nil ? "Add link" : "Edit link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try library.save(id: draft.linkID, title: draft.title, address: draft.address)
                            dismiss()
                        } catch { failed = true }
                    }.disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.address.isEmpty)
                        .accessibilityIdentifier("link-save")
                }
            }
        }
    }
}
