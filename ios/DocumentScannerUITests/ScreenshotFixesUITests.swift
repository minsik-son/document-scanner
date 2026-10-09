import XCTest

/// Screens checked after the store-screenshot fixes (2026-10-08). PNGs go to
/// Verification/private/review-shots/fixes (git-ignored). Sample photos are fictional.
final class ScreenshotFixesUITests: XCTestCase {
    private static let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let shots = ios.appendingPathComponent("Verification/private/review-shots/fixes")
    private static func sample(_ name: String) -> String {
        ios.deletingLastPathComponent().appendingPathComponent("마케팅 리포트/store-screenshots/samples/\(name).jpg").path
    }
    override func setUp() { continueAfterFailure = true }

    @MainActor private func save(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let a = XCTAttachment(screenshot: shot); a.name = name; a.lifetime = .keepAlways; add(a)
        try? FileManager.default.createDirectory(at: Self.shots, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: Self.shots.appendingPathComponent(name + ".png"))
    }
    @MainActor private func launch(_ language: String, seeds: [String] = [], camera: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["--ui-test-session", UUID().uuidString, "-app-language", language]
        for s in seeds { args += ["--seed-image", Self.sample(s)] }
        if let camera { args += ["--simulate-camera", "--camera-sample", Self.sample(camera)] }
        app.launchArguments = args
        app.launch()
        if app.buttons["onboarding-skip"].waitForExistence(timeout: 6) { app.buttons["onboarding-skip"].tap() }
        if app.buttons["onboarding-later"].waitForExistence(timeout: 3) { app.buttons["onboarding-later"].tap() }
        XCTAssertTrue(app.buttons["nav-tools"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor private func openTool(_ app: XCUIApplication, _ prefix: String) {
        app.buttons["nav-tools"].tap()
        XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout: 5))
        let tile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        _ = tile.waitForExistence(timeout: 3)
        for _ in 0..<8 where !(tile.exists && tile.isHittable) { app.swipeUp() }
        tile.tap()
        if app.buttons["pro-try-free"].waitForExistence(timeout: 4) { app.buttons["pro-try-free"].tap() }
    }
    @MainActor private func chooseDocument(_ app: XCUIApplication, _ title: String) {
        let doc = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(doc.waitForExistence(timeout: 20), "Seeded document \(title) not listed")
        for _ in 0..<4 where !doc.isHittable { app.swipeUp() }
        doc.tap()
    }

    /// A1/A4: boxes on the sample form in English, then the saved copy.
    @MainActor func testRedactSampleForm() {
        let app = launch("en", seeds: ["photo_form"])
        openTool(app, "Hide personal info")
        chooseDocument(app, "photo_form")
        XCTAssertTrue(app.buttons["redact-save"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'items to hide'")).firstMatch.exists)
        save(app, "en-redact-preview")
        app.buttons["redact-save"].tap()
        XCTAssertTrue(app.staticTexts["Personal info hidden"].waitForExistence(timeout: 60))
        save(app, "en-redact-saved")
    }

    /// B1: the French letter is detected as French.
    @MainActor func testTranslationDetectsFrench() {
        let app = launch("en", camera: "photo_letter_fr")
        openTool(app, "Photo translation")
        XCTAssertTrue(app.buttons["text-tool-capture"].waitForExistence(timeout: 10))
        app.buttons["text-tool-capture"].tap()
        let source = app.staticTexts["translation-source-name"]
        XCTAssertTrue(source.waitForExistence(timeout: 60))
        XCTAssertEqual(source.label, "French")
        save(app, "en-translation-languages")
    }

    /// C: Korean screens, with no English left on them.
    @MainActor func testKoreanScreens() {
        let app = launch("ko", seeds: ["photo_invoice", "photo_lease", "photo_form"], camera: "photo_letter_fr")
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'photo_'")).firstMatch.waitForExistence(timeout: 30)
        sleep(2)
        save(app, "ko-home"); assertNoEnglish(app, "home")
        app.buttons["nav-documents"].tap(); sleep(1)
        save(app, "ko-documents"); assertNoEnglish(app, "documents")
        app.buttons["nav-home"].tap()
        openTool(app, "사진 번역")
        XCTAssertTrue(app.buttons["text-tool-capture"].waitForExistence(timeout: 10))
        app.buttons["text-tool-capture"].tap()
        XCTAssertTrue(app.staticTexts["translation-source-name"].waitForExistence(timeout: 60))
        XCTAssertEqual(app.staticTexts["translation-source-name"].label, "프랑스어")
        save(app, "ko-translation-languages"); assertNoEnglish(app, "translation")
        app.terminate()
        let again = launch("ko", seeds: ["photo_invoice"])
        openTool(again, "PDF 압축")
        chooseDocument(again, "photo_invoice")
        if again.buttons["compress-run"].waitForExistence(timeout: 20) {
            save(again, "ko-compress-options"); assertNoEnglish(again, "compress options")
            again.buttons["compress-run"].tap()
            XCTAssertTrue(again.otherElements["compress-result"].waitForExistence(timeout: 60) || again.staticTexts.matching(NSPredicate(format: "label CONTAINS '%'")).firstMatch.waitForExistence(timeout: 5))
            save(again, "ko-compress-result"); assertNoEnglish(again, "compress result")
        } else { XCTFail("Compress options not shown") }
    }

    /// E1: the lifetime plan shows the founding ribbon ending Dec 17.
    @MainActor func testPaywallFoundingRibbon() {
        for language in ["en", "ko"] {
            let app = launch(language)
            app.buttons["home-pro"].tap()
            let ribbon = app.staticTexts["founding-price"]
            if !ribbon.waitForExistence(timeout: 15) {
                for _ in 0..<3 where !ribbon.exists { app.swipeUp() }
            }
            XCTAssertTrue(ribbon.exists, "No founding ribbon (\(language))")
            if language == "en" { XCTAssertTrue(ribbon.label.contains("ENDS DEC 17"), ribbon.label) }
            else { XCTAssertTrue(ribbon.label.contains("12월 17일"), ribbon.label) }
            // Scroll the plans (below the carousel) until the lifetime card shows.
            let window = app.windows.firstMatch
            let cta = app.buttons["subscribe-button"]
            for _ in 0..<5 where !cta.exists || ribbon.frame.maxY > cta.frame.minY - 160 {
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            }
            if language != "en" { assertNoEnglish(app, "\(language) paywall") }
            save(app, "\(language)-paywall-founding")
            app.terminate()
        }
    }

    /// C: the same check on Home, Documents and Tools in the other 13 languages.
    @MainActor func testOtherLanguagesHaveNoEnglish() {
        for language in ["ja", "es", "pt-BR", "de", "fr", "it", "pl", "tr", "id", "vi", "th", "zh-Hans", "zh-Hant"] {
            let app = launch(language, seeds: ["photo_form"])
            _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'photo_'")).firstMatch.waitForExistence(timeout: 30)
            assertNoEnglish(app, "\(language) home")
            app.buttons["nav-documents"].tap(); sleep(1)
            assertNoEnglish(app, "\(language) documents")
            app.buttons["nav-tools"].tap(); _ = app.textFields["tool-search"].waitForExistence(timeout: 5)
            assertNoEnglish(app, "\(language) tools")
            save(app, "\(language)-tools")
            app.terminate()
        }
    }

    /// Flags visible text that is still the English source of a string this
    /// language translates differently ("Documents" where Korean has "문서").
    /// Each label is checked whole and in its " · " / ", " parts.
    @MainActor private func assertNoEnglish(_ app: XCUIApplication, _ screen: String) {
        let language = app.launchArguments[app.launchArguments.firstIndex(of: "-app-language")! + 1]
        let path = Self.ios.appendingPathComponent("DocumentScanner/\(language).lproj/Localizable.strings").path
        let table = (NSDictionary(contentsOfFile: path) as? [String: String]) ?? [:]
        XCTAssertFalse(table.isEmpty, "No strings for \(language)")
        var hits: [String] = []
        let elements = app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex
        for e in elements where e.exists && e.isHittable {
            let label = e.label
            let parts = [label] + label.components(separatedBy: " · ") + label.components(separatedBy: ", ")
            for part in parts {
                let t = part.trimmingCharacters(in: .whitespaces)
                if let translated = table[t], translated != t { hits.append(t); break }
            }
            // Korean never uses these English words; catches strings with no key at all.
            if language == "ko" {
                let words: Set<String> = ["the", "and", "your", "documents", "document", "folders", "recent", "receipts", "contracts", "forms", "pages", "page", "now", "saved", "translate", "from", "close", "cancel", "done", "tools", "home", "search", "import", "choose", "language", "english", "korean", "french", "oct", "am", "pm"]
                let latin = label.replacingOccurrences(of: #"photo_\w+"#, with: "", options: .regularExpression)
                    .lowercased().split { !$0.isLetter || !$0.isASCII }.map(String.init)
                if latin.contains(where: { words.contains($0) }) { hits.append(label) }
            }
        }
        XCTAssertTrue(hits.isEmpty, "English left on \(screen): \(Set(hits).sorted())")
    }
}
