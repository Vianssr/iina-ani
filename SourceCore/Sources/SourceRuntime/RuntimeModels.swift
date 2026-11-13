import Foundation
import SourceCore

public struct RuntimeWork: Sendable {
    public let item: SourceItemRef
    public let title: String
    public init(item: SourceItemRef, title: String) { self.item = item; self.title = title }
}

public struct RuntimeEpisode: Hashable, Sendable {
    public let item: SourceItemRef
    public let title: String
    public let line: Int
    public let number: Int
    public let identity: String?
    public let mediaPath: String?
    public let qualityID: String?
    public init(item: SourceItemRef, title: String, line: Int, number: Int,
                identity: String? = nil, mediaPath: String? = nil, qualityID: String? = nil) {
        self.item = item; self.title = title; self.line = line; self.number = number
        self.identity = identity; self.mediaPath = mediaPath; self.qualityID = qualityID
    }
}

public struct RuntimeLine: Sendable {
    public let id: Int
    public let title: String
    public let episodes: [RuntimeEpisode]
    public init(id: Int, title: String, episodes: [RuntimeEpisode]) {
        self.id = id; self.title = title; self.episodes = episodes
    }
}

public struct RuntimeCatalog: Sendable {
    public let work: RuntimeWork
    public let lines: [RuntimeLine]
    public init(work: RuntimeWork, lines: [RuntimeLine]) { self.work = work; self.lines = lines }
}

public struct RuntimePage: Sendable {
    public let works: [RuntimeWork]
    public let nextPage: Int?
    public init(works: [RuntimeWork], nextPage: Int?) { self.works = works; self.nextPage = nextPage }
}
