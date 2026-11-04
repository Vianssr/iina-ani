import Foundation
import CryptoKit
import CommonCrypto

/// Fixed public player protocols, not an interpreter for downloaded JavaScript.
/// Requests carry only the token returned by the selected episode; no account cookies.
public struct PublicPlayerProtocol: Sendable {
    public typealias Request = @Sendable (URLRequest) async throws -> Data
    public struct Policy: Sendable {
        public let source: SourceConfiguration?
        public let hosts: Set<String>
        public let requestHosts: Set<String>
        public let enabled: Bool
        public let allowedExtensions: [String]
        public init(_ source: SourceConfiguration) {
            self.source = source; hosts = Set(source.hosts); requestHosts = source.requestHosts
            enabled = source.webSelector != nil; allowedExtensions = source.player.allowedExtensions
        }
        public init(host: String) {
            source = nil; hosts = [host]; requestHosts = [host]; enabled = true
            allowedExtensions = ["mp4", "m3u8", "flv"]
        }
        public func requestURL(_ raw: String, media: Bool) throws -> URL {
            if let source { return try source.requestURL(raw, media: media) }
            guard let url = URL(string: raw), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  url.port == nil || (hosts.contains("dm1.xfdm.pro") && url.host == "play.xfvod.pro" && url.port == 8088) else {
                throw PlaybackFailure.unsafeMediaAddress
            }
            return url
        }
    }
    public let configuration: Policy
    public let request: Request

    public init(configuration: SourceConfiguration, request: @escaping Request) {
        self.configuration = Policy(configuration); self.request = request
    }
    public init(host: String, request: @escaping Request) {
        self.configuration = Policy(host: host); self.request = request
    }
    public static func permits(_ request: URLRequest, configuration: SourceConfiguration) -> Bool {
        permits(request, configuration: Policy(configuration))
    }

    public static let smartAPI = URL(string: "https://hd.ticktockwow.com/smartplay-cache/api/webvideo_ty.php")!

    /// Dynamic episode resolution can take longer than static scripts or CDN probes.
    public static func requestTimeout(for request: URLRequest) -> TimeInterval {
        request.url == smartAPI && request.httpMethod == "POST" ? 45 : 20
    }

    public static func permits(_ request: URLRequest, configuration: Policy) -> Bool {
        guard configuration.enabled, let url = request.url,
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil, let host = url.host else { return false }
        let method = request.httpMethod ?? "GET"
        let hosts = configuration.requestHosts
        if hosts.contains("dm1.xfdm.pro"), method == "GET" {
            if host == "dm1.xfdm.pro", url.path == "/static/js/playerconfig.js" { return url.query == nil }
            if host == "player.moedot.net", url.path == "/player/ec.php",
               let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                return query.count == 3 && query.filter({ $0.name == "code" && $0.value == "xfdm1" }).count == 1 &&
                    query.filter({ $0.name == "from" && $0.value == "cf" }).count == 1 && query.filter({ $0.name == "url" }).count == 1
            }
        }
        let artSite = !hosts.isDisjoint(with: ["www.didahd.xyz", "www.rebozj.cc"])
        if url == smartAPI { return artSite && method == "POST" }
        if ["www.didahd.xyz", "www.rebozj.cc"].contains(host), hosts.contains(host), method == "GET" {
            return ["/static/player/artplayer", "/static/player/artplayer/"].contains(url.path) ||
                (url.path.hasPrefix("/static/player/") && url.path.hasSuffix(".js") &&
                 url.pathComponents.count == 4)
        }
        if host == "www.mutedm.com", hosts.contains(host), method == "GET" {
            return ["/addons/dp/player/index.php", "/addons/dp/player/dp.php"].contains(url.path)
        }
        return artSite && method == "GET" && request.value(forHTTPHeaderField: "Range") == "bytes=0-63" && isMP4ProbeCandidate(url)
    }

    public static func isMP4ProbeCandidate(_ url: URL) -> Bool {
        // This public cloud line serves MP4 without a path extension; require magic below.
        if url.host?.lowercased() == "ykj-eos-dg5-01.eos-dongguan-6.cmecloud.cn", url.pathExtension.isEmpty { return true }
        guard let host = url.host?.lowercased(), host.hasSuffix(".byteimg.com"),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let types = (c.queryItems ?? []).filter { $0.name == "mime_type" }
        return types.count == 1 && types[0].value == "video_mp4"
    }

    // JSON dictionaries stay in the caller's isolation across asynchronous requests.
    public func resolve(_ payload: [String: Any], page originalPage: URL,
                        isolation: isolated (any Actor)? = #isolation) async throws -> URL {
        var pageParts = URLComponents(url: originalPage, resolvingAgainstBaseURL: false)!
        let movedHosts = ["www.2kdm.com": "www.mutedm.com", "www.didahd.pro": "www.didahd.xyz", "www.rebozj.pro": "www.rebozj.cc"]
        if let current = movedHosts[pageParts.host ?? ""] { pageParts.host = current }
        guard let page = pageParts.url, configuration.requestHosts.contains(page.host ?? "") else { throw PlaybackFailure.unsafeMediaAddress }
        guard let raw = payload["url"] as? String, !raw.isEmpty, raw.utf8.count <= 16_384,
              let from = payload["from"] as? String, !from.isEmpty, from.utf8.count <= 32,
              from.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else {
            throw PlaybackFailure.invalidPlayerData
        }
        let hosts = configuration.requestHosts
        let supportedHosts: Set<String> = ["www.didahd.xyz", "www.didahd.pro", "www.rebozj.cc", "www.rebozj.pro", "www.2kdm.com", "www.mutedm.com"]
        guard supportedHosts.contains(page.host ?? "") else { throw PlaybackFailure.unsupportedEncryption }
        let pattern = #"^/(?:vodplay|play)/([0-9]+)-([0-9]+)-([0-9]+)\.html$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: page.path, range: NSRange(page.path.startIndex..., in: page.path)),
              let idRange = Range(match.range(at: 1), in: page.path),
              let lineRange = Range(match.range(at: 2), in: page.path),
              let episodeRange = Range(match.range(at: 3), in: page.path),
              payload["id"] as? String == String(page.path[idRange]),
              (payload["sid"] as? NSNumber)?.doubleValue == Double(page.path[lineRange]),
              (payload["nid"] as? NSNumber)?.doubleValue == Double(page.path[episodeRange]) else { throw PlaybackFailure.missingEpisode }
        if ["www.didahd.xyz", "www.didahd.pro", "www.rebozj.cc", "www.rebozj.pro"].contains(page.host ?? "") {
            let host = (page.host == "www.didahd.pro" ? "www.didahd.xyz" : page.host == "www.rebozj.pro" ? "www.rebozj.cc" : page.host!)
            guard hosts.contains(host), raw.count.isMultiple(of: 2),
                  raw.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw PlaybackFailure.invalidPlayerData
            }
            // Confirm this line actually uses the supported player; never send a token
            // to a parser inferred only from the site's name or encryption flag.
            let script = try await get(URL(string: "https://\(host)/static/player/\(from).js")!, referer: page)
            guard String(decoding: script, as: UTF8.self).contains("/static/player/artplayer/?url=") else {
                throw PlaybackFailure.unsupportedEncryption
            }
            var components = URLComponents(string: "https://\(host)/static/player/artplayer/")!
            components.queryItems = [URLQueryItem(name: "url", value: raw)]
            let endpoint = components.url!
            let html = String(decoding: try await get(endpoint, referer: page), as: UTF8.self)
            let timestamp = try Self.stringConstant("timestamp", in: html)
            guard timestamp.count <= 16, !timestamp.isEmpty, timestamp.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw PlaybackFailure.invalidPlayerData
            }
            let media: String
            if html.range(of: #"\bconst\s+isSmartPlay\s*=\s*true\s*;"#, options: .regularExpression) != nil {
                let key = try Self.stringConstant("playPageUrl", in: html)
                let code = try Self.stringConstant("secretKeySeed", in: html)
                guard !key.isEmpty, !code.isEmpty, key.utf8.count <= 16_384, code.utf8.count <= 4096 else { throw PlaybackFailure.invalidPlayerData }
                let time = Int(Date().timeIntervalSince1970)
                var api = URLRequest(url: Self.smartAPI)
                api.httpMethod = "POST"
                api.setValue("application/json", forHTTPHeaderField: "Content-Type")
                api.setValue("https://" + host, forHTTPHeaderField: "Origin")
                api.setValue(endpoint.deletingQuery.absoluteString, forHTTPHeaderField: "Referer")
                api.httpBody = try JSONSerialization.data(withJSONObject: ["vkey": key, "code": code, "t": time,
                    "signature": Self.md5(String(time))])
                let data = try await send(api)
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (root["code"] as? Int) == 200, let encrypted = root["url"] as? String else {
                    throw PlaybackFailure.invalidPlayerData
                }
                media = try Self.decrypt(encrypted, timestamp: timestamp)
            } else {
                let encoded = try Self.capture(#"\bconst\s+qualities\s*=\s*(\[[\s\S]*?\])\s*;"#, in: html)
                guard let entries = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]],
                      entries.count == 1, let encrypted = entries.first?["url"] as? String else { throw PlaybackFailure.ambiguousMedia }
                media = try Self.decrypt(encrypted, timestamp: timestamp)
            }
            // The site's first entry is the default stream. Subtitle/fallback suffixes
            // are protocol delimiters, not alternate episodes or automatic retries.
            let first = media.components(separatedBy: "/T/")[0].components(separatedBy: "/fallbackurl/")[0]
            return try await checkedMedia(first)
        }
        if ["www.2kdm.com", "www.mutedm.com"].contains(page.host ?? ""), hosts.contains("www.mutedm.com"), from == "m2" {
            guard let id = payload["id"] as? String, !id.isEmpty, id.utf8.count <= 20,
                  id.utf8.allSatisfy({ (48...57).contains($0) }) else { throw PlaybackFailure.invalidPlayerData }
            var components = URLComponents(string: "https://www.mutedm.com/addons/dp/player/index.php")!
            components.queryItems = [URLQueryItem(name: "key", value: "0"), URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "from", value: from), URLQueryItem(name: "url", value: raw)]
            let endpoint = components.url!
            let html = String(decoding: try await get(endpoint, referer: page), as: UTF8.self)
            let literal = try Self.capture(#"window\.location\.href\s*=\s*("(?:[^"\\]|\\.)*")\s*;"#, in: html)
            guard let target = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)),
                  let url = URL(string: target, relativeTo: endpoint)?.absoluteURL,
                  url.host == "www.mutedm.com", url.path == "/addons/dp/player/dp.php",
                  let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw PlaybackFailure.invalidPlayerData }
            for (name, expected) in [("id", id), ("from", from), ("url", raw)] {
                let fields = query.filter { $0.name == name }
                guard fields.count == 1, fields[0].value == expected else { throw PlaybackFailure.invalidPlayerData }
            }
            let player = String(decoding: try await get(url, referer: endpoint.deletingQuery), as: UTF8.self)
            let config = try Self.objectLiteral(variable: "config", in: player)
            guard try Self.stringProperty("api_vod_url", in: config) == raw else { throw PlaybackFailure.invalidPlayerData }
            return try await checkedMedia(Self.stringProperty("url", in: config))
        }
        throw PlaybackFailure.unsupportedEncryption
    }

    public func resolveXiFan(_ payload: [String: Any], page: URL,
                            isolation: isolated (any Actor)? = #isolation) async throws -> URL {
        guard page.host == "dm1.xfdm.pro", configuration.hosts.contains("dm1.xfdm.pro"),
              let raw = payload["url"] as? String, let from = payload["from"] as? String,
              let id = payload["id"] as? String, let sid = payload["sid"] as? Int, let nid = payload["nid"] as? Int,
              page.path == "/watch/\(id)/\(sid)/\(nid).html" else { throw PlaybackFailure.missingEpisode }
        let script = String(decoding: try await get(URL(string: "https://dm1.xfdm.pro/static/js/playerconfig.js")!, referer: page), as: UTF8.self)
        let list = try Self.capture(#"MacPlayerConfig\.player_list\s*=\s*(\{[\s\S]*?\})\s*(?:,\s*MacPlayerConfig\.|;)"#, in: script)
        guard let entries = try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: [String: Any]],
              let parser = entries[from]?["parse"] as? String else { throw PlaybackFailure.invalidPlayerData }
        if parser.isEmpty { return try await checkedMedia(raw) }
        guard var endpoint = URLComponents(string: parser), endpoint.scheme == "https", endpoint.host == "player.moedot.net",
              endpoint.path == "/player/index.php", endpoint.user == nil, endpoint.password == nil, endpoint.port == nil else {
            throw PlaybackFailure.indirectMedia
        }
        endpoint.path = "/player/ec.php"
        endpoint.queryItems = (endpoint.queryItems ?? []).filter { $0.name != "url" } + [URLQueryItem(name: "url", value: raw)]
        guard let url = endpoint.url else { throw PlaybackFailure.invalidPlayerData }
        let html = String(decoding: try await get(url, referer: page), as: UTF8.self)
        let body = try Self.capture(#"(?:let|var|const)\s+ConFig\s*=\s*(\{[\s\S]*\})\s*,\s*box\s*="#, in: html)
        guard let root = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { throw PlaybackFailure.invalidPlayerData }
        guard root["code"] as? Int == 200 else { throw PlaybackFailure.playerServiceUnavailable }
        guard let type = root["type"] as? String, ["0", "auto"].contains(type),
              let config = root["config"] as? [String: Any], let uid = config["uid"] as? String,
              uid.utf8.count == 6, uid.utf8.allSatisfy({ (33...126).contains($0) }),
              let encrypted = root["url"] as? String else { throw PlaybackFailure.invalidPlayerData }
        let decoded = try Self.decryptAES(encrypted, key: Array("2890\(uid)tB959C".utf8), iv: Array("2F131BE91247866E".utf8))
        return try await checkedMedia(decoded)
    }

    private func checkedMedia(_ raw: String) async throws -> URL {
        if URL(string: raw)?.scheme == nil { throw PlaybackFailure.indirectMedia }
        let url: URL
        do { url = try configuration.requestURL(raw, media: true) }
        catch { throw PlaybackFailure.unsafeMediaAddress }
        guard url.fragment == nil else { throw PlaybackFailure.unsafeMediaAddress }
        if configuration.allowedExtensions.contains(url.pathExtension.lowercased()) { return url }
        // These CDN addresses have no extension or end in .image. Require
        // actual ISO BMFF magic, not a filename/query claim, before handing to mpv.
        if Self.isMP4ProbeCandidate(url) {
            var probe = URLRequest(url: url)
            probe.setValue("bytes=0-63", forHTTPHeaderField: "Range")
            let bytes = try await send(probe)
            guard bytes.count >= 12, String(data: bytes.subdata(in: 4..<8), encoding: .ascii) == "ftyp" else {
                throw PlaybackFailure.unsupportedMediaFormat
            }
            return url
        }
        throw PlaybackFailure.unsupportedMediaFormat
    }

    private func get(_ url: URL, referer: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(referer.deletingQuery.absoluteString, forHTTPHeaderField: "Referer")
        return try await send(request)
    }
    private func send(_ value: URLRequest) async throws -> Data {
        guard Self.permits(value, configuration: configuration) else { throw PlaybackFailure.unsafeMediaAddress }
        try Task.checkCancellation()
        let data = try await request(value)
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw PlaybackFailure.invalidResponseBody }
        return data
    }

    public static func capture(_ pattern: String, in text: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: text) else { throw PlaybackFailure.invalidPlayerData }
        return String(text[range])
    }
    /// Balanced object extraction handles nested ad/settings objects and braces in
    /// quoted strings. Values remain data; no JavaScript is evaluated.
    public static func objectLiteral(variable: String, in text: String) throws -> String {
        let pattern = "\\b(?:var|let|const)\\s+" + NSRegularExpression.escapedPattern(for: variable) + "\\s*=\\s*"
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let prefix = Range(matches[0].range, in: text) else { throw PlaybackFailure.invalidPlayerData }
        let start = prefix.upperBound
        guard start < text.endIndex, text[start] == "{" else { throw PlaybackFailure.invalidPlayerData }
        var depth = 0, count = 0, quote: Character?, escaped = false
        for index in text[start...].indices {
            let character = text[index]
            count += 1
            guard count <= 65_536, depth <= 64 else { throw PlaybackFailure.invalidPlayerData }
            if let delimiter = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == delimiter { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
        }
        throw PlaybackFailure.invalidPlayerData
    }

    public static func stringConstant(_ name: String, in html: String) throws -> String {
        let value = try capture("\\bconst\\s+" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*("(?:[^"\\]|\\.)*")\s*;"#, in: html)
        guard let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) else { throw PlaybackFailure.invalidPlayerData }
        return decoded
    }
    public static func stringProperty(_ name: String, in json: String) throws -> String {
        let value = try capture("\"" + NSRegularExpression.escapedPattern(for: name) + #""\s*:\s*("(?:[^"\\]|\\.)*")"#, in: json)
        guard let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) else { throw PlaybackFailure.invalidPlayerData }
        return decoded
    }
    /// Matches the public artplayer execB protocol; MD5 is not used for credential storage.
    public static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func decrypt(_ encoded: String, timestamp: String) throws -> String {
        guard !encoded.isEmpty, encoded.utf8.count <= 32_768 else { throw PlaybackFailure.invalidPlayerData }
        if encoded.hasPrefix("https://") { return encoded }
        let hash = md5(timestamp + "RY7e48naFXPsLJC")
        return try decryptAES(encoded, key: Array(hash.suffix(16).utf8), iv: Array(hash.prefix(16).utf8))
    }
    public static func decryptAES(_ encoded: String, key: [UInt8], iv: [UInt8]) throws -> String {
        guard encoded.utf8.count <= 32_768, key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128,
              let data = Data(base64Encoded: encoded), !data.isEmpty, data.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw PlaybackFailure.invalidPlayerData
        }
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128), length = 0
        let status = data.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, bytes.baseAddress, data.count, &output, output.count, &length)
        }
        guard status == kCCSuccess, let value = String(bytes: output.prefix(length), encoding: .utf8), !value.isEmpty else {
            throw PlaybackFailure.invalidPlayerData
        }
        return value
    }
}

private extension URL {
    var deletingQuery: URL {
        var value = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        value.query = nil; value.fragment = nil
        return value.url!
    }
}
