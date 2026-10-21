import CryptoKit
import Foundation

public enum SkinStoreError: Error, LocalizedError {
    case notInstalled(String)
    case replacementConfirmationRequired(SkinReplacementConfirmation)
    case invalidConfirmation
    case corruptCatalog
    case invalidOverride
    case invalidExportLayout
    case unsafePackageContents(String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled(let id): return String(localized: "Skin is not installed: \(id).")
        case .replacementConfirmationRequired(let change):
            return
                String(localized: "Skin \(change.skinID) has changed (\(change.currentVersion) → \(change.newVersion)); review the changed package files before replacing it.")
        case .invalidConfirmation:
            return String(localized: "The Skin replacement confirmation does not match the pending revision.")
        case .corruptCatalog: return String(localized: "The Skin catalog is invalid and was preserved for recovery.")
        case .invalidOverride:
            return String(localized: "Personal Skin overrides are invalid or exceed the size limit.")
        case .invalidExportLayout:
            return String(localized: "The selected workspace layout could not be safely exported.")
        case .unsafePackageContents(let path):
            return String(localized: "A required Skin package file is missing or unsafe: \(path).")
        }
    }
}
public struct SkinReplacementConfirmation: Equatable, Sendable {
    public let skinID: String
    public let currentDigest: String
    public let newDigest: String
    public let currentVersion: String
    public let newVersion: String
    public let changedFiles: [String]
    public init(
        skinID: String, currentDigest: String, newDigest: String, currentVersion: String,
        newVersion: String, changedFiles: [String]
    ) {
        self.skinID = skinID
        self.currentDigest = currentDigest
        self.newDigest = newDigest
        self.currentVersion = currentVersion
        self.newVersion = newVersion
        self.changedFiles = changedFiles.sorted()
    }
}
public enum SkinImportResult: Sendable {
    case installed(SkinPackage)
    case unchanged(SkinPackage)
    case replaced(SkinPackage, previousDigest: String)
}
public enum SkinExportMode: Sendable { case original, derived }

/// A validated review snapshot; releasing it cancels without installing.
public final class SkinReviewPackage: @unchecked Sendable {
    public let package: SkinPackage
    public let digest: String
    fileprivate init(package: SkinPackage, digest: String) {
        self.package = package
        self.digest = digest
    }
    deinit { try? FileManager.default.removeItem(at: package.directoryURL) }
}

private struct SkinCatalog: Codable {
    struct Record: Codable {
        var id: String
        var digest: String
        var revision: Int
        var name: String
    }
    var records: [String: Record] = [:]
    var selectedSkinID: String?
    var colorScheme: SkinColorScheme = .system
}
public final class SkinStore: @unchecked Sendable {
    public let rootURL: URL
    private let fileManager = FileManager.default
    private let lock = NSRecursiveLock()
    private var catalogURL: URL { rootURL.appendingPathComponent("catalog-v1.json") }
    private var packageRoot: URL { rootURL.appendingPathComponent("revisions", isDirectory: true) }
    private var overrideRoot: URL { rootURL.appendingPathComponent("overrides", isDirectory: true) }
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init(rootURL: URL) { self.rootURL = rootURL }
    private var recoveryNoticeStorage: String?
    public var recoveryNotice: String? { lock.withLock { recoveryNoticeStorage } }
    public var colorScheme: SkinColorScheme {
        lock.withLock { (try? loadCatalog().colorScheme) ?? .system }
    }

    public func installedSkins() throws -> [SkinPackage] {
        try lock.withLock {
            let catalog = try loadCatalog()
            return try catalog.records.values.sorted { $0.id < $1.id }.map {
                try SkinPackageValidator.validate(
                    directoryURL: revisionURL(id: $0.id, digest: $0.digest))
            }
        }
    }

    public func selectedPackage() throws -> SkinPackage? {
        try lock.withLock {
            let catalog = try loadCatalog()
            guard let id = catalog.selectedSkinID, let record = catalog.records[id] else {
                return nil
            }
            return try SkinPackageValidator.validate(
                directoryURL: revisionURL(id: id, digest: record.digest))
        }
    }

    public func setColorScheme(_ scheme: SkinColorScheme) throws {
        try lock.withLock {
            var catalog = try loadCatalog()
            catalog.colorScheme = scheme
            try saveCatalog(catalog)
        }
    }

    public func selectSkin(id: String?, activate: (() throws -> Void)? = nil, validate: ((SkinPackage?) throws -> Void)? = nil) throws {
        try lock.withLock {
            var catalog = try loadCatalog()
            let previous = catalog
            let package: SkinPackage?
            if let id {
                guard let record = catalog.records[id] else {
                    throw SkinStoreError.notInstalled(id)
                }
                package = try SkinPackageValidator.validate(
                    directoryURL: revisionURL(id: id, digest: record.digest))
            } else {
                package = nil
            }
            try validate?(package)
            catalog.selectedSkinID = id
            try commitCatalog(catalog, previous: previous, activate: activate)
        }
    }

    public func importSkin(
        from archiveURL: URL, replacing confirmation: SkinReplacementConfirmation? = nil,
        validateForActivation: ((SkinPackage) throws -> Void)? = nil
    ) throws -> SkinImportResult {
        let review = try prepareReview(archiveURL: archiveURL)
        return try installReviewed(review, replacing: confirmation, validateForActivation: validateForActivation)
    }

    public func prepareReview(archiveURL: URL) throws -> SkinReviewPackage {
        try makeReview { staging in try SkinArchive.extract(from: archiveURL, to: staging) }
    }

    public func prepareReview(directoryURL: URL) throws -> SkinReviewPackage {
        try makeReview { staging in
            let package = try SkinPackageValidator.validate(directoryURL: directoryURL)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try self.copyWhitelistedPackage(package, to: staging)
            let snapshot = try SkinPackageValidator.validate(directoryURL: staging)
            guard try SkinPackageCodec.contentDigest(for: snapshot) == SkinPackageCodec.contentDigest(for: package) else {
                throw SkinStoreError.unsafePackageContents("author directory changed while loading")
            }
        }
    }

    private func makeReview(_ populate: (URL) throws -> Void) throws -> SkinReviewPackage {
        try lock.withLock {
            let staging = fileManager.temporaryDirectory.appendingPathComponent("iina-skin-review-\(UUID().uuidString)", isDirectory: true)
            do {
                try populate(staging)
                let package = try SkinPackageValidator.validate(directoryURL: staging)
                return try SkinReviewPackage(package: package, digest: SkinPackageCodec.contentDigest(for: package))
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        }
    }

    public func replacementRequired(for review: SkinReviewPackage) throws -> SkinReplacementConfirmation? {
        try lock.withLock {
            let catalog = try loadCatalog()
            let id = review.package.manifest.id
            guard let prior = catalog.records[id], prior.digest != review.digest else { return nil }
            let oldURL = revisionURL(id: id, digest: prior.digest)
            let old = try SkinPackageValidator.validate(directoryURL: oldURL)
            return SkinReplacementConfirmation(
                skinID: id, currentDigest: prior.digest, newDigest: review.digest,
                currentVersion: old.manifest.version, newVersion: review.package.manifest.version,
                changedFiles: try changedFiles(old: oldURL, new: review.package.directoryURL))
        }
    }

    /// Installs exactly the reviewed snapshot; installation and selection use one catalog commit.
    public func installReviewed(
        _ review: SkinReviewPackage, replacing confirmation: SkinReplacementConfirmation? = nil,
        select: Bool = false, activate: (() throws -> Void)? = nil,
        validateForActivation: ((SkinPackage) throws -> Void)? = nil
    ) throws -> SkinImportResult {
        try lock.withLock {
            let staged = try SkinPackageValidator.validate(directoryURL: review.package.directoryURL)
            let digest = try SkinPackageCodec.contentDigest(for: staged)
            guard digest == review.digest else { throw SkinStoreError.invalidConfirmation }
            var catalog = try loadCatalog()
            let previous = catalog
            let id = staged.manifest.id
            let prior = catalog.records[id]
            if let prior, prior.digest == digest {
                let installed = try SkinPackageValidator.validate(directoryURL: revisionURL(id: id, digest: digest))
                try validateForActivation?(installed)
                if select { catalog.selectedSkinID = id }
                if select || activate != nil { try commitCatalog(catalog, previous: previous, activate: activate) }
                return .unchanged(installed)
            }
            if let required = try replacementRequired(for: review) {
                guard confirmation == required else { throw SkinStoreError.replacementConfirmationRequired(required) }
            } else if confirmation != nil { throw SkinStoreError.invalidConfirmation }
            let destination = revisionURL(id: id, digest: digest)
            let existed = fileManager.fileExists(atPath: destination.path)
            let installed: SkinPackage
            do {
                if !existed {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                    try copyWhitelistedPackage(staged, to: destination)
                }
                installed = try SkinPackageValidator.validate(directoryURL: destination)
                guard try SkinPackageCodec.contentDigest(for: installed) == digest else { throw SkinStoreError.invalidConfirmation }
                try validateForActivation?(installed)
                catalog.records[id] = .init(id: id, digest: digest, revision: installed.manifest.revision, name: installed.manifest.name)
                if select { catalog.selectedSkinID = id }
                try commitCatalog(catalog, previous: previous, activate: activate)
            } catch {
                if !existed, !(error is SkinCatalogRollbackFailure) { try? fileManager.removeItem(at: destination) }
                throw error
            }
            if let prior { removeRevisionIfUnreferenced(id: id, digest: prior.digest, catalog: catalog) }
            if let prior { return .replaced(installed, previousDigest: prior.digest) }
            return .installed(installed)
        }
    }

    public func removeSkin(id: String) throws {
        try lock.withLock {
            var catalog = try loadCatalog()
            guard let old = catalog.records.removeValue(forKey: id) else {
                throw SkinStoreError.notInstalled(id)
            }
            if catalog.selectedSkinID == id { catalog.selectedSkinID = nil }
            try saveCatalog(catalog)
            removeRevisionIfUnreferenced(id: id, digest: old.digest, catalog: catalog)
            let url = overridesURL(id: id)
            if fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
        }
    }

    public func loadOverrides(for skinID: String) throws -> SkinPersonalOverrides {
        try lock.withLock {
            let url = overridesURL(id: skinID)
            guard fileManager.fileExists(atPath: url.path) else { return SkinPersonalOverrides() }
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                guard ((attributes[.size] as? NSNumber)?.int64Value ?? Int64.max) <= 1_048_576
                else { throw SkinStoreError.invalidOverride }
                let data = try Data(contentsOf: url)
                guard data.count <= 1_048_576 else { throw SkinStoreError.invalidOverride }
                let envelope = try decoder.decode(OverrideEnvelope.self, from: data)
                guard envelope.skinID == skinID else { throw SkinStoreError.invalidOverride }
                return envelope.overrides
            } catch {
                try preserveCorruptFile(url)
                throw SkinStoreError.invalidOverride
            }
        }
    }

    public func saveOverrides(_ overrides: SkinPersonalOverrides, for skinID: String) throws {
        try lock.withLock {
            let data = try encoder.encode(OverrideEnvelope(skinID: skinID, overrides: overrides))
            guard data.count <= 1_048_576 else { throw SkinStoreError.invalidOverride }
            try fileManager.createDirectory(at: overrideRoot, withIntermediateDirectories: true)
            try data.write(to: overridesURL(id: skinID), options: .atomic)
        }
    }

    public func exportSkin(
        id: String, to destination: URL, mode: SkinExportMode, layout: WorkspaceLayout? = nil,
        overrides: SkinPersonalOverrides? = nil
    ) throws {
        try lock.withLock {
            let catalog = try loadCatalog()
            guard let record = catalog.records[id] else { throw SkinStoreError.notInstalled(id) }
            let package = try SkinPackageValidator.validate(
                directoryURL: revisionURL(id: id, digest: record.digest))
            let staging = rootURL.appendingPathComponent(
                ".export-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: staging) }
            try copyWhitelistedPackage(package, to: staging)
            if mode == .derived {
                var manifest = package.manifest
                let derivedID = "iina-ani.derived.\(UUID().uuidString.lowercased())"
                manifest.id = derivedID
                manifest.provenance["originalID"] = package.manifest.id
                manifest.provenance["originalName"] = package.manifest.name
                manifest.provenance["originalAuthor"] = package.manifest.author ?? ""
                manifest.provenance["originalLicense"] = package.manifest.license
                manifest.provenance["sourceDigest"] = record.digest
                manifest.provenance["derivedFrom"] = package.manifest.id
                manifest.layout = try layout.map { try WorkspaceLayoutCodec.sanitizedForSharing($0) }
                let personal = try overrides ?? loadOverrides(for: id)
                var theme = package.theme
                merge(personal.theme, into: &theme.system)
                merge(personal.theme, into: &theme.light)
                merge(personal.theme, into: &theme.dark)
                let components = SkinStyleCascade.derivedComponents(
                    package.components, personal: personal)
                let themePath = manifest.entryPaths["theme"] ?? "theme.json"
                let componentsPath = manifest.entryPaths["components"] ?? "components.json"
                try encoder.encode(manifest).write(
                    to: staging.appendingPathComponent("manifest.json"), options: .atomic)
                try encoder.encode(theme).write(
                    to: staging.appendingPathComponent(themePath), options: .atomic)
                try encoder.encode(components).write(
                    to: staging.appendingPathComponent(componentsPath), options: .atomic)
            }
            _ = try SkinPackageValidator.validate(directoryURL: staging)
            try SkinArchive.create(from: staging, to: destination)
        }
    }

    private struct OverrideEnvelope: Codable {
        var skinID: String
        var overrides: SkinPersonalOverrides
    }
    private func loadCatalog() throws -> SkinCatalog {
        guard fileManager.fileExists(atPath: catalogURL.path) else { return SkinCatalog() }
        let attributes = try fileManager.attributesOfItem(atPath: catalogURL.path)
        guard ((attributes[.size] as? NSNumber)?.int64Value ?? Int64.max) <= 1_048_576 else {
            try preserveCorruptFile(catalogURL)
            recoveryNoticeStorage = String(localized: "Skin catalog exceeded the 1 MiB limit and was preserved.")
            return SkinCatalog()
        }
        let data = try Data(contentsOf: catalogURL)
        do {
            guard data.count <= 1_048_576 else { throw SkinStoreError.corruptCatalog }
            let catalog = try decoder.decode(SkinCatalog.self, from: data)
            try validateCatalog(catalog)
            return catalog
        } catch {
            try preserveCorruptFile(catalogURL)
            recoveryNoticeStorage =
                String(localized: "Skin catalog was invalid and preserved as a corrupt backup: \(error.localizedDescription)")
            return SkinCatalog()
        }
    }
    private func validateCatalog(_ catalog: SkinCatalog) throws {
        guard
            catalog.records.allSatisfy({ entry in
                let (key, record) = entry
                return key == record.id && !key.isEmpty && key.utf8.count <= 128
                    && !key.unicodeScalars.contains(where: {
                        CharacterSet.controlCharacters.contains($0)
                    }) && record.digest.count == 64
                    && record.digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
                    && record.revision >= 0
            }), catalog.selectedSkinID.map({ catalog.records[$0] != nil }) ?? true
        else { throw SkinStoreError.corruptCatalog }
    }
    private func saveCatalog(_ catalog: SkinCatalog) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try encoder.encode(catalog).write(to: catalogURL, options: .atomic)
    }
    private func commitCatalog(_ candidate: SkinCatalog, previous: SkinCatalog, activate: (() throws -> Void)?) throws {
        let wasPresent = fileManager.fileExists(atPath: catalogURL.path)
        try saveCatalog(candidate)
        do { try activate?() } catch {
            do {
                if wasPresent { try saveCatalog(previous) }
                else { try fileManager.removeItem(at: catalogURL) }
            } catch let rollbackError {
                throw SkinCatalogRollbackFailure(operation: error, rollback: rollbackError)
            }
            throw error
        }
    }
    private func revisionURL(id: String, digest: String) -> URL {
        packageRoot.appendingPathComponent(stableKey(id), isDirectory: true).appendingPathComponent(
            digest, isDirectory: true)
    }
    private func overridesURL(id: String) -> URL {
        overrideRoot.appendingPathComponent(stableKey(id) + ".json")
    }
    private func stableKey(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func removeRevisionIfUnreferenced(id: String, digest: String, catalog: SkinCatalog) {
        guard !catalog.records.values.contains(where: { $0.id == id && $0.digest == digest }) else {
            return
        }
        try? fileManager.removeItem(at: revisionURL(id: id, digest: digest))
    }
    private func preserveCorruptFile(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.moveItem(
            at: url, to: url.appendingPathExtension("corrupt-\(UUID().uuidString)"))
    }
    private func copyWhitelistedPackage(_ package: SkinPackage, to destination: URL) throws {
        let root = package.directoryURL.standardizedFileURL
        let themePath = package.manifest.entryPaths["theme"] ?? "theme.json"
        let componentsPath = package.manifest.entryPaths["components"] ?? "components.json"
        func write(_ data: Data, to relativePath: String) throws {
            guard safeRelativePath(relativePath) else {
                throw SkinStoreError.unsafePackageContents(relativePath)
            }
            let target = destination.appendingPathComponent(relativePath).standardizedFileURL
            guard target.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                throw SkinStoreError.unsafePackageContents(relativePath)
            }
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .withoutOverwriting)
        }
        func copy(_ relativePath: String) throws {
            guard safeRelativePath(relativePath) else {
                throw SkinStoreError.unsafePackageContents(relativePath)
            }
            let source = root.appendingPathComponent(relativePath).standardizedFileURL
            guard source.path.hasPrefix(root.path + "/"),
                fileManager.fileExists(atPath: source.path)
            else { throw SkinStoreError.unsafePackageContents(relativePath) }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw SkinStoreError.unsafePackageContents(relativePath)
            }
            try write(Data(contentsOf: source, options: [.mappedIfSafe]), to: relativePath)
        }
        try write(encoder.encode(package.manifest), to: "manifest.json")
        try write(encoder.encode(package.theme), to: themePath)
        let componentsSource = root.appendingPathComponent(componentsPath).standardizedFileURL
        if fileManager.fileExists(atPath: componentsSource.path) {
            try write(encoder.encode(package.components), to: componentsPath)
        }
        if let motionPath = package.manifest.entryPaths["pageMotion"] { try copy(motionPath) }
        let preview = root.appendingPathComponent("preview.png")
        if fileManager.fileExists(atPath: preview.path) { try copy("preview.png") }
        for path in Set(package.manifest.assets.values).sorted() { try copy(path) }
    }
    private func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
    private func merge(
        _ values: [String: SkinJSONValue], into target: inout [String: SkinJSONValue]
    ) {
        target.merge(values) { _, newValue in newValue }
    }
    private func changedFiles(old: URL, new: URL) throws -> [String] {
        func fingerprints(_ root: URL) throws -> [String: String] {
            guard
                let e = fileManager.enumerator(
                    at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [])
            else { throw SkinStoreError.unsafePackageContents("package directory") }
            var result: [String: String] = [:]
            while let url = e.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                ])
                guard values.isSymbolicLink != true else {
                    throw SkinStoreError.unsafePackageContents(url.lastPathComponent)
                }
                guard values.isRegularFile == true else { continue }
                let rootPath = root.standardizedFileURL.path
                let itemPath = url.standardizedFileURL.path
                guard itemPath.hasPrefix(rootPath + "/") else {
                    throw SkinStoreError.unsafePackageContents(url.lastPathComponent)
                }
                let path = String(itemPath.dropFirst(rootPath.count + 1))
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    hash.update(data: chunk)
                }
                result[path] = hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
            return result
        }
        let before = try fingerprints(old)
        let after = try fingerprints(new)
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }
}

private struct SkinCatalogRollbackFailure: Error, LocalizedError {
    let operation: Error
    let rollback: Error
    var errorDescription: String? {
        String(localized: "Skin activation failed: \(operation.localizedDescription). Catalog rollback also failed: \(rollback.localizedDescription). Both package revisions were preserved; installed selection requires recovery.")
    }
}

extension NSRecursiveLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
