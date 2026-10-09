import XCTest

final class AdvancedToolsUITests:XCTestCase {
    @MainActor private func ready(_ button:XCUIElement,file:StaticString = #filePath,line:UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == true AND enabled == true"),object:button)
        XCTAssertEqual(XCTWaiter.wait(for:[expectation],timeout:30),.completed,file:file,line:line)
    }
    /// A finished Word, Excel or PowerPoint file opens full screen; close it to continue.
    @MainActor private func closePreview(_ app:XCUIApplication,file:StaticString = #filePath,line:UInt = #line) {
        let done = app.buttons["office-preview-done"]
        XCTAssertTrue(done.waitForExistence(timeout:90),"The finished file opens at full size",file:file,line:line)
        let shot = XCTAttachment(screenshot:app.screenshot());shot.name = "Office full-size preview";shot.lifetime = .keepAlways;add(shot)
        done.tap()
    }
    @MainActor private func launch(document:Bool = false,table:Bool = false) -> XCUIApplication {
        let app = XCUIApplication();app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en"]+(document ? ["--seed-saved"] : [])+(table ? ["--seed-office-table"] : []);app.launch()
        if document { app.buttons["nav-documents"].tap();app.staticTexts["Test document"].tap();XCTAssertTrue(app.buttons["Share PDF"].waitForExistence(timeout:5));app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier IN %@)", "Tools", ["nav-tools", "home-tools"])).firstMatch.tap();app.buttons["More offline tools"].tap();XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout:5)) }
        else { XCTAssertTrue(app.buttons["home-tools"].isHittable);app.buttons["home-tools"].tap() }
        return app
    }
    @MainActor func testProToolFreeTriesThenUpgrade() {
        let session = UUID().uuidString
        func open() -> XCUIApplication {
            let app = XCUIApplication();app.launchArguments = ["--ui-test-session",session,"-app-language","en","--test-pro-gate"];app.launch()
            app.buttons["home-tools"].tap();XCTAssertTrue(app.tool("Word export").waitForExistence(timeout:5));app.tool("Word export").tap()
            return app
        }
        // From the Tools tab a free user gets the free-try screen, not the paywall; Try free is the main button.
        var app = open()
        let tryFree = app.buttons["pro-try-free"]
        XCTAssertTrue(tryFree.waitForExistence(timeout:5));XCTAssertTrue(tryFree.label.contains("3 left"))
        XCTAssertFalse(app.buttons["subscribe-button"].exists)
        let lock = XCTAttachment(screenshot:app.screenshot());lock.name = "Pro tool free try";lock.lifetime = .keepAlways;add(lock)
        tryFree.tap()
        XCTAssertFalse(app.buttons["pro-try-free"].waitForExistence(timeout:2))
        XCTAssertFalse(app.staticTexts["pro-trial-status"].exists)
        app.terminate()
        // Leaving without making anything does not spend the try.
        app = open()
        XCTAssertTrue(app.buttons["pro-try-free"].waitForExistence(timeout:5));XCTAssertTrue(app.buttons["pro-try-free"].label.contains("3 left"))
        app.buttons["pro-upgrade"].tap()
        XCTAssertTrue(app.buttons["subscribe-button"].waitForExistence(timeout:10) || app.buttons["Reload plans"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Word · Excel · PowerPoint"].exists,"The paywall opens on the tapped tool's slide")
        XCTAssertFalse(app.staticTexts["Text from any page"].exists,"Text recognition is free and never sold as Pro")
        let pay = XCTAttachment(screenshot:app.screenshot());pay.name = "Paywall from tool";pay.lifetime = .keepAlways;add(pay)
    }
    @MainActor func testPDFProToolShowsFreeTryBeforeChoosingADocument() {
        let app = XCUIApplication();app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en","--test-pro-gate","--seed-saved"];app.launch()
        app.buttons["home-tools"].tap()
        let compress = app.buttons["Compress PDF, Pro"]
        for _ in 0..<8 where !compress.isHittable { app.swipeUp() }
        compress.tap()
        let tryFree = app.buttons["pro-try-free"]
        XCTAssertTrue(tryFree.waitForExistence(timeout:5));XCTAssertTrue(tryFree.label.contains("3 left"))
        XCTAssertFalse(app.buttons["pdf-import"].exists,"No document choice before the free-try screen")
        app.buttons["pro-upgrade"].tap()
        XCTAssertTrue(app.buttons["subscribe-button"].waitForExistence(timeout:10) || app.buttons["Reload plans"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Lock & compress PDFs"].exists,"Paywall from Compress starts on its slide")
        let shot = XCTAttachment(screenshot:app.screenshot());shot.name = "Paywall from Compress PDF";shot.lifetime = .keepAlways;add(shot)
    }
    @MainActor func testHubListsAllToolsAndHonestDeviceRequirements() {
        for populated in [false,true] {
            let home = XCUIApplication();home.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en"]+(populated ? ["--seed-saved"] : []);home.launch()
            let entry = home.buttons["home-tools"]
            XCTAssertTrue(entry.waitForExistence(timeout:5));XCTAssertTrue(entry.isHittable,"Tools must be visible without scrolling or opening a menu")
            let screenshot = XCTAttachment(screenshot:home.screenshot());screenshot.name = populated ? "Home tools with documents" : "Home tools empty library";screenshot.lifetime = .keepAlways;add(screenshot)
            entry.tap();XCTAssertTrue(home.textFields["tool-search"].waitForExistence(timeout:5));XCTAssertTrue(home.tool("Word export").exists);XCTAssertTrue(home.tool("QR code").exists)
            home.buttons["Close"].tap();XCTAssertTrue(home.buttons["home-tools"].isHittable);home.terminate()
        }
        let app = launch()
        // In page order: Fix a page, Turn it into, Capture more.
        for label in ["Spot eraser","Remove colored marks","Restore photo","Book pages","Word export","Excel export","PowerPoint export","Photo translation","Math scan","ID photo","Mega scan"] {
            XCTAssertTrue(app.tool(label).exists,"Missing \(label)")
        }
        // Count objects stays hidden. Measure and 3D scan appear only where the device has
        // AR and LiDAR, so the simulator never offers a tool it cannot run.
        XCTAssertFalse(app.buttons["Count objects"].exists)
        let shot = XCTAttachment(screenshot:app.screenshot());shot.name = "Tools sections";shot.lifetime = .keepAlways;add(shot)
    }
    @MainActor func testLocalMathAndEditableWordExport() {
        let app = launch();app.tool("Math scan").tap()
        XCTAssertTrue(app.buttons["text-tool-capture"].waitForExistence(timeout:5))
        app.buttons["text-tool-more"].tap();app.buttons["Type expression"].tap()
        let editor = app.textViews["offline-text"]
        for _ in 0..<4 where !editor.isHittable { app.swipeUp() }
        editor.tap();editor.typeText("sqrt(81)+2^3")
        app.buttons["offline-run"].tap()
        XCTAssertTrue(app.staticTexts["17"].waitForExistence(timeout:5))
        app.buttons["Close"].tap()
        for _ in 0..<6 where !app.buttons["Word export"].isHittable { app.swipeDown() }
        app.tool("Word export").tap()
        XCTAssertFalse(app.buttons["offline-run"].exists)
        XCTAssertFalse(app.buttons["word-extract"].isEnabled)
        app.swipeUp()
        app.buttons["word-type-text"].tap()
        XCTAssertFalse(app.buttons["offline-run"].isEnabled)
        editor.tap();editor.typeText("Local document\nOffline export example")
        app.buttons["offline-run"].tap();closePreview(app);ready(app.buttons["word-share"])
        XCTAssertFalse(app.buttons["offline-run"].exists)
        app.buttons["word-preview"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout:10))
        let shot = XCTAttachment(screenshot:app.screenshot());shot.name = "DOCX Quick Look";shot.lifetime = .keepAlways;add(shot)
    }
    @MainActor func testCameraFirstMathRecognizesReviewsAndReturnsWithoutSaving() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en","--simulate-camera"]
        app.launch();app.buttons["home-tools"].tap();app.tool("Math scan").tap()
        XCTAssertTrue(app.buttons["text-tool-capture"].waitForExistence(timeout:5))
        XCTAssertFalse(app.textViews["offline-text"].exists)
        XCTAssertFalse(app.buttons["offline-run"].exists)
        saveShot(app,"math-camera-first")
        app.buttons["text-tool-capture"].tap()
        XCTAssertTrue(app.buttons["math-scan-preview"].waitForExistence(timeout:40))
        XCTAssertFalse(app.textViews["math-text"].exists)
        saveShot(app,"math-corrected-scan")
        app.buttons["math-primary"].tap()
        let editor = app.textViews["math-text"]
        XCTAssertTrue(editor.waitForExistence(timeout:60))
        let recognized = editor.value as? String ?? ""
        XCTAssertTrue(recognized.contains("12"),recognized)
        XCTAssertTrue(recognized.contains("45"),"All recognized lines must survive: \(recognized)")
        XCTAssertTrue(app.buttons["math-primary"].isEnabled)
        saveShot(app,"math-review-all-lines")
        app.buttons["math-primary"].tap()
        for name in ["txt","docx","pdf","rtf","html"] { XCTAssertTrue(app.buttons["math-format-"+name].exists) }
        app.buttons["math-format-pdf"].tap()
        saveShot(app,"math-export-formats")
        app.buttons["math-primary"].tap()
        XCTAssertTrue(app.buttons["math-preview-file"].waitForExistence(timeout:20))
        app.buttons["math-preview-file"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout:15))
        saveShot(app,"math-pdf-preview")
        app.navigationBars.buttons["Done"].tap()
        app.buttons["math-primary"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout:15))
        saveShot(app,"math-share-document")
        app.buttons["header.closeButton"].tap()
        ready(app.buttons["math-another"])
        app.buttons["math-another"].tap()
        XCTAssertTrue(app.buttons["text-tool-capture"].waitForExistence(timeout:5))
        app.buttons["text-tool-capture"].tap()
        XCTAssertTrue(app.buttons["math-scan-preview"].waitForExistence(timeout:40))
        app.buttons["math-back"].tap()
        XCTAssertTrue(app.buttons["text-tool-capture"].waitForExistence(timeout:5))
        app.buttons["text-tool-close"].tap();app.buttons["Close"].tap()
        app.buttons["nav-documents"].tap()
        XCTAssertTrue(app.staticTexts["Paperwork, simplified"].waitForExistence(timeout:5))
    }
    @MainActor func testCameraFirstTranslationKeepsReviewAndLanguageSetupSeparate() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en","--simulate-camera"]
        app.launch();app.buttons["home-tools"].tap();app.tool("Photo translation").tap()
        XCTAssertTrue(app.buttons["text-tool-capture"].waitForExistence(timeout:5))
        XCTAssertFalse(app.textViews["offline-text"].exists)
        app.buttons["text-tool-capture"].tap()
        XCTAssertTrue(app.buttons["translation-document-preview"].waitForExistence(timeout:45))
        XCTAssertFalse(app.textViews["offline-text"].exists)
        XCTAssertTrue(app.buttons["translation-run"].exists)
        saveShot(app,"photo-translation-corrected-scan")
        app.buttons["translation-run"].tap()
        let settled = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            app.buttons["translation-share"].exists || app.staticTexts["text-tool-error"].exists
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[settled],timeout:30),.completed)
        if app.staticTexts["text-tool-error"].exists {
            XCTAssertTrue(app.buttons["translation-document-preview"].exists)
            XCTAssertTrue(app.buttons["translation-run"].exists)
        }
        saveShot(app,"photo-translation-availability")
    }
    @MainActor func testPhotoTranslationManualCorrectionRebuildsPageAndSharesPDF() {
        let app = XCUIApplication();app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en","--simulate-camera"]
        app.launch();app.buttons["home-tools"].tap();app.tool("Photo translation").tap()
        app.buttons["text-tool-capture"].tap()
        XCTAssertTrue(app.buttons["translation-edit-areas"].waitForExistence(timeout:45))
        for _ in 0..<3 where !app.buttons["translation-edit-areas"].isHittable { app.swipeUp() }
        app.buttons["translation-edit-areas"].tap()
        let source = app.textViews["translation-source-text"]
        XCTAssertTrue(source.waitForExistence(timeout:5))
        XCTAssertTrue((source.value as? String ?? "").contains("Welcome"))
        let target = app.textViews["translation-target-text"]
        target.tap();target.typeText("Bienvenue")
        app.buttons["translation-apply-areas"].tap()
        app.buttons["translation-run"].tap()
        XCTAssertTrue(app.buttons["translation-share"].waitForExistence(timeout:20))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH '1 text area replaced'")).firstMatch.exists)
        saveShot(app,"photo-translation-layout-preview")
        app.buttons["translation-share"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout:15))
        saveShot(app,"photo-translation-pdf-share")
    }
    @MainActor func testPhotoTranslationUnplacedTextCanBeReviewedAndCopied() {
        let app = XCUIApplication();app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en","--simulate-camera"]
        app.launch();app.buttons["home-tools"].tap();app.tool("Photo translation").tap()
        app.buttons["text-tool-capture"].tap()
        XCTAssertTrue(app.buttons["translation-edit-areas"].waitForExistence(timeout:45))
        app.buttons["translation-edit-areas"].tap()
        let target = app.textViews["translation-target-text"]
        XCTAssertTrue(target.waitForExistence(timeout:5));target.tap()
        let value = String(repeating:"A translated sentence that needs much more space. ",count:10)
        target.typeText(value)
        app.buttons["translation-apply-areas"].tap();app.buttons["translation-run"].tap()
        XCTAssertTrue(app.buttons["translation-share"].waitForExistence(timeout:20))
        let review = app.buttons["translation-review-issues"]
        for _ in 0..<6 where !review.isHittable || review.frame.maxY > app.buttons["translation-share"].frame.minY { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["translation-partial"].exists)
        review.tap()
        XCTAssertEqual(app.switches["translation-issues-filter"].value as? String,"1")
        XCTAssertEqual(app.textViews["translation-target-text"].value as? String,value)
        let copy = app.buttons["translation-copy-area"]
        for _ in 0..<5 where !copy.isHittable { app.swipeUp() }
        XCTAssertTrue(copy.isEnabled);copy.tap()
        saveShot(app,"photo-translation-unplaced-text-review")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["translation-share"].exists)
    }
    @MainActor private func saveShot(_ app:XCUIApplication,_ name:String) {
        let attachment = XCTAttachment(screenshot:app.screenshot())
        attachment.name = name;attachment.lifetime = .keepAlways;add(attachment)
    }
    @MainActor func testEditingTextInvalidatesPreparedOfficeFile() {
        let app = launch();app.tool("Word export").tap()
        app.swipeUp()
        app.buttons["word-type-text"].tap()
        let editor = app.textViews["offline-text"]
        editor.tap();editor.typeText("First version")
        app.buttons["offline-run"].tap();closePreview(app);ready(app.buttons["word-share"])
        app.buttons["word-step-back"].tap()
        XCTAssertFalse(app.buttons["word-share"].exists)
        XCTAssertFalse(app.buttons["word-preview"].exists)
        XCTAssertTrue((editor.value as? String ?? "").contains("First version"))
        editor.tap();editor.typeText(" revised")
        app.buttons["offline-run"].tap();closePreview(app);ready(app.buttons["word-share"])
    }
    @MainActor func testWordCameraShowsEachPageBeforeContinuing() {
        let app = XCUIApplication();app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en","--simulate-camera"];app.launch()
        app.buttons["home-tools"].tap();ready(app.tool("Word export"));app.tool("Word export").tap()
        ready(app.buttons["word-camera"]);app.buttons["word-camera"].tap()
        // Each shot is shown for checking before scanning more or continuing.
        ready(app.buttons["Capture page"]);app.buttons["Capture page"].tap()
        ready(app.buttons["review-add-page"]);XCTAssertTrue(app.buttons["review-done"].exists)
        XCTAssertEqual(app.buttons["review-done"].label,"Continue")
        let check = XCTAttachment(screenshot:app.screenshot());check.name = "Office scan page check";check.lifetime = .keepAlways;add(check)
        app.buttons["review-add-page"].tap()
        ready(app.buttons["Capture page"]);app.buttons["Capture page"].tap()
        ready(app.buttons["review-done"]);app.buttons["review-done"].tap()
        ready(app.buttons["word-extract"])
        XCTAssertFalse(app.buttons["Capture page"].exists)
    }
    @MainActor func testWordPDFExportHasOnePrimaryActionPerStep() {
        let app = launch(document:true);app.tool("Word export").tap()
        ready(app.buttons["word-extract"])
        XCTAssertTrue(app.buttons["word-input-preview"].exists)
        XCTAssertTrue(app.buttons["word-camera"].exists)
        XCTAssertTrue(app.buttons["word-photo"].exists)
        XCTAssertTrue(app.buttons["word-file"].exists)
        XCTAssertFalse(app.buttons["offline-run"].exists)
        XCTAssertFalse(app.textViews["offline-text"].exists)
        XCTAssertFalse(app.buttons["Create Office file"].exists)
        func shot(_ name:String) {
            let attachment = XCTAttachment(screenshot:app.screenshot())
            attachment.name = name;attachment.lifetime = .keepAlways;add(attachment)
        }
        shot("Word 1 choose input")
        app.buttons["word-extract"].tap()
        ready(app.buttons["offline-run"])
        XCTAssertFalse(app.buttons["word-extract"].exists)
        let line = app.descendants(matching:.any).matching(NSPredicate(format:"identifier BEGINSWITH 'word-line-'")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout:5))
        XCTAssertTrue((line.value as? String ?? "").contains("SCANNER TEST PAGE"))
        shot("Word 2 review text")
        app.buttons["word-step-back"].tap()
        ready(app.buttons["word-extract"])
        XCTAssertFalse(app.buttons["offline-run"].exists)
        app.buttons["word-extract"].tap();ready(app.buttons["offline-run"])
        app.buttons["offline-run"].tap();closePreview(app);ready(app.buttons["word-share"])
        XCTAssertFalse(app.buttons["word-extract"].exists)
        XCTAssertFalse(app.buttons["offline-run"].exists)
        XCTAssertFalse(app.textViews["offline-text"].exists)
        shot("Word 3 ready to share")
        app.buttons["word-share"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout:10))
        XCTAssertTrue(app.cells["Save to Files"].exists)
    }
    @MainActor func testWordReviewShowsTablesWithEditableCells() {
        let app = launch(document:true,table:true);app.tool("Word export").tap()
        ready(app.buttons["word-extract"]);app.buttons["word-extract"].tap();ready(app.buttons["offline-run"])
        let header = app.buttons["word-cell-0-0"]
        XCTAssertTrue(header.waitForExistence(timeout:5),"Tables are shown as tables")
        XCTAssertTrue(header.label.contains("Product"))
        let shot = XCTAttachment(screenshot:app.screenshot());shot.name = "Word review table";shot.lifetime = .keepAlways;add(shot)
        let cell = app.buttons["word-cell-1-1"];XCTAssertTrue(cell.label.contains("12"))
        cell.tap()
        let value = app.textViews["word-cell-value"];XCTAssertTrue(value.waitForExistence(timeout:5))
        value.tap();value.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:6)+"15")
        app.buttons["word-cell-save"].tap()
        XCTAssertTrue(app.buttons["word-cell-1-1"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["word-cell-1-1"].label.contains("15"),"The corrected cell keeps its place")
        app.buttons["word-plain-text"].tap()
        XCTAssertTrue((app.textViews["offline-text"].value as? String ?? "").contains("Paper\t15"))
        app.buttons["word-plain-text"].tap()
        XCTAssertTrue(app.buttons["word-cell-1-1"].waitForExistence(timeout:5))
        app.buttons["offline-run"].tap();closePreview(app);ready(app.buttons["word-share"])
    }
    @MainActor func testPowerPointMultiplePagesOrderRemovalAndExport() {
        let app = launch(document:true);app.tool("PowerPoint export").tap()
        ready(app.buttons["office-continue"])
        XCTAssertTrue(app.staticTexts["ppt-source-1"].label.contains("Page 1"))
        XCTAssertTrue(app.staticTexts["ppt-source-2"].label.contains("Page 2"))
        XCTAssertFalse(app.buttons["Read text from input"].exists)
        app.buttons["ppt-options-2"].tap();app.buttons["Move earlier"].tap()
        XCTAssertTrue(app.staticTexts["ppt-source-1"].label.contains("Page 2"))
        let selected = XCTAttachment(screenshot:app.screenshot());selected.name = "PowerPoint selected pages";selected.lifetime = .keepAlways;add(selected)
        app.buttons["ppt-options-1"].tap();app.buttons["Remove slide"].tap()
        XCTAssertFalse(app.staticTexts["ppt-source-2"].exists)
        app.buttons["office-continue"].tap();app.buttons["ppt-create"].tap();closePreview(app);ready(app.buttons["ppt-share"])
        XCTAssertTrue(app.staticTexts["1 slide ready"].exists)
        app.buttons["ppt-preview"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout:10))
        app.navigationBars.buttons["Done"].tap()
        app.buttons["ppt-edit"].tap();app.buttons["ppt-edit"].tap()
        XCTAssertFalse(app.buttons["ppt-share"].exists)
        app.buttons["ppt-library"].tap()
        app.buttons["ppt-library-page-2"].tap();app.buttons["ppt-add-pages"].tap()
        ready(app.buttons["office-continue"])
        XCTAssertTrue(app.staticTexts["ppt-source-2"].label.contains("Page 2"))
        app.buttons["office-continue"].tap();app.buttons["ppt-create"].tap();closePreview(app);ready(app.buttons["ppt-share"])
        let result = XCTAttachment(screenshot:app.screenshot());result.name = "PowerPoint ready";result.lifetime = .keepAlways;add(result)
        app.buttons["ppt-share"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout:10))
        XCTAssertTrue(app.cells["Save to Files"].exists)
    }
    @MainActor func testPowerPointEmptySelectionAndMultiPagePicker() {
        let app = launch(document:true);app.tool("PowerPoint export").tap()
        ready(app.buttons["office-continue"])
        for _ in 0..<2 { app.buttons["ppt-options-1"].tap();app.buttons["Remove slide"].tap() }
        XCTAssertFalse(app.buttons["office-continue"].isEnabled)
        app.buttons["ppt-library"].tap()
        XCTAssertFalse(app.buttons["ppt-add-pages"].isEnabled)
        app.buttons["ppt-library-page-2"].tap();app.buttons["ppt-library-page-1"].tap()
        let selected = XCTAttachment(screenshot:app.screenshot());selected.name = "PowerPoint select multiple pages";selected.lifetime = .keepAlways;add(selected)
        app.buttons["ppt-add-pages"].tap();ready(app.buttons["office-continue"])
        XCTAssertTrue(app.staticTexts["ppt-source-1"].label.contains("Page 2"))
        XCTAssertTrue(app.staticTexts["ppt-source-2"].label.contains("Page 1"))
    }
    @MainActor func testExcelReviewCellsBeforeExport() {
        let app = launch(document:true,table:true);app.tool("Excel export").tap()
        ready(app.buttons["office-continue"])
        XCTAssertFalse(app.buttons["ppt-create"].exists)
        app.buttons["office-continue"].tap()
        let cell = app.buttons["excel-cell-0-0"]
        XCTAssertTrue(cell.waitForExistence(timeout:60))
        cell.tap()
        let editor = app.textViews["excel-cell-value"]
        XCTAssertTrue(editor.waitForExistence(timeout:5))
        editor.tap();editor.typeText(" corrected")
        app.buttons["excel-cell-save"].tap()
        XCTAssertTrue(cell.label.contains("corrected"))
        let shot = XCTAttachment(screenshot:app.screenshot());shot.name = "Excel review cells";shot.lifetime = .keepAlways;add(shot)
        app.buttons["ppt-create"].tap();closePreview(app);ready(app.buttons["ppt-share"])
        app.buttons["ppt-preview"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout:15))
        _ = app.staticTexts.containing(NSPredicate(format:"label CONTAINS[c] %@","Paper")).firstMatch.waitForExistence(timeout:15)
        let preview = XCTAttachment(screenshot:app.screenshot());preview.name = "Excel Quick Look";preview.lifetime = .keepAlways;add(preview)
        app.navigationBars.buttons["Done"].tap();app.buttons["ppt-edit"].tap()
        XCTAssertTrue(cell.label.contains("corrected"))
        XCTAssertFalse(app.buttons["ppt-share"].exists)
    }
    @MainActor func testPowerPointEditableTextSteps() {
        let app = launch(document:true);app.tool("PowerPoint export").tap()
        app.buttons["office-continue"].tap()
        XCTAssertFalse(app.buttons["ppt-photos"].exists)
        app.buttons["ppt-mode-text"].tap();app.buttons["office-extract"].tap()
        XCTAssertTrue(app.textViews["ppt-text-1"].waitForExistence(timeout:60))
        XCTAssertTrue((app.textViews["ppt-text-1"].value as? String ?? "").contains("SCANNER TEST PAGE"))
        app.buttons["ppt-create"].tap();closePreview(app);ready(app.buttons["ppt-share"])
        app.buttons["ppt-preview"].tap()
        XCTAssertTrue(app.navigationBars.buttons["Done"].waitForExistence(timeout:15))
        _ = app.staticTexts.containing(NSPredicate(format:"label CONTAINS[c] %@","SCANNER TEST PAGE")).firstMatch.waitForExistence(timeout:15)
        let shot = XCTAttachment(screenshot:app.screenshot());shot.name = "PowerPoint editable Quick Look";shot.lifetime = .keepAlways;add(shot)
    }
    @MainActor func testBookOnePageOrTwoPagesFromDocument() {
        let app = launch(document:true);let book = app.buttons["Book pages"]
        for _ in 0..<6 where !book.isHittable { app.swipeUp() }
        book.tap();ready(app.buttons["source-current"]);app.buttons["source-current"].tap()
        // The test document has two pages: pick the first.
        ready(app.buttons["page-cell-1"]);app.buttons["page-cell-1"].tap()
        ready(app.buttons["book-next"])
        app.buttons["book-one"].tap();app.buttons["book-next"].tap()
        XCTAssertTrue(app.images["book-page-1"].waitForExistence(timeout:30))
        XCTAssertFalse(app.pageIndicators.firstMatch.exists,"One page has no page dots")
        app.buttons["tool-back"].tap();ready(app.buttons["book-two"])
        app.buttons["book-two"].tap();app.buttons["book-next"].tap()
        XCTAssertTrue(app.images["book-page-1"].waitForExistence(timeout:30))
        XCTAssertTrue(app.pageIndicators.firstMatch.exists,"Two pages show page dots")
        XCTAssertTrue(app.sliders["Flatten curve"].exists)
    }
    @MainActor func testBookPagesSavedFromDocument() {
        let app = launch(document:true);let book = app.buttons["Book pages"]
        for _ in 0..<6 where !book.isHittable { app.swipeUp() }
        book.tap();ready(app.buttons["source-current"]);app.buttons["source-current"].tap()
        ready(app.buttons["page-cell-1"]);app.buttons["page-cell-1"].tap()
        ready(app.buttons["book-next"]);app.buttons["book-next"].tap()
        ready(app.buttons["book-save"])
        let shot = XCTAttachment(screenshot:app.screenshot());shot.name = "Book split preview";shot.lifetime = .keepAlways;add(shot)
        app.buttons["book-save"].tap()
        XCTAssertTrue(app.staticTexts["tool-done-title"].waitForExistence(timeout:60))
        app.buttons["tool-done-primary"].tap()
        // Back in the tools hub; the pages are saved as a new document.
        XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout:10))
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Book pages"].waitForExistence(timeout:10) || app.buttons["Share PDF"].exists)
    }

    /// Writes screenshots of the redesigned tool pages to Verification/private/design-shots on the developer Mac.
    @MainActor private func designShot(_ app:XCUIApplication,_ name:String) {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return }
        let folder = URL(fileURLWithPath:home).appendingPathComponent("Documents/ChatGPT/정치 중립/scanner-product/ios/Verification/private/design-shots")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        sleep(1)
        try? app.screenshot().pngRepresentation.write(to:folder.appendingPathComponent(name+".png"))
    }
    @MainActor func testDesignSystemScreens() throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] != nil else { throw XCTSkip("Developer Mac only.") }
        // Word: source, review, ready.
        var app = launch(document:true);app.tool("Word export").tap()
        ready(app.buttons["word-extract"]);designShot(app,"word-1-source")
        app.buttons["word-extract"].tap();ready(app.buttons["offline-run"]);designShot(app,"word-2-review")
        app.buttons["offline-run"].tap();closePreview(app);ready(app.buttons["word-share"]);designShot(app,"word-3-ready")
        app.terminate()
        // PowerPoint: pages, look, ready.
        app = launch(document:true);app.tool("PowerPoint export").tap()
        ready(app.buttons["office-continue"]);designShot(app,"ppt-1-pages")
        app.buttons["office-continue"].tap();ready(app.buttons["ppt-create"]);designShot(app,"ppt-2-look")
        app.buttons["ppt-create"].tap();closePreview(app);ready(app.buttons["ppt-share"]);designShot(app,"ppt-3-ready")
        app.terminate()
        // Excel: check cells.
        app = launch(document:true,table:true);app.tool("Excel export").tap()
        ready(app.buttons["office-continue"]);app.buttons["office-continue"].tap()
        XCTAssertTrue(app.buttons["excel-cell-0-0"].waitForExistence(timeout:60));designShot(app,"excel-2-review")
        app.terminate()
        // Photo translation: camera, language, result.
        app = XCUIApplication();app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en","--simulate-camera"]
        app.launch();app.buttons["home-tools"].tap();app.tool("Photo translation").tap()
        XCTAssertTrue(app.buttons["text-tool-capture"].waitForExistence(timeout:5));designShot(app,"translate-0-camera")
        app.buttons["text-tool-capture"].tap()
        XCTAssertTrue(app.buttons["translation-run"].waitForExistence(timeout:45));designShot(app,"translate-1-language")
        app.buttons["translation-edit-areas"].tap()
        let target = app.textViews["translation-target-text"]
        if target.waitForExistence(timeout:5) { target.tap();target.typeText("Bienvenue");app.buttons["translation-apply-areas"].tap() }
        app.buttons["translation-run"].tap()
        if app.buttons["translation-share"].waitForExistence(timeout:30) { designShot(app,"translate-2-result") }
        app.terminate()
        // Math: corrected scan and text.
        app = XCUIApplication();app.launchArguments = ["--ui-test-session",UUID().uuidString,"-app-language","en","--simulate-camera"]
        app.launch();app.buttons["home-tools"].tap();app.tool("Math scan").tap()
        XCTAssertTrue(app.buttons["text-tool-capture"].waitForExistence(timeout:5));app.buttons["text-tool-capture"].tap()
        XCTAssertTrue(app.buttons["math-scan-preview"].waitForExistence(timeout:40));designShot(app,"math-1-scan")
        app.buttons["math-primary"].tap()
        XCTAssertTrue(app.textViews["math-text"].waitForExistence(timeout:60));designShot(app,"math-2-text")
        app.buttons["math-primary"].tap();designShot(app,"math-3-format")
        app.terminate()
    }
}

extension XCUIApplication {
    /// A tile on the Tools page, scrolled into view (sections run below the fold).
    @MainActor func tool(_ label: String) -> XCUIElement {
        let button = buttons[label]
        _ = button.waitForExistence(timeout: 2)
        for _ in 0..<8 where !(button.exists && button.isHittable) { swipeUp() }
        return button
    }
}
