import Foundation
import CoreML
import CoreImage
import CoreVideo
import UIKit

/// Small on-device neural models (Core ML, every iPhone the app runs on, no network).
/// Each one is optional: when a model is missing or fails, the hand-written path is used.
/// - PageUnwarp: UVDoc (Verhoeven et al. 2023, MIT) – where each point of a curled or
///   crumpled sheet lies in the photo.
/// - PhotoRestore(Gentle/Strong): Real-ESRGAN realesr-general-x4v3 (Wang et al., BSD-3)
///   – denoise, deblur and enlarge photos.
/// The page model only measures (a grid); document pages are always resampled from the
/// full-resolution original, so text is never redrawn.
enum NeuralModels {
    struct Use: Equatable {
        var unwarp = true
        var restore = true
    }
    /// Tests switch models off to compare with the hand-written paths.
    nonisolated(unsafe) static var use = Use()
    private static let lock = NSLock()
    private static let predictLock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: MLModel] = [:]
    nonisolated(unsafe) private static var missing: Set<String> = []

    static func model(_ name: String) -> MLModel? {
        lock.lock(); defer { lock.unlock() }
        if let m = loaded[name] { return m }
        guard !missing.contains(name) else { return nil }
        let config = MLModelConfiguration()
        // Neural Engine (or CPU), not the GPU: the same page always gives the same
        // result, and Core Image keeps the GPU to itself.
        config.computeUnits = .cpuAndNeuralEngine
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
              let m = try? MLModel(contentsOf: url, configuration: config) else { missing.insert(name); return nil }
        loaded[name] = m
        return m
    }

    /// `image` stretched to width × height (sRGB, BGRA), the way the models were trained.
    static func pixelBuffer(_ image: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        let e = image.extent
        guard e.width >= 1, e.height >= 1, !e.isInfinite else { return nil }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        let sy = CGFloat(height) / e.height, sx = CGFloat(width) / e.width
        let moved = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).clampedToExtent()
        let scaled = abs(sx - 1) < 1e-6 && abs(sy - 1) < 1e-6 ? moved
            : moved.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        DocumentProcessing.context.render(scaled.cropped(to: bounds), to: buffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    static func predict(_ model: MLModel, _ buffer: CVPixelBuffer, output: String) -> MLMultiArray? {
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]) else { return nil }
        predictLock.lock(); defer { predictLock.unlock() }
        return (try? model.prediction(from: input))?.featureValue(for: output)?.multiArrayValue
    }

    /// A [1, C, H, W] output as plain floats, channel by channel, rows from the top.
    struct Planes {
        var c: Int, h: Int, w: Int
        var values: [Float]
        func at(_ k: Int, _ y: Int, _ x: Int) -> Float { values[(k * h + y) * w + x] }
    }
    static func planes(_ a: MLMultiArray) -> Planes? {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        guard shape.count == 4, shape[0] == 1 else { return nil }
        let c = shape[1], h = shape[2], w = shape[3]
        var out = [Float](repeating: 0, count: c * h * w)
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            for k in 0..<c { for y in 0..<h { for x in 0..<w { out[(k * h + y) * w + x] = p[k * strides[1] + y * strides[2] + x * strides[3]] } } }
        case .float16:
            let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
            for k in 0..<c { for y in 0..<h { for x in 0..<w { out[(k * h + y) * w + x] = Float(p[k * strides[1] + y * strides[2] + x * strides[3]]) } } }
        default:
            for k in 0..<c { for y in 0..<h { for x in 0..<w { out[(k * h + y) * w + x] = a[[0, k, y, x] as [NSNumber]].floatValue } } }
        }
        guard out.allSatisfy(\.isFinite) else { return nil }
        return Planes(c: c, h: h, w: w, values: out)
    }
}

/// Curled, folded and crumpled sheets: UVDoc predicts, for a 31 × 45 grid over the flat
/// page, where each point is in the photo. The grid becomes the same mesh the
/// hand-written flattener makes, so the page is resampled from the full photo.
enum NeuralUnwarp {
    /// Room around the crop's bounding box, as a share of its size (the model was
    /// trained on photos with a little background around the sheet).
    nonisolated(unsafe) static var margin = 0.04

    /// - Parameters:
    ///   - photo: the analysis copy of the photo (about 1400 px on the long side).
    ///   - crop: the page corners (normalized, top-left origin, clockwise from top-left).
    static func analyze(_ photo: CGImage, crop: ScanQuad) -> FlattenMesh? {
        guard NeuralModels.use.unwarp, crop.points.count == 4, let model = NeuralModels.model("PageUnwarp") else { return nil }
        let W = Double(photo.width), H = Double(photo.height)
        let xs = crop.points.map { $0.x * W }, ys = crop.points.map { $0.y * H }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let bw = maxX - minX, bh = maxY - minY
        guard bw > 48, bh > 48 else { return nil }
        let x0 = max(0, (minX - bw * margin).rounded(.down)), x1 = min(W, (maxX + bw * margin).rounded(.up))
        let y0 = max(0, (minY - bh * margin).rounded(.down)), y1 = min(H, (maxY + bh * margin).rounded(.up))
        // Core Image works from the bottom left.
        let region = CGRect(x: x0, y: H - y1, width: x1 - x0, height: y1 - y0)
        guard let buffer = NeuralModels.pixelBuffer(CIImage(cgImage: photo).cropped(to: region), width: 488, height: 712),
              let output = NeuralModels.predict(model, buffer, output: "grid"),
              let grid = NeuralModels.planes(output), grid.c == 2, grid.w >= 2, grid.h >= 2 else { return nil }
        let cols = grid.w, rows = grid.h
        // Grid values are -1…1 across the region, pixel centre to pixel centre.
        var nodes = [PaperFlattener.Pt]()
        nodes.reserveCapacity(cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let gx = Double(grid.at(0, r, c)), gy = Double(grid.at(1, r, c))
                nodes.append(PaperFlattener.Pt(x0 + 0.5 + (gx + 1) / 2 * (x1 - x0 - 1), y0 + 0.5 + (gy + 1) / 2 * (y1 - y0 - 1)))
            }
        }
        guard plausible(nodes, cols: cols, rows: rows, crop: xs.indices.map { PaperFlattener.Pt(xs[$0], ys[$0]) }) else { return nil }
        // A flat page is left to the four-corner path (and the hand-written flattener):
        // there the model's small wobble would only cost sharpness and straight lines.
        guard let bend = curvature(nodes, cols: cols, rows: rows), bend >= minimumCurvature else { return nil }
        let corners = crop.points.map { PaperFlattener.Pt($0.x * W, $0.y * H) }
        guard let aspect = PaperFlattener.pageAspect(corners, W: W, H: H) else { return nil }
        var points = [Float]()
        points.reserveCapacity(cols * rows * 2)
        for p in nodes { points.append(Float(p.x / W)); points.append(Float(p.y / H)) }
        return FlattenMesh(cols: cols, rows: rows, points: points, aspect: aspect, maskCols: 1, maskRows: 1, missing: Data([0]), paper: [1, 1, 1])
    }

    /// How far the page is from flat: the RMS distance between the grid and the best
    /// plain perspective mapping of it, as a share of the page's diagonal.
    /// Flat pages measure about 0.0013–0.0035 (steep angles highest), curled ones 0.0045 and up.
    nonisolated(unsafe) static var minimumCurvature = 0.004
    static func curvature(_ nodes: [PaperFlattener.Pt], cols: Int, rows: Int) -> Double? {
        guard nodes.count == cols * rows, cols > 1, rows > 1 else { return nil }
        let xs = nodes.map(\.x), ys = nodes.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        let diag = hypot(x1 - x0, y1 - y0)
        guard diag > 0 else { return nil }
        let cx = xs.reduce(0, +) / Double(xs.count), cy = ys.reduce(0, +) / Double(ys.count)
        // Least squares for x = (h0 u + h1 v + h2) / (h6 u + h7 v + 1), y likewise.
        var a = [Double](repeating: 0, count: 64), b = [Double](repeating: 0, count: 8)
        func add(_ row: [Double], _ rhs: Double) {
            for i in 0..<8 { b[i] += row[i] * rhs; for j in 0..<8 { a[i * 8 + j] += row[i] * row[j] } }
        }
        for r in 0..<rows {
            for c in 0..<cols {
                let u = Double(c) / Double(cols - 1), v = Double(r) / Double(rows - 1)
                let p = nodes[r * cols + c], x = (p.x - cx) / diag, y = (p.y - cy) / diag
                add([u, v, 1, 0, 0, 0, -u * x, -v * x], x)
                add([0, 0, 0, u, v, 1, -u * y, -v * y], y)
            }
        }
        // Gaussian elimination with partial pivoting.
        for k in 0..<8 {
            guard let pivot = (k..<8).max(by: { abs(a[$0 * 8 + k]) < abs(a[$1 * 8 + k]) }), abs(a[pivot * 8 + k]) > 1e-12 else { return nil }
            if pivot != k { for j in 0..<8 { a.swapAt(k * 8 + j, pivot * 8 + j) }; b.swapAt(k, pivot) }
            for i in (k + 1)..<8 {
                let f = a[i * 8 + k] / a[k * 8 + k]
                guard f != 0 else { continue }
                for j in k..<8 { a[i * 8 + j] -= f * a[k * 8 + j] }
                b[i] -= f * b[k]
            }
        }
        var h = [Double](repeating: 0, count: 8)
        for i in stride(from: 7, through: 0, by: -1) {
            var t = b[i]
            for j in (i + 1)..<8 { t -= a[i * 8 + j] * h[j] }
            h[i] = t / a[i * 8 + i]
        }
        var total = 0.0
        for r in 0..<rows {
            for c in 0..<cols {
                let u = Double(c) / Double(cols - 1), v = Double(r) / Double(rows - 1)
                let w = h[6] * u + h[7] * v + 1
                guard abs(w) > 1e-9 else { return nil }
                let p = nodes[r * cols + c]
                let dx = (h[0] * u + h[1] * v + h[2]) / w - (p.x - cx) / diag, dy = (h[3] * u + h[4] * v + h[5]) / w - (p.y - cy) / diag
                total += dx * dx + dy * dy
            }
        }
        let rms = (total / Double(nodes.count)).squareRoot()
        return rms.isFinite ? rms : nil
    }

    /// No folds (every cell the same way round and of real size), and the page it
    /// finds is about the sheet the crop outlines, not a part of it or the desk.
    static func plausible(_ nodes: [PaperFlattener.Pt], cols: Int, rows: Int, crop: [PaperFlattener.Pt]) -> Bool {
        var sign = 0
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let a = nodes[r * cols + c], b = nodes[r * cols + c + 1], d = nodes[(r + 1) * cols + c]
                let cross = (b - a).x * (d - a).y - (b - a).y * (d - a).x
                guard cross.isFinite, abs(cross) > 0.05 else { return false }
                let s = cross > 0 ? 1 : -1
                if sign == 0 { sign = s } else if s != sign { return false }
            }
        }
        func area(_ p: [PaperFlattener.Pt]) -> Double {
            var a = 0.0
            for k in p.indices { let u = p[k], v = p[(k + 1) % p.count]; a += u.x * v.y - v.x * u.y }
            return abs(a) / 2
        }
        var outline = [PaperFlattener.Pt]()
        for c in 0..<cols { outline.append(nodes[c]) }
        for r in 1..<rows { outline.append(nodes[r * cols + cols - 1]) }
        for c in stride(from: cols - 2, through: 0, by: -1) { outline.append(nodes[(rows - 1) * cols + c]) }
        for r in stride(from: rows - 2, through: 1, by: -1) { outline.append(nodes[r * cols]) }
        let found = area(outline), expected = area(crop)
        guard expected > 0 else { return false }
        let ratio = found / expected
        return ratio > 0.7 && ratio < 1.35
    }
}

/// Photo restoration with Real-ESRGAN (general x4v3): noise, blur and JPEG blocks are
/// rebuilt, small photos enlarged. Runs in 256-px tiles with overlap, so any size works.
enum NeuralRestore {
    static let tile = 256, pad = 32
    /// Largest working copy (the model enlarges four times, then it is scaled to `size`).
    nonisolated(unsafe) static var workSide: CGFloat = 1600

    static func modelName(_ level: ImageToolEngine.RestoreLevel) -> String {
        switch level { case .gentle: return "PhotoRestoreGentle"; case .standard: return "PhotoRestore"; case .strong: return "PhotoRestoreStrong" }
    }

    /// `photo` rebuilt at `size` (pixels), or nil when the model isn't available.
    static func restore(_ photo: CGImage, level: ImageToolEngine.RestoreLevel, size: CGSize) throws -> CGImage? {
        guard NeuralModels.use.restore, let model = NeuralModels.model(modelName(level)) else { return nil }
        let FW = Int(size.width.rounded()), FH = Int(size.height.rounded())
        guard FW >= 8, FH >= 8 else { return nil }
        let source = CIImage(cgImage: photo)
        let s = min(1, workSide / CGFloat(max(photo.width, photo.height)))
        let WW = max(8, Int((CGFloat(photo.width) * s).rounded())), WH = max(8, Int((CGFloat(photo.height) * s).rounded()))
        let work = source.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: CGFloat(WH) / CGFloat(photo.height),
                                                                                   kCIInputAspectRatioKey: (CGFloat(WW) / CGFloat(photo.width)) / (CGFloat(WH) / CGFloat(photo.height))])
            .cropped(to: CGRect(x: 0, y: 0, width: WW, height: WH)).clampedToExtent()
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: FW, height: FH, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        canvas.interpolationQuality = .high
        let kx = CGFloat(FW) / CGFloat(WW), ky = CGFloat(FH) / CGFloat(WH)
        let core = tile - 2 * pad
        // Tiles in working-copy pixels, top-left origin.
        var ty = 0
        while ty < WH {
            var tx = 0
            while tx < WW {
                try Task.checkCancellation()
                // The tile's input reaches `pad` beyond its core on every side.
                let ix = tx - pad, iy = ty - pad
                let rect = CGRect(x: ix, y: WH - iy - tile, width: tile, height: tile)
                guard let buffer = NeuralModels.pixelBuffer(work.cropped(to: rect), width: tile, height: tile),
                      let output = NeuralModels.predict(model, buffer, output: "restored"),
                      let rgb = NeuralModels.planes(output), rgb.c == 3, let tileImage = image(rgb, space: sRGB) else { return nil }
                // Draw the tile at the final scale, keeping only its core.
                let cw = min(core, WW - tx), ch = min(core, WH - ty)
                let clip = CGRect(x: (CGFloat(tx) * kx).rounded(.down), y: (CGFloat(FH) - CGFloat(ty + ch) * ky).rounded(.down),
                                  width: (CGFloat(cw) * kx).rounded(.up) + 1, height: (CGFloat(ch) * ky).rounded(.up) + 1)
                let place = CGRect(x: CGFloat(ix) * kx, y: CGFloat(FH) - CGFloat(iy + tile) * ky, width: CGFloat(tile) * kx, height: CGFloat(tile) * ky)
                canvas.saveGState(); canvas.clip(to: clip); canvas.draw(tileImage, in: place); canvas.restoreGState()
                tx += core
            }
            ty += core
        }
        return canvas.makeImage()
    }

    private static func image(_ p: NeuralModels.Planes, space: CGColorSpace) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: p.w * p.h * 4)
        for y in 0..<p.h {
            for x in 0..<p.w {
                let o = (y * p.w + x) * 4
                for k in 0..<3 { bytes[o + k] = UInt8(max(0, min(255, p.at(k, y, x) * 255 + 0.5))) }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: p.w, height: p.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: p.w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
