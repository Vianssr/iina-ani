import Foundation
import SwiftSoup

private final class SourceRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowedHosts: Set<String>
    let credentialHosts: Set<String>
    let cookies: [HTTPCookie]
    init(allowedHosts: Set<String>, credentialHosts: Set<String>, cookies: [HTTPCookie]) {
        self.allowedHosts = allowedHosts
        self.credentialHosts = credentialHosts
        self.cookies = cookies
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        var safe = request
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        if credentialHosts.contains(host) {
            let eligible = cookies.filter { cookie in
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                return cookie.isSecure && (host == domain || host.hasSuffix("." + domain)) &&
                    (url.path == cookie.path || url.path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path + "/"))
            }
            if !eligible.isEmpty { safe.setValue(HTTPCookie.requestHeaderFields(with: eligible)["Cookie"], forHTTPHeaderField: "Cookie") }
        }
        completionHandler(safe)
    }
}

func validateConfiguredSourceAccountContext(configuration: SourceConfiguration, sourceID: String?) throws {
    guard configuration.credentialHosts.isEmpty || sourceID == nil || sourceID == configuration.id else {
        throw SiteAccountError.invalidAccount
    }
}

actor ConfiguredSource: SupportSiteProtocol {
    nonisolated let configuration: SourceConfiguration
    private let site: SupportSites
    private let requestConfiguration: URLSessionConfiguration

    init(configuration: SourceConfiguration, site: SupportSites,
         requestConfiguration: sending URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        self.site = site
        requestConfiguration.httpCookieStorage = nil
        requestConfiguration.httpShouldSetCookies = false
        requestConfiguration.urlCache = nil
        self.requestConfiguration = requestConfiguration
    }

    func liveInfo(_ url: String) async throws -> LiveInfo {
        let p = try configuration.parts(url)
        let catalog = try await loadCatalog(id: p.id)
        let available = p.episodeIdentity == nil || catalog.lines.contains { line in
            (p.line == nil || line.number == p.line) && line.episodes.contains { $0.identity == p.episodeIdentity }
        }
        return ConfiguredSourceInfo(title: catalog.title, cover: catalog.cover, isLiving: available, site: site)
    }

    func episodeList(_ url: String) async throws -> (nodes: [VideoTreeNode], current: Int) {
        let p = try configuration.parts(url)
        let catalog = try await loadCatalog(id: p.id)
        var current = 0
        var position = 0
        let nodes = catalog.lines.map { line in
            let matchesLine = p.line == nil || line.number == p.line
            let children = line.episodes.map { episode in
                if matchesLine, episode.identity == p.episodeIdentity { current = position }
                position += 1
                return VideoTreeNode(site: site, index: episode.number, title: episode.title,
                                     id: p.id, url: episodePageURL(id: p.id, identity: episode.identity, fallback: episode.url))
            }
            return VideoTreeNode(title: line.title, children: children)
        }
        if p.episodeIdentity != nil && !catalog.lines.contains(where: { line in
            (p.line == nil || line.number == p.line) && line.episodes.contains { $0.identity == p.episodeIdentity }
        }) { throw VideoGetError.notFountData }
        return (nodes, current)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let p = try configuration.parts(url)
        let catalog = try await loadCatalog(id: p.id)
        guard let line = p.line == nil ? catalog.lines.first : catalog.lines.first(where: { $0.number == p.line }),
              let episode = p.episodeIdentity == nil ? line.episodes.first : line.episodes.first(where: { $0.identity == p.episodeIdentity }) else {
            throw VideoGetError.notFountData
        }
        let media = try await resolveMedia(episode.url, id: p.id, line: line.number, episode: episode.number, identity: episode.identity)
        var result = YouGetJSON(rawUrl: url)
        result.title = "\(catalog.title) - \(episode.title)"
        var stream = Stream(url: media)
        stream.qualityIndex = line.number
        result.streams["\(line.title) (\(line.number))"] = stream
        let alternatives = catalog.lines.compactMap { other -> (CatalogLine, CatalogEpisode)? in
            guard other.number != line.number,
                  let match = other.episodes.first(where: { $0.title == episode.title }) ??
                    other.episodes.first(where: { $0.identity == episode.identity }) else { return nil }
            return (other, match)
        }
        await withTaskGroup(of: (Int, String?).self) { group in
            for (other, match) in alternatives {
                group.addTask { (other.number, try? await self.resolveMedia(match.url, id: p.id,
                    line: other.number, episode: match.number, identity: match.identity)) }
            }
            for await (number, media) in group {
                guard let media, let other = alternatives.first(where: { $0.0.number == number })?.0 else { continue }
                var stream = Stream(url: media)
                stream.qualityIndex = number
                result.streams["\(other.title) (\(number))"] = stream
            }
        }
        try Task.checkCancellation()
        result.site = site
        return result
    }

    func search(query: String, page: Int) async throws -> SourceSearchPage {
        guard let spec = configuration.search,
              configuration.capabilities.contains(.search) else { throw SourceConfiguration.ConfigurationError.unsupportedCapability }
        let url = try SourceSearchExecutor.requestURL(spec, query: query, page: page,
                                                       allowedHosts: Set(configuration.hosts))
        let data = try await request(url, searchRequest: true)
        return try SourceSearchExecutor.parse(data: data, spec: spec, page: page, responseURL: url,
                                             resultURLTemplate: configuration.route.detailTemplate,
                                             classification: { _ in configuration.classification }) {
            try? configuration.item($0)
        }
    }

    private struct CatalogEpisode: Sendable { let number: Int; let identity: String; let title: String; let url: String }
    private struct CatalogLine: Sendable { let number: Int; let title: String; let episodes: [CatalogEpisode] }
    private struct CatalogData: Sendable { let title: String; let cover: String; let lines: [CatalogLine] }

    private func loadCatalog(id: String) async throws -> CatalogData {
        let spec = configuration.catalog
        let url = try configuration.requestURL(configuration.expanded(spec.url, values: ["id": id]))
        let data = try await request(url)
        if spec.format == "json" {
            let root = try JSONSerialization.jsonObject(with: data)
            guard let titlePath = spec.jsonTitlePath,
                  let title = jsonValue(root, path: titlePath) as? String, !title.isEmpty else { throw VideoGetError.notFountData }
            let cover = spec.jsonCoverPath.flatMap { jsonValue(root, path: $0) as? String } ?? ""
            let entries = spec.jsonEntriesPath.flatMap { jsonValue(root, path: $0) as? [[String: Any]] } ?? []
            var lines: [CatalogLine] = []
            for (offset, entry) in entries.enumerated() {
                guard let titlePath = spec.jsonEpisodeTitlePath,
                      let episodeTitle = jsonValue(entry, path: titlePath) as? String, !episodeTitle.isEmpty,
                      let identityPath = spec.jsonEpisodeIdentityPath ?? spec.jsonEpisodeURLPath,
                      let identity = jsonValue(entry, path: identityPath) as? String, !identity.isEmpty else { continue }
                let mediaPath = spec.jsonMediaPath.flatMap { jsonValue(entry, path: $0) as? String } ?? identity
                let ext = URL(fileURLWithPath: identity).pathExtension.lowercased()
                if let allowed = spec.jsonEntryExtensions, !allowed.map({ $0.lowercased() }).contains(ext) { continue }
                let number = spec.jsonEpisodeNumberPath.flatMap { jsonValue(entry, path: $0) as? Int } ?? offset + 1
                let lineNumber = spec.jsonLineNumberPath.flatMap { jsonValue(entry, path: $0) as? Int } ?? 1
                let lineTitle = spec.jsonLineTitlePath.flatMap { jsonValue(entry, path: $0) as? String } ?? "Line \(lineNumber)"
                let e = CatalogEpisode(number: number, identity: identity, title: episodeTitle, url: mediaPath)
                if let index = lines.firstIndex(where: { $0.number == lineNumber }) {
                    let existing = lines[index]
                    lines[index] = CatalogLine(number: existing.number, title: existing.title, episodes: existing.episodes + [e])
                } else { lines.append(CatalogLine(number: lineNumber, title: lineTitle, episodes: [e])) }
            }
            guard !lines.isEmpty else { throw VideoGetError.notFountData }
            return CatalogData(title: title, cover: cover, lines: lines)
        }
        let html = String(decoding: data, as: UTF8.self)
        let doc = try SwiftSoup.parse(html)
        guard let selector = spec.titleSelector, let title = try doc.select(selector).first()?.text(), !title.isEmpty else {
            throw VideoGetError.notFountData
        }
        let cover: String
        if let selector = spec.coverSelector, let element = try doc.select(selector).first(),
           let attribute = spec.coverAttribute, let value = try? element.attr(attribute),
           let resolved = URL(string: value, relativeTo: url)?.absoluteURL {
            cover = resolved.absoluteString
        } else { cover = "" }
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
                      let p = try? configuration.parts(target.absoluteString), p.id == id,
                      let number = p.episode, let line = p.line, lineNumber == nil || lineNumber == line,
                      seen.insert(number).inserted else { continue }
                lineNumber = line
                let episodeTitle = spec.episodeTitleSelector == "self" ? try link.text() :
                    (try spec.episodeTitleSelector.flatMap { try link.select($0).first()?.text() } ?? "")
                guard !episodeTitle.isEmpty else { continue }
                episodes.append(CatalogEpisode(number: number, identity: String(number), title: episodeTitle, url: target.absoluteString))
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
        guard !lines.isEmpty else { throw VideoGetError.notFountData }
        return CatalogData(title: title, cover: cover, lines: lines)
    }

    private func resolveMedia(_ raw: String, id: String, line: Int, episode: Int, identity: String) async throws -> String {
        let playerSpec = configuration.player
        if let template = playerSpec.streamURLTemplate {
            let rendered = configuration.expanded(template, values: ["id": id, "line": String(line), "episode": identity, "file": identity])
            let mediaURL = try configuration.requestURL(rendered, media: true)
            guard playerSpec.allowedExtensions.contains(mediaURL.pathExtension.lowercased()) else { throw VideoGetError.notFountData }
            return mediaURL.absoluteString
        }
        let url = try configuration.requestURL(raw)
        let data = try await request(url)
        let player: [String: Any]
        if playerSpec.format == "json" {
            let root = try JSONSerialization.jsonObject(with: data)
            guard let playerPath = playerSpec.payloadPattern,
                  let value = jsonValue(root, path: playerPath) as? [String: Any] else { throw VideoGetError.notFountData }
            player = value
        } else {
            let html = String(decoding: data, as: UTF8.self)
            let doc = try SwiftSoup.parse(html)
            if let rejects = playerSpec.rejectSelectors, try rejects.contains(where: { try !doc.select($0).isEmpty() }) {
                throw VideoGetError.needVip
            }
            guard let regex = configuration.compiledPlayerPattern?.value,
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let payload = String(html[range]).data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw VideoGetError.notFountData }
            player = parsed
        }
        return try configuration.validatedPlayerMediaURL(player, id: id, line: line, episode: episode)
    }

    private func request(_ url: URL, searchRequest: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        guard let initialHost = url.host?.lowercased(), url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil, configuration.hosts.contains(initialHost) ||
                configuration.mediaHosts.contains(initialHost) || configuration.credentialHosts.contains(initialHost) else {
            throw SourceConfiguration.ConfigurationError.invalidURL
        }
        let context = AccountHTTP.context
        try validateConfiguredSourceAccountContext(configuration: configuration, sourceID: context?.sourceID)
        let scopedCookies: [HTTPCookie]
        let requestCookies: [HTTPCookie]
        if let context, context.sourceID == configuration.id, context.accountID != nil {
            scopedCookies = (context.cookieStorage.cookies ?? []).filter { $0.isSecure }
            requestCookies = configuration.credentialHosts.contains(initialHost) ? AccountHTTP.cookies(for: url).filter { $0.isSecure } : []
        } else {
            scopedCookies = []
            requestCookies = []
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.httpShouldHandleCookies = false
        req.setValue(nil, forHTTPHeaderField: "Cookie")
        req.setValue(nil, forHTTPHeaderField: "Authorization")
        if !requestCookies.isEmpty { req.setValue(HTTPCookie.requestHeaderFields(with: requestCookies)["Cookie"], forHTTPHeaderField: "Cookie") }
        let allowed = Set(configuration.hosts + configuration.mediaHosts + configuration.credentialHosts)
        let delegate = SourceRedirectPolicy(allowedHosts: allowed, credentialHosts: Set(configuration.credentialHosts), cookies: scopedCookies)
        let session = URLSession(configuration: requestConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if searchRequest { throw SourceSearchError.transport }
            throw error
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            if searchRequest { throw SourceSearchError.malformedResponse }
            throw VideoGetError.notFountData
        }
        guard (200..<300).contains(response.statusCode) else {
            if searchRequest { throw SourceSearchError.httpStatus(response.statusCode) }
            throw VideoGetError.notFountData
        }
        return data
    }


    private func episodePageURL(id: String, identity: String, fallback: String) -> String {
        guard let parameter = configuration.route.queryIdentityParameter,
              var components = URLComponents(string: configuration.expanded(configuration.route.detailTemplate, values: ["id": id])) else {
            return fallback
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: parameter, value: identity)]
        return components.string ?? fallback
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

private struct ConfiguredSourceInfo: LiveInfo {
    let title: String
    let name: String
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites

    init(title: String, cover: String, isLiving: Bool, site: SupportSites) {
        self.title = title
        self.name = title
        self.cover = cover
        self.isLiving = isLiving
        self.site = site
    }
}
