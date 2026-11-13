import Foundation
import CryptoKit
import SourceCore
import SwiftSoup

/// Compiles the declarative part of an Animeko export. Imported rules are data,
/// and a new origin has its own identity instead of acquiring a native adapter.
public enum SourceWebConfigurationConverter {
    public static func configuration(_ item: [String: Any]) throws -> SourceConfiguration {
        guard item["factoryId"] as? String == "web-selector", item["version"] as? Int == 2,
              !(item["version"] is Bool), let arguments = item["arguments"] as? [String: Any],
              let name = arguments["name"] as? String, !name.isEmpty, name.utf8.count <= 160,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let config = arguments["searchConfig"] as? [String: Any],
              let raw = config["searchUrl"] as? String else { throw SourceSubscriptionError.malformed }
        let sample = raw.replacingOccurrences(of: "{keyword}", with: "test")
            .replacingOccurrences(of: "{query}", with: "test").replacingOccurrences(of: "{page}", with: "1")
        guard let searchURL = SourceSubscriptionTransport.parse(sample), searchURL.port == nil,
              let host = searchURL.host?.lowercased() else { throw SourceSubscriptionFailure.invalidAddress }
        var origin = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)!
        origin.scheme = "https"; origin.host = host; origin.port = nil
        origin.path = ""; origin.query = nil; origin.fragment = nil
        guard let originURL = origin.url else { throw SourceSubscriptionError.malformed }
        let base: URL
        if let rawBase = config["rawBaseUrl"] as? String, !rawBase.isEmpty {
            guard let declared = SourceSubscriptionTransport.parse(rawBase), declared.port == nil,
                  declared.query == nil else { throw SourceSubscriptionFailure.invalidAddress }
            var normalized = URLComponents(url: declared, resolvingAgainstBaseURL: false)!
            normalized.scheme = "https"; normalized.host = declared.host?.lowercased()
            base = normalized.url!
        } else { base = originURL }
        let baseURL = base.absoluteString.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        let hosts = Set([host, base.host!.lowercased()]).sorted()
        let searchSource = try SourceSubscriptionConverter.searchSource(config: config, hosts: hosts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let search = try JSONSerialization.jsonObject(with: encoder.encode(searchSource.search))
        let format = config["subjectFormatId"] as? String ?? ""
        let subject: [String: Any]
        let names: String
        let links: String
        switch format {
        case "a":
            subject = config["selectorSubjectFormatA"] as? [String: Any] ?? [:]
            names = try selector(subject["selectLists"]); links = names
        case "indexed":
            subject = config["selectorSubjectFormatIndexed"] as? [String: Any] ?? [:]
            names = try selector(subject["selectNames"]); links = try selector(subject["selectLinks"])
        case "json-path-indexed":
            subject = config["selectorSubjectFormatJsonPathIndexed"] as? [String: Any] ?? [:]
            // convertSearch has compiled and validated both paths against the same JSON row.
            guard let n = subject["selectNames"] as? String, let l = subject["selectLinks"] as? String else {
                throw SourceSubscriptionError.malformed
            }
            names = n; links = l
        default: throw SourceSubscriptionError.malformed
        }
        var selectors: [String: Any] = ["baseURL": baseURL, "relativeLinksUseSearchURL": config["rawBaseUrl"] as? String == nil || config["rawBaseUrl"] as? String == "",
            "subjectFormat": format, "searchNames": names, "searchLinks": links]
        let channel = config["channelFormatId"] as? String ?? ""
        selectors["channelFormat"] = channel
        switch channel {
        case "index-grouped":
            guard let group = config["selectorChannelFormatFlattened"] as? [String: Any] else { throw SourceSubscriptionError.malformed }
            selectors["episodeLists"] = try selector(group["selectEpisodeLists"])
            selectors["episodeNames"] = try selector(group["selectEpisodesFromList"])
            if let value = group["selectChannelNames"] as? String, !value.isEmpty { selectors["channelNames"] = try selector(value) }
            if let value = group["selectEpisodeLinksFromList"] as? String, !value.isEmpty { selectors["episodeLinks"] = try selector(value) }
        case "no-channel":
            guard let group = config["selectorChannelFormatNoChannel"] as? [String: Any] else { throw SourceSubscriptionError.malformed }
            selectors["episodeNames"] = try selector(group["selectEpisodes"])
            if let value = group["selectEpisodeLinks"] as? String, !value.isEmpty { selectors["episodeLinks"] = try selector(value) }
        default: throw SourceSubscriptionError.malformed
        }
        if let resolution = config["defaultResolution"] as? String {
            let digits = resolution.prefix(while: { $0.isNumber })
            if let height = Int(digits), (1...4320).contains(height) { selectors["preferredVideoHeight"] = height }
        }
        let id = "web-" + SHA256.hash(data: Data(originURL.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let object: [String: Any] = ["id": id, "name": name, "version": 4, "hosts": hosts,
            "anonymousExternalHTTPSMedia": true, "credentialHosts": [],
            "capabilities": ["information", "search", "episodes", "lines", "resolve", "iina", "mpv"],
            "route": ["pattern": "^/(.*)$", "idGroup": 1, "detailTemplate": baseURL + "/{id}"],
            "catalog": ["url": baseURL + "/{id}", "format": "web-selector"],
            "player": ["format": "web-selector", "allowedExtensions": ["mp4", "m3u8", "mkv", "webm", "mov"]],
            "search": search, "webSelector": selectors]
        return try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    /// Keep native/search-only handling authoritative. Only previously unknown origins
    /// or explicitly imported web identities can become static-page configurations.
    static func addingStaticSources(items: [Any], to plan: SourceSubscriptionPlan,
                                    baselines: [String: NativeSearchSource]) -> SourceSubscriptionPlan {
        var entries = plan.entries
        var overrides = plan.overrides
        var configurations: [String: Data] = [:]
        var rejected = Set<String>()
        let nativeHosts = Set(SupportSites.nativeSites.flatMap(\.hosts)).union(SourceSubscriptionRules.excludedHosts)
        let reserved = nativeHosts.union(baselines.filter { !$0.key.hasPrefix("web-") }.values.flatMap(\.hosts))
        var candidateIndexes: [String: [Int]] = [:]
        for (index, raw) in items.enumerated() {
            guard entries.indices.contains(index), entries[index].sourceID == nil || entries[index].sourceID?.hasPrefix("web-") == true,
                  let item = raw as? [String: Any] else { continue }
            let old = entries[index]
            let proposedID = identity(item)
            do {
                let config = try configuration(item)
                guard Set(config.hosts).isDisjoint(with: reserved) else { continue }
                let data = try config.encodedData()
                candidateIndexes[config.id, default: []].append(index)
                if let previous = configurations[config.id], previous != data { rejected.insert(config.id) }
                else { configurations[config.id] = data }
                overrides.removeValue(forKey: config.id)
                entries[index] = .init(sourceID: config.id, name: old.name,
                    status: String(localized: "待匯入靜態來源"),
                    detail: String(localized: "提供搜尋、選集與靜態直連解析；需明確套用及啟用。未驗證網站即時可用性，不執行遠端腳本或匯入登入資訊。"))
            } catch {
                // Malformed updates to an existing origin must not replace its previous rules.
                entries[index] = .init(sourceID: old.sourceID, name: old.name, status: String(localized: "不支援"),
                    detail: String(localized: "無法轉換為靜態來源：需公開 HTTPS 網址、有效搜尋與集數選擇器；原有設定保留。"))
                if let id = old.sourceID ?? proposedID { rejected.insert(id); overrides.removeValue(forKey: id) }
            }
        }
        for id in rejected {
            configurations.removeValue(forKey: id)
            for index in candidateIndexes[id] ?? [] {
                let old = entries[index]
                entries[index] = .init(sourceID: id, name: old.name, status: String(localized: "衝突，已保留"),
                    detail: String(localized: "同一來源的重複項目互相衝突或含不支援設定；全部拒絕，保留先前設定。"))
            }
        }
        return .init(fingerprint: plan.fingerprint, checkedAt: plan.checkedAt, overrides: overrides,
            entries: entries, configurations: configurations)
    }

    private static func selector(_ value: Any?) throws -> String {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 1024, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SourceSubscriptionError.malformed
        }
        _ = try SwiftSoup.parse("").select(value)
        return value
    }

    private static func identity(_ item: [String: Any]) -> String? {
        guard let args = item["arguments"] as? [String: Any], let config = args["searchConfig"] as? [String: Any],
              let raw = config["searchUrl"] as? String, var url = URLComponents(string: raw),
              url.scheme?.lowercased() == "https", url.host != nil, url.port == nil else { return nil }
        url.scheme = "https"; url.host = url.host?.lowercased(); url.user = nil; url.password = nil
        url.path = ""; url.query = nil; url.fragment = nil
        guard let origin = url.url else { return nil }
        return "web-" + SHA256.hash(data: Data(origin.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
