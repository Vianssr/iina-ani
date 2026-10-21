import SwiftUI
import WebKit

struct BangumiAccountSheetView: View {
    @State private var account: SiteAccount?
    @State private var attempt: BangumiOAuth.Attempt?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var authorizationTask: Task<Void, Never>?
    private let service: SiteAccounts
    private let onClose: () -> Void

    init(service: SiteAccounts = .shared, onClose: @escaping () -> Void) {
        self.service = service
        self.onClose = onClose
    }

    private var statusLabel: LocalizedStringKey {
        switch account?.status {
        case .valid: return "Authorized"
        case .expired: return "Authorization expired"
        case .needsLogin, nil: return "Needs authorization"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bangumi account").font(.title2).fontWeight(.semibold)
            if let attempt {
                BangumiAuthorizationWebView(attempt: attempt, completion: completeAuthorization)
                    .frame(width: 790, height: 520)
            } else {
                if let account, account.status != .needsLogin {
                    Text(account.displayName).fontWeight(.medium)
                }
                HStack {
                    Text("Status")
                    Text(statusLabel)
                    Spacer()
                }
                Divider()
                Text("Sign in to your personal Bangumi account and authorize this app. Application credentials are handled automatically; your account tokens are stored in macOS Keychain.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(account?.status == .valid || account?.status == .expired
                           ? String(localized: "Reauthorize") : String(localized: "Sign In")) { authorize() }
                        .disabled(isWorking)
                    if isWorking { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { cancelAuthorization(); onClose() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("login.cancel")
            }
        }
        .padding(22)
        .frame(width: attempt == nil ? 520 : 834)
        .task { account = await service.bangumiAccount() }
        .onDisappear { cancelAuthorization() }
    }

    private func authorize() {
        do {
            try BangumiOAuth.shared.requireConfiguration()
            isWorking = true
            errorMessage = nil
            attempt = BangumiOAuth.Attempt()
        } catch {
            isWorking = false
            errorMessage = error.localizedDescription
        }
    }

    private func completeAuthorization(_ result: Result<BangumiOAuth.Callback, Error>) {
        attempt = nil
        authorizationTask = Task {
            defer { if !Task.isCancelled { isWorking = false; authorizationTask = nil } }
            do {
                let credentials = try await BangumiOAuth.shared.exchange(result.get())
                let updated = try await service.completeBangumiLogin(credentials: credentials)
                try Task.checkCancellation()
                account = updated
                errorMessage = nil
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    private func cancelAuthorization() {
        authorizationTask?.cancel()
        authorizationTask = nil
        attempt = nil
        isWorking = false
    }

}

private struct BangumiAuthorizationWebView: NSViewRepresentable {
    let attempt: BangumiOAuth.Attempt
    let completion: @MainActor (Result<BangumiOAuth.Callback, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(attempt: attempt, completion: completion) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: attempt.loginURL))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.finished = true
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let attempt: BangumiOAuth.Attempt
        let completion: @MainActor (Result<BangumiOAuth.Callback, Error>) -> Void
        var finished = false
        init(attempt: BangumiOAuth.Attempt, completion: @escaping @MainActor (Result<BangumiOAuth.Callback, Error>) -> Void) {
            self.attempt = attempt
            self.completion = completion
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard !finished else { return .cancel }
            guard action.targetFrame?.isMainFrame != false, let url = action.request.url else { return .allow }
            do {
                if let callback = try attempt.callback(from: url) {
                    finish(.success(callback))
                    return .cancel
                }
                return .allow
            } catch {
                finish(.failure(error))
                return .cancel
            }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if !finished, action.targetFrame == nil { webView.load(action.request) }
            return nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { finish(.failure(BangumiOAuth.Failure.exchangeFailed)) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { finish(.failure(BangumiOAuth.Failure.exchangeFailed)) }
        }
        private func finish(_ result: Result<BangumiOAuth.Callback, Error>) {
            guard !finished else { return }
            finished = true
            completion(result)
        }
    }
}
