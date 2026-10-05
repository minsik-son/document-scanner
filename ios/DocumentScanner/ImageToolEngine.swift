import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import Accelerate
import CoreML

/// Image algorithms behind the photo tools. Everything runs on this iPhone.
enum ImageToolEngine {
    static let context = CIContext(options: [.cacheIntermediates: false])

    // MARK: Raster helpers

    struct Raster {
        var bytes: [UInt8]
        let width: Int
        let height: Int
        @inline(__always) func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 4 }
    }
    static func raster(_ image: UIImage, maxSide: Int? = nil) throws -> Raster {
        guard let cg = Imaging.normalized(image).cgImage else { throw ScannerError.message("This image is unavailable.") }
        let longest = max(cg.width, cg.height)
        let scale = min(1, Double(maxSide ?? longest) / Double(longest))
        let w = max(1, Int(Double(cg.width) * scale)), h = max(1, Int(Double(cg.height) * scale))
        guard w * h <= 40_000_000 else { throw ScannerError.message("This image is too large to edit. Choose a smaller photo.") }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard ok else { throw ScannerError.message("Not enough memory to edit this image.") }
        return Raster(bytes: bytes, width: w, height: h)
    }
    static func image(_ r: Raster) throws -> UIImage {
        guard let provider = CGDataProvider(data: Data(r.bytes) as CFData),
              let cg = CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: r.width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ScannerError.message("The edited image couldn't be saved.") }
        return UIImage(cgImage: cg)
    }
    static func output(_ image: CIImage, extent: CGRect? = nil) throws -> UIImage {
        guard let cg = context.createCGImage(image, from: extent ?? image.extent) else { throw ScannerError.message("Image processing failed.") }
        return UIImage(cgImage: cg)
    }

    // MARK: Smart erase

    /// A brush stroke in normalized image coordinates; width is a fraction of the image width.
    struct Stroke: Equatable {
        var points: [CGPoint]
        var width: CGFloat
    }

    /// Fills the painted area from its surroundings. A coarse-to-fine harmonic
    /// fill gives clean paper and smooth backgrounds; fine grain from the edge
    /// keeps the patch from looking flat.
    static func erase(_ input: UIImage, strokes: [Stroke]) throws -> UIImage {
        guard !strokes.isEmpty else { throw ScannerError.message("Paint over what you want to erase.") }
        var r = try raster(input)
        let w = r.width, h = r.height
        // Paint the mask at full resolution.
        var mask = [UInt8](repeating: 0, count: w * h)
        mask.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setStrokeColor(gray: 1, alpha: 1); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            for stroke in strokes where !stroke.points.isEmpty {
                ctx.setLineWidth(max(2, stroke.width * CGFloat(w)) * 1.15)
                ctx.beginPath()
                let first = stroke.points[0]
                ctx.move(to: CGPoint(x: first.x * CGFloat(w), y: first.y * CGFloat(h)))
                if stroke.points.count == 1 { ctx.addLine(to: CGPoint(x: first.x * CGFloat(w) + 0.1, y: first.y * CGFloat(h))) }
                for p in stroke.points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * CGFloat(w), y: p.y * CGFloat(h))) }
                ctx.strokePath()
            }
        }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where mask[y * w + x] > 40 {
            mask[y * w + x] = 255
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { throw ScannerError.message("Paint over what you want to erase.") }
        try Task.checkCancellation()
        // Work on the painted area plus a margin of known pixels.
        let margin = max(12, (maxX - minX + maxY - minY) / 6)
        let x0 = max(0, minX - margin), y0 = max(0, minY - margin), x1 = min(w - 1, maxX + margin), y1 = min(h - 1, maxY + margin)
        let rw = x1 - x0 + 1, rh = y1 - y0 + 1
        var values = [Float](repeating: 0, count: rw * rh * 3)
        var known = [Bool](repeating: true, count: rw * rh)
        for y in 0..<rh { for x in 0..<rw {
            let src = r.index(x + x0, y + y0), dst = (y * rw + x) * 3
            values[dst] = Float(r.bytes[src]); values[dst + 1] = Float(r.bytes[src + 1]); values[dst + 2] = Float(r.bytes[src + 2])
            if mask[(y + y0) * w + x + x0] != 0 { known[y * rw + x] = false }
        } }
        // On paper, ink around the brush must not bleed into the fill: only
        // paper-coloured pixels guide it, so erased text becomes clean paper.
        var guide = known
        var lums: [Float] = []
        lums.reserveCapacity(rw * rh)
        for i in 0..<(rw * rh) where known[i] { lums.append((values[i * 3] + values[i * 3 + 1] + values[i * 3 + 2]) / 3) }
        if lums.count > 16 {
            lums.sort()
            let paper = lums[lums.count * 9 / 10]
            let paperShare = Float(lums.filter { $0 > paper * 0.8 }.count) / Float(lums.count)
            if paper > 120, paperShare > 0.6 {
                for i in 0..<(rw * rh) where known[i] {
                    if (values[i * 3] + values[i * 3 + 1] + values[i * 3 + 2]) / 3 < paper * 0.8 { guide[i] = false }
                }
            }
        }
        let filled = try harmonicFill(values: values, known: guide, width: rw, height: rh)
        // Grain: the standard deviation of guiding pixels along the hole border.
        var sum: Float = 0, sumSq: Float = 0, n: Float = 0
        for y in 0..<rh { for x in 0..<rw where guide[y * rw + x] {
            let nearHole = (max(0, x - 3)...min(rw - 1, x + 3)).contains { !known[y * rw + $0] }
            guard nearHole else { continue }
            let i = (y * rw + x) * 3
            let l = (values[i] + values[i + 1] + values[i + 2]) / 3
            sum += l; sumSq += l * l; n += 1
        } }
        let grain = n > 4 ? min(10, max(0, ((sumSq / n) - (sum / n) * (sum / n)).squareRoot() * 0.6)) : 0
        var seed: UInt32 = 2463534242
        func noise() -> Float { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return Float(seed % 1000) / 1000 - 0.5 }
        // Feather by distance to known pixels so the seam disappears.
        for y in 0..<rh { for x in 0..<rw where !known[y * rw + x] {
            let g = noise() * grain * 2
            let dst = r.index(x + x0, y + y0), i = (y * rw + x) * 3
            for c in 0..<3 { r.bytes[dst + c] = UInt8(max(0, min(255, filled[i + c] + g))) }
        } }
        return try image(r)
    }

    /// Solves Laplace's equation inside unknown pixels on an image pyramid.
    static func harmonicFill(values: [Float], known: [Bool], width: Int, height: Int) throws -> [Float] {
        if width <= 24 || height <= 24 {
            return relax(values: values, known: known, width: width, height: height, start: nil, iterations: 400)
        }
        // Downsample by two: average known pixels only.
        let cw = (width + 1) / 2, ch = (height + 1) / 2
        var coarse = [Float](repeating: 0, count: cw * ch * 3)
        var coarseKnown = [Bool](repeating: false, count: cw * ch)
        for y in 0..<ch { for x in 0..<cw {
            var s: (Float, Float, Float) = (0, 0, 0); var count: Float = 0
            for dy in 0..<2 { for dx in 0..<2 {
                let sx = min(width - 1, x * 2 + dx), sy = min(height - 1, y * 2 + dy)
                guard known[sy * width + sx] else { continue }
                let i = (sy * width + sx) * 3
                s.0 += values[i]; s.1 += values[i + 1]; s.2 += values[i + 2]; count += 1
            } }
            if count > 0 {
                let o = (y * cw + x) * 3
                coarse[o] = s.0 / count; coarse[o + 1] = s.1 / count; coarse[o + 2] = s.2 / count
                coarseKnown[y * cw + x] = true
            }
        } }
        try Task.checkCancellation()
        let solved = try harmonicFill(values: coarse, known: coarseKnown, width: cw, height: ch)
        var start = values
        for y in 0..<height { for x in 0..<width where !known[y * width + x] {
            let o = ((y / 2) * cw + x / 2) * 3, i = (y * width + x) * 3
            start[i] = solved[o]; start[i + 1] = solved[o + 1]; start[i + 2] = solved[o + 2]
        } }
        return relax(values: values, known: known, width: width, height: height, start: start, iterations: 24)
    }
    private static func relax(values: [Float], known: [Bool], width: Int, height: Int, start: [Float]?, iterations: Int) -> [Float] {
        var current = start ?? values
        if start == nil {
            // Seed holes with the mean of known pixels.
            var mean: (Float, Float, Float) = (0, 0, 0); var n: Float = 0
            for i in 0..<(width * height) where known[i] { mean.0 += values[i * 3]; mean.1 += values[i * 3 + 1]; mean.2 += values[i * 3 + 2]; n += 1 }
            if n > 0 { mean = (mean.0 / n, mean.1 / n, mean.2 / n) } else { mean = (245, 245, 245) }
            for i in 0..<(width * height) where !known[i] { current[i * 3] = mean.0; current[i * 3 + 1] = mean.1; current[i * 3 + 2] = mean.2 }
        }
        let holes = (0..<(width * height)).filter { !known[$0] }
        guard !holes.isEmpty else { return current }
        for _ in 0..<iterations {
            for i in holes {
                let x = i % width, y = i / width
                var s: (Float, Float, Float) = (0, 0, 0); var n: Float = 0
                if x > 0 { let j = (i - 1) * 3; s.0 += current[j]; s.1 += current[j + 1]; s.2 += current[j + 2]; n += 1 }
                if x < width - 1 { let j = (i + 1) * 3; s.0 += current[j]; s.1 += current[j + 1]; s.2 += current[j + 2]; n += 1 }
                if y > 0 { let j = (i - width) * 3; s.0 += current[j]; s.1 += current[j + 1]; s.2 += current[j + 2]; n += 1 }
                if y < height - 1 { let j = (i + width) * 3; s.0 += current[j]; s.1 += current[j + 1]; s.2 += current[j + 2]; n += 1 }
                if n > 0 { current[i * 3] = s.0 / n; current[i * 3 + 1] = s.1 / n; current[i * 3 + 2] = s.2 / n }
            }
        }
        return current
    }

    // MARK: Colored marks

    enum MarkColor: String, CaseIterable, Identifiable {
        case highlighter = "Highlighter", red = "Red pen", blue = "Blue pen", green = "Green pen"
        var id: String { rawValue }
        var swatch: UIColor {
            switch self {
            case .highlighter: return UIColor(red: 1, green: 0.85, blue: 0.2, alpha: 1)
            case .red: return UIColor(red: 0.93, green: 0.25, blue: 0.3, alpha: 1)
            case .blue: return UIColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1)
            case .green: return UIColor(red: 0.15, green: 0.7, blue: 0.4, alpha: 1)
            }
        }
        /// Hue ranges in degrees.
        func matches(hue: Double, saturation: Double, value: Double) -> Bool {
            switch self {
            // Highlighters are light, see-through inks of any hue.
            // Text under a yellow or orange highlighter is tinted too.
            case .highlighter: return (value > 0.6 && saturation < 0.9) || (hue >= 35 && hue < 80)
            case .red: return (hue >= 330 || hue < 25)
            case .blue: return hue >= 190 && hue < 265
            case .green: return hue >= 80 && hue < 170
            }
        }
    }

    /// Removes colored ink. Coloured ink and highlighter act like a filter on
    /// the paper: the brightest colour channel still shows what is underneath.
    /// So each coloured pixel is rebuilt as neutral paper-toned grey at the
    /// level of its brightest channel – highlighter over paper becomes paper,
    /// black text under a highlighter stays black. Neutral pixels are never touched.
    static func removeMarks(_ input: UIImage, colors: Set<MarkColor>, strength: Double) throws -> UIImage {
        guard !colors.isEmpty else { throw ScannerError.message("Choose at least one ink color.") }
        guard strength.isFinite, (0...1).contains(strength) else { throw ScannerError.message("Invalid cleanup strength.") }
        var r = try raster(input)
        let paper = paperColor(r)
        let paperHigh = max(1, max(paper.0, paper.1, paper.2))
        let w = r.width, h = r.height
        var touched = [Bool](repeating: false, count: w * h)
        for p in stride(from: 0, to: r.bytes.count, by: 4) {
            if p % 262144 == 0 { try Task.checkCancellation() }
            let red = Double(r.bytes[p]) / 255, green = Double(r.bytes[p + 1]) / 255, blue = Double(r.bytes[p + 2]) / 255
            let high = max(red, green, blue), low = min(red, green, blue)
            let chroma = high - low
            guard chroma > 0.08, high > 0.12 else { continue }
            let saturation = chroma / high
            guard saturation > 0.15 else { continue }
            var hue: Double
            if high == red { hue = 60 * ((green - blue) / chroma).truncatingRemainder(dividingBy: 6) }
            else if high == green { hue = 60 * ((blue - red) / chroma + 2) }
            else { hue = 60 * ((red - green) / chroma + 4) }
            if hue < 0 { hue += 360 }
            guard let match = colors.first(where: { $0.matches(hue: hue, saturation: saturation, value: high) }) else { continue }
            // What shows through the ink, as a fraction of paper brightness.
            // Pen ink is darker than a highlighter, so its level is lifted more.
            let raw = min(1, high * 255 / paperHigh / (match == .highlighter ? 0.92 : 0.72))
            // Keep text crisp: what shows through dark stays dark.
            let level = min(1, max(0, (raw - 0.3) / 0.65))
            if raw > 0.6, match != .highlighter { touched[p / 4] = true }
            let weight = strength * min(1, (saturation - 0.12) * 10)
            r.bytes[p] = UInt8(max(0, min(255, Double(r.bytes[p]) * (1 - weight) + paper.0 * level * weight)))
            r.bytes[p + 1] = UInt8(max(0, min(255, Double(r.bytes[p + 1]) * (1 - weight) + paper.1 * level * weight)))
            r.bytes[p + 2] = UInt8(max(0, min(255, Double(r.bytes[p + 2]) * (1 - weight) + paper.2 * level * weight)))
        }
        // Ink edges blur into grey in photos and JPEGs. Next to removed ink,
        // light grey (not dark text) is lifted to paper too.
        try Task.checkCancellation()
        let paperLum = max(1, (paper.0 + paper.1 + paper.2) / 3)
        // Separable dilation by two pixels.
        var rows = touched
        for y in 0..<h { for x in 0..<w where touched[y * w + x] { for xx in max(0, x - 2)...min(w - 1, x + 2) { rows[y * w + xx] = true } } }
        var near = rows
        for y in 0..<h { for x in 0..<w where rows[y * w + x] { for yy in max(0, y - 2)...min(h - 1, y + 2) { near[yy * w + x] = true } } }
        for y in 0..<h {
            for x in 0..<w where near[y * w + x] && !touched[y * w + x] {
                let p = r.index(x, y)
                let lum = (Double(r.bytes[p]) + Double(r.bytes[p + 1]) + Double(r.bytes[p + 2])) / 3 / paperLum
                guard lum > 0.5 else { continue }
                let level = min(1, 0.5 + (lum - 0.5) / 0.7) * strength + lum * (1 - strength)
                r.bytes[p] = UInt8(min(255, paper.0 * level)); r.bytes[p + 1] = UInt8(min(255, paper.1 * level)); r.bytes[p + 2] = UInt8(min(255, paper.2 * level))
            }
        }
        return try image(r)
    }
    /// The bright, unsaturated colour most of the page has.
    static func paperColor(_ r: Raster) -> (Double, Double, Double) {
        var histogram = [Int](repeating: 0, count: 256)
        let step = max(1, r.width * r.height / 200_000) * 4
        var samples: [(Int, Int, Int)] = []
        for p in stride(from: 0, to: r.bytes.count, by: step) {
            let l = (Int(r.bytes[p]) * 299 + Int(r.bytes[p + 1]) * 587 + Int(r.bytes[p + 2]) * 114) / 1000
            histogram[l] += 1; samples.append((Int(r.bytes[p]), Int(r.bytes[p + 1]), Int(r.bytes[p + 2])))
        }
        var cumulative = 0, cut = 255
        for l in stride(from: 255, through: 0, by: -1) { cumulative += histogram[l]; if cumulative >= samples.count / 4 { cut = l; break } }
        let bright = samples.filter { ($0.0 * 299 + $0.1 * 587 + $0.2 * 114) / 1000 >= cut }
        guard !bright.isEmpty else { return (250, 250, 250) }
        let n = Double(bright.count)
        return (Double(bright.reduce(0) { $0 + $1.0 }) / n, Double(bright.reduce(0) { $0 + $1.1 }) / n, Double(bright.reduce(0) { $0 + $1.2 }) / n)
    }

    // MARK: Photo restoration

    enum RestoreLevel: String, CaseIterable, Identifiable {
        case gentle = "Gentle", standard = "Standard", strong = "Strong"
        var id: String { rawValue }
        var amount: Double { self == .gentle ? 0.4 : (self == .standard ? 0.7 : 1) }
    }

    /// Removes dust and small scratches, brings back faded colour and contrast,
    /// reduces noise and sharpens. Small photos are enlarged two times.
    static func restore(_ input: UIImage, level: RestoreLevel, fixColor: Bool) throws -> UIImage {
        guard let cg = Imaging.normalized(input).cgImage else { throw ScannerError.message("This photo is unavailable.") }
        let extent = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let amount = level.amount
        // 1. Dust and scratches: specks and thin lines smaller than a small
        // window are found by closing + opening and replaced; real detail stays.
        var r = try raster(UIImage(cgImage: cg))
        let radius = max(2, Int(Double(max(cg.width, cg.height)) * 0.003 * (0.7 + 0.6 * amount)))
        try despeckle(&r, radius: radius, threshold: Int(34 - 12 * amount))
        guard let clean = try image(r).cgImage else { throw ScannerError.message("This photo is unavailable.") }
        var image = CIImage(cgImage: clean)
        try Task.checkCancellation()
        // 2. Noise and film grain.
        image = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.015 + 0.025 * amount, "inputSharpness": 0.4])
            .cropped(to: extent)
        // 3. Faded colour and contrast: per-channel levels in display space.
        image = try levels(image, perChannel: fixColor, amount: amount)
        image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": 0.2 * amount, "inputHighlightAmount": 1 - 0.1 * amount])
        if fixColor { image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.25 * amount]) }
        image = image.cropped(to: extent)
        // 4. Small photos are enlarged two times, then sharpened.
        var outputExtent = extent
        if max(cg.width, cg.height) < 1400 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 2.0, kCIInputAspectRatioKey: 1.0])
            outputExtent = CGRect(x: 0, y: 0, width: cg.width * 2, height: cg.height * 2)
        }
        image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.25 + 0.35 * amount, kCIInputRadiusKey: 1.5])
        try Task.checkCancellation()
        return try output(image.cropped(to: outputExtent), extent: outputExtent)
    }
    /// Removes small light and dark specks with vImage morphology.
    static func despeckle(_ r: inout Raster, radius: Int, threshold: Int) throws {
        let w = r.width, h = r.height, k = vImagePixelCount(radius * 2 + 1)
        var a = r.bytes, b = [UInt8](repeating: 0, count: r.bytes.count)
        func pass(_ input: inout [UInt8], _ output: inout [UInt8], max: Bool) throws {
            let status = input.withUnsafeMutableBytes { i in output.withUnsafeMutableBytes { o -> vImage_Error in
                var src = vImage_Buffer(data: i.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var dst = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                return max ? vImageMax_ARGB8888(&src, &dst, nil, 0, 0, k, k, vImage_Flags(kvImageEdgeExtend))
                           : vImageMin_ARGB8888(&src, &dst, nil, 0, 0, k, k, vImage_Flags(kvImageEdgeExtend))
            } }
            guard status == kvImageNoError else { throw ScannerError.message("Image processing failed.") }
        }
        // Closing removes dark specks, opening removes light ones.
        try pass(&a, &b, max: true); try pass(&b, &a, max: false)
        try pass(&a, &b, max: false); try pass(&b, &a, max: true)
        try Task.checkCancellation()
        // Replace only pixels that clearly changed, plus a one-pixel rim.
        var changed = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let p = i * 4
            let d = abs(Int(r.bytes[p]) - Int(a[p])) + abs(Int(r.bytes[p + 1]) - Int(a[p + 1])) + abs(Int(r.bytes[p + 2]) - Int(a[p + 2]))
            changed[i] = d > threshold * 3
        }
        for y in 0..<h { for x in 0..<w {
            var hit = false
            for yy in max(0, y - 1)...min(h - 1, y + 1) where !hit { for xx in max(0, x - 1)...min(w - 1, x + 1) where changed[yy * w + xx] { hit = true; break } }
            guard hit else { continue }
            let p = (y * w + x) * 4
            r.bytes[p] = a[p]; r.bytes[p + 1] = a[p + 1]; r.bytes[p + 2] = a[p + 2]
        } }
    }
    private static func levels(_ image: CIImage, perChannel: Bool, amount: Double) throws -> CIImage {
        let extent = image.extent
        let sample = image.transformed(by: CGAffineTransform(scaleX: min(1, 400 / max(extent.width, 1)), y: min(1, 400 / max(extent.height, 1))))
        guard let cg = context.createCGImage(sample, from: sample.extent) else { return image }
        let r = try raster(UIImage(cgImage: cg))
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        for p in stride(from: 0, to: r.bytes.count, by: 4) { for c in 0..<3 { hist[c][Int(r.bytes[p + c])] += 1 } }
        let total = r.width * r.height
        func percentile(_ h: [Int], _ q: Double) -> Double {
            var cumulative = 0
            for (i, v) in h.enumerated() { cumulative += v; if Double(cumulative) >= Double(total) * q { return Double(i) / 255 } }
            return 1
        }
        var lows = (0..<3).map { percentile(hist[$0], 0.01) }
        var highs = (0..<3).map { percentile(hist[$0], 0.99) }
        if !perChannel { let lo = lows.min() ?? 0, hi = highs.max() ?? 1; lows = [lo, lo, lo]; highs = [hi, hi, hi] }
        var vectors: [CIVector] = []
        var bias: [Double] = []
        for c in 0..<3 {
            let span = max(0.35, highs[c] - lows[c])
            let gain = 1 + (1 / span - 1) * amount
            let offset = -lows[c] * gain * amount
            vectors.append(CIVector(x: c == 0 ? gain : 0, y: c == 1 ? gain : 0, z: c == 2 ? gain : 0, w: 0))
            bias.append(offset)
        }
        // The percentiles were measured on display (sRGB) values, so stretch there.
        return image.applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": vectors[0], "inputGVector": vectors[1], "inputBVector": vectors[2],
                "inputBiasVector": CIVector(x: bias[0], y: bias[1], z: bias[2], w: 0)])
            .applyingFilter("CIColorClamp")
            .applyingFilter("CISRGBToneCurveToLinear")
    }

    // MARK: Object counting

    enum Polarity: String, CaseIterable, Identifiable {
        case auto = "Auto", dark = "Dark objects", light = "Light objects"
        var id: String { rawValue }
    }
    struct CountResult: Equatable {
        var points: [CGPoint]
        var radius: CGFloat
    }

    /// Finds separate objects against a contrasting background. Clumps of
    /// touching objects are split by comparing their area with a typical object.
    static func count(_ input: UIImage, polarity: Polarity, sensitivity: Double) throws -> CountResult {
        let r = try raster(input, maxSide: 900)
        let w = r.width, h = r.height, n = w * h
        var gray = [UInt8](repeating: 0, count: n)
        for i in 0..<n { let p = i * 4; gray[i] = UInt8((Int(r.bytes[p]) * 299 + Int(r.bytes[p + 1]) * 587 + Int(r.bytes[p + 2]) * 114) / 1000) }
        // Light blur for noise.
        var smooth = gray
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            var s = 0
            for dy in -1...1 { for dx in -1...1 { s += Int(gray[(y + dy) * w + x + dx]) } }
            smooth[y * w + x] = UInt8(s / 9)
        } }
        try Task.checkCancellation()
        // Otsu threshold.
        var hist = [Int](repeating: 0, count: 256)
        for v in smooth { hist[Int(v)] += 1 }
        var sumAll = 0.0; for i in 0..<256 { sumAll += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0, best = 0.0, threshold = 128
        for t in 0..<256 {
            wB += hist[t]; guard wB > 0 else { continue }
            let wF = n - wB; if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / Double(wB), mF = (sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t }
        }
        let shift = Int((sensitivity - 0.5) * 60)
        let below = (0..<threshold).reduce(0) { $0 + hist[$1] }
        let dark: Bool
        switch polarity {
        case .dark: dark = true
        case .light: dark = false
        case .auto: dark = below < n / 2
        }
        let cut = dark ? threshold + shift : threshold - shift
        var on = [Bool](repeating: false, count: n)
        for i in 0..<n { on[i] = dark ? Int(smooth[i]) < cut : Int(smooth[i]) > cut }
        // Opening: erode then dilate to cut thin bridges between objects.
        on = morph(on, w, h, erode: true); on = morph(on, w, h, erode: false)
        try Task.checkCancellation()
        // Connected components.
        var label = [Int32](repeating: -1, count: n)
        var components: [[Int]] = []
        for start in 0..<n where on[start] && label[start] < 0 {
            var queue = [start]; label[start] = Int32(components.count); var head = 0
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let j = ny * w + nx
                    if on[j] && label[j] < 0 { label[j] = Int32(components.count); queue.append(j) }
                }
            }
            components.append(queue)
            if components.count > 4000 { break }
        }
        let minimum = max(6, n / 40000)
        // Keep solid, object-sized regions: no frames, shadows along the edges or thin lines.
        var blobs = components.filter { blob in
            guard blob.count >= minimum, blob.count < n / 4 else { return false }
            var x0 = w, x1 = 0, y0 = h, y1 = 0
            for i in blob { let x = i % w, y = i / w; x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
            let bw = x1 - x0 + 1, bh = y1 - y0 + 1
            guard bw < w * 6 / 10, bh < h * 6 / 10 else { return false }
            return Double(blob.count) / Double(bw * bh) > 0.3
        }
        guard !blobs.isEmpty else { return CountResult(points: [], radius: 0.02) }
        // Drop specks far smaller than a typical object.
        let sizes = blobs.map(\.count).sorted()
        let typical = Double(sizes[sizes.count / 2])
        blobs = blobs.filter { Double($0.count) >= typical * 0.18 }
        let areas = blobs.map(\.count).sorted()
        let median = Double(areas[areas.count / 2])
        // Touching objects form one blob. Split it at the peaks of the distance
        // to the background: each round object has one peak at its centre.
        let typicalRadius = (median / Double.pi).squareRoot()
        var inBlob = [Bool](repeating: false, count: n)
        for blob in blobs { for i in blob { inBlob[i] = true } }
        let distance = distanceTransform(inBlob, w, h)
        var points: [CGPoint] = []
        for blob in blobs {
            if Double(blob.count) <= median * 1.5 {
                let cx = blob.reduce(0.0) { $0 + Double($1 % w) } / Double(blob.count)
                let cy = blob.reduce(0.0) { $0 + Double($1 / w) } / Double(blob.count)
                points.append(CGPoint(x: cx / Double(w), y: cy / Double(h)))
            } else {
                let candidates = blob.filter { Double(distance[$0]) >= typicalRadius * 0.45 }.sorted { distance[$0] > distance[$1] }
                var peaks: [(Double, Double)] = []
                let spacing = typicalRadius * 0.95
                for i in candidates {
                    let p = (Double(i % w), Double(i / w))
                    if peaks.allSatisfy({ hypot($0.0 - p.0, $0.1 - p.1) > spacing }) { peaks.append(p) }
                    if peaks.count >= 40 { break }
                }
                if peaks.isEmpty { peaks = kMeans(blob.map { (Double($0 % w), Double($0 / w)) }, k: 1) }
                for c in peaks { points.append(CGPoint(x: c.0 / Double(w), y: c.1 / Double(h))) }
            }
            if points.count >= 999 { break }
        }
        let radius = CGFloat((median / Double.pi).squareRoot() / Double(w))
        // Number in reading order: rows of about one object height, then left to right.
        let row = max(0.01, radius * 2 * CGFloat(w) / CGFloat(h))
        points.sort { a, b in
            let ra = Int(a.y / row), rb = Int(b.y / row)
            return ra != rb ? ra < rb : a.x < b.x
        }
        return CountResult(points: points, radius: max(0.012, min(0.08, radius)))
    }
    /// Chamfer distance from each "on" pixel to the nearest "off" pixel.
    static func distanceTransform(_ on: [Bool], _ w: Int, _ h: Int) -> [Float] {
        let big: Float = 1e6, d1: Float = 1, d2: Float = 1.4142
        var d = on.map { $0 ? big : 0 }
        for y in 0..<h { for x in 0..<w where d[y * w + x] > 0 {
            var v = d[y * w + x]
            if x > 0 { v = min(v, d[y * w + x - 1] + d1) } else { v = min(v, d1) }
            if y > 0 {
                v = min(v, d[(y - 1) * w + x] + d1)
                if x > 0 { v = min(v, d[(y - 1) * w + x - 1] + d2) }
                if x < w - 1 { v = min(v, d[(y - 1) * w + x + 1] + d2) }
            } else { v = min(v, d1) }
            d[y * w + x] = v
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) where d[y * w + x] > 0 {
            var v = d[y * w + x]
            if x < w - 1 { v = min(v, d[y * w + x + 1] + d1) } else { v = min(v, d1) }
            if y < h - 1 {
                v = min(v, d[(y + 1) * w + x] + d1)
                if x < w - 1 { v = min(v, d[(y + 1) * w + x + 1] + d2) }
                if x > 0 { v = min(v, d[(y + 1) * w + x - 1] + d2) }
            } else { v = min(v, d1) }
            d[y * w + x] = v
        } }
        return d
    }
    private static func morph(_ on: [Bool], _ w: Int, _ h: Int, erode: Bool) -> [Bool] {
        var out = on
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            let neighbors = [x > 0 ? on[i - 1] : !erode, x < w - 1 ? on[i + 1] : !erode, y > 0 ? on[i - w] : !erode, y < h - 1 ? on[i + w] : !erode]
            out[i] = erode ? on[i] && neighbors.allSatisfy { $0 } : on[i] || neighbors.contains(true)
        } }
        return out
    }
    private static func kMeans(_ points: [(Double, Double)], k: Int) -> [(Double, Double)] {
        guard k > 1, points.count > k else {
            let n = Double(max(1, points.count))
            return [(points.reduce(0) { $0 + $1.0 } / n, points.reduce(0) { $0 + $1.1 } / n)]
        }
        let step = max(1, points.count / k)
        var centers = (0..<k).map { points[min(points.count - 1, $0 * step + step / 2)] }
        let sample = points.count > 4000 ? stride(from: 0, to: points.count, by: points.count / 4000).map { points[$0] } : points
        for _ in 0..<12 {
            var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: k)
            for p in sample {
                var best = 0, distance = Double.infinity
                for (j, c) in centers.enumerated() { let d = (p.0 - c.0) * (p.0 - c.0) + (p.1 - c.1) * (p.1 - c.1); if d < distance { distance = d; best = j } }
                sums[best].0 += p.0; sums[best].1 += p.1; sums[best].2 += 1
            }
            centers = centers.enumerated().map { j, c in sums[j].2 > 0 ? (sums[j].0 / sums[j].2, sums[j].1 / sums[j].2) : c }
        }
        return centers
    }
    /// The photo with numbered markers, for saving and sharing.
    static func annotated(_ input: UIImage, points: [CGPoint], radius: CGFloat) -> UIImage {
        let base = Imaging.normalized(input)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: base.size, format: format).image { ctx in
            base.draw(at: .zero)
            let r = max(14, radius * base.size.width * 0.75)
            let font = UIFont.systemFont(ofSize: r * 0.9, weight: .heavy)
            for (i, p) in points.enumerated() {
                let center = CGPoint(x: p.x * base.size.width, y: p.y * base.size.height)
                let circle = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                UIColor(red: 0.09, green: 0.73, blue: 0.6, alpha: 0.92).setFill(); ctx.cgContext.fillEllipse(in: circle)
                UIColor.white.setStroke(); ctx.cgContext.setLineWidth(max(2, r * 0.12)); ctx.cgContext.strokeEllipse(in: circle)
                let text = "\(i + 1)" as NSString
                let size = text.size(withAttributes: [.font: font])
                text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: [.font: font, .foregroundColor: UIColor.white])
            }
            let label = "Total: \(points.count)" as NSString
            let font2 = UIFont.systemFont(ofSize: max(28, base.size.width / 24), weight: .bold)
            let size = label.size(withAttributes: [.font: font2])
            let box = CGRect(x: 24, y: 24, width: size.width + 32, height: size.height + 16)
            UIColor.black.withAlphaComponent(0.6).setFill(); UIBezierPath(roundedRect: box, cornerRadius: box.height / 2).fill()
            label.draw(at: CGPoint(x: box.minX + 16, y: box.minY + 8), withAttributes: [.font: font2, .foregroundColor: UIColor.white])
        }
    }

    // MARK: ID photo

    /// A file for an online application: exact pixels and a size limit.
    struct DigitalSpec: Identifiable, Equatable, Hashable {
        let id: String
        let title: String
        let width: Int
        let height: Int
        let maxKB: Int
        var minKB: Int = 0
    }
    struct PhotoSize: Identifiable, Equatable, Hashable {
        let id: String
        let title: String
        let detail: String
        let region: String
        let width: Double   // millimetres
        let height: Double
        /// Allowed head height, chin to crown (top of the hair), in millimetres.
        let headMin: Double
        let headMax: Double
        /// Space between the top of the head and the top edge, in millimetres.
        let crownGap: Double
        /// Clothing can be swapped only where edited photos are accepted.
        var allowsOutfit = false
        var digital: [DigitalSpec] = []
        var headTarget: Double { (headMin + headMax) / 2 }
        static let regions = ["Korea", "United States", "Canada", "Japan", "Europe & UK", "China", "India", "Résumé & cards"]
        /// The section for a country (ISO region code), nil when none fits.
        static func region(for code: String?) -> String? {
            guard let code = code?.uppercased() else { return nil }
            switch code {
            case "KR": return "Korea"
            case "US": return "United States"
            case "CA": return "Canada"
            case "JP": return "Japan"
            case "CN": return "China"
            case "IN": return "India"
            case "GB", "AU", "TW", "CH", "NO", "IS", "LI", "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE",
                 "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE": return "Europe & UK"
            default: return nil
            }
        }
        /// Sections with the user's own country first.
        static func regions(for code: String?) -> [String] {
            guard let home = region(for: code) else { return regions }
            return [home] + regions.filter { $0 != home }
        }
        /// The first size of the user's country, or the Korean passport.
        static func preferred(for code: String?) -> PhotoSize {
            all.first { $0.region == regions(for: code)[0] } ?? all[0]
        }
        /// Where the user lives. The iPhone's region setting is often the
        /// home country of an expat (Korea for a Korean in Canada), so the App
        /// Store country and the time zone come first.
        static func homeCode(storefront: String? = nil, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
            if let code = storefront.flatMap(alpha2), region(for: code) != nil { return code }
            if let code = country(of: timeZone) { return code }
            return locale.region?.identifier
        }
        static var homeCode: String? { homeCode() }
        /// App Store country codes are three letters (CAN, KOR…).
        static func alpha2(_ code: String) -> String? {
            let map = ["KOR": "KR", "USA": "US", "CAN": "CA", "JPN": "JP", "CHN": "CN", "IND": "IN", "GBR": "GB", "AUS": "AU", "TWN": "TW",
                       "DEU": "DE", "FRA": "FR", "ITA": "IT", "ESP": "ES", "NLD": "NL", "BEL": "BE", "AUT": "AT", "CHE": "CH", "SWE": "SE",
                       "NOR": "NO", "DNK": "DK", "FIN": "FI", "IRL": "IE", "PRT": "PT", "POL": "PL", "CZE": "CZ", "GRC": "GR", "HUN": "HU"]
            let upper = code.uppercased()
            return upper.count == 2 ? upper : map[upper]
        }
        /// The country of a time zone, for the countries with their own sizes.
        static func country(of zone: TimeZone) -> String? {
            let id = zone.identifier
            let exact: [String: String] = ["Asia/Seoul": "KR", "Asia/Tokyo": "JP", "Asia/Shanghai": "CN", "Asia/Hong_Kong": "CN", "Asia/Kolkata": "IN",
                                           "Asia/Calcutta": "IN", "Asia/Taipei": "TW", "Europe/London": "GB", "Europe/Dublin": "IE"]
            if let code = exact[id] { return code }
            let canada = ["Vancouver", "Edmonton", "Calgary", "Winnipeg", "Regina", "Toronto", "Montreal", "Halifax", "St_Johns", "Moncton",
                          "Whitehorse", "Yellowknife", "Iqaluit", "Glace_Bay", "Goose_Bay", "Dawson_Creek", "Fort_Nelson", "Creston", "Swift_Current",
                          "Cambridge_Bay", "Inuvik", "Rankin_Inlet", "Resolute", "Atikokan", "Blanc-Sablon", "Dawson"]
            if id.hasPrefix("America/"), canada.contains(String(id.dropFirst(8))) { return "CA" }
            if id.hasPrefix("Canada/") { return "CA" }
            let us = ["New_York", "Chicago", "Denver", "Los_Angeles", "Phoenix", "Anchorage", "Detroit", "Boise", "Juneau", "Adak", "Nome",
                      "Indiana/Indianapolis", "Kentucky/Louisville", "Sitka", "Menominee", "Metlakatla", "Yakutat"]
            if id.hasPrefix("America/"), us.contains(String(id.dropFirst(8))) { return "US" }
            if id.hasPrefix("US/") || id == "Pacific/Honolulu" { return "US" }
            if id.hasPrefix("Australia/") { return "AU" }
            if id.hasPrefix("Europe/") { return "DE" }   // any EU-style biometric country
            return nil
        }
        /// Flag shown next to a section (Apple's flag emoji), nil for non-country sections.
        static func flag(_ region: String) -> String? {
            switch region {
            case "Korea": return "🇰🇷"
            case "United States": return "🇺🇸"
            case "Canada": return "🇨🇦"
            case "Japan": return "🇯🇵"
            case "Europe & UK": return "🇪🇺"
            case "China": return "🇨🇳"
            case "India": return "🇮🇳"
            default: return nil
            }
        }
        static let all: [PhotoSize] = [
            PhotoSize(id: "35x45", title: "Passport · 35 × 45 mm", detail: "Korean passport and visa", region: "Korea", width: 35, height: 45, headMin: 32, headMax: 36, crownGap: 4,
                      digital: [DigitalSpec(id: "kr-online", title: "Online passport application · 413 × 531 px, up to 500 KB", width: 413, height: 531, maxKB: 500)]),
            PhotoSize(id: "kr-id", title: "ID card & driver's licence · 35 × 45 mm", detail: "Resident registration card and driver's licence", region: "Korea", width: 35, height: 45, headMin: 32, headMax: 36, crownGap: 4),
            PhotoSize(id: "2x2", title: "US passport · 2 × 2 in", detail: "United States passport and visa", region: "United States", width: 50.8, height: 50.8, headMin: 25.4, headMax: 34.9, crownGap: 7,
                      digital: [DigitalSpec(id: "us-renewal", title: "Online passport renewal · 1200 × 1200 px", width: 1200, height: 1200, maxKB: 10_240, minKB: 54),
                                DigitalSpec(id: "us-dv", title: "Diversity visa (DV) · 600 × 600 px, up to 240 KB", width: 600, height: 600, maxKB: 240)]),
            PhotoSize(id: "50x70", title: "Canada passport · 50 × 70 mm", detail: "Canadian passport photo", region: "Canada", width: 50, height: 70, headMin: 31, headMax: 36, crownGap: 12),
            PhotoSize(id: "jp-35x45", title: "Japan passport · 35 × 45 mm", detail: "Japanese passport", region: "Japan", width: 35, height: 45, headMin: 32, headMax: 36, crownGap: 4),
            PhotoSize(id: "eu-35x45", title: "Biometric · 35 × 45 mm", detail: "Schengen visa, UK, Germany, France, Australia, Taiwan", region: "Europe & UK", width: 35, height: 45, headMin: 32, headMax: 36, crownGap: 4,
                      digital: [DigitalSpec(id: "uk-online", title: "UK online passport · 600 × 771 px", width: 600, height: 771, maxKB: 10_240, minKB: 50)]),
            PhotoSize(id: "33x48", title: "China visa · 33 × 48 mm", detail: "Chinese visa applications", region: "China", width: 33, height: 48, headMin: 28, headMax: 33, crownGap: 4,
                      digital: [DigitalSpec(id: "cn-visa", title: "Online visa form · 354 × 472 px, 40–120 KB", width: 354, height: 472, maxKB: 120, minKB: 40)]),
            PhotoSize(id: "in-2x2", title: "India passport & visa · 51 × 51 mm", detail: "Indian passport and visa", region: "India", width: 51, height: 51, headMin: 25, headMax: 35, crownGap: 6,
                      digital: [DigitalSpec(id: "in-evisa", title: "e-Visa upload · 600 × 600 px, up to 1 MB", width: 600, height: 600, maxKB: 1024, minKB: 10)]),
            PhotoSize(id: "30x40", title: "Résumé · 3 × 4 cm", detail: "Résumés, applications and certificates", region: "Résumé & cards", width: 30, height: 40, headMin: 24, headMax: 28, crownGap: 4, allowsOutfit: true,
                      digital: [DigitalSpec(id: "resume-upload", title: "Job site upload · 300 × 400 px, up to 300 KB", width: 300, height: 400, maxKB: 300)]),
            PhotoSize(id: "25x30", title: "Small ID · 25 × 30 mm", detail: "Membership cards and student IDs", region: "Résumé & cards", width: 25, height: 30, headMin: 18, headMax: 22, crownGap: 3, allowsOutfit: true)
        ]
    }
    /// Paper for a print sheet; sizes are landscape, in millimetres.
    enum PrintPaper: String, CaseIterable, Identifiable {
        case fourBySix = "4 × 6 in", threeHalfByFive = "3.5 × 5 in", fiveBySeven = "5 × 7 in", a4 = "A4"
        var id: String { rawValue }
        var millimeters: CGSize {
            switch self {
            case .fourBySix: return CGSize(width: 152.4, height: 101.6)
            case .threeHalfByFive: return CGSize(width: 127, height: 88.9)
            case .fiveBySeven: return CGSize(width: 177.8, height: 127)
            case .a4: return CGSize(width: 297, height: 210)
            }
        }
    }
    /// Clothing laid over the body for résumé photos. Each asset is a 1024²
    /// transparent picture with the neck at (512, 230) and shoulders 884 px wide.
    enum Outfit: String, CaseIterable, Identifiable {
        case none, menNavyTie = "outfit-men-navy-tie", menCharcoalOpen = "outfit-men-charcoal-open", menBlackTie = "outfit-men-black-tie"
        case womenBlackBlazer = "outfit-women-black-blazer", womenNavyBlazer = "outfit-women-navy-blazer", whiteShirt = "outfit-white-shirt"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "My clothes"
            case .menNavyTie: return "Navy suit"
            case .menCharcoalOpen: return "Grey suit, no tie"
            case .menBlackTie: return "Black suit"
            case .womenBlackBlazer: return "Black blazer"
            case .womenNavyBlazer: return "Navy blazer"
            case .whiteShirt: return "White shirt"
            }
        }
        var image: CIImage? {
            guard self != .none, let cg = UIImage(named: rawValue)?.cgImage else { return nil }
            return CIImage(cgImage: cg)
        }
        /// White where the neck opening is: filled with the person's skin so
        /// their own clothes never show through the collar.
        var neckMask: CIImage? {
            guard self != .none, let cg = UIImage(named: rawValue + "-neck")?.cgImage else { return nil }
            return CIImage(cgImage: cg)
        }
        static let neck = CGPoint(x: 512, y: 230), shoulders: CGFloat = 884, canvas: CGFloat = 1024
    }
    /// The user's fine-tuning on top of the automatic fit: zoom scales the
    /// head; offsets move it in millimetres of the finished photo (up, right).
    struct PortraitAdjust: Equatable {
        var zoom: Double = 1
        var dx: Double = 0
        var dy: Double = 0
    }
    /// Where the head and shoulders land in the finished photo, in
    /// millimetres from the top edge.
    struct PortraitMetrics: Equatable {
        var head: Double
        var crown: Double
        var chin: Double
        var shoulder: Double?
        var centerOffset: Double   // head centre from the photo's centre line
    }
    enum Backdrop: String, CaseIterable, Identifiable {
        case white = "White", lightGrey = "Light grey", sky = "Light blue", blue = "Blue", red = "Red"
        var id: String { rawValue }
        var color: UIColor {
            switch self {
            case .white: return .white
            case .lightGrey: return UIColor(red: 0.92, green: 0.93, blue: 0.94, alpha: 1)
            case .sky: return UIColor(red: 0.79, green: 0.88, blue: 0.98, alpha: 1)
            case .blue: return UIColor(red: 0.26, green: 0.55, blue: 0.93, alpha: 1)
            case .red: return UIColor(red: 0.86, green: 0.2, blue: 0.22, alpha: 1)
            }
        }
    }
    /// Subject cut-out computed once; recolouring and cropping are then instant.
    struct PortraitSubject {
        let image: CIImage
        let mask: CIImage
        let face: CGRect   // Core Image coordinates
        /// Top of the hair, bottom of the chin and the shoulder line (y, Core
        /// Image coordinates), and the head's centre line (x).
        var crown: CGFloat = 0
        var chin: CGFloat = 0
        var shoulder: CGFloat? = nil
        var centerX: CGFloat = 0
        /// Widest part of the shoulders, in pixels.
        var shoulderWidth: CGFloat? = nil
        var quality = PortraitQuality()
    }
    /// Raw measurements behind the photo checks; nil when not measurable.
    struct PortraitQuality: Equatable {
        var roll: Double?          // degrees, head tilt
        var yaw: Double?           // degrees, head turn
        var eyeOpenness: Double?   // eye height ÷ width, the more closed eye
        var mouthOpen: Double?     // inner lip gap ÷ mouth width
        var lightBalance: Double?  // left/right brightness difference ÷ mean
        var brightness: Double?    // mean face brightness, 0...1
        var glare: Double?         // share of blown-out pixels around the eyes
    }
    struct PortraitCheck: Identifiable, Equatable {
        let id: String
        let title: String
        let passed: Bool
        let detail: String
    }
    /// Last resort when Vision can't cut the person out (older devices, the
    /// simulator): flood the plain wall in from the top and side edges.
    static func plainBackgroundMask(_ cg: CGImage, extent: CGRect, face: CGRect) -> CIImage? {
        guard let r = try? raster(UIImage(cgImage: cg), maxSide: 320) else { return nil }
        let w = r.width, h = r.height
        // Below the chin the neck is always the person; elsewhere below the
        // chin the wall must match more closely (clothes are often wall-coloured).
        let sx = CGFloat(w) / extent.width, sy = CGFloat(h) / extent.height
        let bandLo = Int((face.midX - face.width * 0.45 - extent.minX) * sx), bandHi = Int((face.midX + face.width * 0.45 - extent.minX) * sx)
        let chinRow = Int((extent.maxY - face.minY) * sy)
        func body(_ x: Int, _ y: Int) -> Bool { y > chinRow && x >= bandLo && x <= bandHi }
        var edge: [(Double, Double, Double)] = []
        for x in stride(from: 0, to: w, by: 2) { let p = r.index(x, 1); edge.append((Double(r.bytes[p]), Double(r.bytes[p + 1]), Double(r.bytes[p + 2]))) }
        for y in stride(from: 0, to: h * 2 / 3, by: 2) {
            for x in [1, w - 2] { let p = r.index(x, y); edge.append((Double(r.bytes[p]), Double(r.bytes[p + 1]), Double(r.bytes[p + 2]))) }
        }
        guard !edge.isEmpty else { return nil }
        var wall = [UInt8](repeating: 0, count: w * h)   // 1 = background
        var queue: [Int] = []
        func similar(_ i: Int, _ ref: Int) -> Bool {
            let low = i / w > chinRow
            let p = i * 4, q = ref * 4
            let d = abs(Int(r.bytes[p]) - Int(r.bytes[q])) + abs(Int(r.bytes[p + 1]) - Int(r.bytes[q + 1])) + abs(Int(r.bytes[p + 2]) - Int(r.bytes[q + 2]))
            return d < (low ? 20 : 24)
        }
        let mean = edge.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
        let m = (mean.0 / Double(edge.count), mean.1 / Double(edge.count), mean.2 / Double(edge.count))
        // The clothes colour at the bottom centre; below the chin a pixel is wall
        // only when it is nearer the wall than the clothes.
        let cp = r.index(min(w - 1, max(0, (bandLo + bandHi) / 2)), max(0, h - 4))
        let cloth = (Double(r.bytes[cp]), Double(r.bytes[cp + 1]), Double(r.bytes[cp + 2]))
        func nearWall(_ i: Int) -> Bool {
            let p = i * 4
            let px = (Double(r.bytes[p]), Double(r.bytes[p + 1]), Double(r.bytes[p + 2]))
            let toWall = abs(px.0 - m.0) + abs(px.1 - m.1) + abs(px.2 - m.2)
            guard i / w > chinRow else { return toWall < 200 }
            return toWall < 200 && toWall < abs(px.0 - cloth.0) + abs(px.1 - cloth.1) + abs(px.2 - cloth.2)
        }
        for x in 0..<w { queue.append(x) }
        for y in 0..<h { if !body(0, y) { queue.append(y * w) }; if !body(w - 1, y) { queue.append(y * w + w - 1) } }
        for i in queue { wall[i] = 1 }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let j = ny * w + nx
                if wall[j] == 0 && !body(nx, ny) && similar(j, i) && nearWall(j) { wall[j] = 1; queue.append(j) }
            }
        }
        let person = wall.filter { $0 == 0 }.count
        guard person > w * h / 10, person < w * h * 9 / 10 else { return nil }
        let pixels = wall.map { $0 == 1 ? UInt8(0) : UInt8(255) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let maskCG = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let small = CIImage(cgImage: maskCG)
        return small.transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h)))
            .clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: extent.width / CGFloat(w) * 0.6]).cropped(to: extent)
    }
    /// The simulator has no Neural Engine: run Vision on the CPU there.
    static func simulatorSafe<R: VNRequest>(_ request: R) -> R {
        #if targetEnvironment(simulator)
        if let stages = try? request.supportedComputeStageDevices {
            for (stage, devices) in stages {
                if let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) { request.setComputeDevice(cpu, for: stage) }
            }
        }
        #endif
        return request
    }
    static func portraitSubject(_ input: UIImage) throws -> PortraitSubject {
        guard let cg = Imaging.limited(Imaging.normalized(input), maxPixels: 16_000_000).cgImage else { throw ScannerError.message("This photo is unavailable.") }
        let handler = VNImageRequestHandler(cgImage: cg)
        let faces = simulatorSafe(VNDetectFaceRectanglesRequest())
        do { try handler.perform([faces]) }
        catch { throw ScannerError.message("This photo couldn't be analysed on this device. Try another photo.") }
        try Task.checkCancellation()
        guard let observations = faces.results, !observations.isEmpty else { throw ScannerError.message("No face found. Use a photo that faces the camera.") }
        guard observations.count == 1 else { throw ScannerError.message("More than one face was found. Use a photo of one person.") }
        let box = observations[0].boundingBox
        let base = CIImage(cgImage: cg)
        let face = CGRect(x: box.minX * base.extent.width, y: box.minY * base.extent.height, width: box.width * base.extent.width, height: box.height * base.extent.height)
        let segmentation = simulatorSafe(VNGeneratePersonSegmentationRequest())
        segmentation.qualityLevel = .accurate
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        var mask: CIImage?
        do {
            try handler.perform([segmentation])
            if let buffer = segmentation.results?.first?.pixelBuffer {
                let raw = CIImage(cvPixelBuffer: buffer)
                mask = raw.transformed(by: CGAffineTransform(scaleX: base.extent.width / raw.extent.width, y: base.extent.height / raw.extent.height))
            }
        } catch { mask = nil }
        if mask == nil {
            let foreground = simulatorSafe(VNGenerateForegroundInstanceMaskRequest())
            if (try? handler.perform([foreground])) != nil, let observation = foreground.results?.first, !observation.allInstances.isEmpty,
               let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) {
                mask = CIImage(cvPixelBuffer: buffer)
            }
        }
        if mask == nil { mask = plainBackgroundMask(cg, extent: base.extent, face: face) }
        guard let mask else { throw ScannerError.message("The person couldn't be separated from the background. Use a plain background.") }
        // Soften the edge of the cut-out slightly for natural hair.
        let soft = mask.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.2]).cropped(to: base.extent)
        var subject = PortraitSubject(image: base, mask: soft, face: face)
        // Chin: the lowest point of the face outline (the box stops short of it).
        subject.chin = face.minY
        let landmarks = simulatorSafe(VNDetectFaceLandmarksRequest())
        var observation: VNFaceObservation?
        if (try? handler.perform([landmarks])) != nil { observation = landmarks.results?.first }
        if let contour = observation?.landmarks?.faceContour {
            let points = contour.pointsInImage(imageSize: base.extent.size)
            if let low = points.map(\.y).min(), low > face.minY - face.height * 0.4 { subject.chin = min(face.minY, low) }
        }
        subject.centerX = face.midX
        let lines = headLines(mask: soft, extent: base.extent, face: face, chin: subject.chin)
        subject.crown = lines.crown
        subject.shoulder = lines.shoulder
        subject.shoulderWidth = lines.shoulderWidth
        subject.quality = portraitQuality(cg, face: face, observation: observation ?? observations[0])
        return subject
    }

    /// Reads the cut-out: the first rows of the person above the face are the
    /// top of the hair; the row where the person widens to about twice the
    /// face below the chin is the shoulder line.
    static func headLines(mask: CIImage, extent: CGRect, face: CGRect, chin: CGFloat) -> (crown: CGFloat, shoulder: CGFloat?, shoulderWidth: CGFloat?) {
        let fallback = face.maxY + face.height * 0.35
        let scale = min(1, 512 / max(extent.width, extent.height))
        let w = max(1, Int(extent.width * scale)), h = max(1, Int(extent.height * scale))
        let small = mask.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: CGRect(x: 0, y: 0, width: w, height: h)) else { return (fallback, nil, nil) }
        var gray = [UInt8](repeating: 0, count: w * h)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn else { return (fallback, nil, nil) }
        // Row r of the bitmap is the top of the image first; y = maxY - r / scale.
        func y(_ row: Int) -> CGFloat { extent.maxY - (CGFloat(row) + 0.5) / scale }
        func row(_ y: CGFloat) -> Int { max(0, min(h - 1, Int((extent.maxY - y) * scale))) }
        let x0 = max(0, Int((face.minX - extent.minX) * scale)), x1 = min(w - 1, Int((face.maxX - extent.minX) * scale))
        guard x1 > x0 else { return (fallback, nil, nil) }
        var crown = fallback
        let faceTop = row(face.maxY)
        for r in 0..<faceTop {
            var on = 0
            for x in x0...x1 where gray[r * w + x] > 128 { on += 1 }
            if Double(on) >= Double(x1 - x0 + 1) * 0.15 { crown = y(r); break }
        }
        if crown < face.maxY { crown = fallback }
        var shoulder: CGFloat?, shoulderRow = h
        let faceWidth = face.width * scale
        for r in row(chin)..<h {
            var on = 0
            for x in 0..<w where gray[r * w + x] > 128 { on += 1 }
            if Double(on) >= Double(faceWidth) * 2.0 { shoulder = y(r); shoulderRow = r; break }
        }
        // The widest span a little below the shoulder line is the shoulder width.
        var widest = 0
        if shoulder != nil {
            for r in shoulderRow..<min(h, shoulderRow + max(2, Int(faceWidth * 0.8))) {
                var first = -1, last = -1
                for x in 0..<w where gray[r * w + x] > 128 { if first < 0 { first = x }; last = x }
                if first >= 0 { widest = max(widest, last - first + 1) }
            }
        }
        return (crown, shoulder, widest > 0 ? CGFloat(widest) / scale : nil)
    }

    /// The crop (Core Image coordinates) that puts the head at the size's
    /// target height, the crown at its gap from the top, centred.
    static func portraitCrop(_ subject: PortraitSubject, size: PhotoSize, adjust: PortraitAdjust) -> (rect: CGRect, pxPerMM: CGFloat) {
        let headPx = max(1, subject.crown - subject.chin)
        let pxPerMM = headPx / CGFloat(size.headTarget * max(0.5, adjust.zoom))
        let w = CGFloat(size.width) * pxPerMM, h = CGFloat(size.height) * pxPerMM
        // The head's centre stays put while zooming.
        let headCentre = (subject.crown + subject.chin) / 2
        let centreFromTop = CGFloat(size.crownGap + size.headTarget / 2) * pxPerMM
        let top = headCentre + centreFromTop - CGFloat(adjust.dy) * pxPerMM
        let x = subject.centerX - w / 2 - CGFloat(adjust.dx) * pxPerMM
        return (CGRect(x: x, y: top - h, width: w, height: h), pxPerMM)
    }

    static func portraitMetrics(_ subject: PortraitSubject, size: PhotoSize, adjust: PortraitAdjust) -> PortraitMetrics {
        let (crop, k) = portraitCrop(subject, size: size, adjust: adjust)
        func fromTop(_ y: CGFloat) -> Double { Double((crop.maxY - y) / k) }
        return PortraitMetrics(head: Double((subject.crown - subject.chin) / k), crown: fromTop(subject.crown), chin: fromTop(subject.chin),
                               shoulder: subject.shoulder.map(fromTop), centerOffset: Double((subject.centerX - crop.midX) / k))
    }
    /// Measures what makes ID photos get rejected: tilt, closed eyes, an open
    /// mouth, uneven light, under/over exposure and glare on glasses.
    static func portraitQuality(_ cg: CGImage, face: CGRect, observation: VNFaceObservation) -> PortraitQuality {
        var q = PortraitQuality()
        if let roll = observation.roll?.doubleValue { q.roll = roll * 180 / .pi }
        if let yaw = observation.yaw?.doubleValue { q.yaw = yaw * 180 / .pi }
        let imageSize = CGSize(width: cg.width, height: cg.height)
        func box(_ region: VNFaceLandmarkRegion2D?) -> CGRect? {
            guard let points = region?.pointsInImage(imageSize: imageSize), points.count > 2 else { return nil }
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        // Landmarks are only trusted where a face has them: eyes in the upper
        // half of the face box, the mouth in its lower part, near the middle.
        let eyes = [box(observation.landmarks?.leftEye), box(observation.landmarks?.rightEye)].compactMap { $0 }
            .filter { $0.width > 1 && $0.midY > face.midY && $0.midY < face.maxY && face.contains(CGPoint(x: $0.midX, y: face.midY)) }
        if eyes.count == 2, abs(eyes[0].midX - eyes[1].midX) > face.width * 0.25 { q.eyeOpenness = eyes.map { Double($0.height / $0.width) }.min() }
        if let inner = box(observation.landmarks?.innerLips), let outer = box(observation.landmarks?.outerLips), outer.width > face.width * 0.2,
           outer.midY < face.minY + face.height * 0.42, outer.midY > face.minY - face.height * 0.1, abs(outer.midX - face.midX) < face.width * 0.15 {
            q.mouthOpen = Double(inner.height / outer.width)
        }
        // Brightness inside the face, from a small grey copy (top-left origin).
        let crop = CGRect(x: face.minX, y: imageSize.height - face.maxY, width: face.width, height: face.height).integral
            .intersection(CGRect(origin: .zero, size: imageSize))
        guard crop.width > 8, crop.height > 8, let part = cg.cropping(to: crop) else { return q }
        let n = 128
        var gray = [UInt8](repeating: 0, count: n * n)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(part, in: CGRect(x: 0, y: 0, width: n, height: n)); return true
        }
        guard drawn else { return q }
        func mean(_ xs: Range<Int>, _ ys: Range<Int>) -> Double {
            var sum = 0, count = 0
            for y in ys { for x in xs { sum += Int(gray[y * n + x]); count += 1 } }
            return count > 0 ? Double(sum) / Double(count) / 255 : 0
        }
        // Cheeks and eyes, clear of hair and background: rows 30–80 % from the top.
        let rows = Int(Double(n) * 0.4)..<Int(Double(n) * 0.75)
        let left = mean(Int(Double(n) * 0.22)..<Int(Double(n) * 0.42), rows)
        let right = mean(Int(Double(n) * 0.58)..<Int(Double(n) * 0.78), rows)
        let middle = mean(Int(Double(n) * 0.15)..<Int(Double(n) * 0.85), rows)
        q.brightness = middle
        if middle > 0.02 { q.lightBalance = abs(left - right) / middle }
        if eyes.count == 2 {
            var blown = 0, total = 0
            for eye in eyes {
                // Eye box widened to the lens of a pair of glasses, in grid cells.
                let lens = eye.insetBy(dx: -eye.width * 0.45, dy: -eye.width * 0.35)
                let gx0 = max(0, Int((lens.minX - face.minX) / face.width * CGFloat(n)))
                let gx1 = min(n, Int((lens.maxX - face.minX) / face.width * CGFloat(n)))
                let gy0 = max(0, Int((face.maxY - lens.maxY) / face.height * CGFloat(n)))
                let gy1 = min(n, Int((face.maxY - lens.minY) / face.height * CGFloat(n)))
                guard gx1 > gx0, gy1 > gy0 else { continue }
                for y in gy0..<gy1 { for x in gx0..<gx1 { total += 1; if gray[y * n + x] >= 245 { blown += 1 } } }
            }
            if total > 0 { q.glare = Double(blown) / Double(total) }
        }
        return q
    }

    static func portraitChecks(_ subject: PortraitSubject, size: PhotoSize, adjust: PortraitAdjust) -> [PortraitCheck] {
        let q = subject.quality
        var checks: [PortraitCheck] = []
        let m = portraitMetrics(subject, size: size, adjust: adjust)
        let fits = m.head >= size.headMin - 0.05 && m.head <= size.headMax + 0.05
        checks.append(PortraitCheck(id: "head", title: "Head size", passed: fits,
                                    detail: fits ? String(format: "%.1f mm, within %g–%g mm", m.head, size.headMin, size.headMax)
                                                 : String(format: "%.1f mm. Needs %g–%g mm; adjust it on the guide", m.head, size.headMin, size.headMax)))
        checks.append(PortraitCheck(id: "centre", title: "Centred", passed: abs(m.centerOffset) <= 1.5,
                                    detail: abs(m.centerOffset) <= 1.5 ? "The face is in the middle" : "Move the face to the centre line"))
        if q.roll != nil || q.yaw != nil {
            let roll = abs(q.roll ?? 0), yaw = abs(q.yaw ?? 0)
            let ok = roll <= 5 && yaw <= 10
            checks.append(PortraitCheck(id: "straight", title: "Head straight", passed: ok,
                                        detail: ok ? "Facing the camera, not tilted" : (roll > 5 ? "The head is tilted. Keep it level" : "The head is turned. Look straight at the camera")))
        }
        if let eyes = q.eyeOpenness {
            checks.append(PortraitCheck(id: "eyes", title: "Eyes open", passed: eyes >= 0.16,
                                        detail: eyes >= 0.16 ? "Both eyes are open" : "An eye looks closed. Retake with eyes wide open"))
        }
        if let mouth = q.mouthOpen {
            checks.append(PortraitCheck(id: "mouth", title: "Mouth closed", passed: mouth <= 0.08,
                                        detail: mouth <= 0.08 ? "Neutral expression" : "The mouth looks open. Keep a neutral face"))
        }
        if let balance = q.lightBalance {
            checks.append(PortraitCheck(id: "light", title: "Even light", passed: balance <= 0.25,
                                        detail: balance <= 0.25 ? "No strong shadow on the face" : "One side of the face is darker. Face a window or soft light"))
        }
        if let bright = q.brightness {
            let ok = bright >= 0.28 && bright <= 0.9
            checks.append(PortraitCheck(id: "exposure", title: "Exposure", passed: ok,
                                        detail: ok ? "The face is well lit" : (bright < 0.28 ? "The face is too dark" : "The face is too bright")))
        }
        if let glare = q.glare {
            checks.append(PortraitCheck(id: "glare", title: "No glare", passed: glare <= 0.03,
                                        detail: glare <= 0.03 ? "Eyes are clearly visible" : "Light reflects near the eyes. Tilt glasses or remove them"))
        }
        return checks
    }

    /// The collar line: just below the chin, moved up by lift millimetres.
    static func outfitNeckY(_ subject: PortraitSubject, pxPerMM: CGFloat, lift: Double) -> CGFloat {
        subject.chin - max(1, subject.crown - subject.chin) * 0.06 + CGFloat(lift) * pxPerMM
    }
    /// Where the outfit goes: its neck on the person's neck below the chin and
    /// its shoulders as wide as theirs. lift moves it up in millimetres.
    static func outfitTransform(_ subject: PortraitSubject, pxPerMM: CGFloat, lift: Double, extent: CGRect) -> CGAffineTransform {
        let faceW = max(1, subject.face.width)
        let width = min(max(subject.shoulderWidth ?? faceW * 2.7, faceW * 2.2), faceW * 3.2) * 1.04
        let unit = extent.width / Outfit.canvas
        // Neck point in the asset, Core Image coordinates (origin bottom-left).
        let neck = CGPoint(x: extent.minX + Outfit.neck.x * unit, y: extent.minY + (Outfit.canvas - Outfit.neck.y) * unit)
        let target = CGPoint(x: subject.centerX, y: outfitNeckY(subject, pxPerMM: pxPerMM, lift: lift))
        let scale = width / (Outfit.shoulders * unit)
        return CGAffineTransform(translationX: -neck.x, y: -neck.y).concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: target.x, y: target.y))
    }

    /// The colour of the neck just below the chin, slightly shaded.
    static func neckTone(_ subject: PortraitSubject) -> CIColor {
        let head = max(1, subject.crown - subject.chin), w = max(4, subject.face.width * 0.16)
        let rect = CGRect(x: subject.centerX - w / 2, y: subject.chin - head * 0.09, width: w, height: max(2, head * 0.06)).intersection(subject.image.extent)
        guard !rect.isEmpty else { return CIColor(red: 0.8, green: 0.65, blue: 0.55) }
        let average = subject.image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return CIColor(red: CGFloat(px[0]) / 255 * 0.97, green: CGFloat(px[1]) / 255 * 0.97, blue: CGFloat(px[2]) / 255 * 0.97)
    }

    /// The photo as a JPEG for an online form: the exact pixels, compressed
    /// until it is under the limit. Uneven aspect ratios pad with the backdrop.
    static func digitalJPEG(_ photo: UIImage, spec: DigitalSpec, backdrop: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let canvas = CGSize(width: spec.width, height: spec.height)
        let fit = min(canvas.width / max(1, photo.size.width), canvas.height / max(1, photo.size.height))
        let drawn = CGSize(width: photo.size.width * fit, height: photo.size.height * fit)
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            backdrop.setFill(); ctx.fill(CGRect(origin: .zero, size: canvas))
            photo.draw(in: CGRect(x: (canvas.width - drawn.width) / 2, y: (canvas.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        let limit = spec.maxKB * 1024
        if let best = image.jpegData(compressionQuality: 0.95), best.count <= limit { return best }
        var lo = 0.05, hi = 0.95
        var found = image.jpegData(compressionQuality: lo) ?? Data()
        for _ in 0..<9 {
            let q = (lo + hi) / 2
            guard let data = image.jpegData(compressionQuality: q) else { break }
            if data.count <= limit { found = data; lo = q } else { hi = q }
        }
        return found
    }

    /// The finished photo at 300 dpi: the head from chin to crown at the
    /// size's required height, the crown at its gap from the top, centred.
    /// Space beyond the original photo takes the background colour.
    static func portrait(_ subject: PortraitSubject, size: PhotoSize, backdrop: Backdrop, adjust: PortraitAdjust = PortraitAdjust(),
                         outfit: Outfit = .none, outfitLift: Double = 0) throws -> UIImage {
        let base = subject.image
        let background = CIImage(color: CIColor(color: backdrop.color))
        let (crop, pxPerMM) = portraitCrop(subject, size: size, adjust: adjust)
        var personMask = subject.mask
        if let clothes = outfit.image {
            // With an outfit the suit is the body. Below the collar the person
            // only stays where the suit or its neck opening covers them, so their
            // own clothes never show around it; hair beside the neck tucks behind.
            let place = outfitTransform(subject, pxPerMM: pxPerMM, lift: outfitLift, extent: clothes.extent)
            let collar = outfitNeckY(subject, pxPerMM: pxPerMM, lift: outfitLift)
            let feather = max(2, (subject.crown - subject.chin) * 0.02)
            let step = CIFilter.linearGradient()
            let cut = collar - (subject.crown - subject.chin) * 0.03   // a little inside the collar, no seam
            step.point0 = CGPoint(x: 0, y: cut - feather); step.color0 = CIColor(red: 0, green: 0, blue: 0)
            step.point1 = CGPoint(x: 0, y: cut + feather); step.color1 = CIColor(red: 1, green: 1, blue: 1)
            let alpha = CIVector(x: 0, y: 0, z: 0, w: 1)
            var covered = clothes.applyingFilter("CIColorMatrix", parameters: ["inputRVector": alpha, "inputGVector": alpha, "inputBVector": alpha, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                .transformed(by: place)
            if let neck = outfit.neckMask { covered = neck.transformed(by: place).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: covered]) }
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: base.extent)
            if let above = step.outputImage?.cropped(to: base.extent) {
                let keep = above.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: covered.composited(over: black)]).cropped(to: base.extent)
                personMask = keep.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: subject.mask])
            }
        }
        var composite = base.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: personMask])
        if let clothes = outfit.image {
            let place = outfitTransform(subject, pxPerMM: pxPerMM, lift: outfitLift, extent: clothes.extent)
            if let neck = outfit.neckMask {
                // Fade the skin in below the collar line so the real neck runs into it.
                let unit = neck.extent.width / Outfit.canvas
                let top = neck.extent.maxY - Outfit.neck.y * unit
                let ramp = CIFilter.linearGradient()
                ramp.point0 = CGPoint(x: 0, y: top); ramp.color0 = CIColor(red: 0, green: 0, blue: 0)
                ramp.point1 = CGPoint(x: 0, y: top - 70 * unit); ramp.color1 = CIColor(red: 1, green: 1, blue: 1)
                let faded = (ramp.outputImage ?? CIImage(color: .white)).cropped(to: neck.extent)
                    .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: neck])
                let skin = CIImage(color: neckTone(subject)).cropped(to: composite.extent)
                composite = skin.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: composite, kCIInputMaskImageKey: faded.transformed(by: place)])
            }
            composite = clothes.transformed(by: place).composited(over: composite)
        }
        let x = crop.minX, y = crop.minY, w = crop.width, h = crop.height
        let pixelsW = size.width / 25.4 * 300, pixelsH = size.height / 25.4 * 300
        let out = composite.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
            .transformed(by: CGAffineTransform(scaleX: pixelsW / w, y: pixelsH / h))
        return try output(out, extent: CGRect(x: 0, y: 0, width: pixelsW.rounded(), height: pixelsH.rounded()))
    }
    /// How many copies fit on a paper and which way round it goes.
    static func sheetLayout(_ size: PhotoSize, paper: PrintPaper) -> (sheet: CGSize, columns: Int, rows: Int) {
        let gap = 2.0, margin = 3.0
        func count(_ sheet: CGSize) -> (Int, Int) {
            (max(0, Int((Double(sheet.width) - 2 * margin + gap) / (size.width + gap))), max(0, Int((Double(sheet.height) - 2 * margin + gap) / (size.height + gap))))
        }
        let landscape = paper.millimeters, portrait = CGSize(width: landscape.height, height: landscape.width)
        let a = count(landscape), b = count(portrait)
        return a.0 * a.1 >= b.0 * b.1 ? (landscape, max(1, a.0), max(1, a.1)) : (portrait, max(1, b.0), max(1, b.1))
    }
    /// A print sheet at 300 dpi with as many copies as fit, cut lines included.
    static func printSheet(_ photo: UIImage, size: PhotoSize, paper: PrintPaper = .fourBySix) -> UIImage {
        let dpi: CGFloat = 300, px = dpi / 25.4
        let layout = sheetLayout(size, paper: paper)
        let sheet = CGSize(width: (layout.sheet.width * px).rounded(), height: (layout.sheet.height * px).rounded())
        let cell = CGSize(width: CGFloat(size.width) * px, height: CGFloat(size.height) * px)
        let gap = 2 * px
        let used = CGSize(width: CGFloat(layout.columns) * cell.width + CGFloat(layout.columns - 1) * gap, height: CGFloat(layout.rows) * cell.height + CGFloat(layout.rows - 1) * gap)
        let origin = CGPoint(x: (sheet.width - used.width) / 2, y: (sheet.height - used.height) / 2)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: sheet, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: sheet))
            let cg = ctx.cgContext
            for r in 0..<layout.rows { for c in 0..<layout.columns {
                let rect = CGRect(x: origin.x + CGFloat(c) * (cell.width + gap), y: origin.y + CGFloat(r) * (cell.height + gap), width: cell.width, height: cell.height)
                photo.draw(in: rect)
                UIColor(white: 0.75, alpha: 1).setStroke(); cg.setLineWidth(1); cg.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
            } }
            // Cut marks in the margin, in line with every edge.
            UIColor(white: 0.55, alpha: 1).setStroke(); cg.setLineWidth(2)
            let mark = min(origin.x, origin.y, 6 * px) * 0.8
            var xs: [CGFloat] = [], ys: [CGFloat] = []
            for c in 0..<layout.columns { let x = origin.x + CGFloat(c) * (cell.width + gap); xs += [x, x + cell.width] }
            for r in 0..<layout.rows { let y = origin.y + CGFloat(r) * (cell.height + gap); ys += [y, y + cell.height] }
            if mark > 2 {
                for x in xs { cg.strokeLineSegments(between: [CGPoint(x: x, y: origin.y - mark - 4), CGPoint(x: x, y: origin.y - 4),
                                                              CGPoint(x: x, y: origin.y + used.height + 4), CGPoint(x: x, y: origin.y + used.height + mark + 4)]) }
                for y in ys { cg.strokeLineSegments(between: [CGPoint(x: origin.x - mark - 4, y: y), CGPoint(x: origin.x - 4, y: y),
                                                              CGPoint(x: origin.x + used.width + 4, y: y), CGPoint(x: origin.x + used.width + mark + 4, y: y)]) }
            }
        }
    }

    // MARK: Book

    /// Finds the fold of a book spread: the darkest, most uniform vertical band
    /// near the middle where the pages curve into the spine.
    static func gutter(_ input: UIImage) -> Double {
        guard let r = try? raster(input, maxSide: 600) else { return 0.5 }
        let w = r.width, h = r.height
        var profile = [Double](repeating: 0, count: w)
        for x in 0..<w {
            var s = 0
            var y = h / 5
            while y < h * 4 / 5 { let p = r.index(x, y); s += Int(r.bytes[p]) + Int(r.bytes[p + 1]) + Int(r.bytes[p + 2]); y += 2 }
            profile[x] = Double(s)
        }
        let window = max(3, w / 60)
        var best = 0.5, bestScore = Double.infinity
        for x in (w * 30 / 100)...(w * 70 / 100) {
            let lo = max(0, x - window), hi = min(w - 1, x + window)
            let mean = profile[lo...hi].reduce(0, +) / Double(hi - lo + 1)
            // Prefer the centre slightly.
            let score = mean * (1 + abs(Double(x) / Double(w) - 0.5) * 0.6)
            if score < bestScore { bestScore = score; best = Double(x) / Double(w) }
        }
        let median = profile.sorted()[w / 2]
        // No clear fold: start from the middle.
        return bestScore < median * 0.93 ? best : 0.5
    }

    enum Spine { case left, right }

    /// Crops a photo to the document it shows (the open book), straightening
    /// the perspective. Returns the photo unchanged when no clear page is found.
    static func cropToPage(_ input: UIImage) -> UIImage {
        let image = Imaging.normalized(input)
        guard let cg = image.cgImage, let quad = DocumentProcessing.detect(cg), quad.valid,
              DocumentProcessing.area(quad) > 0.2, DocumentProcessing.area(quad) < 0.97,
              let rendered = try? DocumentProcessing.render(CIImage(cgImage: cg), crop: quad, turns: 0, enhancement: .original),
              let result = try? output(rendered) else { return image }
        return result
    }

    /// Splits a spread into pages, with the spine side of each page.
    static func bookPages(_ input: UIImage, split: Double, twoPages: Bool) throws -> [(UIImage, Spine)] {
        guard let cg = Imaging.normalized(input).cgImage, (0.1...0.9).contains(split) else { throw ScannerError.message("Invalid book settings.") }
        if !twoPages { return [(UIImage(cgImage: cg), try spineSide(UIImage(cgImage: cg)))] }
        let cut = Int(Double(cg.width) * split)
        guard let left = cg.cropping(to: CGRect(x: 0, y: 0, width: cut, height: cg.height)),
              let right = cg.cropping(to: CGRect(x: cut, y: 0, width: cg.width - cut, height: cg.height))
        else { throw ScannerError.message("Could not split the book.") }
        return [(UIImage(cgImage: left), .right), (UIImage(cgImage: right), .left)]
    }

    /// For a single page the spine is the darker edge.
    static func spineSide(_ page: UIImage) throws -> Spine {
        let r = try raster(page, maxSide: 400)
        func edge(_ xs: Range<Int>) -> Int {
            var s = 0
            for y in stride(from: 0, to: r.height, by: 2) { for x in xs { let p = r.index(x, y); s += Int(r.bytes[p + 1]) } }
            return s
        }
        let band = max(2, r.width / 12)
        return edge(0..<band) <= edge((r.width - band)..<r.width) ? .left : .right
    }

    /// Estimates how much the page curls up next to the spine. Near the spine
    /// the page rises toward the camera, so text lines there look magnified
    /// away from the middle of the page. Walks from the flat outer part toward
    /// the spine in narrow bands, measuring the small change of scale between
    /// neighbouring bands from their text-line profiles, then fits the
    /// cylinder model used by `flattenPage`.
    static func estimateCurve(_ page: UIImage, spine: Spine) -> Double {
        guard let r = try? raster(page, maxSide: 900), r.width > 80, r.height > 80 else { return 0 }
        let w = r.width, h = r.height
        func profile(_ t0: Double, _ t1: Double) -> [Double] {
            let a = Int(Double(w) * t0), b = max(a + 1, Int(Double(w) * t1))
            var out = [Double](repeating: 0, count: h)
            for y in 0..<h {
                var s = 0
                for i in a..<b { let x = spine == .left ? i : w - 1 - i; s += 255 - Int(r.bytes[r.index(x, y) + 1]) }
                out[y] = Double(s) / Double(b - a)
            }
            return out
        }
        let cy = Double(h) / 2, y0 = h / 10, y1 = h * 9 / 10
        func sample(_ v: [Double], _ y: Double) -> Double {
            if y <= 0 { return v[0] }
            if y >= Double(h - 1) { return v[h - 1] }
            let i = Int(y), f = y - Double(i); return v[i] * (1 - f) + v[i + 1] * f
        }
        func correlation(_ a: [Double], _ b: [Double], _ scale: Double) -> Double {
            var sxy = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, n = 0.0
            for y in y0..<y1 {
                let p = a[y], q = sample(b, cy + (Double(y) - cy) / scale)
                sxy += p * q; sx += p; sy += q; sxx += p * p; syy += q * q; n += 1
            }
            let cov = sxy - sx * sy / n, va = sxx - sx * sx / n, vb = syy - sy * sy / n
            return va > 1e-6 && vb > 1e-6 ? cov / sqrt(va * vb) : -1
        }
        let centers = stride(from: 0.7, to: 0.03, by: -0.04).map { $0 }
        let profiles = centers.map { profile($0 - 0.02, $0 + 0.02) }
        var magnification = [1.0], usable = [true]
        for i in 1..<centers.count {
            var best = (-2.0, 1.0)
            for step in 0...40 {
                let scale = 0.95 + Double(step) * 0.0025
                let c = correlation(profiles[i], profiles[i - 1], scale)
                if c > best.0 { best = (c, scale) }
            }
            magnification.append(magnification[i - 1] * best.1)
            usable.append(best.0 > 0.5)
        }
        guard usable.filter({ $0 }).count >= 6 else { return 0 }
        var best = (Double.infinity, 0.0)
        for step in 0...120 {
            let k = Double(step) * 0.005
            let reference = 1 + k * 0.09
            var error = 0.0
            for i in centers.indices where usable[i] {
                let model = (1 + k * (1 - centers[i]) * (1 - centers[i])) / reference
                error += (model - magnification[i]) * (model - magnification[i])
            }
            if error < best.0 { best = (error, k) }
        }
        return min(0.45, best.1)
    }

    /// Flattens a curved book page with a cylinder model: content close to the
    /// spine curls toward the camera, so it looks larger (lines bend away from
    /// the middle) and squeezed sideways. Also lifts the shadow in the gutter.
    static func flattenPage(_ page: UIImage, spine: Spine, curve: Double, liftShadow: Bool = true) throws -> UIImage {
        let normalized = Imaging.normalized(page)
        guard let cg = normalized.cgImage, cg.width > 2, cg.height > 2 else { return page }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var image = CIImage(cgImage: cg)
        // 1. Lift the gutter shadow: divide every column by its paper brightness.
        if liftShadow, let shade = try? columnShade(normalized) {
            let map = CIImage(cgImage: shade)
                .transformed(by: CGAffineTransform(scaleX: w / CGFloat(shade.width), y: h))
                .clampedToExtent().cropped(to: image.extent)
            // CIDivideBlendMode gives background ÷ input.
            image = map.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: image.extent)
        }
        // 2. Undo the curl with a warp on the GPU.
        let k = max(0, min(0.5, curve)), a = min(0.5, k * 0.7)
        if k > 0.001, let kernel = flattenKernel {
            let extent = image.extent
            // Pad with paper white so samples beyond the photo never smear its edge rows.
            let padded = image.composited(over: CIImage(color: .white).cropped(to: extent.insetBy(dx: -w, dy: -h)))
            let args: [Any] = [Float(w), Float(h), Float(k), Float(a), Float(spine == .left ? 1 : 0)]
            if let warped = kernel.apply(extent: extent, roiCallback: { _, rect in
                rect.insetBy(dx: -(w * CGFloat(a) * 0.16 + 2), dy: -(h * CGFloat(k) * 0.5 + 2)).intersection(padded.extent)
            }, image: padded, arguments: args) {
                image = warped.cropped(to: extent)
            }
        }
        return try output(image, extent: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// One row of per-column shading: paper brightness relative to the page,
    /// 1 where there is no gutter shadow.
    private static func columnShade(_ page: UIImage) throws -> CGImage {
        let r = try raster(page, maxSide: 800)
        let w = r.width, h = r.height
        var paper = [Float](repeating: 0, count: w)
        var column = [UInt8](repeating: 0, count: (h + 1) / 2)
        for x in 0..<w {
            var n = 0
            for y in stride(from: 0, to: h, by: 2) {
                let p = r.index(x, y); column[n] = max(r.bytes[p], max(r.bytes[p + 1], r.bytes[p + 2])); n += 1
            }
            column[0..<n].sort()
            paper[x] = Float(column[n * 85 / 100])
        }
        let radius = max(2, w / 80)
        var smooth = [Float](repeating: 0, count: w)
        for x in 0..<w { let lo = max(0, x - radius), hi = min(w - 1, x + radius); smooth[x] = paper[lo...hi].reduce(0, +) / Float(hi - lo + 1) }
        let target = max(1, smooth.sorted()[w * 3 / 4])
        // Only a paper-coloured shadow is lifted, never a dark desk or a photo.
        var bytes = smooth.map { v -> UInt8 in
            let shade = v > target * 0.45 ? min(1, max(0.55, v / target)) : 1
            return UInt8((shade * 255).rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes: &bytes, count: w) as CFData),
              let image = CGImage(width: w, height: 1, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ScannerError.message("Image processing failed.") }
        return image
    }

    /// Maps each output pixel of a flattened page back into the photo
    /// (Core Image coordinates; the model is symmetric top to bottom).
    private static let flattenKernel = CIWarpKernel(source: """
    kernel vec2 flattenPage(float w, float h, float k, float a, float spineLeft) {
        vec2 d = destCoord();
        float u = spineLeft > 0.5 ? d.x / (w - 1.0) : (w - 1.0 - d.x) / (w - 1.0);
        float us = u - a * u * (1.0 - u) * (1.0 - u);
        float g = (1.0 - us) * (1.0 - us);
        float sx = (spineLeft > 0.5 ? us : 1.0 - us) * (w - 1.0);
        float cy = (h - 1.0) * 0.5;
        return vec2(sx, cy + (d.y - cy) * (1.0 + k * g));
    }
    """)

    // MARK: Mega scan

    /// Positions each photo against the previous one using image registration
    /// on reduced copies. Returns offsets in pixels of the full-size images.
    static func autoArrange(_ images: [UIImage]) throws -> [CGPoint] {
        guard images.count >= 2 else { return images.map { _ in .zero } }
        var offsets: [CGPoint] = [.zero]
        for i in 1..<images.count {
            try Task.checkCancellation()
            let a = Imaging.normalized(images[i - 1]), b = Imaging.normalized(images[i])
            guard let shift = try register(a, b) else {
                throw ScannerError.message("Photos \(i) and \(i + 1) don't overlap enough. Retake them with about a third shared.")
            }
            offsets.append(CGPoint(x: offsets[i - 1].x + shift.x, y: offsets[i - 1].y + shift.y))
        }
        return offsets
    }

    /// Edge map of a photo at a given scale, for matching overlaps.
    struct EdgeMap {
        let values: [Float]
        let width: Int
        let height: Int
        /// Summed-area tables of values and squares, (width+1)×(height+1).
        let sum: [Double]
        let sumSq: [Double]
        init(_ image: UIImage, scale: CGFloat) throws {
            let r = try ImageToolEngine.raster(image, maxSide: max(8, Int((max(image.size.width, image.size.height) * scale).rounded())))
            let w = r.width, h = r.height
            var gray = [Float](repeating: 0, count: w * h)
            for i in 0..<(w * h) { let p = i * 4; gray[i] = Float(Int(r.bytes[p]) + Int(r.bytes[p + 1]) + Int(r.bytes[p + 2])) / 3 }
            var edge = [Float](repeating: 0, count: w * h)
            for y in 1..<max(1, h - 1) { for x in 1..<max(1, w - 1) {
                let i = y * w + x
                edge[i] = abs(gray[i + 1] - gray[i - 1]) + abs(gray[i + w] - gray[i - w])
            } }
            var s = [Double](repeating: 0, count: (w + 1) * (h + 1)), q = s
            for y in 0..<h {
                var row = 0.0, rowSq = 0.0
                for x in 0..<w {
                    let v = Double(edge[y * w + x]); row += v; rowSq += v * v
                    s[(y + 1) * (w + 1) + x + 1] = s[y * (w + 1) + x + 1] + row
                    q[(y + 1) * (w + 1) + x + 1] = q[y * (w + 1) + x + 1] + rowSq
                }
            }
            values = edge; width = w; height = h; sum = s; sumSq = q
        }
        func box(_ t: [Double], _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
            let W = width + 1
            return t[y1 * W + x1] - t[y0 * W + x1] - t[y1 * W + x0] + t[y0 * W + x0]
        }
    }

    /// Normalised cross-correlation of B placed at (dx, dy) inside A's frame.
    static func overlapScore(_ a: EdgeMap, _ b: EdgeMap, _ dx: Int, _ dy: Int, minimumShare: Double) -> Double? {
        let x0 = max(0, dx), y0 = max(0, dy), x1 = min(a.width, dx + b.width), y1 = min(a.height, dy + b.height)
        let ow = x1 - x0, oh = y1 - y0
        guard ow >= 6, oh >= 6 else { return nil }
        let n = Double(ow * oh)
        guard n >= minimumShare * Double(min(a.width * a.height, b.width * b.height)) else { return nil }
        let sa = a.box(a.sum, x0, y0, x1, y1), saa = a.box(a.sumSq, x0, y0, x1, y1)
        let sb = b.box(b.sum, x0 - dx, y0 - dy, x1 - dx, y1 - dy), sbb = b.box(b.sumSq, x0 - dx, y0 - dy, x1 - dx, y1 - dy)
        var sab = 0.0
        a.values.withUnsafeBufferPointer { pa in b.values.withUnsafeBufferPointer { pb in
            for y in y0..<y1 {
                var dot: Float = 0
                vDSP_dotpr(pa.baseAddress! + y * a.width + x0, 1, pb.baseAddress! + (y - dy) * b.width + (x0 - dx), 1, &dot, vDSP_Length(ow))
                sab += Double(dot)
            }
        } }
        let va = saa - sa * sa / n, vb = sbb - sb * sb / n
        guard va > 1e-6, vb > 1e-6 else { return nil }
        return (sab - sa * sb / n) / (va * vb).squareRoot()
    }

    /// Finds where photo B sits relative to photo A (in A's pixels), searching
    /// every overlap on small copies, then refining on larger ones.
    static func register(_ a: UIImage, _ b: UIImage) throws -> CGPoint? {
        let longest = max(a.size.width, a.size.height, b.size.width, b.size.height)
        let coarseScale = 140 / longest, fineScale = min(1, 560 / longest)
        let ca = try EdgeMap(a, scale: coarseScale), cb = try EdgeMap(b, scale: coarseScale)
        var best: (score: Double, x: Int, y: Int) = (-2, 0, 0)
        for dy in stride(from: -cb.height + 6, through: ca.height - 6, by: 2) {
            if dy % 16 == 0 { try Task.checkCancellation() }
            for dx in stride(from: -cb.width + 6, through: ca.width - 6, by: 2) {
                if let s = overlapScore(ca, cb, dx, dy, minimumShare: 0.12), s > best.score { best = (s, dx, dy) }
            }
        }
        let (gx, gy) = (best.x, best.y)
        for dy in (gy - 2)...(gy + 2) { for dx in (gx - 2)...(gx + 2) {
            if let s = overlapScore(ca, cb, dx, dy, minimumShare: 0.12), s > best.score { best = (s, dx, dy) }
        } }
        guard best.score > 0.25 else { return nil }
        let fa = try EdgeMap(a, scale: fineScale), fb = try EdgeMap(b, scale: fineScale)
        let ratio = fineScale / coarseScale
        let cx = Int((Double(best.x) * ratio).rounded()), cy = Int((Double(best.y) * ratio).rounded())
        let reach = Int(ratio.rounded(.up)) + 2
        var fine: (score: Double, x: Int, y: Int) = (-2, cx, cy)
        for dy in (cy - reach)...(cy + reach) { for dx in (cx - reach)...(cx + reach) {
            if let s = overlapScore(fa, fb, dx, dy, minimumShare: 0.08), s > fine.score { fine = (s, dx, dy) }
        } }
        guard fine.score > 0.3 else { return nil }
        // Back to full-size pixels of photo A.
        let sx = a.size.width / CGFloat(fa.width)
        let sy = a.size.height / CGFloat(fa.height)
        return CGPoint(x: CGFloat(fine.x) * sx, y: CGFloat(fine.y) * sy)
    }
    private static func resized(_ image: UIImage, scale: CGFloat) -> UIImage {
        let size = CGSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
    /// One canvas, later photos blended in with a soft edge so seams fade.
    static func stitch(_ images: [UIImage], offsets: [CGPoint]) throws -> UIImage {
        guard (2...8).contains(images.count), offsets.count == images.count else { throw ScannerError.message("Choose 2–8 photos.") }
        let rects = zip(images, offsets).map { CGRect(origin: $0.1, size: $0.0.size) }
        let bounds = rects.reduce(CGRect.null) { $0.union($1) }.integral
        var scale: CGFloat = 1
        if bounds.width * bounds.height > 40_000_000 { scale = (40_000_000 / (bounds.width * bounds.height)).squareRoot() }
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            for (i, image) in images.enumerated() {
                if Task.isCancelled { return }
                let rect = rects[i].offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                let target = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                if i == 0 { Imaging.normalized(image).draw(in: target); continue }
                let feather = min(target.width, target.height) * 0.06
                if let soft = softEdged(Imaging.normalized(image), feather: feather / scale) { soft.draw(in: target) }
                else { Imaging.normalized(image).draw(in: target) }
            }
        }
    }
    private static func softEdged(_ image: UIImage, feather: CGFloat) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let base = CIImage(cgImage: cg)
        let e = base.extent
        let inner = e.insetBy(dx: feather, dy: feather)
        guard inner.width > 0, inner.height > 0 else { return nil }
        let mask = CIImage(color: .white).cropped(to: inner).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather / 2.5])
            .composited(over: CIImage(color: .black)).cropped(to: e)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: e)
        let out = base.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
        guard let space = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let result = context.createCGImage(out, from: e, format: .RGBA8, colorSpace: space) else { return nil }
        return UIImage(cgImage: result)
    }

    // MARK: Saving

    /// A PDF with one picture per page, at the picture's physical size when given.
    static func pdf(_ images: [UIImage], millimeters: CGSize? = nil, text: [[TextBlock]] = []) throws -> Data {
        try OfflineImageEngine.pdf(images, millimeters: millimeters, text: text)
    }
}

/// ID photos made before, kept on this iPhone so they can be printed again or
/// remade in another size: the source photo, the finished photo and the settings.
struct PortraitHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var sizeID: String
    var backdrop: String
    var zoom: Double = 1
    var dx: Double = 0
    var dy: Double = 0
    var outfit: String = ImageToolEngine.Outfit.none.rawValue
    var outfitLift: Double = 0
}

enum PortraitHistory {
    static let limit = 12
    static var root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("IDPhotoHistory", isDirectory: true)
    private static func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    static func list() -> [PortraitHistoryEntry] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("entry.json")) else { return nil }
            return try? JSONDecoder().decode(PortraitHistoryEntry.self, from: data)
        }.sorted { $0.date > $1.date }
    }
    /// Saves or updates an entry; the oldest beyond the limit are removed.
    static func save(_ entry: PortraitHistoryEntry, source: UIImage, photo: UIImage) throws {
        let dir = folder(entry.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sourceURL = dir.appendingPathComponent("source.jpg")
        if !FileManager.default.fileExists(atPath: sourceURL.path) {
            let small = Imaging.limited(Imaging.normalized(source), maxPixels: 6_000_000)
            try (small.jpegData(compressionQuality: 0.9) ?? Data()).write(to: sourceURL, options: [.atomic, .completeFileProtection])
        }
        try (photo.jpegData(compressionQuality: 0.85) ?? Data()).write(to: dir.appendingPathComponent("photo.jpg"), options: [.atomic, .completeFileProtection])
        try JSONEncoder().encode(entry).write(to: dir.appendingPathComponent("entry.json"), options: [.atomic, .completeFileProtection])
        for old in list().dropFirst(limit) { remove(old.id) }
    }
    static func source(_ id: UUID) -> UIImage? { UIImage(contentsOfFile: folder(id).appendingPathComponent("source.jpg").path) }
    static func photo(_ id: UUID) -> UIImage? { UIImage(contentsOfFile: folder(id).appendingPathComponent("photo.jpg").path) }
    static func remove(_ id: UUID) { try? FileManager.default.removeItem(at: folder(id)) }
}
