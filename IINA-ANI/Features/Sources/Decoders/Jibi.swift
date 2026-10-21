//
//  Jibi.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation
import Alamofire
import SwiftSoup

actor Jibi: SupportSiteProtocol {
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
              let page = SupportSites.jibiPage(components) else { throw VideoGetError.invalidLink }
        return page
    }

    private func catalog(_ id: Int) async throws -> Catalog {
        let base = URL(string: "https://www.jibi.cc/index.php/vod/detail/id/\(id).html")!
        let html = try await AccountHTTP.request(base).validate().serializingString().value
        let document = try SwiftSoup.parse(html)
        guard let title = try document.select(".module-info-heading h1").first()?.text(),
              !title.isEmpty else { throw VideoGetError.notFountData }
        let coverPath = try document.select(".module-info-poster img").first()?.attr("data-original") ?? ""
        let cover = URL(string: coverPath, relativeTo: base)?.absoluteURL.absoluteString ?? ""

        // The tab order may differ from the episode-list order; associate by sid, not position.
        var names: [Int: String] = [:]
        for tab in try document.select(".module-tab-item[data-dropdown-value]") {
            let name = try tab.attr("data-dropdown-value")
            if let suffix = name.range(of: "叽哔"), name.hasSuffix("线"),
               let number = Int(name[suffix.upperBound..<name.index(before: name.endIndex)]), number > 0 {
                names[number] = name
            }
        }
        var lines: [Line] = []
        for list in try document.select(".module-play-list") {
            var episodes: [Episode] = []
            var lineNumber: Int?
            for link in try list.select("a.module-play-list-link[href]") {
                let href = try link.attr("href")
                guard let address = URL(string: href, relativeTo: base)?.absoluteURL,
                      let components = URLComponents(url: address, resolvingAgainstBaseURL: false),
                      let parts = SupportSites.jibiPage(components), parts.id == id,
                      let line = parts.line, let episode = parts.episode,
                      lineNumber == nil || lineNumber == line else { continue }
                lineNumber = line
                episodes.append(Episode(number: episode, title: try link.text(), url: address.absoluteString))
            }
            if let lineNumber, !episodes.isEmpty {
                lines.append(Line(number: lineNumber, title: names[lineNumber] ?? "Line \(lineNumber)", episodes: episodes))
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
                if line.number == address.line && episode.number == address.episode { current = position }
                position += 1
                return VideoTreeNode(site: .jibi, index: episode.number,
                                     title: episode.title, id: "\(address.id)", url: episode.url)
            }
            return VideoTreeNode(title: line.title, children: children)
        }
        if address.episode != nil && !data.lines.contains(where: { line in
            line.number == address.line && line.episodes.contains(where: { $0.number == address.episode })
        }) { throw VideoGetError.notFountData }
        return (nodes, current)
    }

    func liveInfo(_ url: String) async throws -> any LiveInfo {
        let address = try page(url)
        let data = try await catalog(address.id)
        let available = address.episode == nil || data.lines.contains { line in
            line.number == address.line && line.episodes.contains { $0.number == address.episode }
        }
        return JibiInfo(title: data.title, name: data.title, cover: data.cover, isLiving: available)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let address = try page(url)
        let data = try await catalog(address.id)
        guard let line = address.line == nil ? data.lines.first : data.lines.first(where: { $0.number == address.line }),
              let episode = address.episode == nil ? line.episodes.first : line.episodes.first(where: { $0.number == address.episode }) else {
            throw VideoGetError.notFountData
        }
        let media = try await Self.mediaURL(episode.url, id: address.id, line: line.number, episode: episode.number)
        var result = YouGetJSON(rawUrl: url)
        result.title = "\(data.title) - \(episode.title)"
        var stream = Stream(url: media)
        stream.qualityIndex = 0
        result.streams["\(line.title) (\(line.number))"] = stream
        // Other lines are only offered if their matching episode has a direct, unrestricted URL.
        let alternatives = data.lines.filter { $0.number != line.number }.compactMap { other -> (Line, Episode)? in
            guard let match = other.episodes.first(where: { $0.number == episode.number }) else { return nil }
            return (other, match)
        }
        await withTaskGroup(of: (Int, String?).self) { group in
            for (other, match) in alternatives {
                group.addTask {
                    (other.number, try? await Self.mediaURL(match.url, id: address.id,
                                                              line: other.number, episode: match.number))
                }
            }
            for await (number, url) in group {
                guard let url, let other = alternatives.first(where: { $0.0.number == number })?.0 else { continue }
                var stream = Stream(url: url)
                stream.qualityIndex = number + 1
                result.streams["\(other.title) (\(number))"] = stream
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func mediaURL(_ url: String, id: Int, line: Int, episode: Int) async throws -> String {
        let html = try await AccountHTTP.request(url).validate().serializingString().value
        guard let start = html.range(of: "var player_aaaa=")?.upperBound,
              let end = html.range(of: "</script>", range: start..<html.endIndex)?.lowerBound,
              let data = html[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";")).data(using: .utf8),
              let player = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              player["id"] as? String == "\(id)", player["sid"] as? Int == line,
              player["nid"] as? Int == episode, player["points"] as? Int == 0,
              player["trysee"] as? Int == 0, player["encrypt"] as? Int == 0,
              let raw = player["url"] as? String,
              let media = URL(string: raw), media.scheme?.lowercased() == "https",
              media.host != nil, media.user == nil, media.password == nil,
              ["mp4", "m3u8"].contains(media.pathExtension.lowercased()) else {
            throw VideoGetError.notFountData
        }
        return media.absoluteString
    }
}

struct JibiInfo: LiveInfo {
    let title: String
    let name: String
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites = .jibi
}
