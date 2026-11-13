import Foundation
import CoreFoundation
import SourceCore
import SwiftSoup

/// Explicit v4 static sources. Remote selectors describe data; downloaded scripts never run.
/// Retained v3 configurations remain inactive and cannot enter this adapter.
public struct StaticWebSourceClient: Sendable {
    public let configuration: SourceConfiguration
    private let fetch: SourceHTTPTransport.Fetch?
    private static let maximumBytes = 4 * 1024 * 1024

    public init(configuration: SourceConfiguration, fetch: SourceHTTPTransport.Fetch? = nil) {
        self.configuration = configuration
        self.fetch = fetch
    }

    /// Search overlays may change selectors and URLs, never the configured transport or work identity.
    public func search(query: String, page: Int = 1, searchOverride: SourceConfiguration.Search? = nil) async throws -> SourceSearchPage {
        try requireSupportedConfiguration()
        guard let search = searchOverride ?? configuration.search, query.utf8.count <= 1024 else { throw PlaybackFailure.searchStructure }
        return try await SourceSearchExecutor.search(query: query, page: page, spec: search,
            allowedHosts: configuration.requestHosts, classification: { _ in configuration.classification },
            fetch: { request in try await response(request) },
            item: { try? configuration.webItem($0, kind: .work) })
    }

    public func catalog(_ work: RuntimeWork) async throws -> RuntimeCatalog {
        try requireSupportedConfiguration()
        guard let spec = configuration.webSelector, work.item.sourceID == configuration.id,
              work.item.kind == .work,
              try configuration.webItem(work.item.pageURL, kind: .work) == work.item else {
            throw PlaybackFailure.missingEpisode
        }
        let page = try configuration.requestURL(work.item.pageURL)
        let body = try await body(page)
        let doc = try document(body)
        let panels: [Element]
        let labels: [String]
        switch spec.channelFormat {
        case "no-channel": panels = [doc]; labels = []
        case "index-grouped":
            guard let selector = spec.episodeLists else { throw PlaybackFailure.catalogStructure }
            panels = try doc.select(selector).array()
            let names = try spec.channelNames.map { try doc.select($0).map(title) } ?? []
            // A partial label list must never shift the association of later groups.
            labels = names.count == panels.count ? names : []
        default: throw PlaybackFailure.catalogStructure
        }
        guard panels.count <= 100 else { throw PlaybackFailure.catalogStructure }
        var lines: [RuntimeLine] = []
        for (index, panel) in panels.enumerated() {
            try Task.checkCancellation()
            let pairs: [(name: Element, link: Element)]
            do {
                pairs = try SelectorPairing.pairs(in: panel, names: spec.episodeNames,
                                                 links: spec.episodeLinks ?? spec.episodeNames)
            } catch { throw PlaybackFailure.catalogStructure }
            guard pairs.count <= 10_000 else { throw PlaybackFailure.catalogStructure }
            var episodes: [RuntimeEpisode] = []
            var seen = Set<SourceItemRef>()
            for (offset, pair) in pairs.enumerated() {
                let name = try title(pair.name)
                let href = try pair.link.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !href.isEmpty,
                      let target = URL(string: href, relativeTo: page)?.absoluteURL,
                      target.fragment == nil, target != page,
                      let item = try? configuration.webItem(target.absoluteString, kind: .episode),
                      seen.insert(item).inserted else { continue }
                episodes.append(RuntimeEpisode(item: item, title: name, line: index + 1,
                    number: displayNumber(name) ?? offset + 1, identity: item.pageURL))
            }
            guard !episodes.isEmpty else { continue }
            let label = labels.indices.contains(index) && !labels[index].isEmpty ? labels[index] : String(index + 1)
            lines.append(RuntimeLine(id: index + 1, title: label, episodes: episodes))
        }
        guard !lines.isEmpty else { throw PlaybackFailure.catalogStructure }
        return RuntimeCatalog(work: work, lines: lines)
    }

    public func resolve(_ episode: RuntimeEpisode, in catalog: RuntimeCatalog) async throws -> URL {
        try requireSupportedConfiguration()
        guard catalog.work.item.sourceID == configuration.id, catalog.work.item.kind == .work,
              episode.item.sourceID == configuration.id, episode.item.kind == .episode,
              episode.qualityID == nil, episode.identity == episode.item.pageURL,
              try configuration.webItem(catalog.work.item.pageURL, kind: .work) == catalog.work.item,
              try configuration.webItem(episode.item.pageURL, kind: .episode) == episode.item,
              catalog.lines.contains(where: { $0.id == episode.line && $0.episodes.contains(episode) }) else {
            throw PlaybackFailure.missingEpisode
        }
        let page = try configuration.requestURL(episode.item.pageURL)
        let data = try await body(page)
        let doc = try document(data)
        var candidates = Set<URL>()
        let sized = try doc.select("video source[src][size]").array()
        let nodes: [Element]
        if let height = configuration.webSelector?.preferredVideoHeight, !sized.isEmpty {
            guard try doc.select("video").count == 1 else { throw PlaybackFailure.ambiguousMedia }
            nodes = try sized.filter { Int(try $0.attr("size")) == height }
            guard !nodes.isEmpty else { throw PlaybackFailure.missingMediaQuality }
        } else {
            nodes = try doc.select("video[src], video source[src]").array()
        }
        guard nodes.count <= 100 else { throw PlaybackFailure.ambiguousMedia }
        for node in nodes {
            candidates.insert(try media(try node.attr("src"), relativeTo: page))
        }
        let html = String(decoding: data, as: UTF8.self)
        let assignment = try NSRegularExpression(pattern: #"\b(?:var|let|const)\s+(player_[A-Za-z0-9_]+)\s*="#)
        let matches = assignment.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard matches.count <= 16 else { throw PlaybackFailure.invalidPlayerData }
        for match in matches {
            guard let range = Range(match.range(at: 1), in: html) else { throw PlaybackFailure.invalidPlayerData }
            let literal = try PublicPlayerProtocol.objectLiteral(variable: String(html[range]), in: html)
            guard let payload = try? JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String: Any] else {
                throw PlaybackFailure.invalidPlayerData
            }
            for key in ["points", "trysee", "paid", "preview"] {
                if let raw = payload[key] {
                    guard let number = number(raw), number >= 0 else { throw PlaybackFailure.invalidPlayerData }
                    guard number == 0 else { throw PlaybackFailure.authenticationRequired }
                }
            }
            try validateDeclaredIdentity(payload, page: page)
            guard let raw = payload["url"] as? String, !raw.isEmpty, raw.utf8.count <= 16_384 else {
                throw PlaybackFailure.invalidPlayerData
            }
            let encoding: Double
            if let rawEncoding = payload["encrypt"] {
                guard let value = number(rawEncoding) else { throw PlaybackFailure.invalidPlayerData }
                encoding = value
            } else { encoding = 0 }
            let decoded: String?
            switch encoding {
            case 0: decoded = raw
            case 1: decoded = raw.removingPercentEncoding
            case 2: decoded = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) }?.removingPercentEncoding
            default: throw PlaybackFailure.unsupportedEncryption
            }
            guard let decoded, !decoded.isEmpty else { throw PlaybackFailure.invalidPlayerData }
            candidates.insert(try media(decoded, relativeTo: nil))
        }
        try Task.checkCancellation()
        guard !candidates.isEmpty else {
            if !(try doc.select("iframe")).isEmpty() { throw PlaybackFailure.indirectMedia }
            throw PlaybackFailure.missingMedia
        }
        guard candidates.count == 1, let selected = candidates.first else { throw PlaybackFailure.ambiguousMedia }
        return selected
    }

    private func requireSupportedConfiguration() throws {
        guard configuration.version == 4, configuration.webSelector != nil else {
            throw SourceConfiguration.ConfigurationError.unsupportedCapability
        }
        try Task.checkCancellation()
    }

    private func response(_ request: URLRequest) async throws -> SourceHTTPResponse {
        guard let url = request.url,
              SourceHTTPTransport.permits(url, allowedHosts: configuration.requestHosts) else { throw PlaybackFailure.sourceRedirect }
        var anonymous = URLRequest(url: url)
        anonymous.httpMethod = "GET"
        anonymous.httpShouldHandleCookies = false
        anonymous.timeoutInterval = 30
        anonymous.setValue(SourceHTTPTransport.userAgent, forHTTPHeaderField: "User-Agent")
        let result: SourceHTTPResponse
        do {
            if let fetch { result = try await fetch(anonymous) }
            else {
                try await SourceSubscriptionTransport.validatePublicHost(url)
                result = try await SourceHTTPTransport().response(for: anonymous,
                    allowedHosts: configuration.requestHosts, maximumResponseBytes: Self.maximumBytes)
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if case SourceHTTPTransportError.oversizedResponse = error { throw PlaybackFailure.invalidResponseBody }
            throw error
        }
        try Task.checkCancellation()
        guard SourceHTTPTransport.permits(result.url, allowedHosts: configuration.requestHosts) else {
            throw PlaybackFailure.sourceRedirect
        }
        guard result.data.count <= Self.maximumBytes else { throw PlaybackFailure.invalidResponseBody }
        return result
    }

    private func body(_ page: URL) async throws -> Data {
        let result = try await response(URLRequest(url: page))
        switch result.statusCode {
        case 200..<300: break
        case 401: throw PlaybackFailure.authenticationRequired
        case 403: throw PlaybackFailure.httpForbidden
        case 300..<400: throw PlaybackFailure.sourceRedirect
        case 404, 410: throw PlaybackFailure.mediaNotFound
        default: throw PlaybackFailure.unsupportedResponse
        }
        // A requested episode must not quietly become a different page after redirect.
        guard result.url == page else { throw PlaybackFailure.sourceRedirect }
        guard !result.data.isEmpty else { throw PlaybackFailure.invalidResponseBody }
        return result.data
    }

    private func document(_ data: Data) throws -> Document {
        let doc = try SwiftSoup.parse(String(decoding: data, as: UTF8.self))
        guard try doc.select("#challenge-form, #cf-challenge-running, .cf-browser-verification, #cf-error-details, form[action*='/ajax/verify_check']").isEmpty() else {
            throw PlaybackFailure.websiteVerification
        }
        return doc
    }

    private func media(_ raw: String, relativeTo base: URL?) throws -> URL {
        guard !raw.isEmpty, raw.utf8.count <= 16_384,
              let url = URL(string: raw, relativeTo: base)?.absoluteURL else { throw PlaybackFailure.invalidPlayerData }
        guard url.scheme != nil else { throw PlaybackFailure.indirectMedia }
        guard url.port == nil else { throw PlaybackFailure.mediaPortUnsupported }
        guard let safe = try? configuration.requestURL(url.absoluteString, media: true), safe.fragment == nil else {
            throw PlaybackFailure.unsafeMediaAddress
        }
        let ext = safe.pathExtension.lowercased()
        guard configuration.player.allowedExtensions.contains(ext) else {
            if ext.isEmpty || ["html", "htm", "php"].contains(ext) { throw PlaybackFailure.indirectMedia }
            throw PlaybackFailure.unsupportedMediaFormat
        }
        return safe
    }

    private func title(_ element: Element) throws -> String {
        let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
        return String((text.isEmpty ? try element.attr("title").trimmingCharacters(in: .whitespacesAndNewlines) : text).prefix(500))
    }

    private func displayNumber(_ title: String) -> Int? {
        let pattern = #"(?i)^\s*(?:第\s*|episode\s*|ep\.?\s*)?([0-9]+)(?:\s*[集话話回]|\s|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title), let number = Int(title[range]), number > 0 else { return nil }
        return number
    }

    private func number(_ value: Any) -> Double? {
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    /// Where a page carries the standard MacCMS identity, declared IDs must agree.
    /// Other page shapes retain their full URL identity and never invent numeric IDs.
    private func validateDeclaredIdentity(_ payload: [String: Any], page: URL) throws {
        let patterns = [#"/vodplay/([0-9]+)-([0-9]+)-([0-9]+)\.html$"#,
                        #"/vod/play/id/([0-9]+)/sid/([0-9]+)/nid/([0-9]+)\.html$"#]
        for pattern in patterns {
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: page.path, range: NSRange(page.path.startIndex..., in: page.path)) else { continue }
            for (offset, key) in ["id", "sid", "nid"].enumerated() {
                guard let declared = payload[key] else { continue }
                guard let range = Range(match.range(at: offset + 1), in: page.path),
                      let expected = Double(page.path[range]), number(declared) == expected else {
                    throw PlaybackFailure.missingEpisode
                }
            }
        }
    }
}
