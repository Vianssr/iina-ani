//
//  Wedm.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation
import Alamofire
import SwiftSoup

actor Wedm: SupportSiteProtocol {
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

    private func page(_ raw: String) throws -> (id: String, line: Int?, episode: Int?) {
        guard let components = URLComponents(string: raw),
              let page = SupportSites.wedmPage(components) else { throw VideoGetError.invalidLink }
        return page
    }

    private func catalog(_ id: String) async throws -> Catalog {
        let base = URL(string: "https://www.vdm5.com/vodetail_\(id).html")!
        let html = try await AccountHTTP.request(base).validate().serializingString().value
        try Task.checkCancellation()
        let document = try SwiftSoup.parse(html)
        guard let title = try document.select("h1.title").first()?.ownText(),
              !title.isEmpty else { throw VideoGetError.notFountData }
        let coverPath = try document.select(".stui-content__thumb img").first()?.attr("data-original") ?? ""
        let cover = URL(string: coverPath, relativeTo: base)?.absoluteURL.absoluteString ?? ""
        var lines: [Line] = []
        for panel in try document.select(".stui-pannel:has(.stui-content__playlist)") {
            var episodes: [Episode] = []
            var seen = Set<Int>()
            var lineNumber: Int?
            for link in try panel.select(".stui-content__playlist a[href]") {
                guard let address = URL(string: try link.attr("href"), relativeTo: base)?.absoluteURL,
                      let components = URLComponents(url: address, resolvingAgainstBaseURL: false),
                      let item = SupportSites.wedmPage(components), item.id == id,
                      let line = item.line, let episode = item.episode,
                      lineNumber == nil || lineNumber == line else { continue }
                lineNumber = line
                guard seen.insert(episode).inserted else { continue }
                episodes.append(Episode(number: episode, title: try link.text(), url: address.absoluteString))
            }
            if let lineNumber, !episodes.isEmpty {
                let label = try panel.select("h3.title").first()?.text() ?? ""
                lines.append(Line(number: lineNumber, title: label.isEmpty ? "Line \(lineNumber)" : label,
                                  episodes: episodes))
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
                return VideoTreeNode(site: .wedm, index: episode.number, title: episode.title,
                                     id: address.id, url: episode.url)
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
        return WedmInfo(title: data.title, name: data.title, cover: data.cover, isLiving: available)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let address = try page(url)
        let data = try await catalog(address.id)
        guard let line = address.line == nil ? data.lines.first : data.lines.first(where: { $0.number == address.line }),
              let episode = address.episode == nil ? line.episodes.first : line.episodes.first(where: { $0.number == address.episode }) else {
            throw VideoGetError.notFountData
        }
        let media = try await Self.mediaURL(episode.url, id: address.id, line: line.number,
                                            episode: episode.number)
        var result = YouGetJSON(rawUrl: url)
        result.title = "\(data.title) - \(episode.title)"
        var stream = Stream(url: media)
        stream.qualityIndex = line.number
        result.streams["\(line.title) (\(line.number))"] = stream
        let alternatives = data.lines.compactMap { other -> (Line, Episode)? in
            guard other.number != line.number,
                  let match = other.episodes.first(where: { $0.title == episode.title }) ??
                    other.episodes.first(where: { $0.number == episode.number }) else { return nil }
            return (other, match)
        }
        await withTaskGroup(of: (Int, String?).self) { group in
            for (other, match) in alternatives {
                group.addTask { (other.number, try? await Self.mediaURL(match.url, id: address.id,
                                                                         line: other.number, episode: match.number)) }
            }
            for await (number, media) in group {
                guard let media, let other = alternatives.first(where: { $0.0.number == number })?.0 else { continue }
                var stream = Stream(url: media)
                stream.qualityIndex = number
                result.streams["\(other.title) (\(number))"] = stream
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func mediaURL(_ raw: String, id: String, line: Int, episode: Int) async throws -> String {
        let html = try await AccountHTTP.request(raw).validate().serializingString().value
        try Task.checkCancellation()
        guard let start = html.range(of: "var player_aaaa=")?.upperBound,
              let end = html.range(of: "</script>", range: start..<html.endIndex)?.lowerBound,
              let data = html[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";")).data(using: .utf8),
              let player = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              player["id"] as? String == id, player["sid"] as? Int == line,
              player["nid"] as? Int == episode, player["points"] as? Int == 0,
              player["trysee"] as? Int == 0,
              let encoding = player["encrypt"] as? Int,
              let encoded = player["url"] as? String else { throw VideoGetError.notFountData }
        let decoded: String?
        switch encoding {
        case 0: decoded = encoded
        case 1: decoded = encoded.removingPercentEncoding
        case 2:
            decoded = Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }?.removingPercentEncoding
        default: decoded = nil
        }
        guard let decoded, let url = URL(string: decoded), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil,
              ["m3u8", "mp4"].contains(url.pathExtension.lowercased()) else {
            throw VideoGetError.notFountData
        }
        return url.absoluteString
    }
}

struct WedmInfo: LiveInfo {
    let title: String
    let name: String
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites = .wedm
}
