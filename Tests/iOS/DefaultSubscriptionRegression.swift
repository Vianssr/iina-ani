import Foundation

/// Startup is intentionally empty. These tests preserve the historical runner signature.
@MainActor enum DefaultSubscriptionRegression {
    static func run(root: URL) async throws {
        let original = try Data(contentsOf: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("explicit-source-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try emptyStartup(directory.appendingPathComponent("empty"))
        try legacyAndBatchPersistence(original, directory.appendingPathComponent("persistence"))
        try allOrNothing(original, directory.appendingPathComponent("atomic"))
        try countLimit(original, directory.appendingPathComponent("limit"))
        print("PASS: empty startup, explicit single/batch import persistence, atomic validation/storage failure, source limit and legacy/subscription preservation")
    }

    private static func emptyStartup(_ directory: URL) throws {
        let library = MobileSourceLibrary(directory: directory)
        precondition(library.sources.isEmpty && library.subscriptionBaselines.isEmpty && library.issues.isEmpty)
        library.reload()
        precondition(library.sources.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: directory.path), "Opening an empty library must not install default files")
    }

    private static func draft(_ original: Data, id: String, name: String) throws -> MobileSourceDraft {
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        object["id"] = id
        object["name"] = name
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return MobileSourceDraft(configuration: try MobileSourceLibrary.validate(data), data: data)
    }

    private static func legacyAndBatchPersistence(_ original: Data, _ directory: URL) throws {
        let legacy = try draft(original, id: "fixture-legacy", name: "Legacy source")
        let imported = try draft(original, id: "fixture-imported", name: "Imported source")
        let replacement = try draft(original, id: legacy.configuration.id, name: "Batch replacement")
        let single = try draft(original, id: "fixture-single", name: "Later single source")
        let ids = [legacy.configuration.id, imported.configuration.id, single.configuration.id]
        let defaults = savedDefaults(ids)
        defer { restoreDefaults(defaults) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyFile = directory.appendingPathComponent(legacy.configuration.id + ".json")
        try legacy.data.write(to: legacyFile)
        let subscriptionFile = directory.appendingPathComponent("SearchSubscription/state.json")
        let subscription = MobileSubscriptionState(fingerprint: "existing-subscription", checkedAt: .distantPast,
            overrides: [legacy.configuration.id: MobileSearchOverride(
                baselineRevision: legacy.configuration.configurationRevision, search: legacy.configuration.search!)])
        let subscriptionBytes = try JSONEncoder().encode(subscription)
        try FileManager.default.createDirectory(at: subscriptionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try subscriptionBytes.write(to: subscriptionFile)

        let library = MobileSourceLibrary(directory: directory)
        precondition(library.sources.count == 1 && library.sources[0].imported)
        precondition(library.sources[0].configuration.name == "Legacy source")
        for id in ids { UserDefaults.standard.set(true, forKey: key(id)) }
        let applied = try library.apply(MobileSourceBatchDraft(drafts: [replacement, imported]))
        precondition(applied == [legacy.configuration.id, imported.configuration.id])
        precondition(library.sources.count == 2 && library.sources.allSatisfy(\.imported))
        precondition(library.sources.first(where: { $0.id == legacy.configuration.id })?.configuration.name == "Batch replacement")
        precondition(read(legacyFile) == legacy.data, "Batch import must preserve legacy source bytes")
        precondition(read(subscriptionFile) == subscriptionBytes, "Batch import must preserve search subscription authority")
        precondition(!UserDefaults.standard.bool(forKey: key(legacy.configuration.id)))
        precondition(!UserDefaults.standard.bool(forKey: key(imported.configuration.id)))
        precondition(UserDefaults.standard.bool(forKey: key(single.configuration.id)), "Unrelated enablement changed")

        let reopened = MobileSourceLibrary(directory: directory)
        precondition(reopened.sources.map(\.id) == library.sources.map(\.id))
        precondition(reopened.replaces(replacement))
        let newer = try draft(original, id: legacy.configuration.id, name: "Single update of batch source")
        try reopened.apply(newer)
        precondition(read(legacyFile) == legacy.data, "Single update of batch authority must not rewrite stale legacy shadow")
        try reopened.apply(single)
        precondition(read(directory.appendingPathComponent(single.configuration.id + ".json")) == single.data,
                     "Single-file compatibility was lost")
        let final = MobileSourceLibrary(directory: directory)
        precondition(final.sources.count == 3)
        precondition(final.sources.first(where: { $0.id == legacy.configuration.id })?.configuration.name == "Single update of batch source")
        precondition(read(subscriptionFile) == subscriptionBytes)
    }

    private static func allOrNothing(_ original: Data, _ directory: URL) throws {
        let first = try draft(original, id: "fixture-atomic-one", name: "Original one")
        let second = try draft(original, id: "fixture-atomic-two", name: "Original two")
        let update = try draft(original, id: first.configuration.id, name: "Updated one")
        let defaults = savedDefaults([first.configuration.id, second.configuration.id])
        defer { restoreDefaults(defaults) }
        let library = MobileSourceLibrary(directory: directory)
        try library.apply(MobileSourceBatchDraft(drafts: [first, second]))
        let stateFile = directory.appendingPathComponent("ConfigurationImports/state.json")
        let before = read(stateFile)
        let beforeRevisions = library.sources.map { $0.configuration.configurationRevision }
        UserDefaults.standard.set(true, forKey: key(first.configuration.id))
        let invalid = MobileSourceDraft(configuration: second.configuration, data: Data("broken".utf8))
        rejects { try library.apply(MobileSourceBatchDraft(drafts: [update, invalid])) }
        rejects { try library.apply(MobileSourceBatchDraft(drafts: [update, update])) }
        rejects { try library.apply(MobileSourceBatchDraft(drafts: [])) }
        let mismatched = MobileSourceDraft(configuration: first.configuration, data: second.data)
        rejects { try library.apply(MobileSourceBatchDraft(drafts: [update, mismatched])) }
        precondition(read(stateFile) == before)
        precondition(library.sources.map { $0.configuration.configurationRevision } == beforeRevisions)
        precondition(UserDefaults.standard.bool(forKey: key(first.configuration.id)), "Failed import changed source enablement")

        let blockedDirectory = directory.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        let legacyFile = blockedDirectory.appendingPathComponent(first.configuration.id + ".json")
        try first.data.write(to: legacyFile)
        let blocker = blockedDirectory.appendingPathComponent("ConfigurationImports")
        try Data("preserved non-directory".utf8).write(to: blocker)
        let blocked = MobileSourceLibrary(directory: blockedDirectory)
        rejects { try blocked.apply(MobileSourceBatchDraft(drafts: [update, second])) }
        precondition(read(legacyFile) == first.data && read(blocker) == Data("preserved non-directory".utf8))
        precondition(blocked.sources.count == 1 && blocked.sources[0].configuration.name == "Original one")
        precondition(UserDefaults.standard.bool(forKey: key(first.configuration.id)))

        // Unknown or corrupt new authority must not silently fall back to legacy sources or be overwritten.
        let oldLegacy = directory.appendingPathComponent(first.configuration.id + ".json")
        try first.data.write(to: oldLegacy)
        for broken in [Data("broken batch authority".utf8), Data(#"{"version":2,"configurations":{}}"#.utf8)] {
            try broken.write(to: stateFile, options: .atomic)
            let unreadable = MobileSourceLibrary(directory: directory)
            precondition(unreadable.sources.isEmpty && unreadable.issues.contains("ConfigurationImports/state.json"))
            rejects { try unreadable.apply(MobileSourceBatchDraft(drafts: [update])) }
            rejects { try unreadable.apply(update) }
            precondition(read(stateFile) == broken && read(oldLegacy) == first.data)
        }
        try before.write(to: stateFile, options: .atomic)
        library.reload()
        precondition(library.sources.count == 2)
    }

    private static func countLimit(_ original: Data, _ directory: URL) throws {
        let items = try (0..<100).map { try draft(original, id: "fixture-limit-\($0)", name: "Limit \($0)") }
        let excess = try draft(original, id: "fixture-limit-100", name: "Excess")
        let defaults = savedDefaults(items.map { $0.configuration.id } + [excess.configuration.id])
        defer { restoreDefaults(defaults) }
        let library = MobileSourceLibrary(directory: directory)
        try library.apply(MobileSourceBatchDraft(drafts: items))
        precondition(library.sources.count == 100)
        let stateFile = directory.appendingPathComponent("ConfigurationImports/state.json")
        let before = read(stateFile)
        rejects { try library.apply(MobileSourceBatchDraft(drafts: [excess])) }
        rejects { try library.apply(excess) }
        precondition(read(stateFile) == before && library.sources.count == 100)
        let replacement = try draft(original, id: items[0].configuration.id, name: "Replacement at capacity")
        try library.apply(MobileSourceBatchDraft(drafts: [replacement]))
        precondition(library.sources.count == 100)
        precondition(library.sources.first(where: { $0.id == replacement.configuration.id })?.configuration.name == "Replacement at capacity")
    }

    private static func rejects<T>(_ operation: () throws -> T) {
        do { _ = try operation(); preconditionFailure("Invalid batch was committed") } catch {}
    }
    private static func read(_ file: URL) -> Data { try! Data(contentsOf: file) }
    private static func key(_ id: String) -> String { "mobile.sources." + id + ".enabled" }
    private static func savedDefaults(_ ids: [String]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: ids.map { (key($0), UserDefaults.standard.object(forKey: key($0)) ?? NSNull()) })
    }
    private static func restoreDefaults(_ values: [String: Any]) {
        for (key, value) in values {
            if value is NSNull { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(value, forKey: key) }
        }
    }
}
