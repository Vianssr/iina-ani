import Foundation
import SwiftSoup
import WebKit

struct NativeSearchSource: Codable, Sendable {
    let hosts: [String]
    let search: SourceConfiguration.Search
    let resultURLTemplate: String?
}

struct NativeSearchResources: Decodable, Sendable {
    let version: Int
    let sources: [String: NativeSearchSource]
}

enum SourceSearchError: Error, LocalizedError {
    case invalidConfiguration
    case transport
    case httpStatus(Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return String(localized: "The source search configuration is invalid.")
        case .transport: return String(localized: "The source search request failed before receiving a response.")
        case .httpStatus(let status): return String(localized: "The source search server returned HTTP \(status).")
        case .malformedResponse: return String(localized: "The source search response did not match its configured format.")
        }
    }
}

private final class SearchRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allowedHosts: Set<String>

    init(allowedHosts: Set<String>) { self.allowedHosts = allowedHosts }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil, let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        var safe = request
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        completionHandler(safe)
    }
}

enum SourceSearchExecutor {
    static func search(query: String, page: Int, spec: SourceConfiguration.Search,
                       allowedHosts: Set<String>, resultURLTemplate: String? = nil,
                       classification: @Sendable (SourceItemRef) -> MediaClassification = { _ in .unknown },
                       item: @Sendable (String) -> SourceItemRef?) async throws -> SourceSearchPage {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, page > 0, page <= 100_000,
              spec.rowsPerPage > 0, spec.rowsPerPage <= 100,
              ["html", "json"].contains(spec.format), !allowedHosts.isEmpty else {
            throw VideoGetError.invalidLink
        }
        let url = try requestURL(spec, query: query, page: page, allowedHosts: allowedHosts)
        let data: Data
        let responseURL: URL
        if url.host == "api.bilibili.com", url.path == "/x/web-interface/search/type" {
            data = try await BilibiliGuestSearch.fetch(url, query: query)
            responseURL = url
        } else {
            (data, responseURL) = try await fetch(url, allowedHosts: allowedHosts)
        }
        try Task.checkCancellation()
        return try parse(data: data, spec: spec, page: page, responseURL: responseURL,
                         resultURLTemplate: resultURLTemplate, classification: classification, item: item)
    }

    static func requestURL(_ spec: SourceConfiguration.Search, query: String, page: Int,
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
        } else {
            guard var components = URLComponents(string: raw) else { throw SourceSearchError.invalidConfiguration }
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: spec.queryParameter, value: query)]
            guard let url = components.url else { throw SourceSearchError.invalidConfiguration }
            raw = url.absoluteString
        }
        if !hasPagePlaceholder {
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

    static func parse(data: Data, spec: SourceConfiguration.Search, page: Int, responseURL: URL,
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
            guard try doc.select("#challenge-form, #cf-challenge-running, .cf-browser-verification").isEmpty() else {
                throw SourceSearchError.malformedResponse
            }
            for selector in spec.rejectSelectors ?? [] {
                if try !doc.select(selector).isEmpty() { throw SourceSearchError.malformedResponse }
            }
            guard let rowSelector = spec.resultsSelector, !rowSelector.isEmpty,
                  let titleSelector = spec.titleSelector, !titleSelector.isEmpty,
                  let hrefAttribute = spec.hrefAttribute, !hrefAttribute.isEmpty else {
                throw SourceSearchError.invalidConfiguration
            }
            let rows: Elements
            do { rows = try doc.select(rowSelector) }
            catch { throw SourceSearchError.invalidConfiguration }
            for row in rows {
                do {
                    let titleNode = titleSelector == "self" ? row : try row.select(titleSelector).first()
                    guard let titleNode else { continue }
                    let title = try titleNode.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    let linkNode: Element
                    if let selector = spec.linkSelector, selector != "self" {
                        guard let selected = try row.select(selector).first() else { continue }
                        linkNode = selected
                    } else {
                        linkNode = titleNode
                    }
                    let href = try linkNode.attr(hrefAttribute)
                    guard !title.isEmpty, !href.isEmpty,
                          let target = URL(string: href, relativeTo: responseURL)?.absoluteURL,
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
            if !rows.isEmpty() && results.isEmpty { throw SourceSearchError.malformedResponse }
            if let selector = spec.nextPageSelector {
                do {
                    hasNext = try doc.select(selector).contains { element in
                        let href = try element.attr("href")
                        return !href.isEmpty && href != "#" && !href.lowercased().hasPrefix("javascript:") &&
                            !element.hasClass("disabled") && element.parent()?.hasClass("disabled") != true &&
                            URL(string: href, relativeTo: responseURL)?.absoluteURL != responseURL
                    }
                } catch { throw SourceSearchError.invalidConfiguration }
            } else { hasNext = rows.count >= spec.rowsPerPage }
        } else if spec.format == "json" {
            let root: Any
            do { root = try JSONSerialization.jsonObject(with: data) }
            catch { throw SourceSearchError.malformedResponse }
            guard let rows = jsonValue(root, path: spec.jsonResultsPath ?? "") as? [[String: Any]],
                  let titlePath = spec.jsonTitlePath, let identifierPath = spec.jsonIdentifierPath else {
                throw SourceSearchError.malformedResponse
            }
            for row in rows {
                guard let rawTitle = jsonValue(row, path: titlePath) as? String,
                      let identifier = stringValue(jsonValue(row, path: identifierPath)) else { continue }
                let title: String
                do { title = try SwiftSoup.parse(rawTitle).text().trimmingCharacters(in: .whitespacesAndNewlines) }
                catch { throw SourceSearchError.malformedResponse }
                guard !title.isEmpty else { continue }
                let pageURL = resultURLTemplate.map { expand($0, values: ["id": identifier]) } ?? identifier
                guard !pageURL.contains("{") && !pageURL.contains("}"), let ref = item(pageURL) else { continue }
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
        return SourceSearchPage(results: results, nextPage: hasNext ? page + 1 : nil)
    }

    private static func fetch(_ url: URL, allowedHosts: Set<String>) async throws -> (Data, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let session = URLSession(configuration: configuration,
                                 delegate: SearchRedirectPolicy(allowedHosts: allowedHosts), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw SourceSearchError.transport
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SourceSearchError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw SourceSearchError.httpStatus(http.statusCode) }
        guard let finalURL = http.url, finalURL.scheme?.lowercased() == "https", finalURL.user == nil,
              finalURL.password == nil, finalURL.port == nil, let host = finalURL.host?.lowercased(),
              allowedHosts.contains(host) else { throw SourceSearchError.invalidConfiguration }
        return (data, finalURL)
    }

    private static func jsonValue(_ root: Any, path: String) -> Any? {
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
        if let value = value as? NSNumber { return value.stringValue }
        return nil
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

// Bilibili search runs in its public frontend origin, with a fresh anonymous web store.
@MainActor private final class BilibiliGuestSearch: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var timeout: Task<Void, Never>?
    private var endpoint: URL?

    static func fetch(_ endpoint: URL, query: String) async throws -> Data {
        let search = BilibiliGuestSearch()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                search.start(endpoint, query: query, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in search.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ endpoint: URL, query: String, continuation: CheckedContinuation<Data, any Error>) {
        self.endpoint = endpoint
        self.continuation = continuation
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView = view
        view.navigationDelegate = self
        var page = URLComponents(string: "https://search.bilibili.com/all")!
        page.queryItems = [URLQueryItem(name: "keyword", value: query)]
        view.load(URLRequest(url: page.url!))
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.finish(.failure(SourceSearchError.transport))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let frame = navigationAction.targetFrame else { decisionHandler(.cancel); return }
        if !frame.isMainFrame { decisionHandler(.allow); return }
        guard let url = navigationAction.request.url, url.scheme == "https", let host = url.host,
              (host == "search.bilibili.com" || host == "www.bilibili.com"),
              url.port == nil, url.user == nil, url.password == nil else {
            decisionHandler(.cancel)
            finish(.failure(SourceSearchError.transport))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let endpoint, continuation != nil else { return }
        webView.callAsyncJavaScript("""
            const response = await fetch(endpoint, {credentials: 'include'});
            return {status: response.status, body: await response.text()};
            """, arguments: ["endpoint": endpoint.absoluteString], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            guard case .success(let value) = result, let response = value as? [String: Any],
                  let status = response["status"] as? Int, let body = response["body"] as? String else {
                self.finish(.failure(SourceSearchError.transport))
                return
            }
            guard (200..<300).contains(status) else {
                self.finish(.failure(SourceSearchError.httpStatus(status)))
                return
            }
            self.finish(.success(Data(body.utf8)))
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(SourceSearchError.transport))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(SourceSearchError.transport))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(SourceSearchError.transport)) }

    private func finish(_ result: Result<Data, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(with: result)
    }
}
