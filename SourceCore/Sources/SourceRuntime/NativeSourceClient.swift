import Foundation
import SourceCore

/// Desktop native adapters run with invocation-scoped anonymous or explicitly injected HTTP.
public struct NativeSourceClient: Sendable {
    public let sourceID: String
    private let fetch: SourceHTTPTransport.Fetch?
    private let decoder: (any SupportSiteProtocol)?
    public init(sourceID: String, fetch: SourceHTTPTransport.Fetch? = nil) {
        self.sourceID = sourceID
        self.fetch = fetch
        self.decoder = Self.makeAdapter(sourceID)
    }

    private func adapter() throws -> any SupportSiteProtocol {
        guard let decoder else { throw PlaybackFailure.unsupportedResponse }
        return decoder
    }
    private static func makeAdapter(_ sourceID: String) -> (any SupportSiteProtocol)? {
        switch sourceID {
        case "xifan": return XiFan()
        case "girigiri": return Girigiri()
        case "didahd": return Didahd()
        case "jibi": return Jibi()
        case "eacg": return EACG()
        case "senfun": return Senfun()
        case "kanba": return Kanba()
        case "haixing": return Haixing()
        case "yinghua": return Yinghua()
        case "dilidili": return Dilidili()
        case "youknow": return Youknow()
        case "hanime1": return Hanime1()
        case "wedm": return Wedm()
        case "fengche": return Fengche()
        case "rebo": return Rebo()
        case "mutedm": return Mutedm()
        default: return nil
        }
    }
    private func nodes(_ adapter: any SupportSiteProtocol, page: String) async throws -> [VideoTreeNode] {
        switch adapter {
        case let a as XiFan: return try await a.episodeList(page).nodes
        case let a as Girigiri: return try await a.episodeList(page).nodes
        case let a as Didahd: return try await a.episodeList(page).nodes
        case let a as Jibi: return try await a.episodeList(page).nodes
        case let a as EACG: return try await a.episodeList(page).nodes
        case let a as Senfun: return try await a.episodeList(page).nodes
        case let a as Kanba: return try await a.episodeList(page).nodes
        case let a as Haixing: return try await a.episodeList(page).nodes
        case let a as Yinghua: return try await a.episodeList(page).nodes
        case let a as Dilidili: return try await a.episodeList(page).nodes
        case let a as Youknow: return try await a.episodeList(page).nodes
        case let a as Wedm: return try await a.episodeList(page).nodes
        case let a as Fengche: return try await a.episodeList(page).nodes
        case let a as Rebo: return try await a.episodeList(page).nodes
        case let a as Mutedm: return try await a.episodeList(page).nodes
        default: throw PlaybackFailure.catalogStructure
        }
    }
    public func catalog(_ work: RuntimeWork) async throws -> RuntimeCatalog {
        try await AccountHTTP.$currentFetch.withValue(fetch) {
            try Task.checkCancellation()
            let source = RuntimeSource.native(sourceID)
            guard work.item.sourceID == sourceID, try source.item(work.item.pageURL) == work.item else { throw PlaybackFailure.missingEpisode }
            let decoder = try adapter()
            let info = try await decoder.liveInfo(work.item.pageURL)
            let canonical = RuntimeWork(item: work.item, title: info.title)
            if sourceID == "hanime1" {
                let media = try await decoder.decodeUrl(work.item.pageURL)
                let episodes = media.videos.map { entry in
                    RuntimeEpisode(item: work.item, title: entry.key, line: 0, number: 1,
                        identity: "\(sourceID):video:\(work.item.pageURL)", qualityID: entry.key)
                }
                guard !episodes.isEmpty else { throw PlaybackFailure.missingMediaQuality }
                return RuntimeCatalog(work: canonical, lines: [RuntimeLine(id: 0, title: info.title, episodes: episodes)])
            }
            let tree = try await nodes(decoder, page: work.item.pageURL)
            var lines: [RuntimeLine] = []
            for (offset, group) in tree.enumerated() {
                let leaves = group.isLeaf ? [group] : group.children
                guard !leaves.isEmpty else { throw PlaybackFailure.catalogStructure }
                let line = routeLine(leaves[0].url) ?? offset + 1
                let title = group.isLeaf ? "Line \(line)" : group.title
                let episodes = try leaves.map { leaf -> RuntimeEpisode in
                    let item = try source.item(leaf.selectionURL)
                    guard leaf.site.sourceID == sourceID, routeLine(leaf.url).map({ $0 == line }) ?? true else { throw PlaybackFailure.catalogStructure }
                    let key: String?
                    if sourceID == "senfun" || sourceID == "dilidili" { key = nil }
                    else if sourceID == "mutedm" { key = "Line \(line)" }
                    else if sourceID == "haixing" || (sourceID == "xifan" && URL(string: item.pageURL)?.host == "next.xifanacg.com") { key = title }
                    else { key = "\(title) (\(line))" }
                    return RuntimeEpisode(item: item, title: leaf.title, line: line, number: leaf.index,
                        identity: identity(leaf, item: item), qualityID: key)
                }
                lines.append(RuntimeLine(id: line, title: title, episodes: episodes))
            }
            try Task.checkCancellation()
            guard !lines.isEmpty else { throw PlaybackFailure.catalogStructure }
            return RuntimeCatalog(work: canonical, lines: lines)
        }
    }
    /// Dynamic public playback lines are queried only for the episode the user selected.
    public func playbackOptions(_ episode: RuntimeEpisode, in catalog: RuntimeCatalog) async throws -> [RuntimeEpisode] {
        try await AccountHTTP.$currentFetch.withValue(fetch) {
            try validate(episode, in: catalog)
            guard sourceID == "senfun" || sourceID == "dilidili" else { return [episode] }
            let media = try await adapter().decodeUrl(episode.item.pageURL)
            return media.videos.map { entry in
                RuntimeEpisode(item: episode.item, title: entry.key, line: episode.line, number: episode.number,
                    identity: episode.identity, mediaPath: episode.mediaPath, qualityID: entry.key)
            }
        }
    }
    public func resolve(_ episode: RuntimeEpisode, in catalog: RuntimeCatalog) async throws -> URL {
        try await AccountHTTP.$currentFetch.withValue(fetch) {
            try Task.checkCancellation()
            try validate(episode, in: catalog)
            guard let key = episode.qualityID else { throw PlaybackFailure.missingMediaQuality }
            let media = try await adapter().decodeUrl(episode.item.pageURL)
            guard let stream = media.streams[key], let raw = stream.url,
                  let url = URL(string: raw) else { throw PlaybackFailure.missingMediaQuality }
            if sourceID == "didahd", await DidahdProxy.shared.ownsPlaylist(url) { return url }
            guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
                  url.port == nil else { throw PlaybackFailure.unsafeMediaAddress }
            try Task.checkCancellation()
            return url
        }
    }
    private func validate(_ episode: RuntimeEpisode, in catalog: RuntimeCatalog) throws {
        let source = RuntimeSource.native(sourceID)
        let dynamic = sourceID == "senfun" || sourceID == "dilidili"
        guard catalog.work.item.sourceID == sourceID, episode.item.sourceID == sourceID,
              try source.item(catalog.work.item.pageURL) == catalog.work.item,
              try source.item(episode.item.pageURL) == episode.item,
              catalog.lines.contains(where: { line in
                  line.id == episode.line && line.episodes.contains(where: { candidate in
                      if !dynamic { return candidate == episode }
                      return candidate.item == episode.item && candidate.line == episode.line &&
                          candidate.number == episode.number && candidate.identity == episode.identity &&
                          candidate.mediaPath == episode.mediaPath
                  })
              }) else { throw PlaybackFailure.missingEpisode }
    }
    private func identity(_ leaf: VideoTreeNode, item: SourceItemRef) -> String {
        if sourceID == "dilidili" { return "\(sourceID):\(item.kind.rawValue):\(item.pageURL)" }
        if sourceID == "xifan", URL(string: item.pageURL)?.host == "next.xifanacg.com" {
            return "\(sourceID):\(leaf.id):\(leaf.index):\(URLComponents(string: item.pageURL)?.query ?? "")"
        }
        return "\(sourceID):\(leaf.id):\(leaf.index)"
    }
    private func routeLine(_ raw: String) -> Int? {
        guard let c = URLComponents(string: raw) else { return nil }
        switch sourceID {
        case "xifan": return SupportSites.xiFanPage(c)?.line
        case "girigiri": return SupportSites.girigiriPage(c)?.line
        case "didahd": return SupportSites.didahdPage(c)?.line
        case "jibi": return SupportSites.jibiPage(c)?.line
        case "eacg": return SupportSites.eacgPage(c)?.line
        case "kanba": return SupportSites.kanbaPage(c)?.line
        case "haixing": return SupportSites.haixingPage(c)?.line
        case "yinghua": return SupportSites.yinghuaPage(c)?.line
        case "youknow": return SupportSites.youknowPage(c)?.line
        case "wedm": return SupportSites.wedmPage(c)?.line
        case "fengche": return SupportSites.fengchePage(c)?.line
        case "rebo": return SupportSites.reboPage(c)?.line
        case "mutedm": return SupportSites.mutedmPage(c)?.line
        default: return nil
        }
    }
}
