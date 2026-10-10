import Foundation
import CoreGraphics

/// What the flattening needs to know about a photographed page: the paper's
/// outline, and lines that are straight on the real page (text lines and ruled
/// lines across, ruled lines and bar code bars down).
enum PaperFeatures {
    typealias Pt = SIMD2<Double>

    // MARK: Paper mask

    /// Light, low-saturation pixels joined into the region that holds `seed`,
    /// with holes (the print) filled.
    static func paperMask(_ img: RGBAImage, seed: Pt) -> Plane? {
        var m = Plane(w: img.w, h: img.h)
        for i in 0..<(img.w * img.h) {
            let r = Int(img.px[i * 4]), g = Int(img.px[i * 4 + 1]), b = Int(img.px[i * 4 + 2])
            let mx = max(r, g, b), mn = min(r, g, b)
            let s = mx == 0 ? 0 : (mx - mn) * 255 / mx
            if s < 70 && mx > 140 { m.p[i] = 255 }
        }
        return region(m, seed: seed)
    }

    /// Pixels whose colour is close to the paper's at `seed`, for paper that is not
    /// plain white or lies on a light background with another colour (beige paper
    /// on a dark cloth, a pink receipt on a blue folder). Lightness counts for
    /// little, so shading across the sheet stays paper.
    static func contrastPaperMask(_ img: RGBAImage, seed: Pt) -> Plane? {
        let n = img.w * img.h
        var L = [Float](repeating: 0, count: n), A = [Float](repeating: 0, count: n), B = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let r = Float(img.px[i * 4]), g = Float(img.px[i * 4 + 1]), b = Float(img.px[i * 4 + 2])
            L[i] = 0.3 * r + 0.59 * g + 0.11 * b; A[i] = r - g; B[i] = (r + g) / 2 - b
        }
        // Paper colour: the lighter pixels (not print) around the seed.
        let rw = max(4, img.w / 10), rh = max(4, img.h / 10)
        let sx = min(max(0, Int(seed.x)), img.w - 1), sy = min(max(0, Int(seed.y)), img.h - 1)
        var near: [Int] = []
        for y in max(0, sy - rh)..<min(img.h, sy + rh) { for x in max(0, sx - rw)..<min(img.w, sx + rw) { near.append(y * img.w + x) } }
        guard near.count > 50 else { return nil }
        near.sort { L[$0] < L[$1] }
        let light = near[(near.count * 6 / 10)...]
        func med(_ v: [Float]) -> Float { let s = v.sorted(); return s[s.count / 2] }
        let pl = med(light.map { L[$0] }), pa = med(light.map { A[$0] }), pb = med(light.map { B[$0] })
        guard pl > 90 else { return nil }
        var d = [Int](repeating: 0, count: n)
        var hist = [Int](repeating: 0, count: 256)
        for i in 0..<n {
            let dl = (L[i] - pl) * 0.35, da = A[i] - pa, db = B[i] - pb
            let v = min(255, Int((dl * dl + da * da + db * db).squareRoot()))
            d[i] = v; hist[v] += 1
        }
        // Otsu's split between "paper colour" and "everything else".
        var sum = 0.0; for k in 0..<256 { sum += Double(k * hist[k]) }
        var sumB = 0.0, wB = 0.0, best = 0.0, t = 0
        for k in 0..<256 {
            wB += Double(hist[k]); guard wB > 0 else { continue }
            let wF = Double(n) - wB; if wF <= 0 { break }
            sumB += Double(k * hist[k])
            let mB = sumB / wB, mF = (sum - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > best { best = between; t = k }
        }
        guard t >= 12 else { return nil }   // no clear colour difference to the background
        var m = Plane(w: img.w, h: img.h)
        for i in 0..<n where d[i] <= t && L[i] > pl * 0.55 { m.p[i] = 255 }
        return region(m, seed: seed)
    }

    /// The region of `m` that holds `seed`, cleaned and with holes (the print) filled.
    static func region(_ m0: Plane, seed: Pt) -> Plane? {
        var m = m0
        let side = max(m.w, m.h)
        m = m.open(5, 5)
        let (labels, blobs) = Components.label(m)
        let sx = min(max(0, Int(seed.x)), m.w - 1), sy = min(max(0, Int(seed.y)), m.h - 1)
        var id = Int(labels[sy * m.w + sx])
        if id == 0 {
            // The seed fell on print: take the largest region whose box holds it.
            var best = 0
            for (k, b) in blobs.enumerated() where k > 0 && b.x0 <= sx && sx <= b.x1 && b.y0 <= sy && sy <= b.y1 && b.area > best { best = b.area; id = k }
        }
        guard id > 0 else { return nil }
        var page = Plane(w: m.w, h: m.h)
        for i in 0..<(m.w * m.h) where labels[i] == Int32(id) { page.p[i] = 255 }
        let k = max(5, side / 100)
        page = page.close(k, k)
        // Fill holes: what the outside can't reach is page.
        var outside = Plane(w: m.w, h: m.h)
        var stack: [Int] = []
        for x in 0..<m.w { stack.append(x); stack.append((m.h - 1) * m.w + x) }
        for y in 0..<m.h { stack.append(y * m.w); stack.append(y * m.w + m.w - 1) }
        while let i = stack.popLast() {
            if page.p[i] > 0 || outside.p[i] > 0 { continue }
            outside.p[i] = 255
            let x = i % m.w, y = i / m.w
            if x > 0 { stack.append(i - 1) }; if x < m.w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - m.w) }; if y < m.h - 1 { stack.append(i + m.w) }
        }
        for i in 0..<(m.w * m.h) { page.p[i] = outside.p[i] > 0 ? 0 : 255 }
        return page
    }

    /// Outline of the mask as seen from `center`: the farthest paper pixel along
    /// each of `n` rays, in order around the page.
    static func outline(_ m: Plane, center c: Pt, rays n: Int = 720) -> [Pt] {
        var out: [Pt] = []
        let reach = Double(m.w + m.h)
        for k in 0..<n {
            let a = Double(k) / Double(n) * 2 * Double.pi
            let d = Pt(cos(a), sin(a))
            var last: Pt?
            var t = 0.0
            while t < reach {
                let p = c + d * t
                let x = Int(p.x), y = Int(p.y)
                if x < 0 || y < 0 || x >= m.w || y >= m.h { break }
                if m[x, y] > 0 { last = p }
                t += 1
            }
            if let last { out.append(last) }
        }
        return out
    }

    // MARK: Lines on a page picture (already roughly rectified)

    struct Line { var pts: [Pt]; var weight: Double }

    static func binarize(_ g: Plane) -> Plane {
        let mean = g.boxMean(41)
        var b = Plane(w: g.w, h: g.h)
        for i in 0..<(g.w * g.h) where Int(g.p[i]) < Int(mean.p[i]) - 15 { b.p[i] = 255 }
        return b
    }

    /// Centre of the ink, every `step` along x (or along y for vertical lines).
    static func centerline(_ xs: [Int], _ ys: [Int], from a: Int, to b: Int, step: Int, vertical: Bool = false) -> [Pt] {
        let along = vertical ? ys : xs, across = vertical ? xs : ys
        var buckets: [Int: [Int]] = [:]
        for i in along.indices where along[i] >= a && along[i] <= b { buckets[(along[i] - a) / step, default: []].append(across[i]) }
        var out: [Pt] = []
        for k in buckets.keys.sorted() {
            guard let v0 = buckets[k], v0.count >= 4 else { continue }
            let v = v0.sorted()
            let mid = Double(v[v.count * 15 / 100] + v[v.count * 85 / 100]) / 2
            let t = Double(a + k * step) + Double(step) / 2
            out.append(vertical ? Pt(mid, t) : Pt(t, mid))
        }
        return out
    }

    /// Pixels of each blob, from a label map.
    static func pixels(_ labels: [Int32], _ blobs: [Blob], w: Int, keep: (Int) -> Bool) -> [Int: ([Int], [Int])] {
        var out: [Int: ([Int], [Int])] = [:]
        for (i, l) in labels.enumerated() where l > 0 && keep(Int(l)) {
            out[Int(l), default: ([], [])].0.append(i % w)
            out[Int(l), default: ([], [])].1.append(i / w)
        }
        return out
    }

    /// Long horizontal rules (table lines, underlines).
    static func horizontalRules(_ th: Plane) -> [Line] {
        let W = th.w, H = th.h
        let rules = th.open(Int(Double(W) * 0.06), 1).dilate(15, 3)
        let (labels, blobs) = Components.label(rules)
        let wanted = Set(blobs.indices.filter { $0 > 0 && Double(blobs[$0].width) >= Double(W) * 0.15 && Double(blobs[$0].height) <= Double(H) * 0.025 })
        let px = pixels(labels, blobs, w: W) { wanted.contains($0) }
        return px.compactMap { id, p in
            let b = blobs[id]
            let pts = centerline(p.0, p.1, from: b.x0, to: b.x1, step: max(8, W / 120))
            return pts.count >= 6 ? Line(pts: pts, weight: 2) : nil
        }
    }

    /// Vertical rules and bar code bars.
    static func verticalRules(_ th: Plane) -> [Line] {
        let W = th.w, H = th.h
        let rules = th.open(1, Int(Double(H) * 0.022)).dilate(3, 15)
        let (labels, blobs) = Components.label(rules)
        let wanted = Set(blobs.indices.filter { $0 > 0 && Double(blobs[$0].height) >= Double(H) * 0.028 && Double(blobs[$0].width) <= Double(W) * 0.02 })
        let px = pixels(labels, blobs, w: W) { wanted.contains($0) }
        return px.compactMap { id, p in
            let b = blobs[id]
            let pts = centerline(p.0, p.1, from: b.y0, to: b.y1, step: max(6, H / 200), vertical: true)
            return pts.count >= 5 ? Line(pts: pts, weight: 2) : nil
        }
    }

    /// Text lines: glyphs joined into words, words chained left to right while
    /// they continue each other (so a line that curls up stays one line).
    static func textLines(_ th: Plane) -> [Line] {
        let W = th.w, H = th.h
        let (labels, blobs) = Components.label(th)
        let heights = blobs.indices.dropFirst().compactMap { k -> Int? in
            let b = blobs[k]; return b.height > 4 && Double(b.height) < Double(H) * 0.04 && Double(b.width) < Double(W) * 0.05 && b.area > 8 ? b.height : nil
        }.sorted()
        guard !heights.isEmpty else { return [] }
        let gh = Double(heights[heights.count / 2])
        var glyph = Plane(w: W, h: H)
        var keep = [Bool](repeating: false, count: blobs.count)
        for k in 1..<blobs.count {
            let b = blobs[k]
            // Blurred print joins a word's letters into one blob: allow a long word.
            keep[k] = Double(b.height) > 0.4 * gh && Double(b.height) < 3.5 * gh && Double(b.width) < max(Double(W) * 0.05, 10 * gh) && b.area > 6
        }
        for i in 0..<(W * H) where labels[i] > 0 && keep[Int(labels[i])] { glyph.p[i] = 255 }
        let joined = glyph.close(max(3, Int(gh * 0.9)), 1)
        let (l2, b2) = Components.label(joined)
        // keep glyph pixels only, per word
        var wordPx: [Int: ([Int], [Int])] = [:]
        for i in 0..<(W * H) where l2[i] > 0 && glyph.p[i] > 0 {
            wordPx[Int(l2[i]), default: ([], [])].0.append(i % W)
            wordPx[Int(l2[i]), default: ([], [])].1.append(i / W)
        }
        /// `ly`/`ry`: the line's height at `lx`/`rx`, the middle of each end window.
        struct Word {
            var x0: Int; var x1: Int; var lx: Double; var rx: Double; var ly: Double; var ry: Double; var xs: [Int]; var ys: [Int]
            var slope: Double { rx - lx > 1 ? (ry - ly) / (rx - lx) : 0 }
        }
        var words: [Word] = []
        for (id, p) in wordPx {
            let b = b2[id]
            guard Double(b.width) >= gh * 0.8, p.0.count >= 10 else { continue }
            // A curled or tilted line is tall overall but thin in every column.
            let step = max(4, Int(gh))
            var cols: [Int: (Int, Int)] = [:]
            for i in p.0.indices {
                let k = (p.0[i] - b.x0) / step
                let y = p.1[i]
                if let c = cols[k] { cols[k] = (min(c.0, y), max(c.1, y)) } else { cols[k] = (y, y) }
            }
            let thick = cols.values.map { $0.1 - $0.0 }.sorted()
            guard !thick.isEmpty, Double(thick[thick.count / 2]) <= 2.2 * gh else { continue }
            let q = max(2, min(b.width / 4, Int(2 * gh)))
            func endY(_ sel: (Int) -> Bool) -> Double? {
                let v = p.0.indices.filter { sel(p.0[$0]) }.map { p.1[$0] }.sorted()
                guard !v.isEmpty else { return nil }
                return Double(v[v.count * 15 / 100] + v[v.count * 85 / 100]) / 2
            }
            guard let ly = endY({ $0 < b.x0 + q }), let ry = endY({ $0 >= b.x1 - q }) else { continue }
            words.append(Word(x0: b.x0, x1: b.x1, lx: Double(b.x0) + Double(q) / 2, rx: Double(b.x1) - Double(q) / 2, ly: ly, ry: ry, xs: p.0, ys: p.1))
        }
        words.sort { $0.x0 < $1.x0 }
        // Each word links to the best continuation on its right.
        var bestPred: [Int: (Double, Int)] = [:]
        for i in words.indices {
            var best: (Double, Int)?
            for j in (i + 1)..<words.count {
                let a = words[i], b = words[j]
                let gap = Double(b.x0 - a.x1)
                if gap < -gh * 0.5 || gap > gh * 3.5 { continue }
                // Where a's line, continued at its own slope, meets b (a line that
                // curls up toward a page corner climbs steeply).
                let slope = abs(a.slope) < 0.6 ? a.slope : 0
                let dy = abs(b.ly - (a.ry + slope * (b.lx - a.rx)))
                if dy > gh * 0.8 { continue }
                let cost = gap + dy * 4
                if best == nil || cost < best!.0 { best = (cost, j) }
            }
            if let best, bestPred[best.1] == nil || best.0 < bestPred[best.1]!.0 { bestPred[best.1] = (best.0, i) }
        }
        var next: [Int: Int] = [:]
        for (j, v) in bestPred where next[v.1] == nil { next[v.1] = j }
        let hasPred = Set(next.values)
        var lines: [Line] = []
        for s in words.indices where !hasPred.contains(s) {
            var chain = [s]; var k = s
            while let n = next[k], !chain.contains(n) { chain.append(n); k = n }
            let x0 = words[chain[0]].x0, x1 = words[chain.last!].x1
            guard Double(x1 - x0) >= Double(W) * 0.12 else { continue }
            let xs = chain.flatMap { words[$0].xs }, ys = chain.flatMap { words[$0].ys }
            let pts = centerline(xs, ys, from: x0, to: x1, step: max(8, W / 100))
            if pts.count >= 5 { lines.append(Line(pts: pts, weight: 1)) }
        }
        return lines
    }
}
