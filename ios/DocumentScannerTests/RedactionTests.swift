import XCTest
import UIKit
import PDFKit
@testable import DocumentScanner

@MainActor
final class RedactionTests: XCTestCase {
    private var roots: [URL] = []
    private func library() -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        return LibraryStore(root: root)
    }
    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }
    /// "VISIBLE TEXT" near the top, "SECRET 98765" lower down.
    private func page() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1000), format: format).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
            let font: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black]
            ("VISIBLE TEXT" as NSString).draw(at: CGPoint(x: 70, y: 130), withAttributes: font)
            ("SECRET 98765" as NSString).draw(at: CGPoint(x: 70, y: 600), withAttributes: font)
        }
    }
    /// The lower line, on the finished page.
    private let secretArea = CGRect(x: 0.05, y: 0.585, width: 0.9, height: 0.09)

    func testGeometryRoundTripsThroughTurnsAndMargins() {
        let rects = [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1), CGRect(x: 0.6, y: 0.7, width: 0.2, height: 0.05)]
        let trims = [PageTrim(), PageTrim(top: 0.05, right: 0.1, bottom: 0.02, left: 0.07)]
        for turns in 0..<4 { for trim in trims { for r in rects {
            let back = RedactionGeometry.toSheet(RedactionGeometry.toPage(r, turns: turns, trim: trim), turns: turns, trim: trim)
            XCTAssertEqual(back.minX, r.minX, accuracy: 1e-9); XCTAssertEqual(back.minY, r.minY, accuracy: 1e-9)
            XCTAssertEqual(back.width, r.width, accuracy: 1e-9); XCTAssertEqual(back.height, r.height, accuracy: 1e-9)
        } } }
        // One clockwise turn: the top-left corner goes to the top-right.
        let turned = RedactionGeometry.toPage(CGRect(x: 0, y: 0, width: 0.1, height: 0.2), turns: 1, trim: PageTrim())
        XCTAssertEqual(turned.minX, 0.8, accuracy: 1e-9); XCTAssertEqual(turned.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(turned.width, 0.2, accuracy: 1e-9); XCTAssertEqual(turned.height, 0.1, accuracy: 1e-9)
    }

    func testScrubDropsHiddenWordsAndKeepsTheRestOfTheLine() {
        let words = [TextWord(text: "Phone", x: 0.1, y: 0.5, width: 0.1, height: 0.03), TextWord(text: "010-1234-5678", x: 0.25, y: 0.5, width: 0.25, height: 0.03)]
        let line = TextBlock(text: "Phone 010-1234-5678", x: 0.1, y: 0.5, width: 0.4, height: 0.03, words: words)
        let other = TextBlock(text: "Total", x: 0.1, y: 0.8, width: 0.1, height: 0.03)
        let out = RedactionGeometry.scrub([line, other], boxes: [CGRect(x: 0.24, y: 0.49, width: 0.27, height: 0.05)])
        XCTAssertEqual(out.map(\.text), ["Phone", "Total"])
    }

    func testHiddenAreaIsBlackAndItsTextIsInNoOutput() async throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(page(), to: id, detectedCrop: .full)
        var doc = try XCTUnwrap(store.document(id))
        doc.pages[0].setRedaction(hidden: [secretArea], visible: [])
        try store.update(doc)
        let result = try await PDFExport.prepare(try XCTUnwrap(store.document(id)), root: store.root)
        let pdf = try XCTUnwrap(PDFDocument(data: result.data))
        let text = pdf.string ?? ""
        XCTAssertTrue(text.contains("VISIBLE"), text)
        XCTAssertFalse(text.contains("98765"), text)
        XCTAssertFalse(result.document.pages[0].plainText.contains("98765"))
        // The picture itself is covered.
        let shot = try XCTUnwrap(pdf.page(at: 0)).thumbnail(of: CGSize(width: 400, height: 500), for: .mediaBox)
        XCTAssertLessThan(luminance(shot, at: CGPoint(x: 0.3, y: 0.63)), 0.1)
        XCTAssertGreaterThan(luminance(shot, at: CGPoint(x: 0.5, y: 0.9)), 0.9)
        // Office exports read the page through the same render.
        let render = try Imaging.render(result.document.pages[0], root: store.root)
        XCTAssertFalse(try Imaging.recognize(render).map(\.text).joined().contains("98765"))
    }

    func testTurningThePageKeepsTheBoxOnTheSameWords() async throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(page(), to: id, detectedCrop: .full)
        var doc = try XCTUnwrap(store.document(id))
        doc.pages[0].setRedaction(hidden: [secretArea], visible: [])
        doc.pages[0].turns = 1; doc.pages[0].trimming = doc.pages[0].trimming.rotatedClockwise()
        XCTAssertFalse(doc.pages[0].redactionNeedsCheck)
        try store.update(doc)
        let result = try await PDFExport.prepare(try XCTUnwrap(store.document(id)), root: store.root)
        let text = PDFDocument(data: result.data)?.string ?? ""
        XCTAssertFalse(text.contains("98765"), text)
    }

    func testNewCropOrToneAsksForACheckButKeepsCovering() {
        var page = ScanPage(imageFile: "x.jpg")
        page.setRedaction(hidden: [secretArea], visible: [])
        XCTAssertFalse(page.redactionNeedsCheck)
        page.enhancement = .gray
        XCTAssertTrue(page.redactionNeedsCheck)
        XCTAssertEqual(page.redactionBoxes.count, 1)
        page.setRedaction(hidden: page.redactionBoxes, visible: [])
        XCTAssertFalse(page.redactionNeedsCheck)
        XCTAssertFalse(page.preservesPDF)
    }

    func testImportedTextPDFWithHiddenWordIsRedrawn() async throws {
        let store = library()
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).pdfData { c in
            c.beginPage()
            let font: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 30)]
            ("PUBLIC LINE" as NSString).draw(at: CGPoint(x: 50, y: 100), withAttributes: font)
            ("ACCOUNT 55443322" as NSString).draw(at: CGPoint(x: 50, y: 500), withAttributes: font)
        }
        let url = store.root.appendingPathComponent("vector.pdf")
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try bytes.write(to: url)
        let id = try await store.importNativePDF(url)
        var doc = try XCTUnwrap(store.document(id))
        XCTAssertTrue(doc.pages[0].preservesPDF)
        doc.pages[0].setRedaction(hidden: [CGRect(x: 0.05, y: 0.6, width: 0.9, height: 0.08)], visible: [])
        try store.update(doc)
        let result = try await PDFExport.prepare(try XCTUnwrap(store.document(id)), root: store.root)
        let text = PDFDocument(data: result.data)?.string ?? ""
        XCTAssertTrue(text.contains("PUBLIC"), text)
        XCTAssertFalse(text.contains("55443322"), text)
    }

    func testEditorDoesNotSuggestAgainWhatWasKeptVisible() {
        let phone = TextBlock(text: "Phone 010-1234-5678", x: 0.1, y: 0.5, width: 0.4, height: 0.03,
                              words: [TextWord(text: "Phone", x: 0.1, y: 0.5, width: 0.1, height: 0.03), TextWord(text: "010-1234-5678", x: 0.25, y: 0.5, width: 0.25, height: 0.03)])
        var page = ScanPage(imageFile: "x.jpg")
        let first = RedactionEditor.marks(for: page, blocks: [phone])
        XCTAssertEqual(first.filter(\.hidden).count, 1)
        page.setRedaction(hidden: [], visible: first.map(\.rect))
        let again = RedactionEditor.marks(for: page, blocks: [phone])
        XCTAssertEqual(again.filter(\.hidden).count, 0)
        XCTAssertEqual(again.count, 1)
    }

    func testEraseUsesTheBackgroundAndMosaicHidesTheLetters() throws {
        // Dark text on a light-blue cell.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let cell = UIColor(red: 0.8, green: 0.9, blue: 1, alpha: 1)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200), format: format).image { c in
            cell.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
            ("SECRET 4242" as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 36), .foregroundColor: UIColor.black])
        }
        let box = CGRect(x: 0.12, y: 0.38, width: 0.7, height: 0.3)
        var page = ScanPage(imageFile: "x.jpg")
        page.setRedaction(hidden: [box], visible: [], style: .erase)
        let erased = Imaging.applyRedactions(image, page: page)
        for x in [0.2, 0.4, 0.6] {
            let rgb = color(erased, at: CGPoint(x: x, y: 0.53))
            XCTAssertEqual(rgb.0, 0.8, accuracy: 0.05); XCTAssertEqual(rgb.2, 1, accuracy: 0.05)
        }
        XCTAssertFalse(try Imaging.recognize(erased).map(\.text).joined().contains("4242"))
        page.setRedaction(hidden: [box], visible: [], style: .mosaic)
        let mosaic = Imaging.applyRedactions(image, page: page)
        XCTAssertFalse(try Imaging.recognize(mosaic).map(\.text).joined().contains("4242"))
        // Large blocks: neighbouring pixels inside a block are the same colour.
        let a = color(mosaic, at: CGPoint(x: 0.3, y: 0.5)), b = color(mosaic, at: CGPoint(x: 0.3025, y: 0.505))
        XCTAssertEqual(a.0, b.0, accuracy: 0.01); XCTAssertEqual(a.1, b.1, accuracy: 0.01)
        // Outside the box nothing changes.
        XCTAssertEqual(color(mosaic, at: CGPoint(x: 0.05, y: 0.1)).0, 0.8, accuracy: 0.02)
    }

    private func color(_ image: UIImage, at unit: CGPoint) -> (CGFloat, CGFloat, CGFloat) {
        guard let cg = image.cgImage else { return (-1, -1, -1) }
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let x = unit.x * CGFloat(cg.width), y = unit.y * CGFloat(cg.height)
        ctx.draw(cg, in: CGRect(x: -x, y: -(CGFloat(cg.height) - y), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (CGFloat(pixel[0]) / 255, CGFloat(pixel[1]) / 255, CGFloat(pixel[2]) / 255)
    }

    private func luminance(_ image: UIImage, at unit: CGPoint) -> CGFloat {
        guard let cg = image.cgImage else { return -1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let x = unit.x * CGFloat(cg.width), y = unit.y * CGFloat(cg.height)
        ctx.draw(cg, in: CGRect(x: -x, y: -(CGFloat(cg.height) - y), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / (3 * 255)
    }
}
