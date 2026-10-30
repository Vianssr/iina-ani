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

/// Stable domain identity; neither a display title nor a resolved media URL is an ID.
struct PlaybackWorkIdentity: Codable, Hashable, Sendable {
    let localID: String
    let bangumiID: Int?

    static func bangumi(_ id: Int) -> Self {
        Self(localID: playbackIdentity("bangumi-work", [String(id)]), bangumiID: id)
    }

    /// `workID` is the source's work/season key, not the work's title.
    static func source(sourceID: String, workID: String) -> Self {
        Self(localID: playbackIdentity("source-work", [sourceID, workID]), bangumiID: nil)
    }

    /// For native adapters with an already-canonical, credential-free page reference.
    static func source(_ item: SourceItemRef) -> Self {
        source(sourceID: item.sourceID, workID: item.pageURL)
    }
}

struct PlaybackEpisodeIdentity: Codable, Hashable, Sendable {
    let localID: String
    let bangumiID: Int?
    let type: Int?
    /// The raw Bangumi sort, including fractional values; never a displayed integer.
    let sort: Double?

    static func bangumi(_ id: Int, type: Int?, sort: Double?) -> Self {
        Self(localID: playbackIdentity("bangumi-episode", [String(id)]),
             bangumiID: id, type: type, sort: sort)
    }

    /// Work/season scope is required because episode keys are commonly reused.
    static func source(sourceID: String, workID: String, episodeID: String) -> Self {
        Self(localID: playbackIdentity("source-episode", [sourceID, workID, episodeID]),
             bangumiID: nil, type: nil, sort: nil)
    }

    static func source(work: SourceItemRef, episode: SourceItemRef) -> Self {
        Self(localID: playbackIdentity("source-episode-page",
             [work.sourceID, work.pageURL, episode.sourceID, episode.pageURL]),
             bangumiID: nil, type: nil, sort: nil)
    }
}

/// Durable selection and requested domain identities, independent of expiring playback input.
struct PlaybackContext: Codable, Hashable, Sendable {
    let work: PlaybackWorkIdentity
    let episode: PlaybackEpisodeIdentity
    let selection: PlayableSelection
    let configurationRevision: String?
}

/// A manually confirmed, successfully resolved choice, never the resolved stream itself.
struct ConfirmedSourceMapping: Codable, Hashable, Sendable {
    let context: PlaybackContext
    let sourceTitle: String
    let confirmedAt: Date

    init(context: PlaybackContext, sourceTitle: String, confirmedAt: Date = .now) {
        self.context = context
        self.sourceTitle = sourceTitle
        self.confirmedAt = confirmedAt
    }

    func matches(work: PlaybackWorkIdentity, episode: PlaybackEpisodeIdentity) -> Bool {
        context.work == work && context.episode == episode
    }

    /// The iOS configured-source library boundary also checks callers that bypass
    /// canonicalization. Native desktop adapters retain their own identity validation.
    /// Current configuration authority is deliberately not checked here: invalidated records
    /// remain durable until the user explicitly reconfirms or removes them.
    func validateForPersistence() throws {
        let selection = context.selection
        guard confirmedAt.timeIntervalSinceReferenceDate.isFinite,
              !sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selection.item.kind == .work, let episode = selection.episode, episode.kind == .episode,
              selection.item.sourceID == episode.sourceID,
              !selection.item.sourceID.isEmpty,
              selection.item.sourceID.utf8.count <= 64,
              selection.item.sourceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              selection.accountID == nil, selection.torrent == nil,
              Self.isCanonicalPublicPage(selection.item.pageURL),
              Self.isCanonicalPublicPage(episode.pageURL),
              selection.lineID.map(Self.safeLabel) ?? true,
              selection.qualityID.map(Self.safeLabel) ?? true,
              Self.safeProvenance(selection.classification.provenance),
              let revision = context.configurationRevision, revision.hasPrefix("sha256:"), revision.utf8.count == 71,
              revision.utf8.dropFirst(7).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              Self.validWork(context.work), Self.validEpisode(context.episode) else {
            throw PlaybackFailure.unsupportedResponse
        }
    }

    static func safeIdentityParameter(_ name: String) -> Bool {
        let lower = name.lowercased()
        let compact = lower.filter { $0.isLetter || $0.isNumber }
        return !name.isEmpty && name.utf8.count <= 64 &&
            name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) &&
            !sensitiveIdentityFragments.contains(where: compact.contains) &&
            !lower.hasPrefix("utm_") && !trackingIdentityNames.contains(lower)
    }

    static func isCanonicalPublicPage(_ raw: String) -> Bool {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme, scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty, host == host.lowercased(),
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil, components.url != nil,
              !mediaPageExtensions.contains((components.path as NSString).pathExtension.lowercased()) else { return false }
        let query = components.queryItems ?? []
        guard query.count <= 1, query.allSatisfy({
            safeIdentityParameter($0.name) && $0.value.map({ !$0.isEmpty && !$0.contains("://") &&
                !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) == true
        }) else { return false }
        components.queryItems = query.isEmpty ? nil : query
        return components.string == raw
    }

    static func safeLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("://") &&
            !value.contains(where: { "?&=#@".contains($0) }) &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    // Classification evidence uses assignments (for example, bangumi.subject.type=2),
    // unlike source-owned line/quality labels. It still cannot carry URLs or queries.
    private static func safeProvenance(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("://") &&
            !value.contains(where: { "?&#@".contains($0) }) &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static let sensitiveIdentityFragments = [
        "token", "cookie", "auth", "password", "passwd", "secret", "signature", "credential",
        "session", "apikey", "accesskey", "privatekey", "bearer", "jwt", "csrf", "xsrf", "tracking", "expires"
    ]
    private static let trackingIdentityNames: Set<String> = ["ref", "referer", "referrer", "fbclid", "gclid", "sig", "key"]
    private static let mediaPageExtensions: Set<String> = [
        "m3u8", "mpd", "mp4", "m4v", "mov", "mkv", "webm", "ts", "flv", "mp3", "aac", "torrent"
    ]

    private static func validWork(_ work: PlaybackWorkIdentity) -> Bool {
        if let id = work.bangumiID { return id > 0 && work == .bangumi(id) }
        return validSourceIdentity(work.localID, namespaces: ["source-work"])
    }

    private static func validEpisode(_ episode: PlaybackEpisodeIdentity) -> Bool {
        guard episode.sort.map({ $0.isFinite && $0 >= 0 }) ?? true,
              episode.type.map({ $0 >= 0 }) ?? true else { return false }
        if let id = episode.bangumiID {
            return id > 0 && episode == .bangumi(id, type: episode.type, sort: episode.sort)
        }
        return episode.type == nil && episode.sort == nil &&
            validSourceIdentity(episode.localID, namespaces: ["source-episode", "source-episode-page"])
    }

    private static func validSourceIdentity(_ raw: String, namespaces: [String]) -> Bool {
        guard let namespace = namespaces.first(where: { raw.hasPrefix($0 + ":v1:") }) else { return false }
        var bytes = raw.utf8.dropFirst(namespace.utf8.count + 4)
        var count = 0
        while !bytes.isEmpty {
            guard let colon = bytes.firstIndex(of: 58), colon != bytes.startIndex,
                  let length = Int(String(decoding: bytes[..<colon], as: UTF8.self)), length > 0,
                  String(length).utf8.elementsEqual(bytes[..<colon]) else { return false }
            let start = bytes.index(after: colon)
            guard let end = bytes.index(start, offsetBy: length, limitedBy: bytes.endIndex),
                  let value = String(bytes: bytes[start..<end], encoding: .utf8),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  (value.contains("://") ? isCanonicalPublicPage(value) : !value.contains("?")) else { return false }
            bytes = bytes[end...]
            count += 1
        }
        return count == (namespace == "source-work" ? 2 : namespace == "source-episode" ? 3 : 4)
    }
}

/// Cross-platform failure categories intentionally contain no raw response, URL or credentials.
enum PlaybackFailure: String, Error, Codable, CaseIterable, Sendable {
    case noCandidates, missingEpisode, sourceDisabled, configurationChanged
    case network, unsupportedResponse, authenticationRequired, mediaPlayback, cancelled
}

/// UTF-8 byte-length framing makes arbitrary delimiters and Unicode components unambiguous.
private func playbackIdentity(_ namespace: String, _ components: [String]) -> String {
    namespace + ":v1:" + components.map { "\($0.utf8.count):\($0)" }.joined()
}
