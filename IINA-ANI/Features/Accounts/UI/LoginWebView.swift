//
//  LoginWebView.swift
//  IINA+
//
//  Created by xjbeta on 2026/9/22.
//  Copyright © 2026 xjbeta. All rights reserved.
//

import SwiftUI
import WebKit

/// Each login attempt has a fresh, memory-only container. Only server-validated
/// cookies are committed to the selected account's secure credential store.
struct LoginWebView: NSViewRepresentable {
    var accounts: SiteAccounts = .shared
    let sourceID: String
    var accountID: UUID? = nil
    let url: URL
    let userAgent: String
    let successCookies: [String]
    let loginHandler: @MainActor (Bool, String) async -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(sourceID: sourceID, accountID: accountID,
                    successCookies: successCookies, loginHandler: loginHandler, accounts: accounts)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = userAgent
        context.coordinator.start(webView: webView, url: url)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.cancel()
        nsView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject {
        let sourceID: String
        let accounts: SiteAccounts
        private(set) var accountID: UUID?
        let successCookies: [String]
        let loginHandler: @MainActor (Bool, String) async -> Void
        private(set) weak var webView: WKWebView?
        private var pollingTask: Task<Void, Never>?
        private(set) var completed = false
        private var cancelled = false
        #if DEBUG
        private var lastDouyuCookieState: UInt8?
        #endif

        init(sourceID: String, accountID: UUID?, successCookies: [String],
             loginHandler: @escaping @MainActor (Bool, String) async -> Void, accounts: SiteAccounts) {
            self.sourceID = sourceID
            self.accountID = accountID
            self.successCookies = successCookies
            self.loginHandler = loginHandler
            self.accounts = accounts
        }

        func start(webView: WKWebView, url: URL) {
            self.webView = webView
            pollingTask = Task { [weak self] in
                guard let self else { return }
                do {
                    if accountID == nil {
                        if let account = try await accounts.defaultAccount(sourceID: sourceID) {
                            accountID = account.id
                        } else if let pending = try await accounts.accounts(sourceID: sourceID)
                            .first(where: { $0.enabled && $0.status == .needsLogin }) {
                            accountID = pending.id
                        } else {
                            let account = try await accounts.add(sourceID: sourceID, displayName: sourceID)
                            accountID = account.id
                        }
                    }
                    try Task.checkCancellation()
                    #if DEBUG
                    if sourceID == "douyu" { Log("[DouyuLogin] stage=web.load") }
                    #endif
                    webView.load(URLRequest(url: url))
                    while !completed {
                        try await Task.sleep(for: .seconds(2))
                        try Task.checkCancellation()
                        await checkLogin()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !cancelled else { return }
                    #if DEBUG
                    if sourceID == "douyu" {
                        Log("[DouyuLogin] stage=start.failed error=\(String(describing: error as? SiteAccountError ?? .validationFailed))")
                    }
                    #endif
                    completed = true
                    await loginHandler(false, "")
                }
            }
        }

        func checkLogin() async {
            guard !completed, !cancelled, let webView, let accountID else { return }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            #if DEBUG
            if sourceID == "douyu", !cancelled {
                var state: UInt8 = 0
                for cookie in cookies where !cookie.value.isEmpty {
                    switch cookie.name {
                    case "dy_auth": state |= 1
                    case "acf_auth": state |= 2
                    case "acf_uid": state |= 4
                    case "acf_nickname": state |= 8
                    case "dy_did": state |= 16
                    default: break
                    }
                }
                if lastDouyuCookieState != state {
                    lastDouyuCookieState = state
                    Log("[DouyuLogin] stage=web.cookies dy_auth=\(state & 1 != 0) acf_auth=\(state & 2 != 0) uid=\(state & 4 != 0) nickname=\(state & 8 != 0) did=\(state & 16 != 0)")
                }
            }
            #endif
            guard !cancelled,
                  cookies.contains(where: { successCookies.contains($0.name) }) else { return }
            completed = true
            #if DEBUG
            if sourceID == "douyu" { Log("[DouyuLogin] stage=validation.begin") }
            #endif
            do {
                let account = try await accounts.completeLogin(accountID: accountID, cookies: cookies)
                guard !cancelled else { return }
                if try await accounts.defaultAccount(sourceID: sourceID) == nil {
                    try await accounts.setDefault(accountID: account.id, sourceID: sourceID)
                }
                guard !cancelled else { return }
                #if DEBUG
                if sourceID == "douyu" { Log("[DouyuLogin] stage=login.succeeded") }
                #endif
                await loginHandler(true, account.displayName)
            } catch {
                guard !cancelled else { return }
                #if DEBUG
                if sourceID == "douyu" {
                    Log("[DouyuLogin] stage=validation.failed error=\(String(describing: error as? SiteAccountError ?? .validationFailed))")
                }
                #endif
                await loginHandler(false, "")
            }
        }

        func cancel() {
            #if DEBUG
            if sourceID == "douyu" { Log("[DouyuLogin] stage=web.closed completed=\(completed)") }
            #endif
            cancelled = true
            pollingTask?.cancel()
            pollingTask = nil
            webView?.stopLoading()
            webView = nil
        }
    }
}

#Preview {
    LoginWebView(sourceID: "douyu", url: URL(string: "https://www.douyu.com")!,
                 userAgent: "Mozilla/5.0", successCookies: ["dy_auth"],
                 loginHandler: { _, _ in })
        .frame(width: 500, height: 700)
}
