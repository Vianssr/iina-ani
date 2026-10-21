//
//  Haixing.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation
import Alamofire
import SwiftSoup

actor Haixing: SupportSiteProtocol {
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

    private struct PlayInfo: Decodable, Sendable {
        let purl: String?
        let vurl: String?
        let inv: String?
    }

    /// One `playinfo` cookie challenge: the response sets `t1`/`k1`, and the
    /// payload request must answer with cookies derived from them.
    private struct Challenge: Sendable {
        let t1: String
        let k1: String?
        let serverTime: Int64?
    }

    private static let siteHeaders: HTTPHeaders = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.3"
    ]

    /// The site's cookie challenge is answered manually below; a session with
    /// cookie storage disabled keeps stale `t1` challenges from being echoed
    /// back and voiding the next one.
    private static let session: Session = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        return Session(configuration: configuration)
    }()

    private static let lineTitles = ["播放Ⅰ", "播放Ⅱ", "播放Ⅲ", "播放Ⅳ", "播放Ⅴ", "播放Ⅵ"]

    private func page(_ url: String) throws -> (id: String, line: Int?, episode: Int?) {
        guard let components = URLComponents(string: url),
              let page = SupportSites.haixingPage(components) else { throw VideoGetError.invalidLink }
        return page
    }

    private func catalog(_ id: String) async throws -> Catalog {
        let base = URL(string: "https://www.haixingdmx.com/view/\(id).html")!
        let html = try await Self.session.request(base, headers: Self.siteHeaders).validate().serializingString().value
        let document = try SwiftSoup.parse(html)
        guard let title = try document.select("h1").first()?.text(),
              !title.isEmpty else { throw VideoGetError.notFountData }
        let coverPath = try document.select(".thumb img").first()?.attr("src") ?? ""
        let cover = URL(string: coverPath, relativeTo: base)?.absoluteURL.absoluteString ?? ""

        // Each `div.movurl` block is one playback line; only anchors link to
        // playable episodes, plain text rows are "no resource" placeholders.
        var lines: [Line] = []
        for block in try document.select("div.movurl") {
            var episodes: [Episode] = []
            var seen: Set<Int> = []
            var lineNumber: Int?
            for link in try block.select("li a[href]") {
                let href = try link.attr("href")
                guard let address = URL(string: href, relativeTo: base)?.absoluteURL,
                      let components = URLComponents(url: address, resolvingAgainstBaseURL: false),
                      let item = SupportSites.haixingPage(components), item.id == id,
                      let line = item.line, let episode = item.episode,
                      lineNumber == nil || lineNumber == line else { continue }
                lineNumber = line
                guard seen.insert(episode).inserted else { continue }
                var title = try link.text()
                if title.isEmpty {
                    title = try link.attr("title")
                }
                episodes.append(Episode(number: episode, title: title, url: address.absoluteString))
            }
            if let lineNumber, !episodes.isEmpty {
                lines.append(Line(number: lineNumber,
                                  title: lineNumber >= 0 && lineNumber < Self.lineTitles.count
                                    ? Self.lineTitles[lineNumber] : "播放\(lineNumber + 1)",
                                  episodes: episodes))
            }
        }
        lines.sort { $0.number < $1.number }
        return Catalog(title: title, cover: cover, lines: lines)
    }

    private func episode(_ address: (id: String, line: Int?, episode: Int?), _ data: Catalog) throws -> (line: Line, episode: Episode) {
        guard let line = address.line == nil ? data.lines.first : data.lines.first(where: { $0.number == address.line }),
              let episode = address.episode == nil ? line.episodes.first : line.episodes.first(where: { $0.number == address.episode }) else {
            throw VideoGetError.notFountData
        }
        return (line, episode)
    }

    func episodeList(_ url: String) async throws -> (nodes: [VideoTreeNode], current: Int) {
        let address = try page(url)
        let data = try await catalog(address.id)
        guard !data.lines.isEmpty else { throw VideoGetError.notFountData }
        var current = 0
        var position = 0
        let nodes = data.lines.map { line in
            let children = line.episodes.map { episode in
                if line.number == address.line && episode.number == address.episode { current = position }
                position += 1
                return VideoTreeNode(site: .haixing, index: episode.number,
                                     title: episode.title, id: address.id, url: episode.url)
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
        let available = address.episode == nil
            ? !data.lines.isEmpty
            : data.lines.contains { line in
                line.number == address.line && line.episodes.contains { $0.number == address.episode }
            }
        return HaixingInfo(title: data.title, name: data.title, cover: data.cover, isLiving: available)
    }

    func decodeUrl(_ url: String) async throws -> YouGetJSON {
        let address = try page(url)
        let data = try await catalog(address.id)
        let selected = try episode(address, data)
        let challenge = try await Self.challenge(id: address.id, line: selected.line.number, episode: selected.episode.number)
        let media = try await Self.mediaURL(challenge, id: address.id, line: selected.line.number, episode: selected.episode.number)
        var result = YouGetJSON(rawUrl: url)
        result.title = "\(data.title) - \(selected.episode.title)"
        var stream = Stream(url: media)
        stream.qualityIndex = selected.line.number
        result.streams[selected.line.title] = stream

        // Other lines only offer the same episode: match by title when both
        // lines name their episodes, otherwise by the shared episode index.
        let alternatives = data.lines.filter { $0.number != selected.line.number }.compactMap { other -> (Line, Episode)? in
            guard let match = other.episodes.first(where: {
                if !$0.title.isEmpty && !selected.episode.title.isEmpty { return $0.title == selected.episode.title }
                return $0.number == selected.episode.number
            }) else { return nil }
            return (other, match)
        }
        for (other, match) in alternatives {
            guard let url = try? await Self.mediaURL(challenge, id: address.id, line: other.number, episode: match.number) else { continue }
            try Task.checkCancellation()
            var stream = Stream(url: url)
            stream.qualityIndex = other.number
            result.streams[other.title] = stream
        }
        return result
    }

    // MARK: - playinfo cookie challenge

    private static func challenge(id: String, line: Int, episode: Int) async throws -> Challenge {
        let url = try playInfoURL(id: id, line: line, episode: episode)
        var headers = siteHeaders
        headers.add(name: "Referer", value: "https://www.haixingdmx.com/play/\(id)-\(line)-\(episode).html")
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let response = await session.request(url, headers: headers).serializingData().response
            let setCookie = response.response?.value(forHTTPHeaderField: "Set-Cookie") ?? ""
            guard let t1 = cookieValue("t1", in: setCookie) else { continue }
            var serverTime: Int64?
            if let time = try? await session.request("https://www.haixingdmx.com/time", headers: siteHeaders).serializingString().value,
               let seconds = Int64(time.trimmingCharacters(in: .whitespacesAndNewlines)) {
                serverTime = seconds
            }
            return Challenge(t1: t1, k1: cookieValue("k1", in: setCookie), serverTime: serverTime)
        }
        throw VideoGetError.notFountData
    }

    private static func mediaURL(_ challenge: Challenge, id: String, line: Int, episode: Int) async throws -> String {
        var current = challenge
        for attempt in 0..<3 {
            if attempt > 0 {
                current = try await self.challenge(id: id, line: line, episode: episode)
            }
            var headers = siteHeaders
            headers.add(name: "Referer", value: "https://www.haixingdmx.com/play/\(id)-\(line)-\(episode).html")
            headers.add(name: "Cookie", value: cookieHeader(current))
            let request = try playInfoURL(id: id, line: line, episode: episode)
            let body = await session.request(request, headers: headers)
                .serializingData().response.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if let info = payload(body), info.inv != "1", let media = media(info.vurl) {
                return media
            }
        }
        throw VideoGetError.notFountData
    }

    private static func playInfoURL(id: String, line: Int, episode: Int) throws -> URL {
        var components = URLComponents(string: "https://www.haixingdmx.com/playinfo")!
        components.queryItems = [
            URLQueryItem(name: "aid", value: id),
            URLQueryItem(name: "playindex", value: "\(line)"),
            URLQueryItem(name: "epindex", value: "\(episode)"),
            URLQueryItem(name: "r", value: "\(Double.random(in: 0..<1))")
        ]
        guard let url = components.url else { throw VideoGetError.invalidLink }
        return url
    }

    /// Mirrors the site's `pck.js`: `k2`/`t2` answer the `t1` challenge, `m2t`
    /// is a client timestamp fingerprint, `im`/`kr` track the server clock.
    private static func cookieHeader(_ challenge: Challenge) -> String {
        let now = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        let c = ((Int64(challenge.t1) ?? 0) / 1000) >> 5
        let k2 = ((c * (c % 255 + 3) + 27691) * ((c % 129) + 11)) * ((c % 15) + 7) + c
        var t2 = now
        let need = String(k2 % 10)
        while true {
            let text = String(t2)
            if text.count >= 3, String(text[text.index(text.endIndex, offsetBy: -3)]) == need { break }
            t2 += 1
        }
        // The browser counts Windows and sparse touch screens into the shift;
        // a macOS desktop profile contributes one.
        let x = (now / 1000) >> 18
        let m2t = (x * 17 + 189) * ((x % 63) + 15) * ((x % 31) + 33) * ((x % 17) + 112) * ((x % 7) + 67) + 379
        var cookies = ["t1=\(challenge.t1)", "k2=\(k2)", "t2=\(t2)", "m2t=\(m2t)"]
        if let k1 = challenge.k1 {
            cookies.append("k1=\(k1)")
        }
        if let serverTime = challenge.serverTime {
            let im = fingerprint(serverTime >> 18)
            let kr = fingerprint(serverTime >> 7)
            cookies.append("im=\(im)")
            cookies.append("kr=\(kr)")
        }
        return cookies.joined(separator: "; ")
    }

    private static func fingerprint(_ x: Int64) -> Int64 {
        (x * 13 + 275) * ((x % 33) + 11) * ((x % 17) + 3) + 903
    }

    private static func cookieValue(_ name: String, in header: String) -> String? {
        let pattern = "(?:^|[;,]\\s*)\(NSRegularExpression.escapedPattern(for: name))=([^;,]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        return Range(match.range(at: 1), in: header).map { String(header[$0]) }
    }

    // MARK: - playinfo payload

    private static func payload(_ body: String) -> PlayInfo? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("ipchk:"), !trimmed.contains("not verified") else { return nil }
        var text = trimmed
        if !text.contains("{") {
            // Hex pairs decoded from the end of the string with a running offset.
            let chars = Array(text)
            guard chars.count % 2 == 0, chars.allSatisfy({ $0.isHexDigit }) else { return nil }
            var bytes: [UInt8] = []
            var index = 0
            while index < chars.count {
                guard let high = Int(String(chars[index]), radix: 16),
                      let low = Int(String(chars[index + 1]), radix: 16) else { return nil }
                let value = (high * 16 + low + 1048576 - 2371 - (chars.count / 2 - 1 - index / 2)) % 256
                bytes.append(UInt8(value))
                index += 2
            }
            // The payload is UTF-8; the site's own player turns each byte into a
            // character instead, which mangles non-ASCII media paths.
            text = String(decoding: bytes.reversed(), as: UTF8.self)
        }
        guard let data = text.data(using: .utf8),
              let info = try? JSONDecoder().decode(PlayInfo.self, from: data) else { return nil }
        return info
    }

    private static func media(_ string: String?) -> String? {
        guard let string,
              let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              ["m3u8", "mp4", "flv", "mkv"].contains(url.pathExtension.lowercased()) else { return nil }
        return url.absoluteString
    }
}

struct HaixingInfo: LiveInfo {
    let title: String
    let name: String
    let avatar = ""
    let cover: String
    let isLiving: Bool
    let site: SupportSites = .haixing
}
