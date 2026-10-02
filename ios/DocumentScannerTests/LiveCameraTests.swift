import XCTest
import UIKit
import CoreImage
@testable import DocumentScanner

final class LiveCameraTests: XCTestCase {
    func testExplicitNextPageRearmsAutoCaptureButRequiresANewStableHold() {
        var tracker = LiveDocumentTracker()
        _ = tracker.update(.full, at: 0)
        XCTAssertTrue(tracker.update(.full, at: 1).canAutoCapture)
        tracker.markCapture()
        tracker.clearPreview()
        XCTAssertFalse(tracker.update(.full, at: 2).canAutoCapture)
        tracker.beginNextPage()
        XCTAssertFalse(tracker.update(.full, at: 3).canAutoCapture)
        XCTAssertTrue(tracker.update(.full, at: 4).canAutoCapture)
    }
    private let page = ScanQuad(points: [.init(x: 0.15, y: 0.1), .init(x: 0.85, y: 0.1), .init(x: 0.85, y: 0.9), .init(x: 0.15, y: 0.9)])
    func testAutoCaptureWaitsForStableDocument() {
        var tracker = LiveDocumentTracker()
        XCTAssertFalse(tracker.update(page, at: 0).canAutoCapture)
        XCTAssertFalse(tracker.update(page, at: 0.5).canAutoCapture)
        XCTAssertTrue(tracker.update(page, at: 0.9).canAutoCapture)
    }
    func testMovingPageRestartsSteadyInterval() {
        var tracker = LiveDocumentTracker()
        _ = tracker.update(page, at: 0)
        var moved = page
        moved.points = page.points.map { ScanPoint(x: $0.x + 0.05, y: $0.y) }
        XCTAssertFalse(tracker.update(moved, at: 0.7).canAutoCapture)
        XCTAssertFalse(tracker.update(moved, at: 1.2).canAutoCapture)
        XCTAssertTrue(tracker.update(moved, at: 1.6).canAutoCapture)
    }
    func testCapturedPageCannotCreateDuplicateUntilRemoved() {
        var tracker = LiveDocumentTracker()
        _ = tracker.update(page, at: 0)
        XCTAssertTrue(tracker.update(page, at: 1).canAutoCapture)
        tracker.markCapture()
        XCTAssertFalse(tracker.update(page, at: 20).canAutoCapture)
        _ = tracker.update(nil, at: 21)
        XCTAssertFalse(tracker.update(page, at: 21.4).canAutoCapture)
        _ = tracker.update(nil, at: 22)
        _ = tracker.update(nil, at: 23)
        XCTAssertFalse(tracker.update(page, at: 24).canAutoCapture)
        XCTAssertTrue(tracker.update(page, at: 25).canAutoCapture)
    }
    func testMissingDetectionBreaksStabilityAndClearsOutline() {
        var tracker = LiveDocumentTracker()
        _ = tracker.update(page, at: 0)
        _ = tracker.update(nil, at: 0.5)
        XCTAssertNil(tracker.update(nil, at: 0.8).quad)
        XCTAssertFalse(tracker.update(page, at: 1).canAutoCapture)
    }
    func testBackgroundResumeKeepsCapturedPageLatch() {
        var tracker = LiveDocumentTracker()
        _ = tracker.update(page, at: 0)
        tracker.markCapture()
        tracker.clearPreview()
        XCTAssertNil(tracker.snapshot.quad)
        XCTAssertFalse(tracker.update(page, at: 10).canAutoCapture)
        XCTAssertFalse(tracker.update(page, at: 11).canAutoCapture)
    }
    func testPortraitCornersConvertToSensorCoordinates() {
        let input = [ScanPoint(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)]
        let expected = [CGPoint(x: 0, y: 1), .init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1)]
        XCTAssertEqual(input.map(LiveDocumentTracker.captureDevicePoint), expected)
        XCTAssertEqual(LiveDocumentTracker.captureDevicePoint(fromPortrait: .init(x: 0.25, y: 0.6)), CGPoint(x: 0.6, y: 0.75))
    }
}

extension LiveCameraTests {
    func testIDShapeUsesPixelAspectAndRejectsUnrelatedRectangles() {
        let size = CGSize(width: 1000, height: 1600)
        func quad(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> ScanQuad {
            ScanQuad(points: [.init(x:x,y:y), .init(x:x+w,y:y), .init(x:x+w,y:y+h), .init(x:x,y:y+h)])
        }
        XCTAssertNotNil(CaptureStyle.cardScore(quad(0.18,0.3,0.64,0.2525), imageSize: size))
        XCTAssertNil(CaptureStyle.cardScore(quad(0.18,0.3,0.64,0.4), imageSize: size), "A square is not an ID card")
        XCTAssertNil(CaptureStyle.cardScore(.full, imageSize: size), "A clipped desk/frame must not auto-capture")
        XCTAssertNil(CaptureStyle.cardScore(quad(0.05,0.3,0.1,0.04), imageSize: size), "Tiny objects must not trigger")
    }
}


extension LiveCameraTests {
    func testVisionFindsSyntheticCardAndExcludesPortraitInsideIt() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 1600), format: format).image { c in
            UIColor.darkGray.setFill(); c.fill(CGRect(x: 0, y: 0, width: 1000, height: 1600))
            UIColor.white.setFill(); c.fill(CGRect(x: 180, y: 400, width: 640, height: 404))
            UIColor.blue.setFill(); c.fill(CGRect(x: 220, y: 460, width: 120, height: 190))
            ("SAMPLE CARD" as NSString).draw(at: CGPoint(x: 380, y: 460), withAttributes: [.font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.black])
        }
        let card = try XCTUnwrap(CaptureStyle.card.detect(image))
        XCTAssertEqual(card.points[0].x, 0.18, accuracy: 0.04)
        XCTAssertEqual(card.points[0].y, 0.25, accuracy: 0.04)
        XCTAssertEqual(card.points[2].x, 0.82, accuracy: 0.04)
        XCTAssertEqual(card.points[2].y, 0.5025, accuracy: 0.04)
    }
}


extension LiveCameraTests {
    func testIDRequiresGuideAlignmentThenAnUninterruptedStableHold() {
        var tracker = LiveDocumentTracker()
        _ = tracker.update(page, at: 0, eligible: false)
        XCTAssertEqual(tracker.update(page, at: 5, eligible: false).phase, .aligning)
        XCTAssertFalse(tracker.update(page, at: 6, eligible: true).canAutoCapture)
        XCTAssertTrue(tracker.update(page, at: 7, eligible: true).canAutoCapture)
        XCTAssertFalse(tracker.update(page, at: 8, eligible: false).canAutoCapture)
        XCTAssertFalse(tracker.update(page, at: 9, eligible: true).canAutoCapture)
        XCTAssertTrue(tracker.update(page, at: 10, eligible: true).canAutoCapture)
        tracker.markCapture()
        _ = tracker.update(page, at: 11, eligible: false)
        XCTAssertFalse(tracker.update(page, at: 20, eligible: true).canAutoCapture)
    }
    func testCardCanBeAnywhereVisibleAndDoesNotWaitAfterGreen() {
        let card = ScanQuad(points:[.init(x:0.12,y:0.2),.init(x:0.65,y:0.21),.init(x:0.64,y:0.45),.init(x:0.11,y:0.44)])
        XCTAssertTrue(CaptureStyle.fullyVisible(card,in:.full))
        var clipped = card; clipped.points[0].x = -0.01
        XCTAssertFalse(CaptureStyle.fullyVisible(clipped,in:.full))
        XCTAssertFalse(CaptureStyle.fullyVisible(card,in:nil))
        var tracker = LiveDocumentTracker()
        XCTAssertFalse(tracker.update(card,at:0,requiredSteadyDuration:0.18).canAutoCapture)
        let green = tracker.update(card,at:0.22,requiredSteadyDuration:0.18)
        XCTAssertEqual(green.phase,.steady)
        XCTAssertTrue(green.canAutoCapture)
        tracker.markCapture()
        XCTAssertFalse(tracker.update(card,at:1,requiredSteadyDuration:0.18).canAutoCapture)
        _ = tracker.update(nil,at:2,missingReleaseDuration:0.2)
        _ = tracker.update(nil,at:2.22,missingReleaseDuration:0.2)
        _ = tracker.update(card,at:3,requiredSteadyDuration:0.18)
        XCTAssertTrue(tracker.update(card,at:3.22,requiredSteadyDuration:0.18).canAutoCapture)
    }
    func testCapturedCardRemovesDeskAndRejectsMissingEdges() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size:CGSize(width:1000,height:1600), format:format).image { c in
            UIColor.brown.setFill(); c.fill(CGRect(x:0,y:0,width:1000,height:1600))
            UIColor.white.setFill(); c.fill(CGRect(x:180,y:400,width:640,height:404))
            UIColor.blue.setFill(); c.fill(CGRect(x:220,y:460,width:120,height:190))
        }
        let quad = try XCTUnwrap(CaptureStyle.card.detect(image,capturedPhoto:true))
        XCTAssertEqual(quad.points[0].x,0.18,accuracy:0.025)
        XCTAssertEqual(quad.points[2].y,0.5025,accuracy:0.025)
        let rendered = try DocumentProcessing.render(CIImage(image:image)!,crop:quad,turns:0,enhancement:.original,strength:1)
        XCTAssertEqual(rendered.extent.width/rendered.extent.height,1.586,accuracy:0.08)
        XCTAssertLessThan(rendered.extent.height,450)
        XCTAssertLessThan(rendered.extent.width,690)
        let blank = UIGraphicsImageRenderer(size:CGSize(width:1000,height:1600),format:format).image { c in
            UIColor.gray.setFill(); c.fill(CGRect(x:0,y:0,width:1000,height:1600))
        }
        XCTAssertNil(CaptureStyle.card.detect(blank,capturedPhoto:true))
    }
}


extension LiveCameraTests {
    func testIdentityCleanupRemovesUnevenDeskStripsAndKeepsPrintedColors() throws {
        let desk = CIImage(color:CIColor(red:0.5,green:0.22,blue:0.08)).cropped(to:CGRect(x:0,y:0,width:880,height:560))
        let cardBounds = CGRect(x:9,y:13,width:860,height:540)
        let cardMask = CIFilter(name:"CIRoundedRectangleGenerator",parameters:["inputExtent":CIVector(cgRect:cardBounds),"inputRadius":28,"inputColor":CIColor.white])!.outputImage!
        let paper = CIImage(color:.white).cropped(to:desk.extent)
        let card = paper.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:desk,kCIInputMaskImageKey:cardMask])
        let stripe = CIImage(color:.black).cropped(to:CGRect(x:30,y:400,width:820,height:60))
        let blue = CIImage(color:CIColor(red:0.1,green:0.4,blue:0.8)).cropped(to:CGRect(x:180,y:150,width:100,height:100))
        let source = blue.composited(over:stripe.composited(over:card))
        let result = IdentityBackground.clean(source)
        XCTAssertLessThan(result.extent.width,870)
        XCTAssertLessThan(result.extent.height,545)
        func rgb(_ x:CGFloat,_ y:CGFloat) -> [UInt8] {
            var pixel = [UInt8](repeating:0,count:4)
            DocumentProcessing.context.render(result,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            return pixel
        }
        for point in [CGPoint(x:0,y:0),CGPoint(x:result.extent.width-1,y:0),CGPoint(x:0,y:result.extent.height-1)] {
            XCTAssertTrue(rgb(point.x,point.y).prefix(3).allSatisfy { $0 > 245 },"Rounded corner background must be white")
        }
        XCTAssertLessThan(rgb(400,420)[0],10,"Magnetic stripe must stay black")
        XCTAssertGreaterThan(rgb(210,180)[2],180,"Printed blue must remain blue")
        XCTAssertGreaterThan(rgb(400,1)[0],240,"Bottom desk strip must be gone")
        XCTAssertGreaterThan(rgb(400,result.extent.height-2)[1],240,"Top desk strip must be gone")
    }

    func testIdentityPreviewAndExportShareCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size:CGSize(width:880,height:560),format:format).image { c in
            UIColor.brown.setFill(); c.fill(CGRect(x:0,y:0,width:880,height:560))
            UIColor.white.setFill(); UIBezierPath(roundedRect:CGRect(x:10,y:10,width:860,height:540),cornerRadius:28).fill()
            UIColor.blue.setFill(); c.fill(CGRect(x:180,y:150,width:100,height:100))
        }
        try image.pngData()!.write(to:root.appendingPathComponent("card.png"))
        var page = ScanPage(imageFile:"card.png"); page.identityBackgroundCleanup = true
        let preview = try await ScanPreviewRenderer().render(page,root:root,maxDimension:nil)
        let exported = try Imaging.render(page,root:root)
        XCTAssertEqual(preview.size,exported.size)
        XCTAssertLessThan(exported.size.width,880)
        XCTAssertLessThan(exported.size.height,560)
        let cache = PageThumbnailCache()
        var unchecked = page; unchecked.cropReviewNeeded = true
        let before = try await cache.image(for:unchecked,root:root)
        let after = try await cache.image(for:page,root:root)
        XCTAssertNotEqual(before.size.width/before.size.height,after.size.width/after.size.height,
                          "Confirming ID edges must invalidate the uncleaned thumbnail")

    }
}


extension LiveCameraTests {
    func testThickBottomDeskStripIsRemovedWithoutClippingBarcode() throws {
        let bounds = CGRect(x:0,y:0,width:880,height:560)
        let desk = CIImage(color:CIColor(red:0.5,green:0.22,blue:0.08)).cropped(to:bounds)
        // An 8% bottom band reproduces a case the previous 3% search missed.
        let card = CIImage(color:.white).cropped(to:CGRect(x:0,y:45,width:880,height:515))
        let barcode = CIImage(color:.black).cropped(to:CGRect(x:25,y:65,width:570,height:48))
        let source = barcode.composited(over:card.composited(over:desk))
        let cleaned = IdentityBackground.clean(source)
        XCTAssertLessThan(cleaned.extent.height,520)
        XCTAssertGreaterThan(cleaned.extent.height,507,"Do not cut into ID content")
        var pixel = [UInt8](repeating:0,count:4)
        func read(_ x:CGFloat,_ y:CGFloat) -> [UInt8] {
            DocumentProcessing.context.render(cleaned,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:x,y:y,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
            return pixel
        }
        XCTAssertTrue(read(400,1).prefix(3).allSatisfy { $0 > 245 },"Bottom background must be white")
        XCTAssertTrue(read(100,25).prefix(3).allSatisfy { $0 < 10 },"Barcode must remain black")
    }

    func testInternalDarkBandIsNotTreatedAsConnectedBackground() {
        let bounds = CGRect(x:0,y:0,width:880,height:560)
        let white = CIImage(color:.white).cropped(to:bounds)
        // The outer margin is white, so this is printed content, not a desk.
        let printed = CIImage(color:.black).cropped(to:CGRect(x:0,y:10,width:880,height:28))
        let cleaned = IdentityBackground.clean(printed.composited(over:white))
        XCTAssertEqual(cleaned.extent,bounds)
    }

    func testSidewaysPhoneProducesLandscapeTurnsWithHysteresis() {
        // Upright portrait, then top of the phone to the right and to the left.
        XCTAssertEqual(CaptureOrientation.turns(gravityX: 0, gravityY: -1, previous: 0), 0)
        XCTAssertEqual(CaptureOrientation.turns(gravityX: 1, gravityY: 0, previous: 0), 1)
        XCTAssertEqual(CaptureOrientation.turns(gravityX: -1, gravityY: 0, previous: 0), 3)
        XCTAssertEqual(CaptureOrientation.turns(gravityX: -1, gravityY: 0, previous: 1), 3)
        // Flat over the page keeps the last decision.
        XCTAssertEqual(CaptureOrientation.turns(gravityX: 0.1, gravityY: -0.1, previous: 1), 1)
        XCTAssertEqual(CaptureOrientation.turns(gravityX: -0.1, gravityY: 0.2, previous: 0), 0)
        // Near the 45° boundary nothing flips back and forth.
        let near = 48 * Double.pi / 180
        XCTAssertEqual(CaptureOrientation.turns(gravityX: sin(near), gravityY: -cos(near), previous: 0), 0)
        XCTAssertEqual(CaptureOrientation.turns(gravityX: sin(near), gravityY: -cos(near), previous: 1), 1)
        // Upside down is not treated as a new orientation.
        XCTAssertEqual(CaptureOrientation.turns(gravityX: 0, gravityY: 1, previous: 0), 0)
    }

    @MainActor
    func testLandscapeCaptureIsStoredAsRotatedPageAndRendersWide() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), id = try store.createDraft()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }
        try store.appendImage(photo, to: id, detectedCrop: .full, enhancement: .original, style: .document, turns: 1)
        let page = try XCTUnwrap(store.document(id)?.pages.first)
        XCTAssertEqual(page.turns, 1)
        let rendered = try Imaging.render(page, root: store.root)
        XCTAssertGreaterThan(rendered.size.width, rendered.size.height, "A sideways capture must produce a landscape page")
    }
}
