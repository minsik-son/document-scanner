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

/// The save step's big preview against the list thumbnail, on real document photos.
final class LargePreviewQualityTests: XCTestCase {
    @MainActor func testLargePreviewKeepsThinLines() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/private")
        let out = base.appendingPathComponent("anim"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["IMG_3885.HEIC", "IMG_3887.HEIC"] {
            let src = base.appendingPathComponent("testimg/" + name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try? FileManager.default.copyItem(at: src, to: root.appendingPathComponent(name))
            var page = ScanPage(imageFile: name); page.enhancement = .document
            if let image = UIImage(contentsOfFile: src.path), let quad = CaptureStyle.document.detect(image, capturedPhoto: true) { page.crop = quad }
            let small = try Imaging.renderThumbnail(page, root: root, maxDimension: 700)
            let large = try Imaging.renderThumbnail(page, root: root, maxDimension: 1400)
            // Same box, shown at the large size, side by side.
            let w = large.size.width, h = large.size.height
            let sheet = UIGraphicsImageRenderer(size: CGSize(width: w * 2 + 20, height: h), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { c in
                UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: w * 2 + 20, height: h))
                small.draw(in: CGRect(x: 0, y: 0, width: w, height: h)); large.draw(in: CGRect(x: w + 20, y: 0, width: w, height: h))
            }
            try XCTUnwrap(sheet.jpegData(compressionQuality: 0.9)).write(to: out.appendingPathComponent("preview_" + name + ".jpg"))
        }
    }
}

/// Pale colored table cells on the Document tone: dumps the lit-flattened page and the
/// finished page so cell colors can be compared row by row.
final class PaleCellToneTests: XCTestCase {
    @MainActor func testDumpPaleCells() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/private")
        let out = base.appendingPathComponent("tone"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        DocumentProcessing.paperTrace = { samples, columns, rows, grid in
            var lines = ["grid \(columns)x\(rows) table \(String(describing: grid))"]
            for r in 0..<rows { lines.append((0..<columns).map { c in samples[r*columns+c].map { v in String(format: "%02d%02d%02d", Int(v[0]*99), Int(v[1]*99), Int(v[2]*99)) } ?? "------" }.joined(separator: " ")) }
            try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("trace.txt"), atomically: true, encoding: .utf8)
        }
        defer { DocumentProcessing.paperTrace = nil }
        for name in ["tint_sheet.jpg"] {
            let url = base.appendingPathComponent("testimg/" + name)
            guard let image = UIImage(contentsOfFile: url.path), let cg = image.cgImage else { continue }
            let crop = CaptureStyle.document.detect(image, capturedPhoto: true) ?? .full
            let ci = CIImage(cgImage: cg)
            let prepared = try DocumentProcessing.prepare(ci, crop: crop, turns: 0, enhancement: .document)
            let finished = try DocumentProcessing.finish(prepared)
            for (suffix, img) in [("flat", prepared.image), ("doc", finished)] {
                let ctx = DocumentProcessing.context
                guard let png = ctx.pngRepresentation(of: img, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { continue }
                try png.write(to: out.appendingPathComponent(name + "." + suffix + ".png"))
            }
        }
    }
}

/// Where the seconds go between the shutter and the finished page.
final class ScanSpeedTests: XCTestCase {
    @MainActor func testScanPipelineTimings() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/private")
        let out = base.appendingPathComponent("speed"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var lines: [String] = []
        func time<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
            let t = CFAbsoluteTimeGetCurrent(); let r = try work()
            lines.append(String(format: "%@ %.0f ms", label, (CFAbsoluteTimeGetCurrent() - t) * 1000)); return r
        }
        PaperFlattener.trace = { lines.append("    flattener " + $0) }
        defer { PaperFlattener.trace = nil }
        for name in ["IMG_3885.HEIC", "IMG_3887.HEIC", "tint_sheet.jpg"] {
            let url = base.appendingPathComponent("testimg/" + name)
            guard let data = try? Data(contentsOf: url) else { continue }
            lines.append("== " + name)
            guard let photo = time("decode ~24MP", { CameraController.decode(data, maxPixels: 25_000_000) }), let cg = photo.cgImage else { continue }
            lines.append("  size \(cg.width)x\(cg.height)")
            let crop = time("find page") { CaptureStyle.document.detect(Imaging.limited(photo, maxPixels: 12_200_000), capturedPhoto: true) } ?? .full
            let source = CIImage(cgImage: cg)
            let mesh = time("flatten analysis") { PaperFlatten.analyze(source, crop: crop) }
            lines.append("  flattened: \(mesh != nil)")
            for (label, flatten) in [("with flatten", FlattenRequest(key: nil)), ("perspective only", nil)] as [(String, FlattenRequest?)] {
                let prepared = try time("prepare " + label) { try DocumentProcessing.prepare(source, crop: crop, turns: 0, enhancement: .document, flatten: flatten) }
                let finished = try DocumentProcessing.finish(prepared)
                _ = time("  render full " + label + " \(Int(finished.extent.width))x\(Int(finished.extent.height))") { DocumentProcessing.context.createCGImage(finished, from: finished.extent) }
            }
            for limit in [12_000_000, 6_000_000] {
                let small = Imaging.limited(photo, maxPixels: limit)
                guard let scg = small.cgImage else { continue }
                let s = CIImage(cgImage: scg)
                let prepared = try time("prepare with flatten @\(limit/1_000_000)MP") { try DocumentProcessing.prepare(s, crop: crop, turns: 0, enhancement: .document, flatten: FlattenRequest(key: nil)) }
                let finished = try DocumentProcessing.finish(prepared)
                _ = time("  render @\(limit/1_000_000)MP \(Int(finished.extent.width))x\(Int(finished.extent.height))") { DocumentProcessing.context.createCGImage(finished, from: finished.extent) }
            }
        }
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("timings.txt"), atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
    }
}

extension ScanSpeedTests {
    /// The on-screen preview (1800 px) from a smaller source vs from the full photo.
    @MainActor func testSmallSourcePreviewMatchesFull() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/private")
        let out = base.appendingPathComponent("speed"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var lines: [String] = []
        func preview(_ photo: UIImage, _ crop: ScanQuad) throws -> UIImage {
            let prepared = try DocumentProcessing.prepare(CIImage(cgImage: photo.cgImage!), crop: crop, turns: 0, enhancement: .document, flatten: FlattenRequest(key: nil))
            let finished = try DocumentProcessing.finish(prepared)
            let cg = DocumentProcessing.context.createCGImage(finished, from: finished.extent)!
            return try Imaging.previewThumbnail(UIImage(cgImage: cg), maxDimension: 1800)
        }
        func gray(_ image: UIImage, _ w: Int, _ h: Int) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: w * h)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            ctx.interpolationQuality = .high; ctx.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h)); return px
        }
        for name in ["IMG_3885.HEIC", "IMG_3887.HEIC", "IMG_3889.HEIC"] {
            guard let data = try? Data(contentsOf: base.appendingPathComponent("testimg/" + name)),
                  let photo = CameraController.decode(data, maxPixels: 25_000_000) else { continue }
            let crop = CaptureStyle.document.detect(Imaging.limited(photo, maxPixels: 12_200_000), capturedPhoto: true) ?? .full
            let full = try preview(photo, crop)
            let w = Int(full.size.width * full.scale), h = Int(full.size.height * full.scale)
            let a = gray(full, w, h)
            for limit in [12_000_000, 6_000_000] {
                let small = try preview(Imaging.limited(photo, maxPixels: limit), crop)
                let b = gray(small, w, h)
                var sum = 0, big = 0
                for i in 0..<a.count { let d = abs(Int(a[i]) - Int(b[i])); sum += d; if d > 24 { big += 1 } }
                lines.append(String(format: "%@ @%dMP: mean diff %.2f / 255, pixels off by >24: %.3f%%", name, limit / 1_000_000, Double(sum) / Double(a.count), Double(big) * 100 / Double(a.count)))
                if limit == 6_000_000 {
                    try full.jpegData(compressionQuality: 0.9)?.write(to: out.appendingPathComponent(name + ".full.jpg"))
                    try small.jpegData(compressionQuality: 0.9)?.write(to: out.appendingPathComponent(name + ".6mp.jpg"))
                }
            }
        }
        try lines.joined(separator: "\n").write(to: out.appendingPathComponent("match.txt"), atomically: true, encoding: .utf8)
    }
}

/// Quality guard for speed work: the finished full-resolution page of each test
/// photo, byte for byte. The first run records `golden/`, later runs must match.
final class ScanOutputGoldenTests: XCTestCase {
    @MainActor func testFinishedPagesUnchanged() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/private")
        let golden = base.appendingPathComponent("speed/golden"); try FileManager.default.createDirectory(at: golden, withIntermediateDirectories: true)
        var report: [String] = []
        for name in ["IMG_3885.HEIC", "IMG_3886.HEIC", "IMG_3887.HEIC", "IMG_3888.HEIC", "IMG_3889.HEIC", "tint_sheet.jpg", "marked_doc.jpg", "book_spread.jpg"] {
            guard let data = try? Data(contentsOf: base.appendingPathComponent("testimg/" + name)),
                  let photo = CameraController.decode(data, maxPixels: 25_000_000), let cg = photo.cgImage else { continue }
            let crop = CaptureStyle.document.detect(Imaging.limited(photo, maxPixels: 12_200_000), capturedPhoto: true) ?? .full
            let prepared = try DocumentProcessing.prepare(CIImage(cgImage: cg), crop: crop, turns: 0, enhancement: .document, flatten: FlattenRequest(key: nil))
            let finished = try DocumentProcessing.finish(prepared)
            let w = Int(finished.extent.width), h = Int(finished.extent.height)
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            DocumentProcessing.context.render(finished, toBitmap: &bytes, rowBytes: w * 4, bounds: finished.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            let file = golden.appendingPathComponent(name + ".rgba")
            let header = Data("\(w)x\(h)\n".utf8)
            let current = header + Data(bytes)
            if let stored = try? Data(contentsOf: file) {
                if stored == current { report.append("\(name) \(w)x\(h) identical") }
                else {
                    var diff = 0, maxd = 0
                    let s = [UInt8](stored.dropFirst(header.count))
                    if s.count == bytes.count { for i in 0..<s.count { let d = abs(Int(s[i]) - Int(bytes[i])); if d > 0 { diff += 1; maxd = max(maxd, d) } } }
                    report.append("\(name) \(w)x\(h) CHANGED: \(s.count == bytes.count ? "\(diff) values differ, max \(maxd)" : "size differs")")
                }
            } else { try current.write(to: file); report.append("\(name) \(w)x\(h) recorded") }
        }
        try report.joined(separator: "\n").write(to: golden.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        // Core Image on the GPU is not bit-exact run to run: a few hundred of ~40M
        // values flip between identical runs. More than that is a real change.
        let real = report.filter { line in
            guard line.contains("CHANGED") else { return false }
            if line.contains("size differs") { return true }
            let count = Int(line.components(separatedBy: "CHANGED: ").last?.components(separatedBy: " ").first ?? "") ?? 0
            return count > 3000
        }
        XCTAssertTrue(real.isEmpty, report.joined(separator: "\n"))
    }
}

extension ScanSpeedTests {
    /// The flat-page mesh found from a thumbnail-sized copy (1600 px) vs from the
    /// full photo: how far apart the finished full-resolution pages are.
    @MainActor func testMeshFromThumbnailVsFull() throws {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/private")
        var lines: [String] = []
        func pixels(_ prepared: DocumentProcessing.PreparedDocument) throws -> (Int, Int, [UInt8]) {
            let f = try DocumentProcessing.finish(prepared)
            let w = Int(f.extent.width), h = Int(f.extent.height)
            var b = [UInt8](repeating: 0, count: w * h * 4)
            DocumentProcessing.context.render(f, toBitmap: &b, rowBytes: w * 4, bounds: f.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return (w, h, b)
        }
        for name in ["IMG_3885.HEIC", "IMG_3886.HEIC", "IMG_3887.HEIC", "IMG_3888.HEIC", "IMG_3889.HEIC"] {
            guard let data = try? Data(contentsOf: base.appendingPathComponent("testimg/" + name)),
                  let photo = CameraController.decode(data, maxPixels: 25_000_000), let cg = photo.cgImage else { continue }
            let crop = CaptureStyle.document.detect(Imaging.limited(photo, maxPixels: 12_200_000), capturedPhoto: true) ?? .full
            let full = CIImage(cgImage: cg)
            let a = try pixels(DocumentProcessing.prepare(full, crop: crop, turns: 0, enhancement: .document, flatten: FlattenRequest(key: nil)))
            let key = "thumbtest-" + name + UUID().uuidString
            let thumb = CIImage(cgImage: Imaging.limited(photo, maxPixels: 1600 * 1600 * 3 / 4).cgImage!)
            _ = PaperFlatten.mesh(for: thumb, crop: crop, key: key)
            let b = try pixels(DocumentProcessing.prepare(full, crop: crop, turns: 0, enhancement: .document, flatten: FlattenRequest(key: key)))
            if a.0 == b.0 && a.1 == b.1 {
                var n = 0; for i in 0..<a.2.count where a.2[i] != b.2[i] { n += 1 }
                lines.append("\(name) same size \(a.0)x\(a.1), \(n) values differ")
            } else { lines.append("\(name) size full \(a.0)x\(a.1) vs thumb-mesh \(b.0)x\(b.1)") }
        }
        try lines.joined(separator: "\n").write(to: base.appendingPathComponent("speed/mesh.txt"), atomically: true, encoding: .utf8)
    }
}

// MARK: - QA: answer-key scans
//
// Synthetic photos with known page corners and known text (Verification/private/qa,
// made by gen_pages.py / gen_photos.py). For each photo: edge finding error, then the
// full scan pipeline with the found corners and with the true ones, read back with
// the app's own text recognition and scored against the page's text. Results go to
// qa/results/scan.jsonl (one line per photo) and qa/results/scan/<photo>.jpg.
enum QAText {
    /// Compare text the way a reader would: case, spacing and width variants ignored.
    static func normalize(_ s: String) -> [Character] {
        let n = s.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        // Dotted and dashed rules (a receipt's separators) are drawing, not text.
        let joined = String(n.filter { !$0.isWhitespace })
        return Array(joined.replacingOccurrences(of: "[-_.·•=*~]{3,}", with: "", options: .regularExpression))
    }
    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + (a[i-1] == b[j-1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
    /// Character error rate of `read` against `truth` (0 = perfect).
    static func cer(truth: String, read: String) -> Double {
        let t = normalize(truth), r = normalize(read)
        return t.isEmpty ? 0 : Double(levenshtein(t, r)) / Double(t.count)
    }
    /// Share of the truth's pieces (words; two-character runs for CJK) found anywhere
    /// in the reading. Order-free, so table read order doesn't count against it.
    static func recall(truth: String, read: String) -> Double {
        let r = String(normalize(read))
        var pieces: [String] = []
        for word in truth.split(whereSeparator: { $0.isWhitespace }) {
            let w = Array(String(word).precomposedStringWithCompatibilityMapping.lowercased())
            if w.contains(where: { $0.unicodeScalars.first.map { $0.value >= 0x2E80 } ?? false }) {
                if w.count < 2 { pieces.append(String(w)) } else { for i in 0..<(w.count - 1) { pieces.append(String(w[i...i+1])) } }
            } else { pieces.append(String(w)) }
        }
        guard !pieces.isEmpty else { return 1 }
        return Double(pieces.filter { r.contains(String(normalize($0))) }.count) / Double(pieces.count)
    }
}

final class QAScanTests: XCTestCase {
    struct PhotoTruth: Decodable { let page: String; let variant: String; let corners: [[Double]] }
    struct PageTruth: Decodable { let id: String; let kind: String; let size: [Double]; let lines: [String]; let colors: [ColorTruth] }
    struct ColorTruth: Decodable { let name: String; let box: [Double]; let rgb: [Double] }

    static let qa = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Verification/private/qa")

    func read(_ cg: CGImage) -> String {
        ((try? TextRecognition.recognize(cg)) ?? []).map(\.text).joined(separator: "\n")
    }
    var lastFlattened = false
    func render(_ photo: UIImage, crop: ScanQuad) throws -> CGImage {
        let prepared = try DocumentProcessing.prepare(CIImage(cgImage: photo.cgImage!), crop: crop, turns: 0, enhancement: .document, flatten: FlattenRequest(key: nil))
        lastFlattened = prepared.flattened
        let finished = try DocumentProcessing.finish(prepared)
        return DocumentProcessing.context.createCGImage(finished, from: finished.extent)!
    }
    /// Paper level and evenness: the bright 90th percentile of each of 6×8 tiles.
    func paper(_ cg: CGImage) -> (median: Double, spread: Double) {
        let w = 240, h = 320
        var px = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        ctx.interpolationQuality = .medium; ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var tiles: [Double] = []
        for ty in 0..<8 { for tx in 0..<6 {
            var v: [UInt8] = []
            for y in (ty*40)..<(ty*40+40) { for x in (tx*40)..<(tx*40+40) { v.append(px[y*w+x]) } }
            v.sort(); tiles.append(Double(v[Int(Double(v.count) * 0.9)]))
        } }
        let s = tiles.sorted()
        return (s[s.count/2], s[s.count - 1] - s[min(2, s.count - 1)])
    }
    /// Mean colour of a truth box (page pixel coordinates) found at the same place on the output.
    func colour(_ cg: CGImage, box: [Double], page: [Double]) -> [Double] {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Inner 60 % of the box, so a few pixels of edge misplacement don't matter.
        let x0 = Int((box[0] + box[2]*0.2) / page[0] * Double(w)), x1 = Int((box[0] + box[2]*0.8) / page[0] * Double(w))
        let y0 = Int((box[1] + box[3]*0.2) / page[1] * Double(h)), y1 = Int((box[1] + box[3]*0.8) / page[1] * Double(h))
        var sum = [0.0, 0.0, 0.0], n = 0.0
        for y in stride(from: max(0, y0), to: min(h, y1), by: 2) { for x in stride(from: max(0, x0), to: min(w, x1), by: 2) {
            let i = (y * w + x) * 4; sum[0] += Double(px[i]); sum[1] += Double(px[i+1]); sum[2] += Double(px[i+2]); n += 1 } }
        return n > 0 ? sum.map { $0 / n } : [0, 0, 0]
    }
    /// CIE76 ΔE between two sRGB colours (0–255).
    static func deltaE(_ a: [Double], _ b: [Double]) -> Double {
        func lab(_ c: [Double]) -> [Double] {
            let l = c.map { v -> Double in let s = v / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
            var x = (l[0]*0.4124 + l[1]*0.3576 + l[2]*0.1805) / 0.95047, y = l[0]*0.2126 + l[1]*0.7152 + l[2]*0.0722, z = (l[0]*0.0193 + l[1]*0.1192 + l[2]*0.9505) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1/3) : 7.787 * t + 16/116 }
            x = f(x); y = f(y); z = f(z)
            return [116*y - 16, 500*(x - y), 200*(y - z)]
        }
        let p = lab(a), q = lab(b)
        return sqrt(pow(p[0]-q[0], 2) + pow(p[1]-q[1], 2) + pow(p[2]-q[2], 2))
    }
    /// Saved at the clean page's resolution (JPEG 0.95) so score_scan.py compares like with like.
    func save(_ cg: CGImage, to url: URL, side: Double) {
        let s = min(1, side / Double(max(cg.width, cg.height)))
        let img = UIImage(cgImage: cg)
        let size = CGSize(width: Double(cg.width) * s, height: Double(cg.height) * s)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        try? small.jpegData(compressionQuality: 0.95)?.write(to: url)
    }

    func testScanAnswerKeys() throws {
        let qa = Self.qa, photos = qa.appendingPathComponent("synth/photos"), pages = qa.appendingPathComponent("synth/pages")
        let out = qa.appendingPathComponent("results/scan"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let log = qa.appendingPathComponent("results/scan.jsonl"); try? FileManager.default.removeItem(at: log); FileManager.default.createFile(atPath: log.path, contents: nil)
        let only = ProcessInfo.processInfo.environment["QA_ONLY"]
        let names = try FileManager.default.contentsOfDirectory(atPath: photos.path).filter { $0.hasSuffix(".json") }.sorted()
        var baseline: [String: (cer: Double, recall: Double)] = [:]
        for name in names {
            if let only, !name.contains(only) { continue }
            try autoreleasepool {
                let truth = try JSONDecoder().decode(PhotoTruth.self, from: Data(contentsOf: photos.appendingPathComponent(name)))
                let page = try JSONDecoder().decode(PageTruth.self, from: Data(contentsOf: pages.appendingPathComponent(truth.page + ".json")))
                let text = page.lines.joined(separator: "\n")
                if baseline[truth.page] == nil, let clean = UIImage(contentsOfFile: pages.appendingPathComponent(truth.page + ".png").path)?.cgImage {
                    let r = read(clean); baseline[truth.page] = (QAText.cer(truth: text, read: r), QAText.recall(truth: text, read: r))
                }
                let stem = String(name.dropLast(5))
                guard let data = try? Data(contentsOf: photos.appendingPathComponent(stem + ".jpg")), let photo = CameraController.decode(data, maxPixels: 25_000_000) else { return }
                let W = Double(photo.cgImage!.width), H = Double(photo.cgImage!.height), diag = hypot(W, H)
                let t0 = CFAbsoluteTimeGetCurrent()
                let found = CaptureStyle.document.detect(Imaging.limited(photo, maxPixels: 12_200_000), capturedPhoto: true)
                let detectMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                var cornerErr: [Double] = []
                if let found { for (p, q) in zip(found.points, truth.corners) { cornerErr.append(hypot((p.x - q[0]) * W, (p.y - q[1]) * H) / diag * 100) } }
                let trueCrop = ScanQuad(points: truth.corners.map { ScanPoint(x: $0[0], y: $0[1]) })
                var row: [String: Any] = ["photo": stem, "page": truth.page, "variant": truth.variant, "kind": page.kind,
                                          "detected": found != nil, "detect_ms": Int(detectMs),
                                          "corner_err_mean_pct": cornerErr.isEmpty ? NSNull() : cornerErr.reduce(0, +) / 4,
                                          "corner_err_max_pct": cornerErr.max() ?? NSNull(),
                                          "baseline_cer": baseline[truth.page]!.cer, "baseline_recall": baseline[truth.page]!.recall]
                for (label, crop) in [("auto", found ?? .full), ("truecrop", trueCrop)] {
                    let t1 = CFAbsoluteTimeGetCurrent()
                    guard let cg = try? render(photo, crop: crop) else { row[label + "_error"] = true; continue }
                    row[label + "_render_ms"] = Int((CFAbsoluteTimeGetCurrent() - t1) * 1000)
                    row[label + "_flattened"] = lastFlattened
                    let r = read(cg)
                    row[label + "_cer"] = QAText.cer(truth: text, read: r)
                    row[label + "_recall"] = QAText.recall(truth: text, read: r)
                    let aspect = Double(cg.width) / Double(cg.height), want = page.size[0] / page.size[1]
                    row[label + "_aspect_err_pct"] = abs(aspect / want - 1) * 100
                    let p = paper(cg); row[label + "_paper_median"] = p.median; row[label + "_paper_spread"] = p.spread
                    if !page.colors.isEmpty {
                        row[label + "_color_de"] = page.colors.map { Self.deltaE(colour(cg, box: $0.box, page: page.size), $0.rgb) }
                    }
                    save(cg, to: out.appendingPathComponent("\(stem)__\(label).jpg"), side: page.size.max()!)
                    if label == "auto" { try? r.write(to: out.appendingPathComponent("\(stem)__auto.txt"), atomically: true, encoding: .utf8) }
                }
                let line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                let h = try FileHandle(forWritingTo: log); h.seekToEndOfFile(); h.write(line + Data("\n".utf8)); try h.close()
            }
        }
    }
}

/// QA: what the saved PDF and the Compress PDF tool do to quality and size.
/// Scanned document = the nine answer-key pages photographed (v1_ideal, true corners), saved
/// the way the app saves; imported document = a vector text PDF of the same truth lines.
/// For the saved file and every compression preset: bytes, text layer vs truth, OCR of the
/// page rendered at the truth resolution, and the render itself (results/pdf/<doc>/<label>/)
/// for score_pdf.py (SSIM against the saved render). One JSON line per page in results/pdf.jsonl.
@MainActor
final class QAPDFTests: XCTestCase {
    func renderPage(_ page: PDFPage, width: Double) -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let pw = rotated ? box.height : box.width, ph = rotated ? box.width : box.height
        let s = width / pw
        let size = CGSize(width: (pw * s).rounded(), height: (ph * s).rounded())
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { c in
            UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: size))
            c.cgContext.translateBy(x: 0, y: size.height); c.cgContext.scaleBy(x: s, y: -s)
            page.draw(with: .mediaBox, to: c.cgContext)
        }
        return img.cgImage!
    }
    func png(_ cg: CGImage, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? UIImage(cgImage: cg).pngData()?.write(to: url)
    }
    func vectorPDF(_ pages: [QAScanTests.PageTruth]) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for p in pages {
                let w = p.size[0] / 200 * 72, h = p.size[1] / 200 * 72
                ctx.beginPage(withBounds: CGRect(x: 0, y: 0, width: w, height: h), pageInfo: [:])
                var y = 40.0
                let size = p.id.contains("small") ? 7.5 : (p.id.contains("receipt") ? 8.0 : 11.0)
                for line in p.lines {
                    (line as NSString).draw(in: CGRect(x: 36, y: y, width: w - 72, height: size * 3),
                                            withAttributes: [.font: UIFont.systemFont(ofSize: size)])
                    y += size * 1.6
                }
            }
        }
    }

    func testPDFQuality() async throws {
        let qa = QAScanTests.qa, pagesDir = qa.appendingPathComponent("synth/pages"), photos = qa.appendingPathComponent("synth/photos")
        let out = qa.appendingPathComponent("results/pdf")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let log = qa.appendingPathComponent("results/pdf.jsonl"); try? FileManager.default.removeItem(at: log); FileManager.default.createFile(atPath: log.path, contents: nil)
        func write(_ row: [String: Any]) throws {
            let line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            let h = try FileHandle(forWritingTo: log); h.seekToEndOfFile(); h.write(line + Data("\n".utf8)); try h.close()
        }
        let ids = try FileManager.default.contentsOfDirectory(atPath: pagesDir.path).filter { $0.hasSuffix(".json") }.sorted().map { String($0.dropLast(5)) }
        let truths = try ids.map { try JSONDecoder().decode(QAScanTests.PageTruth.self, from: Data(contentsOf: pagesDir.appendingPathComponent($0 + ".json"))) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)

        // Scanned document.
        let scanID = try library.createDraft()
        for t in truths {
            let stem = t.id + "__v1_ideal"
            let truth = try JSONDecoder().decode(QAScanTests.PhotoTruth.self, from: Data(contentsOf: photos.appendingPathComponent(stem + ".json")))
            let photo = try XCTUnwrap(CameraController.decode(Data(contentsOf: photos.appendingPathComponent(stem + ".jpg")), maxPixels: 25_000_000))
            try library.appendImage(photo, to: scanID, detectedCrop: ScanQuad(points: truth.corners.map { ScanPoint(x: $0[0], y: $0[1]) }), style: .document)
        }
        // Imported vector PDF.
        let vector = root.appendingPathComponent("vector.pdf"); try vectorPDF(truths).write(to: vector)
        let vectorID = try await library.importNativePDF(vector)

        for (docName, id) in [("scan", scanID), ("vector", vectorID)] {
            let doc = try XCTUnwrap(library.document(id))
            let t0 = CFAbsoluteTimeGetCurrent()
            let saved = try await PDFExport.prepare(doc, root: library.root)
            let saveMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            var outputs: [(String, Data, Int)] = [("saved", saved.data, saveMs)]
            if docName == "vector" { let source = try Data(contentsOf: vector); outputs.insert(("source", source, 0), at: 0) }
            for preset in CompressionPreset.allCases {
                var copy = saved.document; copy.searchable = copy.pages.contains { !$0.textBlocks.isEmpty }
                let t1 = CFAbsoluteTimeGetCurrent()
                let data = try DocumentPDF.compose(copy, root: library.root, compression: preset)
                outputs.append((preset.rawValue.replacingOccurrences(of: " ", with: "_").lowercased(), data, Int((CFAbsoluteTimeGetCurrent() - t1) * 1000)))
            }
            for (label, data, ms) in outputs {
                let pdf = try XCTUnwrap(PDFDocument(data: data))
                try data.write(to: out.appendingPathComponent("\(docName)__\(label).pdf"))
                for (i, t) in truths.enumerated() where i < pdf.pageCount {
                    try autoreleasepool {
                        let page = pdf.page(at: i)!
                        let text = t.lines.joined(separator: "\n")
                        let layer = page.string ?? ""
                        let render = renderPage(page, width: t.size[0])
                        png(render, out.appendingPathComponent("\(docName)/\(label)/\(t.id).png"))
                        let ocr = ((try? TextRecognition.recognize(render)) ?? []).map(\.text).joined(separator: "\n")
                        try write(["doc": docName, "label": label, "page": t.id, "bytes": data.count, "pages": pdf.pageCount, "ms": ms,
                                   "layer_cer": QAText.cer(truth: text, read: layer), "layer_recall": QAText.recall(truth: text, read: layer),
                                   "ocr_cer": QAText.cer(truth: text, read: ocr), "ocr_recall": QAText.recall(truth: text, read: ocr),
                                   "page_pt": [page.bounds(for: .mediaBox).width, page.bounds(for: .mediaBox).height]])
                    }
                }
            }
        }
    }
}
