import XCTest
import UIKit
import CoreImage
import PDFKit
import Combine
@testable import DocumentScanner

@MainActor
final class PageAdjustmentsTests: XCTestCase {
    private func fixture() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 500), format: format).image { r in
            UIColor(white: 0.7, alpha: 1).setFill(); r.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
            UIColor(white: 0.35, alpha: 1).setFill(); r.fill(CGRect(x: 50, y: 100, width: 220, height: 4))
            UIColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1).setFill(); r.fill(CGRect(x: 50, y: 250, width: 100, height: 80))
        }
    }
    private func channel(_ image: UIImage, x: Int, y: Int) throws -> Double {
        let cg = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let c = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(bytes[0])/255
    }
    func testZoomPreservesPositionWhenFullResolutionArrivesAndFitsNewViewport() {
        let view = ScanImageScrollView(image: fixture())
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        view.layoutIfNeeded()
        XCTAssertEqual(view.accessibilityValue, "100%")
        view.setZoomScale(view.minimumZoomScale * 2, animated: false)
        view.setContentOffset(CGPoint(x: 100, y: 150), animated: false)
        let scale = view.zoomScale, offset = view.contentOffset
        let full = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1000)).image { _ in
            fixture().draw(in: CGRect(x: 0, y: 0, width: 800, height: 1000))
        }
        view.setImage(full)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, scale, accuracy: 0.001)
        XCTAssertEqual(view.contentOffset.x, offset.x, accuracy: 0.5)
        XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 0.5)
        XCTAssertEqual(view.accessibilityValue, "200%")
        view.frame.size = CGSize(width: 600, height: 390)
        view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, view.minimumZoomScale, accuracy: 0.001)
        XCTAssertEqual(view.accessibilityValue, "100%")
    }

    func testBrightnessContrastAndSharpnessChangePixelsWithoutChangingSize() throws {
        let source = fixture()
        let bright = try Imaging.adjust(source, settings: .init(brightness: 0.15))
        let dark = try Imaging.adjust(source, settings: .init(brightness: -0.15))
        XCTAssertGreaterThan(try channel(bright, x: 200, y: 200), try channel(dark, x: 200, y: 200)+0.15)
        let highContrast = try Imaging.adjust(source, settings: .init(contrast: 1.5))
        XCTAssertLessThan(try channel(highContrast, x: 100, y: 101), try channel(source, x: 100, y: 101))
        let softened = try Imaging.adjust(source, settings: .init(sharpness: -1))
        let sharpened = try Imaging.adjust(softened, settings: .init(sharpness: 1))
        XCTAssertLessThan(try channel(sharpened, x: 100, y: 101), try channel(softened, x: 100, y: 101))
        XCTAssertEqual(bright.cgImage?.width, 400); XCTAssertEqual(bright.cgImage?.height, 500)
        let neutral = try Imaging.adjust(source, settings: .init())
        XCTAssertEqual(try channel(neutral, x: 200, y: 200), try channel(source, x: 200, y: 200), accuracy: 0.01)
    }
    func testAdjustmentsSurviveRelaunchPerPageAndPreviewMatchesExportRenderer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), id = try store.createDraft()
        try store.appendImage(fixture(), to: id, detectedCrop: .full)
        try store.appendImage(fixture(), to: id, detectedCrop: .full)
        var doc = try XCTUnwrap(store.document(id))
        let originalURL = store.url(doc.pages[0].imageFile)
        let originalBytes = try Data(contentsOf: originalURL)
        doc.pages[0].appearance = .init(brightness: -0.2, contrast: 1.1, sharpness: 0.6)
        try store.update(doc)
        let reopened = LibraryStore(root: root)
        let recovered = try XCTUnwrap(reopened.document(id))
        XCTAssertEqual(recovered.pages[0].appearance, doc.pages[0].appearance)
        XCTAssertEqual(recovered.pages[1].appearance, .init())
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        let preview = try await ScanPreviewRenderer().render(recovered.pages[0], root: root)
        let exportImage = try Imaging.render(recovered.pages[0], root: root)
        // A small source is not resized. The shared processing stages should match
        // export within rounding from the rasterized preview cache.
        for point in [(100,101), (200,200), (100,280)] {
            XCTAssertEqual(try channel(preview, x: point.0, y: point.1), try channel(exportImage, x: point.0, y: point.1), accuracy: 0.03)
        }
        var plain = recovered.pages[0]; plain.adjustments = nil
        let neutral = try Imaging.render(plain, root: root)
        XCTAssertGreaterThan(try channel(neutral, x: 200, y: 200), try channel(exportImage, x: 200, y: 200))
    }
    func testPreviewIsBoundedAndCleanupReusesPreparedSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let large = UIGraphicsImageRenderer(size: CGSize(width: 1800, height: 2400), format: format).image { context in
            fixture().draw(in: CGRect(x: 0, y: 0, width: 1800, height: 2400))
        }
        let store = LibraryStore(root: root), id = try store.createDraft()
        try store.appendImage(large, to: id, detectedCrop: .full)
        var page = try XCTUnwrap(store.document(id)?.pages.first)
        page.enhancement = .document; page.enhancementStrength = 0.5
        let renderer = ScanPreviewRenderer()
        let first = try await renderer.render(page, root: root)
        XCTAssertLessThanOrEqual(max(first.size.width, first.size.height), CGFloat(ScanPreviewRenderer.maximumDimension))
        let exported = try Imaging.render(page, root: root)
        XCTAssertEqual(exported.cgImage?.width, 1800)
        XCTAssertEqual(exported.cgImage?.height, 2400)
        let full = try await renderer.render(page, root: root, maxDimension: nil)
        XCTAssertEqual(full.cgImage?.width, exported.cgImage?.width)
        XCTAssertEqual(full.cgImage?.height, exported.cgImage?.height)
        XCTAssertGreaterThan(full.size.height, first.size.height, "Zoom must load full detail instead of stretching the thumbnail")
        for point in [(450, 485), (900, 960), (450, 1300)] {
            XCTAssertEqual(try channel(full, x: point.0, y: point.1), try channel(exported, x: point.0, y: point.1), accuracy: 0.03)
        }
        // A gesture must use its prepared texture, even if the source becomes
        // unavailable after the initial frame. This exercises Cleanup as well as
        // brightness/contrast/sharpness, not just a cached identical request.
        try FileManager.default.removeItem(at: store.url(page.imageFile))
        page.enhancementStrength = 1.5
        page.appearance = .init(brightness: -0.2, contrast: 1.2, sharpness: 0.5)
        let changed = try await renderer.render(page, root: root)
        XCTAssertEqual(first.size, changed.size)
        // The output sample is sRGB, while brightness/contrast are combined in
        // Core Image's working space. Check a visible change above 8-bit rounding
        // instead of treating the slider delta as a linear sRGB pixel delta.
        XCTAssertGreaterThan(try channel(first, x: 300, y: 300), try channel(changed, x: 300, y: 300)+4.0/255)
    }

    func testHighResolutionPreviewPreservesExportInkAndColoredCells() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), id = try store.createDraft()
        try store.appendImage(tableFixture(), to: id, detectedCrop: .full)
        var page = try XCTUnwrap(store.document(id)?.pages.first)
        page.enhancement = .document
        let renderer = ScanPreviewRenderer()
        try await assertPreviewPreservesExport(page, renderer: renderer, root: root)

        // Geometry and tonal edits must still use the same source-resolution
        // processing as the image that is embedded in the final PDF.
        page.crop = ScanQuad(points: [.init(x: 0.04, y: 0.03), .init(x: 0.96, y: 0.04),
                                     .init(x: 0.97, y: 0.96), .init(x: 0.03, y: 0.97)])
        page.turns = 1
        page.enhancementStrength = 1.35
        page.appearance = .init(brightness: -0.025, contrast: 1.08, sharpness: 0.65)
        try await assertPreviewPreservesExport(page, renderer: renderer, root: root)
    }

    private func assertPreviewPreservesExport(_ page: ScanPage, renderer: ScanPreviewRenderer, root: URL,
                                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let preview = try await renderer.render(page, root: root)
        // Imaging.render is the final PDF/OCR path. Resize its finished pixels,
        // never its source: cleanup, ink contrast and sharpening are not scale invariant.
        let expected = try Imaging.previewThumbnail(Imaging.render(page, root: root),
                                                    maxDimension: ScanPreviewRenderer.maximumDimension)
        XCTAssertEqual(preview.size, expected.size, file: file, line: line)
        let actual = try rgba(preview), reference = try rgba(expected)
        guard actual.count == reference.count else {
            XCTFail("Preview and export must have the same display dimensions", file: file, line: line)
            return
        }
        var inkCount = 0, missingInk = 0, coloredCount = 0, missingColor = 0
        var foregroundError = 0.0, foregroundSamples = 0
        for offset in stride(from: 0, to: reference.count, by: 4) {
            let r = Int(reference[offset]), g = Int(reference[offset+1]), b = Int(reference[offset+2])
            let ar = Int(actual[offset]), ag = Int(actual[offset+1]), ab = Int(actual[offset+2])
            let ink = max(r, g, b) < 150
            let color = max(r, g, b)-min(r, g, b) > 30 && min(r, g, b) < 220
            if ink {
                inkCount += 1
                if (ar+ag+ab)-(r+g+b) > 3*35 { missingInk += 1 }
            }
            if color {
                coloredCount += 1
                if max(ar, ag, ab)-min(ar, ag, ab) < (max(r, g, b)-min(r, g, b))/2 { missingColor += 1 }
            }
            if ink || color {
                foregroundError += Double(abs(ar-r)+abs(ag-g)+abs(ab-b))
                foregroundSamples += 3
            }
        }
        XCTAssertGreaterThan(inkCount, 1_000, "The regression must exercise actual fine ink", file: file, line: line)
        XCTAssertGreaterThan(coloredCount, 1_000, "The regression must exercise printed color", file: file, line: line)
        XCTAssertLessThan(Double(missingInk)/Double(max(1, inkCount)), 0.005,
                          "Preview must not whiten ink retained by the PDF", file: file, line: line)
        XCTAssertLessThan(Double(missingColor)/Double(max(1, coloredCount)), 0.005,
                          "Preview must not whiten colored cells retained by the PDF", file: file, line: line)
        XCTAssertLessThan(foregroundError/Double(max(1, foregroundSamples)), 2.0,
                          "Preview foreground must match final PDF pixels within raster rounding", file: file, line: line)
    }

    private func tableFixture() -> UIImage {
        let size = CGSize(width: 2400, height: 3200)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.90, green: 0.85, blue: 0.75, alpha: 1).cgColor,
                          UIColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                      locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let table = CGRect(x: 270, y: 430, width: 1860, height: 1728)
            for row in 0..<36 {
                let color: UIColor = row >= 25 ? UIColor(red: 0.40, green: 0.63, blue: 0.83, alpha: 1)
                    : row == 24 ? UIColor(red: 0.96, green: 0.79, blue: 0.24, alpha: 1)
                    : row < 10 ? UIColor(red: 0.96, green: 0.94, blue: 0.82, alpha: 1)
                    : UIColor(red: 0.94, green: 0.88, blue: 0.87, alpha: 1)
                color.setFill()
                context.fill(CGRect(x: table.minX, y: table.minY+CGFloat(row)*48, width: table.width, height: 48))
                let text = "Montreal (몬트리올)  St. Catherine  \(row+1)  10.41.22.xx"
                (text as NSString).draw(at: CGPoint(x: table.minX+25, y: table.minY+CGFloat(row)*48+10),
                                       withAttributes: [.font: UIFont.systemFont(ofSize: 23, weight: .regular),
                                                        .foregroundColor: UIColor(white: row % 3 == 0 ? 0.30 : 0.13, alpha: 1)])
            }
            cg.setStrokeColor(UIColor(white: 0.12, alpha: 1).cgColor); cg.setLineWidth(2.2)
            for row in 0...36 {
                cg.move(to: CGPoint(x: table.minX, y: table.minY+CGFloat(row)*48))
                cg.addLine(to: CGPoint(x: table.maxX, y: table.minY+CGFloat(row)*48))
            }
            for fraction in [0.0, 0.43, 0.77, 1.0] {
                cg.move(to: CGPoint(x: table.minX+table.width*fraction, y: table.minY))
                cg.addLine(to: CGPoint(x: table.minX+table.width*fraction, y: table.maxY))
            }
            cg.strokePath()
            // Small, faint text outside the colored grid catches sharpening and
            // paper-cleanup differences that broad color samples would miss.
            for row in 0..<8 {
                ("Fine print: signed 원본 보존 0123456789" as NSString)
                    .draw(at: CGPoint(x: 500, y: 2440+row*40),
                          withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .light),
                                           .foregroundColor: UIColor(white: 0.42, alpha: 1)])
            }
        }
    }

    private func rgba(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width*cg.height*4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                             bytesPerRow: cg.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return bytes
    }

    func testPreviewCoalescesDragButPresentsIntermediateAndFinalFrames() async throws {
        let firstStarted = expectation(description: "First frame started")
        let nextStarted = expectation(description: "Newest frame started")
        let ready = expectation(description: "Final frame ready")
        let gate = ControlledPreviewRenderer { call in
            if call == 1 { firstStarted.fulfill() }
            if call == 2 { nextStarted.fulfill() }
        }
        let model = ScanPreviewModel(render: { page, _ in try await gate.render(page) })
        let token = model.$isReady.dropFirst().filter { $0 }.sink { _ in ready.fulfill() }
        defer { token.cancel(); model.cancel() }
        let root = FileManager.default.temporaryDirectory
        var page = ScanPage(imageFile: "page.jpg")
        model.request(page, root: root)
        await fulfillment(of: [firstStarted], timeout: 3)
        for value in [0.05, 0.1, 0.15, 0.2] {
            page.appearance = .init(brightness: value)
            model.request(page, root: root)
        }
        let first = fixture(), final = try Imaging.adjust(first, settings: .init(brightness: 0.2))
        await gate.complete(first)
        await fulfillment(of: [nextStarted], timeout: 3)
        XCTAssertTrue(model.image === first, "A completed frame is shown while the latest adjustment renders")
        XCTAssertFalse(model.isReady)
        let values = await gate.values
        XCTAssertEqual(values, [0, 0.2], "Intermediate pending slider values should not build an unbounded queue")
        await gate.complete(final)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertTrue(model.image === final)
        XCTAssertNil(model.problem)
    }

    /// Slider frames during a drag come from the fast cached tone; the value the
    /// drag ends on is rendered once more exactly like the export, and only that
    /// frame marks the preview ready.
    func testDragEndsWithAnExactFrame() async throws {
        actor Log { var items: [(Double, Bool)] = []; func add(_ v: Double, _ i: Bool) { items.append((v, i)) } }
        let log = Log()
        let ready = expectation(description: "Settled")
        let model = ScanPreviewModel(renderInteractive: { page, _, interactive in
            await log.add(page.appearance.brightness, interactive)
            try await Task.sleep(for: .milliseconds(40))
            return UIImage()
        })
        var readyCount = 0
        let token = model.$isReady.dropFirst().filter { $0 }.sink { _ in readyCount += 1; if readyCount == 2 { ready.fulfill() } }
        defer { token.cancel(); model.cancel() }
        let root = FileManager.default.temporaryDirectory
        var page = ScanPage(imageFile: "page.jpg")
        model.request(page, root: root)
        try await Task.sleep(for: .milliseconds(200))
        // Now drag: requests keep arriving while frames render.
        for value in stride(from: 0.02, through: 0.2, by: 0.02) {
            page.appearance = .init(brightness: value)
            model.request(page, root: root)
            try await Task.sleep(for: .milliseconds(15))
        }
        await fulfillment(of: [ready], timeout: 5)
        let items = await log.items
        XCTAssertEqual(items.first?.1, false, "The first frame of a page is exact")
        XCTAssertTrue(items.dropFirst().dropLast().contains { $0.1 }, "Drag frames use the fast path: \(items)")
        XCTAssertEqual(items.last?.0 ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(items.last?.1, false, "The drag ends on an exact frame: \(items)")
    }

    func testCancelledPreviewCannotReplaceNewPage() async throws {
        let firstStarted = expectation(description: "Old frame started")
        let nextStarted = expectation(description: "New frame started")
        let ready = expectation(description: "New page ready")
        let gate = ControlledPreviewRenderer { call in
            if call == 1 { firstStarted.fulfill() }
            if call == 2 { nextStarted.fulfill() }
        }
        let model = ScanPreviewModel(render: { page, _ in try await gate.render(page) })
        let token = model.$isReady.dropFirst().filter { $0 }.sink { _ in ready.fulfill() }
        defer { token.cancel(); model.cancel() }
        let root = FileManager.default.temporaryDirectory
        model.request(ScanPage(imageFile: "old.jpg"), root: root)
        await fulfillment(of: [firstStarted], timeout: 3)
        model.cancel()
        model.request(ScanPage(imageFile: "new.jpg"), root: root)
        await fulfillment(of: [nextStarted], timeout: 3)
        let old = fixture(), new = try Imaging.adjust(old, settings: .init(brightness: -0.2))
        // Complete the new job before the cancelled job. Its late return must not
        // overwrite the visible page or mark the new worker as stopped.
        await gate.complete(new, at: 1)
        await fulfillment(of: [ready], timeout: 3)
        await gate.complete(old)
        // Give the old continuation its turn on the main actor.
        await Task.yield()
        XCTAssertTrue(model.image === new)
        XCTAssertTrue(model.isReady)
        XCTAssertNil(model.problem)
    }

    func testLegacyPageDefaultsAndInvalidAdjustmentValuesAreBounded() throws {
        let bytes = Data("{\"id\":\"CF78F2E3-DA53-408B-A2C2-C86860CD67C8\",\"imageFile\":\"old.jpg\",\"crop\":{\"points\":[{\"x\":0,\"y\":0},{\"x\":1,\"y\":0},{\"x\":1,\"y\":1},{\"x\":0,\"y\":1}]},\"turns\":0,\"enhancement\":\"Original\",\"textBlocks\":[],\"ocrComplete\":false}".utf8)
        let page = try JSONDecoder().decode(ScanPage.self, from: bytes)
        XCTAssertEqual(page.appearance, .init())
        let bounded = PageAdjustments(brightness: .nan, contrast: 10, sharpness: -10).bounded
        XCTAssertEqual(bounded.brightness, 0); XCTAssertEqual(bounded.contrast, 1.6); XCTAssertEqual(bounded.sharpness, -1)
    }
}

private actor ControlledPreviewRenderer {
    private var continuations: [CheckedContinuation<UIImage, Error>] = []
    private(set) var values: [Double] = []
    private let onCall: (Int) -> Void
    init(onCall: @escaping (Int) -> Void) { self.onCall = onCall }
    func render(_ page: ScanPage) async throws -> UIImage {
        values.append(page.appearance.brightness)
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            onCall(values.count)
        }
    }
    func complete(_ image: UIImage, at index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations.remove(at: index).resume(returning: image)
    }
}
