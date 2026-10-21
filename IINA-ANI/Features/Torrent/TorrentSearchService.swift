import Foundation

struct TorrentSearchResult: Sendable {
    let title: String
    let sourceName: String
    let magnetURL: String?
    let torrentURL: URL?
}

struct TorrentSearchReport: Sendable {
    let results: [TorrentSearchResult]
    let failures: [String]
}

enum TorrentSearchError: Error, LocalizedError {
    case emptyKeyword, invalidSubscription, unsupportedSource, invalidSearchURL
    case httpStatus(Int), oversizedResponse, invalidRSS, forbiddenEntity
    case allSourcesFailed([String])

    var errorDescription: String? {
        switch self {
        case .emptyKeyword: return String(localized: "請輸入 BT 搜尋關鍵詞。")
        case .invalidSubscription: return String(localized: "BT 訂閱格式無效，應包含 exportedMediaSourceDataList.mediaSources。")
        case .unsupportedSource: return String(localized: "僅支援 rss 第 1 版來源。")
        case .invalidSearchURL: return String(localized: "BT 搜尋網址無效，僅接受 HTTP／HTTPS 與 {keyword} 查詢。")
        case .httpStatus(let status): return String(localized: "BT 搜尋伺服器回傳 HTTP \(status)。")
        case .oversizedResponse: return String(localized: "BT 搜尋回應超過大小限制。")
        case .invalidRSS: return String(localized: "BT 搜尋回應不是有效 RSS。")
        case .forbiddenEntity: return String(localized: "BT RSS 不允許 XML 實體宣告。")
        case .allSourcesFailed(let failures): return String(localized: "全部 BT 來源搜尋失敗：\n") + failures.joined(separator: "\n")
        }
    }
}

/// Searches public RSS metadata only; importing and starting P2P remain explicit UI actions.
actor TorrentSearchService {
    static let endpoint = URL(string: "https://sub.creamycake.org/v1/bt1.json")!
    static let subscriptionLimit = 2 * 1024 * 1024
    static let feedLimit = 4 * 1024 * 1024
    typealias Fetch = @Sendable (URL, Int) async throws -> (Data, URL)
    private let fetch: Fetch

    init(fetch: @escaping Fetch = TorrentSearchService.download) {
        self.fetch = fetch
    }

    func search(keyword: String) async throws -> TorrentSearchReport {
        try Task.checkCancellation()
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { throw TorrentSearchError.emptyKeyword }
        // Fetch on every search: no stale subscription or alternative search URL fallback.
        let (data, _) = try await fetch(Self.endpoint, Self.subscriptionLimit)
        try Task.checkCancellation()
        guard data.count <= Self.subscriptionLimit,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exported = root["exportedMediaSourceDataList"] as? [String: Any],
              let sources = exported["mediaSources"] as? [Any], sources.count <= 128 else {
            throw TorrentSearchError.invalidSubscription
        }
        var results: [TorrentSearchResult] = []
        var failures: [String] = []
        var succeeded = 0
        for (index, raw) in sources.enumerated() {
            try Task.checkCancellation()
            let object = raw as? [String: Any]
            let arguments = object?["arguments"] as? [String: Any]
            let name = (arguments?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = name.flatMap { $0.isEmpty ? nil : $0 } ?? "來源 \(index + 1)"
            do {
                guard let object,
                      let encoded = try? JSONSerialization.data(withJSONObject: object),
                      let source = try? JSONDecoder().decode(RSSSource.self, from: encoded),
                      source.factoryId == "rss", source.version == 1 else {
                    throw TorrentSearchError.unsupportedSource
                }
                let url = try Self.requestURL(template: source.arguments.searchConfig.searchUrl, keyword: keyword)
                let (feed, responseURL) = try await fetch(url, Self.feedLimit)
                try Task.checkCancellation()
                results += try Self.parseRSS(data: feed, sourceName: displayName, responseURL: responseURL)
                succeeded += 1
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                failures.append("\(displayName)：\(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()
        guard succeeded > 0 else {
            throw TorrentSearchError.allSourcesFailed(failures.isEmpty ? ["訂閱沒有可搜尋的 RSS 來源。"] : failures)
        }
        return TorrentSearchReport(results: results, failures: failures)
    }

    private struct RSSSource: Decodable {
        let factoryId: String
        let version: Int
        let arguments: Arguments
        struct Arguments: Decodable {
            let name: String
            let searchConfig: SearchConfig
        }
        struct SearchConfig: Decodable { let searchUrl: String }
    }

    static func requestURL(template: String, keyword: String) throws -> URL {
        guard template.contains("{keyword}"), var components = URLComponents(string: template),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, !host.contains("{keyword}"),
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw TorrentSearchError.invalidSearchURL
        }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved)! }
        let items = try (components.queryItems ?? []).map { item -> URLQueryItem in
            guard !item.name.contains("{keyword}") else { throw TorrentSearchError.invalidSearchURL }
            guard let value = item.value, value.contains("{keyword}") else { return item }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") || (trimmed.hasPrefix("{") && !trimmed.hasPrefix("{keyword}")) {
                // Replace JSON string values structurally, before URL encoding. Quotes, backslashes,
                // control characters and query delimiters in a keyword cannot escape the filter.
                guard let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) else {
                    throw TorrentSearchError.invalidSearchURL
                }
                let substituted = substituteJSON(object, keyword: keyword)
                let encoded = try JSONSerialization.data(withJSONObject: substituted, options: [.sortedKeys, .fragmentsAllowed])
                return URLQueryItem(name: item.name, value: String(decoding: encoded, as: UTF8.self))
            }
            return URLQueryItem(name: item.name, value: value.replacingOccurrences(of: "{keyword}", with: keyword))
        }
        components.percentEncodedQuery = items.isEmpty ? nil : items.map { item in
            encode(item.name) + (item.value.map { "=" + encode($0) } ?? "")
        }.joined(separator: "&")
        components.percentEncodedPath = components.percentEncodedPath
            .replacingOccurrences(of: "%7Bkeyword%7D", with: encode(keyword), options: .caseInsensitive)
            .replacingOccurrences(of: "{keyword}", with: encode(keyword))
        guard let url = components.url, safeHTTPURL(url) else { throw TorrentSearchError.invalidSearchURL }
        return url
    }

    private static func substituteJSON(_ value: Any, keyword: String) -> Any {
        if let string = value as? String { return string.replacingOccurrences(of: "{keyword}", with: keyword) }
        if let array = value as? [Any] { return array.map { substituteJSON($0, keyword: keyword) } }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues { substituteJSON($0, keyword: keyword) } }
        return value
    }

    static func parseRSS(data: Data, sourceName: String, responseURL: URL) throws -> [TorrentSearchResult] {
        try Task.checkCancellation()
        guard data.count <= feedLimit else { throw TorrentSearchError.oversizedResponse }
        guard safeHTTPURL(responseURL), !data.isEmpty else { throw TorrentSearchError.invalidRSS }
        // XMLParser can suppress declaration callbacks when external resolution is disabled.
        // Reject DTDs before parsing, including the XML UTF-16/32 byte orders.
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            if let marker = "<!DOCTYPE".data(using: encoding), data.range(of: marker) != nil {
                throw TorrentSearchError.forbiddenEntity
            }
        }
        let delegate = TorrentRSSParser(sourceName: sourceName, baseURL: responseURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        let parsed = parser.parse()
        try Task.checkCancellation()
        if let error = delegate.failure { throw error }
        guard parsed, delegate.isRSS else { throw TorrentSearchError.invalidRSS }
        return delegate.results
    }

    fileprivate static func safeHTTPURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
        !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }

    static func download(_ url: URL, limit: Int) async throws -> (Data, URL) {
        try Task.checkCancellation()
        guard safeHTTPURL(url) else { throw TorrentSearchError.invalidSearchURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.setValue(url == endpoint ? "application/json" : "application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        let policy = TorrentSearchRedirectPolicy(subscription: url == endpoint)
        let (bytes, response) = try await session.bytes(for: request, delegate: policy)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw TorrentSearchError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let finalURL = response.url, safeHTTPURL(finalURL),
              url != endpoint || (finalURL.scheme == "https" && finalURL.host == endpoint.host) else {
            throw TorrentSearchError.invalidSearchURL
        }
        guard response.expectedContentLength <= limit else { throw TorrentSearchError.oversizedResponse }
        var data = Data()
        data.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 64_000)
        for try await byte in bytes {
            guard data.count < limit else { throw TorrentSearchError.oversizedResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, finalURL)
    }
}

private final class TorrentSearchRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let subscription: Bool
    init(subscription: Bool) { self.subscription = subscription }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, TorrentSearchService.safeHTTPURL(url),
              !subscription || (url.scheme == "https" && url.host == TorrentSearchService.endpoint.host) else {
            completionHandler(nil)
            return
        }
        var anonymous = request
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie")
        anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        anonymous.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        anonymous.httpShouldHandleCookies = false
        completionHandler(anonymous)
    }
}

private final class TorrentRSSParser: NSObject, XMLParserDelegate {
    let sourceName: String
    let baseURL: URL
    var results: [TorrentSearchResult] = []
    var failure: Error?
    var isRSS = false
    private var depth = 0
    private var itemDepth: Int?
    private var field: (name: String, depth: Int, text: String)?
    private var title = ""
    private var magnet: String?
    private var torrent: URL?
    private var seen: Set<String> = []

    init(sourceName: String, baseURL: URL) {
        self.sourceName = sourceName
        self.baseURL = baseURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        if Task.isCancelled { failure = CancellationError(); parser.abortParsing(); return }
        depth += 1
        let name = elementName.lowercased()
        if depth == 1 { isRSS = name == "rss" || name == "rdf" }
        guard isRSS else { return }
        if name == "item", itemDepth == nil {
            itemDepth = depth
            title = ""
            magnet = nil
            torrent = nil
            return
        }
        guard let itemDepth, depth == itemDepth + 1 else { return }
        if name == "enclosure", let raw = attributes["url"] {
            acceptLink(raw, enclosure: true, type: attributes["type"])
        }
        if name == "link", let href = attributes["href"] {
            acceptLink(href, enclosure: attributes["rel"]?.lowercased() == "enclosure", type: attributes["type"])
        }
        if ["title", "link", "magnet", "magneturi", "magneturl"].contains(name) ||
            (name == "infohash" && ((namespaceURI ?? "").lowercased().contains("nyaa") || (qName ?? "").lowercased().hasPrefix("nyaa:"))) {
            field = (name, depth, "")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { field?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { field?.text += String(decoding: CDATABlock, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer { depth -= 1 }
        if let field, field.depth == depth {
            let value = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field.name {
            case "title": title = value
            case "infohash":
                let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
                if value.count == 40, value.unicodeScalars.allSatisfy({ hex.contains($0) }), magnet == nil {
                    magnet = "magnet:?xt=urn:btih:" + value.lowercased()
                }
            default: acceptLink(value)
            }
            self.field = nil
        }
        if elementName.lowercased() == "item", itemDepth == depth {
            if !title.isEmpty, magnet != nil || torrent != nil {
                let key = magnet ?? torrent!.absoluteString
                if seen.insert(key).inserted {
                    results.append(TorrentSearchResult(title: title, sourceName: sourceName, magnetURL: magnet, torrentURL: torrent))
                }
            }
            itemDepth = nil
        }
    }

    private func httpURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
              TorrentSearchService.safeHTTPURL(url) else { return nil }
        return url
    }

    private func isTorrent(_ url: URL, type: String?) -> Bool {
        let mime = type?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        return url.pathExtension.lowercased() == "torrent" || mime == "application/x-bittorrent"
    }

    private func acceptLink(_ raw: String, enclosure: Bool = false, type: String? = nil) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URLComponents(string: value), url.scheme?.lowercased() == "magnet",
           url.queryItems?.contains(where: { item in
               guard item.name.lowercased() == "xt", let topic = item.value?.lowercased() else { return false }
               let hash = String(topic.dropFirst("urn:btih:".count))
               if topic.hasPrefix("urn:btih:") {
                   let characters = CharacterSet(charactersIn: hash.count == 40 ? "0123456789abcdef" : "abcdefghijklmnopqrstuvwxyz234567")
                   return [32, 40].contains(hash.count) && hash.unicodeScalars.allSatisfy { characters.contains($0) }
               }
               if topic.hasPrefix("urn:btmh:1220") {
                   let digest = topic.dropFirst("urn:btmh:1220".count)
                   return digest.count == 64 && digest.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
               }
               return false
           }) == true {
            magnet = magnet ?? value
        } else if let url = httpURL(value), isTorrent(url, type: enclosure ? type : nil) {
            torrent = torrent ?? url
        }
    }

    private func rejectEntity(_ parser: XMLParser) { failure = TorrentSearchError.forbiddenEntity; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { rejectEntity(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { rejectEntity(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { rejectEntity(parser); return nil }
}
