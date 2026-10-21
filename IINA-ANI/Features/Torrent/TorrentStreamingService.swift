import Foundation

struct TorrentPlaybackGrant: Sendable {
    let id: UUID
    let url: URL
    let selection: TorrentSelection
}

struct TorrentStreamingReader: Sendable {
    let id: UUID
    let readerID: UUID
    let size: UInt64
    let path: String
    let pool: TorrentTransferPool
}

actor TorrentStreamingService {
    static let shared = TorrentStreamingService()

    private final class WeakPool: @unchecked Sendable {
        weak var value: TorrentTransferPool?
        init(_ value: TorrentTransferPool) { self.value = value }
    }

    private struct ActiveReader {
        let pool: TorrentTransferPool
        let readerID: UUID
        let abort: @Sendable () -> Void
    }
    private struct Grant {
        let id: UUID
        let selected: TorrentSelectedFile
        let uploadPolicy: TorrentUploadPolicy
        let pool: TorrentTransferPool
        let leaseID: UUID
        let expiresAt: ContinuousClock.Instant
        let expiryTask: Task<Void, Never>
        var readers: [UUID: ActiveReader] = [:]
    }

    private let lifetime: Duration = .seconds(21_600)
    private let maximumGrants = 32
    private let maximumReaders = 32
    private var grants: [String: Grant] = [:]
    private var pendingGrants = 0
    private var readerCount = 0 // Includes requests currently awaiting a pool reader or close.
    private var closedPools: [ObjectIdentifier: WeakPool] = [:]
    private var stopped = false

    func grant(selected: TorrentSelectedFile, uploadPolicy: TorrentUploadPolicy,
               pool: TorrentTransferPool, port: Int) async throws -> TorrentPlaybackGrant {
        await expireOldGrants()
        pruneClosedPools()
        let poolIdentity = ObjectIdentifier(pool)
        guard !stopped, closedPools[poolIdentity] == nil,
              (1...65_535).contains(port), grants.count + pendingGrants < maximumGrants else {
            throw TorrentStreamingError.capacity
        }
        guard uploadPolicy.acknowledged,
              (1...TorrentUploadPolicy.maximumBytesPerSecond).contains(uploadPolicy.bytesPerSecond),
              selected.selection.isValid, selected.selection.isPlayableMedia else {
            throw TorrentStreamingError.invalidSelection
        }
        pendingGrants += 1
        let leaseID: UUID
        do {
            leaseID = try await pool.openReader(selected: selected, uploadPolicy: uploadPolicy)
        } catch {
            pendingGrants -= 1
            throw error
        }
        pendingGrants -= 1
        pruneClosedPools()
        guard !stopped, closedPools[poolIdentity] == nil,
              grants.count + pendingGrants < maximumGrants else {
            await pool.closeReader(leaseID)
            throw TorrentStreamingError.capacity
        }

        var token: String
        repeat { token = Self.randomToken() } while grants[token] != nil
        let id = UUID()
        let expiry = ContinuousClock.now + lifetime
        let expirationDelay = lifetime
        let expiryTask = Task { [weak self, expirationDelay] in
            do { try await Task.sleep(for: expirationDelay) } catch { return }
            await self?.expireGrant(id)
        }
        grants[token] = Grant(id: id, selected: selected, uploadPolicy: uploadPolicy, pool: pool,
                              leaseID: leaseID, expiresAt: expiry, expiryTask: expiryTask)
        guard let url = URL(string: "http://127.0.0.1:\(port)/torrent/\(token)/media") else {
            await removeGrant(token)
            throw TorrentStreamingError.invalidSelection
        }
        return TorrentPlaybackGrant(id: id, url: url, selection: selected.selection)
    }

    func beginRequest(token: String, abort: @escaping @Sendable () -> Void) async throws -> TorrentStreamingReader {
        await expireOldGrants()
        guard !stopped, let grant = grants[token] else { throw TorrentStreamingError.notFound }
        guard readerCount < maximumReaders else { throw TorrentStreamingError.capacity }
        readerCount += 1
        let poolReaderID: UUID
        do {
            poolReaderID = try await grant.pool.openReader(selected: grant.selected, uploadPolicy: grant.uploadPolicy)
        } catch {
            readerCount -= 1
            throw error
        }
        guard !stopped, var current = grants[token], current.id == grant.id,
              current.expiresAt > .now else {
            await grant.pool.closeReader(poolReaderID)
            readerCount -= 1
            throw TorrentStreamingError.revoked
        }
        let requestID = UUID()
        current.readers[requestID] = ActiveReader(pool: current.pool, readerID: poolReaderID, abort: abort)
        grants[token] = current
        return TorrentStreamingReader(id: requestID, readerID: poolReaderID,
                                      size: current.selected.selection.size,
                                      path: current.selected.selection.path, pool: current.pool)
    }

    func endRequest(token: String, requestID: UUID) async {
        guard var grant = grants[token], let active = grant.readers.removeValue(forKey: requestID) else { return }
        grants[token] = grant
        await active.pool.closeReader(active.readerID)
        readerCount -= 1
    }

    func revoke(_ id: UUID) async {
        guard let token = grants.first(where: { $0.value.id == id })?.key else { return }
        await removeGrant(token)
    }

    func shutdown() async {
        stopped = true
        for token in Array(grants.keys) { await removeGrant(token) }
    }

    func shutdown(pool: TorrentTransferPool) async {
        closedPools[ObjectIdentifier(pool)] = WeakPool(pool)
        let owned = grants.filter { $0.value.pool === pool }.map(\.key)
        for token in owned { await removeGrant(token) }
    }

    func revokeAll(pool: TorrentTransferPool) async {
        let owned = grants.filter { $0.value.pool === pool }.map { $0.key }
        for token in owned { await removeGrant(token) }
    }

    private func pruneClosedPools() {
        closedPools = closedPools.filter { $0.value.value != nil }
    }

    private func expireGrant(_ id: UUID) async {
        guard let token = grants.first(where: { $0.value.id == id })?.key else { return }
        await removeGrant(token)
    }

    private func expireOldGrants() async {
        let expired = grants.filter { $0.value.expiresAt <= .now }.map(\.key)
        for token in expired { await removeGrant(token) }
    }

    private func removeGrant(_ token: String) async {
        guard let grant = grants.removeValue(forKey: token) else { return }
        grant.expiryTask.cancel()
        for reader in grant.readers.values { reader.abort() }
        for reader in grant.readers.values {
            await reader.pool.closeReader(reader.readerID)
            readerCount -= 1
        }
        await grant.pool.closeReader(grant.leaseID)
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum TorrentStreamingError: Error {
    case capacity, invalidSelection, revoked, notFound, shortRead
}
