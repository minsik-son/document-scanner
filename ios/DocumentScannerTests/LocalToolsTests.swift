import XCTest
import UIKit
import PDFKit
@testable import DocumentScanner

@MainActor
final class LocalToolsTests: XCTestCase {
    private func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { c in
            for title in ["FRONT 원본", "BACK original"] {
                c.beginPage(); UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
                (title as NSString).draw(at: CGPoint(x: 25, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
    }
    private func solid(_ color: UIColor, size: CGSize = CGSize(width: 400, height: 600)) -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { c in color.setFill(); c.fill(CGRect(origin: .zero, size: size)) }
    }
    func testQRUnicodeRoundTripAndInputLimits() throws {
        let text = "https://example.com/문서?name=한글-日本語-العربية"
        let image = try LocalDocumentTools.qrImage(text)
        XCTAssertEqual(try LocalDocumentTools.readQR(image), [text])
        XCTAssertEqual(try LocalDocumentTools.readQR(solid(.white)), [])
        XCTAssertThrowsError(try LocalDocumentTools.qrImage(""))
        XCTAssertThrowsError(try LocalDocumentTools.qrImage(String(repeating: "가", count: 401)))
    }
    func testWatermarkRetainsOriginalTextLinksAndPageSelection() throws {
        let input = try XCTUnwrap(PDFDocument(data: pdf()))
        let link = PDFAnnotation(bounds: CGRect(x: 20, y: 30, width: 70, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        input.page(at: 0)!.addAnnotation(link)
        let source = try XCTUnwrap(input.dataRepresentation())
        let result = try LocalDocumentTools.stamped(source, indices: [0], stamp: DocumentStamp(text: "CONFIDENTIAL", opacity: 0.4))
        let output = try XCTUnwrap(PDFDocument(data: result))
        XCTAssertEqual(output.pageCount, 2)
        XCTAssertTrue(output.page(at: 0)!.string!.contains("FRONT"))
        XCTAssertTrue(output.page(at: 0)!.string!.contains("CONFIDENTIAL"))
        XCTAssertTrue(output.page(at: 1)!.string!.contains("BACK"))
        XCTAssertFalse(output.page(at: 1)!.string!.contains("CONFIDENTIAL"))
        XCTAssertEqual(output.page(at: 0)!.annotations.first(where: { $0.type == "Link" })?.url, link.url)
        XCTAssertFalse(try XCTUnwrap(PDFDocument(data: source)?.string).contains("CONFIDENTIAL"))
        XCTAssertThrowsError(try LocalDocumentTools.stamped(source, indices: [10], stamp: DocumentStamp()))
        XCTAssertThrowsError(try LocalDocumentTools.stamped(source, indices: [0], stamp: DocumentStamp(text: "")))
        XCTAssertThrowsError(try LocalDocumentTools.stamped(source, indices: [0], stamp: DocumentStamp(opacity: .nan)))
    }
    func testTimestampLogoAndRotatedPage() throws {
        let input = try XCTUnwrap(PDFDocument(data: pdf())); input.page(at: 0)!.rotation = 90
        let source = try XCTUnwrap(input.dataRepresentation())
        let stamp = DocumentStamp(text: "2026-09-29 10:30 PDT", opacity: 0.9, width: 0.5, angle: 0, position: .bottomRight)
        let data = try LocalDocumentTools.stamped(source, indices: [0,1], stamp: stamp)
        let output = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(try LocalDocumentTools.pageSize(output.page(at: 0)!), CGSize(width: 600, height: 400))
        XCTAssertTrue(output.page(at: 0)!.string!.contains("2026-09-29"))
        let logo = try XCTUnwrap(solid(.blue, size: CGSize(width: 80, height: 40)).pngData())
        let marked = try LocalDocumentTools.stamped(source, indices: [0], stamp: DocumentStamp(logo: logo, repeated: true))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: marked)?.string).contains("FRONT"))
    }
    func testIDCardLayoutContainsBothSidesAndPreservesText() throws {
        let output = try XCTUnwrap(PDFDocument(data: LocalDocumentTools.identitySheet(pdf(), front: 0, back: 1, paper: .a4)))
        XCTAssertEqual(output.pageCount, 1)
        XCTAssertEqual(output.page(at: 0)!.bounds(for: .mediaBox).width, PaperSize.a4.size.width, accuracy: 0.01)
        XCTAssertTrue(output.string!.contains("FRONT")); XCTAssertTrue(output.string!.contains("BACK"))
        XCTAssertThrowsError(try LocalDocumentTools.identitySheet(pdf(), front: 0, back: 0, paper: .letter))
        XCTAssertThrowsError(try LocalDocumentTools.identitySheet(pdf(), front: 0, back: 1, paper: .original))
        let single = try LocalDocumentTools.identitySheet(pdf(), front: 1, back: nil, paper: .letter)
        XCTAssertFalse(try XCTUnwrap(PDFDocument(data: single)?.string).contains("FRONT"))
    }
    func testLongImagePartsPreserveAllRowsAndRejectOversize() throws {
        let files = try LocalDocumentTools.strips(heights: [7000,7000], width: 320) { i, rect, cg in
            cg.setFillColor((i == 0 ? UIColor.red : UIColor.blue).cgColor); cg.fill(rect)
        }
        defer { ExportFiles.remove(files.directory) }
        XCTAssertEqual(files.urls.count, 2)
        let first = try XCTUnwrap(UIImage(contentsOfFile: files.urls[0].path)?.cgImage)
        let second = try XCTUnwrap(UIImage(contentsOfFile: files.urls[1].path)?.cgImage)
        XCTAssertEqual(first.width,320); XCTAssertEqual(first.height,10000); XCTAssertEqual(second.height,4000)
        XCTAssertThrowsError(try LocalDocumentTools.strips(heights: [100000,100000], width: 1600) { _,_,_ in })
        let result = try LocalDocumentTools.longImages(pdf(), indices: [1,0], width: 720, gap: 12)
        defer { ExportFiles.remove(result.directory) }
        XCTAssertEqual(UIImage(contentsOfFile: result.urls[0].path)?.cgImage?.height,2172)
        XCTAssertThrowsError(try LocalDocumentTools.longImages(pdf(), indices: [4]))
    }
    func testScreenshotOverlapRejectsBlankAndMatchesKnownOffset() throws {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 1600), format: f).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0,y: 0,width: 384,height: 1600))
            var seed: UInt32 = 1234
            for y in stride(from: 0, to: 1600, by: 8) {
                for x in stride(from: 0, to: 384, by: 8) {
                    seed = 1664525 &* seed &+ 1013904223
                    UIColor(white: CGFloat(seed % 200)/255, alpha: 1).setFill(); c.fill(CGRect(x: x,y: y,width: 8,height: 8))
                }
            }
        }
        let first = UIImage(cgImage: try XCTUnwrap(source.cgImage?.cropping(to: CGRect(x:0,y:0,width:384,height:1000))))
        let second = UIImage(cgImage: try XCTUnwrap(source.cgImage?.cropping(to: CGRect(x:0,y:600,width:384,height:1000))))
        let overlap = try XCTUnwrap(ScreenshotStitcher.suggestedOverlap(previous: first,next: second))
        XCTAssertEqual(overlap,0.4,accuracy:0.025)
        XCTAssertNil(ScreenshotStitcher.suggestedOverlap(previous: solid(.white),next: solid(.white)))
        let files = try ScreenshotStitcher.export([StitchPage(image:first),StitchPage(image:second,overlap:0.4)],width:384)
        defer { ExportFiles.remove(files.directory) }
        XCTAssertEqual(UIImage(contentsOfFile:files.urls[0].path)?.cgImage?.height,1600)
        XCTAssertThrowsError(try ScreenshotStitcher.export([StitchPage(image:first)]))
        XCTAssertThrowsError(try ScreenshotStitcher.export([StitchPage(image:first),StitchPage(image:second,overlap:.nan)]))
    }
    func testScreenshotOverlapMatchesSparseTextRows() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 1600), format: format).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 1600))
            for row in 0..<32 {
                UIColor(hue: CGFloat(row)/32, saturation: 0.4, brightness: 0.8, alpha: 1).setFill()
                c.fill(CGRect(x: 20, y: row*50, width: 40+row*7, height: 20))
                ("ROW \(row) • Offline stitching" as NSString).draw(at: CGPoint(x: 20, y: row*50+22), withAttributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.black])
            }
        }
        let a = UIImage(cgImage: try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 0,y: 0,width: 400,height: 1000))))
        let b = UIImage(cgImage: try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 0,y: 600,width: 400,height: 1000))))
        XCTAssertEqual(try XCTUnwrap(ScreenshotStitcher.suggestedOverlap(previous: a, next: b)), 0.4, accuracy: 0.025)
    }

    func testScreenshotOverlapRejectsRepeatedRows() {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 1000), format: format).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 384, height: 1000))
            UIColor.black.setFill()
            for row in stride(from: 0, to: 1000, by: 100) { c.fill(CGRect(x: 20, y: row+20, width: 280, height: 20)) }
        }
        XCTAssertNil(ScreenshotStitcher.suggestedOverlap(previous: image, next: image), "Repeated content must not be removed without a unique registration.")
    }

    func testGeneratedCopyCommitsAndReloadsWithoutChangingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = LibraryStore(root:root)
        let original = try await store.saveGeneratedPDF(pdf(),title:"Original")
        let before = try XCTUnwrap(store.document(original))
        let data = try LocalDocumentTools.stamped(pdf(),indices:[0,1],stamp:DocumentStamp())
        let copy = try await store.saveGeneratedPDF(data,title:"Copy")
        XCTAssertNotEqual(copy,original);XCTAssertEqual(store.active.count,2)
        XCTAssertEqual(store.document(original),before)
        let reloaded = LibraryStore(root:root)
        XCTAssertEqual(reloaded.active.count,2)
        let doc = try XCTUnwrap(reloaded.document(copy))
        XCTAssertFalse(doc.isDraft);XCTAssertEqual(doc.pages.count,2)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url:reloaded.url(doc.pdfFile!))?.string).contains("FRONT"))
        let composed = try DocumentPDF.compose(doc,root:root)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data:composed)?.string).contains("COPY"))
    }
    func testCaptureStylesHaveDistinctColorAndCleanupPolicies() throws {
        XCTAssertEqual(CaptureStyle.slides.enhancement,.original)
        XCTAssertEqual(CaptureStyle.card.enhancement,.original)
        XCTAssertEqual(CaptureStyle.whiteboard.enhancement,.document)
        XCTAssertGreaterThan(CaptureStyle.whiteboard.strength,CaptureStyle.document.strength)
        var doc = ScanDocument(title:"Whiteboard");doc.captureStyle = .whiteboard
        XCTAssertEqual(try JSONDecoder().decode(ScanDocument.self,from:JSONEncoder().encode(doc)).captureStyle,.whiteboard)
    }
}
