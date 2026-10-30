import Foundation
import CryptoKit

struct PlaybackHistoryEntry: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let episodeTitle: String?
    let coverURL: String?
    let selection: PlayableSelection
    let position: Double
    let duration: Double?
    let updatedAt: Date
    let awaitingUpdates: Bool?
    var context: PlaybackContext? = nil
    var localFile: PlaybackLocalFileReference? = nil
}

enum PlaybackLocalFileAccessError: Error {
    case requiresAuthorization
}

/// A bookmark follows the original file; device/inode identity prevents a same-name
/// replacement or reauthorization from silently receiving another video's progress.
struct PlaybackLocalFileReference: Codable, Sendable {
    let bookmark: Data
    let resourceIdentity: String

    static func capture(_ url: URL) throws -> Self {
        let identity = try resourceIdentity(url)
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(options: [.withSecurityScope],
                includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            bookmark = try url.bookmarkData(options: [.minimalBookmark],
                includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        return Self(bookmark: bookmark, resourceIdentity: identity)
    }

    func resolve() throws -> URL {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try matches(url) else { throw CocoaError(.fileReadNoSuchFile) }
        return url
    }

    func matches(_ url: URL) throws -> Bool {
        try Self.resourceIdentity(url) == resourceIdentity
    }

    private static func resourceIdentity(_ url: URL) throws -> String {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values.isRegularFile == true, let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return device.stringValue + ":" + inode.stringValue
    }
}

/// Stores page/file identities only, never resolved streams or account credentials.
@MainActor
final class PlaybackHistoryStore {
    static let didChangeNotification = Notification.Name("PlaybackHistoryStore.didChange")
    private struct Archive: Codable { let version: Int; let entries: [PlaybackHistoryEntry] }
    private let url: URL
    private var entries: [String: PlaybackHistoryEntry] = [:]
    // Include zero-position and throttled replay events, even when no entry is written.
    private var latestProgressAt: [String: Date] = [:]
    private let registry: SourceRegistry
    private var recorderGeneration: UInt64 = 0
    private var activeRecorders: [String: UInt64] = [:]
    private var deletionGenerations: [String: UInt64] = [:]
    fileprivate struct RecorderToken {
        let id: String
        let generation: UInt64
        let deletionGeneration: UInt64
    }
    fileprivate struct DurableSelection {
        let selection: PlayableSelection
        let context: PlaybackContext?
        let localFile: PlaybackLocalFileReference?
    }
    var unfinished: [PlaybackHistoryEntry] { entries.values.sorted { $0.updatedAt > $1.updatedAt } }
    /// Episode progress stays independent; home shows only the latest watched anime episode per work.
    func continuing(downloads: [DownloadRecord]) -> [PlaybackHistoryEntry] {
        var records: [String: DownloadRecord] = [:]
        for record in downloads.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let source = Self.identity(record.selection)
            if records[source] == nil { records[source] = record }
            if let file = record.completedFile {
                let local = PlayableSelection(item: SourceItemRef(sourceID: "local", pageURL: file.absoluteString, kind: .local))
                let key = Self.identity(local)
                if records[key] == nil { records[key] = record }
            }
        }
        var seen = Set<String>()
        return unfinished.compactMap { entry in
            let record = records[entry.id]
            let selection = record?.selection ?? entry.selection
            guard selection.classification.kind == .anime else { return nil }
            let workKey: String
            if let id = record?.bangumiID { workKey = "bangumi:\(id)" }
            else if let id = record?.workID { workKey = "work:\(id)" }
            else if selection.episode != nil || selection.item.kind == .work {
                workKey = selection.item.sourceID + "\n" + selection.item.pageURL
            } else { workKey = entry.id }
            guard seen.insert(workKey).inserted else { return nil }
            return PlaybackHistoryEntry(id: entry.id, title: record?.title ?? entry.title,
                episodeTitle: Self.nonempty(record?.episodeTitle) ?? entry.episodeTitle,
                coverURL: Self.publicCover(record?.coverURL) ?? entry.coverURL, selection: entry.selection,
                position: entry.position, duration: entry.duration, updatedAt: entry.updatedAt,
                awaitingUpdates: entry.awaitingUpdates, context: entry.context, localFile: entry.localFile)
        }
    }
    init(url: URL, registry: SourceRegistry = .shared) throws {
        self.url = url
        self.registry = registry
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        for entry in archive.entries {
            // Reopening must not reinterpret a saved identity under a replacement configuration.
            let selection = try Self.archivedSelection(entry)
            guard Self.identity(selection) == entry.id, entry.position.isFinite, entry.position > 0,
                  entry.duration.map({ $0.isFinite && $0 > 0 && ($0 > entry.position || entry.awaitingUpdates == true) }) ?? true else { continue }
            entries[entry.id] = PlaybackHistoryEntry(id: entry.id, title: Self.mediaTitle(entry.title, selection: selection),
                episodeTitle: Self.nonempty(entry.episodeTitle), coverURL: Self.publicCover(entry.coverURL), selection: selection,
                position: entry.position, duration: entry.duration, updatedAt: entry.updatedAt,
                awaitingUpdates: entry.awaitingUpdates, context: entry.context, localFile: entry.localFile)
        }
    }

    func record(selection: PlayableSelection, title: String, coverURL: String?, position: Double,
                duration: Double?, completed: Bool, episodeTitle: String? = nil) throws {
        guard selection.classification.kind != .live, selection.item.kind != .live,
              position.isFinite, position >= 0 else { return }
        let durable = try durable(selection)
        let token = registerRecorder(for: Self.identity(durable.selection))
        try record(durable: durable, token: token, title: title, coverURL: coverURL,
                   position: position, duration: duration, completed: completed, episodeTitle: episodeTitle)
    }

    fileprivate func record(durable: DurableSelection, token: RecorderToken, title: String, coverURL: String?,
                            position: Double, duration: Double?, completed: Bool, episodeTitle: String?) throws {
        guard position.isFinite, position >= 0, claim(token) else { return }
        let selection = durable.selection
        let id = token.id
        let updatedAt = Date()
        noteProgress(for: id, at: updatedAt)
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var next = entries
        if completed || duration.map({ position >= $0 }) == true { next.removeValue(forKey: id) }
        else if position > 0 {
            next[id] = PlaybackHistoryEntry(id: id, title: Self.mediaTitle(title, selection: selection), episodeTitle: Self.nonempty(episodeTitle), coverURL: Self.publicCover(coverURL),
                selection: selection, position: position, duration: duration, updatedAt: updatedAt, awaitingUpdates: nil,
                context: durable.context, localFile: durable.localFile)
        } else { return }
        try save(next)
    }

    func remove(id: String) throws {
        if entries[id] != nil {
            var next = entries
            next.removeValue(forKey: id)
            try save(next)
        }
        // A failed delete leaves recorder ownership intact; an already absent
        // EOF entry still invalidates its pending completion/flush callbacks.
        deletionGenerations[id, default: 0] += 1
        activeRecorders.removeValue(forKey: id)
        noteProgress(for: id, at: Date())
    }

    /// Legacy configured progress stays visible, but cannot adopt replacement rules.
    func selectionForResume(_ entry: PlaybackHistoryEntry) throws -> PlayableSelection {
        guard let current = entries[entry.id], current.updatedAt == entry.updatedAt else {
            throw PlaybackFailure.cancelled
        }
        if entry.context == nil, registry.source(for: entry.selection.item.sourceID) != nil {
            throw PlaybackFailure.configurationChanged
        }
        let selection = try Self.archivedSelection(entry)
        guard selection.item.kind != .work || selection.episode != nil || selection.torrent != nil else {
            throw PlaybackFailure.missingEpisode
        }
        if let context = entry.context {
            guard let configuration = registry.source(for: selection.item.sourceID),
                  registry.loadError == nil,
                  configuration.configurationRevision == context.configurationRevision else {
                throw PlaybackFailure.configurationChanged
            }
            var canonical = try configuration.mappingSelection(selection)
            if canonical.classification.kind == .unknown { canonical.classification = selection.classification }
            guard canonical == selection else {
                throw PlaybackFailure.configurationChanged
            }
        }
        return selection
    }

    func localFileForResume(_ entry: PlaybackHistoryEntry, authorizedURL: URL? = nil) throws -> URL {
        guard entry.selection.item.sourceID == "local", entry.selection.item.kind == .local,
              let original = URL(string: entry.selection.item.pageURL), original.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let current = entries[entry.id] ?? entry
        let candidate: URL
        do {
            candidate = try authorizedURL ?? current.localFile?.resolve() ?? original
        } catch {
            if authorizedURL == nil { throw PlaybackLocalFileAccessError.requiresAuthorization }
            throw error
        }
        let scoped = candidate.startAccessingSecurityScopedResource()
        defer { if scoped { candidate.stopAccessingSecurityScopedResource() } }
        let reference: PlaybackLocalFileReference
        do {
            if let previous = current.localFile {
                guard try previous.matches(candidate) else { throw CocoaError(.fileReadNoSuchFile) }
            } else {
                // Legacy paths may be upgraded in place, not matched by basename.
                guard candidate.standardizedFileURL.resolvingSymlinksInPath() ==
                        original.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
            }
            reference = try PlaybackLocalFileReference.capture(candidate)
        } catch {
            if authorizedURL == nil { throw PlaybackLocalFileAccessError.requiresAuthorization }
            throw error
        }
        if var saved = entries[entry.id] {
            saved.localFile = reference
            var next = entries
            next[entry.id] = saved
            try save(next)
        }
        return candidate
    }

    func validateResumeCatalog(_ catalog: VideoSelectionCatalog, selection: PlayableSelection) throws {
        let target = selection.episode ?? selection.item
        guard catalog.selection.item.sourceID == selection.item.sourceID,
              selection.item.kind != .work || catalog.selection.item == selection.item else {
            throw PlaybackFailure.missingEpisode
        }
        func canonical(_ ref: SourceItemRef) -> SourceItemRef? {
            if let configuration = registry.source(for: selection.item.sourceID) {
                var choice = selection
                choice.episode = ref
                return (try? configuration.mappingSelection(choice))?.episode
            }
            return try? registry.item(for: ref.pageURL)
        }
        guard let expected = canonical(target) else { throw PlaybackFailure.missingEpisode }
        func matches(_ nodes: [VideoTreeNode]) -> Int {
            nodes.reduce(0) { count, node in
                guard node.isLeaf else { return count + matches(node.children) }
                guard !node.isLiving, node.site.sourceID == target.sourceID,
                      let ref = try? registry.item(for: node.selectionURL),
                      canonical(ref) == expected else { return count }
                return count + 1
            }
        }
        guard matches(catalog.nodes) == 1 else { throw PlaybackFailure.missingEpisode }
    }

    func validateResolvedSelection(_ resolved: PlayableSelection?, requested: PlayableSelection) throws {
        guard let resolved else { throw PlaybackFailure.missingEpisode }
        let candidate: PlayableSelection
        if let configuration = registry.source(for: requested.item.sourceID) {
            candidate = try configuration.mappingSelection(resolved)
        } else {
            candidate = try Self.nativeSelection(resolved)
        }
        guard candidate.item == requested.item, candidate.episode == requested.episode,
              candidate.lineID == requested.lineID,
              requested.qualityID == nil || candidate.qualityID == requested.qualityID else {
            throw PlaybackFailure.missingEpisode
        }
    }

    fileprivate func prepareRecorder(_ selection: PlayableSelection) throws -> (DurableSelection, RecorderToken) {
        let value = try durable(selection)
        return (value, registerRecorder(for: Self.identity(value.selection)))
    }

    private func registerRecorder(for id: String) -> RecorderToken {
        recorderGeneration += 1
        return RecorderToken(id: id, generation: recorderGeneration,
                             deletionGeneration: deletionGenerations[id, default: 0])
    }

    fileprivate func claim(_ token: RecorderToken) -> Bool {
        guard deletionGenerations[token.id, default: 0] == token.deletionGeneration,
              activeRecorders[token.id, default: 0] <= token.generation else { return false }
        activeRecorders[token.id] = token.generation
        return true
    }

    fileprivate func noteProgress(for id: String, at date: Date) {
        latestProgressAt[id] = max(latestProgressAt[id] ?? date, date)
    }

    /// EOF is real playback, but an unconfirmed season must remain available for updates.
    fileprivate func retainForUpdates(durable: DurableSelection, token: RecorderToken, title: String, coverURL: String?,
                                      position: Double, duration: Double?, episodeTitle: String?,
                                      through completedAt: Date) throws {
        guard position.isFinite, position > 0, claim(token) else { return }
        let selection = durable.selection
        let id = token.id
        guard (latestProgressAt[id].map { $0 <= completedAt } ?? true),
              (entries[id].map { $0.updatedAt <= completedAt } ?? true) else { return }
        guard entries[id]?.awaitingUpdates != true || entries[id]?.updatedAt != completedAt else { return }
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var next = entries
        next[id] = PlaybackHistoryEntry(id: id, title: Self.mediaTitle(title, selection: selection),
            episodeTitle: Self.nonempty(episodeTitle), coverURL: Self.publicCover(coverURL), selection: selection,
            position: position, duration: duration, updatedAt: completedAt, awaitingUpdates: true,
            context: durable.context, localFile: durable.localFile)
        try save(next)
    }

    /// Clear only the confirmed catalog group, not titles or every entry for a work.
    /// A newer update from another player must survive an asynchronous catalog lookup.
    func removeCompletedSeason(_ items: [SourceItemRef], through completedAt: Date,
                               registry: SourceRegistry) throws {
        func identity(_ item: SourceItemRef) -> SourceItemRef? {
            if item.sourceID == "local", item.kind == .local,
               let url = URL(string: item.pageURL), url.isFileURL {
                return SourceItemRef(sourceID: "local", pageURL: url.resolvingSymlinksInPath().absoluteString, kind: .local)
            }
            guard let canonical = try? registry.item(for: item.pageURL),
                  canonical.sourceID == item.sourceID else { return nil }
            return canonical
        }
        let completed = Set(items.compactMap(identity))
        guard !completed.isEmpty else { return }
        let next = entries.filter { _, entry in
            guard entry.updatedAt <= completedAt, (latestProgressAt[entry.id].map { $0 <= completedAt } ?? true),
                  entry.selection.torrent == nil,
                  let item = identity(entry.selection.episode ?? entry.selection.item) else { return true }
            return !completed.contains(item)
        }
        guard next.count != entries.count else { return }
        try save(next)
    }

    private func save(_ next: [String: PlaybackHistoryEntry]) throws {
        let data = try JSONEncoder().encode(Archive(version: 1, entries: Array(next.values)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        entries = next
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func identity(_ selection: PlayableSelection) -> String {
        let ref = selection.episode ?? selection.item
        let value = selection.torrent?.identityURL.absoluteString ?? (ref.sourceID + "\n" + ref.pageURL)
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate func validateConfiguration(_ durable: DurableSelection) throws {
        guard let context = durable.context else { return }
        guard let configuration = registry.source(for: durable.selection.item.sourceID),
              registry.loadError == nil,
              configuration.configurationRevision == context.configurationRevision else {
            throw PlaybackFailure.configurationChanged
        }
    }

    private func durable(_ original: PlayableSelection) throws -> DurableSelection {
        guard original.classification.kind != .live, original.item.kind != .live else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        if let configuration = registry.source(for: original.item.sourceID) {
            guard registry.loadError == nil else { throw PlaybackFailure.configurationChanged }
            var choice = original
            if choice.episode == nil, choice.item.kind == .episode {
                let parts = try configuration.parts(choice.item.pageURL)
                choice.episode = choice.item
                choice.item = try configuration.item(configuration.expanded(configuration.route.detailTemplate, values: ["id": parts.id]))
            }
            var selection = try configuration.mappingSelection(choice)
            if selection.classification.kind == .unknown { selection.classification = original.classification }
            let work = try configuration.parts(selection.item.pageURL)
            let episode = try configuration.parts(selection.episode!.pageURL)
            guard let episodeID = episode.episodeIdentity else { throw PlaybackFailure.missingEpisode }
            let context = PlaybackContext(work: .source(sourceID: configuration.id, workID: work.id),
                episode: .source(sourceID: configuration.id, workID: work.id, episodeID: episodeID),
                selection: selection, configurationRevision: configuration.configurationRevision)
            try ConfirmedSourceMapping(context: context, sourceTitle: configuration.name).validateForPersistence()
            return DurableSelection(selection: selection, context: context, localFile: nil)
        }
        if original.item.kind != .local, original.torrent == nil {
            let path = URLComponents(string: original.item.pageURL)?.path ?? ""
            guard !["mp4", "m4v", "mov", "mkv", "webm", "m3u8", "mpd", "ts", "flv", "mp3", "aac"]
                .contains((path as NSString).pathExtension.lowercased()) else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
        }
        var selection = try Self.nativeSelection(original)
        let local = selection.item.kind == .local ? URL(string: selection.item.pageURL) : nil
        let reference = local.flatMap { try? PlaybackLocalFileReference.capture($0) }
        if let reference, let previous = entries.values.lazy.filter({
            $0.localFile?.resourceIdentity == reference.resourceIdentity
        }).max(by: { $0.updatedAt < $1.updatedAt }) {
            // Playback uses the bookmark's current URL, while history keeps the
            // original ID, including later loads/revisits in the same local queue.
            selection.item = previous.selection.item
            if selection.classification.kind == .unknown { selection.classification = previous.selection.classification }
        }
        return DurableSelection(selection: selection, context: nil,
            localFile: reference ?? entries[Self.identity(selection)]?.localFile)
    }

    private static func archivedSelection(_ entry: PlaybackHistoryEntry) throws -> PlayableSelection {
        if let context = entry.context {
            guard context.selection == entry.selection else { throw CocoaError(.fileReadCorruptFile) }
            try ConfirmedSourceMapping(context: context, sourceTitle: "History").validateForPersistence()
            return context.selection
        }
        return try nativeSelection(entry.selection)
    }

    /// Legacy native page identities keep their existing allowlist and hash inputs.
    private static func nativeSelection(_ original: PlayableSelection) throws -> PlayableSelection {
        func page(_ ref: SourceItemRef) throws -> SourceItemRef {
            guard var parts = URLComponents(string: ref.pageURL), parts.user == nil, parts.password == nil,
                  ["https", "http", "file", "iina-torrent"].contains(parts.scheme ?? "") else { throw CocoaError(.validationMissingMandatoryProperty) }
            if parts.scheme != "iina-torrent" {
                // Only public page identity parameters survive. Signed/authenticated pages are not resumable.
                let identityKeys: Set<String> = ["id", "p", "ep", "episode", "season", "cid", "bvid", "aid", "vid", "v", "page", "play", "s"]
                guard (parts.queryItems ?? []).allSatisfy({ identityKeys.contains($0.name.lowercased()) }) else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                parts.fragment = nil
            }
            guard let url = parts.string else { throw CocoaError(.validationMissingMandatoryProperty) }
            return SourceItemRef(sourceID: ref.sourceID, pageURL: url, kind: ref.kind)
        }
        var result = original
        result.item = try page(original.item)
        result.episode = try original.episode.map(page)
        result.accountID = nil
        return result
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func mediaTitle(_ title: String, selection: PlayableSelection) -> String {
        if let title = nonempty(title) { return title }
        let ref = selection.episode ?? selection.item
        if ref.kind == .local, let file = URL(string: ref.pageURL), file.isFileURL { return file.lastPathComponent }
        return title
    }

    private static func publicCover(_ value: String?) -> String? {
        guard let value, var parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme ?? ""),
              parts.user == nil, parts.password == nil else { return nil }
        parts.query = nil; parts.fragment = nil
        return parts.string
    }
}

/// One instance per real player load. A launch alone never creates a history item.
@MainActor
final class PlaybackProgressRecorder {
    let selection: PlayableSelection
    private let store: PlaybackHistoryStore
    private let durable: PlaybackHistoryStore.DurableSelection?
    private let token: PlaybackHistoryStore.RecorderToken?
    private let title: String
    private let episodeTitle: String?
    private let coverURL: String?
    private var position: Double = 0
    private var duration: Double?
    private var savedAt: Double = -1
    private var ended = false
    private var hasActualSample = false

    init(store: PlaybackHistoryStore, selection: PlayableSelection, title: String, coverURL: String?, episodeTitle: String? = nil) {
        self.store = store; self.selection = selection; self.title = title; self.coverURL = coverURL; self.episodeTitle = episodeTitle
        let prepared = try? store.prepareRecorder(selection)
        durable = prepared?.0
        token = prepared?.1
    }
    func validateForLaunch() throws {
        if let durable { try store.validateConfiguration(durable) }
    }

    var displayTitle: String { episodeTitle.map { title + " · " + $0 } ?? title }

    /// EOF work must still belong to this recorder after any asynchronous lookup.
    func validateForContinuation() throws {
        guard hasActualSample, let token, store.claim(token) else { throw CancellationError() }
        try validateForLaunch()
    }

    func update(position: Double, duration: Double?, completed: Bool = false, flush: Bool = false) {
        guard !ended, position.isFinite, position >= 0,
              let durable, let token, store.claim(token) else { return }
        hasActualSample = true
        self.position = position
        if let duration, duration.isFinite, duration > 0 { self.duration = duration }
        store.noteProgress(for: token.id, at: Date())
        guard flush || completed || abs(position - savedAt) >= 1 else { return }
        do {
            try store.record(durable: durable, token: token, title: title, coverURL: coverURL,
                             position: position, duration: self.duration, completed: completed, episodeTitle: episodeTitle)
            savedAt = position
        } catch { NSLog("Playback history could not be saved (%@).", String(describing: type(of: error))) }
        if completed { ended = true }
    }
    func flush() {
        guard hasActualSample else { return }
        update(position: position, duration: duration, flush: true)
    }

    func finish(completed: Bool = false) {
        if hasActualSample {
            update(position: position, duration: duration, completed: completed, flush: true)
        }
        ended = true
    }
    func retainForUpdates(through completedAt: Date) throws {
        guard let durable, let token else { return }
        try store.retainForUpdates(durable: durable, token: token, title: title, coverURL: coverURL,
                                  position: position, duration: duration, episodeTitle: episodeTitle,
                                  through: completedAt)
    }
}
