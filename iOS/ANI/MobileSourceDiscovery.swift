import Foundation
import Observation

struct MobileSourceCandidate: Identifiable, Sendable {
    let configuration: SourceConfiguration
    let catalog: MobileSourceCatalog
    let episode: MobileSourceEpisode?
    let trusted: Bool
    var id: String { catalog.work.id }
}

/// The desktop policy requires exact title plus independent year/subtype evidence, never a title alone.
/// Mobile deliberately leaves relative/absolute numbering and non-main episodes to manual confirmation.
enum MobileSourceTrust {
    private static let seasons = try! NSRegularExpression(pattern: #"(?:第\s*([0-9一二三四五六七八九十IVXⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]+)\s*[季期]|season\s*([0-9IVXⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]+)\b|\bs([0-9]+)\b)"#, options: .caseInsensitive)
    private static let years = try! NSRegularExpression(pattern: #"(?<![0-9])(?:19|20)[0-9]{2}(?![0-9])"#)
    private static let labels = try! NSRegularExpression(pattern: #"^(?:第\s*|ep(?:isode)?\s*)?([0-9]+(?:\.[0-9]+)?)(?:\s*[集话話回])?(?:$|[\s:：._-])"#, options: .caseInsensitive)
    private static let ordinals = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10, "I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6, "VII": 7, "VIII": 8, "IX": 9, "X": 10, "Ⅰ": 1, "Ⅱ": 2, "Ⅲ": 3, "Ⅳ": 4, "Ⅴ": 5, "Ⅵ": 6, "Ⅶ": 7, "Ⅷ": 8, "Ⅸ": 9, "Ⅹ": 10]
    static func season(_ title: String) -> Int? {
        guard let match = seasons.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) else { return nil }
        for i in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: i), in: title) {
                let raw = String(title[range]).uppercased()
                return Int(raw) ?? ordinals[raw]
            }
        }
        return nil
    }
    private static func format(_ title: String) -> String? {
        let title = title.lowercased()
        if ["劇場", "剧场", "映画", "movie"].contains(where: title.contains) { return "movie" }
        if ["ova", "oad"].contains(where: title.contains) { return "ova" }
        if ["web", "ona"].contains(where: title.contains) { return "web" }
        if ["tv", "電視", "电视"].contains(where: title.contains) { return "tv" }
        return nil
    }
    private static func normalize(_ title: String) -> String {
        let value = title.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? title
        return value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private static func base(_ title: String) -> String {
        var value = seasons.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
        value = years.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        for marker in ["TV", "WEB", "OVA", "OAD", "ONA", "Movie", "劇場版", "剧场版", "映画"] {
            value = value.replacingOccurrences(of: marker, with: "", options: .caseInsensitive)
        }
        return normalize(value)
    }
    private static func year(_ title: String) -> Int? {
        guard let match = years.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range, in: title) else { return nil }
        return Int(title[range])
    }
    static func evidence(anime: Anime, title: String) -> (compatible: Bool, trusted: Bool) {
        let titles = [anime.name, anime.name_cn ?? ""].filter { !$0.isEmpty }
        let targetSeason = titles.compactMap(season).first
        let sourceSeason = season(title)
        let targetYear = anime.date.flatMap { Int($0.prefix(4)) }
        let sourceYear = year(title)
        let targetFormat = format(anime.platform ?? "") ?? titles.compactMap(format).first
        let sourceFormat = format(title)
        let exact = titles.contains { !base($0).isEmpty && base($0) == base(title) }
        let compatible = exact && (sourceSeason == nil || sourceSeason == (targetSeason ?? 1)) &&
            (targetYear == nil || sourceYear == nil || targetYear == sourceYear) &&
            (targetFormat == nil || sourceFormat == nil || targetFormat == sourceFormat)
        // Stage ranges need desktop's richer numbering evidence; retaining them in the exact title
        // and requiring their explicit season is conservative, but never grants automatic trust.
        let staged = titles.contains { $0.contains("阶段") || $0.contains("階段") || $0.contains("赛段") || $0.contains("賽段") || $0.lowercased().contains("stage") }
        return (compatible, compatible && !staged && targetYear != nil && targetYear == sourceYear &&
                targetFormat != nil && targetFormat == sourceFormat && (targetSeason == nil || targetSeason == sourceSeason))
    }
    static func episode(in catalog: MobileSourceCatalog, requested: CatalogEpisode, anime: Anime) -> MobileSourceEpisode? {
        guard requested.type == 0, requested.sort > 0, requested.ep == nil || requested.ep == requested.sort else { return nil }
        let targetSeason = [anime.name, anime.name_cn ?? ""].compactMap(season).first
        var matches: [MobileSourceEpisode] = []
        for line in catalog.lines {
            if let sourceSeason = season(line.title), sourceSeason != (targetSeason ?? 1) { continue }
            let hits = line.episodes.filter { episode in
                guard let match = labels.firstMatch(in: episode.title, range: NSRange(episode.title.startIndex..., in: episode.title)),
                      let range = Range(match.range(at: 1), in: episode.title) else { return false }
                return Double(episode.title[range]) == requested.sort
            }
            guard hits.count <= 1 else { return nil }
            matches += hits
        }
        // Line/quality selection is not an automatic preference. More than one leaf needs confirmation.
        return matches.count == 1 ? matches.first : nil
    }
}

@MainActor @Observable
final class MobileSourceDiscovery {
    private(set) var candidates: [MobileSourceCandidate] = []
    private(set) var failures: [PlaybackFailure] = []
    private(set) var busy = false
    private(set) var searched = false
    private(set) var automatic: MobileSourceCandidate?
    private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    deinit { task?.cancel() }

    func cancel() {
        generation += 1; task?.cancel(); task = nil; busy = false; automatic = nil
    }

    func find(anime: Anime, episode: CatalogEpisode, sources: [SourceConfiguration],
              library: MobileLibrary, authority: @escaping (String) throws -> String,
              client: @escaping (SourceConfiguration) -> MobileSourceClient = { .make(configuration: $0) }) {
        cancel(); candidates = []; failures = []; searched = false
        // An invalid stored choice is still a choice: only explicit durable deletion unlocks discovery.
        guard library.isReadable, library.storedMapping(for: .bangumi(anime.id),
            episode: .bangumi(episode.id, type: episode.type, sort: episode.sort)) == nil else { return }
        let expected = generation
        busy = true
        task = Task { [weak self] in
            var found: [MobileSourceCandidate] = []
            var errors: [PlaybackFailure] = []
            var allComplete = true
            for configuration in sources.sorted(by: { $0.id < $1.id }) {
                do {
                    try Task.checkCancellation()
                    guard try authority(configuration.id) == configuration.configurationRevision else { throw PlaybackFailure.configurationChanged }
                    let api = client(configuration)
                    try api.require(.search); try api.require(.episodes); try api.require(.resolve); try api.require(.mpv)
                    var seen = Set<String>()
                    let aliases = Array(Set([anime.title, anime.name].filter { !$0.isEmpty })).sorted()
                    for alias in aliases {
                        let page = try await api.search(alias)
                        try Task.checkCancellation()
                        guard try authority(configuration.id) == configuration.configurationRevision else { throw PlaybackFailure.configurationChanged }
                        if page.nextPage != nil { allComplete = false }
                        if page.works.count > 8 { allComplete = false }
                        for work in page.works.prefix(8) where seen.insert(work.id).inserted {
                            let evidence = MobileSourceTrust.evidence(anime: anime, title: work.title)
                            guard evidence.compatible else { continue }
                            let catalog = try await api.catalog(work)
                            try Task.checkCancellation()
                            guard try authority(configuration.id) == configuration.configurationRevision else { throw PlaybackFailure.configurationChanged }
                            let actual = MobileSourceTrust.evidence(anime: anime, title: catalog.work.title)
                            let leaf = MobileSourceTrust.episode(in: catalog, requested: episode, anime: anime)
                            if leaf == nil { errors.append(.missingEpisode) }
                            found.append(MobileSourceCandidate(configuration: configuration, catalog: catalog,
                                episode: leaf, trusted: evidence.trusted && actual.trusted && leaf != nil))
                        }
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    let failure = MobileSourceClient.failure(for: error)
                    if failure != .sourceDisabled { allComplete = false; errors.append(failure) }
                }
            }
            guard let self, self.generation == expected, !Task.isCancelled else { return }
            // Revalidate the entire search set at issuance; a later disabled/config-changed candidate
            // cannot turn an ambiguous report into an apparently unique automatic choice.
            for candidate in found {
                do {
                    guard try authority(candidate.configuration.id) == candidate.configuration.configurationRevision else { throw PlaybackFailure.configurationChanged }
                } catch { allComplete = false; errors.append(MobileSourceClient.failure(for: error)) }
            }
            guard library.isReadable, library.storedMapping(for: .bangumi(anime.id),
                episode: .bangumi(episode.id, type: episode.type, sort: episode.sort)) == nil else { self.cancel(); return }
            self.candidates = found; self.failures = Array(Set(errors)); self.busy = false; self.searched = true
            self.automatic = allComplete && found.count == 1 && found[0].trusted ? found[0] : nil
            self.task = nil
        }
    }
}
