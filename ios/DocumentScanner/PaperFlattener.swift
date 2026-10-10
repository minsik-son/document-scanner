import Foundation
import CoreGraphics
import simd

/// The flat page found in a photo: where each point of the page lies in the photo.
/// Points are normalized to the photo (0…1, origin top-left), on a grid that covers
/// the page from its top-left to its bottom-right corner.
struct FlattenMesh: Codable, Equatable {
    var cols: Int
    var rows: Int
    /// x, y pairs, row by row from the top.
    var points: [Float]
    /// Page width / height.
    var aspect: Double
    /// Parts of the page rectangle where there is no paper (a cut or folded-away
    /// corner, the desk past a curled edge), plus a thin rim along the paper's edge:
    /// one byte per cell, 255 = fill with the paper colour.
    var maskCols: Int
    var maskRows: Int
    var missing: Data
    /// The paper's colour in the photo (sRGB 0…1).
    var paper: [Float]
    static let version = 1
}

/// Finds how a photographed sheet bends and how the camera saw it, so the page can
/// be drawn flat: text lines straight across, ruled lines and bar codes straight
/// down, edges straight. The sheet is a smooth surface (a cubic B-spline over the
/// page) seen by a pinhole camera; its shape, the camera pose and the position of
/// every line are solved together (Levenberg–Marquardt).
enum PaperFlattener {
    typealias Pt = SIMD2<Double>
    static let gridSize = 10
    /// Tests only: time spent in each step.
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    /// Tests only: the rough rectification and the lines found on it.
    nonisolated(unsafe) static var traceLines: ((Plane, [[Pt]], [[Pt]]) -> Void)?
    private static func lap(_ name: String, _ t: inout CFAbsoluteTime) {
        guard let trace else { return }
        let now = CFAbsoluteTimeGetCurrent(); trace(String(format: "%@ %.0fms", name, (now - t) * 1000)); t = now
    }

    /// - Parameters:
    ///   - photo: the page photo, about 1400 px on the long side is plenty.
    ///   - crop: the page corners (normalized, top-left origin, clockwise from top-left).
    static func analyze(_ photo: CGImage, crop: ScanQuad) -> FlattenMesh? {
        var t = CFAbsoluteTimeGetCurrent()
        guard let img = RGBAImage(photo), crop.points.count == 4 else { return nil }
        lap("pixels", &t)
        let W = Double(img.w), H = Double(img.h)
        var corners = crop.points.map { Pt($0.x * W, $0.y * H) }
        let center = corners.reduce(Pt(0, 0), +) / 4
        guard let mask = PaperFeatures.paperMask(img, seed: center) else { return nil }
        let outline = PaperFeatures.outline(mask, center: center)
        lap("mask", &t)
        // Sides between the corners, and corners refined from the paper's edges.
        var sides = splitOutline(outline, corners: corners, center: center)
        let diag = hypot(W, H)
        let lines = sides.map { fitLine(Array($0.dropFirst($0.count / 5).dropLast($0.count / 5))) }
        var usable = [Bool](repeating: false, count: 4), outward = [Bool](repeating: false, count: 4)
        for k in 0..<4 {
            guard let l = lines[k], sides[k].count >= 12 else { continue }
            // The outline follows this side of the crop (it isn't a crop inside the paper).
            let a = corners[k], b = corners[(k + 1) % 4]
            let mid = (a + b) / 2
            if distance(l, mid) < diag * 0.03 { usable[k] = true; continue }
            // Or the crop stops short of the paper's edge (a detector that cut off a
            // curled strip): a straight, parallel paper edge a little farther out.
            let side = L(p: a, d: simd_normalize(b - a))
            let beyond = distance(l, center) - distance(side, center)
            let parallel = abs(simd_dot(l.d, side.d)) > cos(10 * Double.pi / 180)
            let body = Array(sides[k].dropFirst(sides[k].count / 5).dropLast(sides[k].count / 5))
            let straight = median(body.map { distance(l, $0) }) < diag * 0.004
            if beyond > 0, beyond < diag * 0.10, parallel, straight { usable[k] = true; outward[k] = true }
        }
        for k in 0..<4 where usable[k] && usable[(k + 3) % 4] {
            let reach = outward[k] || outward[(k + 3) % 4] ? 0.14 : 0.06
            if let l1 = lines[(k + 3) % 4], let l2 = lines[k], let p = intersect(l1, l2), simd_distance(p, corners[k]) < diag * reach { corners[k] = p }
        }
        sides = splitOutline(outline, corners: corners, center: center)
        // Page shape: perspective aspect, snapped to Letter or A4 when close.
        guard var aspect = quadAspect(corners, W: W, H: H) else { return nil }
        for std in [8.5 / 11, 11 / 8.5, 1 / 2.0.squareRoot(), 2.0.squareRoot()] where abs(aspect / std - 1) < 0.06 { aspect = std; break }
        let pw = 1.0, ph = 1.0 / aspect
        // Rough rectification to find the lines.
        let pageToPhoto = homography(from: [Pt(0, 0), Pt(pw, 0), Pt(pw, ph), Pt(0, ph)], to: corners)
        let qW = 1000, qH = max(200, Int(Double(qW) / aspect))
        var rect = Plane(w: qW, h: qH)
        for y in 0..<qH {
            for x in 0..<qW {
                let p = apply(pageToPhoto, Pt((Double(x) + 0.5) / Double(qW) * pw, (Double(y) + 0.5) / Double(qH) * ph))
                rect[x, y] = img.grayAt(p.x, p.y)
            }
        }
        lap("rectify", &t)
        let th = PaperFeatures.binarize(rect)
        lap("binarize", &t)
        let toPhoto = { (q: Pt) -> Pt in apply(pageToPhoto, Pt(q.x / Double(qW) * pw, q.y / Double(qH) * ph)) }
        let acrossRect = (PaperFeatures.textLines(th) + PaperFeatures.horizontalRules(th)).map(\.pts)
        let across = acrossRect.map { $0.map(toPhoto) }
        lap("text", &t)
        let downRect = PaperFeatures.verticalRules(th).map(\.pts)
        let down = downRect.map { $0.map(toPhoto) }
        traceLines?(rect, acrossRect, downRect)
        lap("rules", &t)
        var edges: [(Pt, Int)] = []
        for k in 0..<4 where usable[k] {
            let s = sides[k]
            let a = s.count * 12 / 100, b = s.count * 88 / 100
            guard b > a else { continue }
            let step = max(1, (b - a) / 32)
            for i in stride(from: a, to: b, by: step) { edges.append((s[i], k)) }
        }
        guard across.count + down.count >= 1 || edges.count >= 40 else { return nil }
        let camera = Camera(f: 0.72 * max(W, H), cx: W / 2, cy: H / 2)
        guard var pose = Pose(homography: pageToPhoto, camera: camera) else { return nil }
        let photoToPage = invert(pageToPhoto)
        var solver = Solver(camera: camera, pw: pw, ph: ph, scale: 0.002 * max(W, H))
        // A couple of dozen points per line pin its shape; more only add time.
        func thin(_ l: [Pt]) -> [Pt] { l.count <= 24 ? l : (0..<24).map { l[$0 * (l.count - 1) / 23] } }
        for line in across.map(thin) where line.count >= 4 {
            let page = line.map { apply(photoToPage, $0) }
            solver.addAcross(line, xs: page.map(\.x), y: median(page.map(\.y)))
        }
        for line in down.map(thin) where line.count >= 4 {
            let page = line.map { apply(photoToPage, $0) }
            solver.addDown(line, ys: page.map(\.y), x: median(page.map(\.x)))
        }
        for (p, k) in edges {
            let q = apply(photoToPage, p)
            solver.addEdge(p, side: k, free: k == 0 || k == 2 ? q.x : q.y)
        }
        guard solver.solve(pose: &pose, iterations: 40) else { lap("solve failed", &t); return nil }
        lap("solve", &t)
        let result = mesh(solver: solver, pose: pose, mask: mask, img: img, aspect: aspect)
        lap("mesh", &t)
        trace?(String(format: "aspect %.3f lines %d down %d edges %d obs %d", aspect, across.count, down.count, edges.count, solver.obs.count))
        return result
    }

    /// A curled or bent sheet that rectangle detection misses: the light paper
    /// region in the middle of the photo, its corners where the outline reaches
    /// farthest along the diagonals. Nil when there is no clear sheet on a darker
    /// background.
    static func findPage(_ photo: CGImage) -> ScanQuad? {
        guard let img = RGBAImage(photo, maxSide: 700) else { return nil }
        let center = Pt(Double(img.w) / 2, Double(img.h) / 2)
        // Light, plain paper first; then paper told apart from its background by colour.
        for mask in [PaperFeatures.paperMask(img, seed: center), PaperFeatures.contrastPaperMask(img, seed: center)] {
            if let mask, let quad = pageQuad(mask, center: center) { return quad }
        }
        return nil
    }

    /// The sheet's corners from its mask, when the mask looks like one sheet that
    /// ends inside the photo.
    static func pageQuad(_ mask: Plane, center: Pt) -> ScanQuad? {
        let W = Double(mask.w), H = Double(mask.h)
        let area = Double(mask.p.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }) / (W * H)
        guard area > 0.06, area < 0.9 else { return nil }
        // The paper must end inside the photo on most of its outline.
        let outline = PaperFeatures.outline(mask, center: center)
        guard outline.count > 600 else { return nil }
        let onBorder = outline.filter { $0.x < 3 || $0.y < 3 || $0.x > W - 4 || $0.y > H - 4 }.count
        guard Double(onBorder) / Double(outline.count) < 0.25 else { return nil }
        // A sheet fills most of its own corner quad (a blob of desk does not).
        let dirs = [Pt(-1, -1), Pt(1, -1), Pt(1, 1), Pt(-1, 1)]
        let corners = dirs.map { d in outline.max { simd_dot($0 - center, d) < simd_dot($1 - center, d) }! }
        let quad = ScanQuad(points: corners.map { ScanPoint(x: $0.x / W, y: $0.y / H) })
        guard quad.valid, DocumentProcessing.area(quad) > 0.05, area / DocumentProcessing.area(quad) > 0.75 else { return nil }
        return quad
    }

    // MARK: Output

    static func mesh(solver: Solver, pose: Pose, mask: Plane, img: RGBAImage, aspect: Double) -> FlattenMesh? {
        let W = Double(img.w), H = Double(img.h)
        let cols = 49, rows = max(9, Int((48 / aspect).rounded())) + 1
        var pts = [Float](); pts.reserveCapacity(cols * rows * 2)
        var grid = [Pt]()
        for r in 0..<rows {
            for c in 0..<cols {
                let X = Double(c) / Double(cols - 1) * solver.pw, Y = Double(r) / Double(rows - 1) * solver.ph
                let p = solver.project(X, Y, pose: pose)
                grid.append(p)
                pts.append(Float(p.x / W)); pts.append(Float(p.y / H))
            }
        }
        // No folds: every cell keeps the same orientation and a real size.
        var sign = 0
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let a = grid[r * cols + c], b = grid[r * cols + c + 1], d = grid[(r + 1) * cols + c]
                let cross = (b - a).x * (d - a).y - (b - a).y * (d - a).x
                guard abs(cross) > 0.5, cross.isFinite else { return nil }
                let s = cross > 0 ? 1 : -1
                if sign == 0 { sign = s } else if s != sign { return nil }
            }
        }
        // Where the page has no paper, and the rim along the paper's edge.
        let mcols = aspect >= 1 ? 192 : max(32, Int(192 * aspect)), mrows = aspect >= 1 ? max(32, Int(192 / aspect)) : 192
        var missing = Plane(w: mcols, h: mrows)
        for r in 0..<mrows {
            for c in 0..<mcols {
                let X = (Double(c) + 0.5) / Double(mcols) * solver.pw, Y = (Double(r) + 0.5) / Double(mrows) * solver.ph
                let p = solver.project(X, Y, pose: pose)
                let x = Int(p.x), y = Int(p.y)
                let paper = x >= 0 && y >= 0 && x < mask.w && y < mask.h && mask[x, y] > 0
                missing[c, r] = paper ? 0 : 255
            }
        }
        missing = edgeGaps(missing)
        let rim = max(1, Int((Double(min(mcols, mrows)) * 0.012).rounded()))
        missing = missing.dilate(2 * rim + 1, 2 * rim + 1)
        // Paper colour: the bright half of the paper pixels.
        var lum: [(Int, Int)] = []
        let stride = max(1, mask.w * mask.h / 60000)
        for i in Swift.stride(from: 0, to: mask.w * mask.h, by: stride) where mask.p[i] > 0 {
            let l = Int(img.px[i * 4]) * 77 + Int(img.px[i * 4 + 1]) * 150 + Int(img.px[i * 4 + 2]) * 29
            lum.append((l, i))
        }
        guard lum.count > 100 else { return nil }
        lum.sort { $0.0 < $1.0 }
        let bright = lum[(lum.count * 55 / 100)...]
        var rgb = [Double](repeating: 0, count: 3)
        let band = Array(bright.prefix(max(1, bright.count * 6 / 10)))
        for (_, i) in band { for k in 0..<3 { rgb[k] += Double(img.px[i * 4 + k]) } }
        let paper = rgb.map { Float($0 / Double(band.count) / 255) }
        return FlattenMesh(cols: cols, rows: rows, points: pts, aspect: aspect, maskCols: mcols, maskRows: mrows, missing: Data(missing.p), paper: paper)
    }

    /// Paper is missing only where a corner was cut off or curled out of view:
    /// gaps along the page's edge. A paper mask that missed dense or dark print
    /// would otherwise paint over the page itself, so gaps inside the page, or
    /// more than a small share of it, are not filled at all.
    static func edgeGaps(_ m: Plane) -> Plane {
        let w = m.w, h = m.h
        let bandX = max(2, w * 15 / 100), bandY = max(2, h * 15 / 100)
        var near = Plane(w: w, h: h)
        for y in 0..<h { for x in 0..<w where m[x, y] > 0 && (x < bandX || x >= w - bandX || y < bandY || y >= h - bandY) { near[x, y] = 255 } }
        // Keep the gaps that reach the page's edge.
        var out = Plane(w: w, h: h)
        var stack: [Int] = []
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let i = stack.popLast() {
            guard near.p[i] > 0, out.p[i] == 0 else { continue }
            out.p[i] = 255
            let x = i % w, y = i / w
            if x > 0 { stack.append(i - 1) }; if x < w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }; if y < h - 1 { stack.append(i + w) }
        }
        let share = Double(out.p.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }) / Double(w * h)
        return share > 0.10 ? Plane(w: w, h: h) : out
    }

    // MARK: Geometry helpers

    static func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

    /// Outline points between consecutive corners, by angle around the centre.
    static func splitOutline(_ outline: [Pt], corners: [Pt], center: Pt) -> [[Pt]] {
        func angle(_ p: Pt) -> Double { atan2(p.y - center.y, p.x - center.x) }
        var sides: [[Pt]] = [[], [], [], []]
        let ca = corners.map(angle)
        for p in outline {
            let a = angle(p)
            for k in 0..<4 {
                var lo = ca[k], hi = ca[(k + 1) % 4]
                if hi < lo { hi += 2 * .pi }
                var x = a; if x < lo { x += 2 * .pi }
                if x >= lo && x < hi { sides[k].append(p); break }
            }
        }
        // order each side from its first corner to the next
        for k in 0..<4 {
            let a = corners[k]
            sides[k].sort { simd_distance($0, a) < simd_distance($1, a) }
        }
        return sides
    }

    struct L { var p: Pt; var d: Pt }
    /// Least-squares line with Huber weights.
    static func fitLine(_ pts: [Pt]) -> L? {
        guard pts.count >= 4 else { return nil }
        var w = [Double](repeating: 1, count: pts.count)
        var line: L?
        for _ in 0..<5 {
            let sw = w.reduce(0, +)
            let c = zip(pts, w).reduce(Pt(0, 0)) { $0 + $1.0 * $1.1 } / sw
            var sxx = 0.0, sxy = 0.0, syy = 0.0
            for (p, wi) in zip(pts, w) { let d = p - c; sxx += wi * d.x * d.x; sxy += wi * d.x * d.y; syy += wi * d.y * d.y }
            let theta = 0.5 * atan2(2 * sxy, sxx - syy)
            let d = Pt(cos(theta), sin(theta))
            line = L(p: c, d: d)
            let res = pts.map { abs(($0 - c).x * d.y - ($0 - c).y * d.x) }
            let s = max(1, median(res) * 1.4826)
            w = res.map { $0 <= 1.5 * s ? 1 : 1.5 * s / $0 }
        }
        return line
    }
    static func distance(_ l: L, _ p: Pt) -> Double { abs((p - l.p).x * l.d.y - (p - l.p).y * l.d.x) }
    static func intersect(_ a: L, _ b: L) -> Pt? {
        let det = a.d.x * (-b.d.y) - a.d.y * (-b.d.x)
        guard abs(det) > 1e-9 else { return nil }
        let r = b.p - a.p
        let t = (r.x * (-b.d.y) - r.y * (-b.d.x)) / det
        return a.p + t * a.d
    }

    /// Width / height of the rectangle a perspective quad shows (Zhang & He), or nil.
    static func quadAspect(_ c: [Pt], W: Double, H: Double) -> Double? {
        let u0 = W / 2, v0 = H / 2
        func v(_ p: Pt) -> SIMD3<Double> { SIMD3(p.x, p.y, 1) }
        let m1 = v(c[3]), m2 = v(c[2]), m3 = v(c[0]), m4 = v(c[1])
        let k2 = simd_dot(simd_cross(m1, m4), m3) / simd_dot(simd_cross(m2, m4), m3)
        let k3 = simd_dot(simd_cross(m1, m4), m2) / simd_dot(simd_cross(m3, m4), m2)
        let n2 = k2 * m2 - m1, n3 = k3 * m3 - m1
        // The focal length is the phone camera's (as in the solver): solving for it
        // from the four corners (Zhang & He) is unstable when opposite sides are
        // nearly parallel, which is the usual case.
        let f = 0.72 * max(W, H)
        let Ai = simd_double3x3(rows: [SIMD3(1 / f, 0, -u0 / f), SIMD3(0, 1 / f, -v0 / f), SIMD3(0, 0, 1)])
        let a = Ai * n2, b = Ai * n3
        let r = simd_length(a) / simd_length(b)
        return r.isFinite && r > 0.2 && r < 5 ? r : nil
    }

    /// 3×3 homography taking `from` to `to` (four points).
    static func homography(from s: [Pt], to d: [Pt]) -> simd_double3x3 {
        var A = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = s[i].x, y = s[i].y, u = d[i].x, v = d[i].y
            A[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            A[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        // Gaussian elimination on the 8×9 augmented matrix.
        for c in 0..<8 {
            var p = c
            for r in c..<8 where abs(A[r][c]) > abs(A[p][c]) { p = r }
            A.swapAt(c, p)
            let piv = A[c][c]
            if abs(piv) < 1e-12 { continue }
            for k in c..<9 { A[c][k] /= piv }
            for r in 0..<8 where r != c {
                let f = A[r][c]
                if f != 0 { for k in c..<9 { A[r][k] -= f * A[c][k] } }
            }
        }
        let h = (0..<8).map { A[$0][8] }
        return simd_double3x3(rows: [SIMD3(h[0], h[1], h[2]), SIMD3(h[3], h[4], h[5]), SIMD3(h[6], h[7], 1)])
    }
    static func apply(_ m: simd_double3x3, _ p: Pt) -> Pt {
        let q = m * SIMD3(p.x, p.y, 1)
        return Pt(q.x / q.z, q.y / q.z)
    }
    static func invert(_ m: simd_double3x3) -> simd_double3x3 { m.inverse }
}

// MARK: - Camera and pose

struct Camera { var f: Double; var cx: Double; var cy: Double }

struct Pose {
    var r: SIMD3<Double>
    var t: SIMD3<Double>
    var R: simd_double3x3 { Pose.rotation(r) }
    init(r: SIMD3<Double>, t: SIMD3<Double>) { self.r = r; self.t = t }
    /// From the homography that maps the flat page (z = 0) into the photo.
    init?(homography Hm: simd_double3x3, camera c: Camera) {
        let Kinv = simd_double3x3(rows: [SIMD3(1 / c.f, 0, -c.cx / c.f), SIMD3(0, 1 / c.f, -c.cy / c.f), SIMD3(0, 0, 1)])
        let M = Kinv * Hm
        var c1 = M.columns.0, c2 = M.columns.1, c3 = M.columns.2
        let l = (simd_length(c1) + simd_length(c2)) / 2
        guard l > 1e-12 else { return nil }
        c1 /= l; c2 /= l; c3 /= l
        if c3.z < 0 { c1 = -c1; c2 = -c2; c3 = -c3 }
        let r1 = simd_normalize(c1)
        var r2 = c2 - simd_dot(c2, r1) * r1; r2 = simd_normalize(r2)
        let r3 = simd_cross(r1, r2)
        let R = simd_double3x3(columns: (r1, r2, r3))
        self.init(r: Pose.log(R), t: c3)
    }
    static func rotation(_ r: SIMD3<Double>) -> simd_double3x3 {
        let th = simd_length(r)
        guard th > 1e-12 else { return matrix_identity_double3x3 }
        let k = r / th
        let K = simd_double3x3(rows: [SIMD3(0, -k.z, k.y), SIMD3(k.z, 0, -k.x), SIMD3(-k.y, k.x, 0)])
        return matrix_identity_double3x3 + sin(th) * K + (1 - cos(th)) * (K * K)
    }
    static func log(_ R: simd_double3x3) -> SIMD3<Double> {
        let c = max(-1, min(1, (R.columns.0.x + R.columns.1.y + R.columns.2.z - 1) / 2))
        let th = acos(c)
        guard th > 1e-9 else { return .zero }
        let v = SIMD3(R.columns.1.z - R.columns.2.y, R.columns.2.x - R.columns.0.z, R.columns.0.y - R.columns.1.x)
        return v * (th / (2 * sin(th)))
    }
}
