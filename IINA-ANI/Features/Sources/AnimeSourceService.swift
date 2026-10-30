import Foundation

struct AnimeSourceCandidate: Sendable, Identifiable {
    let id: String
    let sourceName: String
    let title: String
    let selection: PlayableSelection?
    let evidence: String
    let failure: String?
    let trusted: Bool
}

struct AnimeSourceReport: Sendable {
    let candidates: [AnimeSourceCandidate]
    var matchedCandidates: [AnimeSourceCandidate] {
        candidates.filter { $0.failure == nil && $0.selection != nil }
    }
    var automaticCandidates: [AnimeSourceCandidate] {
        candidates.filter { $0.trusted && $0.failure == nil && $0.selection != nil }
    }
}

/// Searches only on an explicit episode-play action. Page identities, never media URLs or
/// catalog positions, cross the persistence boundary. All decoder calls are pinned guest.
@MainActor
final class AnimeSourceService {
    struct Dependencies: Sendable {
        var descriptors: @Sendable () async -> [SourceDescriptor]
        var enabled: @Sendable (String) -> Bool
        var search: @Sendable (String, String) async throws -> SourceSearchPage
        var selection: @Sendable (String) async throws -> PlayableSelection
        var catalog: @Sendable (PlayableSelection) async throws -> VideoSelectionCatalog?
        var decode: @Sendable (PlayableSelection) async throws -> YouGetJSON
        var prepare: @Sendable (YouGetJSON, String) async throws -> YouGetJSON
        var mappingSelection: @Sendable (PlayableSelection) throws -> (selection: PlayableSelection, revision: String, configured: Bool)
        var mappingRevision: @Sendable (String) throws -> String
    }

    enum SourceError: Error, LocalizedError {
        case invalidContext, unavailable, unresolved, storage
        case failure(PlaybackFailure)
        var errorDescription: String? {
            switch self {
            case .invalidContext: return String(localized: "此候選不屬於當前作品／集數。")
            case .unavailable: return String(localized: "此來源沒有可用的公開播放網址。")
            case .unresolved: return String(localized: "來源尚未成功解析，不會保存關聯。")
            case .failure(let failure): return AnimeSourceService.failureDescription(failure)
            case .storage: return String(localized: "播放來源已解析，但映射保存失敗；請檢查本機儲存後重試。")
            }
        }
    }

    private struct Issued {
        let work: Work
        let episode: Episode
        let revision: String
        let title: String
        let sourceWork: SourceItemRef
        let selection: PlayableSelection
        var resolved: PlayableSelection?
        var catalogGroup: [String]?
        var resolutionID: UUID?
    }
    private struct CandidateIdentity: Hashable {
        let work: SourceItemRef
        let episode: SourceItemRef?
        init(_ selection: PlayableSelection) { work = selection.item; episode = selection.episode }
    }
    private struct SearchOutcome: Sendable {
        let source: SourceDescriptor
        let results: [(SourceSearchResult, Evidence)]
        let failures: [String]
    }
    private let dependencies: Dependencies
    private var issued: [String: Issued] = [:]
    private var generation: UInt64 = 0

    init(decoder: VideoDecoder) {
        dependencies = Dependencies(
            descriptors: { await decoder.sourceDescriptors() }, enabled: { decoder.isSourceEnabled($0) },
            search: { try await decoder.searchSource(sourceID: $0, query: $1, page: 1, classifyWithBangumi: true) },
            selection: { try await decoder.guestSelection(for: $0) },
            catalog: { try await decoder.catalog(for: $0) },
            decode: { try await decoder.resolve($0) },
            prepare: { try await decoder.prepareVideoUrl($0, $1) },
            mappingSelection: { try decoder.mappingSelection($0) },
            mappingRevision: { try decoder.mappingRevision($0) })
    }

    /// Offline behavioral tests inject the existing decoder boundaries, not a second resolver.
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    func discover(work: Work, episode: Episode, links: [WorkSourceLink],
                  forceSearch: Bool = false) async throws -> AnimeSourceReport {
        try Task.checkCancellation()
        guard work.classification.kind == .anime, episode.workID == work.id else { throw SourceError.invalidContext }
        generation &+= 1
        let requestGeneration = generation
        issued.removeAll()
        let descriptors = await dependencies.descriptors()
        try Task.checkCancellation()
        let names = Dictionary(descriptors.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var candidates: [AnimeSourceCandidate] = []
        var seen: Set<CandidateIdentity> = []
        for link in links where link.workID == work.id {
            for mapping in link.episodeMappings where mapping.episodeID == episode.id {
                let name = names[mapping.selection.item.sourceID] ?? mapping.selection.item.sourceID
                do {
                    let authority = try current(mapping.selection)
                    let choice = authority.selection
                    guard choice.item.sourceID == link.sourceWork.sourceID else { throw SourceError.invalidContext }
                    if let confirmation = mapping.confirmation {
                        guard confirmation.matches(work: Self.workIdentity(work), episode: Self.episodeIdentity(episode, work: work)),
                              confirmation.context.selection == choice,
                              confirmation.context.configurationRevision == authority.revision else {
                            throw SourceError.failure(.configurationChanged)
                        }
                    } else if authority.configured {
                        throw SourceError.failure(.configurationChanged)
                    }
                    let group = try await validateCatalog(choice, work: work, episode: episode,
                        title: mapping.confirmation?.sourceTitle ?? work.title, revision: authority.revision)
                    guard mapping.catalogGroup == nil || mapping.catalogGroup == group else {
                        throw SourceError.failure(.missingEpisode)
                    }
                    guard generation == requestGeneration else { throw CancellationError() }
                    guard seen.insert(CandidateIdentity(choice)).inserted else { continue }
                    candidates.append(issue(work: work, episode: episode, sourceWork: choice.item,
                        name: name, title: mapping.confirmation?.sourceTitle ?? work.title,
                        selection: choice, evidence: String(localized: "已保存的作品／集數映射"), failure: nil, trusted: true,
                        catalogGroup: group))
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    candidates.append(issue(work: work, episode: episode, sourceWork: link.sourceWork,
                        name: name, title: work.title, selection: nil,
                        evidence: String(localized: "已保存的作品／集數映射"),
                        failure: Self.diagnostic(error), trusted: false))
                }
            }
        }
        if !forceSearch, !candidates.isEmpty {
            guard generation == requestGeneration else { throw CancellationError() }
            let blocked = candidates.contains { $0.failure != nil }
            return AnimeSourceReport(candidates: candidates.map {
                AnimeSourceCandidate(id: $0.id, sourceName: $0.sourceName, title: $0.title,
                    selection: $0.selection, evidence: $0.evidence, failure: $0.failure,
                    trusted: $0.trusted && !blocked)
            })
        }

        let aliases = Self.aliases(work)
        let sources = descriptors.filter {
            dependencies.enabled($0.id) && $0.capabilities.contains(.search) &&
            $0.capabilities.contains(.resolve) && ($0.capabilities.contains(.iina) || $0.capabilities.contains(.mpv))
        }.sorted { $0.id < $1.id }
        let revisions = Dictionary(uniqueKeysWithValues: sources.compactMap { source in
            (try? dependencies.mappingRevision(source.id)).map { (source.id, $0) }
        })
        let dependencies = self.dependencies
        // Three in-flight sources, four aliases and at most eight plausible works/source.
        let outcomes = try await Self.bounded(sources, limit: 3) { source in
            var hits: [(SourceSearchResult, Evidence)] = [], rejected: [(SourceSearchResult, Evidence)] = []
            var seen: Set<SourceItemRef> = [], failures: [String] = []
            for alias in aliases {
                try Task.checkCancellation()
                do {
                    let page = try await dependencies.search(source.id, alias)
                    try Task.checkCancellation()
                    guard dependencies.enabled(source.id) else { throw PlaybackFailure.sourceDisabled }
                    guard try dependencies.mappingRevision(source.id) == revisions[source.id] else {
                        throw PlaybackFailure.configurationChanged
                    }
                    for result in page.results where result.item.sourceID == source.id {
                        guard seen.insert(result.item).inserted else { continue }
                        let evidence = Self.workEvidence(work, result: result)
                        if evidence.conflict == nil {
                            if hits.count < 8 { hits.append((result, evidence)) }
                        } else if rejected.count < 8 {
                            rejected.append((result, evidence))
                        }
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    failures.append(Self.diagnostic(error))
                }
            }
            return SearchOutcome(source: source, results: hits + rejected, failures: failures)
        }
        guard generation == requestGeneration else { throw CancellationError() }
        for outcome in outcomes {
            if !outcome.failures.isEmpty || outcome.results.isEmpty {
                candidates.append(issue(work: work, episode: episode,
                    sourceWork: SourceItemRef(sourceID: outcome.source.id, pageURL: "", kind: .work),
                    name: outcome.source.name, title: work.title, selection: nil,
                    evidence: String(localized: "關鍵詞搜尋（\(aliases.count) 個名稱）"),
                    failure: outcome.failures.isEmpty ? String(localized: "搜尋沒有命中。") :
                        Array(Set(outcome.failures)).sorted().joined(separator: "\n"), trusted: false))
            }
        }
        let numbering = Self.episodeNumbering(work: work, episode: episode)
        let entries = outcomes.flatMap { outcome in outcome.results.map { (outcome.source, $0.0, $0.1) } }
        let evaluated = try await Self.bounded(entries, limit: 3) { entry -> (SourceDescriptor, SourceSearchResult, PlayableSelection?, String, String?, Bool) in
            let (source, result, evidence) = entry
            if let conflict = evidence.conflict { return (source, result, nil, evidence.description, conflict, false) }
            do {
                var choice = try await dependencies.selection(result.item.pageURL)
                choice.accountID = nil
                guard choice.item.sourceID == source.id, choice.torrent == nil,
                      choice.item.kind == .work || choice.item.kind == .episode else {
                    return (source, result, nil, evidence.description, String(localized: "不是番劇作品／集數頁。"), false)
                }
                choice.classification = work.classification
                guard let catalog = try await dependencies.catalog(choice) else {
                    return (source, result, nil, evidence.description, String(localized: "來源未提供明確集數清單。"), false)
                }
                try Task.checkCancellation()
                guard dependencies.enabled(source.id) else { throw PlaybackFailure.sourceDisabled }
                guard try dependencies.mappingRevision(source.id) == revisions[source.id] else {
                    throw PlaybackFailure.configurationChanged
                }
                let matched = Self.catalogMatch(catalog, episode: episode, work: work, sourceTitle: result.title, numbering: numbering)
                if let failure = matched.failure { return (source, result, nil, evidence.description, failure, false) }
                guard let leaf = matched.nodes.first else {
                    return (source, result, nil, evidence.description, String(localized: "缺少所選類型／集號的明確集數。"), false)
                }
                let exact = try await dependencies.selection(leaf.selectionURL)
                try Task.checkCancellation()
                guard exact.item.sourceID == source.id, exact.item.kind == .episode else {
                    return (source, result, nil, evidence.description, String(localized: "集數頁身份不屬於此來源。"), false)
                }
                choice.episode = exact.item
                choice.qualityID = nil
                choice.lineID = nil
                choice = try Self.animeSelection(dependencies.mappingSelection(choice).selection,
                    evidence: work.classification)
                guard try dependencies.mappingRevision(source.id) == revisions[source.id] else {
                    throw PlaybackFailure.configurationChanged
                }
                let savedWork = links.contains { $0.workID == work.id && $0.sourceWork == result.item }
                return (source, result, choice, evidence.description + String(localized: "；精確 \(episode.kind.displayTitle)／\(episode.sort) 集號") +
                    (matched.evidence.isEmpty ? "" : "；" + matched.evidence.joined(separator: "；")) +
                    (savedWork ? String(localized: "；已確認作品來源") : ""), nil, !evidence.manualOnly && !matched.manualOnly && (savedWork || evidence.corroborated))
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                return (source, result, nil, evidence.description, Self.diagnostic(error), false)
            }
        }
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        // Multiple plausible works remain a manual decision even if their titles coincide.
        let plausible = evaluated.filter { $0.2 != nil && $0.4 == nil }
        for (source, result, choice, evidence, failure, corroborated) in evaluated {
            if let choice, !seen.insert(CandidateIdentity(choice)).inserted { continue }
            candidates.append(issue(work: work, episode: episode, sourceWork: result.item,
                name: source.name, title: result.title, selection: choice, evidence: evidence +
                    (failure == nil && !corroborated ? String(localized: "；僅同名，不足自動綁定") : "") +
                    (plausible.count > 1 && choice != nil ? String(localized: "；多候選，請確認") : ""),
                failure: failure, trusted: corroborated && plausible.count == 1 && failure == nil,
                revision: revisions[source.id]))
        }
        return AnimeSourceReport(candidates: candidates)
    }

    func resolve(_ candidate: AnimeSourceCandidate) async throws -> YouGetJSON {
        try Task.checkCancellation()
        guard candidate.failure == nil, var record = issued[candidate.id], let requested = candidate.selection,
              Self.sameEpisode(requested, record.selection) else { throw SourceError.unavailable }
        let choice = try current(requested, revision: record.revision).selection
        issued[candidate.id]?.resolved = nil
        record.resolutionID = UUID()
        issued[candidate.id]?.resolutionID = record.resolutionID
        let group = try await validateCatalog(choice, work: record.work, episode: record.episode,
            title: record.title, revision: record.revision)
        try checkIssued(candidate.id, record: record)
        guard record.catalogGroup == nil || record.catalogGroup == group else { throw SourceError.failure(.missingEpisode) }
        issued[candidate.id]?.catalogGroup = group
        var result = try await dependencies.decode(choice)
        try Task.checkCancellation()
        try checkIssued(candidate.id, record: record)
        guard let decoded = result.selection,
              Self.sameEpisode(try current(decoded, revision: record.revision).selection, choice) else {
            throw SourceError.failure(.missingEpisode)
        }
        result.selection = choice // Prevent prepare from consulting a default account.
        guard let quality = choice.qualityID ?? result.videos.first?.key else { throw SourceError.unavailable }
        result = try await dependencies.prepare(result, quality)
        try Task.checkCancellation()
        try checkIssued(candidate.id, record: record)
        guard let prepared = result.selection,
              Self.sameEpisode(try current(prepared, revision: record.revision).selection, choice) else {
            throw SourceError.failure(.missingEpisode)
        }
        guard let stream = result.streams[quality] else { throw SourceError.unavailable }
        let line: Int
        if let lineID = choice.lineID {
            guard let parsed = Int(lineID) else { throw SourceError.unavailable }
            line = parsed
        } else { line = 0 }
        guard line >= 0, line <= stream.src.count else { throw SourceError.unavailable }
        let raw = line == 0 ? stream.url : stream.src[line - 1]
        guard let raw, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { throw SourceError.unavailable }
        try checkIssued(candidate.id, record: record)
        var resolved = choice
        resolved.qualityID = quality
        result.selection = resolved
        issued[candidate.id]?.resolved = resolved
        return result
    }

    /// Call only for the user's chosen candidate or a trusted automatic candidate, after resolve.
    func confirm(_ candidate: AnimeSourceCandidate, work: Work, episode: Episode, library: WorkLibrary) throws {
        try Task.checkCancellation()
        guard let record = issued[candidate.id], record.work == work, record.episode == episode,
              episode.workID == work.id, work.classification.kind == .anime,
              candidate.failure == nil, let choice = candidate.selection,
              Self.sameEpisode(choice, record.selection) else { throw SourceError.invalidContext }
        guard let resolved = record.resolved else { throw SourceError.unresolved }
        guard choice.qualityID == nil || choice.qualityID == resolved.qualityID,
              choice.lineID == resolved.lineID else { throw SourceError.invalidContext }
        guard let storedWork = try library.fetchWork(id: work.id),
              Self.workIdentity(storedWork) == Self.workIdentity(work),
              storedWork.classification == work.classification,
              let storedEpisode = try library.episodes(forWorkID: work.id).first(where: { $0.id == episode.id }),
              Self.episodeIdentity(storedEpisode, work: storedWork) == Self.episodeIdentity(episode, work: work) else {
            throw SourceError.failure(.configurationChanged)
        }
        let safe = try current(resolved, revision: record.revision).selection
        let context = PlaybackContext(work: Self.workIdentity(work), episode: Self.episodeIdentity(episode, work: work),
            selection: safe, configurationRevision: record.revision)
        let mapping = EpisodeSourceMapping(episodeID: episode.id, selection: safe,
            confirmation: ConfirmedSourceMapping(context: context, sourceTitle: record.title), catalogGroup: record.catalogGroup)
        do { try library.setPreferredMapping(mapping, forWorkID: work.id, sourceWork: record.sourceWork) }
        catch { throw SourceError.storage }
    }

    private nonisolated static func sameEpisode(_ lhs: PlayableSelection, _ rhs: PlayableSelection) -> Bool {
        lhs.item == rhs.item && lhs.episode == rhs.episode && lhs.torrent == rhs.torrent &&
            lhs.classification == rhs.classification
    }

    private func issue(work: Work, episode: Episode, sourceWork: SourceItemRef, name: String, title: String,
                       selection: PlayableSelection?, evidence: String, failure: String?, trusted: Bool,
                       catalogGroup: [String]? = nil, revision: String? = nil) -> AnimeSourceCandidate {
        let id = UUID().uuidString
        var safe = selection
        var diagnostic = failure
        if let selection {
            do {
                guard selection.item.sourceID == sourceWork.sourceID else { throw SourceError.invalidContext }
                let authority = try current(selection, revision: revision)
                safe = authority.selection
                issued[id] = Issued(work: work, episode: episode, revision: authority.revision,
                    title: title, sourceWork: authority.selection.item, selection: authority.selection, catalogGroup: catalogGroup)
            } catch {
                safe = nil
                diagnostic = Self.diagnostic(error)
            }
        }
        return AnimeSourceCandidate(id: id, sourceName: name, title: title, selection: safe,
                                    evidence: evidence, failure: diagnostic, trusted: trusted && diagnostic == nil)
    }

    private func current(_ selection: PlayableSelection, revision: String? = nil) throws
        -> (selection: PlayableSelection, revision: String, configured: Bool) {
        guard dependencies.enabled(selection.item.sourceID) else { throw SourceError.failure(.sourceDisabled) }
        do {
            let authority = try dependencies.mappingSelection(selection)
            guard revision == nil || revision == authority.revision else {
                throw SourceError.failure(.configurationChanged)
            }
            return (try Self.animeSelection(authority.selection, evidence: selection.classification),
                authority.revision, authority.configured)
        } catch let failure as PlaybackFailure { throw SourceError.failure(failure) }
    }

    /// A mixed-content source's lack of classification cannot erase a confirmed anime work.
    /// Explicit video/live source evidence is a conflict, never an invitation to relabel it.
    private nonisolated static func animeSelection(_ selection: PlayableSelection,
                                                   evidence: MediaClassification) throws -> PlayableSelection {
        guard evidence.kind == .anime else { throw SourceError.invalidContext }
        var safe = selection
        if safe.classification.kind == .unknown { safe.classification = evidence }
        guard safe.classification.kind == .anime else { throw SourceError.invalidContext }
        return safe
    }

    private func checkIssued(_ id: String, record: Issued) throws {
        guard let active = issued[id], active.work == record.work, active.episode == record.episode,
              active.selection == record.selection, active.revision == record.revision,
              active.resolutionID == record.resolutionID else { throw CancellationError() }
        _ = try current(record.selection, revision: record.revision)
    }

    /// Re-read the catalog, then compare exact page identities among typed episode matches.
    /// Never choose another line, the first leaf or a nearby episode when the saved leaf disappears.
    private func validateCatalog(_ choice: PlayableSelection, work: Work, episode: Episode,
                                 title: String, revision: String) async throws -> [String] {
        _ = try current(choice, revision: revision)
        guard let catalog = try await dependencies.catalog(choice) else { throw SourceError.failure(.missingEpisode) }
        try Task.checkCancellation()
        _ = try current(choice, revision: revision)
        guard catalog.selection.item == choice.item else { throw SourceError.failure(.missingEpisode) }
        let matches = Self.catalogMatch(catalog, episode: episode, work: work, sourceTitle: title,
            numbering: Self.episodeNumbering(work: work, episode: episode))
        guard matches.failure == nil else { throw SourceError.failure(.missingEpisode) }
        var groups: [[String]] = []
        for node in matches.nodes {
            let exact = try await dependencies.selection(node.selectionURL)
            try Task.checkCancellation()
            _ = try current(choice, revision: revision)
            var leaf = choice
            leaf.episode = exact.item
            let safe = try current(leaf, revision: revision).selection
            if safe.episode == (choice.episode ?? choice.item) {
                groups += Self.catalogGroups(for: node.selectionURL, in: catalog.nodes)
            }
        }
        guard groups.count == 1, let group = groups.first else { throw SourceError.failure(.missingEpisode) }
        return group
    }

    private nonisolated static func catalogGroups(for page: String, in nodes: [VideoTreeNode],
                                                  prefix: [String] = []) -> [[String]] {
        nodes.flatMap { node in
            if node.isLeaf { return node.selectionURL == page ? [prefix] : [] }
            return catalogGroups(for: page, in: node.children, prefix: prefix + [node.title])
        }
    }

    /// Manual mapping uses exactly the same fresh-catalog / decode / confirmation boundary.
    func candidate(for selection: PlayableSelection, work: Work, episode: Episode, title: String) throws -> AnimeSourceCandidate {
        guard work.classification.kind == .anime, episode.workID == work.id else { throw SourceError.invalidContext }
        let safe = try current(selection).selection
        let previous = issued.values.first {
            $0.work.id == work.id && $0.episode.id == episode.id &&
                $0.resolved.map { Self.sameEpisode($0, safe) } == true
        }
        return issue(work: work, episode: episode, sourceWork: safe.item, name: safe.item.sourceID,
            title: previous?.title ?? title, selection: safe, evidence: String(localized: "已保存的作品／集數映射"), failure: nil, trusted: false,
            catalogGroup: previous?.catalogGroup)
    }

    /// Call immediately at the actual player handoff, including after danmaku preparation.
    func validateHandoff(_ selection: PlayableSelection) throws {
        // Detail presentation may replace classification provenance with the local work's
        // evidence. That does not change the resolved media choice or its content kind.
        guard let record = issued.values.first(where: {
            guard let resolved = $0.resolved else { return false }
            return resolved.item == selection.item && resolved.episode == selection.episode &&
                resolved.qualityID == selection.qualityID && resolved.lineID == selection.lineID &&
                resolved.accountID == selection.accountID && resolved.torrent == selection.torrent &&
                resolved.classification.kind == selection.classification.kind
        }) else { throw SourceError.unresolved }
        _ = try current(selection, revision: record.revision)
    }

    private nonisolated static func workIdentity(_ work: Work) -> PlaybackWorkIdentity {
        PlaybackWorkIdentity(localID: work.id.uuidString, bangumiID: work.bangumiID)
    }

    private nonisolated static func episodeIdentity(_ episode: Episode, work: Work) -> PlaybackEpisodeIdentity {
        let id = episode.externalID.flatMap { $0.hasPrefix("bangumi:") ? Int($0.dropFirst(8)) : nil }
        let type: Int
        switch episode.kind {
        case .main: type = 0
        case .special: type = 1
        case .opening: type = 2
        case .ending: type = 3
        case .other: type = 4
        }
        let rawType = work.bangumiMetadata?.episodes.first(where: { $0.id == id })?.type ?? type
        return PlaybackEpisodeIdentity(localID: episode.id.uuidString, bangumiID: id, type: rawType, sort: episode.sort)
    }

    nonisolated static func diagnostic(_ error: Error) -> String {
        if let failure = error as? PlaybackFailure { return failureDescription(failure) }
        if let error = error as? SourceError { return error.localizedDescription }
        if let error = error as? SiteAccountError {
            switch error {
            case .disabled: return failureDescription(.sourceDisabled)
            case .needsLogin, .expired, .invalidAccount: return failureDescription(.authenticationRequired)
            default: return error.localizedDescription
            }
        }
        if let error = error as? VideoGetError {
            switch error {
            case .needLogin, .needPassWork: return failureDescription(.authenticationRequired)
            case .needVip, .cantWatch: return String(localized: "此影片不可觀看或需要來源會員權限。")
            case .notFountData, .notFindUrls, .notSupported: return failureDescription(.unsupportedResponse)
            case .invalidLink: return failureDescription(.missingEpisode)
            default: return error.localizedDescription
            }
        }
        if error is SourceConfiguration.ConfigurationError { return failureDescription(.unsupportedResponse) }
        let underlying = error as NSError
        if error is URLError || underlying.domain == NSURLErrorDomain ||
            (underlying.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain == NSURLErrorDomain {
            return failureDescription(.network)
        }
        // Keep adapter-owned diagnostics (VIP, region, response parsing) rather than inventing auth failures.
        return error.localizedDescription
    }

    private nonisolated static func failureDescription(_ failure: PlaybackFailure) -> String {
        switch failure {
        case .sourceDisabled: return String(localized: "來源已停用；請在設定啟用後重試，不會自動換站。")
        case .configurationChanged: return String(localized: "來源配置或保存的集數身份已變更；請按重新尋源並明確確認，原映射保留。")
        case .missingEpisode: return String(localized: "原來源已缺少完全相同的集數／線路；請重新尋源確認，不會改播第一集。")
        case .authenticationRequired: return String(localized: "來源要求登入或授權；請在原站確認可用性後重試，不會保存失敗映射。")
        case .network: return String(localized: "來源網路請求失敗；請檢查連線後重試，原映射保留。")
        case .unsupportedResponse: return String(localized: "來源回應無法安全解析；請檢查來源配置後重新尋源。")
        default: return String(localized: "此來源沒有可用的公開播放網址。")
        }
    }

    private nonisolated static func bounded<Input: Sendable, Output: Sendable>(_ inputs: [Input], limit: Int,
        operation: @escaping @Sendable (Input) async throws -> Output) async throws -> [Output] {
        try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var next = 0, results: [Int: Output] = [:]
            for _ in 0..<min(limit, inputs.count) {
                let index = next; next += 1
                group.addTask { (index, try await operation(inputs[index])) }
            }
            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                results[index] = result
                if next < inputs.count {
                    let index = next; next += 1
                    group.addTask { (index, try await operation(inputs[index])) }
                }
            }
            return inputs.indices.compactMap { results[$0] }
        }
    }

    private nonisolated static func aliases(_ work: Work) -> [String] {
        let subject = work.bangumiMetadata?.subject
        let title = stageTitle(work.title).title
        let base = seasonPattern.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = base.split(whereSeparator: \.isWhitespace)
        let component = components.count > 1 && (components.first?.count ?? 0) >= 4 ? String(components[0]) : ""
        var seen: Set<String> = []
        return ([work.title, base, component, subject?.name ?? "", subject?.nameCN ?? ""] + work.aliases + (subject?.aliases ?? []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(normalize($0)).inserted }.prefix(4).map { $0 }
    }

    private struct Evidence: Sendable {
        let description: String
        let conflict: String?
        let corroborated: Bool
        let manualOnly: Bool
    }
    private enum Format: String { case tv, web, ova, movie }
    private nonisolated static func format(_ value: String) -> Format? {
        let value = value.lowercased()
        if value.contains("劇場") || value.contains("剧场") || value.contains("映画") || value.contains("movie") { return .movie }
        if value.contains("ova") || value.contains("oad") { return .ova }
        if value.contains("web") || value.contains("ona") { return .web }
        if value.contains("tv") || value.contains("電視") || value.contains("电视") { return .tv }
        return nil
    }
    private nonisolated static let seasonPattern = try! NSRegularExpression(pattern: #"(?:第\s*([0-9一二三四五六七八九十IVXⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]+)\s*[季期]|season\s*([0-9IVXⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]+)\b|\bs([0-9]+)\b)"#, options: .caseInsensitive)
    private nonisolated static let yearPattern = try! NSRegularExpression(pattern: "(?<![0-9])(?:19|20)[0-9]{2}(?![0-9])")
    private nonisolated static let episodePattern = try! NSRegularExpression(pattern: "^(?:(sp|special|特别篇|特別篇|ova|oad|op|opening|ed|ending)\\s*(?:第\\s*)?|第\\s*|ep(?:isode)?\\s*)?([0-9]+(?:\\.[0-9]+)?)(?:\\s*[集话話回])?(?:$|[\\s:：._-])", options: .caseInsensitive)
    private nonisolated static let stagePattern = try! NSRegularExpression(pattern: #"(?:第\s*[0-9一二三四五六七八九十]+(?:\s*[&＆、,，/-]\s*(?:第\s*)?[0-9一二三四五六七八九十]+)*\s*(?:赛段|賽段|阶段|階段)|[0-9]+(?:st|nd|rd|th)(?:\s*[&＆、,，/-]\s*[0-9]+(?:st|nd|rd|th))*\s+stages?)\s*(?=$|[\[（(【])"#, options: .caseInsensitive)
    private nonisolated static let stageNumberPattern = try! NSRegularExpression(pattern: #"[0-9]+|[一二三四五六七八九十]+"#)
    private nonisolated static let ordinalNumbers = [
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
        "I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6, "VII": 7, "VIII": 8, "IX": 9, "X": 10,
        "Ⅰ": 1, "Ⅱ": 2, "Ⅲ": 3, "Ⅳ": 4, "Ⅴ": 5, "Ⅵ": 6, "Ⅶ": 7, "Ⅷ": 8, "Ⅸ": 9, "Ⅹ": 10]
    private nonisolated static let numericTitleScalars = CharacterSet(charactersIn: "0123456789一二三四五六七八九十")
    private nonisolated static func stageTitle(_ value: String) -> (title: String, stages: Set<Int>?) {
        guard let match = capture(stagePattern, value), let range = Range(match.range, in: value) else { return (value, nil) }
        let marker = String(value[range])
        let numbers = stageNumberPattern.matches(in: marker, range: NSRange(marker.startIndex..., in: marker))
        var stages: Set<Int> = []
        for match in numbers {
            guard let range = Range(match.range, in: marker) else { return (value, nil) }
            let raw = String(marker[range])
            guard let number = Int(raw) ?? ordinalNumbers[raw] else { return (value, nil) }
            stages.insert(number)
        }
        guard !stages.isEmpty else { return (value, nil) }
        var title = value
        title.removeSubrange(range)
        return (title, stages)
    }

    /// Rotate only complete whitespace-delimited title components, never arbitrary substrings.
    /// Comparing the entire normalized name also supports a source omitting the separator.
    private nonisolated static func rotatedTitleMatches(_ target: String, source: String) -> Bool {
        let components = target.split(whereSeparator: \.isWhitespace).map { baseTitle(String($0)) }.filter { !$0.isEmpty }
        guard components.count > 1 else { return false }
        let complete = components.joined()
        guard complete.count == source.count else { return false }
        var boundary = complete.startIndex
        for component in components {
            if source.hasPrefix(complete[boundary...]) && source.hasSuffix(complete[..<boundary]) { return true }
            boundary = complete.index(boundary, offsetBy: component.count)
        }
        return false
    }
    private nonisolated static func capture(_ regex: NSRegularExpression, _ value: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    }
    private nonisolated static func season(_ value: String) -> Int? {
        guard let match = capture(seasonPattern, value) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: value) {
                let number = String(value[range])
                return Int(number) ?? ordinalNumbers[number.uppercased()]
            }
        }
        return nil
    }
    private nonisolated static func normalize(_ value: String) -> String {
        let simplified = value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value
        return simplified.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    private nonisolated static func baseTitle(_ value: String) -> String {
        var title = seasonPattern.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        title = yearPattern.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: "")
        for marker in ["TV", "WEB", "OVA", "OAD", "ONA", "Movie", "劇場版", "剧场版", "映画"] {
            title = title.replacingOccurrences(of: marker, with: "", options: .caseInsensitive)
        }
        return normalize(title)
    }

    /// Small spelling differences can suggest a manual candidate, not establish work identity.
    /// A two-edit cap and 15% limit exclude short names and different series subtitles.
    private nonisolated static func similarTitle(_ target: String, source: String) -> Bool {
        let targetLength = target.count, sourceLength = source.count
        let limit = min(2, max(targetLength, sourceLength) * 15 / 100)
        guard min(targetLength, sourceLength) >= 8, limit > 0,
              abs(targetLength - sourceLength) <= limit else { return false }
        guard target.unicodeScalars.lazy.filter({ numericTitleScalars.contains($0) })
            .elementsEqual(source.unicodeScalars.lazy.filter({ numericTitleScalars.contains($0) })) else { return false }
        let a = Array(target), b = Array(source)
        var previous = Array(repeating: limit + 1, count: b.count + 1)
        var current = previous
        for j in 0...min(limit, b.count) { previous[j] = j }
        for i in 1...a.count {
            let lower = max(1, i - limit), upper = min(b.count, i + limit)
            current[lower - 1] = lower == 1 ? i : limit + 1
            var best = limit + 1
            for j in lower...upper {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                best = min(best, current[j])
            }
            if upper < b.count { current[upper + 1] = limit + 1 }
            guard best <= limit else { return false }
            swap(&previous, &current)
        }
        return previous[b.count] <= limit
    }
    private nonisolated static func workEvidence(_ work: Work, result: SourceSearchResult) -> Evidence {
        let subject = work.bangumiMetadata?.subject
        let titles = [work.title, subject?.name ?? "", subject?.nameCN ?? ""] + work.aliases + (subject?.aliases ?? [])
        let targetTitles = titles.map(stageTitle)
        let sourceTitle = stageTitle(result.title)
        let sourceBase = baseTitle(sourceTitle.title)
        let orderedMatch = targetTitles.contains { !baseTitle($0.title).isEmpty && baseTitle($0.title) == sourceBase }
        let rotatedMatch = !orderedMatch && targetTitles.contains { rotatedTitleMatches($0.title, source: sourceBase) }
        let approximateMatch = !orderedMatch && !rotatedMatch && targetTitles.contains { similarTitle(baseTitle($0.title), source: sourceBase) }
        let titleMatches = orderedMatch || rotatedMatch || approximateMatch
        let targetStages = targetTitles.compactMap(\.stages).first
        let unmarkedStages = targetStages != nil && sourceTitle.stages == nil
        let targetSeason = titles.compactMap(season).first
        let sourceSeason = season(result.title)
        let targetFormat = format(subject?.platform ?? "") ?? titles.compactMap(format).first
        let sourceFormat = format(result.title)
        let targetYear = work.year ?? subject?.date.flatMap { Int($0.prefix(4)) }
        let sourceYear = capture(yearPattern, result.title).flatMap { Range($0.range, in: result.title) }.flatMap { Int(result.title[$0]) }
        let evidence = String(localized: "搜尋命中；") + (titleMatches ? String(localized: "名稱一致") : String(localized: "名稱不一致")) +
            (sourceSeason.map { String(localized: "；第\($0)季") } ?? "") + (sourceYear.map { String(localized: "；\($0)年") } ?? "") +
            (sourceFormat.map { "；\($0.rawValue.uppercased())" } ?? "") +
            (rotatedMatch ? String(localized: "；完整標題成分順序不同") : "") +
            (approximateMatch ? String(localized: "；名稱近似，需手動確認") : "") +
            (unmarkedStages ? String(localized: "；來源分段未標，需手動確認") : "") +
            (sourceTitle.stages.map { String(localized: "；分段 ") + $0.sorted().map(String.init).joined(separator: ",") } ?? "")
        let conflict: String?
        if result.classification.kind == .video || result.classification.kind == .live { conflict = String(localized: "此命中不是動畫作品。") }
        else if !titleMatches { conflict = String(localized: "作品名稱證據不一致。") }
        else if let sourceStages = sourceTitle.stages, let targetStages, sourceStages != targetStages { conflict = String(localized: "分段衝突，不能選用。") }
        else if sourceTitle.stages != nil && targetStages == nil { conflict = String(localized: "來源明示分段，但作品沒有相同分段證據。") }
        else if let sourceSeason, sourceSeason != (targetSeason ?? 1) { conflict = String(localized: "季別衝突，不能選用。") }
        else if let targetYear, let sourceYear, targetYear != sourceYear { conflict = String(localized: "年份衝突，不能選用。") }
        else if let targetFormat, let sourceFormat, targetFormat != sourceFormat { conflict = String(localized: "作品型態衝突，不能選用。") }
        else { conflict = nil }
        // Title-derived classification (including Bangumi same-title lookup) is not independent
        // corroboration. Require release-year AND explicit subtype evidence as well as title.
        let manualOnly = unmarkedStages || rotatedMatch || approximateMatch
        let corroborated = titleMatches && conflict == nil && !manualOnly && targetYear != nil && targetYear == sourceYear &&
            targetFormat != nil && targetFormat == sourceFormat && (targetSeason == nil || targetSeason == sourceSeason)
        return Evidence(description: evidence, conflict: conflict, corroborated: corroborated, manualOnly: manualOnly)
    }
    private nonisolated static func leaves(_ nodes: [VideoTreeNode]) -> [VideoTreeNode] {
        nodes.flatMap { $0.isLeaf ? [$0] : leaves($0.children) }
    }
    private struct EpisodeLabel {
        let number: Double
        let kind: Episode.Kind
        let title: String
    }
    private struct EpisodeNumbering: Sendable {
        struct Anchor: Sendable { let id: Int; let absolute: Double; let relative: Double }
        let selected: Anchor
        let firstAbsolute: Double
        let lastRelative: Double
        let names: [String: Anchor]
    }
    private struct CatalogMatch {
        var nodes: [VideoTreeNode] = []
        var evidence: [String] = []
        var manualOnly = false
        var failure: String?
    }

    private nonisolated static func episodeNumbering(work: Work, episode: Episode) -> EpisodeNumbering? {
        guard episode.kind == .main, let externalID = episode.externalID,
              let episodes = work.bangumiMetadata?.episodes,
              let selected = episodes.first(where: { "bangumi:\($0.id)" == externalID && $0.type == 0 }),
              selected.sort == episode.sort, let relative = selected.ep, relative.isFinite, relative > 0 else { return nil }
        var names: [String: EpisodeNumbering.Anchor] = [:], ambiguous: Set<String> = []
        var firstAbsolute: Double?, lastRelative = relative
        for item in episodes where item.type == 0 {
            guard let ep = item.ep, ep.isFinite, ep > 0 else { continue }
            lastRelative = max(lastRelative, ep)
            let anchor = EpisodeNumbering.Anchor(id: item.id, absolute: item.sort, relative: ep)
            if ep == 1 { firstAbsolute = firstAbsolute.map { min($0, item.sort) } ?? item.sort }
            for title in [item.name, item.nameCN] {
                let key = normalize(title)
                guard key.count >= 4, !ambiguous.contains(key) else { continue }
                if let previous = names[key], previous.id != item.id { names.removeValue(forKey: key); ambiguous.insert(key) }
                else { names[key] = anchor }
            }
        }
        return EpisodeNumbering(selected: .init(id: selected.id, absolute: selected.sort, relative: relative),
            firstAbsolute: firstAbsolute ?? selected.sort - relative + 1, lastRelative: lastRelative, names: names)
    }

    private nonisolated static let episodeRangePattern = try! NSRegularExpression(pattern: #"^\s*[-–—~～至]\s*[0-9]"#)
    private nonisolated static func episodeLabel(_ leaf: VideoTreeNode) -> EpisodeLabel? {
        let label = leaf.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = capture(episodePattern, label), let range = Range(match.range(at: 2), in: label),
              let number = Double(label[range]), number.isFinite,
              capture(episodeRangePattern, String(label[range.upperBound...])) == nil,
              let prefix = Range(match.range, in: label) else { return nil }
        let marker = Range(match.range(at: 1), in: label).map { String(label[$0]).lowercased() } ?? ""
        let kind: Episode.Kind
        switch marker {
        case "sp", "special", "特别篇", "特別篇", "ova", "oad": kind = .special
        case "op", "opening": kind = .opening
        case "ed", "ending": kind = .ending
        default: kind = .main
        }
        return EpisodeLabel(number: number, kind: kind,
            title: String(label[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
    }

    /// Each line owns its numbering scheme. Source order and decoder indexes are not evidence.
    private nonisolated static func catalogMatch(_ catalog: VideoSelectionCatalog, episode: Episode, work: Work,
        sourceTitle: String, numbering: EpisodeNumbering?) -> CatalogMatch {
        let lines: [(String, [VideoTreeNode])] = catalog.nodes.contains(where: \.isLeaf)
            ? [(sourceTitle, leaves(catalog.nodes))] : catalog.nodes.map { ($0.title, leaves([$0])) }
        var result = CatalogMatch(), pages: Set<String> = []
        let targetTitles = [work.title, work.bangumiMetadata?.subject.name ?? "", work.bangumiMetadata?.subject.nameCN ?? ""]
        let targetSeason = targetTitles.compactMap(season).first
        let targetStages = targetTitles.compactMap { stageTitle($0).stages }.first
        for (lineTitle, leaves) in lines {
            if let lineSeason = season(lineTitle), let targetSeason, lineSeason != targetSeason { continue }
            if let lineStages = stageTitle(lineTitle).stages, let targetStages, lineStages != targetStages { continue }
            let available = leaves.filter { !$0.selectionURL.isEmpty }
            var matches: [VideoTreeNode]
            var note: String?
            if let numbering, numbering.selected.absolute != numbering.selected.relative {
                let labeled = available.map { ($0, episodeLabel($0)) }
                var named: [VideoTreeNode] = []
                var absoluteAnchor = false, relativeAnchor = false
                var minimum: Double?, maximum: Double?
                for (node, label) in labeled {
                    if let label, label.kind == .main, label.number > 0 {
                        minimum = minimum.map { min($0, label.number) } ?? label.number
                        maximum = maximum.map { max($0, label.number) } ?? label.number
                    }
                    guard label == nil || label?.kind == .main else { continue }
                    let title = label?.title ?? node.title
                    guard !title.isEmpty, let anchor = numbering.names[normalize(title)] else { continue }
                    if anchor.id == numbering.selected.id { named.append(node) }
                    guard let label, anchor.absolute != anchor.relative else { continue }
                    if label.number == anchor.absolute { absoluteAnchor = true }
                    else if label.number == anchor.relative { relativeAnchor = true }
                    else { absoluteAnchor = true; relativeAnchor = true }
                }
                if !named.isEmpty {
                    matches = named
                    note = String(localized: "唯一官方集名對應")
                    result.manualOnly = true
                } else {
                    guard !(absoluteAnchor && relativeAnchor) else {
                        result.failure = String(localized: "同一線路的集名與連續／季度內編號證據衝突，不能猜測。"); return result
                    }
                    let sourceSeason = season(sourceTitle) ?? season(lineTitle)
                    let sourceStages = stageTitle(sourceTitle).stages ?? stageTitle(lineTitle).stages
                    let scoped = (targetSeason != nil && targetSeason == sourceSeason) ||
                        (targetStages != nil && targetStages == sourceStages) ||
                        targetTitles.contains { !normalize($0).isEmpty && normalize($0) == normalize(sourceTitle) }
                    let useRelative: Bool
                    if absoluteAnchor || relativeAnchor { useRelative = relativeAnchor }
                    else if scoped, let minimum {
                        if minimum < numbering.firstAbsolute { useRelative = true }
                        else if let maximum, maximum > numbering.lastRelative { useRelative = false }
                        else { result.failure = String(localized: "線路缺少能區分連續與季度內編號的集名或範圍證據。"); return result }
                    }
                    else { useRelative = false }
                    let number = useRelative ? numbering.selected.relative : numbering.selected.absolute
                    matches = labeled.filter { $0.1?.kind == .main && $0.1?.number == number }.map { $0.0 }
                    note = useRelative ? String(localized: "Bangumi 連續 \(episode.sort) → 條目內 \(number) 集號") : String(localized: "來源合併／連續 \(number) 集號")
                }
            } else {
                matches = available.filter { Self.matches($0, episode: episode, work: work) }
            }
            var linePages: Set<String> = []
            matches = matches.filter { linePages.insert($0.selectionURL).inserted }
            guard matches.count <= 1 else {
                result.failure = String(localized: "同一線路有多個相同集號或集名，無法確定集數。"); return result
            }
            if let match = matches.first, pages.insert(match.selectionURL).inserted {
                result.nodes.append(match)
                if let note, !result.evidence.contains(note) { result.evidence.append(note) }
            }
        }
        return result
    }

    private nonisolated static func matches(_ leaf: VideoTreeNode, episode: Episode, work: Work) -> Bool {
        guard !leaf.selectionURL.isEmpty else { return false }
        let label = leaf.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = episodeLabel(leaf), parsed.number == episode.sort { return parsed.kind == episode.kind }
        let movie = format(work.bangumiMetadata?.subject.platform ?? "") == .movie || format(work.title) == .movie
        if movie, episode.kind == .main, episode.sort == 1,
           ["正片", "全片", "全集", "movie", "劇場版", "剧场版"].contains(label.lowercased()) { return true }
        // Named non-main episodes require exact labels; neither sort nor position alone is evidence.
        return episode.kind != .main && !normalize(label).isEmpty && normalize(label) == normalize(episode.label)
    }
}
