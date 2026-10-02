import CoreImage
import UIKit

// Applied only to confirmed ID crops, after perspective correction. Work in a
// small analysis raster, but crop/mask original pixels so printing stays intact.
enum IdentityBackground {
    static func clean(_ source: CIImage) -> CIImage {
        let extent = source.extent
        let scale = min(1, 640 / max(extent.width, extent.height))
        let small = source.clampedToExtent().transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Fractional analysis bounds can rasterize an extra transparent row.
        // Treating that row as black breaks border connectivity and can create
        // a false edge on an otherwise clean card.
        let analysisBounds = CGRect(x:0,y:0,width:floor(extent.width*scale),height:floor(extent.height*scale))
        guard let cg = DocumentProcessing.context.createCGImage(small, from: analysisBounds) else { return source }
        let w = cg.width, h = cg.height
        guard w >= 80, h >= 80 else { return source }
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let c = CGContext(data: raw.baseAddress, width:w, height:h, bitsPerComponent:8,
                                    bytesPerRow:w*4, space:CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // CGImage raster rows are read top-down below.
            c.draw(cg, in:CGRect(x:0,y:0,width:w,height:h)); return true
        }
        guard rendered else { return source }
        func rgb(_ x: Int, _ y: Int) -> [Double] {
            let i = (max(0,min(h-1,y))*w+max(0,min(w-1,x)))*4
            return (0..<3).map { Double(pixels[i+$0])/255 }
        }
        // A residual desk strip is a coherent, lighter transition along most
        // of an outer edge. Search up to 10%, but require the candidate
        // background to connect continuously to the outer border. This avoids
        // treating an internal dark printed stripe as an external desk edge.
        func inset(horizontal: Bool, reverse: Bool) -> Int {
            let depth = horizontal ? h : w, length = horizontal ? w : h
            let limit = max(1,Int(Double(depth)*0.10))
            var best = 0, bestScore = 0.0
            func sample(_ d: Int, _ t: Int) -> [Double] {
                let d = reverse ? depth-1-d : d
                return horizontal ? rgb(t,d) : rgb(d,t)
            }
            for d in 1...limit {
                var scores = [Double]()
                for step in 0..<31 {
                    let t = Int(Double(length) * (0.2 + 0.6*Double(step)/30))
                    let outerDepth = max(0,d-3)
                    let outer = sample(outerDepth,t), inner = sample(min(depth-1,d+1),t)
                    let brightness = (inner.reduce(0,+)-outer.reduce(0,+))/3
                    let distance = zip(inner,outer).map { abs($0-$1) }.reduce(0,+)/3
                    let lightInterior = inner.reduce(0,+)/3 > 0.48
                    // Check the full proposed discarded band, not just its
                    // innermost gradient. White margins enclosing dark text
                    // must not be mistaken for a removable dark background.
                    let connected = [0, outerDepth/3, 2*outerDepth/3, outerDepth].allSatisfy { offset in
                        let edge = sample(offset,t)
                        let difference = zip(edge,outer).map { abs($0-$1) }.reduce(0,+)/3
                        return difference < 0.16
                    }
                    scores.append(lightInterior && brightness > 0.07 && connected ? distance : 0)
                }
                scores.sort()
                // Lower quartile requires evidence along at least 75% of edge.
                let score = scores[7]
                if score > max(0.12,bestScore+0.025) { bestScore = score; best = d }
            }
            return best > 0 ? min(limit, best+2) : 0
        }
        let left = inset(horizontal:false,reverse:false), right = inset(horizontal:false,reverse:true)
        // CGImage rows are top-down; CI crop coordinates are bottom-up.
        let top = inset(horizontal:true,reverse:false), bottom = inset(horizontal:true,reverse:true)
        let rect = CGRect(x:extent.minX+CGFloat(left)/scale, y:extent.minY+CGFloat(bottom)/scale,
                          width:extent.width-CGFloat(left+right)/scale,
                          height:extent.height-CGFloat(top+bottom)/scale)
        let cropped = source.cropped(to:rect).transformed(by:CGAffineTransform(translationX:-rect.minX,y:-rect.minY))
        // ID-1 cards have rounded corners. Whiten only their corner cutouts;
        // never whiten the photo, holograms, magnetic stripe or printed fills.
        let bounds = cropped.extent
        let mask = CIFilter(name:"CIRoundedRectangleGenerator", parameters:[
            "inputExtent":CIVector(cgRect:bounds), "inputRadius":min(bounds.width,bounds.height)*0.055,
            "inputColor":CIColor.white
        ])?.outputImage?.cropped(to:bounds)
        guard let mask else { return cropped }
        return cropped.applyingFilter("CIBlendWithMask", parameters:[
            kCIInputBackgroundImageKey:CIImage(color:.white).cropped(to:bounds), kCIInputMaskImageKey:mask
        ]).cropped(to:bounds)
    }
}
