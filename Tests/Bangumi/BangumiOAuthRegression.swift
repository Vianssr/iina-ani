import Foundation
import Cocoa
import Security
import Alamofire
@testable import IINA_ANI

@main
enum BangumiOAuthRegression {
    static func main() async throws {
        _ = NSApplication.shared
        try callbacks()
        try await missingConfiguration()
        try await renewal()
    }

    private static func callbacks() throws {
        let attempt = BangumiOAuth.Attempt()
        let base = BangumiOAuth.redirectURI
        let callback = try attempt.callback(from: URL(string: base + "?code=fixture%2Bcode&state=" + attempt.state)!)
        try require(callback == BangumiOAuth.Callback(code: "fixture+code"), "only the native callback may yield an authorization code")
        for target in ["https://bgm.tv/login", "https://example.invalid/oauth", "iina-ani://bangumi.attacker.invalid/oauth", "iina-ani://bangumi/other"] {
            try require(try attempt.callback(from: URL(string: target + "?code=fixture&state=" + attempt.state)!) == nil, "foreign callback destinations must not initiate token exchange")
        }
        for query in ["code=fixture", "code=fixture&state=wrong", "code=fixture&state=\(attempt.state)&state=\(attempt.state)", "code=one&code=two&state=\(attempt.state)", "code=&state=\(attempt.state)", "code=fixture&state=\(attempt.state)#fragment", "code=fixture&state=\(attempt.state)&unexpected=1"] {
            do {
                _ = try attempt.callback(from: URL(string: base + "?" + query)!)
                throw Failure.assertion("malformed or foreign-state callbacks must not be accepted")
            } catch BangumiOAuth.Failure.invalidCallback {}
        }
        do {
            _ = try attempt.callback(from: URL(string: base + "?error=access_denied&state=" + attempt.state)!)
            throw Failure.assertion("denial must not become successful authorization")
        } catch BangumiOAuth.Failure.denied {}
        print("PASS: OAuth native callback allowlist, state binding, ambiguous callback rejection, and denial")
    }

    private static func missingConfiguration() async throws {
        for (id, secret) in [("", "fixture-secret"), ("fixture-client", " \n"),
                             ("$(BANGUMI_CLIENT_ID)", "fixture-secret"),
                             ("fixture-client", "$(BANGUMI_CLIENT_SECRET)")] {
            let oauth = BangumiOAuth(clientID: id, clientSecret: secret)
            do {
                _ = try await oauth.exchange(.init(code: "unused-code"))
                throw Failure.assertion("an unconfigured build must reject authorization before a network request")
            } catch BangumiOAuth.Failure.notConfigured {}
            do {
                _ = try await oauth.refresh(.init(accessToken: "old", refreshToken: "unused-refresh", expiresAt: .distantPast))
                throw Failure.assertion("an unconfigured build must not attempt renewal")
            } catch BangumiOAuth.Failure.notConfigured {}
        }
        print("PASS: missing and unresolved build credentials reject authorization and renewal")
    }

    private static func renewal() async throws {
        let suite = "iina-oauth-regression.\(UUID().uuidString)"
        let service = suite
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        defer { defaults.removePersistentDomain(forName: suite); SecItemDelete(query as CFDictionary) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TokenProtocol.self]
        let oauth = BangumiOAuth(session: Session(configuration: configuration, redirectHandler: Redirector(behavior: .doNotFollow)),
                                clientID: "fixture-client", clientSecret: "fixture-secret")
        let account = SiteAccount(id: UUID(), sourceID: "bangumi", displayName: "Pending", enabled: true, status: .needsLogin)
        let archived = SiteAccount(id: UUID(), sourceID: "bangumi", displayName: "Legacy unselected", enabled: true, status: .valid)
        defaults.set(try JSONEncoder().encode([account, archived]), forKey: "site-account-metadata-v1")
        preferences.setDefaultAccountID(account.id, for: "bangumi")
        let pool = SiteAccounts(preferences: preferences, keychainService: service,
                                bangumiIdentityValidator: { _ in "OAuth User" }, bangumiOAuth: oauth)
        try require(await pool.bangumiAccount()?.id == account.id, "single-account migration must honor the previously selected profile")
        let old = BangumiOAuth.Credentials(accessToken: "old-access", refreshToken: "old-refresh",
                                          expiresAt: Date(timeIntervalSince1970: 1))
        var item = query
        item[kSecAttrAccount as String] = account.id.uuidString
        item[kSecValueData as String] = try JSONEncoder().encode(old)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        try require(SecItemAdd(item as CFDictionary, nil) == errSecSuccess, "isolated expired credential setup failed")
        let archivedCredentials = BangumiOAuth.Credentials(accessToken: "archived-access", refreshToken: "archived-refresh", expiresAt: Date(timeIntervalSince1970: 1))
        item[kSecAttrAccount as String] = archived.id.uuidString
        item[kSecValueData as String] = try JSONEncoder().encode(archivedCredentials)
        try require(SecItemAdd(item as CFDictionary, nil) == errSecSuccess, "legacy credential setup failed")

        TokenProtocol.response.set(status: 503, body: "{}")
        do { _ = try await pool.refreshStatus(accountID: account.id); throw Failure.assertion("server failure must not renew authorization") }
        catch BangumiOAuth.Failure.exchangeFailed {}
        try require(try await pool.account(accountID: account.id).status == .needsLogin, "server failure must not falsely classify the credential as revoked")
        try require(try stored(account.id, service: service) == old, "failed renewal must preserve the previous refresh token")

        TokenProtocol.response.set(status: 400, body: "{\"error\":\"invalid_grant\"}")
        do { _ = try await pool.refreshStatus(accountID: account.id); throw Failure.assertion("revoked refresh credentials must not authorize an account") }
        catch SiteAccountError.expired {}
        try require(try await pool.account(accountID: account.id).status == .expired, "revoked refresh credentials must require reauthorization")
        try require(try stored(account.id, service: service) == old, "rejected renewal must not overwrite secure credentials")

        TokenProtocol.response.set(status: 200, body: "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"expires_in\":604800,\"token_type\":\"Bearer\"}")
        let renewed = try await pool.refreshStatus(accountID: account.id)
        let committed = try stored(account.id, service: service)
        try require(renewed.status == .valid && renewed.displayName == "OAuth User", "validated renewal must recover account state")
        try require(try await pool.defaultAccount(sourceID: "bangumi")?.id == account.id, "renewed authorization must automatically resume authenticated metadata requests")
        try require(committed.accessToken == "new-access" && committed.refreshToken == "new-refresh" && committed.expiresAt > Date(), "renewal must atomically retain both rotated tokens and their expiry")
        try require(!String(decoding: defaults.data(forKey: "site-account-metadata-v1")!, as: UTF8.self).contains("new-refresh"), "refresh credentials must not leak into ordinary account metadata")
        try await pool.signOut(accountID: account.id)
        do { _ = try stored(account.id, service: service); throw Failure.assertion("sign-out must remove the entire OAuth credential") }
        catch Failure.keychain(let status) { try require(status == errSecItemNotFound, "sign-out must remove both tokens") }
        try require(try stored(archived.id, service: service) == archivedCredentials, "migration and sign-out must not delete unselected legacy credentials")
        let restarted = SiteAccounts(preferences: preferences, keychainService: service)
        try require(await restarted.bangumiAccount() == nil, "restart after sign-out must not reactivate an unselected legacy profile")
        try require(try await restarted.defaultAccount(sourceID: "bangumi") == nil, "restart after sign-out must stay anonymous")
        print("PASS: single-account migration honors the selected identity without deleting or reactivating legacy credentials")
        print("PASS: OAuth renewal distinguishes server failures from revoked grants, preserves failed credentials, rotates both tokens, and signs out securely")
    }

    private static func stored(_ id: UUID, service: String) throws -> BangumiOAuth.Credentials {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        return try JSONDecoder().decode(BangumiOAuth.Credentials.self, from: result as! Data)
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }
    private enum Failure: Error { case assertion(String), keychain(OSStatus) }

    private final class TokenProtocol: URLProtocol, @unchecked Sendable {
        static let response = Response()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let (status, data) = Self.response.get()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    private final class Response: @unchecked Sendable {
        private let lock = NSLock()
        private var status = 500
        private var data = Data()
        func set(status: Int, body: String) { lock.lock(); defer { lock.unlock() }; self.status = status; data = Data(body.utf8) }
        func get() -> (Int, Data) { lock.lock(); defer { lock.unlock() }; return (status, data) }
    }
}
