//
//  Senfun.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation
import Alamofire
import SwiftSoup

actor Senfun: SupportSiteProtocol {
    private struct Episode: Sendable {
        let slug: String
        let title: String
        let url: String
    }

    private struct Catalog: Sendable {
        let title: String
        let cover: String
        let episodes: [Episode]
    }

    private struct PlaysResponse: Decodable, Sendable {
        struct Play: Decodable, Sendable {
            let play_data: String
            let src_site: String
        }
        let video_plays: [Play]
    }

    private func page(_ url: String) throws -> (id: Int, episode: String?) {
        guard let components = URLComponents(string: url),
              let page = SupportSites.senfunPage(components) else { throw VideoGetError.invalidLink }
        return page
    }

    private func catalog(_ id: Int) async throws -> Catalog {
        let base = URL(string: "https://senfun.in/voddetail/\(id).html")!
        let html = try await AccountHTTP.request(base).validate().serializingString().value
        let document = try SwiftSoup.parse(html)
        guard let title = try document.select(".module-info-heading h1").first()?.text(),
              !title.isEmpty else { throw VideoGetError.notFountData }
        let coverPath = try document.select(".module-info-poster img[data-original]").first()?.attr("data-original") ?? ""
        let cover = URL(string: coverPath, relativeTo: base)?.absoluteURL.absoluteString ?? ""

        var episodes: [Episode] = []
        for list in try document.select(".module-play-list-content") {
            for link in try list.select("a[href]") {
                let href = try link.attr("href")
                guard let address = URL(string: href, relativeTo: base)?.absoluteURL,
                      let components = URLComponents(url: address, resolvingAgainstBaseURL: false),
                      let item = SupportSites.senfunPage(components), item.id == id,
                      let slug = item.episode else { continue }
                episodes.append(Episode(slug: slug, title: try link.text(), url: address.absoluteString))
            }
        }
        guard !episodes.isEmpty else { throw VideoGetError.notFountData }
        return Catalog(title: title, cover: cover, episodes: episodes)
    }

    private func episode(_ address: (id: Int, episode: String?), _ data: Catalog) throws -> Episode {
        guard let slug = address.episode else {
            guard let first = data.episodes.first else { throw VideoGetError.notFountData }
            return first
        }
        guard let episode = data.episodes.first(where: { $0.slug == slug }) else {
            throw VideoGetError.notFountData
        }
        return episode
    }

    func episodeList(_ url: String) async throws -> (nodes: [VideoTreeNode], current: Int) {
        let address = try page(url)
        let data = try await catalog(address.id)
        var current = 0
        let children = data.episodes.enumerated().map { offset, episode -> VideoTreeNode in
            if episode.slug == address.episode { current = offset }
            return VideoTreeNode(site: .senfun, index: offset + 1,
                                 title: episode.title, id: "\(address.id)", url: episode.url)
        }
        if address.episode != nil,
           !data.episodes.contains(where: { $0.slug == address.episode }) {
            throw VideoGetError.notFountData
        }
        return ([VideoTreeNode(title: data.title, children: children)], current)
    }

    func liveInfo(_ url: String) async throws -> any LiveInfo {
        let address = try page(url)
        let data = try await catalog(address.id)
        let available = address.episode == nil || data.episodes.contains { $0.slug == address.episode }
        return SenfunInfo(title: data.title, name: data.title, cover: data.cover, isLiving: available)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let address = try page(url)
        let data = try await catalog(address.id)
        let episode = try episode(address, data)
        let lines = try await Self.lines(id: address.id, slug: episode.slug)
        var result = YouGetJSON(rawUrl: url)
        result.title = "\(data.title) - \(episode.title)"
        for (offset, line) in lines.enumerated() {
            var stream = Stream(url: line.url)
            stream.qualityIndex = offset + 1
            result.streams["\(line.site.uppercased()) (\(offset + 1))"] = stream
        }
        guard !result.streams.isEmpty else { throw VideoGetError.notFountData }
        return result
    }

    private static func lines(id: Int, slug: String) async throws -> [(site: String, url: String)] {
        let endpoint = "https://senfun.in/_senfun_plays/\(id)/\(slug)"
        let response = try await AccountHTTP.request(endpoint).validate().serializingDecodable(PlaysResponse.self).value
        return response.video_plays.compactMap { play in
            guard let media = URL(string: play.play_data),
                  media.scheme?.lowercased() == "https",
                  media.host != nil, media.user == nil, media.password == nil,
                  ["m3u8", "mp4"].contains(media.pathExtension.lowercased()) else { return nil }
            return (play.src_site, media.absoluteString)
        }
    }
}

struct SenfunInfo: LiveInfo {
    let title: String
    let name: String
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites = .senfun
}
