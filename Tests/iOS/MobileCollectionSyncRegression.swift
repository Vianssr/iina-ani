import Foundation

@main @MainActor
struct MobileCollectionSyncRegression {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-sync-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await durableRetry(root.appendingPathComponent("retry"))
        try await newerEdit(root.appendingPathComponent("newer"))
        try await accountIsolation(root.appendingPathComponent("accounts"))
        try await importMerge(root.appendingPathComponent("import"))
        try await failedStorage(root.appendingPathComponent("storage"))
        try upgrade(root.appendingPathComponent("upgrade"))
        print("PASS: durable account-bound retry, in-flight edit/logout/switch guards, atomic nondeleting import, storage failure, and v2 upgrade protection")
    }

    static func anime(_ id: Int) -> Anime {
        Anime(id: id, name: "Local \(id)", name_cn: nil, images: nil, summary: "Preserve local text", date: nil, rating: nil)
    }
    static func library(_ root: URL) -> MobileLibrary { MobileLibrary(file: root.appendingPathComponent("favorites.json")) }

    static func durableRetry(_ root: URL) async throws {
        let library = library(root)
        let store = MemoryCredentials()
        let remote = ControlledTransport()
        let account = MobileBangumiAccount(library: library, client: remote, credentials: store)
        library.setStatus(.wish, for: anime(1))
        precondition(library.unassignedCollectionCount == 1)
        await account.signIn(token: "A")
        precondition(account.pendingCount == 0 && library.unassignedCollectionCount == 1)
        await remote.failWrites(true)
        await account.syncUnassignedChanges()
        precondition(account.pendingCount == 1 && account.errorMessage != nil)
        let restarted = self.library(root)
        let reopened = MobileBangumiAccount(library: restarted, client: remote, credentials: store)
        precondition(reopened.user?.id == 101 && reopened.pendingCount == 1)
        await remote.failWrites(false)
        await reopened.retrySync()
        precondition(reopened.pendingCount == 0 && restarted.status(for: 1) == .wish)
        let count = await remote.sent().count
        restarted.setStatus(nil, for: anime(1))
        await reopened.retrySync()
        let afterClear = await remote.sent().count
        precondition(afterClear == count && restarted.status(for: 1) == nil)
        precondition(self.library(root).status(for: 1) == nil)
        store.failSaving = true
        await reopened.signIn(token: "B")
        precondition(reopened.user?.id == 101 && store.value?.user.id == 101)
        store.failSaving = false
    }

    static func newerEdit(_ root: URL) async throws {
        let library = library(root)
        let remote = ControlledTransport()
        let account = MobileBangumiAccount(library: library, client: remote, credentials: MemoryCredentials())
        await account.signIn(token: "A")
        library.setStatus(.wish, for: anime(2))
        await remote.blockNextWrite()
        let request = Task { await account.retrySync() }
        await remote.waitForBlock()
        library.setStatus(.doing, for: anime(2))
        await remote.release()
        await request.value
        let sent = await remote.sent()
        precondition(sent.map { $0.1.status } == [.wish, .doing])
        precondition(account.pendingCount == 0 && library.status(for: 2) == .doing)
    }

    static func accountIsolation(_ root: URL) async throws {
        let library = library(root)
        let remote = ControlledTransport()
        let store = MemoryCredentials()
        let account = MobileBangumiAccount(library: library, client: remote, credentials: store)
        await account.signIn(token: "A")
        library.setStatus(.wish, for: anime(3))
        await remote.blockNextWrite()
        let request = Task { await account.retrySync() }
        await remote.waitForBlock()
        account.signOut()
        await account.signIn(token: "B")
        await remote.release()
        await request.value
        precondition(account.user?.id == 202 && library.pendingCollections(for: 101).count == 1)
        precondition(library.pendingCollections(for: 202).isEmpty)
        library.setStatus(.doing, for: anime(3))
        await account.retrySync()
        let sent = await remote.sent()
        precondition(sent.count == 2 && sent[0].0 == "A" && sent[1].0 == "B")
        precondition(sent[0].1.accountID == 101 && sent[1].1.accountID == 202)
        precondition(library.pendingCollections(for: 101).count == 1)
        await account.signIn(token: "A")
        precondition(library.pendingCollections(for: 101).isEmpty && library.status(for: 3) == .doing)

        await remote.blockNextImport([MobileRemoteCollection(anime: anime(300), status: .collected)])
        let importing = Task { await account.importCollections() }
        await remote.waitForBlock()
        await account.signIn(token: "B")
        await remote.release()
        await importing.value
        precondition(!library.contains(anime(300)))
        await remote.blockNextUser()
        let signingIn = Task { await account.signIn(token: "A") }
        await remote.waitForBlock()
        account.signOut()
        await remote.release()
        await signingIn.value
        precondition(account.user == nil && store.value == nil && !account.isAuthenticating)
    }

    static func importMerge(_ root: URL) async throws {
        let library = library(root)
        let remote = ControlledTransport()
        let account = MobileBangumiAccount(library: library, client: remote, credentials: MemoryCredentials())
        await account.signIn(token: "A")
        for id in [4, 5, 6] { library.toggle(anime(id)) }
        let mapping = ConfirmedSourceMapping(context: PlaybackContext(work: .bangumi(5),
            episode: .bangumi(501, type: 0, sort: 1),
            selection: PlayableSelection(
                item: SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/work", kind: .work),
                episode: SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/episode", kind: .episode),
                lineID: "one", qualityID: "HD", classification: .unknown),
            configurationRevision: "sha256:" + String(repeating: "a", count: 64)),
            sourceTitle: "Keep mapping", confirmedAt: .now)
        try library.saveMapping(mapping)
        library.setStatus(nil, for: anime(4))
        library.setStatus(.doing, for: anime(5))
        library.setStatus(.wish, for: anime(8))
        let records = [4, 5, 6, 7, 7, 8].map { MobileRemoteCollection(anime: anime($0), status: .collected) }
        await remote.blockNextImport(records)
        let request = Task { await account.importCollections() }
        await remote.waitForBlock()
        library.toggle(anime(6))
        await account.retrySync()
        library.setStatus(.onHold, for: anime(5))
        await remote.release()
        await request.value
        precondition(Set(library.favorites.map(\.id)) == [4, 5, 7, 8])
        precondition(library.favorites.filter { $0.id == 7 }.count == 1)
        precondition(library.status(for: 4) == nil && library.status(for: 5) == .onHold)
        precondition(library.pendingCollections(for: 101).count == 1)
        precondition(library.status(for: 8) == .wish, "An import begun before a successful local sync must not overwrite it")
        precondition(library.mapping(for: mapping.context.work, episode: mapping.context.episode) == mapping)
        let absent = anime(88)
        library.toggle(absent)
        await remote.setImport([])
        await account.importCollections()
        precondition(library.contains(absent) && library.contains(anime(7)))
        precondition(self.library(root).favorites == library.favorites)
    }

    static func failedStorage(_ root: URL) async throws {
        let library = library(root)
        let remote = ControlledTransport()
        let account = MobileBangumiAccount(library: library, client: remote, credentials: MemoryCredentials())
        await account.signIn(token: "A")
        library.setStatus(.wish, for: anime(9))
        let stage = root.appendingPathComponent("library.json.staged")
        await remote.blockNextWrite()
        let request = Task { await account.retrySync() }
        await remote.waitForBlock()
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        await remote.release()
        await request.value
        precondition(library.storageError && account.pendingCount == 1)
        precondition(self.library(root).pendingCollections(for: 101).count == 1)
        library.setStatus(.doing, for: anime(9))
        precondition(library.status(for: 9) == .wish)
        try FileManager.default.removeItem(at: stage)
        await account.retrySync()
        precondition(account.pendingCount == 0 && !library.storageError)
        // A newer/corrupt authority appearing after load must never be overwritten by a stale instance.
        let authority = root.appendingPathComponent("library.json")
        let future = Data(#"{"version":999,"favorites":[],"works":[]}"#.utf8)
        try future.write(to: authority)
        library.setStatus(.doing, for: anime(9))
        precondition(!library.isReadable && tryData(authority) == future)
    }

    static func upgrade(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let authority = root.appendingPathComponent("library.json")
        let old = Data(#"{"version":2,"favorites":[{"id":10,"name":"Keep text"}],"works":[{"id":"bangumi:10","subjectID":10,"status":3}],"mappings":[]}"#.utf8)
        try old.write(to: authority)
        let library = library(root)
        precondition(library.isReadable && library.status(for: 10) == .doing && library.unassignedCollectionCount == 1)
        precondition(tryData(authority.appendingPathExtension("v2.backup")) == old)
        let saved = try Data(contentsOf: authority)
        var malformed = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        malformed.removeValue(forKey: "pendingCollections")
        let corrupt = try JSONSerialization.data(withJSONObject: malformed)
        try corrupt.write(to: authority)
        let blocked = self.library(root)
        blocked.toggle(anime(11))
        precondition(!blocked.isReadable && tryData(authority) == corrupt)
    }

    static func tryData(_ url: URL) -> Data { (try? Data(contentsOf: url)) ?? Data() }
}

@MainActor
private final class MemoryCredentials: MobileBangumiCredentialStore {
    var value: MobileBangumiCredential?
    var failSaving = false
    func load() throws -> MobileBangumiCredential? { value }
    func save(_ credential: MobileBangumiCredential) throws {
        if failSaving { throw MobileBangumiFailure.secureStorage }
        value = credential
    }
    func remove() throws { value = nil }
}

private actor ControlledTransport: MobileBangumiTransport {
    private var writes: [(String, MobileCollectionOperation)] = []
    private var fail = false
    private var shouldBlockWrite = false
    private var shouldBlockImport = false
    private var shouldBlockUser = false
    private var records: [MobileRemoteCollection] = []
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func user(token: String) async throws -> MobileBangumiUser {
        if shouldBlockUser { shouldBlockUser = false; await pause() }
        return MobileBangumiUser(id: token == "A" ? 101 : 202, username: token, nickname: "Fixture " + token)
    }
    func collections(userID: Int, token: String) async throws -> [MobileRemoteCollection] {
        let snapshot = records
        if shouldBlockImport { shouldBlockImport = false; await pause() }
        return snapshot
    }
    func setCollection(_ operation: MobileCollectionOperation, token: String) async throws {
        if fail { throw MobileBangumiFailure.unavailable }
        writes.append((token, operation))
        if shouldBlockWrite { shouldBlockWrite = false; await pause() }
    }
    func sent() -> [(String, MobileCollectionOperation)] { writes }
    func failWrites(_ value: Bool) { fail = value }
    func blockNextWrite() { shouldBlockWrite = true }
    func blockNextUser() { shouldBlockUser = true }
    func setImport(_ value: [MobileRemoteCollection]) { records = value }
    func blockNextImport(_ value: [MobileRemoteCollection]) { records = value; shouldBlockImport = true }
    func waitForBlock() async {
        if blocked != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
    private func pause() async {
        await withCheckedContinuation { continuation in
            blocked = continuation
            waiter?.resume()
            waiter = nil
        }
    }
}
