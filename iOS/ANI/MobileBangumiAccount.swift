import Foundation
import Observation
import Security

struct MobileBangumiCredential: Codable {
    let version: Int
    let user: MobileBangumiUser
    let token: String
}

@MainActor
protocol MobileBangumiCredentialStore {
    func load() throws -> MobileBangumiCredential?
    func save(_ credential: MobileBangumiCredential) throws
    func remove() throws
}

struct MobileBangumiKeychain: MobileBangumiCredentialStore {
    nonisolated init() {}
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "IINA-ANI-iOS.Bangumi",
         kSecAttrAccount as String: "active-personal-token"]
    }
    func load() throws -> MobileBangumiCredential? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = value as? Data,
              let credential = try? JSONDecoder().decode(MobileBangumiCredential.self, from: data),
              credential.version == 1, credential.user.id > 0,
              !credential.user.username.isEmpty, !credential.token.isEmpty,
              !credential.token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw MobileBangumiFailure.secureStorage
        }
        return credential
    }
    func save(_ credential: MobileBangumiCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes = [kSecValueData as String: data,
                          kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var insertion = query
            insertion.merge(attributes) { _, new in new }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw MobileBangumiFailure.secureStorage }
        } else if result != errSecSuccess { throw MobileBangumiFailure.secureStorage }
    }
    func remove() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw MobileBangumiFailure.secureStorage }
    }
}

/// All local mutations and response guards run on the main actor without a suspension between them.
@MainActor @Observable
final class MobileBangumiAccount {
    private(set) var user: MobileBangumiUser?
    private(set) var isAuthenticating = false
    private(set) var isSyncing = false
    private(set) var isImporting = false
    private(set) var errorMessage: String?
    private(set) var lastImportedCount: Int?
    private let library: MobileLibrary
    private let client: any MobileBangumiTransport
    private let credentials: any MobileBangumiCredentialStore
    private var credential: MobileBangumiCredential?
    private var epoch = UUID()
    private var activeSyncAccounts = Set<Int>()

    init(library: MobileLibrary, client: any MobileBangumiTransport = MobileBangumiClient(),
         credentials: any MobileBangumiCredentialStore = MobileBangumiKeychain()) {
        self.library = library
        self.client = client
        self.credentials = credentials
        library.activeCollectionAccountID = nil
        do {
            credential = try credentials.load()
            user = credential?.user
            library.activeCollectionAccountID = user?.id
        } catch { errorMessage = MobileBangumiFailure.secureStorage.message }
    }

    var pendingCount: Int { user.map { library.pendingCollections(for: $0.id).count } ?? 0 }
    var unassignedCount: Int { library.unassignedCollectionCount }

    func signIn(token input: String) async {
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            errorMessage = MobileBangumiFailure.invalidToken.message
            return
        }
        invalidateRequests()
        let attempt = epoch
        isAuthenticating = true
        library.activeCollectionAccountID = nil
        errorMessage = nil
        do {
            let validatedUser = try await client.user(token: token)
            guard epoch == attempt else { return }
            try Task.checkCancellation()
            let updated = MobileBangumiCredential(version: 1, user: validatedUser, token: token)
            do { try credentials.save(updated) } catch { throw MobileBangumiFailure.secureStorage }
            credential = updated
            user = validatedUser
            library.activeCollectionAccountID = validatedUser.id
            isAuthenticating = false
            await retrySync()
        } catch {
            guard epoch == attempt else { return }
            isAuthenticating = false
            library.activeCollectionAccountID = user?.id
            report(error)
        }
    }

    func signOut() {
        invalidateRequests()
        isAuthenticating = false
        do {
            try credentials.remove()
            credential = nil
            user = nil
            library.activeCollectionAccountID = nil
            errorMessage = nil
            lastImportedCount = nil
        } catch {
            library.activeCollectionAccountID = user?.id
            errorMessage = MobileBangumiFailure.secureStorage.message
        }
    }

    /// Retry on launch/foreground and by an explicit button. A failure never drops an operation.
    func retrySync() async {
        guard !isSyncing, !isAuthenticating, let credential else { return }
        let generation = epoch
        let accountID = credential.user.id
        guard library.activeCollectionAccountID == accountID, !activeSyncAccounts.contains(accountID) else { return }
        activeSyncAccounts.insert(accountID)
        isSyncing = true
        errorMessage = nil
        defer {
            activeSyncAccounts.remove(accountID)
            if epoch == generation {
                isSyncing = false
            } else if user?.id == accountID, !isAuthenticating {
                // Re-entering the same account waits for its old request to finish before sending a newer command.
                Task { await self.retrySync() }
            }
        }
        do {
            // Revalidate restored credentials before sending any durable commands.
            let identity = try await client.user(token: credential.token)
            guard accepts(generation, accountID: accountID) else { return }
            guard identity.id == accountID else { throw MobileBangumiFailure.authentication }
            while let operation = library.pendingCollections(for: accountID).first {
                try Task.checkCancellation()
                guard accepts(generation, accountID: accountID) else { return }
                try await client.setCollection(operation, token: credential.token)
                guard accepts(generation, accountID: accountID), !Task.isCancelled else { return }
                do { try library.acknowledgeCollection(operation) } catch { throw MobileBangumiFailure.localStorage }
                // Pull the next command from live storage: a newer in-flight edit is not acknowledged away.
            }
        } catch {
            if accepts(generation, accountID: accountID) { report(error) }
        }
    }

    func syncUnassignedChanges() async {
        guard !isAuthenticating, let user else { return }
        do { try library.assignUnassignedCollections(to: user.id) }
        catch { errorMessage = MobileBangumiFailure.localStorage.message; return }
        await retrySync()
    }

    func importCollections() async {
        guard !isImporting, !isAuthenticating, let credential else { return }
        let generation = epoch
        let accountID = credential.user.id
        let snapshot = library.collectionImportSnapshot()
        isImporting = true
        errorMessage = nil
        lastImportedCount = nil
        defer { if epoch == generation { isImporting = false } }
        do {
            let identity = try await client.user(token: credential.token)
            guard accepts(generation, accountID: accountID) else { return }
            guard identity.id == accountID else { throw MobileBangumiFailure.authentication }
            let records = try await client.collections(userID: accountID, token: credential.token)
            guard accepts(generation, accountID: accountID), !Task.isCancelled else { return }
            do { try library.importCollections(records, snapshot: snapshot, accountID: accountID) }
            catch { throw MobileBangumiFailure.localStorage }
            lastImportedCount = Set(records.map { $0.anime.id }).count
        } catch {
            if accepts(generation, accountID: accountID) { report(error) }
        }
    }

    private func accepts(_ generation: UUID, accountID: Int) -> Bool {
        generation == epoch && user?.id == accountID && library.activeCollectionAccountID == accountID
    }
    private func invalidateRequests() {
        epoch = UUID()
        isSyncing = false
        isImporting = false
    }
    private func report(_ error: Error) {
        if error is CancellationError { return }
        errorMessage = (error as? MobileBangumiFailure ?? .unavailable).message
    }
}
