import Foundation
import CryptoKit
import SwiftSoup

struct SourceSubscriptionPlan: Codable, Sendable {
    let fingerprint: String
    let checkedAt: Date
    let overrides: [String: Data]
    let entries: [SourceSubscriptionEntry]
}

struct SourceSubscriptionEntry: Codable, Sendable {
    let sourceID: String?
    let name: String
    let status: String
    let detail: String
}

enum SourceSubscriptionError: Error, LocalizedError, Equatable {
    case tooLarge, malformed, tooManyItems

    var errorDescription: String? {
        switch self {
        case .tooLarge: return String(localized: "來源訂閱超過 2 MiB 上限。")
        case .malformed: return String(localized: "來源訂閱格式無效，應包含 exportedMediaSourceDataList.mediaSources。")
        case .tooManyItems: return String(localized: "來源訂閱超過 128 個項目上限。")
        }
    }
}

/// Converts css1 search metadata only. Playback, quality and authentication remain local adapter concerns.
enum SourceSubscriptionConverter {
    static let managedSourceIDs: Set<String> = [
        "xifan", "girigiri", "didahd", "jibi", "eacg", "senfun", "fengche", "kanba",
        "haixing", "yinghua", "dilidili", "youknow", "fqdm", "hanime1", "wedm", "rebo"
    ]

    // Identity is audited host ownership, never the remote display name or a suffix match.
    private static let aliases: [String: [String]] = [
        "xifan": ["dm1.xfdm.pro"],
        "girigiri": ["ani.girigirilove.com"],
        "didahd": ["www.didahd.pro", "didahd.pro", "www.didahd.xyz", "didahd.xyz"],
        "jibi": ["www.jibi.cc", "jibi.cc"],
        "eacg": ["www.eacg1.com", "eacg1.com"],
        "senfun": ["senfun.in"],
        "fengche": ["www.dongmandaquan.vip", "dongmandaquan.vip"],
        "kanba": ["11kt.net", "www.11kt.net", "qkan8.com", "www.qkan8.com"],
        "haixing": ["www.haixingdmx.com", "haixingdmx.com"],
        "yinghua": ["www.yinghuabb.com", "yinghuabb.com", "www.yinghuaaa.com", "yinghuaaa.com", "www.yinghua2.com", "yinghua2.com"],
        "dilidili": ["dilidili.io", "www.dilidili.io"],
        "youknow": ["www.youknow.tv", "youknow.tv"],
        "fqdm": ["www.fqdm.cc", "fqdm.cc"],
        "hanime1": ["hanime1.me", "www.hanime1.me"],
        "wedm": ["www.vdm5.com", "vdm5.com"],
        "rebo": ["www.rebozj.cc", "rebozj.cc", "www.rebozj.pro", "rebozj.pro"]
    ]
    private static let excludedHosts: Set<String> = ["www.hc34567.com", "hc34567.com"]
    private static let indexedSelectors: [String: (names: String, links: String)] = [
        "xifan": ("body > .box-width .search-box .thumb-content > .thumb-txt", "body > .box-width .search-box .thumb-menu > a"),
        "girigiri": ("body > .box-width .vod-detail .detail-info .slide-info-title", "body > .box-width .vod-detail .detail-info > a"),
        "hanime1": ("#home-rows-wrapper > div.content-padding-new > div > div > div > div > a > div.title", "#home-rows-wrapper > div.content-padding-new > div > div > div > div > a")
    ]
    private struct Candidate {
        let encoded: Data
        let signature: Data
    }
    private enum Rejection: Error {
        case invalidURL, invalidSelector, unsupportedParser, unavailableBaseline
        var detail: String {
            switch self {
            case .invalidURL: return String(localized: "搜尋網址不符合本機核准的 HTTPS 網域、路徑與公開查詢欄位，保留原設定。")
            case .invalidSelector: return String(localized: "搜尋選擇器無效或超過 1024 字元上限，保留原設定。")
            case .unsupportedParser: return String(localized: "尚未支援此搜尋解析格式；不匯入遠端播放解析器，保留原設定。")
            case .unavailableBaseline: return String(localized: "找不到此來源的本機搜尋與播放適配器，保留原設定。")
            }
        }
    }

    static func convert(data: Data, registry: SourceRegistry) throws -> SourceSubscriptionPlan {
        guard data.count <= 2 * 1024 * 1024 else { throw SourceSubscriptionError.tooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exported = root["exportedMediaSourceDataList"] as? [String: Any],
              let items = exported["mediaSources"] as? [Any] else { throw SourceSubscriptionError.malformed }
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
        for (index, raw) in items.enumerated() {
            let item = raw as? [String: Any]
            let arguments = item?["arguments"] as? [String: Any]
            let name = displayName(arguments?["name"] as? String, index: index)
            let config = arguments?["searchConfig"] as? [String: Any]
            let rawURL = config?["searchUrl"] as? String
            let host = rawURL.flatMap { URLComponents(string: $0)?.host?.lowercased() }
            let id = host.flatMap { host in aliases.first(where: { $0.value.contains(host) })?.key }
            if let id { seen.insert(id) }
            if let host, excludedHosts.contains(host) {
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
                guard let baseline = registry.builtinSearch(for: id) else { throw Rejection.unavailableBaseline }
                let candidate = try convert(config: config, id: id, baseline: baseline)
                if let previous = candidates[id], previous.signature != candidate.signature {
                    rejected.insert(id)
                } else {
                    candidates[id] = candidate
                }
                let effective = registry.subscriptionSearch(for: id) ?? baseline
                let unchanged = try canonical(effective) == candidate.encoded
                let converted = try JSONDecoder().decode(NativeSearchSource.self, from: candidate.encoded)
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
                let awaitingSubscription = registry.subscriptionSearch(for: id) == nil
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
        for id in managedSourceIDs.subtracting(seen).sorted() where registry.builtinSearch(for: id) != nil {
            entries.append(.init(sourceID: id, name: registry.descriptor(for: id)?.name ?? id, status: String(localized: "缺少，已保留"),
                                 detail: String(localized: "本次訂閱未提供此來源，保留已安裝的搜尋與播放設定。")))
        }
        return .init(fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                     checkedAt: Date(), overrides: overrides, entries: entries)
    }

    private static func convert(config: [String: Any], id: String, baseline: NativeSearchSource) throws -> Candidate {
        guard let rawURL = config["searchUrl"] as? String else { throw Rejection.invalidURL }
        let url = try safeURL(rawURL, id: id, baseline: baseline)
        let format = config["subjectFormatId"] as? String
        var search = try JSONSerialization.jsonObject(with: canonical(baseline.search)) as! [String: Any]
        var signature: [String: String] = ["url": url, "format": format ?? ""]
        switch format {
        case "a":
            guard let spec = config["selectorSubjectFormatA"] as? [String: Any],
                  let selector = spec["selectLists"] as? String else { throw Rejection.invalidSelector }
            try validateSelector(selector)
            signature["selector"] = normalizedSelector(selector)
            if id != "fengche" && id != "haixing" {
                search["resultsSelector"] = selector
                search["titleSelector"] = "self"
                search.removeValue(forKey: "linkSelector")
                search.removeValue(forKey: "coverSelector")
                search.removeValue(forKey: "coverAttribute")
                search["hrefAttribute"] = "href"
            }
        case "indexed":
            guard let expected = indexedSelectors[id],
                  let spec = config["selectorSubjectFormatIndexed"] as? [String: Any],
                  let names = spec["selectNames"] as? String, let links = spec["selectLinks"] as? String else {
                throw Rejection.unsupportedParser
            }
            try validateSelector(names)
            try validateSelector(links)
            guard normalizedSelector(names) == normalizedSelector(expected.names),
                  normalizedSelector(links) == normalizedSelector(expected.links) else { throw Rejection.unsupportedParser }
            signature["names"] = normalizedSelector(names)
            signature["links"] = normalizedSelector(links)
            // Indexed lists are not independently zipped: vetted local row selectors retain correct identities.
        default: throw Rejection.unsupportedParser
        }
        search["url"] = url
        let transformed = try JSONDecoder().decode(SourceConfiguration.Search.self,
            from: JSONSerialization.data(withJSONObject: search, options: [.sortedKeys]))
        let source = NativeSearchSource(hosts: baseline.hosts, search: transformed, resultURLTemplate: baseline.resultURLTemplate)
        return Candidate(encoded: try canonical(source), signature: try JSONSerialization.data(withJSONObject: signature, options: [.sortedKeys]))
    }

    private static func safeURL(_ raw: String, id: String, baseline: NativeSearchSource) throws -> String {
        guard raw.utf8.count <= 4096, raw.contains("{keyword}"), !raw.contains(where: { $0.isWhitespace || $0.isNewline }),
              let incoming = URLComponents(string: raw), incoming.scheme == "https", incoming.user == nil,
              incoming.password == nil, incoming.port == nil, incoming.fragment == nil,
              let host = incoming.host?.lowercased(), aliases[id]?.contains(host) == true,
              baseline.hosts.contains(host), let local = URLComponents(string: baseline.search.url),
              incoming.path == local.path, !incoming.path.contains("..") else { throw Rejection.invalidURL }
        let fields = incoming.queryItems ?? []
        let localFields = local.queryItems ?? []
        var keys: Set<String> = []
        var hasQuery = false
        for field in fields {
            guard keys.insert(field.name).inserted else { throw Rejection.invalidURL }
            if field.name == baseline.search.queryParameter {
                guard field.value == "{keyword}" else { throw Rejection.invalidURL }
                hasQuery = true
            } else if field.name == baseline.search.pageParameter {
                guard field.value == "{page}" else { throw Rejection.invalidURL }
            } else {
                guard let fixed = localFields.first(where: { $0.name == field.name }), fixed.value == field.value,
                      !(field.value?.contains("{") ?? false) else { throw Rejection.invalidURL }
            }
        }
        guard hasQuery else { throw Rejection.invalidURL }
        let result = raw.replacingOccurrences(of: "{keyword}", with: "{query}")
        let sample = result.replacingOccurrences(of: "{query}", with: "boundary").replacingOccurrences(of: "{page}", with: "1")
        guard !sample.contains("{"), !sample.contains("}"), URL(string: sample) != nil else { throw Rejection.invalidURL }
        return result
    }

    private static func validateSelector(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 1024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Rejection.invalidSelector }
        do { _ = try SwiftSoup.parse("").select(value) }
        catch { throw Rejection.invalidSelector }
    }
    private static func normalizedSelector(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .replacingOccurrences(of: " >", with: ">").replacingOccurrences(of: "> ", with: ">")
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
