import Foundation
import SQLite3
import CryptoSwift
@testable import IINA_ANI

/// Standalone regression executable. Every production I/O call receives a
/// temporary synthetic home and an injected key provider: never a real browser
/// store, real Chrome Safe Storage item, or system authentication prompt.
@main
enum YouTubeBrowserCookiesRegression {
    private static let now = Date(timeIntervalSince1970: 1_600_000_000)
    private static let password = Data("synthetic-browser-password".utf8)
    private static let secret = "synthetic-cookie-do-not-report"
    private static let profile = YouTubeBrowserProfile(browser: .chrome, id: "Default", name: "Default")
    private static let safari = YouTubeBrowserProfile(browser: .safari, id: "default", name: "Default")

    static func main() async throws {
        try cryptoReferenceVector()
        try withHome { try chromeRoundTrip($0) }
        try withHome { try chromeFailures($0) }
        try withHome { try safariRoundTrip($0) }
        try withHome { try safariMalformedFiles($0) }
        try withHome { try profileBoundaries($0) }
        try await cancellation()
        try safeErrors()
        print("PASS: synthetic Chrome v10/schema24, Safari binarycookies, domain isolation, profiles, expiry, flags, dedupe, corruption, denied keys and cancellation")
    }

    private static func cryptoReferenceVector() throws {
        // Public upstream yt-dlp/test/test_cookies.py Mac v10 known-answer vector,
        // independent of the fixture encoder below (no real browser credentials).
        let knownPassword = Array("6eIDUdtKAacvlHwBVwvg/Q==".utf8)
        let key = try deriveKey(Data(knownPassword))
        let ciphertext = Data([0x76, 0x31, 0x30, 0xb3, 0xbe, 0xad, 0xa1, 0x5b, 0x9f, 0x43, 0xa1,
                               0x98, 0xe0, 0x9a, 0x01, 0xd9, 0xcf, 0xbf, 0x63])
        try require(try YouTubeBrowserCookies.decryptChrome(ciphertext, host: ".youtube.com", schemaVersion: 23, key: key)
                    == "2021-06-01-22", "Chrome v10 must match the upstream known-answer vector")
        let abc = try deriveKey(Data("abc".utf8))
        try require(abc == [0x59, 0xe2, 0xc0, 0xd0, 0x50, 0xf6, 0xf4, 0xe1,
                            0x6c, 0xc1, 0x8c, 0x51, 0xcb, 0x7c, 0xcd, 0x59], "PBKDF2 must use macOS Chrome's 1003/SHA1 parameters")
        let bound = try encrypt(secret, host: ".youtube.com", schema: 24)
        try require(try YouTubeBrowserCookies.decryptChrome(bound, host: ".youtube.com", schemaVersion: 24,
                                                           key: deriveKey(password)) == secret,
                    "schema24 must strip and verify the complete host SHA256 prefix")
        try rejects(.malformedStorage) {
            _ = try YouTubeBrowserCookies.decryptChrome(bound, host: "www.youtube.com", schemaVersion: 24, key: deriveKey(password))
        }
        try rejects(.unsupportedStorage) {
            _ = try YouTubeBrowserCookies.decryptChrome(Data("v20unsupported".utf8), host: ".youtube.com", schemaVersion: 24, key: key)
        }
        try rejects(.malformedStorage) {
            _ = try YouTubeBrowserCookies.decryptChrome(Data("v10short".utf8), host: ".youtube.com", schemaVersion: 24, key: key)
        }
        // AES with no padding encodes a deliberately invalid PKCS#7 suffix.
        let invalidPadding = try AES(key: deriveKey(password), blockMode: CBC(iv: [UInt8](repeating: 32, count: 16)), padding: .noPadding)
            .encrypt([UInt8](repeating: 0, count: 16))
        try rejects(.malformedStorage) {
            _ = try YouTubeBrowserCookies.decryptChrome(Data([0x76, 0x31, 0x30] + invalidPadding), host: ".youtube.com",
                                                       schemaVersion: 23, key: deriveKey(password))
        }
    }

    private static func chromeRoundTrip(_ home: URL) throws {
        var rows = try authentication(schema: 24)
        rows += [ChromeRow(name: "PREF", value: "older", creation: 1),
                 ChromeRow(name: "PREF", value: "newer", creation: 2),
                 ChromeRow(domain: "www.youtube.com", name: "host-only", value: secret),
                 ChromeRow(domain: ".studio.youtube.com", name: "subdomain", value: secret),
                 ChromeRow(name: "expired", encrypted: Data("v20must-not-decrypt".utf8), expiry: windowsTime(now.timeIntervalSince1970 - 1)),
                 ChromeRow(name: "insecure", encrypted: Data("v20must-not-decrypt".utf8), secure: false)]
        // Unsupported foreign payloads prove filtering occurs before decryption
        // and key acquisition, not merely after importing an all-domain jar.
        for domain in [".google.com", ".notyoutube.com", ".youtube.com.evil.invalid", ".youtube.invalid"] {
            rows.append(ChromeRow(domain: domain, name: "foreign", encrypted: Data("v20must-not-decrypt".utf8)))
        }
        let file = try makeChrome(home, rows: rows)
        try withDatabase(file) { db in
            try sql(db, "ALTER TABLE cookies ADD COLUMN top_frame_site_key TEXT NOT NULL DEFAULT ''")
            // A newer partitioned credential must neither shadow the first-party
            // credential nor trigger decryption of its unsupported payload.
            try sql(db, """
                INSERT INTO cookies(host_key, path, name, value, encrypted_value, expires_utc,
                    is_secure, is_httponly, has_expires, creation_utc, top_frame_site_key)
                VALUES('.youtube.com', '/', 'SAPISID', '', X'763230', 0, 1, 1, 0, 99, 'https://example.invalid')
                """)
        }
        let before = try Data(contentsOf: file)
        var keyReads = 0
        let data = try YouTubeBrowserCookies.read(profile: profile, home: home, now: now) {
            keyReads += 1
            return password
        }
        let cookies = try YouTubeCookieImport.parse(data, now: now)
        try require(keyReads == 1, "one import must acquire Chrome Safe Storage at most once")
        try require(cookies.count == 5, "only secure live YouTube records may be exported and duplicates must collapse")
        try require(cookies.first { $0.name == "SAPISID" }?.isHTTPOnly == true, "Chrome HttpOnly must survive export")
        try require(cookies.first { $0.name == "SID" }?.expiresDate == nil, "Chrome has_expires=0 must remain a session cookie")
        try require(cookies.first { $0.name == "SAPISID" }?.expiresDate == Date(timeIntervalSince1970: 1_600_001_000), "Chrome epoch conversion must preserve expiry")
        try require(cookies.first { $0.name == "PREF" }?.value == "newer", "newest duplicate identity must win deterministically")
        try require(cookies.first { $0.name == "host-only" }?.domain == "www.youtube.com", "host-only scope must not widen")
        try require(!String(decoding: data, as: UTF8.self).contains("foreign"), "foreign records must not reach the export")
        try require(try Data(contentsOf: file) == before, "browser SQLite must remain unmodified")
        let discovered = try YouTubeBrowserCookies.profiles(for: .chrome, home: home)
        try require(discovered.count == 1 && discovered[0].id == "Default", "Chrome discovery must expose explicit profile identity")
    }

    private static func chromeFailures(_ home: URL) throws {
        var keyReads = 0
        let provider: () throws -> Data = { keyReads += 1; return password }
        _ = try makeChrome(home, rows: [ChromeRow(domain: ".google.com", encrypted: Data("v20unsupported".utf8))])
        try rejects(.noCookies) { _ = try YouTubeBrowserCookies.read(profile: profile, home: home, now: now, keyProvider: provider) }
        try require(keyReads == 0, "a foreign-only database must never request a key")
        _ = try makeChrome(home, rows: try authentication(schema: 24))
        try rejects(.keychainDenied) {
            _ = try YouTubeBrowserCookies.read(profile: profile, home: home, now: now) { throw YouTubeBrowserCookiesError.keychainDenied }
        }
        try rejects(.malformedStorage) {
            _ = try YouTubeBrowserCookies.read(profile: profile, home: home, now: now) { Data("wrong-fixture-key".utf8) }
        }
        var unsupported = try authentication(schema: 24)
        unsupported[0].encrypted = Data("v20unsupported".utf8)
        unsupported[0].value = secret // Never fall back to plaintext when encryption is unsupported.
        _ = try makeChrome(home, rows: unsupported)
        keyReads = 0
        try rejects(.unsupportedStorage) { _ = try YouTubeBrowserCookies.read(profile: profile, home: home, now: now, keyProvider: provider) }
        try require(keyReads == 0, "unsupported encryption must fail before any Keychain prompt")
        var mismatch = try authentication(schema: 24)
        mismatch[0].encrypted = try encrypt(secret, host: ".google.com", schema: 24)
        _ = try makeChrome(home, rows: mismatch)
        try rejects(.malformedStorage) { _ = try YouTubeBrowserCookies.read(profile: profile, home: home, now: now, keyProvider: provider) }
        var expired = try authentication(schema: 24)
        expired[0].expiry = windowsTime(now.timeIntervalSince1970)
        expired[1].persistent = true
        expired[1].expiry = windowsTime(now.timeIntervalSince1970 - 1)
        _ = try makeChrome(home, rows: expired)
        keyReads = 0
        try rejects(.noCookies) { _ = try YouTubeBrowserCookies.read(profile: profile, home: home, now: now, keyProvider: provider) }
        try require(keyReads == 0, "expired credentials must not be decrypted")
        // Older schema v10 remains supported without removing a nonexistent hash.
        _ = try makeChrome(home, rows: try authentication(schema: 23), version: 23)
        let oldData = try YouTubeBrowserCookies.read(profile: profile, home: home, now: now, keyProvider: provider)
        try require(try YouTubeCookieImport.parse(oldData, now: now).count == 2, "pre24 Chrome must remain supported")
        // Read the actual live WAL, rather than copying only the main database.
        let file = try makeChrome(home, rows: [], version: 24)
        try withDatabase(file) { db in
            try sql(db, "PRAGMA journal_mode=WAL")
            for row in try authentication(schema: 24) { try insert(row, into: db) }
            let walData = try YouTubeBrowserCookies.read(profile: profile, home: home, now: now, keyProvider: provider)
            try require(try YouTubeCookieImport.parse(walData, now: now).count == 2, "live committed WAL cookies must be visible")
        }
        try withDatabase(file) { db in
            try sql(db, "PRAGMA journal_mode=DELETE")
            try sql(db, "BEGIN EXCLUSIVE")
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            try rejects(.busy) { _ = try YouTubeBrowserCookies.read(profile: profile, home: home, now: now, keyProvider: provider) }
        }
    }

    private static func safariRoundTrip(_ home: URL) throws {
        var rows = safariAuthentication()
        rows += [SafariRow(name: "PREF", value: "first"), SafariRow(name: "PREF", value: "second"),
                 SafariRow(domain: "www.youtube.com", name: "host-only"),
                 SafariRow(name: "expired", expiry: now.timeIntervalSince1970 - 1),
                 SafariRow(name: "cocoa-zero", expiry: 978_307_200),
                 SafariRow(name: "insecure", flags: 0)]
        for domain in [".google.com", ".notyoutube.com", ".youtube.com.evil.invalid", ".youtube.invalid"] {
            // Invalid UTF8 in a foreign value must not be decoded.
            rows.append(SafariRow(domain: domain, name: "foreign", valueBytes: [0xff, 0xfe]))
        }
        try makeSafari(home, data: binaryCookies(rows))
        let data = try YouTubeBrowserCookies.read(profile: safari, home: home, now: now) {
            throw Failure.assertion("Safari must never request Chrome Safe Storage")
        }
        let cookies = try YouTubeCookieImport.parse(data, now: now)
        try require(cookies.count == 4, "Safari must omit foreign, insecure, expired and duplicate records")
        try require(cookies.first { $0.name == "SAPISID" }?.isHTTPOnly == true, "Safari flags bit4 must preserve HttpOnly")
        try require(cookies.first { $0.name == "PREF" }?.value == "first", "Safari duplicate selection must follow deterministic page order")
        try require(cookies.first { $0.name == "host-only" }?.domain == "www.youtube.com", "Safari host-only scope must survive export")
        try require(cookies.allSatisfy { $0.expiresDate == Date(timeIntervalSince1970: 1_600_001_000) }, "Safari dates must use the Cocoa epoch, not treat Cocoa zero as session")
        let profiles = try YouTubeBrowserCookies.profiles(for: .safari, home: home)
        try require(profiles.count == 1 && profiles[0].id == "default", "Safari's default store must be discoverable")
    }

    private static func safariMalformedFiles(_ home: URL) throws {
        let valid = binaryCookies(safariAuthentication())
        var mutations: [Data] = []
        mutations.append(Data(valid.prefix(7)))
        var bad = valid; put(&bad, 4, UInt64(UInt32.max), bigEndian: true); mutations.append(bad)
        bad = valid; put(&bad, 8, UInt64(UInt32.max), bigEndian: true); mutations.append(bad)
        bad = valid; put(&bad, 12 + 8, UInt64(UInt32.max)); mutations.append(bad) // record offset
        let recordStart = 12 + 12 + 2 * 4
        bad = valid; put(&bad, recordStart, UInt64(UInt32.max)); mutations.append(bad) // record size
        bad = valid; put(&bad, recordStart + 16, 4); mutations.append(bad) // domain inside header
        bad = valid; put(&bad, recordStart + 28, UInt64(UInt32.max)); mutations.append(bad) // value outside record
        bad = valid; put(&bad, recordStart + 20, 56); mutations.append(bad) // overlapping string offsets
        bad = valid; put(&bad, recordStart + 40, Double.nan.bitPattern, bytes: 8); mutations.append(bad)
        bad = valid; put(&bad, recordStart + 40, Double.infinity.bitPattern, bytes: 8); mutations.append(bad)
        // Domain terminator removed: a parser must not read into the name field.
        bad = valid; bad[recordStart + 56 + ".youtube.com".utf8.count] = 65; mutations.append(bad)
        for data in mutations {
            try makeSafari(home, data: data)
            try rejects(.malformedStorage) {
                _ = try YouTubeBrowserCookies.read(profile: safari, home: home, now: now) { password }
            }
        }
        var invalidValue = safariAuthentication()
        invalidValue[0].valueBytes = [0xff]
        try makeSafari(home, data: binaryCookies(invalidValue))
        try rejects(.malformedStorage) { _ = try YouTubeBrowserCookies.read(profile: safari, home: home, now: now) { password } }
        var expired = safariAuthentication()
        expired[0].expiry = now.timeIntervalSince1970
        expired[1].expiry = 978_307_200
        try makeSafari(home, data: binaryCookies(expired))
        try rejects(.noCookies) { _ = try YouTubeBrowserCookies.read(profile: safari, home: home, now: now) { password } }
        try makeSafari(home, data: Data("not-a-cookie-store".utf8))
        try rejects(.unsupportedStorage) { _ = try YouTubeBrowserCookies.read(profile: safari, home: home, now: now) { password } }
        let oversized = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        let handle = try FileHandle(forWritingTo: oversized)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(33 * 1_048_576))
        try rejects(.unsupportedStorage) { _ = try YouTubeBrowserCookies.read(profile: safari, home: home, now: now) { password } }
    }

    private static func profileBoundaries(_ home: URL) throws {
        try rejects(.noProfile) { _ = try YouTubeBrowserCookies.profiles(for: .chrome, home: home) }
        try rejects(.noProfile) { _ = try YouTubeBrowserCookies.profiles(for: .safari, home: home) }
        for id in ["../Default", "Profile ../", "Profile 1/../../", "Guest Profile", "System Profile"] {
            let invalid = YouTubeBrowserProfile(browser: .chrome, id: id, name: "fixture")
            try rejects(.noProfile) { _ = try YouTubeBrowserCookies.read(profile: invalid, home: home) { password } }
        }
        _ = try makeChrome(home, rows: try authentication(schema: 24), profileID: "Profile 2")
        _ = try makeChrome(home, rows: try authentication(schema: 24), profileID: "Guest Profile")
        let profiles = try YouTubeBrowserCookies.profiles(for: .chrome, home: home)
        try require(profiles.map(\.id) == ["Profile 2"], "only standard explicitly selectable Chrome profiles may be discovered")
        let networkFile = home.appendingPathComponent("Library/Application Support/Google/Chrome/Profile 2/Network/Cookies")
        let legacyChromeFile = networkFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Cookies")
        try FileManager.default.moveItem(at: networkFile, to: legacyChromeFile)
        _ = try YouTubeBrowserCookies.read(profile: profiles[0], home: home, now: now) { password }
        let uuid = "12345678-1234-4234-8234-123456789ABC"
        let namedFile = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteDataStore/\(uuid)/Cookies/Cookies.binarycookies")
        try write(binaryCookies(safariAuthentication()), to: namedFile)
        let safariProfiles = try YouTubeBrowserCookies.profiles(for: .safari, home: home)
        try require(safariProfiles.count == 1 && safariProfiles[0].id == "store:0:\(uuid)", "Safari UUID stores must be selectable without private APIs")
        _ = try YouTubeBrowserCookies.read(profile: safariProfiles[0], home: home, now: now) { password }
        let legacySafariFile = home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")
        try write(binaryCookies(safariAuthentication()), to: legacySafariFile)
        _ = try YouTubeBrowserCookies.read(profile: safari, home: home, now: now) { password }
        let link = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: namedFile)
        try rejects(.unsupportedStorage) { _ = try YouTubeBrowserCookies.read(profile: safari, home: home, now: now) { password } }
    }

    private static func cancellation() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try makeChrome(home, rows: authentication(schema: 24))
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try YouTubeBrowserCookies.read(profile: profile, home: home, now: now) {
                throw Failure.assertion("cancelled imports must not acquire a key")
            }
        }
        do { _ = try await before.value; throw Failure.assertion("pre-read cancellation must propagate") }
        catch is CancellationError {}
        let afterKey = Task {
            try YouTubeBrowserCookies.read(profile: profile, home: home, now: now) {
                withUnsafeCurrentTask { $0?.cancel() }
                return password
            }
        }
        do { _ = try await afterKey.value; throw Failure.assertion("cancellation following Keychain must stop decryption") }
        catch is CancellationError {}
    }

    private static func safeErrors() throws {
        for error in [YouTubeBrowserCookiesError.noProfile, .accessDenied, .keychainDenied, .keychainUnavailable,
                      .busy, .unsupportedStorage, .malformedStorage, .noCookies, .readFailed] {
            try require(!error.localizedDescription.contains(secret) && !error.localizedDescription.contains("/Users/")
                        && !String(describing: error).contains(secret), "errors must never include browser secrets or paths")
        }
    }

    private struct ChromeRow {
        var domain = ".youtube.com"
        var name = "SAPISID"
        var value = ""
        var encrypted = Data()
        var expiry: Int64 = windowsTime(1_600_001_000)
        var secure = true
        var httpOnly = true
        var persistent = true
        var creation: Int64 = 1
    }

    private static func authentication(schema: Int) throws -> [ChromeRow] {
        [ChromeRow(name: "SAPISID", encrypted: try encrypt(secret, host: ".youtube.com", schema: schema)),
         ChromeRow(name: "SID", encrypted: try encrypt(secret, host: ".youtube.com", schema: schema), expiry: 0, persistent: false)]
    }

    private static func deriveKey(_ password: Data) throws -> [UInt8] {
        try PKCS5.PBKDF2(password: Array(password), salt: Array("saltysalt".utf8), iterations: 1003, keyLength: 16, variant: .sha1).calculate()
    }

    private static func encrypt(_ value: String, host: String, schema: Int) throws -> Data {
        let prefix = schema >= 24 ? SHA2(variant: .sha256).calculate(for: Array(host.utf8)) : []
        let aes = try AES(key: deriveKey(password), blockMode: CBC(iv: [UInt8](repeating: 32, count: 16)), padding: .pkcs7)
        return Data([0x76, 0x31, 0x30] + (try aes.encrypt(prefix + Array(value.utf8))))
    }

    private static func windowsTime(_ unix: Double) -> Int64 { Int64(unix + 11_644_473_600) * 1_000_000 }

    @discardableResult
    private static func makeChrome(_ home: URL, rows: [ChromeRow], version: Int = 24, profileID: String = "Default") throws -> URL {
        let file = home.appendingPathComponent("Library/Application Support/Google/Chrome/\(profileID)/Network/Cookies")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withDatabase(file) { db in
            try sql(db, "DROP TABLE IF EXISTS meta; DROP TABLE IF EXISTS cookies; CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version', '\(version)')")
            try sql(db, "CREATE TABLE cookies(host_key TEXT, path TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, has_expires INTEGER, creation_utc INTEGER)")
            for row in rows { try insert(row, into: db) }
        }
        return file
    }

    private static func withDatabase(_ file: URL, _ operation: (OpaquePointer) throws -> Void) throws {
        var optional: OpaquePointer?
        guard sqlite3_open(file.path, &optional) == SQLITE_OK, let db = optional else {
            if let optional { sqlite3_close(optional) }
            throw Failure.assertion("synthetic SQLite fixture could not open")
        }
        defer { sqlite3_close(db) }
        try operation(db)
    }

    private static func sql(_ db: OpaquePointer, _ text: String) throws {
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw Failure.assertion("synthetic SQLite fixture statement failed") }
    }

    private static func insert(_ row: ChromeRow, into db: OpaquePointer) throws {
        var optional: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES(?, '/', ?, ?, ?, ?, ?, ?, ?, ?)", -1, &optional, nil) == SQLITE_OK,
              let statement = optional else { throw Failure.assertion("fixture insert could not prepare") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (column, value) in [(Int32(1), row.domain), (2, row.name), (3, row.value)] {
            _ = value.withCString { sqlite3_bind_text(statement, column, $0, -1, transient) }
        }
        _ = row.encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient) }
        sqlite3_bind_int64(statement, 5, row.expiry)
        sqlite3_bind_int(statement, 6, row.secure ? 1 : 0)
        sqlite3_bind_int(statement, 7, row.httpOnly ? 1 : 0)
        sqlite3_bind_int(statement, 8, row.persistent ? 1 : 0)
        sqlite3_bind_int64(statement, 9, row.creation)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.assertion("fixture cookie insert failed") }
    }

    private struct SafariRow {
        var domain = ".youtube.com"
        var name = "PREF"
        var value = secret
        var valueBytes: [UInt8]? = nil
        var flags: UInt64 = 5
        var expiry: Double = 1_600_001_000
    }

    private static func safariAuthentication() -> [SafariRow] { [SafariRow(name: "SAPISID"), SafariRow(name: "SID")] }

    private static func binaryCookies(_ rows: [SafariRow]) -> Data {
        var page = Data(count: 12 + rows.count * 4)
        put(&page, 0, 0x00010000)
        put(&page, 4, UInt64(rows.count))
        for (index, row) in rows.enumerated() {
            put(&page, 8 + index * 4, UInt64(page.count))
            var record = Data(count: 56)
            put(&record, 8, row.flags)
            put(&record, 40, (row.expiry - 978_307_200).bitPattern, bytes: 8)
            put(&record, 48, Double(100).bitPattern, bytes: 8)
            let fields = [Array(row.domain.utf8), Array(row.name.utf8), Array("/".utf8), row.valueBytes ?? Array(row.value.utf8)]
            for (fieldIndex, field) in fields.enumerated() {
                put(&record, 16 + fieldIndex * 4, UInt64(record.count))
                record.append(contentsOf: field)
                record.append(0)
            }
            put(&record, 0, UInt64(record.count))
            page.append(record)
        }
        var file = Data(count: 12)
        put(&file, 0, 0x636f6f6b, bigEndian: true)
        put(&file, 4, 1, bigEndian: true)
        put(&file, 8, UInt64(page.count), bigEndian: true)
        file.append(page)
        file.append(Data(repeating: 0, count: 8)) // Safari checksum/footer, not a cookie page.
        return file
    }

    private static func put(_ data: inout Data, _ offset: Int, _ value: UInt64, bytes: Int = 4, bigEndian: Bool = false) {
        for index in 0..<bytes {
            let shift = (bigEndian ? bytes - index - 1 : index) * 8
            data[offset + index] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }

    private static func makeSafari(_ home: URL, data: Data) throws {
        try write(data, to: home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"))
    }

    private static func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private static func temporaryHome() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("youtube-browser-regression-\(UUID().uuidString)") }

    private static func withHome(_ operation: (URL) throws -> Void) throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try operation(home)
    }

    private static func rejects(_ expected: YouTubeBrowserCookiesError, _ operation: () throws -> Void) throws {
        do { try operation(); throw Failure.assertion("expected sanitized browser failure") }
        catch let error as YouTubeBrowserCookiesError {
            try require(String(describing: error) == String(describing: expected), "unexpected sanitized browser failure category")
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.assertion(message) }
    }

    private enum Failure: Error { case assertion(String) }
}
