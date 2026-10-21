//
//  DidahdProxy.swift
//  IINA+
//
//  Copyright © 2026 IINA-ANI contributors.
//

import Foundation

// Didahd returns MPEG-TS segments with a small, valid PNG prepended. External players
// detect the PNG rather than the transport stream; expose only validated TS on loopback.
actor DidahdProxy {
    static let shared = DidahdProxy()

    private struct Session {
        let playlist: Data
        let segments: [URL]
        let expires: Date
        let endpoint: HTTPServerEndpoint
    }

    private let client: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration, delegate: DidahdRedirectPolicy(), delegateQueue: nil)
    }()
    private var sessions: [String: Session] = [:]

    func register(_ remote: URL, endpoint: HTTPServerEndpoint) async throws -> String {
        guard remote.scheme == "https", remote.host == "www.didahd.xyz", remote.port == nil,
              remote.path == "/video_m3u8/secure.php" else { throw VideoGetError.notFountData }
        let (data, response) = try await client.data(from: remote)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count < 2_000_000, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#EXTM3U") else { throw VideoGetError.notFountData }
        let id = UUID().uuidString
        var segments: [URL] = []
        var output: [String] = []
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            if line.hasPrefix("#") {
                // Keys, init segments and secondary playlists would need their own protected routes.
                guard !line.contains("URI=") else { throw VideoGetError.notFountData }
                output.append(line)
            } else {
                guard let url = URL(string: line), url.scheme == "https",
                      url.host == "file.icve.com.cn", url.port == nil,
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
        sessions = sessions.filter { $0.value.expires > Date() }
        sessions[id] = Session(playlist: playlist, segments: segments,
                               expires: Date().addingTimeInterval(2 * 60 * 60), endpoint: endpoint)
        return "http://\(endpoint.host):\(endpoint.port)/didahd/\(id)/index.m3u8"
    }

    func ownsPlaylist(_ url: URL) -> Bool {
        let parts = url.path.split(separator: "/")
        guard url.scheme == "http", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              parts.count == 3, parts[0] == "didahd", parts[2] == "index.m3u8",
              let session = sessions[String(parts[1])], url.host == session.endpoint.host,
              url.port == session.endpoint.port else { return false }
        return session.expires > Date()
    }

    func response(for path: String) async throws -> (data: Data, contentType: String)? {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "didahd",
              let session = sessions[String(parts[1])], session.expires > Date() else { return nil }
        if parts[2] == "index.m3u8" {
            return (session.playlist, "application/vnd.apple.mpegurl")
        }
        guard parts[2].hasSuffix(".ts"),
              let index = Int(parts[2].dropLast(3)), session.segments.indices.contains(index) else {
            return nil
        }
        let (data, response) = try await client.data(from: session.segments[index])
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count < 8_000_000, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let pngEnd = data.range(of: Data([73, 69, 78, 68, 174, 66, 96, 130]))?.upperBound,
              pngEnd + 376 < data.count,
              data[pngEnd] == 0x47, data[pngEnd + 188] == 0x47,
              data[pngEnd + 376] == 0x47 else { throw VideoGetError.notFountData }
        return (data.subdata(in: pngEnd..<data.count), "video/mp2t")
    }
}

private final class DidahdRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme == "https" &&
                          ["www.didahd.xyz", "file.icve.com.cn"].contains(url?.host ?? "")
                          ? request : nil)
    }
}
