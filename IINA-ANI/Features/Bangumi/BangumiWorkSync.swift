import Foundation

struct BangumiWorkRead: Sendable {
    enum State: Sendable { case unlinked, linkedWithoutMetadata, available }
    let work: Work
    let origin: BangumiOrigin?
    let failure: BangumiError?
    var collectionStatusPending: Bool { work.collectionStatusPending }

    var state: State {
        work.bangumiID == nil ? .unlinked : work.bangumiMetadata == nil ? .linkedWithoutMetadata : .available
    }
}

struct BangumiScheduledRefresh: Sendable {
    let workID: UUID
    let read: BangumiWorkRead?
    let failure: String?
}

/// The library owns local identity; the service owns replaceable API cache.
@MainActor
final class BangumiWorkSync {
    private let library: WorkLibrary
    private let service: BangumiService
    private static var collectionWrites: [UUID: (id: UUID, task: Task<BangumiWorkRead, Error>)] = [:]

    init(library: WorkLibrary, service: BangumiService = .shared) {
        self.library = library
        self.service = service
    }

    func read(workID: UUID) throws -> BangumiWorkRead {
        guard let work = try library.fetchWork(id: workID) else { throw WorkLibrary.LibraryError.workNotFound(workID) }
        return BangumiWorkRead(work: work, origin: work.bangumiMetadata == nil ? nil : .cache, failure: nil)
    }

    /// Save the user's command before any suspension; failed sync never rolls it back.
    @discardableResult
    func setCollectionStatus(workID: UUID, status: BangumiCollectionStatus) async throws -> BangumiWorkRead {
        let previousWork = try read(workID: workID).work
        let retrying = previousWork.collectionStatusPending && previousWork.collectionStatus == status
        var initial = try library.setCollectionStatus(workID: workID, status: status,
            accountID: retrying ? previousWork.collectionStatusAccountID : nil)
        guard let subjectID = initial.bangumiID else {
            throw BangumiError.account(String(localized: "尚未關聯 Bangumi 作品；分類已儲存於本機，關聯後可重新同步。"))
        }
        let account: Result<UUID, Error>
        do { account = .success(try await service.collectionAccountID()) }
        catch { account = .failure(error) }
        try Task.checkCancellation()
        if let accountID = try? account.get() {
            if let owner = initial.collectionStatusAccountID, owner != accountID {
                throw BangumiError.account(String(localized: "This pending collection change belongs to another Bangumi account. Sign in to that account to retry."))
            }
            initial = try library.bindCollectionStatusAccount(workID: workID,
                revision: initial.collectionStatusRevision, accountID: accountID)
        }
        let previous = Self.collectionWrites[workID]?.task
        let token = UUID()
        let task = Task { @MainActor in
            // `account` was captured for this durable revision; never resolve a new default on retry.
            // Keep remote writes in command order, bound to the account selected for this command.
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            let accountID = try account.get()
            let current = try self.read(workID: workID).work
            guard current.bangumiID == subjectID,
                  current.bangumiAssociationRevision == initial.bangumiAssociationRevision else {
                throw WorkLibrary.LibraryError.bangumiAssociationChanged(workID)
            }
            guard current.collectionStatusRevision == initial.collectionStatusRevision else {
                throw WorkLibrary.LibraryError.collectionStatusChanged(workID)
            }
            try await self.service.setCollectionStatus(subjectID: subjectID, status: status, accountID: accountID)
            try Task.checkCancellation()
            try await self.service.checkCollectionAccount(accountID)
            let work = try self.library.applyCollectionStatus(status, workID: workID, subjectID: subjectID,
                associationRevision: initial.bangumiAssociationRevision, collectionRevision: initial.collectionStatusRevision,
                acknowledgingLocalEdit: true)
            return BangumiWorkRead(work: work, origin: .network, failure: nil)
        }
        Self.collectionWrites[workID] = (token, task)
        defer { if Self.collectionWrites[workID]?.id == token { Self.collectionWrites.removeValue(forKey: workID) } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    func refreshCollectionStatus(workID: UUID) async throws -> BangumiWorkRead {
        try Task.checkCancellation()
        let initial = try read(workID: workID)
        // Pending commands remain authoritative even offline, after relinking, and after restart.
        guard !initial.collectionStatusPending else { return initial }
        guard let subjectID = initial.work.bangumiID else { return initial }
        let accountID = try await service.collectionAccountID()
        let status = try await service.collectionStatus(subjectID: subjectID, accountID: accountID)
        try Task.checkCancellation()
        try await service.checkCollectionAccount(accountID)
        let work = try library.applyCollectionStatus(status, workID: workID, subjectID: subjectID,
            associationRevision: initial.work.bangumiAssociationRevision,
            collectionRevision: initial.work.collectionStatusRevision, acknowledgingLocalEdit: false)
        return BangumiWorkRead(work: work, origin: .network, failure: nil)
    }

    /// Explicit read-only import. Stage every page before touching the local library.
    @discardableResult
    func loadOnlineCollections(favorites: FavoriteLibrary) async throws -> Int {
        try Task.checkCancellation()
        let initialWorks = try Dictionary(uniqueKeysWithValues: library.allWorks().map { ($0.id, $0) })
        let initialFavorites = try favorites.favoriteWorkIDs()
        let accountID = try await service.collectionAccountID()
        let collections = try await service.onlineCollections(accountID: accountID)
        try await service.checkCollectionAccount(accountID)
        try Task.checkCancellation()

        // Nothing below suspends: a local edit cannot interleave between the final guards and merge.
        var associated = Dictionary(grouping: try library.allWorks().filter { $0.bangumiID != nil },
                                    by: { $0.bangumiID! })
        var currentFavorites = try favorites.favoriteWorkIDs()
        for record in collections {
            let matches = (associated[record.subjectID] ?? []).sorted {
                let a = initialFavorites.contains($0.id), b = initialFavorites.contains($1.id)
                return a == b ? $0.id.uuidString < $1.id.uuidString : a
            }
            let work: Work
            if let existing = matches.first {
                work = existing
                if let initial = initialWorks[existing.id],
                   initial.bangumiID == existing.bangumiID,
                   initial.bangumiAssociationRevision == existing.bangumiAssociationRevision {
                    _ = try library.applyCollectionStatus(record.status, workID: existing.id, subjectID: record.subjectID,
                        associationRevision: initial.bangumiAssociationRevision,
                        collectionRevision: initial.collectionStatusRevision, acknowledgingLocalEdit: false)
                }
            } else {
                let subject = record.subject
                work = Work(bangumiID: record.subjectID, title: subject.title,
                    aliases: [subject.name, subject.nameCN].filter { !$0.isEmpty && $0 != subject.title },
                    coverURL: subject.coverURL, year: subject.date.flatMap { Int($0.prefix(4)) },
                    classification: subject.classification, collectionStatus: record.status)
                try library.upsert(work)
                associated[record.subjectID] = [work]
            }
            // A removal made while fetching is a newer local command; do not undo it.
            if !currentFavorites.contains(work.id), !initialFavorites.contains(work.id) {
                try favorites.addWork(workID: work.id)
                currentFavorites.insert(work.id)
            }
        }
        return collections.count
    }

    /// Setting an ID is an explicit local command, not a name-based auto-match.
    @discardableResult
    func associate(workID: UUID, subjectID: Int?, accountID: UUID? = nil) async throws -> BangumiWorkRead {
        if let subjectID {
            let initial = try read(workID: workID).work
            guard initial.classification.kind == .anime else { throw WorkLibrary.LibraryError.animeRequired }
            let result = try await service.metadata(subjectID: subjectID, accountID: accountID)
            try Task.checkCancellation()
            guard result.value.subject.classification.kind == .anime else { throw WorkLibrary.LibraryError.animeRequired }
            let current = try read(workID: workID).work
            guard current.bangumiID == initial.bangumiID && current.bangumiAssociationRevision == initial.bangumiAssociationRevision else {
                throw WorkLibrary.LibraryError.bangumiAssociationChanged(workID)
            }
            let associated = try library.setBangumiAssociation(workID: workID, subjectID: subjectID)
            let work = try library.applyBangumiMetadata(result.value, toWorkID: workID,
                                                       expectedAssociationRevision: associated.bangumiAssociationRevision)
            return BangumiWorkRead(work: work, origin: result.origin, failure: result.failure)
        }
        try library.setBangumiAssociation(workID: workID, subjectID: nil)
        return try read(workID: workID)
    }

    @discardableResult
    func refresh(workID: UUID, forceRefresh: Bool = false, accountID: UUID? = nil) async throws -> BangumiWorkRead {
        try Task.checkCancellation()
        let initial = try read(workID: workID)
        guard let subjectID = initial.work.bangumiID else { return initial }
        let revision = initial.work.bangumiAssociationRevision
        let saved = initial.work.bangumiMetadata
        // Saved library metadata survives eviction of the rebuildable cache.
        let cacheAge = saved.map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity
        if !forceRefresh, let saved, cacheAge >= 0, cacheAge < BangumiService.cacheLifetime, !saved.needsEpisodeNumberRefresh {
            return initial
        }
        let result: BangumiResult<BangumiMetadata>
        do {
            result = try await service.metadata(subjectID: subjectID, forceRefresh: forceRefresh, accountID: accountID)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            let current = try read(workID: workID)
            guard current.work.bangumiID == subjectID, current.work.bangumiAssociationRevision == revision else {
                throw WorkLibrary.LibraryError.bangumiAssociationChanged(workID)
            }
            guard current.work.bangumiMetadata != nil, let failure = error as? BangumiError else { throw error }
            return BangumiWorkRead(work: current.work, origin: .staleCache, failure: failure)
        }
        try Task.checkCancellation()
        let work = try library.applyBangumiMetadata(result.value, toWorkID: workID, expectedAssociationRevision: revision)
        return BangumiWorkRead(work: work, origin: result.origin, failure: result.failure)
    }

    /// W5 supplies the actual favorite IDs. No invented favorites or background poller.
    /// One failure is reported for that work and does not prevent the others refreshing.
    func refreshFavorites(workIDs: [UUID], forceRefresh: Bool = false, accountID: UUID? = nil) async throws -> [BangumiScheduledRefresh] {
        var seen = Set<UUID>()
        var reports: [BangumiScheduledRefresh] = []
        for id in workIDs where seen.insert(id).inserted {
            try Task.checkCancellation()
            do {
                let value = try await refresh(workID: id, forceRefresh: forceRefresh, accountID: accountID)
                reports.append(BangumiScheduledRefresh(workID: id, read: value, failure: nil))
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                let reason: String
                if let failure = error as? BangumiError {
                    reason = failure.localizedDescription
                } else if let failure = error as? WorkLibrary.LibraryError {
                    switch failure {
                    case .workNotFound: reason = String(localized: "The local work no longer exists.")
                    case .bangumiAssociationChanged: reason = String(localized: "The Bangumi association changed during refresh.")
                    default: reason = String(localized: "The local library could not save the metadata.")
                    }
                } else {
                    reason = String(localized: "The metadata refresh could not be completed.")
                }
                reports.append(BangumiScheduledRefresh(workID: id, read: nil, failure: reason))
            }
        }
        return reports
    }
}
