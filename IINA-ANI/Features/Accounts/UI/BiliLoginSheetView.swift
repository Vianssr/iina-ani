//
//  BiliLoginSheetView.swift
//  IINA+
//
//  Created by xjbeta on 2025/8/9.
//  Copyright © 2025 xjbeta. All rights reserved.
//

import SwiftUI

struct BiliLoginSheetView: View {

    @Binding var loginSheet: Bool
    @Binding var status: SiteLoginStatus
    @Binding var userName: String
    var accountID: UUID? = nil
    var accounts: SiteAccounts = .shared

    var body: some View {
        LoginSheetContainer(size: CGSize(width: 500, height: 700), onCancel: {
            loginSheet = false
        }) {
            LoginWebView(
                accounts: accounts,
                sourceID: "bilibili",
                accountID: accountID,
                url: URL(string: "https://passport.bilibili.com/login")!,
                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 10_2_1 like Mac OS X) AppleWebKit/602.4.6 (KHTML, like Gecko) Version/10.0 Mobile/14D27 Safari/602.1",
                successCookies: ["bili_jct"],
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
    BiliLoginSheetView(loginSheet: .init(get: {
        true
    }, set: { _ in

    }), status: .init(get: {
        .error
    }, set: { _ in
    }), userName: .init(get: {
        ""
    }, set: { _ in

    }))
}