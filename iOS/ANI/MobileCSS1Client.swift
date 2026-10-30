import Foundation
import CoreFoundation
import SwiftSoup

/// Executes the supported declarative CSS1 subset. Pages are parsed as data; scripts never execute.
struct MobileCSS1Client: Sendable {
    let configuration: SourceConfiguration
    let fetch: @Sendable (URL) async throws -> Data

    func search(keyword: String) async throws -> MobileSourcePage {
        guard let spec = configuration.webSelector, let search = configuration.search,
              !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              keyword.utf8.count <= 1024 else { throw PlaybackFailure.unsupportedResponse }
        let url = try configuration.requestURL(configuration.expanded(search.url, values: ["query": keyword, "page": "1"]))
        let data = try await body(url)
        let names: [String]
        let links: [String]
        if spec.subjectFormat == "json-path-indexed" {
            guard let root = try? JSONSerialization.jsonObject(with: data) else { throw PlaybackFailure.unsupportedResponse }
            names = try jsonValues(root, path: spec.searchNames)
            links = try jsonValues(root, path: spec.searchLinks)
        } else {
            let doc = try document(data)
            guard spec.subjectFormat == "a" || spec.subjectFormat == "indexed" else { throw PlaybackFailure.unsupportedResponse }
            names = try doc.select(spec.searchNames).map(title)
            // Indexed selectors can also match non-link controls such as bookmark buttons.
            // Exclude only nodes without href; retain empty/invalid hrefs for count validation.
            links = try doc.select(spec.searchLinks).filter { spec.subjectFormat != "indexed" || $0.hasAttr("href") }.map { try $0.attr("href") }
        }
        guard names.count == links.count, names.count <= 10_000 else { throw PlaybackFailure.unsupportedResponse }
        let base = spec.relativeLinksUseSearchURL == true ? url : try configuration.requestURL(spec.baseURL)
        var works: [MobileSourceWork] = []
        var seen = Set<SourceItemRef>()
        for (name, link) in zip(names, links) {
            try Task.checkCancellation()
            let raw = spec.linkTemplate.map { configuration.expanded($0, values: ["value": link]) } ?? link
            guard !name.isEmpty, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let url = URL(string: raw, relativeTo: base)?.absoluteURL,
                  let item = try? configuration.webItem(url.absoluteString, kind: .work),
                  seen.insert(item).inserted else { continue }
            works.append(.init(item: item, title: name))
        }
        if !names.isEmpty && works.isEmpty { throw PlaybackFailure.unsupportedResponse }
        return .init(works: works, nextPage: nil)
    }

    func catalog(work: MobileSourceWork) async throws -> MobileSourceCatalog {
        guard let spec = configuration.webSelector, work.item.sourceID == configuration.id,
              work.item.kind == .work,
              try configuration.webItem(work.item.pageURL, kind: .work) == work.item else {
            throw PlaybackFailure.missingEpisode
        }
        let url = try configuration.requestURL(work.item.pageURL)
        let doc = try document(await body(url))
        let panels: [Element]
        let names: [String]
        switch spec.channelFormat {
        case "no-channel": panels = [doc]; names = []
        case "index-grouped":
            guard let selector = spec.episodeLists else { throw PlaybackFailure.unsupportedResponse }
            panels = try doc.select(selector).array()
            let labels = try spec.channelNames.map { try doc.select($0).map(title) } ?? []
            names = labels.count == panels.count ? labels : []
        default: throw PlaybackFailure.unsupportedResponse
        }
        guard panels.count <= 100 else { throw PlaybackFailure.unsupportedResponse }
        var lines: [MobileSourceLine] = []
        var seen = Set<SourceItemRef>()
        for (index, panel) in panels.enumerated() {
            let episodeNames = try panel.select(spec.episodeNames).map(title)
            let episodeLinks = try panel.select(spec.episodeLinks ?? spec.episodeNames).map { try $0.attr("href") }
            guard episodeNames.count == episodeLinks.count, episodeNames.count <= 10_000 else { throw PlaybackFailure.unsupportedResponse }
            var episodes: [MobileSourceEpisode] = []
            for (position, pair) in zip(episodeNames, episodeLinks).enumerated() {
                try Task.checkCancellation()
                guard !pair.0.isEmpty, !pair.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let target = URL(string: pair.1, relativeTo: url)?.absoluteURL,
                      let item = try? configuration.webItem(target.absoluteString, kind: .episode),
                      seen.insert(item).inserted else { continue }
                episodes.append(.init(item: item, title: pair.0, line: index + 1, number: displayNumber(pair.0) ?? position + 1, identity: item.pageURL))
            }
            if !episodes.isEmpty {
                let name = names.indices.contains(index) && !names[index].isEmpty ? names[index] : String(index + 1)
                lines.append(.init(id: index + 1, title: name, episodes: episodes))
            }
        }
        guard !lines.isEmpty else { throw PlaybackFailure.missingEpisode }
        return .init(work: work, lines: lines)
    }

    func resolve(episode: MobileSourceEpisode, catalog: MobileSourceCatalog) async throws -> URL {
        guard configuration.webSelector != nil, catalog.work.item.sourceID == configuration.id,
              catalog.work.item.kind == .work, episode.item.sourceID == configuration.id,
              episode.item.kind == .episode, episode.qualityID == nil,
              try configuration.webItem(catalog.work.item.pageURL, kind: .work) == catalog.work.item,
              try configuration.webItem(episode.item.pageURL, kind: .episode) == episode.item,
              catalog.lines.contains(where: { $0.id == episode.line && $0.episodes.contains(episode) }) else {
            throw PlaybackFailure.missingEpisode
        }
        let page = try configuration.requestURL(episode.item.pageURL)
        let data = try await body(page)
        let doc = try document(data)
        var candidates = Set<URL>()
        for node in try doc.select("video[src], video source[src], source[src]") {
            if let url = media(try node.attr("src"), relativeTo: page) { candidates.insert(url) }
        }
        for frame in try doc.select("iframe[src]") {
            let raw = try frame.attr("src")
            guard let url = URL(string: raw, relativeTo: page)?.absoluteURL,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            for field in components.queryItems ?? [] where field.name == "url" {
                if let raw = field.value, let url = media(raw, relativeTo: nil) { candidates.insert(url) }
            }
        }
        let html = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: #"\b(?:var|let|const)\s+player_[A-Za-z0-9_]+\s*=\s*(\{[\s\S]*?\})\s*(?=;|</script>|$)"#)
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let payload = try? JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: Any] else {
                throw PlaybackFailure.unsupportedResponse
            }
            for key in ["points", "trysee", "paid", "preview"] {
                if let raw = payload[key] {
                    guard let value = number(raw) else { throw PlaybackFailure.unsupportedResponse }
                    if value > 0 { throw PlaybackFailure.authenticationRequired }
                }
            }
            guard let raw = payload["url"] as? String else { continue }
            let encoding: Double
            if let raw = payload["encrypt"] {
                guard let parsed = number(raw) else { throw PlaybackFailure.unsupportedResponse }
                encoding = parsed
            } else { encoding = 0 }
            let decoded: String?
            switch encoding {
            case 0: decoded = raw
            case 1: decoded = raw.removingPercentEncoding
            case 2: decoded = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) }?.removingPercentEncoding
            default: throw PlaybackFailure.unsupportedResponse
            }
            if let decoded, let url = media(decoded, relativeTo: nil) { candidates.insert(url) }
        }
        // Senfun exposes the default player through a same-origin JSON endpoint.
        // Use the website's first entry, not an arbitrary alternative stream or executable script.
        if candidates.isEmpty, page.host == "senfun.in",
           !(try doc.select("#senfun-p")).isEmpty,
           page.path.range(of: #"^/vodwatch/[0-9]+/[A-Za-z0-9_-]+\.html$"#, options: .regularExpression) != nil {
            let path = page.path.replacingOccurrences(of: "/vodwatch/", with: "/_senfun_plays/").dropLast(5)
            let endpoint = try configuration.requestURL("https://senfun.in" + path)
            let response = try await body(endpoint)
            guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let streams = root["video_plays"] as? [[String: Any]], streams.count <= 100,
                  let first = streams.first, let raw = first["play_data"] as? String,
                  let url = media(raw, relativeTo: nil) else { throw PlaybackFailure.unsupportedResponse }
            try Task.checkCancellation()
            return url
        }
        try Task.checkCancellation()
        guard candidates.count == 1, let media = candidates.first else { throw PlaybackFailure.unsupportedResponse }
        return media
    }

    private func body(_ url: URL) async throws -> Data {
        _ = try configuration.requestURL(url.absoluteString)
        try Task.checkCancellation()
        let data = try await fetch(url)
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw PlaybackFailure.unsupportedResponse }
        return data
    }

    private func document(_ data: Data) throws -> Document {
        let doc = try SwiftSoup.parse(String(decoding: data, as: UTF8.self))
        guard try doc.select("#challenge-form, #cf-challenge-running, .cf-browser-verification").isEmpty() else {
            throw PlaybackFailure.authenticationRequired
        }
        return doc
    }

    private func title(_ element: Element) throws -> String {
        let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        let value = text.isEmpty ? try element.attr("title").trimmingCharacters(in: .whitespacesAndNewlines) : text
        return String(value.prefix(500))
    }

    /// A label is display metadata only; playback and persistence always use the exact page URL.
    private func displayNumber(_ title: String) -> Int? {
        let pattern = #"(?i)^\s*(?:第\s*|episode\s*|ep\.?\s*)?([0-9]+)(?:\s*[集话話回]|\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title), let number = Int(title[range]), number > 0 else { return nil }
        return number
    }

    private func media(_ raw: String, relativeTo base: URL?) -> URL? {
        guard raw.utf8.count <= 16 * 1024,
              let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              let safe = try? configuration.requestURL(url.absoluteString, media: true),
              safe.fragment == nil, configuration.player.allowedExtensions.contains(safe.pathExtension.lowercased()) else { return nil }
        return safe
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func jsonValues(_ root: Any, path: String) throws -> [String] {
        let checked: String
        do { checked = try MobileCSS1Configuration.jsonPath(path) }
        catch { throw PlaybackFailure.unsupportedResponse }
        let parts = String(checked.dropFirst()).components(separatedBy: "[*]")
        guard parts.count == 2 else { throw PlaybackFailure.unsupportedResponse }
        let regex = try NSRegularExpression(pattern: #"(?:\.([A-Za-z_][A-Za-z0-9_-]*))|(?:\['([A-Za-z_][A-Za-z0-9_-]*)'\])"#)
        func keys(_ path: String) -> [String] {
            regex.matches(in: path, range: NSRange(path.startIndex..., in: path)).compactMap { match in
                let index = match.range(at: 1).location == NSNotFound ? 2 : 1
                return Range(match.range(at: index), in: path).map { String(path[$0]) }
            }
        }
        var container: Any = root
        for key in keys(parts[0]) {
            guard let value = (container as? [String: Any])?[key] else { throw PlaybackFailure.unsupportedResponse }
            container = value
        }
        guard let rows = container as? [Any], rows.count <= 10_000 else { throw PlaybackFailure.unsupportedResponse }
        let leaves = keys(parts[1])
        return try rows.map { row in
            var value: Any = row
            for key in leaves {
                guard let next = (value as? [String: Any])?[key] else { throw PlaybackFailure.unsupportedResponse }
                value = next
            }
            if let value = value as? String { return try SwiftSoup.parse(value).text() }
            if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.stringValue }
            throw PlaybackFailure.unsupportedResponse
        }
    }
}
