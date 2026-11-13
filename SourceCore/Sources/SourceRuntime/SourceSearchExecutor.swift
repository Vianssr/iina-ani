import SourceCore
import Foundation
import CoreFoundation
import SwiftSoup

public enum SourceSearchError: Error, LocalizedError, Sendable {
    case invalidConfiguration
    case transport
    case httpStatus(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return String(localized: "The source search configuration is invalid.")
        case .transport: return String(localized: "The source search request failed before receiving a response.")
        case .httpStatus(let status): return String(localized: "The source search server returned HTTP \(status).")
        case .malformedResponse: return String(localized: "The source search response did not match its configured format.")
        }
    }
}

/// Static HTML/JSON search used by the desktop CSS1-backed source identities.
/// The unrelated Bilibili browser-origin search is intentionally not part of this runtime.
public enum SourceSearchExecutor {
    /// Validates persisted/public search metadata independently of any particular native adapter.
    public static func validate(_ spec: SourceConfiguration.Search, allowedHosts: Set<String>,
                                resultURLTemplate: String? = nil, allowLegacyArrayQueryParameters: Bool = false) throws {
        let credentialKeys: Set<String> = ["cookie", "token", "access_token", "authorization", "auth", "api_key", "apikey", "password", "passwd", "secret"]
        // Reviewed v1/v2 APIs can request several fixed output fields with fl[]=a&fl[]=b.
        // Imported selector rules retain the stricter default; dynamic and secret arrays never qualify.
        let fixedArrayKeys: Set<String>
        if allowLegacyArrayQueryParameters {
            // Encoding the template delimiters first prevents Foundation from escaping
            // already encoded query names again while repairing the raw braces.
            let parseable = spec.url.replacingOccurrences(of: "{", with: "%7B").replacingOccurrences(of: "}", with: "%7D")
            let items = URLComponents(string: parseable)?.queryItems ?? []
            fixedArrayKeys = Set(Dictionary(grouping: items, by: \.name).compactMap { key, values in
                guard key.hasSuffix("[]"), key != spec.queryParameter, key != spec.pageParameter,
                      !credentialKeys.contains(String(key.dropLast(2)).lowercased()),
                      values.allSatisfy({ $0.value.map { !$0.contains("{") && !$0.contains("}") } ?? false }) else { return nil }
                return key
            })
        } else { fixedArrayKeys = [] }
        func publicURL(_ url: URL) -> Bool {
            guard SourceSubscriptionTransport.allows(url), url.port == nil,
                  let host = url.host?.lowercased(), allowedHosts.contains(host) else { return false }
            var keys = Set<String>()
            return (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).allSatisfy {
                !credentialKeys.contains($0.name.lowercased()) && (keys.insert($0.name).inserted || fixedArrayKeys.contains($0.name))
            }
        }
        guard !allowedHosts.isEmpty, spec.url.utf8.count <= 4096, !spec.url.contains("\\"),
              !spec.url.contains(where: { $0.isWhitespace || $0.isNewline }),
              spec.queryParameter.utf8.count <= 128, spec.pageParameter.utf8.count <= 128,
              ["html", "json"].contains(spec.format) else { throw SourceSearchError.invalidConfiguration }
        let expanded = expand(spec.url, values: ["query": "ConfigValidationID", "page": "1"])
        guard !expanded.contains("{"), !expanded.contains("}"),
              let request = try? requestURL(spec, query: "ConfigValidationID", page: 1, allowedHosts: allowedHosts),
              publicURL(request) else { throw SourceSearchError.invalidConfiguration }
        func selector(_ value: String?) throws {
            guard let value else { throw SourceSearchError.invalidConfiguration }
            do { try SelectorPairing.validate(value) } catch { throw SourceSearchError.invalidConfiguration }
        }
        if spec.format == "html" {
            guard let attribute = spec.hrefAttribute, !attribute.isEmpty, attribute.utf8.count <= 128,
                  attribute.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":") }) else {
                throw SourceSearchError.invalidConfiguration
            }
            if spec.indexedNamesSelector != nil || spec.indexedLinksSelector != nil {
                guard spec.resultsSelector == nil, spec.titleSelector == nil, spec.linkSelector == nil else {
                    throw SourceSearchError.invalidConfiguration
                }
                try selector(spec.indexedNamesSelector); try selector(spec.indexedLinksSelector)
            } else {
                try selector(spec.resultsSelector)
                if spec.titleSelector != "self" { try selector(spec.titleSelector) }
                if let link = spec.linkSelector, link != "self" { try selector(link) }
            }
            if let next = spec.nextPageSelector { try selector(next) }
            if let cover = spec.coverSelector { try selector(cover) }
            for reject in spec.rejectSelectors ?? [] { try selector(reject) }
        } else {
            guard spec.indexedNamesSelector == nil, spec.indexedLinksSelector == nil else { throw SourceSearchError.invalidConfiguration }
            func path(_ value: String?, root: Bool = false) -> Bool {
                guard let value, !value.isEmpty, value.utf8.count <= 256 else { return false }
                if root && value == "$" { return true }
                let parts = value.split(separator: ".", omittingEmptySubsequences: false)
                return parts.count <= 16 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } }
            }
            guard path(spec.jsonResultsPath, root: true), path(spec.jsonTitlePath), path(spec.jsonIdentifierPath),
                  spec.jsonTitleAlternatives.map({ !$0.isEmpty && $0.count <= 8 && $0.allSatisfy { path($0) } }) ?? true,
                  spec.jsonIdentifierAlternatives.map({ !$0.isEmpty && $0.count <= 8 && $0.allSatisfy { path($0) } }) ?? true,
                  spec.jsonCoverPath.map({ path($0) }) ?? true,
                  spec.jsonTotalPath.map({ path($0) }) ?? true else { throw SourceSearchError.invalidConfiguration }
        }
        let base = try resultBaseURL(spec, responseURL: request)
        guard publicURL(base) else { throw SourceSearchError.invalidConfiguration }
        for template in [spec.resultURLTemplate, resultURLTemplate].compactMap({ $0 }) {
            let sample = expand(template, values: ["id": "ConfigValidationID", "value": "ConfigValidationID"])
            guard template.utf8.count <= 4096, !template.contains("\\"),
                  !template.contains(where: { $0.isWhitespace || $0.isNewline }),
                  !sample.contains("{"), !sample.contains("}"),
                  let target = URL(string: sample, relativeTo: base)?.absoluteURL, publicURL(target) else {
                throw SourceSearchError.invalidConfiguration
            }
        }
    }

    public static func search(query: String, page: Int, spec: SourceConfiguration.Search,
                              allowedHosts: Set<String>, resultURLTemplate: String? = nil,
                              allowLegacyArrayQueryParameters: Bool = false,
                              classification: @Sendable (SourceItemRef) -> MediaClassification = { _ in .unknown },
                              fetch: SourceHTTPTransport.Fetch? = nil,
                              item: @Sendable (String) -> SourceItemRef?) async throws -> SourceSearchPage {
        try validate(spec, allowedHosts: allowedHosts, resultURLTemplate: resultURLTemplate,
                     allowLegacyArrayQueryParameters: allowLegacyArrayQueryParameters)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, page > 0, page <= 100_000,
              spec.rowsPerPage > 0, spec.rowsPerPage <= 100,
              ["html", "json"].contains(spec.format), !allowedHosts.isEmpty else {
            throw SourceSearchError.invalidConfiguration
        }
        let url = try requestURL(spec, query: query, page: page, allowedHosts: allowedHosts)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SourceHTTPTransport.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 30
        let response: SourceHTTPResponse
        do {
            try Task.checkCancellation()
            if let fetch { response = try await fetch(request) }
            else { response = try await SourceHTTPTransport.fetch(request, allowedHosts: allowedHosts) }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            switch error {
            case SourceHTTPTransportError.invalidURL: throw SourceSearchError.invalidConfiguration
            case SourceHTTPTransportError.invalidResponse, SourceHTTPTransportError.oversizedResponse:
                throw SourceSearchError.malformedResponse
            default: throw SourceSearchError.transport
            }
        }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw SourceSearchError.httpStatus(response.statusCode) }
        guard SourceHTTPTransport.permits(response.url, allowedHosts: allowedHosts) else {
            throw SourceSearchError.invalidConfiguration
        }
        guard response.data.count <= SourceHTTPTransport.maximumResponseBytes else { throw SourceSearchError.malformedResponse }
        return try parse(data: response.data, spec: spec, page: page, responseURL: response.url,
                         resultURLTemplate: resultURLTemplate, classification: classification, item: item)
    }

    public static func requestURL(_ spec: SourceConfiguration.Search, query: String, page: Int,
                                  allowedHosts: Set<String>) throws -> URL {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, page > 0, page <= 100_000,
              spec.rowsPerPage > 0, spec.rowsPerPage <= 100 else { throw SourceSearchError.invalidConfiguration }
        guard (0...1).contains(spec.firstPage ?? 1) else { throw SourceSearchError.invalidConfiguration }
        let sourcePage = page - 1 + (spec.firstPage ?? 1)
        var raw = spec.url
        let hasQueryPlaceholder = raw.contains("{query}")
        let hasPagePlaceholder = raw.contains("{page}")
        if hasQueryPlaceholder || hasPagePlaceholder {
            raw = expand(raw, values: ["query": query, "page": String(sourcePage)])
        }
        if !hasQueryPlaceholder {
            guard !spec.queryParameter.isEmpty else { throw SourceSearchError.invalidConfiguration }
            guard var components = URLComponents(string: raw) else { throw SourceSearchError.invalidConfiguration }
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: spec.queryParameter, value: query)]
            guard let url = components.url else { throw SourceSearchError.invalidConfiguration }
            raw = url.absoluteString
        }
        if !hasPagePlaceholder && !spec.pageParameter.isEmpty {
            guard var components = URLComponents(string: raw) else { throw SourceSearchError.invalidConfiguration }
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == spec.pageParameter }
            queryItems.append(URLQueryItem(name: spec.pageParameter, value: String(sourcePage)))
            components.queryItems = queryItems
            guard let url = components.url else { throw SourceSearchError.invalidConfiguration }
            raw = url.absoluteString
        }
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(), allowedHosts.contains(host),
              let url = components.url else { throw SourceSearchError.invalidConfiguration }
        return url
    }

    public static func parse(data: Data, spec: SourceConfiguration.Search, page: Int, responseURL: URL,
                             resultURLTemplate: String? = nil,
                             classification: @Sendable (SourceItemRef) -> MediaClassification = { _ in .unknown },
                             item: @Sendable (String) -> SourceItemRef?) throws -> SourceSearchPage {
        guard !data.isEmpty else { throw SourceSearchError.malformedResponse }
        var results: [SourceSearchResult] = []
        var seen: Set<SourceItemRef> = []
        let hasNext: Bool
        if spec.format == "html" {
            let html = String(decoding: data, as: UTF8.self)
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceSearchError.malformedResponse
            }
            let doc: Document
            do { doc = try SwiftSoup.parse(html) }
            catch { throw SourceSearchError.malformedResponse }
            guard try doc.select("#challenge-form, #cf-challenge-running, .cf-browser-verification, #cf-error-details, form[action*='/ajax/verify_check']").isEmpty() else {
                throw SourceSearchError.malformedResponse
            }
            for selector in spec.rejectSelectors ?? [] {
                if try !doc.select(selector).isEmpty() { throw SourceSearchError.malformedResponse }
            }
            guard let hrefAttribute = spec.hrefAttribute, !hrefAttribute.isEmpty else {
                throw SourceSearchError.invalidConfiguration
            }
            let rows: [(row: Element, name: Element, link: Element)]
            let matchedRowCount: Int
            if spec.indexedNamesSelector != nil || spec.indexedLinksSelector != nil {
                guard let names = spec.indexedNamesSelector, let links = spec.indexedLinksSelector else {
                    throw SourceSearchError.invalidConfiguration
                }
                do { rows = try SelectorPairing.pairs(in: doc, names: names, links: links).map { ($0.name, $0.name, $0.link) } }
                catch SelectorPairing.Failure.invalidSelector { throw SourceSearchError.invalidConfiguration }
                catch { throw SourceSearchError.malformedResponse }
                matchedRowCount = rows.count
            } else {
                guard let rowSelector = spec.resultsSelector, !rowSelector.isEmpty,
                      let titleSelector = spec.titleSelector, !titleSelector.isEmpty else { throw SourceSearchError.invalidConfiguration }
                do {
                    let selected = try doc.select(rowSelector)
                    matchedRowCount = selected.count
                    rows = try selected.compactMap { row in
                        guard let title = titleSelector == "self" ? row : try row.select(titleSelector).first() else { return nil }
                        let link: Element?
                        if let selector = spec.linkSelector, selector != "self" { link = try row.select(selector).first() }
                        else { link = title }
                        guard let link else { return nil }
                        return (row, title, link)
                    }
                } catch { throw SourceSearchError.invalidConfiguration }
            }
            let resultBase = try resultBaseURL(spec, responseURL: responseURL)
            for (row, titleNode, linkNode) in rows {
                do {
                    let title = try titleNode.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    let href = try linkNode.attr(hrefAttribute)
                    guard !title.isEmpty, !href.isEmpty,
                          let target = URL(string: href, relativeTo: resultBase)?.absoluteURL,
                          let ref = item(target.absoluteString) else { continue }
                    let cover = try spec.coverSelector.flatMap { selector -> String? in
                        guard let image = try row.select(selector).first() else { return nil }
                        return try image.attr(spec.coverAttribute ?? "src")
                    } ?? ""
                    let absoluteCover = cover.isEmpty ? "" : URL(string: cover, relativeTo: responseURL)?.absoluteURL.absoluteString ?? ""
                    if seen.insert(ref).inserted {
                        results.append(SourceSearchResult(item: ref, title: title, cover: absoluteCover,
                                                          classification: classification(ref)))
                    }
                } catch {
                    throw SourceSearchError.malformedResponse
                }
            }
            if matchedRowCount > 0 && results.isEmpty { throw SourceSearchError.malformedResponse }
            if let selector = spec.nextPageSelector {
                do {
                    hasNext = try doc.select(selector).contains { element in
                        let href = try element.attr("href")
                        return !href.isEmpty && href != "#" && !href.lowercased().hasPrefix("javascript:") &&
                            !element.hasClass("disabled") && element.parent()?.hasClass("disabled") != true &&
                            URL(string: href, relativeTo: responseURL)?.absoluteURL != responseURL
                    }
                } catch { throw SourceSearchError.invalidConfiguration }
            } else { hasNext = matchedRowCount >= spec.rowsPerPage }
        } else if spec.format == "json" {
            let root: Any
            do { root = try JSONSerialization.jsonObject(with: data) }
            catch { throw SourceSearchError.malformedResponse }
            guard let rows = jsonValue(root, path: spec.jsonResultsPath ?? "") as? [[String: Any]],
                  let titlePath = spec.jsonTitlePath, let identifierPath = spec.jsonIdentifierPath else {
                throw SourceSearchError.malformedResponse
            }
            let resultBase = try resultBaseURL(spec, responseURL: responseURL)
            for row in rows {
                guard let rawTitle = ([titlePath] + (spec.jsonTitleAlternatives ?? [])).lazy.compactMap({ jsonValue(row, path: $0) as? String }).first(where: { !$0.isEmpty }),
                      let identifier = ([identifierPath] + (spec.jsonIdentifierAlternatives ?? [])).lazy.compactMap({ stringValue(jsonValue(row, path: $0)) }).first else { continue }
                let title: String
                do { title = try SwiftSoup.parse(rawTitle).text().trimmingCharacters(in: .whitespacesAndNewlines) }
                catch { throw SourceSearchError.malformedResponse }
                guard !title.isEmpty else { continue }
                let template = spec.resultURLTemplate ?? resultURLTemplate
                let pageURL = template.map { expand($0, values: ["id": identifier, "value": identifier]) } ?? identifier
                guard !pageURL.contains("{") && !pageURL.contains("}"),
                      let target = URL(string: pageURL, relativeTo: resultBase)?.absoluteURL,
                      let ref = item(target.absoluteString) else { continue }
                let cover = spec.jsonCoverPath.flatMap { jsonValue(row, path: $0) as? String } ?? ""
                if seen.insert(ref).inserted {
                    let absoluteCover = cover.isEmpty ? "" : URL(string: cover, relativeTo: responseURL)?.absoluteURL.absoluteString ?? ""
                    results.append(SourceSearchResult(item: ref, title: title, cover: absoluteCover,
                                                      classification: classification(ref)))
                }
            }
            if !rows.isEmpty && results.isEmpty { throw SourceSearchError.malformedResponse }
            if let totalPath = spec.jsonTotalPath, let total = jsonValue(root, path: totalPath) as? NSNumber {
                hasNext = total.intValue > page * spec.rowsPerPage
            } else {
                hasNext = rows.count >= spec.rowsPerPage
            }
        } else {
            throw SourceSearchError.invalidConfiguration
        }
        let canRequestNextPage = spec.url.contains("{page}") || !spec.pageParameter.isEmpty
        return SourceSearchPage(results: results, nextPage: hasNext && canRequestNextPage && page < 100_000 ? page + 1 : nil)
    }

    private static func jsonValue(_ root: Any, path: String) -> Any? {
        if path == "$" { return root }
        guard !path.isEmpty else { return nil }
        return path.split(separator: ".").reduce(Optional(root)) { value, key in
            guard let value else { return nil }
            if let dict = value as? [String: Any] { return dict[String(key)] }
            if let array = value as? [Any], let index = Int(key), array.indices.contains(index) { return array[index] }
            return nil
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.stringValue }
        return nil
    }

    private static func resultBaseURL(_ spec: SourceConfiguration.Search, responseURL: URL) throws -> URL {
        guard let raw = spec.resultBaseURL else { return responseURL }
        guard let base = URL(string: raw), base.scheme?.lowercased() == "https", base.host != nil,
              base.user == nil, base.password == nil, base.port == nil, base.fragment == nil else {
            throw SourceSearchError.invalidConfiguration
        }
        return base
    }

    private static func expand(_ template: String, values: [String: String]) -> String {
        var safe = CharacterSet.alphanumerics
        safe.insert(charactersIn: "-._~")
        return values.reduce(template) { current, entry in
            current.replacingOccurrences(of: "{\(entry.key)}",
                with: entry.value.addingPercentEncoding(withAllowedCharacters: safe) ?? "")
        }
    }
}
