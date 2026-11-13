import SourceCore
import Foundation
import SwiftSoup

/// Shared declarative decoder. Explicit v4 static imports use exact page identities;
/// retained v3 configurations remain inactive.
public struct ConfiguredSourceClient: Sendable {
    public let configuration: SourceConfiguration
    private let fetch: SourceHTTPTransport.Fetch?

    public init(configuration: SourceConfiguration, fetch: SourceHTTPTransport.Fetch? = nil) {
        self.configuration = configuration
        self.fetch = fetch
    }

    public func catalog(_ work: RuntimeWork) async throws -> RuntimeCatalog {
        if configuration.version == 4 {
            return try await StaticWebSourceClient(configuration: configuration, fetch: fetch).catalog(work)
        }
        try requireSupportedConfiguration()
        guard work.item.sourceID == configuration.id else { throw SourceConfiguration.ConfigurationError.invalidURL }
        let parts = try configuration.parts(work.item.pageURL)
        let data = try await loadCatalog(id: parts.id, workPageURL: work.item.pageURL)
        let lines = data.lines.map { line in
            RuntimeLine(id: line.number, title: line.title, episodes: line.episodes.map { episode in
                RuntimeEpisode(item: episode.item, title: episode.title, line: line.number, number: episode.number,
                               identity: episode.identity, mediaPath: episode.url)
            })
        }
        try Task.checkCancellation()
        return RuntimeCatalog(work: RuntimeWork(item: work.item, title: data.title), lines: lines)
    }

    public func resolve(_ episode: RuntimeEpisode, in catalog: RuntimeCatalog) async throws -> URL {
        if configuration.version == 4 {
            return try await StaticWebSourceClient(configuration: configuration, fetch: fetch).resolve(episode, in: catalog)
        }
        try requireSupportedConfiguration()
        guard catalog.work.item.sourceID == configuration.id, episode.item.sourceID == configuration.id,
              let line = catalog.lines.first(where: { $0.id == episode.line }),
              let selected = line.episodes.first(where: { $0 == episode }),
              let raw = selected.mediaPath, let identity = selected.identity else { throw PlaybackFailure.missingEpisode }
        let parts = try configuration.parts(catalog.work.item.pageURL)
        let selectedParts = try configuration.parts(selected.item.pageURL)
        guard selectedParts.id == parts.id,
              configuration.route.lineGroup == nil || selectedParts.line == selected.line,
              configuration.route.episodeGroup == nil || selectedParts.episode == selected.number,
              selectedParts.episodeIdentity == identity else { throw PlaybackFailure.missingEpisode }
        let media = try await resolveMedia(raw, id: parts.id, line: line.id, episode: selected.number, identity: identity)
        try Task.checkCancellation()
        guard let url = URL(string: media) else { throw PlaybackFailure.mediaNotFound }
        return url
    }

    private func requireSupportedConfiguration() throws {
        guard configuration.webSelector == nil else { throw SourceConfiguration.ConfigurationError.unsupportedCapability }
        try Task.checkCancellation()
    }

    private struct CatalogEpisode: Sendable { let item: SourceItemRef; let number: Int; let identity: String; let title: String; let url: String }
    private struct CatalogLine: Sendable { let number: Int; let title: String; var episodes: [CatalogEpisode] }
    private struct CatalogData: Sendable { let title: String; let lines: [CatalogLine] }

    private func loadCatalog(id: String, workPageURL: String) async throws -> CatalogData {
        let spec = configuration.catalog
        let url = try configuration.requestURL(configuration.expanded(spec.url, values: ["id": id]))
        let data = try await request(url)
        if spec.format == "json" {
            let root = try JSONSerialization.jsonObject(with: data)
            guard let titlePath = spec.jsonTitlePath,
                  let title = jsonValue(root, path: titlePath) as? String, !title.isEmpty else { throw PlaybackFailure.mediaNotFound }
            let entries = spec.jsonEntriesPath.flatMap { jsonValue(root, path: $0) as? [[String: Any]] } ?? []
            let allowedExtensions = spec.jsonEntryExtensions.map { Set($0.map { $0.lowercased() }) }
            var lines: [CatalogLine] = []
            var seen = Set<SourceItemRef>()
            for (offset, entry) in entries.enumerated() {
                guard let titlePath = spec.jsonEpisodeTitlePath,
                      let episodeTitle = jsonValue(entry, path: titlePath) as? String, !episodeTitle.isEmpty,
                      let identityPath = spec.jsonEpisodeIdentityPath ?? spec.jsonEpisodeURLPath,
                      let identity = jsonString(jsonValue(entry, path: identityPath)), !identity.isEmpty else { continue }
                if let allowedExtensions,
                   !allowedExtensions.contains(URL(fileURLWithPath: identity).pathExtension.lowercased()) { continue }
                let pageURL: String
                if let parameter = configuration.route.queryIdentityParameter {
                    guard var page = URLComponents(string: workPageURL) else { throw SourceConfiguration.ConfigurationError.invalidURL }
                    page.queryItems = (page.queryItems ?? []).filter { $0.name != parameter } + [URLQueryItem(name: parameter, value: identity)]
                    guard let address = page.string else { throw SourceConfiguration.ConfigurationError.invalidURL }
                    pageURL = address
                } else {
                    let raw = spec.jsonEpisodeURLPath.flatMap { jsonString(jsonValue(entry, path: $0)) } ?? identity
                    guard let page = URL(string: raw, relativeTo: url)?.absoluteURL,
                          let safe = try? configuration.requestURL(page.absoluteString) else { continue }
                    pageURL = safe.absoluteString
                }
                guard let parts = try? configuration.parts(pageURL), parts.id == id, parts.item.kind == .episode,
                      let episodeIdentity = parts.episodeIdentity else { continue }
                let configuredNumber = spec.jsonEpisodeNumberPath.flatMap { jsonValue(entry, path: $0) as? Int }
                let configuredLine = spec.jsonLineNumberPath.flatMap { jsonValue(entry, path: $0) as? Int }
                guard spec.jsonEpisodeNumberPath == nil || configuredNumber != nil,
                      spec.jsonLineNumberPath == nil || configuredLine != nil else { continue }
                let number = configuredNumber ?? parts.episode ?? offset + 1
                let lineNumber = configuredLine ?? parts.line ?? 1
                guard number > 0, lineNumber > 0,
                      configuration.route.episodeGroup == nil || parts.episode == number,
                      configuration.route.lineGroup == nil || parts.line == lineNumber,
                      seen.insert(parts.item).inserted else { continue }
                let rawMedia = (spec.jsonMediaPath ?? spec.jsonEpisodeURLPath).flatMap { jsonString(jsonValue(entry, path: $0)) }
                let mediaPath = rawMedia.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL.absoluteString } ?? parts.item.pageURL
                let lineTitle = spec.jsonLineTitlePath.flatMap { jsonValue(entry, path: $0) as? String } ?? "Line \(lineNumber)"
                let episode = CatalogEpisode(item: parts.item, number: number, identity: episodeIdentity, title: episodeTitle, url: mediaPath)
                if let index = lines.firstIndex(where: { $0.number == lineNumber }) {
                    lines[index].episodes.append(episode)
                } else { lines.append(CatalogLine(number: lineNumber, title: lineTitle, episodes: [episode])) }
            }
            guard !lines.isEmpty else { throw PlaybackFailure.mediaNotFound }
            return CatalogData(title: title, lines: lines)
        }
        let html = String(decoding: data, as: UTF8.self)
        let doc = try SwiftSoup.parse(html)
        guard let selector = spec.titleSelector, let title = try doc.select(selector).first()?.text(), !title.isEmpty else {
            throw PlaybackFailure.mediaNotFound
        }
        let panels = try doc.select(spec.panelSelector ?? "")
        let labels = try spec.lineTitleSelector.map { try doc.select($0).map { try $0.text() } } ?? []
        var lines: [CatalogLine] = []
        for panel in panels {
            guard let episodeSelector = spec.episodeSelector else { continue }
            var episodes: [CatalogEpisode] = []
            var seen = Set<Int>()
            var lineNumber: Int?
            for link in try panel.select(episodeSelector) {
                guard let attr = spec.episodeURLAttribute, let href = try? link.attr(attr),
                      let target = URL(string: href, relativeTo: url)?.absoluteURL,
                      let parts = try? configuration.parts(target.absoluteString), parts.id == id,
                      let number = parts.episode, let line = parts.line, lineNumber == nil || lineNumber == line,
                      seen.insert(number).inserted else { continue }
                lineNumber = line
                let episodeTitle = (spec.episodeTitleSelector ?? "self") == "self" ? try link.text() :
                    (try spec.episodeTitleSelector.flatMap { try link.select($0).first()?.text() } ?? "")
                guard !episodeTitle.isEmpty else { continue }
                episodes.append(CatalogEpisode(item: parts.item, number: number, identity: parts.episodeIdentity ?? String(number),
                                               title: episodeTitle, url: target.absoluteString))
            }
            if let lineNumber, !episodes.isEmpty {
                let label: String
                if let template = spec.labelLinkTemplate {
                    let linkSelector = template.replacingOccurrences(of: "{line}", with: String(lineNumber))
                    label = try doc.select(linkSelector).first()?.text() ?? ""
                } else { label = labels.indices.contains(lines.count) ? labels[lines.count] : "" }
                lines.append(CatalogLine(number: lineNumber, title: label.isEmpty ? "Line \(lineNumber)" : label, episodes: episodes))
            }
        }
        guard !lines.isEmpty else { throw PlaybackFailure.mediaNotFound }
        return CatalogData(title: title, lines: lines)
    }

    private func resolveMedia(_ raw: String, id: String, line: Int, episode: Int, identity: String) async throws -> String {
        let playerSpec = configuration.player
        if let template = playerSpec.streamURLTemplate {
            let rendered = configuration.expanded(template, values: ["id": id, "line": String(line), "episode": identity, "file": identity])
            let mediaURL = try configuration.requestURL(rendered, media: true)
            guard playerSpec.allowedExtensions.contains(mediaURL.pathExtension.lowercased()) else { throw PlaybackFailure.mediaNotFound }
            return mediaURL.absoluteString
        }
        let url = try configuration.requestURL(raw)
        let data = try await request(url)
        let player: [String: Any]
        if playerSpec.format == "json" {
            let root = try JSONSerialization.jsonObject(with: data)
            guard let playerPath = playerSpec.payloadPattern,
                  let value = jsonValue(root, path: playerPath) as? [String: Any] else { throw PlaybackFailure.mediaNotFound }
            player = value
        } else {
            let html = String(decoding: data, as: UTF8.self)
            let doc = try SwiftSoup.parse(html)
            if let rejects = playerSpec.rejectSelectors, try rejects.contains(where: { try !doc.select($0).isEmpty() }) {
                throw PlaybackFailure.authenticationRequired
            }
            guard let regex = configuration.compiledPlayerPattern?.value,
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let payload = String(html[range]).data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw PlaybackFailure.mediaNotFound }
            player = parsed
        }
        do {
            return try configuration.validatedPlayerMediaURL(player, id: id, line: line, episode: episode)
        } catch SourceConfiguration.ConfigurationError.invalidMedia {
            throw PlaybackFailure.mediaNotFound
        }
    }

    private func request(_ url: URL) async throws -> Data {
        try Task.checkCancellation()
        let allowed = Set(configuration.hosts + configuration.mediaHosts + configuration.credentialHosts)
        guard SourceHTTPTransport.permits(url, allowedHosts: allowed) else { throw SourceConfiguration.ConfigurationError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        let response: SourceHTTPResponse
        do {
            if let fetch { response = try await fetch(request) }
            else { response = try await SourceHTTPTransport.fetch(request, allowedHosts: allowed) }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if case SourceHTTPTransportError.oversizedResponse = error { throw PlaybackFailure.invalidResponseBody }
            throw error
        }
        try Task.checkCancellation()
        guard SourceHTTPTransport.permits(response.url, allowedHosts: allowed) else { throw SourceConfiguration.ConfigurationError.invalidURL }
        guard response.data.count <= SourceHTTPTransport.maximumResponseBytes else { throw PlaybackFailure.invalidResponseBody }
        switch response.statusCode {
        case 200..<300: break
        case 401: throw PlaybackFailure.authenticationRequired
        case 403: throw PlaybackFailure.httpForbidden
        case 300..<400: throw PlaybackFailure.sourceRedirect
        case 408, 429, 500..<600: throw PlaybackFailure.network
        case 404, 410: throw PlaybackFailure.mediaNotFound
        default: throw PlaybackFailure.unsupportedResponse
        }
        return response.data
    }

    private func jsonString(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func jsonValue(_ root: Any, path: String) -> Any? {
        guard !path.isEmpty else { return nil }
        return path.split(separator: ".").reduce(Optional(root)) { value, key in
            guard let value else { return nil }
            if let dict = value as? [String: Any] { return dict[String(key)] }
            if let array = value as? [Any], let index = Int(key), array.indices.contains(index) { return array[index] }
            return nil
        }
    }
}
