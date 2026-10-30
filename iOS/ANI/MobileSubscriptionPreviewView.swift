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
                    Text("Search subscriptions only update supported local search rules. They do not import full configurations, playback code, or enable sources.")
                    Text("Missing, unsupported or conflicting entries keep their previous rules. Cancel makes no changes.")
                }
                ForEach(preview.entries) { entry in
                    Section {
                        Text(verbatim: entry.name).font(.headline)
                        if let id = entry.sourceID { Text(verbatim: id).font(.caption).foregroundStyle(.secondary) }
                        Text(LocalizedStringKey(entry.status))
                        if let before = entry.before {
                            Text("Current search rules").font(.caption.bold())
                            Text(verbatim: before).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if let after = entry.after {
                            Text("Proposed search rules").font(.caption.bold())
                            Text(verbatim: after).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Section("Subscription fingerprint") {
                    Text(verbatim: preview.state.fingerprint).font(.caption.monospaced())
                    Text(preview.state.checkedAt, style: .date)
                }
                Section {
                    Text("Changed configuration fingerprints require saved selections to be confirmed again. Source order and enablement remain unchanged.")
                    Button("Apply search rules") {
                        do { try apply(); dismiss() } catch { failed = true }
                    }.frame(minHeight: 48).disabled(preview.state.overrides.isEmpty)
                        .accessibilityIdentifier("source-subscription-apply")
                }
            }
            .navigationTitle("Review search subscription")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("Unable to apply search rules", isPresented: $failed) { Button("OK", role: .cancel) {} }
            message: { Text("The preview or local sources changed, or storage is unavailable. Check the subscription again. Existing rules were preserved.") }
        }
    }
}
