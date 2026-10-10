import Foundation
import Accelerate
import CoreGraphics

/// Small image helpers for page flattening: 8-bit planes, vImage morphology and
/// connected components. Pixel loops stay simple; the heavy filters use vImage
/// so they are fast in debug builds too.
struct Plane {
    var w: Int, h: Int
    var p: [UInt8]
    init(w: Int, h: Int, fill: UInt8 = 0) { self.w = w; self.h = h; p = [UInt8](repeating: fill, count: w * h) }
    @inline(__always) subscript(x: Int, y: Int) -> UInt8 {
        get { p[y * w + x] }
        set { p[y * w + x] = newValue }
    }
    private func run(_ body: (inout vImage_Buffer, inout vImage_Buffer) -> Void) -> Plane {
        var out = Plane(w: w, h: h)
        var src = p
        src.withUnsafeMutableBytes { s in
            out.p.withUnsafeMutableBytes { d in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                body(&a, &b)
            }
        }
        return out
    }
    /// Max filter (dilate) over a kw × kh rectangle.
    func dilate(_ kw: Int, _ kh: Int) -> Plane {
        let kw = max(1, kw | 1), kh = max(1, kh | 1)
        return run { a, b in _ = vImageMax_Planar8(&a, &b, nil, 0, 0, vImagePixelCount(kh), vImagePixelCount(kw), vImage_Flags(kvImageEdgeExtend)) }
    }
    /// Min filter (erode) over a kw × kh rectangle.
    func erode(_ kw: Int, _ kh: Int) -> Plane {
        let kw = max(1, kw | 1), kh = max(1, kh | 1)
        return run { a, b in _ = vImageMin_Planar8(&a, &b, nil, 0, 0, vImagePixelCount(kh), vImagePixelCount(kw), vImage_Flags(kvImageEdgeExtend)) }
    }
    func open(_ kw: Int, _ kh: Int) -> Plane { erode(kw, kh).dilate(kw, kh) }
    func close(_ kw: Int, _ kh: Int) -> Plane { dilate(kw, kh).erode(kw, kh) }
    /// Mean over a k × k box.
    func boxMean(_ k: Int) -> Plane {
        let k = max(1, k | 1)
        return run { a, b in _ = vImageBoxConvolve_Planar8(&a, &b, nil, 0, 0, UInt32(k), UInt32(k), 0, vImage_Flags(kvImageEdgeExtend)) }
    }
}

/// One connected group of set pixels.
struct Blob {
    var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min, area = 0
    var width: Int { x1 - x0 + 1 }
    var height: Int { y1 - y0 + 1 }
}

enum Components {
    /// Labels 8-connected set pixels (value > 0). Returns labels (0 = none, 1...n) and stats.
    static func label(_ m: Plane) -> (labels: [Int32], blobs: [Blob]) {
        let w = m.w, h = m.h
        var labels = [Int32](repeating: 0, count: w * h)
        var blobs: [Blob] = [Blob()]  // index 0 unused
        var stack: [Int] = []
        stack.reserveCapacity(4096)
        for start in 0..<(w * h) where m.p[start] > 0 && labels[start] == 0 {
            let id = Int32(blobs.count)
            var b = Blob()
            labels[start] = id; stack.append(start)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                b.area += 1
                if x < b.x0 { b.x0 = x }; if x > b.x1 { b.x1 = x }
                if y < b.y0 { b.y0 = y }; if y > b.y1 { b.y1 = y }
                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= h { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        if nx < 0 || nx >= w { continue }
                        let j = ny * w + nx
                        if m.p[j] > 0 && labels[j] == 0 { labels[j] = id; stack.append(j) }
                    }
                }
            }
            blobs.append(b)
        }
        return (labels, blobs)
    }
}

/// An RGBA8 copy of a CGImage.
struct RGBAImage {
    let w: Int, h: Int
    var px: [UInt8]
    init?(_ image: CGImage, maxSide: Int? = nil) {
        let f = maxSide.map { min(1, Double($0) / Double(max(image.width, image.height))) } ?? 1
        w = max(1, Int(Double(image.width) * f)); h = max(1, Int(Double(image.height) * f))
        px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok { return nil }
    }
    var gray: Plane {
        var g = Plane(w: w, h: h)
        for i in 0..<(w * h) {
            let r = Int(px[i * 4]), gg = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            g.p[i] = UInt8((r * 77 + gg * 150 + b * 29) >> 8)
        }
        return g
    }
    /// Bilinear gray sample at a point in pixels (top-left origin).
    @inline(__always) func grayAt(_ x: Double, _ y: Double) -> UInt8 {
        let xi = min(max(0, Int(x)), w - 2), yi = min(max(0, Int(y)), h - 2)
        let fx = min(max(0, x - Double(xi)), 1), fy = min(max(0, y - Double(yi)), 1)
        func g(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            return (Double(px[i]) * 77 + Double(px[i + 1]) * 150 + Double(px[i + 2]) * 29) / 256
        }
        let v = g(xi, yi) * (1 - fx) * (1 - fy) + g(xi + 1, yi) * fx * (1 - fy) + g(xi, yi + 1) * (1 - fx) * fy + g(xi + 1, yi + 1) * fx * fy
        return UInt8(max(0, min(255, v)))
    }
}
