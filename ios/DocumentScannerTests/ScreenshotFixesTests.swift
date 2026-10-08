import XCTest
import PDFKit
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
        if let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] {
            let folder = URL(fileURLWithPath: home).appendingPathComponent("Documents/ChatGPT/정치 중립/scanner-product/ios/Verification/private/review-shots")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: folder.appendingPathComponent("redacted-sample.pdf"))
        }
    }
}
