import Foundation

enum SupportSites: String, Hashable, Sendable, CaseIterable {
    case xiFan = "xifan", girigiri, didahd, jibi, eacg, senfun, kanba, haixing
    case yinghua, dilidili, youknow, hanime1, wedm, fengche, rebo, mutedm
    case unsupported
    var sourceID: String { rawValue }
    static let nativeSites = allCases.filter { $0 != .unsupported }
    static let siteHosts: [SupportSites: [String]] = [
        .xiFan: [
            "dm1.xfdm.pro", "next.xifanacg.com"
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
        .mutedm: ["www.mutedm.com", "mutedm.com", "www.2kdm.com", "2kdm.com"],
        .rebo: ["www.rebozj.cc", "rebozj.cc", "www.rebozj.pro", "rebozj.pro"],
    ]
    var hosts: [String] { Self.siteHosts[self] ?? [] }
    static func canonicalHost(_ host: String) -> String {
        let normalized = host.lowercased()
        if normalized == "next.xifanacg.com" { return normalized }
        return siteHosts.first(where: { $0.value.contains(normalized) })?.value.first ?? normalized
    }
    init?(host: String) {
        guard let site = Self.nativeSites.first(where: { $0.hosts.contains(host.lowercased()) }) else { return nil }
        self = site
    }
    static func xiFanNextPage(_ c: URLComponents) -> (id: Int, episode: Int?, source: String?)? {
        guard c.scheme == "https", c.host == "next.xifanacg.com", c.port == nil,
              c.user == nil, c.password == nil, c.fragment == nil else { return nil }
        let parts = c.path.split(separator: "/", omittingEmptySubsequences: false)
        guard (parts.count == 3 || parts.count == 5), parts[0].isEmpty, parts[1] == "anime",
              let id = Int(parts[2]), id > 0, String(id) == parts[2] else { return nil }
        if parts.count == 3 { return c.query == nil ? (id, nil, nil) : nil }
        guard parts[3] == "play", let episode = Int(parts[4]), episode > 0, String(episode) == parts[4] else { return nil }
        let query = c.queryItems ?? []
        guard query.count <= 1, query.allSatisfy({ $0.name == "source" }) else { return nil }
        let source = query.first?.value
        if !query.isEmpty {
            guard let source, !source.isEmpty, source.utf8.count <= 32,
                  source.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else { return nil }
        }
        return (id, episode, source)
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
    static func mutedmPage(_ components: URLComponents) -> (id: Int, line: Int?, episode: Int?)? {
        guard let host = components.host?.lowercased(), siteHosts[.mutedm]?.contains(host) == true,
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
}
