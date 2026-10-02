import XCTest
import UIKit
import PDFKit
@testable import DocumentScanner

@MainActor
final class PDFExportTests: XCTestCase {
    private var roots: [URL] = []
    private func library() -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        return LibraryStore(root: root)
    }
    private func image(_ text: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1000), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
            (text as NSString).draw(at: CGPoint(x: 70, y: 130), withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black])
        }
    }
    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }
    func testOrdinarySaveEmbedsTextOnEveryPageAndPersistsIt() async throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(image("INVOICE 12345"), to: id, detectedCrop: .full)
        try store.appendImage(image("RECEIPT 67890"), to: id, detectedCrop: .full)
        let draft = try XCTUnwrap(store.document(id))
        let result = try await PDFExport.prepare(draft, root: store.root)
        // Preparation must not make uncommitted metadata look like a saved PDF.
        XCTAssertTrue(try XCTUnwrap(store.document(id)).isDraft)
        XCTAssertNil(store.document(id)?.pdfFile)
        try store.savePDF(result.data, document: result.document)
        let reopened = LibraryStore(root: store.root)
        let saved = try XCTUnwrap(reopened.document(id))
        let pdf = try XCTUnwrap(PDFDocument(url: reopened.url(try XCTUnwrap(saved.pdfFile))))
        XCTAssertTrue(saved.searchable)
        XCTAssertEqual(saved.textStatus, "Searchable PDF")
        XCTAssertEqual(pdf.pageCount, 2)
        for (index, word) in ["12345", "67890"].enumerated() {
            let page = try XCTUnwrap(pdf.page(at: index))
            XCTAssertTrue(page.string?.contains(word) == true)
            let selection = try XCTUnwrap(pdf.findString(word, withOptions: []).first)
            XCTAssertGreaterThan(selection.bounds(for: page).width, 5)
        }
        XCTAssertNil(result.textNotice)
    }
    func testBlankScanDoesNotClaimSelectableText() async throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(image(""), to: id, detectedCrop: .full)
        let result = try await PDFExport.prepare(try XCTUnwrap(store.document(id)), root: store.root)
        XCTAssertFalse(result.document.searchable)
        XCTAssertTrue(result.document.pages[0].ocrComplete)
        XCTAssertEqual(result.document.textStatus, "Image only")
        XCTAssertEqual(PDFDocument(data: result.data)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "")
        XCTAssertNotNil(result.textNotice)
    }
    func testOldOCRCoordinatesAreRebuiltByOrdinarySave() async throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(image("CURRENT 24680"), to: id, detectedCrop: .full)
        var doc = try XCTUnwrap(store.document(id))
        doc.pages[0].textBlocks = [TextBlock(text: "STALE 99999", x: 0.1, y: 0.5, width: 0.5, height: 0.1)]
        doc.pages[0].ocrComplete = true
        doc.pages[0].ocrProcessingVersion = nil
        let result = try await PDFExport.prepare(doc, root: store.root)
        let text = try XCTUnwrap(PDFDocument(data: result.data)?.string)
        XCTAssertTrue(text.contains("24680"))
        XCTAssertFalse(text.contains("99999"))
    }
    func testMissingSourceKeepsPreviousPDFAndMetadata() async throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(image("ORIGINAL 13579"), to: id, detectedCrop: .full)
        let initial = try await PDFExport.prepare(try XCTUnwrap(store.document(id)), root: store.root)
        try store.savePDF(initial.data, document: initial.document)
        let before = try XCTUnwrap(store.document(id))
        var edited = before; edited.pages[0].imageFile = "missing.jpg"
        do {
            _ = try await PDFExport.prepare(edited, root: store.root, forceText: true)
            XCTFail("A missing original must not export successfully")
        } catch {
            XCTAssertEqual(store.document(id), before)
            XCTAssertTrue(PDFDocument(url: store.url(try XCTUnwrap(before.pdfFile)))?.string?.contains("13579") == true)
        }
    }
}
