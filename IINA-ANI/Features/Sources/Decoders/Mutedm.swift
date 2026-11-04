import SourceCore
import Foundation
import Alamofire
import SwiftSoup

/// Native macOS adapter; episode identities stay bound to the selected page.
actor Mutedm: SupportSiteProtocol {
    struct Catalog: Sendable {
        let title: String
        let nodes: [VideoTreeNode]
    }
    private func page(_ raw: String) throws -> (id: Int, line: Int?, episode: Int?) {
        guard let c = URLComponents(string: raw), let result = SupportSites.mutedmPage(c) else {
            throw PlaybackFailure.missingEpisode
        }
        return result
    }
    private static func fetch(_ url: String) async throws -> String {
        try Task.checkCancellation()
        let html = try await AccountHTTP.request(url).validate().serializingString().value
        try Task.checkCancellation()
        return html
    }
    static func catalog(_ html: String, id: Int) throws -> Catalog {
        let document = try SwiftSoup.parse(html)
        guard let title = try document.select("h1").first()?.text(), !title.isEmpty else { throw PlaybackFailure.catalogStructure }
        let tabs = try document.select(".module-tab-item").array()
        let panels = try document.select(".module-play-list-content").array()
        guard !panels.isEmpty, tabs.count == panels.count else { throw PlaybackFailure.catalogStructure }
        var nodes: [VideoTreeNode] = [], seen = Set<Int>()
        for (tab, panel) in zip(tabs, panels) {
            let label = try tab.attr("data-dropdown-value")
            var line: Int?, episodes: [VideoTreeNode] = [], episodeIDs = Set<Int>()
            for link in try panel.select("a[href]") {
                guard let url = URL(string: try link.attr("href"), relativeTo: URL(string:"https://www.mutedm.com/")!)?.absoluteURL,
                      let c = URLComponents(url:url, resolvingAgainstBaseURL:false), let item = SupportSites.mutedmPage(c),
                      item.id == id, let number = item.line, let episode = item.episode,
                      line == nil || line == number, episodeIDs.insert(episode).inserted else { throw PlaybackFailure.catalogStructure }
                let name = try link.text()
                guard !name.isEmpty else { continue }
                line = number
                episodes.append(VideoTreeNode(site:.mutedm,index:episode,title:name,id:String(id),url:url.absoluteString))
            }
            guard let line, !episodes.isEmpty, seen.insert(line).inserted else { throw PlaybackFailure.catalogStructure }
            nodes.append(VideoTreeNode(title:label.isEmpty ? "Line \(line)" : label, children:episodes))
        }
        return Catalog(title:title,nodes:nodes)
    }
    private func catalog(_ id: Int) async throws -> Catalog {
        try Self.catalog(await Self.fetch("https://www.mutedm.com/voddetail/\(id).html"), id:id)
    }
    func episodeList(_ raw: String) async throws -> (nodes:[VideoTreeNode],current:Int) {
        let item = try page(raw), data = try await catalog(item.id)
        let leaves = data.nodes.flatMap(\.children)
        let current: Int
        if let line = item.line, let episode = item.episode {
            guard let index = leaves.firstIndex(where: { node in
                guard let c = URLComponents(string:node.url), let p = SupportSites.mutedmPage(c) else { return false }
                return p.line == line && p.episode == episode
            }) else { throw PlaybackFailure.missingEpisode }
            current = index
        } else { current = 0 }
        return (data.nodes,current)
    }
    func liveInfo(_ raw: String) async throws -> any LiveInfo {
        let item = try page(raw), data = try await catalog(item.id)
        return MutedmInfo(title:data.title)
    }
    static func payload(_ html: String, id: Int, line: Int, episode: Int) throws -> [String:Any] {
        let object = try PublicPlayerProtocol.objectLiteral(variable:"player_aaaa",in:html)
        guard let result = try JSONSerialization.jsonObject(with:Data(object.utf8)) as? [String:Any],
              result["id"] as? String == String(id), result["sid"] as? Int == line, result["nid"] as? Int == episode,
              result["points"] as? Int == 0, result["trysee"] as? Int == 0 else { throw PlaybackFailure.missingEpisode }
        // r2.js loads appzx.html: the site explicitly restricts this line to its own app.
        if result["from"] as? String == "r2" { throw PlaybackFailure.appOnlyPlayback }
        guard result["encrypt"] as? Int == 3, result["from"] as? String == "m2" else { throw PlaybackFailure.unsupportedEncryption }
        return result
    }
    func decodeUrl(_ raw: String) async throws -> YouGetJSON {
        let item = try page(raw), data = try await catalog(item.id)
        let leaves = data.nodes.flatMap(\.children)
        let chosen = item.line == nil ? leaves.first : leaves.first { node in
            guard let c = URLComponents(string:node.url), let p = SupportSites.mutedmPage(c) else { return false }
            return p.line == item.line && p.episode == item.episode
        }
        guard let chosen, let c = URLComponents(string:chosen.url), let p = SupportSites.mutedmPage(c),
              let line = p.line, let episode = p.episode else { throw PlaybackFailure.missingEpisode }
        let payload = try Self.payload(await Self.fetch(chosen.url),id:item.id,line:line,episode:episode)
        let media = try await PublicPlayerProtocol.resolveDesktop(payload,page:URL(string:chosen.url)!)
        var result = YouGetJSON(rawUrl:raw)
        result.title = "\(data.title) - \(chosen.title)"
        result.streams["Line \(line)"] = Stream(url:media.absoluteString)
        return result
    }
}
struct MutedmInfo: LiveInfo {
    let title: String
    var name: String { title }
    let cover = "", avatar = ""
    let isLiving = true
    let site: SupportSites = .mutedm
}
