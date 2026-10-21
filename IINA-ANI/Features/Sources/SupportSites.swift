//
//  SupportSites.swift
//  IINA+
//
//  Created by xjbeta on 11/15/21.
//  Copyright © 2021 xjbeta. All rights reserved.
//

import Cocoa

enum SupportSites: Hashable, Sendable {
    case b23
    case biliLive
    case bilibili
    case bangumi
    case douyu
    case huya
    case cc163
    case douyin
    case qieTV
    case xiFan
    case girigiri
    case didahd
    case jibi
    case eacg
    case senfun
    case kanba
    case haixing
    case yinghua
    case dilidili
    case youknow
    case hanime1
    case wedm
    case fengche
    case rebo
    case local
    case configured(String)
    case unsupported

    private static let siteHosts: [SupportSites: [String]] = [
        .b23: [
            "b23.tv"
        ],
        .biliLive: [
            "live.bilibili.com"
        ],
        .bangumi: [
            "www.bilibili.com",
            "bilibili.com"
        ],
        .bilibili: [
            "www.bilibili.com",
            "bilibili.com"
        ],
        .douyu: [
            "www.douyu.com",
            "douyu.com"
        ],
        .huya: [
            "www.huya.com",
            "huya.com"
        ],
        .cc163: [
            "cc.163.com",
            "ds.163.com"
        ],
        .douyin: [
            "live.douyin.com",
            "www.douyin.com",
            "douyin.com"
        ],
        .qieTV: [
            "www.qie.tv",
            "qie.tv",
            "live.qq.com"
        ],
        .xiFan: [
            "dm1.xfdm.pro"
        ],
        .girigiri: [
            "ani.girigirilove.com"
        ],
        .didahd: [
            "www.didahd.pro", "didahd.pro", "www.didahd.xyz", "didahd.xyz"
        ],
        .jibi: [
            "www.jibi.cc", "jibi.cc"
        ],
        .eacg: [
            "www.eacg1.com", "eacg1.com"
        ],
        .senfun: [
            "senfun.in"
        ],
        .kanba: [
            "11kt.net", "www.11kt.net", "qkan8.com", "www.qkan8.com"
        ],
        .haixing: [
            "www.haixingdmx.com", "haixingdmx.com"
        ],
        .yinghua: [
            "www.yinghuabb.com", "yinghuabb.com", "www.yinghuaaa.com", "yinghuaaa.com", "www.yinghua2.com", "yinghua2.com"
        ],
        .dilidili: [
            "dilidili.io", "www.dilidili.io"
        ],
        .youknow: ["www.youknow.tv", "youknow.tv"],
        .hanime1: ["hanime1.me", "www.hanime1.me"],
        .wedm: ["www.vdm5.com", "vdm5.com"],
        .fengche: ["www.dongmandaquan.vip", "dongmandaquan.vip"],
        .rebo: ["www.rebozj.cc", "rebozj.cc", "www.rebozj.pro", "rebozj.pro"],
    ]

    static let nativeSites: [SupportSites] = [.bilibili, .b23, .biliLive, .bangumi, .douyu, .huya, .cc163, .douyin, .qieTV, .xiFan, .girigiri, .didahd, .jibi, .eacg, .senfun, .kanba, .haixing, .yinghua, .dilidili, .youknow, .hanime1, .wedm, .fengche, .rebo, .local]

    var hosts: [String] {
        if case .configured(let id) = self { return SourceRegistry.shared.source(for: id)?.hosts ?? [] }
        return SupportSites.siteHosts[self] ?? []
    }
    /// Persisted identifiers, independent of localized names and host aliases.
    var sourceID: String {
        switch self {
        case .b23, .bilibili, .bangumi: return "bilibili"
        case .biliLive: return "bilibili-live"
        case .douyu: return "douyu"
        case .huya: return "huya"
        case .cc163: return "cc163"
        case .douyin: return "douyin"
        case .qieTV: return "qie-tv"
        case .xiFan: return "xifan"
        case .girigiri: return "girigiri"
        case .didahd: return "didahd"
        case .jibi: return "jibi"
        case .eacg: return "eacg"
        case .senfun: return "senfun"
        case .kanba: return "kanba"
        case .haixing: return "haixing"
        case .yinghua: return "yinghua"
        case .dilidili: return "dilidili"
        case .youknow: return "youknow"
        case .hanime1: return "hanime1"
        case .wedm: return "wedm"
        case .fengche: return "fengche"
        case .rebo: return "rebo"
        case .local: return "local"
        case .configured(let id): return id
        case .unsupported: return "unsupported"
        }
    }

    var isConfigured: Bool {
        if case .configured = self { return true }
        return false
    }

    init(url: String) {
        self = SourceRegistry.shared.matchingSite(url)
    }

    static func nativeSite(url: String) -> SupportSites {
        SupportSites(nativeURL: url)
    }

    private init(nativeURL url: String) {
        guard url != "",
              var comps = URLComponents(string: url),
              let host = comps.host else {
            self = .unsupported
            return
        }

        comps.host = SupportSites.canonicalHost(host)


        let normalizedURL = comps.url?.absoluteString ?? url
        let normalizedHost = comps.host ?? host

        if normalizedHost.lowercased() == "dm1.xfdm.pro" {
            self = SupportSites.xiFanPage(comps) == nil ? .unsupported : .xiFan
            return
        }

        if normalizedHost.lowercased() == "ani.girigirilove.com" {
            self = SupportSites.girigiriPage(comps) == nil ? .unsupported : .girigiri
            return
        }
        if SupportSites.siteHosts[.didahd]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.didahdPage(comps) == nil ? .unsupported : .didahd
            return
        }
        if SupportSites.siteHosts[.jibi]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.jibiPage(comps) == nil ? .unsupported : .jibi
            return
        }
        if SupportSites.siteHosts[.eacg]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.eacgPage(comps) == nil ? .unsupported : .eacg
            return
        }
        if SupportSites.siteHosts[.senfun]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.senfunPage(comps) == nil ? .unsupported : .senfun
            return
        }
        if SupportSites.siteHosts[.kanba]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.kanbaPage(comps) == nil ? .unsupported : .kanba
            return
        }
        if SupportSites.siteHosts[.haixing]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.haixingPage(comps) == nil ? .unsupported : .haixing
            return
        }
        if SupportSites.siteHosts[.yinghua]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.yinghuaPage(comps) == nil ? .unsupported : .yinghua
            return
        }

        if SupportSites.siteHosts[.dilidili]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.dilidiliPage(comps) == nil ? .unsupported : .dilidili
            return
        }
        if SupportSites.siteHosts[.youknow]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.youknowPage(comps) == nil ? .unsupported : .youknow
            return
        }
        if SupportSites.siteHosts[.hanime1]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.hanime1Page(comps) == nil ? .unsupported : .hanime1
            return
        }
        if SupportSites.siteHosts[.wedm]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.wedmPage(comps) == nil ? .unsupported : .wedm
            return
        }
        if SupportSites.siteHosts[.fengche]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.fengchePage(comps) == nil ? .unsupported : .fengche
            return
        }
        if SupportSites.siteHosts[.rebo]?.contains(normalizedHost.lowercased()) == true {
            self = SupportSites.reboPage(comps) == nil ? .unsupported : .rebo
            return
        }

        if normalizedHost == "www.douyin.com" {
            let pathParts = comps.path.split(separator: "/").map(String.init)
            guard pathParts.count >= 2,
                  pathParts[0] == "live",
                  let rid = Int(pathParts[1]) else {
                self = .unsupported
                return
            }
            self = SupportSites(nativeURL: "https://live.douyin.com/\(rid)")
            return
        }

        if let bUrl = BilibiliUrl(url: normalizedURL) {
            switch bUrl.urlType {
            case .video:
                self = .bilibili
            case .bangumi:
                self = .bangumi
            default:
                self = .unsupported
            }
        } else {
            self = SupportSites(host: normalizedHost) ?? .unsupported
        }
	}

	var siteName: String {
		// Auto-generate with `bartycrouch update`
		switch self {
		case .biliLive:
			return NSLocalizedString("SupportSites.Bilibili Live", comment: "Bilibili Live")
		case .bilibili:
			return NSLocalizedString("SupportSites.Bilibili", comment: "Bilibili")
		case .bangumi:
			return NSLocalizedString("SupportSites.Bilibili Bangumi", comment: "Bilibili Bangumi")
		case .douyu:
			return NSLocalizedString("SupportSites.Douyu", comment: "Douyu")
		case .huya:
			return NSLocalizedString("SupportSites.Huya", comment: "Huya")
		case .cc163:
			return NSLocalizedString("SupportSites.CC163", comment: "CC163")
		case .douyin:
			return NSLocalizedString("SupportSites.DouYin", comment: "DouYin")
		case .qieTV:
			return NSLocalizedString("SupportSites.QieTV", comment: "QieTV")
		case .xiFan:
			return NSLocalizedString("SupportSites.XiFan", comment: "XiFan Anime")
		case .girigiri:
			return NSLocalizedString("SupportSites.Girigiri", comment: "girigiri Anime")
		case .didahd:
			return NSLocalizedString("SupportSites.Didahd", comment: "Didahd")
		case .jibi:
			return NSLocalizedString("SupportSites.Jibi", comment: "Jibi Anime")
        case .eacg:
            return NSLocalizedString("SupportSites.EACG", comment: "E-ACG")
        case .senfun:
            return NSLocalizedString("SupportSites.Senfun", comment: "Senfun Anime")
        case .kanba:
            return NSLocalizedString("SupportSites.Kanba", comment: "Kanba Anime")
        case .haixing:
            return NSLocalizedString("SupportSites.Haixing", comment: "Haixing Anime")
        case .yinghua:
            return NSLocalizedString("SupportSites.Yinghua", comment: "Yinghua Anime")
        case .dilidili:
            return NSLocalizedString("SupportSites.Dilidili", comment: "Dilidili Anime")
        case .youknow:
            return NSLocalizedString("SupportSites.Youknow", comment: "YouKnowTV")
        case .hanime1:
            return NSLocalizedString("SupportSites.Hanime1", comment: "Hanime1")
        case .wedm:
            return NSLocalizedString("SupportSites.Wedm", comment: "wedm")
        case .fengche:
            return NSLocalizedString("SupportSites.Fengche", comment: "Fengche Anime")
        case .rebo:
            return NSLocalizedString("SupportSites.Rebo", comment: "Rebo")
        case .configured(let id):
            return SourceRegistry.shared.source(for: id)?.name ?? id
		case .unsupported:
			return NSLocalizedString("SupportSites.Unsupported", comment: "Unsupported")
		case .b23, .local:
			return ""
		}
	}

    func supportWebPlayer() -> Bool {
        switch self {
        case .biliLive, .douyu, .huya, .cc163, .douyin, .qieTV:
            return true
        default:
            return false
        }
    }

	var urlFilterPredicate: String {
		switch self {
		case .bilibili:
			return "url CONTAINS 'bilibili.com/video/'"
		case .bangumi:
			return "url CONTAINS 'bilibili.com/bangumi/'"
		case .xiFan:
			return "url BEGINSWITH[c] 'https://dm1.xfdm.pro/watch/' || url BEGINSWITH[c] 'https://dm1.xfdm.pro/bangumi/' || url BEGINSWITH[c] 'http://dm1.xfdm.pro/watch/' || url BEGINSWITH[c] 'http://dm1.xfdm.pro/bangumi/'"
		case .girigiri:
			return "url BEGINSWITH[c] 'https://ani.girigirilove.com/GV' || url BEGINSWITH[c] 'https://ani.girigirilove.com/playGV' || url BEGINSWITH[c] 'http://ani.girigirilove.com/GV' || url BEGINSWITH[c] 'http://ani.girigirilove.com/playGV'"
		case .didahd:
			return ["www.didahd.pro", "didahd.pro", "www.didahd.xyz", "didahd.xyz"].flatMap { host in
				["http", "https"].flatMap { scheme in
					["detail", "play"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/\($0)/'" }
				}
			}.joined(separator: " || ")
		case .jibi:
			return ["www.jibi.cc", "jibi.cc"].flatMap { host in
				["http", "https"].flatMap { scheme in
					["detail", "play"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/index.php/vod/\($0)/id/'" }
				}
			}.joined(separator: " || ")
        case .eacg:
            return hosts.flatMap { host in
                ["http", "https"].flatMap { scheme in
                    ["voddetails-", "Comicplay/", "voddetail/", "vodplay/"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/\($0)'" }
                }
            }.joined(separator: " || ")
        case .senfun:
            return hosts.flatMap { host in
                ["http", "https"].flatMap { scheme in
                    ["voddetail", "vodwatch"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/\($0)/'" }
                }
            }.joined(separator: " || ")
        case .kanba:
            return hosts.flatMap { host in
                ["http", "https"].flatMap { scheme in
                    ["index.php/vod/detail/id/", "index.php/vod/play/id/"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/\($0)'" }
                }
            }.joined(separator: " || ")
        case .haixing:
            return hosts.flatMap { host in
                ["http", "https"].flatMap { scheme in
                    ["view/", "play/"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/\($0)'" }
                }
            }.joined(separator: " || ")
        case .yinghua:
            return hosts.flatMap { host in
                ["http", "https"].flatMap { scheme in
                    ["detail", "play"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/index.php/vod/\($0)/id/'" }
                }
            }.joined(separator: " || ")
        case .dilidili:
            return hosts.flatMap { host in
                ["http", "https"].flatMap { scheme in
                    ["anime", "watch"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/\($0)/'" }
                }
            }.joined(separator: " || ")
        case .youknow:
            return hosts.flatMap { host in
                ["http", "https"].flatMap { scheme in
                    ["d", "p"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/\($0)/'" }
                }
            }.joined(separator: " || ")
        case .hanime1:
            return hosts.flatMap { host in
                ["http", "https"].map { "url BEGINSWITH[c] '\($0)://\(host)/watch?v='" }
            }.joined(separator: " || ")
        case .wedm:
            return hosts.flatMap { host in
                ["http", "https"].flatMap { scheme in
                    ["vodetail_", "dmplay_"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/\($0)'" }
                }
            }.joined(separator: " || ")
        case .fengche:
            return hosts.flatMap { host in
                ["http", "https"].flatMap { scheme in
                    ["voddetail/", "vodplay/"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/\($0)'" }
                }
            }.joined(separator: " || ")
        case .rebo:
            return hosts.flatMap { host in
                ["http", "https"].flatMap { scheme in
                    ["detail/", "play/"].map { "url BEGINSWITH[c] '\(scheme)://\(host)/\($0)'" }
                }
            }.joined(separator: " || ")
		default:
			let tokens = hosts
			if tokens.isEmpty {
				return ""
			} else if tokens.count == 1 {
				return "url CONTAINS '\(tokens[0])'"
			} else {
				return tokens.map { "url CONTAINS '\($0)'" }.joined(separator: " || ")
			}
		}
	}

	static func canonicalHost(_ host: String) -> String {
		SupportSites.siteHosts.first(where: { $0.value.contains(host) })?.value.first ?? host
	}

    init?(host: String) {
        let normalizedHost = SupportSites.canonicalHost(host)
        guard let site = SupportSites.siteHosts.first(where: { $0.value.contains(normalizedHost) })?.key else {
            return nil
        }
        self = site
    }

    static func xiFanPage(_ components: URLComponents) -> (id: Int, line: Int?, episode: Int?)? {
        guard components.host?.lowercased() == "dm1.xfdm.pro",
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil else { return nil }
        guard components.path.hasSuffix(".html") else { return nil }
        let parts = components.path.split(separator: "/")
        if parts.count == 2, parts[0] == "bangumi",
           parts[1].hasSuffix(".html"),
           let id = Int(parts[1].dropLast(5)), id > 0 {
            return (id, nil, nil)
        }
        if parts.count == 4, parts[0] == "watch",
           parts[3].hasSuffix(".html"),
           let id = Int(parts[1]), id > 0,
           let line = Int(parts[2]), line > 0,
           let episode = Int(parts[3].dropLast(5)), episode > 0 {
            return (id, line, episode)
        }
        return nil
    }

    static func girigiriPage(_ components: URLComponents) -> (id: Int, line: Int?, episode: Int?)? {
        guard components.host?.lowercased() == "ani.girigirilove.com",
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil else { return nil }
        let path = components.path
        guard path.hasPrefix("/"), path.hasSuffix("/") else { return nil }
        let part = path.dropFirst().dropLast()
        if part.hasPrefix("GV"), let id = Int(part.dropFirst(2)), id > 0 {
            return (id, nil, nil)
        }
        if part.hasPrefix("playGV") {
            let fields = part.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if fields.count == 3,
               let id = Int(fields[0]), id > 0,
               let line = Int(fields[1]), line > 0,
               let episode = Int(fields[2]), episode > 0 {
                return (id, line, episode)
            }
        }
        return nil
    }

    static func didahdPage(_ components: URLComponents) -> (id: Int, line: Int?, episode: Int?)? {
        guard let host = components.host?.lowercased(),
              siteHosts[.didahd]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil,
              components.path.hasSuffix(".html") else { return nil }
        let parts = components.path.split(separator: "/")
        if parts.count == 2, parts[0] == "detail",
           let id = Int(parts[1].dropLast(5)), id > 0 { return (id, nil, nil) }
        if parts.count == 2, parts[0] == "play" {
            let fields = parts[1].dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
            if fields.count == 3, let id = Int(fields[0]), id > 0,
               let line = Int(fields[1]), line > 0,
               let episode = Int(fields[2]), episode > 0 { return (id, line, episode) }
        }
        return nil
    }
    static func reboPage(_ components: URLComponents) -> (id: Int, line: Int?, episode: Int?)? {
        guard let host = components.host?.lowercased(), siteHosts[.rebo]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil,
              components.path.hasSuffix(".html") else { return nil }
        let parts = components.path.split(separator: "/")
        if parts.count == 2, parts[0] == "detail",
           let id = Int(parts[1].dropLast(5)), id > 0 { return (id, nil, nil) }
        if parts.count == 2, parts[0] == "play" {
            let fields = parts[1].dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
            if fields.count == 3, let id = Int(fields[0]), id > 0,
               let line = Int(fields[1]), line > 0,
               let episode = Int(fields[2]), episode > 0 { return (id, line, episode) }
        }
        return nil
    }
    static func jibiPage(_ components: URLComponents) -> (id: Int, line: Int?, episode: Int?)? {
        guard let host = components.host?.lowercased(), siteHosts[.jibi]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil,
              components.path.hasSuffix(".html") else { return nil }
        let parts = components.path.split(separator: "/")
        if parts.count == 5, parts[0] == "index.php", parts[1] == "vod",
           parts[2] == "detail", parts[3] == "id",
           let id = Int(parts[4].dropLast(5)), id > 0 { return (id, nil, nil) }
        if parts.count == 9, parts[0] == "index.php", parts[1] == "vod", parts[2] == "play",
           parts[3] == "id", parts[5] == "sid", parts[7] == "nid",
           let id = Int(parts[4]), id > 0, let line = Int(parts[6]), line > 0,
           let episode = Int(parts[8].dropLast(5)), episode > 0 {
            return (id, line, episode)
        }
        return nil
    }
    static func eacgPage(_ components: URLComponents) -> (id: Int, line: Int?, episode: Int?)? {
        guard let host = components.host?.lowercased(), siteHosts[.eacg]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil,
              components.path.hasSuffix(".html") else { return nil }
        let parts = components.path.split(separator: "/")
        if parts.count == 1, parts[0].hasPrefix("voddetails-"),
           let id = Int(parts[0].dropFirst("voddetails-".count).dropLast(5)), id > 0 {
            return (id, nil, nil)
        }
        if parts.count == 2, parts[0] == "voddetail",
           let id = Int(parts[1].dropLast(5)), id > 0 { return (id, nil, nil) }
        if parts.count == 2, parts[0] == "Comicplay" || parts[0] == "vodplay" {
            let fields = parts[1].dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
            if fields.count == 3, let id = Int(fields[0]), id > 0,
               let line = Int(fields[1]), line > 0,
               let episode = Int(fields[2]), episode > 0 { return (id, line, episode) }
        }
        return nil
    }

    static func senfunPage(_ components: URLComponents) -> (id: Int, episode: String?)? {
        guard let host = components.host?.lowercased(), siteHosts[.senfun]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil,
              components.path.hasSuffix(".html") else { return nil }
        let parts = components.path.split(separator: "/")
        if parts.count == 2, parts[0] == "voddetail",
           let id = Int(parts[1].dropLast(5)), id > 0 { return (id, nil) }
        if parts.count == 3, parts[0] == "vodwatch",
           let id = Int(parts[1]), id > 0 {
            let slug = String(parts[2].dropLast(5))
            if slug.range(of: #"^[0-9A-Za-z_]+$"#, options: .regularExpression) != nil {
                return (id, slug)
            }
        }
        return nil
    }

    static func kanbaPage(_ components: URLComponents) -> (id: Int, line: Int?, episode: Int?)? {
        guard let host = components.host?.lowercased(), siteHosts[.kanba]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil,
              components.path.hasSuffix(".html") else { return nil }
        let parts = components.path.split(separator: "/")
        if parts.count == 5, parts[0] == "index.php", parts[1] == "vod",
           parts[2] == "detail", parts[3] == "id",
           let id = Int(parts[4].dropLast(5)), id > 0 { return (id, nil, nil) }
        if parts.count == 9, parts[0] == "index.php", parts[1] == "vod", parts[2] == "play",
           parts[3] == "id", parts[5] == "sid", parts[7] == "nid",
           let id = Int(parts[4]), id > 0, let line = Int(parts[6]), line > 0,
           let episode = Int(parts[8].dropLast(5)), episode > 0 {
            return (id, line, episode)
        }
        return nil
    }

    static func haixingPage(_ components: URLComponents) -> (id: String, line: Int?, episode: Int?)? {
        guard let host = components.host?.lowercased(), siteHosts[.haixing]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil,
              components.path.hasSuffix(".html") else { return nil }
        let parts = components.path.split(separator: "/")
        if parts.count == 2, parts[0] == "view" {
            let id = String(parts[1].dropLast(5))
            if !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return (id, nil, nil)
            }
        }
        if parts.count == 2, parts[0] == "play" {
            // <id>-<playindex>-<epindex>; both indexes are zero based, so split
            // the numbers off from the end before validating the id.
            let fields = parts[1].dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
            if fields.count >= 3,
               let episode = Int(fields[fields.count - 1]), episode >= 0,
               let line = Int(fields[fields.count - 2]), line >= 0 {
                let id = fields[..<(fields.count - 2)].joined(separator: "-")
                if !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    return (id, line, episode)
                }
            }
        }
        return nil
    }
    static func yinghuaPage(_ components: URLComponents) -> (id: Int, line: Int?, episode: Int?)? {
        guard let host = components.host?.lowercased(), siteHosts[.yinghua]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil,
              components.path.hasSuffix(".html") else { return nil }
        let parts = components.path.split(separator: "/")
        if parts.count == 5, parts[0] == "index.php", parts[1] == "vod",
           parts[2] == "detail", parts[3] == "id",
           let id = Int(parts[4].dropLast(5)), id > 0 { return (id, nil, nil) }
        if parts.count == 9, parts[0] == "index.php", parts[1] == "vod",
           parts[2] == "play", parts[3] == "id", parts[5] == "sid", parts[7] == "nid",
           let id = Int(parts[4]), id > 0, let line = Int(parts[6]), line > 0,
           let episode = Int(parts[8].dropLast(5)), episode > 0 {
            return (id, line, episode)
        }
        return nil
    }


    enum DilidiliPage {
        case anime(String)
        case watch(String)
    }

    static func dilidiliPage(_ components: URLComponents) -> DilidiliPage? {
        guard let host = components.host?.lowercased(), siteHosts[.dilidili]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[3].isEmpty,
              !parts[2].isEmpty, parts[2].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        switch parts[1] {
        case "anime": return .anime(String(parts[2]))
        case "watch": return .watch(String(parts[2]))
        default: return nil
        }
    }
    static func youknowPage(_ components: URLComponents) -> (id: Int, line: Int?, episode: Int?)? {
        guard let host = components.host?.lowercased(), siteHosts[.youknow]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "", parts.last == "" else { return nil }
        if parts.count == 4, parts[1] == "d", let id = Int(parts[2]), id > 0 {
            return (id, nil, nil)
        }
        if parts.count == 4, parts[1] == "p" {
            let fields = parts[2].split(separator: "-", omittingEmptySubsequences: false)
            if fields.count == 3, let id = Int(fields[0]), id > 0,
               let line = Int(fields[1]), line > 0,
               let episode = Int(fields[2]), episode > 0 { return (id, line, episode) }
        }
        return nil
    }
    static func hanime1Page(_ components: URLComponents) -> Int? {
        guard let host = components.host?.lowercased(), siteHosts[.hanime1]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil,
              components.path == "/watch",
              let value = components.queryItems?.first(where: { $0.name == "v" })?.value,
              let id = Int(value), id > 0 else { return nil }
        return id
    }
    static func wedmPage(_ components: URLComponents) -> (id: String, line: Int?, episode: Int?)? {
        guard let host = components.host?.lowercased(), siteHosts[.wedm]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil,
              components.path.hasSuffix(".html") else { return nil }
        let path = components.path
        func valid(_ id: String) -> Bool {
            !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        if path.hasPrefix("/vodetail_") {
            let id = String(path.dropFirst(10).dropLast(5))
            if valid(id) { return (id, nil, nil) }
        }
        if path.hasPrefix("/dmplay_") {
            let fields = path.dropFirst(8).dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
            if fields.count >= 3, let line = Int(fields[fields.count - 2]), line > 0,
               let episode = Int(fields[fields.count - 1]), episode > 0 {
                let id = fields.dropLast(2).joined(separator: "-")
                if valid(id) { return (id, line, episode) }
            }
        }
        return nil
    }
    static func fengchePage(_ components: URLComponents) -> (id: Int, line: Int?, episode: Int?)? {
        guard let host = components.host?.lowercased(), siteHosts[.fengche]?.contains(host) == true,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.port == nil, components.user == nil, components.password == nil,
              components.path.hasSuffix(".html") else { return nil }
        let parts = components.path.split(separator: "/")
        if parts.count == 2, parts[0] == "voddetail",
           let id = Int(parts[1].dropLast(5)), id > 0 { return (id, nil, nil) }
        if parts.count == 2, parts[0] == "vodplay" {
            let fields = parts[1].dropLast(5).split(separator: "-", omittingEmptySubsequences: false)
            if fields.count == 3, let id = Int(fields[0]), id > 0,
               let line = Int(fields[1]), line > 0,
               let episode = Int(fields[2]), episode > 0 { return (id, line, episode) }
        }
        return nil
    }

    static func isBilibiliHost(_ host: String?) -> Bool {
		guard let host else { return false }
		return SupportSites.siteHosts[.bilibili]?.contains(host) == true || SupportSites.siteHosts[.bangumi]?.contains(host) == true
    }
}


enum LiveState: Int {
    case living = 1
    case offline = 0
    case video = -99
    case replay = 2
    case `none` = -1
    
    var raw: Int16 {
        get {
            return Int16(rawValue)
        }
    }
    
    var color: NSColor {
        get {
            let pref = Preferences.shared
            switch self {
            case .living:
                return pref.stateLiving
            case .offline:
                return pref.stateOffline
            case .video:
                return .clear
            case .replay:
                return pref.stateReplay
            case .none:
                return pref.stateUnknown
            }
        }
    }
}

protocol SupportSiteProtocol {
    func liveInfo(_ url: String) async throws -> LiveInfo
    func decodeUrl(_ url: String) async throws -> YouGetJSON
}
