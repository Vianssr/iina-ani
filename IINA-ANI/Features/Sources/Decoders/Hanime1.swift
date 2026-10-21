//
//  Hanime1.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation
import Alamofire
import SwiftSoup

actor Hanime1: SupportSiteProtocol {
    private struct Video: Sendable {
        let title: String
        let cover: String
        let streams: [Int: String]
    }

    private func video(_ raw: String) async throws -> Video {
        guard let components = URLComponents(string: raw),
              SupportSites.hanime1Page(components) != nil,
              let url = components.url else { throw VideoGetError.invalidLink }
        let html = try await AccountHTTP.request(url).validate().serializingString().value
        try Task.checkCancellation()
        let document = try SwiftSoup.parse(html)
        let title = try (document.select("h1, h3.video-details-wrapper").first()?.text()
            ?? document.select("meta[name=title]").first()?.attr("content")
            ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw VideoGetError.notFountData }
        let coverPath = try document.select("meta[property=og:image]").first()?.attr("content") ?? ""
        let cover = URL(string: coverPath, relativeTo: url)?.absoluteURL.absoluteString ?? ""
        var streams: [Int: String] = [:]
        for source in try document.select("video#player source[src][size]") {
            guard let quality = Int(try source.attr("size")), quality > 0,
                  let media = URL(string: try source.attr("src"), relativeTo: url)?.absoluteURL,
                  media.scheme?.lowercased() == "https", media.host != nil,
                  media.user == nil, media.password == nil,
                  media.pathExtension.lowercased() == "mp4" else { continue }
            streams[quality] = media.absoluteString
        }
        guard !streams.isEmpty else { throw VideoGetError.notFountData }
        return Video(title: title, cover: cover, streams: streams)
    }

    func liveInfo(_ url: String) async throws -> any LiveInfo {
        let data = try await video(url)
        return Hanime1Info(title: data.title, name: data.title, cover: data.cover, isLiving: true)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let data = try await video(url)
        var result = YouGetJSON(rawUrl: url)
        result.title = data.title
        for (quality, media) in data.streams {
            var stream = Stream(url: media)
            stream.quality = quality
            result.streams["\(quality)p"] = stream
        }
        return result
    }
}

struct Hanime1Info: LiveInfo {
    let title: String
    let name: String
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites = .hanime1
}
