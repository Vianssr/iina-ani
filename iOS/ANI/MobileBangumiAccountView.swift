import SwiftUI

struct MobileBangumiAccountView: View {
    @Environment(MobileBangumiAccount.self) private var account
    @Environment(MobileLibrary.self) private var library
    @State private var token = ""
    @State private var showAssignmentConfirmation = false

    var body: some View {
        Form {
            Section {
                Text("This build uses Bangumi personal access tokens, not an embedded OAuth client. Create a token on Bangumi and paste it here. It is stored only in this device’s Keychain.")
                    .foregroundStyle(.secondary)
                Link("Create a Bangumi personal access token", destination: URL(string: "https://bgm.tv/dev/app")!)
                SecureField("Personal access token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .accessibilityIdentifier("bangumi-token")
                Button(LocalizedStringKey(account.user == nil ? "Sign in to Bangumi" : "Switch Bangumi account")) {
                    let submitted = token
                    token = ""
                    Task { await account.signIn(token: submitted) }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || account.isAuthenticating)
                .accessibilityIdentifier("bangumi-sign-in")
                if account.isAuthenticating { ProgressView("Validating account…") }
            } header: { Text("Bangumi account") }

            if let user = account.user {
                Section {
                    LabeledContent("Signed in as", value: user.displayName)
                    LabeledContent("Bangumi user ID", value: String(user.id))
                    LabeledContent("Pending changes for this account", value: String(account.pendingCount))
                    Button("Retry collection sync") { Task { await account.retrySync() } }
                        .disabled(account.isSyncing || account.isAuthenticating || !library.isReadable)
                        .accessibilityIdentifier("bangumi-sync-retry")
                    if account.isSyncing { ProgressView("Syncing collection categories…") }
                    Button("Import Bangumi collections") { Task { await account.importCollections() } }
                        .disabled(account.isImporting || account.isAuthenticating || !library.isReadable)
                        .accessibilityIdentifier("bangumi-import")
                    if account.isImporting { ProgressView("Importing collections…") }
                    if account.lastImportedCount != nil { Text("Import complete. Existing local favorites were preserved.") }
                    Button("Sign out of Bangumi", role: .destructive) { account.signOut() }
                        .accessibilityIdentifier("bangumi-sign-out")
                } header: { Text("Collection category sync") }
            }

            if account.unassignedCount > 0 {
                Section {
                    LabeledContent("Unassigned local changes", value: String(account.unassignedCount))
                    Text("Changes made without an account stay local until you explicitly assign them. Another account’s pending changes are never sent to the current account.")
                    if account.user != nil {
                        Button("Send unassigned changes to this account") { showAssignmentConfirmation = true }
                            .disabled(account.isAuthenticating || !library.isReadable)
                    }
                }
            }
            Section {
                Text("Only collection categories sync. Unclassified never deletes a remote collection. Watch progress, ratings and comments stay unchanged. Failed changes remain saved for retry, including after restart.")
                if let error = account.errorMessage { Text(LocalizedStringKey(error)).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Bangumi account & sync")
        .confirmationDialog("Send unassigned local categories to this Bangumi account?", isPresented: $showAssignmentConfirmation,
                            titleVisibility: .visible) {
            Button("Send changes") { Task { await account.syncUnassignedChanges() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates collection categories on the currently signed-in account. Changes already bound to other accounts remain untouched.")
        }
    }
}
