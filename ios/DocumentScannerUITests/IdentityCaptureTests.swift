import XCTest

final class IdentityCaptureTests: XCTestCase {
    @MainActor private func launchID() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--simulate-camera"]
        app.launch()
        XCTAssertTrue(app.buttons["home-tools"].waitForExistence(timeout: 10))
        app.buttons["home-tools"].tap()
        let search = app.textFields["tool-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("ID scan")
        app.buttons["id-scan-tool"].tap()
        XCTAssertTrue(app.buttons["Capture page"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Select a saved PDF to get started."].exists)
        XCTAssertTrue(app.staticTexts["Front of card"].exists)
        XCTAssertEqual(app.buttons["Automatic capture"].value as? String, "On")
        return app
    }
    @MainActor private func accept(_ app: XCUIApplication) {
        app.buttons["Capture page"].tap()
        let done = app.buttons["review-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: done)
        waitForExpectations(timeout: 30)
        done.tap()
    }
    @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testIDStartsCameraCapturesBothSidesRetakesAndSavesOneSheet() {
        let app = launchID()
        shot(app, "ID front camera")
        accept(app)
        XCTAssertTrue(app.staticTexts["Back of card"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["id-ready-back"].exists)
        XCTAssertTrue(app.staticTexts["Back of card"].exists)
        shot(app, "Flip card before automatic capture")
        accept(app)
        XCTAssertTrue(app.buttons["id-retake-front"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["id-save-pdf"].waitForExistence(timeout: 15))
        shot(app, "Both ID sides on one sheet")
        designShot(app, "id-1-sides")
        XCTAssertTrue(app.buttons["id-retake-front"].isHittable)
        app.buttons["id-retake-front"].tap()
        XCTAssertTrue(app.staticTexts["Front of card"].waitForExistence(timeout: 10))
        app.buttons["Capture page"].tap()
        XCTAssertTrue(app.buttons["capture-review-cancel"].waitForExistence(timeout: 15))
        app.buttons["capture-review-cancel"].tap()
        XCTAssertTrue(app.buttons["Capture page"].waitForExistence(timeout: 10))
        accept(app)
        XCTAssertTrue(app.buttons["id-retake-back"].waitForExistence(timeout: 15))
        let save = app.buttons["id-save-pdf"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 30)
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Front and back on one page"].exists)
        shot(app, "Saved single-page ID PDF")
        designShot(app, "id-2-saved")
        app.buttons["id-saved-done"].tap()
        XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Close"].tap()
        app.buttons["nav-documents"].tap()
        XCTAssertTrue(app.staticTexts["ID card"].waitForExistence(timeout: 10))
    }
    @MainActor func testCancelIDCaptureAndDiscardDoNotSaveDocument() {
        let app = launchID()
        app.buttons["Capture page"].tap()
        XCTAssertTrue(app.buttons["capture-review-cancel"].waitForExistence(timeout: 15))
        app.buttons["capture-review-cancel"].tap()
        XCTAssertTrue(app.staticTexts["Front of card"].waitForExistence(timeout: 10))
        accept(app)
        XCTAssertTrue(app.staticTexts["Back of card"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["id-ready-back"].exists)
        app.buttons["camera-close"].tap()
        XCTAssertTrue(app.buttons["Scan back"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["id-save-pdf"].exists)
        app.buttons["id-cancel"].tap()
        app.buttons["Discard scan"].tap()
        XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Close"].tap()
        app.buttons["nav-documents"].tap()
        XCTAssertFalse(app.staticTexts["ID card"].exists)
        XCTAssertFalse(app.staticTexts["Saved on this iPhone"].exists)
    }

    @MainActor private func designShot(_ app: XCUIApplication, _ name: String) {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return }
        let folder = URL(fileURLWithPath: home).appendingPathComponent("Documents/ChatGPT/정치 중립/scanner-product/ios/Verification/private/design-shots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sleep(1)
        try? app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
