//
//  Dilidili.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation
import Alamofire
import SwiftSoup

actor Dilidili: SupportSiteProtocol {
    private struct Episode: Sendable {
        let title: String
        let url: String
    }

    private struct Catalog: Sendable {
        let title: String
        let cover: String
        let episodes: [Episode]
    }

    private func address(_ raw: String) throws -> (URL, SupportSites.DilidiliPage) {
        guard let url = URL(string: raw),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let page = SupportSites.dilidiliPage(components) else { throw VideoGetError.invalidLink }
        return (url, page)
    }

    private func document(_ url: URL) async throws -> Document {
        let html = try await AccountHTTP.request(url).validate().serializingString().value
        try Task.checkCancellation()
        return try SwiftSoup.parse(html)
    }

    private func catalog(_ raw: String) async throws -> (Catalog, String?) {
        let (url, page) = try address(raw)
        let slug: String
        let selected: String?
        switch page {
        case .anime(let name):
            slug = name
            selected = nil
        case .watch(let name):
            selected = name
            let watch = try await document(url)
            guard let link = try watch.select("#link a[href]").first(where: {
                let href = try $0.attr("href")
                guard let target = URL(string: href, relativeTo: url)?.absoluteURL,
                      let components = URLComponents(url: target, resolvingAgainstBaseURL: false),
                      case .anime = SupportSites.dilidiliPage(components) else { return false }
                return true
            }),
                  let detail = URL(string: try link.attr("href"), relativeTo: url)?.absoluteURL,
                  let components = URLComponents(url: detail, resolvingAgainstBaseURL: false),
                  case .anime(let name) = SupportSites.dilidiliPage(components) else {
                throw VideoGetError.notFountData
            }
            slug = name
        }

        let base = URL(string: "https://dilidili.io/anime/\(slug)/")!
        let detail = try await document(base)
        guard let title = try detail.select("h1").first()?.text(), !title.isEmpty else {
            throw VideoGetError.notFountData
        }
        let coverPath = try detail.select("dl dt img").first()?.attr("src") ?? ""
        let cover = URL(string: coverPath, relativeTo: base)?.absoluteURL.absoluteString ?? ""
        var seen = Set<String>()
        var episodes: [Episode] = []
        for link in try detail.select(".swiper-slide a[href]") {
            let href = try link.attr("href")
            guard let target = URL(string: href, relativeTo: base)?.absoluteURL,
                  let components = URLComponents(url: target, resolvingAgainstBaseURL: false),
                  case .watch(let name) = SupportSites.dilidiliPage(components),
                  seen.insert(name).inserted else { continue }
            let label = try link.select("span").first()?.text() ?? ""
            let title = label.isEmpty ? try link.text() : label
            episodes.append(Episode(title: title, url: target.absoluteString))
        }
        guard !episodes.isEmpty, selected == nil || episodes.contains(where: {
            URL(string: $0.url)?.lastPathComponent == selected
        }) else { throw VideoGetError.notFountData }
        return (Catalog(title: title, cover: cover, episodes: episodes), selected)
    }

    func episodeList(_ url: String) async throws -> (nodes: [VideoTreeNode], current: Int) {
        let (data, selected) = try await catalog(url)
        let current = data.episodes.firstIndex {
            URL(string: $0.url)?.lastPathComponent == selected
        } ?? 0
        let children = data.episodes.enumerated().map { index, episode in
            VideoTreeNode(site: .dilidili, index: index, title: episode.title,
                          id: episode.url, url: episode.url)
        }
        return ([VideoTreeNode(title: data.title, children: children)], current)
    }

    func liveInfo(_ url: String) async throws -> any LiveInfo {
        let (data, _) = try await catalog(url)
        return DilidiliInfo(title: data.title, name: data.title, cover: data.cover, isLiving: true)
    }

    private static func media(_ id: String) async throws -> String {
        var components = URLComponents(string: "https://dilidili.io/_get_play")!
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        let body = try await AccountHTTP.request(components.url!).validate().serializingData().value
        try Task.checkCancellation()
        guard let response = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              response["id"] as? String == "_get_play_\(id)",
              let result = response["result"] as? [String: Any],
              let format = result["play_cfg"] as? String,
              ["mp4", "m3u8"].contains(format),
              let raw = result["play_data"] as? String,
              let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.pathExtension.lowercased() == format else { throw VideoGetError.notFountData }
        return url.absoluteString
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let (data, selected) = try await catalog(url)
        guard let episode = selected == nil ? data.episodes.first : data.episodes.first(where: {
            URL(string: $0.url)?.lastPathComponent == selected
        }) else { throw VideoGetError.notFountData }
        let page = try await document(URL(string: episode.url)!)
        var lines: [(String, String)] = []
        for button in try page.select("button.play-btn[play_id]") {
            let id = try button.attr("play_id")
            guard !id.isEmpty, id.allSatisfy(\.isNumber) else { continue }
            lines.append((try button.text(), id))
        }
        guard !lines.isEmpty else { throw VideoGetError.notFountData }

        var result = YouGetJSON(rawUrl: url)
        result.title = "\(data.title) - \(episode.title)"
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, line) in lines.enumerated() {
                group.addTask { (index, try? await Self.media(line.1)) }
            }
            for await (index, media) in group {
                guard let media else { continue }
                var stream = Stream(url: media)
                stream.qualityIndex = index
                result.streams["\(lines[index].0) (\(index + 1))"] = stream
            }
        }
        try Task.checkCancellation()
        guard !result.streams.isEmpty else { throw VideoGetError.notFountData }
        return result
    }
}

struct DilidiliInfo: LiveInfo {
    let title: String
    let name: String
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites = .dilidili
}
