import XCTest
import PDFKit
import SwiftUI
@testable import DocumentScanner

/// Problems found while capturing store screenshots (2026-10-08), checked on the
/// same sample photos (all fictional data).
final class ScreenshotFixesTests: XCTestCase {
    private func image(_ name: String) throws -> UIImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "jpg"))
        return try XCTUnwrap(UIImage(contentsOfFile: url.path))
    }
    /// The photo as a letter-size PDF, as importing it would make.
    private func formPDF() throws -> URL {
        let photo = try image("photo_form")
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: page).pdfData { c in
            c.beginPage()
            let s = min(page.width / photo.size.width, page.height / photo.size.height)
            let w = photo.size.width * s, h = photo.size.height * s
            photo.draw(in: CGRect(x: (page.width - w) / 2, y: (page.height - h) / 2, width: w, height: h))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try data.write(to: url)
        return url
    }

    // A2: a page smaller than the picture must fill the picture, not sit in a corner.
    func testRenderedPageFillsThePicture() throws {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: page).pdfData { c in
            c.beginPage(); UIColor.black.setFill(); c.fill(CGRect(x: 512, y: 692, width: 100, height: 100))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try data.write(to: url)
        let picture = try ExtractRender.page(url, index: 0, maxSide: 2000)
        XCTAssertEqual(picture.size.height, 2000, accuracy: 1)
        let cg = try XCTUnwrap(picture.cgImage)
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Bottom-right corner (inside the black square) must be dark.
        ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width) + 10, y: -10, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertLessThan(Int(px[0]), 60, "Bottom-right of the page should be the black square")
    }

    // A3: labelled member numbers are found; dates beside labels are not.
    func testLabelledMemberNumberIsFound() {
        let line = "Insurance member ID: RFC 4418 2209 7731"
        let found = Redaction.matches(line)
        let hidden = found.map { (line as NSString).substring(with: $0.1) }
        XCTAssertTrue(hidden.contains { $0.contains("4418 2209 7731") }, "\(hidden)")
        XCTAssertTrue(Redaction.matches("Policy start date: 10/05/2026").isEmpty)
        XCTAssertTrue(Redaction.matches("Member since 2019").isEmpty)
        XCTAssertFalse(Redaction.matches("보험 회원번호 4418 2209 7731").isEmpty)
    }

    // A1, A2, A4 on the sample form: boxes sit on the text, the copy keeps the page size, text is gone.
    func testSampleFormRedaction() throws {
        let url = try formPDF()
        let picture = try ExtractRender.page(url, index: 0, maxSide: 2000)
        let blocks = try Imaging.recognize(picture)
        let boxes = try Redaction.detect(picture)
        let wanted = ["123-45-6789", "4111", "@", "RFC 4418"]
        for needle in wanted {
            guard let block = blocks.first(where: { $0.text.contains(needle) }) else { XCTFail("OCR missed \(needle)"); continue }
            let line = CGRect(x: block.x, y: block.y, width: block.width, height: block.height)
            XCTAssertTrue(boxes.contains { $0.rect.intersects(line) }, "No box over \(needle): \(block.text)")
        }
        let phone = blocks.first { $0.text.range(of: #"\(?\d{3}\)?[ -.]\d{3}[ -.]\d{4}"#, options: .regularExpression) != nil && !$0.text.contains("6789") }
        if let phone {
            let line = CGRect(x: phone.x, y: phone.y, width: phone.width, height: phone.height)
            XCTAssertTrue(boxes.contains { $0.rect.intersects(line) }, "No box over phone: \(phone.text)")
        }
        // The preview places boxes with the same function as the saved copy.
        let fit = FitRect.rect(picture.size, in: CGSize(width: 390, height: 600))
        for b in boxes {
            let onScreen = Redaction.place(b.rect, in: fit)
            let onPicture = Redaction.place(b.rect, in: CGRect(origin: .zero, size: picture.size))
            XCTAssertEqual((onScreen.minX - fit.minX) / fit.width, onPicture.minX / picture.size.width, accuracy: 0.0001)
        }
        let data = try Redaction.apply(url, boxes: [0: boxes.filter(\.on).map(\.rect)], pageCount: 1)
        let copy = try XCTUnwrap(PDFDocument(data: data))
        let source = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(copy.page(at: 0)!.bounds(for: .mediaBox).size, source.page(at: 0)!.bounds(for: .mediaBox).size)
        let text = copy.string ?? ""
        for needle in ["6789", "4111", "7731"] { XCTAssertFalse(text.contains(needle)) }
        // The hidden digits must not come back from the picture either.
        let again = try Imaging.recognize(ExtractRender.page(URL(fileURLWithPath: { let u = FileManager.default.temporaryDirectory.appendingPathComponent("r.pdf"); try? data.write(to: u); return u.path }()), index: 0, maxSide: 2000))
        let reread = again.map(\.text).joined(separator: " ")
        for needle in ["123-45-6789", "4418 2209 7731"] { XCTAssertFalse(reread.contains(needle), reread) }
        if ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] != nil {
            let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/private/review-shots")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent("redacted-sample.pdf"))
        }
    }

    // B1: the French letter is judged from all its text; too little text is not guessed.
    func testFrenchLetterIsDetected() throws {
        let scan = try PhotoTranslation.scan(try image("photo_letter_fr"))
        XCTAssertEqual(SourceLanguageGuess.detect(scan.regions.map(\.source)), "fr")
        XCTAssertNil(SourceLanguageGuess.detect(["OK", "12/10"]))
    }
    // B2: language names follow the app language, and Korean takes the right particle.
    func testLanguageNamesFollowAppLanguage() {
        let saved = UserDefaults.standard.string(forKey: AppLanguage.key)
        defer { UserDefaults.standard.set(saved, forKey: AppLanguage.key) }
        UserDefaults.standard.set("ko", forKey: AppLanguage.key)
        XCTAssertEqual(LanguageName.of("fr"), "프랑스어")
        XCTAssertEqual(LanguageName.direction("ko"), "한국어로")
        XCTAssertEqual(LanguageName.direction("en"), "영어로")
        UserDefaults.standard.set("en", forKey: AppLanguage.key)
        XCTAssertEqual(LanguageName.of("fr"), "French")
        XCTAssertEqual(LanguageName.direction("ko"), "Korean")
    }

    // D2: 10/05/2026 is October 5 in the US, May 10 in the UK, and left out when nothing decides.
    func testNumericDateOrder() throws {
        let cal = Calendar(identifier: .gregorian)
        let us = try XCTUnwrap(DocumentInsight.paperDate("Date: 10/05/2026  Signature", region: "US").date)
        XCTAssertEqual(cal.component(.month, from: us), 10); XCTAssertEqual(cal.component(.day, from: us), 5)
        let gb = try XCTUnwrap(DocumentInsight.paperDate("Date: 10/05/2026  Signature", region: "GB").date)
        XCTAssertEqual(cal.component(.month, from: gb), 5)
        XCTAssertTrue(DocumentInsight.paperDate("Date: 10/05/2026  Signature", region: "CA").ambiguous)
        let fr = try XCTUnwrap(DocumentInsight.paperDate("Fait à Paris le 10/05/2026. Nous vous remercions de votre confiance et restons à votre disposition.", region: "US").date)
        XCTAssertEqual(cal.component(.month, from: fr), 5, "French documents are day-first")
        let clear = try XCTUnwrap(DocumentInsight.paperDate("Date: 10/25/2026", region: "CA").date)
        XCTAssertEqual(cal.component(.day, from: clear), 25)
    }
    // D1: one page is "1 page".
    func testSinglePageWording() {
        let saved = UserDefaults.standard.string(forKey: AppLanguage.key)
        defer { UserDefaults.standard.set(saved, forKey: AppLanguage.key) }
        UserDefaults.standard.set("en", forKey: AppLanguage.key)
        XCTAssertEqual(pagesText(1), "1 page"); XCTAssertEqual(pagesText(3), "3 pages")
    }

    // E1: the founding price ends on Dec 17, 2026, from one constant.
    func testFoundingOfferEndsDecember17() throws {
        let cal = Calendar.current
        let end = try XCTUnwrap(FoundingOffer.endDate)
        XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: end), DateComponents(year: 2026, month: 12, day: 17))
        let oct8 = cal.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15))!
        XCTAssertEqual(FoundingOffer.daysLeft(now: oct8), 70)
        let dec16 = cal.date(from: DateComponents(year: 2026, month: 12, day: 16, hour: 23))!
        XCTAssertEqual(FoundingOffer.daysLeft(now: dec16), 1)
        let dec17 = cal.date(from: DateComponents(year: 2026, month: 12, day: 17, hour: 0, minute: 1))!
        XCTAssertNil(FoundingOffer.daysLeft(now: dec17), "Ribbon and days left hide after the end date")
        XCTAssertEqual(FoundingOffer.regularPrices["USD"], Decimal(string: "59.99"))
        XCTAssertEqual(FoundingOffer.regularPrices["KRW"], 79000)
    }

    // E1 follow-up: other currencies show the ribbon too; known currencies only while cheaper than the regular price.
    func testFoundingRibbonInEveryCurrency() {
        XCTAssertTrue(FoundingOffer.applies(price: 39.99, regular: Decimal(string: "59.99")), "USD founding price")
        XCTAssertFalse(FoundingOffer.applies(price: Decimal(string: "59.99")!, regular: Decimal(string: "59.99")), "USD already at the regular price")
        XCTAssertTrue(FoundingOffer.applies(price: 54.99, regular: nil), "CAD and other currencies: ribbon without strikethrough")
    }
}

/// Hide personal info on ID cards and licences from the US, Canada, Korea, Japan
/// and China (Verification/private/testimg/ids: official specimens, public-domain
/// samples and made-up cards, plus each card on a page and as a phone photo).
/// expected.json is the answer key: the name, number, date of birth, address and
/// passport lines that must end up covered. Writes ids/report.txt and an overlay
/// picture per sample (green: must hide, red: what was hidden).
final class IDRedactionSampleTests: XCTestCase {
    struct Field: Codable { let kind: String; let text: String }
    struct Entry: Codable { let negative: Bool; let fields: [Field]; let source: [String]? }

    private func root() throws -> URL {
        guard ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] != nil else { throw XCTSkip("Private samples are only on the developer Mac.") }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/private")
    }

    /// Letters and digits only, upper-cased: OCR spacing and punctuation don't matter.
    static func squeeze(_ s: String) -> (String, [Int]) {
        var out = "", map: [Int] = []
        for (i, ch) in Array(s).enumerated() where ch.isLetter || ch.isNumber || ch == "<" {
            out += String(ch).uppercased(); map.append(i)
        }
        return (out, map)
    }
    /// Where `text` is on the page, from recognized lines (several lines for a long address).
    static func locate(_ text: String, in blocks: [TextBlock]) -> [CGRect] {
        let target = squeeze(text).0
        guard !target.isEmpty else { return [] }
        func span(_ block: TextBlock, _ lo: Int, _ hi: Int) -> CGRect {
            let chars = Array(block.text)
            let words = block.words ?? []
            var cursor = 0, rects: [CGRect] = []
            for w in words {
                let wc = Array(w.text)
                guard let start = (cursor...max(cursor, chars.count - wc.count)).first(where: { i in i + wc.count <= chars.count && Array(chars[i..<(i + wc.count)]) == wc }) else { continue }
                let end = start + wc.count; cursor = end
                if end > lo && start <= hi { rects.append(CGRect(x: w.x, y: w.y, width: w.width, height: w.height)) }
            }
            if let first = rects.first { return rects.dropFirst().reduce(first) { $0.union($1) } }
            let n = Double(max(1, chars.count))
            return CGRect(x: block.x + block.width * Double(lo) / n, y: block.y, width: block.width * Double(hi - lo + 1) / n, height: block.height)
        }
        for b in blocks {
            let (s, map) = squeeze(b.text)
            if let r = s.range(of: target) {
                let lo = s.distance(from: s.startIndex, to: r.lowerBound), hi = lo + target.count - 1
                return [span(b, map[lo], map[hi])]
            }
        }
        // Split over lines or words: every part must be found.
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" || $0 == "," }).map(String.init).filter { !squeeze($0).0.isEmpty }
        guard parts.count > 1 else { return [] }
        var found: [CGRect] = []
        for p in parts {
            let r = locate(p, in: blocks)
            if r.isEmpty { return [] }
            found += r
        }
        return found
    }
    /// The share of `rect` under the hidden boxes (sampled on a grid).
    static func covered(_ rect: CGRect, by boxes: [CGRect]) -> Double {
        var hit = 0, total = 0
        for i in 0..<12 { for j in 0..<6 {
            let p = CGPoint(x: rect.minX + rect.width * (Double(i) + 0.5) / 12, y: rect.minY + rect.height * (Double(j) + 0.5) / 6)
            total += 1; if boxes.contains(where: { $0.contains(p) }) { hit += 1 }
        } }
        return Double(hit) / Double(total)
    }

    /// Ordinary pages (letters, forms, photos) must not be read as ID cards.
    @MainActor func testOrdinaryPagesAreNotTreatedAsCards() throws {
        let dir = try root().appendingPathComponent("testimg")
        var report: [String] = []
        for name in ["erase_doc.jpg", "marked_doc.jpg", "mega_1.jpg", "mega_2.jpg", "mega_3.jpg", "book_spread.jpg", "old_photo.jpg", "coins.jpg"] {
            guard let image = UIImage(contentsOfFile: dir.appendingPathComponent(name).path) else { continue }
            let parts = try Redaction.readParts(image)
            let fields = parts.flatMap { Redaction.cardFields($0.blocks, card: $0.card) }
            report.append("\(name): parts \(parts.count), cards \(parts.filter(\.card).count), card fields \(fields.count) \(fields.map(\.0))")
            XCTAssertFalse(parts.contains(where: \.card), "\(name) was taken for a card")
        }
        print("IDORDINARY " + report.joined(separator: " | "))
    }

    @MainActor func testIDCardsHideTheirPersonalDetails() throws {
        let base = try root()
        let dir = base.appendingPathComponent("testimg/ids")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("expected.json")) else { throw XCTSkip("No ID samples.") }
        let entries = try JSONDecoder().decode([String: Entry].self, from: data)
        let out = base.appendingPathComponent("ids")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let onlyText = (try? String(contentsOf: out.appendingPathComponent("only.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let only: String? = onlyText.isEmpty ? nil : onlyText
        var lines: [String] = [], total = 0, hidden = 0, unlocated = 0, negBoxes = 0
        var byKind: [String: (Int, Int)] = [:]
        for name in entries.keys.sorted() where only == nil || name.contains(only!) {
            let entry = entries[name]!
            let file = ["png", "jpg"].map { dir.appendingPathComponent("\(name).\($0)") }.first { FileManager.default.fileExists(atPath: $0.path) }
            guard let file, var image = UIImage(contentsOfFile: file.path) else { lines.append("\(name): missing"); continue }
            if name.hasPrefix("photo_") {
                let cg = try XCTUnwrap(image.cgImage)
                guard let crop = CaptureStyle.card.detect(image, capturedPhoto: true) else { lines.append("\(name): card edges not found"); continue }
                let ci = try DocumentProcessing.render(CIImage(cgImage: cg), crop: crop, turns: 0, enhancement: .original, flatten: FlattenRequest(key: nil))
                image = UIImage(cgImage: try XCTUnwrap(DocumentProcessing.context.createCGImage(ci, from: ci.extent)))
            }
            let start = Date()
            let parts = try Redaction.readParts(image)
            let read = parts.flatMap { part in part.blocks.map(part.place) }
            let boxes = parts.flatMap { part in Redaction.boxes(in: part.blocks, card: part.card).map { var b = $0; b.rect = part.place($0.rect); return b } }
            let seconds = Date().timeIntervalSince(start)
            try FileManager.default.createDirectory(at: out.appendingPathComponent("ocr"), withIntermediateDirectories: true)
            try JSONEncoder().encode(read).write(to: out.appendingPathComponent("ocr/\(name).json"))
            let rects = boxes.filter(\.on).map(\.rect)
            if entry.negative {
                negBoxes += rects.count
                lines.append(String(format: "%@: blank sample, %d boxes (%.1fs)", name, rects.count, seconds))
                continue
            }
            // Ground truth: read at twice the size so small print is found.
            let big = UIGraphicsImageRenderer(size: CGSize(width: image.size.width * 2, height: image.size.height * 2), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { _ in image.draw(in: CGRect(origin: .zero, size: CGSize(width: image.size.width * 2, height: image.size.height * 2))) }
            let truth = try Imaging.recognize(big)
            var row: [String] = [], misses: [String] = []
            var fieldRects: [CGRect] = []
            for f in entry.fields {
                let where_ = Self.locate(f.text, in: truth)
                guard !where_.isEmpty else { unlocated += 1; misses.append("?" + f.text); continue }
                total += 1
                fieldRects += where_
                let share = where_.map { Self.covered($0, by: rects) }.min() ?? 0
                var k = byKind[f.kind] ?? (0, 0); k.1 += 1
                if share >= 0.8 { hidden += 1; k.0 += 1 } else { misses.append(String(format: "%@ %.0f%%", f.text, share * 100)) }
                byKind[f.kind] = k
                row.append(f.text)
            }
            let found = entry.fields.count - misses.filter { $0.hasPrefix("?") }.count
            let ok = found - misses.filter { !$0.hasPrefix("?") }.count
            lines.append(String(format: "%@: %d/%d hidden, %d boxes (%.1fs)%@", name, ok, found, rects.count, seconds, misses.isEmpty ? "" : " — missed: " + misses.joined(separator: " | ")))
            // Overlay for checking by eye.
            let overlay = UIGraphicsImageRenderer(size: image.size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { c in
                image.draw(at: .zero)
                let full = CGRect(origin: .zero, size: image.size)
                UIColor.systemGreen.setStroke()
                for r in fieldRects { let p = UIBezierPath(rect: Redaction.place(r, in: full)); p.lineWidth = 3; p.stroke() }
                UIColor.red.withAlphaComponent(0.45).setFill()
                for r in rects { c.fill(Redaction.place(r, in: full)) }
            }
            try overlay.jpegData(compressionQuality: 0.8)?.write(to: out.appendingPathComponent(name + ".jpg"))
            try FileManager.default.createDirectory(at: out.appendingPathComponent("truth"), withIntermediateDirectories: true)
            var truthOut: [String: [[Double]]] = [:]
            for f in entry.fields { truthOut[f.kind + "|" + f.text] = Self.locate(f.text, in: truth).map { [$0.minX, $0.minY, $0.width, $0.height] } }
            try JSONSerialization.data(withJSONObject: truthOut).write(to: out.appendingPathComponent("truth/\(name).json"))
        }
        let kinds = byKind.keys.sorted().map { "\($0) \(byKind[$0]!.0)/\(byKind[$0]!.1)" }.joined(separator: ", ")
        let head = String(format: "Hidden %d/%d fields (%.0f%%); not readable by OCR: %d; boxes on blank samples: %d\nBy kind: %@", hidden, total, total == 0 ? 0 : 100.0 * Double(hidden) / Double(total), unlocated, negBoxes, kinds)
        try ([head, ""] + lines).joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        print("IDREDACT " + head.replacingOccurrences(of: "\n", with: " | "))
    }
}

/// Renders single frames of the wait animations so their look can be checked by eye.
final class WorkAnimationFrameTests: XCTestCase {
    @MainActor func testSaveAnimationFrames() throws {
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/private/anim")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for t in [0.12, 0.3, 0.42, 0.5, 0.54, 0.58, 0.68, 0.8, 0.9] {
            let view = WorkProgressView(kind: .save, phase: "Saving PDF…").stage(t).background(TK.paper)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            try XCTUnwrap(image.pngData()).write(to: out.appendingPathComponent(String(format: "save_%02d.png", Int(t * 100))))
        }
    }
}
