//
//  DouyuLoginSheetView.swift
//  IINA+
//
//  Created by xjbeta on 2026/9/22.
//  Copyright © 2026 xjbeta. All rights reserved.
//

import SwiftUI

struct DouyuLoginSheetView: View {

    @Binding var loginSheet: Bool
    @Binding var status: SiteLoginStatus
    @Binding var userName: String
    var accountID: UUID? = nil
    var accounts: SiteAccounts = .shared

    var body: some View {
        LoginSheetContainer(size: CGSize(width: 840, height: 600), onCancel: {
            loginSheet = false
        }) {
            LoginWebView(
                accounts: accounts,
                sourceID: "douyu",
                accountID: accountID,
                url: URL(string: "https://passport.douyu.com/index/login?client_id=1")!,
                userAgent: Douyu.webUserAgent,
                successCookies: ["dy_auth", "acf_auth"],
                loginHandler: { isLogin, name in
                    defer {
                        loginSheet = false
                    }
                    guard isLogin else {
                        status = .error
                        return
                    }
                    status = .loggedIn
                    userName = name
                })
        }
    }
}

#Preview {
    DouyuLoginSheetView(loginSheet: .init(get: {
        true
    }, set: { _ in
    }), status: .init(get: {
        .error
    }, set: { _ in
    }), userName: .constant(""))
}