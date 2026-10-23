import AppKit
import CoreText
import Foundation
import ImageIO

public enum SkinColorScheme: String, Codable, Hashable, Sendable {
    case light, dark, system
    public var displayTitle: String {
        switch self {
        case .light: String(localized: "淺色")
        case .dark: String(localized: "深色")
        case .system: String(localized: "跟隨系統")
        }
    }
}
public enum SkinDensity: String, Codable, Sendable {
    case compact, regular, comfortable
    public var displayTitle: String {
        switch self {
        case .compact: String(localized: "緊湊")
        case .regular: String(localized: "標準")
        case .comfortable: String(localized: "寬鬆")
        }
    }
}
public enum SkinControlState: String, Codable, CaseIterable, Sendable {
    case normal, hover, pressed, selected, focus, disabled, loading, error
}
public enum SkinSlot: String, Codable, CaseIterable, Sendable {
    case workCard, list, search, navigation, primaryAction, tabs, progress, background, icon,
        placeholder, decoration
}
public enum SkinAssetRole: String, Codable, CaseIterable, Sendable {
    case background, icon, placeholder, decoration
}

public struct SkinPersonalOverrides: Codable, Equatable, Sendable {
    public var theme: [String: SkinJSONValue]
    public var slots: [String: SkinSlotStyle]
    public init(theme: [String: SkinJSONValue] = [:], slots: [String: SkinSlotStyle] = [:]) {
        self.theme = theme
        self.slots = slots
    }
}
public struct SkinResolvedStyle {
    public let background: NSColor
    public let foreground: NSColor
    public let borderColor: NSColor
    public let font: NSFont
    public let spacing: CGFloat
    public let radius: CGFloat
    public let borderWidth: CGFloat
    public let density: SkinDensity
    public let assetIDs: [SkinAssetRole: String]
    public let values: [String: SkinJSONValue]
}
public struct SkinContrastWarning: Equatable, Sendable {
    public let slot: String
    public let state: SkinControlState
    public let ratio: Double
}
public enum SkinAppearanceError: Error, Equatable {
    case invalidAsset(String)
    case invalidFont(String)
    case invalidValue(String)
    case missingVariant(SkinColorScheme)
    case fontRegistration(String)
    case packageRejected(String)
}

extension SkinAppearanceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAsset(let path):
            return String(localized: "Skin image asset is missing, corrupt, or unsupported: \(path)")
        case .invalidFont(let path):
            return String(localized: "Skin font must be a valid attributed TTF or OTF file: \(path)")
        case .invalidValue(let key): return String(localized: "Skin contains an invalid style value: \(key)")
        case .missingVariant(let scheme):
            return String(localized: "This Skin does not provide the \(scheme.displayTitle) appearance.")
        case .fontRegistration(let path): return String(localized: "The Skin font could not be registered: \(path)")
        case .packageRejected(let reason): return String(localized: "Skin package validation failed: \(reason)")
        }
    }
}
@MainActor public final class SkinAppearance {
    public static let didChangeNotification = Notification.Name("SkinAppearanceDidChange")
    public private(set) var revision: UInt64 = 0
    public private(set) var effectiveColorScheme: SkinColorScheme = .light
    public private(set) var selectionError: SkinAppearanceError?
    public private(set) var contrastWarnings: [SkinContrastWarning] = []
    public private(set) var assetError: SkinAppearanceError?
    private var package: SkinPackage?
    private var overrides: SkinPersonalOverrides?
    private var scheme: SkinColorScheme
    private var imageCache: [ImageKey: NSImage] = [:]
    private var cacheCosts: [ImageKey: Int] = [:]
    private var cacheOrder: [ImageKey] = []
    private var cacheCost = 0
    private let maximumCacheCost = 48 * 1024 * 1024
    private let maximumCacheEntries = 256
    private var registeredFonts = Set<URL>()
    private struct ResolutionKey: Hashable {
        let revision: UInt64
        let slot: String
        let componentID: String?
        let state: SkinControlState
    }
    private var styleCache: [ResolutionKey: SkinResolvedStyle] = [:]
    private static var fontReferenceCounts: [URL: Int] = [:]
    private struct ImageKey: Hashable {
        let revision: UInt64
        let asset: String
        let scale: CGFloat
        let width: Int
        let height: Int
    }
    public convenience init() { self.init(builtin: ()) }
    private init(builtin: Void) {
        package = nil
        overrides = nil
        scheme = .system
        effectiveColorScheme = Self.systemScheme()
    }
    public init(
        package: SkinPackage, overrides: SkinPersonalOverrides? = nil,
        scheme: SkinColorScheme = .system
    ) throws {
        try Self.validate(package, overrides: overrides, scheme: scheme)
        self.package = package
        self.overrides = overrides
        self.scheme = scheme
        effectiveColorScheme = scheme == .system ? Self.systemScheme() : scheme
        registeredFonts = try Self.registerFonts(in: package)
    }
    /// Page-authored motion wins; neutral pages inherit the selected Skin without mutating Layout.
    public func pageMotion(for page: WorkspacePage) -> WorkspacePageMotion {
        resolvedPageMotion(page.motion)
    }

    func resolvedPageMotion(_ motion: WorkspacePageMotion) -> WorkspacePageMotion {
        motion == .none ? package?.pageMotion ?? .none : motion
    }

    public func setColorScheme(_ value: SkinColorScheme) {
        guard scheme != value else { return }
        let next = value == .system ? Self.systemScheme() : value
        if let package, Self.variant(package, next) == nil {
            let error = SkinAppearanceError.missingVariant(next)
            if selectionError != error {
                selectionError = error
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
            return
        }
        selectionError = nil
        scheme = value
        effectiveColorScheme = next
        changed()
    }
    public func refreshSystemAppearance() {
        guard scheme == .system else { return }
        let next = Self.systemScheme()
        guard next != effectiveColorScheme else { return }
        if let package, Self.variant(package, next) == nil {
            let error = SkinAppearanceError.missingVariant(next)
            if selectionError != error {
                selectionError = error
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
            return
        }
        selectionError = nil
        effectiveColorScheme = next
        changed()
    }
    private static func systemScheme() -> SkinColorScheme {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
    public func apply(
        package: SkinPackage?, overrides: SkinPersonalOverrides? = nil,
        scheme: SkinColorScheme? = nil
    ) throws {
        let nextScheme = scheme ?? self.scheme
        if let package {
            try Self.validate(package, overrides: overrides, scheme: nextScheme)
        } else if let overrides {
            try Self.validate(overrides, assets: [:])
        }
        var nextFonts = Set<URL>()
        do { if let package { nextFonts = try Self.registerFonts(in: package) } } catch {
            Self.unregister(nextFonts)
            throw error
        }
        let oldFonts = registeredFonts
        self.package = package
        self.overrides = overrides
        self.scheme = nextScheme
        effectiveColorScheme = nextScheme == .system ? Self.systemScheme() : nextScheme
        registeredFonts = nextFonts
        Self.unregister(oldFonts)
        changed()
    }
    public func adopt(_ prepared: SkinAppearance) {
        guard prepared !== self else { return }
        Self.unregister(registeredFonts)
        package = prepared.package
        overrides = prepared.overrides
        scheme = prepared.scheme
        effectiveColorScheme = prepared.effectiveColorScheme
        registeredFonts = prepared.registeredFonts
        prepared.registeredFonts.removeAll()
        changed()
    }
    private func changed() {
        revision &+= 1
        imageCache.removeAll(keepingCapacity: true)
        cacheCosts.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        cacheCost = 0
        styleCache.removeAll(keepingCapacity: true)
        contrastWarnings = []
        assetError = nil
        selectionError = nil
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
    public func resolve(
        slot: SkinSlot, componentID: String? = nil, state: SkinControlState = .normal
    ) -> SkinResolvedStyle {
        resolve(slot: slot.rawValue, componentID: componentID, state: state)
    }
    public func resolve(slot: String, componentID: String? = nil, state: SkinControlState = .normal)
        -> SkinResolvedStyle
    {
        let key = ResolutionKey(
            revision: revision, slot: slot, componentID: componentID, state: state)
        if let cached = styleCache[key] { return cached }
        let components = package?.components
        let style = SkinStyleCascade.merge(
            components?.slots[slot] ?? SkinSlotStyle(),
            components?.overrides[componentID ?? ""]?[slot])
        let values = SkinStyleCascade.values(
            theme: themeValues(), style: style, personalTheme: overrides?.theme ?? [:],
            personalStyle: overrides?.slots[slot], state: state)
        let defaults = Self.defaultStyle(
            slot: slot, componentID: componentID, state: state, scheme: effectiveColorScheme)
        let background =
            Self.color(values["background"]) ?? defaults.background
        let foreground =
            Self.color(values["foreground"]) ?? defaults.foreground
        let border =
            Self.color(values["borderColor"]) ?? Self.defaultBorder(for: effectiveColorScheme)
        let spacing = Self.number(values["spacing"]) ?? (slot == "toolbar" ? 12 : 8)
        let radius = Self.number(values["radius"]) ?? defaults.radius
        let borderWidth = Self.number(values["borderWidth"]) ?? 0
        let size = Self.number(values["fontSize"]) ?? defaults.fontSize
        let defaultFont = NSFont.systemFont(ofSize: size, weight: defaults.fontWeight)
        let font = Self.string(values["fontFamily"]).flatMap { NSFont(name: $0, size: size) }
            ?? defaultFont
        let density = SkinDensity(rawValue: Self.string(values["density"]) ?? "regular") ?? .regular
        let assetIDs = Dictionary(
            uniqueKeysWithValues: SkinAssetRole.allCases.compactMap { role in
                Self.string(values[role.rawValue + "Asset"]).map { (role, $0) }
            })
        let ratio = Self.contrast(foreground, background)
        if ratio < 4.5 {
            let warning = SkinContrastWarning(slot: slot, state: state, ratio: ratio)
            if !contrastWarnings.contains(warning), contrastWarnings.count < 128 {
                contrastWarnings.append(warning)
            }
        }
        let result = SkinResolvedStyle(
            background: background, foreground: foreground, borderColor: border, font: font,
            spacing: spacing, radius: radius, borderWidth: borderWidth, density: density,
            assetIDs: assetIDs, values: values)
        if styleCache.count >= 256 { styleCache.removeAll(keepingCapacity: true) }
        styleCache[key] = result
        return result
    }
    private func themeValues() -> [String: SkinJSONValue] {
        guard let package else { return [:] }
        var values = package.theme.system
        if let variant = Self.variant(package, effectiveColorScheme) {
            values.merge(variant) { _, new in new }
        }
        return values
    }
    private static func variant(_ package: SkinPackage, _ scheme: SkinColorScheme) -> [String:
        SkinJSONValue]?
    {
        guard package.manifest.supportedVariants.contains(scheme) else { return nil }
        return scheme == .dark ? package.theme.dark : package.theme.light
    }
    private static func string(_ value: SkinJSONValue?) -> String? {
        if case .string(let text)? = value { return text }
        return nil
    }
    private static func number(_ value: SkinJSONValue?) -> CGFloat? {
        guard case .number(let number)? = value, number.isFinite, number >= 0, number <= 2048 else {
            return nil
        }
        return CGFloat(number)
    }
    private static func color(_ value: SkinJSONValue?) -> NSColor? {
        guard let text = string(value) else { return nil }
        var hex = text.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if hex.count == 6 { hex += "FF" }
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 24) & 255) / 255, green: CGFloat((value >> 16) & 255) / 255,
            blue: CGFloat((value >> 8) & 255) / 255, alpha: CGFloat(value & 255) / 255)
    }
    private static func defaultBorder(for scheme: SkinColorScheme) -> NSColor {
        paletteColor(scheme == .dark ? 0x7C8A9C : 0x868175)
    }

    private struct DefaultStyle {
        var background: NSColor
        var foreground: NSColor
        var radius: CGFloat = 10
        var fontSize: CGFloat = 13
        var fontWeight: NSFont.Weight = .regular
    }

    private static func paletteColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    /// Semantic fallbacks stay outside the authored cascade, so a Skin or personal value always wins.
    private static func defaultStyle(
        slot: String, componentID: String?, state: SkinControlState, scheme: SkinColorScheme
    ) -> DefaultStyle {
        let dark = scheme == .dark
        let page = paletteColor(dark ? 0x151B25 : 0xF6F4EF)
        let surface = paletteColor(dark ? 0x202A37 : 0xFCFBF8)
        let ink = paletteColor(dark ? 0xEEF0F2 : 0x282B30)
        let muted = paletteColor(dark ? 0xA5B1BF : 0x636760)
        var style = DefaultStyle(background: surface, foreground: ink)
        switch slot {
        case "background", "panel", "toolbar":
            style.background = page
            style.radius = 0
        case "sidebar":
            style.background = paletteColor(dark ? 0x1A222D : 0xEFEEE8)
            style.radius = 0
        case "list":
            style.background = page
            style.radius = 0
        case "pageTitle":
            style.background = page
            style.fontSize = 28
            style.fontWeight = .bold
        case "header":
            style.background = page
            style.fontSize = componentID == "detail.media" ? 26 : 18
            style.fontWeight = .semibold
        case "brand":
            style.background = page
            style.fontSize = 18
            style.fontWeight = .semibold
        case "subtitle", "sectionLabel", "emptyState", "status", "placeholder":
            style.foreground = muted
            style.fontSize = slot == "sectionLabel" ? 10.5 : 12.5
            style.fontWeight = slot == "sectionLabel" ? .semibold : .regular
        case "navigation":
            style.background = paletteColor(dark ? 0x1A222D : 0xEFEEE8)
            style.fontWeight = .medium
            if state == .selected || state == .pressed {
                style.background = paletteColor(dark ? 0x3B3226 : 0xF1E2C6)
                style.foreground = paletteColor(dark ? 0xF3C475 : 0x76501B)
                style.fontWeight = .semibold
            } else if state == .hover || state == .focus {
                style.background = paletteColor(dark ? 0x293341 : 0xE5E3DC)
            }
        case "primaryAction", "button", "tabs":
            style.background = paletteColor(dark ? 0x2A3543 : 0xECE9E1)
            style.fontWeight = .medium
            style.radius = 8
            if state == .hover || state == .focus {
                style.background = paletteColor(dark ? 0x364351 : 0xE4DFD3)
            } else if state == .selected || state == .pressed {
                style.background = paletteColor(dark ? 0x3B3226 : 0xF1E2C6)
                style.foreground = paletteColor(dark ? 0xF3C475 : 0x76501B)
            }
        case "workCard", "row":
            style.radius = 12
            style.fontWeight = .medium
        case "search":
            style.background = paletteColor(dark ? 0x242F3D : 0xFFFFFF)
            style.radius = 10
        case "progress":
            style.background = paletteColor(dark ? 0x304647 : 0xD9E5DF)
            style.foreground = paletteColor(dark ? 0x71CDB7 : 0x146E61)
            style.radius = 3
        default:
            break
        }
        if state == .disabled { style.foreground = muted }
        if state == .error { style.foreground = paletteColor(dark ? 0xF09D98 : 0xA84439) }
        return style
    }
    private static func contrast(_ fg: NSColor, _ bg: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.deviceRGB)!
            func channel(_ x: CGFloat) -> Double {
                let v = Double(x)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722
                * channel(c.blueComponent)
        }
        let a = luminance(fg)
        let b = luminance(bg)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    private func reportAssetError(_ error: SkinAppearanceError) {
        guard assetError != error else { return }
        assetError = error
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
    public func image(assetID: String, scale: CGFloat, targetSize: NSSize) -> NSImage? {
        guard scale.isFinite, scale > 0, let package else { return nil }
        guard let path = package.manifest.assets[assetID] else {
            reportAssetError(.invalidAsset(assetID))
            return nil
        }
        let root = package.directoryURL.standardizedFileURL
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"),
            ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
            targetSize.width.isFinite, targetSize.height.isFinite,
            targetSize.width > 0, targetSize.height > 0,
            targetSize.width < 8192, targetSize.height < 8192
        else { return nil }

        let scaledWidth = targetSize.width * scale
        let scaledHeight = targetSize.height * scale
        guard scaledWidth.isFinite, scaledHeight.isFinite,
            scaledWidth <= 8192, scaledHeight <= 8192
        else { return nil }
        let width = max(1, Int(scaledWidth.rounded(.up)))
        let height = max(1, Int(scaledHeight.rounded(.up)))
        guard width * height <= 16_000_000 else { return nil }

        let key = ImageKey(
            revision: revision, asset: assetID, scale: scale, width: width, height: height)
        if let cached = imageCache[key] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let type = CGImageSourceGetType(source) as String?,
            ["public.png", "public.jpeg"].contains(type),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
            sourceWidth > 0, sourceHeight > 0,
            sourceWidth <= 8192, sourceHeight <= 8192,
            sourceWidth * sourceHeight <= 64_000_000
        else {
            reportAssetError(.invalidAsset(path))
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            reportAssetError(.invalidAsset(path))
            return nil
        }
        let result = NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        )
        let cost = image.bytesPerRow * image.height
        while cacheCost + cost > maximumCacheCost || cacheOrder.count >= maximumCacheEntries,
            !cacheOrder.isEmpty
        {
            let oldest = cacheOrder.removeFirst()
            cacheCost -= cacheCosts.removeValue(forKey: oldest) ?? 0
            imageCache.removeValue(forKey: oldest)
        }
        guard cost <= maximumCacheCost else { return result }
        imageCache[key] = result
        cacheCosts[key] = cost
        cacheOrder.append(key)
        cacheCost += cost
        return result
    }
    private static func validate(
        _ package: SkinPackage, overrides: SkinPersonalOverrides?, scheme: SkinColorScheme
    ) throws {
        do { try SkinPackageValidator.validate(package) } catch {
            throw SkinAppearanceError.packageRejected(error.localizedDescription)
        }

        let current = scheme == .system ? systemScheme() : scheme
        guard current != .system, package.manifest.supportedVariants.contains(current) else {
            throw SkinAppearanceError.missingVariant(current)
        }
        for variant in package.manifest.supportedVariants
        where Self.variant(package, variant) == nil {
            throw SkinAppearanceError.missingVariant(variant)
        }
        if let overrides { try validate(overrides, assets: package.manifest.assets) }
    }
    private static func validate(_ overrides: SkinPersonalOverrides, assets: [String: String])
        throws
    {
        try validateValues(overrides.theme)
        try validateAssetReferences(overrides.theme, assets: assets)
        let availableSlots = Set(SkinSlot.allCases.map(\.rawValue)).union(
            WorkspaceRegistry.builtins.descriptors.reduce(into: Set<String>()) {
                $0.formUnion($1.styleSlots)
            })
        guard overrides.slots.keys.allSatisfy({ availableSlots.contains($0) }) else {
            throw SkinAppearanceError.invalidValue("personal override slot")
        }
        for style in overrides.slots.values { try validate(style, assets: assets) }
    }

    private static func validateAssetReferences(
        _ values: [String: SkinJSONValue], assets: [String: String]
    ) throws {
        for (key, value) in values where key.hasSuffix("Asset") {
            guard case .string(let assetID) = value, assets[assetID] != nil else {
                throw SkinAppearanceError.invalidAsset(key)
            }
        }
    }
    private static func validate(_ style: SkinSlotStyle, assets: [String: String]) throws {
        try validateValues(style.values)
        for (key, value) in style.values where key.hasSuffix("Asset") {
            guard let assetID = Self.string(value), assets[assetID] != nil else {
                throw SkinAppearanceError.invalidAsset(key)
            }
        }
        for (state, values) in style.states {
            guard SkinControlState(rawValue: state) != nil else {
                throw SkinAppearanceError.invalidValue("state:" + state)
            }
            try validateValues(values)
            for (key, value) in values where key.hasSuffix("Asset") {
                guard let assetID = Self.string(value), assets[assetID] != nil else {
                    throw SkinAppearanceError.invalidAsset(key)
                }
            }
        }
    }
    private static func validateValues(_ values: [String: SkinJSONValue]) throws {
        let allowed: Set<String> = [
            "foreground", "background", "borderColor", "fontFamily", "fontSize",
            "spacing", "radius", "borderWidth", "density", "opacity",
            "backgroundAsset", "iconAsset", "placeholderAsset", "decorationAsset",
        ]
        for (key, value) in values {
            guard allowed.contains(key) else { throw SkinAppearanceError.invalidValue(key) }
            if ["spacing", "radius", "borderWidth", "fontSize", "opacity"].contains(key) {
                guard case .number(let number) = value, number.isFinite, number >= 0,
                    number <= 2048,
                    key != "opacity" || number <= 1
                else { throw SkinAppearanceError.invalidValue(key) }
            } else if ["foreground", "background", "borderColor"].contains(key) {
                guard case .string = value, color(value) != nil else {
                    throw SkinAppearanceError.invalidValue(key)
                }
            } else if key.hasSuffix("Asset") || key == "fontFamily" || key == "density" {
                guard let text = string(value), !text.isEmpty else {
                    throw SkinAppearanceError.invalidValue(key)
                }
                if key == "density", SkinDensity(rawValue: text) == nil {
                    throw SkinAppearanceError.invalidValue(key)
                }
            }
        }
    }
    private static func registerFonts(in package: SkinPackage) throws -> Set<URL> {
        var registered = Set<URL>()
        do {
            for (role, path) in package.manifest.assets where role.hasPrefix("font") {
                let url = package.directoryURL.appendingPathComponent(path).standardizedFileURL
                guard !registered.contains(url) else { continue }
                if let count = fontReferenceCounts[url] {
                    fontReferenceCounts[url] = count + 1
                    registered.insert(url)
                    continue
                }
                var error: Unmanaged<CFError>?
                guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
                    throw SkinAppearanceError.fontRegistration(path)
                }
                fontReferenceCounts[url] = 1
                registered.insert(url)
            }
            return registered
        } catch {
            unregister(registered)
            throw error
        }
    }
    isolated deinit {
        if !registeredFonts.isEmpty { Self.unregister(registeredFonts) }
    }
    private static func unregister(_ urls: Set<URL>) {
        for url in urls {
            guard let count = fontReferenceCounts[url] else { continue }
            if count <= 1 {
                fontReferenceCounts.removeValue(forKey: url)
                CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            } else {
                fontReferenceCounts[url] = count - 1
            }
        }
    }
}
