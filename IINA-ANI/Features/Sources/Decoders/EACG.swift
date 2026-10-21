//
//  EACG.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation
import Alamofire
import SwiftSoup

actor EACG: SupportSiteProtocol {
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
              let page = SupportSites.eacgPage(components) else { throw VideoGetError.invalidLink }
        return page
    }

    private func catalog(_ id: Int) async throws -> Catalog {
        let base = URL(string: "https://www.eacg1.com/voddetails-\(id).html")!
        let html = try await AccountHTTP.request(base).validate().serializingString().value
        let document = try SwiftSoup.parse(html)
        guard let title = try document.select(".fed-deta-info h1").first()?.text(),
              !title.isEmpty else { throw VideoGetError.notFountData }
        let coverPath = try document.select(".fed-deta-images a[data-original]").first()?.attr("data-original") ?? ""
        let cover = URL(string: coverPath, relativeTo: base)?.absoluteURL.absoluteString ?? ""

        var names: [String] = []
        for tab in try document.select(".fed-tabs-boxs .fed-play-btns a") {
            names.append(try tab.text())
        }
        var lines: [Line] = []
        for (offset, list) in (try document.select(".fed-tabs-boxs .fed-play-item")).enumerated() {
            var episodes: [Episode] = []
            var number: Int?
            for link in try list.select("a[href]") {
                let href = try link.attr("href")
                guard let address = URL(string: href, relativeTo: base)?.absoluteURL,
                      let components = URLComponents(url: address, resolvingAgainstBaseURL: false),
                      let item = SupportSites.eacgPage(components), item.id == id,
                      let line = item.line, let episode = item.episode else { continue }
                if let number, number != line { continue }
                number = line
                episodes.append(Episode(number: episode, title: try link.text(), url: address.absoluteString))
            }
            if let number, !episodes.isEmpty {
                let title = offset < names.count ? names[offset] : "Line \(number)"
                lines.append(Line(number: number, title: title, episodes: episodes))
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
                return VideoTreeNode(site: .eacg, index: episode.number,
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
        return EACGInfo(title: data.title, name: data.title, cover: data.cover, isLiving: available)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let address = try page(url)
        let data = try await catalog(address.id)
        guard let line = address.line == nil ? data.lines.first : data.lines.first(where: { $0.number == address.line }),
              let episode = address.episode == nil ? line.episodes.first : line.episodes.first(where: { $0.number == address.episode }) else {
            throw VideoGetError.notFountData
        }
        let media = try await Self.mediaURL(episode.url)
        var result = YouGetJSON(rawUrl: url)
        result.title = "\(data.title) - \(episode.title)"
        var stream = Stream(url: media)
        stream.qualityIndex = 0
        result.streams["\(line.title) (\(line.number))"] = stream

        let alternatives = data.lines.filter { $0.number != line.number }.compactMap { other -> (Line, Episode)? in
            guard let match = other.episodes.first(where: { $0.number == episode.number }) else { return nil }
            return (other, match)
        }
        await withTaskGroup(of: (Int, String?).self) { group in
            for (other, match) in alternatives {
                group.addTask { (other.number, try? await Self.mediaURL(match.url)) }
            }
            for await (number, url) in group {
                guard let url, let other = alternatives.first(where: { $0.0.number == number })?.0 else { continue }
                var stream = Stream(url: url)
                stream.qualityIndex = number
                result.streams["\(other.title) (\(number))"] = stream
            }
        }
        try Task.checkCancellation()
        return result
    }

    private static func mediaURL(_ url: String) async throws -> String {
        let html = try await AccountHTTP.request(url).validate().serializingString().value
        let document = try SwiftSoup.parse(html)
        guard let frame = try document.select("#fed-play-iframe").first(),
              try frame.attr("data-lock") == "0", try frame.attr("data-pass") == "1",
              try frame.attr("data-trys") == "0", try frame.attr("data-code") == "1" else {
            throw VideoGetError.notFountData
        }
        // The site's player stores a three-character prefix followed by a base64 media URL.
        let encoded = try frame.attr("data-play")
        guard encoded.count > 3,
              let bytes = Data(base64Encoded: String(encoded.dropFirst(3))),
              let raw = String(data: bytes, encoding: .utf8),
              let media = URL(string: raw), media.scheme?.lowercased() == "https",
              media.host != nil, media.user == nil, media.password == nil,
              ["m3u8", "mp4"].contains(media.pathExtension.lowercased()) else {
            throw VideoGetError.notFountData
        }
        return media.absoluteString
    }
}

struct EACGInfo: LiveInfo {
    let title: String
    let name: String
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites = .eacg
}
