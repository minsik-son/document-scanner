import XCTest
import StoreKitTest

final class PaywallDesignTests: HushUITestCase {
    @MainActor func testPlansShowRealPricesAndPurchaseUnlocksPro() throws {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scanner", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration)
        session.disableDialogs = true;session.clearTransactions()
        let app = XCUIApplication();app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en"];app.launch()
        app.buttons["nav-settings"].tap();app.buttons["Explore Pro"].tap()
        XCTAssertTrue(app.buttons["subscribe-button"].waitForExistence(timeout: 10))
        capture(app, "Pro spotlight")
        let monthly = app.buttons["plan-monthly"], yearly = app.buttons["plan-yearly"]
        aboveFooter(monthly, in: app)
        XCTAssertTrue(yearly.exists);XCTAssertTrue(monthly.isHittable)
        XCTAssertTrue(yearly.label.contains("SAVE 49%"))
        let subscribe = app.buttons["subscribe-button"]
        XCTAssertTrue(subscribe.label.contains("29.99"));XCTAssertTrue(subscribe.label.contains("year"))
        monthly.tap();XCTAssertTrue(subscribe.label.contains("4.99"));XCTAssertTrue(subscribe.label.contains("month"))
        capture(app, "Pro monthly plan")
        let lifetime = app.buttons["plan-lifetime"]
        aboveFooter(lifetime, in: app)
        lifetime.tap();XCTAssertTrue(subscribe.label.contains("39.99"));XCTAssertTrue(subscribe.label.contains("Buy once"))
        capture(app, "Pro lifetime plan")
        yearly.tap();XCTAssertTrue(subscribe.label.contains("29.99"))
        capture(app, "Pro yearly plan")
        XCTAssertTrue(app.buttons["Privacy"].exists);XCTAssertTrue(app.buttons["Restore purchases"].exists)
        subscribe.tap()
        XCTAssertTrue(app.staticTexts["Pro is active"].waitForExistence(timeout: 20))
        XCTAssertFalse(subscribe.exists)
        session.clearTransactions()
    }
    /// Plan cards scroll under the pinned purchase footer; drag until the card sits clear above it.
    @MainActor private func aboveFooter(_ card: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let cta = app.buttons["subscribe-button"]
        for _ in 0..<8 where card.frame.maxY > cta.frame.minY - 60 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -150)))
        }
    }
    @MainActor func testLargeTextPaywallCanCloseWithoutBuying() throws {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scanner", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration);session.clearTransactions()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en","-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch();app.buttons["nav-settings"].tap()
        let explore = app.buttons["Explore Pro"]
        for _ in 0..<6 where !explore.isHittable { app.swipeUp() }
        explore.tap()
        let subscribe = app.buttons["subscribe-button"]
        XCTAssertTrue(app.buttons["subscribe-button"].waitForExistence(timeout:10))
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
