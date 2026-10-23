import Foundation
import Alamofire
import CryptoSwift

struct YouTubeVideo: Sendable, Hashable {
    let id: String
    let title: String
    let thumbnailURL: String
    let channel: String
    let durationText: String
    let viewCountText: String

    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}

/// Contains only the bootstrap belonging to this feed, not endpoints supplied by cards.
struct YouTubeContinuation: Sendable {
    fileprivate let token: String
    fileprivate let bootstrap: YouTubeBootstrap
    fileprivate let targetID: String?
    fileprivate let credentialFingerprint: String?
}

struct YouTubeBrowsePage: Sendable {
    let videos: [YouTubeVideo]
    let continuation: YouTubeContinuation?
    let message: String?
}

enum YouTubeBrowseError: Error, LocalizedError {
    case malformedPage, unavailable, consentRequired, challengeRequired, emptyQuery, accountChanged

    var errorDescription: String? {
        switch self {
        case .malformedPage: return String(localized: "YouTube returned an unsupported or malformed page.")
        case .unavailable: return String(localized: "YouTube could not be reached or rejected this request. Try again later.")
        case .consentRequired: return String(localized: "YouTube requires consent. Open YouTube in your browser, complete consent, then import updated cookies.")
        case .challengeRequired: return String(localized: "YouTube requires a browser verification or has limited requests. Open YouTube in your browser and try again later.")
        case .emptyQuery: return String(localized: "Enter a YouTube search query.")
        case .accountChanged: return String(localized: "The YouTube account changed. Reload the page before loading more.")
        }
    }
}

fileprivate struct YouTubeBootstrap: Sendable {
    enum Route: String, Sendable { case browse, search }
    let route: Route
    let context: Data
    let apiKey: String
    let clientName: String
    let clientVersion: String
    let sessionIndex: String?
    let delegatedSessionID: String?
    let accountID: UUID?
}

actor YouTubeBrowseService {
    static let shared = YouTubeBrowseService()
    private static let origin = "https://www.youtube.com"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    func home() async throws -> YouTubeBrowsePage {
        try await initialPage(url: URL(string: Self.origin + "/")!, route: .browse)
    }

    func search(_ query: String) async throws -> YouTubeBrowsePage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw YouTubeBrowseError.emptyQuery }
        var url = URLComponents(string: Self.origin + "/results")!
        url.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return try await initialPage(url: url.url!, route: .search)
    }

    func more(_ continuation: YouTubeContinuation) async throws -> YouTubeBrowsePage {
        let bootstrap = continuation.bootstrap
        guard AccountHTTP.context?.accountID == bootstrap.accountID,
              Self.credentialFingerprint() == continuation.credentialFingerprint else { throw YouTubeBrowseError.accountChanged }
        var url = URLComponents(string: Self.origin + "/youtubei/v1/" + bootstrap.route.rawValue)!
        url.queryItems = [URLQueryItem(name: "key", value: bootstrap.apiKey), URLQueryItem(name: "prettyPrint", value: "false")]
        var request = baseRequest(url.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin, forHTTPHeaderField: "X-Origin")
        request.setValue(bootstrap.clientName, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(bootstrap.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        if let index = bootstrap.sessionIndex { request.setValue(index, forHTTPHeaderField: "X-Goog-AuthUser") }
        if let pageID = bootstrap.delegatedSessionID { request.setValue(pageID, forHTTPHeaderField: "X-Goog-PageId") }
        let context = try JSONSerialization.jsonObject(with: bootstrap.context)
        if let client = (context as? [String: Any])?["client"] as? [String: Any],
           let visitor = client["visitorData"] as? String {
            request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context": context, "continuation": continuation.token])
        // Always use the CURRENT jar: cookies may have rotated since the bootstrap.
        if let cookie = Self.signingCookie() {
            let timestamp = String(Int(Date().timeIntervalSince1970))
            let digest = "\(timestamp) \(cookie.value) \(Self.origin)".sha1()
            request.setValue("SAPISIDHASH \(timestamp)_\(digest)", forHTTPHeaderField: "Authorization")
            if bootstrap.sessionIndex == nil { request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser") }
        }
        let data = try await fetch(request)
        return try YouTubePageParser.continuation(data: data, previous: continuation)
    }

    func accountName() async throws -> String {
        let data = try await fetch(baseRequest(URL(string: Self.origin + "/")!))
        do {
            let document = try YouTubePageParser.document(data: data)
            guard let loggedIn = YouTubePageParser.loggedIn(config: document.config, initialData: document.initialData) else {
                throw SiteAccountError.validationFailed
            }
            guard loggedIn else { throw SiteAccountError.expired }
            // The home bootstrap does not consistently expose the account display name.
            return "YouTube"
        } catch let error as SiteAccountError {
            throw error
        } catch let error as YouTubeBrowseError {
            if case .malformedPage = error { throw SiteAccountError.validationFailed }
            throw error
        }
    }

    private func initialPage(url: URL, route: YouTubeBootstrap.Route) async throws -> YouTubeBrowsePage {
        let data = try await fetch(baseRequest(url))
        return try YouTubePageParser.initial(data: data, isSearch: route == .search, accountID: AccountHTTP.context?.accountID,
                                             credentialFingerprint: Self.credentialFingerprint())
    }

    private static func signingCookie() -> HTTPCookie? {
        let cookies = AccountHTTP.cookies(for: URL(string: origin + "/")!)
        let now = Date()
        for name in ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"] {
            if let cookie = cookies.first(where: { $0.name == name && $0.isSecure && ($0.expiresDate.map { $0 > now } ?? true) }) { return cookie }
        }
        return nil
    }

    private static func credentialFingerprint() -> String? {
        signingCookie().map { ($0.name + "\n" + $0.value).sha256() }
    }

    private func baseRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.origin + "/", forHTTPHeaderField: "Referer")
        return request
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        guard AccountHTTP.context == nil || AccountHTTP.context?.sourceID == "youtube",
              request.url?.scheme == "https", request.url?.host == "www.youtube.com",
              request.url?.port == nil, request.url?.user == nil, request.url?.password == nil else {
            throw YouTubeBrowseError.unavailable
        }
        // Do not follow even a same-origin redirect: signed headers must never be
        // forwarded by URLSession to consent.google.com or another origin.
        let response = await AccountHTTP.request(request)
            .redirect(using: Redirector(behavior: .doNotFollow))
            .serializingData().response
        try Task.checkCancellation()
        guard let http = response.response else { throw YouTubeBrowseError.unavailable }
        if (300..<400).contains(http.statusCode) {
            let destination = http.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: request.url)?.absoluteURL }
            if destination?.host == "consent.youtube.com" || destination?.host == "consent.google.com" {
                throw YouTubeBrowseError.consentRequired
            }
            throw YouTubeBrowseError.challengeRequired
        }
        if http.statusCode == 429 { throw YouTubeBrowseError.challengeRequired }
        if http.statusCode == 401 || http.statusCode == 403 {
            if AccountHTTP.context?.accountID != nil { throw SiteAccountError.expired }
            throw YouTubeBrowseError.challengeRequired
        }
        guard (200..<300).contains(http.statusCode), response.error == nil,
              let data = response.data, !data.isEmpty, data.count <= 20_000_000 else { throw YouTubeBrowseError.unavailable }
        return data
    }
}

/// Explicit feed paths keep sidebar videos, shelf recommendations and their tokens
/// out of the native result set. These seams also accept deterministic fixtures.
enum YouTubePageParser {
    struct Document {
        let initialData: [String: Any]
        let config: [String: Any]
    }

    static func document(data: Data) throws -> Document {
        guard data.count <= 20_000_000, let html = String(data: data, encoding: .utf8) else { throw YouTubeBrowseError.malformedPage }
        let initialPattern = #"(?:\b(?:var\s+)?ytInitialData\s*=\s*|window\s*\[\s*["']ytInitialData["']\s*\]\s*=\s*)\{"#
        guard let initialData = try jsonObjects(in: html, pattern: initialPattern).first else {
            if html.contains("consent.youtube.com") || html.contains("consent.google.com") { throw YouTubeBrowseError.consentRequired }
            if html.contains("recaptcha") || html.contains("/sorry/") || html.contains("unusual traffic") { throw YouTubeBrowseError.challengeRequired }
            throw YouTubeBrowseError.malformedPage
        }
        let configurations = try jsonObjects(in: html, pattern: #"\bytcfg\.set\(\s*\{"#, strict: false)
        var config: [String: Any] = [:]
        for configuration in configurations { config.merge(configuration) { _, new in new } }
        return Document(initialData: initialData, config: config)
    }

    static func loggedIn(config: [String: Any], initialData: [String: Any]) -> Bool? {
        if let value = config["LOGGED_IN"] as? Bool { return value }
        if let loggedOut = object(initialData, "responseContext", "mainAppWebResponseContext")?["loggedOut"] as? Bool { return !loggedOut }
        return nil
    }

    static func initial(data: Data, isSearch: Bool, accountID: UUID? = nil, credentialFingerprint: String? = nil) throws -> YouTubeBrowsePage {
        let document = try document(data: data)
        if accountID != nil, loggedIn(config: document.config, initialData: document.initialData) == false { throw SiteAccountError.expired }
        let bootstrap = try bootstrap(config: document.config, isSearch: isSearch, accountID: accountID)
        let root = try feedRoot(document.initialData, isSearch: isSearch)
        return try page(root: root, bootstrap: bootstrap, targetID: root["targetId"] as? String, credentialFingerprint: credentialFingerprint)
    }

    static func continuation(data: Data, previous: YouTubeContinuation) throws -> YouTubeBrowsePage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw YouTubeBrowseError.malformedPage }
        if let error = json["error"] as? [String: Any] {
            if let code = error["code"] as? Int, code == 401 || code == 403 { throw SiteAccountError.expired }
            throw YouTubeBrowseError.unavailable
        }
        if previous.bootstrap.accountID != nil, loggedIn(config: [:], initialData: json) == false { throw SiteAccountError.expired }
        var roots: [[String: Any]] = []
        for key in ["onResponseReceivedCommands", "onResponseReceivedActions", "onResponseReceivedEndpoints"] {
            for action in json[key] as? [[String: Any]] ?? [] {
                for command in ["appendContinuationItemsAction", "reloadContinuationItemsCommand"] {
                    guard let root = action[command] as? [String: Any], let items = root["continuationItems"] as? [[String: Any]] else { continue }
                    let target = root["targetId"] as? String
                    guard target == nil || previous.targetID == nil || target == previous.targetID else { continue }
                    roots.append(["contents": items])
                }
            }
        }
        if roots.isEmpty, let contents = json["continuationContents"] as? [String: Any] {
            let names = previous.bootstrap.route == .search ? ["sectionListContinuation", "itemSectionContinuation"] : ["richGridContinuation", "gridContinuation"]
            for name in names {
                if let root = contents[name] as? [String: Any] { roots.append(root) }
            }
        }
        guard !roots.isEmpty else { throw YouTubeBrowseError.malformedPage }
        var items: [[String: Any]] = []
        for root in roots { items += root["contents"] as? [[String: Any]] ?? root["items"] as? [[String: Any]] ?? [] }
        return try page(root: ["contents": items], bootstrap: previous.bootstrap, targetID: previous.targetID,
                        credentialFingerprint: previous.credentialFingerprint)
    }

    private static func bootstrap(config: [String: Any], isSearch: Bool, accountID: UUID?) throws -> YouTubeBootstrap {
        guard let context = config["INNERTUBE_CONTEXT"] as? [String: Any],
              let client = context["client"] as? [String: Any],
              let version = client["clientVersion"] as? String, !version.isEmpty,
              let apiKey = config["INNERTUBE_API_KEY"] as? String, !apiKey.isEmpty else { throw YouTubeBrowseError.malformedPage }
        let clientName = string(config["INNERTUBE_CONTEXT_CLIENT_NAME"]) ?? "1"
        return YouTubeBootstrap(route: isSearch ? .search : .browse, context: try JSONSerialization.data(withJSONObject: context),
                                apiKey: apiKey, clientName: clientName, clientVersion: version,
                                sessionIndex: string(config["SESSION_INDEX"]), delegatedSessionID: config["DELEGATED_SESSION_ID"] as? String,
                                accountID: accountID)
    }

    private static func feedRoot(_ json: [String: Any], isSearch: Bool) throws -> [String: Any] {
        guard let contents = json["contents"] as? [String: Any] else { throw YouTubeBrowseError.malformedPage }
        if isSearch {
            guard let primary = object(contents, "twoColumnSearchResultsRenderer", "primaryContents"),
                  let root = primary["sectionListRenderer"] as? [String: Any] else { throw YouTubeBrowseError.malformedPage }
            return root
        }
        guard let browse = contents["twoColumnBrowseResultsRenderer"] as? [String: Any],
              let tabs = browse["tabs"] as? [[String: Any]] else { throw YouTubeBrowseError.malformedPage }
        let renderers = tabs.compactMap { $0["tabRenderer"] as? [String: Any] }
        guard let tab = renderers.first(where: { $0["selected"] as? Bool == true }) ?? (renderers.count == 1 ? renderers.first : nil),
              let content = tab["content"] as? [String: Any] else { throw YouTubeBrowseError.malformedPage }
        if let root = content["richGridRenderer"] as? [String: Any] { return root }
        if let root = content["sectionListRenderer"] as? [String: Any] { return root }
        throw YouTubeBrowseError.malformedPage
    }

    private static func page(root: [String: Any], bootstrap: YouTubeBootstrap, targetID: String?, credentialFingerprint: String?) throws -> YouTubeBrowsePage {
        guard let items = root["contents"] as? [[String: Any]] ?? root["items"] as? [[String: Any]] else { throw YouTubeBrowseError.malformedPage }
        var videos: [YouTubeVideo] = []
        var seen: Set<String> = []
        var token: String?
        var messages: [String] = []
        func visit(_ item: [String: Any], depth: Int) {
            guard depth < 8 else { return }
            if let video = video(item), seen.insert(video.id).inserted { videos.append(video); return }
            if let continuation = item["continuationItemRenderer"] as? [String: Any] {
                let endpoint = continuation["continuationEndpoint"] as? [String: Any]
                    ?? object(continuation, "button", "buttonRenderer", "command")
                if let command = endpoint?["continuationCommand"] as? [String: Any], let next = command["token"] as? String, !next.isEmpty {
                    let request = command["request"] as? String
                    let expected = bootstrap.route == .search ? "CONTINUATION_REQUEST_TYPE_SEARCH" : "CONTINUATION_REQUEST_TYPE_BROWSE"
                    if request == nil || request == expected { token = next }
                }
                return
            }
            if let rich = object(item, "richItemRenderer", "content") { visit(rich, depth: depth + 1); return }
            for key in ["itemSectionRenderer", "sectionListRenderer", "richGridRenderer", "gridRenderer"] {
                if let section = item[key] as? [String: Any] {
                    for child in section["contents"] as? [[String: Any]] ?? section["items"] as? [[String: Any]] ?? [] { visit(child, depth: depth + 1) }
                    return
                }
            }
            if let section = object(item, "richSectionRenderer", "content"), section["feedNudgeRenderer"] != nil || section["messageRenderer"] != nil {
                visit(section, depth: depth + 1)
            }
            for key in ["messageRenderer", "feedNudgeRenderer", "backgroundPromoRenderer"] {
                if let message = item[key] as? [String: Any] {
                    let value = [text(message["title"]), text(message["text"]), text(message["subtitle"]), text(message["bodyText"])].filter { !$0.isEmpty }.joined(separator: "\n")
                    if !value.isEmpty { messages.append(value) }
                }
            }
        }
        for item in items { visit(item, depth: 0) }
        let continuation = token.map { YouTubeContinuation(token: $0, bootstrap: bootstrap, targetID: targetID, credentialFingerprint: credentialFingerprint) }
        let fallback = bootstrap.route == .search ? String(localized: "No YouTube videos were found for this search.")
            : String(localized: "YouTube has no home recommendations for this session. Search for videos or import signed-in browser cookies.")
        return YouTubeBrowsePage(videos: videos, continuation: continuation,
                                message: messages.isEmpty ? (videos.isEmpty ? fallback : nil) : messages.joined(separator: "\n"))
    }

    static func video(_ item: [String: Any]) -> YouTubeVideo? {
        // Ads wrap cards in adSlotRenderer/inFeedAdLayoutRenderer; never descend into them.
        guard item["adSlotRenderer"] == nil, item["inFeedAdLayoutRenderer"] == nil,
              item["promotedVideoRenderer"] == nil, item["adPlacements"] == nil else { return nil }
        if let renderer = item["videoRenderer"] as? [String: Any] ?? item["videoWithContextRenderer"] as? [String: Any] {
            guard renderer["adInfo"] == nil, renderer["promotedMetadata"] == nil,
                  let id = renderer["videoId"] as? String, validVideoID(id) else { return nil }
            let title = text(renderer["title"] ?? renderer["headline"])
            guard !title.isEmpty else { return nil }
            let sources = object(renderer, "thumbnail")?["thumbnails"] as? [[String: Any]] ?? []
            let thumbnail = sources.reversed().compactMap { thumbnailURL($0["url"] as? String) }.first ?? ""
            let duration = text(renderer["lengthText"]).isEmpty ? overlayDuration(renderer["thumbnailOverlays"] as? [[String: Any]] ?? []) : text(renderer["lengthText"])
            return YouTubeVideo(id: id, title: title, thumbnailURL: thumbnail,
                                channel: text(renderer["ownerText"] ?? renderer["shortBylineText"] ?? renderer["longBylineText"]),
                                durationText: duration, viewCountText: text(renderer["viewCountText"] ?? renderer["shortViewCountText"]))
        }
        guard let renderer = item["lockupViewModel"] as? [String: Any],
              renderer["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO",
              let id = renderer["contentId"] as? String, validVideoID(id),
              let metadata = object(renderer, "metadata", "lockupMetadataViewModel") else { return nil }
        let title = text(metadata["title"])
        guard !title.isEmpty else { return nil }
        let thumbnail = object(renderer, "contentImage", "thumbnailViewModel") ?? [:]
        let sources = object(thumbnail, "image")?["sources"] as? [[String: Any]] ?? []
        let rows = object(metadata, "metadata", "contentMetadataViewModel")?["metadataRows"] as? [[String: Any]] ?? []
        let parts = rows.map { row in (row["metadataParts"] as? [[String: Any]] ?? []).map { text($0["text"]) }.filter { !$0.isEmpty } }
        // Current compact cards put channel, optional collaborators, views and age
        // in one row. Older cards put channel and statistics in separate rows.
        let firstRow = parts.first ?? []
        let views = parts.count > 1 ? parts.dropFirst().first?.first ?? ""
            : (firstRow.count >= 3 ? firstRow[firstRow.count - 2] : "")
        return YouTubeVideo(id: id, title: title, thumbnailURL: sources.reversed().compactMap { thumbnailURL($0["url"] as? String) }.first ?? "",
                            channel: firstRow.first ?? "", durationText: overlayDuration(thumbnail["overlays"] as? [[String: Any]] ?? []),
                            viewCountText: views)
    }

    static func validVideoID(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func thumbnailURL(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, let host = url.host?.lowercased(),
              ["ytimg.com", "ggpht.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url.absoluteString
    }

    private static func overlayDuration(_ overlays: [[String: Any]]) -> String {
        for overlay in overlays {
            if let status = overlay["thumbnailOverlayTimeStatusRenderer"] as? [String: Any] { return text(status["text"]) }
            for key in ["thumbnailOverlayBadgeViewModel", "thumbnailBottomOverlayViewModel"] {
                guard let model = overlay[key] as? [String: Any] else { continue }
                for badge in model["thumbnailBadges"] as? [[String: Any]] ?? model["badges"] as? [[String: Any]] ?? [] {
                    let label = text((badge["thumbnailBadgeViewModel"] as? [String: Any] ?? badge)["text"])
                    if label.range(of: #"^\d{1,3}(?:,\d{3})*:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil { return label }
                }
            }
        }
        return ""
    }

    private static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        guard let value = value as? [String: Any] else { return "" }
        if let simple = value["simpleText"] as? String ?? value["content"] as? String { return simple }
        return (value["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func object(_ value: [String: Any], _ keys: String...) -> [String: Any]? {
        var current = value
        for key in keys {
            guard let next = current[key] as? [String: Any] else { return nil }
            current = next
        }
        return current
    }

    /// JSON only: balanced delimiters honor escaped quotes/backslashes. No JavaScript
    /// execution, expression evaluation, or regular expression pretending to parse JSON.
    private static func jsonObjects(in html: String, pattern: String, strict: Bool = true) throws -> [[String: Any]] {
        let expression = try NSRegularExpression(pattern: pattern)
        let matches = expression.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var results: [[String: Any]] = []
        candidate: for match in matches {
            guard let range = Range(match.range, in: html), let opener = html[range].lastIndex(of: "{") else { continue }
            var stack: [Character] = []
            var quoted = false
            var escaped = false
            var end: String.Index?
            var cursor = opener
            while cursor < html.endIndex {
                let character = html[cursor]
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                } else if character == "\"" { quoted = true }
                else if character == "{" || character == "[" { stack.append(character) }
                else if character == "}" || character == "]" {
                    guard let opening = stack.popLast(), (opening == "{" && character == "}") || (opening == "[" && character == "]") else {
                        if strict { throw YouTubeBrowseError.malformedPage }
                        continue candidate
                    }
                    if stack.isEmpty { end = html.index(after: cursor); break }
                }
                cursor = html.index(after: cursor)
            }
            guard let end, let json = try? JSONSerialization.jsonObject(with: Data(html[opener..<end].utf8)) as? [String: Any] else {
                // YouTube also calls ytcfg.set with JavaScript expressions and
                // single-quoted telemetry values. Only consume JSON bootstraps.
                if strict { throw YouTubeBrowseError.malformedPage }
                continue
            }
            results.append(json)
        }
        return results
    }
}
