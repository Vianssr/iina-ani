import Foundation
@testable import IINA_ANI

@main
struct WorkspaceDetailTransitionPreferencesRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    @MainActor static func main() {
        let suite = "iina-detail-transition-preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let prefix = "workspace.detailTransition."
        let numericKeys = ["duration", "gamma", "zoom"].map { prefix + $0 }

        preferences.appLanguage = .simplifiedChinese
        preferences.enableDanmaku = true
        preferences.downloadConcurrencyLimit = 5
        preferences.saveCapability(.recommendations, enabled: false)
        defaults.set(["sentinel": "keep"], forKey: "unrelated.fixture")
        let originalDomain = defaults.persistentDomain(forName: suite) ?? [:]

        check(preferences.detailTransition == .init(style: .cover, curve: .smooth,
              duration: 0.65, gamma: 0.65, zoom: 1.18), "new users receive explicit safe animation defaults")
        check(NSDictionary(dictionary: originalDomain).isEqual(to: defaults.persistentDomain(forName: suite) ?? [:]),
              "reading defaults must not rewrite the preferences domain")

        for style in WorkspaceDetailTransitionStyle.allCases {
            for curve in WorkspaceDetailTransitionCurve.allCases {
                let chosen = WorkspaceDetailTransitionSettings(style: style, curve: curve,
                    duration: 1.25, gamma: 0.45, zoom: 1.35)
                preferences.detailTransition = chosen
                let reopened = Preferences(defaults: UserDefaults(suiteName: suite)!)
                check(reopened.detailTransition == chosen, "every style and curve persists across preference instances")
            }
        }

        preferences.detailTransition = .defaults
        defaults.set("future-style", forKey: prefix + "style")
        defaults.set("future-curve", forKey: prefix + "curve")
        check(preferences.detailTransition == .defaults, "unknown enum raw values fall back without disabling the feature")
        defaults.set(42, forKey: prefix + "style")
        defaults.set(["invalid"], forKey: prefix + "curve")
        check(preferences.detailTransition == .defaults, "malformed enum storage is handled safely")

        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            preferences.detailTransition = .init(duration: invalid, gamma: invalid, zoom: invalid)
            check(preferences.detailTransition == .defaults, "nonfinite values are replaced before saving")
            for key in numericKeys {
                check((defaults.object(forKey: key) as? Double)?.isFinite == true,
                      "nonfinite edits cannot be persisted as animation parameters")
                defaults.set(invalid, forKey: key)
            }
            check(preferences.detailTransition == .defaults, "nonfinite stored values use safe defaults when read")
        }

        let malformedValues: [Any] = ["invalid-number", true, [1, 2], ["value": 1]]
        for malformed in malformedValues {
            for key in numericKeys { defaults.set(malformed, forKey: key) }
            check(preferences.detailTransition == .defaults, "strings, booleans and containers are not animation numbers")
        }

        preferences.detailTransition = .init(duration: -10, gamma: -10, zoom: -10)
        check(preferences.detailTransition == .init(duration: 0.2, gamma: 0.35, zoom: 1.05),
              "edits below the supported range clamp to the lower bounds")
        preferences.detailTransition = .init(duration: 100, gamma: 100, zoom: 100)
        check(preferences.detailTransition == .init(duration: 1.8, gamma: 1, zoom: 1.5),
              "edits above the supported range clamp to the upper bounds")
        for key in numericKeys { defaults.set(-10, forKey: key) }
        check(preferences.detailTransition == .init(duration: 0.2, gamma: 0.35, zoom: 1.05),
              "out-of-range stored values clamp on read")
        for key in numericKeys { defaults.set(100, forKey: key) }
        check(preferences.detailTransition == .init(duration: 1.8, gamma: 1, zoom: 1.5),
              "oversized stored values clamp on read")

        let finalUnrelated = (defaults.persistentDomain(forName: suite) ?? [:]).filter { !$0.key.hasPrefix(prefix) }
        check(NSDictionary(dictionary: originalDomain).isEqual(to: finalUnrelated),
              "animation edits and sanitization must preserve every unrelated preference")
        check(preferences.appLanguage == .simplifiedChinese && preferences.enableDanmaku &&
              preferences.downloadConcurrencyLimit == 5 && !preferences.capabilityEnabled(.recommendations),
              "existing language, playback, download and capability choices retain their behavior")
        print("PASS: detail transition defaults, persistence, invalid storage, finite bounds and unrelated preferences")
    }
}
