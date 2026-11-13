//
//  DidahdProxy.swift
//  SourceRuntime
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation
import SourceCore

// Didahd prepends a PNG to each MPEG-TS segment. Only the validated TS payload
// is served to players, through a loopback-only listener retained for playback.
actor DidahdProxy {
    static let shared = DidahdProxy()

    private struct Session {
        let playlist: Data
        let segments: [URL]
        let expires: Date
        let port: UInt16
        let fetch: SourceHTTPTransport.Fetch?
        var lastAccess: Date
    }

    private let client: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: DidahdRedirectPolicy(), delegateQueue: nil)
    }()
    private let server = DidahdLoopbackServer()
    private var sessions: [String: Session] = [:]
    private var cleanupTask: Task<Void, Never>?

    deinit {
        cleanupTask?.cancel()
        client.invalidateAndCancel()
    }

    func register(_ remote: URL, fetch: SourceHTTPTransport.Fetch? = nil) async throws -> String {
        try Task.checkCancellation()
        guard remote.scheme == "https", remote.host == "www.didahd.xyz", remote.port == nil,
              remote.user == nil, remote.password == nil,
              remote.path == "/video_m3u8/secure.php" else { throw VideoGetError.notFountData }
        let data = try await download(remote, maximumBytes: 2_000_000, fetch: fetch)
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
            throw VideoGetError.notFountData
        }
        let id = UUID().uuidString
        var segments: [URL] = []
        var output: [String] = []
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            if line.hasPrefix("#") {
                // Encrypted keys, init segments and child playlists have no protected route.
                guard !line.contains("URI=") else { throw VideoGetError.notFountData }
                output.append(line)
            } else {
                guard let url = URL(string: line), url.scheme == "https",
                      url.host == "file.icve.com.cn", url.port == nil,
                      url.user == nil, url.password == nil,
                      (url.path.hasPrefix("/bk/") || url.path.hasPrefix("/rc/")),
                      url.pathExtension.lowercased() == "png" else {
                    throw VideoGetError.notFountData
                }
                output.append("\(segments.count).ts")
                segments.append(url)
            }
        }
        guard !segments.isEmpty, segments.count <= 10_000,
              let playlist = (output.joined(separator: "\n") + "\n").data(using: .utf8) else {
            throw VideoGetError.notFountData
        }
        let port = try await server.start { [weak self] path in
            try await self?.response(for: path)
        }
        try Task.checkCancellation()
        removeExpiredSessions()
        // Retain adjacent playback sessions, but never accumulate an unbounded
        // history of tokenized playlists in a long-running mobile process.
        if sessions.count >= 16, let oldest = sessions.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            sessions.removeValue(forKey: oldest)
        }
        let now = Date()
        sessions[id] = Session(playlist: playlist, segments: segments,
                               expires: now.addingTimeInterval(2 * 60 * 60), port: port,
                               fetch: fetch, lastAccess: now)
        if cleanupTask == nil {
            cleanupTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self else { return }
                    if await self.removeExpiredSessions() { return }
                }
            }
        }
        return "http://127.0.0.1:\(port)/didahd/\(id)/index.m3u8"
    }

    func ownsPlaylist(_ url: URL) -> Bool {
        let parts = url.path.split(separator: "/")
        guard url.scheme == "http", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              parts.count == 3, parts[0] == "didahd", parts[2] == "index.m3u8",
              let session = sessions[String(parts[1])], url.host == "127.0.0.1",
              url.port == Int(session.port) else { return false }
        return session.expires > Date()
    }

    func response(for path: String) async throws -> (data: Data, contentType: String)? {
        try Task.checkCancellation()
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "didahd",
              let session = sessions[String(parts[1])], session.expires > Date() else { return nil }
        sessions[String(parts[1])]?.lastAccess = Date()
        if parts[2] == "index.m3u8" {
            return (session.playlist, "application/vnd.apple.mpegurl")
        }
        guard parts[2].hasSuffix(".ts"),
              let index = Int(parts[2].dropLast(3)), session.segments.indices.contains(index) else { return nil }
        let data = try await download(session.segments[index], maximumBytes: 8_000_000, fetch: session.fetch)
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let pngEnd = data.range(of: Data([73, 69, 78, 68, 174, 66, 96, 130]))?.upperBound,
              pngEnd + 376 < data.count,
              data[pngEnd] == 0x47, data[pngEnd + 188] == 0x47,
              data[pngEnd + 376] == 0x47 else { throw VideoGetError.notFountData }
        return (data.subdata(in: pngEnd..<data.count), "video/mp2t")
    }

    // Keep the desktop's two-hour token lifetime, including when no new source
    // selections arrive to trigger cleanup. No segment bodies or temp files persist.
    @discardableResult
    private func removeExpiredSessions() -> Bool {
        sessions = sessions.filter { $0.value.expires > Date() }
        if sessions.isEmpty {
            cleanupTask?.cancel()
            cleanupTask = nil
            return true
        }
        return false
    }

    private func download(_ url: URL, maximumBytes: Int, fetch: SourceHTTPTransport.Fetch?) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        if let fetch {
            let response = try await fetch(request)
            try Task.checkCancellation()
            guard response.statusCode == 200, DidahdRedirectPolicy.permits(response.url),
                  response.data.count < maximumBytes else { throw VideoGetError.notFountData }
            return response.data
        }
        // The shared general-purpose transport may have a smaller response cap than
        // this site's segments. Keep the desktop's separate playlist/segment bounds,
        // and stop reading at the bound instead of allocating an unbounded response.
        let (bytes, response) = try await client.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let finalURL = response.url, DidahdRedirectPolicy.permits(finalURL),
              response.expectedContentLength < Int64(maximumBytes) else { throw VideoGetError.notFountData }
        var data = Data()
        data.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 64_000)
        for try await byte in bytes {
            guard data.count < maximumBytes - 1 else { throw VideoGetError.notFountData }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}

private final class DidahdRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func permits(_ url: URL) -> Bool {
        url.scheme == "https" && url.port == nil && url.user == nil && url.password == nil &&
            ["www.didahd.xyz", "file.icve.com.cn"].contains(url.host ?? "")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.permits(url) else {
            completionHandler(nil)
            return
        }
        var safe = request
        safe.httpShouldHandleCookies = false
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        completionHandler(safe)
    }
}
