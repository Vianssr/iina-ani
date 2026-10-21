//
//  Didahd.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Alamofire
import Foundation
import SwiftSoup
import WebKit

actor Didahd: SupportSiteProtocol {
    typealias LocalEndpoint = @Sendable () async throws -> HTTPServerEndpoint
    private let localEndpoint: LocalEndpoint

    init(localEndpoint: @escaping LocalEndpoint = { throw VideoGetError.notSupported }) {
        self.localEndpoint = localEndpoint
    }
    private struct Episode: Sendable {
        let number: Int
        let title: String
        let url: String
    }

    private struct Line: Sendable {
        let number: Int
        let title: String
        let episodes: [Episode]
    }

    private struct Catalog: Sendable {
        let title: String
        let cover: String
        let lines: [Line]
    }

    private func page(_ url: String) throws -> (id: Int, line: Int?, episode: Int?) {
        guard let components = URLComponents(string: url),
              let page = SupportSites.didahdPage(components) else { throw VideoGetError.invalidLink }
        return page
    }

    private func catalog(_ id: Int) async throws -> Catalog {
        let base = URL(string: "https://www.didahd.xyz/detail/\(id).html")!
        let html = try await AccountHTTP.request(base).validate().serializingString().value
        let document = try SwiftSoup.parse(html)
        guard let title = try document.select(".myui-content__detail h1.title").first()?.text(),
              !title.isEmpty else { throw VideoGetError.notFountData }
        let coverPath = try document.select(".myui-vodlist__thumb img").first()?.attr("data-original") ?? ""
        let cover = URL(string: coverPath, relativeTo: base)?.absoluteURL.absoluteString ?? ""
        var candidates: [Line] = []
        for tab in try document.select("a[href^=\"#playlist\"]") {
            let target = try tab.attr("href")
            guard target.hasPrefix("#playlist"),
                  let section = try document.select(target).first() else { continue }
            let name = try tab.text()
            var episodes: [Episode] = []
            var lineNumber: Int?
            for link in try section.select("a[href]") {
                let href = try link.attr("href")
                guard let address = URL(string: href, relativeTo: base)?.absoluteURL,
                      let components = URLComponents(url: address, resolvingAgainstBaseURL: false),
                      let item = SupportSites.didahdPage(components), item.id == id,
                      let line = item.line, let episode = item.episode,
                      lineNumber == nil || lineNumber == line else { continue }
                lineNumber = line
                episodes.append(Episode(number: episode, title: try link.text(), url: address.absoluteString))
            }
            if let lineNumber, !episodes.isEmpty {
                candidates.append(Line(number: lineNumber, title: name, episodes: episodes))
            }
        }
        // The other lines currently use unsupported encrypted players or cloud-drive pages.
        // Check their real player before offering them as playable choices.
        var lines: [Line] = []
        await withTaskGroup(of: (Int, Bool).self) { group in
            for line in candidates {
                group.addTask { (line.number, (try? await Self.player(line.episodes[0].url, id: id,
                                                                       line: line.number,
                                                                       episode: line.episodes[0].number)) != nil) }
            }
            var supported = Set<Int>()
            for await (number, available) in group where available { supported.insert(number) }
            lines = candidates.filter { supported.contains($0.number) }
        }
        try Task.checkCancellation()
        guard !lines.isEmpty else { throw VideoGetError.notFountData }
        return Catalog(title: title, cover: cover, lines: lines)
    }

    func episodeList(_ url: String) async throws -> (nodes: [VideoTreeNode], current: Int) {
        let address = try page(url)
        let data = try await catalog(address.id)
        var current = 0
        var position = 0
        let nodes = data.lines.map { line in
            let children = line.episodes.map { episode in
                if line.number == address.line && episode.number == address.episode { current = position }
                position += 1
                return VideoTreeNode(site: .didahd, index: episode.number,
                                     title: episode.title, id: "\(address.id)", url: episode.url)
            }
            return VideoTreeNode(title: line.title, children: children)
        }
        if address.episode != nil && !data.lines.contains(where: { line in
            line.number == address.line && line.episodes.contains(where: { $0.number == address.episode })
        }) { throw VideoGetError.notFountData }
        return (nodes, current)
    }

    func liveInfo(_ url: String) async throws -> any LiveInfo {
        let address = try page(url)
        let data = try await catalog(address.id)
        let available = address.episode == nil || data.lines.contains { line in
            line.number == address.line && line.episodes.contains { $0.number == address.episode }
        }
        return DidahdInfo(title: data.title, name: data.title, cover: data.cover, isLiving: available)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let address = try page(url)
        let data = try await catalog(address.id)
        guard let line = address.line == nil ? data.lines.first : data.lines.first(where: { $0.number == address.line }),
              let episode = address.episode == nil ? line.episodes.first : line.episodes.first(where: { $0.number == address.episode }) else {
            throw VideoGetError.notFountData
        }
        let token = try await Self.player(episode.url, id: address.id, line: line.number, episode: episode.number)
        let playlist = try await DidahdTokenResolver.resolve(token)
        let endpoint = try await localEndpoint()
        let streamURL = try await DidahdProxy.shared.register(playlist, endpoint: endpoint)
        var result = YouGetJSON(rawUrl: url)
        result.title = "\(data.title) - \(episode.title)"
        result.streams["\(line.title) (\(line.number))"] = Stream(url: streamURL)
        return result
    }

    private static func player(_ url: String, id: Int, line: Int, episode: Int) async throws -> String {
        let html = try await AccountHTTP.request(url).validate().serializingString().value
        guard let start = html.range(of: "var player_aaaa=")?.upperBound,
              let end = html.range(of: "</script>", range: start..<html.endIndex)?.lowerBound,
              let data = html[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";")).data(using: .utf8),
              let player = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              player["id"] as? String == "\(id)", player["sid"] as? Int == line,
              player["nid"] as? Int == episode, player["trysee"] as? Int == 0,
              player["points"] as? Int == 0, player["from"] as? String == "4kvm",
              player["encrypt"] as? Int == 3,
              let token = player["url"] as? String, !token.isEmpty,
              token.count.isMultiple(of: 2), token.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else {
            throw VideoGetError.notFountData
        }
        return token
    }
}

struct DidahdInfo: LiveInfo {
    let title: String
    let name: String
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites = .didahd
}

@MainActor private final class DidahdTokenResolver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var timeout: Task<Void, Never>?

    static func resolve(_ token: String) async throws -> URL {
        let resolver = DidahdTokenResolver()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resolver.start(token, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in resolver.finish(.failure(CancellationError())) }
        }
    }

    private func start(_ token: String, continuation: CheckedContinuation<URL, any Error>) {
        self.continuation = continuation
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "didahdPlaylist")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            (() => {
              const send = url => {
                if (String(url).includes('/video_m3u8/secure.php'))
                  window.webkit.messageHandlers.didahdPlaylist.postMessage(new URL(url, location.href).href);
              };
              const fetch0 = window.fetch;
              window.fetch = function(input, ...rest) {
                send(typeof input === 'string' ? input : input.url);
                return fetch0.call(this, input, ...rest);
              };
              const open0 = XMLHttpRequest.prototype.open;
              XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                send(url);
                return open0.call(this, method, url, ...rest);
              };
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView = view
        view.navigationDelegate = self
        var address = URLComponents(string: "https://www.didahd.xyz/static/player/artplayer/")!
        address.queryItems = [URLQueryItem(name: "url", value: token)]
        view.load(URLRequest(url: address.url!))
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.finish(.failure(VideoGetError.notFountData))
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "www.didahd.xyz",
              let text = message.body as? String, let url = URL(string: text),
              url.scheme == "https", url.host == "www.didahd.xyz", url.port == nil,
              url.path == "/video_m3u8/secure.php",
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                  $0.name == "skey" && $0.value?.hasSuffix(".m3u8") == true
              }) == true else { return }
        finish(.success(url))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "didahdPlaylist")
        webView = nil
        continuation.resume(with: result)
    }
}
