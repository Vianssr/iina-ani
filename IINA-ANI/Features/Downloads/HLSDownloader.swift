import Foundation

/// Downloads finite HLS assets sequentially. FFmpeg alone demuxes/decrypts/remuxes media.
enum HLSDownloader {
    struct Downloaded: Sendable {
        let playlist: URL
        let progress: DownloadTransferProgress
    }
    private struct Loaded {
        let text: String
        let url: URL
    }
    private struct Key: Equatable {
        let url: URL
        let iv: String?
    }
    private struct Map: Equatable {
        let url: URL
        let range: DownloadByteRange?
        let key: Key?
    }
    private struct Segment {
        let url: URL
        let range: DownloadByteRange?
        let duration: String
        let key: Key?
        let map: Map?
        let discontinuity: Bool
    }
    private struct Media {
        let segments: [Segment]
        let sequence: UInt64
        let targetDuration: Int
    }
    private struct Variant: Equatable, Codable {
        let bandwidth: Int64
        let resolution: String?
        let codecs: String?
        let audioGroup: String?
    }
    private struct Chosen {
        let video: Loaded
        let audio: Loaded?
    }

    static func executable() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func download(resource: DownloadResource, directory: URL,
                         progress: @escaping DownloadProgressHandler) async throws -> Downloaded {
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let identityFile = directory.appendingPathComponent("variants.json")
        let pinned: [Variant]
        if manager.fileExists(atPath: identityFile.path) {
            pinned = try JSONDecoder().decode([Variant].self, from: Data(contentsOf: identityFile))
        } else { pinned = [] }
        // HLS never splices uncertain partial segments; only the rendition choice survives.
        for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file != identityFile {
            try manager.removeItem(at: file)
        }
        progress(.init(bytes: 0, totalBytes: nil, completedSegments: 0, totalSegments: nil,
                       restartReason: String(localized: "HLS 恢復時重新下載全部分段；保持原集數、來源品質及已選主清單變體。")))
        var identities: [Variant] = []
        let initial = try await load(resource, url: resource.url, directory: directory)
        let chosen = try await select(initial, resource: resource, directory: directory,
                                      pinned: pinned, identities: &identities, depth: 0)
        if !pinned.isEmpty, identities != pinned { throw DownloadFailure.invalidSelection }
        try privateWrite(JSONEncoder().encode(identities), to: identityFile)
        let video = try parse(chosen.video)
        let audio = try chosen.audio.map(parse)
        let count = video.segments.count + (audio?.segments.count ?? 0)
        var bytes: Int64 = 0
        let videoFile = try await materialize(video, prefix: "video", resource: resource, directory: directory,
                                             priorBytes: bytes, priorSegments: 0, totalSegments: count, progress: progress)
        bytes += videoFile.bytes
        guard let audio else {
            return Downloaded(playlist: videoFile.playlist, progress: .init(bytes: bytes, totalBytes: nil, completedSegments: count, totalSegments: count))
        }
        let audioFile = try await materialize(audio, prefix: "audio", resource: resource, directory: directory,
                                             priorBytes: bytes, priorSegments: video.segments.count,
                                             totalSegments: count, progress: progress)
        bytes += audioFile.bytes
        let master = directory.appendingPathComponent("local.m3u8")
        let text = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="audio",DEFAULT=YES,AUTOSELECT=YES,URI="\(audioFile.playlist.lastPathComponent)"
        #EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="audio"
        \(videoFile.playlist.lastPathComponent)

        """
        try privateWrite(Data(text.utf8), to: master)
        return Downloaded(playlist: master, progress: .init(bytes: bytes, totalBytes: nil, completedSegments: count, totalSegments: count))
    }

    static func finalize(playlist: URL, directory: URL, ffmpegURL: URL?) async throws -> URL {
        guard let tool = ffmpegURL ?? executable() else { throw DownloadFailure.mediaToolMissing }
        let output = directory.appendingPathComponent("video.mkv")
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        try await run(tool, arguments: ["-nostdin", "-v", "error", "-xerror", "-n",
            "-protocol_whitelist", "file,crypto,data", "-allowed_extensions", "ALL", "-i", playlist.path,
            "-map", "0:v?", "-map", "0:a?", "-c", "copy", "-f", "matroska", output.path])
        do {
            // Probe a decoded frame, not just an exit code from an empty stream-copy operation.
            try await run(tool, arguments: ["-nostdin", "-v", "error", "-xerror", "-i", output.path,
                "-t", "1", "-f", "null", "-"])
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    private static func run(_ tool: URL, arguments: [String]) async throws {
        let result: (Int32, DownloadFailure?) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // Foundation termination delivery is tied to the launching thread/run loop.
                // Launch, drain and wait on the same utility thread, never a Swift actor thread.
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                let errors = Pipe()
                process.standardError = errors
                do { try process.run() } catch { continuation.resume(throwing: DownloadFailure.finalization); return }
                var failure: DownloadFailure?, tail = ""
                while let data = try? errors.fileHandleForReading.read(upToCount: 4_096), !data.isEmpty {
                    let text = tail + String(decoding: data, as: UTF8.self)
                    if text.contains("No space left on device") { failure = .diskFull }
                    else if text.contains("Permission denied") || text.contains("Read-only file system") { failure = .directoryNotWritable }
                    tail = String(text.suffix(64))
                }
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, failure))
            }
        }
        guard result.0 == 0 else { throw result.1 ?? DownloadFailure.finalization }
    }

    private static func load(_ resource: DownloadResource, url: URL, directory: URL) async throws -> Loaded {
        let file = directory.appendingPathComponent("manifest-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: file) }
        let response = try await DirectDownloader.download(resource: replacing(resource, url: url), destination: file,
                                                           resume: false, progress: { _ in })
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1_024 * 1_024 else { throw DownloadFailure.invalidResponse }
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        guard text.hasPrefix("#EXTM3U") else { throw DownloadFailure.invalidResponse }
        return Loaded(text: text, url: response.responseURL)
    }

    private static func select(_ manifest: Loaded, resource: DownloadResource, directory: URL,
                               pinned: [Variant], identities: inout [Variant], depth: Int) async throws -> Chosen {
        guard depth < 5 else { throw DownloadFailure.unsupportedMedia }
        let lines = manifest.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) else {
            return Chosen(video: manifest, audio: nil)
        }
        for line in lines where line.hasPrefix("#EXT-X-SESSION-KEY:") {
            let key = attributes(String(line.dropFirst("#EXT-X-SESSION-KEY:".count)))
            guard key["METHOD"] == "AES-128", key["KEYFORMAT"] == nil || key["KEYFORMAT"] == "identity" else { throw DownloadFailure.protectedMedia }
        }
        var variants: [(identity: Variant, url: URL)] = []
        var pending: [String: String]?
        let renditions = lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") }
            .map { attributes(String($0.dropFirst("#EXT-X-MEDIA:".count))) }
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if !line.isEmpty, !line.hasPrefix("#"), let attrs = pending {
                guard let bandwidth = attrs["BANDWIDTH"].flatMap(Int64.init), bandwidth > 0 else { throw DownloadFailure.invalidResponse }
                let variant = Variant(bandwidth: bandwidth, resolution: attrs["RESOLUTION"], codecs: attrs["CODECS"], audioGroup: attrs["AUDIO"])
                variants.append((variant, try resolve(line, base: manifest.url)))
                pending = nil
            }
        }
        let selected: (identity: Variant, url: URL)
        if depth < pinned.count {
            guard let match = variants.first(where: { $0.identity == pinned[depth] }) else { throw DownloadFailure.invalidSelection }
            selected = match
        } else {
            // Only on first creation: deterministic highest declared bandwidth, no failover.
            guard let highest = variants.max(by: { $0.identity.bandwidth < $1.identity.bandwidth }) else { throw DownloadFailure.invalidResponse }
            selected = highest
        }
        identities.append(selected.identity)
        let child = try await load(resource, url: selected.url, directory: directory)
        let nested = try await select(child, resource: resource, directory: directory,
                                      pinned: pinned, identities: &identities, depth: depth + 1)
        var audio = nested.audio
        if let group = selected.identity.audioGroup {
            let candidates = renditions.filter { $0["TYPE"] == "AUDIO" && $0["GROUP-ID"] == group }
            guard let rendition = candidates.first(where: { $0["DEFAULT"] == "YES" }) ??
                    candidates.first(where: { $0["AUTOSELECT"] == "YES" }) ?? candidates.first else { throw DownloadFailure.invalidResponse }
            if let uri = rendition["URI"] {
                audio = try await load(resource, url: resolve(uri, base: manifest.url), directory: directory)
            }
        }
        return Chosen(video: nested.video, audio: audio)
    }

    private static func parse(_ manifest: Loaded) throws -> Media {
        let lines = manifest.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.contains("#EXT-X-ENDLIST") else { throw DownloadFailure.liveHLS }
        var sequence: UInt64 = 0, target = 1
        var segments: [Segment] = [], currentKey: Key?, currentMap: Map?
        var duration: String?, rawRange: String?, discontinuity = false
        var previousSegment: (url: URL, end: Int64)?, previousMap: (url: URL, end: Int64)?
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard let value = UInt64(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) else { throw DownloadFailure.invalidResponse }
                sequence = value
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                guard let value = Int(line.dropFirst("#EXT-X-TARGETDURATION:".count)), value > 0 else { throw DownloadFailure.invalidResponse }
                target = value
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                if attrs["METHOD"] == "NONE" { currentKey = nil; continue }
                guard attrs["METHOD"] == "AES-128", let uri = attrs["URI"],
                      attrs["KEYFORMAT"] == nil || attrs["KEYFORMAT"] == "identity" else { throw DownloadFailure.protectedMedia }
                currentKey = Key(url: try resolve(uri, base: manifest.url), iv: try normalizeIV(attrs["IV"]))
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uri = attrs["URI"] else { throw DownloadFailure.invalidResponse }
                if currentKey != nil, currentKey?.iv == nil { throw DownloadFailure.invalidResponse }
                let url = try resolve(uri, base: manifest.url)
                let range = try byteRange(attrs["BYTERANGE"], url: url, previous: previousMap)
                previousMap = range.map { (url, $0.offset + $0.length) }
                currentMap = Map(url: url, range: range, key: currentKey)
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                rawRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if line.hasPrefix("#EXTINF:") {
                let raw = String(line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? "")
                guard let seconds = Double(raw), seconds.isFinite, seconds > 0 else { throw DownloadFailure.invalidResponse }
                duration = raw
            } else if line == "#EXT-X-DISCONTINUITY" {
                discontinuity = true
            } else if line.contains("SAMPLE-AES") {
                throw DownloadFailure.protectedMedia
            } else if line.hasPrefix("#EXT-X-PART") || line.hasPrefix("#EXT-X-SERVER-CONTROL") || line.hasPrefix("#EXT-X-I-FRAMES-ONLY") || line.hasPrefix("#EXT-X-GAP") {
                throw DownloadFailure.unsupportedMedia
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard let duration, sequence <= UInt64.max - UInt64(segments.count) else { throw DownloadFailure.invalidResponse }
                let url = try resolve(line, base: manifest.url)
                let range = try byteRange(rawRange, url: url, previous: previousSegment)
                previousSegment = range.map { (url, $0.offset + $0.length) }
                segments.append(Segment(url: url, range: range, duration: duration, key: currentKey,
                                        map: currentMap, discontinuity: discontinuity))
                rawRange = nil
                discontinuity = false
            }
            if !line.isEmpty, !line.hasPrefix("#") { duration = nil }
        }
        guard !segments.isEmpty else { throw DownloadFailure.invalidResponse }
        return Media(segments: segments, sequence: sequence, targetDuration: target)
    }

    private static func materialize(_ media: Media, prefix: String, resource: DownloadResource, directory: URL,
                                    priorBytes: Int64, priorSegments: Int, totalSegments: Int,
                                    progress: @escaping DownloadProgressHandler) async throws -> (playlist: URL, bytes: Int64) {
        var local = "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:\(media.targetDuration)\n#EXT-X-MEDIA-SEQUENCE:0\n"
        var keyFiles: [URL: String] = [:], maps: [(map: Map, file: String)] = []
        var bytes: Int64 = 0, previousMap: Map?
        func keyLine(_ key: Key?, sequence: UInt64) -> String {
            guard let key, let file = keyFiles[key.url] else { return "#EXT-X-KEY:METHOD=NONE\n" }
            let iv = key.iv ?? String(format: "%032llx", sequence)
            return "#EXT-X-KEY:METHOD=AES-128,URI=\"\(file)\",IV=0x\(iv)\n"
        }
        for (index, segment) in media.segments.enumerated() {
            try Task.checkCancellation()
            for key in [segment.map?.key, segment.key].compactMap({ $0 }) where keyFiles[key.url] == nil {
                let name = "\(prefix)-key-\(keyFiles.count).bin"
                let destination = directory.appendingPathComponent(name)
                _ = try await DirectDownloader.download(resource: replacing(resource, url: key.url), destination: destination,
                                                        resume: false, progress: { _ in })
                guard try fileSize(destination) == 16 else { throw DownloadFailure.protectedMedia }
                bytes += 16
                keyFiles[key.url] = name
            }
            if segment.discontinuity { local += "#EXT-X-DISCONTINUITY\n" }
            if let map = segment.map, map != previousMap {
                let name: String
                if let cached = maps.first(where: { $0.map == map }) { name = cached.file }
                else {
                    name = "\(prefix)-map-\(maps.count).mp4"
                    let file = directory.appendingPathComponent(name)
                    _ = try await DirectDownloader.download(resource: replacing(resource, url: map.url), destination: file,
                                                            resume: false, byteRange: map.range, progress: { _ in })
                    bytes += try fileSize(file)
                    maps.append((map, name))
                }
                local += keyLine(map.key, sequence: 0)
                local += "#EXT-X-MAP:URI=\"\(name)\"\n"
                previousMap = map
            }
            local += keyLine(segment.key, sequence: media.sequence + UInt64(index))
            let file = directory.appendingPathComponent("\(prefix)-segment-\(index)." + (segment.map == nil ? "ts" : "m4s"))
            let prior = priorBytes + bytes
            _ = try await DirectDownloader.download(resource: replacing(resource, url: segment.url), destination: file,
                                                    resume: false, byteRange: segment.range) { update in
                progress(.init(bytes: prior + update.bytes, totalBytes: nil,
                               completedSegments: priorSegments + index, totalSegments: totalSegments))
            }
            bytes += try fileSize(file)
            local += "#EXTINF:\(segment.duration),\n\(file.lastPathComponent)\n"
            progress(.init(bytes: priorBytes + bytes, totalBytes: nil,
                           completedSegments: priorSegments + index + 1, totalSegments: totalSegments))
        }
        local += "#EXT-X-ENDLIST\n"
        let file = directory.appendingPathComponent("\(prefix)-local.m3u8")
        try privateWrite(Data(local.utf8), to: file)
        return (file, bytes)
    }

    private static func resolve(_ raw: String, base: URL) throws -> URL {
        guard let url = URL(string: raw, relativeTo: base)?.absoluteURL, url.user == nil, url.password == nil else {
            throw DownloadFailure.invalidResponse
        }
        return url
    }
    private static func replacing(_ resource: DownloadResource, url: URL) -> DownloadResource {
        DownloadResource(url: url, format: resource.format, context: resource.context, fileExtension: resource.fileExtension)
    }
    private static func attributes(_ input: String) -> [String: String] {
        var result: [String: String] = [:], key = "", value = "", quoted = false
        func save() { if !key.isEmpty { result[key] = value.trimmingCharacters(in: .whitespaces); key = ""; value = "" } }
        for character in input {
            if character == "\"" { quoted.toggle(); continue }
            if character == ",", !quoted { save(); continue }
            if character == "=", key.isEmpty { key = value.trimmingCharacters(in: .whitespaces); value = ""; continue }
            value.append(character)
        }
        save()
        return result
    }
    private static func byteRange(_ raw: String?, url: URL, previous: (url: URL, end: Int64)?) throws -> DownloadByteRange? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let length = Int64(parts[0]), length > 0 else { throw DownloadFailure.invalidResponse }
        let offset: Int64
        if parts.count == 2 {
            guard let parsed = Int64(parts[1]) else { throw DownloadFailure.invalidResponse }
            offset = parsed
        } else {
            guard let previous, previous.url == url else { throw DownloadFailure.invalidResponse }
            offset = previous.end
        }
        guard offset >= 0, offset <= Int64.max - length else { throw DownloadFailure.invalidResponse }
        return DownloadByteRange(offset: offset, length: length)
    }
    private static func normalizeIV(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let hex = raw.lowercased().hasPrefix("0x") ? String(raw.dropFirst(2)) : raw
        guard !hex.isEmpty, hex.count <= 32, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw DownloadFailure.invalidResponse }
        return String(repeating: "0", count: 32 - hex.count) + hex.lowercased()
    }
    private static func fileSize(_ file: URL) throws -> Int64 {
        ((try FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
    private static func privateWrite(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
