import XCTest
import UIKit
import CoreImage
import PDFKit
import Vision
@testable import DocumentScanner

@MainActor
final class ScanQualityTests: XCTestCase {
    private func photo() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { renderer in
            let cg = renderer.cgContext
            let colors = [UIColor(red: 0.56, green: 0.51, blue: 0.43, alpha: 1).cgColor, UIColor(red: 0.94, green: 0.90, blue: 0.82, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 600, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            UIColor.black.setFill(); cg.fill(CGRect(x: 80, y: 100, width: 120, height: 8))
            UIColor(red: 0.23, green: 0.25, blue: 0.29, alpha: 1).setFill(); cg.fill(CGRect(x: 80, y: 540, width: 180, height: 3))
            UIColor(red: 0.27, green: 0.42, blue: 0.65, alpha: 1).setFill(); cg.fill(CGRect(x: 280, y: 280, width: 110, height: 20))
        }
    }
    private func pixel(_ image: UIImage, x: Int, y: Int) throws -> [Double] {
        let cg = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.prefix(3).map { Double($0)/255 }
    }
    private func render(_ image: UIImage, _ enhancement: Enhancement) throws -> UIImage {
        let output = try DocumentProcessing.render(CIImage(cgImage: image.cgImage!), crop: .full, turns: 0, enhancement: enhancement)
        return UIImage(cgImage: try XCTUnwrap(DocumentProcessing.context.createCGImage(output, from: output.extent)))
    }
    func testPaperWhiteningReducesShadowWithoutRemovingInkOrBlueHighlight() throws {
        let source = photo(), output = try render(source, .document)
        let left = try pixel(output, x: 40, y: 400), right = try pixel(output, x: 500, y: 400)
        XCTAssertGreaterThan(left.min()!, 0.91)
        XCTAssertGreaterThan(right.min()!, 0.91)
        XCTAssertLessThan(abs(left[0]-right[0]), 0.07)
        XCTAssertLessThan(try pixel(output, x: 130, y: 104).max()!, 0.2)
        XCTAssertLessThan(try pixel(output, x: 130, y: 541).max()!, 0.75)
        let blue = try pixel(output, x: 335, y: 290)
        XCTAssertGreaterThan(blue[2]-blue[0], 0.12)
        let original = try render(source, .original)
        let originalPaper = try pixel(original, x: 40, y: 400)
        XCTAssertLessThan(originalPaper.min()!, 0.7)
        XCTAssertEqual(originalPaper[0], try pixel(source, x: 40, y: 400)[0], accuracy: 0.02)
    }
    func testLargeBlueAndYellowAreasAreNotUsedAsPaperWhiteReference() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 600,height: 800),format: format).image { renderer in
            let cg = renderer.cgContext
            let colors = [UIColor(red: 0.56,green: 0.51,blue: 0.43,alpha: 1).cgColor,UIColor(red: 0.94,green: 0.9,blue: 0.82,alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),colors: colors,locations: [0,1])!
            cg.drawLinearGradient(gradient,start: .zero,end: CGPoint(x: 600,y: 0),options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
            UIColor(red: 0.27,green: 0.42,blue: 0.65,alpha: 1).setFill()
            cg.fill(CGRect(x: 80,y: 280,width: 420,height: 260))
            UIColor(red: 0.85,green: 0.7,blue: 0.2,alpha: 1).setFill()
            cg.fill(CGRect(x: 80,y: 150,width: 420,height: 90))
            UIColor.black.setFill(); cg.fill(CGRect(x: 120,y: 400,width: 130,height: 5))
        }
        let output = try render(source,.document)
        for point in [(150,340),(320,450),(450,500)] {
            let blue = try pixel(output,x: point.0,y: point.1)
            XCTAssertGreaterThan(blue[2]-blue[0],0.2,"Blue cell at \(point) must retain its color across its full area")
            XCTAssertLessThan(blue[0],0.8)
        }
        let yellow = try pixel(output,x: 350,y: 200)
        XCTAssertGreaterThan(yellow[0]-yellow[2],0.35)
        XCTAssertGreaterThan(try pixel(output,x: 40,y: 600).min()!,0.91)
        XCTAssertLessThan(try pixel(output,x: 160,y: 402).max()!,0.2)
    }
    func testFullColorPageUsesScalarFallbackAndRetainsColor() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400,height: 500),format: format).image { renderer in
            UIColor(red: 0.25,green: 0.4,blue: 0.7,alpha: 1).setFill();renderer.fill(CGRect(x: 0,y: 0,width: 400,height: 500))
            UIColor.black.setFill();renderer.fill(CGRect(x: 70,y: 130,width: 180,height: 5))
        }
        let output = try render(image,.document), blue = try pixel(output,x: 200,y: 300)
        XCTAssertGreaterThan(blue[2]-blue[0],0.35)
        XCTAssertLessThan(blue[0],0.75)
        XCTAssertLessThan(try pixel(output,x: 130,y: 132).max()!,0.2)
    }

    func testWarmPaperBecomesDigitalWhiteWithoutRemovingPaleYellowArtwork() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { renderer in
            let cg = renderer.cgContext
            UIColor.white.setFill(); cg.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            let colors = [UIColor(red: 0.78, green: 0.72, blue: 0.58, alpha: 1).cgColor, UIColor.white.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            cg.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 570, options: [.drawsAfterEndLocation])
            UIColor.black.setFill(); cg.fill(CGRect(x: 90, y: 100, width: 200, height: 3))
            UIColor(red: 0.98, green: 0.96, blue: 0.86, alpha: 1).setFill()
            cg.fill(CGRect(x: 370, y: 620, width: 140, height: 70))
            UIColor(white: 0.55, alpha: 1).setFill(); cg.fill(CGRect(x: 100, y: 720, width: 180, height: 2))
        }
        let output = try render(source, .document)
        for point in [(40,40), (160,50), (40,300), (250,300)] {
            let color = try pixel(output, x: point.0, y: point.1)
            XCTAssertGreaterThan(color.min()!, 0.98, "Warm paper at \(point) must read as digital white")
            XCTAssertLessThan(color.max()!-color.min()!, 0.015)
        }
        let yellow = try pixel(output, x: 440, y: 650)
        XCTAssertGreaterThan(yellow[0]-yellow[2], 0.085, "A bounded pale yellow printed area must retain its color")
        XCTAssertLessThan(try pixel(output, x: 150, y: 101).max()!, 0.15)
        XCTAssertLessThan(try pixel(output, x: 150, y: 720).max()!, 0.65)
    }

    func testWarmShadowAlongOnePageEdgeIsWhitenedAndColoredGridSurvives() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { renderer in
            slantedGrid(rows: 12).draw(at: .zero)
            let cg = renderer.cgContext
            cg.saveGState(); cg.clip(to: CGRect(x: 45, y: 0, width: 510, height: 65))
            let colors = [UIColor(red: 0.87, green: 0.83, blue: 0.73, alpha: 1).cgColor, UIColor.white.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: CGPoint(x: 45, y: 0), end: CGPoint(x: 500, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            cg.restoreGState()
            UIColor(red: 0.98, green: 0.94, blue: 0.74, alpha: 1).setFill()
            cg.fill(CGRect(x: 330, y: 310, width: 65, height: 15))
        }
        let output = try render(source, .document)
        let paper = try pixel(output, x: 200, y: 25)
        XCTAssertGreaterThan(paper.min()!, 0.98)
        // The verified grid transform can move the colored strip slightly.
        var yellowCount = 0
        for y in stride(from: 280, to: 350, by: 4) { for x in stride(from: 310, to: 420, by: 4) {
            let color = try pixel(output, x: x, y: y)
            if color[0]-color[2] > 0.15 { yellowCount += 1 }
        }}
        XCTAssertGreaterThan(yellowCount, 20)
    }
    func testConfidentDocumentCanOccupyAQuarterOfCameraFrame() {
        let sheet = ScanQuad(points: [.init(x: 0.25,y: 0.2),.init(x: 0.75,y: 0.2),.init(x: 0.75,y: 0.7),.init(x: 0.25,y: 0.7)])
        XCTAssertTrue(DocumentProcessing.acceptableCrop(sheet,source: .document,confidence: 0.9))
        XCTAssertFalse(DocumentProcessing.acceptableCrop(sheet,source: .document,confidence: 0.75))
        XCTAssertFalse(DocumentProcessing.acceptableCrop(sheet,source: .rectangle,confidence: 1))
        XCTAssertTrue(DocumentProcessing.acceptableCrop(sheet,source: .rectangle,confidence: 1,boundarySupport: true))
        let tiny = ScanQuad(points: [.init(x: 0.4,y: 0.4),.init(x: 0.6,y: 0.4),.init(x: 0.6,y: 0.6),.init(x: 0.4,y: 0.6)])
        XCTAssertFalse(DocumentProcessing.acceptableCrop(tiny,source: .document,confidence: 1,boundarySupport: true))
    }
    func testDetectionChoosesSmallPaperInsteadOfPrintedTable() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800,height: 1000),format: format).image { renderer in
            let cg = renderer.cgContext
            UIColor(red: 0.43,green: 0.21,blue: 0.07,alpha: 1).setFill(); cg.fill(CGRect(x: 0,y: 0,width: 800,height: 1000))
            UIColor.white.setFill(); cg.fill(CGRect(x: 200,y: 200,width: 400,height: 600))
            UIColor.black.setStroke(); cg.setLineWidth(2)
            cg.stroke(CGRect(x: 230,y: 250,width: 330,height: 330))
            for y in stride(from: 280,through: 550,by: 30) { cg.move(to: CGPoint(x: 230,y: y));cg.addLine(to: CGPoint(x: 560,y: y));cg.strokePath() }
            cg.move(to: CGPoint(x: 300,y: 250));cg.addLine(to: CGPoint(x: 300,y: 580));cg.strokePath()
        }
        let detected = try XCTUnwrap(DocumentProcessing.detect(try XCTUnwrap(image.cgImage)))
        XCTAssertEqual(DocumentProcessing.area(detected),0.3,accuracy: 0.045)
        XCTAssertEqual(detected.points[0].x,0.25,accuracy: 0.04)
        XCTAssertEqual(detected.points[2].y,0.8,accuracy: 0.04)
    }
    func testMonochromeKeepsInkAndMakesChannelsEqual() throws {
        let output = try render(photo(), .mono)
        let color = try pixel(output, x: 335, y: 290)
        XCTAssertEqual(color[0], color[1], accuracy: 0.01); XCTAssertEqual(color[1], color[2], accuracy: 0.01)
        XCTAssertLessThan(try pixel(output, x: 130, y: 104).max()!, 0.2)
    }
    func testAutoCropRejectsSmallTableInsidePaper() {
        let table = ScanQuad(points: [.init(x: 0.3, y: 0.1), .init(x: 0.7, y: 0.1), .init(x: 0.7, y: 0.7), .init(x: 0.3, y: 0.7)])
        XCTAssertFalse(DocumentProcessing.acceptableCrop(table))
        XCTAssertTrue(DocumentProcessing.acceptableCrop(.full))
    }
    func testNewPhotoUsesDocumentModeAndFlagsMissingEdges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root), id = try store.createDraft()
        try store.appendImage(photo(), to: id)
        let page = try XCTUnwrap(store.document(id)?.pages.first)
        XCTAssertEqual(page.enhancement, .document); XCTAssertEqual(page.cropReviewNeeded, true)
        let pdf = try XCTUnwrap(PDFDocument(data: Imaging.pdf(try XCTUnwrap(store.document(id)), root: root)))
        XCTAssertEqual(pdf.pageCount, 1)
        let reopened = LibraryStore(root: root)
        XCTAssertEqual(reopened.document(id)?.pages.first?.enhancement, .document)
    }
    func testExistingPageWithoutNewSettingsStillDecodes() throws {
        let old = Data("{\"id\":\"CF78F2E3-DA53-408B-A2C2-C86860CD67C8\",\"imageFile\":\"old.jpg\",\"crop\":{\"points\":[{\"x\":0,\"y\":0},{\"x\":1,\"y\":0},{\"x\":1,\"y\":1},{\"x\":0,\"y\":1}]},\"turns\":0,\"enhancement\":\"Original\",\"textBlocks\":[],\"ocrComplete\":false}".utf8)
        let page = try JSONDecoder().decode(ScanPage.self, from: old)
        XCTAssertEqual(page.enhancement, .original); XCTAssertEqual(page.enhancementStrength, 1); XCTAssertNil(page.cropReviewNeeded)
    }
    func testPerspectiveCorrectionUsesAllFourCorners() throws {
        let quad = ScanQuad(points: [.init(x: 0.15, y: 0.12), .init(x: 0.85, y: 0.2), .init(x: 0.95, y: 0.9), .init(x: 0.05, y: 0.82)])
        let image = try DocumentProcessing.render(CIImage(cgImage: photo().cgImage!), crop: quad, turns: 0, enhancement: .original)
        XCTAssertLessThan(image.extent.width, 600); XCTAssertLessThan(image.extent.height, 800)
        XCTAssertGreaterThan(image.extent.width, 300); XCTAssertGreaterThan(image.extent.height, 400)
    }

    private func slantedGrid(rows: Int, corners: [CGPoint] = [CGPoint(x: 65,y: 90),CGPoint(x: 540,y: 75),CGPoint(x: 535,y: 560),CGPoint(x: 85,y: 570)]) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { renderer in
            let cg = renderer.cgContext
            UIColor.white.setFill(); cg.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor(white: 0.3, alpha: 1).setStroke(); cg.setLineWidth(2.5)
            for row in 0...rows {
                let t = CGFloat(row)/CGFloat(max(1,rows))
                cg.move(to: CGPoint(x: corners[0].x+(corners[3].x-corners[0].x)*t, y: corners[0].y+(corners[3].y-corners[0].y)*t))
                cg.addLine(to: CGPoint(x: corners[1].x+(corners[2].x-corners[1].x)*t, y: corners[1].y+(corners[2].y-corners[1].y)*t))
                cg.strokePath()
            }
            for column in 0...4 {
                let t = CGFloat(column)/4
                cg.move(to: CGPoint(x: corners[0].x+(corners[1].x-corners[0].x)*t, y: corners[0].y+(corners[1].y-corners[0].y)*t))
                cg.addLine(to: CGPoint(x: corners[3].x+(corners[2].x-corners[3].x)*t, y: corners[3].y+(corners[2].y-corners[3].y)*t))
                cg.strokePath()
            }
            // Content beyond the table must survive the correction.
            UIColor.red.setFill(); cg.fill(CGRect(x: 200,y: 710,width: 35,height: 25))
        }
    }

    func testResidualGridCorrectionStraightensRulingsAndPreservesOutsideContent() throws {
        let source = slantedGrid(rows: 12)
        let alignment = DocumentProcessing.alignPrintedGrid(CIImage(cgImage: try XCTUnwrap(source.cgImage)))
        XCTAssertNotNil(alignment.grid)
        let result = try XCTUnwrap(DocumentProcessing.context.createCGImage(alignment.image, from: alignment.image.extent))
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 12; request.minimumConfidence = 0.8
        try VNImageRequestHandler(cgImage: result).perform([request])
        let rectangle = try XCTUnwrap(request.results?.max(by: { $0.boundingBox.width*$0.boundingBox.height < $1.boundingBox.width*$1.boundingBox.height }))
        XCTAssertEqual(rectangle.topLeft.y, rectangle.topRight.y, accuracy: 0.006)
        XCTAssertEqual(rectangle.bottomLeft.y, rectangle.bottomRight.y, accuracy: 0.006)
        XCTAssertEqual(rectangle.topLeft.x, rectangle.bottomLeft.x, accuracy: 0.006)
        XCTAssertEqual(rectangle.topRight.x, rectangle.bottomRight.x, accuracy: 0.006)
        XCTAssertGreaterThan(result.height, 740, "Correction must retain the full page below the table")
        let output = UIImage(cgImage: result)
        var redSamples = 0
        for y in stride(from: result.height*3/4, to: result.height, by: 5) {
            for x in stride(from: 0, to: result.width, by: 5) {
                let color = try pixel(output,x: x,y: y)
                if color[0] > 0.7 && color[1] < 0.35 && color[2] < 0.35 { redSamples += 1 }
            }
        }
        XCTAssertGreaterThan(redSamples, 15, "A mark outside the table must remain in the corrected scan")
    }

    func testObliqueGridCorrectionStraightensLargeSkewWithoutCroppingSignature() throws {
        // Both the rotation and the convergence exceed the old 5°/3° limits.
        let source = slantedGrid(rows: 12, corners: [CGPoint(x: 120,y: 75),CGPoint(x: 510,y: 175),CGPoint(x: 550,y: 570),CGPoint(x: 65,y: 505)])
        let alignment = DocumentProcessing.alignPrintedGrid(CIImage(cgImage: try XCTUnwrap(source.cgImage)))
        XCTAssertNotNil(alignment.grid)
        let result = try XCTUnwrap(DocumentProcessing.context.createCGImage(alignment.image, from: alignment.image.extent))
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 12; request.minimumConfidence = 0.8
        try VNImageRequestHandler(cgImage: result).perform([request])
        let rectangle = try XCTUnwrap(request.results?.max(by: { $0.boundingBox.width*$0.boundingBox.height < $1.boundingBox.width*$1.boundingBox.height }))
        XCTAssertEqual(rectangle.topLeft.y, rectangle.topRight.y, accuracy: 0.008)
        XCTAssertEqual(rectangle.bottomLeft.y, rectangle.bottomRight.y, accuracy: 0.008)
        XCTAssertEqual(rectangle.topLeft.x, rectangle.bottomLeft.x, accuracy: 0.008)
        XCTAssertEqual(rectangle.topRight.x, rectangle.bottomRight.x, accuracy: 0.008)
        let output = UIImage(cgImage: result)
        var redSamples = 0
        for y in stride(from: 0, to: result.height, by: 4) { for x in stride(from: 0, to: result.width, by: 4) {
            let color = try pixel(output, x: x, y: y)
            if color[0] > 0.7 && color[1] < 0.35 && color[2] < 0.35 { redSamples += 1 }
        }}
        XCTAssertGreaterThan(redSamples, 15, "The signature outside the table must remain in the image")
        XCTAssertLessThan(result.width*result.height, 600*800*3)
    }

    private func rotatedTextPage(lineCount: Int) throws -> CIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let page = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1100), format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 800, height: 1100))
            for i in 0..<lineCount {
                ("A document line with several words \(i)" as NSString).draw(at: CGPoint(x: 80, y: 150+i*70),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 26), .foregroundColor: UIColor.black])
            }
            UIColor.red.setFill(); renderer.fill(CGRect(x: 70, y: 990, width: 35, height: 25))
        }
        let rotated = CIImage(cgImage: try XCTUnwrap(page.cgImage)).transformed(by: CGAffineTransform(rotationAngle: .pi/18))
        return rotated.composited(over: CIImage(color: .white).cropped(to: rotated.extent))
            .transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
    }

    func testTextOnlyPageDeskewsFromConsistentBaselinesAndKeepsOutsideMark() throws {
        let source = try rotatedTextPage(lineCount: 10)
        let aligned = DocumentProcessing.alignTextLines(source)
        let result = try XCTUnwrap(DocumentProcessing.context.createCGImage(aligned, from: aligned.extent))
        let request = VNDetectTextRectanglesRequest()
        try VNImageRequestHandler(cgImage: result).perform([request])
        let lines = try XCTUnwrap(request.results)
        XCTAssertGreaterThanOrEqual(lines.count, 8)
        for line in lines where line.boundingBox.width > 0.15 {
            let angle = atan2((line.topRight.y-line.topLeft.y)*Double(result.height),
                              (line.topRight.x-line.topLeft.x)*Double(result.width))
            XCTAssertLessThan(abs(angle), .pi/180, "Text baselines should be within 1° of horizontal")
        }
        let output = UIImage(cgImage: result)
        var redSamples = 0
        for y in stride(from: 0, to: result.height, by: 6) { for x in stride(from: 0, to: result.width, by: 6) {
            let color = try pixel(output, x: x, y: y)
            if color[0] > 0.7 && color[1] < 0.35 && color[2] < 0.35 { redSamples += 1 }
        }}
        XCTAssertGreaterThan(redSamples, 12)
    }

    func testSparseTextDoesNotTriggerSpeculativePageRotation() throws {
        let source = try rotatedTextPage(lineCount: 2)
        let aligned = DocumentProcessing.alignTextLines(source)
        XCTAssertEqual(aligned.extent, source.extent)
    }

    func testResidualCorrectionDoesNotReshapeAnUnruledRectangle() throws {
        let source = slantedGrid(rows: 1)
        let alignment = DocumentProcessing.alignPrintedGrid(CIImage(cgImage: try XCTUnwrap(source.cgImage)))
        XCTAssertNil(alignment.grid)
        XCTAssertEqual(alignment.image.extent.width,600)
        XCTAssertEqual(alignment.image.extent.height,800)
    }

    func testDocumentFilterRestoresGrayInkContrastWithoutDroppingThinStrokes() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 400,height: 500),format: format).image { renderer in
            UIColor.white.setFill();renderer.fill(CGRect(x: 0,y: 0,width: 400,height: 500))
            UIColor(white: 0.42,alpha: 1).setFill();renderer.fill(CGRect(x: 70,y: 130,width: 240,height: 2))
        }
        let output = try render(source,.document)
        XCTAssertLessThan(try pixel(output,x: 150,y: 130).max()!,0.31)
        XCTAssertGreaterThan(try pixel(output,x: 150,y: 135).min()!,0.95)
    }

    func testWhiteCanvasRejectionDoesNotMistakeGrayInkForShadow() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 500), format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
            UIColor(white: 0.60, alpha: 1).setFill()
            renderer.fill(CGRect(x: 70, y: 140, width: 240, height: 12))
        }
        let output = try render(source, .document)
        XCTAssertLessThan(try pixel(output, x: 150, y: 145).max()!, 0.75)
        XCTAssertGreaterThan(try pixel(output, x: 150, y: 125).min()!, 0.99)
    }

    func testPaleBlueMarkOutsideGridIsPreservedWhenCornerShadowIsWhitened() throws {
        let format = UIGraphicsImageRendererFormat();format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 600,height: 800),format: format).image { renderer in
            slantedGrid(rows: 12).draw(at: .zero)
            let cg = renderer.cgContext
            cg.saveGState();cg.clip(to: CGRect(x: 0,y: 600,width: 330,height: 200))
            let colors = [UIColor(red: 0.62,green: 0.77,blue: 0.94,alpha: 1).cgColor,UIColor.white.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),colors: colors,locations: [0,1])!
            cg.drawLinearGradient(gradient,start: CGPoint(x: 0,y: 600),end: CGPoint(x: 330,y: 600),options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
            cg.restoreGState()
            UIColor(red: 0.65,green: 0.78,blue: 0.94,alpha: 1).setFill();cg.fill(CGRect(x: 430,y: 650,width: 70,height: 50))
        }
        let output = try render(source,.document), cg = try XCTUnwrap(output.cgImage)
        var logoSamples = 0
        for y in stride(from: cg.height*3/4,to: cg.height*9/10,by: 8) {
            for x in stride(from: cg.width*3/5,to: cg.width*9/10,by: 8) {
                let color = try pixel(output,x: x,y: y)
                if color[2]-color[0] > 0.12 && color[0] < 0.88 { logoSamples += 1 }
            }
        }
        XCTAssertGreaterThan(logoSamples,20,"A bounded pale blue mark must not become the illumination reference")
        let paper = try pixel(output,x: cg.width/8,y: cg.height*7/8)
        XCTAssertGreaterThan(paper.min()!,0.91)
    }

    // Paper on a dark desk. `rule` draws a printed line just inside the top paper
    // edge that must never be mistaken for surroundings.
    private func paperOnDesk(rule: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { renderer in
            let cg = renderer.cgContext
            UIColor(red: 0.27, green: 0.18, blue: 0.12, alpha: 1).setFill(); cg.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor.white.setFill(); cg.fill(CGRect(x: 60, y: 50, width: 480, height: 700))
            UIColor.black.setFill(); cg.fill(CGRect(x: 120, y: 120, width: 200, height: 10))
            if rule { UIColor(white: 0.12, alpha: 1).setFill(); cg.fill(CGRect(x: 60, y: 60, width: 480, height: 4)) }
        }
    }
    private func darkPixels(_ image: UIImage, in rect: CGRect) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage?.cropping(to: rect))
        var bytes = [UInt8](repeating: 0, count: cg.width*cg.height*4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] < 80 && bytes[$0+1] < 80 && bytes[$0+2] < 80 }.count
    }
    func testDeskStripBeyondDetectedCornersIsRemoved() throws {
        // Corners 8 px outside the paper on the left/top and 4 px below it, as a
        // coarse segmentation mask produces; the right edge is just inside.
        let quad = ScanQuad(points: [.init(x: 52.0/600, y: 42.0/800), .init(x: 539.0/600, y: 42.0/800),
                                     .init(x: 539.0/600, y: 754.0/800), .init(x: 52.0/600, y: 754.0/800)])
        for enhancement in [Enhancement.original, .document] {
            let output = try DocumentProcessing.render(CIImage(cgImage: paperOnDesk().cgImage!), crop: quad, turns: 0, enhancement: enhancement)
            let image = UIImage(cgImage: try XCTUnwrap(DocumentProcessing.context.createCGImage(output, from: output.extent)))
            let cg = try XCTUnwrap(image.cgImage), w = cg.width, h = cg.height
            for t in [0.25, 0.5, 0.75] {
                let along = { (n: Int) in Int(Double(n)*t) }
                for (x, y) in [(1, along(h)), (w-2, along(h)), (along(w), 1), (along(w), h-2)] {
                    XCTAssertGreaterThan(try pixel(image, x: x, y: y).min()!, 0.8, "\(enhancement) edge pixel (\(x),\(y)) still shows the desk")
                }
            }
            // Only the strip is removed: the page keeps nearly its full size and content.
            XCTAssertGreaterThan(w, 466); XCTAssertLessThan(w, 487)
            XCTAssertGreaterThan(h, 680); XCTAssertLessThan(h, 712)
            XCTAssertGreaterThan(try darkPixels(image, in: CGRect(x: 0, y: 0, width: w, height: h/4)), 1500, "Printed content must survive")
        }
    }
    func testPrintingNearAnAccuratePaperEdgeIsNotTrimmed() throws {
        let quad = ScanQuad(points: [.init(x: 63.0/600, y: 53.0/800), .init(x: 537.0/600, y: 53.0/800),
                                     .init(x: 537.0/600, y: 747.0/800), .init(x: 63.0/600, y: 747.0/800)])
        let source = CIImage(cgImage: paperOnDesk(rule: true).cgImage!)
        let output = try DocumentProcessing.render(source, crop: quad, turns: 0, enhancement: .original)
        XCTAssertGreaterThanOrEqual(output.extent.height, 690, "No strip touches the edge, so nothing may be cropped")
        XCTAssertGreaterThanOrEqual(output.extent.width, 470)
        let image = UIImage(cgImage: try XCTUnwrap(DocumentProcessing.context.createCGImage(output, from: output.extent)))
        XCTAssertGreaterThan(try darkPixels(image, in: CGRect(x: 0, y: 0, width: image.cgImage!.width, height: 20)), 1000, "The printed rule near the top edge must remain")
    }
    func testPrintedGrayBandAtPageEdgeIsKeptWhileDeskIsRemoved() throws {
        // A cover with a pale gray design band printed to its top edge, and a
        // 3 px desk strip above it from slightly misplaced corners.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800), format: format).image { renderer in
            let cg = renderer.cgContext
            UIColor(red: 0.27, green: 0.18, blue: 0.12, alpha: 1).setFill(); cg.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor(white: 0.98, alpha: 1).setFill(); cg.fill(CGRect(x: 60, y: 50, width: 480, height: 700))
            UIColor(red: 0.80, green: 0.80, blue: 0.82, alpha: 1).setFill(); cg.fill(CGRect(x: 60, y: 50, width: 480, height: 30))
        }
        let quad = ScanQuad(points: [.init(x: 61.0/600, y: 47.0/800), .init(x: 539.0/600, y: 47.0/800),
                                     .init(x: 539.0/600, y: 749.0/800), .init(x: 61.0/600, y: 749.0/800)])
        let output = try DocumentProcessing.render(CIImage(cgImage: photo.cgImage!), crop: quad, turns: 0, enhancement: .original)
        let image = UIImage(cgImage: try XCTUnwrap(DocumentProcessing.context.createCGImage(output, from: output.extent)))
        let w = try XCTUnwrap(image.cgImage).width
        for x in [w/4, w/2, w*3/4] {
            let top = try pixel(image, x: x, y: 1)
            XCTAssertGreaterThan(top.min()!, 0.7, "The desk strip must be removed")
            XCTAssertLessThan(top.max()!, 0.9, "The printed gray band must remain at the top edge")
            XCTAssertLessThan(top.max()!-top.min()!, 0.05)
            XCTAssertLessThan(try pixel(image, x: x, y: 20).max()!, 0.9, "The gray band keeps its height")
        }
        XCTAssertGreaterThanOrEqual(output.extent.height, 696)
    }
    func testGradualShadingIsNotTreatedAsResidualEdge() {
        XCTAssertEqual(DocumentProcessing.residualEdges(CIImage(cgImage: photo().cgImage!)), .untouched)
    }
}
