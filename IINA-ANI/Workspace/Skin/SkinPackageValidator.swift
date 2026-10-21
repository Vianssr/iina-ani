import CoreText
import Darwin
import Foundation
import ImageIO

public enum SkinPackageValidationError: Error, Equatable {
    case missingFile(String)
    case malformedFile(String)
    case unsupportedSchema(Int)
    case invalidManifest(String)
    case unsafePath(String)
    case unexpectedFile(String)
    case symbolicLink(String)
    case hardLink(String)
    case fileTooLarge(String)
    case packageTooLarge
    case invalidAsset(String)
    case missingAsset(String)
    case unsupportedPayload(String)
    case invalidStyle(String)
    case invalidLayout
}
extension SkinPackageValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingFile(let path): return String(localized: "Skin package is missing required file: \(path)")
        case .malformedFile(let path): return String(localized: "Skin package file is invalid: \(path)")
        case .unsupportedSchema(let version):
            return String(localized: "Unsupported Skin manifest schema version \(version).")
        case .invalidManifest(let reason): return String(localized: "Skin manifest is invalid: \(reason)")
        case .unsafePath(let path): return String(localized: "Skin package contains an unsafe relative path: \(path)")
        case .unexpectedFile(let path): return String(localized: "Skin package contains an unsupported file: \(path)")
        case .symbolicLink(let path): return String(localized: "Skin package links are not allowed: \(path)")
        case .hardLink(let path): return String(localized: "Skin package hard links are not allowed: \(path)")
        case .fileTooLarge(let path): return String(localized: "Skin package file exceeds the size limit: \(path)")
        case .packageTooLarge: return String(localized: "Skin package exceeds the total expanded size limit.")
        case .invalidAsset(let path): return String(localized: "Skin package asset is corrupt or unsupported: \(path)")
        case .missingAsset(let path): return String(localized: "Skin package references a missing asset: \(path)")
        case .unsupportedPayload(let path):
            return String(localized: "Skin package contains a prohibited executable payload: \(path)")
        case .invalidStyle(let reason): return String(localized: "Skin style data is invalid: \(reason)")
        case .invalidLayout: return String(localized: "Skin author layout does not satisfy the workspace contract.")
        }
    }
}
public enum SkinPackageValidator {
    public static let maximumPackageBytes = 64 * 1024 * 1024
    public static let maximumDocumentBytes = 1 * 1024 * 1024
    public static let maximumAssetBytes = 16 * 1024 * 1024
    private static let allowedTokens: Set<String> = [
        "foreground", "background", "borderColor", "fontFamily", "fontSize", "spacing", "radius",
        "borderWidth", "density", "opacity",
        "backgroundAsset", "iconAsset", "placeholderAsset", "decorationAsset",
    ]
    public static func validate(_ package: SkinPackage) throws {
        try validate(package, checkDirectoryContent: true)
    }

    private static func validate(_ package: SkinPackage, checkDirectoryContent: Bool) throws {
        try validateManifest(package.manifest)
        try validateTheme(package.theme)
        try validateStyles(package.components)
        for values in [package.theme.light, package.theme.dark, package.theme.system] {
            try validateAssetReferences(values, assets: package.manifest.assets)
        }
        for style in package.components.slots.values {
            try validateAssetReferences(style, assets: package.manifest.assets)
        }
        for slots in package.components.overrides.values {
            for style in slots.values {
                try validateAssetReferences(style, assets: package.manifest.assets)
            }
        }
        if let layout = package.manifest.layout {
            do {
                try WorkspaceValidator(registry: WorkspaceRegistry.builtins).validate(layout)
            } catch { throw SkinPackageValidationError.invalidLayout }
        }
        if checkDirectoryContent {
            let root = package.directoryURL.standardizedFileURL
            let manifestData = try read("manifest.json", root: root)
            try preflightManifestLayout(in: manifestData)
            try checkKeys(
                manifestData,
                allowed: [
                    "schemaVersion", "componentContractVersion", "minimumAppVersion",
                    "supportedVariants", "entryPaths", "id", "version", "revision", "name",
                    "author", "license", "assets", "assetAttributions", "provenance", "layout",
                ], file: "manifest.json")
            let diskManifest: SkinManifest
            do {
                diskManifest = try JSONDecoder().decode(SkinManifest.self, from: manifestData)
            } catch { throw SkinPackageValidationError.malformedFile("manifest.json") }
            guard diskManifest == package.manifest else {
                throw SkinPackageValidationError.invalidManifest(
                    "package metadata does not match manifest.json")
            }
            let themePath = package.manifest.entryPaths["theme"] ?? "theme.json"
            let themeData = try read(themePath, root: root)
            try checkKeys(themeData, allowed: ["light", "dark", "system"], file: themePath)
            let diskTheme: SkinTheme
            do { diskTheme = try JSONDecoder().decode(SkinTheme.self, from: themeData) } catch {
                throw SkinPackageValidationError.malformedFile(themePath)
            }
            guard diskTheme == package.theme else {
                throw SkinPackageValidationError.invalidManifest(
                    "package theme does not match theme entry")
            }
            let componentsPath = package.manifest.entryPaths["components"] ?? "components.json"
            let componentsURL = root.appendingPathComponent(componentsPath).standardizedFileURL
            var diskComponents = SkinComponents()
            if FileManager.default.fileExists(atPath: componentsURL.path) {
                let componentsData = try read(componentsPath, root: root)
                try checkKeys(
                    componentsData, allowed: ["slots", "overrides"], file: componentsPath)
                try checkComponentKeys(componentsData, file: componentsPath)
                do {
                    diskComponents = try JSONDecoder().decode(
                        SkinComponents.self, from: componentsData)
                } catch { throw SkinPackageValidationError.malformedFile(componentsPath) }
            } else if package.manifest.entryPaths["components"] != nil {
                throw SkinPackageValidationError.missingFile(componentsPath)
            }
            guard diskComponents == package.components else {
                throw SkinPackageValidationError.invalidManifest(
                    "package components do not match components entry")
            }
            let diskPageMotion = try readPageMotion(package.manifest, root: root)
            guard diskPageMotion == package.pageMotion else {
                throw SkinPackageValidationError.invalidManifest(
                    "package page motion does not match pageMotion entry")
            }
            try validateContents(
                root: root, manifest: package.manifest, themePath: themePath,
                componentsPath: componentsPath)
        }
    }

    private static func validateAssetReferences(
        _ values: [String: SkinJSONValue], assets: [String: String]
    ) throws {
        for (key, value) in values where key.hasSuffix("Asset") {
            guard case .string(let id) = value, assets[id] != nil else {
                throw SkinPackageValidationError.missingAsset(key)
            }
        }
    }
    private static func validateAssetReferences(_ style: SkinSlotStyle, assets: [String: String])
        throws
    {
        try validateAssetReferences(style.values, assets: assets)
        for values in style.states.values { try validateAssetReferences(values, assets: assets) }
    }
    private static func checkComponentKeys(_ data: Data, file: String) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkinPackageValidationError.malformedFile(file)
        }
        func checkStyles(_ raw: Any?) throws {
            guard let styles = raw as? [String: Any] else {
                throw SkinPackageValidationError.malformedFile(file)
            }
            for (_, rawStyle) in styles {
                guard let style = rawStyle as? [String: Any],
                    Set(style.keys).isSubset(of: Set(["values", "states"])),
                    style["values"] as? [String: Any] != nil,
                    let states = style["states"] as? [String: Any]
                else {
                    throw SkinPackageValidationError.malformedFile(file)
                }
                for (_, rawValues) in states where rawValues as? [String: Any] == nil {
                    throw SkinPackageValidationError.malformedFile(file)
                }
            }
        }
        guard let topSlots = root["slots"] as? [String: Any],
            let componentOverrides = root["overrides"] as? [String: Any]
        else {
            throw SkinPackageValidationError.malformedFile(file)
        }
        try checkStyles(topSlots)
        for rawSlots in componentOverrides.values {
            guard let slots = rawSlots as? [String: Any] else {
                throw SkinPackageValidationError.malformedFile(file)
            }
            try checkStyles(slots)
        }
    }

    private static let semanticSlots = Set(SkinSlot.allCases.map(\.rawValue))

    public static func validate(directoryURL: URL) throws -> SkinPackage {
        let root = directoryURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw SkinPackageValidationError.missingFile("package directory")
        }
        let manifestData = try read("manifest.json", root: root)
        try preflightManifestLayout(in: manifestData)
        try checkKeys(
            manifestData,
            allowed: [
                "schemaVersion", "componentContractVersion", "minimumAppVersion",
                "supportedVariants", "entryPaths", "id", "version", "revision", "name", "author",
                "license", "assets", "assetAttributions", "provenance", "layout",
            ], file: "manifest.json")
        let manifest: SkinManifest
        manifest = try decodeDocument(SkinManifest.self, data: manifestData, file: "manifest.json")
        try validateManifest(manifest)

        let themePath = manifest.entryPaths["theme"] ?? "theme.json"
        guard safeRelativePath(themePath) else {
            throw SkinPackageValidationError.unsafePath(themePath)
        }
        let themeData = try read(themePath, root: root)
        try checkKeys(themeData, allowed: ["light", "dark", "system"], file: themePath)
        let theme: SkinTheme
        theme = try decodeDocument(SkinTheme.self, data: themeData, file: themePath)

        var components = SkinComponents()
        let componentsPath = manifest.entryPaths["components"] ?? "components.json"
        guard safeRelativePath(componentsPath) else {
            throw SkinPackageValidationError.unsafePath(componentsPath)
        }
        let componentsURL = root.appendingPathComponent(componentsPath).standardizedFileURL
        if FileManager.default.fileExists(atPath: componentsURL.path) {
            let data = try read(componentsPath, root: root)
            try checkKeys(data, allowed: ["slots", "overrides"], file: componentsPath)
            try checkComponentKeys(data, file: componentsPath)
            components = try decodeDocument(SkinComponents.self, data: data, file: componentsPath)
        } else if manifest.entryPaths["components"] != nil {
            throw SkinPackageValidationError.missingFile(componentsPath)
        }
        let pageMotion = try readPageMotion(manifest, root: root)
        try atField(componentsPath) { try validateStyles(components) }
        try atField(themePath) { try validateTheme(theme) }
        try validateContents(
            root: root, manifest: manifest, themePath: themePath, componentsPath: componentsPath)
        if let layout = manifest.layout {
            do {
                try WorkspaceValidator(registry: WorkspaceRegistry.builtins).validate(layout)
            } catch { throw SkinPackageValidationError.invalidLayout }
        }
        let package = SkinPackage(
            manifest: manifest, theme: theme, components: components, pageMotion: pageMotion,
            directoryURL: root)
        try validate(package, checkDirectoryContent: false)
        return package
    }
    private static func decodeDocument<T: Decodable>(_ type: T.Type, data: Data, file: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch let error as DecodingError {
            let context: DecodingError.Context
            var missing: String?
            switch error {
            case .keyNotFound(let key, let value): context = value; missing = key.stringValue
            case .typeMismatch(_, let value), .valueNotFound(_, let value), .dataCorrupted(let value): context = value
            @unknown default: throw SkinPackageValidationError.malformedFile(file)
            }
            var fields = context.codingPath.map(\.stringValue)
            if let missing { fields.append(missing) }
            throw SkinPackageValidationError.malformedFile("\(file) [\(fields.joined(separator: "."))]: \(context.debugDescription)")
        } catch { throw SkinPackageValidationError.malformedFile(file) }
    }
    private static func atField(_ field: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch SkinPackageValidationError.invalidStyle(let reason) {
            throw SkinPackageValidationError.invalidStyle("\(field): \(reason)")
        }
    }

    private static func preflightManifestLayout(in data: Data) throws {
        let bytes = Array(data)
        var index = 0
        skipWhitespace(bytes, &index)
        guard index < bytes.count, bytes[index] == 123 else {
            throw SkinPackageValidationError.malformedFile("manifest.json")
        }
        index += 1
        while index < bytes.count {
            skipWhitespace(bytes, &index)
            guard index < bytes.count else {
                throw SkinPackageValidationError.malformedFile("manifest.json")
            }
            if bytes[index] == 125 { return }
            guard let (key, _) = readJSONString(bytes, &index) else {
                throw SkinPackageValidationError.malformedFile("manifest.json")
            }
            skipWhitespace(bytes, &index)
            guard index < bytes.count, bytes[index] == 58 else {
                throw SkinPackageValidationError.malformedFile("manifest.json")
            }
            index += 1
            skipWhitespace(bytes, &index)
            let valueRange = try scanJSONValue(bytes, &index)
            if key == "layout" {
                let raw = Data(bytes[valueRange])
                if String(data: raw, encoding: .utf8) != "null" {
                    do {
                        _ = try WorkspaceLayoutCodec.decode(
                            raw, validator: WorkspaceValidator(registry: WorkspaceRegistry.builtins)
                        )
                    } catch { throw SkinPackageValidationError.invalidLayout }
                }
            }
            skipWhitespace(bytes, &index)
            guard index < bytes.count else {
                throw SkinPackageValidationError.malformedFile("manifest.json")
            }
            if bytes[index] == 44 {
                index += 1
                continue
            }
            if bytes[index] == 125 { return }
            throw SkinPackageValidationError.malformedFile("manifest.json")
        }
        throw SkinPackageValidationError.malformedFile("manifest.json")
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private static func readJSONString(_ bytes: [UInt8], _ index: inout Int) -> (
        String, Range<Int>
    )? {
        guard index < bytes.count, bytes[index] == 34 else { return nil }
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 92 {
                escaped = true
            } else if byte == 34 {
                let range = start..<index
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[range]))
                else { return nil }
                return (value, range)
            }
        }
        return nil
    }

    private static func scanJSONValue(_ bytes: [UInt8], _ index: inout Int) throws -> Range<Int> {
        let start = index
        guard index < bytes.count else {
            throw SkinPackageValidationError.malformedFile("manifest.json")
        }
        if bytes[index] == 34 {
            guard readJSONString(bytes, &index) != nil else {
                throw SkinPackageValidationError.malformedFile("manifest.json")
            }
            return start..<index
        }
        if bytes[index] == 123 || bytes[index] == 91 {
            var depth = 0
            var inString = false
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 92 {
                        escaped = true
                    } else if byte == 34 {
                        inString = false
                    }
                } else if byte == 34 {
                    inString = true
                } else if byte == 123 || byte == 91 {
                    depth += 1
                } else if byte == 125 || byte == 93 {
                    depth -= 1
                    if depth == 0 { return start..<index }
                    if depth < 0 { break }
                }
            }
            throw SkinPackageValidationError.malformedFile("manifest.json")
        }
        while index < bytes.count && ![9, 10, 13, 32, 44, 125].contains(bytes[index]) { index += 1 }
        guard index > start else { throw SkinPackageValidationError.malformedFile("manifest.json") }
        return start..<index
    }

    private static func read(
        _ path: String, root: URL,
        maximumBytes: Int = SkinPackageValidator.maximumDocumentBytes
    ) throws -> Data {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard safeRelativePath(path), url.path.hasPrefix(root.path + "/") else {
            throw SkinPackageValidationError.unsafePath(path)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SkinPackageValidationError.missingFile(path)
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw SkinPackageValidationError.symbolicLink(path)
        }
        guard let size = values.fileSize, size <= maximumBytes else {
            throw SkinPackageValidationError.fileTooLarge(path)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw SkinPackageValidationError.fileTooLarge(path)
        }
        return data
    }

    private static func readPageMotion(_ manifest: SkinManifest, root: URL) throws -> WorkspacePageMotion? {
        guard let path = manifest.entryPaths["pageMotion"] else { return nil }
        let data = try read(path, root: root, maximumBytes: WorkspacePageMotion.maximumXMLBytes)
        do { return try WorkspacePageMotion.decodeXML(data) }
        catch { throw SkinPackageValidationError.malformedFile(path) }
    }

    private static func checkKeys(_ data: Data, allowed: Set<String>, file: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            Set(dictionary.keys).isSubset(of: allowed)
        else { throw SkinPackageValidationError.malformedFile(file) }
    }

    private static func validateManifest(_ value: SkinManifest) throws {
        guard value.schemaVersion == SkinManifest.currentSchemaVersion else {
            throw SkinPackageValidationError.unsupportedSchema(value.schemaVersion)
        }
        guard value.componentContractVersion == SkinManifest.currentComponentContractVersion,
            !value.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !value.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !value.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !value.minimumAppVersion.isEmpty, value.revision >= 0,
            !value.supportedVariants.isEmpty, !value.supportedVariants.contains(.system)
        else {
            throw SkinPackageValidationError.invalidManifest("required metadata")
        }
        let entryKeys = Set(value.entryPaths.keys)
        let entryValues = Array(value.entryPaths.values)
        guard entryKeys.isSubset(of: Set(["theme", "components", "pageMotion"])),
            entryValues.allSatisfy(safeRelativePath),
            Set(entryValues.map { $0.lowercased() }).count == entryValues.count
        else {
            throw SkinPackageValidationError.invalidManifest("entryPaths")
        }
        var declaredPaths = Set(["manifest.json", "preview.png"])
        var effectivePaths = [
            value.entryPaths["theme"] ?? "theme.json",
            value.entryPaths["components"] ?? "components.json",
        ]
        if let motionPath = value.entryPaths["pageMotion"] { effectivePaths.append(motionPath) }
        for path in effectivePaths + Array(value.assets.values) {
            guard safeRelativePath(path), declaredPaths.insert(path.lowercased()).inserted else {
                throw SkinPackageValidationError.invalidManifest("path collision: " + path)
            }
        }
        guard Set(value.assetAttributions.keys).isSubset(of: Set(value.assets.keys)) else {
            throw SkinPackageValidationError.invalidManifest("asset attribution reference")
        }
        guard let requiredVersion = parseVersion(value.minimumAppVersion),
            let currentVersion = parseVersion(SkinManifest.currentAppVersion),
            compareVersion(requiredVersion, currentVersion) <= 0
        else {
            throw SkinPackageValidationError.invalidManifest("minimumAppVersion")
        }
        for (role, path) in value.assets {
            guard !role.isEmpty, safeRelativePath(path) else {
                throw SkinPackageValidationError.unsafePath(path)
            }
            if role.hasPrefix("font"),
                value.assetAttributions[role]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty != false
            {
                throw SkinPackageValidationError.invalidManifest("font attribution: \(role)")
            }
        }
        for key in value.provenance.keys
        where ![
            "originalID", "originalName", "originalAuthor", "originalLicense", "sourceDigest",
            "derivedFrom", "derivedAt",
        ].contains(key) {
            throw SkinPackageValidationError.invalidManifest("unknown provenance field: \(key)")
        }
    }

    private static func validateTheme(_ theme: SkinTheme) throws {
        try atField("light") { try validateTokens(theme.light) }
        try atField("dark") { try validateTokens(theme.dark) }
        try atField("system") { try validateTokens(theme.system) }
    }
    private static func validateStyles(_ components: SkinComponents) throws {
        let builtinIDs = Set(WorkspaceRegistry.builtins.descriptors.map { $0.id.rawValue })
        let availableSlots = semanticSlots.union(
            WorkspaceRegistry.builtins.descriptors.reduce(into: Set<String>()) {
                $0.formUnion($1.styleSlots)
            })
        for (slot, style) in components.slots {
            guard availableSlots.contains(slot) else {
                throw SkinPackageValidationError.invalidStyle("unknown slot \(slot)")
            }
            try atField("slots.\(slot)") { try validateStyle(style) }
        }
        for (component, slots) in components.overrides {
            guard builtinIDs.contains(component) else {
                throw SkinPackageValidationError.invalidStyle("unknown component \(component)")
            }
            for (slot, style) in slots {
                guard availableSlots.contains(slot) else {
                    throw SkinPackageValidationError.invalidStyle("unknown slot \(slot)")
                }
                try atField("overrides.\(component).\(slot)") { try validateStyle(style) }
            }
        }
    }
    private static func validateStyle(_ style: SkinSlotStyle) throws {
        try atField("values") { try validateTokens(style.values) }
        for (state, values) in style.states where state != "normal" {
            for role in SkinAssetRole.allCases {
                let assetKey = role.rawValue + "Asset"
                if values[assetKey] != nil,
                    style.values[assetKey] == nil,
                    style.states["normal"]?[assetKey] == nil
                {
                    throw SkinPackageValidationError.invalidStyle(
                        "state asset requires normal fallback: \(assetKey)")
                }
            }
        }
        for (state, values) in style.states {
            guard SkinControlState(rawValue: state) != nil else {
                throw SkinPackageValidationError.invalidStyle("unknown state \(state)")
            }
            try atField("states.\(state)") { try validateTokens(values) }
        }
    }
    private static func validateTokens(_ values: [String: SkinJSONValue]) throws {
        for (key, value) in values {
            guard allowedTokens.contains(key) else {
                throw SkinPackageValidationError.invalidStyle("unknown token \(key)")
            }
            if ["spacing", "radius", "borderWidth", "fontSize", "opacity"].contains(key) {
                guard case .number(let n) = value, n.isFinite, n >= 0, n <= 2048,
                    key != "opacity" || n <= 1
                else { throw SkinPackageValidationError.invalidStyle("invalid number \(key)") }
            } else if key.hasSuffix("Asset") || key == "foreground" || key == "background"
                || key == "borderColor" || key == "fontFamily" || key == "density"
            {
                guard case .string(let text) = value, !text.isEmpty else {
                    throw SkinPackageValidationError.invalidStyle("invalid string \(key)")
                }
                if ["foreground", "background", "borderColor"].contains(key) {
                    guard validHexColor(text) else {
                        throw SkinPackageValidationError.invalidStyle("invalid color \(key)")
                    }
                }
                if key == "density", !["compact", "regular", "comfortable"].contains(text) {
                    throw SkinPackageValidationError.invalidStyle("invalid density")
                }
            }
        }
    }

    private static func validateContents(
        root: URL, manifest: SkinManifest, themePath: String, componentsPath: String
    ) throws {
        var allowed: Set<String> = ["manifest.json", themePath, "preview.png"]
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw SkinPackageValidationError.symbolicLink("package directory")
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(componentsPath).path)
        {
            allowed.insert(componentsPath)
        }
        if let motionPath = manifest.entryPaths["pageMotion"] { allowed.insert(motionPath) }
        allowed.formUnion(manifest.assets.values)
        var seenInodes = Set<String>()
        var total = 0
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                ], options: [])
        else {
            throw SkinPackageValidationError.invalidManifest("unreadable directory")
        }
        while let url = enumerator.nextObject() as? URL {
            let v = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            let path = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard v.isSymbolicLink != true else {
                throw SkinPackageValidationError.symbolicLink(path)
            }
            if v.isDirectory == true { continue }
            guard v.isRegularFile == true, allowed.contains(path) else {
                throw SkinPackageValidationError.unexpectedFile(path)
            }
            let size = v.fileSize ?? Int.max
            let maximumBytes = path == manifest.entryPaths["pageMotion"]
                ? WorkspacePageMotion.maximumXMLBytes : maximumAssetBytes
            guard size <= maximumBytes else {
                throw SkinPackageValidationError.fileTooLarge(path)
            }
            total += size
            guard total <= maximumPackageBytes else {
                throw SkinPackageValidationError.packageTooLarge
            }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw SkinPackageValidationError.malformedFile(path)
            }
            guard metadata.st_nlink == 1 else { throw SkinPackageValidationError.hardLink(path) }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let dev = attrs[.systemNumber] as? NSNumber,
                let ino = attrs[.systemFileNumber] as? NSNumber
            {
                let identity = "\(dev.stringValue):\(ino.stringValue)"
                guard seenInodes.insert(identity).inserted else {
                    throw SkinPackageValidationError.hardLink(path)
                }
            }
            if [".js", ".scpt", ".sh", ".dylib", ".so", ".app", ".command", ".wasm"].contains(
                url.pathExtension.lowercased())
            {
                throw SkinPackageValidationError.unsupportedPayload(path)
            }
        }
        for (role, path) in manifest.assets {
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), allowed.contains(path),
                FileManager.default.fileExists(atPath: url.path)
            else { throw SkinPackageValidationError.missingAsset(path) }
            let ext = url.pathExtension.lowercased()
            if role.hasPrefix("font") {
                guard ["ttf", "otf"].contains(ext), let data = try? Data(contentsOf: url),
                    data.count <= maximumAssetBytes,
                    data.starts(with: [0x00, 0x01, 0x00, 0x00])
                        || data.starts(with: [0x4F, 0x54, 0x54, 0x4F]),
                    CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) != nil
                else { throw SkinPackageValidationError.invalidAsset(path) }
            } else {
                try validateImage(url, path: path)
            }
        }
        let preview = root.appendingPathComponent("preview.png")
        if FileManager.default.fileExists(atPath: preview.path) {
            try validateImage(preview, path: "preview.png")
        }
    }
    private static func validateImage(_ url: URL, path: String) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let type = CGImageSourceGetType(source) as String?,
            ["public.png", "public.jpeg"].contains(type),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 64_000_000
        else { throw SkinPackageValidationError.invalidAsset(path) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil else {
            throw SkinPackageValidationError.invalidAsset(path)
        }
    }
    private static func validHexColor(_ text: String) -> Bool {
        let raw = text.hasPrefix("#") ? String(text.dropFirst()) : text
        return (raw.count == 6 || raw.count == 8) && raw.allSatisfy { $0.isHexDigit }
    }
    private static func safeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
    private static func parseVersion(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    private static func compareVersion(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<3 {
            if lhs[index] != rhs[index] { return lhs[index] < rhs[index] ? -1 : 1 }
        }
        return 0
    }
}
