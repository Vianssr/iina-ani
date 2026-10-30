import Foundation
import Alamofire
import Security
import WebKit

struct SiteAccount: Codable, Sendable, Identifiable, Equatable {
    enum Status: String, Codable, Sendable { case needsLogin, valid, expired }
    let id: UUID
    let sourceID: String
    var displayName: String
    var enabled: Bool
    var status: Status
    var bangumiUserID: Int? = nil
}

enum SiteAccountError: Error, LocalizedError {
    case unsupportedLogin(String), invalidAccount, disabled, needsLogin, expired
    case accountInUse, invalidCookies, validationFailed, secureStorage(OSStatus)
    case bangumiIdentityChanged

    var errorDescription: String? {
        switch self {
        case .unsupportedLogin(let source): return String(localized: "Login is not supported for \(source).")
        case .invalidAccount: return NSLocalizedString("The selected account does not exist or belongs to another source.", comment: "")
        case .disabled: return NSLocalizedString("The selected source or account is disabled.", comment: "")
        case .needsLogin: return NSLocalizedString("The selected account needs login.", comment: "")
        case .expired: return NSLocalizedString("The selected account has expired. Sign in again.", comment: "")
        case .accountInUse: return NSLocalizedString("The account is being used by an active operation. Stop it before changing this account.", comment: "")
        case .invalidCookies: return NSLocalizedString("No supported site credentials were provided.", comment: "")
        case .validationFailed: return NSLocalizedString("The site could not validate this login. Retry or sign in again.", comment: "")
        case .secureStorage: return NSLocalizedString("Secure credential storage is unavailable.", comment: "")
        case .bangumiIdentityChanged: return String(localized: "Sign out before switching Bangumi accounts. Existing pending changes belong to the previous account.")
        }
    }
}

/// A caller can release its own use exactly once, not another operation's use.
struct AccountUseLease: Sendable {
    fileprivate let id: UUID
    let accountID: UUID
}

actor SiteAccounts {
    static let shared: SiteAccounts = {
        let service = SiteAccounts(legacyCookieStorage: .shared)
        let migratedSources = ["bilibili", "douyu"].filter {
            Preferences.shared.prefs.bool(forKey: "site-account-legacy-migrated.\($0)")
        }
        if !migratedSources.isEmpty {
            Task { @MainActor in
                let jar = WKWebsiteDataStore.default().httpCookieStore
                for cookie in await jar.allCookies()
                where migratedSources.contains(where: { SiteAccounts.belongs(cookie, to: $0) }) {
                    await jar.deleteCookie(cookie)
                }
            }
        }
        return service
    }()
    private static let metadataKey = "site-account-metadata-v1"
    private static let bangumiAccountKey = "bangumi-account-id"
    private let preferences: Preferences
    private var defaults: UserDefaults { preferences.prefs }
    private let keychainService: String
    private let bangumiIdentityValidator: (@Sendable (AccountHTTP.Context) async throws -> String)?
    private let bangumiOAuth: BangumiOAuth
    private func sourceEnabled(_ source: String) -> Bool { preferences.isSourceEnabled(source) }
    private func defaultID(_ source: String) -> UUID? { preferences.defaultAccountID(for: source) }
    private func setDefaultID(_ id: UUID?, _ source: String) { preferences.setDefaultAccountID(id, for: source) }
    private var records: [UUID: SiteAccount]
    private var leases: [UUID: UUID] = [:]
    private var bangumiAccountID: UUID
    private var importingYouTubeCookies = false

    init(preferences: Preferences = .shared,
         keychainService: String = "\(Bundle.main.bundleIdentifier ?? "IINA-ANI").site-accounts",
         legacyCookieStorage: HTTPCookieStorage? = nil,
         bangumiIdentityValidator: (@Sendable (AccountHTTP.Context) async throws -> String)? = nil,
         bangumiOAuth: BangumiOAuth = .shared) {
        self.preferences = preferences
        self.keychainService = keychainService
        self.bangumiIdentityValidator = bangumiIdentityValidator
        self.bangumiOAuth = bangumiOAuth
        let defaults = preferences.prefs
        let decoded = defaults.data(forKey: Self.metadataKey)
            .flatMap { try? JSONDecoder().decode([SiteAccount].self, from: $0) } ?? []
        var records = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let savedID = defaults.string(forKey: Self.bangumiAccountKey).flatMap(UUID.init(uuidString:))
        let selectedID = savedID ?? preferences.defaultAccountID(for: "bangumi")
            .flatMap { records[$0]?.sourceID == "bangumi" ? $0 : nil }
            ?? records.values.lazy.filter { $0.sourceID == "bangumi" }.min { $0.id.uuidString < $1.id.uuidString }?.id
            ?? UUID()
        self.bangumiAccountID = selectedID
        defaults.set(selectedID.uuidString, forKey: Self.bangumiAccountKey)
        let selected = records[selectedID]
        preferences.setDefaultAccountID(selected?.status == .valid && selected?.enabled == true ? selectedID : nil, for: "bangumi")
        // Copy before deleting, synchronously before any caller can capture a guest
        // identity. Authentication is checked by the first status/operation request.
        if let legacyCookieStorage {
            for source in ["bilibili", "douyu"] {
                let marker = "site-account-legacy-migrated.\(source)"
                guard !defaults.bool(forKey: marker) else { continue }
                let cookies = (legacyCookieStorage.cookies ?? []).filter { Self.belongs($0, to: source) }
                guard Self.hasCredential(cookies, source: source) else { continue }
                let account = SiteAccount(id: UUID(), sourceID: source, displayName: source,
                                          enabled: true, status: .needsLogin)
                do {
                    try Self.store(cookies, accountID: account.id, service: keychainService)
                    records[account.id] = account
                    defaults.set(try JSONEncoder().encode(Array(records.values)), forKey: Self.metadataKey)
                    if preferences.defaultAccountID(for: source) == nil { preferences.setDefaultAccountID(account.id, for: source) }
                    defaults.set(true, forKey: marker)
                    cookies.forEach(legacyCookieStorage.deleteCookie)
                } catch {
                    // Leave the original cookies intact if the secure copy failed.
                }
            }
        }
        self.records = records
    }

    func bangumiAccount() -> SiteAccount? { records[bangumiAccountID] }

    func accounts(sourceID: String) throws -> [SiteAccount] {
        let source = Self.canonicalSource(sourceID)
        return records.values.filter { $0.sourceID == source && (source != "bangumi" || $0.id == bangumiAccountID) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func add(sourceID: String, displayName: String) throws -> SiteAccount {
        let source = Self.canonicalSource(sourceID)
        guard ["bilibili", "douyu", "youtube"].contains(source) else { throw SiteAccountError.unsupportedLogin(sourceID) }
        let account = SiteAccount(id: UUID(), sourceID: source,
                                  displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                                  enabled: true, status: .needsLogin)
        records[account.id] = account
        persist()
        return account
    }

    func account(accountID: UUID) throws -> SiteAccount {
        guard let account = records[accountID] else { throw SiteAccountError.invalidAccount }
        return account
    }

    func defaultAccount(sourceID: String) throws -> SiteAccount? {
        guard let id = selectedDefaultID(sourceID) else { return nil }
        return try checkedAccount(id, source: sourceID)
    }

    func currentAccount(sourceID: String) throws -> SiteAccount? {
        guard let id = currentAccountID(sourceID: sourceID) else { return nil }
        return try checkedAccount(id, source: sourceID)
    }

    func currentAccountID(sourceID: String) -> UUID? {
        if let context = AccountHTTP.context,
           context.sourceID == Self.canonicalSource(sourceID) { return context.accountID }
        return selectedDefaultID(sourceID)
    }

    func setDefault(accountID: UUID?, sourceID: String) throws {
        if let accountID { _ = try checkedAccount(accountID, source: sourceID) }
        setDefaultID(accountID, sourceID)
    }

    func setEnabled(accountID: UUID, enabled: Bool) throws {
        var account = try self.account(accountID: accountID)
        try ensureUnused(accountID)
        account.enabled = enabled
        records[accountID] = account
        persist()
    }

    func signOut(accountID: UUID) async throws {
        var account = try self.account(accountID: accountID)
        try ensureUnused(accountID)
        try deleteCredentials(accountID)
        if account.sourceID == "bangumi", accountID == bangumiAccountID {
            records.removeValue(forKey: accountID)
            bangumiAccountID = UUID()
            defaults.set(bangumiAccountID.uuidString, forKey: Self.bangumiAccountKey)
        } else {
            account.status = .needsLogin
            records[accountID] = account
        }
        // A subsequent guest operation must not silently pick another account.
        for source in ["bilibili", "bilibili-live", "douyu", "bangumi", "youtube"] where defaultID(source) == accountID {
            setDefaultID(nil, source)
        }
        persist()
    }

    func remove(accountID: UUID) throws {
        _ = try account(accountID: accountID)
        try ensureUnused(accountID)
        try deleteCredentials(accountID)
        for source in ["bilibili", "bilibili-live", "douyu", "bangumi", "youtube"] where defaultID(source) == accountID {
            setDefaultID(nil, source)
        }
        records.removeValue(forKey: accountID)
        persist()
    }

    func completeLogin(accountID: UUID, cookies: [HTTPCookie]) async throws -> SiteAccount {
        var account = try self.account(accountID: accountID)
        guard account.sourceID != "bangumi" else { throw SiteAccountError.unsupportedLogin(account.sourceID) }
        guard account.enabled else { throw SiteAccountError.disabled }
        if account.sourceID == "youtube", !sourceEnabled("youtube") { throw SiteAccountError.disabled }
        try ensureUnused(accountID)
        let supported = cookies.filter { Self.belongs($0, to: account.sourceID) }
        guard Self.hasCredential(supported, source: account.sourceID) else { throw SiteAccountError.invalidCookies }
        let context = try Self.makeContext(accountID: accountID, source: account.sourceID, cookies: supported)
        let lease = beginUse(accountID)
        defer { releaseUse(lease) }
        let name = try await validatedName(account.sourceID, context: context)
        try Task.checkCancellation()
        // Validation suspends the actor; a new task may have acquired this identity.
        try ensureUnused(accountID, excluding: lease)
        #if DEBUG
        if account.sourceID == "douyu" { Log("[DouyuLogin] stage=keychain.store") }
        #endif
        let validatedCookies = (context.cookieStorage.cookies ?? []).filter { Self.belongs($0, to: account.sourceID) }
        try Self.store(validatedCookies, accountID: accountID, service: keychainService)
        account.status = .valid
        account.displayName = name
        records[accountID] = account
        if selectedDefaultID(account.sourceID) == nil { setDefaultID(accountID, account.sourceID) }
        persist()
        #if DEBUG
        if account.sourceID == "douyu" { Log("[DouyuLogin] stage=account.saved") }
        #endif
        return account
    }

    /// Validates in an isolated, temporary jar before replacing any saved login.
    /// A new profile is not published at all until its credentials are accepted.
    func importYouTubeCookies(_ data: Data) async throws -> SiteAccount {
        guard sourceEnabled("youtube") else { throw SiteAccountError.disabled }
        guard !importingYouTubeCookies else { throw SiteAccountError.accountInUse }
        let cookies = try YouTubeCookieImport.parse(data)
        var account = try defaultAccount(sourceID: "youtube") ??
            SiteAccount(id: UUID(), sourceID: "youtube", displayName: "YouTube",
                        enabled: true, status: .needsLogin)
        guard account.enabled else { throw SiteAccountError.disabled }
        try ensureUnused(account.id)
        let context = try Self.makeContext(accountID: account.id, source: "youtube", cookies: cookies)
        importingYouTubeCookies = true
        let lease = beginUse(account.id)
        defer {
            releaseUse(lease)
            importingYouTubeCookies = false
        }
        let name = try await validatedName("youtube", context: context)
        try Task.checkCancellation()
        guard sourceEnabled("youtube") else { throw SiteAccountError.disabled }
        try ensureUnused(account.id, excluding: lease)
        let validatedCookies = (context.cookieStorage.cookies ?? []).filter { Self.belongs($0, to: "youtube") }
        guard Self.hasCredential(validatedCookies, source: "youtube") else { throw SiteAccountError.invalidCookies }
        try Self.store(validatedCookies, accountID: account.id, service: keychainService)
        account.status = .valid
        account.displayName = name
        records[account.id] = account
        setDefaultID(account.id, "youtube")
        persist()
        return account
    }

    func completeBangumiLogin(credentials: BangumiOAuth.Credentials) async throws -> SiteAccount {
        let accountID = bangumiAccountID
        var account = records[accountID] ?? SiteAccount(id: accountID, sourceID: "bangumi",
                                                      displayName: "Bangumi", enabled: true, status: .needsLogin)
        try ensureUnused(accountID)
        guard credentials.expiresAt > Date(), !credentials.accessToken.isEmpty,
              !credentials.refreshToken.isEmpty,
              !credentials.accessToken.contains(where: { $0.isWhitespace }) else { throw SiteAccountError.invalidCookies }
        let context = try Self.makeContext(accountID: accountID, source: "bangumi", cookies: [], bearerToken: credentials.accessToken)
        let lease = beginUse(accountID)
        defer { releaseUse(lease) }
        let name: String
        let remoteUserID: Int?
        if let bangumiIdentityValidator {
            name = try await bangumiIdentityValidator(context)
            remoteUserID = nil
        } else {
            let response = await context.session.request(
                "https://api.bgm.tv/v0/me",
                headers: ["User-Agent": "IINA-ANI/1.0 (Bangumi account client)"],
                requestModifier: AccountHTTP.authorizationModifier(token: context.bearerToken)
            ).serializingData().response
            name = try Self.bangumiDisplayName(data: response.data, statusCode: response.response?.statusCode)
            guard let data = response.data,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = value["id"] as? Int, id > 0 else { throw SiteAccountError.validationFailed }
            remoteUserID = id
            try Self.checkBangumiIdentity(existing: records[accountID], userID: id)
        }
        try Task.checkCancellation()
        try ensureUnused(accountID, excluding: lease)
        try Self.storeSecret(JSONEncoder().encode(credentials), accountID: accountID, service: keychainService)
        account.status = .valid
        account.enabled = true
        account.displayName = name
        account.bangumiUserID = remoteUserID
        records[accountID] = account
        setDefaultID(accountID, "bangumi")
        persist()
        return account
    }
    func refreshStatus(accountID: UUID) async throws -> SiteAccount {
        let account = try self.account(accountID: accountID)
        guard account.enabled else { throw SiteAccountError.disabled }
        guard account.sourceID != "bangumi" || accountID == bangumiAccountID else { throw SiteAccountError.invalidAccount }
        try ensureUnused(accountID)
        let lease = beginUse(accountID)
        defer { releaseUse(lease) }
        if account.sourceID == "bangumi" {
            let credentials = try bangumiCredentials(accountID: accountID)
            if credentials.expiresAt <= Date() {
                let renewed: BangumiOAuth.Credentials
                do { renewed = try await bangumiOAuth.refresh(credentials) }
                catch BangumiOAuth.Failure.invalidRefresh {
                    try markExpired(accountID: accountID)
                    throw SiteAccountError.expired
                }
                let context = try Self.makeContext(accountID: accountID, source: "bangumi", cookies: [], bearerToken: renewed.accessToken)
                let name = try await validatedName("bangumi", context: context)
                try Task.checkCancellation()
                try Self.storeSecret(JSONEncoder().encode(renewed), accountID: accountID, service: keychainService)
                var updated = account
                updated.status = .valid
                updated.displayName = name
                records[accountID] = updated
                setDefaultID(accountID, "bangumi")
                persist()
                return updated
            }
        }
        let context = try contextFor(account)
        try await validateAndPersist(account, context: context)
        return try self.account(accountID: accountID)
    }

    /// W6 retains the lease for the lifetime of a task, including pauses. Its
    /// request scopes still validate credentials before performing site I/O.
    func acquireUse(accountID: UUID, sourceID: String) throws -> AccountUseLease {
        let account = try checkedAccount(accountID, source: sourceID)
        guard sourceEnabled(sourceID), account.enabled else { throw SiteAccountError.disabled }
        switch account.status {
        case .needsLogin: throw SiteAccountError.needsLogin
        case .expired: throw SiteAccountError.expired
        case .valid: return beginUse(accountID)
        }
    }

    func releaseUse(_ lease: AccountUseLease) { leases.removeValue(forKey: lease.id) }

    /// Presentation explains blocks; mutations still recheck leases atomically.
    func activeUseCount(accountID: UUID) -> Int {
        leases.values.filter { $0 == accountID }.count
    }

    func withSource<T: Sendable>(sourceID: String, accountID: UUID? = nil,
                                useDefaultAccount: Bool = true,
                                operation: @Sendable () async throws -> T) async throws -> T {
        if let current = AccountHTTP.context {
            guard current.sourceID == Self.canonicalSource(sourceID),
                  accountID == nil || accountID == current.accountID,
                  useDefaultAccount || accountID == current.accountID else { throw SiteAccountError.invalidAccount }
            return try await operation()
        }
        guard sourceEnabled(sourceID) else { throw SiteAccountError.disabled }
        let selected = accountID ?? (useDefaultAccount ? selectedDefaultID(sourceID) : nil)
        if let selected { return try await withAccount(accountID: selected, sourceID: sourceID, operation: operation) }
        let context = try Self.makeContext(accountID: nil, source: Self.canonicalSource(sourceID), cookies: [])
        return try await AccountHTTP.$context.withValue(context, operation: operation)
    }

    func withAccount<T: Sendable>(accountID: UUID, sourceID: String,
                                 operation: @Sendable () async throws -> T) async throws -> T {
        if let current = AccountHTTP.context {
            guard current.accountID == accountID,
                  current.sourceID == Self.canonicalSource(sourceID) else { throw SiteAccountError.invalidAccount }
            return try await operation()
        }
        let account = try checkedAccount(accountID, source: sourceID)
        guard sourceEnabled(sourceID), account.enabled else { throw SiteAccountError.disabled }
        guard account.status != .expired else { throw SiteAccountError.expired }
        let context = try contextFor(account)
        let lease = beginUse(accountID)
        defer { releaseUse(lease) }
        try await validateAndPersist(account, context: context)
        return try await AccountHTTP.$context.withValue(context, operation: operation)
    }

    func storeCurrentCookies() throws {
        guard let context = AccountHTTP.context, let id = context.accountID,
              records[id]?.sourceID == context.sourceID, context.sourceID != "bangumi" else { throw SiteAccountError.invalidAccount }
        let cookies = (context.cookieStorage.cookies ?? []).filter { Self.belongs($0, to: context.sourceID) }
        try Self.store(cookies, accountID: id, service: keychainService)
    }

    func markExpired(accountID: UUID) throws {
        var account = try self.account(accountID: accountID)
        account.status = .expired
        records[accountID] = account
        persist()
    }

    static func canonicalSource(_ source: String) -> String { source == "bilibili-live" ? "bilibili" : source }

    private func selectedDefaultID(_ source: String) -> UUID? {
        defaultID(source) ?? (Self.canonicalSource(source) != source ? defaultID(Self.canonicalSource(source)) : nil)
    }
    private func checkedAccount(_ id: UUID, source: String) throws -> SiteAccount {
        let account = try self.account(accountID: id)
        guard account.sourceID == Self.canonicalSource(source),
              account.sourceID != "bangumi" || id == bangumiAccountID else { throw SiteAccountError.invalidAccount }
        return account
    }
    private func beginUse(_ id: UUID) -> AccountUseLease {
        let lease = AccountUseLease(id: UUID(), accountID: id)
        leases[lease.id] = id
        return lease
    }
    private func ensureUnused(_ accountID: UUID, excluding lease: AccountUseLease? = nil) throws {
        guard !leases.contains(where: { $0.value == accountID && $0.key != lease?.id }) else { throw SiteAccountError.accountInUse }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(Array(records.values)) { defaults.set(data, forKey: Self.metadataKey) }
    }

    private func contextFor(_ account: SiteAccount) throws -> AccountHTTP.Context {
        if account.sourceID == "bangumi" {
            let credentials = try bangumiCredentials(accountID: account.id)
            guard credentials.expiresAt > Date() else {
                try markExpired(accountID: account.id)
                throw SiteAccountError.expired
            }
            return try Self.makeContext(accountID: account.id, source: account.sourceID, cookies: [], bearerToken: credentials.accessToken)
        }
        let data = try credentialData(accountID: account.id)
        guard let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else { throw SiteAccountError.invalidCookies }
        let cookies = stored.compactMap { $0.cookie() }.filter { Self.belongs($0, to: account.sourceID) }
        guard Self.hasCredential(cookies, source: account.sourceID) else { throw SiteAccountError.needsLogin }
        return try Self.makeContext(accountID: account.id, source: account.sourceID, cookies: cookies)
    }

    private func bangumiCredentials(accountID: UUID) throws -> BangumiOAuth.Credentials {
        let data = try credentialData(accountID: accountID)
        guard let credentials = try? JSONDecoder().decode(BangumiOAuth.Credentials.self, from: data) else {
            var account = try self.account(accountID: accountID)
            account.status = .needsLogin
            records[accountID] = account
            persist()
            throw SiteAccountError.needsLogin
        }
        return credentials
    }

    private func credentialData(accountID: UUID) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keychainService, kSecAttrAccount as String: accountID.uuidString,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw SiteAccountError.needsLogin }
        guard status == errSecSuccess else { throw SiteAccountError.secureStorage(status) }
        guard let data = result as? Data else { throw SiteAccountError.invalidCookies }
        return data
    }

    private func validateAndPersist(_ account: SiteAccount, context: AccountHTTP.Context) async throws {
        do {
            let name = try await validatedName(account.sourceID, context: context)
            try Task.checkCancellation()
            if account.sourceID != "bangumi" {
                let cookies = (context.cookieStorage.cookies ?? []).filter { Self.belongs($0, to: account.sourceID) }
                try Self.store(cookies, accountID: account.id, service: keychainService)
            }
            var updated = account
            updated.status = .valid
            updated.displayName = name
            records[account.id] = updated
            if account.sourceID == "bangumi" { setDefaultID(account.id, "bangumi") }
            persist()
        } catch SiteAccountError.expired {
            try markExpired(accountID: account.id)
            throw SiteAccountError.expired
        }
    }

    private func validatedName(_ source: String, context: AccountHTTP.Context) async throws -> String {
        do {
            if source == "bangumi", let bangumiIdentityValidator {
                return try await bangumiIdentityValidator(context)
            }
            return try await readValidatedName(source, context: context)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? SiteAccountError { throw error }
            #if DEBUG
            if source == "douyu" {
                let failure = error as NSError
                let underlying = (error as? AFError)?.underlyingError as NSError?
                Log("[DouyuLogin] stage=userInfo.transport.failed domain=\(failure.domain) code=\(failure.code) underlyingDomain=\(underlying?.domain ?? "none") underlyingCode=\(underlying?.code ?? 0)")
            }
            #endif
            throw SiteAccountError.validationFailed
        }
    }

    static func checkBangumiIdentity(existing: SiteAccount?, userID: Int) throws {
        guard userID > 0 else { throw SiteAccountError.validationFailed }
        // Legacy profiles without a verified identity must sign out once before reauthorization.
        if let existing, existing.bangumiUserID != userID {
            throw SiteAccountError.bangumiIdentityChanged
        }
    }

    static func bangumiDisplayName(data: Data?, statusCode: Int?) throws -> String {
        if statusCode == 401 { throw SiteAccountError.expired }
        guard statusCode == 200, let data,
              let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let username = user["username"] as? String, !username.isEmpty else {
            throw SiteAccountError.validationFailed
        }
        if let nickname = user["nickname"] as? String, !nickname.isEmpty { return nickname }
        return username
    }
    private func readValidatedName(_ source: String, context: AccountHTTP.Context) async throws -> String {
        if source == "youtube" {
            return try await AccountHTTP.$context.withValue(context) {
                try await YouTubeBrowseService.shared.accountName()
            }
        }
        if source == "bangumi" {
            let response = await context.session.request(
                "https://api.bgm.tv/v0/me",
                headers: ["User-Agent": "IINA-ANI/1.0 (Bangumi metadata client)"],
                requestModifier: AccountHTTP.authorizationModifier(token: context.bearerToken)
            ).serializingData().response
            return try Self.bangumiDisplayName(data: response.data, statusCode: response.response?.statusCode)
        }
        if source == "bilibili" {
            let data = try await context.session.request("https://api.bilibili.com/x/web-interface/nav").serializingData().value
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["data"] as? [String: Any], let loggedIn = body["isLogin"] as? Bool else {
                throw SiteAccountError.validationFailed
            }
            guard loggedIn else { throw SiteAccountError.expired }
            guard let name = body["uname"] as? String, !name.isEmpty else { throw SiteAccountError.validationFailed }
            return name
        }
        guard source == "douyu" else { throw SiteAccountError.unsupportedLogin(source) }
        var url = URLComponents(string: "https://www.douyu.com/lapi/member/api/getInfo")!
        url.queryItems = [URLQueryItem(name: "client_type", value: "0"),
                         URLQueryItem(name: "d", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
        #if DEBUG
        Log("[DouyuLogin] stage=userInfo.request")
        #endif
        let response = await context.session.request(url.url!, headers: [
            "Referer": "https://www.douyu.com/",
            "User-Agent": Douyu.webUserAgent
        ]).serializingData().response
        #if DEBUG
        Log("[DouyuLogin] stage=userInfo.response http=\(response.response?.statusCode ?? -1)")
        #endif
        let data = try response.result.get()
        guard response.response?.statusCode == 200 else { throw SiteAccountError.validationFailed }
        let cookies = context.cookieStorage.cookies(for: URL(string: "https://www.douyu.com/")!) ?? []
        return try Self.douyuDisplayName(from: data, cookies: cookies)
    }

    /// Validate the main-site session against the server's UID, not a passport
    /// SSO exchange or the mere presence of cookies.
    static func douyuDisplayName(from data: Data, cookies: [HTTPCookie]) throws -> String {
        guard let response = try? JSONDecoder().decode(DouyuAccountResponse.self, from: data) else {
            #if DEBUG
            Log("[DouyuLogin] stage=userInfo.parse.failed")
            #endif
            throw SiteAccountError.validationFailed
        }
        #if DEBUG
        Log("[DouyuLogin] stage=userInfo.result error=\(response.error)")
        #endif
        if response.error == 1 { throw SiteAccountError.expired }
        guard response.error == 0, let uid = response.msg?.uid, uid > 0 else {
            throw SiteAccountError.validationFailed
        }
        let cookieUID = (cookies.first { $0.name == "acf_uid" }?.value).flatMap(Int64.init)
        #if DEBUG
        Log("[DouyuLogin] stage=identity.checked uidMatches=\(cookieUID == uid)")
        #endif
        guard cookieUID == uid else { throw SiteAccountError.validationFailed }
        if let name = cookies.first(where: { $0.name == "acf_nickname" })?.value.removingPercentEncoding,
           !name.isEmpty { return name }
        return String(uid)
    }

    private struct DouyuAccountResponse: Decodable {
        let error: Int
        let msg: Identity?
        struct Identity: Decodable { let uid: Int64 }
    }

    private static func belongs(_ cookie: HTTPCookie, to source: String) -> Bool {
        if source == "youtube" {
            let domain = cookie.domain.lowercased()
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            return YouTubeCookieImport.isYouTubeDomain(host) && cookie.isSecure
        }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let root = source == "bilibili" ? "bilibili.com" : source == "douyu" ? "douyu.com" : ""
        return !root.isEmpty && (domain == root || domain.hasSuffix("." + root))
    }
    private static func hasCredential(_ cookies: [HTTPCookie], source: String) -> Bool {
        if source == "youtube" { return YouTubeCookieImport.hasAuthenticationCookies(cookies) }
        return cookies.contains { !$0.value.isEmpty && (source == "bilibili" ? $0.name == "SESSDATA" : ["dy_auth", "acf_auth"].contains($0.name)) }
    }
    private static func makeContext(accountID: UUID?, source: String, cookies: [HTTPCookie], bearerToken: String? = nil) throws -> AccountHTTP.Context {
        let configuration = URLSessionConfiguration.ephemeral
        guard let jar = configuration.httpCookieStorage else { throw SiteAccountError.validationFailed }
        cookies.compactMap { StoredCookie($0).cookie() }.forEach(jar.setCookie)
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let redirector = Redirector.modify { _, request, response in
            var redirected = request
            if source == "youtube" {
                guard let target = redirected.url, target.scheme?.lowercased() == "https",
                      target.host?.lowercased() == "www.youtube.com",
                      target.port == nil || target.port == 443,
                      target.user == nil, target.password == nil else { return nil }
                redirected.setValue(nil, forHTTPHeaderField: "Cookie")
                let origin = response.url
                if origin?.scheme?.lowercased() != "https" ||
                    origin?.host?.lowercased() != "www.youtube.com" ||
                    (origin?.port != nil && origin?.port != 443) {
                    for header in ["Authorization", "X-Goog-AuthUser", "X-Goog-PageId", "X-Origin", "Origin"] {
                        redirected.setValue(nil, forHTTPHeaderField: header)
                    }
                }
            }
            if accountID != nil {
                guard redirected.url?.scheme?.lowercased() == "https" else { return nil }
                redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            }
            if bearerToken != nil, !AccountHTTP.isBangumiAPI(redirected.url) {
                redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            return redirected
        }
        return AccountHTTP.Context(accountID: accountID, sourceID: source,
                                   session: Session(configuration: configuration, redirectHandler: redirector), cookieStorage: jar, bearerToken: bearerToken)
    }

    private struct StoredCookie: Codable {
        let domain: String, path: String, name: String, value: String
        let version: Int
        let secure: Bool, httpOnly: Bool
        let expires: Date?
        init(_ cookie: HTTPCookie) {
            domain = cookie.domain; path = cookie.path; name = cookie.name; value = cookie.value
            version = cookie.version; secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly; expires = cookie.expiresDate
        }
        func cookie() -> HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name,
                                                           .value: value, .version: version, .secure: "TRUE"]
            if httpOnly { properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)
        }
    }
    private static func store(_ cookies: [HTTPCookie], accountID: UUID, service: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: accountID.uuidString]
        let data = try JSONEncoder().encode(cookies.map(StoredCookie.init))
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SiteAccountError.secureStorage(status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SiteAccountError.secureStorage(added) }
    }
    private static func storeSecret(_ data: Data, accountID: UUID, service: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: accountID.uuidString]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SiteAccountError.secureStorage(status) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SiteAccountError.secureStorage(added) }
    }
    private func deleteCredentials(_ id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keychainService, kSecAttrAccount as String: id.uuidString]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SiteAccountError.secureStorage(status) }
    }
}

enum AccountHTTP {
    struct Context: Sendable {
        let accountID: UUID?
        let sourceID: String
        let session: Session
        let cookieStorage: HTTPCookieStorage
        let bearerToken: String?
    }
    @TaskLocal static var context: Context?
    private static let anonymousSession: Session = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return Session(configuration: configuration)
    }()

    static func request(_ convertible: URLConvertible, method: HTTPMethod = .get,
                        parameters: Parameters? = nil, encoding: ParameterEncoding = URLEncoding.default,
                        headers: HTTPHeaders? = nil, interceptor: RequestInterceptor? = nil,
                        requestModifier: Session.RequestModifier? = nil) -> DataRequest {
        let token = context?.bearerToken
        let modifier: Session.RequestModifier?
        if token == nil {
            modifier = requestModifier
        } else {
            modifier = { request in
                try requestModifier?(&request)
                try authorizationModifier(token: token)(&request)
            }
        }
        return (context?.session ?? anonymousSession).request(convertible, method: method, parameters: parameters,
                                                              encoding: encoding, headers: headers, interceptor: interceptor,
                                                              requestModifier: modifier)
    }

    static func request(_ urlRequest: URLRequest, interceptor: RequestInterceptor? = nil,
                        requestModifier: Session.RequestModifier? = nil) -> DataRequest {
        let token = context?.bearerToken
        let target = urlRequest.url!
        return (context?.session ?? anonymousSession).request(target,
            method: HTTPMethod(rawValue: urlRequest.httpMethod ?? HTTPMethod.get.rawValue),
            interceptor: interceptor,
            requestModifier: { request in
                request = urlRequest
                try requestModifier?(&request)
                try authorizationModifier(token: token)(&request)
            })
    }

    static func isBangumiAPI(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "api.bgm.tv" &&
            (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    static func authorizationModifier(token: String?) -> Session.RequestModifier {
        { request in
            guard let token else { return }
            if isBangumiAPI(request.url) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else {
                request.setValue(nil, forHTTPHeaderField: "Authorization")
            }
        }
    }
    static func cookies(for url: URL) -> [HTTPCookie] { context?.cookieStorage.cookies(for: url) ?? [] }
}
