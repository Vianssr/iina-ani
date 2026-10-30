//
//  VideoDecoder.swift
//  iina+
//
//  Created by xjbeta on 2018/10/28.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa
import Alamofire
import Marshal
import CommonCrypto
import JavaScriptCore
import SwiftSoup

actor VideoDecoder {
    nonisolated let registry: SourceRegistry
    nonisolated let accounts: SiteAccounts
    nonisolated private let sourceEnabledPolicy: @Sendable (String) -> Bool
    nonisolated private let localEndpoint: @Sendable () async throws -> HTTPServerEndpoint

    init(registry: SourceRegistry = .shared, accounts: SiteAccounts = .shared,
         sourceEnabled: @escaping @Sendable (String) -> Bool = { Preferences.shared.isSourceEnabled($0) },
         localEndpoint: @escaping @Sendable () async throws -> HTTPServerEndpoint = { throw VideoGetError.notSupported }) {
        self.registry = registry
        self.accounts = accounts
        self.sourceEnabledPolicy = sourceEnabled
        self.localEndpoint = localEndpoint
    }
    private struct NativeCatalogResult {
        let nodes: [VideoTreeNode]
        let current: Int
        let selection: PlayableSelection?
    }
    private typealias NativeCatalogLoader = (String) async throws -> NativeCatalogResult?
    private var nativeCatalogLoaders: [String: NativeCatalogLoader] = [:]
    private var nativeAdapters: [SupportSites: any SupportSiteProtocol] = [:]

    private func registerNativeCatalogLoaders() {
        guard nativeCatalogLoaders.isEmpty else { return }
        nativeCatalogLoaders = [
            "bilibili": { [bilibili] str in
                guard let bURL = BilibiliUrl(url: str) else { return nil }
                switch bURL.urlType {
                case .video:
                    let catalog = try await bilibili.video.getVideoList(str)
                    return NativeCatalogResult(nodes: catalog.nodes, current: catalog.current, selection: nil)
                case .bangumi:
                    let list = try await bilibili.bangumi.getBangumiList(str)
                    let leaves = list.epVideoSelectors
                    let current = try bURL.episodeIndex(in: leaves)
                    return NativeCatalogResult(nodes: [VideoTreeNode(title: "", children: leaves)], current: current,
                                               selection: nil)
                case .unknown:
                    throw VideoGetError.invalidLink
                }
            },
            "douyu": { [douyu] str in
                guard let url = URL(string: str), url.pathComponents.count > 2,
                      url.pathComponents[1] == "topic" else { return nil }
                do {
                    let html = try await douyu.getDouyuHtml(str)
                    guard !html.roomIds.isEmpty else { return nil }
                    let names = try await douyu.getDouyuEventRoomNames(html.pageId)
                    let status = try await douyu.getDouyuEventRoomOnlineStatus(html.pageId)
                    let leaves = names.enumerated().map {
                        VideoTreeNode(site: .douyu, index: $0.offset, title: $0.element.text,
                            id: $0.element.roomId, url: "https://www.douyu.com/\($0.element.roomId)",
                            isLiving: status[$0.element.roomId] ?? false)
                    }
                    let current = leaves.firstIndex(where: { $0.id == html.roomId }) ?? 0
                    return NativeCatalogResult(nodes: [VideoTreeNode(title: "", children: leaves)], current: current, selection: nil)
                } catch VideoGetError.douyuNotFoundSubRooms { return nil }
            },
            "xifan": { [xiFan] str in let list = try await xiFan.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "girigiri": { [girigiri] str in let list = try await girigiri.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "didahd": { [didahd] str in let list = try await didahd.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "jibi": { [jibi] str in let list = try await jibi.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "eacg": { [eacg] str in let list = try await eacg.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "senfun": { [senfun] str in let list = try await senfun.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "kanba": { [kanba] str in let list = try await kanba.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "haixing": { [haixing] str in let list = try await haixing.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "yinghua": { [yinghua] str in let list = try await yinghua.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "dilidili": { [dilidili] str in let list = try await dilidili.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "youknow": { [youknow] str in let list = try await youknow.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "wedm": { [wedm] str in let list = try await wedm.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "fengche": { [fengche] str in let list = try await fengche.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "rebo": { [rebo] str in let list = try await rebo.episodeList(str); return NativeCatalogResult(nodes: list.nodes, current: list.current, selection: nil) },
            "huya": { [huya] str in
                let rooms = try await huya.getHuyaRoomList(str)
                return NativeCatalogResult(nodes: [VideoTreeNode(title: "", children: rooms.list)],
                    current: rooms.list.firstIndex(where: { $0.id == rooms.current }) ?? 0, selection: nil)
            },
            "bilibili-live": { [bilibili] str in
                let rooms = try await bilibili.live.getRoomList(str)
                let current = URL(string: str)?.lastPathComponent ?? ""
                return NativeCatalogResult(nodes: [VideoTreeNode(title: "", children: rooms.1)],
                    current: rooms.1.firstIndex(where: { $0.id == current }) ?? 0, selection: nil)
            },
            "cc163": { [cc163, weak self] str in
                guard let self else { throw CancellationError() }
                let state = try await cc163.getCC163State(str)
                let rooms = state.list.enumerated().map {
                    VideoTreeNode(site: .cc163, index: $0.offset, title: $0.element.name,
                        id: "\($0.element.ccid)", url: $0.element.channel, isLiving: $0.element.isLiving)
                }
                let choiceURL: String?
                if let info = state.info as? CC163Info { choiceURL = "https://cc.163.com/ccid/\(info.ccid)" }
                else if let info = state.info as? CC163ChannelInfo { choiceURL = "https://cc.163.com/ccid/\(info.ccid)" }
                else { choiceURL = nil }
                let choice: PlayableSelection?
                if let choiceURL { choice = try await self.selection(for: choiceURL) }
                else { choice = nil }
                return NativeCatalogResult(nodes: [VideoTreeNode(title: "", children: rooms)], current: 0, selection: choice)
            }
        ]
    }

    private func registerNativeAdapters() async {
        guard nativeAdapters.isEmpty else { return }
        nativeAdapters = [
            .bilibili: await bilibili.video,
            .bangumi: await bilibili.bangumi,
            .biliLive: await bilibili.live,
            .douyu: douyu,
            .huya: huya,
            .cc163: cc163,
            .douyin: douyin,
            .qieTV: qieTV,
            .xiFan: xiFan,
            .girigiri: girigiri,
            .didahd: didahd,
            .jibi: jibi,
            .eacg: eacg,
            .senfun: senfun,
            .kanba: kanba,
            .haixing: haixing,
            .yinghua: yinghua,
            .dilidili: dilidili,
            .youknow: youknow,
            .hanime1: hanime1,
            .wedm: wedm,
            .fengche: fengche,
            .rebo: rebo
        ]
    }

    private func configuredAdapter(_ id: String) throws -> ConfiguredSource {
        guard let configuration = registry.source(for: id),
              sourceEnabledPolicy(id) else { throw VideoGetError.notSupported }
        return ConfiguredSource(configuration: configuration, site: .configured(id))
    }

    private func nativeAdapter(for site: SupportSites) async throws -> any SupportSiteProtocol {
        await registerNativeAdapters()
        guard registry.descriptor(for: site.sourceID) != nil,
              sourceEnabledPolicy(site.sourceID),
              let adapter = nativeAdapters[site] else { throw VideoGetError.notSupported }
        return adapter
    }

    lazy var douyin = DouYin()
    lazy var huya = Huya(localEndpoint: localEndpoint)
    lazy var douyu = Douyu()
    lazy var cc163 = CC163()
    let bilibili = Bilibili.shared
    lazy var qieTV = QieTV()
    lazy var xiFan = XiFan()
    lazy var girigiri = Girigiri()
    lazy var didahd = Didahd(localEndpoint: localEndpoint)
    lazy var jibi = Jibi()
    lazy var eacg = EACG()
    lazy var senfun = Senfun()
    lazy var kanba = Kanba()
    lazy var haixing = Haixing()
    lazy var yinghua = Yinghua()
    lazy var dilidili = Dilidili()
    lazy var youknow = Youknow()
    lazy var hanime1 = Hanime1()
    lazy var wedm = Wedm()
    lazy var fengche = Fengche()
    lazy var rebo = Rebo()
	
    nonisolated func isSourceEnabled(_ sourceID: String) -> Bool { sourceEnabledPolicy(sourceID) }
    nonisolated func episodeIdentity(_ leaf: VideoTreeNode) throws -> String { try registry.episodeIdentity(for: leaf) }

    nonisolated func mappingRevision(_ id: String) throws -> String {
        guard sourceEnabledPolicy(id) else { throw PlaybackFailure.sourceDisabled }
        let snapshot = registry.snapshot
        guard snapshot.descriptors.contains(where: { $0.id == id }) else { throw PlaybackFailure.configurationChanged }
        if snapshot.configurations[id] != nil, snapshot.loadError != nil {
            throw PlaybackFailure.configurationChanged
        }
        return snapshot.configurations[id]?.configurationRevision ?? "native-adapter:\(id):mapping-v1"
    }

    /// Synchronous registry authority, also used immediately before persisting or handing off playback.
    nonisolated func mappingSelection(_ selection: PlayableSelection) throws
        -> (selection: PlayableSelection, revision: String, configured: Bool) {
        let id = selection.item.sourceID
        guard sourceEnabledPolicy(id) else { throw PlaybackFailure.sourceDisabled }
        let snapshot = registry.snapshot
        guard snapshot.descriptors.contains(where: { $0.id == id }) else { throw PlaybackFailure.configurationChanged }
        if let configuration = snapshot.configurations[id] {
            guard snapshot.loadError == nil else { throw PlaybackFailure.configurationChanged }
            return (try configuration.mappingSelection(selection), configuration.configurationRevision, true)
        }
        guard selection.torrent == nil, selection.classification.kind == .anime,
              (selection.episode ?? selection.item).kind == .episode else { throw PlaybackFailure.missingEpisode }
        func canonical(_ ref: SourceItemRef) throws -> SourceItemRef {
            guard var page = URLComponents(string: ref.pageURL), page.user == nil, page.password == nil,
                  ["https", "http"].contains(page.scheme?.lowercased() ?? ""),
                  !["mp4", "m3u8", "mpd", "mkv", "torrent"].contains(URL(string: ref.pageURL)?.pathExtension.lowercased() ?? "") else {
                throw PlaybackFailure.missingEpisode
            }
            // Bilibili's canonicalizer owns its p identity. Other supported anime adapters use path IDs.
            if id != "bilibili" { page.query = nil }
            page.fragment = nil
            guard let raw = page.string else { throw PlaybackFailure.missingEpisode }
            return try registry.item(for: raw)
        }
        var safe = selection
        safe.accountID = nil
        let work = try canonical(selection.item)
        guard work.sourceID == id, work.kind == selection.item.kind else { throw PlaybackFailure.missingEpisode }
        safe.item = work
        if let episode = selection.episode {
            let exact = try canonical(episode)
            guard exact.sourceID == id, exact.kind == .episode else { throw PlaybackFailure.missingEpisode }
            safe.episode = exact
        }
        return (safe, "native-adapter:\(id):mapping-v1", false)
    }

    func sourceDescriptors() -> [SourceDescriptor] { registry.snapshot.descriptors }
    var sourceRegistryLoadError: String? { registry.loadError }

    func searchSource(sourceID: String, query: String, page: Int, classifyWithBangumi: Bool) async throws -> SourceSearchPage {
        guard sourceEnabledPolicy(sourceID),
              registry.descriptor(for: sourceID)?.capabilities.contains(.search) == true else {
            throw VideoGetError.notSupported
        }
        try Task.checkCancellation()
        if !SourceSubscriptionConverter.managedSourceIDs.contains(sourceID),
           let configuration = registry.source(for: sourceID), registry.subscriptionSearch(for: sourceID) == nil {
            guard configuration.capabilities.contains(.search) else { throw VideoGetError.notSupported }
            return try await ConfiguredSource(configuration: configuration, site: .configured(sourceID))
                .search(query: query, page: page)
        }
        guard let source = registry.nativeSearch(for: sourceID) else { throw VideoGetError.notSupported }
        let result = try await SourceSearchExecutor.search(query: query, page: page, spec: source.search,
            allowedHosts: Set(source.hosts.map { $0.lowercased() }), resultURLTemplate: source.resultURLTemplate,
            classification: { registry.classification(for: $0) }) { raw in
                try? registry.item(for: raw)
            }
        guard classifyWithBangumi, result.results.contains(where: { MediaClassification.requiresBangumiLookup(for: $0.item) }) else { return result }
        var results: [SourceSearchResult] = []
        results.reserveCapacity(result.results.count)
        for entry in result.results {
            try Task.checkCancellation()
            let classification = MediaClassification.requiresBangumiLookup(for: entry.item)
                ? try await BangumiService.shared.classifyMedia(title: entry.title) : entry.classification
            results.append(SourceSearchResult(item: entry.item, title: entry.title, cover: entry.cover, classification: classification))
        }
        return SourceSearchPage(results: results, nextPage: result.nextPage)
    }


    /// Public anime workflows never inherit a caller account or consult source defaults.
    func guestSelection(for url: String) async throws -> PlayableSelection {
        try Task.checkCancellation()
        let site = registry.matchingSite(url)
        guard site != .unsupported else { throw VideoGetError.notSupported }
        return try await AccountHTTP.$context.withValue(nil) {
            try await self.accounts.withSource(sourceID: site.sourceID, useDefaultAccount: false) {
                try await self.selection(for: url)
            }
        }
    }

    func selection(for url: String) async throws -> PlayableSelection {
        try Task.checkCancellation()
        guard let input = URL(string: url) else { throw VideoGetError.invalidLink }
        if input.isFileURL {
            guard sourceEnabledPolicy("local") else { throw SiteAccountError.disabled }
            return PlayableSelection(item: SourceItemRef(sourceID: "local",
                pageURL: input.standardizedFileURL.absoluteString, kind: .local))
        }
        let initialSite = registry.matchingSite(url)
        guard initialSite != .unsupported else { throw VideoGetError.notSupported }
        guard sourceEnabledPolicy(initialSite.sourceID) else { throw SiteAccountError.disabled }
        let formatted: String
        if initialSite == .b23 {
            formatted = try await accounts.withSource(sourceID: initialSite.sourceID) {
                try await self.resolveBilibiliShortLink(url)
            }
        } else {
            formatted = url
        }
        try Task.checkCancellation()
        let item = try registry.item(for: formatted)
        let site = registry.matchingSite(item.pageURL)
        guard sourceEnabledPolicy(item.sourceID) else { throw SiteAccountError.disabled }
        let accountID: UUID?
        if let context = AccountHTTP.context,
           SiteAccounts.canonicalSource(context.sourceID) == SiteAccounts.canonicalSource(site.sourceID) {
            accountID = context.accountID
        } else {
            accountID = try await accounts.defaultAccount(sourceID: site.sourceID)?.id
        }
        var classification = registry.classification(for: item)
        if MediaClassification.requiresBangumiLookup(for: item) {
            do {
                let title = try await AccountHTTP.$context.withValue(nil) {
                    try await self.accounts.withSource(sourceID: item.sourceID, useDefaultAccount: false) {
                        if site == .bangumi {
                            return try await self.bilibili.bangumi.classificationTitle(item.pageURL)
                        }
                        return try await self.liveInfoInScope(item.pageURL, true).title
                    }
                }
                classification = try await BangumiService.shared.classifyMedia(title: title)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                classification = MediaClassification(kind: .unknown, provenance: "bangumi.lookup.source-title-unavailable")
            }
        }
        return PlayableSelection(item: item, accountID: accountID, classification: classification)
    }

    func resolve(_ selection: PlayableSelection) async throws -> YouGetJSON {
        try Task.checkCancellation()
        let ref = selection.episode ?? selection.item
        guard ref.sourceID == selection.item.sourceID else { throw VideoGetError.invalidLink }
        guard sourceEnabledPolicy(ref.sourceID) else { throw SiteAccountError.disabled }
        if ref.kind == .local {
            guard selection.accountID == nil else { throw SiteAccountError.invalidAccount }
            return try await resolveInScope(selection)
        }
        let pinned = selection
        return try await accounts.withSource(sourceID: ref.sourceID, accountID: pinned.accountID,
                                             useDefaultAccount: false) {
            try await self.resolveInScope(pinned)
        }
    }

    private func resolveInScope(_ selection: PlayableSelection) async throws -> YouGetJSON {
        try Task.checkCancellation()
        let ref = selection.episode ?? selection.item
        let normalized = try await self.selection(for: ref.pageURL)
        guard normalized.item.sourceID == ref.sourceID,
              ref.sourceID == selection.item.sourceID else { throw VideoGetError.invalidLink }
        var result: YouGetJSON
        if ref.kind == .local, normalized.item.kind == .local {
            result = YouGetJSON(url: normalized.item.pageURL)
            result.site = .local
            result.rawUrl = normalized.item.pageURL
            result.title = URL(string: normalized.item.pageURL)?.lastPathComponent ?? ""
        } else {
            guard normalized.item.kind != .local else { throw VideoGetError.invalidLink }
            result = try await decodeSourceURL(normalized.item.pageURL)
        }
        try Task.checkCancellation()
        var original = selection
        if original.classification.kind == .unknown, original.classification.provenance != "manual" {
            original.classification = normalized.classification
        }
        if original.episode != nil { original.episode = normalized.item }
        else { original.item = normalized.item }
        result.selection = original
        if let key = original.qualityID {
            result = try await prepareVideoUrl(result, key)
        } else if original.lineID != nil, let key = result.videos.first?.key {
            result = try await prepareVideoUrl(result, key)
        }
        try Task.checkCancellation()
        return result
    }

    func inspect(_ url: String, directly: Bool = false) async throws -> VideoInspection {
        let choice = try await selection(for: url)
        return try await inspect(choice, directly: directly)
    }

    func inspect(_ choice: PlayableSelection, directly: Bool = false) async throws -> VideoInspection {
        try Task.checkCancellation()
        if choice.item.kind == .local {
            guard choice.accountID == nil else { throw SiteAccountError.invalidAccount }
            return try await inspectInScope(choice, directly: directly)
        }
        return try await accounts.withSource(sourceID: choice.item.sourceID, accountID: choice.accountID,
                                             useDefaultAccount: false) {
            try await self.inspectInScope(choice, directly: directly)
        }
    }

    private func inspectInScope(_ selection: PlayableSelection, directly: Bool) async throws -> VideoInspection {
        var choice = selection
        if !directly, let catalog = try await catalogInScope(for: choice) {
            try Task.checkCancellation()
            let leaves = catalog.nodes.flattened.flatMap { $0.children.filter(\.isLeaf) }
            if leaves.count > 1 { return .selection(catalog) }
            if registry.matchingSite(choice.item.pageURL) != .cc163,
               let leaf = leaves.first, !leaf.selectionURL.isEmpty {
                choice.episode = try await self.selection(for: leaf.selectionURL).item
            } else {
                choice = catalog.selection
            }
        }
        try Task.checkCancellation()
        let page = (choice.episode ?? choice.item).pageURL
        if choice.item.kind != .local {
            let info = try await liveInfo(page, false)
            try Task.checkCancellation()
            guard info.isLiving else { throw VideoGetError.isNotLiving }
        }
        return .playable(try await resolve(choice))
    }

    func catalog(for selection: PlayableSelection) async throws -> VideoSelectionCatalog? {
        try Task.checkCancellation()
        if selection.item.kind == .local {
            guard selection.accountID == nil else { throw SiteAccountError.invalidAccount }
            return try await catalogInScope(for: selection)
        }
        return try await accounts.withSource(sourceID: selection.item.sourceID,
            accountID: selection.accountID, useDefaultAccount: false) {
            try await self.catalogInScope(for: selection)
        }
    }

    private func catalogInScope(for selection: PlayableSelection) async throws -> VideoSelectionCatalog? {
        let str = selection.item.pageURL
        guard URL(string: str) != nil else { throw VideoGetError.invalidLink }
        let site = registry.matchingSite(str)
        guard site != .unsupported else { throw VideoGetError.notSupported }
        guard site.sourceID == selection.item.sourceID else { throw VideoGetError.invalidLink }
        guard sourceEnabledPolicy(site.sourceID) else { throw SiteAccountError.disabled }
        if case .configured(let id) = site {
            guard let configuration = registry.source(for: id),
                  configuration.capabilities.contains(.episodes) else { return nil }
            let list = try await configuredAdapter(id).episodeList(str)
            return VideoSelectionCatalog(nodes: list.nodes, current: list.current, selection: selection)
        }
        guard let descriptor = registry.descriptor(for: site.sourceID),
              descriptor.capabilities.contains(.episodes) else { return nil }
        registerNativeCatalogLoaders()
        guard let loader = nativeCatalogLoaders[site.sourceID], let list = try await loader(str) else { return nil }
        try Task.checkCancellation()
        var choice = list.selection ?? selection
        if selection.classification.kind != .unknown || selection.classification.provenance == "manual" {
            choice.classification = selection.classification
        }
        return VideoSelectionCatalog(nodes: list.nodes, current: list.current, selection: choice)
    }


    private func resolveBilibiliShortLink(_ url: String) async throws -> String {
        let response = await AccountHTTP.request(url).serializingData().response
        guard let redirected = response.response?.url?.absoluteString,
              let item = try? registry.item(for: redirected),
              item.pageURL.hasPrefix("https://www.bilibili.com/") else { throw VideoGetError.invalidLink }
        return item.pageURL
    }
    
    private func decodeSourceURL(_ url: String) async throws -> YouGetJSON {
        let site = registry.matchingSite(url)
        if case .configured(let id) = site {
            return try await configuredAdapter(id).decodeUrl(url)
        }
        return try await nativeAdapter(for: site).decodeUrl(url)
    }
    
    func liveInfo(_ url: String, _ checkSupport: Bool = true) async throws -> LiveInfo {
        let site = registry.matchingSite(url)
        if site != .unsupported {
            guard sourceEnabledPolicy(site.sourceID) else { throw SiteAccountError.disabled }
            if site == .local { throw VideoGetError.notSupported }
        }
        if site == .unsupported {
             return try await liveInfoInScope(url, checkSupport)
         }
        return try await accounts.withSource(sourceID: site.sourceID) {
            try await self.liveInfoInScope(url, checkSupport)
        }
    }

    private func liveInfoInScope(_ url: String, _ checkSupport: Bool) async throws -> LiveInfo {
        let site = registry.matchingSite(url)
        if case .configured(let id) = site {
            return try await configuredAdapter(id).liveInfo(url)
        }
        if site == .local { throw VideoGetError.notSupported }
        if site == .unsupported { throw VideoGetError.notSupported }
        return try await nativeAdapter(for: site).liveInfo(url)
    }
	
    
    func prepareVideoUrl(_ json: YouGetJSON, _ key: String) async throws -> YouGetJSON {
        let site = registry.matchingSite(json.rawUrl)
        let sourceID = json.selection?.item.sourceID ?? site.sourceID
        guard registry.descriptor(for: sourceID) != nil else { throw VideoGetError.notSupported }
        guard sourceEnabledPolicy(sourceID) else { throw SiteAccountError.disabled }
        if json.site == .local || site == .unsupported {
            return try await prepareVideoUrlInScope(json, key)
        }
        return try await accounts.withSource(sourceID: sourceID, accountID: json.selection?.accountID,
                                                       useDefaultAccount: json.selection == nil) {
            try await self.prepareVideoUrlInScope(json, key)
        }
    }

    private func prepareVideoUrlInScope(_ json: YouGetJSON, _ key: String) async throws -> YouGetJSON {
        try Task.checkCancellation()
        guard json.streams[key] != nil else { throw VideoGetError.notFountData }
        var result = try await prepareStream(json, key)
        try Task.checkCancellation()
        result.selection = json.selection
        result.selection?.qualityID = key
        if let lineID = result.selection?.lineID {
            guard let line = Int(lineID), line >= 0,
                  let stream = result.streams[key], line <= stream.src.count,
                  line == 0 || stream.url?.isEmpty == false else { throw VideoGetError.notFountData }
        }
        return result
    }


    private func prepareStream(_ json: YouGetJSON, _ key: String) async throws -> YouGetJSON {
        let sourceID = json.selection?.item.sourceID ?? registry.matchingSite(json.rawUrl).sourceID
        guard registry.descriptor(for: sourceID) != nil else { throw VideoGetError.notSupported }
        guard sourceEnabledPolicy(sourceID) else { throw SiteAccountError.disabled }
        guard json.id != -1 else { return json }
        switch sourceID {
        case "bilibili":
			guard let stream = json.streams[key],
				  stream.url == "" else {
				return json
			}
			
			let qn = stream.quality
            let json = try await Bilibili.shared.bilibiliPlayUrl(yougetJson: json, json.site == .bangumi, qn)
			return json
        case "bilibili-live":
			guard let stream = json.streams[key],
				  stream.quality != -1 else {
				return json
			}
			let qn = stream.quality
			
			if let url = stream.url,
			   url != "" {
				return json
			} else {
				var re = try await bilibili.live.getBiliLiveJSON(json, qn, with: .roomPlayInfo)
				
				func results() -> YouGetJSON? {
					if let stream = re.streams[key],
					   let url = stream.url,
					   url != "" {
						return re
					} else {
						return nil
					}
				}
				
				if let re = results() {
					return re
				}
				
				re = try await bilibili.live.getBiliLiveJSON(json, qn, with: .playUrl)
				
				if let re = results() {
					return re
				}
				
				throw VideoGetError.needLogin
			}
        case "douyu":
			guard let stream = json.streams[key],
				  stream.quality != -1 else {
				return json
			}
			let rate = stream.rate
			if stream.url != "" {
				return json
			} else {
				let id = json.id
				let html = try await douyu.getDouyuHtml("https://www.douyu.com/\(id)")
				let urls = try await douyu.getDouyuUrl(id, rate: rate)
				let url = urls.first {
					$0.1.rate == rate
				}?.1.url
				var re = json
				re.streams[key]?.url = url
				return re
			}
		default:
			return json
		}
	}
}



extension VideoDecoder {
    
    // MARK: - Bilibili Danmaku
    func downloadDMFile(_ cid: Int, id: String) async throws {
        try await accounts.withSource(sourceID: "bilibili") {
            let data = try await AccountHTTP.request("https://comment.bilibili.com/\(cid).xml").serializingData().value
            VideoDecoder.saveDMFile(data, with: id)
        }
    }
    
    
    func downloadDMFileV2(cid: Int, length: Int, id: String,
                          selection: PlayableSelection? = nil) async throws {
        try await accounts.withSource(sourceID: selection?.item.sourceID ?? "bilibili",
                                                 accountID: selection?.accountID,
                                                 useDefaultAccount: selection == nil) {
            try await self.downloadDMFileV2InScope(cid: cid, length: length, id: id)
        }
    }

    private func downloadDMFileV2InScope(cid: Int, length: Int, id: String) async throws {
        
//        segment_index  6min
        
        let c = Int(ceil(Double(length) / 360))
        let s = c > 1 ? Array(1...c) : [1]
        
        print("downloadDMFileV2", c)
        
        guard c < 1500 else {
            return
        }
		
		let dms = try await withThrowingTaskGroup(of: [DanmakuElem].self) { group in
			for i in s {
				group.addTask {
					try await self.getDanmakuContent(cid: cid, index: i)
				}
			}
			
			var re = [DanmakuElem]()
			
			for try await e in group {
				re.append(contentsOf: e)
			}
			
			return re
		}
		
		let element = try XMLElement(xmlString: #"<?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.tv</chatserver><chatid>170102</chatid></i>"#)
		
		let doc = XMLDocument(rootElement: element)
		
		dms.map { dm -> String in
			let s1 = ["\(Double(dm.progress) / 1000)",
					  "\(dm.mode)",
					  "\(dm.fontsize)",
					  "\(dm.color)",
					  "\(dm.ctime)",
					  "\(dm.pool)",
					  "\(dm.midHash)",
					  "\(dm.id)"].joined(separator: ",")
			var s2 = dm.content
			
			s2 = s2.replacingOccurrences(of: "<", with: "&lt;")
			s2 = s2.replacingOccurrences(of: ">", with: "&gt;")
			s2 = s2.replacingOccurrences(of: "&", with: "&amp;")
			s2 = s2.replacingOccurrences(of: "'", with: "&apos;")
			s2 = s2.replacingOccurrences(of: "\"", with: "&quot;")
			
			s2 = s2.replacingOccurrences(of: "`", with: "&apos;")
			
			return "<d p=\"\(s1)\">\(s2)</d>"
		}.forEach {
			if let node = try? XMLElement(xmlString: $0) {
				element.addChild(node)
			} else {
				Log("Invalid Bangumi Line: \($0)")
			}
		}
		
		VideoDecoder.saveDMFile(doc.xmlData, with: id)
    }
    
    static func saveDMFile(_ data: Data?, with id: String) {
		guard let path = VideoDecoder.dmPath(id) else { return }
        var p = path
        p.deleteLastPathComponent()
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
        Log("Saved DM in \(path)")
    }
    
    static func dmPath(_ id: String) -> String? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
            var filesURL = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let folderName = "WebFiles"
        
        filesURL.appendPathComponent(bundleIdentifier)
        filesURL.appendPathComponent(folderName)
        let fileName = "danmaku" + "-" + id + ".xml"
        
        filesURL.appendPathComponent(fileName)
        return filesURL.path
    }
    
    func getDanmakuContent(cid: Int, index: Int) async throws -> [DanmakuElem] {
		let u = "https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid=\(cid)&segment_index=\(index)"
		
        let data = try await AccountHTTP.request(u).serializingData().value
		return try DmSegMobileReply(serializedBytes: data).elems
    }
}

enum VideoGetError: Error {
    case invalidLink
    
    case douyuUrlError
    case douyuSignError
    case douyuNotFoundRoomId
    case douyuNotFoundSubRooms
    case douyuRoomIdsCountError
    
    case isNotLiving
    case notFindUrls
    case notSupported
    
    case cantFindIdForDM
    
    case prepareDMFailed
    
    case cantWatch
    case notFountData
    case needVip
	case needLogin
    case needPassWork
}
