import Foundation
import CoreImage.CIFilterBuiltins
import Vision

// Shared by the iPhone renderer and the local quality-check tool.
// Every output pixel is derived from the photograph; printed content is never synthesized.
enum DocumentProcessing {
    static let context = CIContext(options: [.cacheIntermediates: false])
    // Applied after automatic cleanup, identically in preview, OCR and export.
    // The neutral values leave existing documents' appearance unchanged.
    static func adjust(_ image: CIImage, settings: PageAdjustments) -> CIImage {
        let settings = settings.bounded
        var result = image
        if settings.brightness != 0 || settings.contrast != 1 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: settings.brightness, kCIInputContrastKey: settings.contrast
            ])
        }
        let scale = min(1.6, max(0.8, max(image.extent.width, image.extent.height)/2200))
        if settings.sharpness > 0 {
            result = result.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: scale, kCIInputIntensityKey: settings.sharpness*1.2
            ])
        } else if settings.sharpness < 0 {
            result = result.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: -settings.sharpness*0.8*scale
            ])
        }
        return result.cropped(to: image.extent)
    }
    enum DetectionKind { case document, rectangle }

    struct DetectionCandidate {
        var quad: ScanQuad
        var kind: DetectionKind
        var confidence: Float
        var interior: Double
        var edge: Double
        var strongEdges: Int
        var accepted: Bool
        var score: Double
    }

    static func detect(_ image: CGImage) -> ScanQuad? {
        guard let best = candidates(image).filter(\.accepted).max(by: { $0.score < $1.score })?.quad else { return nil }
        guard let raster = Raster(image, maximumDimension: 384) else { return best }
        return extendToPaperEdges(best, raster: raster)
    }

    /// Vision's rectangle can stop at a printed screenshot, a box or a fold instead of the
    /// sheet's edge, cutting off the rest of the page. Where paper clearly continues
    /// beyond an edge, move that edge outward until the paper ends. An edge is moved only
    /// when the end of the paper is found inside the photo, so a sheet on a white desk
    /// (no visible boundary) keeps its detected edge.
    /// When no sheet outline is found (a stack of pages, a cluttered desk), a printed
    /// rectangle on the page, such as a table's frame, still runs parallel to the
    /// sheet's edges. Grow it outward across the paper margin to where the paper ends.
    /// Tests only: traces the sheet-edge search.
    nonisolated(unsafe) static var debugLog: ((String) -> Void)?
    static func detectSheetFromContent(_ image: CGImage) -> ScanQuad? {
        guard let raster = Raster(image, maximumDimension: 900) else { return nil }
        let inner = candidates(image).filter { $0.kind == .rectangle && $0.interior > 0.75 && area($0.quad) >= 0.04 }
            .max { area($0.quad) < area($1.quad) }
        guard let inner else { return nil }
        guard let grown = growToSheet(inner.quad, raster: raster), grown.valid, area(grown) > area(inner.quad) * 1.3 else { return nil }
        // The paper reaches this far, but it may be several sheets lying on each
        // other. Within that area, the top sheet is the largest rectangle that
        // holds the content.
        return topSheet(in: grown, containing: inner.quad, image: image) ?? grown
    }

    private static func topSheet(in outer: ScanQuad, containing inner: ScanQuad, image: CGImage) -> ScanQuad? {
        let xs = outer.points.map(\.x), ys = outer.points.map(\.y)
        let x0 = max(0, xs.min()! - 0.03), x1 = min(1, xs.max()! + 0.03), y0 = max(0, ys.min()! - 0.03), y1 = min(1, ys.max()! + 0.03)
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 16; request.minimumConfidence = 0.5; request.minimumAspectRatio = 0.3
        request.minimumSize = 0.5; request.quadratureTolerance = 25
        // Vision's region of interest is in lower-left-origin normalized coordinates.
        request.regionOfInterest = CGRect(x: x0, y: 1 - y1, width: x1 - x0, height: y1 - y0)
        try? VNImageRequestHandler(cgImage: image).perform([request])
        func inside(_ p: ScanPoint, _ q: ScanQuad) -> Bool {
            var sign = 0
            for i in 0..<4 {
                let a = q.points[i], b = q.points[(i + 1) % 4]
                let c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                let s = c >= 0 ? 1 : -1
                if sign == 0 { sign = s } else if s != sign { return false }
            }
            return true
        }
        let found = (request.results ?? []).map { o -> ScanQuad in
            // Results are relative to the region of interest.
            let pts = [o.topLeft, o.topRight, o.bottomRight, o.bottomLeft].map { p in
                ScanPoint(x: x0 + Double(p.x) * (x1 - x0), y: y1 - Double(p.y) * (y1 - y0))
            }
            return ScanQuad(points: pts)
        }.filter { q in
            q.valid && inner.points.allSatisfy { p in inside(ScanPoint(x: p.x, y: p.y), q) }
                && area(q) > area(inner) * 1.3 && area(q) <= area(outer) * 1.02
        }
        return found.max { area($0) < area($1) }
    }

    /// Maps the unit square onto a quad (TL, TR, BR, BL): a projective map, so
    /// lines parallel on the page stay parallel in (u, v) whatever the camera angle.
    struct SquareToQuad {
        let h: [Double]
        init?(_ q: ScanQuad) {
            let p = q.points
            let x0 = p[0].x, y0 = p[0].y, x1 = p[1].x, y1 = p[1].y, x2 = p[2].x, y2 = p[2].y, x3 = p[3].x, y3 = p[3].y
            let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
            let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
            let det = dx1 * dy2 - dx2 * dy1
            guard abs(det) > 1e-12 else { return nil }
            let g = (dx3 * dy2 - dx2 * dy3) / det, hh = (dx1 * dy3 - dx3 * dy1) / det
            h = [x1 - x0 + g * x1, x3 - x0 + hh * x3, x0, y1 - y0 + g * y1, y3 - y0 + hh * y3, y0, g, hh, 1]
        }
        func callAsFunction(_ u: Double, _ v: Double) -> ScanPoint {
            let w = h[6] * u + h[7] * v + h[8]
            return ScanPoint(x: (h[0] * u + h[1] * v + h[2]) / w, y: (h[3] * u + h[4] * v + h[5]) / w)
        }
    }

    /// Grows printed content (a table's frame) to the sheet it is printed on. The
    /// search runs in the content's own rectified coordinates, where the sheet is
    /// an upright rectangle around it, so a steep camera angle does not tilt the
    /// sheet's edges. Each side moves out across the paper margin until the paper ends.
    private static func growToSheet(_ quad: ScanQuad, raster: Raster) -> ScanQuad? {
        guard let map = SquareToQuad(quad) else { return nil }
        func rgb(_ u: Double, _ v: Double) -> [Double]? {
            let p = map(u, v)
            guard (0...1).contains(p.x), (0...1).contains(p.y) else { return nil }
            return raster.pixel(p.x, p.y)
        }
        func lum(_ c: [Double]) -> Double { c[0] * 0.299 + c[1] * 0.587 + c[2] * 0.114 }
        // Step of about one raster pixel in content units.
        let corner = map(0, 0), across = map(1, 0)
        let widthPx = hypot((across.x - corner.x) * Double(raster.width), (across.y - corner.y) * Double(raster.height))
        let step = 1 / max(50, widthPx)
        var bounds = [0.0, 0.0, 1.0, 1.0]   // u0, v0, u1, v1
        var framed = 0
        // side: (moves u or v, direction)
        for (side, along) in [(0, true), (1, false), (2, true), (3, false)].map({ ($0.0, $0.1) }) {
            let outward = side >= 2 ? 1.0 : -1.0
            let base = bounds[side]
            func point(_ t: Double, _ d: Double) -> (Double, Double) {
                let s = 0.1 + 0.8 * t
                let edge = base + outward * d
                return along ? (edge, s) : (s, edge)
            }
            // The paper margin just outside the content is the reference.
            var reference = [0.0, 0.0, 0.0], n = 0.0
            for j in 0..<9 {
                let (u, v) = point(Double(j) / 8, step * 6)
                guard let c = rgb(u, v), paperLikelihood(c) > 0.5 else { continue }
                for k in 0..<3 { reference[k] += c[k] }; n += 1
            }
            guard n >= 5 else { return nil }
            reference = reference.map { $0 / n }
            func samePaper(_ c: [Double]) -> Bool {
                guard paperLikelihood(c) > 0.5 else { return false }
                let shift = (0..<3).map { c[$0] - reference[$0] }
                let mean = shift.reduce(0, +) / 3
                return (shift.map { abs($0 - mean) }.max() ?? 0) < 0.06 && mean > -0.25
            }
            func paperFraction(_ d: Double) -> Double? {
                var paper = 0.0, total = 0.0
                for j in 0..<9 { let (u, v) = point(Double(j) / 8, d); guard let c = rgb(u, v) else { continue }; total += 1; if samePaper(c) { paper += 1 } }
                return total >= 6 ? paper / total : nil
            }
            /// A second sheet under this one shows as a band of paper slightly darker
            /// than the top sheet, between the top sheet's edge and the desk. Walking
            /// in from the paper's end, the top sheet starts where the brightness
            /// steps up sharply and stays up, at the same place along both halves of the side.
            func topSheetStep(_ end: Double) -> Double? {
                func lums(_ d: Double, _ js: ClosedRange<Int>) -> Double? {
                    var v: [Double] = []
                    for j in js { let (u, vv) = point(Double(j) / 8, d); if let c = rgb(u, vv), paperLikelihood(c) > 0.3 { v.append(lum(c)) } }
                    return v.count * 2 > js.count ? v.sorted()[v.count / 2] : nil
                }
                func profile(_ js: ClosedRange<Int>) -> [(Double, Double)] {
                    stride(from: step * 6, to: end - step * 2, by: step).compactMap { d in lums(d, js).map { (d, $0) } }
                }
                /// The steepest fall in brightness going outward that stays down: the
                /// top sheet's edge (often a thin shadow line, then the slightly darker
                /// sheet underneath). Returns the position and the fall.
                func stepAt(_ prof: [(Double, Double)]) -> (Double, Double)? {
                    guard prof.count >= 16 else { return nil }
                    func mean(_ x: ArraySlice<(Double, Double)>) -> Double { x.map(\.1).reduce(0, +) / Double(x.count) }
                    var best: (Double, Double)?
                    for i in 4..<(prof.count - 8) {
                        let fall = mean(prof[(i - 2)...(i - 1)]) - mean(prof[(i + 1)...(i + 2)])
                        let stays = mean(prof[(i - 4)...(i - 1)]) - mean(prof[(i + 1)...min(prof.count - 1, i + 6)])
                        guard fall >= 0.012, stays >= 0.01 else { continue }
                        if best == nil || fall > best!.1 { best = (prof[i].0, fall) }
                    }
                    return best
                }
                if let log = debugLog {
                    for js in [0...4, 4...8] {
                        let p = profile(js)
                        log("side \(side) end \(String(format: "%.3f", end)) half \(js.lowerBound) step \(stepAt(p).map { String(format: "%.3f/%.3f", $0.0, $0.1) } ?? "-") " + stride(from: 0, to: p.count, by: max(1, p.count / 40)).map { String(format: "%.0f", p[$0].1 * 1000) }.joined(separator: " "))
                    }
                }
                guard let a = stepAt(profile(0...4)), let b = stepAt(profile(4...8)), abs(a.0 - b.0) <= step * 6 else { return nil }
                return (a.0 + b.0) / 2
            }
            var d = step * 6, edge: Double?
            while d < 3 {
                d += step
                guard let here = paperFraction(d) else { edge = d; framed += 1; break }   // left the photo: the sheet reaches the frame
                if here <= 0.3, let next = paperFraction(d + step * 3), next <= 0.3 {
                    // A desk goes on; a dark table or bar on the page ends and the
                    // paper comes back. Only the first is the edge of the sheet.
                    let beyond = stride(from: 8.0, through: 40.0, by: 8.0).compactMap { paperFraction(d + step * $0) }
                    guard beyond.allSatisfy({ $0 <= 0.3 }) else { return nil }
                    edge = d; break
                }
            }
            guard let edge else { return nil }
            bounds[side] = base + outward * (topSheetStep(edge) ?? edge)
        }
        // A sheet lying on a desk shows the desk on at least three sides.
        guard framed <= 1 else { return nil }
        let q = ScanQuad(points: [map(bounds[0], bounds[1]), map(bounds[2], bounds[1]), map(bounds[2], bounds[3]), map(bounds[0], bounds[3])]
            .map { ScanPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) })
        return q.valid ? q : nil
    }

    private static func extendToPaperEdges(_ quad: ScanQuad, raster: Raster) -> ScanQuad {
        var p = quad.points
        let span = Double(max(raster.width, raster.height))
        for i in 0..<4 {
            let a = p[i], b = p[(i+1)%4]
            let dx = (b.x-a.x)*Double(raster.width), dy = (b.y-a.y)*Double(raster.height)
            let length = max(1, hypot(dx, dy))
            // Outward unit normal, in normalized units per raster pixel (inside is the
            // opposite direction used by paperEvidence).
            let nx = dy/length/Double(raster.width), ny = -dx/length/Double(raster.height)
            let probe = max(4, span*0.018)
            // The sheet's own color just inside this edge. Paper continues only
            // where the color stays close to it: a light wooden desk is bright
            // and fairly neutral too, but warmer and darker than the sheet.
            var reference = [0.0, 0.0, 0.0], referenceCount = 0.0
            for j in 1...9 {
                let t = Double(j)/10
                let x = a.x+(b.x-a.x)*t-nx*probe, y = a.y+(b.y-a.y)*t-ny*probe
                guard (0...1).contains(x), (0...1).contains(y) else { continue }
                let rgb = raster.pixel(x, y)
                guard paperLikelihood(rgb) > 0.5 else { continue }
                for c in 0..<3 { reference[c] += rgb[c] }
                referenceCount += 1
            }
            guard referenceCount >= 4 else { continue }
            reference = reference.map { $0/referenceCount }
            func samePaper(_ rgb: [Double]) -> Bool {
                guard paperLikelihood(rgb) > 0.5 else { return false }
                let shift = (0..<3).map { rgb[$0]-reference[$0] }
                // Shadows darken all channels together; a different surface changes the hue.
                let mean = shift.reduce(0,+)/3
                let hue = shift.map { abs($0-mean) }.max() ?? 0
                return hue < 0.06 && mean > -0.25
            }
            func paperFraction(_ distance: Double) -> Double? {
                var paper = 0.0, samples = 0.0
                for j in 1...9 {
                    let t = Double(j)/10
                    let x = a.x+(b.x-a.x)*t+nx*distance, y = a.y+(b.y-a.y)*t+ny*distance
                    guard (0...1).contains(x), (0...1).contains(y) else { continue }
                    samples += 1
                    if samePaper(raster.pixel(x, y)) { paper += 1 }
                }
                return samples >= 6 ? paper/samples : nil
            }
            guard let near = paperFraction(probe), near >= 0.75 else { continue }
            var distance = probe, boundary: Double?
            while distance < span {
                distance += 2
                guard let here = paperFraction(distance) else { break }
                if here <= 0.3, let next = paperFraction(distance+3), next <= 0.3 { boundary = distance; break }
            }
            guard let boundary else { continue }
            let shift = max(0, boundary-2)
            for k in [i, (i+1)%4] {
                p[k] = ScanPoint(x: min(1, max(0, p[k].x+nx*shift)), y: min(1, max(0, p[k].y+ny*shift)))
            }
        }
        let extended = ScanQuad(points: p)
        return extended.valid ? extended : quad
    }

    /// Every Vision observation with its paper evidence, accepted or not. `detect`
    /// picks the best accepted one; tests use the full list to explain a crop.
    static func candidates(_ image: CGImage) -> [DetectionCandidate] {
        let handler = VNImageRequestHandler(cgImage: image)
        let document = VNDetectDocumentSegmentationRequest()
        try? handler.perform([document])
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 12
        rectangles.minimumConfidence = 0.7
        rectangles.minimumAspectRatio = 0.2
        rectangles.minimumSize = 0.12
        try? handler.perform([rectangles])
        guard let raster = Raster(image, maximumDimension: 384) else { return [] }
        let observations = (document.results ?? []).map { ($0 as VNRectangleObservation, DetectionKind.document) }
            + (rectangles.results ?? []).map { ($0 as VNRectangleObservation, DetectionKind.rectangle) }
        // A segmentation confidence is not enough: some desks form a large false polygon.
        // Compare paper on the inside with the surroundings just beyond all four edges.
        return observations.compactMap { observation, kind -> DetectionCandidate? in
            let quad = ScanQuad(points: [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft].map {
                ScanPoint(x: Double($0.x), y: 1-Double($0.y))
            })
            guard quad.valid else { return nil }
            let evidence = paperEvidence(quad, raster: raster)
            let supported = evidence.strongEdges >= 2 && evidence.edge > 0.10
            // Near-full-frame sheets may have no visible surroundings. Otherwise real
            // paper boundaries must be present, even for segmentation observations.
            let accepted = acceptableCrop(quad, source: kind, confidence: observation.confidence, boundarySupport: supported)
                && evidence.interior > 0.58
                && (supported || (area(quad) > 0.72 && evidence.interior > 0.82))
            let score = evidence.interior*0.5 + evidence.edge*0.9 + min(area(quad), 0.75)*0.2
            return DetectionCandidate(quad: quad, kind: kind, confidence: observation.confidence, interior: evidence.interior,
                                      edge: evidence.edge, strongEdges: evidence.strongEdges, accepted: accepted, score: score)
        }
    }

    static func area(_ quad: ScanQuad) -> Double {
        guard quad.valid else { return 0 }
        return abs((0..<4).reduce(0.0) { value, i in
            let a = quad.points[i], b = quad.points[(i+1)%4]
            return value + a.x*b.y-b.x*a.y
        }) / 2
    }
    static func acceptableCrop(_ quad: ScanQuad, source: DetectionKind = .rectangle, confidence: Float = 1, boundarySupport: Bool = false) -> Bool {
        guard quad.valid, confidence >= 0.7 else { return false }
        // Small rectangles on paper still need actual paper-boundary evidence. A
        // confidently segmented sheet is allowed to occupy less of the camera frame.
        let minimumArea = boundarySupport || (source == .document && confidence >= 0.8) ? 0.15 : 0.45
        return area(quad) >= minimumArea
    }

    private static func paperEvidence(_ quad: ScanQuad, raster: Raster) -> (interior: Double, edge: Double, strongEdges: Int) {
        let p = quad.points
        var interior = 0.0
        for y in 0..<9 { for x in 0..<7 {
            let u = (Double(x)+0.5)/7, v = (Double(y)+0.5)/9
            let point = ScanPoint(x: (1-v)*((1-u)*p[0].x+u*p[1].x)+v*((1-u)*p[3].x+u*p[2].x),
                                  y: (1-v)*((1-u)*p[0].y+u*p[1].y)+v*((1-u)*p[3].y+u*p[2].y))
            interior += paperLikelihood(raster.pixel(point.x, point.y))
        }}
        var edges = [Double]()
        for i in 0..<4 {
            let a = p[i], b = p[(i+1)%4]
            let dx = (b.x-a.x)*Double(raster.width), dy = (b.y-a.y)*Double(raster.height)
            let length = max(1, hypot(dx, dy))
            let nx = -dy/length/Double(raster.width), ny = dx/length/Double(raster.height)
            let distance = max(4, Double(max(raster.width, raster.height))*0.018)
            var evidence = 0.0, samples = 0.0
            for j in 1...8 {
                let t = Double(j)/9, x = a.x+(b.x-a.x)*t, y = a.y+(b.y-a.y)*t
                let outerX = x-nx*distance, outerY = y-ny*distance
                guard (0...1).contains(outerX), (0...1).contains(outerY) else { continue }
                let inside = paperLikelihood(raster.pixel(x+nx*distance, y+ny*distance))
                let outside = paperLikelihood(raster.pixel(outerX, outerY))
                evidence += max(0, inside-outside); samples += 1
            }
            edges.append(samples > 0 ? evidence/samples : 0)
        }
        return (interior/63, edges.reduce(0,+)/4, edges.filter { $0 > 0.12 }.count)
    }
    private static func paperLikelihood(_ rgb: [Double]) -> Double {
        let high = rgb.max()!, low = rgb.min()!
        let brightness = min(1, max(0, (high-0.25)/0.45))
        let saturation = (high-low)/max(0.01, high)
        let neutral = min(1, max(0, (0.45-saturation)/0.23))
        return brightness*neutral
    }

    struct PreparedDocument {
        var image: CIImage
        var enhancement: Enhancement
    }

    static func render(_ source: CIImage, crop: ScanQuad, turns: Int, enhancement: Enhancement, strength: Double = 1, identityCleanup: Bool = false, alignedOriginal: Bool = false, flatten: FlattenRequest? = nil) throws -> CIImage {
        try finish(prepare(source, crop: crop, turns: turns, enhancement: enhancement, identityCleanup: identityCleanup, alignedOriginal: alignedOriginal, flatten: flatten), strength: strength)
    }

    // Geometry and illumination estimation do not depend on the cleanup slider.
    // Interactive previews can cache this stage without repeatedly running Vision.
    /// `alignedOriginal`: the Original tone with the same grid/line alignment the
    /// cleaned tones get, so the two renderings share their geometry exactly.
    static func prepare(_ source: CIImage, crop: ScanQuad, turns: Int, enhancement: Enhancement, identityCleanup: Bool = false, alignedOriginal: Bool = false, flatten: FlattenRequest? = nil) throws -> PreparedDocument {
        guard crop.valid else { throw ScannerError.message("Check the four crop corners before saving.") }
        var image = source
        // A curled or bent sheet is drawn flat; otherwise the four corners are enough.
        var flattened = false
        if let flatten, !identityCleanup, let mesh = PaperFlatten.mesh(for: source, crop: crop, key: flatten.key), let flat = PaperFlatten.apply(mesh, to: source) {
            image = flat; flattened = true
        } else if crop != .full {
            let f = CIFilter.perspectiveCorrection(); f.inputImage = image
            let p = crop.points.map { CGPoint(x: image.extent.minX + $0.x*image.extent.width, y: image.extent.minY + (1-$0.y)*image.extent.height) }
            f.topLeft = p[0]; f.topRight = p[1]; f.bottomRight = p[2]; f.bottomLeft = p[3]
            guard let corrected = f.outputImage else { throw ScannerError.message("Perspective correction couldn't be applied. Adjust the crop and try again.") }
            image = corrected
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        // Remove the strip of desk/shadow that survives when the crop corners sit a
        // little outside the paper. ID crops have their own edge cleanup below.
        if crop != .full && !identityCleanup && !flattened { image = removeResidualEdges(image) }
        if identityCleanup { image = IdentityBackground.clean(image) }
        if turns % 4 != 0 { image = image.oriented([.up, .right, .down, .left][((turns%4)+4)%4]) }
        guard enhancement != .original || alignedOriginal else { return .init(image: image, enhancement: enhancement) }

        // A correctly cropped sheet can still contain a slanted printed grid,
        // especially when the page was bent or the paper-edge detector was off by
        // a few pixels. Only a large grid with several supported ruling lines is
        // allowed to guide a second perspective correction. Pixels outside that
        // grid stay in the image; this is not a crop to the printed table.
        let alignment = alignPrintedGrid(image)
        image = alignment.grid == nil ? alignTextLines(alignment.image) : alignment.image
        if enhancement == .original { return .init(image: image, enhancement: enhancement) }
        let extent = image.extent
        // Estimate illumination from paper-like pixels. Colored cells and logos do
        // not become the local white reference, even when they fill a large area.
        guard let paper = paperSurface(image, protectedGrid: alignment.grid) else { throw ScannerError.message("Document enhancement couldn't be applied. Try the Original filter.") }
        var flat = paper.surface.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: extent)
        // A small residual cast is still visible on a digital white page. Remove
        // it only where spatial paper evidence agrees, before the tone curve.
        // Printed fills have no paper confidence; dark/faint strokes retain their
        // luminance. This is not global desaturation of the document.
        if let confidence = paper.confidence {
            guard let kernel = paperWhiteKernel,
                  let cleaned = kernel.apply(extent: extent, arguments: [flat, confidence]) else {
                throw ScannerError.message("Paper background cleanup couldn't be applied. Try the Original filter.")
            }
            flat = cleaned
        }
        return .init(image: flat, enhancement: enhancement)
    }

    static func finish(_ prepared: PreparedDocument, strength: Double = 1) throws -> CIImage {
        guard prepared.enhancement != .original else { return prepared.image }
        var flat = prepared.image
        let extent = flat.extent
        let enhancement = prepared.enhancement
        let amount = CGFloat(strength.isFinite ? min(1.5, max(0.5, strength)) : 1)
        // "No shadows" keeps the page as photographed, only with the lighting
        // flattened: a light level stretch and half-strength clarity.
        let gentle = enhancement == .noShadow
        let whitePoint = gentle ? 1.0 - 0.04*amount : 1.0 - 0.12*amount
        // Camera sharpening cannot restore lost detail. A modest black point
        // gives the photographed ink its contrast back without replacing strokes.
        let blackPoint: CGFloat = gentle ? 0.015 + 0.02*amount : 0.035 + 0.07*amount
        if enhancement == .document || enhancement == .enhanced {
            // Paper can be pushed to white; colored content must retain its tonal
            // range instead of having pale blue/yellow cells clipped to white.
            let dimension = 24
            var cube = [Float](); cube.reserveCapacity(dimension*dimension*dimension*4)
            for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
                let rgb = [Float(r),Float(g),Float(b)].map { $0/Float(dimension-1) }
                let high = rgb.max()!, low = rgb.min()!
                let saturation = (high-low)/max(0.01,high)
                let t = min(1,max(0,(saturation-0.008)/0.04))
                let color = t*t*(3-2*t)
                let white = Float(whitePoint)+(1-Float(whitePoint))*color
                for component in rgb { cube.append(min(1,max(0,(component-Float(blackPoint))/(white-Float(blackPoint))))) }
                cube.append(1)
            }}}
            let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
            flat = flat.applyingFilter("CIColorCube",parameters: ["inputCubeDimension": dimension,"inputCubeData": data])
        } else {
            let gain = 1/(whitePoint-blackPoint)
            flat = flat.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain,y: 0,z: 0,w: 0), "inputGVector": CIVector(x: 0,y: gain,z: 0,w: 0),
                "inputBVector": CIVector(x: 0,y: 0,z: gain,w: 0), "inputBiasVector": CIVector(x: -blackPoint*gain,y: -blackPoint*gain,z: -blackPoint*gain,w: 0)
            ])
        }
        switch enhancement {
        case .mono: flat = flat.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.15])
        case .gray: flat = flat.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.0])
        case .enhanced:
            // White paper like Document, with livelier colour and a little more punch.
            flat = flat.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.45*amount])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + 0.12*amount, kCIInputContrastKey: 1 + 0.06*amount])
        default: break
        }
        return try DocumentClarity.enhance(flat, strength: gentle ? amount*0.5 : amount).cropped(to: extent)
    }

    // Vision's document corners come from a coarse mask and often sit a few pixels
    // outside the sheet. After rectification that error becomes a thin strip of
    // desk along one or more sides. A strip is removed only when it touches the
    // outer edge, is clearly not paper (much darker, or colored), ends at a sharp
    // boundary within a few percent of the page and is seen along several parts
    // of that side. Pale gray or tinted printing at the page edge (cover bands,
    // design panels) is paper-like and is kept, as are gradual shading and printing
    // that does not touch the edge. This runs before illumination analysis, so
    // every tone mode, preview, OCR and export share the same geometry.
    struct ResidualEdges: Equatable {
        var top = 0.0, right = 0.0, bottom = 0.0, left = 0.0
        static let untouched = ResidualEdges()
    }
    static let maximumResidualEdge = 0.045

    static func removeResidualEdges(_ image: CIImage) -> CIImage {
        let edges = residualEdges(image)
        guard edges != .untouched else { return image }
        let extent = image.extent
        let x0 = (extent.minX + edges.left*extent.width).rounded(.up)
        let x1 = (extent.maxX - edges.right*extent.width).rounded(.down)
        let y0 = (extent.minY + edges.bottom*extent.height).rounded(.up)
        let y1 = (extent.maxY - edges.top*extent.height).rounded(.down)
        guard x1-x0 >= extent.width*0.85, y1-y0 >= extent.height*0.85 else { return image }
        return image.cropped(to: CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0))
            .transformed(by: CGAffineTransform(translationX: -x0, y: -y0))
    }

    static func residualEdges(_ image: CIImage) -> ResidualEdges {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull, extent.width >= 64, extent.height >= 64 else { return .untouched }
        // Desk strips can be only 2–3 source pixels wide, so keep near-full detail.
        let scale = min(1, 1600/max(extent.width, extent.height))
        let reduced = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Floor the analysis bounds: a fractional extent can rasterize a partially
        // transparent outer row that would look like a dark border.
        let bounds = CGRect(x: 0, y: 0, width: floor(extent.width*scale), height: floor(extent.height*scale))
        guard let cg = context.createCGImage(reduced, from: bounds),
              let raster = Raster(cg, maximumDimension: 1600),
              raster.width >= 32, raster.height >= 32 else { return .untouched }
        let width = raster.width, height = raster.height
        // Only the edge bands are read, so measure pixels on demand.
        func measure(_ index: Int) -> (luminance: Double, saturation: Double) {
            let r = Double(raster.bytes[index*4])/255
            let g = Double(raster.bytes[index*4+1])/255
            let b = Double(raster.bytes[index*4+2])/255
            let high = max(r, max(g, b)), low = min(r, min(g, b))
            return (0.2126*r + 0.7152*g + 0.0722*b, (high-low)/max(0.01, high))
        }
        // side: 0 top, 1 right, 2 bottom, 3 left. `depth` is measured inward from
        // that side, `position` runs along it. Raster rows are top-down.
        func offset(_ side: Int, _ depth: Int, _ position: Int) -> Int {
            switch side {
            case 0: return depth*width + position
            case 1: return position*width + (width-1-depth)
            case 2: return (height-1-depth)*width + position
            default: return position*width + depth
            }
        }
        func trim(_ side: Int) -> Double {
            let alongRows = side == 0 || side == 2
            let length = alongRows ? width : height
            let span = alongRows ? height : width
            let limit = max(3, Int((Double(span)*maximumResidualEdge).rounded(.up)))
            let referenceEnd = min(span/2, limit*2 + 2)
            // Skip the corners, where the neighbouring side's strip is visible.
            let margin = length/20, usable = length - 2*margin, segments = 16
            guard referenceEnd > limit+2, usable >= segments*2 else { return 0 }
            var depths = [Int](), unresolved = 0
            for segment in 0..<segments {
                let start = margin + segment*usable/segments, end = margin + (segment+1)*usable/segments
                var lineLuminance = [Double](), lineSaturation = [Double]()
                lineLuminance.reserveCapacity(referenceEnd); lineSaturation.reserveCapacity(referenceEnd)
                for depth in 0..<referenceEnd {
                    var l = [Double](), s = [Double]()
                    l.reserveCapacity(end-start); s.reserveCapacity(end-start)
                    for position in start..<end {
                        let value = measure(offset(side, depth, position))
                        l.append(value.luminance); s.append(value.saturation)
                    }
                    lineLuminance.append(quantile(l, 0.5)); lineSaturation.append(quantile(s, 0.5))
                }
                // The paper just inside the search band is the local reference.
                let paperLuminance = quantile(Array(lineLuminance[limit..<referenceEnd]), 0.75)
                let paperSaturation = quantile(Array(lineSaturation[limit..<referenceEnd]), 0.25)
                // Surroundings are far darker than the paper or clearly colored.
                // A modestly darker neutral band is printed design, not desk.
                func foreign(_ depth: Int) -> Bool {
                    lineLuminance[depth] < paperLuminance*0.6 || lineSaturation[depth] > paperSaturation + 0.15
                }
                // Only a band that starts at the outer edge can be surroundings.
                guard foreign(0) else { continue }
                var boundary: Int?
                for depth in 1..<limit where !foreign(depth) && !foreign(depth+1) && !foreign(depth+2) {
                    boundary = depth; break
                }
                guard let edge = boundary else { unresolved += 1; continue }
                // A physical paper edge is a sharp step, unlike a gradual shadow.
                let outer = max(0, edge-2), inner = edge+1
                guard lineLuminance[inner] - lineLuminance[outer] >= 0.05
                        || lineSaturation[outer] - lineSaturation[inner] >= 0.10 else { unresolved += 1; continue }
                depths.append(edge)
            }
            guard depths.count >= 3, unresolved <= depths.count else { return 0 }
            depths.sort()
            // The second-deepest segment covers a slanted strip without letting a
            // single dark mark at the edge decide the whole side.
            let deepest = depths.count >= 4 ? depths[depths.count-2] : depths[depths.count-1]
            return min(maximumResidualEdge, Double(deepest+1)/Double(span))
        }
        return ResidualEdges(top: trim(0), right: trim(1), bottom: trim(2), left: trim(3))
    }

    private static func quantile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count-1)*q).rounded())
        return sorted[min(sorted.count-1, max(0, index))]
    }

    struct GridAlignment {
        var image: CIImage
        // Core Image coordinates, used to prevent blue/yellow cells being mistaken
        // for discolored paper when estimating the illumination of the sheet.
        var grid: CGRect?
    }

    static func alignPrintedGrid(_ image: CIImage) -> GridAlignment {
        let extent = image.extent
        let scale = min(1, 1200/max(extent.width, extent.height))
        let reduced = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(reduced, from: reduced.extent),
              let raster = Raster(cg, maximumDimension: 720) else { return .init(image: image, grid: nil) }
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 16
        request.minimumConfidence = 0.85
        request.minimumAspectRatio = 0.25
        request.minimumSize = 0.18
        guard (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil else { return .init(image: image, grid: nil) }
        let candidates = (request.results ?? []).compactMap { result -> ScanQuad? in
            let quad = ScanQuad(points: [result.topLeft, result.topRight, result.bottomRight, result.bottomLeft].map { .init(x: Double($0.x), y: 1-Double($0.y)) })
            guard plausibleGrid(quad, width: extent.width, height: extent.height), ruledRows(quad, raster: raster) >= 5 else { return nil }
            return quad
        }
        guard let quad = candidates.max(by: { area($0) < area($1) }) else { return .init(image: image, grid: nil) }
        let points = quad.points.map { CGPoint(x: extent.minX+$0.x*extent.width, y: extent.minY+(1-$0.y)*extent.height) }
        let correction = CIFilter.perspectiveCorrection()
        correction.inputImage = image
        correction.topLeft = points[0]; correction.topRight = points[1]
        correction.bottomRight = points[2]; correction.bottomLeft = points[3]
        correction.crop = true
        guard let gridExtent = correction.outputImage?.extent else { return .init(image: image, grid: nil) }
        correction.crop = false
        guard let corrected = correction.outputImage,
              boundedPerspective(quad, source: extent, result: corrected.extent) else { return .init(image: image, grid: nil) }
        // Fill only the exposed canvas beyond the photograph. No photographed
        // content is masked, and the source file remains untouched in the library.
        let outputExtent = corrected.extent.integral
        let paper = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: outputExtent)
        let translation = CGAffineTransform(translationX: -outputExtent.minX, y: -outputExtent.minY)
        return .init(image: corrected.composited(over: paper).cropped(to: outputExtent).transformed(by: translation), grid: gridExtent.applying(translation))
    }

    private static func plausibleGrid(_ quad: ScanQuad, width: CGFloat, height: CGFloat) -> Bool {
        guard quad.valid, (0.18...0.9).contains(area(quad)) else { return false }
        let p = quad.points.map { CGPoint(x: $0.x*width, y: $0.y*height) }
        let top = atan2(p[1].y-p[0].y, p[1].x-p[0].x), bottom = atan2(p[2].y-p[3].y, p[2].x-p[3].x)
        let left = atan2(p[3].x-p[0].x, p[3].y-p[0].y), right = atan2(p[2].x-p[1].x, p[2].y-p[1].y)
        let lengths = (0..<4).map { i in hypot(p[(i+1)%4].x-p[i].x, p[(i+1)%4].y-p[i].y) }
        // A real ruled grid can be substantially oblique after an imperfect page
        // crop. Allow that correction, while rejecting severe foreshortening and
        // divergent opposite edges that could magnify unrelated page content.
        return [top,bottom,left,right].allSatisfy { abs($0) <= 25 * .pi/180 }
            && abs(top-bottom) < 20 * .pi/180 && abs(left-right) < 20 * .pi/180
            && (0.55...1.82).contains(lengths[0]/lengths[2])
            && (0.55...1.82).contains(lengths[1]/lengths[3])
    }

    private static func boundedPerspective(_ quad: ScanQuad, source: CGRect, result: CGRect) -> Bool {
        guard !result.isInfinite, !result.isNull,
              result.width.isFinite, result.height.isFinite,
              (0.65...1.65).contains(result.width/source.width),
              (0.65...1.65).contains(result.height/source.height),
              result.width*result.height <= source.width*source.height*2.5 else { return false }
        // A homography may be well behaved inside the grid yet approach its
        // horizon in the margins. Its denominator is linear, so requiring the
        // same sign and bounded variation at all four photograph corners guards
        // the entire image against folds and runaway expansion.
        let p = quad.points
        let dx1 = p[1].x-p[2].x, dx2 = p[3].x-p[2].x
        let dy1 = p[1].y-p[2].y, dy2 = p[3].y-p[2].y
        let sx = p[0].x-p[1].x+p[2].x-p[3].x
        let sy = p[0].y-p[1].y+p[2].y-p[3].y
        let divisor = dx1*dy2-dx2*dy1
        guard abs(divisor) > 0.00001 else { return false }
        let g = (sx*dy2-dx2*sy)/divisor, h = (dx1*sy-sx*dy1)/divisor
        let a = p[1].x-p[0].x+g*p[1].x, b = p[3].x-p[0].x+h*p[3].x
        let d = p[1].y-p[0].y+g*p[1].y, e = p[3].y-p[0].y+h*p[3].y
        // Last row of the inverse 3x3 matrix (its common determinant cancels).
        let iG = d*h-e*g, iH = b*g-a*h, iI = a*e-b*d
        let denominators = [iI, iG+iI, iG+iH+iI, iH+iI]
        guard denominators.allSatisfy({ $0 > 0 }) || denominators.allSatisfy({ $0 < 0 }) else { return false }
        let magnitudes = denominators.map(abs)
        return magnitudes.max()!/magnitudes.min()! < 2.5
    }

    static func alignTextLines(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let scale = min(1, 1200/max(extent.width, extent.height))
        let reduced = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(reduced, from: reduced.extent) else { return image }
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false
        guard (try? VNImageRequestHandler(cgImage: cg).perform([request])) != nil else { return image }
        let lines = (request.results ?? []).compactMap { observation -> (angle: Double, width: Double, y: Double)? in
            let dx = (observation.topRight.x-observation.topLeft.x)*Double(cg.width)
            let dy = (observation.topRight.y-observation.topLeft.y)*Double(cg.height)
            let width = hypot(dx, dy)/Double(cg.width)
            let height = hypot((observation.topLeft.x-observation.bottomLeft.x)*Double(cg.width),
                               (observation.topLeft.y-observation.bottomLeft.y)*Double(cg.height))/Double(cg.height)
            let angle = atan2(dy, dx)
            guard observation.confidence >= 0.7, width >= 0.15, width >= height*3,
                  abs(angle) <= 18 * .pi/180 else { return nil }
            return (angle, width, Double(observation.boundingBox.midY))
        }
        guard lines.count >= 4 else { return image }
        let ordered = lines.map(\.angle).sorted(), median = ordered[ordered.count/2]
        let agreeing = lines.filter { abs($0.angle-median) <= 1.2 * .pi/180 }
        guard agreeing.count >= 4, Double(agreeing.count)/Double(lines.count) >= 0.75,
              agreeing.map(\.width).reduce(0,+) >= 1.2,
              agreeing.map(\.y).max()!-agreeing.map(\.y).min()! >= 0.15 else { return image }
        let weight = agreeing.map(\.width).reduce(0,+)
        let angle = agreeing.reduce(0) { $0+$1.angle*$1.width }/weight
        guard abs(angle) >= 0.3 * .pi/180 else { return image }
        // Consensus text baselines only justify a rigid rotation, not an inferred
        // projective warp. This works without recognizing any particular language.
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: -angle))
        let output = rotated.extent.integral
        let paper = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: output)
        return rotated.composited(over: paper).cropped(to: output)
            .transformed(by: CGAffineTransform(translationX: -output.minX, y: -output.minY))
    }

    private static func ruledRows(_ quad: ScanQuad, raster: Raster) -> Int {
        let p = quad.points
        var runs = 0, wasLine = false
        let rowCount = max(40, Int(hypot((p[3].x-p[0].x)*Double(raster.width), (p[3].y-p[0].y)*Double(raster.height))))
        for row in 1..<rowCount-1 {
            let v = Double(row)/Double(rowCount)
            var support = 0
            for column in 0..<60 {
                let u = (Double(column)+0.5)/60
                let x = (1-v)*((1-u)*p[0].x+u*p[1].x)+v*((1-u)*p[3].x+u*p[2].x)
                let y = (1-v)*((1-u)*p[0].y+u*p[1].y)+v*((1-u)*p[3].y+u*p[2].y)
                // Look within one raster pixel so subpixel ruling lines survive
                // this analysis, but require support across most of the row.
                let dark = (-1...1).contains { offset in
                    let color = raster.pixel(x, y+Double(offset)/Double(raster.height))
                    return color.max()! < 0.65
                }
                if dark { support += 1 }
            }
            let isLine = support >= 40
            if isLine && !wasLine { runs += 1 }
            wasLine = isLine
        }
        return runs
    }

    private struct Raster {
        var width: Int, height: Int, bytes: [UInt8]
        init?(_ image: CGImage, maximumDimension: Int) {
            let scale = min(1, Double(maximumDimension)/Double(max(image.width,image.height)))
            width = max(1, Int(Double(image.width)*scale)); height = max(1, Int(Double(image.height)*scale))
            bytes = [UInt8](repeating: 0, count: width*height*4)
            guard let c = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            c.interpolationQuality = .high
            c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func pixel(_ x: Double, _ y: Double) -> [Double] {
            let ix = min(width-1,max(0,Int(x*Double(width)))), iy = min(height-1,max(0,Int(y*Double(height))))
            let k = (iy*width+ix)*4
            return (0..<3).map { Double(bytes[k+$0])/255 }
        }
    }

    private static let paperWhiteKernel = CIColorKernel(source: """
    kernel vec4 paperWhite(__sample normalized, __sample confidence) {
        vec3 rgb = clamp(normalized.rgb, 0.0, 1.0);
        float high = max(rgb.r, max(rgb.g, rgb.b));
        float low = min(rgb.r, min(rgb.g, rgb.b));
        float saturation = (high-low)/max(0.001, high);
        float nearPaper = 1.0-smoothstep(0.07, 0.18, saturation);
        float brightPaper = smoothstep(0.65, 0.90, low);
        float weight = confidence.r*nearPaper*brightPaper;
        return vec4(mix(rgb, vec3(high), weight), normalized.a);
    }
    """)

    private struct PaperEstimate {
        var surface: CIImage
        var confidence: CIImage?
    }

    private static func paperSurface(_ image: CIImage, protectedGrid: CGRect? = nil) -> PaperEstimate? {
        let extent = image.extent
        let scale = min(1, 512/max(extent.width,extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent), let raster = Raster(cg, maximumDimension: 512) else { return nil }
        let columns = max(8, Int(Double(raster.width)/24)), rows = max(8, Int(Double(raster.height)/24))
        var brightest = [(Double,[Double])]()
        for y in stride(from: 0, to: raster.height, by: 3) { for x in stride(from: 0, to: raster.width, by: 3) {
            let rgb = raster.pixel((Double(x)+0.5)/Double(raster.width),(Double(y)+0.5)/Double(raster.height))
            let high = rgb.max()!
            if high > 0.3 && (high-rgb.min()!)/high < 0.3 { brightest.append((high,rgb)) }
        }}
        guard !brightest.isEmpty else { return PaperEstimate(surface: scalarSurface(image)) }
        brightest.sort { $0.0 > $1.0 }
        let referenceSamples = brightest.prefix(max(1,brightest.count/5))
        let reference = (0..<3).map { channel in referenceSamples.reduce(0.0) { $0+$1.1[channel]/$1.0 }/Double(referenceSamples.count) }
        let paperCasts = edgePaperCasts(raster: raster, columns: columns, rows: rows, reference: reference, protectedGrid: protectedGrid, extent: extent)
        var samples = [[Double]?](repeating: nil, count: columns*rows)
        var paperConfidence = [Bool](repeating: false, count: columns*rows)
        for row in 0..<rows { for column in 0..<columns {
            let x0 = column*raster.width/columns, x1 = (column+1)*raster.width/columns
            let y0 = row*raster.height/rows, y1 = (row+1)*raster.height/rows
            var candidates = [(Double,[Double])]()
            for y in stride(from: y0, to: y1, by: 2) { for x in stride(from: x0, to: x1, by: 2) {
                let rgb = raster.pixel((Double(x)+0.5)/Double(raster.width),(Double(y)+0.5)/Double(raster.height))
                let high = rgb.max()!
                let chroma = rgb.map { $0/max(0.01,high) }
                let chromaDistance = (0..<3).map { abs(chroma[$0]-reference[$0]) }.max()!
                let warmerShadow = chroma[0] >= reference[0]-0.015 && chroma[2] <= reference[2]+0.015
                // Pale blue fills must also be excluded, not only saturated blue.
                let coolOffset = (chroma[2]-chroma[0])-(reference[2]-reference[0])
                let inGrid = protectedGrid?.contains(CGPoint(x: extent.minX+(Double(x)+0.5)/Double(raster.width)*extent.width,
                                                             y: extent.minY+(1-(Double(y)+0.5)/Double(raster.height))*extent.height)) ?? true
                // Outside a verified printed grid a broad cool cast can be paper
                // shadow. Inside it, the exact same blue can be intentional ink.
                let blankPaper = (protectedGrid == nil || !inGrid) && paperCasts[row*columns+column] && (high-rgb.min()!)/max(0.01,high) < 0.38
                let neutralPaper = inGrid && protectedGrid != nil
                    ? coolOffset < 0.015 && chromaDistance < 0.045
                    : coolOffset < 0.025 && (chromaDistance < 0.045 || (warmerShadow && chromaDistance < 0.16 && paperCasts[row*columns+column]))
                let paperChroma = blankPaper || neutralPaper
                if high > 0.25 && paperChroma { candidates.append((high,rgb)) }
            }}
            let available = max(1, (x1-x0)*(y1-y0)/4)
            let tilePoint = CGPoint(x: extent.minX+(Double(column)+0.5)/Double(columns)*extent.width,
                                    y: extent.minY+(1-(Double(row)+0.5)/Double(rows))*extent.height)
            let printedTile = protectedGrid?.contains(tilePoint) == true
            if candidates.count >= max(4,available/8) {
                // The pure-white canvas introduced by perspective correction is
                // not a measurement of the photographed paper beside it.
                let unclipped = candidates.filter { $0.1.min()! < 0.99 }
                if !printedTile && paperCasts[row*columns+column] && unclipped.count >= max(4,available/8) { candidates = unclipped }
                candidates.sort { $0.0 > $1.0 }
                // The brightest quarter overestimates textured paper and leaves
                // colored grain behind. A robust upper-middle band excludes ink
                // without using specular highlights as the local paper color.
                let top = candidates.dropFirst(printedTile ? 0 : candidates.count/5).prefix(max(1,candidates.count/(printedTile ? 4 : 3)))
                samples[row*columns+column] = (0..<3).map { channel in top.reduce(0.0) { $0+$1.1[channel] }/Double(top.count) }
                paperConfidence[row*columns+column] = !printedTile && (candidates.count > available/2 || paperCasts[row*columns+column])
            }
        }}
        let known = samples.indices.filter { samples[$0] != nil }
        // Without enough visible neutral paper, use a scalar estimate that cannot
        // independently normalize R/G/B of colored artwork to white.
        guard known.count >= max(4,samples.count/8) else { return PaperEstimate(surface: scalarSurface(image)) }
        var bytes = [UInt8](repeating: 255, count: columns*rows*4)
        var confidenceBytes = [UInt8](repeating: 255, count: columns*rows*4)
        for row in 0..<rows { for column in 0..<columns {
            let index = row*columns+column
            let value: [Double]
            if let sample = samples[index] { value = sample }
            else {
                let nearest = known.sorted { a,b in
                    let ax = a%columns-column, ay = a/columns-row, bx = b%columns-column, by = b/columns-row
                    return ax*ax+ay*ay < bx*bx+by*by
                }.prefix(12)
                var total = 0.0, sum = [Double](repeating: 0,count: 3)
                for k in nearest {
                    let dx = Double(k%columns-column), dy = Double(k/columns-row)
                    let weight = 1/(0.5+dx*dx+dy*dy); total += weight
                    for channel in 0..<3 { sum[channel] += samples[k]![channel]*weight }
                }
                value = sum.map { $0/total }
            }
            for channel in 0..<3 { bytes[index*4+channel] = UInt8(min(255,max(32,Int(value[channel]*255)))) }
            for channel in 0..<3 { confidenceBytes[index*4+channel] = paperConfidence[index] ? 255 : 0 }
        }}
        func gridImage(_ bytes: [UInt8]) -> CIImage? {
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let grid = CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns*4,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            return CIImage(cgImage: grid).clampedToExtent()
            .applyingFilter("CIGaussianBlur",parameters: [kCIInputRadiusKey: 0.65])
            .cropped(to: CGRect(x: 0,y: 0,width: columns,height: rows))
            .transformed(by: CGAffineTransform(scaleX: extent.width/CGFloat(columns),y: extent.height/CGFloat(rows)))
            .clampedToExtent()
        }
        guard let surface = gridImage(bytes), let confidence = gridImage(confidenceBytes) else { return nil }
        return PaperEstimate(surface: surface, confidence: confidence)
    }

    private static func edgePaperCasts(raster: Raster, columns: Int, rows: Int, reference: [Double], protectedGrid: CGRect?, extent: CGRect) -> [Bool] {
        var eligible = [Bool](repeating: false,count: columns*rows)
        var paperLevels = [Double](repeating: 1,count: columns*rows)
        for row in 0..<rows { for column in 0..<columns {
            let x = (Double(column)+0.5)/Double(columns), y = (Double(row)+0.5)/Double(rows)
            let point = CGPoint(x: extent.minX+x*extent.width,y: extent.minY+(1-y)*extent.height)
            guard protectedGrid?.contains(point) != true else { continue }
            // A center pixel may land on ink or on the added white canvas. Use
            // actual unclipped paper samples across the tile to keep narrow edge
            // shadows connected without letting a single dark stroke decide.
            var colors = [[Double]]()
            for sy in 0..<5 { for sx in 0..<5 {
                let color = raster.pixel((Double(column)+(Double(sx)+0.5)/5)/Double(columns),
                                         (Double(row)+(Double(sy)+0.5)/5)/Double(rows))
                let high = color.max()!, low = color.min()!
                if high > 0.35 && low < 0.99 && (high-low)/high < 0.38 { colors.append(color) }
            }}
            colors.sort { $0.max()! < $1.max()! }
            let rgb = colors.count >= 3 ? colors[colors.count/2] : raster.pixel(x,y)
            let high = rgb.max()!, low = rgb.min()!
            paperLevels[row*columns+column] = low
            let chroma = rgb.map { $0/max(0.01,high) }
            let distance = (0..<3).map { abs(chroma[$0]-reference[$0]) }.max()!
            // Neutral tiles do not connect a bounded pale logo to the page edge.
            eligible[row*columns+column] = high > 0.35 && (high-low)/high < 0.38 && distance > 0.012 && distance < 0.38
        }}
        var visited = [Bool](repeating: false,count: eligible.count), result = visited
        for seed in eligible.indices where eligible[seed] && !visited[seed] {
            var component = [seed], cursor = 0
            visited[seed] = true
            while cursor < component.count {
                let item = component[cursor], x = item%columns,y = item/columns
                for (nx,ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where (0..<columns).contains(nx) && (0..<rows).contains(ny) {
                    let neighbor = ny*columns+nx
                    if eligible[neighbor] && !visited[neighbor] { visited[neighbor] = true; component.append(neighbor) }
                }
                cursor += 1
            }
            // A cast across a page corner is evidence of broad illumination. A
            // bounded colored mark outside the grid is intentionally left alone.
            // The two-cell tolerance allows the new white canvas from rectification.
            let left = component.contains { $0%columns <= 1 }, right = component.contains { $0%columns >= columns-2 }
            let top = component.contains { $0/columns <= 1 }, bottom = component.contains { $0/columns >= rows-2 }
            let width = component.map { $0%columns }.max()! - component.map { $0%columns }.min()! + 1
            let height = component.map { $0/columns }.max()! - component.map { $0/columns }.min()! + 1
            // Rectification can add a white border between the cast and one page
            // edge. A broad gradient reaching a single edge is also illumination;
            // a flat colored strip does not supply this evidence.
            let levels = component.map { paperLevels[$0] }
            let broadGradient = ((top || bottom) && width >= columns/3 || (left || right) && height >= rows/3)
                && levels.max()!-levels.min()! > 0.035
            guard ((left || right) && (top || bottom)) || broadGradient else { continue }
            guard component.count >= (broadGradient ? max(4,eligible.count/60) : max(8,eligible.count/20)) else { continue }
            for item in component { result[item] = true }
        }
        return result
    }

    private static func scalarSurface(_ image: CIImage) -> CIImage {
        // A single brightness reference preserves channel ratios in saturated pages.
        let maximum = image.applyingFilter("CIMaximumComponent")
        let radius = max(8,max(image.extent.width,image.extent.height)*0.025)
        return maximum.clampedToExtent().applyingFilter("CIMorphologyMaximum",parameters: [kCIInputRadiusKey: radius])
            .applyingFilter("CIGaussianBlur",parameters: [kCIInputRadiusKey: radius/3]).cropped(to: image.extent).clampedToExtent()
    }
}
