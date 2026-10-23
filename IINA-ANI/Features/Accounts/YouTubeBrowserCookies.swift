import Foundation
import Security
import SQLite3
import CryptoSwift
import Darwin

enum YouTubeCookieBrowser: String, CaseIterable, Sendable {
    case chrome, safari
}

struct YouTubeBrowserProfile: Sendable {
    let browser: YouTubeCookieBrowser
    let id: String
    let name: String
}

enum YouTubeBrowserCookiesError: Error, LocalizedError, Sendable {
    case noProfile, accessDenied, keychainDenied, keychainUnavailable, busy
    case unsupportedStorage, malformedStorage, noCookies, readFailed

    var errorDescription: String? {
        switch self {
        case .noProfile:
            return String(localized: "No supported browser profile was found. Open the browser, sign in to YouTube, then try again or import a cookies.txt export.")
        case .accessDenied:
            return String(localized: "Browser cookie access was denied. Allow access in macOS Privacy & Security if desired, or import a cookies.txt export.")
        case .keychainDenied:
            return String(localized: "Chrome Safe Storage access was denied or cancelled. Try again and allow the Keychain request, or import a cookies.txt export.")
        case .keychainUnavailable:
            return String(localized: "Chrome Safe Storage is unavailable. Open Chrome and sign in to YouTube, or import a cookies.txt export.")
        case .busy:
            return String(localized: "The browser cookie store is busy. Close the browser and try again.")
        case .unsupportedStorage:
            return String(localized: "This browser cookie storage or encryption format is not supported. Import a cookies.txt export instead.")
        case .malformedStorage:
            return String(localized: "The browser cookie store is malformed or could not be decrypted. Sign in again in the browser, or import a cookies.txt export.")
        case .noCookies:
            return String(localized: "No usable YouTube login cookies were found in this profile. Sign in to YouTube in that profile, then try again.")
        case .readFailed:
            return String(localized: "The browser cookie store could not be read. Close the browser and try again, or import a cookies.txt export.")
        }
    }
}

/// Called only after the account UI obtains explicit consent. Never publishes an
/// account or writes browser files, temporary exports, preferences, or Keychain items.
/// Format references: yt-dlp/yt_dlp/cookies.py (MacChromeCookieDecryptor and Safari
/// parser), Chromium components/os_crypt/sync/os_crypt_mac.mm, and WebKit
/// UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm (UUID data-store locations).
enum YouTubeBrowserCookies {
    private static let maximumStoreSize = 32 * 1_048_576
    private static let maximumCookies = 20_000
    private static let maximumFieldSize = 65_536

    static func profiles(for browser: YouTubeCookieBrowser) async throws -> [YouTubeBrowserProfile] {
        try await offMain {
            try profiles(for: browser, home: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    static func read(profile: YouTubeBrowserProfile) async throws -> Data {
        try await offMain {
            try read(profile: profile, home: FileManager.default.homeDirectoryForCurrentUser,
                     keyProvider: chromeSafeStoragePassword)
        }
    }

    private static func offMain<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { try operation() }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    // Internal root/key seams let regression tests exercise production I/O using
    // exclusively synthetic stores, without accessing a user's browser or Keychain.
    static func profiles(for browser: YouTubeCookieBrowser, home: URL) throws -> [YouTubeBrowserProfile] {
        try Task.checkCancellation()
        var result: [YouTubeBrowserProfile] = []
        switch browser {
        case .chrome:
            let root = chromeRoot(home)
            for child in try directories(root) where isChromeProfileID(child) {
                if try firstRegularFile(chromeFiles(root.appendingPathComponent(child))) != nil {
                    result.append(.init(browser: .chrome, id: child, name: child))
                }
            }
        case .safari:
            // The legacy and container files are alternative default stores, not
            // separate identities. Prefer the current Safari container when present.
            if try firstRegularFile(safariDefaultFiles(home)) != nil {
                result.append(.init(browser: .safari, id: "default", name: "Default"))
            }
            for (index, root) in safariProfileRoots(home).enumerated() {
                for child in try directories(root) where UUID(uuidString: child) != nil {
                    let file = root.appendingPathComponent(child).appendingPathComponent("Cookies/Cookies.binarycookies")
                    if try regularFileExists(file) {
                        result.append(.init(browser: .safari, id: "store:\(index):\(child)", name: "Profile \(child)"))
                    }
                }
            }
        }
        try Task.checkCancellation()
        guard !result.isEmpty else { throw YouTubeBrowserCookiesError.noProfile }
        return result.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func read(profile: YouTubeBrowserProfile, home: URL,
                     now: Date = Date(), keyProvider: () throws -> Data) throws -> Data {
        try Task.checkCancellation()
        let file: URL?
        switch profile.browser {
        case .chrome:
            guard isChromeProfileID(profile.id) else { throw YouTubeBrowserCookiesError.noProfile }
            file = try firstRegularFile(chromeFiles(chromeRoot(home).appendingPathComponent(profile.id)))
        case .safari:
            if profile.id == "default" {
                file = try firstRegularFile(safariDefaultFiles(home))
            } else {
                let parts = profile.id.split(separator: ":", omittingEmptySubsequences: false)
                let roots = safariProfileRoots(home)
                guard parts.count == 3, parts[0] == "store", let index = Int(parts[1]),
                      roots.indices.contains(index), UUID(uuidString: String(parts[2])) != nil else {
                    throw YouTubeBrowserCookiesError.noProfile
                }
                let candidate = roots[index].appendingPathComponent(String(parts[2]))
                    .appendingPathComponent("Cookies/Cookies.binarycookies")
                file = try regularFileExists(candidate) ? candidate : nil
            }
        }
        guard let file else { throw YouTubeBrowserCookiesError.noProfile }
        let records: [Record]
        switch profile.browser {
        case .chrome: records = try chromeRecords(file: file, now: now, keyProvider: keyProvider)
        case .safari: records = try safariRecords(readBoundedFile(file), now: now)
        }
        try Task.checkCancellation()
        return try export(records, now: now)
    }

    private static func chromeRoot(_ home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome")
    }

    private static func isChromeProfileID(_ id: String) -> Bool {
        if id == "Default" { return true }
        guard id.hasPrefix("Profile ") else { return false }
        let suffix = id.dropFirst(8)
        return !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func chromeFiles(_ profile: URL) -> [URL] {
        [profile.appendingPathComponent("Network/Cookies"), profile.appendingPathComponent("Cookies")]
    }

    private static func safariDefaultFiles(_ home: URL) -> [URL] {
        [home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
         home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")]
    }

    private static func safariProfileRoots(_ home: URL) -> [URL] {
        [home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteDataStore"),
         home.appendingPathComponent("Library/WebKit/com.apple.Safari/WebsiteDataStore"),
         home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/WebKit/com.apple.Safari/WebsiteDataStore"),
         home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/WebKit/Profiles")]
    }

    private static func directories(_ root: URL) throws -> [String] {
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            return try urls.filter {
                let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
            }.map(\.lastPathComponent)
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { return [] }
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError { return [] }
            throw fileError(error)
        }
    }

    private static func regularFileExists(_ file: URL) throws -> Bool {
        var info = stat()
        if lstat(file.path, &info) != 0 {
            if errno == ENOENT || errno == ENOTDIR { return false }
            throw posixError(errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw YouTubeBrowserCookiesError.unsupportedStorage }
        return true
    }

    private static func firstRegularFile(_ files: [URL]) throws -> URL? {
        for file in files where try regularFileExists(file) { return file }
        return nil
    }

    private static func posixError(_ code: Int32) -> YouTubeBrowserCookiesError {
        code == EACCES || code == EPERM ? .accessDenied : .readFailed
    }

    private static func fileError(_ error: Error) -> YouTubeBrowserCookiesError {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return posixError(Int32(ns.code)) }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return .accessDenied }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain { return posixError(Int32(underlying.code)) }
        return .readFailed
    }

    private static func readBoundedFile(_ file: URL) throws -> Data {
        try Task.checkCancellation()
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw posixError(errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError(errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
              info.st_size <= maximumStoreSize else { throw YouTubeBrowserCookiesError.unsupportedStorage }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), min(65_536, bytes.count - offset))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno)
                }
                guard count > 0 else { throw YouTubeBrowserCookiesError.malformedStorage }
                offset += count
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
            throw YouTubeBrowserCookiesError.busy
        }
        try Task.checkCancellation()
        return data
    }

    private struct Record {
        let domain: String
        let path: String
        let name: String
        let value: String
        let secure: Bool
        let httpOnly: Bool
        let expires: Int64 // Netscape 0 is a session cookie.
    }

    private static func export(_ records: [Record], now: Date) throws -> Data {
        // Prefer the first unpartitioned row in deterministic storage order.
        struct Identity: Hashable { let domain: String; let path: String; let name: String }
        var seen: Set<Identity> = []
        var text = "# Netscape HTTP Cookie File\n"
        var byteCount = text.utf8.count
        for record in records {
            try Task.checkCancellation()
            guard record.secure, isYouTube(record.domain),
                  record.expires == 0 || Double(record.expires) > now.timeIntervalSince1970 else { continue }
            let identity = Identity(domain: record.domain.lowercased(), path: record.path, name: record.name)
            guard seen.insert(identity).inserted else { continue }
            let fields = [record.domain.lowercased(), record.domain.hasPrefix(".") ? "TRUE" : "FALSE",
                          record.path, "TRUE", String(record.expires), record.name, record.value]
            guard fields.allSatisfy({ !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
                throw YouTubeBrowserCookiesError.malformedStorage
            }
            let line = (record.httpOnly ? "#HttpOnly_" : "") + fields.joined(separator: "\t") + "\n"
            byteCount += line.utf8.count
            guard byteCount <= YouTubeCookieImport.maximumFileSize else { throw YouTubeBrowserCookiesError.unsupportedStorage }
            text += line
        }
        let data = Data(text.utf8)
        do { _ = try YouTubeCookieImport.parse(data, now: now) }
        catch { throw YouTubeBrowserCookiesError.noCookies }
        try Task.checkCancellation()
        return data
    }

    private static func isYouTube(_ domain: String) -> Bool {
        let lower = domain.lowercased()
        return YouTubeCookieImport.isYouTubeDomain(lower.hasPrefix(".") ? String(lower.dropFirst()) : lower)
    }

    private static func chromeSafeStoragePassword() throws -> Data {
        try Task.checkCancellation()
        // Native Security preserves macOS's normal Keychain ACL/consent UI. Do not
        // use security(1), suppress authentication, or query unrelated items.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage", kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try Task.checkCancellation()
        switch status {
        case errSecSuccess:
            guard let password = result as? Data, !password.isEmpty, password.count <= maximumFieldSize else {
                throw YouTubeBrowserCookiesError.keychainUnavailable
            }
            return password
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw YouTubeBrowserCookiesError.keychainDenied
        default: throw YouTubeBrowserCookiesError.keychainUnavailable
        }
    }

    private static func sqliteError(_ code: Int32) -> YouTubeBrowserCookiesError {
        switch code & 0xff {
        case SQLITE_BUSY, SQLITE_LOCKED: return .busy
        case SQLITE_PERM, SQLITE_AUTH: return .accessDenied
        case SQLITE_NOTADB, SQLITE_CORRUPT: return .malformedStorage
        case SQLITE_ERROR, SQLITE_SCHEMA: return .unsupportedStorage
        default: return .readFailed
        }
    }

    private static func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw sqliteError(status)
        }
        return statement
    }

    private static func columnData(_ statement: OpaquePointer, _ column: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximumFieldSize else { throw YouTubeBrowserCookiesError.malformedStorage }
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { throw YouTubeBrowserCookiesError.malformedStorage }
        return Data(bytes: bytes, count: count)
    }

    private static func columnText(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard let value = String(data: try columnData(statement, column), encoding: .utf8) else {
            throw YouTubeBrowserCookiesError.malformedStorage
        }
        return value
    }

    private static func chromeRecords(file: URL, now: Date, keyProvider: () throws -> Data) throws -> [Record] {
        try Task.checkCancellation()
        // Check OS permissions independently so SQLite cannot hide a TCC denial
        // behind SQLITE_CANTOPEN. This descriptor never reads cookie contents.
        let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw posixError(errno) }
        close(fd)
        var optionalDB: OpaquePointer?
        let status = sqlite3_open_v2(file.path, &optionalDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let db = optionalDB else {
            if let optionalDB { sqlite3_close(optionalDB) }
            throw sqliteError(status)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_000)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw sqliteError(sqlite3_errcode(db)) }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        let meta = try prepare("SELECT value FROM meta WHERE key = 'version'", db: db)
        let metaStatus = sqlite3_step(meta)
        guard metaStatus == SQLITE_ROW else {
            sqlite3_finalize(meta)
            throw metaStatus == SQLITE_DONE ? YouTubeBrowserCookiesError.unsupportedStorage : sqliteError(metaStatus)
        }
        let versionText: String
        do { versionText = try columnText(meta, 0) }
        catch { sqlite3_finalize(meta); throw error }
        sqlite3_finalize(meta)
        guard let version = Int(versionText), version > 0 else { throw YouTubeBrowserCookiesError.unsupportedStorage }
        // Partitioned cookies must not become unpartitioned account credentials.
        // Older Chrome schemas have no partition column.
        let columns = try prepare("PRAGMA table_info(cookies)", db: db)
        var hasPartitionColumn = false
        do {
            defer { sqlite3_finalize(columns) }
            while true {
                let step = sqlite3_step(columns)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw sqliteError(step) }
                if try columnText(columns, 1) == "top_frame_site_key" { hasPartitionColumn = true }
            }
        }
        let partitionFilter = hasPartitionColumn ? "AND top_frame_site_key = ''" : ""
        // Domain restriction is in SQL, before fetching any encrypted/plaintext
        // values. GLOB's literal dot ensures notyoutube.com cannot match.
        let rows = try prepare("""
            SELECT host_key, path, name, value, encrypted_value, expires_utc,
                   is_secure, is_httponly, has_expires
            FROM cookies
            WHERE (lower(host_key) IN ('youtube.com', '.youtube.com')
               OR lower(host_key) GLOB '*.youtube.com')
            \(partitionFilter)
            ORDER BY host_key, path, name, creation_utc DESC, rowid DESC
            """, db: db)
        defer { sqlite3_finalize(rows) }
        var records: [Record] = []
        var key: [UInt8]?
        var count = 0
        while true {
            try Task.checkCancellation()
            let step = sqlite3_step(rows)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw sqliteError(step) }
            count += 1
            guard count <= maximumCookies else { throw YouTubeBrowserCookiesError.unsupportedStorage }
            let domain = try columnText(rows, 0)
            guard isYouTube(domain) else { continue }
            let secure = sqlite3_column_int(rows, 6) != 0
            guard secure else { continue }
            let rawExpiry = sqlite3_column_int64(rows, 5)
            let persistent = sqlite3_column_int(rows, 8) != 0
            let expires: Int64
            if persistent {
                guard rawExpiry > 0 else { throw YouTubeBrowserCookiesError.malformedStorage }
                expires = rawExpiry / 1_000_000 - 11_644_473_600
                guard expires > 0, Double(expires) > now.timeIntervalSince1970 else { continue }
            } else { expires = 0 }
            let encrypted = try columnData(rows, 4)
            let value: String
            if encrypted.isEmpty {
                value = try columnText(rows, 3)
            } else {
                guard encrypted.starts(with: [0x76, 0x31, 0x30]) else { throw YouTubeBrowserCookiesError.unsupportedStorage }
                guard encrypted.count > 3, (encrypted.count - 3) % 16 == 0 else {
                    throw YouTubeBrowserCookiesError.malformedStorage
                }
                if key == nil {
                    try Task.checkCancellation()
                    let password = try keyProvider()
                    try Task.checkCancellation()
                    guard !password.isEmpty, password.count <= maximumFieldSize else {
                        throw YouTubeBrowserCookiesError.keychainUnavailable
                    }
                    do {
                        key = try PKCS5.PBKDF2(password: Array(password), salt: Array("saltysalt".utf8),
                                              iterations: 1003, keyLength: 16, variant: .sha1).calculate()
                    } catch { throw YouTubeBrowserCookiesError.malformedStorage }
                    try Task.checkCancellation()
                }
                guard let key else { throw YouTubeBrowserCookiesError.keychainUnavailable }
                value = try decryptChrome(encrypted, host: domain, schemaVersion: version, key: key)
            }
            records.append(Record(domain: domain, path: try columnText(rows, 1), name: try columnText(rows, 2),
                                  value: value, secure: secure, httpOnly: sqlite3_column_int(rows, 7) != 0, expires: expires))
        }
        try Task.checkCancellation()
        return records
    }

    static func decryptChrome(_ encrypted: Data, host: String, schemaVersion: Int, key: [UInt8]) throws -> String {
        try Task.checkCancellation()
        guard encrypted.starts(with: [0x76, 0x31, 0x30]) else { throw YouTubeBrowserCookiesError.unsupportedStorage }
        let ciphertext = encrypted.dropFirst(3)
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { throw YouTubeBrowserCookiesError.malformedStorage }
        var plaintext: [UInt8]
        do {
            // Validate PKCS#7 ourselves: some padding helpers remove padding
            // permissively, which is not appropriate for a credential boundary.
            plaintext = try AES(key: key, blockMode: CBC(iv: [UInt8](repeating: 32, count: 16)), padding: .noPadding)
                .decrypt(Array(ciphertext))
        } catch { throw YouTubeBrowserCookiesError.malformedStorage }
        try Task.checkCancellation()
        guard let last = plaintext.last, (1...16).contains(Int(last)), plaintext.count >= Int(last),
              plaintext.suffix(Int(last)).allSatisfy({ $0 == last }) else { throw YouTubeBrowserCookiesError.malformedStorage }
        plaintext.removeLast(Int(last))
        if schemaVersion >= 24 {
            let digest = SHA2(variant: .sha256).calculate(for: Array(host.utf8))
            guard plaintext.count >= digest.count else { throw YouTubeBrowserCookiesError.malformedStorage }
            var difference: UInt8 = 0
            for index in digest.indices { difference |= digest[index] ^ plaintext[index] }
            guard difference == 0 else { throw YouTubeBrowserCookiesError.malformedStorage }
            plaintext.removeFirst(digest.count)
        }
        guard let value = String(bytes: plaintext, encoding: .utf8) else { throw YouTubeBrowserCookiesError.malformedStorage }
        try Task.checkCancellation()
        return value
    }

    private struct BinaryView {
        let data: Data
        let start: Int
        let count: Int

        init(_ data: Data, start: Int = 0, count: Int? = nil) {
            self.data = data
            self.start = start
            self.count = count ?? data.count
        }

        func uint(_ offset: Int, bytes: Int = 4, bigEndian: Bool = false) throws -> UInt64 {
            guard offset >= 0, bytes > 0, offset <= count, bytes <= count - offset else {
                throw YouTubeBrowserCookiesError.malformedStorage
            }
            var value: UInt64 = 0
            for index in 0..<bytes {
                let shift = bigEndian ? (bytes - index - 1) * 8 : index * 8
                value |= UInt64(data[start + offset + index]) << shift
            }
            return value
        }

        func string(_ offset: Int, limit: Int) throws -> String {
            guard offset >= 56, offset < limit, limit <= count else { throw YouTubeBrowserCookiesError.malformedStorage }
            var end = offset
            while end < limit, data[start + end] != 0 {
                guard end - offset < maximumFieldSize else { throw YouTubeBrowserCookiesError.malformedStorage }
                end += 1
            }
            guard end < limit, let value = String(data: data[(start + offset)..<(start + end)], encoding: .utf8) else {
                throw YouTubeBrowserCookiesError.malformedStorage
            }
            return value
        }
    }

    private static func safariRecords(_ data: Data, now: Date) throws -> [Record] {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumStoreSize else { throw YouTubeBrowserCookiesError.unsupportedStorage }
        let file = BinaryView(data)
        guard try file.uint(0, bigEndian: true) == 0x636f6f6b else { throw YouTubeBrowserCookiesError.unsupportedStorage }
        let pages = Int(try file.uint(4, bigEndian: true))
        guard pages <= maximumCookies, pages <= (data.count - 8) / 4 else { throw YouTubeBrowserCookiesError.malformedStorage }
        var pageStart = 8 + pages * 4
        var result: [Record] = []
        var totalCookies = 0
        for pageIndex in 0..<pages {
            try Task.checkCancellation()
            let pageSize = Int(try file.uint(8 + pageIndex * 4, bigEndian: true))
            guard pageSize >= 12, pageStart <= data.count, pageSize <= data.count - pageStart else {
                throw YouTubeBrowserCookiesError.malformedStorage
            }
            let page = BinaryView(data, start: pageStart, count: pageSize)
            guard try page.uint(0) == 0x00010000 else { throw YouTubeBrowserCookiesError.malformedStorage }
            let count = Int(try page.uint(4))
            totalCookies += count
            guard totalCookies <= maximumCookies, count <= (pageSize - 12) / 4 else { throw YouTubeBrowserCookiesError.malformedStorage }
            let headerEnd = 12 + count * 4
            guard try page.uint(8 + count * 4) == 0 else { throw YouTubeBrowserCookiesError.malformedStorage }
            let offsets = try (0..<count).map { Int(try page.uint(8 + $0 * 4)) }.sorted()
            var previousEnd = headerEnd
            for offset in offsets {
                try Task.checkCancellation()
                guard offset >= previousEnd, offset <= pageSize - 56 else { throw YouTubeBrowserCookiesError.malformedStorage }
                let size = Int(try page.uint(offset))
                guard size >= 56, size <= pageSize - offset else { throw YouTubeBrowserCookiesError.malformedStorage }
                previousEnd = offset + size
                let record = BinaryView(data, start: pageStart + offset, count: size)
                let stringOffsets = try [16, 20, 24, 28].map { Int(try record.uint($0)) }
                let sorted = stringOffsets.sorted()
                guard Set(sorted).count == 4, sorted.first! >= 56, sorted.last! < size else {
                    throw YouTubeBrowserCookiesError.malformedStorage
                }
                func field(_ index: Int) throws -> String {
                    let position = stringOffsets[index]
                    return try record.string(position, limit: sorted.first(where: { $0 > position }) ?? size)
                }
                // Only the domain is decoded for foreign cookies. Their names,
                // values and encrypted payloads are never materialized as strings.
                let domain = try field(0)
                guard isYouTube(domain) else { continue }
                let flags = try record.uint(8)
                guard flags & 1 != 0 else { continue }
                let cocoaExpiry = Double(bitPattern: try record.uint(40, bytes: 8))
                let unixExpiry = cocoaExpiry + 978_307_200
                // binarycookies persists expiration dates, not Netscape session
                // sentinels: Cocoa 0 is 2001-01-01, never a session cookie.
                guard cocoaExpiry.isFinite, unixExpiry.isFinite,
                      unixExpiry >= 0, unixExpiry < Double(Int64.max) else { throw YouTubeBrowserCookiesError.malformedStorage }
                guard unixExpiry > now.timeIntervalSince1970 else { continue }
                result.append(Record(domain: domain, path: try field(2), name: try field(1), value: try field(3),
                                     secure: true, httpOnly: flags & 4 != 0, expires: Int64(unixExpiry)))
            }
            pageStart += pageSize
        }
        // Safari versions append checksums and optional metadata. Their contents
        // are not credentials and are not needed to interpret bounded pages.
        try Task.checkCancellation()
        return result
    }
}
