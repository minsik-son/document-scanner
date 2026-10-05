import XCTest
import UIKit
import PDFKit
import CoreImage
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

    /// The ID photo fit puts the head (chin to crown) at the size's target
    /// height with the crown at its gap from the top, and the user's zoom
    /// and moves land where the guide shows them.
    func testPortraitFitMatchesHeadSpec() {
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1400))
        var subject = ImageToolEngine.PortraitSubject(image: base, mask: base, face: CGRect(x: 380, y: 640, width: 240, height: 280))
        subject.crown = 1000; subject.chin = 600; subject.centerX = 500; subject.shoulder = 480
        let size = ImageToolEngine.PhotoSize.all.first { $0.id == "35x45" }!
        var m = ImageToolEngine.portraitMetrics(subject, size: size, adjust: ImageToolEngine.PortraitAdjust())
        XCTAssertEqual(m.head, size.headTarget, accuracy: 0.01)
        XCTAssertEqual(m.crown, size.crownGap, accuracy: 0.01)
        XCTAssertEqual(m.chin, size.crownGap + size.headTarget, accuracy: 0.01)
        XCTAssertEqual(m.centerOffset, 0, accuracy: 0.01)
        XCTAssertNotNil(m.shoulder)
        m = ImageToolEngine.portraitMetrics(subject, size: size, adjust: ImageToolEngine.PortraitAdjust(zoom: 1.05, dx: 1, dy: 2))
        XCTAssertEqual(m.head, size.headTarget * 1.05, accuracy: 0.01)
        XCTAssertEqual(m.centerOffset, 1, accuracy: 0.01, "Moved right")
        XCTAssertEqual((m.crown + m.chin) / 2, size.crownGap + size.headTarget / 2 - 2, accuracy: 0.01, "Moved up, head centre kept while zooming")
        let crop = ImageToolEngine.portraitCrop(subject, size: size, adjust: ImageToolEngine.PortraitAdjust()).rect
        XCTAssertEqual(Double(crop.width / crop.height), size.width / size.height, accuracy: 0.001)
    }

    private func portraitSubjectFixture() -> ImageToolEngine.PortraitSubject {
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1400))
        var subject = ImageToolEngine.PortraitSubject(image: base, mask: base, face: CGRect(x: 380, y: 640, width: 240, height: 280))
        subject.crown = 1000; subject.chin = 600; subject.centerX = 500; subject.shoulder = 480; subject.shoulderWidth = 640
        return subject
    }

    /// Online files have the form's exact pixels and stay under its size limit.
    func testDigitalPhotoMeetsPixelsAndSizeLimit() throws {
        let noisy = image(CGSize(width: 700, height: 900)) { c in
            for y in stride(from: 0, to: 900, by: 6) { for x in stride(from: 0, to: 700, by: 6) {
                UIColor(hue: CGFloat((x * 7 + y * 13) % 360) / 360, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
                c.fill(CGRect(x: x, y: y, width: 6, height: 6))
            } }
        }
        let spec = ImageToolEngine.DigitalSpec(id: "t", title: "Test", width: 413, height: 531, maxKB: 60)
        let data = ImageToolEngine.digitalJPEG(noisy, spec: spec, backdrop: .white)
        XCTAssertLessThanOrEqual(data.count, 60 * 1024)
        let decoded = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(decoded.width, 413); XCTAssertEqual(decoded.height, 531)
        for size in ImageToolEngine.PhotoSize.all { for spec in size.digital { XCTAssertGreaterThan(spec.maxKB, spec.minKB, spec.id) } }
    }

    /// Sheets turn the paper whichever way fits more copies.
    func testPrintSheetFitsMostCopiesOnEachPaper() {
        let passport = ImageToolEngine.PhotoSize.all.first { $0.id == "35x45" }!
        let six = ImageToolEngine.sheetLayout(passport, paper: .fourBySix)
        XCTAssertEqual(six.columns * six.rows, 8)
        XCTAssertGreaterThan(six.sheet.width, six.sheet.height)
        let a4 = ImageToolEngine.sheetLayout(passport, paper: .a4)
        XCTAssertEqual(a4.columns * a4.rows, 30)
        XCTAssertLessThan(a4.sheet.width, a4.sheet.height)
        let photo = image(CGSize(width: 413, height: 531)) { c in UIColor.gray.setFill(); c.fill(CGRect(x: 0, y: 0, width: 413, height: 531)) }
        let sheet = ImageToolEngine.printSheet(photo, size: passport, paper: .a4)
        XCTAssertEqual(sheet.size.width, 2480, accuracy: 1)
        XCTAssertEqual(sheet.size.height, 3508, accuracy: 1)
    }

    /// The photo check flags what offices reject and passes a clean photo.
    func testPortraitChecksFlagCommonRejections() {
        var subject = portraitSubjectFixture()
        let size = ImageToolEngine.PhotoSize.all[0]
        subject.quality = ImageToolEngine.PortraitQuality(roll: 1, yaw: 2, eyeOpenness: 0.32, mouthOpen: 0.02, lightBalance: 0.05, brightness: 0.6, glare: 0)
        XCTAssertTrue(ImageToolEngine.portraitChecks(subject, size: size, adjust: ImageToolEngine.PortraitAdjust()).allSatisfy(\.passed))
        subject.quality = ImageToolEngine.PortraitQuality(roll: 12, yaw: 2, eyeOpenness: 0.05, mouthOpen: 0.3, lightBalance: 0.5, brightness: 0.15, glare: 0.2)
        let failed = Set(ImageToolEngine.portraitChecks(subject, size: size, adjust: ImageToolEngine.PortraitAdjust(zoom: 1.3)).filter { !$0.passed }.map(\.id))
        XCTAssertEqual(failed, ["head", "straight", "eyes", "mouth", "light", "exposure", "glare"])
    }

    /// The outfit's neck lands just below the chin and its shoulders match the person's.
    func testOutfitSitsBelowChinAtShoulderWidth() {
        let subject = portraitSubjectFixture()
        let extent = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let t = ImageToolEngine.outfitTransform(subject, pxPerMM: 10, lift: 0, extent: extent)
        let neck = CGPoint(x: 512, y: 1024 - 230).applying(t)
        XCTAssertEqual(neck.x, 500, accuracy: 0.5)
        XCTAssertLessThan(neck.y, 600); XCTAssertGreaterThan(neck.y, 560)
        let left = CGPoint(x: 70, y: 0).applying(t), right = CGPoint(x: 954, y: 0).applying(t)
        XCTAssertEqual(right.x - left.x, 640 * 1.04, accuracy: 1)
        let lifted = CGPoint(x: 512, y: 1024 - 230).applying(ImageToolEngine.outfitTransform(subject, pxPerMM: 10, lift: 1, extent: extent))
        XCTAssertEqual(lifted.y - neck.y, 10, accuracy: 0.01)
    }

    /// Made photos are kept for reprinting, newest first, up to the limit.
    func testPortraitHistoryKeepsRecentPhotos() throws {
        let saved = PortraitHistory.root
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        PortraitHistory.root = root
        defer { PortraitHistory.root = saved; try? FileManager.default.removeItem(at: root) }
        let photo = image(CGSize(width: 60, height: 80)) { c in UIColor.gray.setFill(); c.fill(CGRect(x: 0, y: 0, width: 60, height: 80)) }
        var first = PortraitHistoryEntry(sizeID: "2x2", backdrop: "White", zoom: 1.1)
        first.date = Date(timeIntervalSince1970: 1)
        try PortraitHistory.save(first, source: photo, photo: photo)
        for i in 0..<PortraitHistory.limit {
            var entry = PortraitHistoryEntry(sizeID: "35x45", backdrop: "Blue")
            entry.date = Date(timeIntervalSince1970: TimeInterval(10 + i))
            try PortraitHistory.save(entry, source: photo, photo: photo)
        }
        let list = PortraitHistory.list()
        XCTAssertEqual(list.count, PortraitHistory.limit)
        XCTAssertFalse(list.contains { $0.id == first.id }, "The oldest is dropped")
        XCTAssertNotNil(PortraitHistory.source(list[0].id))
        XCTAssertEqual(list[0].backdrop, "Blue")
    }

    /// Runs the whole ID photo on private test portraits (AI-generated
    /// people) and writes the results to Verification/private/id-check for review.
    func testPrivatePortraitsEndToEnd() throws {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { throw XCTSkip("Private samples are only on the developer Mac.") }
        let folder = URL(fileURLWithPath: home).appendingPathComponent("Documents/ChatGPT/정치 중립/scanner-product/ios/Verification/private")
        let out = folder.appendingPathComponent("id-check")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var found = 0
        for name in ["test-portrait-1", "test-portrait-2"] {
            guard let input = UIImage(contentsOfFile: folder.appendingPathComponent("testimg/\(name).png").path) else { continue }
            found += 1
            let subject: ImageToolEngine.PortraitSubject
            do { subject = try ImageToolEngine.portraitSubject(input) }
            catch { try "\(error)".write(to: out.appendingPathComponent("\(name)-error.txt"), atomically: true, encoding: .utf8); throw error }
            XCTAssertNotNil(subject.shoulder, name); XCTAssertNotNil(subject.shoulderWidth, name)
            XCTAssertGreaterThan(subject.crown, subject.face.maxY, name)
            XCTAssertLessThanOrEqual(subject.chin, subject.face.minY, name)
            let checks = ImageToolEngine.portraitChecks(subject, size: ImageToolEngine.PhotoSize.all[0], adjust: ImageToolEngine.PortraitAdjust())
            let report = checks.map { "\($0.passed ? "PASS" : "WARN") \($0.title): \($0.detail)" }.joined(separator: "\n") + "\n\(subject.quality)"
            try report.write(to: out.appendingPathComponent("\(name)-checks.txt"), atomically: true, encoding: .utf8)
            XCTAssertTrue(checks.filter { ["head", "centre", "straight", "exposure", "glare"].contains($0.id) }.allSatisfy(\.passed), "\(name):\n\(report)")
            let passport = try ImageToolEngine.portrait(subject, size: ImageToolEngine.PhotoSize.all[0], backdrop: .white)
            try passport.jpegData(compressionQuality: 0.9)?.write(to: out.appendingPathComponent("\(name)-passport.jpg"))
            let resume = try XCTUnwrap(ImageToolEngine.PhotoSize.all.first { $0.id == "30x40" })
            for outfit in ImageToolEngine.Outfit.allCases where outfit != .none {
                XCTAssertNotNil(outfit.image, outfit.rawValue); XCTAssertNotNil(outfit.neckMask, outfit.rawValue)
                let photo = try ImageToolEngine.portrait(subject, size: resume, backdrop: .sky, outfit: outfit)
                try photo.jpegData(compressionQuality: 0.9)?.write(to: out.appendingPathComponent("\(name)-\(outfit.rawValue).jpg"))
            }
        }
        if found == 0 { throw XCTSkip("No private test portraits.") }
    }
}
