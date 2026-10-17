import XCTest
import StoreKitTest

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
    @MainActor func testPaywallFoundingRibbon() throws {
        // A purchase left by an earlier test would hide the Get PRO button.
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scanner", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration); session.clearTransactions()
        for language in ["en", "ko"] {
            let app = launch(language)
            let pro = app.buttons["home-pro"]
            for _ in 0..<50 where !pro.isHittable { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
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

/// App Store screenshots: the six storyboard screens in every app language.
/// PNGs go to Verification/private/store-shots/raw (git-ignored). Sample photos are fictional.
final class StoreScreenshotsUITests: HushUITestCase {
    private static let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let out = ios.appendingPathComponent("Verification/private/store-shots/raw")
    private static let samples = ios.deletingLastPathComponent().appendingPathComponent("마케팅 리포트/store-screenshots/samples")
    /// Seeded document names per language (lease, invoice, patient form).
    private static let titles: [String: [String]] = [
        "en": ["Lease agreement", "Invoice", "Patient form"],
        "ko": ["임대차 계약서", "인보이스", "환자 접수 양식"],
        "ja": ["賃貸契約書", "請求書", "問診票"],
        "zh-Hans": ["租赁合同", "发票", "患者登记表"],
        "zh-Hant": ["租賃合約", "發票", "病患登記表"],
        "de": ["Mietvertrag", "Rechnung", "Patientenformular"],
        "fr": ["Contrat de bail", "Facture", "Fiche patient"],
        "es": ["Contrato de alquiler", "Factura", "Formulario de paciente"],
        "pt-BR": ["Contrato de aluguel", "Fatura", "Ficha do paciente"],
        "it": ["Contratto di locazione", "Fattura", "Modulo paziente"],
        "pl": ["Umowa najmu", "Faktura", "Formularz pacjenta"],
        "tr": ["Kira sözleşmesi", "Fatura", "Hasta formu"],
        "id": ["Perjanjian sewa", "Faktur", "Formulir pasien"],
        "vi": ["Hợp đồng thuê nhà", "Hóa đơn", "Phiếu bệnh nhân"],
        "th": ["สัญญาเช่า", "ใบแจ้งหนี้", "แบบฟอร์มผู้ป่วย"],
    ]
    override func setUp() { continueAfterFailure = true }

    @MainActor func testEN() { shoot("en") }
    @MainActor func testKO() { shoot("ko") }
    @MainActor func testJA() { shoot("ja") }
    @MainActor func testZHHans() { shoot("zh-Hans") }
    @MainActor func testZHHant() { shoot("zh-Hant") }
    @MainActor func testDE() { shoot("de") }
    @MainActor func testFR() { shoot("fr") }
    @MainActor func testES() { shoot("es") }
    @MainActor func testPTBR() { shoot("pt-BR") }
    @MainActor func testIT() { shoot("it") }
    @MainActor func testPL() { shoot("pl") }
    @MainActor func testTR() { shoot("tr") }
    @MainActor func testID() { shoot("id") }
    @MainActor func testVI() { shoot("vi") }
    @MainActor func testTH() { shoot("th") }

    private var table: [String: String] = [:]
    private func L(_ key: String) -> String { table[key] ?? key }

    /// Copies the samples under this language's document names.
    private func seeds(_ language: String) -> [String] {
        let flat = Self.out.deletingLastPathComponent().appendingPathComponent("flat")
        let dir = Self.out.deletingLastPathComponent().appendingPathComponent("seeds/\(language)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return zip(["lease", "invoice", "form"], Self.titles[language]!).map { source, title in
            let to = dir.appendingPathComponent(title + ".jpg")
            if !FileManager.default.fileExists(atPath: to.path) {
                try? FileManager.default.copyItem(at: flat.appendingPathComponent(source + ".jpg"), to: to)
            }
            return to.path
        }
    }
    @MainActor private func save(_ app: XCUIApplication, _ language: String, _ name: String) {
        let shot = app.screenshot()
        let a = XCTAttachment(screenshot: shot); a.name = "\(language)-\(name)"; a.lifetime = .keepAlways; add(a)
        try? FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: Self.out.appendingPathComponent("\(language)-\(name).png"))
    }
    @MainActor private func launch(_ language: String, seeds: [String] = [], camera: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["--ui-test-session", UUID().uuidString, "-app-language", language]
        for s in seeds { args += ["--seed-image", s] }
        if let camera { args += ["--simulate-camera", "--camera-sample", camera.hasPrefix("/") ? camera : Self.samples.appendingPathComponent(camera + ".jpg").path] }
        app.launchArguments = args
        app.launch()
        if app.buttons["onboarding-skip"].waitForExistence(timeout: 6) { app.buttons["onboarding-skip"].tap() }
        if app.buttons["onboarding-later"].waitForExistence(timeout: 3) { app.buttons["onboarding-later"].tap() }
        XCTAssertTrue(app.buttons["nav-tools"].waitForExistence(timeout: 15))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.otherElements["startup-screen"])], timeout: 10)
        let welcome = app.buttons["welcome-pro-start"]
        if welcome.waitForExistence(timeout: 1) { welcome.tap() }
        return app
    }
    @MainActor private func openTool(_ app: XCUIApplication, id: String? = nil, label: String? = nil) {
        app.buttons["nav-tools"].tap()
        XCTAssertTrue(app.textFields["tool-search"].waitForExistence(timeout: 5))
        let tile = id.map { app.buttons[$0] } ?? app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label!)).firstMatch
        _ = tile.waitForExistence(timeout: 3)
        for _ in 0..<8 where !(tile.exists && tile.isHittable) { app.swipeUp() }
        tile.tap()
        if app.buttons["pro-try-free"].waitForExistence(timeout: 4) { app.buttons["pro-try-free"].tap() }
    }
    @MainActor private func chooseDocument(_ app: XCUIApplication, _ title: String) {
        let doc = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(doc.waitForExistence(timeout: 20), "Seeded document \(title) not listed")
        let window = app.windows.firstMatch
        for _ in 0..<4 where !doc.isHittable || doc.frame.maxY > window.frame.maxY - 140 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        }
        doc.tap()
    }

    @MainActor private func shoot(_ language: String) {
        table = (NSDictionary(contentsOfFile: Self.ios.appendingPathComponent("DocumentScanner/\(language).lproj/Localizable.strings").path) as? [String: String]) ?? [:]
        let seeded = seeds(language), names = Self.titles[language]!

        // 1. Scan review of the lease.
        var app = launch(language, camera: Self.out.deletingLastPathComponent().appendingPathComponent("flat/lease.jpg").path)
        let scan = app.buttons["scan-document"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10)); scan.tap()
        let shutter = app.buttons[L("Capture page")]
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: shutter)], timeout: 20)
        shutter.tap()
        XCTAssertTrue(app.buttons["capture-review-retake"].waitForExistence(timeout: 20))
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: app.buttons["review-done"])], timeout: 40)
        sleep(4)
        save(app, language, "01-review")
        app.terminate()

        // 6. Home with three saved documents, then 2. tables to Excel from the invoice.
        app = launch(language, seeds: seeded)
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", names[2])).firstMatch.waitForExistence(timeout: 30)
        sleep(2)
        save(app, language, "06-home")
        app.buttons["nav-documents"].tap()
        chooseDocument(app, names[1])
        let tools = app.descendants(matching: .any)["document-tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 10)); tools.tap()
        let more = app.buttons[L("More offline tools")]
        if more.waitForExistence(timeout: 5) { more.tap() }
        let excel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", L("Excel export"))).firstMatch
        _ = excel.waitForExistence(timeout: 20)
        for _ in 0..<6 where !excel.isHittable { app.swipeUp() }
        excel.tap()
        if app.buttons["pro-try-free"].waitForExistence(timeout: 4) { app.buttons["pro-try-free"].tap() }
        let excelPage = app.descendants(matching: .any)["office-page-preview"].firstMatch
        if app.buttons["office-continue"].waitForExistence(timeout: 8), !excelPage.exists { app.buttons["office-continue"].tap() }
        XCTAssertTrue(excelPage.waitForExistence(timeout: 90))
        sleep(1)
        save(app, language, "02-excel")
        // Corrections: the whole form first, then zoomed in on the table.
        excelPage.tap()
        let editor = app.descendants(matching: .any)["office-page-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        sleep(1)
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).doubleTap()
        sleep(1)
        save(app, language, "02-excel-cells")
        app.terminate()

        // 4. Sign the patient form.
        app = launch(language, seeds: seeded)
        openTool(app, id: "library-tool-signature")
        chooseDocument(app, names[2])
        sleep(5)
        save(app, language, "04-sign")
        app.terminate()

        // 5. Compress the lease.
        app = launch(language, seeds: seeded)
        openTool(app, label: L("Compress PDF"))
        chooseDocument(app, names[0])
        if app.buttons["compress-run"].waitForExistence(timeout: 20) {
            app.buttons["compress-run"].tap()
            _ = app.otherElements["compress-result"].waitForExistence(timeout: 60)
            sleep(2)
            save(app, language, "05-compress")
        } else { XCTFail("Compress options not shown") }
        app.terminate()

        // 3. Translate the French letter.
        app = launch(language, camera: "photo_letter_fr")
        openTool(app, label: L("Photo translation"))
        XCTAssertTrue(app.buttons["text-tool-capture"].waitForExistence(timeout: 10))
        app.buttons["text-tool-capture"].tap()
        XCTAssertTrue(app.staticTexts["translation-source-name"].waitForExistence(timeout: 60))
        sleep(1)
        save(app, language, "03-translate")
        app.terminate()
    }
}

/// App Store preview video: the same flows as the screenshots, paced for a screen
/// recording (runner `recuitest`). Scene start/end times go to
/// Verification/private/preview/marks-<lang>.json so the edit can cut them.
extension StoreScreenshotsUITests {
    @MainActor func testPreviewEN() { preview("en") }
    @MainActor func testPreviewKO() { preview("ko") }

    private static var marksURL: URL { ios.appendingPathComponent("Verification/private/preview") }

    @MainActor private func preview(_ language: String) {
        table = (NSDictionary(contentsOfFile: Self.ios.appendingPathComponent("DocumentScanner/\(language).lproj/Localizable.strings").path) as? [String: String]) ?? [:]
        let seeded = seeds(language), names = Self.titles[language]!
        var marks: [[String: Any]] = []
        func mark(_ scene: String, _ edge: String) { marks.append(["scene": scene, "edge": edge, "t": Date().timeIntervalSince1970]) }
        func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        defer {
            try? FileManager.default.createDirectory(at: Self.marksURL, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: marks, options: .prettyPrinted) {
                try? data.write(to: Self.marksURL.appendingPathComponent("marks-\(language).json"))
            }
        }

        // 1. Scan the lease: capture, then the clean page appears.
        var app = launch(language, camera: Self.out.deletingLastPathComponent().appendingPathComponent("flat/lease.jpg").path)
        let scan = app.buttons["scan-document"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10)); scan.tap()
        let shutter = app.buttons[L("Capture page")]
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: shutter)], timeout: 20)
        pause(1)
        mark("scan", "start")
        shutter.tap()
        _ = app.buttons["capture-review-retake"].waitForExistence(timeout: 20)
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: app.buttons["review-done"])], timeout: 40)
        pause(3)
        mark("scan", "end")
        app.terminate()

        // 2. Invoice to Excel.
        app = launch(language, seeds: seeded)
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", names[2])).firstMatch.waitForExistence(timeout: 30)
        pause(1)
        mark("home", "start")
        pause(2.5)
        mark("home", "end")
        app.buttons["nav-documents"].tap()
        chooseDocument(app, names[1])
        let tools = app.descendants(matching: .any)["document-tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 10)); tools.tap()
        let more = app.buttons[L("More offline tools")]
        if more.waitForExistence(timeout: 5) { more.tap() }
        let excel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", L("Excel export"))).firstMatch
        _ = excel.waitForExistence(timeout: 20)
        for _ in 0..<6 where !excel.isHittable { app.swipeUp() }
        pause(0.5)
        mark("excel", "start")
        excel.tap()
        if app.buttons["pro-try-free"].waitForExistence(timeout: 4) { app.buttons["pro-try-free"].tap() }
        let excelPage = app.descendants(matching: .any)["office-page-preview"].firstMatch
        if app.buttons["office-continue"].waitForExistence(timeout: 8), !excelPage.exists { app.buttons["office-continue"].tap() }
        XCTAssertTrue(excelPage.waitForExistence(timeout: 90))
        pause(2)
        excelPage.tap()
        let editor = app.descendants(matching: .any)["office-page-editor"].firstMatch
        if editor.waitForExistence(timeout: 10) {
            pause(1)
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).doubleTap()
            pause(2.5)
        }
        mark("excel", "end")
        app.terminate()

        // 4. Hide personal info on the patient form.
        app = launch(language, seeds: seeded)
        openTool(app, label: L("Hide personal info"))
        pause(0.5)
        mark("redact", "start")
        chooseDocument(app, names[2])
        _ = app.buttons["redact-save"].waitForExistence(timeout: 60)
        pause(3)
        mark("redact", "end")
        app.terminate()

        // 6. Compress the lease.
        app = launch(language, seeds: seeded)
        openTool(app, label: L("Compress PDF"))
        chooseDocument(app, names[0])
        if app.buttons["compress-run"].waitForExistence(timeout: 20) {
            pause(1)
            mark("compress", "start")
            app.buttons["compress-run"].tap()
            _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "%")).firstMatch.waitForExistence(timeout: 60)
            pause(2.5)
            mark("compress", "end")
        }
        app.terminate()
    }
}
