import Foundation
import Cocoa
import Security
@testable import IINA_ANI

@main
enum SiteAccountsRegression {
    static func main() async throws {
        _ = NSApplication.shared
        try douyuIdentityValidation()
        try bangumiHTTPBoundaries()
        let suite = "iina-account-regression.\(UUID().uuidString)"
        let service = "iina-account-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        defer { defaults.removePersistentDomain(forName: suite); SecItemDelete(query as CFDictionary) }
        let jar = URLSessionConfiguration.ephemeral.httpCookieStorage!
        let unrelated = cookie("keep", domain: ".example.invalid", name: "unrelated")
        jar.setCookie(unrelated)
        jar.setCookie(cookie("fixture-A"))
        let first = manager(service, preferences, legacy: jar)
        let a = try await first.accounts(sourceID: "bilibili").first!
        try require(a.status == .needsLogin, "migration must not invent a validated login")
        try require(jar.cookies?.contains(where: { $0.name == "SESSDATA" }) != true, "migration must remove only securely copied legacy cookies")
        try require(jar.cookies?.contains(where: { $0.name == "unrelated" }) == true, "migration must preserve other sites")
        try require(try secret(a.id, service: service).contains("fixture-A"), "the Keychain copy must survive migration")
        let restarted = manager(service, preferences, legacy: jar)
        try require(try await restarted.accounts(sourceID: "bilibili").map(\.id) == [a.id], "restart must not duplicate a migrated account")

        defaults.removeObject(forKey: "site-account-legacy-migrated.bilibili")
        jar.setCookie(cookie("fixture-B"))
        let importedSecond = manager(service, preferences, legacy: jar)
        let b = try await importedSecond.accounts(sourceID: "bilibili").first(where: { $0.id != a.id })!
        try require(try await importedSecond.defaultAccount(sourceID: "bilibili")?.id == a.id, "import must not silently change the selected account")
        try require(try secret(a.id, service: service).contains("fixture-A") && secret(b.id, service: service).contains("fixture-B"), "same-site secrets must remain isolated by account")
        let persisted = defaults.data(forKey: "site-account-metadata-v1")!
        try require(!String(decoding: persisted, as: UTF8.self).contains("fixture-"), "general preferences must not contain credentials")

        // Fixtures exercise the W6 lease contract, not successful remote login.
        var fixtures = try JSONDecoder().decode([SiteAccount].self, from: persisted)
        for index in fixtures.indices { fixtures[index].status = .valid }
        defaults.set(try JSONEncoder().encode(fixtures), forKey: "site-account-metadata-v1")
        let pool = manager(service, preferences)
        let lease1 = try await pool.acquireUse(accountID: a.id, sourceID: "bilibili")
        let lease2 = try await pool.acquireUse(accountID: a.id, sourceID: "bilibili-live")
        await pool.releaseUse(lease1)
        await pool.releaseUse(lease1)
        do { try await pool.remove(accountID: a.id); throw Failure.assertion("double release must not release another user's lease") }
        catch SiteAccountError.accountInUse {}
        do { try await pool.setEnabled(accountID: a.id, enabled: false); throw Failure.assertion("active identity must not be disabled") }
        catch SiteAccountError.accountInUse {}
        do { try await pool.signOut(accountID: a.id); throw Failure.assertion("active identity must not lose its credentials") }
        catch SiteAccountError.accountInUse {}
        try await pool.signOut(accountID: b.id)
        try require(try await pool.account(accountID: b.id).status == .needsLogin, "sign-out must require reauthorization")
        do {
            _ = try secret(b.id, service: service)
            throw Failure.assertion("sign-out must delete this account's credential")
        } catch Failure.keychain(let status) {
            try require(status == errSecItemNotFound, "sign-out must remove exactly the selected credential")
        }
        try await pool.remove(accountID: b.id)
        try require(try secret(a.id, service: service).contains("fixture-A"), "removing the other account must preserve this account's credentials")
        await pool.releaseUse(lease2)
        try await pool.setEnabled(accountID: a.id, enabled: false)
        do { _ = try await pool.acquireUse(accountID: a.id, sourceID: "bilibili"); throw Failure.assertion("disabled account must be refused") }
        catch SiteAccountError.disabled {}
        try await pool.setEnabled(accountID: a.id, enabled: true)
        try require(try await pool.defaultAccount(sourceID: "bilibili-live")?.id == a.id, "existing Bili login must apply to live unless overridden")
        do { try await pool.setDefault(accountID: a.id, sourceID: "douyu"); throw Failure.assertion("cross-site identity must be refused") }
        catch SiteAccountError.invalidAccount {}

        let decoder = VideoDecoder(registry: SourceRegistry(), accounts: pool, sourceEnabled: { preferences.isSourceEnabled($0) }, localEndpoint: { throw VideoGetError.notSupported })
        let publicPage = "https://www.bilibili.com/video/BV1xx411c7mD?p=2"
        let ordinary = try await decoder.selection(for: publicPage)
        let guest = try await decoder.guestSelection(for: publicPage)
        try require(ordinary.accountID == a.id && guest.accountID == nil && guest.item == ordinary.item, "guest resolution must retain exact part identity without selecting the global default account")
        try await pool.withSource(sourceID: "bilibili", useDefaultAccount: false) {
            let context = AccountHTTP.context!
            let inherited = AccountHTTP.Context(accountID: a.id, sourceID: context.sourceID, session: context.session, cookieStorage: context.cookieStorage, bearerToken: "fixture-inherited-token")
            try await AccountHTTP.$context.withValue(inherited) {
                let nestedGuest = try await decoder.guestSelection(for: publicPage)
                try require(nestedGuest.accountID == nil && AccountHTTP.context?.accountID == a.id, "guest lookup must clear inherited authenticated context without mutating its caller")
            }
        }
        preferences.setDefaultAccountID(UUID(), for: "bilibili")
        do { _ = try await decoder.selection(for: publicPage); throw Failure.assertion("ordinary selection must not hide a removed default account") }
        catch SiteAccountError.invalidAccount {}
        let withoutInvalidDefault = try await decoder.guestSelection(for: publicPage)
        try require(withoutInvalidDefault.accountID == nil && withoutInvalidDefault.item == guest.item, "a removed global account must not block the guest path")
        try await pool.setDefault(accountID: nil, sourceID: "bilibili")
        try await pool.withSource(sourceID: "bilibili") {
            guard let context = AccountHTTP.context else { throw Failure.assertion("guest scope must have an isolated session") }
            context.cookieStorage.setCookie(cookie("guest-one", name: "scope"))
            try await pool.setDefault(accountID: a.id, sourceID: "bilibili")
            preferences.setSourceEnabled(false, sourceID: "bilibili")
            try await pool.withSource(sourceID: "bilibili") {
                try require(AccountHTTP.context?.accountID == nil, "changing the default must not switch an active guest identity")
                try require(AccountHTTP.cookies(for: URL(string: "https://www.bilibili.com/")!).first(where: { $0.name == "scope" })?.value == "guest-one", "nested requests must use the same isolated jar")
            }
        }
        do { try await pool.withSource(sourceID: "bilibili") {}; throw Failure.assertion("source disablement must stop new operations") }
        catch SiteAccountError.disabled {}
        preferences.setSourceEnabled(true, sourceID: "bilibili")
        try await pool.withSource(sourceID: "bilibili", useDefaultAccount: false) {
            try require(AccountHTTP.context?.accountID == nil, "a captured guest choice must not adopt the new default")
            try require(!AccountHTTP.cookies(for: URL(string: "https://www.bilibili.com/")!).contains(where: { $0.name == "scope" }), "separate operation containers must not share cookies")
        }
        try await pool.remove(accountID: a.id)
        try require(try await pool.defaultAccount(sourceID: "bilibili") == nil, "removal must clear stale default references")
        try require(try await manager(service, preferences).accounts(sourceID: "bilibili").isEmpty, "account deletion must persist")
        let validatingPool = SiteAccounts(preferences: preferences, keychainService: service, bangumiIdentityValidator: { context in
            guard let supplied = context.bearerToken, supplied.hasPrefix("fixture-valid-") else { throw SiteAccountError.expired }
            return "Fixture Bangumi User"
        })
        do { _ = try await validatingPool.add(sourceID: "bangumi", displayName: "Extra"); throw Failure.assertion("Bangumi must not accept a second account through the site pool") }
        catch SiteAccountError.unsupportedLogin {}
        let pendingID = UUID(uuidString: defaults.string(forKey: "bangumi-account-id")!)!
        do { _ = try await validatingPool.completeBangumiLogin(credentials: credentials("rejected-token")); throw Failure.assertion("rejected OAuth credentials must not be committed") }
        catch SiteAccountError.expired {}
        try require(await validatingPool.bangumiAccount() == nil, "rejected login must not create a signed-in profile")
        do { _ = try secret(pendingID, service: service); throw Failure.assertion("rejected OAuth credentials must leave Keychain untouched") }
        catch Failure.keychain(let status) { try require(status == errSecItemNotFound, "rejected OAuth credentials must not create a Keychain item") }
        let reauthAccount = try await validatingPool.completeBangumiLogin(credentials: credentials("fixture-valid-first"))
        try require(try storedCredentials(reauthAccount.id, service: service) == credentials("fixture-valid-first"), "validated OAuth credentials must be committed to Keychain")
        try require(try await validatingPool.accounts(sourceID: "bilibili").allSatisfy { $0.id != reauthAccount.id }, "Bangumi identity must remain separate from Bilibili playback")
        let reauthLease = try await validatingPool.acquireUse(accountID: reauthAccount.id, sourceID: "bangumi")
        do { _ = try await validatingPool.completeBangumiLogin(credentials: credentials("fixture-valid-second")); throw Failure.assertion("reauthorization must respect an active account lease") }
        catch SiteAccountError.accountInUse {}
        do { try await validatingPool.signOut(accountID: reauthAccount.id); throw Failure.assertion("an active Bangumi account must not be signed out") }
        catch SiteAccountError.accountInUse {}
        await validatingPool.releaseUse(reauthLease)
        do { _ = try await validatingPool.completeBangumiLogin(credentials: credentials("rejected-token")); throw Failure.assertion("failed reauthorization must not replace the existing OAuth credentials") }
        catch SiteAccountError.expired {}
        try require(try storedCredentials(reauthAccount.id, service: service) == credentials("fixture-valid-first"), "failed reauthorization must preserve the prior credential")
        let reauthorized = try await validatingPool.completeBangumiLogin(credentials: credentials("fixture-valid-second"))
        try require(reauthorized.id == reauthAccount.id && reauthorized.status == .valid && reauthorized.displayName == "Fixture Bangumi User", "reauthorization must update the same single profile")
        try require(try storedCredentials(reauthAccount.id, service: service) == credentials("fixture-valid-second"), "reauthorization must replace both secure OAuth tokens")
        var verified = reauthorized
        verified.bangumiUserID = 101
        try SiteAccounts.checkBangumiIdentity(existing: verified, userID: 101)
        try SiteAccounts.checkBangumiIdentity(existing: nil, userID: 202)
        for old in [verified, reauthorized] {
            do {
                try SiteAccounts.checkBangumiIdentity(existing: old, userID: 202)
                throw Failure.assertion("different or unverified remote identities must not reuse a Bangumi profile's pending commands/cache")
            } catch SiteAccountError.bangumiIdentityChanged {}
        }
        try require(await manager(service, preferences).bangumiAccount()?.id == reauthAccount.id, "the single profile must survive service restart")
        try require(try await validatingPool.defaultAccount(sourceID: "bangumi")?.id == reauthAccount.id, "metadata requests must automatically use the signed-in account")
        let bangumiMetadata = String(decoding: defaults.data(forKey: "site-account-metadata-v1")!, as: UTF8.self)
        try require(!bangumiMetadata.contains("fixture-valid-"), "validated Bangumi credentials remain absent from preferences")
        try await validatingPool.signOut(accountID: reauthAccount.id)
        let signedOutProfile = await validatingPool.bangumiAccount()
        let restartedSignedOutProfile = await manager(service, preferences).bangumiAccount()
        try require(signedOutProfile == nil && restartedSignedOutProfile == nil, "sign-out must leave no signed-in profile after restart")
        try require(try await validatingPool.defaultAccount(sourceID: "bangumi") == nil, "sign-out must restore anonymous metadata access")
        do { _ = try secret(reauthAccount.id, service: service); throw Failure.assertion("sign-out must remove both OAuth tokens") }
        catch Failure.keychain(let status) { try require(status == errSecItemNotFound, "sign-out must delete the OAuth credential") }
        let nextAccount = try await validatingPool.completeBangumiLogin(credentials: credentials("fixture-valid-next"))
        try require(nextAccount.id != reauthAccount.id, "a new login after sign-out must not reuse the previous identity's private metadata cache")
        try await validatingPool.signOut(accountID: nextAccount.id)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let cancelPool = SiteAccounts(preferences: preferences, keychainService: service, bangumiIdentityValidator: { _ in
            signal.yield(())
            signal.finish()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "Validation must not commit after cancellation"
        })
        let cancelledID = UUID(uuidString: defaults.string(forKey: "bangumi-account-id")!)!
        let authorization = Task { try await cancelPool.completeBangumiLogin(credentials: credentials("cancelled-fixture")) }
        for await _ in started { break }
        authorization.cancel()
        do { _ = try await authorization.value; throw Failure.assertion("cancelled authorization must not commit") }
        catch is CancellationError {}
        try require(await cancelPool.bangumiAccount() == nil, "cancellation must not create a signed-in profile")
        try require(try await cancelPool.defaultAccount(sourceID: "bangumi") == nil, "cancellation must not replace anonymous metadata access")
        do { _ = try secret(cancelledID, service: service); throw Failure.assertion("cancelled authorization stored OAuth credentials") }
        catch Failure.keychain(let status) { try require(status == errSecItemNotFound, "cancelled authorization must leave Keychain empty") }
        print("PASS: single Bangumi profile, rejection, reauthorization preservation/replacement, lease, persistence, sign-out cache isolation, and cancellation")
    }

    private static func bangumiHTTPBoundaries() throws {
        try require(AccountHTTP.isBangumiAPI(URL(string: "https://api.bgm.tv/v0/me")), "only the exact HTTPS Bangumi API host may receive the PAT")
        for raw in ["http://api.bgm.tv/v0/me", "https://www.bgm.tv/v0/me", "https://api.bgm.tv.attacker.invalid/v0/me"] {
            try require(!AccountHTTP.isBangumiAPI(URL(string: raw)), "PAT must not be accepted for non-API or downgraded URLs")
        }
        let modifier = AccountHTTP.authorizationModifier(token: "fixture-secret")
        var allowed = URLRequest(url: URL(string: "https://api.bgm.tv/v0/me")!)
        try modifier(&allowed)
        try require(allowed.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret", "Bangumi requests must use the Bearer scheme")
        var otherHost = URLRequest(url: URL(string: "https://example.invalid/")!)
        otherHost.setValue("Bearer fixture-secret", forHTTPHeaderField: "Authorization")
        try modifier(&otherHost)
        try require(otherHost.value(forHTTPHeaderField: "Authorization") == nil, "the request modifier boundary must strip caller-supplied authorization off-host")
        try require(try SiteAccounts.bangumiDisplayName(data: Data("{\"username\":\"bg-user\",\"nickname\":\"Bangumi Name\"}".utf8), statusCode: 200) == "Bangumi Name", "validated Bangumi identity should prefer nickname")
        try require(try SiteAccounts.bangumiDisplayName(data: Data("{\"username\":\"bg-user\"}".utf8), statusCode: 200) == "bg-user", "Bangumi identity should fall back to username")
        do { _ = try SiteAccounts.bangumiDisplayName(data: nil, statusCode: 401); throw Failure.assertion("401 must mark a PAT as expired") }
        catch SiteAccountError.expired {}
        let failureStatuses: [Int?] = [nil, 403, 500]
        for status in failureStatuses {
            do { _ = try SiteAccounts.bangumiDisplayName(data: nil, statusCode: status); throw Failure.assertion("transport and non-auth server failures must not be treated as expired credentials") }
            catch SiteAccountError.validationFailed {}
        }
        do { _ = try SiteAccounts.bangumiDisplayName(data: Data("{}".utf8), statusCode: 200); throw Failure.assertion("an identity-free response must not authorize an account") }
        catch SiteAccountError.validationFailed {}
        print("PASS: Bangumi token host allowlist, header stripping, identity validation, and 401-vs-failure distinction")
    }
    private static func douyuIdentityValidation() throws {
        let uid = cookie("17", domain: ".douyu.com", name: "acf_uid")
        let nickname = cookie("%E6%B8%AC%E8%A9%A6", domain: ".douyu.com", name: "acf_nickname")
        func name(_ body: String, cookies: [HTTPCookie] = [uid, nickname]) throws -> String {
            try SiteAccounts.douyuDisplayName(from: Data(body.utf8), cookies: cookies)
        }
        let valid = "{\"error\":0,\"msg\":{\"uid\":17}}"
        try require(try name(valid) == "測試", "only a matching server identity may supply the decoded account name")
        try require(try name(valid, cookies: [uid]) == "17", "missing nickname must fall back to the validated server UID")
        for body in [
            "{\"error\":0,\"msg\":{\"uid\":18}}",
            "{\"error\":0,\"msg\":{\"uid\":0}}",
            "{\"error\":0,\"msg\":{\"uid\":true}}",
            "{\"error\":0,\"msg\":{}}",
            "{\"error\":3,\"msg\":{\"uid\":17}}",
            "<html>blocked</html>"
        ] {
            do { _ = try name(body); throw Failure.assertion("rejected or inconsistent server identity must not authorize an account") }
            catch SiteAccountError.validationFailed {}
        }
        do { _ = try name(valid, cookies: []); throw Failure.assertion("a server identity must match the identity selected by the login container") }
        catch SiteAccountError.validationFailed {}
        do { _ = try name("{\"error\":1,\"msg\":{\"uid\":0}}"); throw Failure.assertion("explicit guest response must expire the session") }
        catch SiteAccountError.expired {}
        print("PASS: Douyu server identity matching, nickname/UID display, guest expiry, and malformed/rejected identity boundaries")
    }

    private static func manager(_ service: String, _ preferences: Preferences,
                                legacy: HTTPCookieStorage? = nil) -> SiteAccounts {
        SiteAccounts(preferences: preferences, keychainService: service, legacyCookieStorage: legacy)
    }
    private static func cookie(_ value: String, domain: String = ".bilibili.com", name: String = "SESSDATA") -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: value, .secure: "TRUE"])!
    }
    private static func credentials(_ token: String) -> BangumiOAuth.Credentials {
        BangumiOAuth.Credentials(accessToken: token, refreshToken: token + "-refresh",
                                 expiresAt: Date(timeIntervalSince1970: 4_102_444_800))
    }
    private static func storedCredentials(_ id: UUID, service: String) throws -> BangumiOAuth.Credentials {
        try JSONDecoder().decode(BangumiOAuth.Credentials.self, from: Data(secret(id, service: service).utf8))
    }
    private static func secret(_ id: UUID, service: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let data = result as? Data else { throw Failure.assertion("fixture credential has invalid data") }
        return String(decoding: data, as: UTF8.self)
    }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }
    private enum Failure: Error { case assertion(String), keychain(OSStatus) }
}
