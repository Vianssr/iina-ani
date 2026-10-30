import XCTest
import UIKit

final class ANIUITests: XCTestCase {
    @MainActor func testConfigurationOnlyURLImport() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-catalog-ui-fixture", "-empty-sources-ui-fixture", "-source-import-ui-fixture"]
        app.launch()
        app.buttons["source-settings"].tap()
        XCTAssertTrue(app.staticTexts["source-settings-empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["source-default-status"].exists)
        app.buttons["source-settings-import"].tap()
        let field = app.descendants(matching: .any)["source-import-url"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse((field.value as? String ?? "").contains("creamycake"))
        XCTAssertFalse(app.buttons["source-import-download"].isEnabled)
        field.tap(); field.typeText("https://mirror.example/rules.json?version=2")
        app.buttons["source-import-download"].tap()
        XCTAssertTrue(app.navigationBars["Review sources"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Mirrored CSS1 fixture"].exists)
        let apply = app.buttons["source-import-batch-apply"]
        for _ in 0..<6 where !apply.isHittable { app.swipeUp() }
        XCTAssertTrue(apply.isHittable); apply.tap()
        XCTAssertTrue(app.navigationBars["Source configuration"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["source-settings-enabled-fixture-css1"].exists)
        XCTAssertFalse(app.staticTexts["source-settings-empty"].exists)
        attachPlayerScreenshot("configuration-only-css1-import")
        app.buttons["source-settings-import"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("https://configuration.example/list.json")
        app.buttons["source-import-download"].tap()
        XCTAssertTrue(app.navigationBars["Review sources"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["URL configuration fixture"].exists)
        XCTAssertTrue(app.staticTexts["List configuration fixture"].exists)
        for _ in 0..<6 where !apply.isHittable { app.swipeUp() }
        XCTAssertTrue(apply.isHittable); apply.tap()
        XCTAssertTrue(app.navigationBars["Source configuration"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["source-settings-enabled-fixture-url-source"].exists)
        XCTAssertTrue(app.switches["source-settings-enabled-fixture-list-source"].exists)
        setSwitch(app.switches["source-settings-enabled-fixture-css1"], on: true)
        app.navigationBars.buttons["BackButton"].tap()
        reopenFixtureEpisode(app)
        if app.buttons["source-reconfirm"].exists { app.buttons["source-reconfirm"].tap() }
        app.buttons["source-picker"].tap()
        app.buttons["Mirrored CSS1 fixture"].tap()
        app.buttons["Find sources"].tap()
        let candidate = app.buttons["source-work"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5)); candidate.tap()
        let episode = app.buttons["source-episode-1-2"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5)); episode.tap()
        XCTAssertTrue(app.buttons["playerTogglePause"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 1 })
        attachPlayerScreenshot("css1-import-source-mpv-playback")
        app.buttons["playerClose"].tap()
    }

    @MainActor func testMobileBrowseAndURLConfiguration() throws {
        let app = XCUIApplication()
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-catalog-ui-fixture", "-source-list-ui-fixture", "-source-import-ui-fixture"]
        app.launch()
        openWorkspace(app, section: "trending", title: "Trending")
        let featured = app.buttons["trending-featured"]
        XCTAssertTrue(featured.waitForExistence(timeout: 10))
        XCTAssertTrue(featured.label.contains("Source Flow Fixture"))
        attachPlayerScreenshot("mobile-trending")
        featured.tap()
        XCTAssertTrue(app.navigationBars["About this anime"].waitForExistence(timeout: 5))

        openWorkspace(app, section: "calendar", title: "Calendar")
        let weekdays = app.scrollViews["calendar-weekdays"]
        let tuesday = app.buttons["calendar-day-2"]
        XCTAssertTrue(tuesday.waitForExistence(timeout: 5))
        for _ in 0..<3 where !tuesday.isHittable { weekdays.swipeRight() }
        tuesday.tap()
        XCTAssertTrue(app.buttons["Tuesday Calendar Fixture"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["calendar-day-3"].tap()
        XCTAssertTrue(app.staticTexts["Nothing scheduled"].waitForExistence(timeout: 5))
        tuesday.tap()
        attachPlayerScreenshot("mobile-calendar")

        openWorkspace(app, section: "discover", title: "Discover")
        app.buttons["source-settings"].tap()
        app.buttons["source-settings-import"].tap()
        let field = app.descendants(matching: .any)["source-import-url"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("http://configuration.example/source.json")
        XCTAssertEqual(field.value as? String, "http://configuration.example/source.json")
        app.buttons["source-import-download"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["source-import-error"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["source-import-cancel"].tap()
        app.buttons["source-settings-import"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("https://configuration.example/source.json")
        XCTAssertEqual(field.value as? String, "https://configuration.example/source.json")
        app.buttons["source-import-download"].tap()
        XCTAssertTrue(app.staticTexts["URL configuration fixture"].firstMatch.waitForExistence(timeout: 5))
        attachPlayerScreenshot("mobile-url-import-preview")
        let apply = app.buttons["source-import-apply"]
        for _ in 0..<5 where !apply.isHittable { app.swipeUp() }
        XCTAssertTrue(apply.isHittable)
        app.buttons["source-import-preview-cancel"].tap()
        XCTAssertTrue(app.buttons["source-import-cancel"].waitForExistence(timeout: 5))
        app.buttons["source-import-cancel"].tap()
        XCTAssertFalse(app.switches["source-settings-enabled-fixture-url-source"].exists)
    }

    @MainActor func testBTEntryPlayback() throws {
        let app = XCUIApplication()
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-catalog-ui-fixture", "-bt-ui-fixture"]
        app.launch()
        openPlayerWorkspace(app)
        let entry = app.buttons["bt-playback-entry"]
        for _ in 0..<5 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.exists); entry.tap()
        let server = app.textFields["bt-server-url"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.tap(); server.typeText("https://torrent.example")
        let torrent = app.descendants(matching: .any)["bt-torrent-url"].firstMatch
        torrent.tap(); torrent.typeText("magnet:?xt=urn:btih:1111111111111111111111111111111111111111")
        let load = app.buttons["bt-load"]
        for _ in 0..<4 where !load.isHittable { app.swipeUp() }
        load.tap()
        let video = app.buttons["bt-file-2"]
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        for _ in 0..<4 where !video.isHittable { app.swipeUp() }
        attachPlayerScreenshot("mobile-bt-files")
        video.tap()
        XCTAssertTrue(app.buttons["playerTogglePause"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 1 })
        attachPlayerScreenshot("mobile-bt-player")
        app.buttons["playerClose"].tap()
        XCTAssertTrue(app.navigationBars["BT playback"].waitForExistence(timeout: 5))
    }

    @MainActor private func openWorkspace(_ app: XCUIApplication, section: String, title: String) {
        let item = UIDevice.current.userInterfaceIdiom == .pad
            ? app.descendants(matching: .any)["workspace-" + section].firstMatch
            : app.tabBars.buttons[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10)); item.tap()
    }

    @MainActor func testSourceNextEpisode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-source-ui-fixture",
                               "-mobile.sources.fqdm.enabled", "YES", "-mobile.player.autoPlayNext", "NO"]
        app.launch()
        reopenFixtureEpisode(app)
        if app.buttons["source-play-saved"].exists {
            app.buttons["source-play-saved"].tap()
        } else {
            app.buttons["Find sources"].tap()
            let work = app.buttons["source-work"].firstMatch
            XCTAssertTrue(work.waitForExistence(timeout: 5)); work.tap()
            let episode = app.buttons["source-episode-1-2"]
            XCTAssertTrue(episode.waitForExistence(timeout: 5)); episode.tap()
        }
        XCTAssertTrue(app.buttons["playerTogglePause"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 1 })
        app.buttons["playerNextEpisode"].tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerEpisodes") == "1" })
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 0 && self.numericValue(app, "playerElapsedSeconds") < 12 })
        XCTAssertTrue(app.staticTexts["Source Flow Fixture · Episode 3"].firstMatch.exists)
        app.buttons["playerEpisodes"].tap()
        setSwitch(app.switches["playerAutoPlayNext"], on: true)
        closePlayerSheet(app)
        app.sliders["playerTimeline"].adjust(toNormalizedSliderPosition: 0.97)
        XCTAssertTrue(waitUntil(timeout: 20) { self.accessibilityValue(app, "playerEpisodes") == "2" })
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 0 && self.numericValue(app, "playerElapsedSeconds") < 12 })
        XCTAssertTrue(app.staticTexts["Source Flow Fixture · Episode 4"].firstMatch.exists)
        attachPlayerScreenshot("same-source-natural-next")
        app.buttons["playerEpisodes"].tap()
        setSwitch(app.switches["playerAutoPlayNext"], on: false)
        closePlayerSheet(app)
        app.sliders["playerTimeline"].adjust(toNormalizedSliderPosition: 0.97)
        XCTAssertTrue(waitUntil(timeout: 20) {
            self.numericValue(app, "playerElapsedSeconds") >= 89 &&
                self.accessibilityValue(app, "playerPlaybackState") == "paused"
        })
        XCTAssertEqual(accessibilityValue(app, "playerEpisodes"), "2")
        XCTAssertFalse(app.staticTexts["playerNextError"].exists)
        attachPlayerScreenshot("autoplay-disabled-eof")
        app.buttons["playerTogglePause"].tap()
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 0 && self.numericValue(app, "playerElapsedSeconds") < 12 })
        XCTAssertEqual(accessibilityValue(app, "playerEpisodes"), "2")
        app.buttons["playerClose"].tap()
    }

    @MainActor func testEpisodeAttachmentIsolation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-player-ui-fixture",
                               "-mobile.player.autoPlayNext", "NO", "-mobile.danmaku.blockedWords", "",
                               "-mobile.danmaku.enabled", "YES", "-mobile.danmaku.hideScrolling", "NO",
                               "-mobile.danmaku.hideTop", "NO", "-mobile.danmaku.hideBottom", "NO"]
        app.launch()
        openPlayerWorkspace(app)
        XCTAssertTrue(app.buttons["playerTogglePause"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 1 })
        app.buttons["playerSubtitles"].tap()
        app.buttons["subtitle-off"].tap()
        closePlayerSheet(app)
        app.buttons["playerDanmaku"].tap()
        XCTAssertEqual(numericValue(app, "playerDanmakuCount"), 6)
        let filter = app.descendants(matching: .any)["danmaku-filter"].firstMatch
        filter.tap(); filter.typeText("spoiler")
        closePlayerSheet(app)
        app.buttons["playerNextEpisode"].tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerEpisodes") == "1" })
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 0 })
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerSubtitles") == "1" })
        app.buttons["playerDanmaku"].tap()
        XCTAssertEqual(numericValue(app, "playerDanmakuCount"), 0)
        XCTAssertEqual(filter.value as? String, "spoiler")
        closePlayerSheet(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertEqual(accessibilityValue(app, "playerEpisodes"), "1")
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPlaybackState") == "paused" })
        app.buttons["playerEpisodes"].tap()
        let first = app.buttons["episode-0"]
        for _ in 0..<3 where !first.isHittable { app.swipeUp() }
        first.tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerEpisodes") == "0" })
        XCTAssertTrue(waitUntil { ["off", "-1"].contains(self.accessibilityValue(app, "playerSubtitles")) })
        app.buttons["playerDanmaku"].tap()
        XCTAssertEqual(numericValue(app, "playerDanmakuCount"), 6)
        XCTAssertEqual(numericValue(app, "playerDanmakuFilteredCount"), 5)
        attachPlayerScreenshot("episode-owned-danmaku-restored")
        closePlayerSheet(app)
        app.buttons["playerClose"].tap()
    }

    @MainActor func testSourceHistoryResume() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-source-ui-fixture", "-mobile.sources.fqdm.enabled", "YES"]
        app.launch()
        reopenFixtureEpisode(app)
        if app.buttons["source-play-saved"].exists {
            app.buttons["source-play-saved"].tap()
        } else {
            app.buttons["Find sources"].tap()
            let work = app.buttons["source-work"].firstMatch
            XCTAssertTrue(work.waitForExistence(timeout: 5)); work.tap()
            let episode = app.buttons["source-episode-1-2"]
            XCTAssertTrue(episode.waitForExistence(timeout: 5)); episode.tap()
        }
        try verifyHistoryRestart(app, title: "Source Flow Fixture")
        app.terminate()
        let index = try XCTUnwrap(app.launchArguments.firstIndex(of: "-mobile.sources.fqdm.enabled"))
        app.launchArguments[index + 1] = "NO"
        app.launch()
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "history-resume-", "Source Flow Fixture")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10)); resume.tap()
        XCTAssertTrue(app.staticTexts["history-resume-error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["playerTogglePause"].exists)
        attachPlayerScreenshot("history-disabled-no-fallback")
    }

    @MainActor func testLocalHistoryResume() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-player-ui-fixture"]
        app.launch()
        openPlayerWorkspace(app)
        try verifyHistoryRestart(app, title: "player-fixture-01")
    }

    @MainActor private func verifyHistoryRestart(_ app: XCUIApplication, title: String) throws {
        let pause = app.buttons["playerTogglePause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 1 })
        pause.tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPlaybackState") == "paused" })
        app.buttons["playerSeekForward"].tap()
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 10 })
        app.buttons["playerSeekForward"].tap()
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 20 })
        let saved = numericValue(app, "playerElapsedSeconds")
        app.buttons["playerClose"].tap()
        app.terminate()
        app.launchArguments.removeAll { $0 == "-player-ui-fixture" }
        app.launch()
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "history-resume-", title)).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 15))
        attachPlayerScreenshot("history-restored")
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") >= saved - 0.5 })
        // Measure the first observed backend position, not additional playback during the pause tap.
        XCTAssertEqual(numericValue(app, "playerElapsedSeconds"), saved, accuracy: 2)
        pause.tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPlaybackState") == "paused" })
        XCTAssertFalse(app.staticTexts["history-storage-error"].exists)
        attachPlayerScreenshot("history-resumed-real-clock")
        app.buttons["playerClose"].tap()
        app.buttons["Done"].tap()
    }

    @MainActor func testDetailSourcePlayback() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-source-ui-fixture", "-source-ui-failure", "-source-list-ui-fixture", "-mobile.sources.fqdm.enabled", "YES", "-mobile.sources.fixture-second.enabled", "YES"]
        app.launch()
        let work = app.buttons["Source Flow Fixture"].firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 15))
        work.tap()
        let episode = app.buttons["catalog-episode-4202"]
        for _ in 0..<6 where !episode.isHittable { app.swipeUp() }
        XCTAssertTrue(episode.waitForExistence(timeout: 5))
        XCTAssertEqual(episode.label, "2")
        XCTAssertLessThan(episode.frame.width, app.frame.width / 2)
        let detailAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        detailAttachment.name = "detail-episode-grid"
        detailAttachment.lifetime = .keepAlways
        add(detailAttachment)
        episode.tap()
        let sourcePicker = app.buttons["source-picker"]
        XCTAssertTrue(sourcePicker.waitForExistence(timeout: 5))
        if app.buttons["source-reconfirm"].exists { app.buttons["source-reconfirm"].tap() }
        sourcePicker.tap()
        app.buttons["Tomato Anime"].tap()
        app.buttons["Find sources"].tap()
        XCTAssertTrue(app.buttons["source-work"].firstMatch.waitForExistence(timeout: 5))
        sourcePicker.tap()
        app.buttons["Second fixture source"].tap()
        XCTAssertFalse(app.buttons["source-work"].exists)
        XCTAssertTrue(app.buttons["source-import"].exists)
        XCTAssertTrue(app.buttons["Find sources"].waitForExistence(timeout: 5))
        app.buttons["Find sources"].tap()
        let candidate = app.buttons["source-work"].firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5))
        candidate.tap()
        let sourceEpisode = app.buttons["source-episode-1-2"]
        XCTAssertTrue(sourceEpisode.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["source-episode-1-1"].exists)
        XCTAssertEqual(sourceEpisode.label, "2")
        XCTAssertLessThan(sourceEpisode.frame.width, app.frame.width / 2)
        let thirdEpisode = app.buttons["source-episode-1-3"]
        XCTAssertTrue(thirdEpisode.exists)
        XCTAssertEqual(sourceEpisode.frame.minY, thirdEpisode.frame.minY, accuracy: 2)
        let sourceAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sourceAttachment.name = "detail-source-selection"
        sourceAttachment.lifetime = .keepAlways
        add(sourceAttachment)
        sourceEpisode.tap()
        let error = app.staticTexts["source-error"]
        for _ in 0..<4 where !error.isHittable { app.swipeUp() }
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["playerTogglePause"].exists)
        XCTAssertFalse(app.buttons["Retry"].exists)
        sourceEpisode.tap()
        XCTAssertTrue(app.buttons["playerTogglePause"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 1 })
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "detail-source-mpv-playback"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["playerClose"].tap()
        XCTAssertTrue(app.buttons["source-play-saved"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["About this anime"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments.removeAll { $0 == "-source-ui-failure" }
        app.launch()
        reopenFixtureEpisode(app)
        XCTAssertTrue(app.buttons["source-play-saved"].waitForExistence(timeout: 5))
        let restoredSource = app.buttons["source-picker"]
        XCTAssertTrue((restoredSource.label + String(describing: restoredSource.value)).contains("Second fixture source"))
        XCTAssertFalse(app.buttons["source-work"].exists)
        let savedAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        savedAttachment.name = "mapping-restored-after-relaunch"
        savedAttachment.lifetime = .keepAlways
        add(savedAttachment)
        app.buttons["source-play-saved"].tap()
        XCTAssertTrue(app.buttons["playerTogglePause"].waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 1 })
        let reusedAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        reusedAttachment.name = "mapping-fresh-resolve-mpv-playback"
        reusedAttachment.lifetime = .keepAlways
        add(reusedAttachment)
        app.buttons["playerClose"].tap()
        app.terminate()
        let enabledArgument = try XCTUnwrap(app.launchArguments.firstIndex(of: "-mobile.sources.fixture-second.enabled"))
        app.launchArguments[enabledArgument + 1] = "NO"
        app.launch()
        reopenFixtureEpisode(app)
        XCTAssertTrue(app.staticTexts["source-error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["playerTogglePause"].exists)
        XCTAssertFalse(app.buttons["source-play-saved"].isEnabled)
        let disabledAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        disabledAttachment.name = "mapping-disabled-source-no-fallback"
        disabledAttachment.lifetime = .keepAlways
        add(disabledAttachment)
        app.buttons["source-reconfirm"].tap()
        XCTAssertTrue(app.buttons["source-picker"].isEnabled)
        XCTAssertFalse(app.buttons["source-play-saved"].exists)
    }

    @MainActor private func reopenFixtureEpisode(_ app: XCUIApplication) {
        let work = app.buttons["Source Flow Fixture"].firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 15))
        work.tap()
        let episode = app.buttons["catalog-episode-4202"]
        for _ in 0..<6 where !episode.isHittable { app.swipeUp() }
        XCTAssertTrue(episode.waitForExistence(timeout: 5))
        episode.tap()
        XCTAssertTrue(app.buttons["source-picker"].waitForExistence(timeout: 5))
    }

    @MainActor func testLibraryPresentation() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone navigation") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Library"].tap()
        let search = app.searchFields["Search library"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("no-match-7c149")
        XCTAssertTrue(search.buttons["Clear text"].waitForExistence(timeout: 5))
        search.buttons["Clear text"].tap()
        app.terminate(); app.launch()
        app.tabBars.buttons["Library"].tap()
        app.buttons["library-sort"].tap()
        XCTAssertTrue(app.buttons["Recently saved"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Title"].exists)
        XCTAssertTrue(app.buttons["Highest rated"].exists)
        app.buttons["Highest rated"].tap()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "iOS-library-controls"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Exercises the actual libmpv clock and track state using a bundled, deterministic MP4.
    /// No network access, source parser, or simulated playback engine is involved.
    @MainActor func testMPVPlayerControls() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-player-ui-fixture"]
        app.launchArguments += ["-mobile.danmaku.blockedWords", "", "-mobile.danmaku.enabled", "YES",
                                "-mobile.danmaku.hideScrolling", "NO", "-mobile.danmaku.hideTop", "NO",
                                "-mobile.danmaku.hideBottom", "NO", "-mobile.player.autoPlayNext", "NO"]
        app.launch()
        openPlayerWorkspace(app)
        let pause = app.buttons["playerTogglePause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 1 })

        // Pause must stop libmpv's reported media clock, not merely change the icon.
        pause.tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPlaybackState") == "paused" })
        XCTAssertFalse(app.staticTexts["Playback unavailable"].exists)
        XCTAssertGreaterThanOrEqual(pause.frame.height, 48)
        let pausedAt = numericValue(app, "playerElapsedSeconds")
        let unexpectedAdvance = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(self.numericValue(app, "playerElapsedSeconds") - pausedAt) > 0.4
        }, object: nil)
        unexpectedAdvance.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedAdvance], timeout: 1.2), .completed)

        // An explicit step makes this independent of previously saved user preferences.
        app.buttons["playerSettings"].tap()
        app.buttons["seekStep-15"].tap()
        closePlayerSheet(app)
        app.buttons["playerSeekForward"].tap()
        XCTAssertTrue(waitUntil { abs(self.numericValue(app, "playerElapsedSeconds") - pausedAt - 15) < 0.8 })
        app.buttons["playerSeekBackward"].tap()
        XCTAssertTrue(waitUntil { abs(self.numericValue(app, "playerElapsedSeconds") - pausedAt) < 0.8 })

        // The dedicated double-tap regions use the same configured interval.
        app.descendants(matching: .any)["playerDoubleTapForward"].firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).doubleTap()
        XCTAssertTrue(waitUntil { abs(self.numericValue(app, "playerElapsedSeconds") - pausedAt - 15) < 0.8 })
        app.descendants(matching: .any)["playerDoubleTapBackward"].firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).doubleTap()
        XCTAssertTrue(waitUntil { abs(self.numericValue(app, "playerElapsedSeconds") - pausedAt) < 0.8 })

        app.buttons["playerSpeed"].tap()
        app.buttons["speed-2.0"].tap()
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerSpeed") == 2 })
        XCTAssertEqual(accessibilityValue(app, "playerPlaybackState"), "paused")

        // Both subtitle tracks are embedded in the MP4 and discovered by libmpv.
        app.buttons["playerSubtitles"].tap()
        XCTAssertTrue(app.buttons["subtitle-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["subtitle-2"].exists)
        app.buttons["subtitle-2"].tap()
        closePlayerSheet(app)
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerSubtitles") == "2" })
        let subtitleAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        subtitleAttachment.name = UIDevice.current.userInterfaceIdiom == .pad ? "iPad-mpv-subtitles-danmaku" : "iPhone-mpv-subtitles-danmaku"
        subtitleAttachment.lifetime = .keepAlways
        add(subtitleAttachment)
        app.buttons["playerSubtitles"].tap()
        app.buttons["subtitle-off"].tap()
        closePlayerSheet(app)
        XCTAssertTrue(waitUntil { ["off", "-1"].contains(self.accessibilityValue(app, "playerSubtitles")) })

        // The fixture enters through the real XML parser; filters apply to parsed comments.
        app.buttons["playerDanmaku"].tap()
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerDanmakuCount") == 6 })
        let danmaku = app.switches["danmaku-enabled"]
        XCTAssertTrue(danmaku.exists)
        let filter = app.descendants(matching: .any)["danmaku-filter"].firstMatch
        XCTAssertTrue(filter.exists)
        for identifier in ["danmaku-hideScrolling", "danmaku-hideTop", "danmaku-hideBottom"] {
            setSwitch(app.switches[identifier], on: false)
        }
        setSwitch(danmaku, on: false)
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerDanmakuFilteredCount") == 0 })
        setSwitch(danmaku, on: true)
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerDanmakuFilteredCount") == 6 })
        filter.tap()
        filter.typeText("spoiler")
        // Close and reopen to dismiss the keyboard before touching lower form controls.
        closePlayerSheet(app)
        app.buttons["playerDanmaku"].tap()
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerDanmakuFilteredCount") == 5 })
        let hideTop = app.switches["danmaku-hideTop"]
        setSwitch(hideTop, on: true)
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerDanmakuFilteredCount") == 4 })
        closePlayerSheet(app)
        app.buttons["playerDanmaku"].tap()
        XCTAssertEqual(app.descendants(matching: .any)["danmaku-filter"].firstMatch.value as? String, "spoiler")
        XCTAssertEqual(app.switches["danmaku-hideTop"].value as? String, "1")
        closePlayerSheet(app)

        // Replacing a queued file must reset the real playback position.
        app.buttons["playerSpeed"].tap()
        app.buttons["speed-1.0"].tap()
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerSpeed") == 1 })
        app.buttons["playerSeekForward"].tap()
        app.buttons["playerSeekForward"].tap()
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 25 })
        app.buttons["playerEpisodes"].tap()
        XCTAssertTrue(app.buttons["episode-0"].exists)
        app.buttons["episode-1"].tap()
        // This sheet dismisses on selection. Avoid a missing-element wait while playback advances.
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerEpisodes") == "1" })
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") < 12 })
        if accessibilityValue(app, "playerPlaybackState") == "paused" { pause.tap() }
        let resumedAt = numericValue(app, "playerElapsedSeconds")
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > resumedAt + 1 })
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = UIDevice.current.userInterfaceIdiom == .pad ? "iPad-mpv-player" : "iPhone-mpv-player"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Returning to the app keeps playback paused until the user resumes it.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPlaybackState") == "paused" })
        let foregroundAt = numericValue(app, "playerElapsedSeconds")
        pause.tap()
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > foregroundAt + 1 })

        // Dismiss while decoding and relaunch to catch an invalid player/surface lifecycle.
        app.buttons["playerClose"].tap()
        XCTAssertTrue(waitUntil { !pause.exists })
        app.terminate()
        app.launch()
        openPlayerWorkspace(app)
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 1 })
        XCTAssertFalse(app.staticTexts["Playback unavailable"].exists)
        app.buttons["playerClose"].tap()
    }

    @MainActor func testMPVPlayerRotation() throws {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-player-ui-fixture"]
        app.launch()
        openPlayerWorkspace(app)
        let pause = app.buttons["playerTogglePause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 0.5 })
        pause.tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPlaybackState") == "paused" })

        // Use the second file and a nonzero position so an accidental session rebuild is observable.
        app.buttons["playerEpisodes"].tap()
        app.buttons["episode-1"].tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerEpisodes") == "1" })
        if accessibilityValue(app, "playerPlaybackState") != "paused" { pause.tap() }
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPlaybackState") == "paused" })
        app.buttons["playerSettings"].tap()
        app.buttons["seekStep-15"].tap()
        closePlayerSheet(app)
        app.buttons["playerSeekForward"].tap()
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > 14 })
        app.buttons["playerSubtitles"].tap()
        XCTAssertTrue(app.buttons["subtitle-2"].waitForExistence(timeout: 5))
        app.buttons["subtitle-2"].tap()
        closePlayerSheet(app)
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerSubtitles") == "2" })
        var pausedAt = numericValue(app, "playerElapsedSeconds")

        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerLayout") == "portrait" })
        assertPlayerRetainedState(app, pausedAt: pausedAt)
        attachPlayerScreenshot("portrait")

        // Sensor-driven rotation must resize the existing rendering surface, without reloading mpv.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerLayout") == "landscape" })
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        assertPlayerRetainedState(app, pausedAt: pausedAt)
        attachPlayerScreenshot("landscape")
        // Capture a newly rendered frame too: a retained pre-rotation texture can hide resize bugs.
        pause.tap()
        XCTAssertTrue(waitUntil { self.numericValue(app, "playerElapsedSeconds") > pausedAt + 1 })
        pause.tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPlaybackState") == "paused" })
        pausedAt = numericValue(app, "playerElapsedSeconds")
        assertPlayerRetainedState(app, pausedAt: pausedAt)
        attachPlayerScreenshot("landscape-redrawn")
        let hiddenWhilePaused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.accessibilityValue(app, "playerChrome") == "hidden"
                || abs(self.numericValue(app, "playerElapsedSeconds") - pausedAt) > 0.4
        }, object: nil)
        hiddenWhilePaused.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [hiddenWhilePaused], timeout: 4.2), .completed)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerLayout") == "portrait" })
        XCTAssertGreaterThan(app.windows.firstMatch.frame.height, app.windows.firstMatch.frame.width)
        assertPlayerRetainedState(app, pausedAt: pausedAt)

        // iPhone requests orientation; iPad enters immersive playback in its current window.
        // iPad windowing modes can reject programmatic rotation, so multitasking remains available.
        let isTablet = UIDevice.current.userInterfaceIdiom == .pad
        let portraitWindow = app.windows.firstMatch.frame
        let fullscreenLayout = isTablet ? "portrait" : "landscape"
        XCTAssertEqual(accessibilityValue(app, "playerPresentation"), "inline")
        app.buttons["playerFullscreen"].tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPresentation") == "fullscreen" })
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerLayout") == fullscreenLayout })
        if isTablet {
            XCTAssertEqual(app.windows.firstMatch.frame.width, portraitWindow.width, accuracy: 1)
            XCTAssertEqual(app.windows.firstMatch.frame.height, portraitWindow.height, accuracy: 1)
        } else {
            XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        }
        assertPlayerRetainedState(app, pausedAt: pausedAt)
        app.buttons["playerFullscreen"].tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPresentation") == "inline" })
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerLayout") == "portrait" })
        XCTAssertGreaterThan(app.windows.firstMatch.frame.height, app.windows.firstMatch.frame.width)
        assertPlayerRetainedState(app, pausedAt: pausedAt)

        // Immersive playback hides chrome; tapping the unobstructed center restores touch controls.
        app.buttons["playerFullscreen"].tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPresentation") == "fullscreen" })
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerLayout") == fullscreenLayout })
        pause.tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPlaybackState") == "playing" })
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerChrome") == "hidden" })
        app.descendants(matching: .any)["playerControlsToggle"].firstMatch.tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerChrome") == "visible" })
        XCTAssertTrue(pause.isHittable)
        pause.tap()
        XCTAssertTrue(waitUntil { self.accessibilityValue(app, "playerPlaybackState") == "paused" })
        XCTAssertGreaterThan(numericValue(app, "playerElapsedSeconds"), pausedAt + 1)
        XCTAssertEqual(accessibilityValue(app, "playerSubtitles"), "2")
        XCTAssertEqual(accessibilityValue(app, "playerEpisodes"), "1")
        app.buttons["playerClose"].tap()
        XCTAssertTrue(waitUntil { !pause.exists })
    }

    @MainActor private func assertPlayerRetainedState(_ app: XCUIApplication, pausedAt: Double) {
        XCTAssertEqual(accessibilityValue(app, "playerPlaybackState"), "paused")
        XCTAssertEqual(numericValue(app, "playerElapsedSeconds"), pausedAt, accuracy: 0.4)
        XCTAssertEqual(accessibilityValue(app, "playerSubtitles"), "2")
        XCTAssertEqual(accessibilityValue(app, "playerEpisodes"), "1")
        XCTAssertEqual(accessibilityValue(app, "playerChrome"), "visible")
        for identifier in ["playerTogglePause", "playerFullscreen", "playerSubtitles", "playerEpisodes", "playerClose"] {
            XCTAssertTrue(app.buttons[identifier].isHittable, "Control inaccessible after rotation: \(identifier)")
        }
        XCTAssertFalse(app.staticTexts["Playback unavailable"].exists)
    }

    @MainActor private func attachPlayerScreenshot(_ orientation: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        attachment.name = "\(device)-mpv-modern-\(orientation)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func accessibilityValue(_ app: XCUIApplication, _ identifier: String) -> String {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        guard element.exists else { return "" }
        return element.value as? String ?? element.label
    }

    @MainActor private func openPlayerWorkspace(_ app: XCUIApplication) {
        let play = UIDevice.current.userInterfaceIdiom == .pad
            ? app.descendants(matching: .any)["workspace-play"].firstMatch
            : app.tabBars.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        play.tap()
    }

    @MainActor private func numericValue(_ app: XCUIApplication, _ identifier: String) -> Double {
        Double(accessibilityValue(app, identifier)) ?? .nan
    }

    @MainActor private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor private func closePlayerSheet(_ app: XCUIApplication) {
        let done = app.buttons["playerSheetDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
    }

    @MainActor private func setSwitch(_ toggle: XCUIElement, on: Bool) {
        let expected = on ? "1" : "0"
        guard toggle.value as? String != expected else { return }
        // SwiftUI exposes the whole labeled row as its switch AX frame. Recorded taps at
        // the row center hit only the label; the trailing 51-point control is the switch.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -28, dy: 0)).tap()
        XCTAssertTrue(waitUntil(timeout: 3) { toggle.value as? String == expected })
    }

    @MainActor func testTabletWorkspace() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout test") }
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launch()
        let play = app.descendants(matching: .any)["workspace-play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(play.frame.height, 56)
        let discoverShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        discoverShot.name = "iPad-discover"; discoverShot.lifetime = .keepAlways; add(discoverShot)
        play.tap()
        let field = app.textFields["mediaAddress"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(field.frame.height, 44)
        let files = app.buttons["從「檔案」選擇"]
        XCTAssertTrue(files.exists)
        XCTAssertGreaterThanOrEqual(files.frame.height, 56)
        XCTAssertGreaterThan(files.frame.minX, field.frame.minX)
        let playShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        playShot.name = "iPad-play"; playShot.lifetime = .keepAlways; add(playShot)
        field.tap(); field.typeText("invalid")
        app.buttons["播放影片"].tap()
        XCTAssertTrue(app.alerts["無法開啟影片"].waitForExistence(timeout: 5))
        app.alerts.buttons["好"].tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "invalid")
        XCTAssertTrue(files.isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        app.descendants(matching: .any)["workspace-library"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["下一部想看，都放這裡"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["workspace-discover"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Cowboy Bebop\n")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "Bebop", "星际牛仔")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30)); result.tap()
        XCTAssertTrue(app.navigationBars["作品詳情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["加入收藏"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["加入收藏"].frame.height, 56)
        let detailShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        detailShot.name = "iPad-detail"; detailShot.lifetime = .keepAlways; add(detailShot)
    }

    @MainActor func testMobileFlow() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("iPhone flow test") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Play"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Play"].tap()
        let address = app.textFields["mediaAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("not-a-url")
        app.buttons["Play video"].tap()
        XCTAssertTrue(app.alerts["Unable to open media"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        // Relaunch clears ephemeral input without touching persistent favorites.
        app.terminate()
        app.launch()
        app.tabBars.buttons["Play"].tap()
        address.tap()
        address.typeText("https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")
        app.buttons["Play video"].tap()
        XCTAssertTrue(app.buttons["playerTogglePause"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 30) { self.numericValue(app, "playerElapsedSeconds") > 1 })
        XCTAssertFalse(app.staticTexts["Playback unavailable"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "iOS-player"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["playerClose"].tap()
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Discover"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Cowboy Bebop\n")
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "Bebop", "星际牛仔")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        result.tap()
        XCTAssertTrue(app.navigationBars["About this anime"].waitForExistence(timeout: 8))
        let wasSaved = app.buttons["Saved to library"].exists
        if !wasSaved { app.buttons["Save to library"].tap() }
        XCTAssertTrue(app.buttons["Saved to library"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "Bebop", "星际牛仔")).firstMatch.waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.tabBars.buttons["Library"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "Bebop", "星际牛仔")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        let librarySearch = app.searchFields.firstMatch
        XCTAssertTrue(librarySearch.waitForExistence(timeout: 5))
        librarySearch.tap()
        librarySearch.typeText("no-match-7c149")
        XCTAssertFalse(saved.exists)
        librarySearch.buttons["Clear text"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        // Restart to leave the system search presentation without depending on its OS-specific dismiss label.
        app.terminate(); app.launch()
        app.tabBars.buttons["Library"].tap()
        app.buttons["library-sort"].tap()
        app.buttons["Highest rated"].tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        let libraryAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        libraryAttachment.name = "iOS-library-search-sort"
        libraryAttachment.lifetime = .keepAlways
        add(libraryAttachment)
        saved.tap()
        if !wasSaved { app.buttons["Saved to library"].tap() }
    }
}
