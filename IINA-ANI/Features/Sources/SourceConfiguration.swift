import Foundation

struct SourceConfiguration: Decodable, Sendable {
    struct Route: Decodable, Sendable {
        let pattern: String
        let idGroup: Int
        let lineGroup: Int?
        let episodeGroup: Int?
        let detailTemplate: String
        let queryIdentityParameter: String?
        let idIsPositiveInteger: Bool?
    }
    struct Catalog: Decodable, Sendable {
        let url: String
        let format: String
        let titleSelector: String?
        let coverSelector: String?
        let coverAttribute: String?
        let panelSelector: String?
        let lineTitleSelector: String?
        let episodeSelector: String?
        let episodeTitleSelector: String?
        let episodeURLAttribute: String?
        let jsonTitlePath: String?
        let jsonCoverPath: String?
        let jsonEntriesPath: String?
        let jsonEpisodeTitlePath: String?
        let jsonEpisodeURLPath: String?
        let jsonEpisodeIdentityPath: String?
        let jsonMediaPath: String?
        let jsonEntryExtensions: [String]?
        let jsonLineTitlePath: String?
        let jsonLineNumberPath: String?
        let jsonEpisodeNumberPath: String?
        let labelLinkTemplate: String?
    }
    struct Player: Decodable, Sendable {
        let format: String
        let payloadPattern: String?
        let idKey: String?
        let lineKey: String?
        let episodeKey: String?
        let paidKey: String?
        let previewKey: String?
        let encodingKey: String?
        let urlKey: String?
        let idIsString: Bool?
        let allowedExtensions: [String]
        let streamURLTemplate: String?
        let rejectSelectors: [String]?
    }
    struct Search: Codable, Sendable {
        let url: String
        let format: String
        let queryParameter: String
        let pageParameter: String
        let rowsPerPage: Int
        let firstPage: Int?
        let resultsSelector: String?
        let titleSelector: String?
        let coverSelector: String?
        let coverAttribute: String?
        let linkSelector: String?
        let hrefAttribute: String?
        let nextPageSelector: String?
        let rejectSelectors: [String]?
        let jsonResultsPath: String?
        let jsonTitlePath: String?
        let jsonCoverPath: String?
        let jsonIdentifierPath: String?
        let jsonTotalPath: String?
    }
    enum ConfigurationError: Error, Equatable { case invalidConfiguration, invalidURL, unsupportedCapability }
    struct CompiledPattern: @unchecked Sendable { let value: NSRegularExpression }

    let id: String
    let name: String
    let version: Int
    let hosts: [String]
    let mediaHosts: [String]
    let anonymousExternalHTTPSMedia: Bool
    let credentialHosts: [String]
    let capabilities: Set<SourceCapability>
    let route: Route
    let catalog: Catalog
    let player: Player
    let search: Search?
    let contentKind: MediaContentKind?
    var classification: MediaClassification {
        guard let contentKind else { return .unknown }
        return MediaClassification(kind: contentKind, provenance: "source-schema:" + id + ":contentKind:v" + String(version))
    }
    let compiledRoutePattern: CompiledPattern
    let compiledPlayerPattern: CompiledPattern?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cookie = try c.decodeIfPresent(String.self, forKey: .cookie)
        let token = try c.decodeIfPresent(String.self, forKey: .token)
        let authorization = try c.decodeIfPresent(String.self, forKey: .authorization)
        let headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        guard cookie == nil, token == nil, authorization == nil, headers == nil else { throw ConfigurationError.invalidConfiguration }
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(Int.self, forKey: .version)
        hosts = try c.decode([String].self, forKey: .hosts).map { $0.lowercased() }
        mediaHosts = (try c.decodeIfPresent([String].self, forKey: .mediaHosts) ?? []).map { $0.lowercased() }
        anonymousExternalHTTPSMedia = try c.decodeIfPresent(Bool.self, forKey: .anonymousExternalHTTPSMedia) ?? false
        credentialHosts = (try c.decodeIfPresent([String].self, forKey: .credentialHosts) ?? []).map { $0.lowercased() }
        capabilities = try c.decode(Set<SourceCapability>.self, forKey: .capabilities)
        route = try c.decode(Route.self, forKey: .route)
        catalog = try c.decode(Catalog.self, forKey: .catalog)
        player = try c.decode(Player.self, forKey: .player)
        search = try c.decodeIfPresent(Search.self, forKey: .search)
        contentKind = try c.decodeIfPresent(MediaContentKind.self, forKey: .contentKind)
        guard route.pattern.utf8.count <= 1024, let routeRegex = try? NSRegularExpression(pattern: route.pattern) else { throw ConfigurationError.invalidConfiguration }
        compiledRoutePattern = CompiledPattern(value: routeRegex)
        if player.format == "html", let playerPattern = player.payloadPattern {
            guard let regex = try? NSRegularExpression(pattern: playerPattern) else { throw ConfigurationError.invalidConfiguration }
            compiledPlayerPattern = CompiledPattern(value: regex)
        } else { compiledPlayerPattern = nil }
        try validate()
    }
    private enum CodingKeys: String, CodingKey {
        case id,name,version,hosts,mediaHosts,anonymousExternalHTTPSMedia,credentialHosts,capabilities,route,catalog,player,search,contentKind
        case cookie,token,authorization,headers
    }
    static func load(data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigurationError.invalidConfiguration }
        let schemas: [String: Set<String>] = [
            "": ["id","name","version","hosts","mediaHosts","anonymousExternalHTTPSMedia","credentialHosts","capabilities","route","catalog","player","search","contentKind","cookie","token","authorization","headers"],
            "route": ["pattern","idGroup","lineGroup","episodeGroup","detailTemplate","queryIdentityParameter","idIsPositiveInteger"],
            "catalog": ["url","format","titleSelector","coverSelector","coverAttribute","panelSelector","lineTitleSelector","episodeSelector","episodeTitleSelector","episodeURLAttribute","jsonTitlePath","jsonCoverPath","jsonEntriesPath","jsonEpisodeTitlePath","jsonEpisodeURLPath","jsonEpisodeIdentityPath","jsonMediaPath","jsonEntryExtensions","jsonLineTitlePath","jsonLineNumberPath","jsonEpisodeNumberPath","labelLinkTemplate"],
            "player": ["format","payloadPattern","idKey","lineKey","episodeKey","paidKey","previewKey","encodingKey","urlKey","idIsString","allowedExtensions","streamURLTemplate","rejectSelectors"],
            "search": ["url", "format", "queryParameter", "pageParameter", "rowsPerPage", "firstPage", "resultsSelector", "titleSelector", "linkSelector", "nextPageSelector", "rejectSelectors", "coverSelector", "coverAttribute", "hrefAttribute", "jsonResultsPath", "jsonTitlePath", "jsonCoverPath", "jsonIdentifierPath", "jsonTotalPath"]
        ]
        for (section, allowed) in schemas {
            let fields: [String: Any]
            if section.isEmpty { fields = root }
            else if let nested = root[section] as? [String: Any] { fields = nested }
            else if root[section] == nil && section == "search" { continue }
            else { throw ConfigurationError.invalidConfiguration }
            guard Set(fields.keys).isSubset(of: allowed) else { throw ConfigurationError.invalidConfiguration }
        }
        return try JSONDecoder().decode(SourceConfiguration.self, from: data)
    }
    static func load(fileURL: URL) throws -> Self { try load(data: Data(contentsOf: fileURL)) }

    func validate() throws {
        let hostRegex = try NSRegularExpression(pattern: "^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$")
        func validHost(_ host: String) -> Bool {
            hostRegex.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil && !host.contains("..") && !host.hasPrefix(".") && !host.hasSuffix(".")
        }
        let supported: Set<SourceCapability> = [.information, .resolve, .episodes, .lines, .quality, .search, .iina, .mpv, .download]
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              !name.isEmpty, version == 1, !hosts.isEmpty, hosts.allSatisfy(validHost), mediaHosts.allSatisfy(validHost),
              credentialHosts.allSatisfy({ hosts.contains($0) }), !capabilities.isEmpty, capabilities.isSubset(of: supported),
              capabilities.contains(.information), capabilities.contains(.resolve), capabilities.contains(.episodes),
              route.idGroup > 0, route.lineGroup.map({ $0 > 0 }) ?? true, route.episodeGroup.map({ $0 > 0 }) ?? true,
              ["html", "json"].contains(catalog.format), ["html", "json"].contains(player.format),
              !player.allowedExtensions.isEmpty,
              player.allowedExtensions.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }),
              compiledRoutePattern.value.numberOfCaptureGroups >= max(route.idGroup, max(route.lineGroup ?? 0, route.episodeGroup ?? 0)) else {
            throw ConfigurationError.invalidConfiguration
        }
        let sampleID = "ConfigValidationID"
        func hasInlineAuthentication(_ raw: String) -> Bool {
            let names: Set<String> = ["cookie", "token", "access_token", "authorization", "auth", "api_key"]
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
        if capabilities.contains(.lines) {
            guard route.lineGroup != nil || (catalog.format == "json" && catalog.jsonLineNumberPath != nil && catalog.jsonLineTitlePath != nil) else {
                throw ConfigurationError.unsupportedCapability
            }
        }
        if capabilities.contains(.quality) && !capabilities.contains(.lines) { throw ConfigurationError.invalidConfiguration }
        guard !capabilities.contains(.danmaku), !capabilities.contains(.jsPlayer),
              !capabilities.contains(.browse) else { throw ConfigurationError.unsupportedCapability }
    }

    var descriptor: SourceDescriptor { SourceDescriptor(id: id, name: name, version: version, capabilities: capabilities) }
    func matches(_ raw: String) -> Bool { (try? item(raw)) != nil }

    func item(_ raw: String) throws -> SourceItemRef {
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

    func parts(_ raw: String) throws -> (item: SourceItemRef, id: String, line: Int?, episode: Int?, episodeIdentity: String?) {
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
    func expanded(_ template: String, values: [String: String]) -> String {
        var safe = CharacterSet.alphanumerics
        safe.insert(charactersIn: "-._~")
        return values.reduce(template) { current, entry in
            let value = entry.value.addingPercentEncoding(withAllowedCharacters: safe) ?? ""
            return current.replacingOccurrences(of: "{\(entry.key)}", with: value)
        }
    }
    func requestURL(_ raw: String, media: Bool = false) throws -> URL {
        guard let c = URLComponents(string: raw), c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              c.port == nil, let host = c.host?.lowercased(),
              media ? (mediaHosts.contains(host) || anonymousExternalHTTPSMedia) : hosts.contains(host),
              let url = c.url else { throw ConfigurationError.invalidURL }
        return url
    }
    func validatedPlayerMediaURL(_ payload: [String: Any], id: String, line: Int, episode: Int) throws -> String {
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
            throw VideoGetError.notFountData
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
              player.allowedExtensions.contains(url.pathExtension.lowercased()) else { throw VideoGetError.notFountData }
        return url.absoluteString
    }
}
