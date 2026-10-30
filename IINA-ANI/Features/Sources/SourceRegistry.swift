import Foundation

/// Immutable snapshots keep URL classification synchronous for bookmarks and legacy entry points.
final class SourceRegistry: @unchecked Sendable {
    static let shared = SourceRegistry()

    struct Snapshot: Sendable {
        let configurations: [String: SourceConfiguration]
        let nativeSearch: [String: NativeSearchSource]
        let matchers: [SourceConfiguration]
        let descriptors: [SourceDescriptor]
        let loadError: String?
        var subscription: SourceSubscriptionPlan? = nil
        var subscriptionSearch: [String: NativeSearchSource] = [:]
    }

    struct ConfigurationImport {
        let configuration: SourceConfiguration
        let previousRevision: String?
        fileprivate let data: Data
        fileprivate let registryRevision: UInt64
    }

    enum RegistryError: Error, LocalizedError {
        case duplicateID(String)
        case hostConflict(String)
        case stalePreview

        var errorDescription: String? {
            switch self {
            case .duplicateID(let id): return String(localized: "Duplicate source ID: \(id)")
            case .hostConflict(let host): return String(localized: "Source host conflicts with an existing source: \(host)")
            case .stalePreview: return String(localized: "來源配置已變更；請重新匯入並檢查預覽。")
            }
        }
    }

    private let lock = NSLock()
    private let mutationLock = NSLock()
    private var generation: UInt64 = 0
    private var subscriptionURL: URL?
    private var directories: (builtin: URL?, user: URL)?
    private var stored = Snapshot(configurations: [:], nativeSearch: [:], matchers: [], descriptors: [], loadError: nil)

    init(builtinDirectory: URL? = nil, userDirectory: URL? = nil) {
        do { try reload(builtinDirectory: builtinDirectory, userDirectory: userDirectory) }
        catch {
            if let builtins = try? load(builtinDirectory: builtinDirectory, userDirectory: nil, includeUsers: false) {
                stored = builtins
            }
            lock.lock()
            stored = Snapshot(configurations: stored.configurations, nativeSearch: stored.nativeSearch,
                              matchers: stored.matchers, descriptors: stored.descriptors,
                              loadError: error.localizedDescription)
            lock.unlock()
        }
    }
    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var loadError: String? { snapshot.loadError }
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return generation }

    /// Failed reloads retain the previous complete snapshot, including subscription overrides.
    func reload(builtinDirectory: URL? = nil, userDirectory: URL? = nil) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        do {
            let builtins = builtinDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("Sources", isDirectory: true)
            let directory = try userDirectory ?? Self.defaultUserDirectory()
            let loaded = try load(builtinDirectory: builtins, userDirectory: directory)
            lock.lock()
            stored = loaded
            subscriptionURL = directory.appendingPathComponent("subscriptions/css1.json")
            directories = (builtins, directory)
            generation &+= 1
            lock.unlock()
        } catch {
            lock.lock()
            stored = Snapshot(configurations: stored.configurations, nativeSearch: stored.nativeSearch,
                matchers: stored.matchers, descriptors: stored.descriptors, loadError: error.localizedDescription,
                subscription: stored.subscription, subscriptionSearch: stored.subscriptionSearch)
            lock.unlock()
            throw error
        }
    }

    private static func defaultUserDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "IINA-ANI", isDirectory: true)
            .appendingPathComponent("sources", isDirectory: true)
    }

    private func locations() throws -> (builtin: URL?, user: URL) {
        lock.lock()
        let current = directories
        lock.unlock()
        return try current ?? (Bundle.main.resourceURL?.appendingPathComponent("Sources", isDirectory: true),
                               Self.defaultUserDirectory())
    }

    var configurationDirectory: URL? { try? locations().user }

    func reloadCurrent() throws {
        let current = try locations()
        try reload(builtinDirectory: current.builtin, userDirectory: current.user)
    }

    /// Preview validates the complete resulting registry without changing files or enablement.
    func prepareConfigurationImport(fileURL: URL) throws -> ConfigurationImport {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576 else {
            throw SourceConfiguration.ConfigurationError.invalidConfiguration
        }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 1_048_576 else { throw SourceConfiguration.ConfigurationError.invalidConfiguration }
        let configuration = try SourceConfiguration.load(data: data)
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let current = try locations()
        let base = try load(builtinDirectory: current.builtin, userDirectory: current.user)
        let destination = try configurationFile(for: configuration.id, directory: current.user)
        _ = try load(builtinDirectory: current.builtin, userDirectory: current.user,
                     replacement: (destination, configuration))
        return ConfigurationImport(configuration: configuration,
            previousRevision: base.configurations[configuration.id]?.configurationRevision,
            data: data, registryRevision: revision)
    }

    /// The bytes are validated before atomic replacement; failed writes never publish a new snapshot.
    func applyConfigurationImport(_ draft: ConfigurationImport) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let current = try locations()
        let base = try load(builtinDirectory: current.builtin, userDirectory: current.user)
        guard revision == draft.registryRevision,
              base.configurations[draft.configuration.id]?.configurationRevision == draft.previousRevision else {
            throw RegistryError.stalePreview
        }
        let configuration = try SourceConfiguration.load(data: draft.data)
        let destination = try configurationFile(for: configuration.id, directory: current.user)
        let next = try load(builtinDirectory: current.builtin, userDirectory: current.user,
                            replacement: (destination, configuration))
        try FileManager.default.createDirectory(at: current.user, withIntermediateDirectories: true)
        try draft.data.write(to: destination, options: .atomic)
        lock.lock()
        stored = next
        directories = current
        subscriptionURL = current.user.appendingPathComponent("subscriptions/css1.json")
        generation &+= 1
        lock.unlock()
    }

    private func configurationFile(for id: String, directory: URL) throws -> URL {
        // This filename belongs to the native search resource and is excluded by load().
        guard id.lowercased() != "native-search" else {
            throw SourceConfiguration.ConfigurationError.invalidConfiguration
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != "native-search.json" }
            for file in files where try SourceConfiguration.load(fileURL: file).id == id { return file }
        }
        let destination = directory.appendingPathComponent(id + ".json")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RegistryError.duplicateID(id) }
        return destination
    }

    private func load(builtinDirectory: URL?, userDirectory: URL?, includeUsers: Bool = true,
                      replacement: (file: URL, configuration: SourceConfiguration)? = nil) throws -> Snapshot {
        let builtins = builtinDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("Sources", isDirectory: true)
        let users: URL?
        if !includeUsers {
            users = nil
        } else if let userDirectory {
            users = userDirectory
        } else {
            users = try Self.defaultUserDirectory()
        }

        let nativeSites = SupportSites.nativeSites
        var nativeIDs: Set<String> = ["torrent", "youtube"]
        var nativeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]
        for site in nativeSites {
            nativeIDs.insert(site.sourceID)
            nativeHosts.formUnion(site.hosts.map { $0.lowercased() })
        }

        var nativeSearch: [String: NativeSearchSource] = [:]
        if let builtins {
            let searchFile = builtins.appendingPathComponent("native-search.json")
            if FileManager.default.fileExists(atPath: searchFile.path) {
                let resources = try JSONDecoder().decode(NativeSearchResources.self, from: Data(contentsOf: searchFile))
                guard resources.version == 1 else { throw SourceSearchError.invalidConfiguration }
                let hostPattern = try NSRegularExpression(pattern: "^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$")
                for (id, source) in resources.sources {
                    let hosts = Set(source.hosts.map { $0.lowercased() })
                    guard nativeIDs.contains(id), !hosts.isEmpty, hosts.count == source.hosts.count,
                          hosts.allSatisfy({ host in
                              hostPattern.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil &&
                                  !host.contains("..") && !host.hasPrefix(".") && !host.hasSuffix(".")
                          }), source.search.rowsPerPage > 0, source.search.rowsPerPage <= 100,
                          ["html", "json"].contains(source.search.format) else {
                        throw SourceSearchError.invalidConfiguration
                    }
                    _ = try SourceSearchExecutor.requestURL(source.search, query: "boundary", page: 1, allowedHosts: hosts)
                    if let template = source.resultURLTemplate {
                        let sample = template.replacingOccurrences(of: "{id}", with: "boundary")
                        guard !sample.contains("{") && !sample.contains("}"),
                              let url = URLComponents(string: sample), url.scheme?.lowercased() == "https",
                              url.user == nil, url.password == nil, url.port == nil,
                              let host = url.host?.lowercased(), nativeHosts.contains(host) else {
                            throw SourceSearchError.invalidConfiguration
                        }
                    }
                    nativeSearch[id] = source
                }
            }
        }

        var configurations: [String: SourceConfiguration] = [:]
        let directories = [builtins, users]
        for directory in directories {
            guard let directory else { continue }
            var files = FileManager.default.fileExists(atPath: directory.path)
                ? try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                    .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != "native-search.json" }
                : []
            if let replacement,
               replacement.file.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
               !files.contains(replacement.file) { files.append(replacement.file) }
            guard files.count <= 100 else { throw SourceConfiguration.ConfigurationError.invalidConfiguration }
            var directoryIDs: Set<String> = []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let configuration: SourceConfiguration
                if let replacement, file == replacement.file { configuration = replacement.configuration }
                else {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= 1_048_576 else { throw SourceConfiguration.ConfigurationError.invalidConfiguration }
                    configuration = try SourceConfiguration.load(fileURL: file)
                }
                guard !nativeIDs.contains(configuration.id), directoryIDs.insert(configuration.id).inserted else {
                    throw RegistryError.duplicateID(configuration.id)
                }
                configurations[configuration.id] = configuration
            }
        }
        var occupiedHosts = nativeHosts
        for configuration in configurations.values.sorted(by: { $0.id < $1.id }) {
            for host in configuration.hosts.map({ $0.lowercased() }) {
                guard occupiedHosts.insert(host).inserted else { throw RegistryError.hostConflict(host) }
            }
        }

        var nativeDescriptors: [String: SourceDescriptor] = [:]
        let liveIDs: Set<String> = ["bilibili-live", "douyu", "huya", "cc163", "douyin", "qie-tv"]
        let catalogIDs: Set<String> = ["bilibili", "bilibili-live", "douyu", "huya", "cc163", "xifan", "girigiri", "didahd", "jibi", "eacg", "senfun", "kanba", "haixing", "yinghua", "dilidili", "youknow", "wedm", "fengche", "rebo"]
        let qualityIDs: Set<String> = ["bilibili", "bilibili-live", "douyu", "huya", "cc163", "douyin", "hanime1"]
        let danmakuIDs: Set<String> = ["bilibili", "bilibili-live", "douyu", "huya", "douyin", "qie-tv", "local"]
        let cmsIDs: Set<String> = ["xifan", "girigiri", "didahd", "jibi", "eacg", "senfun", "kanba", "haixing", "yinghua", "dilidili", "youknow", "wedm", "fengche", "rebo"]
        let lineIDs = cmsIDs.union(["bilibili", "bilibili-live", "douyu", "cc163"])
        let downloadIDs = cmsIDs.union(["hanime1"])
        for site in nativeSites {
            let id = site.sourceID
            guard nativeDescriptors[id] == nil else { continue }
            var capabilities: Set<SourceCapability> = [.resolve, .iina, .mpv]
            if id != "local" { capabilities.insert(.information) }
            if nativeSearch[id] != nil { capabilities.insert(.search) }
            if liveIDs.contains(id) { capabilities.insert(.jsPlayer) }
            if danmakuIDs.contains(id) { capabilities.insert(.danmaku) }
            if catalogIDs.contains(id) { capabilities.insert(.episodes) }
            if lineIDs.contains(id) { capabilities.insert(.lines) }
            if qualityIDs.contains(id) { capabilities.insert(.quality) }
            if downloadIDs.contains(id) { capabilities.insert(.download) }
            nativeDescriptors[id] = SourceDescriptor(id: id, name: site.siteName.isEmpty ? id : site.siteName,
                                                     version: 1, capabilities: capabilities)
        }
        nativeDescriptors["torrent"] = SourceDescriptor(id: "torrent", name: "BitTorrent", version: 1,
            capabilities: [.information, .episodes, .download])
        nativeDescriptors["youtube"] = SourceDescriptor(id: "youtube", name: "YouTube", version: 1,
            capabilities: [.browse])
        // Native descriptors remain adapter-owned; declarative sources cannot enable unimplemented operations.
        let descriptors = (Array(nativeDescriptors.values) + configurations.values.map { $0.descriptor(on: .macOS) })
            .sorted { $0.id < $1.id }
        let matchers = configurations.values.sorted { $0.id < $1.id }
        let base = Snapshot(configurations: configurations, nativeSearch: nativeSearch, matchers: matchers,
                            descriptors: subscriptionDescriptors(descriptors, active: []), loadError: nil)
        if let file = users?.appendingPathComponent("subscriptions/css1.json"),
           FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 2_000_000 else { throw SourceSearchError.invalidConfiguration }
            return try applying(JSONDecoder().decode(SourceSubscriptionPlan.self, from: data), to: base)
        }
        return base
    }

    func subscriptionSearch(for id: String) -> NativeSearchSource? { snapshot.subscriptionSearch[id] }

    func builtinSearch(for id: String) -> NativeSearchSource? {
        let base = snapshot
        if let native = base.nativeSearch[id] { return native }
        guard let config = base.configurations[id], let search = config.search else { return nil }
        return NativeSearchSource(hosts: config.hosts, search: search, resultURLTemplate: nil)
    }

    /// Write before publishing; neither a failed write nor a stale preview changes active sources.
    func applySubscription(_ plan: SourceSubscriptionPlan, expectedRevision: UInt64) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard revision == expectedRevision, let file = subscriptionURL else {
            throw SourceSubscriptionFailure.stalePreview
        }
        let base = snapshot
        var overrides = base.subscription?.overrides ?? [:]
        overrides.merge(plan.overrides) { _, new in new }
        let merged = SourceSubscriptionPlan(fingerprint: plan.fingerprint, checkedAt: plan.checkedAt,
            overrides: overrides, entries: plan.entries)
        let next = try applying(merged, to: base)
        let data = try JSONEncoder().encode(merged)
        guard data.count <= 2_000_000 else { throw SourceSearchError.invalidConfiguration }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        lock.lock()
        stored = next
        generation &+= 1
        lock.unlock()
    }

    private func applying(_ plan: SourceSubscriptionPlan, to base: Snapshot) throws -> Snapshot {
        var overlays: [String: NativeSearchSource] = [:]
        guard plan.overrides.count <= 32 else { throw SourceSearchError.invalidConfiguration }
        for (id, data) in plan.overrides {
            guard SourceSubscriptionConverter.managedSourceIDs.contains(id), data.count <= 64_000 else {
                throw SourceSearchError.invalidConfiguration
            }
            let source = try JSONDecoder().decode(NativeSearchSource.self, from: data)
            let allowed = Set(base.configurations[id]?.hosts ?? SupportSites.nativeSites.first(where: { $0.sourceID == id })?.hosts ?? [])
            guard !source.hosts.isEmpty, Set(source.hosts).isSubset(of: allowed),
                  source.resultURLTemplate == nil, source.search.format == "html",
                  source.search.rowsPerPage > 0, source.search.rowsPerPage <= 100,
                  let rows = source.search.resultsSelector, !rows.isEmpty, rows.utf8.count <= 4096,
                  let title = source.search.titleSelector, !title.isEmpty, title.utf8.count <= 4096,
                  source.search.hrefAttribute == "href" else { throw SourceSearchError.invalidConfiguration }
            _ = try SourceSearchExecutor.requestURL(source.search, query: "boundary", page: 1, allowedHosts: Set(source.hosts))
            let sensitive: Set<String> = ["cookie", "token", "access_token", "authorization", "auth", "api_key"]
            guard !(URLComponents(string: source.search.url)?.queryItems ?? []).contains(where: { sensitive.contains($0.name.lowercased()) }) else {
                throw SourceSearchError.invalidConfiguration
            }
            overlays[id] = source
        }
        return Snapshot(configurations: base.configurations, nativeSearch: base.nativeSearch, matchers: base.matchers,
            descriptors: subscriptionDescriptors(base.descriptors, active: Set(overlays.keys)),
            loadError: nil, subscription: plan, subscriptionSearch: overlays)
    }

    private func subscriptionDescriptors(_ descriptors: [SourceDescriptor], active: Set<String>) -> [SourceDescriptor] {
        return descriptors.map { descriptor in
            guard SourceSubscriptionConverter.managedSourceIDs.contains(descriptor.id) else { return descriptor }
            var capabilities = descriptor.capabilities
            if active.contains(descriptor.id) { capabilities.insert(.search) }
            else { capabilities.remove(.search) }
            return SourceDescriptor(id: descriptor.id, name: descriptor.name, version: descriptor.version, capabilities: capabilities)
        }
    }

    func source(for id: String) -> SourceConfiguration? {
        snapshot.configurations[id]
    }
    func nativeSearch(for id: String) -> NativeSearchSource? {
        let current = snapshot
        if let source = current.subscriptionSearch[id] { return source }
        guard !SourceSubscriptionConverter.managedSourceIDs.contains(id) else { return nil }
        return current.nativeSearch[id]
    }
    /// Precompiled, host-conflict-checked matchers avoid sorting or allocating on each bookmark lookup.
    func matching(url: String) -> SourceConfiguration? {
        snapshot.matchers.first { $0.matches(url) }
    }

    func descriptor(for id: String) -> SourceDescriptor? {
        snapshot.descriptors.first { $0.id == id }
    }

    /// One classification entry point for native, configured, and local identities.
    func matchingSite(_ url: String) -> SupportSites {
        let current = snapshot
        if URL(string: url)?.isFileURL == true {
            return current.descriptors.contains(where: { $0.id == "local" }) ? .local : .unsupported
        }
        let site: SupportSites
        if let configuration = current.matchers.first(where: { $0.matches(url) }) {
            site = .configured(configuration.id)
        } else {
            site = SupportSites.nativeSite(url: url)
        }
        guard site != .unsupported,
              current.descriptors.contains(where: { $0.id == site.sourceID }) else { return .unsupported }
        return site
    }
    /// Native adapters explicitly declare their content scope; identity kinds are not evidence.
    func classification(for item: SourceItemRef) -> MediaClassification {
        if let configuration = source(for: item.sourceID) { return configuration.classification }
        let kind: MediaContentKind
        switch item.sourceID {
        case "bilibili":
            if BilibiliUrl(url: item.pageURL)?.urlType == .video {
                return MediaClassification(kind: .video, provenance: "bilibili.route.video")
            }
            // PGC routes include animation and live-action; Bangumi title lookup resolves the scope.
            return MediaClassification(kind: .unknown, provenance: "bilibili.pgc.awaiting-bangumi-lookup")
        case "bilibili-live", "douyu", "huya", "cc163", "douyin", "qie-tv": kind = .live
        case "xifan", "girigiri", "jibi", "eacg", "senfun", "haixing", "yinghua", "dilidili", "wedm", "fengche": kind = .anime
        default: return .unknown
        }
        return MediaClassification(kind: kind, provenance: "native-adapter:\(item.sourceID):content-scope-v1")
    }

    /// Source-owned, offline page identity shared by playback and favorites.
    func item(for raw: String) throws -> SourceItemRef {
        if let url = URL(string: raw), url.scheme?.lowercased() == "iina-torrent" {
            guard let selection = TorrentSelection(identityURL: url) else { throw VideoGetError.invalidLink }
            return SourceItemRef(sourceID: "torrent", pageURL: selection.identityURL.absoluteString, kind: .video)
        }
        if let input = try torrentInput(for: raw) {
            return SourceItemRef(sourceID: "torrent", pageURL: input.absoluteString, kind: .work)
        }
        if let url = URL(string: raw), url.isFileURL {
            return SourceItemRef(sourceID: "local", pageURL: url.standardizedFileURL.absoluteString, kind: .local)
        }
        guard var components = URLComponents(string: raw),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil, components.user == nil, components.password == nil else {
            throw VideoGetError.invalidLink
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        guard let page = components.url?.absoluteString else { throw VideoGetError.invalidLink }
        let site = matchingSite(page)
        guard site != .unsupported else { throw VideoGetError.notSupported }
        if case .configured(let id) = site {
            guard let configuration = source(for: id) else { throw VideoGetError.notSupported }
            return try configuration.item(page)
        }
        let canonical: String
        if site == .bilibili || site == .bangumi {
            var input = page
            if components.path.contains("/festival/"),
               let bvid = components.queryItems?.first(where: { $0.name == "bvid" })?.value {
                var video = URLComponents()
                video.scheme = "https"
                video.host = "www.bilibili.com"
                video.path = "/video/\(bvid)"
                video.queryItems = components.queryItems?.filter { $0.name == "p" }
                guard let festivalPage = video.string else { throw VideoGetError.invalidLink }
                input = festivalPage
            }
            guard let normalized = BilibiliUrl(url: input)?.fUrl, !normalized.isEmpty else {
                throw VideoGetError.invalidLink
            }
            canonical = normalized
        } else {
            canonical = page
        }
        let kind: SourceItemRef.Kind
        switch site {
        case .bilibili, .b23, .hanime1: kind = .video
        case .bangumi: kind = BilibiliUrl(url: canonical)?.id.hasPrefix("ss") == true ? .work : .episode
        case .biliLive, .douyu, .huya, .cc163, .douyin, .qieTV: kind = .live
        default: kind = components.path.contains("detail") || components.path.contains("bangumi") ? .work : .episode
        }
        return SourceItemRef(sourceID: site.sourceID, pageURL: canonical, kind: kind)
    }

    /// Canonical episode identity owned by the source layer for Discovery baselines.
    func episodeIdentity(for leaf: VideoTreeNode) throws -> String {
        let item = try self.item(for: leaf.selectionURL)
        if let configuration = source(for: item.sourceID) {
            let parts = try configuration.parts(item.pageURL)
            guard let episode = parts.episodeIdentity else { throw VideoGetError.invalidLink }
            return "\(item.sourceID):\(parts.id):\(episode)"
        }
        switch leaf.site {
        case .xiFan, .girigiri, .didahd, .jibi, .eacg, .senfun, .kanba, .haixing,
             .yinghua, .youknow, .wedm, .fengche, .rebo:
            return "\(item.sourceID):\(leaf.id):\(leaf.index)"
        default:
            return "\(item.sourceID):\(item.kind.rawValue):\(item.pageURL)"
        }
    }

    /// Imports require metadata and an explicit file choice before downloading.
    func torrentInput(for raw: String) throws -> URL? {
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased() else { return nil }
        if scheme == "magnet" {
            guard components.host == nil, components.user == nil, components.password == nil,
                  components.fragment == nil, components.path.isEmpty,
                  components.queryItems?.contains(where: { $0.name == "xt" &&
                      ($0.value?.hasPrefix("urn:btih:") == true || $0.value?.hasPrefix("urn:btmh:") == true) }) == true,
                  let url = components.url else { throw VideoGetError.invalidLink }
            // The native parser validates digest length and base32 v1 hashes.
            return url
        }
        guard scheme == "file", let url = components.url, url.pathExtension.lowercased() == "torrent" else { return nil }
        guard components.host == nil || components.host == "" || components.host == "localhost",
              components.query == nil, components.fragment == nil, components.user == nil,
              components.password == nil else { throw VideoGetError.invalidLink }
        return url.standardizedFileURL
    }

    /// Favorites remain accessible when a source is missing, disabled, or its page is broken.
    /// No network request or short-link redirect is required to save a link.
    func favoriteItem(for raw: String) throws -> SourceItemRef {
        if let known = try? item(for: raw) { return known }
        return SourceItemRef(sourceID: "unavailable", pageURL: raw, kind: .video)
    }
}
