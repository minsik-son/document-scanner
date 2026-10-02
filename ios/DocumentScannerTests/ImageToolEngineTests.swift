import XCTest
import UIKit
import PDFKit
@testable import DocumentScanner

/// Engines behind the rebuilt photo and PDF tools.
final class ImageToolEngineTests: XCTestCase {
    private func image(_ size: CGSize, _ draw: (CGContext) -> Void) -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        return UIGraphicsImageRenderer(size: size, format: f).image { draw($0.cgContext) }
    }
    private func pixel(_ image: UIImage, _ x: Int, _ y: Int) throws -> (Int, Int, Int) {
        let r = try ImageToolEngine.raster(image)
        let p = r.index(x, y)
        return (Int(r.bytes[p]), Int(r.bytes[p + 1]), Int(r.bytes[p + 2]))
    }
    private let paper = UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1)

    func testRemoveMarksKeepsBlackTextAndClearsInk() throws {
        let page = image(CGSize(width: 400, height: 300)) { c in
            paper.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIColor.black.setFill(); c.fill(CGRect(x: 40, y: 40, width: 200, height: 12))            // printed text
            UIColor(red: 1, green: 0.9, blue: 0.2, alpha: 1).setFill(); c.fill(CGRect(x: 40, y: 120, width: 300, height: 30)) // highlighter
            UIColor(red: 0.85, green: 0.1, blue: 0.15, alpha: 1).setFill(); c.fill(CGRect(x: 40, y: 220, width: 300, height: 6)) // red pen
        }
        let out = try ImageToolEngine.removeMarks(page, colors: Set(ImageToolEngine.MarkColor.allCases), strength: 1)
        let text = try pixel(out, 100, 45), highlight = try pixel(out, 100, 135), pen = try pixel(out, 100, 222)
        XCTAssertLessThan(text.0 + text.1 + text.2, 60, "Black text must stay")
        for p in [highlight, pen] {
            XCTAssertGreaterThan(p.0 + p.1 + p.2, 650, "Ink must turn into paper")
            XCTAssertLessThan(abs(p.0 - p.2), 20, "No colour cast left")
        }
    }

    func testSmartEraseFillsPaperUnderTheBrush() throws {
        let page = image(CGSize(width: 300, height: 300)) { c in
            paper.setFill(); c.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            UIColor.black.setFill()
            for y in stride(from: 20, to: 280, by: 24) { c.fill(CGRect(x: 20, y: y, width: 260, height: 8)) } // text lines around
            UIColor.brown.setFill(); c.fillEllipse(in: CGRect(x: 120, y: 120, width: 60, height: 60))      // stain
        }
        let stroke = ImageToolEngine.Stroke(points: [CGPoint(x: 0.5, y: 0.5)], width: 0.3)
        let out = try ImageToolEngine.erase(page, strokes: [stroke])
        let centre = try pixel(out, 150, 150)
        XCTAssertGreaterThan(centre.0 + centre.1 + centre.2, 600, "The erased spot is paper, not smeared ink")
        XCTAssertEqual(out.size, page.size)
    }

    func testCountSplitsTouchingObjects() throws {
        let centres: [CGPoint] = [CGPoint(x: 80, y: 80), CGPoint(x: 220, y: 80), CGPoint(x: 360, y: 80),
                                  CGPoint(x: 80, y: 240), CGPoint(x: 140, y: 240), // touching pair
                                  CGPoint(x: 300, y: 240), CGPoint(x: 420, y: 240),
                                  CGPoint(x: 120, y: 380), CGPoint(x: 260, y: 380), CGPoint(x: 400, y: 380)]
        let photo = image(CGSize(width: 500, height: 460)) { c in
            UIColor(white: 0.9, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 500, height: 460))
            UIColor(red: 0.45, green: 0.32, blue: 0.18, alpha: 1).setFill()
            for p in centres { c.fillEllipse(in: CGRect(x: p.x - 32, y: p.y - 32, width: 64, height: 64)) }
        }
        let result = try ImageToolEngine.count(photo, polarity: .auto, sensitivity: 0.5)
        XCTAssertEqual(result.points.count, centres.count)
        // Reading order: the first marker is the top-left object.
        let first = try XCTUnwrap(result.points.first)
        XCTAssertEqual(first.x * 500, 80, accuracy: 12); XCTAssertEqual(first.y * 460, 80, accuracy: 12)
    }

    func testRestoreRemovesSpecksAndEnlargesSmallPhotos() throws {
        let photo = image(CGSize(width: 400, height: 300)) { c in
            UIColor(red: 0.55, green: 0.6, blue: 0.62, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIColor.white.setFill(); c.fill(CGRect(x: 100, y: 100, width: 3, height: 3))
            UIColor.black.setFill(); c.fill(CGRect(x: 250, y: 150, width: 3, height: 3))
        }
        let out = try ImageToolEngine.restore(photo, level: .standard, fixColor: false)
        XCTAssertEqual(out.size.width, 800, "Small photos are enlarged two times")
        let around = try pixel(out, 160, 160), white = try pixel(out, 203, 203), dark = try pixel(out, 503, 303)
        for p in [white, dark] {
            XCTAssertLessThan(abs((p.0 + p.1 + p.2) - (around.0 + around.1 + around.2)), 60, "Dust specks blend into the photo")
        }
    }

    func testBookFlattenEstimatesNoCurveOnFlatPage() throws {
        let page = image(CGSize(width: 600, height: 800)) { c in
            paper.setFill(); c.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor.black.setFill()
            for y in stride(from: 60, to: 760, by: 26) {
                var x: CGFloat = 40
                while x < 560 { let w = CGFloat(20 + (Int(x + CGFloat(y)) % 40)); c.fill(CGRect(x: x, y: CGFloat(y), width: min(w, 560 - x), height: 10)); x += w + 10 }
            }
        }
        XCTAssertLessThan(ImageToolEngine.estimateCurve(page, spine: .left), 0.06)
        let flat = try ImageToolEngine.flattenPage(page, spine: .right, curve: 0.3)
        XCTAssertEqual(flat.size, page.size)
        let corner = try pixel(flat, 590, 5)
        XCTAssertGreaterThan(corner.0 + corner.1 + corner.2, 600, "Areas outside the photo are paper white, not smeared")
    }

    func testRegistrationFindsTheOverlap() throws {
        let poster = image(CGSize(width: 1200, height: 500)) { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1200, height: 500))
            for i in 0..<60 {
                let x = CGFloat((i * 197) % 1150), y = CGFloat((i * 89) % 460)
                UIColor(hue: CGFloat(i % 7) / 7, saturation: 0.8, brightness: 0.6, alpha: 1).setFill()
                c.fill(CGRect(x: x, y: y, width: 30 + CGFloat(i % 5) * 10, height: 20 + CGFloat(i % 3) * 12))
            }
        }
        let cg = try XCTUnwrap(poster.cgImage)
        let left = UIImage(cgImage: try XCTUnwrap(cg.cropping(to: CGRect(x: 0, y: 0, width: 700, height: 500))))
        let right = UIImage(cgImage: try XCTUnwrap(cg.cropping(to: CGRect(x: 500, y: 0, width: 700, height: 500))))
        let shift = try XCTUnwrap(try ImageToolEngine.register(left, right))
        XCTAssertEqual(shift.x, 500, accuracy: 6); XCTAssertEqual(shift.y, 0, accuracy: 6)
        let stitched = try ImageToolEngine.stitch([left, right], offsets: [.zero, shift])
        XCTAssertEqual(stitched.size.width, 1200, accuracy: 8)
    }

    func testToolCopiesKeepOneSuffix() {
        XCTAssertEqual(PDFTools.named("Report", "watermark"), "Report (watermark)")
        XCTAssertEqual(PDFTools.named("Report (watermark) (merged) (part 2)", "extracted"), "Report (extracted)")
        XCTAssertEqual(PDFTools.named("Trip (Day 1)", "merged"), "Trip (Day 1) (merged)")
    }

    func testTimestampTemplatesStampEveryPage() throws {
        let source = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { c in
            for _ in 0..<2 { c.beginPage(); UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 600)) }
        }
        for template in TimestampTemplate.allCases {
            var stamp = TimestampStamp(); stamp.template = template; stamp.note = "Site A"
            let out = try LocalDocumentTools.timestamped(source, indices: [0, 1], stamp: stamp)
            let pdf = try XCTUnwrap(PDFDocument(data: out))
            XCTAssertEqual(pdf.pageCount, 2, template.rawValue)
        }
    }

    func testGeneratedPDFStoresPhotosCompactly() throws {
        var seed: UInt32 = 7
        let photo = image(CGSize(width: 1600, height: 1200)) { c in
            for y in stride(from: 0, to: 1200, by: 8) { for x in stride(from: 0, to: 1600, by: 8) {
                seed = seed &* 1664525 &+ 1013904223
                UIColor(red: CGFloat(seed % 255) / 255, green: CGFloat((seed >> 8) % 255) / 255, blue: CGFloat((seed >> 16) % 255) / 255, alpha: 1).setFill()
                c.fill(CGRect(x: x, y: y, width: 8, height: 8))
            } }
        }
        let data = try ImageToolEngine.pdf([photo])
        let jpeg = try XCTUnwrap(photo.jpegData(compressionQuality: 0.9))
        XCTAssertLessThan(data.count, jpeg.count * 3 / 2, "Pictures are embedded as JPEG, not as lossless data")
    }
}
