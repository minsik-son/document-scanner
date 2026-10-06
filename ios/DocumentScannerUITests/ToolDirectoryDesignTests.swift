import XCTest

final class ToolDirectoryDesignTests: XCTestCase {
    @MainActor private func launch(saved: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString] + (saved ? ["--seed-saved"] : [])
        app.launch()
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
        XCTAssertTrue(app.navigationBars["Excel export"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Clear search"].tap()
        search.tap(); search.typeText("not-a-tool")
        XCTAssertTrue(app.staticTexts["No tools found"].waitForExistence(timeout: 5))
    }
    @MainActor func testBottomNavigationAndCenterCamera() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-saved", "--simulate-camera"]
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
        app.navigationBars.buttons["Close"].tap()
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
        preview.launchArguments = ["--ui-test-session", UUID().uuidString, "--hold-launch-screen"]
        preview.launch()
        XCTAssertTrue(preview.staticTexts["Paper, made digital."].waitForExistence(timeout: 5))
        XCTAssertFalse(preview.buttons["nav-home"].exists)
        capture(preview, "Branded startup")
        preview.terminate()
        let app = launch(saved: true)
        XCTAssertTrue(app.buttons["nav-documents"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Paper, made digital."].exists)
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
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--test-onboarding"]
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
        XCTAssertEqual(app.buttons["onboarding-next"].label, "Get started")
        app.buttons["onboarding-next"].tap()
        XCTAssertTrue(app.buttons["nav-home"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["nav-home"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["onboarding-skip"].exists)
        app.buttons["nav-settings"].tap()
        app.buttons["Take a quick tour"].tap()
        XCTAssertTrue(app.staticTexts["onboarding-title-0"].waitForExistence(timeout: 5))
        app.buttons["onboarding-skip"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout: 5))
    }
    @MainActor func testOnboardingLargeTextSkipPersists() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--test-onboarding",
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
        XCTAssertTrue(app.buttons["images-run"].waitForExistence(timeout: 5))
        app.buttons["tool-back"].tap()
        XCTAssertTrue(app.buttons["pdf-import"].waitForExistence(timeout: 5))
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
