//
//  XiFan.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation
import Alamofire
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
        let address = try page(url)
        let data = try await catalog(address.id)
        let available = address.episode == nil || data.lines.contains { line in
            line.number == address.line && line.episodes.contains { $0.number == address.episode }
        }
        return XiFanInfo(title: data.title, name: data.title, cover: data.cover, isLiving: available)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
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
        return try resolvedMedia(response)
    }

    static func resolvedMedia(_ html: String) throws -> String {
        guard let match = mediaExpression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let data = html[range].data(using: .utf8),
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              config["code"] as? Int == 200, let type = config["type"] as? String, (type == "0" || type == "auto"),
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
