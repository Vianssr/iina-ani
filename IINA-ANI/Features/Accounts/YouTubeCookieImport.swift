import Foundation

/// Validates a supplied Netscape export, whether selected manually or produced by
/// a consented browser read. Google-wide cookies remain outside this boundary.
enum YouTubeCookieImport {
    static let maximumFileSize = 1_048_576

    static func parse(_ data: Data, now: Date = Date()) throws -> [HTTPCookie] {
        guard !data.isEmpty, data.count <= maximumFileSize,
              let text = String(data: data, encoding: .utf8) else {
            throw SiteAccountError.invalidCookies
        }
        var cookies: [HTTPCookie] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine
            let httpOnly = line.hasPrefix("#HttpOnly_")
            if httpOnly { line = line.dropFirst("#HttpOnly_".count) }
            else if line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 7 else { throw SiteAccountError.invalidCookies }
            let exportedDomain = String(fields[0]).lowercased()
            let host = exportedDomain.hasPrefix(".") ? String(exportedDomain.dropFirst()) : exportedDomain
            guard isYouTubeDomain(host) else { continue }
            guard validHost(host), fields[1] == "TRUE" || fields[1] == "FALSE",
                  !(exportedDomain.hasPrefix(".") && fields[1] == "FALSE"),
                  fields[3] == "TRUE" || fields[3] == "FALSE",
                  let expiration = Int64(fields[4]), expiration >= -1 else {
                throw SiteAccountError.invalidCookies
            }
            // Exports can include non-secure preferences beside secure credentials.
            // Do not import those cookies or reject an otherwise usable login.
            guard fields[3] == "TRUE" else { continue }
            let path = String(fields[2])
            let name = String(fields[5])
            let value = String(fields[6])
            guard path.hasPrefix("/"), safeField(path), validName(name), safeField(value),
                  !value.contains(";") else { throw SiteAccountError.invalidCookies }
            if name.hasPrefix("__Host-"), fields[1] != "FALSE" || path != "/" {
                throw SiteAccountError.invalidCookies
            }
            let expires = expiration > 0 ? Date(timeIntervalSince1970: TimeInterval(expiration)) : nil
            if let expires, expires <= now { continue }
            let domain = fields[1] == "TRUE" ? "." + host : host
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: domain, .path: path, .name: name, .value: value, .secure: "TRUE"
            ]
            if let expires { properties[.expires] = expires }
            if httpOnly { properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
            guard let cookie = HTTPCookie(properties: properties), cookie.isSecure else {
                throw SiteAccountError.invalidCookies
            }
            cookies.append(cookie)
        }
        guard hasAuthenticationCookies(cookies, now: now) else { throw SiteAccountError.invalidCookies }
        return cookies
    }

    static func isYouTubeDomain(_ host: String) -> Bool {
        host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// Presence is only an import precondition; the server must verify the login.
    static func hasAuthenticationCookies(_ cookies: [HTTPCookie], now: Date = Date()) -> Bool {
        let names = Set(cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let reachesSite = host == "www.youtube.com" ||
                (domain.hasPrefix(".") && (host == "youtube.com" || "www.youtube.com".hasSuffix("." + host)))
            return validHost(host) && isYouTubeDomain(host) && reachesSite && cookie.path == "/" &&
                cookie.isSecure && !cookie.value.isEmpty && (cookie.expiresDate.map { $0 > now } ?? true)
        }.map(\.name))
        return !names.isDisjoint(with: ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"]) &&
            !names.isDisjoint(with: ["SID", "__Secure-1PSID", "__Secure-3PSID"])
    }

    private static func validHost(_ host: String) -> Bool {
        guard host.utf8.count <= 253 else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    private static func safeField(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            byte > 32 && byte < 127 && !"()<>@,;:\\\"/[]?={}".utf8.contains(byte)
        }
    }
}
