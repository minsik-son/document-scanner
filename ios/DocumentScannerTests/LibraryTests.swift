import XCTest
import UIKit
import PDFKit
@testable import DocumentScanner

@MainActor
final class LibraryTests: XCTestCase {
    private var roots: [URL] = []
    private func library() -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root); return LibraryStore(root: root)
    }
    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            ("INVOICE 12345" as NSString).draw(at: CGPoint(x: 50, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black])
        }
    }
    override func tearDown() async throws { for root in roots { try? FileManager.default.removeItem(at: root) }; roots = [] }
    func testDiscardCapturePreservesAcceptedPageAndExistingPDF() throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(image(), to: id)
        let accepted = try XCTUnwrap(store.document(id))
        let pdf = try Imaging.pdf(accepted, root: store.root)
        try store.savePDF(pdf, document: accepted)
        let pdfName = try XCTUnwrap(store.document(id)?.pdfFile)
        try store.appendImage(image(), to: id)
        let rejected = try XCTUnwrap(store.document(id)?.pages.last)
        XCTAssertThrowsError(try store.discardCapturedPage(accepted.pages[0].id, from: id))
        XCTAssertEqual(store.document(id)?.pages.count, 2)
        try store.discardCapturedPage(rejected.id, from: id)
        let reopened = LibraryStore(root: store.root)
        XCTAssertEqual(reopened.document(id)?.pages, accepted.pages)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(rejected.imageFile).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(accepted.pages[0].imageFile).path))
        XCTAssertEqual(try Data(contentsOf: reopened.url(pdfName)), pdf)
    }
    func testDiscardOnlyCaptureLeavesNoRecoverableScanAndCleansEmptyDraft() throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(image(), to: id)
        let page = try XCTUnwrap(store.document(id)?.pages.first)
        try store.discardCapturedPage(page.id, from: id)
        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(store.document(id)?.pages.count, 0)
        XCTAssertTrue(LibraryStore(root: store.root).drafts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(page.imageFile).path))
        try store.discardEmptyDrafts()
        XCTAssertTrue(store.documents.isEmpty)
    }
    func testFailedCaptureCancellationKeepsPageAndPixels() throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(image(), to: id)
        let page = try XCTUnwrap(store.document(id)?.pages.first)
        let bytes = try Data(contentsOf: store.url(page.imageFile))
        let index = store.url("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.discardCapturedPage(page.id, from: id))
        XCTAssertEqual(store.document(id)?.pages, [page])
        XCTAssertEqual(try Data(contentsOf: store.url(page.imageFile)), bytes)
    }
    func testCapturedPagesSurviveRelaunch() throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(image(), to: id)
        let reopened = LibraryStore(root: store.root)
        XCTAssertEqual(reopened.drafts.first?.pages.count, 1)
        let page = try XCTUnwrap(reopened.document(id)?.pages.first)
        XCTAssertNotNil(UIImage(contentsOfFile: reopened.url(page.imageFile).path))
    }
    func testRepeatedNewScanDoesNotAccumulateEmptySessions() throws {
        let store = library(), first = try store.createDraft()
        for _ in 0..<20 { XCTAssertEqual(try store.createDraft(), first) }
        XCTAssertEqual(store.documents.count, 1)
        try store.appendImage(image(), to: first)
        let next = try store.createDraft()
        XCTAssertNotEqual(next, first)
        for _ in 0..<20 { XCTAssertEqual(try store.createDraft(), next) }
        XCTAssertEqual(store.documents.count, 2)
        try store.discardEmptyDrafts()
        let reopened = LibraryStore(root: store.root)
        XCTAssertEqual(reopened.documents.map(\.id), [first])
        XCTAssertEqual(reopened.document(first)?.pages.count, 1)
    }
    func testNewScanCollapsesLegacyEmptySessionsWithoutLosingCapturedPages() throws {
        let store = library(), capturedID = try store.createDraft()
        try store.appendImage(image(), to: capturedID)
        for number in 1...5 { try store.update(ScanDocument(title: "Empty session \(number)")) }
        let latest = try XCTUnwrap(store.documents.last)
        XCTAssertEqual(try store.createDraft(), latest.id)
        XCTAssertEqual(Set(store.documents.map(\.id)), Set([capturedID, latest.id]))
        XCTAssertEqual(store.document(capturedID)?.pages.count, 1)
    }
    func testEmptyCleanupPreservesPDFsSavedRecordsAndTrash() throws {
        let store = library(), capturedID = try store.createDraft()
        try store.appendImage(image(), to: capturedID)
        let page = try XCTUnwrap(store.document(capturedID)?.pages.first)
        let original = try Data(contentsOf: store.url(page.imageFile))
        var pdfDraft = ScanDocument(title: "Draft with PDF")
        pdfDraft.pdfFile = "retained.pdf"
        let pdfBytes = try Imaging.pdf(try XCTUnwrap(store.document(capturedID)), root: store.root)
        try pdfBytes.write(to: store.url("retained.pdf"))
        try store.update(pdfDraft)
        var saved = ScanDocument(title: "Saved record"); saved.isDraft = false
        try store.update(saved)
        var trashed = ScanDocument(title: "Deleted empty session"); trashed.deletedAt = Date()
        try store.update(trashed)
        for number in 1...3 { try store.update(ScanDocument(title: "Empty session \(number)")) }
        try store.discardEmptyDrafts()
        let reopened = LibraryStore(root: store.root)
        XCTAssertEqual(Set(reopened.documents.map(\.id)), Set([capturedID, pdfDraft.id, saved.id, trashed.id]))
        XCTAssertEqual(try Data(contentsOf: reopened.url(page.imageFile)), original)
        XCTAssertEqual(try Data(contentsOf: reopened.url("retained.pdf")), pdfBytes)
        XCTAssertEqual(reopened.trash.map(\.id), [trashed.id])
    }
    func testFailedEmptyCleanupLeavesManifestUnchanged() throws {
        let store = library(), id = try store.createDraft()
        let index = store.root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.discardEmptyDrafts())
        XCTAssertEqual(store.documents.map(\.id), [id])
        XCTAssertThrowsError(try store.createDraft())
        XCTAssertEqual(store.documents.map(\.id), [id])
    }
    func testFailedIndexWriteDoesNotAcknowledgeCapturedPage() throws {
        let store = library(), id = try store.createDraft()
        let index = store.root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.appendImage(image(), to: id))
        XCTAssertEqual(store.document(id)?.pages.count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasSuffix("jpg") }.count, 0)
    }
    func testCorruptLibraryNeverOverwritten() throws {
        let store = library()
        let bytes = Data("corrupt".utf8), url = store.root.appendingPathComponent("library.json")
        try bytes.write(to: url)
        let reopened = LibraryStore(root: store.root)
        XCTAssertFalse(reopened.storageAvailable)
        XCTAssertThrowsError(try reopened.createDraft())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testPDFSaveReopensWithCorrectPageCount() throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(image(), to: id); try store.appendImage(image(), to: id)
        var doc = try XCTUnwrap(store.document(id)); doc.pages[0].turns = 1; doc.pages[1].enhancement = .mono
        let bytes = try Imaging.pdf(doc, root: store.root)
        try store.savePDF(bytes, document: doc)
        let reopened = LibraryStore(root: store.root)
        XCTAssertEqual(reopened.active.count, 1); XCTAssertEqual(reopened.drafts.count, 0)
        let name = try XCTUnwrap(reopened.document(id)?.pdfFile)
        let pdf = try XCTUnwrap(PDFDocument(url: reopened.url(name)))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).width, 612)
    }
    func testMissingPageDoesNotReplaceExistingPDF() throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(image(), to: id)
        var doc = try XCTUnwrap(store.document(id))
        try store.savePDF(Imaging.pdf(doc, root: store.root), document: doc)
        let before = try XCTUnwrap(store.document(id)?.pdfFile)
        doc.pages[0].imageFile = "missing.jpg"
        XCTAssertThrowsError(try Imaging.pdf(doc, root: store.root))
        XCTAssertEqual(store.document(id)?.pdfFile, before)
        XCTAssertNotNil(PDFDocument(url: store.url(before)))
    }
    func testBackupRestoreSkipsDuplicateAndPreservesDocument() throws {
        let source = library(), id = try source.createDraft(); try source.appendImage(image(), to: id)
        let backup = try source.exportBackup(); defer { try? FileManager.default.removeItem(at: backup) }
        let target = library(); try target.importBackup(backup); try target.importBackup(backup)
        XCTAssertEqual(target.documents.count, 1)
        XCTAssertEqual(target.document(id)?.pages.count, 1)
        XCTAssertNotEqual(target.document(id)?.pages[0].imageFile, source.document(id)?.pages[0].imageFile)
    }
    func testTamperedBackupDoesNotModifyLibrary() throws {
        let source = library(), id = try source.createDraft(); try source.appendImage(image(), to: id)
        let backup = try source.exportBackup(); defer { try? FileManager.default.removeItem(at: backup) }
        var payload = try Data(contentsOf:backup)
        payload[payload.count-1] ^= 0xFF
        try payload.write(to:backup)
        let target = library(); let existing = try target.createDraft()
        XCTAssertThrowsError(try target.importBackup(backup))
        XCTAssertEqual(target.documents.map(\.id), [existing])
    }
    func testTrashRestoreAndPermanentDelete() throws {
        let store = library(), id = try store.createDraft(); try store.appendImage(image(), to: id)
        let doc = try XCTUnwrap(store.document(id)); let asset = store.url(doc.pages[0].imageFile)
        store.moveToTrash(doc); XCTAssertEqual(store.trash.count, 1)
        store.restore(try XCTUnwrap(store.document(id))); XCTAssertTrue(store.trash.isEmpty)
        try store.permanentlyDelete(try XCTUnwrap(store.document(id)))
        XCTAssertNil(store.document(id)); XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path))
    }
    func testSavedDocumentCanBeTrashedAndRestoredWithItsPDF() throws {
        let store = library(), id = try store.createDraft()
        try store.appendImage(image(), to: id)
        let draft = try XCTUnwrap(store.document(id))
        try store.savePDF(Imaging.pdf(draft, root: store.root), document: draft)
        let saved = try XCTUnwrap(store.document(id))
        let name = try XCTUnwrap(saved.pdfFile), pdfBytes = try Data(contentsOf: store.url(name))
        store.moveToTrash(saved)
        XCTAssertTrue(store.active.isEmpty)
        let reopened = LibraryStore(root: store.root)
        XCTAssertEqual(reopened.trash.map(\.id), [id])
        reopened.restore(try XCTUnwrap(reopened.document(id)))
        XCTAssertEqual(reopened.active.map(\.id), [id])
        XCTAssertTrue(reopened.trash.isEmpty)
        XCTAssertEqual(try Data(contentsOf: reopened.url(name)), pdfBytes)
        XCTAssertEqual(PDFDocument(url: reopened.url(name))?.pageCount, 1)
        XCTAssertNotNil(UIImage(contentsOfFile: reopened.url(saved.pages[0].imageFile).path))
    }
    func testSearchablePDFContainsRecognizedText() throws {
        let store = library(), id = try store.createDraft(); try store.appendImage(image(), to: id)
        var doc = try XCTUnwrap(store.document(id))
        doc.pages[0].textBlocks = try Imaging.recognize(Imaging.render(doc.pages[0], root: store.root))
        doc.pages[0].ocrComplete = true; doc.searchable = true
        let pdf = try XCTUnwrap(PDFDocument(data: Imaging.pdf(doc, root: store.root)))
        XCTAssertTrue(pdf.string?.contains("12345") == true)
        let selections = pdf.findString("12345", withOptions: [])
        XCTAssertFalse(selections.isEmpty)
        let page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertGreaterThan(selections[0].bounds(for: page).width, 0)
    }
    func testCropRejectsCrossingAndNonfiniteCorners() {
        var quad = ScanQuad.full; quad.points.swapAt(0, 1); XCTAssertFalse(quad.valid)
        quad = .full; quad.points[0].x = .nan; XCTAssertFalse(quad.valid)
        XCTAssertTrue(ScanQuad.full.valid)
    }
    func testOCRFindsTextOffline() throws {
        let blocks = try Imaging.recognize(Imaging.normalized(image()))
        XCTAssertTrue(blocks.map(\.text).joined().contains("12345"))
        XCTAssertTrue(blocks.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.width > 0 && $0.height > 0 })
    }
}
