import CoreData
import Foundation
@testable import IINA_ANI

@main
@MainActor
struct CompletedSeasonPolicyRegression {
    struct Failure: Error { let message: String }
    static let now = Date(timeIntervalSince1970: 1_800_014_400)
    static let anime = MediaClassification(kind: .anime, provenance: "fixture")

    struct Fixture {
        var work: Work
        let selection: PlayableSelection
        let candidates: [SourceItemRef]
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }

    static func main() throws {
        guard CommandLine.arguments.count >= 3,
              let loaded = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])),
              let model = loaded.mutableCopy() as? NSManagedObjectModel else {
            throw Failure(message: "compiled app DataModel.momd is required")
        }
        for entity in model.entities { entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self) }
        let container = NSPersistentContainer(name: "DataModel", managedObjectModel: model)
        try container.persistentStoreCoordinator.addPersistentStore(ofType: NSInMemoryStoreType,
                                                                    configurationName: nil, at: nil, options: nil)
        let library = WorkLibrary(container: container)
        try metadataGates(library)
        try sourceEvidence(library)
        try localEvidence(library)
        print("PASS: only fully aired, declared complete seasons with exact online/local identity clear history")
    }

    static func episodes(count: Int = 3, absoluteOffset: Int = 0, relative: Bool = false) -> [BangumiEpisode] {
        (1...count).map { index in
            BangumiEpisode(id: 100 + index, type: 0, sort: Double(absoluteOffset + index),
                           name: "Known episode \(index)", airdate: "2026-01-0\(index)",
                           ep: relative ? Double(index) : nil)
        }
    }

    static func fixture(_ library: WorkLibrary, total: Int? = 3, subjectID: Int = 42,
                        episodes supplied: [BangumiEpisode]? = nil) throws -> Fixture {
        let token = UUID().uuidString
        let subject = BangumiSubject(id: subjectID, name: "Known season", type: 2,
                                    episodeCount: 3, totalEpisodes: total)
        let work = Work(bangumiID: subjectID, title: "Local title", bangumiMetadata:
            BangumiMetadata(subject: subject, episodes: supplied ?? episodes(), fetchedAt: now), classification: anime)
        try library.upsert(work)
        let source = SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/\(token)/work", kind: .work)
        let candidates = (1...3).map {
            SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/\(token)/episode/\($0)", kind: .episode)
        }
        try library.upsert(WorkSourceLink(workID: work.id, sourceWork: source))
        return Fixture(work: work, selection: PlayableSelection(item: source, episode: candidates.last!, classification: anime),
                       candidates: candidates)
    }

    static func policy(_ library: WorkLibrary, _ fixture: Fixture,
                       candidates: [SourceItemRef]? = nil) throws -> [SourceItemRef]? {
        try library.completedSeasonItems(for: fixture.selection, candidates: candidates ?? fixture.candidates,
                                         downloads: [], now: now)
    }

    static func changed(_ episode: BangumiEpisode, title: String? = nil,
                        date: String? = nil, removeDate: Bool = false, id: Int? = nil) -> BangumiEpisode {
        BangumiEpisode(id: id ?? episode.id, type: episode.type, sort: episode.sort,
                       name: title ?? episode.name, airdate: removeDate ? nil : date ?? episode.airdate, ep: episode.ep)
    }

    static func metadataGates(_ library: WorkLibrary) throws {
        let complete = try fixture(library)
        try require(try policy(library, complete) == complete.candidates, "complete online detail-start playback must clear")
        let ongoing = try fixture(library, episodes: Array(episodes().prefix(2)))
        try require(try policy(library, ongoing) == nil, "declared three episodes with only two released must retain")
        let unknownTotal = try fixture(library, total: nil)
        try require(try policy(library, unknownTotal) == nil, "episodeCount alone cannot establish completion")
        let zeroTotal = try fixture(library, total: 0)
        try require(try policy(library, zeroTotal) == nil, "zero declared total must retain")
        for title in ["", "  ", "未知", "標題未知", "标题未知", "UNKNOWN"] {
            var values = episodes()
            values[2] = changed(values[2], title: title)
            try require(try policy(library, fixture(library, episodes: values)) == nil, "unknown episode title must retain: \(title)")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let today = formatter.string(from: now)
        for date in ["2099-01-01", today, "2026-02-30", "2026-1-03", ""] {
            var values = episodes()
            values[2] = changed(values[2], date: date)
            try require(try policy(library, fixture(library, episodes: values)) == nil, "future/today/invalid date must retain: \(date)")
        }
        var undated = episodes()
        undated[2] = changed(undated[2], removeDate: true)
        try require(try policy(library, fixture(library, episodes: undated)) == nil, "missing airdate must retain")
        var duplicate = episodes()
        duplicate[2] = changed(duplicate[2], id: duplicate[0].id)
        try require(try policy(library, fixture(library, episodes: duplicate)) == nil, "duplicate episode identity must retain")
        let gaps = [episodes()[0], episodes()[2], BangumiEpisode(id: 104, type: 0, sort: 4, name: "Fourth", airdate: "2026-01-04")]
        try require(try policy(library, fixture(library, episodes: gaps)) == nil, "gapped main episode numbering must retain")
        let seasonTwo = try fixture(library, episodes: episodes(absoluteOffset: 12, relative: true))
        try require(try policy(library, seasonTwo) == seasonTwo.candidates, "season two must use within-season ep, not absolute sort")
        let absoluteOnly = try fixture(library, episodes: episodes(absoluteOffset: 12))
        try require(try policy(library, absoluteOnly) == nil, "absolute sort without within-season identity must not guess a season")
        var mismatch = try fixture(library)
        mismatch.work.bangumiID = 43
        try library.upsert(mismatch.work)
        try require(try policy(library, mismatch) == nil, "Work and metadata subject identity must agree")
        var missing = try fixture(library)
        missing.work.bangumiMetadata = nil
        try library.upsert(missing.work)
        try require(try policy(library, missing) == nil, "missing metadata must retain")
    }

    static func sourceEvidence(_ library: WorkLibrary) throws {
        let value = try fixture(library)
        try require(try policy(library, value, candidates: Array(value.candidates.suffix(2))) == nil,
                    "incomplete source group must retain even when metadata is complete")
        try require(try policy(library, value, candidates: [value.candidates[0], value.candidates[2], value.candidates[2]]) == nil,
                    "duplicate source group identities must retain")
        let middle = Fixture(work: value.work,
                         selection: PlayableSelection(item: value.selection.item, episode: value.candidates[1], classification: anime),
                         candidates: Array(value.candidates.prefix(2)))
        try require(try policy(library, middle) == nil, "a middle episode cannot complete the season")
        let lostWork = Fixture(work: value.work, selection: PlayableSelection(item: value.candidates.last!, classification: anime),
                               candidates: value.candidates)
        try require(try policy(library, lostWork) == nil, "an episode URL without work association must retain")
        let final = Episode(workID: value.work.id, externalID: "bangumi:103", label: "Final", sort: 3)
        try library.upsert(final)
        let link = WorkSourceLink(workID: value.work.id, sourceWork: value.selection.item,
                                 episodeMappings: [EpisodeSourceMapping(episodeID: final.id, selection: value.selection)])
        try library.upsert(link)
        try require(try policy(library, value) == value.candidates, "exact final episode mapping must clear")
        let wrong = Episode(workID: value.work.id, externalID: "bangumi:102", label: "Middle", sort: 2)
        try library.upsert(wrong)
        try library.upsert(WorkSourceLink(id: link.id, workID: value.work.id, sourceWork: value.selection.item,
                                        episodeMappings: [EpisodeSourceMapping(episodeID: wrong.id, selection: value.selection)]))
        try require(try policy(library, value) == nil, "explicit middle mapping overrides apparently complete source count")
        let ambiguous = try fixture(library)
        let other = Work(bangumiID: 43, title: "Different season", classification: anime)
        try library.upsert(other)
        try library.upsert(WorkSourceLink(workID: other.id, sourceWork: ambiguous.selection.item))
        try require(try policy(library, ambiguous) == nil, "one source work linked to two seasons must retain")
    }

    static func local(_ name: String) -> SourceItemRef {
        SourceItemRef(sourceID: "local", pageURL: URL(fileURLWithPath: "/fixture/mixed/\(name).mp4").absoluteString, kind: .local)
    }

    static func download(_ fixture: Fixture, file: SourceItemRef, index: Int) -> DownloadRecord {
        var selection = fixture.selection
        selection.episode = fixture.candidates[index - 1]
        var record = DownloadRecord(id: UUID(), selection: selection, workID: fixture.work.id, title: "Never parsed",
                                    episodeTitle: nil, outputDirectory: URL(fileURLWithPath: "/fixture/mixed"),
                                    temporaryDirectory: URL(fileURLWithPath: "/fixture/tmp"), concurrencyLimit: 1,
                                    createdAt: now, updatedAt: now)
        record.state = .completed
        record.completedFile = URL(string: file.pageURL)
        record.bangumiID = fixture.work.bangumiID
        record.episodeKey = "bangumi:\(100 + index)"
        return record
    }

    static func localEvidence(_ library: WorkLibrary) throws {
        let value = try fixture(library)
        let first = local("01"), final = local("99"), foreign = local("50-other-season"), unknown = local("60-untracked")
        let other = try fixture(library, subjectID: 43)
        let downloads = [download(value, file: first, index: 1), download(other, file: foreign, index: 3),
                         download(value, file: final, index: 3)]
        let selection = PlayableSelection(item: final, classification: .unknown)
        let candidates = [first, foreign, unknown, final]
        func result(_ records: [DownloadRecord], _ selected: PlayableSelection = selection,
                    _ items: [SourceItemRef] = candidates) throws -> [SourceItemRef]? {
            try library.completedSeasonItems(for: selected, candidates: items, downloads: records, now: now)
        }
        try require(try result(downloads) == [first, final], "mixed folder must clear only exact downloads belonging to this work")
        try require(try result([]) == nil, "a local final filename alone is not evidence")
        try require(try result(downloads, PlayableSelection(item: first), [first]) == nil, "middle local episode must retain")
        var noKey = downloads
        noKey[2].episodeKey = nil
        try require(try result(noKey) == nil, "a final local file without episode metadata/mapping must retain")
        var conflicting = downloads
        conflicting[2].bangumiID = 43
        try require(try result(conflicting) == nil, "conflicting download work/Bangumi identity must retain")
        var duplicates = downloads
        duplicates.append(downloads[2])
        try require(try result(duplicates) == nil, "ambiguous completed file records must retain")
        var noMetadata = value.work
        noMetadata.bangumiMetadata = nil
        try library.upsert(noMetadata)
        try require(try result(downloads) == nil, "final local episode without season metadata must retain")
        try library.upsert(value.work)
        let episode = Episode(workID: value.work.id, externalID: "bangumi:103", label: "Final", sort: 3)
        try library.upsert(episode)
        try library.upsert(WorkSourceLink(workID: value.work.id, sourceWork: value.selection.item,
                                        episodeMappings: [EpisodeSourceMapping(episodeID: episode.id, selection: value.selection)]))
        try require(try result(noKey) == [first, final], "exact source mapping can establish downloaded final episode without a key")
        var uuidKey = downloads
        uuidKey[2].episodeKey = episode.id.uuidString
        try require(try result(uuidKey) == [first, final], "local episode UUID key must resolve through its exact Bangumi external identity")
        var wrongKey = downloads
        wrongKey[2].episodeKey = "bangumi:102"
        try require(try result(wrongKey) == nil, "conflicting key and confirmed mapping must retain")
    }
}
