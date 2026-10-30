import CryptoKit
import Foundation
import Observation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct MobilePlaybackHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let context: PlaybackContext?
    let localReference: MobileLocalMediaReference?
    let title: String
    let position: Double
    let duration: Double?
    let completed: Bool
    let updatedAt: Date

    static func sourceID(_ context: PlaybackContext) -> String {
        let parts = [context.work.localID, context.episode.localID]
        let framed = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return "source:sha256:" + SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct MobilePlaybackHistoryLease: Equatable {
    let entryID: String
    let token: UUID
    let identity: PlaybackLoadIdentity
}

/// An independent authority: library changes never remove playback progress.
@MainActor @Observable
final class MobilePlaybackHistory {
    private(set) var entries: [MobilePlaybackHistoryEntry] = []
    private(set) var isReadable = false
    var storageError = false
    var continuing: [MobilePlaybackHistoryEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            let key = entry.context.map { "work:" + $0.work.localID } ?? "file:" + entry.id
            return seen.insert(key).inserted
        }
    }
    private let file: URL
    private var leases: [String: MobilePlaybackHistoryLease] = [:]
    private var revision = UUID()

    init(file: URL = URL.applicationSupportDirectory.appendingPathComponent("ANI/playback-history.json")) {
        self.file = file
        retryLoad()
    }

    func retryLoad() {
        do {
            let loaded: [MobilePlaybackHistoryEntry]
            do { loaded = try Self.decode(Data(contentsOf: file)).entries }
            catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) { loaded = [] }
            entries = loaded.sorted { $0.updatedAt > $1.updatedAt }
            leases.removeAll()
            revision = UUID()
            isReadable = true
            storageError = false
        } catch {
            // A corrupt/future authority is never replaced by an empty history.
            isReadable = false
            storageError = true
        }
    }

    func remove(_ entry: MobilePlaybackHistoryEntry) {
        do {
            try commit(entries.filter { $0.id != entry.id })
            leases.removeValue(forKey: entry.id)
            revision = UUID()
        } catch { storageError = true }
    }

    /// Captured before an authorization await; deletion or another update makes the response stale.
    func authorizationRevision(for entry: MobilePlaybackHistoryEntry) throws -> UUID {
        guard isReadable, entries.contains(entry) else { throw MobileLocalMediaError.staleHistory }
        return revision
    }

    func replaceLocalReference(_ reference: MobileLocalMediaReference, for entry: MobilePlaybackHistoryEntry,
                               expectedRevision: UUID) throws -> MobilePlaybackHistoryEntry {
        do {
            guard isReadable, expectedRevision == revision, entries.contains(entry),
                  reference.isValid, entry.localReference?.identity == reference.identity else {
                throw MobileLocalMediaError.staleHistory
            }
            let updated = MobilePlaybackHistoryEntry(id: entry.id, context: nil, localReference: reference,
                title: entry.title, position: entry.position, duration: entry.duration,
                completed: entry.completed, updatedAt: entry.updatedAt)
            try commit(entries.map { $0.id == entry.id ? updated : $0 })
            leases.removeValue(forKey: entry.id)
            revision = UUID()
            return updated
        } catch {
            storageError = true
            throw error
        }
    }

    func begin(context: PlaybackContext?, localReference: MobileLocalMediaReference?, title: String,
               configuration: SourceConfiguration?, identity: PlaybackLoadIdentity,
               resumePosition: Double? = nil) -> MobilePlaybackHistoryRecorder? {
        do {
            guard isReadable else { throw StorageFailure.unreadable }
            let durable: PlaybackContext?
            let entryID: String
            if let context {
                guard localReference == nil, let configuration,
                      context.configurationRevision == configuration.configurationRevision else {
                    throw PlaybackFailure.configurationChanged
                }
                durable = PlaybackContext(work: context.work, episode: context.episode,
                    selection: try configuration.mappingSelection(context.selection),
                    configurationRevision: context.configurationRevision)
                try ConfirmedSourceMapping(context: durable!, sourceTitle: title).validateForPersistence()
                entryID = MobilePlaybackHistoryEntry.sourceID(durable!)
            } else if let localReference, localReference.isValid {
                durable = nil
                entryID = localReference.identity.id
            } else {
                // Direct HTTPS media has no re-resolvable identity and is deliberately transient.
                return nil
            }
            let lease = MobilePlaybackHistoryLease(entryID: entryID, token: UUID(), identity: identity)
            leases[entryID] = lease
            return MobilePlaybackHistoryRecorder(history: self, lease: lease, context: durable,
                localReference: localReference, title: title, resumePosition: resumePosition)
        } catch {
            storageError = true
            return nil
        }
    }

    fileprivate func renew(_ lease: MobilePlaybackHistoryLease, identity: PlaybackLoadIdentity) -> MobilePlaybackHistoryLease? {
        guard leases[lease.entryID] == lease, identity.sessionID == lease.identity.sessionID else { return nil }
        let renewed = MobilePlaybackHistoryLease(entryID: lease.entryID, token: lease.token, identity: identity)
        leases[lease.entryID] = renewed
        return renewed
    }

    fileprivate func save(_ entry: MobilePlaybackHistoryEntry, lease: MobilePlaybackHistoryLease) -> Bool {
        guard leases[lease.entryID] == lease else { return false }
        do {
            try commit([entry] + entries.filter { $0.id != entry.id })
            revision = UUID()
            return true
        } catch {
            storageError = true
            return false
        }
    }

    private func commit(_ entries: [MobilePlaybackHistoryEntry]) throws {
        guard isReadable else { throw StorageFailure.unreadable }
        let archive = Archive(version: 1, entries: entries)
        let bytes = try JSONEncoder().encode(archive)
        _ = try Self.decode(bytes)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = file.appendingPathExtension("staged")
        defer { try? FileManager.default.removeItem(at: staged) }
        try bytes.write(to: staged, options: .atomic)
        let persisted = try Data(contentsOf: staged)
        guard persisted == bytes else { throw StorageFailure.invalidData }
        _ = try Self.decode(persisted)
        guard rename(staged.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.entries = entries.sorted { $0.updatedAt > $1.updatedAt }
        storageError = false
    }

    private static func decode(_ data: Data) throws -> Archive {
        let decoder = JSONDecoder()
        guard try decoder.decode(Version.self, from: data).version == 1 else { throw StorageFailure.unsupportedVersion }
        let archive = try decoder.decode(Archive.self, from: data)
        var seen = Set<String>()
        for entry in archive.entries {
            guard seen.insert(entry.id).inserted, !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.title.contains("://"), entry.position.isFinite, entry.position >= 0,
                  entry.duration.map({ $0.isFinite && $0 > 0 }) ?? true,
                  entry.updatedAt.timeIntervalSinceReferenceDate.isFinite else { throw StorageFailure.invalidData }
            if let context = entry.context {
                guard entry.localReference == nil, entry.id == MobilePlaybackHistoryEntry.sourceID(context) else { throw StorageFailure.invalidData }
                try ConfirmedSourceMapping(context: context, sourceTitle: entry.title).validateForPersistence()
            } else {
                guard let reference = entry.localReference, reference.isValid,
                      entry.id == reference.identity.id else { throw StorageFailure.invalidData }
            }
        }
        return archive
    }

    private struct Version: Decodable { let version: Int }
    private struct Archive: Codable { let version: Int; let entries: [MobilePlaybackHistoryEntry] }
    private enum StorageFailure: Error { case unreadable, invalidData, unsupportedVersion }
}

/// Only accepted backend facts enter history. UI slider predictions never reach this boundary.
@MainActor
final class MobilePlaybackHistoryRecorder {
    private let history: MobilePlaybackHistory
    private var lease: MobilePlaybackHistoryLease
    private let context: PlaybackContext?
    private let localReference: MobileLocalMediaReference?
    private let title: String
    private var state = PlaybackEventState()
    private var resumeTarget: Double?
    private var lastSavedAt: Date?
    private var dirty = false
    private var completed = false
    private var actualSample: PlaybackProgressSample?

    fileprivate init(history: MobilePlaybackHistory, lease: MobilePlaybackHistoryLease,
                     context: PlaybackContext?, localReference: MobileLocalMediaReference?, title: String,
                     resumePosition: Double?) {
        self.history = history
        self.lease = lease
        self.context = context
        self.localReference = localReference
        self.title = title
        resumeTarget = resumePosition.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        state.beginLoad(lease.identity)
    }

    /// Reports accepted backend facts; a resume additionally requires explicit seek acknowledgement.
    @discardableResult
    func receive(_ event: PlaybackEvent, now: Date = .now) -> Bool {
        if event.identity != state.identity, case .resolved = event.kind,
           state.phase == .ended, let renewed = history.renew(lease, identity: event.identity),
           state.beginReplay(event.identity) {
            lease = renewed
            actualSample = nil
            completed = false
            dirty = false
        }
        guard state.apply(event) else { return false }
        switch event.kind {
        case let .progress(sample):
            guard resumeTarget == nil, sample.position > 0 || actualSample != nil else { return false }
            actualSample = sample
            completed = false
            dirty = true
            if lastSavedAt.map({ now.timeIntervalSince($0) >= 5 }) ?? true { flush(now: now) }
        case .naturalEOF:
            if actualSample != nil { completed = true; dirty = true; flush(now: now) }
        case .paused(true), .stopped, .cancelled:
            flush(now: now)
        case .failed:
            // Preserve the last committed history, including when a resume seek fails.
            dirty = false
        default: break
        }
        return true
    }

    func confirmResume(_ identity: PlaybackLoadIdentity) {
        guard state.identity == identity, state.phase == .loaded else { return }
        resumeTarget = nil
    }

    func flush(now: Date = .now) {
        guard dirty, resumeTarget == nil, let sample = actualSample else { return }
        let entry = MobilePlaybackHistoryEntry(id: lease.entryID, context: context, localReference: localReference,
            title: title, position: sample.position, duration: sample.duration ?? state.duration,
            completed: completed, updatedAt: now)
        if history.save(entry, lease: lease) {
            dirty = false
            lastSavedAt = now
        }
    }
}
