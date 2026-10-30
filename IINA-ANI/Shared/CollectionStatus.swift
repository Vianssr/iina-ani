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

/// Classification is independent of favorite membership; nil means unclassified.
enum CollectionStatusFilter: Hashable, Sendable {
    case all
    case unclassified
    case status(BangumiCollectionStatus)

    func matches(_ status: BangumiCollectionStatus?) -> Bool {
        switch self {
        case .all: return true
        case .unclassified: return status == nil
        case .status(let expected): return status == expected
        }
    }
}
