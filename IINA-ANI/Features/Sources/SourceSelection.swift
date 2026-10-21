import Foundation

enum MediaContentKind: String, Codable, CaseIterable, Sendable {
    case anime, video, live, unknown

    var title: String {
        switch self {
        case .anime: return String(localized: "番劇")
        case .video: return String(localized: "一般影片")
        case .live: return String(localized: "直播")
        case .unknown: return String(localized: "待確認")
        }
    }
}

/// Evidence is independent of the immutable source identity and presentation.
struct MediaClassification: Codable, Hashable, Sendable {
    var kind: MediaContentKind
    var provenance: String
    static let unknown = MediaClassification(kind: .unknown, provenance: "unknown")
    static func requiresBangumiLookup(for item: SourceItemRef) -> Bool {
        switch item.sourceID {
        case "didahd", "kanba", "youknow", "rebo": return true
        case "bilibili":
            guard let url = URL(string: item.pageURL), let host = url.host?.lowercased(),
                  host == "bilibili.com" || host.hasSuffix(".bilibili.com") else { return false }
            return url.path.hasPrefix("/bangumi/play/")
        default: return false
        }
    }
}

/// A durable page identity. Resolved media URLs never belong in this value.
struct SourceItemRef: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case work, episode, video, live, local
    }
    let sourceID: String
    let pageURL: String
    let kind: Kind
}

/// Exact native torrent file identity. Hashes are tagged `v1:`/`v2:` and never include trackers.
struct TorrentSelection: Codable, Hashable, Sendable {
    let infoHashes: Set<String>
    let fileIndex: Int
    let path: String
    let size: UInt64

    private enum CodingKeys: String, CodingKey { case infoHashes, fileIndex, path, size }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let hashes = try values.decode(Set<String>.self, forKey: .infoHashes)
        let index = try values.decode(Int.self, forKey: .fileIndex)
        let path = try values.decode(String.self, forKey: .path)
        let size = try values.decode(UInt64.self, forKey: .size)
        guard let validated = Self(infoHashes: hashes, fileIndex: index, path: path, size: size) else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: values, debugDescription: "Invalid torrent file identity")
        }
        self = validated
    }

    init?(identityURL: URL) {
        guard let components = URLComponents(url: identityURL, resolvingAgainstBaseURL: false),
              components.scheme == "iina-torrent", components.host == "file",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil else { return nil }
        let items = components.queryItems ?? []
        guard items.count == 4,
              let hashString = items.first(where: { $0.name == "hash" })?.value,
              let indexString = items.first(where: { $0.name == "index" })?.value,
              let path = items.first(where: { $0.name == "path" })?.value,
              let sizeString = items.first(where: { $0.name == "size" })?.value,
              let index = Int(indexString), index >= 0,
              let size = UInt64(sizeString) else { return nil }
        let pieces = hashString.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let selection = Self(infoHashes: Set(pieces), fileIndex: index, path: path, size: size),
              pieces.count == selection.infoHashes.count,
              selection.identityURL.absoluteString == identityURL.absoluteString else { return nil }
        self = selection
    }

    init?(infoHashes: Set<String>, fileIndex: Int, path: String, size: UInt64) {
        guard !infoHashes.isEmpty, infoHashes.allSatisfy(Self.validHash),
              Set(infoHashes.compactMap { $0.split(separator: ":", omittingEmptySubsequences: false).first }).count == infoHashes.count,
              fileIndex >= 0, Self.safeRelativePath(path) else { return nil }
        self.infoHashes = infoHashes
        self.fileIndex = fileIndex
        self.path = path
        self.size = size
    }

    /// Synthesized decoding cannot be used for this identity; this also supports checking in-memory values.
    var isValid: Bool {
        !infoHashes.isEmpty && infoHashes.allSatisfy(Self.validHash) &&
        Set(infoHashes.compactMap { $0.split(separator: ":", omittingEmptySubsequences: false).first }).count == infoHashes.count &&
        fileIndex >= 0 && Self.safeRelativePath(path)
    }
    var isPlayableMedia: Bool { Self.isPlayablePath(path) }

    static func isPlayablePath(_ path: String) -> Bool {
        ["mp4", "m4v", "mov", "mkv", "webm", "flv"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    var identityURL: URL {
        var components = URLComponents()
        components.scheme = "iina-torrent"
        components.host = "file"
        components.queryItems = [
            URLQueryItem(name: "hash", value: infoHashes.sorted().joined(separator: ",")),
            URLQueryItem(name: "index", value: String(fileIndex)),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "size", value: String(size))
        ]
        return components.url!
    }

    private static func validHash(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let expected = parts[0] == "v1" ? 40 : parts[0] == "v2" ? 64 : 0
        return expected > 0 && parts[1].utf8.count == expected && parts[1].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        guard !value.hasPrefix("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// The original choice, retained independently of an expiring stream URL.
struct PlayableSelection: Codable, Hashable, Sendable {
    var item: SourceItemRef
    var episode: SourceItemRef?
    var lineID: String?
    var qualityID: String?
    var accountID: UUID?
    var torrent: TorrentSelection?
    var classification: MediaClassification

    init(item: SourceItemRef, episode: SourceItemRef? = nil,
         lineID: String? = nil, qualityID: String? = nil, accountID: UUID? = nil,
         torrent: TorrentSelection? = nil, classification: MediaClassification = .unknown) {
        self.item = item
        self.episode = episode
        self.lineID = lineID
        self.qualityID = qualityID
        self.accountID = accountID
        self.torrent = torrent
        self.classification = classification
    }

    private enum CodingKeys: String, CodingKey {
        case item, episode, lineID, qualityID, accountID, torrent, classification
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(SourceItemRef.self, forKey: .item)
        episode = try c.decodeIfPresent(SourceItemRef.self, forKey: .episode)
        lineID = try c.decodeIfPresent(String.self, forKey: .lineID)
        qualityID = try c.decodeIfPresent(String.self, forKey: .qualityID)
        accountID = try c.decodeIfPresent(UUID.self, forKey: .accountID)
        torrent = try c.decodeIfPresent(TorrentSelection.self, forKey: .torrent)
        classification = try c.decodeIfPresent(MediaClassification.self, forKey: .classification) ?? .unknown
    }
}
