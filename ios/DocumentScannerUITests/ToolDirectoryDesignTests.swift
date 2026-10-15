import XCTest

final class ToolDirectoryDesignTests: HushUITestCase {
    @MainActor private func launch(saved: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en"] + (saved ? ["--seed-saved"] : [])
        app.launch()
        // The branded startup screen covers Home until the library has opened.
        let splash = app.otherElements["startup-screen"]
        let deadline = Date().addingTimeInterval(10)
        while splash.exists && Date() < deadline { usleep(200_000) }
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testHomeAndSearchableToolDirectory() {
        let app = launch(saved: true)
        XCTAssertTrue(app.buttons["home-tools"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-tools"].isHittable)
        XCTAssertTrue(app.buttons["Scan document"].isHittable)
        capture(app, "Color home")
        app.buttons["home-tools"].tap()
        XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout: 5))
        capture(app, "All tools colored grid")
        let search = app.textFields["tool-search"]
        search.tap(); search.typeText("Excel")
        XCTAssertTrue(app.buttons["Excel export"].isHittable)
        XCTAssertFalse(app.buttons["Word export"].exists)
        app.buttons["Excel export"].tap()
        XCTAssertTrue(app.staticTexts["Turn tables into Excel"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Clear search"].tap()
        search.tap(); search.typeText("not-a-tool")
        XCTAssertTrue(app.staticTexts["No tools found"].waitForExistence(timeout: 5))
    }
    @MainActor func testFreeTriesBadgeOnToolGrid() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--test-pro-gate", "-app-language", "ko", "-AppleLanguages", "(ko)"]
        app.launch()
        XCTAssertTrue(app.buttons["nav-tools"].waitForExistence(timeout: 5))
        app.buttons["nav-tools"].tap()
        XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout: 5))
        capture(app, "Free tries badges")
    }
    @MainActor func testContactSupportRateAndShare() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "-app-language", "ko", "-AppleLanguages", "(ko)"]
        app.launch()
        XCTAssertTrue(app.buttons["nav-settings"].waitForExistence(timeout: 5))
        app.buttons["nav-settings"].tap()
        let support = app.buttons["settings-support"]
        for _ in 0..<12 where !support.isHittable { app.swipeUp() }
        XCTAssertTrue(support.isHittable)
        XCTAssertTrue(app.buttons["settings-rate"].exists)
        XCTAssertTrue(app.buttons["settings-share"].exists)
        capture(app, "Settings about rows")
        support.tap()
        XCTAssertTrue(app.buttons["support-send"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["support-send"].isEnabled)
        capture(app, "Support empty")
        app.buttons["support-topic-scan"].tap()
        let box = app.textViews["support-message"]
        box.tap(); box.typeText("Receipts come out blurry on the second page.")
        XCTAssertTrue(app.buttons["support-send"].isEnabled)
        capture(app, "Support filled")
    }
    @MainActor func testSettingsRedesignScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-saved", "-app-language", "ko", "-AppleLanguages", "(ko)"]
        app.launch()
        XCTAssertTrue(app.buttons["nav-settings"].waitForExistence(timeout: 10))
        app.buttons["nav-settings"].tap()
        let saveBackup = app.buttons["settings-save-backup"]
        XCTAssertTrue(saveBackup.waitForExistence(timeout: 5))
        capture(app, "Settings top")
        app.swipeUp(); capture(app, "Settings middle")
        app.swipeUp(); app.swipeUp(); capture(app, "Settings bottom")
        XCTAssertTrue(app.buttons["settings-support"].exists)
        for _ in 0..<4 { app.swipeDown() }
        for _ in 0..<4 where !saveBackup.isHittable { app.swipeUp() }
        saveBackup.tap()
        XCTAssertTrue(app.buttons["backup-export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["auto-export-choose"].exists || app.switches["auto-export-toggle"].exists)
        capture(app, "Save and backup")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let privacy = app.buttons["settings-privacy"]
        for _ in 0..<4 where !privacy.isHittable { app.swipeUp() }
        privacy.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        capture(app, "Privacy and data")
    }
    /// Light appearance stays as it was (compare with earlier screenshots).
    @MainActor func testLightModeScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-saved", "-appAppearance", "light"]
        app.launch()
        let splash = app.otherElements["startup-screen"]
        let deadline = Date().addingTimeInterval(10)
        while splash.exists && Date() < deadline { usleep(200_000) }
        XCTAssertTrue(app.buttons["home-tools"].waitForExistence(timeout: 5))
        capture(app, "Light home")
        app.buttons["home-tools"].tap()
        XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout: 5))
        capture(app, "Light tools")
    }
    /// Dark appearance across the main screens (screenshots for review).
    @MainActor func testDarkModeScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-saved", "--simulate-camera", "-appAppearance", "dark", "-app-language", "ko", "-AppleLanguages", "(ko)"]
        app.launch()
        XCTAssertTrue(app.buttons["nav-home"].waitForExistence(timeout: 10))
        let splash = app.otherElements["startup-screen"]
        let deadline = Date().addingTimeInterval(10)
        while splash.exists && Date() < deadline { usleep(200_000) }
        capture(app, "Dark home")
        app.swipeUp(); capture(app, "Dark home lower"); app.swipeDown()
        app.buttons["nav-tools"].tap()
        XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout: 5))
        capture(app, "Dark tools")
        let compress = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "PDF 압축")).firstMatch
        if compress.waitForExistence(timeout: 3) {
            compress.tap(); sleep(2); capture(app, "Dark tool page")
            if app.buttons["tool-close"].exists { app.buttons["tool-close"].tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        }
        app.buttons["tools-close"].tap()
        app.buttons["nav-documents"].tap()
        capture(app, "Dark documents")
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "document-row-")).firstMatch
        if row.waitForExistence(timeout: 5) {
            row.tap(); sleep(2); capture(app, "Dark document")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.buttons["nav-settings"].tap()
        XCTAssertTrue(app.buttons["settings-save-backup"].waitForExistence(timeout: 5))
        capture(app, "Dark settings")
        app.buttons["settings-save-backup"].tap()
        XCTAssertTrue(app.buttons["backup-export"].waitForExistence(timeout: 5))
        capture(app, "Dark save and backup")
        app.terminate()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--simulate-camera", "-appAppearance", "dark", "-app-language", "ko", "-AppleLanguages", "(ko)"]
        app.launch()
        let scan = app.buttons["scan-document"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.otherElements["startup-screen"])
        _ = XCTWaiter.wait(for: [gone], timeout: 10)
        scan.tap()
        let shutter = app.buttons["capture-page"]
        if shutter.waitForExistence(timeout: 6) {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: shutter)
            _ = XCTWaiter.wait(for: [enabled], timeout: 8)
            shutter.tap()
            _ = app.buttons["review-done"].waitForExistence(timeout: 12); sleep(2)
            capture(app, "Dark scan review")
        }
    }
    @MainActor func testBottomNavigationAndCenterCamera() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-saved", "--simulate-camera", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["nav-home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scan-document"].isHittable)
        capture(app, "Home with center camera")
        app.buttons["nav-documents"].tap()
        XCTAssertFalse(app.staticTexts["Quick tools"].exists)
        XCTAssertTrue(app.staticTexts["Test document"].isHittable)
        capture(app, "Documents bottom navigation")
        app.buttons["Import"].tap()
        XCTAssertTrue(app.buttons["Choose PDF or image"].waitForExistence(timeout: 5))
        app.buttons["Choose PDF or image"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["nav-tools"].tap()
        XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout: 5))
        app.buttons["tools-close"].tap()
        app.buttons["nav-settings"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Done"].tap()
        app.buttons["nav-home"].tap()
        XCTAssertTrue(app.staticTexts["Quick tools"].waitForExistence(timeout: 5))
        app.buttons["scan-document"].tap()
        XCTAssertTrue(app.buttons["Capture page"].waitForExistence(timeout: 5))
    }
    @MainActor func testBrandedStartupAndLocalLibraryOpening() {
        let preview = XCUIApplication()
        preview.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--hold-launch-screen"]
        preview.launch()
        XCTAssertTrue(preview.staticTexts["Fast, easy scanning."].waitForExistence(timeout: 5))
        XCTAssertFalse(preview.buttons["nav-home"].exists)
        capture(preview, "Branded startup")
        preview.terminate()
        let app = launch(saved: true)
        XCTAssertTrue(app.buttons["nav-documents"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Fast, easy scanning."].exists)
        app.buttons["nav-documents"].tap()
        XCTAssertTrue(app.staticTexts["Test document"].isHittable)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["nav-documents"].waitForExistence(timeout: 10))
        app.buttons["nav-documents"].tap()
        XCTAssertTrue(app.staticTexts["Test document"].isHittable)
    }
    @MainActor func testOnboardingPagesCompletionAndReplay() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--test-onboarding"]
        app.launch()
        XCTAssertTrue(app.staticTexts["onboarding-title-0"].waitForExistence(timeout: 8))
        capture(app, "Onboarding 1 - scan")
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-1"].waitForExistence(timeout: 5))
        capture(app, "Onboarding 2 - refine")
        app.buttons["onboarding-back"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-0"].isHittable)
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["onboarding-title-1"].waitForExistence(timeout: 5))
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-2"].waitForExistence(timeout: 5))
        capture(app, "Onboarding 3 - library")
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-3"].waitForExistence(timeout: 5))
        capture(app, "Onboarding 4 - first scan")
        XCTAssertTrue(app.buttons["onboarding-scan"].exists)
        app.buttons["onboarding-later"].tap()
        XCTAssertTrue(app.buttons["home-scan-tip"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nav-home"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["nav-home"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["onboarding-skip"].exists)
        app.buttons["nav-settings"].tap()
        // Settings is a lazy list; for free users the row starts below the fold.
        let tour = app.buttons["Take a quick tour"]
        _ = tour.waitForExistence(timeout: 3)
        for _ in 0..<5 where !(tour.exists && tour.isHittable) { app.swipeUp() }
        tour.tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-0"].waitForExistence(timeout: 5))
        app.buttons["onboarding-skip"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 5))
    }
    @MainActor func testOnboardingLargeTextSkipPersists() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--test-onboarding",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-skip"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["onboarding-next"].isHittable)
        capture(app, "Onboarding large text")
        app.buttons["onboarding-skip"].tap()
        XCTAssertTrue(app.buttons["nav-home"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["nav-home"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["onboarding-skip"].exists)
    }
    @MainActor func testLibraryToolSelectionAndEmptyState() {
        let app = launch(saved: true)
        app.buttons["home-tools"].tap()
        let search = app.textFields["tool-search"]
        search.tap(); search.typeText("Export images")
        app.buttons["Export images"].tap()
        XCTAssertTrue(app.buttons["pdf-import"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["tool-page-title"].exists)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tool-document-")).firstMatch.tap()
        XCTAssertTrue(app.buttons["images-next"].waitForExistence(timeout: 5)); app.buttons["images-next"].tap()
        XCTAssertTrue(app.buttons["images-run"].waitForExistence(timeout: 5))
        // Every format iOS can write; TIFF can put both pages in one file.
        for id in ["images-jpg", "images-png", "images-heic", "images-tiff", "images-gif", "images-bmp"] {
            XCTAssertTrue(app.buttons[id].exists, id)
        }
        app.buttons["images-tiff"].tap()
        XCTAssertTrue(app.switches["images-tiff-combined"].waitForExistence(timeout: 3))
        capture(app, "Image formats")
        app.buttons["images-run"].tap()
        XCTAssertTrue(app.staticTexts["Your TIFF file is ready"].waitForExistence(timeout: 20))
        app.terminate()
        let empty = launch()
        empty.buttons["Text"].tap()
        XCTAssertTrue(empty.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "No saved documents")).firstMatch.waitForExistence(timeout: 5))
        capture(empty, "Tool without saved document")
    }
    @MainActor func testLibrarySwipeAndNavigationAfterRedesign() {
        let app = launch(saved: true)
        app.swipeUp()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "document-row-")).firstMatch
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)))
        let trash = app.buttons["Move Test document to Trash"].firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        capture(app, "Redesigned home swipe action")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
        XCTAssertFalse(trash.isHittable)
        app.staticTexts["Test document"].tap()
        XCTAssertTrue(app.buttons["Share PDF"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).isHittable)
    }
}

/// QA: every main screen in every app language, light and dark, for a visual review of
/// truncation, overlap, untranslated text and contrast. Screenshots are named
/// "<lang>|<mode>|<screen>". QA_LANGS (comma list) limits the languages; QA_LARGE_TEXT=1
/// adds an Accessibility Large text pass in en and ko.
final class QALocalizationMatrixTests: HushUITestCase {
    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let s = XCTAttachment(screenshot: app.screenshot()); s.name = name; s.lifetime = .keepAlways; add(s)
    }
    @MainActor private func back(_ app: XCUIApplication) {
        let b = app.navigationBars.buttons.element(boundBy: 0)
        if b.exists && b.isHittable { b.tap() } else { app.swipeRight() }
        usleep(600_000)
    }
    @MainActor private func pass(_ lang: String, _ mode: String, size: String? = nil) {
        let app = XCUIApplication()
        var args = ["--ui-test-session", UUID().uuidString, "--seed-saved", "--simulate-camera", "-appAppearance", mode,
                    "-app-language", lang, "-AppleLanguages", "(\(lang))"]
        if let size { args += ["-UIPreferredContentSizeCategoryName", size] }
        app.launchArguments = args
        app.launch()
        settle(app)
        let tag = "\(lang)|\(mode)\(size == nil ? "" : "|large")|"
        shot(app, tag + "01 home")
        app.swipeUp(); usleep(500_000); shot(app, tag + "02 home lower"); app.swipeDown(); usleep(400_000)
        if app.buttons["nav-tools"].exists {
            app.buttons["nav-tools"].tap()
            if app.textFields["tool-search"].waitForExistence(timeout: 5) {
                shot(app, tag + "03 tools")
                app.swipeUp(); usleep(500_000); shot(app, tag + "04 tools middle")
                app.swipeUp(); usleep(500_000); shot(app, tag + "05 tools end")
                let redact = app.buttons["smart-tool-redact"]
                if !redact.isHittable { app.swipeDown(); usleep(400_000) }
                if !redact.isHittable { app.swipeDown(); usleep(400_000) }
                if redact.exists && redact.isHittable {
                    redact.tap(); sleep(2); shot(app, tag + "06 tool intro")
                    if app.buttons["tool-close"].exists { app.buttons["tool-close"].tap() } else { back(app) }
                    usleep(600_000)
                }
                if app.buttons["tools-close"].exists { app.buttons["tools-close"].tap() }
            }
        }
        if app.buttons["nav-settings"].exists {
            app.buttons["nav-settings"].tap()
            if app.buttons["settings-save-backup"].waitForExistence(timeout: 5) {
                shot(app, tag + "10 settings")
                app.swipeUp(); usleep(500_000); shot(app, tag + "11 settings lower"); app.swipeDown(); usleep(400_000)
                app.buttons["settings-save-backup"].tap(); sleep(1); shot(app, tag + "12 save and backup"); back(app)
                if app.buttons["settings-privacy"].exists { app.buttons["settings-privacy"].tap(); sleep(1); shot(app, tag + "13 privacy"); back(app) }
                if app.buttons["settings-benefits"].exists { app.buttons["settings-benefits"].tap(); sleep(1); shot(app, tag + "14 benefits"); back(app) }
            }
        }
        if app.buttons["nav-home"].exists {
            app.buttons["nav-home"].tap(); usleep(600_000)
            let scan = app.buttons["scan-document"]
            if scan.exists && scan.isHittable {
                scan.tap()
                let shutter = app.buttons["capture-page"]
                if shutter.waitForExistence(timeout: 6) {
                    sleep(1); shot(app, tag + "15 camera")
                    let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: shutter)
                    _ = XCTWaiter.wait(for: [enabled], timeout: 8)
                    shutter.tap()
                    if app.buttons["review-done"].waitForExistence(timeout: 12) { sleep(2); shot(app, tag + "16 scan review") }
                }
            }
        }
        app.terminate(); app.launch(); settle(app)
        if app.buttons["nav-documents"].exists {
            app.buttons["nav-documents"].tap(); sleep(1); shot(app, tag + "07 documents")
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "document-row-")).firstMatch
            if row.waitForExistence(timeout: 4) {
                row.tap(); sleep(2); shot(app, tag + "08 document")
                if app.buttons["document-tools"].exists { app.buttons["document-tools"].tap(); sleep(1); shot(app, tag + "09 document tools menu"); app.tap() ; usleep(500_000) }
                back(app)
            }
        }
        app.terminate()
    }
    @MainActor func testScreensAllLanguages() {
        let all = ["en", "ko", "ja", "es", "pt-BR", "de", "fr", "it", "pl", "tr", "id", "vi", "th", "zh-Hans", "zh-Hant"]
        let env = ProcessInfo.processInfo.environment
        let langs = env["QA_LANGS"].map { $0.split(separator: ",").map(String.init) } ?? all
        for lang in langs { for mode in ["light", "dark"] { pass(lang, mode) } }
        if env["QA_LARGE_TEXT"] == "1" || env["QA_LANGS"] == nil {
            for lang in ["en", "ko", "de"] { pass(lang, "light", size: "UICTContentSizeCategoryAccessibilityL") }
        }
    }
}
