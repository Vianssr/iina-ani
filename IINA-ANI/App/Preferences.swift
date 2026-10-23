//
//  Preferences.swift
//  iina+
//
//  Created by xjbeta on 2018/7/17.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa

enum LivePlayer: String, CaseIterable, Identifiable {
    var id: Self { self }
    
    case iina = "/Applications/IINA.app/Contents/MacOS/iina-cli"
    case mpv = "mpv"
    
    var name: String {
        switch self {
        case .iina:
            return "IINA"
        case .mpv:
            return "mpv"
        }
    }
    
    init(raw: String) {
        if let player = LivePlayer.init(rawValue: raw) {
            self = player
        } else {
            self = .iina
        }
    }
    
    init(index: Int) {
        switch index {
        case 1:
            self = .mpv
        default:
            self = .iina
        }
    }
    
    func index() -> Int {
        switch self {
        case .iina:
            return 0
        case .mpv:
            return 1
        }
    }
}

enum AppLanguage: String, CaseIterable {
    case system
    case en
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    var displayTitle: String {
        switch self {
        case .system: return String(localized: "System Default")
        case .en: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }
}

enum WorkspaceDetailTransitionStyle: String, CaseIterable, Sendable {
    case none
    case cover
    case cinema
    case iris

    var displayTitle: String {
        switch self {
        case .none: return String(localized: "關閉動畫")
        case .cover: return String(localized: "封面滑動放大")
        case .cinema: return String(localized: "影院推近")
        case .iris: return String(localized: "光圈揭幕")
        }
    }
}

enum WorkspaceDetailTransitionCurve: String, CaseIterable, Sendable {
    case smooth
    case easeOut
    case dramatic

    var displayTitle: String {
        switch self {
        case .smooth: return String(localized: "柔和加速與減速")
        case .easeOut: return String(localized: "快速起步、緩慢停靠")
        case .dramatic: return String(localized: "蓄勢後推進")
        }
    }
}

struct WorkspaceDetailTransitionSettings: Equatable, Sendable {
    var style: WorkspaceDetailTransitionStyle = .cover
    var curve: WorkspaceDetailTransitionCurve = .smooth
    var duration: Double = 0.65
    var gamma: Double = 0.65
    var zoom: Double = 1.18

    static let defaults = Self()

    fileprivate var clamped: Self {
        func bounded(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        return Self(style: style, curve: curve,
                    duration: bounded(duration, to: 0.2...1.8, fallback: Self.defaults.duration),
                    gamma: bounded(gamma, to: 0.35...1, fallback: Self.defaults.gamma),
                    zoom: bounded(zoom, to: 1.05...1.5, fallback: Self.defaults.zoom))
    }
}

final class Preferences: NSObject, Sendable {
    static let shared = Preferences(defaults: .standard)

    nonisolated(unsafe) let prefs: UserDefaults

    init(defaults: UserDefaults) {
        prefs = defaults
        super.init()
    }

    var appLanguage: AppLanguage {
        get { AppLanguage(rawValue: prefs.string(forKey: "appLanguage") ?? "") ?? .system }
        set {
            prefs.set(newValue.rawValue, forKey: "appLanguage")
            if newValue == .system {
                prefs.removeObject(forKey: "AppleLanguages")
            } else {
                prefs.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    var detailTransition: WorkspaceDetailTransitionSettings {
        get {
            let fallback = WorkspaceDetailTransitionSettings.defaults
            func number(_ key: String, fallback: Double) -> Double {
                guard let stored = prefs.object(forKey: key) as? NSNumber,
                      CFGetTypeID(stored) != CFBooleanGetTypeID() else { return fallback }
                return stored.doubleValue
            }
            return WorkspaceDetailTransitionSettings(
                style: WorkspaceDetailTransitionStyle(rawValue: prefs.string(forKey: "workspace.detailTransition.style") ?? "") ?? fallback.style,
                curve: WorkspaceDetailTransitionCurve(rawValue: prefs.string(forKey: "workspace.detailTransition.curve") ?? "") ?? fallback.curve,
                duration: number("workspace.detailTransition.duration", fallback: fallback.duration),
                gamma: number("workspace.detailTransition.gamma", fallback: fallback.gamma),
                zoom: number("workspace.detailTransition.zoom", fallback: fallback.zoom)
            ).clamped
        }
        set {
            let value = newValue.clamped
            prefs.set(value.style.rawValue, forKey: "workspace.detailTransition.style")
            prefs.set(value.curve.rawValue, forKey: "workspace.detailTransition.curve")
            prefs.set(value.duration, forKey: "workspace.detailTransition.duration")
            prefs.set(value.gamma, forKey: "workspace.detailTransition.gamma")
            prefs.set(value.zoom, forKey: "workspace.detailTransition.zoom")
        }
    }
	
    let keys = PreferenceKeys.self
    func capabilityEnabled(_ capability: WorkspaceCapability) -> Bool {
        if capability == .danmaku { return enableDanmaku }
        guard capability.canDisable else { return true }
        return prefs.object(forKey: "workspace.capability.\(capability.rawValue)") as? Bool ?? true
    }

    func saveCapability(_ capability: WorkspaceCapability, enabled: Bool) {
        prefs.set(enabled, forKey: "workspace.capability.\(capability.rawValue)")
    }

    var discoveryRefreshPolicy: DiscoveryRefreshPolicy {
        DiscoveryRefreshPolicy(schedule: capabilityEnabled(.schedule),
            favoriteUpdates: capabilityEnabled(.favoriteUpdates),
            recommendations: capabilityEnabled(.recommendations))
    }
    private enum PolicyKey {
        static let enabledSources = "sourceEnabledByID"
        static let defaultAccounts = "sourceDefaultAccountIDByID"
        static let downloadDirectoryBookmark = "downloadDirectoryBookmark"
        static let downloadDirectoryPath = "downloadDirectoryPath"
        static let downloadConcurrency = "downloadConcurrencyLimit"
    }

    func isSourceEnabled(_ sourceID: String) -> Bool {
        (prefs.dictionary(forKey: PolicyKey.enabledSources) as? [String: Bool])?[sourceID] ?? true
    }

    func setSourceEnabled(_ enabled: Bool, sourceID: String) {
        var values = prefs.dictionary(forKey: PolicyKey.enabledSources) as? [String: Bool] ?? [:]
        values[sourceID] = enabled
        prefs.set(values, forKey: PolicyKey.enabledSources)
    }

    func defaultAccountID(for sourceID: String) -> UUID? {
        guard let value = (prefs.dictionary(forKey: PolicyKey.defaultAccounts) as? [String: String])?[sourceID] else { return nil }
        return UUID(uuidString: value)
    }

    func setDefaultAccountID(_ accountID: UUID?, for sourceID: String) {
        var values = prefs.dictionary(forKey: PolicyKey.defaultAccounts) as? [String: String] ?? [:]
        values[sourceID] = accountID?.uuidString
        if accountID == nil { values.removeValue(forKey: sourceID) }
        prefs.set(values, forKey: PolicyKey.defaultAccounts)
    }

    var downloadDirectory: URL {
        get {
            var stale = false
            if let bookmark = prefs.data(forKey: PolicyKey.downloadDirectoryBookmark),
               let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
            if let path = prefs.string(forKey: PolicyKey.downloadDirectoryPath) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        }
        set {
            prefs.set(newValue.path, forKey: PolicyKey.downloadDirectoryPath)
            let bookmark = try? newValue.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            prefs.set(bookmark, forKey: PolicyKey.downloadDirectoryBookmark)
        }
    }

    var downloadConcurrencyLimit: Int {
        get {
            let stored = prefs.object(forKey: PolicyKey.downloadConcurrency) as? Int ?? 2
            return min(max(stored, 1), 8)
        }
        set { prefs.set(min(max(newValue, 1), 8), forKey: PolicyKey.downloadConcurrency) }
    }

    func downloadPolicySnapshot(temporaryDirectory: URL) -> DownloadPolicySnapshot {
        DownloadPolicySnapshot(
            outputDirectory: downloadDirectory,
            concurrencyLimit: downloadConcurrencyLimit,
            temporaryDirectory: temporaryDirectory
        )
    }
    
    var livePlayer: LivePlayer {
        get {
            return LivePlayer(raw: defaults(.livePlayer) as? String ?? "")
        }
        set {
            defaultsSet(newValue.rawValue, forKey: .livePlayer)
        }
    }
    
    @objc var enableFlvjs: Bool {
        get {
            return defaults(.enableFlvjs) as? Bool ?? false
        }
        set {
            defaultsSet(newValue, forKey: .enableFlvjs)
        }
    }
    
    @objc var autoOpenResult: Bool {
        get {
            return defaults(.autoOpenResult) as? Bool ?? false
        }
        set {
            defaultsSet(newValue, forKey: .autoOpenResult)
        }
    }

    @objc var autoPlayNext: Bool {
        get { defaults(.autoPlayNext) as? Bool ?? true }
        set { defaultsSet(newValue, forKey: .autoPlayNext) }
    }
    
    @objc var enableDanmaku: Bool {
        get {
            return defaults(.enableDanmaku) as? Bool ?? false
        }
        set {
            defaultsSet(newValue, forKey: .enableDanmaku)
        }
    }
    
    var dmBlockType: [String] {
        get {
            return defaults(.dmBlockType) as? [String] ?? []
        }
        set {
            defaultsSet(newValue, forKey: .dmBlockType)
        }
    }
    
    @objc var danmukuFontFamilyName: String {
        get {
            return defaults(.danmukuFontFamilyName) as? String ?? "SimHei"
        }
        set {
            defaultsSet(newValue, forKey: .danmukuFontFamilyName)
            didChangeValue(for: \.danmukuFontFamilyName)
        }
    }
    
    @objc var danmukuFontWeight: String {
        get {
            return defaults(.danmukuFontWeight) as? String ?? "Regular"
        }
        set {
            defaultsSet(newValue, forKey: .danmukuFontWeight)
            didChangeValue(for: \.danmukuFontWeight)
        }
    }
    
    @objc var danmukuFontSize: Int {
        get {
//            return defaults(.danmukuFontSize) as? Int ?? 24
            return 24
        }
        set {
            defaultsSet(newValue, forKey: .danmukuFontSize)
            didChangeValue(for: \.danmukuFontSize)
        }
    }
    
    @objc dynamic var dmSpeed: Double {
        get {
            return defaults(.dmSpeed) as? Double ?? 680
        }
        set {
            defaultsSet(newValue, forKey: .dmSpeed)
            didChangeValue(for: \.dmSpeed)
        }
    }
    
    @objc dynamic var dmOpacity: Double {
        get {
            return defaults(.dmOpacity) as? Double ?? 1
        }
        set {
            defaultsSet(newValue, forKey: .dmOpacity)
            didChangeValue(for: \.dmOpacity)
        }
    }
    
    @objc dynamic var dmPort: Int {
        get {
			if IINAApp.getBuildVersion() > 16 {
                return defaults(.dmPort) as? Int ?? 19080
            } else {
                return 19080
            }
        }
        set {
            defaultsSet(newValue, forKey: .dmPort)
            didChangeValue(for: \.dmPort)
        }
    }

    @objc dynamic var stateLiving: NSColor {
        get {
            return colorDecode(defaults(.stateLiving)) ?? .systemGreen
        }
        set {
            defaultsSet(colorEncode(newValue), forKey: .stateLiving)
        }
    }
    
    @objc dynamic var stateOffline: NSColor {
        get {
            
            return colorDecode(defaults(.stateOffline)) ?? .systemRed
        }
        set {
            defaultsSet(colorEncode(newValue), forKey: .stateOffline)
        }
    }
    
    @objc dynamic var stateReplay: NSColor {
        get {
            return colorDecode(defaults(.stateReplay)) ?? .controlAccentColor
        }
        set {
            defaultsSet(colorEncode(newValue), forKey: .stateReplay)
        }
    }
    
    @objc dynamic var stateUnknown: NSColor {
        get {
            return colorDecode(defaults(.stateUnknown)) ?? .systemGray
        }
        set {
            defaultsSet(colorEncode(newValue), forKey: .stateUnknown)
        }
    }
	
	@objc dynamic var bilibiliHTMLDecoder: Bool {
		get {
			return defaults(.bilibiliHTMLDecoder) as? Bool ?? false
		}
		set {
			defaultsSet(newValue, forKey: .bilibiliHTMLDecoder)
		}
	}
    
    @objc dynamic var bilibiliCodec: Int {
        get {
            return defaults(.bilibiliCodec) as? Int ?? 1
        }
        set {
            defaultsSet(newValue, forKey: .bilibiliCodec)
        }
    }
    
    @objc dynamic var bililiveHevc: Bool {
        get {
            return defaults(.bililiveHevc) as? Bool ?? false
        }
        set {
            defaultsSet(newValue, forKey: .bililiveHevc)
        }
    }
	
	var customMpvPath: String {
		get {
			return defaults(.customMpvPath) as? String ?? ""
		}
		set {
			defaultsSet(newValue, forKey: .customMpvPath)
		}
	}
    
    private func colorEncode(_ color: NSColor) -> Data {
        (try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false)) ?? Data()
    }
    
    private func colorDecode(_ value: Any?) -> NSColor? {
        guard let data = value as? Data,
              let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) else { return nil }
        return color
    }
}

private extension Preferences {
    
    func defaults(_ key: PreferenceKeys) -> Any? {
		prefs.value(forKey: key.rawValue) as Any?
    }
    
    func defaultsSet(_ value: Any, forKey key: PreferenceKeys) {
        prefs.setValue(value, forKey: key.rawValue)
    }
}

enum PreferenceKeys: String {
    case livePlayer
    case enableFlvjs
    case autoOpenResult
    case autoPlayNext
    
    case enableDanmaku
    case danmukuFontFamilyName
    case danmukuFontWeight
    case danmukuFontSize
    case dmSpeed
    case dmOpacity
    case dmBlockType
    case dmBlockList
    case dmPort
    
    case stateLiving
    case stateOffline
    case stateReplay
    case stateUnknown
    
	case bilibiliHTMLDecoder
    case bilibiliCodec
    case bililiveHevc
	
	case customMpvPath
}

struct DownloadPolicySnapshot: Sendable {
    let outputDirectory: URL
    let concurrencyLimit: Int
    let temporaryDirectory: URL
}
