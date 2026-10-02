import XCTest
import UIKit
import CoreImage
@testable import DocumentScanner

@MainActor
final class ClarityTests: XCTestCase {
    private func fixture() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { r in
            UIColor(white: 0.94, alpha: 1).setFill(); r.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIColor(white: 0.40, alpha: 1).setFill(); r.fill(CGRect(x: 50, y: 50, width: 140, height: 3))
            UIColor(white: 0.81, alpha: 1).setFill(); r.fill(CGRect(x: 50, y: 100, width: 140, height: 2))
            UIColor(red: 0.50, green: 0.69, blue: 0.89, alpha: 1).setFill(); r.fill(CGRect(x: 50, y: 150, width: 130, height: 70))
            UIColor(white: 0.35, alpha: 1).setFill(); r.fill(CGRect(x: 70, y: 175, width: 85, height: 3))
        }
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Double] {
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let c = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes.prefix(3).map { Double($0)/255 }
    }
    func testClarityDarkensBlurredStrokesWithoutClosingWhiteGapOrErasingPencil() throws {
        let input = CIImage(cgImage: try XCTUnwrap(fixture().cgImage))
        let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.7]).cropped(to: input.extent)
        let before = try XCTUnwrap(DocumentProcessing.context.createCGImage(blurred, from: blurred.extent))
        let enhanced = try DocumentClarity.enhance(blurred)
        let after = try XCTUnwrap(DocumentProcessing.context.createCGImage(enhanced, from: enhanced.extent))
        let darkBefore = try pixel(before, x: 110, y: 51)[0]
        let darkAfter = try pixel(after, x: 110, y: 51)[0]
        XCTAssertLessThan(darkAfter, darkBefore * 0.65, "Blurred gray ink needs a visible contrast improvement")
        XCTAssertGreaterThan(try pixel(after, x: 110, y: 57)[0], 0.90, "Paper beside a stroke must not gain dark halos")
        let faintBefore = try pixel(before, x: 110, y: 100)[0]
        let faintAfter = try pixel(after, x: 110, y: 100)[0]
        XCTAssertEqual(faintAfter, faintBefore, accuracy: 0.05, "Pencil must not be erased or forced to heavy black")
        let blueBefore = try pixel(before, x: 100, y: 205)
        let blueAfter = try pixel(after, x: 100, y: 205)
        for i in 0..<3 { XCTAssertEqual(blueAfter[i], blueBefore[i], accuracy: 0.025) }
        XCTAssertLessThan(try pixel(after, x: 100, y: 176)[0], try pixel(before, x: 100, y: 176)[0] * 0.7)
    }
    func testNormalizationPreservesPixelsAndRotatesScaledPhotos() throws {
        let cg = try XCTUnwrap(fixture().cgImage)
        let scaled = UIImage(cgImage: cg, scale: 3, orientation: .up)
        let upright = Imaging.normalized(scaled)
        XCTAssertEqual(upright.cgImage?.width, 400)
        XCTAssertEqual(upright.cgImage?.height, 300)
        let rotated = Imaging.normalized(UIImage(cgImage: cg, scale: 3, orientation: .right))
        XCTAssertEqual(rotated.cgImage?.width, 300)
        XCTAssertEqual(rotated.cgImage?.height, 400)
        XCTAssertEqual(rotated.imageOrientation, .up)
        let originalPixel = try pixel(cg, x: 100, y: 205)
        let rotatedPixel = try pixel(try XCTUnwrap(rotated.cgImage), x: 94, y: 100)
        for i in 0..<3 { XCTAssertEqual(rotatedPixel[i], originalPixel[i], accuracy: 0.02) }
    }
}
