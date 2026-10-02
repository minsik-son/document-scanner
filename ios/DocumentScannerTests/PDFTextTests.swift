import XCTest
import UIKit
import PDFKit
@testable import DocumentScanner

@MainActor
final class PDFTextTests: XCTestCase {
    private func fixture() throws -> (LibraryStore, ScanDocument) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(root: root), id = try store.createDraft()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 60, y: 350, width: 200, height: 120))
            ("Visible source 24680" as NSString).draw(at: CGPoint(x: 60, y: 520), withAttributes: [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black])
        }
        try store.appendImage(image, to: id, enhancement: .original)
        var document = try XCTUnwrap(store.document(id))
        document.margin = .standard
        return (store, document)
    }

    func testMixedScriptWordsSelectAtTheirImagePositionsWithoutProFlag() throws {
        let (store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var document = original
        let words = [TextWord(text: "INVOICE", x: 0.1, y: 0.1, width: 0.2, height: 0.04),
                     TextWord(text: "서울", x: 0.6, y: 0.1, width: 0.1, height: 0.04),
                     TextWord(text: "10.41.22.xx", x: 0.1, y: 0.3, width: 0.28, height: 0.04)]
        document.pages[0].textBlocks = [TextBlock(text: "INVOICE 서울", x: 0.1, y: 0.1, width: 0.6, height: 0.04, words: Array(words.prefix(2))),
                                             TextBlock(text: "10.41.22.xx", x: 0.1, y: 0.3, width: 0.28, height: 0.04, words: [words[2]])]
        // A page's actual OCR determines the PDF layer; a subscription/legacy flag cannot suppress it.
        XCTAssertFalse(document.searchable)
        let pdf = try XCTUnwrap(PDFDocument(data: Imaging.pdf(document, root: store.root)))
        let page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertTrue(pdf.string?.contains("INVOICE 서울") == true)
        let imageRect = CGRect(x: 36, y: 36, width: 540, height: 720)
        for word in words {
            let expected = CGRect(x: imageRect.minX + CGFloat(word.x) * imageRect.width,
                                  y: CGFloat(792) - (imageRect.minY + CGFloat(word.y + word.height) * imageRect.height),
                                  width: CGFloat(word.width) * imageRect.width, height: CGFloat(word.height) * imageRect.height)
            let selection = try XCTUnwrap(pdf.findString(word.text, withOptions: []).first)
            let actual = selection.bounds(for: page)
            XCTAssertEqual(actual.midX, expected.midX, accuracy: 1, word.text)
            XCTAssertEqual(actual.midY, expected.midY, accuracy: 1, word.text)
            XCTAssertEqual(actual.width, expected.width, accuracy: 1, word.text)
            XCTAssertEqual(actual.height, expected.height, accuracy: 1, word.text)
            XCTAssertEqual(page.selection(for: expected)?.string, word.text)
        }
    }

    func testHiddenTextDoesNotChangePDFImagePixelsAndOldBlocksStillSelect() throws {
        let (store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let beforePDF = try XCTUnwrap(PDFDocument(data: Imaging.pdf(original, root: store.root)))
        let before = try XCTUnwrap(beforePDF.page(at: 0))
        var document = original
        // A saved pre-word-geometry block remains usable after an upgrade.
        document.pages[0].textBlocks = [TextBlock(text: "Legacy invoice 12345", x: 0.1, y: 0.2, width: 0.7, height: 0.05)]
        let afterPDF = try XCTUnwrap(PDFDocument(data: Imaging.pdf(document, root: store.root)))
        let after = try XCTUnwrap(afterPDF.page(at: 0))
        XCTAssertTrue(after.string?.contains("Legacy invoice 12345") == true)
        withExtendedLifetime((beforePDF, afterPDF)) {
            let beforePixels = before.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox).pngData()
            let afterPixels = after.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox).pngData()
            XCTAssertNotNil(beforePixels)
            XCTAssertEqual(beforePixels, afterPixels)
        }
    }

    func testAccurateOCRRetainsMixedEnglishKoreanAndWordBounds() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1600)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
            ("INVOICE 서울 12345" as NSString).draw(at: CGPoint(x: 100, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 56), .foregroundColor: UIColor.black])
        }
        let blocks = try Imaging.recognize(image)
        let text = blocks.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("INVOICE"), text)
        XCTAssertTrue(text.contains("서울"), text)
        XCTAssertTrue(text.contains("12345"), text)
        let word = try XCTUnwrap(blocks.flatMap { $0.words ?? [] }.first { $0.text.contains("12345") })
        XCTAssertGreaterThan(word.x, 0.3)
        XCTAssertLessThan(word.y, 0.2)
        XCTAssertGreaterThan(word.width, 0)
    }

    func testKoreanInsideLatinParenthesesHasItsOwnSelectablePDFRegion() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1300, height: 500), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1300, height: 500))
            ("Montreal(몬트리올) Toronto(토론토)" as NSString).draw(at: CGPoint(x: 50, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 42), .foregroundColor: UIColor.black])
        }
        let blocks = try Imaging.recognize(image)
        let words = blocks.flatMap { $0.words ?? [] }
        let (store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var doc = original
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: store.url(doc.pages[0].imageFile))
        doc.pages[0].textBlocks = blocks
        let pdf = try XCTUnwrap(PDFDocument(data: Imaging.pdf(doc, root: store.root)))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let fittedHeight = CGFloat(540) * 500 / 1300
        let imageRect = CGRect(x: 36, y: (792-fittedHeight)/2, width: 540, height: fittedHeight)
        for name in ["몬트리올", "토론토"] {
            let word = try XCTUnwrap(words.first { $0.text == name }, blocks.map(\.text).joined(separator: "\n"))
            let box = CGRect(x: imageRect.minX + word.x * imageRect.width,
                             y: imageRect.maxY - (word.y + word.height) * imageRect.height,
                             width: word.width * imageRect.width, height: word.height * imageRect.height)
            XCTAssertEqual(page.selection(for: box)?.string, name)
            XCTAssertFalse(pdf.findString(name, withOptions: []).isEmpty)
        }
    }

    func testUnicodeTextLayerSelectsMajorScriptsAndCombiningMarks() throws {
        let (store, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var doc = original
        let samples = ["한국어", "日本語", "繁體中文", "简体中文", "Русский", "العربية", "ภาษาไทย", "हिन्दी", "עברית", "Ελληνικά", "Français", "Tiếng Việt"]
        doc.pages[0].textBlocks = samples.enumerated().map { index, text in
            TextBlock(text: text, x: 0.1, y: 0.05 + Double(index)*0.07, width: 0.7, height: 0.04)
        }
        let pdf = try XCTUnwrap(PDFDocument(data: Imaging.pdf(doc, root: store.root)))
        let page = try XCTUnwrap(pdf.page(at: 0))
        for (index, text) in samples.enumerated() {
            let y = 0.05 + Double(index)*0.07
            let box = CGRect(x: 90, y: 756 - (y+0.04)*720, width: 378, height: 28.8)
            let selected = try XCTUnwrap(page.selection(for: box)?.string, text)
            // Complex scripts may use canonically equivalent composed forms.
            XCTAssertEqual(selected.precomposedStringWithCanonicalMapping, text.precomposedStringWithCanonicalMapping)
        }
    }

    func testOCRRecoversDifferentScriptsOnTheSamePage() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let lines = ["한국어 서울", "日本語 東京", "中文 北京", "Русский Москва", "العربية", "ภาษาไทย", "Français été"]
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1500, height: 1400), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1500, height: 1400))
            for (index, text) in lines.enumerated() {
                (text as NSString).draw(at: CGPoint(x: 100, y: 100 + index*175), withAttributes: [.font: UIFont.systemFont(ofSize: 54), .foregroundColor: UIColor.black])
            }
        }
        let recognized = try Imaging.recognize(image).map(\.text).joined(separator: "\n")
        for text in ["서울", "東京", "北京", "Москва", "العربية", "ภาษาไทย", "Français"] {
            XCTAssertTrue(recognized.contains(text), "Missing \(text):\n\(recognized)")
        }
    }
}
