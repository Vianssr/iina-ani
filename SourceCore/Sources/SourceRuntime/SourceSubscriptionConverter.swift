import SourceCore
import Foundation
import CryptoKit
import SwiftSoup

/// Converts css1 search metadata only. Playback, quality and authentication remain local adapter concerns.
public enum SourceSubscriptionConverter {
    public static let managedSourceIDs = Set(SourceSubscriptionRules.hosts.keys)

    private struct Candidate {
        let encoded: Data
        let signature: Data
    }
    private enum Rejection: Error, LocalizedError {
        case invalidURL, invalidSelector, unsupportedParser, unavailableBaseline
        var errorDescription: String? { detail }
        var detail: String {
            switch self {
            case .invalidURL: return String(localized: "搜尋網址不符合本機核准的 HTTPS 網域、路徑與公開查詢欄位，保留原設定。")
            case .invalidSelector: return String(localized: "搜尋選擇器無效或超過 1024 字元上限，保留原設定。")
            case .unsupportedParser: return String(localized: "尚未支援此搜尋解析格式；不匯入遠端播放解析器，保留原設定。")
            case .unavailableBaseline: return String(localized: "找不到此來源的本機搜尋與播放適配器，保留原設定。")
            }
        }
    }

    public static func convert(data: Data, baselines: [String: NativeSearchSource],
                               installed: [String: NativeSearchSource], names: [String: String]) throws -> SourceSubscriptionPlan {
        guard data.count <= 2 * 1024 * 1024 else { throw SourceSubscriptionError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceSubscriptionError.malformed
        }
        let items: [Any]
        // The current feed uses the root list. Its presence is authoritative, including
        // an empty or malformed value: never silently substitute a legacy nested list.
        if let current = root["mediaSources"] {
            guard let list = current as? [Any] else { throw SourceSubscriptionError.malformed }
            items = list
        } else {
            guard let exported = root["exportedMediaSourceDataList"] as? [String: Any],
                  let list = exported["mediaSources"] as? [Any] else { throw SourceSubscriptionError.malformed }
            items = list
        }
        guard items.count <= 128 else { throw SourceSubscriptionError.tooManyItems }
        // A malformed nonempty list is not an empty subscription that can be applied successfully.
        guard items.isEmpty || items.contains(where: { raw in
            let item = raw as? [String: Any]
            let arguments = item?["arguments"] as? [String: Any]
            return arguments?["searchConfig"] is [String: Any]
        }) else {
            throw SourceSubscriptionError.malformed
        }
        var entries: [SourceSubscriptionEntry] = []
        var candidates: [String: Candidate] = [:]
        var rejected: Set<String> = []
        var seen: Set<String> = []
        var owners: [String: Set<String>] = [:]
        for (id, baseline) in baselines {
            for host in baseline.hosts.map({ $0.lowercased() }) {
                let reserved = SourceSubscriptionRules.hosts.filter { $0.value.contains(host) }.map(\.key)
                for nativeID in reserved { owners[host, default: []].insert(nativeID) }
                // An installed custom source may claim its own host, never a native identity or alias.
                if let nativeHosts = SourceSubscriptionRules.hosts[id], !nativeHosts.contains(host) { continue }
                owners[host, default: []].insert(id)
            }
        }
        for (index, raw) in items.enumerated() {
            let item = raw as? [String: Any]
            let arguments = item?["arguments"] as? [String: Any]
            let name = displayName(arguments?["name"] as? String, index: index)
            let config = arguments?["searchConfig"] as? [String: Any]
            let rawURL = config?["searchUrl"] as? String
            let host = rawURL.flatMap { URLComponents(string: $0)?.host?.lowercased() }
            if let host, let matches = owners[host], matches.count > 1 { rejected.formUnion(matches) }
            let id = host.flatMap { host -> String? in
                guard let matches = owners[host], matches.count == 1 else { return nil }
                return matches.first
            }
            if let id { seen.insert(id) }
            if let host, SourceSubscriptionRules.excludedHosts.contains(host) {
                entries.append(.init(sourceID: "forest", name: name, status: String(localized: "已排除"), detail: String(localized: "影视森林已移除；訂閱不會恢復其搜尋或播放能力。")))
                continue
            }
            guard let id else {
                entries.append(.init(sourceID: nil, name: name, status: String(localized: "不支援"), detail: String(localized: "未知或無效網域，不能以名稱替換現有來源；未新增播放能力。")))
                continue
            }
            guard item?["factoryId"] as? String == "web-selector", let version = item?["version"] as? Int,
                  version == 2, !(item?["version"] is Bool), let config else {
                rejected.insert(id)
                entries.append(.init(sourceID: id, name: name, status: String(localized: "不支援"), detail: String(localized: "僅支援 web-selector 第 2 版；保留原設定。")))
                continue
            }
            do {
                guard let baseline = baselines[id] else { throw Rejection.unavailableBaseline }
                let converted = try convertSearch(config: config, baseline: baseline)
                let encoded = try canonical(converted)
                let candidate = Candidate(encoded: encoded, signature: encoded)
                if let previous = candidates[id], previous.signature != candidate.signature {
                    rejected.insert(id)
                } else {
                    candidates[id] = candidate
                }
                let effective = installed[id] ?? baseline
                let unchanged = try canonical(effective) == candidate.encoded
                let policy = id == "hanime1" ? String(localized: "1080p／720p 共用一個搜尋來源；保留本機品質選擇與播放適配器。") : String(localized: "僅更新公開搜尋欄位；保留本機分頁、播放解析與帳號邊界。")
                let fields: [(String, String?, String?)] = [
                    (String(localized: "搜尋網址"), effective.search.url, converted.search.url),
                    (String(localized: "結果選擇器"), effective.search.resultsSelector, converted.search.resultsSelector),
                    (String(localized: "標題選擇器"), effective.search.titleSelector, converted.search.titleSelector),
                    (String(localized: "連結選擇器"), effective.search.linkSelector, converted.search.linkSelector),
                    (String(localized: "封面選擇器"), effective.search.coverSelector, converted.search.coverSelector)
                ]
                let changes = fields.filter { $0.1 != $0.2 }.map { field in
                    field.0 + "：" + (field.1 ?? String(localized: "無")) + " → " + (field.2 ?? String(localized: "無"))
                }.joined(separator: "\n")
                let awaitingSubscription = installed[id] == nil
                let status = awaitingSubscription ? String(localized: "待啟用") : unchanged ? String(localized: "未變更") : String(localized: "待更新")
                let detail = changes.isEmpty ? policy : policy + "\n" + changes
                entries.append(.init(sourceID: id, name: name, status: status,
                    detail: awaitingSubscription ? String(localized: "舊規則僅為轉換基線；套用後才參與搜尋／尋源。\n") + detail : detail))
            } catch {
                rejected.insert(id)
                let detail = (error as? Rejection)?.detail ?? String(localized: "搜尋設定無法轉換，保留原設定。")
                entries.append(.init(sourceID: id, name: name, status: String(localized: "不支援"), detail: detail))
            }
        }
        // Any conflicting or invalid duplicate rejects the entire identity, regardless of item order.
        for index in entries.indices {
            guard let id = entries[index].sourceID, rejected.contains(id), candidates[id] != nil else { continue }
            let previous = entries[index]
            entries[index] = .init(sourceID: id, name: previous.name, status: String(localized: "衝突，已保留"),
                                   detail: String(localized: "同一來源的重複項目互相衝突或含不支援設定；全部拒絕，保留先前設定。"))
        }
        var overrides: [String: Data] = [:]
        for (id, candidate) in candidates where !rejected.contains(id) { overrides[id] = candidate.encoded }
        for id in Set(baselines.keys).subtracting(seen).sorted() {
            entries.append(.init(sourceID: id, name: names[id] ?? id, status: String(localized: "缺少，已保留"),
                                 detail: String(localized: "本次訂閱未提供此來源，保留已安裝的搜尋與播放設定。")))
        }
        let plan = SourceSubscriptionPlan(fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                     checkedAt: Date(), overrides: overrides, entries: entries)
        return SourceWebConfigurationConverter.addingStaticSources(items: items, to: plan, baselines: baselines)
    }

    /// Converts only public search metadata. The caller owns source identity and allowed hosts.
    public static func convertSearch(config: [String: Any], baseline: NativeSearchSource) throws -> NativeSearchSource {
        guard let rawURL = config["searchUrl"] as? String else { throw Rejection.invalidURL }
        let url = try safeURL(rawURL, hosts: baseline.hosts)
        var search = try JSONSerialization.jsonObject(with: canonical(baseline.search)) as! [String: Any]
        // Parse fields belong to the subscription; never present retained local selectors as converted ones.
        for key in ["resultsSelector", "titleSelector", "linkSelector", "coverSelector", "coverAttribute", "hrefAttribute",
                    "indexedNamesSelector", "indexedLinksSelector", "jsonResultsPath", "jsonTitlePath", "jsonIdentifierPath",
                    "jsonCoverPath", "jsonTotalPath", "jsonTitleAlternatives", "jsonIdentifierAlternatives", "resultURLTemplate", "resultBaseURL"] {
            search.removeValue(forKey: key)
        }
        let incoming = URLComponents(string: url)!
        let queryField = incoming.queryItems?.first { $0.value?.contains("{query}") == true }?.name
        search["url"] = url
        search["queryParameter"] = queryField ?? ""
        let rawBase = (config["rawBaseUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let rawBase {
            search["resultBaseURL"] = try safeBaseURL(rawBase, hosts: baseline.hosts)
        }
        let format = config["subjectFormatId"] as? String
        var resultTemplate: String? = nil
        switch format {
        case "a":
            guard let spec = config["selectorSubjectFormatA"] as? [String: Any],
                  let selector = spec["selectLists"] as? String else { throw Rejection.invalidSelector }
            try validateSelector(selector)
            search["format"] = "html"
            search["resultsSelector"] = normalizedSelector(selector)
            search["titleSelector"] = "self"
            search["hrefAttribute"] = "href"
        case "indexed":
            guard let spec = config["selectorSubjectFormatIndexed"] as? [String: Any],
                  let names = spec["selectNames"] as? String, let links = spec["selectLinks"] as? String else {
                throw Rejection.unsupportedParser
            }
            try validateSelector(names); try validateSelector(links)
            search["format"] = "html"
            search["hrefAttribute"] = "href"
            if normalizedSelector(names) == normalizedSelector(links) {
                search["resultsSelector"] = normalizedSelector(names)
                search["titleSelector"] = "self"
            } else {
                search["indexedNamesSelector"] = normalizedSelector(names)
                search["indexedLinksSelector"] = normalizedSelector(links)
            }
        case "json-path-indexed":
            guard let spec = config["selectorSubjectFormatJsonPathIndexed"] as? [String: Any],
                  let names = spec["selectNames"] as? String, let links = spec["selectLinks"] as? String else {
                throw Rejection.unsupportedParser
            }
            let titles: SearchJSONPath.Projection
            let identifiers: SearchJSONPath.Projection
            do { titles = try SearchJSONPath.compile(names); identifiers = try SearchJSONPath.compile(links) }
            catch { throw Rejection.unsupportedParser }
            guard titles.rowsPath == identifiers.rowsPath else { throw Rejection.unsupportedParser }
            search["format"] = "json"
            search["jsonResultsPath"] = titles.rowsPath
            search["jsonTitlePath"] = titles.valuePaths[0]
            search["jsonIdentifierPath"] = identifiers.valuePaths[0]
            if titles.valuePaths.count > 1 { search["jsonTitleAlternatives"] = Array(titles.valuePaths.dropFirst()) }
            if identifiers.valuePaths.count > 1 { search["jsonIdentifierAlternatives"] = Array(identifiers.valuePaths.dropFirst()) }
            // Relative JSON identifiers use the exporter's public base URL (or the search response URL).
            if let template = spec["linkTemplate"] as? String, !template.isEmpty {
                guard template.utf8.count <= 4096, template.contains("{value}"),
                      !template.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw Rejection.invalidURL }
                let sample = template.replacingOccurrences(of: "{value}", with: "ConfigValidationID")
                guard !sample.contains("{"), !sample.contains("}"),
                      let base = URL(string: rawBase ?? url.replacingOccurrences(of: "{query}", with: "test").replacingOccurrences(of: "{page}", with: "1")),
                      let target = URL(string: sample, relativeTo: base)?.absoluteURL else { throw Rejection.invalidURL }
                _ = try safeBaseURL(target.absoluteString, hosts: baseline.hosts)
                search["resultURLTemplate"] = template
            } else if rawBase == nil {
                // Older native exports may provide IDs with their separately reviewed detail template.
                resultTemplate = baseline.resultURLTemplate
            }
        default: throw Rejection.unsupportedParser
        }
        let transformed = try JSONDecoder().decode(SourceConfiguration.Search.self,
            from: JSONSerialization.data(withJSONObject: search, options: [.sortedKeys]))
        try SourceSearchExecutor.validate(transformed, allowedHosts: Set(baseline.hosts), resultURLTemplate: resultTemplate)
        return NativeSearchSource(hosts: baseline.hosts, search: transformed, resultURLTemplate: resultTemplate)
    }

    /// Creates a search-only baseline for a newly proposed generic source; no playback identity is inferred.
    public static func searchSource(config: [String: Any], hosts: [String], baseline: NativeSearchSource? = nil) throws -> NativeSearchSource {
        if let baseline {
            guard Set(baseline.hosts) == Set(hosts) else { throw Rejection.invalidURL }
            return try convertSearch(config: config, baseline: baseline)
        }
        guard let raw = config["searchUrl"] as? String else { throw Rejection.invalidURL }
        let pageSizeKeys: Set<String> = ["pagesize", "page_size", "perpage", "per_page", "limit", "rows"]
        let sizes = Set((URLComponents(string: raw)?.queryItems ?? []).compactMap { item -> Int? in
            guard pageSizeKeys.contains(item.name.lowercased()), let value = item.value,
                  value.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(value),
                  (1...100).contains(count) else { return nil }
            return count
        })
        guard sizes.count <= 1 else { throw Rejection.invalidURL }
        let dictionary: [String: Any] = ["url": raw, "format": "html", "queryParameter": "", "pageParameter": "", "rowsPerPage": sizes.first ?? 100]
        let search = try JSONDecoder().decode(SourceConfiguration.Search.self, from: JSONSerialization.data(withJSONObject: dictionary))
        return try convertSearch(config: config, baseline: NativeSearchSource(hosts: hosts, search: search))
    }

    private static func safeURL(_ raw: String, hosts: [String]) throws -> String {
        guard raw.utf8.count <= 4096, !raw.contains("\\"),
              !raw.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw Rejection.invalidURL }
        let result = raw.replacingOccurrences(of: "{keyword}", with: "{query}")
        guard result.components(separatedBy: "{query}").count == 2 else { throw Rejection.invalidURL }
        let sample = result.replacingOccurrences(of: "{query}", with: "ConfigValidationID").replacingOccurrences(of: "{page}", with: "1")
        guard !sample.contains("{"), !sample.contains("}"),
              let original = URLComponents(string: result), let checked = URLComponents(string: sample),
              original.scheme == checked.scheme, original.host == checked.host,
              original.user == nil, original.password == nil,
              !(original.queryItems ?? []).contains(where: { $0.name.contains("{") || $0.name.contains("}") }) else { throw Rejection.invalidURL }
        _ = try safeBaseURL(sample, hosts: hosts)
        return result
    }

    private static func safeBaseURL(_ raw: String, hosts: [String]) throws -> String {
        let credentialKeys: Set<String> = ["cookie", "token", "access_token", "authorization", "auth", "api_key", "apikey", "password", "passwd", "secret"]
        guard raw.utf8.count <= 4096, !raw.contains("\\"), !raw.contains("{"), !raw.contains("}"),
              !raw.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let host = components.host?.lowercased(), hosts.map({ $0.lowercased() }).contains(host),
              !components.path.split(separator: "/").contains(".."),
              let url = components.url, SourceSubscriptionTransport.allows(url) else { throw Rejection.invalidURL }
        var keys = Set<String>()
        for field in components.queryItems ?? [] {
            guard !credentialKeys.contains(field.name.lowercased()), keys.insert(field.name).inserted else { throw Rejection.invalidURL }
        }
        return raw
    }

    private static func validateSelector(_ value: String) throws {
        do { try SelectorPairing.validate(value) }
        catch { throw Rejection.invalidSelector }
    }
    private static func normalizedSelector(_ value: String) -> String {
        // Whitespace inside attribute strings and :contains() is meaningful CSS data.
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func displayName(_ value: String?, index: Int) -> String {
        guard let value, !value.isEmpty, value.utf8.count <= 160,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return String(localized: "訂閱項目 \(index + 1)")
        }
        return value
    }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
