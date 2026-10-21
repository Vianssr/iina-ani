import Foundation

enum BangumiCollectionStatus: Int, Codable, CaseIterable, Sendable, Hashable {
    case wish = 1
    case doing = 3
    case collected = 2
    case onHold = 4
    case dropped = 5

    static let displayOrder: [Self] = [.wish, .doing, .collected, .onHold, .dropped]

    var title: String {
        switch self {
        case .wish: return String(localized: "想看")
        case .doing: return String(localized: "在看")
        case .collected: return String(localized: "已看")
        case .onHold: return String(localized: "擱置")
        case .dropped: return String(localized: "丟棄")
        }
    }
}

/// The collection endpoint embeds SlimSubject; it is not complete episode metadata.
struct BangumiOnlineCollection: Decodable, Sendable {
    let subjectID: Int
    let subjectType: Int
    let status: BangumiCollectionStatus
    let subject: BangumiSubject

    private enum CodingKeys: String, CodingKey {
        case subjectID = "subject_id", subjectType = "subject_type", status = "type", subject
    }
}

struct BangumiSubject: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
    let nameCN: String
    let aliases: [String]
    let coverURL: String?
    let summary: String?
    let date: String?
    let type: Int
    let platform: String?
    let episodeCount: Int?
    let totalEpisodes: Int?
    let infobox: [BangumiInfoboxEntry]
    let tags: [BangumiTag]
    let metaTags: [String]
    let rating: BangumiRating?
    let collection: BangumiCollection?
    var title: String { nameCN.isEmpty ? name : nameCN }
    var classification: MediaClassification {
        MediaClassification(kind: type == 2 ? .anime : type == 6 ? .video : .unknown,
                            provenance: "bangumi.subject.type=\(type)")
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, nameCN = "name_cn", aliases, images, summary, date, airDate = "air_date", infobox
        case type, platform, eps, totalEpisodes = "total_episodes", epsCount = "eps_count"
        case tags, metaTags = "meta_tags", rating, collection
    }
    private enum ImageKeys: String, CodingKey { case large, common, medium, small, grid }

    init(id: Int, name: String, nameCN: String = "", aliases: [String] = [], coverURL: String? = nil,
         summary: String? = nil, date: String? = nil, type: Int, platform: String? = nil,
         episodeCount: Int? = nil, totalEpisodes: Int? = nil, infobox: [BangumiInfoboxEntry] = [],
         tags: [BangumiTag] = [], metaTags: [String] = [], rating: BangumiRating? = nil,
         collection: BangumiCollection? = nil) {
        self.id = id; self.name = name; self.nameCN = nameCN; self.aliases = aliases
        self.coverURL = coverURL; self.summary = summary; self.date = date; self.type = type
        self.platform = platform; self.episodeCount = episodeCount; self.totalEpisodes = totalEpisodes
        self.infobox = infobox; self.tags = tags; self.metaTags = metaTags
        self.rating = rating; self.collection = collection
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        var resolvedNameCN = try c.decodeIfPresent(String.self, forKey: .nameCN) ?? ""
        type = try c.decode(Int.self, forKey: .type)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? c.decodeIfPresent(String.self, forKey: .airDate)
        let releasedCount = try c.decodeIfPresent(Int.self, forKey: .eps)
        let declaredCount = try c.decodeIfPresent(Int.self, forKey: .totalEpisodes) ?? c.decodeIfPresent(Int.self, forKey: .epsCount)
        episodeCount = releasedCount.flatMap { $0 > 0 ? $0 : nil }
        totalEpisodes = declaredCount.flatMap { $0 > 0 ? $0 : nil }
        var resolvedPlatform = try c.decodeIfPresent(String.self, forKey: .platform)
        var resolvedCover: String?
        if let images = try? c.nestedContainer(keyedBy: ImageKeys.self, forKey: .images) {
            for key in [ImageKeys.large, .common, .medium, .small, .grid] {
                if let value = try images.decodeIfPresent(String.self, forKey: key) {
                    resolvedCover = value
                    break
                }
            }
        }
        coverURL = resolvedCover
        var foundAliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        infobox = try c.decodeIfPresent([BangumiInfoboxEntry].self, forKey: .infobox) ?? []
        tags = try c.decodeIfPresent([BangumiTag].self, forKey: .tags) ?? []
        metaTags = try c.decodeIfPresent([String].self, forKey: .metaTags) ?? []
        rating = try c.decodeIfPresent(BangumiRating.self, forKey: .rating)
        collection = try c.decodeIfPresent(BangumiCollection.self, forKey: .collection)
        if !infobox.isEmpty {
            for entry in infobox {
                switch entry.value {
                case .text(let value):
                    switch entry.key.lowercased() {
                    case "name_cn", "简体中文名", "中文名": if resolvedNameCN.isEmpty { resolvedNameCN = value }
                    case "原名", "name alias", "name_alias": foundAliases.append(value)
                    case "platform", "平台": if resolvedPlatform == nil { resolvedPlatform = value }
                    default: break
                    }
                case .list(let values):
                    switch entry.key.lowercased() {
                    case "别名", "aliases", "alias": foundAliases += values.compactMap(\.v)
                    case "platform", "平台": if resolvedPlatform == nil { resolvedPlatform = values.compactMap(\.v).joined(separator: ", ") }
                    default: break
                    }
                case .other: break
                }
            }
        }
        nameCN = resolvedNameCN
        platform = resolvedPlatform
        let originalName = name
        let localizedName = resolvedNameCN
        var seen = Set<String>()
        aliases = foundAliases.filter { !$0.isEmpty && $0 != originalName && $0 != localizedName && seen.insert($0).inserted }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(nameCN, forKey: .nameCN)
        try c.encode(aliases, forKey: .aliases)
        if let coverURL { var images = c.nestedContainer(keyedBy: ImageKeys.self, forKey: .images); try images.encode(coverURL, forKey: .large) }
        try c.encodeIfPresent(summary, forKey: .summary); try c.encodeIfPresent(date, forKey: .date)
        try c.encode(type, forKey: .type); try c.encodeIfPresent(platform, forKey: .platform)
        try c.encodeIfPresent(episodeCount, forKey: .eps); try c.encodeIfPresent(totalEpisodes, forKey: .totalEpisodes)
        try c.encode(infobox, forKey: .infobox); try c.encode(tags, forKey: .tags)
        try c.encode(metaTags, forKey: .metaTags); try c.encodeIfPresent(rating, forKey: .rating)
        try c.encodeIfPresent(collection, forKey: .collection)
    }
}

struct BangumiEpisode: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let type: Int
    let sort: Double
    /// Official within-subject number; sort can continue across seasons.
    let ep: Double?
    let name: String
    let nameCN: String
    let airdate: String?
    let summary: String?
    let duration: String?
    var title: String { nameCN.isEmpty ? name : nameCN }
    private enum CodingKeys: String, CodingKey { case id, type, sort, ep, name, nameCN = "name_cn", airdate, summary, duration, desc }
    init(id: Int, type: Int, sort: Double, name: String, nameCN: String = "", airdate: String? = nil, summary: String? = nil, duration: String? = nil, ep: Double? = nil) {
        self.id = id; self.type = type; self.sort = sort; self.name = name; self.nameCN = nameCN
        self.airdate = airdate; self.summary = summary; self.duration = duration
        self.ep = ep
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id); type = try c.decode(Int.self, forKey: .type)
        if let value = try? c.decode(Double.self, forKey: .sort) { sort = value } else { sort = Double(try c.decode(Int.self, forKey: .sort)) }
        ep = try c.decodeIfPresent(Double.self, forKey: .ep)
        name = try c.decode(String.self, forKey: .name); nameCN = try c.decodeIfPresent(String.self, forKey: .nameCN) ?? ""
        airdate = try c.decodeIfPresent(String.self, forKey: .airdate)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? c.decodeIfPresent(String.self, forKey: .desc)
        duration = try c.decodeIfPresent(String.self, forKey: .duration)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(type, forKey: .type); try c.encode(sort, forKey: .sort)
        try c.encodeIfPresent(ep, forKey: .ep)
        try c.encode(name, forKey: .name); try c.encode(nameCN, forKey: .nameCN); try c.encodeIfPresent(airdate, forKey: .airdate)
        try c.encodeIfPresent(summary, forKey: .summary); try c.encodeIfPresent(duration, forKey: .duration)
    }
}

struct BangumiMetadata: Codable, Sendable, Equatable, Hashable {
    let subject: BangumiSubject
    let episodes: [BangumiEpisode]
    let fetchedAt: Date
    var sourceURL: String { "https://api.bgm.tv/v0/subjects/\(subject.id)" }
    var needsEpisodeNumberRefresh: Bool { episodes.contains { $0.type == 0 && $0.ep == nil } }
}

struct BangumiPage<T: Codable & Sendable>: Codable, Sendable {
    let data: [T]
    let total: Int
    let limit: Int
    let offset: Int
}

struct BangumiCalendarDay: Codable, Sendable, Equatable, Hashable {
    let weekday: Int
    let items: [BangumiSubject]
    private enum CodingKeys: String, CodingKey { case weekday, items }
    private enum WeekdayKeys: String, CodingKey { case id }
    init(weekday: Int, items: [BangumiSubject]) { self.weekday = weekday; self.items = items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decode(Int.self, forKey: .weekday) { weekday = value }
        else { weekday = try c.nestedContainer(keyedBy: WeekdayKeys.self, forKey: .weekday).decode(Int.self, forKey: .id) }
        items = try c.decode([BangumiSubject].self, forKey: .items)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(weekday, forKey: .weekday); try c.encode(items, forKey: .items)
    }
}

enum BangumiError: Error, Sendable, LocalizedError, Hashable {
    case network(String), httpStatus(Int), decoding(String), account(String), invalidResponse(String), cache(String)
    var errorDescription: String? {
        switch self {
        case .network(let value): return String(localized: "Bangumi network request failed: \(value)")
        case .httpStatus(let status): return String(localized: "Bangumi returned HTTP \(status).")
        case .decoding(let value): return String(localized: "Bangumi response could not be decoded: \(value)")
        case .account(let value): return String(localized: "Bangumi account request failed: \(value)")
        case .invalidResponse(let value): return String(localized: "Invalid Bangumi response: \(value)")
        case .cache(let value): return String(localized: "Bangumi metadata cache failed: \(value)")
        }
    }
}

enum BangumiOrigin: Sendable, Equatable { case network, cache, staleCache }
struct BangumiResult<T: Sendable>: Sendable {
    let value: T
    let origin: BangumiOrigin
    let failure: BangumiError?
    let fetchedAt: Date?
    init(value: T, origin: BangumiOrigin, failure: BangumiError?, fetchedAt: Date? = nil) {
        self.value = value
        self.origin = origin
        self.failure = failure
        self.fetchedAt = fetchedAt
    }
}

struct BangumiInfoboxEntry: Codable, Sendable, Equatable, Hashable {
    let key: String
    let value: BangumiInfoboxValue
}

enum BangumiInfoboxValue: Codable, Sendable, Equatable, Hashable {
    struct Item: Codable, Sendable, Equatable, Hashable { let k: String?; let v: String? }
    case text(String), list([Item]), other
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) { self = .text(text) }
        else if let list = try? c.decode([Item].self) { self = .list(list) }
        else { self = .other }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let text): try c.encode(text)
        case .list(let list): try c.encode(list)
        case .other: try c.encodeNil()
        }
    }
    var displayText: String {
        switch self {
        case .text(let text): return text
        case .list(let list): return list.compactMap { item in
            guard let value = item.v else { return nil }
            return item.k.flatMap { $0.isEmpty ? nil : $0 + ": " + value } ?? value
        }.joined(separator: "、")
        case .other: return ""
        }
    }
}

struct BangumiTag: Codable, Sendable, Equatable, Hashable { let name: String; let count: Int }
struct BangumiRating: Codable, Sendable, Equatable, Hashable {
    let score: Double
    let rank: Int?
    let total: Int
    let count: [String: Int]
}
struct BangumiCollection: Codable, Sendable, Equatable, Hashable {
    let wish: Int?
    let collect: Int?
    let doing: Int?
    let onHold: Int?
    let dropped: Int?
    private enum CodingKeys: String, CodingKey { case wish, collect, doing, onHold = "on_hold", dropped }
}
struct BangumiImages: Codable, Sendable, Equatable, Hashable {
    let large: String?
    let common: String?
    let medium: String?
    let small: String?
    let grid: String?
    var coverURL: String? {
        if let large, !large.isEmpty { return large }
        if let common, !common.isEmpty { return common }
        if let medium, !medium.isEmpty { return medium }
        if let small, !small.isEmpty { return small }
        return grid.flatMap { $0.isEmpty ? nil : $0 }
    }
}
struct BangumiPerson: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: Int
    let name: String
    let images: BangumiImages?
    var coverURL: String? { images?.coverURL }
}
struct BangumiCharacter: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: Int
    let name: String
    var relation: String
    var actors: [BangumiPerson]
    let summary: String
    let infobox: [BangumiInfoboxEntry]
    let images: BangumiImages?
    var introductionFailure: String?
    var coverURL: String? { images?.coverURL }
    var nameCN: String {
        infobox.first {
            switch $0.key.lowercased() {
            case "简体中文名", "中文名", "name_cn": return true
            default: return false
            }
        }?.value.displayText ?? ""
    }
    var title: String { nameCN.isEmpty ? name : nameCN }
    private enum CodingKeys: String, CodingKey { case id, name, relation, actors, summary, infobox, images, introductionFailure }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        relation = try c.decodeIfPresent(String.self, forKey: .relation) ?? ""
        actors = try c.decodeIfPresent([BangumiPerson].self, forKey: .actors) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        infobox = try c.decodeIfPresent([BangumiInfoboxEntry].self, forKey: .infobox) ?? []
        images = try c.decodeIfPresent(BangumiImages.self, forKey: .images)
        introductionFailure = try c.decodeIfPresent(String.self, forKey: .introductionFailure)
    }
}
struct BangumiSubjectRelation: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: Int
    let name: String
    let nameCN: String
    let type: Int
    let relation: String
    let images: BangumiImages?
    var title: String { nameCN.isEmpty ? name : nameCN }
    var coverURL: String? { images?.coverURL }
    private enum CodingKeys: String, CodingKey { case id, name, nameCN = "name_cn", type, relation, images }
}
struct BangumiDetailSection<T: Sendable>: Sendable {
    let value: T?
    let failure: BangumiError?
    let origin: BangumiOrigin?
    let fetchedAt: Date?
}
struct BangumiSubjectExtras: Sendable {
    let subject: BangumiDetailSection<BangumiSubject>
    let characters: BangumiDetailSection<[BangumiCharacter]>
    let relations: BangumiDetailSection<[BangumiSubjectRelation]>
}
struct BangumiComment: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: String
    let author: String
    let userURL: String
    let text: String
    let dateText: String
    let rating: Int?
}
struct BangumiCommentsPage: Codable, Sendable, Equatable, Hashable {
    let data: [BangumiComment]
    let page: Int
    let nextPage: Int?
}

