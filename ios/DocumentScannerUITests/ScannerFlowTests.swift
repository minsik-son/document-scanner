import XCTest
import StoreKitTest

final class ScannerFlowTests: XCTestCase {
    @MainActor
    func testScreenshotSeamPreviewAndReturnToEditing() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-screenshots"]
        app.launch(); app.buttons["home-tools"].tap(); app.buttons["Stitch screenshots"].tap()
        let picker = app.buttons["stitch-selected"]
        for _ in 0..<4 where !picker.isHittable { app.swipeUp() }
        picker.tap(); app.buttons["Screenshot 2"].tap()
        let find = app.buttons["Find overlap"]
        for _ in 0..<4 where !find.isHittable { app.swipeUp() }
        find.tap()
        XCTAssertTrue(app.staticTexts["Overlap suggested. Check the full preview before sharing."].waitForExistence(timeout: 10))
        let preview = app.buttons["Preview long image"]
        for _ in 0..<3 where !preview.isHittable { app.swipeUp() }
        preview.tap()
        let change = app.buttons["Change seams"]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        for _ in 0..<5 where !change.isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["Share long image"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Stitched screenshot preview"; shot.lifetime = .keepAlways; add(shot)
        change.tap()
        XCTAssertTrue(app.buttons["stitch-selected"].exists)
    }

    @MainActor
    func testOfflineQRCodeGenerationAndUtilityEntry() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-session", UUID().uuidString]
        app.launch(); app.buttons["home-tools"].tap(); app.buttons["QR code"].tap()
        let field = app.textFields["qr-text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("https://example.com/offline")
        app.buttons["qr-generate"].tap()
        XCTAssertTrue(app.buttons["qr-share"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Offline QR code"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["QR code"].buttons["Close"].tap(); app.buttons["Stitch screenshots"].tap()
        XCTAssertTrue(app.navigationBars["Stitch screenshots"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose screenshots"].exists)
    }

    @MainActor
    func testLocalWatermarkTimestampIdentityAndLongImagePreview() throws {
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scanner", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: config); session.disableDialogs = true; session.clearTransactions()
        defer { session.clearTransactions() }
        try session.buyProduct(productIdentifier: "com.documentscanner.pro.yearly")
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-saved"]
        app.launch(); XCTAssertTrue(app.staticTexts["Test document"].waitForExistence(timeout: 10)); app.staticTexts["Test document"].tap()
        func finished(_ name: String) {
            XCTAssertTrue(app.staticTexts["tool-done-title"].waitForExistence(timeout: 30), name)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        // Watermark: preview and options on one page, applied to a new copy.
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier IN %@)", "Tools", ["nav-tools", "home-tools"])).firstMatch.tap(); app.buttons["Watermark · PRO"].tap()
        waitEnabled(app.buttons["watermark-apply"]); XCTAssertTrue(app.descendants(matching: .any)["tool-preview"].exists)
        app.buttons["watermark-apply"].tap(); finished("Watermark"); app.buttons["tool-done-primary"].tap()
        // Timestamp: pick a style, then check the details.
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier IN %@)", "Tools", ["nav-tools", "home-tools"])).firstMatch.tap(); app.buttons["Timestamp · PRO"].tap()
        waitEnabled(app.buttons["timestamp-next"]); app.buttons["timestamp-next"].tap()
        waitEnabled(app.buttons["timestamp-apply"]); app.buttons["timestamp-apply"].tap()
        finished("Timestamp"); app.buttons["tool-done-primary"].tap()
        // ID card layout keeps its own screen.
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier IN %@)", "Tools", ["nav-tools", "home-tools"])).firstMatch.tap(); app.buttons["ID card layout"].tap()
        let prepare = app.buttons["local-tool-prepare"]
        for _ in 0..<4 where !prepare.isHittable { app.swipeUp() }
        waitEnabled(prepare); prepare.tap()
        let save = app.buttons["local-tool-save"]
        waitEnabled(save); save.tap()
        let done = expectation(for: NSPredicate(format: "label == %@", "Copy saved on this iPhone."), evaluatedWith: app.staticTexts["local-tool-result"])
        wait(for: [done], timeout: 30)
        app.buttons["Close"].tap()
        // Long image: share-only result.
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier IN %@)", "Tools", ["nav-tools", "home-tools"])).firstMatch.tap(); app.buttons["Long image · PRO"].tap()
        waitEnabled(app.buttons["long-image-run"]); app.buttons["long-image-run"].tap()
        finished("Long image"); XCTAssertTrue(app.buttons["tool-done-secondary"].exists)
        app.buttons["tool-close"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Test document (watermark)"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Test document (timestamp)"].exists)
        XCTAssertTrue(app.staticTexts["Test document (ID card layout)"].exists)
        XCTAssertTrue(app.staticTexts["Test document"].exists)
    }

    @MainActor
    func testIDCaptureStopsAfterTwoSidesAndOffersLayout() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-session", UUID().uuidString, "--simulate-camera"]
        app.launch(); app.buttons["Scan document"].tap()
        app.buttons["capture-style"].tap(); app.buttons["ID card"].tap()
        XCTAssertTrue(app.staticTexts["Front of card"].exists)
        waitEnabled(app.buttons["Capture page"]); app.buttons["Capture page"].tap()
        waitEnabled(app.buttons["review-add-page"]); app.buttons["review-add-page"].tap()
        XCTAssertTrue(app.staticTexts["Back of card"].waitForExistence(timeout: 5))
        waitEnabled(app.buttons["Capture page"]); app.buttons["Capture page"].tap()
        waitEnabled(app.buttons["review-done"])
        XCTAssertFalse(app.buttons["review-add-page"].exists)
        app.buttons["review-done"].tap()
        XCTAssertTrue(app.buttons["Save PDF"].waitForExistence(timeout: 5)); app.buttons["Save PDF"].tap()
        let arrange = app.buttons["Arrange ID card on one page"]
        XCTAssertTrue(arrange.waitForExistence(timeout: 45)); arrange.tap()
        XCTAssertTrue(app.navigationBars["ID card layout"].waitForExistence(timeout: 5))
        app.buttons["local-tool-prepare"].tap(); waitEnabled(app.buttons["local-tool-save"])
    }

    @MainActor
    func testTrimMarginsCanCancelApplyResetAndReopen() throws {
        let app = XCUIApplication();app.launchArguments = ["--ui-test-session",UUID().uuidString,"--seed-draft"]
        app.launch();resumeFirstUnfinishedScan(in:app);app.buttons["Edit page 1"].tap()
        selectEditorTool("crop", in: app)
        let trim = app.buttons["trim-margins"]
        for _ in 0..<3 where !trim.isHittable { app.swipeUp() };trim.tap()
        XCTAssertTrue(app.buttons["trim-preset-2"].waitForExistence(timeout:15));app.buttons["trim-preset-2"].tap()
        app.buttons["trim-cancel"].tap();trim.tap()
        XCTAssertTrue(app.staticTexts["trim-value-top"].waitForExistence(timeout:15));XCTAssertEqual(app.staticTexts["trim-value-top"].label,"0.0%")
        app.buttons["trim-preset-5"].tap();app.buttons["trim-apply"].tap()
        waitEnabled(app.buttons["Apply"]);app.buttons["Apply"].tap()
        app.terminate();app.launch();resumeFirstUnfinishedScan(in:app);app.buttons["Edit page 1"].tap()
        selectEditorTool("crop", in: app)
        for _ in 0..<3 where !trim.isHittable { app.swipeUp() };trim.tap()
        XCTAssertTrue(app.staticTexts["trim-value-top"].waitForExistence(timeout:15));XCTAssertEqual(app.staticTexts["trim-value-top"].label,"5.0%")
        let result = app.switches["trim-show-result"];result.tap()
        let shot = XCTAttachment(screenshot:app.screenshot());shot.name="Trim margins preview";shot.lifetime = .keepAlways;add(shot)
        for _ in 0..<4 where !app.buttons["trim-reset"].isHittable { app.swipeUp() }
        app.buttons["trim-reset"].tap();app.buttons["trim-apply"].tap()
        waitEnabled(app.buttons["Apply"]);app.buttons["Apply"].tap();app.buttons["Save PDF"].tap()
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout:40))
    }

    @MainActor
    func testProExtractionAndAnnotationSaveThroughTools() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scanner", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true; session.clearTransactions()
        defer { session.clearTransactions() }
        try session.buyProduct(productIdentifier: "com.documentscanner.pro.yearly")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-saved"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Test document"].waitForExistence(timeout: 10)); app.staticTexts["Test document"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier IN %@)", "Tools", ["nav-tools", "home-tools"])).firstMatch.tap(); app.buttons["Extract pages · PRO"].tap()
        XCTAssertTrue(app.buttons["page-cell-2"].waitForExistence(timeout: 10))
        app.buttons["page-cell-2"].tap()
        XCTAssertEqual(app.staticTexts["page-selection-count"].label, "1 of 2 selected")
        waitEnabled(app.buttons["extract-run"]); app.buttons["extract-run"].tap()
        XCTAssertTrue(app.staticTexts["tool-done-title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["tool-done-title"].label.contains("Extracted"))
        app.buttons["tool-done-primary"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier IN %@)", "Tools", ["nav-tools", "home-tools"])).firstMatch.tap(); app.buttons["Sign & annotate"].tap()
        XCTAssertTrue(app.buttons["Add text box"].waitForExistence(timeout: 10))
        app.buttons["Add text box"].tap()
        let field = app.descendants(matching: .any)["annotation-text"].firstMatch
        for _ in 0..<3 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(" APPROVED")
        waitEnabled(app.buttons["Save"]); app.buttons["Save"].tap()
        let annotationDismissed = expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:app.navigationBars["Sign & annotate"])
        wait(for:[annotationDismissed],timeout:60)
        XCTAssertTrue(app.buttons["Share PDF"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Annotated document"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testPageDuplicateUndoRedoAndOCRBodySearch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-draft"]
        app.launch(); resumeFirstUnfinishedScan(in: app)
        app.buttons["page-actions-1"].tap()
        app.buttons["Duplicate page"].tap()
        XCTAssertTrue(app.buttons["Edit page 3"].waitForExistence(timeout: 5))
        app.buttons["Undo"].tap(); XCTAssertFalse(app.buttons["Edit page 3"].exists)
        app.buttons["Redo"].tap(); XCTAssertTrue(app.buttons["Edit page 3"].exists)
        app.buttons["Save PDF"].tap()
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 30))
        app.buttons["Done"].tap()
        let search = app.textFields["Search documents"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("SCANNER")
        XCTAssertTrue(app.staticTexts["Text match on page 1"].waitForExistence(timeout: 5))
        app.staticTexts["Test document"].tap()
        XCTAssertTrue(app.buttons["Share PDF"].waitForExistence(timeout: 5))
        app.buttons["Text"].tap()
        XCTAssertTrue(app.buttons["Correct recognized text"].waitForExistence(timeout: 5))
        app.buttons["Correct recognized text"].tap()
        let region = app.descendants(matching: .any)["ocr-region-0"].firstMatch
        XCTAssertTrue(region.waitForExistence(timeout: 5)); region.tap(); region.typeText(" CORRECTED")
        app.buttons["Save"].tap()
        let correctionDismissed = expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:app.navigationBars["Correct text"])
        wait(for:[correctionDismissed],timeout:40)
        XCTAssertTrue(app.buttons["Save text file"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "CORRECTED")).firstMatch.exists)
    }

    @MainActor
    func testSavedDocumentAddCancelAndRetakeCommit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session",UUID().uuidString,"--seed-saved","--simulate-camera"]
        app.launch(); XCTAssertTrue(app.staticTexts["Test document"].waitForExistence(timeout:10));app.staticTexts["Test document"].tap()
        app.buttons["Edit"].tap();app.buttons["Add pages"].tap()
        waitEnabled(app.buttons["Capture page"]);app.buttons["Capture page"].tap()
        waitEnabled(app.buttons["review-done"]);app.buttons["review-done"].tap()
        XCTAssertTrue(app.buttons["Edit page 3"].waitForExistence(timeout:5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Share PDF"].waitForExistence(timeout:5))
        app.buttons["Edit"].tap();XCTAssertFalse(app.buttons["Edit page 3"].exists)
        app.buttons["page-actions-1"].tap();app.buttons["Retake page"].tap()
        waitEnabled(app.buttons["Capture page"]);app.buttons["Capture page"].tap()
        waitEnabled(app.buttons["review-done"]);app.buttons["review-done"].tap()
        XCTAssertTrue(app.buttons["Edit page 2"].waitForExistence(timeout:5));XCTAssertFalse(app.buttons["Edit page 3"].exists)
        app.buttons["Save changes"].tap()
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout:40))
        app.buttons["Done"].tap();app.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["Edit page 2"].waitForExistence(timeout:5));XCTAssertFalse(app.buttons["Edit page 3"].exists)
    }

    @MainActor
    func testMissingEdgesMustBeConfirmedBeforePDFSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-draft", "--seed-unchecked"]
        app.launch()
        resumeFirstUnfinishedScan(in: app)
        app.buttons["Save PDF"].tap()
        XCTAssertTrue(app.staticTexts["Page edges weren't found. Confirm all four corners before saving."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Saved on this iPhone"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Save PDF"].waitForExistence(timeout: 5))
        app.buttons["Save PDF"].tap()
        XCTAssertTrue(app.navigationBars["Crop"].waitForExistence(timeout: 5))
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Text can be selected and copied in your PDF."].exists)
    }
    @MainActor
    func testRecoverDraftEditSaveAndReopenPDF() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-draft"]
        app.launch()
        resumeFirstUnfinishedScan(in: app)
        let page = app.buttons["Edit page 1"]
        XCTAssertTrue(page.waitForExistence(timeout: 5)); page.tap()
        selectEditorTool("crop", in: app)
        app.buttons["rotate-page"].tap()
        waitEnabled(app.buttons["Apply"])
        app.buttons["Apply"].tap()
        app.buttons["Save PDF"].tap()
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Share PDF"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Test document"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        let document = app.staticTexts["Test document"]
        XCTAssertTrue(document.waitForExistence(timeout: 10)); document.tap()
        XCTAssertTrue(app.buttons["Share PDF"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Saved document"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor
    func testEmptyLibraryAndSettings() throws {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource:"Scanner",withExtension:"storekit"))
        try SKTestSession(contentsOf:configuration).clearTransactions()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["Scan document"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Paperwork, simplified"].exists)
        app.buttons["nav-settings"].tap()
        XCTAssertTrue(app.buttons["Explore Pro"].waitForExistence(timeout: 5))
        for _ in 0..<5 where !app.buttons["Export library backup"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["Export library backup"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func selectEditorTool(_ tool: String, in app: XCUIApplication) {
        let button = app.buttons["editor-tool-" + tool]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        for _ in 0..<3 where !button.isHittable { app.swipeUp() }
        button.tap()
    }

    @MainActor
    private func waitEnabled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }

    @MainActor
    private func resumeFirstUnfinishedScan(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["nav-settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Continue your scan"].exists, "Unfinished scans must not accumulate as cards on Home")
        app.buttons["nav-settings"].tap()
        let unfinished = app.buttons["unfinished-scans"]
        XCTAssertTrue(unfinished.waitForExistence(timeout: 5))
        for _ in 0..<2 where !unfinished.isHittable { app.swipeUp() }
        unfinished.tap()
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resume-draft-")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); resume.tap()
        XCTAssertTrue(app.buttons["Save PDF"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func savedDocumentRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "document-row-")).firstMatch
    }

    @MainActor
    private func dragRow(_ row: XCUIElement, from start: CGFloat, to end: CGFloat) {
        row.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5)))
    }

    @MainActor
    private func restoreTestDocument(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Paperwork, simplified"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Move this document to Trash?"].exists, "Home gestures commit directly to recoverable Trash")
        app.buttons["nav-settings"].tap()
        let trashFolder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Trash (")).firstMatch
        XCTAssertTrue(trashFolder.waitForExistence(timeout: 5)); trashFolder.tap()
        XCTAssertTrue(app.staticTexts["Test document"].waitForExistence(timeout: 5))
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 5))
        app.navigationBars["Trash"].buttons["Me"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(savedDocumentRow(in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    func testHomeTrashActionCanBeCancelledAndDocumentRestored() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-saved"]
        app.launch()
        let row = savedDocumentRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let trash = app.buttons["Move Test document to Trash"].firstMatch
        XCTAssertFalse(trash.isHittable, "Idle rows must not expose a trash icon")
        XCTAssertFalse(app.staticTexts["Continue your scan"].exists)
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "Home with swipe actions closed"; home.lifetime = .keepAlways; add(home)
        dragRow(row, from: 0.65, to: 0.35)
        XCTAssertTrue(trash.waitForExistence(timeout: 5)); XCTAssertTrue(trash.isHittable)
        XCTAssertTrue(app.staticTexts["Test document"].exists, "Releasing a partial swipe must not delete")
        let open = XCTAttachment(screenshot: app.screenshot()); open.name = "Home trailing trash revealed"; open.lifetime = .keepAlways; add(open)
        dragRow(row, from: 0.25, to: 0.6)
        XCTAssertFalse(trash.isHittable, "Reversing the swipe must close the action")
        XCTAssertTrue(row.exists)
        dragRow(row, from: 0.65, to: 0.35)
        XCTAssertTrue(trash.waitForExistence(timeout: 5)); trash.tap()
        restoreTestDocument(in: app)
        app.staticTexts["Test document"].tap()
        XCTAssertTrue(app.buttons["Share PDF"].waitForExistence(timeout: 5), "Restoring must retain the saved PDF and normal row navigation")
    }

    @MainActor
    func testHomeLeadingSwipeCanCancelAndBothFullSwipesMoveToTrash() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-saved"]
        app.launch()
        let row = savedDocumentRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let trash = app.buttons["Move Test document to Trash"].firstMatch
        dragRow(row, from: 0.35, to: 0.65)
        XCTAssertTrue(trash.waitForExistence(timeout: 5)); XCTAssertTrue(trash.isHittable)
        let open = XCTAttachment(screenshot: app.screenshot()); open.name = "Home leading trash revealed"; open.lifetime = .keepAlways; add(open)
        dragRow(row, from: 0.75, to: 0.4)
        XCTAssertFalse(trash.isHittable)
        XCTAssertTrue(row.exists)
        dragRow(row, from: 0.1, to: 0.95)
        restoreTestDocument(in: app)
        dragRow(row, from: 0.9, to: 0.05)
        restoreTestDocument(in: app)
        XCTAssertFalse(trash.isHittable)
    }

    @MainActor
    func testUnfinishedScanCanBeTrashedRestoredAndResumed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-draft"]
        app.launch()
        XCTAssertTrue(app.buttons["nav-settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Continue your scan"].exists)
        app.buttons["nav-settings"].tap()
        let unfinished = app.buttons["unfinished-scans"]
        XCTAssertTrue(unfinished.waitForExistence(timeout: 5)); unfinished.tap()
        let trash = app.buttons["Move Test document to Trash"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5)); trash.tap()
        let confirmation = app.alerts["Move this unfinished scan to Trash?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(trash.exists, "Cancelling must retain all unfinished pages")
        trash.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Move to Trash"].tap()
        XCTAssertTrue(app.staticTexts["No unfinished scans"].waitForExistence(timeout: 5))
        app.navigationBars["Unfinished scans"].buttons["Me"].tap()
        let trashFolder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Trash (")).firstMatch
        XCTAssertTrue(trashFolder.waitForExistence(timeout: 5)); trashFolder.tap()
        XCTAssertTrue(app.staticTexts["Test document"].waitForExistence(timeout: 5))
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 5))
        app.navigationBars["Trash"].buttons["Me"].tap()
        unfinished.tap()
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resume-draft-")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); resume.tap()
        XCTAssertTrue(app.buttons["Save PDF"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit page 1"].exists)
        XCTAssertTrue(app.buttons["Edit page 2"].exists, "Restoring must retain every captured page")
    }

    @MainActor
    func testCapturePreviewOpensPinchesPansAndReturnsToUnchangedEdits() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--simulate-camera"]
        app.launch()
        app.buttons["Scan document"].tap()
        waitEnabled(app.buttons["Capture page"]); app.buttons["Capture page"].tap()
        waitEnabled(app.buttons["review-done"])
        selectEditorTool("adjust", in: app)
        let slider = app.sliders["brightness-slider"]
        for _ in 0..<3 where !slider.isHittable { app.swipeUp() }
        slider.adjust(toNormalizedSliderPosition: 0.65)
        let editedValue = app.staticTexts["adjustment-value"].label
        let enlarge = app.buttons["enlarge-page-preview"]
        for _ in 0..<3 where !enlarge.isHittable { app.swipeDown() }
        waitEnabled(enlarge); enlarge.tap()
        let zoom = app.descendants(matching: .any)["zoomable-page"].firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        XCTAssertEqual(zoom.value as? String, "100%")
        zoom.pinch(withScale: 2, velocity: 1)
        let percent = { Double((zoom.value as? String ?? "0").replacingOccurrences(of: "%", with: "")) ?? 0 }
        XCTAssertGreaterThan(percent(), 150)
        zoom.swipeLeft()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Full-screen enlarged scan"; shot.lifetime = .keepAlways; add(shot)
        let before = percent()
        zoom.pinch(withScale: 0.6, velocity: -1)
        XCTAssertLessThan(percent(), before)
        // Double-tapping either zooms in or returns to fit; twice reaches fit.
        if percent() <= 105 { zoom.doubleTap() }
        zoom.doubleTap()
        XCTAssertEqual(zoom.value as? String, "100%")
        app.buttons["close-enlarged-preview"].tap()
        XCTAssertTrue(app.navigationBars["Review scan"].waitForExistence(timeout: 5))
        waitEnabled(app.buttons["review-done"])
        selectEditorTool("adjust", in: app)
        for _ in 0..<3 where !slider.isHittable { app.swipeUp() }
        XCTAssertEqual(app.staticTexts["adjustment-value"].label, editedValue)
        app.buttons["review-add-page"].tap()
        waitEnabled(app.buttons["Capture page"])
        XCTAssertTrue(app.staticTexts["1 page added"].exists)
    }

    @MainActor
    func testCaptureShowsProcessedReviewAndPreservesAdjustmentsWhenAddingPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--simulate-camera"]
        app.launch()
        app.buttons["Scan document"].tap()
        let shutter = app.buttons["Capture page"]
        waitEnabled(shutter); shutter.tap()
        XCTAssertTrue(app.navigationBars["Review scan"].waitForExistence(timeout: 10))
        XCTAssertFalse(shutter.exists, "Capture must pause while the edited result is being reviewed")
        waitEnabled(app.buttons["review-done"])
        let initial = XCTAttachment(screenshot: app.screenshot()); initial.name = "Automatic scan review"; initial.lifetime = .keepAlways; add(initial)
        XCTAssertFalse(app.sliders["brightness-slider"].exists, "Only the selected tool's options should appear")
        XCTAssertFalse(app.buttons["trim-margins"].exists)
        XCTAssertTrue(app.buttons["editor-tone-Document"].isSelected)
        app.buttons["compare-original"].tap()
        XCTAssertEqual(app.buttons["compare-original"].label, "Show scan")
        XCTAssertFalse(app.descendants(matching: .any)["zoomable-page"].exists, "Compare must not open the enlarged viewer")
        app.buttons["compare-original"].tap()
        app.buttons["editor-tone-Original"].tap()
        selectEditorTool("adjust", in: app)
        app.buttons["adjustment-picker"].tap()
        XCTAssertFalse(app.buttons["Cleanup"].exists)
        app.buttons["Contrast"].tap()
        XCTAssertTrue(app.sliders["contrast-slider"].exists)
        app.buttons["adjustment-picker"].tap(); app.buttons["Brightness"].tap()
        selectEditorTool("tone", in: app)
        app.buttons["editor-tone-Document"].tap()

        selectEditorTool("adjust", in: app)
        let slider = app.sliders["brightness-slider"]
        for _ in 0..<3 where !slider.isHittable { app.swipeUp() }
        XCTAssertTrue(slider.isHittable)
        slider.adjust(toNormalizedSliderPosition: 0.72)
        XCTAssertFalse(app.staticTexts["Updating preview…"].exists, "Adjustments must not cover the page with a loading overlay")
        let editedValue = app.staticTexts["adjustment-value"].label
        XCTAssertNotEqual(editedValue, "+0")
        let adjustmentShot = XCTAttachment(screenshot: app.screenshot()); adjustmentShot.name = "Focused adjustment controls"; adjustmentShot.lifetime = .keepAlways; add(adjustmentShot)
        waitEnabled(app.buttons["review-add-page"])
        app.buttons["review-add-page"].tap()
        waitEnabled(shutter); shutter.tap()
        XCTAssertTrue(app.navigationBars["Review scan"].waitForExistence(timeout: 10))
        waitEnabled(app.buttons["review-done"])
        app.buttons["review-done"].tap()
        XCTAssertTrue(app.buttons["Save PDF"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit page 2"].exists)
        app.buttons["Edit page 1"].tap()
        selectEditorTool("adjust", in: app)
        for _ in 0..<3 where !app.sliders["brightness-slider"].isHittable { app.swipeUp() }
        XCTAssertEqual(app.staticTexts["adjustment-value"].label, editedValue)
        app.buttons["Cancel"].tap()
        app.buttons["Edit page 2"].tap()
        selectEditorTool("adjust", in: app)
        for _ in 0..<3 where !app.sliders["brightness-slider"].isHittable { app.swipeUp() }
        XCTAssertEqual(app.staticTexts["adjustment-value"].label, "+0", "Each new page starts from automatic cleanup, not the previous page's sliders")
        app.buttons["Cancel"].tap()
        app.terminate(); app.launch()
        resumeFirstUnfinishedScan(in: app)
        app.buttons["Edit page 1"].tap()
        selectEditorTool("adjust", in: app)
        for _ in 0..<3 where !app.sliders["brightness-slider"].isHittable { app.swipeUp() }
        XCTAssertEqual(app.staticTexts["adjustment-value"].label, editedValue)
        app.buttons["Cancel"].tap()
        app.buttons["Save PDF"].tap()
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 30))
    }

    @MainActor
    func testNativeSDKAdRetainsIdentityAcrossScrolling() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-saved", "--test-native-ad-sdk"]
        let started = Date()
        app.launch()
        let ad = app.otherElements["home-native-ad"]
        guard ad.waitForExistence(timeout: 45) else { throw XCTSkip("Official test ad unavailable; requires network fill") }
        print("HOME AD COLD LAUNCH TO VISIBLE: \(Date().timeIntervalSince(started)) seconds")
        let dismiss = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Dismiss")).firstMatch
        if dismiss.waitForExistence(timeout: 5) { dismiss.tap() }
        else { print("SDK SCROLL TREE: " + app.debugDescription) }
        let original = try XCTUnwrap(ad.value as? String)
        let originalY = ad.frame.minY
        XCTAssertTrue(original.hasPrefix("request-1-"))
        let list = app.collectionViews.firstMatch
        let scroller = list.exists ? list : app.scrollViews.firstMatch
        for _ in 0..<3 {
            scroller.swipeUp()
            scroller.swipeUp()
            XCTAssertLessThan(ad.frame.minY, originalY - 80, "The test must actually scroll the ad upward")
            scroller.swipeDown()
            scroller.swipeDown()
            XCTAssertTrue(ad.waitForExistence(timeout: 3))
            XCTAssertEqual(ad.value as? String, original, "Scroll must retain the same ad without another request")
            XCTAssertFalse(app.otherElements["home-introduction"].exists)
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Same native advertisement after repeated scrolling"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testFirstSavedDocumentReturnsHomeWithoutAd() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--seed-draft"]
        app.launch()
        resumeFirstUnfinishedScan(in: app)
        app.buttons["Save PDF"].tap()
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["saved-done"].exists)
        app.buttons["saved-done"].tap()
        XCTAssertTrue(app.buttons["nav-home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Scan document"].exists)
        XCTAssertFalse(app.buttons["saved-done"].exists)
    }

    @MainActor
    func testCancelCaptureDiscardsOnlyRejectedPageAndAllowsRetake() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "--simulate-camera"]
        app.launch()
        app.buttons["Scan document"].tap()
        waitEnabled(app.buttons["Capture page"]); app.buttons["Capture page"].tap()
        XCTAssertTrue(app.navigationBars["Review scan"].waitForExistence(timeout: 10))
        // Reject even before the first preview finishes.
        app.buttons["capture-review-cancel"].tap()
        waitEnabled(app.buttons["Capture page"])
        XCTAssertTrue(app.staticTexts["No pages yet"].exists)
        XCTAssertFalse(app.buttons["Save PDF"].isHittable)
        // Retake, edit and explicitly accept one page.
        app.buttons["Capture page"].tap()
        waitEnabled(app.buttons["review-done"])
        selectEditorTool("adjust", in: app)
        let slider = app.sliders["brightness-slider"]
        for _ in 0..<3 where !slider.isHittable { app.swipeUp() }
        slider.adjust(toNormalizedSliderPosition: 0.3)
        let editedValue = app.staticTexts["adjustment-value"].label
        waitEnabled(app.buttons["review-add-page"]); app.buttons["review-add-page"].tap()
        waitEnabled(app.buttons["Capture page"])
        XCTAssertTrue(app.staticTexts["1 page added"].exists)
        // Cancel the next shot without losing the accepted first page.
        app.buttons["Capture page"].tap()
        XCTAssertTrue(app.navigationBars["Review scan"].waitForExistence(timeout: 10))
        app.buttons["capture-review-cancel"].tap()
        waitEnabled(app.buttons["Capture page"])
        XCTAssertTrue(app.staticTexts["1 page added"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Camera after rejecting next page"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Edit page 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Edit page 2"].exists)
        app.terminate(); app.launch()
        resumeFirstUnfinishedScan(in: app)
        XCTAssertFalse(app.buttons["Edit page 2"].exists, "Rejected pages must stay removed after relaunch")
        app.buttons["Edit page 1"].tap()
        selectEditorTool("adjust", in: app)
        for _ in 0..<3 where !slider.isHittable { app.swipeUp() }
        XCTAssertEqual(app.staticTexts["adjustment-value"].label, editedValue)
    }
}
