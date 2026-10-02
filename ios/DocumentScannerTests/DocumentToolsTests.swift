import CryptoKit
import PDFKit
import UIKit
import XCTest

@testable import DocumentScanner

@MainActor
final class DocumentToolsTests: XCTestCase {
  private var roots: [URL] = []
  private func store() -> LibraryStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    roots.append(root)
    return LibraryStore(root: root)
  }
  override func tearDown() async throws {
    for root in roots { try? FileManager.default.removeItem(at: root) }
  }
  private func textPDF() -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { ctx in
      for name in ["ALPHA original text", "BETA original text"] {
        ctx.beginPage()
        (name as NSString).draw(
          at: CGPoint(x: 30, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
      }
    }
  }
  func testEditingStagingDoesNotReplaceSavedDocumentUntilCommit() async throws {
    let library = store()
    let file = library.root.appendingPathComponent("input.pdf")
    try textPDF().write(to: file)
    let id = try await library.importNativePDF(file)
    let original = try XCTUnwrap(library.document(id))
    try library.savePDF(DocumentPDF.compose(original, root: library.root), document: original)
    let saved = try XCTUnwrap(library.document(id))
    let stagingID = try library.makeEditingDraft(saved)
    var staging = try XCTUnwrap(library.document(stagingID))
    staging.pages.removeFirst()
    try library.update(staging)
    XCTAssertEqual(library.document(id), saved)
    var accepted = saved
    accepted.pages = staging.pages
    let bytes = try DocumentPDF.compose(accepted, root: library.root)
    try library.savePDF(bytes, document: accepted, replacingDraft: stagingID)
    XCTAssertNil(library.document(stagingID))
    XCTAssertEqual(library.document(id)?.pages.count, 1)
  }
  func testReusableSignaturesAreOptInForBackup() throws {
    let library = store()
    let signature = PageAnnotation(
      kind: .signature, strokes: [[.init(x: 0, y: 0), .init(x: 1, y: 1)]])
    try library.saveSignatures([signature])
    let excluded = try library.exportBackup()
    defer { try? FileManager.default.removeItem(at: excluded) }
    let restored = store()
    try restored.importBackup(excluded)
    XCTAssertTrue((restored.manifest.signatures ?? []).isEmpty)
    let included = try library.exportBackup(includeSignatures: true)
    defer { try? FileManager.default.removeItem(at: included) }
    try restored.importBackup(included)
    XCTAssertEqual(restored.manifest.signatures, [signature])
  }
  func testImageOnlyImportedPDFGetsAutomaticSelectableText() async throws {
    let library = store()
    let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { c in
      UIColor.white.setFill()
      c.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
      ("IMPORTED SCAN 24680" as NSString).draw(
        at: CGPoint(x: 50, y: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 32)])
    }
    let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).pdfData {
      c in
      c.beginPage()
      image.draw(in: CGRect(x: 0, y: 0, width: 600, height: 800))
    }
    let url = library.root.appendingPathComponent("image.pdf")
    try bytes.write(to: url)
    let id = try await library.importNativePDF(url)
    let result = try await PDFExport.prepare(
      try XCTUnwrap(library.document(id)), root: library.root)
    XCTAssertTrue(result.document.searchable)
    XCTAssertTrue(PDFDocument(data: result.data)?.string?.contains("24680") == true)
    try library.savePDF(result.data, document: result.document)
    let cache = library.root.appendingPathComponent("OCRCache")
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    try library.permanentlyDelete(try XCTUnwrap(library.document(id)))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
  }
  func testStreamingBackupCorruptionTruncationAndLegacyCompatibility() throws {
    let library = store()
    let id = try library.createDraft()
    let image = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { c in
      UIColor.white.setFill()
      c.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
    }
    try library.appendImage(image, to: id, detectedCrop: .full)
    let archive = try library.exportBackup()
    defer { try? FileManager.default.removeItem(at: archive) }
    let bytes = try Data(contentsOf: archive)
    let restored = store()
    var corrupted = bytes
    corrupted[corrupted.count - 1] ^= 1
    let bad = library.root.appendingPathComponent("bad.scanbackup")
    for data in [corrupted, Data(bytes.dropLast()), bytes + Data([0])] {
      try data.write(to: bad)
      XCTAssertThrowsError(try restored.importBackup(bad))
      XCTAssertTrue(restored.documents.isEmpty)
    }
    let page = try XCTUnwrap(library.document(id)?.pages.first)
    let data = try Data(contentsOf: library.url(page.imageFile))
    let legacy = LibraryStore.Backup(
      version: 1, manifest: library.manifest, assets: [page.imageFile: data],
      hashes: [page.imageFile: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
    try JSONEncoder().encode(legacy).write(to: bad)
    try restored.importBackup(bad)
    XCTAssertEqual(restored.drafts.first?.pages.count, 1)
  }
  func testCommonPaperLayoutKeepsNativeTextAndTransformedLinks() async throws {
    let library = store()
    let file = library.root.appendingPathComponent("layout.pdf")
    let source = try XCTUnwrap(PDFDocument(data: textPDF()))
    let link = PDFAnnotation(
      bounds: CGRect(x: 30, y: 510, width: 200, height: 30), forType: .link, withProperties: nil)
    link.url = URL(string: "https://example.com")
    source.page(at: 0)?.addAnnotation(link)
    try XCTUnwrap(source.dataRepresentation()).write(to: file)
    let id = try await library.importNativePDF(file)
    var doc = try XCTUnwrap(library.document(id))
    doc.paper = .a4
    doc.margin = .standard
    doc.landscape = true
    doc.pages[0].turns = 1
    let pdf = try XCTUnwrap(PDFDocument(data: DocumentPDF.compose(doc, root: library.root)))
    let page = try XCTUnwrap(pdf.page(at: 0))
    XCTAssertEqual(page.bounds(for: .mediaBox).width, doc.outputSize.width, accuracy: 1)
    XCTAssertEqual(page.bounds(for: .mediaBox).height, doc.outputSize.height, accuracy: 1)
    XCTAssertTrue(page.string?.contains("ALPHA") == true)
    let outputLink = try XCTUnwrap(page.annotations.first { $0.url?.host == "example.com" })
    XCTAssertTrue(page.bounds(for: .mediaBox).contains(outputLink.bounds))
    XCTAssertNotEqual(outputLink.bounds, link.bounds)
    let selection = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox)))
    XCTAssertTrue(page.bounds(for: .mediaBox).contains(selection.bounds(for: page)))
  }
  func testApplyAppearanceKeepsGeometryAndInvalidatesOldOCR() {
    var first = ScanPage(imageFile: "one")
    first.enhancement = .document
    first.appearance.brightness = 0.1
    var second = ScanPage(imageFile: "two")
    second.turns = 1
    second.ocrComplete = true
    second.correctedText = true
    var doc = ScanDocument(title: "Group")
    doc.pages = [first, second]
    doc.applyAppearance(from: first)
    XCTAssertEqual(doc.pages[1].appearance, first.appearance)
    XCTAssertEqual(doc.pages[1].turns, 1)
    XCTAssertFalse(doc.pages[1].ocrComplete)
    XCTAssertNil(doc.pages[1].correctedText)
  }
  func testAbandonedAssetCleanupKeepsRecentAndReferencedFiles() throws {
    let library = store()
    let id = try library.createDraft()
    let image = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 50)).image { _ in }
    try library.appendImage(image, to: id, detectedCrop: .full)
    let referenced = library.url(try XCTUnwrap(library.document(id)?.pages.first?.imageFile))
    let abandoned = library.url(UUID().uuidString + ".jpg")
    let recent = library.url(UUID().uuidString + ".pdf")
    try Data([1, 2]).write(to: abandoned)
    try Data([1, 2]).write(to: recent)
    for url in [referenced, abandoned] {
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -90000)], ofItemAtPath: url.path)
    }
    try library.cleanAbandonedAssets()
    XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
  }
  func testAnnotationTextDrawsIntoProvidedCanvasContext() throws {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 600, height: 800, bitsPerComponent: 8, bytesPerRow: 2400,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(UIColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
    DocumentPDF.draw(
      [PageAnnotation(kind: .text, text: "VISIBLE ANNOTATION")],
      size: CGSize(width: 600, height: 800), context: context)
    let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: 600 * 800 * 4)
    let dark = (0..<(600 * 800)).filter {
      pixels[$0 * 4] < 100 && pixels[$0 * 4 + 1] < 100 && pixels[$0 * 4 + 2] < 100
    }.count
    XCTAssertGreaterThan(
      dark, 100,
      "Text must render in the supplied preview CGContext, not only in UIGraphicsPDFRenderer")
  }
  func testRangesRejectInvalidPagesAndPreserveRequestedOrder() throws {
    XCTAssertEqual(try PageRange.parse("3,1-2,3", count: 4), [2, 0, 1])
    XCTAssertEqual(try PageRange.parse("", count: 3), [0, 1, 2])
    for invalid in ["0", "2-1", "1,", "5", "a", "1--3"] {
      XCTAssertThrowsError(try PageRange.parse(invalid, count: 4))
    }
  }
  func testNativeImportMergeExtractRotateAndBackupKeepTextAndLinks() async throws {
    let library = store()
    let source = library.root.appendingPathComponent("input.pdf")
    let pdf = try XCTUnwrap(PDFDocument(data: textPDF()))
    let link = PDFAnnotation(
      bounds: CGRect(x: 30, y: 500, width: 200, height: 30), forType: .link, withProperties: nil)
    link.url = URL(string: "https://example.com/document")
    pdf.page(at: 0)?.addAnnotation(link)
    try XCTUnwrap(pdf.dataRepresentation()).write(to: source)
    let id = try await library.importNativePDF(source)
    var doc = try XCTUnwrap(library.document(id))
    XCTAssertEqual(doc.pages.count, 2)
    XCTAssertTrue(doc.pages[0].plainText.contains("ALPHA"))
    doc.pages = [doc.pages[1], doc.pages[0]]
    doc.pages[1].turns = 1
    let data = try DocumentPDF.compose(doc, root: library.root)
    let result = try XCTUnwrap(PDFDocument(data: data))
    XCTAssertTrue(result.page(at: 0)?.string?.contains("BETA") == true)
    XCTAssertTrue(result.page(at: 1)?.string?.contains("ALPHA") == true)
    XCTAssertEqual(result.page(at: 1)?.rotation, 90)
    XCTAssertTrue(
      result.page(at: 1)?.annotations.contains(where: { $0.url?.host == "example.com" }) == true)
    try library.savePDF(data, document: doc)
    let backup = try library.exportBackup()
    defer { try? FileManager.default.removeItem(at: backup) }
    let restored = store()
    try restored.importBackup(backup)
    let recovered = try XCTUnwrap(restored.active.first)
    let copied = try XCTUnwrap(
      PDFDocument(data: DocumentPDF.compose(recovered, root: restored.root)))
    XCTAssertTrue(copied.string?.contains("ALPHA") == true)
    try restored.importBackup(backup, keepBoth: true)
    XCTAssertEqual(restored.active.count, 2)
    XCTAssertNotEqual(restored.active[0].id, restored.active[1].id)
    XCTAssertNotEqual(restored.active[0].pages[0].imageFile, restored.active[1].pages[0].imageFile)
  }
  func testPasswordOutputIsLockedAndImportRequiresCorrectPassword() async throws {
    let bytes = textPDF()
    XCTAssertThrowsError(try DocumentPDF.protect(bytes, password: "한글 비밀번호"))
    let protected = try DocumentPDF.protect(bytes, password: "correct password 123")
    let locked = try XCTUnwrap(PDFDocument(data: protected))
    XCTAssertTrue(locked.isLocked)
    XCTAssertFalse(locked.unlock(withPassword: "wrong"))
    XCTAssertTrue(locked.unlock(withPassword: "correct password 123"))
    XCTAssertEqual(locked.pageCount, 2)
    let library = store()
    let file = library.root.appendingPathComponent("protected.pdf")
    try protected.write(to: file)
    do {
      _ = try await library.importNativePDF(file, password: "wrong")
      XCTFail("Wrong password must fail")
    } catch {}
    XCTAssertTrue(library.documents.isEmpty)
    let id = try await library.importNativePDF(file, password: "correct password 123")
    XCTAssertEqual(library.document(id)?.pages.count, 2)
    XCTAssertTrue(library.document(id)?.pages.first?.plainText.contains("ALPHA") == true)
  }
  func testAnnotationOutputContainsTextAndRetainsUnderlyingText() async throws {
    let library = store()
    let file = library.root.appendingPathComponent("input.pdf")
    try textPDF().write(to: file)
    let id = try await library.importNativePDF(file)
    var doc = try XCTUnwrap(library.document(id))
    doc.pages[0].annotations = [
      PageAnnotation(
        kind: .text, x: 0.1, y: 0.6, width: 0.8, height: 0.2, text: "APPROVED annotation")
    ]
    let annotated = try XCTUnwrap(PDFDocument(data: DocumentPDF.compose(doc, root: library.root)))
    XCTAssertTrue(annotated.page(at: 0)?.string?.contains("APPROVED") == true)
    XCTAssertTrue(annotated.page(at: 0)?.string?.contains("ALPHA") == true)
    XCTAssertNil(
      library.document(id)?.pages[0].annotations,
      "Editing an output snapshot must not alter original")
  }
  func testCompressionKeepsSelectableTextAndCopiesKeepSharedAssets() async throws {
    let library = store()
    let id = try library.createDraft()
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1600)).image { c in
      UIColor.white.setFill()
      c.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
      ("HELLO SCAN" as NSString).draw(
        at: CGPoint(x: 120, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 70)])
    }
    try library.appendImage(image, to: id, detectedCrop: .full)
    var doc = try XCTUnwrap(library.document(id))
    doc.pages[0].textBlocks = [
      TextBlock(text: "HELLO SCAN", x: 0.1, y: 0.12, width: 0.6, height: 0.07)
    ]
    doc.pages[0].ocrComplete = true
    let bytes = try DocumentPDF.compose(doc, root: library.root, compression: .smaller)
    XCTAssertTrue(PDFDocument(data: bytes)?.string?.contains("HELLO") == true)
    try library.saveCopies([(doc, bytes), (doc, bytes)])
    XCTAssertEqual(library.active.count, 2)
    let first = library.active[0]
    let second = library.active[1]
    try library.permanentlyDelete(first)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: library.url(second.pages[0].imageFile).path))
    XCTAssertNotNil(PDFDocument(url: library.url(try XCTUnwrap(second.pdfFile))))
  }
  func testTrashRetentionAndFailedCopyCommitDoNotLoseSources() throws {
    let library = store()
    var old = ScanDocument(title: "Old")
    old.deletedAt = Date(timeIntervalSinceNow: -31 * 86400)
    var recent = ScanDocument(title: "Recent")
    recent.deletedAt = Date()
    try library.update(old)
    try library.update(recent)
    try library.purgeExpiredTrash()
    XCTAssertNil(library.document(old.id))
    XCTAssertNotNil(library.document(recent.id))
    let original = library.documents
    try FileManager.default.removeItem(at: library.url("library.json"))
    try FileManager.default.createDirectory(
      at: library.url("library.json"), withIntermediateDirectories: false)
    XCTAssertThrowsError(try library.saveCopies([(ScanDocument(title: "Copy"), textPDF())]))
    XCTAssertEqual(library.documents, original)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: library.root.path).contains {
        $0.hasSuffix(".pdf")
      })
  }
}
