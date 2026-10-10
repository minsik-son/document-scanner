import XCTest
import CoreImage
import UIKit
@testable import DocumentScanner

/// Curled, bent and stapled pages (private photos on the developer Mac) come out
/// flat: text lines and ruled lines straight.
final class FlattenTests: XCTestCase {
    private var folder: URL? {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return nil }
        return URL(fileURLWithPath: home).appendingPathComponent("Documents/ChatGPT/정치 중립/scanner-product/ios/Verification/private/dewarp")
    }

    /// How far lines on a page are from straight and level/upright, in pixels at
    /// 1000 px width (median over the lines found).
    static func bend(_ image: CGImage) -> (median: Double, worst: Double, lines: Int) {
        let w = 1000, h = max(100, Int(Double(image.height) * 1000 / Double(image.width)))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h)
        var g = Plane(w: w, h: h)
        for i in 0..<(w * h) { g.p[i] = data[i] }
        let th = PaperFeatures.binarize(g)
        var scores: [Double] = []
        func score(_ pts: [SIMD2<Double>], vertical: Bool) {
            let t = pts.map { vertical ? $0.y : $0.x }, s = pts.map { vertical ? $0.x : $0.y }
            let n = Double(t.count), mt = t.reduce(0, +) / n, ms = s.reduce(0, +) / n
            let b = zip(t, s).reduce(0) { $0 + ($1.0 - mt) * ($1.1 - ms) } / max(1e-9, t.reduce(0) { $0 + ($1 - mt) * ($1 - mt) })
            let res = zip(t, s).map { abs($0.1 - (ms + b * ($0.0 - mt))) }.reduce(0, +) / n
            scores.append(res + abs(b) * (t.max()! - t.min()!) / 2)
        }
        for l in PaperFeatures.textLines(th) + PaperFeatures.horizontalRules(th) { score(l.pts, vertical: false) }
        for l in PaperFeatures.verticalRules(th) { score(l.pts, vertical: true) }
        scores.sort()
        return scores.isEmpty ? (0, 0, 0) : (scores[scores.count / 2], scores[scores.count * 9 / 10], scores.count)
    }

    func testCurledAndStapledPagesComeOutFlat() throws {
        guard let folder else { throw XCTSkip("Private photos are only on the developer Mac.") }
        let names = ["curl_far", "curl_near", "stapled_cut_corner", "table_bent"]
        let out = folder.appendingPathComponent("out")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        PaperFlattener.trace = { report.append("  " + $0) }
        defer { PaperFlattener.trace = nil }
        for name in names {
            guard let photo = UIImage(contentsOfFile: folder.appendingPathComponent("samples/\(name).jpg").path), let cg = photo.cgImage else {
                throw XCTSkip("\(name).jpg is not available.")
            }
            let source = CIImage(cgImage: cg)
            // The crop the camera would find.
            let found = CaptureStyle.document.detect(photo, capturedPhoto: true)
            let crop = try XCTUnwrap(found, name)
            print("FLATTEN crop \(name): \(crop.points.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) }.joined())")
            PaperFlattener.traceLines = { rect, across, down in
                let ctx = CGContext(data: nil, width: rect.w, height: rect.h, bitsPerComponent: 8, bytesPerRow: rect.w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                let px = ctx.data!.bindMemory(to: UInt8.self, capacity: rect.w * rect.h * 4)
                for i in 0..<(rect.w * rect.h) { px[i * 4] = rect.p[i]; px[i * 4 + 1] = rect.p[i]; px[i * 4 + 2] = rect.p[i] }
                try? UIImage(cgImage: ctx.makeImage()!).pngData()?.write(to: out.appendingPathComponent("\(name)-rect.png"))
                ctx.translateBy(x: 0, y: CGFloat(rect.h)); ctx.scaleBy(x: 1, y: -1)
                ctx.setLineWidth(2)
                for (lines, color) in [(across, CGColor(red: 1, green: 0, blue: 0, alpha: 1)), (down, CGColor(red: 0, green: 0.6, blue: 1, alpha: 1))] {
                    ctx.setStrokeColor(color)
                    for l in lines { ctx.addLines(between: l.map { CGPoint(x: $0.x, y: $0.y) }); ctx.strokePath() }
                }
                try? UIImage(cgImage: ctx.makeImage()!).jpegData(compressionQuality: 0.8)?.write(to: out.appendingPathComponent("\(name)-lines.jpg"))
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let mesh = PaperFlatten.analyze(source, crop: crop)
            let seconds = CFAbsoluteTimeGetCurrent() - t0
            XCTAssertNotNil(mesh, name)
            func render(_ flat: Bool) throws -> CGImage {
                let ci = try DocumentProcessing.render(source, crop: crop, turns: 0, enhancement: .original, flatten: flat ? FlattenRequest(key: nil) : nil)
                return try XCTUnwrap(DocumentProcessing.context.createCGImage(ci, from: ci.extent))
            }
            PaperFlattener.traceLines = nil
            let flat = try render(true), plain = try render(false)
            try UIImage(cgImage: flat).jpegData(compressionQuality: 0.85)?.write(to: out.appendingPathComponent("\(name)-flat.jpg"))
            try UIImage(cgImage: plain).jpegData(compressionQuality: 0.85)?.write(to: out.appendingPathComponent("\(name)-plain.jpg"))
            let a = Self.bend(plain), b = Self.bend(flat)
            report.append(String(format: "%@ analysis %.2fs  plain median %.1f p90 %.1f (%d)  flat median %.1f p90 %.1f (%d)", name, seconds, a.median, a.worst, a.lines, b.median, b.worst, b.lines))
            XCTAssertLessThan(b.worst, 3.0, name)
            XCTAssertLessThanOrEqual(b.worst, a.worst, name)
        }
        print("FLATTEN\n" + report.joined(separator: "\n"))
    }

    /// Flattening applies to photographed sheets with a crop, and re-flattening
    /// marks hidden areas for a check (the page's geometry changed).
    func testFlattenAppliesToCroppedPhotosAndInvalidatesHiding() {
        var page = ScanPage(imageFile: "a.jpg")
        page.flatten = true
        XCTAssertNil(page.flattenRequest, "a page without a crop isn't flattened")
        page.crop = ScanQuad(points: [.init(x: 0.1, y: 0.1), .init(x: 0.9, y: 0.12), .init(x: 0.92, y: 0.9), .init(x: 0.08, y: 0.88)])
        XCTAssertNotNil(page.flattenRequest)
        page.identityBackgroundCleanup = true
        XCTAssertNil(page.flattenRequest, "ID cards keep their own processing")
        page.identityBackgroundCleanup = nil
        page.setRedaction(hidden: [CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.05)], visible: [])
        XCTAssertFalse(page.redactionNeedsCheck)
        page.flatten = false
        XCTAssertTrue(page.redactionNeedsCheck)
        page.flatten = true
        XCTAssertFalse(page.redactionNeedsCheck)
        XCTAssertNotEqual(PaperFlatten.key(imageFile: "a.jpg", crop: page.crop), PaperFlatten.key(imageFile: "a.jpg", crop: .full))
    }

    /// A straight, flat page drawn on a dark background: the paper is found and
    /// the flat result keeps its lines straight.
    func testFlatPageStaysFlat() throws {
        // A Letter page with text, photographed at an angle on a dark desk.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: 850, height: 1100), format: format).image { ctx in
            UIColor(white: 0.95, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 850, height: 1100))
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.black]
            for row in 0..<18 { ("The quick brown fox jumps over the lazy dog " + String(row)).draw(at: CGPoint(x: 70, y: 90 + row * 50), withAttributes: attrs) }
        }
        let flatSheet = CIImage(cgImage: sheet.cgImage!)
        // Core Image: origin bottom-left, in a 1200×1600 photo.
        let photoSize = CGSize(width: 1200, height: 1600)
        func ci(_ x: CGFloat, _ y: CGFloat) -> CIVector { CIVector(x: x, y: photoSize.height - y) }
        let warped = flatSheet.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": ci(250, 220), "inputTopRight": ci(980, 250), "inputBottomRight": ci(1040, 1380), "inputBottomLeft": ci(170, 1350)])
        let desk = CIImage(color: CIColor(red: 0.25, green: 0.22, blue: 0.2)).cropped(to: CGRect(origin: .zero, size: photoSize))
        let photo = warped.composited(over: desk)
        let image = UIImage(cgImage: try XCTUnwrap(DocumentProcessing.context.createCGImage(photo, from: CGRect(origin: .zero, size: photoSize))))
        let cg = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(Imaging.detectPage(image))
        func render(_ flat: Bool) throws -> CGImage {
            let ci = try DocumentProcessing.render(CIImage(cgImage: cg), crop: crop, turns: 0, enhancement: .original, flatten: flat ? FlattenRequest(key: nil) : nil)
            return try XCTUnwrap(DocumentProcessing.context.createCGImage(ci, from: ci.extent))
        }
        let flat = Self.bend(try render(true)), plain = Self.bend(try render(false))
        print(String(format: "FLATTEN synthetic plain median %.2f p90 %.2f (%d)  flat median %.2f p90 %.2f (%d)", plain.median, plain.worst, plain.lines, flat.median, flat.worst, flat.lines))
        XCTAssertGreaterThan(flat.lines, 10)
        XCTAssertLessThan(flat.worst, plain.worst + 1.0)
        XCTAssertLessThan(flat.median, 1.5)
    }
}
