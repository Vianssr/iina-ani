//
//  XiFan.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import SourceCore
import Foundation
import SwiftSoup
import CryptoSwift

actor XiFan: SupportSiteProtocol {
    private static let playerListExpression = try! NSRegularExpression(
        pattern: #"MacPlayerConfig\.player_list\s*=\s*(\{.*?\})\s*(?:,\s*MacPlayerConfig\.|;)"#,
        options: .dotMatchesLineSeparators)
    private static let mediaExpression = try! NSRegularExpression(
        pattern: #"(?:let|var|const)\s+ConFig\s*=\s*(\{.*\})\s*,\s*box\s*="#,
        options: .dotMatchesLineSeparators)

    private struct Episode: Sendable {
        let number: Int
        let title: String
        let url: String
    }

    private struct Line: Sendable {
        let number: Int
        let title: String
        let episodes: [Episode]
    }

    private struct Catalog: Sendable {
        let title: String
        let cover: String
        let lines: [Line]
    }

    private func page(_ url: String) throws -> (id: Int, line: Int?, episode: Int?) {
        guard let components = URLComponents(string: url),
              let page = SupportSites.xiFanPage(components) else {
            throw VideoGetError.invalidLink
        }
        return page
    }

    private func catalog(_ id: Int) async throws -> Catalog {
        let url = "https://dm1.xfdm.pro/bangumi/\(id).html"
        let html = try await AccountHTTP.request(url).validate().serializingString().value
        let document = try SwiftSoup.parse(html)
        guard let title = try document.select(".detail-info .slide-info-title").first()?.text(),
              !title.isEmpty else { throw VideoGetError.notFountData }
        let cover = try document.select(".detail-pic img[data-src]").first()?.attr("data-src") ?? ""
        let tabs = try document.select(".anthology-tab .swiper-slide")
        let boxes = try document.select(".anthology-list .anthology-list-box")
        var lines: [Line] = []
        for (index, tab) in tabs.enumerated() where index < boxes.count {
            let number = index + 1
            let name = tab.ownText().trimmingCharacters(in: .whitespacesAndNewlines)
            let links = try boxes.get(index).select("a[href]")
            var episodes: [Episode] = []
            for link in links {
                let href = try link.attr("href")
                guard let address = URL(string: href, relativeTo: URL(string: url))?.absoluteURL,
                      let parts = SupportSites.xiFanPage(URLComponents(url: address, resolvingAgainstBaseURL: false) ?? URLComponents()),
                      parts.id == id, parts.line == number, let episode = parts.episode else { continue }
                let title = try link.text()
                episodes.append(Episode(number: episode, title: title, url: address.absoluteString))
            }
            if !episodes.isEmpty {
                lines.append(Line(number: number, title: name.isEmpty ? "Line \(number)" : name, episodes: episodes))
            }
        }
        guard !lines.isEmpty else { throw VideoGetError.notFountData }
        return Catalog(title: title, cover: cover, lines: lines)
    }

    func episodeList(_ url: String) async throws -> (nodes: [VideoTreeNode], current: Int) {
        if let c = URLComponents(string: url), SupportSites.xiFanNextPage(c) != nil { return try await Self.nextEpisodes(url) }
        let address = try page(url)
        let data = try await catalog(address.id)
        var current = 0
        var position = 0
        let nodes = data.lines.map { line in
            let children = line.episodes.map { episode in
                if line.number == address.line && episode.number == address.episode {
                    current = position
                }
                position += 1
                return VideoTreeNode(site: .xiFan, index: episode.number,
                                     title: episode.title, id: "\(address.id)", url: episode.url)
            }
            return VideoTreeNode(title: line.title, children: children)
        }
        if address.episode != nil && !data.lines.contains(where: { line in
            line.number == address.line && line.episodes.contains(where: { $0.number == address.episode })
        }) {
            throw VideoGetError.notFountData
        }
        return (nodes, current)
    }

    func liveInfo(_ url: String) async throws -> any LiveInfo {
        if let c = URLComponents(string: url), let page = SupportSites.xiFanNextPage(c) {
            let data = try await Self.nextCatalog(id: page.id)
            return XiFanInfo(title: data.title, name: data.title, cover: data.cover, isLiving: true)
        }
        let address = try page(url)
        let data = try await catalog(address.id)
        let available = address.episode == nil || data.lines.contains { line in
            line.number == address.line && line.episodes.contains { $0.number == address.episode }
        }
        return XiFanInfo(title: data.title, name: data.title, cover: data.cover, isLiving: available)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        if let c = URLComponents(string: url), SupportSites.xiFanNextPage(c) != nil { return try await Self.nextDecode(url) }
        let address = try page(url)
        let data = try await catalog(address.id)
        guard let selectedLine = address.line == nil ? data.lines.first : data.lines.first(where: { $0.number == address.line }),
              let selectedEpisode = address.episode == nil ? selectedLine.episodes.first : selectedLine.episodes.first(where: { $0.number == address.episode }) else {
            throw VideoGetError.notFountData
        }
        let parsers = try await Self.playerParsers()
        let selectedURL = try await Self.mediaURL(selectedEpisode.url, parsers: parsers, id: address.id,
                                                   line: selectedLine.number, episode: selectedEpisode.number)
        var result = YouGetJSON(rawUrl: url)
        result.title = "\(data.title) - \(selectedEpisode.title)"
        var selectedStream = Stream(url: selectedURL)
        selectedStream.qualityIndex = 0
        result.streams["\(selectedLine.title) (\(selectedLine.number))"] = selectedStream

        let alternatives = data.lines.filter { $0.number != selectedLine.number }.compactMap { line -> (Line, Episode)? in
            guard let episode = line.episodes.first(where: { $0.number == selectedEpisode.number }) else { return nil }
            return (line, episode)
        }
        await withTaskGroup(of: (Int, String?).self) { group in
            for (line, episode) in alternatives {
                group.addTask {
                    let media = try? await Self.mediaURL(episode.url, parsers: parsers, id: address.id,
                                                         line: line.number, episode: episode.number)
                    return (line.number, media)
                }
            }
            for await (number, media) in group {
                guard let media, let line = alternatives.first(where: { $0.0.number == number })?.0 else { continue }
                var stream = Stream(url: media)
                stream.qualityIndex = number
                result.streams["\(line.title) (\(number))"] = stream
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func playerParsers() async throws -> [String: String] {
        let script = try await AccountHTTP.request("https://dm1.xfdm.pro/static/js/playerconfig.js")
            .validate().serializingString().value
        return try playerParsers(script)
    }

    static func playerParsers(_ script: String) throws -> [String: String] {
        // MacCMS chains player_list, downer_list and server_list with commas in one statement.
        guard let match = playerListExpression.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script),
              let data = script[range].data(using: .utf8),
              let players = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw VideoGetError.notFountData
        }
        return players.compactMapValues { $0["parse"] as? String }
    }

    private static func mediaURL(_ url: String, parsers: [String: String], id: Int, line: Int, episode: Int) async throws -> String {
        let html = try await AccountHTTP.request(url).validate().serializingString().value
        guard let start = html.range(of: "var player_aaaa=")?.upperBound,
              let end = html.range(of: "</script>", range: start..<html.endIndex)?.lowerBound,
              let data = html[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";")).data(using: .utf8),
              let player = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              player["id"] as? String == "\(id)",
              player["sid"] as? Int == line,
              player["nid"] as? Int == episode,
              player["encrypt"] as? Int == 0,
              player["points"] as? Int == 0,
              player["trysee"] as? Int == 0,
              let from = player["from"] as? String, let parser = parsers[from],
              let raw = player["url"] as? String,
              let media = URL(string: raw), media.scheme?.lowercased() == "https",
              media.host != nil, media.user == nil, media.password == nil,
              ["mp4", "m3u8", "flv"].contains(media.pathExtension.lowercased()) else {
            throw VideoGetError.notFountData
        }
        // The legacy 8088 listener closes TLS handshakes. The same public MP4
        // exists on this host's standard HTTPS endpoint; verify bytes before use.
        if let migrated = legacyHTTPSMedia(media) {
            try await validateMedia(migrated, requireMP4: true)
            return migrated.absoluteString
        }
        if parser.isEmpty { return media.absoluteString }
        guard var endpoint = URLComponents(string: parser),
              endpoint.scheme == "https", endpoint.host == "player.moedot.net",
              endpoint.port == nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.path == "/player/index.php" else { throw VideoGetError.notFountData }
        // The configured index page redirects here in JavaScript and returns an encrypted ConFig payload.
        endpoint.path = "/player/ec.php"
        var query = endpoint.queryItems ?? []
        query.removeAll { $0.name == "url" }
        query.append(URLQueryItem(name: "url", value: raw))
        endpoint.queryItems = query
        guard let address = endpoint.url else { throw VideoGetError.notFountData }
        let response = try await AccountHTTP.request(address).validate().serializingString().value
        try Task.checkCancellation()
        let resolved = try resolvedMedia(response)
        try await validateMedia(URL(string: resolved)!)
        return resolved
    }

    static func legacyHTTPSMedia(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "play.xfvod.pro", parts.port == 8088,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              url.pathExtension.lowercased() == "mp4", !parts.path.isEmpty else { return nil }
        parts.port = nil
        return parts.url
    }

    /// Read only a bounded prefix; never download the movie to validate a source URL.
    private static func validateMedia(_ url: URL, requireMP4: Bool = false, referer: String? = "https://player.moedot.net/") async throws {
        // The shared transport bounds a successful probe to 64 bytes and an
        // error body to 1024 bytes, even when the server ignores Range.
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(referer == nil ? "bytes=0-" : "bytes=0-63", forHTTPHeaderField: "Range")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let response = try await AccountHTTP.mediaPrefixResponse(request, maximumResponseBytes: 1024, successPrefixBytes: 64)
        let prefix = response.data
        try validateMediaResponse(status: response.statusCode, prefix: prefix)
        if requireMP4 {
            // A redirect, an HTML page, or a filename alone cannot confirm migration.
            guard response.url == url, prefix.count >= 12,
                  prefix[4..<8] == Data("ftyp".utf8) else { throw PlaybackFailure.invalidPlayerData }
        }
    }

    static func validateMediaResponse(status: Int, prefix: Data) throws {
        if status == 401 {
            if String(decoding: prefix, as: UTF8.self).contains("expire missing") {
                throw PlaybackFailure.mediaSignatureMissing
            }
            throw PlaybackFailure.authenticationRequired
        }
        if status == 403 { throw PlaybackFailure.httpForbidden }
        if status == 404 || status == 410 { throw PlaybackFailure.mediaNotFound }
        guard (200..<300).contains(status) else { throw PlaybackFailure.playerServiceUnavailable }
    }

    static func resolvedMedia(_ html: String) throws -> String {
        guard let match = mediaExpression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let data = html[range].data(using: .utf8),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaybackFailure.invalidPlayerData
        }
        // EcPlayer1.js treats 103 as a passthrough URL, not a parser error.
        guard let code = config["code"] as? Int, [200, 103].contains(code) else { throw PlaybackFailure.playerServiceUnavailable }
        guard let type = config["type"] as? String, (type == "0" || type == "auto"),
              let settings = config["config"] as? [String: Any],
              let uid = settings["uid"] as? String, uid.utf8.count == 6,
              let encoded = config["url"] as? String,
              let ciphertext = Data(base64Encoded: encoded), !ciphertext.isEmpty else {
            throw VideoGetError.notFountData
        }
        // Matches EcPlayer1.js ad.uic: the response UID forms the per-response AES key.
        let aes = try AES(key: Array("2890\(uid)tB959C".utf8),
                          blockMode: CBC(iv: Array("2F131BE91247866E".utf8)), padding: .pkcs7)
        let plaintext = try aes.decrypt(Array(ciphertext))
        guard let raw = String(bytes: plaintext, encoding: .utf8),
              let media = URL(string: raw), media.scheme?.lowercased() == "https",
              media.host != nil, media.user == nil, media.password == nil,
              ["mp4", "m3u8", "flv"].contains(media.pathExtension.lowercased()) else {
            throw VideoGetError.notFountData
        }
        return media.absoluteString
    }
}

struct XiFanInfo: LiveInfo {
    let title: String
    let name: String
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites = .xiFan
}

extension XiFan {
    struct NextEpisode: Sendable { let id: Int; let title: String }
    struct NextLine: Sendable { let id: Int; let code: String; let title: String; let episodes: [NextEpisode] }
    struct NextCatalog: Sendable { let id: Int; let title: String; let cover: String; let lines: [NextLine] }

    // Public anonymous key shipped in the official site's client bundle, not an account credential.
    private static let nextPublicKey = "sb_publishable_OBIVAWACIX6lPXrO98_z24_HcsmalkA"

    private static func nextRequest(_ url: URL, body: Data? = nil) async throws -> Data {
        guard url.scheme == "https", ["next.xifanacg.com", "api.xifanacg.com"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { throw PlaybackFailure.unsafeMediaAddress }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("https://next.xifanacg.com/", forHTTPHeaderField: "Referer")
        if url.host == "api.xifanacg.com" {
            request.setValue(nextPublicKey, forHTTPHeaderField: "apikey")
            request.setValue("https://next.xifanacg.com", forHTTPHeaderField: "Origin")
        }
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response: SourceHTTPResponse
        do {
            response = try await AccountHTTP.response(request, allowedHosts: ["next.xifanacg.com", "api.xifanacg.com"], maximumResponseBytes: 4 * 1024 * 1024)
        } catch SourceHTTPTransportError.oversizedResponse {
            throw PlaybackFailure.invalidResponseBody
        }
        guard response.url == url else { throw PlaybackFailure.sourceRedirect }
        if response.statusCode == 401 { throw PlaybackFailure.authenticationRequired }
        if response.statusCode == 403 { throw PlaybackFailure.httpForbidden }
        guard (200..<300).contains(response.statusCode) else { throw PlaybackFailure.playerServiceUnavailable }
        guard response.data.count <= 4 * 1024 * 1024 else { throw PlaybackFailure.invalidResponseBody }
        try Task.checkCancellation()
        return response.data
    }

    static func nextCatalog(_ html: String, id: Int) throws -> NextCatalog {
        let regex = try NSRegularExpression(pattern: #"self\.__next_f\.push\((\[.*?\])\)</script>"#, options: .dotMatchesLineSeparators)
        var stream = ""
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let chunk = try? JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [Any],
                  chunk.count == 2, chunk[0] as? Int == 1, let text = chunk[1] as? String else { continue }
            stream += text
        }
        var matches: [[String: Any]] = []
        func visit(_ value: Any, depth: Int) {
            guard depth < 32 else { return }
            if let object = value as? [String: Any] {
                if let anime = object["anime"] as? [String: Any], anime["id"] as? Int == id, object["sources"] is [[String: Any]] {
                    matches.append(object); return
                }
                for child in object.values { visit(child, depth: depth + 1) }
            } else if let array = value as? [Any] { for child in array { visit(child, depth: depth + 1) } }
        }
        for row in stream.split(separator: "\n") {
            guard let colon = row.firstIndex(of: ":"),
                  let value = try? JSONSerialization.jsonObject(with: Data(row[row.index(after: colon)...].utf8)) else { continue }
            visit(value, depth: 0)
        }
        guard matches.count == 1, let object = matches.first,
              let anime = object["anime"] as? [String: Any], let title = anime["title"] as? String, !title.isEmpty,
              let sources = object["sources"] as? [[String: Any]] else { throw PlaybackFailure.catalogStructure }
        var lines: [NextLine] = [], ids = Set<Int>(), codes = Set<String>()
        for source in sources {
            guard let sid = source["id"] as? Int, sid > 0, ids.insert(sid).inserted,
                  let code = source["code"] as? String, validNextCode(code), codes.insert(code).inserted,
                  let entries = source["episodes"] as? [[String: Any]] else { throw PlaybackFailure.catalogStructure }
            var episodes: [NextEpisode] = [], seen = Set<Int>()
            for entry in entries {
                guard let eid = entry["id"] as? Int, eid > 0, seen.insert(eid).inserted,
                      let name = entry["title"] as? String, !name.isEmpty else { throw PlaybackFailure.catalogStructure }
                episodes.append(NextEpisode(id: eid, title: name))
            }
            if !episodes.isEmpty { lines.append(NextLine(id: sid, code: code, title: source["name"] as? String ?? code, episodes: episodes)) }
        }
        guard !lines.isEmpty else { throw PlaybackFailure.missingEpisode }
        return NextCatalog(id: id, title: title, cover: anime["cover_url"] as? String ?? "", lines: lines)
    }
    private static func validNextCode(_ code: String) -> Bool {
        !code.isEmpty && code.utf8.count <= 32 && code.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }
    }
    private static func nextCatalog(id: Int) async throws -> NextCatalog {
        try nextCatalog(String(decoding: await nextRequest(URL(string: "https://next.xifanacg.com/anime/\(id)")!), as: UTF8.self), id: id)
    }
    private static func nextURL(id: Int, episode: Int, code: String) -> String {
        "https://next.xifanacg.com/anime/\(id)/play/\(episode)?source=\(code)"
    }
    private static func nextEpisodes(_ raw: String) async throws -> (nodes: [VideoTreeNode], current: Int) {
        guard let page = SupportSites.xiFanNextPage(URLComponents(string: raw)!) else { throw PlaybackFailure.missingEpisode }
        let catalog = try await nextCatalog(id: page.id)
        var position = 0, current: Int?
        let nodes = catalog.lines.map { line in
            let children = line.episodes.map { episode in
                if episode.id == page.episode && (page.source == nil || page.source == line.code), current == nil { current = position }
                position += 1
                return VideoTreeNode(site: .xiFan, index: episode.id, title: episode.title, id: "next:\(catalog.id)",
                                     url: nextURL(id: catalog.id, episode: episode.id, code: line.code))
            }
            return VideoTreeNode(title: line.title, children: children)
        }
        if page.episode != nil && current == nil { throw PlaybackFailure.missingEpisode }
        return (nodes, current ?? 0)
    }
    static func nextMedia(_ data: Data, anime: Int, episode: Int, source: Int) throws -> URL {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PlaybackFailure.invalidPlayerData }
        guard object["ok"] as? Bool == true else { throw PlaybackFailure.playerServiceUnavailable }
        guard object["anime_id"] as? Int == anime, object["episode_id"] as? Int == episode,
              let raw = object["url"] as? String, let url = URL(string: raw),
              url.scheme == "https", url.user == nil, url.password == nil, url.fragment == nil,
              url.host != nil, ["mp4", "m3u8"].contains(url.pathExtension.lowercased()),
              let candidates = object["candidates"] as? [[String: Any]],
              candidates.contains(where: { $0["source_id"] as? Int == source && $0["url"] as? String == raw }) else {
            throw PlaybackFailure.missingEpisode
        }
        return url
    }
    private static func nextDecode(_ raw: String) async throws -> YouGetJSON {
        guard let page = SupportSites.xiFanNextPage(URLComponents(string: raw)!) else { throw PlaybackFailure.missingEpisode }
        let catalog = try await nextCatalog(id: page.id)
        guard let line = page.source == nil ? catalog.lines.first : catalog.lines.first(where: { $0.code == page.source }),
              let episode = page.episode == nil ? line.episodes.first : line.episodes.first(where: { $0.id == page.episode }) else {
            throw PlaybackFailure.missingEpisode
        }
        let body = try JSONSerialization.data(withJSONObject: ["action": "fallback", "episode_id": episode.id, "source_id": line.id])
        let data = try await nextRequest(URL(string: "https://api.xifanacg.com/functions/v1/issue-web-playback")!, body: body)
        let media = try nextMedia(data, anime: catalog.id, episode: episode.id, source: line.id)
        // The cloud redirect rejects the legacy player Referer. Match the
        // direct media handoff, without forwarding legacy/plugin headers.
        try await validateMedia(media, referer: nil)
        var result = YouGetJSON(rawUrl: raw)
        result.title = "\(catalog.title) - \(episode.title)"
        result.streams[line.title] = Stream(url: media.absoluteString)
        return result
    }
}