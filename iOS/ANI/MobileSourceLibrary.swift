import SourceCore
import SourceRuntime
import Foundation
import Observation

struct MobileSourceEntry: Identifiable, Sendable {
    let source: RuntimeSource
    let imported: Bool
    var search: NativeSearchSource?
    var id: String { source.id }
    var searchRevision: String {
        guard let search else { return source.configurationRevision }
        return (try? SourceSubscriptionBaselines.revision(of: search)) ?? "invalid-search-metadata"
    }
}

struct MobileSourceDraft: Identifiable {
    let id = UUID()
    let configuration: SourceConfiguration
    let data: Data
}

/// Desktop identities are available without installing user files; search remains opt-in.
/// Explicit configured imports and incompatible saved bytes retain their own durable authority.
@MainActor @Observable
final class MobileSourceLibrary {
    private(set) var sources: [MobileSourceEntry] = []
    private(set) var issues: [String] = []
    private let directory: URL
    private let bundled: () throws -> [RuntimeSource]
    private var directoryReadable = true
    private(set) var subscriptionBaselines: [String: NativeSearchSource] = [:]
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
         bundled: @escaping () throws -> [RuntimeSource] = { try RuntimeSource.builtins() }) {
        self.directory = directory
        self.bundled = bundled
        reload()
    }

    static func forApp() -> MobileSourceLibrary {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-native-playback-ui-fixture") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-playback-test-" + UUID().uuidString)
            return MobileSourceLibrary(directory: directory, bundled: { [.native("jibi")] })
        }
        if arguments.contains("-empty-sources-ui-fixture") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("empty-sources-test-" + UUID().uuidString)
            let library = MobileSourceLibrary(directory: directory, bundled: { [] })
            return library
        }
        if arguments.contains("-native-sources-ui-fixture") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-sources-test-" + UUID().uuidString)
            return MobileSourceLibrary(directory: directory)
        }
        if arguments.contains("-source-ui-fixture") || arguments.contains("-source-list-ui-fixture") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-list-test-" + UUID().uuidString)
            let library = MobileSourceLibrary(directory: directory, bundled: { [] })
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

    private nonisolated static let nativeSources = Result {
        try RuntimeSource.builtins().filter { if case .native = $0 { return true }; return false }
    }

    nonisolated static func validate(_ data: Data) throws -> SourceConfiguration {
        guard !data.isEmpty, data.count <= 1024 * 1024 else { throw MobileSourceError.invalidResponse }
        let configuration = try SourceConfiguration.load(data: data)
        guard configuration.version != 3 else { throw MobileSourceError.inactiveWebSelector }
        if configuration.version == 4, let search = configuration.search {
            try SourceSearchExecutor.validate(search, allowedHosts: configuration.requestHosts)
        }
        let native = try nativeSources.get()
        let hosts = Set(configuration.hosts.map { $0.lowercased() })
        guard !native.contains(where: { $0.id == configuration.id || !hosts.isDisjoint(with: $0.hosts.map { $0.lowercased() }) }) else {
            throw MobileSourceError.nativeConflict
        }
        return configuration
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
        try validateManualImportAgainstSubscription(validated)
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
            try validateManualImportAgainstSubscription(validated)
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
        var existing = Set(sources.filter(\.imported).map(\.id)).union(importedConfigurations.keys)
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
        return source.source.configurationRevision
    }

    func validateSubscriptionRevisions(_ expected: [String: String]) throws {
        reload()
        guard directoryReadable, subscriptionReadable,
              try subscriptionRevisions() == expected else {
            throw MobileSubscriptionError.stale
        }
    }

    /// One atomic state-file commit installs all accepted rules; missing/rejected entries stay intact.
    /// Enablement is deliberately untouched, including already-disabled sources.
    func applySubscription(_ preview: MobileSubscriptionPreview) throws {
        try validateSubscriptionRevisions(preview.revisions)
        var overrides = subscriptionState?.overrides ?? [:]
        for (id, value) in preview.state.overrides {
            guard let baseline = subscriptionBaselines[id],
                  try SourceSubscriptionBaselines.revision(of: baseline) == value.baselineRevision else { throw MobileSubscriptionError.stale }
            try SourceSearchExecutor.validate(value.search, allowedHosts: Set(baseline.hosts), resultURLTemplate: baseline.resultURLTemplate)
            overrides[id] = value
        }
        let configurations = (subscriptionState?.configurations ?? [:]).merging(preview.state.configurations) { _, update in update }
        let previousIDs = Set(subscriptionState?.configurations.keys.map { $0 } ?? [])
        let base = sources.filter { !previousIDs.contains($0.id) }
        _ = try Self.subscriptionConfigurations(configurations, alongside: base)
        for id in configurations.keys {
            guard importedConfigurations[id] == nil, !FileManager.default.fileExists(atPath: file(id).path) else {
                throw MobileSubscriptionError.stale
            }
        }
        let next = MobileSubscriptionState(fingerprint: preview.state.fingerprint,
            checkedAt: preview.state.checkedAt, overrides: overrides, configurations: configurations)
        let data = try JSONEncoder().encode(next)
        guard data.count <= 2 * 1024 * 1024 else { throw MobileSubscriptionError.malformed }
        let folder = directory.appendingPathComponent("SearchSubscription", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("state.json"), options: .atomic)
        for id in configurations.keys where !previousIDs.contains(id) {
            UserDefaults.standard.set(false, forKey: "mobile.sources." + id + ".enabled")
        }
        reload()
    }

    private static func subscriptionConfigurations(_ values: [String: Data], alongside entries: [MobileSourceEntry]) throws -> [MobileSourceEntry] {
        guard values.count + entries.filter(\.imported).count <= 100,
              values.values.reduce(0, { $0 + $1.count }) <= maximumImportBytes else {
            throw MobileSubscriptionError.malformed
        }
        var occupied = Set(entries.flatMap { $0.source.hosts })
        var ids = Set(entries.map(\.id))
        return try values.keys.sorted().map { id in
            let configuration = try validate(values[id]!)
            guard id.hasPrefix("web-"), configuration.version == 4, configuration.id == id,
                  ids.insert(id).inserted, configuration.hosts.allSatisfy({ occupied.insert($0).inserted }) else {
                throw MobileSubscriptionError.malformed
            }
            return MobileSourceEntry(source: .configured(configuration), imported: true,
                search: configuration.search.map { NativeSearchSource(hosts: configuration.hosts, search: $0) })
        }
    }

    private func validateManualImportAgainstSubscription(_ configuration: SourceConfiguration) throws {
        guard let state = subscriptionState else { return }
        for (id, data) in state.configurations {
            let existing = try Self.validate(data)
            guard id != configuration.id, Set(existing.hosts).isDisjoint(with: configuration.hosts) else {
                throw MobileSourceError.invalidSelection
            }
        }
    }

    func reload() {
        var entries: [MobileSourceEntry] = []
        var problems: [String] = []
        directoryReadable = true
        importedConfigurations = [:]
        do { entries = try bundled().map { MobileSourceEntry(source: $0, imported: false) } }
        catch { problems.append(String(localized: "Built-in source catalog")) }
        let builtinEntries = entries
        if FileManager.default.fileExists(atPath: directory.path) {
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard files.count <= 100 else { throw MobileSourceError.invalidResponse }
                for url in files {
                    do {
                        let draft = try prepare(url)
                        guard url.lastPathComponent == draft.configuration.id + ".json" else { throw MobileSourceError.invalidSelection }
                        let entry = MobileSourceEntry(source: .configured(draft.configuration), imported: true)
                        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
                        else { entries.append(entry) }
                    } catch {
                        let webSelector = Self.isWebSelectorFile(url)
                        let inactive = webSelector || (error as? MobileSourceError) == .nativeConflict
                        if !inactive { entries.removeAll { $0.id == url.deletingPathExtension().lastPathComponent } }
                        let message = webSelector
                            ? String(localized: "Saved webSelector configuration is inactive; original data retained.")
                            : String(localized: "Source configuration conflicts with a built-in source; original data retained.")
                        problems.append(url.lastPathComponent + (inactive ? " · " + message : ""))
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
                    do {
                        let config = try Self.validate(data)
                        guard config.id == id else { throw MobileSourceError.invalidSelection }
                        imports.append(MobileSourceEntry(source: .configured(config), imported: true))
                    } catch MobileSourceError.inactiveWebSelector {
                        problems.append(id + " · " + String(localized: "Saved webSelector configuration is inactive; original data retained."))
                    } catch MobileSourceError.nativeConflict {
                        problems.append(id + " · " + String(localized: "Source configuration conflicts with a built-in source; original data retained."))
                    } catch {
                        problems.append(id + " · " + String(localized: "Saved configuration is inactive; original data retained."))
                    }
                }
                importedConfigurations = state.configurations
                let inactiveIDs = Set(state.configurations.keys).subtracting(imports.map(\.id))
                entries.removeAll { state.configurations[$0.id] != nil }
                entries += imports
                entries += builtinEntries.filter { inactiveIDs.contains($0.id) }
                guard entries.filter(\.imported).count <= 100 else { throw MobileSourceError.invalidResponse }
            } catch {
                // Unknown or corrupt batch authority must never expose older shadowed configurations.
                directoryReadable = false
                importedConfigurations = [:]
                entries = []
                problems.append("ConfigurationImports/state.json")
            }
        }
        if !directoryReadable { entries = [] }
        do {
            let desktop = try SourceSubscriptionBaselines.load()
            subscriptionBaselines = desktop.filter { id, baseline in
                entries.contains { entry in
                    guard entry.id == id else { return false }
                    if !entry.imported { return true }
                    // Imported JSON keeps its own playback parser. Only the exact desktop
                    // search baseline can participate; never bind by name or host.
                    guard let spec = entry.source.search else { return false }
                    let metadata = NativeSearchSource(hosts: entry.source.hosts, search: spec,
                        resultURLTemplate: spec.format == "json" && entry.source.configured?.version != 4 ? entry.source.configured?.route.detailTemplate : nil)
                    return (try? SourceSubscriptionBaselines.revision(of: metadata)) ==
                        (try? SourceSubscriptionBaselines.revision(of: baseline))
                }
            }
            for index in entries.indices {
                let source = entries[index].source
                if !entries[index].imported && desktop[source.id] != nil { continue }
                if let spec = source.search {
                    entries[index].search = NativeSearchSource(hosts: source.hosts, search: spec,
                        resultURLTemplate: spec.format == "json" && source.configured?.version != 4 ? source.configured?.route.detailTemplate : nil)
                    if !SourceSubscriptionConverter.managedSourceIDs.contains(source.id) {
                        subscriptionBaselines[source.id] = entries[index].search
                    }
                }
            }
        } catch {
            subscriptionBaselines = [:]
            problems.append(String(localized: "Desktop search baselines"))
        }
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
                let staticEntries = try Self.subscriptionConfigurations(state.configurations, alongside: entries)
                entries += staticEntries
                for entry in staticEntries { subscriptionBaselines[entry.id] = entry.search }
                for index in entries.indices {
                    let baseline = entries[index].source
                    guard let override = state.overrides[baseline.id] else { continue }
                    guard let metadata = subscriptionBaselines[baseline.id],
                          override.baselineRevision == (try SourceSubscriptionBaselines.revision(of: metadata)) else {
                        problems.append(baseline.id + " · " + String(localized: "Saved search rules are inactive; original data retained."))
                        continue
                    }
                    try SourceSearchExecutor.validate(override.search, allowedHosts: Set(metadata.hosts), resultURLTemplate: metadata.resultURLTemplate)
                    entries[index].search = NativeSearchSource(hosts: metadata.hosts, search: override.search,
                        resultURLTemplate: metadata.resultURLTemplate)
                }
            } catch {
                // A corrupt installed rule must not silently fall back to a different fingerprint.
                subscriptionReadable = false; entries = []; problems.append("SearchSubscription/state.json")
            }
        }
        let ordered = entries.sorted { $0.id < $1.id }
        if sources.count != ordered.count || zip(sources, ordered).contains(where: {
            $0.0.id != $0.1.id || $0.0.imported != $0.1.imported ||
                $0.0.source.configurationRevision != $0.1.source.configurationRevision ||
                $0.0.searchRevision != $0.1.searchRevision
        }) { sources = ordered }
        if issues != problems { issues = problems }
    }

    func client(for source: RuntimeSource) -> MobileSourceClient {
        .make(source: source, search: sources.first(where: { $0.id == source.id })?.search)
    }

    func searchRevision(for sourceID: String, defaults: UserDefaults = .standard) throws -> String {
        _ = try configurationRevision(for: sourceID, defaults: defaults)
        guard let entry = sources.first(where: { $0.id == sourceID }) else { throw PlaybackFailure.configurationChanged }
        return entry.searchRevision
    }

    func subscriptionRevisions() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: sources.map {
            ($0.id, $0.source.configurationRevision + ":" + $0.searchRevision)
        })
    }


    private static func isWebSelectorFile(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["webSelector"] != nil
    }

    private var importStateFile: URL { directory.appendingPathComponent("ConfigurationImports/state.json") }

    private func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }
}
