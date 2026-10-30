import SwiftUI

struct MobileSourceSettingsView: View {
    @Environment(MobileSourceLibrary.self) private var sources
    @State private var importing = false

    var body: some View {
        Form {
            Section {
                Button { importing = true } label: {
                    Label("Import from URL", systemImage: "link.badge.plus")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("source-settings-import")
            }
            Section("Installed sources") {
                if sources.sources.isEmpty {
                    Text("No sources configured. Import a configuration URL to get started.")
                        .foregroundStyle(.secondary).accessibilityIdentifier("source-settings-empty")
                }
                ForEach(sources.sources) { entry in MobileSourceSettingsRow(entry: entry) }
            }
            if !sources.issues.isEmpty {
                Section {
                    Label("Some source files could not be loaded. Existing files were preserved.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Button("Retry") { sources.reload() }
                }
            }
        }
        .navigationTitle("Source configuration")
        .navigationBarTitleDisplayMode(.inline)
        .task { sources.reload() }
        .sheet(isPresented: $importing) { MobileSourceURLImportView(sources: sources) }
    }
}

private struct MobileSourceSettingsRow: View {
    let entry: MobileSourceEntry
    @AppStorage private var enabled: Bool

    init(entry: MobileSourceEntry) {
        self.entry = entry
        _enabled = AppStorage(wrappedValue: false, "mobile.sources." + entry.id + ".enabled")
    }

    var body: some View {
        Toggle(isOn: $enabled) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: entry.configuration.name).font(.headline)
                Text(verbatim: entry.configuration.hosts.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 2)
        }
        .accessibilityIdentifier("source-settings-enabled-" + entry.id)
        .accessibilityHint("Enable this source to search for episodes and play videos.")
    }
}

struct MobileSourceURLImportView: View {
    let sources: MobileSourceLibrary
    var onSubscriptionApplied: () -> Void = {}
    var onImported: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var importer = MobileSourceURLImport.forApp()
    @State private var imported = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top) {
                        TextField("https://example.com/source.json", text: $address, axis: .vertical)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($addressFocused).lineLimit(2...4)
                            .accessibilityLabel("Configuration URL")
                            .accessibilityIdentifier("source-import-url")
                            .onSubmit { load() }
                        if !address.isEmpty {
                            Button { address = ""; addressFocused = true } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    .frame(minWidth: 44, minHeight: 44)
                            }.buttonStyle(.plain).accessibilityLabel("Clear URL")
                                .accessibilityIdentifier("source-import-clear")
                        }
                    }
                    Button(action: load) {
                        Label("Download and review", systemImage: "arrow.down.doc")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent)
                        .disabled(importer.busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("source-import-download")
                    if importer.busy {
                        ProgressView("Downloading configuration…")
                        Button("Cancel request") { importer.cancel() }
                            .frame(minHeight: 44).accessibilityIdentifier("source-import-cancel-request")
                    }
                    if let failure = importer.failure {
                        Label(LocalizedStringKey(failure.message), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary).accessibilityIdentifier("source-import-error")
                    }
                } header: { Text("Configuration URL") } footer: {
                    Text("Source JSON, source lists, or CSS1 configurations. Review before saving.")
                }
            }
            .navigationTitle("Import from URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { importer.cancel(); dismiss() }
                        .accessibilityIdentifier("source-import-cancel")
                }
            }
        }
        .onChange(of: address) { _, _ in importer.cancel() }
        .onDisappear { importer.cancel() }
        .sheet(item: Binding(get: { importer.draft }, set: { if $0 == nil { importer.clearPreview() } }), onDismiss: finish) { draft in
            SourceImportPreview(draft: draft, replaces: sources.replaces(draft),
                                currentRevision: sources.sources.first(where: { $0.id == draft.configuration.id })?.configuration.configurationRevision) {
                let id = try sources.apply(draft)
                imported = true
                onImported(id)
            }
        }
        .sheet(item: Binding(get: { importer.batch }, set: { if $0 == nil { importer.clearPreview() } }), onDismiss: finish) { batch in
            MobileSourceBatchPreview(batch: batch, sources: sources) {
                let ids = try sources.apply(batch)
                imported = true
                if let id = ids.first { onImported(id) }
            }
        }
        .sheet(item: Binding(get: { importer.subscriptionPreview }, set: { if $0 == nil { importer.clearPreview() } }), onDismiss: finish) { preview in
            MobileSubscriptionPreviewView(preview: preview) {
                try sources.applySubscription(preview)
                imported = true
                onSubscriptionApplied()
            }
        }
    }

    private func finish() { if imported { dismiss() } }
    private func load() {
        guard !importer.busy else { return }
        addressFocused = false
        importer.load(address, library: sources)
    }
}

private struct MobileSourceBatchPreview: View {
    let batch: MobileSourceBatchDraft
    let sources: MobileSourceLibrary
    let apply: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                if batch.drafts.contains(where: { $0.configuration.webSelector != nil }) {
                    Section {
                        Text("CSS1 samples passed search, episode listing and media URL resolution. Playback is not guaranteed. Failed checks are skipped for this import; existing sources are kept.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !batch.notices.isEmpty {
                    Section("Skipped sources") {
                        ForEach(Array(batch.notices.enumerated()), id: \.offset) { _, notice in
                            Text(verbatim: notice).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(batch.drafts) { draft in
                    Section {
                        Text(verbatim: draft.configuration.name).font(.headline)
                        Text(verbatim: draft.configuration.id).font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: draft.configuration.hosts.joined(separator: " · ")).font(.caption)
                        Text(LocalizedStringKey(sources.replaces(draft) ? "Replace configuration" : "Add source"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Imported sources stay disabled until you enable them.")
                    Button("Import sources") {
                        do { try apply(); dismiss() } catch { failed = true }
                    }.frame(minHeight: 44).disabled(batch.drafts.isEmpty).accessibilityIdentifier("source-import-batch-apply")
                }
            }
            .navigationTitle("Review sources").navigationBarTitleDisplayMode(.inline)
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
