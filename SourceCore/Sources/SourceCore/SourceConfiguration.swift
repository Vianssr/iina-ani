import Foundation
import CryptoKit

public struct SourceConfiguration: Decodable, Sendable {
    /// Declarative CSS1 selectors. Executed by the iOS static-page adapter only.
    public struct WebSelector: Codable, Sendable {
        public let baseURL: String
        public let relativeLinksUseSearchURL: Bool?
        public let preferredVideoHeight: Int?
        public let subjectFormat: String
        public let searchNames: String
        public let searchLinks: String
        public let linkTemplate: String?
        public let channelFormat: String
        public let channelNames: String?
        public let episodeLists: String?
        public let episodeNames: String
        public let episodeLinks: String?
    }
    public struct Route: Codable, Sendable {
        public let pattern: String
        public let idGroup: Int
        public let lineGroup: Int?
        public let episodeGroup: Int?
        public let detailTemplate: String
        public let queryIdentityParameter: String?
        public let idIsPositiveInteger: Bool?
    }
    public struct Catalog: Codable, Sendable {
        public let url: String
        public let format: String
        public let titleSelector: String?
        public let coverSelector: String?
        public let coverAttribute: String?
        public let panelSelector: String?
        public let lineTitleSelector: String?
        public let episodeSelector: String?
        public let episodeTitleSelector: String?
        public let episodeURLAttribute: String?
        public let jsonTitlePath: String?
        public let jsonCoverPath: String?
        public let jsonEntriesPath: String?
        public let jsonEpisodeTitlePath: String?
        public let jsonEpisodeURLPath: String?
        public let jsonEpisodeIdentityPath: String?
        public let jsonMediaPath: String?
        public let jsonEntryExtensions: [String]?
        public let jsonLineTitlePath: String?
        public let jsonLineNumberPath: String?
        public let jsonEpisodeNumberPath: String?
        public let labelLinkTemplate: String?
    }
    public struct Player: Codable, Sendable {
        public let format: String
        public let payloadPattern: String?
        public let idKey: String?
        public let lineKey: String?
        public let episodeKey: String?
        public let paidKey: String?
        public let previewKey: String?
        public let encodingKey: String?
        public let urlKey: String?
        public let idIsString: Bool?
        public let allowedExtensions: [String]
        public let streamURLTemplate: String?
        public let rejectSelectors: [String]?
    }
    public struct Search: Codable, Sendable {
        public let url: String
        public let format: String
        public let queryParameter: String
        public let pageParameter: String
        public let rowsPerPage: Int
        public let firstPage: Int?
        public let resultsSelector: String?
        public let titleSelector: String?
        public let coverSelector: String?
        public let coverAttribute: String?
        public let linkSelector: String?
        public let hrefAttribute: String?
        public let nextPageSelector: String?
        public let rejectSelectors: [String]?
        public let jsonResultsPath: String?
        public let jsonTitlePath: String?
        public let jsonCoverPath: String?
        public let jsonIdentifierPath: String?
        public let jsonTotalPath: String?
    }
    /// Explicit, reviewed episode bindings, never title or catalogue-index matches.
    /// This guest XML provider is consumed by iOS, not the desktop generic decoder.
    public struct Danmaku: Codable, Sendable {
        public struct Episode: Codable, Sendable, Equatable {
            public let pageURL: String
            public let aid: Int64
            public let cid: Int64
        }
        public let provider: String
        public let episodes: [Episode]
    }
    public enum ConfigurationError: Error, Equatable { case invalidConfiguration, invalidURL, unsupportedCapability, invalidMedia }
    public struct CompiledPattern: @unchecked Sendable { public let value: NSRegularExpression }

    public let id: String
    public let name: String
    public let version: Int
    public let hosts: [String]
    public let mediaHosts: [String]
    public let anonymousExternalHTTPSMedia: Bool
    public let credentialHosts: [String]
    public let capabilities: Set<SourceCapability>
    public let route: Route
    public let catalog: Catalog
    public let player: Player
    public let search: Search?
    public let danmaku: Danmaku?
    public let webSelector: WebSelector?
    /// Content revision, separate from the schema version (v2 adds danmaku bindings).
    public let configurationRevision: String
    public let contentKind: MediaContentKind?
    public var classification: MediaClassification {
        guard let contentKind else { return .unknown }
        return MediaClassification(kind: contentKind, provenance: "source-schema:" + id + ":contentKind:v" + String(version))
    }
    public let compiledRoutePattern: CompiledPattern
    public let compiledPlayerPattern: CompiledPattern?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cookie = try c.decodeIfPresent(String.self, forKey: .cookie)
        let token = try c.decodeIfPresent(String.self, forKey: .token)
        let authorization = try c.decodeIfPresent(String.self, forKey: .authorization)
        let headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        guard cookie == nil, token == nil, authorization == nil, headers == nil else { throw ConfigurationError.invalidConfiguration }
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(Int.self, forKey: .version)
        guard (1...3).contains(version), version >= 2 || !c.contains(.danmaku),
              (version == 3) == c.contains(.webSelector) else {
            throw ConfigurationError.invalidConfiguration
        }
        hosts = try c.decode([String].self, forKey: .hosts).map { $0.lowercased() }
        mediaHosts = (try c.decodeIfPresent([String].self, forKey: .mediaHosts) ?? []).map { $0.lowercased() }
        anonymousExternalHTTPSMedia = try c.decodeIfPresent(Bool.self, forKey: .anonymousExternalHTTPSMedia) ?? false
        credentialHosts = (try c.decodeIfPresent([String].self, forKey: .credentialHosts) ?? []).map { $0.lowercased() }
        capabilities = try c.decode(Set<SourceCapability>.self, forKey: .capabilities)
        route = try c.decode(Route.self, forKey: .route)
        catalog = try c.decode(Catalog.self, forKey: .catalog)
        player = try c.decode(Player.self, forKey: .player)
        search = try c.decodeIfPresent(Search.self, forKey: .search)
        danmaku = try c.decodeIfPresent(Danmaku.self, forKey: .danmaku)
        webSelector = try c.decodeIfPresent(WebSelector.self, forKey: .webSelector)
        contentKind = try c.decodeIfPresent(MediaContentKind.self, forKey: .contentKind)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = RevisionContent(id: id, name: name, version: version,
            hosts: hosts, mediaHosts: mediaHosts, anonymousExternalHTTPSMedia: anonymousExternalHTTPSMedia,
            credentialHosts: credentialHosts, capabilities: capabilities.map(\.rawValue).sorted(),
            route: route, catalog: catalog, player: player, search: search, contentKind: contentKind, danmaku: danmaku, webSelector: webSelector)
        configurationRevision = "sha256:" + SHA256.hash(data: try encoder.encode(canonical))
            .map { String(format: "%02x", $0) }.joined()
        guard route.pattern.utf8.count <= 1024, let routeRegex = try? NSRegularExpression(pattern: route.pattern) else { throw ConfigurationError.invalidConfiguration }
        compiledRoutePattern = CompiledPattern(value: routeRegex)
        if player.format == "html", let playerPattern = player.payloadPattern {
            guard let regex = try? NSRegularExpression(pattern: playerPattern) else { throw ConfigurationError.invalidConfiguration }
            compiledPlayerPattern = CompiledPattern(value: regex)
        } else { compiledPlayerPattern = nil }
        try validate()
    }
    private enum CodingKeys: String, CodingKey {
        case id,name,version,hosts,mediaHosts,anonymousExternalHTTPSMedia,credentialHosts,capabilities,route,catalog,player,search,contentKind,danmaku,webSelector
        case cookie,token,authorization,headers
    }

    /// Encode decoded rules rather than input bytes: JSON key order and optional defaults
    /// cannot change the revision, and non-content compiled regular expressions are excluded.
    private struct RevisionContent: Encodable {
        let id: String
        let name: String
        let version: Int
        let hosts: [String]
        let mediaHosts: [String]
        let anonymousExternalHTTPSMedia: Bool
        let credentialHosts: [String]
        let capabilities: [String]
        let route: Route
        let catalog: Catalog
        let player: Player
        let search: Search?
        let contentKind: MediaContentKind?
        let danmaku: Danmaku?
        let webSelector: WebSelector?
    }
    /// Lossless decoded-rule serialization for full-config and search-rule updates.
    public func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(RevisionContent(id: id, name: name, version: version,
            hosts: hosts, mediaHosts: mediaHosts, anonymousExternalHTTPSMedia: anonymousExternalHTTPSMedia,
            credentialHosts: credentialHosts, capabilities: capabilities.map(\.rawValue).sorted(),
            route: route, catalog: catalog, player: player, search: search, contentKind: contentKind, danmaku: danmaku, webSelector: webSelector))
    }
    public static func load(data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigurationError.invalidConfiguration }
        let schemas: [String: Set<String>] = [
            "": ["id","name","version","hosts","mediaHosts","anonymousExternalHTTPSMedia","credentialHosts","capabilities","route","catalog","player","search","contentKind","danmaku","webSelector","cookie","token","authorization","headers"],
            "route": ["pattern","idGroup","lineGroup","episodeGroup","detailTemplate","queryIdentityParameter","idIsPositiveInteger"],
            "catalog": ["url","format","titleSelector","coverSelector","coverAttribute","panelSelector","lineTitleSelector","episodeSelector","episodeTitleSelector","episodeURLAttribute","jsonTitlePath","jsonCoverPath","jsonEntriesPath","jsonEpisodeTitlePath","jsonEpisodeURLPath","jsonEpisodeIdentityPath","jsonMediaPath","jsonEntryExtensions","jsonLineTitlePath","jsonLineNumberPath","jsonEpisodeNumberPath","labelLinkTemplate"],
            "player": ["format","payloadPattern","idKey","lineKey","episodeKey","paidKey","previewKey","encodingKey","urlKey","idIsString","allowedExtensions","streamURLTemplate","rejectSelectors"],
            "search": ["url", "format", "queryParameter", "pageParameter", "rowsPerPage", "firstPage", "resultsSelector", "titleSelector", "linkSelector", "nextPageSelector", "rejectSelectors", "coverSelector", "coverAttribute", "hrefAttribute", "jsonResultsPath", "jsonTitlePath", "jsonCoverPath", "jsonIdentifierPath", "jsonTotalPath"],
            "webSelector": ["baseURL", "relativeLinksUseSearchURL", "preferredVideoHeight", "subjectFormat", "searchNames", "searchLinks", "linkTemplate", "channelFormat", "channelNames", "episodeLists", "episodeNames", "episodeLinks"],
            "danmaku": ["provider", "episodes"]
        ]
        for (section, allowed) in schemas {
            let fields: [String: Any]
            if section.isEmpty { fields = root }
            else if let nested = root[section] as? [String: Any] { fields = nested }
            else if root[section] == nil && ["search", "danmaku", "webSelector"].contains(section) { continue }
            else { throw ConfigurationError.invalidConfiguration }
            guard Set(fields.keys).isSubset(of: allowed) else { throw ConfigurationError.invalidConfiguration }
        }
        if root["version"] as? Int == 3 {
            let webFields: [String: Set<String>] = [
                "route": ["pattern", "idGroup", "detailTemplate"],
                "catalog": ["url", "format"],
                "player": ["format", "allowedExtensions"],
                "search": ["url", "format", "queryParameter", "pageParameter", "rowsPerPage"]
            ]
            for (section, allowed) in webFields {
                guard let fields = root[section] as? [String: Any], Set(fields.keys).isSubset(of: allowed) else {
                    throw ConfigurationError.invalidConfiguration
                }
            }
        }
        if let danmaku = root["danmaku"] as? [String: Any], let episodes = danmaku["episodes"] as? [[String: Any]] {
            guard episodes.allSatisfy({ Set($0.keys).isSubset(of: ["pageURL", "aid", "cid"]) }) else {
                throw ConfigurationError.invalidConfiguration
            }
        }
        return try JSONDecoder().decode(SourceConfiguration.self, from: data)
    }
    public static func load(fileURL: URL) throws -> Self { try load(data: Data(contentsOf: fileURL)) }

    public func validate() throws {
        let hostRegex = try NSRegularExpression(pattern: "^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$")
        func validHost(_ host: String) -> Bool {
            hostRegex.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil && !host.contains("..") && !host.hasPrefix(".") && !host.hasSuffix(".")
        }
        let supported: Set<SourceCapability> = [.information, .resolve, .episodes, .lines, .quality, .search, .iina, .mpv, .download]
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              !name.isEmpty, (1...3).contains(version), !hosts.isEmpty, hosts.allSatisfy(validHost), mediaHosts.allSatisfy(validHost),
              credentialHosts.allSatisfy({ hosts.contains($0) }), !capabilities.isEmpty, capabilities.isSubset(of: supported),
              capabilities.contains(.information), capabilities.contains(.resolve), capabilities.contains(.episodes),
              route.idGroup > 0, route.lineGroup.map({ $0 > 0 }) ?? true, route.episodeGroup.map({ $0 > 0 }) ?? true,
              ["html", "json", "web-selector"].contains(catalog.format), ["html", "json", "web-selector"].contains(player.format),
              !player.allowedExtensions.isEmpty,
              player.allowedExtensions.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }),
              compiledRoutePattern.value.numberOfCaptureGroups >= max(route.idGroup, max(route.lineGroup ?? 0, route.episodeGroup ?? 0)) else {
            throw ConfigurationError.invalidConfiguration
        }
        if let spec = webSelector {
            guard version == 3, catalog.format == "web-selector", player.format == "web-selector",
                  search?.format == "web-selector", search?.url.components(separatedBy: "{query}").count == 2,
                  search?.queryParameter == "", search?.pageParameter == "", search?.rowsPerPage == 100,
                  route.pattern == "^/(.*)$", route.idGroup == 1,
                  route.lineGroup == nil, route.episodeGroup == nil, route.queryIdentityParameter == nil,
                  route.detailTemplate == spec.baseURL + "/{id}", catalog.url == route.detailTemplate,
                  player.streamURLTemplate == nil, player.payloadPattern == nil,
                  URLComponents(string: spec.baseURL)?.query == nil,
                  URLComponents(string: spec.baseURL)?.fragment == nil,
                  credentialHosts.isEmpty, danmaku == nil,
                  capabilities.isSubset(of: [.information, .search, .episodes, .lines, .resolve, .mpv]),
                  ["a", "indexed", "json-path-indexed"].contains(spec.subjectFormat),
                  ["index-grouped", "no-channel"].contains(spec.channelFormat),
                  (try? requestURL(spec.baseURL)) != nil,
                  let searchURL = search?.url, !hasInlineAuthentication(searchURL), !hasInlineAuthentication(spec.baseURL),
                  !expanded(searchURL, values: ["query": "test"]).contains("{"),
                  !expanded(searchURL, values: ["query": "test"]).contains("}"),
                  (try? requestURL(expanded(searchURL, values: ["query": "test"]))) != nil else {
                throw ConfigurationError.invalidConfiguration
            }
            if let height = spec.preferredVideoHeight, !(1...4320).contains(height) {
                throw ConfigurationError.invalidConfiguration
            }
            let fields = [spec.searchNames, spec.searchLinks, spec.episodeNames] +
                [spec.episodeLists, spec.episodeLinks, spec.channelNames].compactMap { $0 }
            guard fields.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 &&
                !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
                spec.channelFormat != "index-grouped" || spec.episodeLists != nil,
                spec.linkTemplate.map({ $0.utf8.count <= 4096 && $0.contains("{value}") }) ?? true else {
                throw ConfigurationError.invalidConfiguration
            }
            if let template = spec.linkTemplate {
                let sample = template.replacingOccurrences(of: "{value}", with: "ConfigValidationID")
                guard !sample.contains("{"), !sample.contains("}"),
                      let base = URL(string: spec.baseURL),
                      let target = URL(string: sample, relativeTo: base)?.absoluteURL,
                      target.fragment == nil, !hasInlineAuthentication(target.absoluteString),
                      (try? requestURL(target.absoluteString)) != nil else {
                    throw ConfigurationError.invalidConfiguration
                }
            }
            return
        }
        guard version < 3, catalog.format != "web-selector", player.format != "web-selector" else {
            throw ConfigurationError.invalidConfiguration
        }
        let sampleID = "ConfigValidationID"
        func hasInlineAuthentication(_ raw: String) -> Bool {
            let names: Set<String> = ["cookie", "token", "access_token", "authorization", "auth", "api_key", "apikey", "password"]
            return (URLComponents(string: raw)?.queryItems ?? []).contains { names.contains($0.name.lowercased()) }
        }
        let detail = expanded(route.detailTemplate, values: ["id": sampleID])
        guard !hasInlineAuthentication(route.detailTemplate), !detail.contains("{") && !detail.contains("}"), (try? requestURL(detail)) != nil else { throw ConfigurationError.invalidConfiguration }
        let catalogURL = expanded(catalog.url, values: ["id": sampleID])
        guard !hasInlineAuthentication(catalog.url), !catalogURL.contains("{") && !catalogURL.contains("}"), (try? requestURL(catalogURL)) != nil else { throw ConfigurationError.invalidConfiguration }
        if catalog.format == "html" {
            guard let title = catalog.titleSelector, !title.isEmpty, let panels = catalog.panelSelector, !panels.isEmpty,
                  let episodes = catalog.episodeSelector, !episodes.isEmpty, let href = catalog.episodeURLAttribute, !href.isEmpty else {
                throw ConfigurationError.invalidConfiguration
            }
        } else {
            guard let title = catalog.jsonTitlePath, !title.isEmpty, let entries = catalog.jsonEntriesPath, !entries.isEmpty,
                  let episodeTitle = catalog.jsonEpisodeTitlePath, !episodeTitle.isEmpty,
                  (catalog.jsonEpisodeIdentityPath != nil || catalog.jsonEpisodeURLPath != nil) else {
                throw ConfigurationError.invalidConfiguration
            }
        }
        if let template = player.streamURLTemplate {
            let media = expanded(template, values: ["id": sampleID, "line": "1", "episode": "test.mp4", "file": "test.mp4"])
            guard !hasInlineAuthentication(template), !media.contains("{") && !media.contains("}"), (try? requestURL(media, media: true)) != nil else {
                throw ConfigurationError.invalidConfiguration
            }
        } else {
            let keys = [player.idKey, player.lineKey, player.episodeKey, player.paidKey,
                        player.previewKey, player.encodingKey, player.urlKey]
            guard keys.allSatisfy({ $0?.isEmpty == false }) else { throw ConfigurationError.invalidConfiguration }
            if player.format == "html" {
                guard let regex = compiledPlayerPattern?.value, regex.numberOfCaptureGroups >= 1 else {
                    throw ConfigurationError.invalidConfiguration
                }
            } else {
                guard let path = player.payloadPattern, !path.isEmpty else { throw ConfigurationError.invalidConfiguration }
            }
        }
        if let search {
            let searchURL = expanded(search.url, values: ["query": "test", "page": "1"])
            guard capabilities.contains(.search), search.rowsPerPage > 0, search.rowsPerPage <= 100,
                  (0...1).contains(search.firstPage ?? 1),
                  ["html", "json"].contains(search.format), !hasInlineAuthentication(search.url), !searchURL.contains("{") && !searchURL.contains("}"),
                  (try? requestURL(searchURL)) != nil else { throw ConfigurationError.invalidConfiguration }
            if search.format == "html" {
                guard let results = search.resultsSelector, !results.isEmpty, let title = search.titleSelector, !title.isEmpty,
                      let href = search.hrefAttribute, !href.isEmpty else { throw ConfigurationError.invalidConfiguration }
            } else {
                guard let results = search.jsonResultsPath, !results.isEmpty, let title = search.jsonTitlePath, !title.isEmpty,
                      let identifier = search.jsonIdentifierPath, !identifier.isEmpty else { throw ConfigurationError.invalidConfiguration }
            }
        } else if capabilities.contains(.search) { throw ConfigurationError.invalidConfiguration }
        if let danmaku {
            guard danmaku.provider == "bilibili-xml", !danmaku.episodes.isEmpty,
                  danmaku.episodes.count <= 10_000, contentKind != .live else {
                throw ConfigurationError.invalidConfiguration
            }
            var pages = Set<String>()
            for episode in danmaku.episodes {
                guard episode.aid > 0, episode.cid > 0,
                      ConfirmedSourceMapping.isCanonicalPublicPage(episode.pageURL),
                      let page = try? requestURL(episode.pageURL),
                      let ref = try? item(page.absoluteString), ref.kind == .episode,
                      ref.pageURL == episode.pageURL, pages.insert(episode.pageURL).inserted else {
                    throw ConfigurationError.invalidConfiguration
                }
                let components = URLComponents(url: page, resolvingAgainstBaseURL: false)
                let query = components?.queryItems ?? []
                guard components?.fragment == nil,
                      query.allSatisfy({ $0.name == route.queryIdentityParameter }),
                      query.count <= 1,
                      let match = compiledRoutePattern.value.firstMatch(in: page.path, range: NSRange(page.path.startIndex..., in: page.path)),
                      match.range == NSRange(page.path.startIndex..., in: page.path) else {
                    throw ConfigurationError.invalidConfiguration
                }
            }
        }

        if capabilities.contains(.lines) {
            guard route.lineGroup != nil || (catalog.format == "json" && catalog.jsonLineNumberPath != nil && catalog.jsonLineTitlePath != nil) else {
                throw ConfigurationError.unsupportedCapability
            }
        }
        if capabilities.contains(.quality) && !capabilities.contains(.lines) { throw ConfigurationError.invalidConfiguration }
        guard !capabilities.contains(.danmaku), !capabilities.contains(.jsPlayer),
              !capabilities.contains(.browse) else { throw ConfigurationError.unsupportedCapability }
    }
    /// The approved configuration supplies the cross-provider identity assertion.
    /// Runtime provider metadata and XML chatid must still be verified before use.
    public func danmakuBinding(for selection: PlayableSelection, revision: String?) throws -> Danmaku.Episode? {
        guard revision == configurationRevision else { throw PlaybackFailure.configurationChanged }
        guard let danmaku, selection.classification.kind != .live else { return nil }
        let durable = try mappingSelection(selection)
        guard let episode = durable.episode else { return nil }
        let matches = danmaku.episodes.filter { $0.pageURL == episode.pageURL }
        guard matches.count <= 1 else { throw ConfigurationError.invalidConfiguration }
        return matches.first
    }

    /// Generic HTML/JSON parsers resolve one stream per line, not independent quality choices.
    private static let parserCapabilities: Set<SourceCapability> = [
        .information, .resolve, .episodes, .lines, .search, .iina, .mpv, .download
    ]

    public func effectiveCapabilities(on platform: SourcePlatform) -> Set<SourceCapability> {
        if webSelector != nil && platform != .iOS { return [] }
        return capabilities.intersection(Self.parserCapabilities).intersection(platform.capabilities)
    }

    public func descriptor(on platform: SourcePlatform) -> SourceDescriptor {
        SourceDescriptor(id: id, name: name, version: version, capabilities: effectiveCapabilities(on: platform))
    }

    public var descriptor: SourceDescriptor {
        #if os(iOS)
        return descriptor(on: .iOS)
        #else
        return descriptor(on: .macOS)
        #endif
    }
    public func matches(_ raw: String) -> Bool { (try? item(raw)) != nil }

    public func item(_ raw: String) throws -> SourceItemRef {
        if webSelector != nil { return try webItem(raw, kind: .work) }
        guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              c.port == nil, c.user == nil, c.password == nil, let host = c.host?.lowercased(), hosts.contains(host) else {
            throw ConfigurationError.invalidURL
        }
        let path = c.path
        guard let match = compiledRoutePattern.value.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let idRange = Range(match.range(at: route.idGroup), in: path) else { throw ConfigurationError.invalidURL }
        let identifier = String(path[idRange])
        guard !identifier.isEmpty, identifier != ".", identifier != "..", identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else {
            throw ConfigurationError.invalidURL
        }
        if route.idIsPositiveInteger == true {
            guard let number = Int(identifier), number > 0 else { throw ConfigurationError.invalidURL }
        }
        for group in [route.lineGroup, route.episodeGroup].compactMap({ $0 }) where match.range(at: group).location != NSNotFound {
            guard Int((path as NSString).substring(with: match.range(at: group))) != nil else { throw ConfigurationError.invalidURL }
        }
        let line = route.lineGroup.flatMap { match.range(at: $0).location == NSNotFound ? nil : Int((path as NSString).substring(with: match.range(at: $0))) }
        let episode = route.episodeGroup.flatMap { match.range(at: $0).location == NSNotFound ? nil : Int((path as NSString).substring(with: match.range(at: $0))) }
        let queryIdentity = route.queryIdentityParameter.flatMap { key in c.queryItems?.first(where: { $0.name == key })?.value }
        guard line.map({ $0 > 0 }) ?? true, episode.map({ $0 > 0 }) ?? true,
              queryIdentity.map({ !$0.isEmpty }) ?? true else { throw ConfigurationError.invalidURL }
        var normalized = c
        normalized.scheme = scheme
        normalized.host = host
        normalized.fragment = nil
        guard let page = normalized.string else { throw ConfigurationError.invalidURL }
        return SourceItemRef(sourceID: id, pageURL: page, kind: episode != nil || queryIdentity != nil ? .episode : .work)
    }

    /// CSS1 keeps the actual public page URL; selector order is never a durable identity.
    public func webItem(_ raw: String, kind: SourceItemRef.Kind) throws -> SourceItemRef {
        guard webSelector != nil, kind == .work || kind == .episode,
              raw.utf8.count <= 8192 else { throw ConfigurationError.invalidURL }
        let url = try requestURL(raw)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ConfigurationError.invalidURL
        }
        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.fragment = nil
        guard let canonical = components.string, ConfirmedSourceMapping.isCanonicalPublicPage(canonical) else {
            throw ConfigurationError.invalidURL
        }
        return SourceItemRef(sourceID: id, pageURL: canonical, kind: kind)
    }

    /// Canonical durable page identities for configured sources only; native adapters
    /// retain their existing selection and URL behavior.
    public func mappingSelection(_ selection: PlayableSelection) throws -> PlayableSelection {
        guard selection.torrent == nil, selection.item.sourceID == id,
              selection.item.kind == .work, let selectedEpisode = selection.episode,
              selectedEpisode.sourceID == id, selectedEpisode.kind == .episode else {
            throw PlaybackFailure.missingEpisode
        }
        guard selection.lineID.map(ConfirmedSourceMapping.safeLabel) ?? true,
              selection.qualityID.map(ConfirmedSourceMapping.safeLabel) ?? true else {
            throw PlaybackFailure.unsupportedResponse
        }
        if webSelector != nil {
            var durable = selection
            durable.item = try webItem(selection.item.pageURL, kind: .work)
            durable.episode = try webItem(selectedEpisode.pageURL, kind: .episode)
            durable.accountID = nil
            durable.classification = classification
            return durable
        }
        if let parameter = route.queryIdentityParameter,
           !ConfirmedSourceMapping.safeIdentityParameter(parameter) {
            throw PlaybackFailure.unsupportedResponse
        }
        func canonical(_ ref: SourceItemRef) throws -> SourceItemRef {
            guard var components = URLComponents(string: ref.pageURL),
                  components.user == nil, components.password == nil,
                  let match = compiledRoutePattern.value.firstMatch(in: components.path,
                      range: NSRange(components.path.startIndex..., in: components.path)),
                  match.range == NSRange(components.path.startIndex..., in: components.path) else {
                throw PlaybackFailure.unsupportedResponse
            }
            let identity = (components.queryItems ?? []).filter { $0.name == route.queryIdentityParameter }
            guard identity.count <= 1 else { throw PlaybackFailure.unsupportedResponse }
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            components.queryItems = identity.isEmpty ? nil : identity
            components.fragment = nil
            guard let raw = components.string, ConfirmedSourceMapping.isCanonicalPublicPage(raw),
                  let canonical = try? item(raw), canonical.kind == ref.kind else {
                throw PlaybackFailure.unsupportedResponse
            }
            return canonical
        }
        let work = try canonical(selection.item)
        let episode = try canonical(selectedEpisode)
        guard let workParts = try? parts(work.pageURL), let episodeParts = try? parts(episode.pageURL),
              workParts.id == episodeParts.id, episodeParts.episodeIdentity != nil else {
            throw PlaybackFailure.missingEpisode
        }
        // The route line is retained in the episode page. selection.lineID is
        // adapter-owned: desktop backup-stream index vs iOS catalog line number.
        var durable = selection
        durable.item = work
        durable.episode = episode
        durable.accountID = nil
        durable.classification = classification
        return durable
    }

    public func parts(_ raw: String) throws -> (item: SourceItemRef, id: String, line: Int?, episode: Int?, episodeIdentity: String?) {
        let ref = try item(raw)
        guard let c = URLComponents(string: ref.pageURL),
              let match = compiledRoutePattern.value.firstMatch(in: c.path, range: NSRange(c.path.startIndex..., in: c.path)),
              let range = Range(match.range(at: route.idGroup), in: c.path) else { throw ConfigurationError.invalidURL }
        let line = route.lineGroup.flatMap { match.range(at: $0).location == NSNotFound ? nil : Int((c.path as NSString).substring(with: match.range(at: $0))) }
        let episode = route.episodeGroup.flatMap { match.range(at: $0).location == NSNotFound ? nil : Int((c.path as NSString).substring(with: match.range(at: $0))) }
        let queryID = route.queryIdentityParameter.flatMap { key in c.queryItems?.first(where: { $0.name == key })?.value }
        let capturedID = String(c.path[range])
        let identifier: String
        if route.idIsPositiveInteger == true {
            guard let number = Int(capturedID), number > 0 else { throw ConfigurationError.invalidURL }
            identifier = String(number)
        } else { identifier = capturedID }
        return (ref, identifier, line, episode, queryID ?? episode.map(String.init))
    }
    public func expanded(_ template: String, values: [String: String]) -> String {
        var safe = CharacterSet.alphanumerics
        safe.insert(charactersIn: "-._~")
        return values.reduce(template) { current, entry in
            let value = entry.value.addingPercentEncoding(withAllowedCharacters: safe) ?? ""
            return current.replacingOccurrences(of: "{\(entry.key)}", with: value)
        }
    }
    /// Verified CSS1 site moves. Keep saved page identities intact and permit only
    /// these exact HTTPS destinations, never arbitrary redirect hosts.
    public var requestHosts: Set<String> {
        var result = Set(hosts)
        guard webSelector != nil else { return result }
        let moves = ["www.2kdm.com": "www.mutedm.com",
                     "www.didahd.pro": "www.didahd.xyz",
                     "www.rebozj.pro": "www.rebozj.cc"]
        for (old, current) in moves where result.contains(old) { result.insert(current) }
        return result
    }

    /// XiFan currently publishes HTTPS media on this one non-default endpoint.
    /// This does not authorize ports on source pages or on other media hosts.
    public func allowsMediaPort(_ url: URL) -> Bool {
        url.port == nil || (webSelector != nil && hosts.contains("dm1.xfdm.pro") &&
            url.scheme?.lowercased() == "https" && url.host?.lowercased() == "play.xfvod.pro" && url.port == 8088)
    }

    public func requestURL(_ raw: String, media: Bool = false) throws -> URL {
        guard let c = URLComponents(string: raw), c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              let host = c.host?.lowercased(),
              media ? (mediaHosts.contains(host) || anonymousExternalHTTPSMedia) : requestHosts.contains(host),
              let url = c.url, media ? allowsMediaPort(url) : c.port == nil else { throw ConfigurationError.invalidURL }
        return url
    }
    public func validatedPlayerMediaURL(_ payload: [String: Any], id: String, line: Int, episode: Int) throws -> String {
        let s = player
        guard let idKey = s.idKey, let lineKey = s.lineKey, let episodeKey = s.episodeKey,
              let paidKey = s.paidKey, let previewKey = s.previewKey, let encodingKey = s.encodingKey, let urlKey = s.urlKey else {
            throw ConfigurationError.invalidConfiguration
        }
        let actualID = (s.idIsString ?? false) ? payload[idKey] as? String : (payload[idKey] as? NSNumber)?.stringValue
        guard actualID == id,
              let actualLine = payload[lineKey] as? NSNumber, actualLine.intValue == line, actualLine.doubleValue == Double(line),
              let actualEpisode = payload[episodeKey] as? NSNumber, actualEpisode.intValue == episode, actualEpisode.doubleValue == Double(episode),
              (payload[paidKey] as? NSNumber)?.doubleValue == 0, (payload[previewKey] as? NSNumber)?.doubleValue == 0,
              let encoding = payload[encodingKey] as? NSNumber, encoding.doubleValue == Double(encoding.intValue),
              let encoded = payload[urlKey] as? String else {
            throw ConfigurationError.invalidMedia
        }
        let decoded: String?
        switch encoding.intValue {
        case 0: decoded = encoded
        case 1: decoded = encoded.removingPercentEncoding
        case 2: decoded = Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }?.removingPercentEncoding
        default: decoded = nil
        }
        guard let decoded, let url = URL(string: decoded), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased(), mediaHosts.contains(host) || anonymousExternalHTTPSMedia,
              player.allowedExtensions.contains(url.pathExtension.lowercased()) else { throw ConfigurationError.invalidMedia }
        return url.absoluteString
    }
}
