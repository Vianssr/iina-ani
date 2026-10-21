//
//  Girigiri.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation
import Alamofire
import SwiftSoup

actor Girigiri: SupportSiteProtocol {
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
              let page = SupportSites.girigiriPage(components) else {
            throw VideoGetError.invalidLink
        }
        return page
    }

    private func catalog(_ id: Int) async throws -> Catalog {
        let url = "https://ani.girigirilove.com/GV\(id)/"
        let html = try await AccountHTTP.request(url).validate().serializingString().value
        let document = try SwiftSoup.parse(html)
        guard let title = try document.select(".detail-info .slide-info-title").first()?.text(),
              !title.isEmpty else { throw VideoGetError.notFountData }
        let image = try document.select(".detail-pic img").first()
        let coverPath = try image?.attr("data-src") ?? ""
        let cover = URL(string: coverPath, relativeTo: URL(string: url))?.absoluteURL.absoluteString ?? ""
        let tabs = try document.select(".anthology-tab .swiper-slide")
        let boxes = try document.select(".anthology-list-box")
        var lines: [Line] = []
        for (index, tab) in tabs.enumerated() where index < boxes.count {
            let number = index + 1
            let name = tab.ownText().trimmingCharacters(in: .whitespacesAndNewlines)
            let links = try boxes.get(index).select("a[href]")
            var episodes: [Episode] = []
            for link in links {
                let href = try link.attr("href")
                guard let address = URL(string: href, relativeTo: URL(string: url))?.absoluteURL,
                      let components = URLComponents(url: address, resolvingAgainstBaseURL: false),
                      let parts = SupportSites.girigiriPage(components),
                      parts.id == id, parts.line == number, let episode = parts.episode else { continue }
                episodes.append(Episode(number: episode, title: try link.text(), url: address.absoluteString))
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
                return VideoTreeNode(site: .girigiri, index: episode.number,
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
        return GirigiriInfo(title: data.title, name: data.title, cover: data.cover, isLiving: available)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let address = try page(url)
        let data = try await catalog(address.id)
        guard let selectedLine = address.line == nil ? data.lines.first : data.lines.first(where: { $0.number == address.line }),
              let selectedEpisode = address.episode == nil ? selectedLine.episodes.first : selectedLine.episodes.first(where: { $0.number == address.episode }) else {
            throw VideoGetError.notFountData
        }
        let selectedURL = try await Self.mediaURL(selectedEpisode.url, id: address.id,
                                                   line: selectedLine.number, episode: selectedEpisode.number)
        var result = YouGetJSON(rawUrl: url)
        result.title = "\(data.title) - \(selectedEpisode.title)"
        var selectedStream = Stream(url: selectedURL)
        selectedStream.qualityIndex = selectedLine.number - 1
        result.streams["\(selectedLine.title) (\(selectedLine.number))"] = selectedStream

        let alternatives = data.lines.filter { $0.number != selectedLine.number }.compactMap { line -> (Line, Episode)? in
            guard let episode = line.episodes.first(where: { $0.number == selectedEpisode.number }) else { return nil }
            return (line, episode)
        }
        await withTaskGroup(of: (Int, String?).self) { group in
            for (line, episode) in alternatives {
                group.addTask {
                    let media = try? await Self.mediaURL(episode.url, id: address.id,
                                                         line: line.number, episode: episode.number)
                    return (line.number, media)
                }
            }
            for await (number, media) in group {
                guard let media, let line = alternatives.first(where: { $0.0.number == number })?.0 else { continue }
                var stream = Stream(url: media)
                stream.qualityIndex = number - 1
                result.streams["\(line.title) (\(number))"] = stream
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
              player["id"] as? String == "\(id)",
              player["sid"] as? Int == line,
              player["nid"] as? Int == episode,
              player["points"] as? Int == 0,
              player["trysee"] as? Int == 0,
              let encoded = player["url"] as? String,
              let encrypt = player["encrypt"] as? Int else {
            throw VideoGetError.notFountData
        }
        let raw: String?
        switch encrypt {
        case 0: raw = encoded
        case 1: raw = encoded.removingPercentEncoding
        case 2:
            raw = Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }?.removingPercentEncoding
        default: raw = nil
        }
        guard let raw, let media = URL(string: raw),
              media.scheme?.lowercased() == "https", media.host != nil,
              media.user == nil, media.password == nil,
              ["mp4", "m3u8"].contains(media.pathExtension.lowercased()) else {
            throw VideoGetError.notFountData
        }
        return media.absoluteString
    }
}

struct GirigiriInfo: LiveInfo {
    let title: String
    let name: String
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites = .girigiri
}
