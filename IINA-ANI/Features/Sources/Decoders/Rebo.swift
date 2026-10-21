//
//  Rebo.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation
import Alamofire
import SwiftSoup
import WebKit

actor Rebo: SupportSiteProtocol {
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

    private func page(_ raw: String) throws -> (id: Int, line: Int?, episode: Int?) {
        guard let components = URLComponents(string: raw),
              let page = SupportSites.reboPage(components) else { throw VideoGetError.invalidLink }
        return page
    }

    private func catalog(_ id: Int) async throws -> Catalog {
        guard let url = URL(string: "https://www.rebozj.cc/detail/\(id).html") else {
            throw VideoGetError.invalidLink
        }
        let html = try await AccountHTTP.request(url).validate().serializingString().value
        try Task.checkCancellation()
        let document = try SwiftSoup.parse(html)
        guard let title = try document.select(".stui-content__detail h1.title").first()?.text(),
              !title.isEmpty else { throw VideoGetError.notFountData }
        let image = try document.select(".stui-content__thumb img").first()
        let originalCover = try image?.attr("data-original") ?? ""
        let coverPath = originalCover.isEmpty ? (try image?.attr("src") ?? "") : originalCover
        let cover = URL(string: coverPath, relativeTo: url)?.absoluteURL.absoluteString ?? ""
        var lines: [Line] = []
        for tab in try document.select(".nav-tabs a[href^='#playlist']") {
            let target = try tab.attr("href")
            guard target.hasPrefix("#playlist"), let tabIndex = Int(target.dropFirst("#playlist".count)), tabIndex >= 0,
                  let panel = try document.getElementById("playlist\(tabIndex)") else { continue }
            var episodes: [Episode] = []
            var lineNumber: Int?
            var seen = Set<Int>()
            for link in try panel.select(".stui-content__playlist a[href]") {
                guard let address = URL(string: try link.attr("href"), relativeTo: url)?.absoluteURL,
                      let parsed = try? page(address.absoluteString), parsed.id == id,
                      let number = parsed.line, let episode = parsed.episode,
                      lineNumber == nil || lineNumber == number, seen.insert(episode).inserted else { continue }
                lineNumber = number
                let episodeTitle = try link.text()
                guard !episodeTitle.isEmpty else { continue }
                episodes.append(Episode(number: episode, title: episodeTitle, url: address.absoluteString))
            }
            if !episodes.isEmpty, let lineNumber {
                let label = try tab.text()
                lines.append(Line(number: lineNumber, title: label.isEmpty ? "Line \(lineNumber)" : label,
                                  episodes: episodes))
            }
        }
        var supported = Set<Int>()
        await withTaskGroup(of: (Int, Bool).self) { group in
            for line in lines {
                group.addTask {
                    (line.number, (try? await Self.supportedPlayer(line.episodes[0].url, id: id,
                                                                  line: line.number,
                                                                  episode: line.episodes[0].number)) ?? false)
                }
            }
            for await (number, available) in group where available { supported.insert(number) }
        }
        try Task.checkCancellation()
        lines.removeAll { !supported.contains($0.number) }
        guard !lines.isEmpty else { throw VideoGetError.notFountData }
        return Catalog(title: title, cover: cover, lines: lines)
    }

    private static func supportedPlayer(_ raw: String, id: Int, line: Int, episode: Int) async throws -> Bool {
        let html = try await AccountHTTP.request(raw).validate().serializingString().value
        try Task.checkCancellation()
        return playerToken(html, id: id, line: line, episode: episode) != nil
    }

    private static func playerToken(_ html: String, id: Int, line: Int, episode: Int) -> String? {
        guard let start = html.range(of: "var player_aaaa=")?.upperBound,
              let end = html.range(of: "</script>", range: start..<html.endIndex)?.lowerBound,
              let data = html[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";")).data(using: .utf8),
              let player = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              player["id"] as? String == "\(id)", player["sid"] as? Int == line,
              player["nid"] as? Int == episode, player["points"] as? Int == 0,
              player["trysee"] as? Int == 0, player["encrypt"] as? Int == 3,
              let from = player["from"] as? String, from == "BBA" || from == "NBY",
              let token = player["url"] as? String, !token.isEmpty, token.count.isMultiple(of: 2),
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        return token
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
                return VideoTreeNode(site: .rebo, index: episode.number, title: episode.title,
                                     id: "\(address.id)", url: episode.url)
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
        return ReboInfo(title: data.title, cover: data.cover, isLiving: available)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let address = try page(url)
        let data = try await catalog(address.id)
        guard let line = address.line == nil ? data.lines.first : data.lines.first(where: { $0.number == address.line }),
              let episode = address.episode == nil ? line.episodes.first : line.episodes.first(where: { $0.number == address.episode }) else {
            throw VideoGetError.notFountData
        }
        let media = try await Self.mediaURL(episode.url, id: address.id, line: line.number, episode: episode.number)
        try Task.checkCancellation()
        var result = YouGetJSON(rawUrl: url)
        result.title = "\(data.title) - \(episode.title)"
        var stream = Stream(url: media)
        stream.qualityIndex = line.number
        result.streams["\(line.title) (\(line.number))"] = stream
        return result
    }

    private static func mediaURL(_ raw: String, id: Int, line: Int, episode: Int) async throws -> String {
        let html = try await AccountHTTP.request(raw).validate().serializingString().value
        try Task.checkCancellation()
        guard let token = playerToken(html, id: id, line: line, episode: episode) else {
            throw VideoGetError.notFountData
        }
        return try await ReboTokenResolver.resolve(token).absoluteString
    }
}

struct ReboInfo: LiveInfo {
    let title: String
    var name: String { title }
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites = .rebo
}

@MainActor private final class ReboTokenResolver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var timeout: Task<Void, Never>?

    static func resolve(_ token: String) async throws -> URL {
        let resolver = ReboTokenResolver()
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
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "reboMedia")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            (() => {
              let sent = false;
              const capture = () => {
                if (sent) return;
                const video = document.querySelector('video');
                if (!video) return;
                const source = video.currentSrc || video.getAttribute('src');
                if (!source) return;
                try {
                  const url = new URL(source, location.href);
                  const host = url.hostname.toLowerCase();
                  const allowed = ['365yg.com', 'samtory.cn'].some(domain => host === domain || host.endsWith('.' + domain));
                  if (url.protocol !== 'https:' || url.username || url.password || !allowed) return;
                  sent = true;
                  window.webkit.messageHandlers.reboMedia.postMessage(url.href);
                } catch (_) {}
              };
              new MutationObserver(capture).observe(document, {childList:true,subtree:true,attributes:true,attributeFilter:['src']});
              document.addEventListener('DOMContentLoaded', capture);
              document.addEventListener('loadstart', capture, true);
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView = view
        view.navigationDelegate = self
        var address = URLComponents(string: "https://www.rebozj.cc/static/player/artplayer/")!
        address.queryItems = [URLQueryItem(name: "url", value: token)]
        view.load(URLRequest(url: address.url!))
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.finish(.failure(VideoGetError.notFountData))
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == "www.rebozj.cc",
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.request.url?.path == "/static/player/artplayer",
              let text = message.body as? String, let url = URL(string: text),
              url.scheme == "https", let host = url.host?.lowercased(), url.port == nil,
              url.user == nil, url.password == nil,
              ["365yg.com", "samtory.cn"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return }
        finish(.success(url))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, url.scheme == "https",
              url.host == "www.rebozj.cc", url.port == nil, url.user == nil, url.password == nil,
              url.path == "/static/player/artplayer" else { return .cancel }
        return .allow
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
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "reboMedia")
        webView = nil
        continuation.resume(with: result)
    }
}
