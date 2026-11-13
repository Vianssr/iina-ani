import SwiftUI

struct MobileSubscriptionPreviewView: View {
    let preview: MobileSubscriptionPreview
    let apply: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var failed = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Subscriptions update search rules and can import static page sources. Review the entries before applying; new sources remain disabled.")
                    Text("Missing, unsupported or conflicting entries keep their previous rules. Cancel makes no changes.")
                }
                ForEach(preview.entries) { entry in
                    Section {
                        Text(verbatim: entry.name).font(.headline)
                        if let id = entry.sourceID { Text(verbatim: id).font(.caption).foregroundStyle(.secondary) }
                        Text(LocalizedStringKey(entry.status))
                        Text(verbatim: entry.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Subscription fingerprint") {
                    Text(verbatim: preview.state.fingerprint).font(.caption.monospaced())
                    Text(preview.state.checkedAt, style: .date)
                }
                Section {
                    Text("Search updates keep saved playback selections and source enablement unchanged.")
                    Button("Apply subscription") {
                        do { try apply(); dismiss() } catch { failed = true }
                    }.frame(minHeight: 48).disabled(preview.state.overrides.isEmpty && preview.state.configurations.isEmpty)
                        .accessibilityIdentifier("source-subscription-apply")
                }
            }
            .navigationTitle("Review source subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Unable to apply search rules", isPresented: $failed) { Button("OK", role: .cancel) {} }
            message: { Text("The preview or local sources changed, or storage is unavailable. Check the subscription again. Existing rules were preserved.") }
        }
    }
}
