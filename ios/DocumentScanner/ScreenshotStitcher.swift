import UIKit

struct StitchPage: Identifiable {
    var id = UUID()
    var image: UIImage
    var top = 0.0
    var bottom = 0.0
    // Fraction of this trimmed image to skip where it overlaps the previous image.
    var overlap = 0.0
}
enum ScreenshotStitcher {
    static func cropped(_ page: StitchPage) throws -> UIImage {
        guard page.top.isFinite, page.bottom.isFinite, (0...0.3).contains(page.top), (0...0.3).contains(page.bottom),
              let cg = page.image.cgImage else { throw ScannerError.message("Invalid screenshot crop.") }
        let rect = CGRect(x: 0, y: ceil(CGFloat(cg.height)*page.top), width: CGFloat(cg.width), height: floor(CGFloat(cg.height)*(1-page.top-page.bottom)))
        guard let cropped = cg.cropping(to: rect) else { throw ScannerError.message("Keep a larger part of this screenshot.") }
        return UIImage(cgImage: cropped)
    }
    // Conservative vertical registration. Reject blank/repetitive matches rather than silently losing content.
    static func suggestedOverlap(previous: UIImage, next: UIImage) -> Double? {
        func raster(_ image: UIImage, width: Int) -> (pixels: [UInt8], height: Int)? {
            guard let source = image.cgImage else { return nil }
            let height = Int((Double(source.height)*Double(width)/Double(source.width)).rounded())
            guard height >= 24, height <= 6400 else { return nil }
            var pixels = [UInt8](repeating: 0, count: width*height)
            let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                context.interpolationQuality = .high
                context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
            }
            return ok ? (pixels, height) : nil
        }
        let width = 96
        guard let a = raster(previous, width: width), let b = raster(next, width: width) else { return nil }
        let low = max(12, min(a.height,b.height)/12), high = min(a.height,b.height)*4/5
        guard high > low else { return nil }
        var scores: [(Int, Double)] = []
        for overlap in low...high {
            var error = 0.0, sum = 0.0, squared = 0.0, n = 0.0
            for row in 0..<overlap {
                for x in 3..<(width-3) {
                    let left = Double(a.pixels[(a.height-overlap+row)*width+x])
                    let right = Double(b.pixels[row*width+x])
                    error += abs(left-right); sum += right; squared += right*right; n += 1
                }
            }
            let variance = squared/n-pow(sum/n,2)
            if variance > 100 { scores.append((overlap, error/n)) }
        }
        // Small text can alias differently when two crops are downsampled. Verify the
        // strongest candidates at a finer scale before judging uniqueness or removing rows.
        guard let coarse = scores.min(by: { $0.1 < $1.1 }), coarse.1 < 24 else { return nil }
        let fineWidth = min(512, previous.cgImage!.width, next.cgImage!.width)
        guard let fineA = raster(previous, width: fineWidth), let fineB = raster(next, width: fineWidth) else { return nil }
        let scale = Double(fineB.height)/Double(b.height)
        let radius = Int(ceil(scale))
        var candidates = Set<Int>()
        for candidate in scores.sorted(by: { $0.1 < $1.1 }).prefix(12) {
            let center = Int((Double(candidate.0)*scale).rounded())
            for row in (center-radius)...(center+radius) where row > 0 && row <= min(fineA.height,fineB.height)*4/5 { candidates.insert(row) }
        }
        let refined = candidates.map { overlap -> (Int, Double) in
            var error = 0.0, count = 0.0
            for row in stride(from: 0, to: overlap, by: 2) {
                for x in stride(from: 3, to: fineWidth-3, by: 2) {
                    error += abs(Double(fineA.pixels[(fineA.height-overlap+row)*fineWidth+x])-Double(fineB.pixels[row*fineWidth+x])); count += 1
                }
            }
            return (overlap, error/count)
        }
        guard let best = refined.min(by: { $0.1 < $1.1 }), best.1 < 24 else { return nil }
        let rival = refined.filter { abs($0.0-best.0) > radius*3 }.map(\.1).min() ?? 255
        guard rival > best.1 + max(0.5, best.1*0.2), best.1 < rival*0.65 else { return nil }
        return Double(best.0)/Double(fineB.height)
    }
    static func export(_ pages: [StitchPage], width requested: Int = 1080) throws -> ExportedFiles {
        guard (2...12).contains(pages.count), (320...1440).contains(requested),
              pages.allSatisfy({ $0.overlap.isFinite && (0...0.8).contains($0.overlap) }) else { throw ScannerError.message("Choose 2–12 screenshots and check the overlaps.") }
        let images = try pages.map(cropped)
        let width = min(requested, images.compactMap { $0.cgImage?.width }.min() ?? requested)
        var visible: [UIImage] = []
        for (i, image) in images.enumerated() {
            guard let cg = image.cgImage else { throw ScannerError.message("Screenshot unavailable.") }
            let top = i == 0 ? 0 : Int((Double(cg.height)*pages[i].overlap).rounded())
            guard let kept = cg.cropping(to: CGRect(x: 0, y: top, width: cg.width, height: cg.height-top)) else { throw ScannerError.message("Invalid overlap.") }
            visible.append(UIImage(cgImage: kept))
        }
        let heights = visible.map { max(1, Int((Double(width)*$0.size.height/$0.size.width).rounded())) }
        return try LocalDocumentTools.strips(heights: heights, width: width) { i, rect, context in
            UIGraphicsPushContext(context); visible[i].draw(in: rect); UIGraphicsPopContext()
        }
    }
}
