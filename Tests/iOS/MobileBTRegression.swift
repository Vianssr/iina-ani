import Foundation

@main struct MobileBTRegression {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func rejects(_ error: MobileBTError, _ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Expected error: \(error)") }
        catch let actual as MobileBTError { require(actual == error, "Unexpected BT error") }
        catch { fatalError("Unexpected error type") }
    }

    static func main() async throws {
        let hash = String(repeating: "a", count: 40)
        let magnet = "magnet:?xt=urn:btih:\(hash)&dn=Fixture&tr=https%3A%2F%2Ftracker.example%2Fannounce%3Ftoken%3Dfixture"
        let server = URL(string: "https://server.example/prefix")!
        require(MobileBTAddress.server(" https://server.example/prefix ") == server, "Server path retained")
        for value in ["http://server.example", "https://u:p@server.example", "https://server.example?token=x", "https://server.example/#x", "file:///tmp/server", "https://"] {
            require(MobileBTAddress.server(value) == nil, "Unsafe server accepted")
        }
        require(MobileBTAddress.torrent(magnet) == magnet, "BTIH magnet")
        require(MobileBTAddress.torrent("magnet:?xt=urn:btih:" + String(repeating: "A", count: 32)) != nil, "Base32 BTIH")
        require(MobileBTAddress.torrent("magnet:?xt=urn:btmh:1220" + String(repeating: "b", count: 64)) != nil, "BTMH magnet")
        require(MobileBTAddress.torrent("https://files.example/video.torrent?token=fixture") != nil, "Signed torrent URL")
        for value in ["magnet:?dn=Name", "magnet:?xt=urn:btih:123", "magnet://host?xt=urn:btih:\(hash)", "javascript:alert(1)", "http://files.example/file.torrent", "https://u:p@files.example/file.torrent", "https://files.example/watch", "https://files.example/file.torrent#x"] {
            require(MobileBTAddress.torrent(value) == nil, "Invalid torrent accepted")
        }
        let pending = Data("{\"hash\":\"\(hash)\"}".utf8)
        let ready = Data("{\"hash\":\"\(hash)\",\"title\":\"Fixture\",\"file_stats\":[{\"id\":7,\"path\":\"Season/episode.mkv\",\"length\":1234},{\"id\":12,\"path\":\"readme.txt\",\"length\":100}]}".utf8)
        let queue = ResponseQueue([pending, ready])
        let client = MobileBTClient(transport: { try await queue.fetch($0) }, pause: {}, attempts: 2)
        let torrent = try await client.load(server: server, input: magnet)
        require(torrent.videoFiles.count == 1 && torrent.videoFiles[0].id == 7, "Playable files retain server IDs")
        let requests = await queue.requests
        require(requests.count == 2, "Poll only while metadata absent")
        require(requests.allSatisfy { $0.url == server.appendingPathComponent("torrents") && $0.httpMethod == "POST" && !$0.httpShouldHandleCookies }, "Protocol request")
        let add = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
        require(add["action"] as? String == "add" && add["link"] as? String == magnet && add["save_to_db"] as? Bool == false, "No database save")
        let get = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
        require(get["action"] as? String == "get" && get["hash"] as? String == hash && get["link"] == nil, "Polling uses hash")
        let stream = try MobileBTClient.stream(server: server, torrent: torrent, file: torrent.videoFiles[0])
        let parts = URLComponents(url: stream, resolvingAgainstBaseURL: false)!
        require(parts.path == "/prefix/stream", "Reverse proxy base path")
        require(parts.queryItems?.first(where: { $0.name == "index" })?.value == "7", "Server file index, not row offset")
        require(!stream.absoluteString.contains("tracker") && !stream.absoluteString.contains("magnet") && !stream.absoluteString.contains("token"), "No input credentials in playback URL")
        await rejects(.invalidSelection) {
            _ = try MobileBTClient.stream(server: server, torrent: torrent, file: MobileBTFile(id: 1, path: "wrong.mp4", length: 100))
        }
        await rejects(.metadataTimeout) {
            _ = try await MobileBTClient(transport: { _ in pending }, pause: {}, attempts: 2).load(server: server, input: magnet)
        }
        await rejects(.invalidResponse) {
            let bad = Data("{\"hash\":\"bad\",\"file_stats\":[]}".utf8)
            _ = try await MobileBTClient(transport: { _ in bad }, pause: {}).load(server: server, input: magnet)
        }
        await rejects(.noVideo) {
            let data = Data("{\"hash\":\"\(hash)\",\"file_stats\":[{\"id\":1,\"path\":\"readme.txt\"}]}".utf8)
            _ = try await MobileBTClient(transport: { _ in data }, pause: {}).load(server: server, input: magnet)
        }
        await rejects(.invalidResponse) {
            let data = Data("{\"hash\":\"\(hash)\",\"file_stats\":[{\"id\":1,\"path\":\"a.mp4\"},{\"id\":1,\"path\":\"b.mp4\"}]}".utf8)
            _ = try MobileBTTorrent.decode(data)
        }
        await rejects(.invalidResponse) {
            _ = try MobileBTTorrent.decode(Data(repeating: 32, count: 2 * 1024 * 1024 + 1))
        }
        await rejects(.invalidResponse) {
            let changed = ResponseQueue([pending, Data("{\"hash\":\"\(String(repeating: "b", count: 40))\"}".utf8)])
            _ = try await MobileBTClient(transport: { try await changed.fetch($0) }, pause: {}).load(server: server, input: magnet)
        }
        let cancelled = Task {
            try await MobileBTClient(transport: { _ in
                try await Task.sleep(for: .seconds(5))
                return ready
            }, pause: {}).load(server: server, input: magnet)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancellation ignored") }
        catch is CancellationError {}
        print("Mobile BT regression passed: URL policy, protocol, metadata polling, file identity, stream construction, malformed responses and cancellation")
    }
}

private actor ResponseQueue {
    private var data: [Data]
    private(set) var requests: [URLRequest] = []
    init(_ data: [Data]) { self.data = data }
    func fetch(_ request: URLRequest) throws -> Data {
        requests.append(request)
        guard !data.isEmpty else { throw MobileBTError.unavailable }
        return data.removeFirst()
    }
}
