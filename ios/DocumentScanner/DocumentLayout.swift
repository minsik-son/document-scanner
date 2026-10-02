import Foundation

// Page layout reconstruction for Office export. Works on the scanned page
// pixels plus recognized words, and produces a format-neutral description
// (paragraphs, ruled and borderless tables, graphics) that the Word, Excel
// and PowerPoint writers share. Pure Foundation: no UIKit or Vision.

struct LBox: Codable, Equatable {
    var x0: Double, y0: Double, x1: Double, y1: Double
    init(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    var width: Double { x1 - x0 }
    var height: Double { y1 - y0 }
    var midX: Double { (x0 + x1) / 2 }
    var midY: Double { (y0 + y1) / 2 }
    func union(_ o: LBox) -> LBox { LBox(min(x0, o.x0), min(y0, o.y0), max(x1, o.x1), max(y1, o.y1)) }
    func overlapX(_ o: LBox) -> Double { max(0, min(x1, o.x1) - max(x0, o.x0)) }
    func overlapY(_ o: LBox) -> Double { max(0, min(y1, o.y1) - max(y0, o.y0)) }
    func contains(x: Double, y: Double) -> Bool { x >= x0 && x <= x1 && y >= y0 && y <= y1 }
    func inset(_ d: Double) -> LBox { LBox(x0 + d, y0 + d, x1 - d, y1 - d) }
    static func around(_ boxes: [LBox]) -> LBox? {
        guard var r = boxes.first else { return nil }
        for b in boxes.dropFirst() { r = r.union(b) }
        return r
    }
}

struct LayoutColor: Codable, Equatable, Hashable {
    var r: UInt8, g: UInt8, b: UInt8
    var hex: String { String(format: "%02X%02X%02X", r, g, b) }
    static let black = LayoutColor(r: 0, g: 0, b: 0)
}

enum LayoutAlignment: String, Codable { case left, center, right }

struct LayoutRun: Codable, Equatable {
    var text: String
    var bold = false
    var underline = false
    var color: LayoutColor? = nil
}

/// Words on one baseline. Several segments on a line are separated by large
/// gaps and become tab stops (Word) or separate cells (Excel).
struct LayoutSegment: Codable, Equatable {
    var runs: [LayoutRun]
    var box: LBox
    var fontSize: Double? = nil
    var text: String { runs.map(\.text).joined() }
}
struct LayoutLine: Codable, Equatable {
    var segments: [LayoutSegment]
    var box: LBox
    /// True when the next line continues this one because the text wrapped.
    var wraps = false
    var text: String { segments.map(\.text).joined(separator: "\t") }
}
struct LayoutParagraph: Codable, Equatable {
    var lines: [LayoutLine]
    var box: LBox
    var fontSize: Double          // points
    var alignment: LayoutAlignment
    var bullet: LBox? = nil       // position of the bullet glyph, if any
    var letterSpacing: Double = 0 // points of extra spacing between characters
    /// Distance between baselines in pixels (single line: estimated).
    var linePitch: Double
}

struct LayoutCell: Codable, Equatable {
    var row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1
    var box: LBox
    var lines: [[LayoutRun]] = []
    var fontSize: Double = 10
    var alignment: LayoutAlignment = .left
    var fill: LayoutColor? = nil
    var letterSpacing: Double = 0
    var top = true, left = true, bottom = true, right = true
    var text: String { lines.map { $0.map(\.text).joined() }.joined(separator: "\n") }
}
struct LayoutTable: Codable, Equatable {
    var columns: [Double]   // x boundaries, count = columnCount + 1
    var rows: [Double]      // y boundaries, count = rowCount + 1
    var cells: [LayoutCell]
    var ruled: Bool
    var box: LBox { LBox(columns.first ?? 0, rows.first ?? 0, columns.last ?? 0, rows.last ?? 0) }
    var rowCount: Int { rows.count - 1 }
    var columnCount: Int { columns.count - 1 }
    func cell(row: Int, column: Int) -> LayoutCell? { cells.first { $0.row == row && $0.column == column } }
}
/// A picture cut from the scan. `cutout` keeps only the ink (transparent paper),
/// used for rules and line art so the picture never hides text.
struct LayoutGraphic: Codable, Equatable {
    var box: LBox
    var cutout: Bool
    /// PNG of the region, filled in by the platform layer after analysis.
    var png: Data? = nil
}

enum LayoutItem: Codable, Equatable {
    case paragraph(LayoutParagraph)
    case table(LayoutTable)
    var box: LBox {
        switch self {
        case .paragraph(let p): return p.box
        case .table(let t): return t.box
        }
    }
}

struct PageLayout: Codable, Equatable {
    var width: Int, height: Int       // pixels
    var pageWidth: Double, pageHeight: Double  // points
    var items: [LayoutItem]
    var graphics: [LayoutGraphic]
    var pointsPerPixel: Double { pageWidth / Double(width) }
    var contentBox: LBox {
        LBox.around(items.map(\.box) + graphics.map(\.box)) ?? LBox(0, 0, Double(width), Double(height))
    }
}

/// RGBA pixels, row-major, top-left origin.
struct LayoutRaster {
    let width: Int, height: Int
    let rgba: [UInt8]
    init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count >= width * height * 4)
        self.width = width; self.height = height; self.rgba = rgba
    }
    @inline(__always) func lum(_ x: Int, _ y: Int) -> Int {
        let i = (y * width + x) * 4
        return (Int(rgba[i]) * 299 + Int(rgba[i + 1]) * 587 + Int(rgba[i + 2]) * 114) / 1000
    }
    @inline(__always) func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
    }
}

enum DocumentLayoutAnalyzer {
    // MARK: Words
    struct Word {
        var text: String
        var box: LBox
        var spaceBefore: Bool
        var bold = false
        var underline = false
        var color: LayoutColor? = nil
    }

    /// Converts recognized lines to pixel words and restores the spaces that
    /// separated them in the recognized line.
    static func words(_ blocks: [TextBlock], width: Int, height: Int) -> [[Word]] {
        let w = Double(width), h = Double(height)
        var lines: [[Word]] = []
        for block in blocks {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Isolated punctuation is usually a speck or a stray pen mark.
            if trimmed.count <= 2 && !trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) && !bulletGlyphs.contains(trimmed) { continue }
            let parts = block.words ?? [TextWord(text: block.text, x: block.x, y: block.y, width: block.width, height: block.height)]
            var cursor = block.text.startIndex
            var line: [Word] = []
            for part in parts {
                var space = false
                if let range = block.text.range(of: part.text, range: cursor..<block.text.endIndex) {
                    space = block.text[cursor..<range.lowerBound].contains { $0.isWhitespace }
                    cursor = range.upperBound
                }
                let box = LBox(part.x * w, part.y * h, (part.x + part.width) * w, (part.y + part.height) * h)
                guard box.width > 0, box.height > 0 else { continue }
                line.append(Word(text: part.text, box: box, spaceBefore: space && !line.isEmpty))
            }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
    static let bulletGlyphs: Set<String> = ["•", "●", "▪", "◦", "‣", "·", "∙", "■", "□", "➢", "►", "-", "–", "*"]

    // MARK: Pixel analysis
    struct Ink {
        let raster: LayoutRaster
        var dark: [Bool]
        let paper: (Double, Double, Double)
        var ptPerPx = 1.0
        init(_ raster: LayoutRaster) {
            self.raster = raster
            var histogram = [Int](repeating: 0, count: 256)
            let step = max(1, raster.width * raster.height / 400_000)
            var samples: [(Int, Int, Int, Int)] = []
            var i = 0
            while i < raster.width * raster.height {
                let x = i % raster.width, y = i / raster.width
                let l = raster.lum(x, y); histogram[l] += 1
                let c = raster.color(x, y); samples.append((l, c.0, c.1, c.2))
                i += step
            }
            // Paper is the bright majority; average the top 30% of samples.
            var cumulative = 0, cut = 255
            let target = samples.count * 30 / 100
            for l in stride(from: 255, through: 0, by: -1) { cumulative += histogram[l]; if cumulative >= target { cut = l; break } }
            let bright = samples.filter { $0.0 >= cut }
            let n = Double(max(1, bright.count))
            paper = (bright.reduce(0) { $0 + Double($1.1) } / n, bright.reduce(0) { $0 + Double($1.2) } / n, bright.reduce(0) { $0 + Double($1.3) } / n)
            let paperLum = paper.0 * 0.299 + paper.1 * 0.587 + paper.2 * 0.114
            let threshold = Int(min(115, paperLum * 0.48))
            var mask = [Bool](repeating: false, count: raster.width * raster.height)
            for y in 0..<raster.height { for x in 0..<raster.width where raster.lum(x, y) < threshold { mask[y * raster.width + x] = true } }
            dark = mask
        }
        @inline(__always) func isDark(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < raster.width && y < raster.height && dark[y * raster.width + x]
        }
        /// Maps a scanned color to the printed color by removing the paper tint.
        func normalized(_ c: (Double, Double, Double)) -> LayoutColor {
            func f(_ v: Double, _ p: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255 / max(80, p)).rounded()))) }
            return LayoutColor(r: f(c.0, paper.0), g: f(c.1, paper.1), b: f(c.2, paper.2))
        }
        /// Average paper-side color in a box, ignoring ink.
        func fill(_ box: LBox) -> LayoutColor? {
            let b = box.inset(min(box.width, box.height) * 0.12)
            guard b.width > 2, b.height > 2 else { return nil }
            var r = 0.0, g = 0.0, bl = 0.0, n = 0.0
            let sx = max(1, Int(b.width / 40)), sy = max(1, Int(b.height / 20))
            for y in stride(from: Int(b.y0), to: Int(b.y1), by: sy) {
                for x in stride(from: Int(b.x0), to: Int(b.x1), by: sx) where !isDark(x, y) {
                    let c = raster.color(x, y); r += Double(c.0); g += Double(c.1); bl += Double(c.2); n += 1
                }
            }
            guard n > 8 else { return nil }
            let c = normalized((r / n, g / n, bl / n))
            return c
        }
        /// Decides whether a measured cell color is a real fill and restores the
        /// saturation that scanning removes from light tints.
        static func printedFill(_ c: LayoutColor, merged: Bool) -> LayoutColor? {
            let maxC = Int(max(c.r, c.g, c.b)), minC = Int(min(c.r, c.g, c.b)), chroma = maxC - minC
            // Uneven lighting tints single cells slightly; merged label cells
            // and strong colors are deliberate.
            let tinted = chroma >= 22 || (chroma >= 10 && merged)
            let gray = chroma < 10 && maxC <= 236
            guard (tinted && minC < 250) || gray else { return nil }
            let lightness = Double(maxC + minC) / 510
            let factor = tinted ? 1 + 0.8 * max(0, min(1, (lightness - 0.7) / 0.25)) : 1
            func boost(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, (255 - (255 - Double(v)) * factor).rounded()))) }
            return LayoutColor(r: boost(c.r), g: boost(c.g), b: boost(c.b))
        }
        /// Fraction of a horizontal or vertical path that has ink within ±tolerance.
        func coverage(horizontal y: Double, from x0: Double, to x1: Double, tolerance: Int) -> Double {
            let a = Int(x0), b = Int(x1), yy = Int(y.rounded())
            guard b > a else { return 0 }
            var hit = 0, total = 0
            for x in stride(from: a, to: b, by: 2) {
                total += 1
                for d in -tolerance...tolerance where isDark(x, yy + d) { hit += 1; break }
            }
            return Double(hit) / Double(max(1, total))
        }
        func coverage(vertical x: Double, from y0: Double, to y1: Double, tolerance: Int) -> Double {
            let a = Int(y0), b = Int(y1), xx = Int(x.rounded())
            guard b > a else { return 0 }
            var hit = 0, total = 0
            for y in stride(from: a, to: b, by: 2) {
                total += 1
                for d in -tolerance...tolerance where isDark(xx + d, y) { hit += 1; break }
            }
            return Double(hit) / Double(max(1, total))
        }
        /// Vertical extent of ink inside a box.
        func inkRows(_ box: LBox) -> (Double, Double)? {
            let x0 = max(0, Int(box.x0)), x1 = min(raster.width, Int(box.x1))
            let y0 = max(0, Int(box.y0 - box.height * 0.1)), y1 = min(raster.height, Int(box.y1 + box.height * 0.1))
            guard x1 > x0, y1 > y0 else { return nil }
            var top: Int?, bottom: Int?
            let minInk = max(1, (x1 - x0) / 120)
            for y in y0..<y1 {
                var count = 0
                for x in x0..<x1 where dark[y * raster.width + x] { count += 1; if count >= minInk { break } }
                if count >= minInk { if top == nil { top = y }; bottom = y }
            }
            guard let t = top, let b = bottom, b > t else { return nil }
            return (Double(t), Double(b + 1))
        }
        /// Horizontal extent of ink in the middle band of a box.
        func inkColumns(_ box: LBox) -> (Double, Double)? {
            let x0 = max(0, Int(box.x0)), x1 = min(raster.width, Int(box.x1))
            let y0 = max(0, Int(box.y0 + box.height * 0.15)), y1 = min(raster.height, Int(box.y1 - box.height * 0.15))
            guard x1 > x0, y1 > y0 else { return nil }
            var left: Int?, right: Int?
            for x in x0..<x1 { for y in y0..<y1 where dark[y * raster.width + x] { if left == nil { left = x }; right = x; break } }
            guard let l = left, let r = right, r >= l, Double(r - l + 1) >= box.width * 0.35 else { return nil }
            return (Double(l), Double(r + 1))
        }
        /// Average stroke width (2 × area / perimeter) of the ink in a box.
        func strokeWidth(_ box: LBox) -> Double? {
            let x0 = max(1, Int(box.x0)), x1 = min(raster.width - 1, Int(box.x1))
            let y0 = max(1, Int(box.y0)), y1 = min(raster.height - 1, Int(box.y1))
            guard x1 > x0, y1 > y0 else { return nil }
            var area = 0, edge = 0
            let w = raster.width
            for y in y0..<y1 { for x in x0..<x1 where dark[y * w + x] {
                area += 1
                if !dark[y * w + x - 1] || !dark[y * w + x + 1] || !dark[(y - 1) * w + x] || !dark[(y + 1) * w + x] { edge += 1 }
            } }
            guard area >= 20, edge > 0 else { return nil }
            return 2 * Double(area) / Double(edge)
        }
        func inkColor(_ box: LBox) -> LayoutColor? {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in stride(from: Int(box.y0), to: Int(box.y1), by: 2) {
                for x in stride(from: Int(box.x0), to: Int(box.x1), by: 2) where isDark(x, y) {
                    let c = raster.color(x, y); r += Double(c.0); g += Double(c.1); b += Double(c.2); n += 1
                }
            }
            guard n > 10 else { return nil }
            let c = (r / n, g / n, b / n)
            let spread = max(c.0, c.1, c.2) - min(c.0, c.1, c.2)
            if spread < 45 { return nil } // neutral ink prints as black
            return normalized(c)
        }
    }

    // MARK: Ruling lines
    struct Segment { var a0: Double; var a1: Double; var c: Double; var thickness: Double } // along, along, cross, thickness

    static func horizontalSegments(_ ink: Ink, minLength: Int) -> [Segment] {
        let w = ink.raster.width, h = ink.raster.height
        var open: [(x0: Int, x1: Int, y0: Int, y1: Int, last: Int)] = []
        var done: [Segment] = []
        for y in 0..<h {
            var runs: [(Int, Int)] = []
            var start = -1, gap = 0
            for x in 0..<w {
                if ink.dark[y * w + x] { if start < 0 { start = x }; gap = 0 }
                else if start >= 0 {
                    gap += 1
                    if gap > 2 { if x - gap - start + 1 >= minLength { runs.append((start, x - gap)) }; start = -1; gap = 0 }
                }
            }
            if start >= 0, w - start >= minLength { runs.append((start, w - 1)) }
            var next: [(x0: Int, x1: Int, y0: Int, y1: Int, last: Int)] = []
            var used = [Bool](repeating: false, count: runs.count)
            for s in open {
                if let i = runs.indices.first(where: { !used[$0] && min(runs[$0].1, s.x1) - max(runs[$0].0, s.x0) > min(runs[$0].1 - runs[$0].0, s.x1 - s.x0) / 2 }) {
                    used[i] = true
                    next.append((min(s.x0, runs[i].0), max(s.x1, runs[i].1), s.y0, y, y))
                } else if y - s.last <= 2 { next.append(s) }
                else { done.append(Segment(a0: Double(s.x0), a1: Double(s.x1 + 1), c: Double(s.y0 + s.y1 + 1) / 2, thickness: Double(s.y1 - s.y0 + 1))) }
            }
            for (i, r) in runs.enumerated() where !used[i] { next.append((r.0, r.1, y, y, y)) }
            open = next
        }
        for s in open { done.append(Segment(a0: Double(s.x0), a1: Double(s.x1 + 1), c: Double(s.y0 + s.y1 + 1) / 2, thickness: Double(s.y1 - s.y0 + 1))) }
        let maxThickness = max(10.0, Double(h) * 0.006)
        return done.filter { $0.thickness <= maxThickness }
    }
    static func verticalSegments(_ ink: Ink, minLength: Int) -> [Segment] {
        // Transpose once, then reuse the horizontal detector.
        let w = ink.raster.width, h = ink.raster.height
        var t = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w where ink.dark[y * w + x] { t[x * h + y] = true } }
        let transposed = Ink(transposedFrom: ink, mask: t)
        return horizontalSegments(transposed, minLength: minLength)
    }

    // MARK: Ruled tables
    static func ruledTables(_ ink: Ink, horizontal: [Segment], vertical: [Segment], textHeight: Double) -> [LayoutTable] {
        let tol = max(8.0, textHeight * 0.25)
        let items = horizontal.map { ($0, true) } + vertical.map { ($0, false) }
        guard !horizontal.isEmpty, !vertical.isEmpty else { return [] }
        var parent = Array(items.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for (i, h) in horizontal.enumerated() {
            for (j, v) in vertical.enumerated() {
                let vi = horizontal.count + j
                if v.c >= h.a0 - tol && v.c <= h.a1 + tol && h.c >= v.a0 - tol && h.c <= v.a1 + tol { parent[find(i)] = find(vi) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in items.indices { groups[find(i), default: []].append(i) }
        var tables: [LayoutTable] = []
        for members in groups.values {
            let hs = members.filter { items[$0].1 }.map { items[$0].0 }, vs = members.filter { !items[$0].1 }.map { items[$0].0 }
            guard hs.count >= 2, vs.count >= 2 else { continue }
            let rows = cluster(hs.map(\.c), tolerance: tol), cols = cluster(vs.map(\.c), tolerance: tol)
            guard rows.count >= 2, cols.count >= 2 else { continue }
            if let table = buildRuledTable(ink, rows: rows, columns: cols, tolerance: Int(max(3, tol / 2))) { tables.append(table) }
        }
        return tables.sorted { $0.box.y0 < $1.box.y0 }
    }
    static func cluster(_ values: [Double], tolerance: Double) -> [Double] {
        var groups: [[Double]] = []
        for v in values.sorted() {
            if let last = groups.last?.last, v - last <= tolerance { groups[groups.count - 1].append(v) } else { groups.append([v]) }
        }
        return groups.map { $0.reduce(0, +) / Double($0.count) }
    }
    static func buildRuledTable(_ ink: Ink, rows: [Double], columns: [Double], tolerance: Int) -> LayoutTable? {
        let R = rows.count - 1, C = columns.count - 1
        guard R >= 1, C >= 1, R * C <= 20000 else { return nil }
        func wallRight(_ r: Int, _ c: Int) -> Bool {   // between (r,c) and (r,c+1)
            let inset = (rows[r + 1] - rows[r]) * 0.2
            return ink.coverage(vertical: columns[c + 1], from: rows[r] + inset, to: rows[r + 1] - inset, tolerance: tolerance) >= 0.6
        }
        func wallBelow(_ r: Int, _ c: Int) -> Bool {   // between (r,c) and (r+1,c)
            let inset = (columns[c + 1] - columns[c]) * 0.08
            return ink.coverage(horizontal: rows[r + 1], from: columns[c] + inset, to: columns[c + 1] - inset, tolerance: tolerance) >= 0.6
        }
        var parent = Array(0..<(R * C))
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for r in 0..<R { for c in 0..<C {
            if c + 1 < C, !wallRight(r, c) { parent[find(r * C + c)] = find(r * C + c + 1) }
            if r + 1 < R, !wallBelow(r, c) { parent[find(r * C + c)] = find((r + 1) * C + c) }
        } }
        var groups: [Int: [Int]] = [:]
        for i in 0..<(R * C) { groups[find(i), default: []].append(i) }
        var cells: [LayoutCell] = []
        var covered = Set<Int>()
        for members in groups.values.sorted(by: { ($0.min() ?? 0) < ($1.min() ?? 0) }) {
            let rs = members.map { $0 / C }, cs = members.map { $0 % C }
            var r0 = rs.min()!, r1 = rs.max()!, c0 = cs.min()!, c1 = cs.max()!
            // A merged region must be rectangular; otherwise keep its first row span.
            if (r1 - r0 + 1) * (c1 - c0 + 1) != members.count { r1 = r0; c1 = c0 }
            for r in r0...r1 { for c in c0...c1 where covered.contains(r * C + c) { r1 = r0; c1 = c0 } }
            for r in r0...r1 { for c in c0...c1 { covered.insert(r * C + c) } }
            _ = (r0, c0)
            var cell = LayoutCell(row: r0, column: c0, rowSpan: r1 - r0 + 1, columnSpan: c1 - c0 + 1,
                                  box: LBox(columns[c0], rows[r0], columns[c1 + 1], rows[r1 + 1]))
            cell.fill = ink.fill(cell.box).flatMap { Ink.printedFill($0, merged: cell.rowSpan > 1 || cell.columnSpan > 1) }
            cells.append(cell)
            r0 = 0; c0 = 0
        }
        // Cells left out by non-rectangular groups become single cells.
        for r in 0..<R { for c in 0..<C where !covered.contains(r * C + c) {
            var cell = LayoutCell(row: r, column: c, box: LBox(columns[c], rows[r], columns[c + 1], rows[r + 1]))
            cell.fill = ink.fill(cell.box).flatMap { Ink.printedFill($0, merged: false) }; cells.append(cell)
        } }
        for i in cells.indices {
            let b = cells[i].box, c = cells[i]
            // Outer edges of a photographed table bend most; search wider there.
            func edge(_ outer: Bool) -> (Int, Double) { outer ? (tolerance * 2, 0.35) : (tolerance, 0.5) }
            let t = edge(c.row == 0), bo = edge(c.row + c.rowSpan == R), l = edge(c.column == 0), r = edge(c.column + c.columnSpan == C)
            cells[i].top = ink.coverage(horizontal: b.y0, from: b.x0 + 4, to: b.x1 - 4, tolerance: t.0) >= t.1
            cells[i].bottom = ink.coverage(horizontal: b.y1, from: b.x0 + 4, to: b.x1 - 4, tolerance: bo.0) >= bo.1
            cells[i].left = ink.coverage(vertical: b.x0, from: b.y0 + 4, to: b.y1 - 4, tolerance: l.0) >= l.1
            cells[i].right = ink.coverage(vertical: b.x1, from: b.y0 + 4, to: b.y1 - 4, tolerance: r.0) >= r.1
        }
        cells.sort { $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row }
        // A single pale row between white rows is a header band.
        func pale(_ r: Int) -> LayoutColor? {
            let row = cells.filter { $0.row == r && $0.rowSpan == 1 && $0.columnSpan == 1 }
            guard row.count >= 2 else { return nil }
            let colors = row.compactMap { ink.fill($0.box) }
            guard colors.count == row.count else { return nil }
            let chromas = colors.map { Int(max($0.r, $0.g, $0.b)) - Int(min($0.r, $0.g, $0.b)) }
            guard chromas.allSatisfy({ $0 >= 10 }) else { return nil }
            let first = colors[0]
            guard colors.allSatisfy({ abs(Int($0.r) - Int(first.r)) + abs(Int($0.g) - Int(first.g)) + abs(Int($0.b) - Int(first.b)) < 18 }) else { return nil }
            return first
        }
        func chroma(_ r: Int) -> Double {
            let colors = cells.filter { $0.row == r && $0.rowSpan == 1 && $0.columnSpan == 1 }.compactMap { ink.fill($0.box) }
            guard !colors.isEmpty else { return 0 }
            return colors.map { Double(Int(max($0.r, $0.g, $0.b)) - Int(min($0.r, $0.g, $0.b))) }.reduce(0, +) / Double(colors.count)
        }
        for r in 0..<R {
            guard let color = pale(r), chroma(r) >= 14, (r == 0 || chroma(r - 1) < 8), (r == R - 1 || chroma(r + 1) < 8),
                  let fill = Ink.printedFill(color, merged: true) else { continue }
            for i in cells.indices where cells[i].row == r && cells[i].rowSpan == 1 && cells[i].columnSpan == 1 && cells[i].fill == nil { cells[i].fill = fill }
        }
        return LayoutTable(columns: columns, rows: rows, cells: cells, ruled: true)
    }

    // MARK: Lines of text
    struct VisualLine {
        var words: [Word]
        var box: LBox
        var segments: [[Word]] = []
    }
    static func visualLines(_ words: [Word]) -> [VisualLine] {
        var lines: [VisualLine] = []
        for word in words.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let i = lines.lastIndex(where: { line in
                let overlap = line.box.overlapY(word.box)
                return overlap >= 0.5 * min(line.box.height, word.box.height) && word.box.height < line.box.height * 2.2 && line.box.height < word.box.height * 2.2
            }) {
                lines[i].words.append(word); lines[i].box = lines[i].box.union(word.box)
            } else { lines.append(VisualLine(words: [word], box: word.box)) }
        }
        for i in lines.indices {
            lines[i].words.sort { $0.box.x0 < $1.box.x0 }
            let heights = lines[i].words.map(\.box.height).sorted()
            let h = heights[heights.count / 2]
            var segments: [[Word]] = []
            for w in lines[i].words {
                if let last = segments.last?.last, w.box.x0 - last.box.x1 <= max(h * 1.6, 1) { segments[segments.count - 1].append(w) }
                else { segments.append([w]) }
            }
            lines[i].segments = segments
        }
        return lines.sorted { $0.box.y0 < $1.box.y0 }
    }

    // MARK: Main entry
    static func analyze(_ raster: LayoutRaster, blocks: [TextBlock], pageSize: (Double, Double)? = nil) -> PageLayout {
        let W = raster.width, H = raster.height
        var ink = Ink(raster)
        var wordLines = words(blocks, width: W, height: H)
        let allHeights = wordLines.flatMap { $0.map(\.box.height) }.sorted()
        let textHeight = allHeights.isEmpty ? Double(H) * 0.015 : allHeights[allHeights.count / 2]
        let size = pageSize ?? physicalSize(width: W, height: H)
        let ptPerPx = size.0 / Double(W)
        ink.ptPerPx = ptPerPx

        for li in wordLines.indices { for wi in wordLines[li].indices { wordLines[li][wi].color = ink.inkColor(wordLines[li][wi].box) } }

        let hSegments = horizontalSegments(ink, minLength: max(40, Int(Double(W) * 0.035)))
        let vSegments = verticalSegments(ink, minLength: max(30, Int(textHeight * 1.4)))
        var tables = ruledTables(ink, horizontal: hSegments, vertical: vSegments, textHeight: textHeight)
        // Text is measured without ruling lines so borders never inflate sizes.
        var textInk = ink
        for s in hSegments {
            let r = Int((s.thickness / 2).rounded(.up)) + 1
            for y in max(0, Int(s.c) - r)...min(H - 1, Int(s.c) + r) { for x in max(0, Int(s.a0))..<min(W, Int(s.a1)) { textInk.dark[y * W + x] = false } }
        }
        for s in vSegments {
            let r = Int((s.thickness / 2).rounded(.up)) + 1
            for x in max(0, Int(s.c) - r)...min(W - 1, Int(s.c) + r) { for y in max(0, Int(s.a0))..<min(H, Int(s.a1)) { textInk.dark[y * W + x] = false } }
        }
        // Recognized word boxes are padded; snap their sides to the ink.
        for li in wordLines.indices { for wi in wordLines[li].indices {
            if let tight = textInk.inkColumns(wordLines[li][wi].box) { wordLines[li][wi].box.x0 = tight.0; wordLines[li][wi].box.x1 = tight.1 }
        } }

        var free: [Word] = []
        var tableWords: [[Word]] = Array(repeating: [], count: tables.count)
        for line in wordLines { for word in line {
            if let t = tables.firstIndex(where: { $0.box.contains(x: word.box.midX, y: word.box.midY) }) { tableWords[t].append(word) }
            else { free.append(word) }
        } }
        for t in tables.indices { fillCells(&tables[t], words: tableWords[t], ink: textInk, ptPerPx: ptPerPx) }

        // Underlines: short rules right below text that are not part of a table.
        let tableBoxes = tables.map { $0.box.inset(-6) }
        let looseRules = hSegments.filter { s in !tableBoxes.contains { $0.contains(x: (s.a0 + s.a1) / 2, y: s.c) } }
        var usedRules = Set<Int>()
        for i in free.indices {
            let wb = free[i].box
            if let r = looseRules.firstIndex(where: { r in
                r.c > wb.y1 - wb.height * 0.25 && r.c < wb.y1 + wb.height * 0.45 &&
                min(r.a1, wb.x1) - max(r.a0, wb.x0) > wb.width * 0.7
            }) { usedRules.insert(r); free[i].underline = true }
        }
        let lines = visualLines(free)

        // Borderless tables from aligned columns.
        var consumed = Set<Int>()
        for group in borderlessGroups(lines, width: Double(W)) {
            if let table = borderlessTable(lines, rows: group, ink: textInk, ptPerPx: ptPerPx) {
                tables.append(table); group.forEach { consumed.insert($0) }
            }
        }
        for t in tables.indices { fixCodeColumns(&tables[t]) }
        let remaining = lines.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
        let paragraphs = buildParagraphs(remaining, ink: textInk, width: Double(W), ptPerPx: ptPerPx)

        // Graphics: remaining ink that is neither text nor table.
        var textBoxes = wordLines.flatMap { $0.map { $0.box } }
        textBoxes += tables.map { $0.box.inset(-12) }
        let underlineBoxes = usedRules.map { looseRules[$0] }.map { LBox($0.a0, $0.c - $0.thickness, $0.a1, $0.c + $0.thickness) }
        let graphics = findGraphics(ink, excluding: textBoxes + underlineBoxes, textHeight: textHeight)

        var items: [LayoutItem] = paragraphs.map { .paragraph($0) } + tables.map { .table($0) }
        items.sort { $0.box.y0 < $1.box.y0 }
        return PageLayout(width: W, height: H, pageWidth: size.0, pageHeight: size.1, items: items, graphics: graphics)
    }


    static func physicalSize(width: Int, height: Int) -> (Double, Double) {
        let aspect = Double(height) / Double(max(1, width))
        if abs(aspect - 11.0 / 8.5) < 0.06 { return (612, 792) }
        if abs(aspect - 297.0 / 210.0) < 0.06 { return (595.3, 841.9) }
        if abs(aspect - 8.5 / 11.0) < 0.05 { return (792, 612) }
        if abs(aspect - 210.0 / 297.0) < 0.05 { return (841.9, 595.3) }
        let w = 612.0
        return (w, min(1584, w * aspect))
    }

    // MARK: Styling helpers
    /// Font size in points, measured per visual line from the ink height and
    /// the kinds of glyphs on the line (caps only, descenders, Hangul…).
    static func fontSize(_ words: [Word], ink: Ink, ptPerPx: Double) -> Double {
        var sizes: [Double] = []
        for w in words { if let px = wordPixelSize(w.text, box: w.box, ink: ink) { sizes.append(px * ptPerPx) } }
        if sizes.isEmpty { return max(6, ((words.map(\.box.height).max() ?? 12) * ptPerPx * 0.75 * 2).rounded() / 2) }
        sizes.sort()
        let median = sizes.count % 2 == 1 ? sizes[sizes.count / 2] : (sizes[sizes.count / 2 - 1] + sizes[sizes.count / 2]) / 2
        return max(5, min(96, (median * 2).rounded() / 2))
    }
    /// Em size in pixels of one word: the contiguous ink band around the
    /// densest row (so a neighbouring line's descenders are left out), divided
    /// by the share of the em that the word's glyphs cover.
    static func wordPixelSize(_ text: String, box: LBox, ink: Ink) -> Double? {
        let letters = text.filter { $0.isLetter || $0.isNumber }
        guard !letters.isEmpty else { return nil }
        let x0 = max(0, Int(box.x0)), x1 = min(ink.raster.width, Int(box.x1))
        let y0 = max(0, Int(box.y0)), y1 = min(ink.raster.height, Int(box.y1))
        guard x1 > x0, y1 - y0 > 3 else { return nil }
        var counts = [Int](repeating: 0, count: y1 - y0)
        for y in y0..<y1 { var c = 0; for x in x0..<x1 where ink.dark[y * ink.raster.width + x] { c += 1 }; counts[y - y0] = c }
        guard let peak = counts.max(), peak > 0, let peakRow = counts.firstIndex(of: peak) else { return nil }
        var top = peakRow, bottom = peakRow
        while top > 0 && (counts[top - 1] > 0 || (top > 1 && counts[top - 2] > 0 && counts[top - 1] == 0 && false)) { top -= 1 }
        while bottom < counts.count - 1 && counts[bottom + 1] > 0 { bottom += 1 }
        let inkHeight = Double(bottom - top + 1)
        let wide = text.contains { isWide($0) }
        let bracket = text.contains { "()[]{}|".contains($0) }
        let descender = text.contains { "gjpqyQ".contains($0) } || bracket
        let tall = text.contains { $0.isUppercase || $0.isNumber || "bdfhklt".contains($0) } || bracket
        let ratio: Double
        if wide { ratio = bracket ? 1.02 : 0.9 }
        else if bracket { ratio = 1.0 }
        else if descender && tall { ratio = 0.94 }
        else if tall { ratio = 0.73 }
        else if descender { ratio = 0.73 }
        else { ratio = 0.53 }
        return inkHeight / ratio
    }
    static func isWide(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first?.value else { return false }
        return (0x1100...0x11FF).contains(s) || (0x3040...0x30FF).contains(s) || (0x3400...0x9FFF).contains(s) || (0xAC00...0xD7AF).contains(s)
    }
    /// Stroke width relative to what regular text of this size measures in a scan
    /// (≈1.0 regular, ≥1.25 bold). Small text blurs thicker, hence the offset.
    static func boldScore(_ words: [Word], ink: Ink, fontPt: Double) -> Double? {
        var values: [Double] = []
        for w in words where w.text.contains(where: { $0.isLetter || $0.isNumber }) {
            if let s = ink.strokeWidth(w.box) { values.append(s * ink.ptPerPx / (0.3 + 0.08 * fontPt)) }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }
    static func runs(_ words: [Word], ink: Ink, fontPx: Double) -> [LayoutRun] {
        let fontPt = fontPx * ink.ptPerPx
        var runs: [LayoutRun] = []
        for w in words {
            let bold = (boldScore([w], ink: ink, fontPt: fontPt) ?? 1) >= 1.25
            let text = (w.spaceBefore && !runs.isEmpty ? " " : "") + w.text
            if var last = runs.last, last.bold == bold, last.underline == w.underline, last.color == w.color {
                last.text += text; runs[runs.count - 1] = last
            } else {
                runs.append(LayoutRun(text: text, bold: bold, underline: w.underline, color: w.color))
            }
        }
        // Words share the line's weight unless a clear phrase differs.
        let boldChars = runs.filter(\.bold).reduce(0) { $0 + $1.text.count }, total = runs.reduce(0) { $0 + $1.text.count }
        if total > 0, runs.count > 1 {
            let share = Double(boldChars) / Double(total)
            if share > 0.75 || share < 0.25 || runs.filter({ $0.bold }).allSatisfy({ $0.text.count <= 2 }) {
                let bold = share > 0.75
                var merged: [LayoutRun] = []
                for var r in runs { r.bold = bold; if var last = merged.last, last.underline == r.underline, last.color == r.color { last.text += r.text; merged[merged.count - 1] = last } else { merged.append(r) } }
                runs = merged
            }
        }
        return runs
    }

    /// In columns of codes like "B1 - B7", recognition often reads 1 as l or I
    /// ("El", "Fl"). When the column clearly holds letter+digit codes, fix those.
    static func fixCodeColumns(_ table: inout LayoutTable) {
        func tokens(_ s: String) -> [Substring] { s.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "–" }) }
        func isCode(_ t: Substring) -> Bool {
            let letters = t.prefix { $0.isUppercase && $0.isASCII }
            let rest = t.dropFirst(letters.count).filter { $0 != "*" }
            return (1...3).contains(letters.count) && (1...3).contains(rest.count) && rest.allSatisfy(\.isNumber)
        }
        for c in 0..<table.columnCount {
            let cells = table.cells.indices.filter { table.cells[$0].column == c && table.cells[$0].lines.count == 1 }
            let all = cells.flatMap { tokens(table.cells[$0].text) }
            guard all.filter(isCode).count >= 3 else { continue }
            for i in cells {
                table.cells[i].lines = table.cells[i].lines.map { line in line.map { run in
                    var run = run
                    run.text = run.text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
                        let letters = word.prefix { $0.isUppercase && $0.isASCII && $0 != "I" && $0 != "O" }
                        let rest = word.dropFirst(letters.count)
                        guard (1...3).contains(letters.count), (1...3).contains(rest.filter { $0 != "*" }.count),
                              rest.allSatisfy({ $0.isNumber || "lIO*".contains($0) }), rest.contains(where: { "lIO".contains($0) }) else { return String(word) }
                        return String(letters) + rest.map { $0 == "O" ? "0" : ("lI".contains($0) ? "1" : String($0)) }.joined()
                    }.joined(separator: " ")
                    return run
                } }
            }
        }
    }
    static func fillCells(_ table: inout LayoutTable, words: [Word], ink: Ink, ptPerPx: Double) {
        var byCell: [Int: [Word]] = [:]
        for w in words {
            if let i = table.cells.firstIndex(where: { $0.box.contains(x: w.box.midX, y: w.box.midY) }) { byCell[i, default: []].append(w) }
        }
        var scores: [Int: Double] = [:]
        for (i, ws) in byCell {
            let lines = visualLines(ws)
            let size = fontSize(ws, ink: ink, ptPerPx: ptPerPx)
            table.cells[i].fontSize = size
            table.cells[i].lines = lines.map { runs($0.words, ink: ink, fontPx: size / ptPerPx) }
            table.cells[i].alignment = alignment(of: LBox.around(ws.map(\.box))!, in: table.cells[i].box)
            scores[i] = boldScore(ws, ink: ink, fontPt: size)
        }
        harmonizeSizes(&table)
        harmonizeWeight(&table, scores: scores)
        fitCells(&table, words: byCell, ptPerPx: ptPerPx)
    }
    static func fitCells(_ table: inout LayoutTable, words: [Int: [Word]], ptPerPx: Double) {
        for (i, ws) in words {
            let lines = visualLines(ws)
            var fits: [Double] = []
            for (k, line) in lines.enumerated() where k < table.cells[i].lines.count {
                guard let box = LBox.around(line.words.map(\.box)) else { continue }
                let runs = table.cells[i].lines[k]
                let text = runs.map(\.text).joined()
                _ = box
                var spacing = 0.0
                // Condense only when the text would otherwise outgrow its cell.
                let room = (table.cells[i].box.width - 8) * ptPerPx
                let needed = naturalWidth(text, size: table.cells[i].fontSize, bold: runs.first?.bold ?? false) + spacing * Double(max(0, text.count - 1))
                if needed > room { spacing -= (needed - room) / Double(max(1, text.count - 1)) }
                fits.append(max(-table.cells[i].fontSize * 0.15, spacing))
            }
            fits.sort()
            if !fits.isEmpty { table.cells[i].letterSpacing = fits[0] }
        }
    }
    /// Cells of one table share a few sizes; snap each cluster of similar sizes to its median.
    static func harmonizeSizes(_ table: inout LayoutTable) {
        let filled = table.cells.indices.filter { !table.cells[$0].lines.isEmpty }
        let sorted = filled.sorted { table.cells[$0].fontSize < table.cells[$1].fontSize }
        var clusters: [[Int]] = []
        for i in sorted {
            if let last = clusters.last?.last, table.cells[i].fontSize <= table.cells[last].fontSize * 1.14 { clusters[clusters.count - 1].append(i) } else { clusters.append([i]) }
        }
        var body = 10.0, best = 0
        for c in clusters {
            let median = table.cells[c[c.count / 2]].fontSize
            for i in c { table.cells[i].fontSize = median }
            if c.count > best { best = c.count; body = median }
        }
        // Lone outliers are measurement noise; give them the body size.
        for c in clusters where c.count * 10 < filled.count {
            for i in c where abs(table.cells[i].fontSize - body) <= body * 0.4 { table.cells[i].fontSize = body }
        }
        for i in table.cells.indices where table.cells[i].lines.isEmpty { table.cells[i].fontSize = body }
    }
    /// A table set mostly in bold is bold throughout; otherwise only clearly bold cells.
    static func harmonizeWeight(_ table: inout LayoutTable, scores: [Int: Double]) {
        guard !scores.isEmpty else { return }
        let share = Double(scores.values.filter { $0 >= 1.1 }.count) / Double(scores.count)
        for (i, score) in scores {
            let bold = share >= 0.6 ? true : (share <= 0.25 ? score >= 1.35 : score >= 1.25)
            table.cells[i].lines = table.cells[i].lines.map { line in
                var merged: [LayoutRun] = []
                for var r in line { r.bold = bold; if var last = merged.last, last.underline == r.underline, last.color == r.color { last.text += r.text; merged[merged.count - 1] = last } else { merged.append(r) } }
                return merged
            }
        }
    }
    static func alignment(of text: LBox, in cell: LBox) -> LayoutAlignment {
        let left = text.x0 - cell.x0, right = cell.x1 - text.x1
        if abs(left - right) <= max(6, cell.width * 0.12) { return .center }
        return left < right ? .left : .right
    }

    // MARK: Borderless tables
    static func borderlessGroups(_ lines: [VisualLine], width: Double) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        func columnsOf(_ indices: [Int]) -> [(Double, Double)] {
            var intervals = indices.flatMap { i in lines[i].segments.map { (LBox.around($0.map(\.box))!.x0, LBox.around($0.map(\.box))!.x1) } }
            intervals.sort { $0.0 < $1.0 }
            var merged: [(Double, Double)] = []
            for iv in intervals {
                if let last = merged.last, iv.0 <= last.1 + width * 0.01 { merged[merged.count - 1].1 = max(last.1, iv.1) } else { merged.append(iv) }
            }
            return merged
        }
        func consistent(_ indices: [Int]) -> Bool {
            let cols = columnsOf(indices)
            guard cols.count >= 2 else { return false }
            // Every segment sits in exactly one column.
            for i in indices { for s in lines[i].segments {
                let b = LBox.around(s.map(\.box))!
                if cols.filter({ b.x1 > $0.0 && b.x0 < $0.1 }).count != 1 { return false }
            } }
            return true
        }
        func flush() {
            let multi = current.filter { lines[$0].segments.count >= 2 }.count
            if current.count >= 3 && multi >= 3, columnsOf(current).count >= 2 { groups.append(current) }
            current = []
        }
        for i in lines.indices {
            let line = lines[i]
            if current.isEmpty {
                if line.segments.count >= 2 { current = [i] }
                continue
            }
            let previous = lines[current.last!]
            let gap = line.box.y0 - previous.box.y1
            let h = max(previous.box.height, line.box.height)
            let fits = gap <= h * 2.2 && consistent(current + [i]) && (line.segments.count >= 2 || {
                // A single segment may continue a row only when it starts in a non-first column.
                let cols = columnsOf(current), b = LBox.around(line.segments[0].map(\.box))!
                return cols.count >= 2 && b.x0 > cols[0].1
            }())
            if fits { current.append(i) } else { flush(); if line.segments.count >= 2 { current = [i] } }
        }
        flush()
        return groups
    }
    static func borderlessTable(_ lines: [VisualLine], rows: [Int], ink: Ink, ptPerPx: Double) -> LayoutTable? {
        var intervals = rows.flatMap { i in lines[i].segments.map { LBox.around($0.map(\.box))! } }.map { ($0.x0, $0.x1) }
        intervals.sort { $0.0 < $1.0 }
        var cols: [(Double, Double)] = []
        for iv in intervals {
            if let last = cols.last, iv.0 <= last.1 + 4 { cols[cols.count - 1].1 = max(last.1, iv.1) } else { cols.append(iv) }
        }
        guard cols.count >= 2 else { return nil }
        var xs = [cols[0].0 - 8]
        for c in 1..<cols.count { xs.append((cols[c - 1].1 + cols[c].0) / 2) }
        xs.append(cols.last!.1 + 8)
        var ys = [lines[rows[0]].box.y0 - 6]
        for r in 1..<rows.count { ys.append((lines[rows[r - 1]].box.y1 + lines[rows[r]].box.y0) / 2) }
        ys.append(lines[rows.last!].box.y1 + 6)
        var cells: [LayoutCell] = []
        var sizes: [Double] = []
        var cellWords: [Int: [Word]] = [:]
        for (r, li) in rows.enumerated() {
            for c in 0..<cols.count {
                var cell = LayoutCell(row: r, column: c, box: LBox(xs[c], ys[r], xs[c + 1], ys[r + 1]))
                cell.top = false; cell.left = false; cell.bottom = false; cell.right = false
                let ws = lines[li].segments.filter { s in let b = LBox.around(s.map(\.box))!; return b.x1 > cols[c].0 && b.x0 < cols[c].1 }.flatMap { $0 }
                if !ws.isEmpty {
                    let size = fontSize(ws, ink: ink, ptPerPx: ptPerPx)
                    sizes.append(size)
                    cell.fontSize = size
                    cell.lines = [runs(ws, ink: ink, fontPx: size / ptPerPx)]
                    cellWords[cells.count] = ws
                }
                cells.append(cell)
            }
        }
        // Column alignment from where the text sits inside each column.
        for c in 0..<cols.count {
            let boxes = rows.indices.compactMap { r -> LBox? in
                let li = rows[r]
                let ws = lines[li].segments.filter { s in let b = LBox.around(s.map(\.box))!; return b.x1 > cols[c].0 && b.x0 < cols[c].1 }.flatMap { $0 }
                return LBox.around(ws.map(\.box))
            }
            let lefts = boxes.map(\.x0), rights = boxes.map(\.x1), mids = boxes.map(\.midX)
            func spread(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
            let a: LayoutAlignment = spread(lefts) <= spread(rights) && spread(lefts) <= spread(mids) + 2 ? .left : (spread(rights) <= spread(mids) ? .right : .center)
            for i in cells.indices where cells[i].column == c { cells[i].alignment = a }
        }
        var table = LayoutTable(columns: xs, rows: ys, cells: cells, ruled: false)
        harmonizeSizes(&table)
        fitCells(&table, words: cellWords, ptPerPx: ptPerPx)
        _ = sizes
        return table
    }

    // MARK: Paragraphs
    static func buildParagraphs(_ lines: [VisualLine], ink: Ink, width: Double, ptPerPx: Double) -> [LayoutParagraph] {
        struct Info { var line: VisualLine; var size: Double; var bullet: LBox?; var textBox: LBox; var segments: [LayoutSegment] }
        var infos: [Info] = []
        for line in lines {
            var words = line.words
            var bullet: LBox?
            if let first = words.first, bulletGlyphs.contains(first.text), words.count > 1, first.text != "-" || words[1].box.x0 - first.box.x1 > first.box.height * 0.3 {
                bullet = first.box; words.removeFirst()
            } else if let first = words.first, let b = detectBullet(ink, before: first.box) {
                bullet = b
            }
            var segs: [[Word]] = []
            let h = (line.words.map(\.box.height).sorted())[line.words.count / 2]
            for w in words {
                if let last = segs.last?.last, w.box.x0 - last.box.x1 <= h * 1.6 { segs[segs.count - 1].append(w) } else { segs.append([w]) }
            }
            if var first = segs.first?.first, segs[0].count > 0 { first.spaceBefore = false; segs[0][0] = first }
            guard !segs.isEmpty else { continue }
            let segments = segs.map { s -> LayoutSegment in
                var copy = s; copy[0].spaceBefore = false
                let size = fontSize(s, ink: ink, ptPerPx: ptPerPx)
                return LayoutSegment(runs: runs(copy, ink: ink, fontPx: size / ptPerPx), box: LBox.around(s.map(\.box))!, fontSize: size)
            }
            let size = segments[0].fontSize ?? 10
            guard let textBox = LBox.around(words.map(\.box)) else { continue }
            infos.append(Info(line: line, size: size, bullet: bullet, textBox: textBox, segments: segments))
        }
        let contentRight = infos.map(\.textBox.x1).max() ?? width
        var paragraphs: [LayoutParagraph] = []
        var i = 0
        while i < infos.count {
            var group = [infos[i]]
            var j = i + 1
            while j < infos.count {
                let prev = group.last!, next = infos[j]
                guard prev.segments.count == 1, next.segments.count == 1, next.bullet == nil else { break }
                let h = max(prev.textBox.height, next.textBox.height)
                let gap = next.textBox.y0 - prev.textBox.y1
                let sameSize = abs(prev.size - next.size) <= max(prev.size, next.size) * 0.15
                let sameLeft = abs(prev.textBox.x0 - next.textBox.x0) <= width * 0.012
                let sameCenter = abs(prev.textBox.midX - next.textBox.midX) <= width * 0.015 && !sameLeft
                guard gap <= h * 0.75, gap > -h * 0.3, sameSize, sameLeft || sameCenter else { break }
                group.append(next); j += 1
            }
            let box = LBox.around(group.map { $0.textBox })!
            var lines: [LayoutLine] = []
            for (k, info) in group.enumerated() {
                var line = LayoutLine(segments: info.segments, box: info.textBox)
                if k + 1 < group.count {
                    let next = group[k + 1]
                    let firstWord = next.segments.first?.box.width ?? 0
                    let nextFirstWidth = min(firstWord, (next.line.words.first?.box.width ?? firstWord))
                    line.wraps = contentRight - info.textBox.x1 < nextFirstWidth + info.textBox.height * 1.2
                }
                lines.append(line)
            }
            let sizes = group.map(\.size).sorted()
            let size = sizes[sizes.count / 2]
            let pitch: Double
            if group.count > 1 {
                let pitches = zip(group, group.dropFirst()).map { $1.textBox.midY - $0.textBox.midY }.sorted()
                pitch = pitches[pitches.count / 2]
            } else { pitch = size / ptPerPx * 1.2 }
            let alignment = paragraphAlignment(box, group: group.map(\.textBox), width: width, contentRight: contentRight)
            // Character spacing that reproduces the scanned line widths.
            var fits: [Double] = []
            for line in group where line.segments.count == 1 {
                let seg = line.segments[0]
                let bold = seg.runs.contains(where: \.bold) && seg.runs.filter(\.bold).reduce(0, { $0 + $1.text.count }) * 2 > seg.text.count
                fits.append(fittingSpacing(text: seg.text, width: seg.box.width * ptPerPx, size: seg.fontSize ?? size, bold: bold))
            }
            fits.sort()
            let spacing = fits.isEmpty ? 0 : fits[fits.count / 2]
            paragraphs.append(LayoutParagraph(lines: lines, box: box, fontSize: size, alignment: alignment, bullet: group[0].bullet, letterSpacing: spacing, linePitch: pitch))
            i = j
        }
        return paragraphs
    }
    /// Arial/Helvetica advance widths (1/1000 em) for ASCII 32–126.
    static let asciiWidths: [Int] = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584]
    static func glyphWidth(_ c: Character) -> Double {
        if let v = c.asciiValue, v >= 32, v < 127 { return Double(asciiWidths[Int(v) - 32]) / 1000 }
        if isWide(c) { return 0.92 }
        if c.isLetter { return 0.6 }
        return 0.5
    }
    /// Width in points the text takes in Arial at `size`.
    static func naturalWidth(_ text: String, size: Double, bold: Bool = false) -> Double {
        text.reduce(0.0) { $0 + glyphWidth($1) } * size * (bold ? 1.07 : 1)
    }
    /// Extra character spacing (points) that makes Arial text as wide as the
    /// scanned text, so lines keep their breaks and tables keep their rows.
    static func fittingSpacing(text: String, width: Double, size: Double, bold: Bool) -> Double {
        let count = Double(max(1, text.count - 1))
        guard text.count >= 3 else { return 0 }
        let extra = (width - naturalWidth(text, size: size, bold: bold)) / count
        if abs(extra) < size * 0.015 { return 0 }
        let caps = !text.contains(where: \.isLowercase) && text.filter(\.isLetter).count >= 4
        return max(-size * 0.12, min(size * (caps ? 0.8 : 0.08), extra))
    }
    static func paragraphAlignment(_ box: LBox, group: [LBox], width: Double, contentRight: Double) -> LayoutAlignment {
        let centered = group.allSatisfy { abs($0.midX - width / 2) <= width * 0.025 }
        if centered && box.x0 > width * 0.2 { return .center }
        if box.x0 > width * 0.55 && abs(box.x1 - contentRight) <= width * 0.02 { return .right }
        return .left
    }
    /// Finds a small round ink blob left of a line that OCR did not report.
    static func detectBullet(_ ink: Ink, before box: LBox) -> LBox? {
        let h = box.height
        let region = LBox(box.x0 - h * 1.4, box.y0 + h * 0.15, box.x0 - h * 0.15, box.y1 - h * 0.15)
        guard region.x0 > 0 else { return nil }
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, count = 0
        for y in Int(region.y0)..<Int(region.y1) { for x in Int(region.x0)..<Int(region.x1) where ink.isDark(x, y) {
            count += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard count > 4 else { return nil }
        let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
        guard bw <= h * 0.45, bh <= h * 0.45, bw >= h * 0.12, abs(bw - bh) <= max(bw, bh) * 0.5,
              Double(count) >= bw * bh * 0.45 else { return nil }
        return LBox(Double(minX), Double(minY), Double(maxX + 1), Double(maxY + 1))
    }

    // MARK: Graphics
    static func findGraphics(_ ink: Ink, excluding: [LBox], textHeight: Double) -> [LayoutGraphic] {
        let cell = 4
        let gw = (ink.raster.width + cell - 1) / cell, gh = (ink.raster.height + cell - 1) / cell
        var grid = [Bool](repeating: false, count: gw * gh)
        var blocked = [Bool](repeating: false, count: gw * gh)
        for b in excluding {
            let e = b.inset(-3)
            for gy in max(0, Int(e.y0) / cell)...min(gh - 1, Int(e.y1) / cell) { for gx in max(0, Int(e.x0) / cell)...min(gw - 1, Int(e.x1) / cell) { blocked[gy * gw + gx] = true } }
        }
        for y in 0..<ink.raster.height { for x in 0..<ink.raster.width where ink.dark[y * ink.raster.width + x] {
            let g = (y / cell) * gw + x / cell
            if !blocked[g] { grid[g] = true }
        } }
        var seen = [Bool](repeating: false, count: gw * gh)
        var boxes: [(LBox, Int)] = []
        for start in 0..<(gw * gh) where grid[start] && !seen[start] {
            var stack = [start]; seen[start] = true
            var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min, n = 0
            while let p = stack.popLast() {
                let x = p % gw, y = p / gw; n += 1
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                    let q = ny * gw + nx
                    if grid[q] && !seen[q] { seen[q] = true; stack.append(q) }
                }
            }
            boxes.append((LBox(Double(x0 * cell), Double(y0 * cell), Double((x1 + 1) * cell), Double((y1 + 1) * cell)), n))
        }
        let minSide = max(textHeight * 2.5, Double(ink.raster.width) * 0.06)
        var kept = boxes.filter { max($0.0.width, $0.0.height) >= minSide && $0.1 >= 12 }
        // Merge nearby pieces of one drawing.
        var merged = true
        while merged {
            merged = false
            outer: for a in kept.indices { for b in kept.indices where b > a {
                let A = kept[a].0.inset(-textHeight * 0.6), B = kept[b].0
                if A.overlapX(B) > 0 && A.overlapY(B) > 0 {
                    kept[a] = (kept[a].0.union(B), kept[a].1 + kept[b].1); kept.remove(at: b); merged = true; break outer
                }
            } }
        }
        return kept.map { box, n in
            let density = Double(n * cell * cell) / max(1, box.width * box.height)
            return LayoutGraphic(box: box, cutout: density < 0.35)
        }.sorted { $0.box.y0 < $1.box.y0 }
    }
}

extension DocumentLayoutAnalyzer.Ink {
    init(transposedFrom other: DocumentLayoutAnalyzer.Ink, mask: [Bool]) {
        self.raster = LayoutRaster(width: other.raster.height, height: other.raster.width, rgba: other.raster.rgba)
        self.dark = mask
        self.paper = other.paper
        self.ptPerPx = other.ptPerPx
    }
}
