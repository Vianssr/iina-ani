import CryptoKit
import Darwin
import Foundation

public enum SkinJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: SkinJSONValue])
    case array([SkinJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SkinJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SkinJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct SkinManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentComponentContractVersion = 1
    public static let currentAppVersion = "0.8.32"

    public var schemaVersion: Int
    public var componentContractVersion: Int
    public var minimumAppVersion: String
    public var supportedVariants: Set<SkinColorScheme>
    public var entryPaths: [String: String]
    public var id: String
    public var version: String
    public var revision: Int
    public var name: String
    public var author: String?
    public var license: String
    public var assets: [String: String]
    public var assetAttributions: [String: String]
    public var provenance: [String: String]
    public var layout: WorkspaceLayout?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, componentContractVersion, minimumAppVersion, supportedVariants,
            entryPaths
        case id, version, revision, name, author, license, assets, assetAttributions, provenance,
            layout
    }

    public init(
        id: String,
        version: String,
        name: String,
        license: String,
        schemaVersion: Int = currentSchemaVersion,
        componentContractVersion: Int = currentComponentContractVersion,
        minimumAppVersion: String = currentAppVersion,
        supportedVariants: Set<SkinColorScheme> = [.light, .dark],
        entryPaths: [String: String] = [:],
        revision: Int = 0,
        author: String? = nil,
        assets: [String: String] = [:],
        assetAttributions: [String: String] = [:],
        provenance: [String: String] = [:],
        layout: WorkspaceLayout? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.componentContractVersion = componentContractVersion
        self.minimumAppVersion = minimumAppVersion
        self.supportedVariants = supportedVariants
        self.entryPaths = entryPaths
        self.id = id
        self.version = version
        self.revision = revision
        self.name = name
        self.author = author
        self.license = license
        self.assets = assets
        self.assetAttributions = assetAttributions
        self.provenance = provenance
        self.layout = layout
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(componentContractVersion, forKey: .componentContractVersion)
        try container.encode(minimumAppVersion, forKey: .minimumAppVersion)
        try container.encode(
            supportedVariants.sorted { $0.rawValue < $1.rawValue }, forKey: .supportedVariants)
        try container.encode(entryPaths, forKey: .entryPaths)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(revision, forKey: .revision)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encode(license, forKey: .license)
        try container.encode(assets, forKey: .assets)
        try container.encode(assetAttributions, forKey: .assetAttributions)
        try container.encode(provenance, forKey: .provenance)
        try container.encodeIfPresent(layout, forKey: .layout)
    }
}

public struct SkinTheme: Codable, Equatable, Sendable {
    public var light: [String: SkinJSONValue]
    public var dark: [String: SkinJSONValue]
    public var system: [String: SkinJSONValue]

    public init(
        light: [String: SkinJSONValue] = [:], dark: [String: SkinJSONValue] = [:],
        system: [String: SkinJSONValue] = [:]
    ) {
        self.light = light
        self.dark = dark
        self.system = system
    }
}

public struct SkinSlotStyle: Codable, Equatable, Sendable {
    public var values: [String: SkinJSONValue]
    public var states: [String: [String: SkinJSONValue]]

    public init(
        values: [String: SkinJSONValue] = [:], states: [String: [String: SkinJSONValue]] = [:]
    ) {
        self.values = values
        self.states = states
    }
}

public struct SkinComponents: Codable, Equatable, Sendable {
    public var slots: [String: SkinSlotStyle]
    public var overrides: [String: [String: SkinSlotStyle]]

    public init(
        slots: [String: SkinSlotStyle] = [:], overrides: [String: [String: SkinSlotStyle]] = [:]
    ) {
        self.slots = slots
        self.overrides = overrides
    }
}

/// Shared cascade for live rendering and standalone derived packages.
enum SkinStyleCascade {
    static func merge(_ base: SkinSlotStyle, _ overlay: SkinSlotStyle?) -> SkinSlotStyle {
        guard let overlay else { return base }
        var result = base
        for role in SkinAssetRole.allCases {
            let key = role.rawValue + "Asset"
            if overlay.values[key] != nil || overlay.states["normal"]?[key] != nil {
                result.values.removeValue(forKey: key)
                for state in Array(result.states.keys) {
                    result.states[state]?.removeValue(forKey: key)
                }
            }
        }
        result.values.merge(overlay.values) { _, new in new }
        for (state, values) in overlay.states {
            result.states[state, default: [:]].merge(values) { _, new in new }
        }
        return result
    }

    static func values(
        theme: [String: SkinJSONValue], style: SkinSlotStyle,
        personalTheme: [String: SkinJSONValue], personalStyle: SkinSlotStyle?,
        state: SkinControlState
    ) -> [String: SkinJSONValue] {
        var result = theme
        result.merge(style.values) { _, new in new }
        result.merge(style.states["normal"] ?? [:]) { _, new in new }
        result.merge(style.states[state.rawValue] ?? [:]) { _, new in new }
        result.merge(personalTheme) { _, new in new }
        if let personalStyle {
            result.merge(personalStyle.values) { _, new in new }
            result.merge(personalStyle.states["normal"] ?? [:]) { _, new in new }
            result.merge(personalStyle.states[state.rawValue] ?? [:]) { _, new in new }
        }
        return result
    }

    static func derivedComponents(_ source: SkinComponents, personal: SkinPersonalOverrides)
        -> SkinComponents
    {
        var slots = Set(source.slots.keys).union(personal.slots.keys)
        for component in source.overrides.values { slots.formUnion(component.keys) }
        func flattened(_ slot: String, componentID: String?) -> SkinSlotStyle {
            let author = merge(
                source.slots[slot] ?? SkinSlotStyle(), source.overrides[componentID ?? ""]?[slot])
            let states = Dictionary(
                uniqueKeysWithValues: SkinControlState.allCases.map { state in
                    (
                        state.rawValue,
                        values(
                            theme: [:], style: author, personalTheme: personal.theme,
                            personalStyle: personal.slots[slot], state: state)
                    )
                })
            return SkinSlotStyle(states: states)
        }
        return SkinComponents(
            slots: Dictionary(
                uniqueKeysWithValues: slots.map { ($0, flattened($0, componentID: nil)) }),
            overrides: Dictionary(
                uniqueKeysWithValues: source.overrides.keys.map { componentID in
                    (
                        componentID,
                        Dictionary(
                            uniqueKeysWithValues: slots.map {
                                ($0, flattened($0, componentID: componentID))
                            })
                    )
                }))
    }
}

public struct SkinPackage: Sendable {
    public let manifest: SkinManifest
    public let theme: SkinTheme
    public let components: SkinComponents
    public let pageMotion: WorkspacePageMotion?
    public let directoryURL: URL

    public init(
        manifest: SkinManifest, theme: SkinTheme, components: SkinComponents = SkinComponents(),
        pageMotion: WorkspacePageMotion? = nil, directoryURL: URL
    ) {
        self.manifest = manifest
        self.theme = theme
        self.components = components
        self.pageMotion = pageMotion
        self.directoryURL = directoryURL
    }
}

public enum SkinPackageCodec {
    public static func canonicalData<T: Encodable>(for value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func contentDigest(for package: SkinPackage) throws -> String {
        var hasher = SHA256()
        func appendLength(_ count: UInt64) {
            var value = count.bigEndian
            withUnsafeBytes(of: &value) { hasher.update(data: Data($0)) }
        }
        func appendBlock(_ block: Data) {
            appendLength(UInt64(block.count))
            hasher.update(data: block)
        }
        func appendFile(_ path: String, maximumBytes: Int = 16 * 1024 * 1024) throws {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(92), !path.contains(":"),
                path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".."
                })
            else {
                throw SkinPackageDigestError.unsafeAssetPath(path)
            }
            let root = package.directoryURL.standardizedFileURL
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else {
                throw SkinPackageDigestError.unsafeAssetPath(path)
            }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
                metadata.st_nlink == 1
            else {
                throw SkinPackageDigestError.unreadableAsset(path)
            }
            let expectedLength = UInt64(metadata.st_size)
            guard expectedLength <= UInt64(maximumBytes) else {
                throw SkinPackageDigestError.unreadableAsset(path)
            }
            appendLength(expectedLength)
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var actualLength: UInt64 = 0
            while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
                actualLength += UInt64(chunk.count)
                guard actualLength <= expectedLength else {
                    throw SkinPackageDigestError.unreadableAsset(path)
                }
                hasher.update(data: chunk)
            }
            guard actualLength == expectedLength else {
                throw SkinPackageDigestError.unreadableAsset(path)
            }
        }

        appendBlock(try canonicalData(for: package.manifest))
        appendBlock(try canonicalData(for: package.theme))
        appendBlock(try canonicalData(for: package.components))
        if let motionPath = package.manifest.entryPaths["pageMotion"] {
            appendBlock(Data("pageMotion".utf8))
            appendBlock(Data(motionPath.utf8))
            try appendFile(motionPath, maximumBytes: WorkspacePageMotion.maximumXMLBytes)
        }
        for (assetID, path) in package.manifest.assets.sorted(by: { $0.key < $1.key }) {
            appendBlock(Data(assetID.utf8))
            appendBlock(Data(path.utf8))
            try appendFile(path)
        }
        let preview = package.directoryURL.appendingPathComponent("preview.png")
        if FileManager.default.fileExists(atPath: preview.path) {
            appendBlock(Data("preview.png".utf8))
            try appendFile("preview.png")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum SkinPackageDigestError: Error {
    case unsafeAssetPath(String)
    case unreadableAsset(String)
}

extension SkinPackageDigestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsafeAssetPath(let path): return String(localized: "Skin digest rejected unsafe asset path: \(path)")
        case .unreadableAsset(let path): return String(localized: "Skin digest could not read asset: \(path)")
        }
    }
}
