import Foundation
import CryptoKit
import SwiftSoup

struct MobileSourceWork: Identifiable, Hashable, Sendable {
    let item: SourceItemRef
    let title: String
    var id: String { PlaybackWorkIdentity.source(item).localID }
}

struct MobileSourceEpisode: Identifiable, Hashable, Sendable {
    let item: SourceItemRef
    let title: String
    let line: Int
    let number: Int
    var identity: String? = nil
    var mediaPath: String? = nil
    var qualityID: String? = nil
    var id: String { PlaybackEpisodeIdentity.source(sourceID: item.sourceID, workID: String(line), episodeID: item.pageURL).localID }
}

struct MobileSourceLine: Identifiable, Sendable {
    let id: Int
    let title: String
    let episodes: [MobileSourceEpisode]
}

struct MobileSourceCatalog: Sendable {
    let work: MobileSourceWork
    let lines: [MobileSourceLine]
}

struct MobileSourcePage: Sendable {
    let works: [MobileSourceWork]
    let nextPage: Int?
}

enum MobileSourceError: Error { case unavailable, invalidResponse, invalidSelection }

/// Guest-only, declarative sources. No desktop accounts, remote JavaScript or credentials.
struct MobileSourceClient: Sendable {
    let configuration: SourceConfiguration
    private let fetch: @Sendable (URL) async throws -> Data

    init(configuration: SourceConfiguration, fetch: (@Sendable (URL) async throws -> Data)? = nil) {
        self.configuration = configuration
        let hosts = Set(configuration.hosts)
        self.fetch = fetch ?? { try await SourceTransport.fetch($0, hosts: hosts) }
    }

    static func make(configuration: SourceConfiguration) -> Self {
        #if DEBUG
        if SourceFixtures.enabled {
            let transport = SourceFixtureTransport()
            return Self(configuration: configuration, fetch: { try await transport.fetch($0) })
        }
        #endif
        return Self(configuration: configuration)
    }

    func require(_ capability: SourceCapability) throws {
        guard configuration.effectiveCapabilities(on: .iOS).contains(capability) else { throw PlaybackFailure.unsupportedResponse }
    }

    static func failure(for error: Error) -> PlaybackFailure {
        if let failure = error as? PlaybackFailure { return failure }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .userAuthenticationRequired, .userCancelledAuthentication: return .authenticationRequired
            default: return .network
            }
        }
        if let error = error as? MobileSourceError {
            switch error {
            case .invalidSelection: return .missingEpisode
            case .unavailable, .invalidResponse: return .unsupportedResponse
            }
        }
        return .unsupportedResponse
    }

    static func responseFailure(statusCode: Int) -> PlaybackFailure? {
        if statusCode == 401 || statusCode == 403 { return .authenticationRequired }
        if statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode) { return .network }
        return (200..<300).contains(statusCode) ? nil : .unsupportedResponse
    }

    func playbackContext(_ episode: MobileSourceEpisode, in catalog: MobileSourceCatalog,
                         requestedWork: PlaybackWorkIdentity?, requestedEpisode: PlaybackEpisodeIdentity?) throws -> PlaybackContext {
        if configuration.webSelector != nil {
            guard catalog.work.item.sourceID == configuration.id, episode.item.sourceID == configuration.id,
                  catalog.lines.contains(where: { $0.id == episode.line && $0.episodes.contains(episode) }) else {
                throw PlaybackFailure.missingEpisode
            }
            let selection = try configuration.mappingSelection(PlayableSelection(item: catalog.work.item,
                episode: episode.item, lineID: String(episode.line), qualityID: episode.qualityID,
                classification: configuration.classification))
            func identity(_ raw: String) -> String { SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined() }
            let workID = identity(selection.item.pageURL)
            return PlaybackContext(work: requestedWork ?? .source(sourceID: configuration.id, workID: workID),
                episode: requestedEpisode ?? .source(sourceID: configuration.id, workID: workID, episodeID: identity(selection.episode!.pageURL)),
                selection: selection, configurationRevision: configuration.configurationRevision)
        }
        let work = try configuration.parts(catalog.work.item.pageURL)
        let parts = try configuration.parts(episode.item.pageURL)
        guard catalog.work.item.sourceID == configuration.id, episode.item.sourceID == configuration.id,
              work.id == parts.id, let episodeID = parts.episodeIdentity,
              catalog.lines.contains(where: { $0.id == episode.line && $0.episodes.contains(episode) }) else { throw PlaybackFailure.missingEpisode }
        let selection = try configuration.mappingSelection(PlayableSelection(item: catalog.work.item, episode: episode.item,
            lineID: String(episode.line), qualityID: episode.qualityID, classification: configuration.classification))
        return PlaybackContext(
            work: requestedWork ?? .source(sourceID: configuration.id, workID: work.id),
            episode: requestedEpisode ?? .source(sourceID: configuration.id, workID: work.id, episodeID: episodeID),
            selection: selection, configurationRevision: configuration.configurationRevision)
    }

    /// A saved choice names one leaf, line and quality; catalogue order and display numbers are not fallbacks.
    func episode(matching selection: PlayableSelection, in catalog: MobileSourceCatalog) throws -> MobileSourceEpisode {
        let saved = try configuration.mappingSelection(selection)
        let matches = try catalog.lines.flatMap(\.episodes).filter { episode in
            let current = try playbackContext(episode, in: catalog, requestedWork: nil, requestedEpisode: nil).selection
            return current.item == saved.item && current.episode == saved.episode &&
                current.lineID == saved.lineID && current.qualityID == saved.qualityID
        }
        guard matches.count == 1, let episode = matches.first else { throw PlaybackFailure.missingEpisode }
        return episode
    }

    /// Advance inside the exact current directory line; missing identities and qualities are not fallback opportunities.
    func nextEpisode(after selection: PlayableSelection, in catalog: MobileSourceCatalog) throws -> MobileSourceEpisode? {
        guard selection.item.kind == .work, selection.classification.kind != .live,
              selection.torrent == nil else { throw PlaybackFailure.unsupportedResponse }
        let current = try episode(matching: selection, in: catalog)
        let groups = catalog.lines.filter { $0.id == current.line }
        guard groups.count == 1, let group = groups.first,
              let index = group.episodes.firstIndex(of: current) else { throw PlaybackFailure.missingEpisode }
        guard index + 1 < group.episodes.count else { return nil }
        let next = group.episodes[index + 1]
        guard next.item != current.item, next.line == current.line,
              group.episodes.filter({ $0.number == next.number }).count == 1 else {
            throw PlaybackFailure.missingEpisode
        }
        if configuration.route.episodeGroup != nil || configuration.catalog.jsonEpisodeNumberPath != nil {
            guard current.number < Int.max, next.number == current.number + 1 else { throw PlaybackFailure.missingEpisode }
        }
        guard next.qualityID == selection.qualityID else { throw MobileNextEpisodeError.qualityUnavailable }
        _ = try playbackContext(next, in: catalog, requestedWork: nil, requestedEpisode: nil)
        return next
    }

    func work(at address: String) throws -> MobileSourceWork {
        try require(.information)
        let safe = try configuration.requestURL(address.trimmingCharacters(in: .whitespacesAndNewlines))
        let item = try configuration.item(safe.absoluteString)
        guard item.kind == .work else { throw MobileSourceError.invalidSelection }
        return MobileSourceWork(item: item, title: configuration.name)
    }

    func search(_ keyword: String, page: Int = 1) async throws -> MobileSourcePage {
        try require(.search)
        if configuration.webSelector != nil {
            guard page == 1 else { throw MobileSourceError.invalidSelection }
            return try await MobileCSS1Client(configuration: configuration, fetch: fetch).search(keyword: keyword)
        }
        guard let spec = configuration.search, page > 0, page <= 1000,
              !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MobileSourceError.invalidSelection }
        var raw = configuration.expanded(spec.url, values: ["query": keyword, "page": String(page - 1 + (spec.firstPage ?? 1))])
        guard var components = URLComponents(string: raw) else { throw MobileSourceError.invalidResponse }
        var query = components.queryItems ?? []
        if !spec.url.contains("{query}") { query.append(URLQueryItem(name: spec.queryParameter, value: keyword)) }
        if !spec.url.contains("{page}") { query.append(URLQueryItem(name: spec.pageParameter, value: String(page - 1 + (spec.firstPage ?? 1)))) }
        components.queryItems = query
        raw = components.string ?? raw
        let url = try configuration.requestURL(raw)
        let data = try await fetch(url)
        if spec.format == "json" { return try jsonSearch(data, spec: spec, page: page, url: url) }
        let doc = try document(data)
        guard let selector = spec.resultsSelector, let titleSelector = spec.titleSelector,
              let hrefAttribute = spec.hrefAttribute else { throw MobileSourceError.invalidResponse }
        for reject in spec.rejectSelectors ?? [] where try !doc.select(reject).isEmpty() { throw PlaybackFailure.authenticationRequired }
        let rows = try doc.select(selector)
        var works: [MobileSourceWork] = []
        var seen = Set<SourceItemRef>()
        for row in rows {
            let titleNode = titleSelector == "self" ? row : try row.select(titleSelector).first()
            guard let titleNode else { continue }
            let link = try spec.linkSelector.flatMap { $0 == "self" ? row : try row.select($0).first() } ?? titleNode
            let title = try titleNode.text()
            let href = try link.attr(hrefAttribute)
            guard !title.isEmpty, !href.isEmpty,
                  let address = URL(string: href, relativeTo: url)?.absoluteURL,
                  let safe = try? configuration.requestURL(address.absoluteString),
                  let ref = try? configuration.item(safe.absoluteString), ref.kind == .work,
                  seen.insert(ref).inserted else { continue }
            works.append(MobileSourceWork(item: ref, title: title))
        }
        if !rows.isEmpty() && works.isEmpty { throw MobileSourceError.invalidResponse }
        let hasNext = try spec.nextPageSelector.map { selector in
            try doc.select(selector).contains {
                let href = try $0.attr("href")
                return !href.isEmpty && href != "#" && !href.lowercased().hasPrefix("javascript:") &&
                    !$0.hasClass("disabled") && $0.parent()?.hasClass("disabled") != true &&
                    URL(string: href, relativeTo: url)?.absoluteURL != url
            }
        } ?? (rows.count >= spec.rowsPerPage)
        try Task.checkCancellation()
        return MobileSourcePage(works: works, nextPage: hasNext ? page + 1 : nil)
    }

    func catalog(_ work: MobileSourceWork) async throws -> MobileSourceCatalog {
        try require(.episodes)
        guard work.item.sourceID == configuration.id, work.item.kind == .work else { throw MobileSourceError.invalidSelection }
        if configuration.webSelector != nil {
            return try await MobileCSS1Client(configuration: configuration, fetch: fetch).catalog(work: work)
        }
        let parts = try configuration.parts(work.item.pageURL)
        let spec = configuration.catalog
        let url = try configuration.requestURL(configuration.expanded(spec.url, values: ["id": parts.id]))
        let data = try await fetch(url)
        if spec.format == "json" { return try jsonCatalog(data, work: work, url: url, workID: parts.id) }
        guard let titleSelector = spec.titleSelector, let panelSelector = spec.panelSelector,
              let episodeSelector = spec.episodeSelector, let hrefAttribute = spec.episodeURLAttribute else { throw MobileSourceError.unavailable }
        let doc = try document(data)
        guard let title = try doc.select(titleSelector).first()?.text(), !title.isEmpty else { throw MobileSourceError.invalidResponse }
        let labels = try spec.lineTitleSelector.map { try doc.select($0).map { try $0.text() } } ?? []
        var lines: [MobileSourceLine] = []
        var seenLines = Set<Int>()
        for (index, panel) in try doc.select(panelSelector).enumerated() {
            var episodes: [MobileSourceEpisode] = []
            var line: Int?
            var seen = Set<SourceItemRef>()
            for link in try panel.select(episodeSelector) {
                let href = try link.attr(hrefAttribute)
                guard let target = URL(string: href, relativeTo: url)?.absoluteURL,
                      let safe = try? configuration.requestURL(target.absoluteString),
                      let p = try? configuration.parts(safe.absoluteString), p.id == parts.id,
                      p.item.kind == .episode, p.episodeIdentity != nil else { continue }
                let number = p.episode ?? episodes.count + 1
                let lineNumber = p.line ?? index + 1
                let name = (spec.episodeTitleSelector ?? "self") == "self" ? try link.text() :
                    (try spec.episodeTitleSelector.flatMap { try link.select($0).first()?.text() } ?? "")
                guard !name.isEmpty, line == nil || line == lineNumber, seen.insert(p.item).inserted else { continue }
                line = lineNumber
                episodes.append(MobileSourceEpisode(item: p.item, title: name, line: lineNumber, number: number, identity: p.episodeIdentity))
            }
            if let line, !episodes.isEmpty, seenLines.insert(line).inserted {
                let label: String
                if let template = spec.labelLinkTemplate {
                    label = try doc.select(template.replacingOccurrences(of: "{line}", with: String(line))).first()?.text() ?? String(line)
                } else { label = labels.indices.contains(index) ? labels[index] : String(line) }
                lines.append(MobileSourceLine(id: line, title: label, episodes: episodes))
            }
        }
        guard !lines.isEmpty else { throw PlaybackFailure.missingEpisode }
        try Task.checkCancellation()
        return MobileSourceCatalog(work: MobileSourceWork(item: work.item, title: title), lines: lines)
    }

    func resolve(_ episode: MobileSourceEpisode, in catalog: MobileSourceCatalog) async throws -> URL {
        try require(.resolve)
        if configuration.webSelector != nil {
            return try await MobileCSS1Client(configuration: configuration, fetch: fetch).resolve(episode: episode, catalog: catalog)
        }
        if catalog.lines.count > 1 { try require(.lines) }
        if episode.qualityID != nil { try require(.quality) }
        guard catalog.work.item.sourceID == configuration.id, episode.item.sourceID == configuration.id,
              catalog.lines.contains(where: { $0.id == episode.line && $0.episodes.contains(episode) }) else { throw MobileSourceError.invalidSelection }
        let work = try configuration.parts(catalog.work.item.pageURL)
        let parts = try configuration.parts(episode.item.pageURL)
        guard parts.id == work.id,
              configuration.route.lineGroup == nil || parts.line == episode.line,
              configuration.route.episodeGroup == nil || parts.episode == episode.number,
              episode.identity == nil || parts.episodeIdentity == episode.identity else { throw MobileSourceError.invalidSelection }
        let spec = configuration.player
        if let template = spec.streamURLTemplate {
            let identity = episode.identity ?? parts.episodeIdentity ?? String(episode.number)
            let raw = configuration.expanded(template, values: ["id": work.id, "line": String(episode.line), "episode": identity, "file": identity])
            let media = try configuration.requestURL(raw, media: true)
            guard spec.allowedExtensions.contains(media.pathExtension.lowercased()) else { throw MobileSourceError.invalidResponse }
            try Task.checkCancellation()
            return media
        }
        let url = try configuration.requestURL(episode.mediaPath ?? episode.item.pageURL)
        let data = try await fetch(url)
        let player: [String: Any]
        if spec.format == "json" {
            let root = try json(data)
            guard let path = spec.payloadPattern, let value = value(root, at: path) as? [String: Any] else { throw MobileSourceError.invalidResponse }
            player = value
        } else {
            let doc = try document(data)
            for reject in spec.rejectSelectors ?? [] where try !doc.select(reject).isEmpty() { throw PlaybackFailure.authenticationRequired }
            let html = String(decoding: data, as: UTF8.self)
            guard let regex = configuration.compiledPlayerPattern?.value,
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let parsed = try JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: Any] else { throw MobileSourceError.invalidResponse }
            player = parsed
        }
        if [spec.paidKey, spec.previewKey].compactMap({ $0 }).contains(where: {
            (player[$0] as? NSNumber)?.doubleValue ?? 0 > 0
        }) { throw PlaybackFailure.authenticationRequired }
        guard let idKey = spec.idKey, let lineKey = spec.lineKey, let episodeKey = spec.episodeKey else {
            throw PlaybackFailure.unsupportedResponse
        }
        let actualID = (spec.idIsString ?? false) ? player[idKey] as? String : (player[idKey] as? NSNumber)?.stringValue
        guard actualID == work.id,
              let actualLine = player[lineKey] as? NSNumber, actualLine.doubleValue == Double(episode.line),
              let actualEpisode = player[episodeKey] as? NSNumber, actualEpisode.doubleValue == Double(episode.number) else {
            throw PlaybackFailure.missingEpisode
        }
        let raw = try configuration.validatedPlayerMediaURL(player, id: work.id, line: episode.line, episode: episode.number)
        try Task.checkCancellation()
        return try configuration.requestURL(raw, media: true)
    }

    private func jsonSearch(_ data: Data, spec: SourceConfiguration.Search, page: Int, url: URL) throws -> MobileSourcePage {
        let root = try json(data)
        guard let path = spec.jsonResultsPath, let rows = value(root, at: path) as? [[String: Any]],
              let titlePath = spec.jsonTitlePath, let identityPath = spec.jsonIdentifierPath else { throw MobileSourceError.invalidResponse }
        var works: [MobileSourceWork] = []
        var seen = Set<SourceItemRef>()
        for row in rows {
            guard let title = value(row, at: titlePath) as? String,
                  let identity = string(value(row, at: identityPath)) else { continue }
            let raw = configuration.expanded(configuration.route.detailTemplate, values: ["id": identity])
            guard let safe = try? configuration.requestURL(raw), let item = try? configuration.item(safe.absoluteString),
                  item.kind == .work, seen.insert(item).inserted else { continue }
            let name = try SwiftSoup.parse(title).text()
            guard !name.isEmpty else { continue }
            works.append(MobileSourceWork(item: item, title: name))
        }
        if !rows.isEmpty && works.isEmpty { throw MobileSourceError.invalidResponse }
        let total = spec.jsonTotalPath.flatMap { value(root, at: $0) as? NSNumber }
        let hasNext = total.map { $0.intValue > page * spec.rowsPerPage } ?? (rows.count >= spec.rowsPerPage)
        try Task.checkCancellation()
        return MobileSourcePage(works: works, nextPage: hasNext && !rows.isEmpty ? page + 1 : nil)
    }

    private func jsonCatalog(_ data: Data, work: MobileSourceWork, url: URL, workID: String) throws -> MobileSourceCatalog {
        let root = try json(data)
        let spec = configuration.catalog
        guard let titlePath = spec.jsonTitlePath, let title = value(root, at: titlePath) as? String, !title.isEmpty,
              let entriesPath = spec.jsonEntriesPath, let entries = value(root, at: entriesPath) as? [[String: Any]],
              let namePath = spec.jsonEpisodeTitlePath,
              let identityPath = spec.jsonEpisodeIdentityPath ?? spec.jsonEpisodeURLPath else { throw MobileSourceError.invalidResponse }
        var lines: [MobileSourceLine] = []
        var seen = Set<String>()
        for (offset, entry) in entries.enumerated() {
            guard let name = value(entry, at: namePath) as? String, !name.isEmpty,
                  let identity = string(value(entry, at: identityPath)), !identity.isEmpty else { continue }
            if let extensions = spec.jsonEntryExtensions,
               !extensions.map({ $0.lowercased() }).contains(URL(fileURLWithPath: identity).pathExtension.lowercased()) { continue }
            let item: SourceItemRef
            if let key = configuration.route.queryIdentityParameter {
                guard var page = URLComponents(string: work.item.pageURL) else { throw MobileSourceError.invalidSelection }
                page.queryItems = (page.queryItems ?? []).filter { $0.name != key } + [URLQueryItem(name: key, value: identity)]
                guard let address = page.string else { throw MobileSourceError.invalidSelection }
                item = try configuration.item(address)
            } else {
                let raw = spec.jsonEpisodeURLPath.flatMap { string(value(entry, at: $0)) } ?? identity
                guard let page = URL(string: raw, relativeTo: url)?.absoluteURL,
                      let safe = try? configuration.requestURL(page.absoluteString),
                      let parts = try? configuration.parts(safe.absoluteString), parts.id == workID,
                      parts.item.kind == .episode else { continue }
                item = parts.item
            }
            let pageParts = try configuration.parts(item.pageURL)
            let configuredLine = spec.jsonLineNumberPath.flatMap { value(entry, at: $0) as? Int }
            let configuredNumber = spec.jsonEpisodeNumberPath.flatMap { value(entry, at: $0) as? Int }
            guard spec.jsonLineNumberPath == nil || configuredLine != nil,
                  spec.jsonEpisodeNumberPath == nil || configuredNumber != nil else { continue }
            let line = configuredLine ?? pageParts.line ?? 1
            let number = configuredNumber ?? pageParts.episode ?? offset + 1
            guard line > 0, number > 0 else { continue }
            guard pageParts.id == workID,
                  configuration.route.lineGroup == nil || pageParts.line == line,
                  configuration.route.episodeGroup == nil || pageParts.episode == number else { continue }
            let rawMedia = (spec.jsonMediaPath ?? spec.jsonEpisodeURLPath).flatMap { string(value(entry, at: $0)) }
            let media = rawMedia.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL.absoluteString }
            let episode = MobileSourceEpisode(item: item, title: name, line: line, number: number,
                identity: pageParts.episodeIdentity, mediaPath: media)
            guard seen.insert(episode.id).inserted else { continue }
            let label = spec.jsonLineTitlePath.flatMap { value(entry, at: $0) as? String } ?? String(line)
            if let index = lines.firstIndex(where: { $0.id == line }) {
                lines[index] = MobileSourceLine(id: line, title: lines[index].title, episodes: lines[index].episodes + [episode])
            } else { lines.append(MobileSourceLine(id: line, title: label, episodes: [episode])) }
        }
        guard !lines.isEmpty else { throw PlaybackFailure.missingEpisode }
        try Task.checkCancellation()
        return MobileSourceCatalog(work: MobileSourceWork(item: work.item, title: title), lines: lines)
    }

    private func json(_ data: Data) throws -> Any {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw MobileSourceError.invalidResponse }
        do { return try JSONSerialization.jsonObject(with: data) }
        catch {
            // JSON endpoints can return the same HTML verification gate as ordinary source pages.
            _ = try document(data)
            throw error
        }
    }
    private func value(_ root: Any, at path: String) -> Any? {
        guard !path.isEmpty else { return nil }
        return path.split(separator: ".").reduce(Optional(root)) { current, key in
            if let object = current as? [String: Any] { return object[String(key)] }
            if let array = current as? [Any], let index = Int(key), array.indices.contains(index) { return array[index] }
            return nil
        }
    }
    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func document(_ data: Data) throws -> Document {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw MobileSourceError.invalidResponse }
        let doc = try SwiftSoup.parse(String(decoding: data, as: UTF8.self))
        guard try doc.select("#challenge-form, #cf-challenge-running, .cf-browser-verification").isEmpty() else { throw PlaybackFailure.authenticationRequired }
        return doc
    }
}

private final class SourceTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let hosts: Set<String>
    init(hosts: Set<String>) { self.hosts = hosts }
    func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && url.port == nil && hosts.contains(url.host?.lowercased() ?? "")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, allows(url) else { completionHandler(nil); return }
        completionHandler(request)
    }
    static func fetch(_ url: URL, hosts: Set<String>) async throws -> Data {
        let policy = SourceTransport(hosts: hosts)
        guard policy.allows(url) else { throw MobileSourceError.invalidSelection }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue("IINA-ANI-iOS/0.1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MobileSourceError.invalidResponse }
        if let failure = MobileSourceClient.responseFailure(statusCode: http.statusCode) { throw failure }
        guard (200..<300).contains(http.statusCode), let final = response.url, policy.allows(final),
              response.expectedContentLength <= 4 * 1024 * 1024 else { throw MobileSourceError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4 * 1024 * 1024 else { throw MobileSourceError.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}
