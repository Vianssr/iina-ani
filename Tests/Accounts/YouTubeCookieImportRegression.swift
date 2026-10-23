import Foundation
import Cocoa
import Security
@testable import IINA_ANI

@main
enum YouTubeCookieImportRegression {
    private static let now = Date(timeIntervalSince1970: 1_600_000_000)
    private static let secret = "fixture-private-cookie-value"

    static func main() async throws {
        _ = NSApplication.shared
        do { try domainBoundaries() }
        catch { throw Failure.assertion("Domain boundaries: \(error)") }
        do { try expiryAndSessionCookies() }
        catch { throw Failure.assertion("Expiry and sessions: \(error)") }
        do { try malformedExports() }
        catch { throw Failure.assertion("Malformed exports: \(error)") }
        do { try await accountMutationBoundaries() }
        catch { throw Failure.assertion("Account mutations: \(error)") }
        print("PASS: YouTube cookie domain, expiry, HttpOnly/session, malformed export, credential privacy, account lease and sign-out boundaries")
    }

    private static func domainBoundaries() throws {
        let foreign = [".google.com", ".youtube.com.evil.invalid", ".notyoutube.com", ".youtube.invalid"]
        let export = authenticated() + foreign.map { line(domain: $0, name: "foreign") }.joined()
            + line(domain: ".studio.youtube.com", name: "studio")
            + line(domain: "www.youtube.com", subdomains: "FALSE", name: "hostOnly")
        let cookies = try parse(export)
        try require(cookies.count == 4, "only YouTube and genuine subdomain cookies may be retained")
        try require(cookies.allSatisfy { !$0.name.contains("foreign") && $0.isSecure }, "Google-wide or lookalike cookies must never enter the account jar")
        for domain in foreign {
            try rejects(authenticated(domain: domain), "foreign-only export must be rejected")
        }
        try rejects(authenticated(domain: ".studio.youtube.com"), "cookies for an unrelated YouTube subdomain cannot authenticate www.youtube.com")
        try rejects(authenticated(domain: "youtube.com", subdomains: "FALSE"), "host-only apex cookies cannot authenticate www.youtube.com")
        try rejects(authenticated(domain: "..youtube.com"), "invalid domain labels must not bypass the suffix boundary")
        try rejects(authenticated(domain: ".youtube.com", subdomains: "FALSE"), "host-only flags must not silently widen cookie scope")
        try rejects(authenticated(secure: "FALSE"), "insecure cookies must not be silently promoted to secure credentials")
        try rejects(authenticated(path: "/private"), "path-restricted cookies cannot authenticate the home page")
    }

    private static func expiryAndSessionCookies() throws {
        let cookies = try parse("# Netscape HTTP Cookie File\r\n" + authenticated(expiry: "0", httpOnly: true)
            + line(name: "session-minus-one", expiry: "-1")
            + line(name: "expired-preference", expiry: "1599999999")
            + line(name: "future-preference", expiry: "1600000100"))
        try require(cookies.count == 4, "expired optional cookies must be omitted")
        try require(cookies.first { $0.name == "SAPISID" }?.isHTTPOnly == true, "#HttpOnly_ must be parsed as a cookie prefix, not a comment")
        try require(cookies.first { $0.name == "SAPISID" }?.expiresDate == nil, "zero expiry must remain a session cookie")
        try require(cookies.first { $0.name == "session-minus-one" }?.expiresDate == nil, "minus-one expiry must remain a session cookie")
        try require(cookies.first { $0.name == "future-preference" }?.expiresDate == Date(timeIntervalSince1970: 1_600_000_100), "persistent expiry must be preserved")
        try rejects(authenticated(expiry: "1599999999"), "expired credentials must be rejected")
        try rejects(authenticated(expiry: "1600000000"), "credentials expiring exactly now must be rejected")
        try rejects(line(name: "SAPISID"), "signing cookies without a session identity cannot authenticate")
        try rejects(line(name: "SID"), "session identity without a signing cookie cannot authenticate")
        try rejects(line(name: "PREF"), "preference-only exports cannot authenticate")
        try rejects(line(name: "SAPISID", value: "") + line(name: "SID"), "empty signing credentials cannot authenticate")
        let secureNames = line(name: "__Secure-3PAPISID") + line(name: "__Secure-3PSID")
        try require(try parse(secureNames).count == 2, "secure third-party authentication pairs must be accepted for server validation")
        let withInsecurePreference = try parse(secureNames + line(secure: "FALSE", name: "PREF"))
        try require(withInsecurePreference.map(\.name) == ["__Secure-3PAPISID", "__Secure-3PSID"],
                    "an insecure preference must not reject or weaken a secure login export")
    }

    private static func malformedExports() throws {
        for text in [
            "", "# comments only\n", "youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\n",
            authenticated() + line(name: "extra").replacingOccurrences(of: "\n", with: "\textra\n"),
            authenticated(expiry: "not-a-number"), authenticated(expiry: "-2"),
            authenticated(expiry: "9999999999999999999999999999"),
            authenticated(subdomains: "true"), authenticated(secure: "true"),
            authenticated(path: "relative"), authenticated(path: "/bad\u{0000}path"),
            line(name: "bad name") + authenticated(),
            line(name: "bad;name") + authenticated(),
            line(name: "value", value: "private;injection") + authenticated(),
            line(name: "value", value: "private\u{0000}injection") + authenticated(),
            line(path: "/", name: "__Host-test") + authenticated()
        ] {
            try rejects(text, "malformed Netscape records must be rejected without disclosing content")
        }
        try rejects(Data([0xff, 0xfe, 0xfd]), "non-UTF-8 exports must be rejected")
        let oversized = Data(repeating: 65, count: YouTubeCookieImport.maximumFileSize + 1)
        try rejects(oversized, "oversized exports must be rejected before parsing")
        let comments = Data(("#" + String(repeating: "a", count: YouTubeCookieImport.maximumFileSize - 1)).utf8)
        try rejects(comments, "a maximum-sized file without credentials must remain invalid")
    }

    private static func accountMutationBoundaries() async throws {
        let suite = "youtube-import-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        let account = SiteAccount(id: UUID(), sourceID: "youtube", displayName: "Existing YouTube",
                                  enabled: true, status: .valid)
        let other = SiteAccount(id: UUID(), sourceID: "bilibili", displayName: "Unrelated",
                                enabled: true, status: .valid)
        let original = Data(secret.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: suite, kSecAttrAccount as String: account.id.uuidString]
        defer {
            defaults.removePersistentDomain(forName: suite)
            SecItemDelete(query as CFDictionary)
        }
        var item = query
        item[kSecValueData as String] = original
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.assertion("fixture Keychain storage is unavailable") }
        defaults.set(try JSONEncoder().encode([account, other]), forKey: "site-account-metadata-v1")
        preferences.setDefaultAccountID(account.id, for: "youtube")
        preferences.setDefaultAccountID(other.id, for: "bilibili")
        let accounts = SiteAccounts(preferences: preferences, keychainService: suite)
        do {
            _ = try await accounts.importYouTubeCookies(Data(secret.utf8))
            throw Failure.assertion("malformed reimport must fail")
        } catch SiteAccountError.invalidCookies {}
        try require(try await accounts.account(accountID: account.id) == account, "failed import must preserve prior valid account metadata")
        try require(try await accounts.defaultAccount(sourceID: "youtube")?.id == account.id, "failed import must preserve the selected account")
        var readQuery = query
        readQuery[kSecReturnData as String] = true
        var result: CFTypeRef?
        try require(SecItemCopyMatching(readQuery as CFDictionary, &result) == errSecSuccess && result as? Data == original,
                    "failed import must leave the existing Keychain secret untouched")
        let lease = try await accounts.acquireUse(accountID: account.id, sourceID: "youtube")
        do {
            _ = try await accounts.importYouTubeCookies(Data(authenticated(expiry: "4102444800").utf8))
            throw Failure.assertion("an active account cannot have its cookies replaced")
        } catch SiteAccountError.accountInUse {}
        do {
            try await accounts.signOut(accountID: account.id)
            throw Failure.assertion("an active account cannot be signed out")
        } catch SiteAccountError.accountInUse {}
        await accounts.releaseUse(lease)
        preferences.setSourceEnabled(false, sourceID: "youtube")
        do {
            _ = try await accounts.importYouTubeCookies(Data(authenticated(expiry: "4102444800").utf8))
            throw Failure.assertion("a disabled source cannot import credentials")
        } catch SiteAccountError.disabled {}
        preferences.setSourceEnabled(true, sourceID: "youtube")
        try await accounts.signOut(accountID: account.id)
        try require(try await accounts.defaultAccount(sourceID: "youtube") == nil, "sign-out must clear the YouTube default")
        try require(SecItemCopyMatching(readQuery as CFDictionary, &result) == errSecItemNotFound, "sign-out must remove the Keychain secret")
        try require(try await accounts.defaultAccount(sourceID: "bilibili")?.id == other.id, "YouTube sign-out must preserve the other source selection")
        try await accounts.remove(accountID: account.id)
        try require(try await accounts.accounts(sourceID: "youtube").isEmpty, "YouTube account removal must persist")
        let added = try await accounts.add(sourceID: "youtube", displayName: "YouTube")
        try require(added.status == .needsLogin, "adding a profile must not invent a validated login")
        let metadata = String(decoding: defaults.data(forKey: "site-account-metadata-v1")!, as: UTF8.self)
        try require(!metadata.contains(secret), "cookie credentials must never be written into preferences")
    }

    private static func authenticated(domain: String = ".youtube.com", subdomains: String = "TRUE",
                                      path: String = "/", secure: String = "TRUE", expiry: String = "4102444800",
                                      httpOnly: Bool = false) -> String {
        line(domain: domain, subdomains: subdomains, path: path, secure: secure, name: "SAPISID", expiry: expiry, httpOnly: httpOnly)
            + line(domain: domain, subdomains: subdomains, path: path, secure: secure, name: "SID", expiry: expiry, httpOnly: httpOnly)
    }

    private static func line(domain: String = ".youtube.com", subdomains: String = "TRUE", path: String = "/",
                             secure: String = "TRUE", name: String, value: String = secret,
                             expiry: String = "4102444800", httpOnly: Bool = false) -> String {
        (httpOnly ? "#HttpOnly_" : "") + [domain, subdomains, path, secure, expiry, name, value].joined(separator: "\t") + "\n"
    }

    private static func parse(_ text: String) throws -> [HTTPCookie] {
        try YouTubeCookieImport.parse(Data(text.utf8), now: now)
    }

    private static func rejects(_ text: String, _ message: String) throws {
        try rejects(Data(text.utf8), message)
    }

    private static func rejects(_ data: Data, _ message: String) throws {
        do {
            _ = try YouTubeCookieImport.parse(data, now: now)
            throw Failure.assertion(message)
        } catch SiteAccountError.invalidCookies {
            let error = SiteAccountError.invalidCookies
            try require(!error.localizedDescription.contains(secret) && !String(describing: error).contains(secret),
                        "parser errors must never contain credential values")
        }
    }

    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }

    private enum Failure: Error { case assertion(String) }
}
