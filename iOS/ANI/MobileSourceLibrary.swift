import Foundation
import Observation

struct MobileSourceEntry: Identifiable {
    let configuration: SourceConfiguration
    let imported: Bool
    var id: String { configuration.id }
}

struct MobileSourceDraft: Identifiable {
    let id = UUID()
    let configuration: SourceConfiguration
    let data: Data
}

/// Explicit imports are authoritative; app startup never installs a source or subscription.
/// Legacy single-file imports remain intact underneath atomic batch-import state.
@MainActor @Observable
final class MobileSourceLibrary {
    private(set) var sources: [MobileSourceEntry] = []
    private(set) var issues: [String] = []
    private let directory: URL
    private let bundled: () throws -> [SourceConfiguration]
    private var directoryReadable = true
    private(set) var subscriptionBaselines: [SourceConfiguration] = []
    private var subscriptionState: MobileSubscriptionState?
    private var subscriptionReadable = true
    private var importedConfigurations: [String: Data] = [:]
    private struct ImportState: Codable {
        let version: Int
        let configurations: [String: Data]
    }
    private static let maximumImportBytes = 16 * 1024 * 1024
    private static let maximumStateBytes = 24 * 1024 * 1024

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("ANI/Sources", isDirectory: true),
         bundled: @escaping () throws -> [SourceConfiguration] = { [] }) {
        self.directory = directory
        self.bundled = bundled
        reload()
    }

    static func forApp() -> MobileSourceLibrary {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-empty-sources-ui-fixture") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("empty-sources-test-" + UUID().uuidString)
            let library = MobileSourceLibrary(directory: directory)
            return library
        }
        if arguments.contains("-source-ui-fixture") || arguments.contains("-source-list-ui-fixture") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-list-test-" + UUID().uuidString)
            let library = MobileSourceLibrary(directory: directory)
            if let data = try? MobileSourceFixtures.configurationData(), let config = try? validate(data) {
                _ = try? library.apply(MobileSourceDraft(configuration: config, data: data))
                if arguments.contains("-source-list-ui-fixture"),
                   var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    object["id"] = "fixture-second"
                    object["name"] = "Second fixture source"
                    if let secondData = try? JSONSerialization.data(withJSONObject: object),
                       let second = try? validate(secondData) {
                        _ = try? library.apply(MobileSourceDraft(configuration: second, data: secondData))
                    }
                }
            }
            return library
        }
        #endif
        return MobileSourceLibrary()
    }

    nonisolated static func loadManifest(_ data: Data, resource: (String) throws -> Data) throws -> [SourceConfiguration] {
        struct Manifest: Decodable { let version: Int; let sources: [String] }
        guard data.count <= 64 * 1024 else { throw MobileSourceError.invalidResponse }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1, manifest.sources.count <= 100,
              Set(manifest.sources).count == manifest.sources.count else { throw MobileSourceError.invalidResponse }
        var result: [SourceConfiguration] = []
        var ids = Set<String>()
        for file in manifest.sources {
            guard file.hasSuffix(".json"), file.count <= 100,
                  !file.contains("/"), !file.contains("\\"), !file.contains("..") else { throw MobileSourceError.invalidSelection }
            let config = try validate(resource(file))
            guard ids.insert(config.id).inserted else { throw MobileSourceError.invalidSelection }
            result.append(config)
        }
        return result
    }

    nonisolated static func validate(_ data: Data) throws -> SourceConfiguration {
        guard !data.isEmpty, data.count <= 1024 * 1024 else { throw MobileSourceError.invalidResponse }
        return try SourceConfiguration.load(data: data)
    }

    func prepare(_ url: URL) throws -> MobileSourceDraft {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1024 * 1024 else { throw MobileSourceError.invalidResponse }
        let data = try Data(contentsOf: url)
        return MobileSourceDraft(configuration: try Self.validate(data), data: data)
    }

    func replaces(_ draft: MobileSourceDraft) -> Bool {
        sources.contains { $0.id == draft.configuration.id } ||
        importedConfigurations[draft.configuration.id] != nil ||
        FileManager.default.fileExists(atPath: file(draft.configuration.id).path)
    }

    @discardableResult func apply(_ draft: MobileSourceDraft) throws -> String {
        reload()
        guard directoryReadable else { throw MobileSourceError.unavailable }
        let validated = try Self.validatedDraft(draft)
        // Once an ID lives in the batch authority, all future updates must use that authority.
        if importedConfigurations[validated.id] != nil {
            return try apply(MobileSourceBatchDraft(drafts: [draft]))[0]
        }
        try requireSourceCapacity(adding: [validated.id])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try draft.data.write(to: file(validated.id), options: .atomic)
        UserDefaults.standard.set(false, forKey: "mobile.sources." + validated.id + ".enabled")
        reload()
        return validated.id
    }

    /// Validate every entry before a single atomic commit. Legacy files and search overlays are untouched.
    @discardableResult func apply(_ batch: MobileSourceBatchDraft) throws -> [String] {
        reload()
        guard directoryReadable else { throw MobileSourceError.unavailable }
        guard !batch.drafts.isEmpty, batch.drafts.count <= 100 else { throw MobileSourceError.invalidResponse }
        var updates: [String: Data] = [:]
        var ids: [String] = []
        for draft in batch.drafts {
            let validated = try Self.validatedDraft(draft)
            guard updates[validated.id] == nil else { throw MobileSourceError.invalidSelection }
            updates[validated.id] = draft.data
            ids.append(validated.id)
        }
        try requireSourceCapacity(adding: Set(ids))
        let combined = importedConfigurations.merging(updates) { _, updated in updated }
        guard combined.count <= 100,
              combined.values.reduce(0, { $0 + $1.count }) <= Self.maximumImportBytes else {
            throw MobileSourceError.invalidResponse
        }
        let encoded = try JSONEncoder().encode(ImportState(version: 1, configurations: combined))
        guard encoded.count <= Self.maximumStateBytes else { throw MobileSourceError.invalidResponse }
        try FileManager.default.createDirectory(at: importStateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: importStateFile, options: .atomic)
        for id in ids { UserDefaults.standard.set(false, forKey: "mobile.sources." + id + ".enabled") }
        reload()
        return ids
    }

    private static func validatedDraft(_ draft: MobileSourceDraft) throws -> SourceConfiguration {
        let validated = try validate(draft.data)
        guard validated.id == draft.configuration.id,
              validated.configurationRevision == draft.configuration.configurationRevision else {
            throw MobileSourceError.invalidSelection
        }
        return validated
    }

    private func requireSourceCapacity(adding ids: Set<String>) throws {
        var existing = Set(subscriptionBaselines.map(\.id)).union(importedConfigurations.keys)
        if FileManager.default.fileExists(atPath: directory.path) {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "json" }
            existing.formUnion(files.map { $0.deletingPathExtension().lastPathComponent })
        }
        guard existing.union(ids).count <= 100 else { throw MobileSourceError.unavailable }
    }

    /// Read disk and enablement at every asynchronous boundary, not the sheet's configuration snapshot.
    func configurationRevision(for sourceID: String, defaults: UserDefaults = .standard) throws -> String {
        reload()
        guard directoryReadable, let source = sources.first(where: { $0.id == sourceID }) else {
            throw PlaybackFailure.configurationChanged
        }
        guard defaults.bool(forKey: "mobile.sources." + sourceID + ".enabled") else {
            throw PlaybackFailure.sourceDisabled
        }
        return source.configuration.configurationRevision
    }

    func validateSubscriptionRevisions(_ expected: [String: String]) throws {
        reload()
        guard directoryReadable, subscriptionReadable,
              Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.configuration.configurationRevision) }) == expected else {
            throw MobileSubscriptionError.stale
        }
    }

    /// One atomic state-file commit installs all accepted rules; missing/rejected entries stay intact.
    /// Enablement is deliberately untouched, including already-disabled sources.
    func applySubscription(_ preview: MobileSubscriptionPreview) throws {
        try validateSubscriptionRevisions(preview.revisions)
        var overrides = subscriptionState?.overrides ?? [:]
        for (id, value) in preview.state.overrides {
            guard let baseline = subscriptionBaselines.first(where: { $0.id == id }),
                  baseline.configurationRevision == value.baselineRevision else { throw MobileSubscriptionError.stale }
            _ = try MobileSubscriptionConverter.replacingSearch(value.search, in: baseline)
            overrides[id] = value
        }
        let next = MobileSubscriptionState(fingerprint: preview.state.fingerprint,
            checkedAt: preview.state.checkedAt, overrides: overrides)
        let data = try JSONEncoder().encode(next)
        guard data.count <= 2 * 1024 * 1024 else { throw MobileSubscriptionError.malformed }
        let folder = directory.appendingPathComponent("SearchSubscription", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("state.json"), options: .atomic)
        reload()
    }

    func reload() {
        var entries: [MobileSourceEntry] = []
        var problems: [String] = []
        directoryReadable = true
        importedConfigurations = [:]
        do { entries = try bundled().map { MobileSourceEntry(configuration: $0, imported: false) } }
        catch { problems.append("source-list.json") }
        if FileManager.default.fileExists(atPath: directory.path) {
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard files.count <= 100 else { throw MobileSourceError.invalidResponse }
                for url in files {
                    do {
                        let draft = try prepare(url)
                        guard url.lastPathComponent == draft.configuration.id + ".json" else { throw MobileSourceError.invalidSelection }
                        let entry = MobileSourceEntry(configuration: draft.configuration, imported: true)
                        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
                        else { entries.append(entry) }
                    } catch {
                        // The filename reserves this source ID even when its replacement cannot be decoded.
                        entries.removeAll { $0.id == url.deletingPathExtension().lastPathComponent }
                        problems.append(url.lastPathComponent)
                    }
                }
            } catch { directoryReadable = false; entries = []; problems.append("Sources") }
        }
        if FileManager.default.fileExists(atPath: importStateFile.path) {
            do {
                let size = try importStateFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= Self.maximumStateBytes else { throw MobileSourceError.invalidResponse }
                let data = try Data(contentsOf: importStateFile)
                guard data.count <= Self.maximumStateBytes else { throw MobileSourceError.invalidResponse }
                let state = try JSONDecoder().decode(ImportState.self, from: data)
                guard state.version == 1, state.configurations.count <= 100,
                      state.configurations.values.reduce(0, { $0 + $1.count }) <= Self.maximumImportBytes else {
                    throw MobileSourceError.invalidResponse
                }
                var imports: [MobileSourceEntry] = []
                for (id, data) in state.configurations {
                    let config = try Self.validate(data)
                    guard config.id == id else { throw MobileSourceError.invalidSelection }
                    imports.append(MobileSourceEntry(configuration: config, imported: true))
                }
                importedConfigurations = state.configurations
                entries.removeAll { state.configurations[$0.id] != nil }
                entries += imports
                guard entries.count <= 100 else { throw MobileSourceError.invalidResponse }
            } catch {
                // Unknown or corrupt batch authority must never expose older shadowed configurations.
                directoryReadable = false
                importedConfigurations = [:]
                entries = []
                problems.append("ConfigurationImports/state.json")
            }
        }
        if !directoryReadable { entries = [] }
        subscriptionBaselines = entries.map(\.configuration)
        subscriptionReadable = true
        subscriptionState = nil
        let stateFile = directory.appendingPathComponent("SearchSubscription/state.json")
        if FileManager.default.fileExists(atPath: stateFile.path) {
            do {
                let data = try Data(contentsOf: stateFile)
                guard data.count <= 2 * 1024 * 1024 else { throw MobileSubscriptionError.malformed }
                let state = try JSONDecoder().decode(MobileSubscriptionState.self, from: data)
                guard state.overrides.count <= 100 else { throw MobileSubscriptionError.malformed }
                subscriptionState = state
                for index in entries.indices {
                    let baseline = entries[index].configuration
                    guard let override = state.overrides[baseline.id],
                          override.baselineRevision == baseline.configurationRevision else { continue }
                    let updated = try MobileSubscriptionConverter.replacingSearch(override.search, in: baseline)
                    entries[index] = MobileSourceEntry(configuration: updated, imported: entries[index].imported)
                }
            } catch {
                // A corrupt installed rule must not silently fall back to a different fingerprint.
                subscriptionReadable = false; entries = []; problems.append("SearchSubscription/state.json")
            }
        }
        let ordered = entries.sorted { $0.id < $1.id }
        if sources.count != ordered.count || zip(sources, ordered).contains(where: {
            $0.0.id != $0.1.id || $0.0.imported != $0.1.imported ||
                $0.0.configuration.configurationRevision != $0.1.configuration.configurationRevision
        }) { sources = ordered }
        if issues != problems { issues = problems }
    }

    private var importStateFile: URL { directory.appendingPathComponent("ConfigurationImports/state.json") }

    private func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }
}
