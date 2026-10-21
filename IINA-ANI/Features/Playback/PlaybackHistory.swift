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
                awaitingUpdates: entry.awaitingUpdates)
        }
    }
    init(url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        guard archive.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        for entry in archive.entries {
            let selection = try Self.durable(entry.selection)
            guard Self.identity(selection) == entry.id, entry.position.isFinite, entry.position > 0,
                  entry.duration.map({ $0.isFinite && $0 > 0 && ($0 > entry.position || entry.awaitingUpdates == true) }) ?? true else { continue }
            entries[entry.id] = PlaybackHistoryEntry(id: entry.id, title: Self.mediaTitle(entry.title, selection: selection),
                episodeTitle: Self.nonempty(entry.episodeTitle), coverURL: Self.publicCover(entry.coverURL), selection: selection,
                position: entry.position, duration: entry.duration, updatedAt: entry.updatedAt,
                awaitingUpdates: entry.awaitingUpdates)
        }
    }

    func record(selection: PlayableSelection, title: String, coverURL: String?, position: Double,
                duration: Double?, completed: Bool, episodeTitle: String? = nil) throws {
        guard selection.classification.kind != .live, selection.item.kind != .live,
              position.isFinite, position >= 0 else { return }
        let selection = try Self.durable(selection)
        let id = Self.identity(selection)
        let updatedAt = Date()
        noteProgress(for: id, at: updatedAt)
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var next = entries
        if completed || duration.map({ position >= $0 }) == true { next.removeValue(forKey: id) }
        else if position > 0 {
            next[id] = PlaybackHistoryEntry(id: id, title: Self.mediaTitle(title, selection: selection), episodeTitle: Self.nonempty(episodeTitle), coverURL: Self.publicCover(coverURL),
                selection: selection, position: position, duration: duration, updatedAt: updatedAt, awaitingUpdates: nil)
        } else { return }
        try save(next)
    }

    func remove(id: String) throws {
        guard entries[id] != nil else { return }
        var next = entries
        next.removeValue(forKey: id)
        try save(next)
        // A pending EOF catalog lookup must not restore a manually deleted entry.
        noteProgress(for: id, at: Date())
    }

    fileprivate func recorderIdentity(for selection: PlayableSelection) -> String? {
        (try? Self.durable(selection)).map(Self.identity)
    }

    fileprivate func noteProgress(for id: String, at date: Date) {
        latestProgressAt[id] = max(latestProgressAt[id] ?? date, date)
    }

    /// EOF is real playback, but an unconfirmed season must remain available for updates.
    fileprivate func retainForUpdates(selection: PlayableSelection, title: String, coverURL: String?,
                                      position: Double, duration: Double?, episodeTitle: String?,
                                      through completedAt: Date) throws {
        guard selection.classification.kind != .live, selection.item.kind != .live,
              position.isFinite, position > 0 else { return }
        let selection = try Self.durable(selection)
        let id = Self.identity(selection)
        guard (latestProgressAt[id].map { $0 <= completedAt } ?? true),
              (entries[id].map { $0.updatedAt <= completedAt } ?? true) else { return }
        guard entries[id]?.awaitingUpdates != true || entries[id]?.updatedAt != completedAt else { return }
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var next = entries
        next[id] = PlaybackHistoryEntry(id: id, title: Self.mediaTitle(title, selection: selection),
            episodeTitle: Self.nonempty(episodeTitle), coverURL: Self.publicCover(coverURL), selection: selection,
            position: position, duration: duration, updatedAt: completedAt, awaitingUpdates: true)
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

    private static func durable(_ original: PlayableSelection) throws -> PlayableSelection {
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
    private let historyID: String?
    private let title: String
    private let episodeTitle: String?
    private let coverURL: String?
    private var position: Double = 0
    private var duration: Double?
    private var savedAt: Double = -1
    private var ended = false

    init(store: PlaybackHistoryStore, selection: PlayableSelection, title: String, coverURL: String?, episodeTitle: String? = nil) {
        self.store = store; self.selection = selection; self.title = title; self.coverURL = coverURL; self.episodeTitle = episodeTitle
        historyID = store.recorderIdentity(for: selection)
    }
    func update(position: Double, duration: Double?, completed: Bool = false, flush: Bool = false) {
        guard !ended, position.isFinite, position >= 0 else { return }
        self.position = position
        if let duration, duration.isFinite, duration > 0 { self.duration = duration }
        if let historyID { store.noteProgress(for: historyID, at: Date()) }
        guard flush || completed || abs(position - savedAt) >= 1 else { return }
        do {
            try store.record(selection: selection, title: title, coverURL: coverURL,
                             position: position, duration: self.duration, completed: completed, episodeTitle: episodeTitle)
            savedAt = position
        } catch { NSLog("Playback history could not be saved (%@).", String(describing: type(of: error))) }
        if completed { ended = true }
    }
    func finish(completed: Bool = false) {
        update(position: position, duration: duration, completed: completed, flush: true)
        ended = true
    }
    func retainForUpdates(through completedAt: Date) throws {
        try store.retainForUpdates(selection: selection, title: title, coverURL: coverURL,
                                  position: position, duration: duration, episodeTitle: episodeTitle,
                                  through: completedAt)
    }
}
