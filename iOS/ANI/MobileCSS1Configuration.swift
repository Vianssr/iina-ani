import Foundation
import CryptoKit
import SwiftSoup

/// Converts the supported, declarative CSS1 subset into independent source configurations.
/// Remote cookies, headers, scripts and video-matching expressions are never persisted.
enum MobileCSS1Configuration {
    static func convert(data: Data) throws -> MobileSourceBatchDraft {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileSourceImportFailure.invalidConfiguration
        }
        let rawItems: Any?
        if root.keys.contains("mediaSources") { rawItems = root["mediaSources"] }
        else { rawItems = (root["exportedMediaSourceDataList"] as? [String: Any])?["mediaSources"] }
        guard let items = rawItems as? [Any], !items.isEmpty, items.count <= 128 else {
            throw MobileSourceImportFailure.invalidConfiguration
        }
        var drafts: [MobileSourceDraft] = []
        var notices: [String] = []
        var ids = Set<String>()
        for raw in items {
            let item = raw as? [String: Any]
            let arguments = item?["arguments"] as? [String: Any]
            let displayName = cleanedName(arguments?["name"] as? String) ?? String(localized: "Unnamed source")
            let draft: MobileSourceDraft
            do { draft = try configuration(item) }
            catch {
                let reason: String
                if item?["factoryId"] as? String != "web-selector" {
                    reason = String(localized: "Unsupported parser type; skipped.")
                } else if let search = arguments?["searchConfig"] as? [String: Any],
                          let address = search["searchUrl"] as? String,
                          address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
                    reason = String(localized: "HTTPS is required; skipped.")
                } else {
                    reason = String(localized: "Unsupported source format or configuration; skipped.")
                }
                notices.append(displayName + " · " + reason)
                continue
            }
            guard ids.insert(draft.configuration.id).inserted else {
                throw MobileSourceImportFailure.invalidConfiguration
            }
            drafts.append(draft)
        }
        guard drafts.count <= 100 else { throw MobileSourceImportFailure.invalidConfiguration }
        return MobileSourceBatchDraft(drafts: drafts, notices: notices)
    }

    private static func configuration(_ item: [String: Any]?) throws -> MobileSourceDraft {
        guard let item, item["factoryId"] as? String == "web-selector",
              item["version"] as? Int == 2, !(item["version"] is Bool),
              let arguments = item["arguments"] as? [String: Any],
              let name = cleanedName(arguments["name"] as? String),
              let input = arguments["searchConfig"] as? [String: Any],
              let rawSearch = input["searchUrl"] as? String,
              rawSearch.components(separatedBy: "{keyword}").count == 2 else {
            throw MobileSourceImportFailure.invalidConfiguration
        }
        let searchURL = rawSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{keyword}", with: "{query}")
        let sampledSearch = searchURL.replacingOccurrences(of: "{query}", with: "MobileConfigurationQuery")
        guard !sampledSearch.contains("{"), !sampledSearch.contains("}") else {
            throw MobileSourceImportFailure.invalidConfiguration
        }
        let search = try safeURL(sampledSearch)
        let base: URL
        if let configured = input["rawBaseUrl"] as? String,
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = try safeURL(configured.trimmingCharacters(in: .whitespacesAndNewlines))
            guard base.query == nil else { throw MobileSourceImportFailure.invalidConfiguration }
        } else {
            var origin = URLComponents(url: search, resolvingAgainstBaseURL: false)!
            origin.path = ""; origin.query = nil; origin.fragment = nil
            guard let url = origin.url else { throw MobileSourceImportFailure.invalidConfiguration }
            base = url
        }
        let baseURL = base.absoluteString.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        let subjectFormat = input["subjectFormatId"] as? String ?? ""
        let searchNames: String
        let searchLinks: String
        var linkTemplate: String?
        switch subjectFormat {
        case "a":
            let selectors = input["selectorSubjectFormatA"] as? [String: Any]
            searchNames = try selector(selectors?["selectLists"])
            searchLinks = searchNames
        case "indexed":
            let selectors = input["selectorSubjectFormatIndexed"] as? [String: Any]
            searchNames = try selector(selectors?["selectNames"])
            searchLinks = try selector(selectors?["selectLinks"])
        case "json-path-indexed":
            let selectors = input["selectorSubjectFormatJsonPathIndexed"] as? [String: Any]
            searchNames = try jsonPath(selectors?["selectNames"])
            searchLinks = try jsonPath(selectors?["selectLinks"])
            if let raw = selectors?["linkTemplate"] as? String, !raw.isEmpty {
                guard raw.utf8.count <= 2048, raw.components(separatedBy: "{value}").count == 2 else {
                    throw MobileSourceImportFailure.invalidConfiguration
                }
                let sample = raw.replacingOccurrences(of: "{value}", with: "MobileConfigurationValue")
                guard !sample.contains("{"), !sample.contains("}"),
                      let resolved = URL(string: sample, relativeTo: base)?.absoluteURL else {
                    throw MobileSourceImportFailure.invalidConfiguration
                }
                let checked = try safeURL(resolved.absoluteString)
                guard checked.host == base.host || checked.host == search.host else {
                    throw MobileSourceImportFailure.invalidConfiguration
                }
                linkTemplate = raw
            }
        default: throw MobileSourceImportFailure.invalidConfiguration
        }
        let channelFormat = input["channelFormatId"] as? String ?? ""
        var channelNames: String?
        var episodeLists: String?
        let episodeNames: String
        var episodeLinks: String?
        switch channelFormat {
        case "index-grouped":
            let selectors = input["selectorChannelFormatFlattened"] as? [String: Any]
            channelNames = try optionalSelector(selectors?["selectChannelNames"])
            episodeLists = try selector(selectors?["selectEpisodeLists"])
            episodeNames = try selector(selectors?["selectEpisodesFromList"])
            episodeLinks = try optionalSelector(selectors?["selectEpisodeLinksFromList"])
        case "no-channel":
            let selectors = input["selectorChannelFormatNoChannel"] as? [String: Any]
            episodeNames = try selector(selectors?["selectEpisodes"])
            episodeLinks = try optionalSelector(selectors?["selectEpisodeLinks"])
        default: throw MobileSourceImportFailure.invalidConfiguration
        }
        let fallbackIdentity = [baseURL, searchURL, name].joined(separator: "\n")
        let sourceID: String
        if let rawID = item["id"] as? String, validID(rawID) { sourceID = rawID }
        else {
            sourceID = "css1-" + SHA256.hash(data: Data(fallbackIdentity.utf8)).prefix(20)
                .map { String(format: "%02x", $0) }.joined()
        }
        var webSelector: [String: Any] = [
            "baseURL": baseURL, "relativeLinksUseSearchURL": (input["rawBaseUrl"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "subjectFormat": subjectFormat,
            "searchNames": searchNames, "searchLinks": searchLinks,
            "channelFormat": channelFormat, "episodeNames": episodeNames
        ]
        webSelector["linkTemplate"] = linkTemplate
        webSelector["channelNames"] = channelNames
        webSelector["episodeLists"] = episodeLists
        webSelector["episodeLinks"] = episodeLinks
        let template = baseURL + "/{id}"
        let object: [String: Any] = [
            "id": sourceID, "name": name, "version": 3,
            "hosts": Array(Set([search.host!, base.host!])).sorted(),
            "mediaHosts": [], "anonymousExternalHTTPSMedia": true, "credentialHosts": [],
            "capabilities": ["information", "resolve", "episodes", "lines", "mpv", "search"],
            "route": ["pattern": "^/(.*)$", "idGroup": 1, "detailTemplate": template],
            "catalog": ["url": template, "format": "web-selector"],
            "player": ["format": "web-selector", "allowedExtensions": ["m3u8", "mp4", "mpd", "mkv", "webm", "mov", "m4v"]],
            "search": ["url": searchURL, "format": "web-selector", "queryParameter": "", "pageParameter": "", "rowsPerPage": 100],
            "webSelector": webSelector
        ]
        let sanitized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let configuration = try MobileSourceLibrary.validate(sanitized)
        return MobileSourceDraft(configuration: configuration, data: sanitized)
    }

    private static func safeURL(_ raw: String) throws -> URL {
        guard !raw.isEmpty, raw.utf8.count <= 4096, !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = URL(string: raw), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else {
            throw MobileSourceImportFailure.invalidConfiguration
        }
        let sensitiveNames: Set<String> = ["cookie", "token", "access_token", "authorization", "auth", "api_key", "apikey", "password"]
        guard !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .contains(where: { sensitiveNames.contains($0.name.lowercased()) }) else {
            throw MobileSourceImportFailure.invalidConfiguration
        }
        return url
    }

    private static func selector(_ value: Any?) throws -> String {
        guard let raw = value as? String else { throw MobileSourceImportFailure.invalidConfiguration }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 1024,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MobileSourceImportFailure.invalidConfiguration
        }
        _ = try SwiftSoup.parse("").select(value)
        return value
    }

    private static func optionalSelector(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String else { throw MobileSourceImportFailure.invalidConfiguration }
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return try selector(string)
    }

    /// One wildcard array followed by a single field; no filters, recursive descent or unions.
    static func jsonPath(_ value: Any?) throws -> String {
        guard let value = value as? String, value.utf8.count <= 1024 else { throw MobileSourceImportFailure.invalidConfiguration }
        let pattern = #"^\$(?:(?:\.[A-Za-z_][A-Za-z0-9_-]*)|(?:\['[A-Za-z_][A-Za-z0-9_-]*'\]))*\[\*\](?:(?:\.[A-Za-z_][A-Za-z0-9_-]*)|(?:\['[A-Za-z_][A-Za-z0-9_-]*'\]))+$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw MobileSourceImportFailure.invalidConfiguration
        }
        return value
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    private static func cleanedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let clean = String(String(name.prefix(160)).unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
