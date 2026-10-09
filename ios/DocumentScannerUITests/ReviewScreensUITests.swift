import XCTest

/// Screens App Review will look at, captured for the submission checklist.
/// testReviewScreens runs against a Release build (no DEBUG-only text may show);
/// the PNGs land in Verification/private/review-shots (git-ignored).
final class ReviewScreensUITests: HushUITestCase {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Verification/private/review-shots")
    override func setUp() { continueAfterFailure = true }

    @MainActor private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: Self.folder.appendingPathComponent(name + ".png"))
    }
    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en"] + extra
        app.launch()
        // A fresh install starts with the introduction.
        if app.buttons["onboarding-skip"].waitForExistence(timeout: 6) { app.buttons["onboarding-skip"].tap() }
        if app.buttons["onboarding-later"].waitForExistence(timeout: 3) { app.buttons["onboarding-later"].tap() }
        return app
    }

    @MainActor func testReviewScreens() throws {
        #if DEBUG
        throw XCTSkip("Release build only: Debug builds show the Developer section in Settings.")
        #endif
        let app = launch()
        XCTAssertTrue(app.buttons["nav-tools"].waitForExistence(timeout: 10))
        // Tools: new sections and Spot eraser.
        app.buttons["nav-tools"].tap()
        XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout: 5))
        save(app, "1-tools-top")
        app.swipeUp(); save(app, "2-tools-middle")
        app.swipeUp(); app.swipeUp(); save(app, "3-tools-bottom")
        app.buttons["tools-close"].tap()
        // Settings bottom: name, version, support, terms — no development text.
        app.buttons["nav-settings"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 5))
        for _ in 0..<10 { app.swipeUp() }
        save(app, "4-settings-bottom")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'development'")).firstMatch.exists, "Development text in Settings")
        XCTAssertTrue(app.buttons["settings-support"].exists || app.links["Contact support"].exists)
        // Subscription page footer: Terms, Privacy, Restore purchases.
        for _ in 0..<10 { app.swipeDown() }
        let explore = app.buttons["Explore Pro"]
        if explore.waitForExistence(timeout: 3) {
            explore.tap()
            XCTAssertTrue(app.buttons["Restore purchases"].waitForExistence(timeout: 8))
            save(app, "5-paywall-top")
            for _ in 0..<4 { app.swipeUp() }
            save(app, "6-paywall-footer")
            XCTAssertTrue(app.buttons["paywall-terms"].exists || app.links["Terms"].exists)
            XCTAssertTrue(app.buttons["paywall-privacy"].exists || app.links["Privacy"].exists)
        } else {
            XCTFail("Explore Pro not found")
        }
    }

    /// Debug build only (uses a DEBUG launch argument): the guide shown when the
    /// translation languages are not downloaded. The view has no DEBUG-only parts.
    @MainActor func testTranslationGuideScreen() {
        let app = launch(["--preview-translation-guide"])
        XCTAssertTrue(app.staticTexts["translation-guide-title"].waitForExistence(timeout: 12))
        save(app, "7-translation-guide")
        app.buttons["translation-guide-ok"].tap()
    }
}
