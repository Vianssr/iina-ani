import Foundation
import SourceCore
import CryptoKit

/// Native identities keep adapter-owned metadata; configured sources retain their real rules.
public enum RuntimeSource: Sendable {
    case configured(SourceConfiguration)
    case native(String)

    public var configured: SourceConfiguration? { if case .configured(let value) = self { return value }; return nil }
    public var id: String { switch self { case .configured(let value): return value.id; case .native(let id): return id } }
    private static let nativeNames = ["xifan":"XiFan Anime", "girigiri":"girigiri Anime", "didahd":"Didahd", "jibi":"Jibi Anime", "eacg":"E-ACG", "senfun":"Senfun Anime", "kanba":"Kanba Anime", "haixing":"Haixing Anime", "yinghua":"Yinghua Anime", "dilidili":"Dilidili Anime", "youknow":"YouKnowTV", "hanime1":"Hanime1", "wedm":"wedm", "fengche":"Fengche Anime", "rebo":"Rebo", "mutedm":"Mutedm"]
    private static let animeIDs: Set<String> = ["xifan", "girigiri", "jibi", "eacg", "senfun", "haixing", "yinghua", "dilidili", "wedm", "fengche", "mutedm"]
    public var name: String {
        if let configured { return configured.name }
        return Self.nativeNames[id] ?? id
    }
    public var hosts: [String] { configured?.hosts ?? SupportSites(rawValue: id)?.hosts ?? [] }
    private static let nativeRevisions: [String: String] = Dictionary(uniqueKeysWithValues: SupportSites.nativeSites.map { site in
        let contract = "SourceRuntime:native:\(site.sourceID):desktop-adapter-v1"
        return (site.sourceID, "sha256:" + SHA256.hash(data: Data(contract.utf8)).map { String(format: "%02x", $0) }.joined())
    })
    public var configurationRevision: String { configured?.configurationRevision ?? Self.nativeRevisions[id] ?? "" }
    // Native search is activated only by a separately approved subscription overlay.
    public var search: SourceConfiguration.Search? { configured?.search }
    public var danmaku: SourceConfiguration.Danmaku? { configured?.danmaku }
    public var classification: MediaClassification {
        if let configured { return configured.classification }
        guard Self.animeIDs.contains(id) else { return .unknown }
        return MediaClassification(kind: .anime, provenance: "native-adapter:\(id):content-scope-v1")
    }
    public func effectiveCapabilities(on platform: SourcePlatform) -> Set<SourceCapability> {
        if let configured { return configured.version != 3 ? configured.effectiveCapabilities(on: platform) : [] }
        guard SupportSites.nativeSites.contains(where: { $0.sourceID == id }) else { return [] }
        var result: Set<SourceCapability> = [.information, .resolve, .iina, .mpv, .download]
        if id == "hanime1" { result.insert(.quality) }
        else { result.formUnion([.episodes, .lines]) }
        if search != nil { result.insert(.search) }
        // Native quality is implemented independently of the generic configuration parser.
        if platform == .iOS { result.subtract([.iina, .download]) }
        return result
    }
    private static let builtinCache: Result<[RuntimeSource], Error> = Result {
        guard let resource = Bundle.module.url(forResource: "fqdm", withExtension: "json") else { throw PlaybackFailure.configurationChanged }
        _ = try SourceSubscriptionBaselines.load()
        let configured = try SourceConfiguration.load(fileURL: resource)
        return (SupportSites.nativeSites.map { RuntimeSource.native($0.sourceID) } + [.configured(configured)]).sorted { $0.id < $1.id }
    }
    public static func builtins() throws -> [RuntimeSource] { try builtinCache.get() }

    public func item(_ raw: String) throws -> SourceItemRef {
        if let configured {
            guard configured.version != 3 else { throw PlaybackFailure.unsupportedResponse }
            return try configured.item(raw)
        }
        guard let site = SupportSites(rawValue: id), site != .unsupported,
              var c = URLComponents(string: raw), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.user == nil, c.password == nil, c.port == nil,
              let host = c.host?.lowercased(), site.hosts.contains(host) else { throw PlaybackFailure.missingEpisode }
        c.scheme = c.scheme?.lowercased(); c.host = host; c.fragment = nil
        let kind: SourceItemRef.Kind
        switch site {
        case .xiFan:
            if host == "next.xifanacg.com" {
                guard let route = SupportSites.xiFanNextPage(c) else { throw PlaybackFailure.missingEpisode }
                kind = route.episode == nil ? .work : .episode
            } else { guard let route = SupportSites.xiFanPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode }
        case .girigiri: guard let route = SupportSites.girigiriPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .didahd: guard let route = SupportSites.didahdPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .jibi: guard let route = SupportSites.jibiPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .eacg: guard let route = SupportSites.eacgPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .senfun: guard let route = SupportSites.senfunPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .kanba: guard let route = SupportSites.kanbaPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .haixing: guard let route = SupportSites.haixingPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .yinghua: guard let route = SupportSites.yinghuaPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .dilidili:
            guard let route = SupportSites.dilidiliPage(c) else { throw PlaybackFailure.missingEpisode }
            switch route { case .anime: kind = .work; case .watch: kind = .episode }
        case .youknow: guard let route = SupportSites.youknowPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .hanime1: guard SupportSites.hanime1Page(c) != nil else { throw PlaybackFailure.missingEpisode }; kind = .video
        case .wedm: guard let route = SupportSites.wedmPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .fengche: guard let route = SupportSites.fengchePage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .rebo: guard let route = SupportSites.reboPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .mutedm: guard let route = SupportSites.mutedmPage(c) else { throw PlaybackFailure.missingEpisode }; kind = route.episode == nil ? .work : .episode
        case .unsupported: throw PlaybackFailure.missingEpisode
        }
        guard let page = c.string else { throw PlaybackFailure.missingEpisode }
        return SourceItemRef(sourceID: id, pageURL: page, kind: kind)
    }

    public func mappingSelection(_ selection: PlayableSelection) throws -> PlayableSelection {
        if let configured {
            guard configured.version != 3 else { throw PlaybackFailure.unsupportedResponse }
            return try configured.mappingSelection(selection)
        }
        guard selection.item.sourceID == id, selection.torrent == nil,
              (selection.episode ?? selection.item).kind == (id == "hanime1" ? .video : .episode) else { throw PlaybackFailure.missingEpisode }
        func canonical(_ ref: SourceItemRef) throws -> SourceItemRef {
            guard ref.sourceID == id, var page = URLComponents(string: ref.pageURL),
                  !["mp4", "m3u8", "mpd", "mkv", "torrent"].contains(URL(string: ref.pageURL)?.pathExtension.lowercased() ?? "") else { throw PlaybackFailure.missingEpisode }
            // Next XiFan's source query is an exact line identity, unlike incidental page queries.
            if id != "hanime1" && !(id == "xifan" && page.host?.lowercased() == "next.xifanacg.com") { page.query = nil }
            page.fragment = nil
            guard let raw = page.string else { throw PlaybackFailure.missingEpisode }
            return try item(raw)
        }
        var safe = selection
        safe.accountID = nil
        safe.item = try canonical(selection.item)
        guard safe.item.kind == selection.item.kind else { throw PlaybackFailure.missingEpisode }
        if let episode = selection.episode {
            let exact = try canonical(episode)
            guard exact.kind == (id == "hanime1" ? .video : .episode) else { throw PlaybackFailure.missingEpisode }
            safe.episode = exact
            if id == "hanime1", exact != safe.item { throw PlaybackFailure.missingEpisode }
        }
        return safe
    }
}
