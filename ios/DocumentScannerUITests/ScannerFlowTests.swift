import XCTest
import StoreKitTest

/// Base for UI tests: every failure carries the screen's element tree and a screenshot,
/// so a stale selector shows what the screen offers now.
class HushUITestCase: XCTestCase {
    /// Attach the screen's element tree to every failure so stale selectors are easy to fix.
    override func record(_ issue: XCTIssue) {
        var issue = issue
        let app = XCUIApplication()
        if app.state == .runningForeground {
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "failure-tree"; issue.add(tree)
            issue.add(XCTAttachment(screenshot: app.screenshot()))
        }
        super.record(issue)
    }
}

final class ScannerFlowTests: HushUITestCase {
    @MainActor
    func testScreenshotSeamPreviewAndReturnToEditing() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-screenshots"]
        app.launch(); app.buttons["home-tools"].tap(); app.tool("Stitch screenshots").tap()
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
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en"]
        app.launch(); app.buttons["home-tools"].tap(); app.tool("QR code").tap()
        let field = app.textFields["qr-text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("https://example.com/offline")
        app.buttons["qr-generate"].tap()
        XCTAssertTrue(app.buttons["qr-share"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Offline QR code"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["QR code"].buttons["Close"].tap(); app.tool("Stitch screenshots").tap()
        XCTAssertTrue(app.navigationBars["Stitch screenshots"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose screenshots"].exists)
    }

    @MainActor
    func testLocalWatermarkTimestampIdentityAndLongImagePreview() throws {
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scanner", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: config); session.disableDialogs = true; session.clearTransactions()
        defer { session.clearTransactions() }
        try session.buyProduct(productIdentifier: "com.hushscan.pro.yearly")
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-saved"]
        app.launch(); openTestDocument(app)
        func finished(_ name: String) {
            XCTAssertTrue(app.staticTexts["tool-done-title"].waitForExistence(timeout: 30), name)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        // Watermark: preview and options on one page, applied to a new copy.
        openDocumentTools(app); app.buttons["Watermark · PRO"].tap()
        waitEnabled(app.buttons["watermark-apply"]); XCTAssertTrue(app.descendants(matching: .any)["tool-preview"].exists)
        app.buttons["watermark-apply"].tap(); finished("Watermark"); app.buttons["tool-done-primary"].tap()
        // Timestamp: pick a style, then check the details.
        openDocumentTools(app); app.buttons["Timestamp · PRO"].tap()
        waitEnabled(app.buttons["timestamp-next"]); app.buttons["timestamp-next"].tap()
        waitEnabled(app.buttons["timestamp-apply"]); app.buttons["timestamp-apply"].tap()
        finished("Timestamp"); app.buttons["tool-done-primary"].tap()
        // ID card layout keeps its own screen.
        openDocumentTools(app); app.buttons["ID card layout"].tap()
        let prepare = app.buttons["local-tool-prepare"]
        for _ in 0..<4 where !prepare.isHittable { app.swipeUp() }
        waitEnabled(prepare); prepare.tap()
        let save = app.buttons["local-tool-save"]
        waitEnabled(save); save.tap()
        let done = expectation(for: NSPredicate(format: "label == %@", "Copy saved on this iPhone."), evaluatedWith: app.staticTexts["local-tool-result"])
        wait(for: [done], timeout: 30)
        app.buttons["Close"].tap()
        // Long image: share-only result.
        openDocumentTools(app); app.buttons["Long image · PRO"].tap()
        waitEnabled(app.buttons["long-image-next"]); app.buttons["long-image-next"].tap()
        waitEnabled(app.buttons["long-image-run"]); app.buttons["long-image-run"].tap()
        finished("Long image"); XCTAssertTrue(app.buttons["tool-done-secondary"].exists)
        app.buttons["tool-close"].tap()
        app.terminate(); app.launch()
        // Newest first; the list builds rows lazily as it scrolls.
        for title in ["Test document (ID card layout)", "Test document (timestamp)", "Test document (watermark)", "Test document"] {
            XCTAssertTrue(reveal(app.staticTexts[title], in: app), title)
        }
    }

    @MainActor
    func testIDCaptureStopsAfterTwoSidesAndOffersLayout() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--simulate-camera"]
        app.launch(); app.buttons["Scan document"].tap()
        app.buttons["ID card"].tap()
        XCTAssertTrue(app.staticTexts["Front of card"].exists)
        waitEnabled(app.buttons["Capture page"]); app.buttons["Capture page"].tap()
        waitEnabled(app.buttons["review-add-page"]); app.buttons["review-add-page"].tap()
        XCTAssertTrue(app.staticTexts["Back of card"].waitForExistence(timeout: 5))
        waitEnabled(app.buttons["Capture page"]); app.buttons["Capture page"].tap()
        waitEnabled(app.buttons["review-done"])
        XCTAssertFalse(app.buttons["review-add-page"].exists)
        app.buttons["review-done"].tap()
        XCTAssertTrue(app.buttons["review-save"].waitForExistence(timeout: 5)); savePDF(in: app)
        let arrange = app.buttons["Arrange ID card on one page"]
        XCTAssertTrue(arrange.waitForExistence(timeout: 45)); arrange.tap()
        XCTAssertTrue(app.navigationBars["ID card layout"].waitForExistence(timeout: 5))
        app.buttons["local-tool-prepare"].tap(); waitEnabled(app.buttons["local-tool-save"])
    }

    @MainActor
    func testTrimMarginsCanCancelApplyResetAndReopen() throws {
        let app = XCUIApplication();app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en","--seed-draft"]
        app.launch();resumeFirstUnfinishedScan(in:app);editPage(1, in: app)
        selectEditorTool("crop", in: app)
        let trim = app.buttons["trim-margins"]
        for _ in 0..<3 where !trim.isHittable { app.swipeUp() };trim.tap()
        XCTAssertTrue(app.buttons["trim-preset-2"].waitForExistence(timeout:15));app.buttons["trim-preset-2"].tap()
        app.buttons["trim-cancel"].tap();trim.tap()
        XCTAssertTrue(app.staticTexts["trim-value-top"].waitForExistence(timeout:15));XCTAssertEqual(app.staticTexts["trim-value-top"].label,"0.0%")
        app.buttons["trim-preset-5"].tap();app.buttons["trim-apply"].tap()
        waitEnabled(app.buttons["Apply"]);app.buttons["Apply"].tap()
        app.terminate();app.launch();resumeFirstUnfinishedScan(in:app);editPage(1, in: app)
        selectEditorTool("crop", in: app)
        for _ in 0..<3 where !trim.isHittable { app.swipeUp() };trim.tap()
        XCTAssertTrue(app.staticTexts["trim-value-top"].waitForExistence(timeout:15));XCTAssertEqual(app.staticTexts["trim-value-top"].label,"5.0%")
        let result = app.buttons["trim-show-result"];result.tap()
        let shot = XCTAttachment(screenshot:app.screenshot());shot.name="Trim margins preview";shot.lifetime = .keepAlways;add(shot)
        for _ in 0..<4 where !app.buttons["trim-reset"].isHittable { app.swipeUp() }
        app.buttons["trim-reset"].tap();app.buttons["trim-apply"].tap()
        waitEnabled(app.buttons["Apply"]);app.buttons["Apply"].tap();savePDF(in: app)
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout:40))
    }

    @MainActor
    func testProExtractionAndAnnotationSaveThroughTools() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scanner", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true; session.clearTransactions()
        defer { session.clearTransactions() }
        try session.buyProduct(productIdentifier: "com.hushscan.pro.yearly")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-saved"]
        app.launch()
        openTestDocument(app)
        openDocumentTools(app); app.buttons["Extract pages · PRO"].tap()
        XCTAssertTrue(app.buttons["page-cell-2"].waitForExistence(timeout: 10))
        app.buttons["page-cell-2"].tap()
        XCTAssertEqual(app.staticTexts["page-selection-count"].label, "1 of 2 selected")
        waitEnabled(app.buttons["extract-next"]); app.buttons["extract-next"].tap()
        waitEnabled(app.buttons["extract-run"]); app.buttons["extract-run"].tap()
        XCTAssertTrue(app.staticTexts["tool-done-title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["tool-done-title"].label.contains("Extracted"))
        app.buttons["tool-done-primary"].tap()
        openDocumentTools(app); app.buttons["Sign & annotate"].tap()
        let addText = app.buttons["Add text box"]
        XCTAssertTrue(addText.waitForExistence(timeout: 10))
        let note = app.staticTexts["annotate-redact-note"]
        // The page canvas takes drags, so scroll from the strip above it.
        let above = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.26)), top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        for _ in 0..<4 where note.exists && addText.frame.maxY > note.frame.minY - 4 { above.press(forDuration: 0.05, thenDragTo: top) }
        XCTAssertLessThan(addText.frame.maxY, note.frame.minY, "Add text box must be reachable above the note")
        addText.tap()
        let field = app.descendants(matching: .any)["annotation-text"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        for _ in 0..<3 where !field.isHittable || field.frame.maxY > note.frame.minY { above.press(forDuration: 0.05, thenDragTo: top) }
        field.tap(); field.typeText(" APPROVED")
        designShot(app, "annotate-1-canvas")
        waitEnabled(app.buttons["Save"]); app.buttons["Save"].tap()
        let annotationDismissed = expectation(for:NSPredicate(format:"exists == false"),evaluatedWith:app.staticTexts["Sign & annotate"])
        wait(for:[annotationDismissed],timeout:60)
        XCTAssertTrue(app.buttons["Share PDF"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Annotated document"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testPageDuplicateUndoRedoAndOCRBodySearch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-draft"]
        app.launch(); resumeFirstUnfinishedScan(in: app)
        app.buttons["page-actions-1"].tap()
        app.buttons["Duplicate page"].tap()
        XCTAssertTrue(app.buttons["Edit page 3"].waitForExistence(timeout: 5))
        app.buttons["Undo"].tap(); XCTAssertFalse(app.buttons["Edit page 3"].exists)
        app.buttons["Redo"].tap(); XCTAssertTrue(app.buttons["Edit page 3"].exists)
        savePDF(in: app)
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 30))
        app.buttons["saved-done"].tap()
        let search = app.textFields["Search documents"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("SCANNER")
        XCTAssertTrue(app.staticTexts["Text match on page 1"].waitForExistence(timeout: 5))
        savedDocumentRow(in: app).tap()
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
        app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en","--seed-saved","--simulate-camera"]
        app.launch(); openTestDocument(app)
        app.buttons["document-edit"].tap();app.buttons["Add pages"].tap()
        waitEnabled(app.buttons["Capture page"]);app.buttons["Capture page"].tap()
        waitEnabled(app.buttons["review-done"]);app.buttons["review-done"].tap()
        XCTAssertTrue(app.buttons["Edit page 3"].waitForExistence(timeout:5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Share PDF"].waitForExistence(timeout:5))
        app.buttons["document-edit"].tap();XCTAssertFalse(app.buttons["Edit page 3"].exists)
        app.buttons["page-actions-1"].tap();app.buttons["Retake page"].tap()
        waitEnabled(app.buttons["Capture page"]);app.buttons["Capture page"].tap()
        waitEnabled(app.buttons["review-done"]);app.buttons["review-done"].tap()
        XCTAssertTrue(app.buttons["Edit page 2"].waitForExistence(timeout:5));XCTAssertFalse(app.buttons["Edit page 3"].exists)
        app.buttons["Save changes"].tap()
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout:40))
        app.buttons["saved-done"].tap();app.buttons["document-edit"].tap()
        XCTAssertTrue(app.buttons["Edit page 2"].waitForExistence(timeout:5));XCTAssertFalse(app.buttons["Edit page 3"].exists)
    }

    @MainActor
    func testMissingEdgesMustBeConfirmedBeforePDFSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-draft", "--seed-unchecked"]
        app.launch()
        resumeFirstUnfinishedScan(in: app)
        savePDF(in: app)
        XCTAssertTrue(app.staticTexts["Page edges weren't found. Confirm all four corners before saving."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Saved on this iPhone"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["review-save"].waitForExistence(timeout: 5))
        savePDF(in: app)
        XCTAssertTrue(app.navigationBars["Crop"].waitForExistence(timeout: 5))
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "text can be copied")).firstMatch.exists)
    }
    @MainActor
    func testRecoverDraftEditSaveAndReopenPDF() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-draft"]
        app.launch()
        resumeFirstUnfinishedScan(in: app)
        editPage(1, in: app)
        selectEditorTool("crop", in: app)
        app.buttons["rotate-page"].tap()
        waitEnabled(app.buttons["Apply"])
        app.buttons["Apply"].tap()
        savePDF(in: app)
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Share PDF"].exists)
        app.buttons["saved-done"].tap()
        XCTAssertTrue(reveal(savedDocumentRow(in: app), in: app))
        app.terminate(); app.launch()
        openTestDocument(app)
        XCTAssertTrue(app.buttons["Share PDF"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Saved document"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor
    func testEmptyLibraryAndSettings() throws {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource:"Scanner",withExtension:"storekit"))
        try SKTestSession(contentsOf:configuration).clearTransactions()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en"]
        app.launch()
        XCTAssertTrue(app.buttons["Scan document"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app.staticTexts["Paperwork, simplified"], in: app))
        app.buttons["nav-settings"].tap()
        XCTAssertTrue(app.buttons["Explore Pro"].waitForExistence(timeout: 5))
        for _ in 0..<5 where !app.buttons["Export library backup"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["Export library backup"].waitForExistence(timeout: 5))
    }

    /// A new scan saves through the save sheet: Save, then Save as PDF.
    @MainActor
    private func savePDF(in app: XCUIApplication) {
        let save = app.buttons["review-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10)); save.tap()
        let pdf = app.buttons["save-format-pdf"]
        if pdf.waitForExistence(timeout: 5) { pdf.tap() }
    }

    @MainActor
    private func openTestDocument(_ app: XCUIApplication) {
        let row = savedDocumentRow(in: app)
        XCTAssertTrue(reveal(row, in: app))
        row.tap()
        XCTAssertTrue(app.buttons["document-edit"].waitForExistence(timeout: 10))
    }

    /// Scroll a lazily built list until the element exists and sits above the tab bar.
    @MainActor @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        _ = element.waitForExistence(timeout: 5)
        let tabBar = app.buttons["nav-home"]
        for _ in 0..<8 {
            if element.exists && element.isHittable && (!tabBar.isHittable || element.frame.maxY < tabBar.frame.minY - 10) { return true }
            app.swipeUp(); _ = element.waitForExistence(timeout: 1)
        }
        return element.exists
    }

    /// Thumbnails select a page; the editor opens from the selected page.
    @MainActor
    private func editPage(_ number: Int, in app: XCUIApplication) {
        let thumb = app.buttons["Edit page \(number)"]
        XCTAssertTrue(thumb.waitForExistence(timeout: 5)); thumb.tap()
        if !app.navigationBars["Edit page"].waitForExistence(timeout: 2) {
            app.buttons["Edit current page"].tap()
            XCTAssertTrue(app.navigationBars["Edit page"].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    private func openDocumentTools(_ app: XCUIApplication) {
        let tools = app.descendants(matching: .any)["document-tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 10)); tools.tap()
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
        let unfinished = app.descendants(matching: .any)["unfinished-scans"]
        XCTAssertTrue(reveal(unfinished, in: app))
        unfinished.tap()
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resume-draft-")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); resume.tap()
        XCTAssertTrue(app.buttons["review-save"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(reveal(app.staticTexts["Paperwork, simplified"], in: app))
        XCTAssertFalse(app.alerts["Move this document to Trash?"].exists, "Home gestures commit directly to recoverable Trash")
        app.buttons["nav-settings"].tap()
        let trashFolder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Trash (")).firstMatch
        XCTAssertTrue(reveal(trashFolder, in: app)); trashFolder.tap()
        XCTAssertTrue(app.staticTexts["Test document"].waitForExistence(timeout: 5))
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 5))
        app.navigationBars["Trash"].buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(reveal(savedDocumentRow(in: app), in: app))
    }

    @MainActor
    func testHomeTrashActionCanBeCancelledAndDocumentRestored() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-saved"]
        app.launch()
        let row = savedDocumentRow(in: app)
        XCTAssertTrue(reveal(row, in: app))
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
        openTestDocument(app)
        XCTAssertTrue(app.buttons["Share PDF"].waitForExistence(timeout: 5), "Restoring must retain the saved PDF and normal row navigation")
    }

    @MainActor
    func testHomeLeadingSwipeCanCancelAndBothFullSwipesMoveToTrash() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-saved"]
        app.launch()
        let row = savedDocumentRow(in: app)
        XCTAssertTrue(reveal(row, in: app))
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
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-draft"]
        app.launch()
        XCTAssertTrue(app.buttons["nav-settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Continue your scan"].exists)
        app.buttons["nav-settings"].tap()
        let unfinished = app.descendants(matching: .any)["unfinished-scans"]
        XCTAssertTrue(reveal(unfinished, in: app)); unfinished.tap()
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
        app.navigationBars["Unfinished scans"].buttons.firstMatch.tap()
        let trashFolder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Trash (")).firstMatch
        XCTAssertTrue(reveal(trashFolder, in: app)); trashFolder.tap()
        XCTAssertTrue(app.staticTexts["Test document"].waitForExistence(timeout: 5))
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 5))
        app.navigationBars["Trash"].buttons.firstMatch.tap()
        unfinished.tap()
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "resume-draft-")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); resume.tap()
        XCTAssertTrue(app.buttons["review-save"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit page 1"].exists)
        XCTAssertTrue(app.buttons["Edit page 2"].exists, "Restoring must retain every captured page")
    }

    @MainActor
    func testCapturePreviewOpensPinchesPansAndReturnsToUnchangedEdits() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--simulate-camera"]
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
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--simulate-camera"]
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
        XCTAssertFalse(app.buttons["Cleanup"].exists)
        app.buttons["Contrast"].tap()
        XCTAssertTrue(app.sliders["contrast-slider"].exists)
        app.buttons["Brightness"].tap()
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
        XCTAssertTrue(app.buttons["review-save"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit page 2"].exists)
        editPage(1, in: app)
        selectEditorTool("adjust", in: app)
        for _ in 0..<3 where !app.sliders["brightness-slider"].isHittable { app.swipeUp() }
        XCTAssertEqual(app.staticTexts["adjustment-value"].label, editedValue)
        app.buttons["Cancel"].tap()
        editPage(2, in: app)
        selectEditorTool("adjust", in: app)
        for _ in 0..<3 where !app.sliders["brightness-slider"].isHittable { app.swipeUp() }
        XCTAssertEqual(app.staticTexts["adjustment-value"].label, "+0", "Each new page starts from automatic cleanup, not the previous page's sliders")
        app.buttons["Cancel"].tap()
        app.terminate(); app.launch()
        resumeFirstUnfinishedScan(in: app)
        editPage(1, in: app)
        selectEditorTool("adjust", in: app)
        for _ in 0..<3 where !app.sliders["brightness-slider"].isHittable { app.swipeUp() }
        XCTAssertEqual(app.staticTexts["adjustment-value"].label, editedValue)
        app.buttons["Cancel"].tap()
        savePDF(in: app)
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 30))
    }

    @MainActor
    func testNativeSDKAdRetainsIdentityAcrossScrolling() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-saved", "--test-native-ad-sdk"]
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
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--seed-draft"]
        app.launch()
        resumeFirstUnfinishedScan(in: app)
        savePDF(in: app)
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
        app.launchArguments = ["--ui-test-session", UUID().uuidString,"-app-language","en", "--simulate-camera"]
        app.launch()
        app.buttons["Scan document"].tap()
        waitEnabled(app.buttons["Capture page"]); app.buttons["Capture page"].tap()
        XCTAssertTrue(app.navigationBars["Review scan"].waitForExistence(timeout: 10))
        // Reject even before the first preview finishes.
        app.buttons["capture-review-cancel"].tap()
        waitEnabled(app.buttons["Capture page"])
        XCTAssertTrue(app.staticTexts["No pages yet"].exists)
        XCTAssertFalse(app.buttons["review-save"].isHittable)
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
        editPage(1, in: app)
        selectEditorTool("adjust", in: app)
        for _ in 0..<3 where !slider.isHittable { app.swipeUp() }
        XCTAssertEqual(app.staticTexts["adjustment-value"].label, editedValue)
    }

    @MainActor
    func testSaveSheetConvertsToWordAndReviewShowsWholePage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session", UUID().uuidString, "-app-language", "en", "--seed-draft"]
        app.launch()
        resumeFirstUnfinishedScan(in: app)
        for id in ["review-tool-crop", "review-tool-filter", "review-tool-adjust", "review-tool-rotate", "review-tool-retake", "review-name"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: 5), id)
        }
        XCTAssertTrue(app.buttons["Add pages"].exists, "Add pages stays above Save")
        designShot(app, "save-1-review")
        app.buttons["review-save"].tap()
        for id in ["save-format-pdf", "save-format-word", "save-format-excel", "save-format-slides", "save-format-images", "save-name"] {
            XCTAssertTrue(app.descendants(matching: .any)[id].waitForExistence(timeout: 5), id)
        }
        designShot(app, "save-2-sheet")
        app.buttons["save-format-word"].tap()
        // The PDF is saved first, then Word reads the pages and opens its review.
        let preview = app.descendants(matching: .any)["office-page-preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 90), "Word review opens with the whole page")
        designShot(app, "save-3-word-review")
        preview.tap()
        XCTAssertTrue(app.buttons["close-enlarged-preview"].waitForExistence(timeout: 10))
        app.buttons["close-enlarged-preview"].tap()
        app.buttons["export-close"].tap()
        XCTAssertTrue(app.staticTexts["Saved on this iPhone"].waitForExistence(timeout: 10), "The PDF was saved too")
    }

    /// Startup logo smoothness: main-thread hitches from launch until the cover is gone
    /// (debug metric, see SplashMetrics). Runs with the ad SDK as a real launch does.
    @MainActor
    func testStartupLogoHasNoHitches() throws {
        var results: [String] = []
        for run in 0..<4 {
            let app = XCUIApplication()
            // Runs 0–1 are a returning user with documents (seeding adds test-only work), 2–3 a fresh library.
            app.launchArguments = ["--ui-test-session", UUID().uuidString, "-app-language", "en", "--test-native-ad-sdk", "--measure-splash"] + (run < 2 ? ["--seed-saved"] : [])
            app.launch()
            let metrics = app.staticTexts["splash-metrics"]
            XCTAssertTrue(metrics.waitForExistence(timeout: 20), "run \(run)")
            results.append(metrics.label)
            app.terminate()
        }
        let note = XCTAttachment(string: results.joined(separator: "\n")); note.name = "splash-metrics"; note.lifetime = .keepAlways; add(note)
        print("SPLASH-RESULTS\n" + results.joined(separator: "\n"))
    }

    /// Frozen logo frames for comparing the Core Animation splash with the Blender render.
    @MainActor
    func testStartupLogoFrames() throws {
        for t in ["0.1", "0.3", "0.6", "0.9", "1.05", "1.15", "1.25", "live"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-session", UUID().uuidString, "-app-language", "en", "--hold-launch-screen"] + (t == "live" ? [] : ["--splash-time", t])
            app.launch()
            XCTAssertTrue(app.otherElements["startup-screen"].waitForExistence(timeout: 10) || app.staticTexts["HushScan"].waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "splash-\(t)"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }

    @MainActor private func designShot(_ app: XCUIApplication, _ name: String) {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return }
        let folder = URL(fileURLWithPath: home).appendingPathComponent("Documents/ChatGPT/정치 중립/scanner-product/ios/Verification/private/design-shots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sleep(1)
        try? app.screenshot().pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }

}
