import Foundation
@testable import IINA_ANI

@main
enum PreferencesRegression {
    static func main() throws {
        let suite = "iina-preferences-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let independentSuite = "iina-language-regression.\(UUID().uuidString)"
        let independentDefaults = UserDefaults(suiteName: independentSuite)!
        defer { independentDefaults.removePersistentDomain(forName: independentSuite) }
        let independentPreferences = Preferences(defaults: independentDefaults)
        let globalLanguages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        try require(preferences.appLanguage == .system, "language defaults to the system")
        for language in AppLanguage.allCases where language != .system {
            preferences.appLanguage = language
            let reopenedLanguage = Preferences(defaults: UserDefaults(suiteName: suite)!)
            try require(reopenedLanguage.appLanguage == language, "language choice survives reopening")
            try require(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == [language.rawValue],
                        "explicit language overrides are stored only in the selected defaults domain")
            try require(independentPreferences.appLanguage == .system &&
                        independentDefaults.persistentDomain(forName: independentSuite)?["AppleLanguages"] == nil,
                        "independent defaults domains do not share language settings")
        }
        preferences.appLanguage = .system
        try require(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil,
                    "system language removes the application override")
        try require(Preferences(defaults: UserDefaults(suiteName: suite)!).appLanguage == .system,
                    "system language choice survives reopening")
        defaults.set("invalid-language", forKey: "appLanguage")
        try require(Preferences(defaults: UserDefaults(suiteName: suite)!).appLanguage == .system,
                    "unknown stored language falls back to the system")
        try require(UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] == globalLanguages,
                    "language choices never alter global defaults")
        try require(!preferences.torrentUploadConsentAcknowledged, "P2P upload consent must never be implicit")
        try require(preferences.torrentUploadLimitBytesPerSecond == 65_536, "new P2P policy has an explicit bounded default")
        preferences.torrentUploadLimitBytesPerSecond = 0
        try require(preferences.torrentUploadLimitBytesPerSecond == 1 && !preferences.torrentUploadConsentAcknowledged,
                    "bandwidth edits must not grant upload consent or produce unlimited native uploads")
        preferences.saveTorrentUploadPolicy(try TorrentUploadPolicy(bytesPerSecond: 12_345, acknowledged: true))
        let accountID = UUID()
        preferences.setSourceEnabled(false, sourceID: "bilibili")
        preferences.setSourceEnabled(true, sourceID: "douyu")
        preferences.setDefaultAccountID(accountID, for: "bilibili")
        preferences.enableDanmaku = true
        preferences.bilibiliCodec = 2
        preferences.bililiveHevc = true
        preferences.saveCapability(.recommendations, enabled: false)
        preferences.saveCapability(.downloads, enabled: false)

        let firstDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("first-\(UUID().uuidString)")
        let nextDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("next-\(UUID().uuidString)")
        preferences.downloadDirectory = firstDirectory
        preferences.downloadConcurrencyLimit = 2
        let first = preferences.downloadPolicySnapshot(temporaryDirectory: FileManager.default.temporaryDirectory)
        preferences.downloadDirectory = nextDirectory
        preferences.downloadConcurrencyLimit = 6
        let reopened = Preferences(defaults: UserDefaults(suiteName: suite)!)
        let next = reopened.downloadPolicySnapshot(temporaryDirectory: FileManager.default.temporaryDirectory)

        try require(reopened.torrentUploadConsentAcknowledged && reopened.torrentUploadLimitBytesPerSecond == 12_345,
                    "explicit P2P consent and actual bandwidth policy survive reopening")
        try require(!reopened.isSourceEnabled("bilibili") && reopened.isSourceEnabled("douyu"), "source policies must persist independently")
        try require(reopened.defaultAccountID(for: "bilibili") == accountID, "account selection must survive reopening")
        try require(reopened.enableDanmaku && reopened.bilibiliCodec == 2 && reopened.bililiveHevc, "existing playback preferences must remain readable")
        try require(!reopened.capabilityEnabled(.recommendations) && !reopened.capabilityEnabled(.downloads), "optional capability choices survive reopening")
        try require(reopened.capabilityEnabled(.favorites) && reopened.isSourceEnabled("douyu"), "disabling optional capabilities must not disable shared data or sources")
        try require(first.outputDirectory.path == firstDirectory.path && first.concurrencyLimit == 2, "changing settings must not mutate a captured task policy")
        try require(next.outputDirectory.path == nextDirectory.path && next.concurrencyLimit == 6, "new policies must use persisted settings")
        try require(first.temporaryDirectory == next.temporaryDirectory, "changing destination must not relocate task temporary storage")
        reopened.setDefaultAccountID(nil, for: "bilibili")
        try require(Preferences(defaults: UserDefaults(suiteName: suite)!).defaultAccountID(for: "bilibili") == nil, "clearing the default must persist")
        print("PASS: persisted source/account/playback settings and immutable download policies")
    }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }
    private enum Failure: Error { case assertion(String) }
}
