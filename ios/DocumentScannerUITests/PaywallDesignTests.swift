import XCTest
import StoreKitTest

final class PaywallDesignTests: XCTestCase {
    @MainActor func testPlansShowRealPricesAndPurchaseUnlocksPro() throws {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scanner", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration)
        session.disableDialogs = true;session.clearTransactions()
        let app = XCUIApplication();app.launchArguments = ["--ui-test-session", UUID().uuidString];app.launch()
        app.buttons["nav-settings"].tap();app.buttons["Explore Pro"].tap()
        XCTAssertTrue(app.staticTexts["Every page.\nMore possibilities."].waitForExistence(timeout: 10))
        capture(app, "Pro spotlight")
        let monthly = app.buttons["plan-monthly"], yearly = app.buttons["plan-yearly"]
        for _ in 0..<6 where !monthly.isHittable { app.swipeUp() }
        XCTAssertTrue(yearly.exists);XCTAssertTrue(monthly.isHittable)
        XCTAssertTrue(yearly.label.contains("SAVE 49%"))
        let subscribe = app.buttons["subscribe-button"]
        XCTAssertTrue(subscribe.label.contains("29.99"));XCTAssertTrue(subscribe.label.contains("year"))
        monthly.tap();XCTAssertTrue(subscribe.label.contains("4.99"));XCTAssertTrue(subscribe.label.contains("month"))
        capture(app, "Pro monthly plan")
        yearly.tap();XCTAssertTrue(subscribe.label.contains("29.99"))
        capture(app, "Pro yearly plan")
        XCTAssertTrue(app.buttons["Privacy"].exists);XCTAssertTrue(app.buttons["Restore purchases"].exists)
        subscribe.tap()
        XCTAssertTrue(app.staticTexts["Pro is active"].waitForExistence(timeout: 20))
        XCTAssertFalse(subscribe.exists)
        session.clearTransactions()
    }
    @MainActor func testLargeTextPaywallCanCloseWithoutBuying() throws {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scanner", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration);session.clearTransactions()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session",UUID().uuidString,"-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch();app.buttons["nav-settings"].tap()
        let explore = app.buttons["Explore Pro"]
        for _ in 0..<6 where !explore.isHittable { app.swipeUp() }
        explore.tap()
        let subscribe = app.buttons["subscribe-button"]
        XCTAssertTrue(app.staticTexts["Every page.\nMore possibilities."].waitForExistence(timeout:10))
        capture(app,"Pro large text overview")
        for _ in 0..<20 where !subscribe.isHittable { app.swipeUp() }
        XCTAssertTrue(subscribe.isHittable)
        XCTAssertLessThanOrEqual(subscribe.frame.maxX,app.frame.maxX)
        XCTAssertGreaterThanOrEqual(subscribe.frame.minX,app.frame.minX)
        capture(app,"Pro large text")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Explore Pro"].waitForExistence(timeout:5))
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot());shot.name = name;shot.lifetime = .keepAlways;add(shot)
    }
}
