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
    /// Ink of this text in the page picture (forms erase it from their background).
    var ink: [LBox]? = nil
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
    /// Literal marker printed instead of a list bullet (e.g. "□" for a checkbox).
    var marker: String? = nil
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
    /// Pixels from the cell's left edge to its text, for flush-left cells.
    var indent: Double = 0
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
    /// Regions whose ink is left out of the picture (text that is written as
    /// editable text instead), except where it lies on a `keep` region (rules).
    var masks: [LBox] = []
    var keeps: [LBox] = []
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
    /// Forms (many boxes side by side) are written with every element at its
    /// exact page position instead of as flowing text.
    var positioned = false
    /// A form: its line art is one picture behind the page and the text that
    /// was read reliably sits on top of it at its exact position.
    var form = false
    init(width: Int, height: Int, pageWidth: Double, pageHeight: Double, items: [LayoutItem], graphics: [LayoutGraphic]) {
        self.width = width; self.height = height; self.pageWidth = pageWidth; self.pageHeight = pageHeight
        self.items = items; self.graphics = graphics
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width); height = try c.decode(Int.self, forKey: .height)
        pageWidth = try c.decode(Double.self, forKey: .pageWidth); pageHeight = try c.decode(Double.self, forKey: .pageHeight)
        items = try c.decode([LayoutItem].self, forKey: .items); graphics = try c.decode([LayoutGraphic].self, forKey: .graphics)
        positioned = try c.decodeIfPresent(Bool.self, forKey: .positioned) ?? false
        form = try c.decodeIfPresent(Bool.self, forKey: .form) ?? false
    }
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
            // Text set sideways (e.g. along the page margin) is not read upright;
            // its ink is kept as a picture instead.
            if block.height * h > block.width * w * 1.3 && trimmed.count >= 2 { continue }
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
    /// Box-shaped marks are checkboxes, kept as printed rather than turned into list bullets.
    static let checkboxGlyphs: Set<String> = ["□", "☐", "❏", "▢", "■", "ㅁ", "口", "ロ"]
    static let bulletGlyphs: Set<String> = ["•", "●", "▪", "◦", "‣", "·", "∙", "■", "□", "➢", "►", "-", "–", "*"]

    // MARK: Pixel analysis
    struct Ink {
        let raster: LayoutRaster
        var dark: [Bool]
        let paper: (Double, Double, Double)
        var ptPerPx = 1.0
        /// Stroke score above which a word counts as bold; set per page from
        /// the body text so photos and scans with different blur both work.
        var boldThreshold = 1.25
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
        /// Grows a word box sideways over letters the recognizer left out: ink
        /// that continues the word with only letter-sized gaps.
        func extendedAlongInk(_ box: LBox, left: Bool, right: Bool, rules: [LBox] = []) -> LBox {
            let y0 = max(0, Int(box.y0 + box.height * 0.2)), y1 = min(raster.height, Int(box.y1 - box.height * 0.2))
            guard y1 > y0 else { return box }
            // Blurred letters are lighter than the dark-ink threshold but still print.
            func inked(_ x: Int) -> Bool {
                guard x >= 0, x < raster.width else { return false }
                return (y0..<y1).contains { y in raster.lum(x, y) < 170 && !rules.contains { $0.contains(x: Double(x), y: Double(y)) } }
            }
            let gapLimit = max(2, Int(box.height * 0.22)), reach = Int(box.height * 1.5)
            var out = box
            if left {
                var x = Int(box.x0) - 1, gap = 0, edge = Int(box.x0)
                while x >= Int(box.x0) - reach, gap <= gapLimit { if inked(x) { edge = x; gap = 0 } else { gap += 1 }; x -= 1 }
                out.x0 = Double(edge)
            }
            if right {
                var x = Int(box.x1), gap = 0, edge = Int(box.x1)
                while x <= Int(box.x1) + reach, gap <= gapLimit { if inked(x) { edge = x + 1; gap = 0 } else { gap += 1 }; x += 1 }
                out.x1 = Double(edge)
            }
            return out
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

    // MARK: Skew
    /// Angle in degrees that the page's text lines and rules are tilted by
    /// (positive: they fall to the right). Rules and lines of text project to
    /// the sharpest row profile when sheared back by the right angle.
    static func skewAngle(_ raster: LayoutRaster, limit: Double = 4) -> Double {
        let ink = Ink(raster)
        let step = max(1, Int((Double(max(raster.width, raster.height)) / 900).rounded()))
        let w = raster.width / step, h = raster.height / step
        guard w > 40, h > 40 else { return 0 }
        var points: [(Double, Double)] = []
        for y in 0..<h { for x in 0..<w where ink.dark[(y * step) * raster.width + x * step] { points.append((Double(x), Double(y))) } }
        guard points.count >= 200 else { return 0 }
        let cx = Double(w) / 2
        func score(_ degrees: Double) -> Double {
            let t = tan(degrees * .pi / 180)
            // Each point is shared between the two nearest rows so no angle is
            // favoured by rounding.
            var bins = [Double](repeating: 0, count: h * 2 + 2)
            let offset = Double(h) / 2
            for (x, y) in points {
                let v = y - (x - cx) * t + offset
                let i = Int(v.rounded(.down)), f = v - Double(i)
                if i >= 0 && i + 1 < bins.count { bins[i] += 1 - f; bins[i + 1] += f }
            }
            return bins.reduce(0.0) { $0 + $1 * $1 }
        }
        var best = 0.0, bestScore = score(0)
        let flat = bestScore
        for a in stride(from: -limit, through: limit, by: 0.1) {
            let s = score(a); if s > bestScore { bestScore = s; best = a }
        }
        let coarse = best
        for a in stride(from: coarse - 0.1, through: coarse + 0.1, by: 0.02) {
            let s = score(a); if s > bestScore { bestScore = s; best = a }
        }
        // Too little structure to tell: leave the page as it is.
        return bestScore > flat * 1.05 ? best : 0
    }

    // MARK: Ruling lines
    struct Segment {
        var a0: Double; var a1: Double; var c: Double; var thickness: Double // along, along, cross, stroke width
        /// Cross distance the whole line covers (more than the stroke when it runs askew).
        var span: Double = 0
        var extent: Double { max(thickness, span) }
    }

    static func horizontalSegments(_ ink: Ink, minLength: Int) -> [Segment] {
        let w = ink.raster.width, h = ink.raster.height
        // `area` counts the dark pixels of the line, so a long rule that runs
        // slightly askew keeps its real stroke width instead of the height it drifts over.
        var open: [(x0: Int, x1: Int, y0: Int, y1: Int, last: Int, area: Int)] = []
        var done: [Segment] = []
        func segment(_ s: (x0: Int, x1: Int, y0: Int, y1: Int, last: Int, area: Int)) -> Segment {
            let span = s.y1 - s.y0 + 1
            let stroke = Double(s.area) / Double(max(1, s.x1 - s.x0 + 1))
            return Segment(a0: Double(s.x0), a1: Double(s.x1 + 1), c: Double(s.y0 + s.y1 + 1) / 2, thickness: min(Double(span), max(1, stroke.rounded())), span: Double(span))
        }
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
            var next: [(x0: Int, x1: Int, y0: Int, y1: Int, last: Int, area: Int)] = []
            var used = [Bool](repeating: false, count: runs.count)
            for s in open {
                if let i = runs.indices.first(where: { !used[$0] && min(runs[$0].1, s.x1) - max(runs[$0].0, s.x0) > min(runs[$0].1 - runs[$0].0, s.x1 - s.x0) / 2 }) {
                    used[i] = true
                    next.append((min(s.x0, runs[i].0), max(s.x1, runs[i].1), s.y0, y, y, s.area + runs[i].1 - runs[i].0 + 1))
                } else if y - s.last <= 2 { next.append(s) }
                else { done.append(segment(s)) }
            }
            for (i, r) in runs.enumerated() where !used[i] { next.append((r.0, r.1, y, y, y, r.1 - r.0 + 1)) }
            open = next
        }
        for s in open { done.append(segment(s)) }
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
            let rows = cluster(hs.map(\.c), tolerance: tol)
            var cols = cluster(vs.map(\.c), tolerance: tol)
            guard rows.count >= 2, cols.count >= 2 else { continue }
            // Open-sided tables (rules across, walls only between columns): the
            // ends of the row rules are the table's outer edges.
            // A photographed rule is found in tilted pieces: each row rule spans
            // from its leftmost to its rightmost piece.
            let spans = rows.map { y -> (Double, Double) in
                let pieces = hs.filter { abs($0.c - y) <= tol }
                var a = pieces.map(\.a0).min() ?? 0, b = pieces.map(\.a1).max() ?? 0
                var ya = pieces.min { $0.a0 < $1.a0 }?.c ?? y, yb = pieces.max { $0.a1 < $1.a1 }?.c ?? y
                // Follow touching pieces outward; each may sit a little higher or lower.
                var grew = true
                while grew {
                    grew = false
                    if let p = horizontal.filter({ $0.a0 < a && $0.a1 >= a - tol * 3 && abs($0.c - ya) <= tol * 0.6 }).min(by: { $0.a0 < $1.a0 }) { a = p.a0; ya = p.c; grew = true }
                    if let p = horizontal.filter({ $0.a1 > b && $0.a0 <= b + tol * 3 && abs($0.c - yb) <= tol * 0.6 }).max(by: { $0.a1 < $1.a1 }) { b = p.a1; yb = p.c; grew = true }
                }
                return (a, b)
            }
            if spans.count >= 2 {
                let left = spans.map(\.0).sorted()[spans.count / 2], right = spans.map(\.1).sorted()[spans.count / 2]
                if left < cols[0] - textHeight * 1.5 { cols.insert(left, at: 0) }
                if right > cols[cols.count - 1] + textHeight * 1.5 { cols.append(right) }
            }
            // A band (e.g. a shaded section title) closed by a free rule just
            // above or below the table is one more row across the table.
            var rowsOut = rows
            let width = cols[cols.count - 1] - cols[0]
            let others = horizontal.filter { h in !hs.contains { $0.c == h.c && $0.a0 == h.a0 } }
            func ruleAt(_ y: Double) -> Bool {
                let pieces = others.filter { abs($0.c - y) <= tol }.map { (max($0.a0, cols[0]), min($0.a1, cols[cols.count - 1])) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
                var covered = 0.0, end = cols[0]
                for p in pieces { if p.1 > end { covered += p.1 - max(p.0, end); end = p.1 } }
                return covered >= width * 0.8
            }
            let candidates = cluster(others.map(\.c), tolerance: tol)
            if let above = candidates.filter({ $0 < rowsOut[0] - textHeight * 1.2 && $0 > rowsOut[0] - textHeight * 3.5 }).max(), ruleAt(above) { rowsOut.insert(above, at: 0) }

            if let table = buildRuledTable(ink, rows: rowsOut, columns: cols, tolerance: Int(max(3, tol / 2))) { tables.append(table) }
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
            let from = rows[r] + inset, to = rows[r + 1] - inset
            if ink.coverage(vertical: columns[c + 1], from: from, to: to, tolerance: tolerance) >= 0.6 { return true }
            // The same rule a little to the side (bent or tilted photo), if it is
            // a thin solid line rather than the stroke of a letter.
            let reach = Int(min(columns[c + 1] - columns[c], columns[c + 2] - columns[c + 1]) * 0.15)
            guard reach > tolerance else { return false }
            for d in stride(from: -reach, through: reach, by: max(1, tolerance)) where d != 0 {
                let x = columns[c + 1] + Double(d)
                let here = ink.coverage(vertical: x, from: from, to: to, tolerance: tolerance)
                guard here >= 0.8 else { continue }
                let clear = Double(tolerance * 2 + 3)
                if min(ink.coverage(vertical: x - clear, from: from, to: to, tolerance: tolerance),
                       ink.coverage(vertical: x + clear, from: from, to: to, tolerance: tolerance)) < here - 0.4 { return true }
            }
            return false
        }
        func wallBelow(_ r: Int, _ c: Int) -> Bool {   // between (r,c) and (r+1,c)
            let inset = (columns[c + 1] - columns[c]) * 0.08
            let from = columns[c] + inset, to = columns[c + 1] - inset
            if ink.coverage(horizontal: rows[r + 1], from: from, to: to, tolerance: tolerance) >= 0.6 { return true }
            // Photographed rules bend, so in one column the rule can sit a little
            // above or below the row line measured across the whole table.
            let reach = Int(min(rows[r + 1] - rows[r], rows[r + 2] - rows[r + 1]) * 0.3)
            guard reach > tolerance else { return false }
            func rule(_ a: Double, _ b: Double) -> Bool {
                for d in stride(from: -reach, through: reach, by: max(1, tolerance)) {
                    let y = rows[r + 1] + Double(d)
                    let here = ink.coverage(horizontal: y, from: a, to: b, tolerance: tolerance)
                    guard here >= 0.6 else { continue }
                    // A rule is thin and solid: just beside it the path is clearly
                    // emptier (a line of text looks the same a little higher or lower).
                    let clear = Double(tolerance * 2 + 3)
                    if min(ink.coverage(horizontal: y - clear, from: a, to: b, tolerance: tolerance),
                           ink.coverage(horizontal: y + clear, from: a, to: b, tolerance: tolerance)) < here - 0.3 { return true }
                }
                return false
            }
            if rule(from, to) { return true }
            // A tilted rule across a wide column: each quarter finds it at its own height.
            let quarter = (to - from) / 4
            guard quarter > Double(tolerance * 6) else { return false }
            return (0..<4).filter { rule(from + Double($0) * quarter, from + Double($0 + 1) * quarter) }.count >= 4
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
        // A faint header band (the photo washes light tints toward white): the
        // first row clearly darker than the body rows, evenly across.
        if R >= 2, cells.filter({ $0.row == 0 }).allSatisfy({ $0.fill == nil }) {
            let head = cells.filter { $0.row == 0 && $0.rowSpan == 1 }.compactMap { ink.fill($0.box) }
            let body = cells.filter { $0.row > 0 }.compactMap { ink.fill($0.box) }
            func lum(_ c: LayoutColor) -> Double { (Double(c.r) + Double(c.g) + Double(c.b)) / 3 }
            if head.count == cells.filter({ $0.row == 0 && $0.rowSpan == 1 }).count, head.count >= 2, !body.isEmpty {
                let hl = head.map(lum), bl = body.map(lum).sorted()[body.count / 2]
                if hl.allSatisfy({ bl - $0 >= 5 }), bl - hl.reduce(0, +) / Double(hl.count) >= 8, (hl.max()! - hl.min()!) < 8 {
                    let n = Double(head.count)
                    let avg = (head.map { Double($0.r) }.reduce(0, +) / n, head.map { Double($0.g) }.reduce(0, +) / n, head.map { Double($0.b) }.reduce(0, +) / n)
                    func deepen(_ v: Double) -> UInt8 { UInt8(max(0, min(255, 255 - (255 - v) * 2.2))) }
                    let tint = LayoutColor(r: deepen(avg.0), g: deepen(avg.1), b: deepen(avg.2))
                    for i in cells.indices where cells[i].row == 0 { cells[i].fill = tint }
                }
            }
        }
        spreadRowFills(&cells, ink: ink)
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
            let r = Int((s.extent / 2).rounded(.up)) + 1
            for y in max(0, Int(s.c) - r)...min(H - 1, Int(s.c) + r) { for x in max(0, Int(s.a0))..<min(W, Int(s.a1)) { textInk.dark[y * W + x] = false } }
        }
        for s in vSegments {
            let r = Int((s.extent / 2).rounded(.up)) + 1
            for x in max(0, Int(s.c) - r)...min(W - 1, Int(s.c) + r) { for y in max(0, Int(s.a0))..<min(H, Int(s.a1)) { textInk.dark[y * W + x] = false } }
        }
        // Recognized word boxes are padded; snap their sides to the ink.
        for li in wordLines.indices { for wi in wordLines[li].indices {
            if let tight = textInk.inkColumns(wordLines[li][wi].box) { wordLines[li][wi].box.x0 = tight.0; wordLines[li][wi].box.x1 = tight.1 }
        } }
        // Body text sets the regular stroke weight of this page.
        var scores: [Double] = []
        for line in wordLines {
            let size = fontSize(line, ink: textInk, ptPerPx: ptPerPx)
            for w in line { if let score = boldScore([w], ink: textInk, fontPt: size) { scores.append(score) } }
        }
        if scores.count >= 8 {
            scores.sort()
            textInk.boldThreshold = max(1.15, min(1.3, scores[scores.count / 2] * 1.27))
        }

        var free: [Word] = []
        var tableWords: [[Word]] = Array(repeating: [], count: tables.count)
        // A page with many separate boxes is a form: its line art becomes one
        // picture behind the page and every line of text is placed exactly.
        let form = tables.count >= 5
        if form {
            let walls = vSegments
            let splitter: (Word, Word) -> Bool = { a, b in
                walls.contains { $0.c > a.box.x1 - 3 && $0.c < b.box.x0 + 3 && $0.a0 < max(a.box.y1, b.box.y1) && $0.a1 > min(a.box.y0, b.box.y0) }
            }
            // Strokes of bold letters can look like short rules; a rule is kept
            // only where it runs outside the words.
            let wordBoxes = wordLines.flatMap { $0.map(\.box) }
            func inText(_ box: LBox) -> Bool {
                let covered = wordBoxes.filter { $0.overlapY(box) >= box.height * 0.8 }.reduce(0.0) { $0 + $1.overlapX(box) }
                    + wordBoxes.filter { $0.overlapX(box) >= box.width * 0.8 }.reduce(0.0) { $0 + $1.overlapY(box) }
                return covered >= max(box.width, box.height) * 0.6
            }
            let keeps = (hSegments.map { LBox($0.a0, $0.c - $0.extent / 2 - 1.5, $0.a1, $0.c + $0.extent / 2 + 1.5) }
                + vSegments.map { LBox($0.c - $0.extent / 2 - 1.5, $0.a0, $0.c + $0.extent / 2 + 1.5, $0.a1) }).filter { !inText($0) }
            var paragraphs: [LayoutParagraph] = []
            // Each recognized line stays one piece of text, cut where a box wall
            // or a wide gap separates its words.
            for line in wordLines {
                var pieces: [[Word]] = []
                for w in line.sorted(by: { $0.box.x0 < $1.box.x0 }) {
                    if let last = pieces.last?.last, w.box.x0 - last.box.x1 <= max(last.box.height, w.box.height) * 1.2, !splitter(last, w) { pieces[pieces.count - 1].append(w) }
                    else { pieces.append([w]) }
                }
                for var piece in pieces {
                    // Stop at box walls: a rule is ink too.
                    let first = textInk.extendedAlongInk(piece[0].box, left: true, right: false, rules: keeps)
                    if !walls.contains(where: { $0.c > first.x0 - 2 && $0.c < piece[0].box.x0 && $0.a0 < first.y1 && $0.a1 > first.y0 }) { piece[0].box = first }
                    let last = textInk.extendedAlongInk(piece[piece.count - 1].box, left: false, right: true, rules: keeps)
                    if !walls.contains(where: { $0.c < last.x1 + 2 && $0.c > piece[piece.count - 1].box.x1 && $0.a0 < last.y1 && $0.a1 > last.y0 }) { piece[piece.count - 1].box = last }
                    let visual = VisualLine(words: piece, box: LBox.around(piece.map(\.box))!)
                    for var p in buildParagraphs([visual], ink: textInk, width: Double(W), ptPerPx: ptPerPx, gap: 1e9, merge: false, bullets: false) {
                        guard var seg = p.lines.first?.segments.first, p.lines.count == 1, p.lines[0].segments.count == 1 else { continue }
                        seg.ink = piece.map { w -> LBox in
                            let rows = textInk.inkRows(w.box) ?? (w.box.y0, w.box.y1)
                            let pad = max(2, (rows.1 - rows.0) * 0.2)
                            return LBox(w.box.x0 - pad, min(rows.0, w.box.y0) - pad, w.box.x1 + pad, max(rows.1, w.box.y1) + pad)
                        }
                        // Short labels have too few strokes to tell weights word by word.
                        let bold = seg.runs.filter(\.bold).reduce(0, { $0 + $1.text.count }) * 2 > seg.text.count
                        seg.runs = [LayoutRun(text: seg.text, bold: bold, underline: seg.runs.contains(where: \.underline), color: seg.runs.first?.color)]
                        // Printed width decides the size within reason; spacing does the rest.
                        var fontSize = seg.fontSize ?? p.fontSize
                        let natural = naturalWidth(seg.text, size: fontSize, bold: bold)
                        if seg.text.count >= 3, natural > 0 { fontSize = min(fontSize * 1.2, max(fontSize * 0.75, fontSize * seg.box.width * ptPerPx / natural)) }
                        seg.fontSize = fontSize; p.fontSize = fontSize
                        p.letterSpacing = fittingSpacing(text: seg.text, width: seg.box.width * ptPerPx, size: fontSize, bold: bold, exact: true)
                        p.alignment = .left
                        p.lines[0].segments[0] = seg
                        paragraphs.append(p)
                    }
                }
            }
            let art = LayoutGraphic(box: LBox(0, 0, Double(W), Double(H)), cutout: true, keeps: keeps)
            var page = PageLayout(width: W, height: H, pageWidth: size.0, pageHeight: size.1,
                                  items: paragraphs.sorted { $0.box.y0 < $1.box.y0 }.map { .paragraph($0) }, graphics: [art])
            page.positioned = true
            page.form = true
            keepText(&page) { _ in true }
            return page
        }
        for line in wordLines { for word in line {
            // Nested boxes: a word belongs to the smallest box around it.
            let holders = tables.indices.filter { tables[$0].box.contains(x: word.box.midX, y: word.box.midY) }
            if let t = holders.min(by: { tables[$0].box.width * tables[$0].box.height < tables[$1].box.width * tables[$1].box.height }) { tableWords[t].append(word) }
            else { free.append(word) }
        } }
        for t in tables.indices where tables[t].ruled { mergeCrossedWalls(&tables[t], words: tableWords[t]) }
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
        for group in form ? [] : borderlessGroups(lines, width: Double(W)) {
            if let table = borderlessTable(lines, rows: group, ink: textInk, ptPerPx: ptPerPx) {
                tables.append(table); group.forEach { consumed.insert($0) }
            }
        }
        for t in tables.indices { fixCodeColumns(&tables[t]); harmonizeRanges(&tables[t]); tidyRecognizedText(&tables[t]) }
        let remaining = lines.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
        var paragraphs = buildParagraphs(remaining, ink: textInk, width: Double(W), ptPerPx: ptPerPx)
        normalizeCheckboxes(&paragraphs)

        // Graphics: remaining ink that is neither text nor table.
        var textBoxes = wordLines.flatMap { $0.map { $0.box } }
        textBoxes += tables.map { $0.box.inset(-12) }
        let underlineBoxes = usedRules.map { looseRules[$0] }.map { LBox($0.a0, $0.c - $0.extent, $0.a1, $0.c + $0.extent) }
        var graphics = findGraphics(ink, excluding: textBoxes + underlineBoxes, textHeight: textHeight)
        // Slivers along the photo's edge are shadow or background, not art.
        graphics.removeAll { g in
            let edge = g.box.x0 <= 2 || g.box.y0 <= 2 || g.box.x1 >= Double(W) - 2 || g.box.y1 >= Double(H) - 2
            return edge && min(g.box.width, g.box.height) < textHeight
        }
        // A page frame (a thin border drawn around the text) is not a picture:
        // a picture of it would carry every word inside it a second time.
        let allWords = wordLines.flatMap { $0.map(\.box) }
        graphics.removeAll { g in
            let inside = allWords.filter { g.box.contains(x: $0.midX, y: $0.midY) }
            guard inside.count >= 3 else { return false }
            var dark = 0, total = 0
            let step = 3
            for y in stride(from: Int(g.box.y0), to: Int(g.box.y1), by: step) { for x in stride(from: Int(g.box.x0), to: Int(g.box.x1), by: step) {
                guard x >= 0, y >= 0, x < W, y < H else { continue }
                if inside.contains(where: { $0.contains(x: Double(x), y: Double(y)) }) || tables.contains(where: { $0.box.contains(x: Double(x), y: Double(y)) }) { continue }
                total += 1; if ink.isDark(x, y) { dark += 1 }
            } }
            return total > 0 && Double(dark) / Double(total) < 0.05
        }

        var items: [LayoutItem] = paragraphs.map { .paragraph($0) } + tables.map { .table($0) }
        items.sort { $0.box.y0 < $1.box.y0 }
        var page = PageLayout(width: W, height: H, pageWidth: size.0, pageHeight: size.1, items: items, graphics: graphics)
        page.positioned = form || overlaps(items)
        tidyParagraphs(&page)
        return page
    }


    /// Keeps only the form text `keep` accepts; the rest stays in the page
    /// picture, which loses exactly the ink of the text that is kept.
    static func keepText(_ page: inout PageLayout, _ keep: (LayoutSegment) -> Bool) {
        guard page.form else { return }
        var dropped: [LBox] = []
        // A rule running through the letters keeps part of them in the picture,
        // so such text stays printed rather than drawn twice.
        let rules = page.graphics.first?.keeps ?? []
        func struck(_ s: LayoutSegment) -> Bool {
            let band = LBox(s.box.x0, s.box.y0 + s.box.height * 0.3, s.box.x1, s.box.y1 - s.box.height * 0.15)
            return rules.contains { $0.width > $0.height && $0.overlapY(band) > 0 && $0.overlapX(band) > band.width * 0.3 }
        }
        page.items = page.items.filter { item in
            guard case .paragraph(let p) = item else { return true }
            let segments = p.lines.flatMap(\.segments)
            if segments.allSatisfy({ keep($0) && !struck($0) }) { return true }
            dropped += segments.map(\.box)
            return false
        }
        // Two readings of the same print overlap; neither can be trusted alone.
        func crosses(_ a: LBox, _ b: LBox) -> Bool {
            a.overlapX(b) * a.overlapY(b) > min(a.width * a.height, b.width * b.height) * 0.05
        }
        let boxes = page.items.map(\.box)
        let doubled = Set(boxes.indices.filter { i in boxes.indices.contains { j in j != i && crosses(boxes[i], boxes[j]) } })
        dropped += doubled.map { boxes[$0] }
        page.items = page.items.enumerated().filter { !doubled.contains($0.offset) }.map(\.element)
        // Text crossing text that stays in the picture stays there too, so no
        // letter is drawn twice.
        var changed = true
        while changed {
            changed = false
            page.items = page.items.filter { item in
                guard case .paragraph(let p) = item else { return true }
                let crossing = dropped.contains { d in
                    crosses(d, p.box)
                }
                if crossing { dropped += p.lines.flatMap { $0.segments.map(\.box) }; changed = true }
                return !crossing
            }
        }
        let masks = page.items.flatMap { item -> [LBox] in
            guard case .paragraph(let p) = item else { return [] }
            return p.lines.flatMap { $0.segments.flatMap { $0.ink ?? [$0.box] } }
        }
        // Text left in the picture is never erased by a neighbour's mask.
        for g in page.graphics.indices where g == 0 { page.graphics[g].masks = masks; page.graphics[g].keeps += dropped }
    }

    /// True when every word of `text` is spelled correctly (`isWord` checks one
    /// word) or is a short code in capitals. Numbers and words mixed
    /// with digits cannot be checked this way and are never plausible.
    static func plausibleText(_ text: String, isWord: (String) -> Bool) -> Bool {
        let elisions: Set<String> = ["d", "l", "n", "s", "j", "c", "m", "t", "qu"]
        var words = 0
        // A lone letter before an apostrophe is a French elision: "l'employé", not "T'employé".
        for (n, token) in text.split(whereSeparator: \.isWhitespace).enumerated() {
            let parts = token.split(whereSeparator: { "'’".contains($0) })
            if parts.count > 1, let first = parts.first, first.count == 1, n > 0, !elisions.contains(String(first)) { return false }
        }
        guard latin(text), balanced(text) else { return false }
        for token in text.split(whereSeparator: { $0.isWhitespace || "-–/()&,.:;'’".contains($0) }) {
            let word = String(token)
            if word.contains(where: \.isNumber) { return false }
            guard word.allSatisfy(\.isLetter) else { return false }
            words += 1
            if word.count == 1 { continue }
            if word == word.uppercased() && word.count <= 2 { continue }
            if elisions.contains(word.lowercased()) { continue }
            // "pA": a capital after a small letter is a misread, not a word.
            if zip(word, word.dropFirst()).contains(where: { $0.isLowercase && $1.isUppercase }) { return false }
            // Spell checkers accept any word in capitals, so check it in lower case.
            if !isWord(word == word.uppercased() ? word.lowercased() : word) { return false }
            // "l'employé" is often read "remployé": both spellings exist, so neither is sure.
            if word.first == "r", let next = word.dropFirst().first, "aeéèêiouyh".contains(next), isWord(String(word.dropFirst())) { return false }
        }
        return words > 0
    }

    /// Letters only from the Latin alphabets (a misread "BC" can come back Cyrillic).
    static func latin(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { !CharacterSet.letters.contains($0) || $0.value < 0x250 }
    }
    static func balanced(_ text: String) -> Bool {
        text.filter { $0 == "(" }.count == text.filter { $0 == ")" }.count
    }
    /// Text that a second, separate reading confirmed can still be a rule or
    /// box wall read as a character; only clean entries count.
    static func confirmable(_ text: String) -> Bool {
        guard latin(text), balanced(text) else { return false }
        let chars = Array(text)
        for (k, c) in chars.enumerated() where "/|\\[]{}".contains(c) {
            if k > 0, k + 1 < chars.count, chars[k - 1].isNumber || chars[k + 1].isNumber { return false }
            if k == 0 || k + 1 == chars.count { return false }
        }
        return true
    }

    /// True when two items share page height side by side, which flowing text cannot reproduce.
    static func overlaps(_ items: [LayoutItem]) -> Bool {
        for (i, a) in items.enumerated() { for b in items[(i + 1)...] {
            if a.box.overlapY(b.box) > min(a.box.height, b.box.height) * 0.3 && a.box.overlapX(b.box) < min(a.box.width, b.box.width) * 0.5 { return true }
        } }
        return false
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
            let bold = (boldScore([w], ink: ink, fontPt: fontPt) ?? 1) >= ink.boldThreshold
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
            if share > 0.7 || share < 0.25 || runs.filter({ $0.bold }).allSatisfy({ $0.text.count <= 2 }) {
                let bold = share > 0.7
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
                        // "81" in a column of codes is "B1" read as a digit.
                        if word.count >= 2, word.count <= 4, word.first == "8", word.dropFirst().allSatisfy(\.isNumber) { return "B" + word.dropFirst() }
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
    /// Spaces that recognition puts inside dotted numbers ("10.41.22. xx",
    /// "192.168 .10.xx") are removed; ordinary sentences are left alone because
    /// the number needs two dots before the gap.
    static func joinedDottedNumbers(_ text: String) -> String {
        guard text.contains("."), text.contains(" ") else { return text }
        let pattern = #"(?<![\w.])(\d{1,3}(?:\s?\.\s?\d{1,3}){2,4})\s?\.\s+(\d{1,3}|[xX]{1,3})(?![\w])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        // Repeat so a number with several gaps closes up completely.
        for _ in 0..<3 {
            let range = NSRange(result.startIndex..., in: result)
            var changed = false
            for match in regex.matches(in: result, range: range).reversed() {
                guard let whole = Range(match.range, in: result), let head = Range(match.range(at: 1), in: result), let tail = Range(match.range(at: 2), in: result) else { continue }
                let joined = result[head].filter { !$0.isWhitespace } + "." + result[tail]
                if joined != result[whole] { result.replaceSubrange(whole, with: joined); changed = true }
            }
            if !changed { break }
        }
        let inner = #"(?<=\d)\s+\.(?=\d)|(?<=\d\.\d{1,3})\.\s+(?=\d{1,3}\.)"#
        if let regex = try? NSRegularExpression(pattern: inner) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ".")
        }
        return result
    }
    /// Small recognition slips in table text: spaces inside dotted numbers and,
    /// in a column whose names end in a bracket ("Finch(핀치)"), a closing
    /// bracket the reader dropped.
    static func tidyRecognizedText(_ table: inout LayoutTable) {
        for i in table.cells.indices {
            table.cells[i].lines = table.cells[i].lines.map { line in line.map { run in
                var run = run; run.text = joinedDottedNumbers(run.text); return run
            } }
        }
        func unclosed(_ text: String) -> Bool {
            guard let open = text.lastIndex(of: "(") else { return false }
            let after = text[text.index(after: open)...]
            return !after.contains(")") && !after.trimmingCharacters(in: .whitespaces).isEmpty && after.count <= 24
        }
        func closed(_ text: String) -> Bool {
            let t = text.trimmingCharacters(in: .whitespaces)
            return t.hasSuffix(")") && t.contains("(")
        }
        for c in 0..<table.columnCount {
            let cells = table.cells.indices.filter { table.cells[$0].column == c && !table.cells[$0].lines.isEmpty }
            let texts = cells.map { table.cells[$0].text }
            let bracketed = texts.filter(closed).count
            guard bracketed >= 2, bracketed * 2 >= texts.filter({ $0.contains("(") }).count else { continue }
            for i in cells where unclosed(table.cells[i].text) {
                let l = table.cells[i].lines.count - 1
                guard let r = table.cells[i].lines[l].indices.last else { continue }
                var text = table.cells[i].lines[l][r].text
                while text.last == " " { text.removeLast() }
                table.cells[i].lines[l][r].text = text + ")"
            }
        }
    }
    /// Ranges in one column ("518 - 689", "476-479") share the spacing most
    /// of them use, so recognition noise does not show as uneven dashes.
    static func harmonizeRanges(_ table: inout LayoutTable) {
        func parts(_ text: String) -> (String, String, Bool)? {
            let dashes: Set<Character> = ["-", "–", "—"]
            guard let i = text.firstIndex(where: { dashes.contains($0) }), text.filter({ dashes.contains($0) }).count == 1 else { return nil }
            let left = text[..<i], right = text[text.index(after: i)...]
            let l = left.trimmingCharacters(in: .whitespaces), r = right.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !r.isEmpty, !l.contains(" "), !r.contains(" ") else { return nil }
            return (l, r, left.hasSuffix(" ") && right.hasPrefix(" "))
        }
        for c in 0..<table.columnCount {
            let cells = table.cells.indices.filter { table.cells[$0].column == c && table.cells[$0].lines.count == 1 && table.cells[$0].lines[0].count == 1 }
            let ranges = cells.compactMap { i in parts(table.cells[i].text).map { (i, $0) } }
            guard ranges.count >= 3 else { continue }
            let spaced = ranges.filter { $0.1.2 }.count * 2 >= ranges.count
            for (i, p) in ranges { table.cells[i].lines[0][0].text = spaced ? "\(p.0) - \(p.1)" : "\(p.0)-\(p.1)" }
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
            // Several lines starting at one edge but ending apart are set flush
            // to that edge, even when the longest line nearly fills the cell.
            if lines.count >= 2 {
                let boxes = lines.compactMap { LBox.around($0.words.map(\.box)) }
                let h = boxes.map(\.height).sorted()[boxes.count / 2]
                func spread(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
                let l = spread(boxes.map(\.x0)), r = spread(boxes.map(\.x1)), m = spread(boxes.map(\.midX))
                if l <= h * 0.6 && l < m && l < r { table.cells[i].alignment = .left }
                else if r <= h * 0.6 && r < m && r < l { table.cells[i].alignment = .right }
            }
            scores[i] = boldScore(ws, ink: ink, fontPt: size)
        }
        // A wide line that looks centered in a column of flush-left cells is
        // flush left too when it starts where the others start.
        for c in 0..<table.columnCount {
            let idx = table.cells.indices.filter { table.cells[$0].column == c && table.cells[$0].columnSpan == 1 && byCell[$0] != nil }
            let starts = idx.filter { table.cells[$0].alignment == .left }.map { i in LBox.around(byCell[i]!.map(\.box))!.x0 - table.cells[i].box.x0 }
            guard starts.count >= 2 else { continue }
            let start = starts.sorted()[starts.count / 2]
            for i in idx where table.cells[i].alignment == .center && table.cells[i].lines.count == 1 {
                let b = LBox.around(byCell[i]!.map(\.box))!
                if abs((b.x0 - table.cells[i].box.x0) - start) <= b.height * 0.8 { table.cells[i].alignment = .left }
            }
        }
        for (i, ws) in byCell where table.cells[i].alignment == .left { table.cells[i].indent = max(0, LBox.around(ws.map(\.box))!.x0 - table.cells[i].box.x0) }
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
    static func buildParagraphs(_ lines: [VisualLine], ink: Ink, width: Double, ptPerPx: Double,
                                gap: Double = 1.6, splitter: ((Word, Word) -> Bool)? = nil, merge: Bool = true, bullets: Bool = true) -> [LayoutParagraph] {
        struct Info { var line: VisualLine; var size: Double; var bullet: LBox?; var marker: String?; var textBox: LBox; var segments: [LayoutSegment] }
        var infos: [Info] = []
        for line in lines {
            var words = line.words
            var bullet: LBox?
            var marker: String?
            // "- 1 -" is a page number, not a list item.
            let pageNumber = words.first?.text == "-" && words.dropFirst().allSatisfy { $0.text.allSatisfy { $0.isNumber || $0 == "-" } }
            if !bullets || pageNumber {
            } else if let first = words.first, checkboxGlyphs.contains(first.text), words.count > 1 {
                bullet = first.box; marker = "□"; words.removeFirst()
            } else if let first = words.first, bulletGlyphs.contains(first.text), words.count > 1, first.text != "-" || words[1].box.x0 - first.box.x1 > first.box.height * 0.3 {
                bullet = first.box; words.removeFirst()
            } else if let first = words.first, let b = detectBullet(ink, before: first.box) {
                bullet = b
                if hollow(ink, b) { marker = "□" }
            }
            var segs: [[Word]] = []
            let h = (line.words.map(\.box.height).sorted())[line.words.count / 2]
            for w in words {
                if let last = segs.last?.last, w.box.x0 - last.box.x1 <= h * gap, !(splitter?(last, w) ?? false) { segs[segs.count - 1].append(w) } else { segs.append([w]) }
            }
            if var first = segs.first?.first, segs[0].count > 0 { first.spaceBefore = false; segs[0][0] = first }
            guard !segs.isEmpty else { continue }
            let segments = segs.map { s -> LayoutSegment in
                var copy = s; copy[0].spaceBefore = false
                var size = fontSize(s, ink: ink, ptPerPx: ptPerPx)
                // A tilted or noisy line measures too tall; its width tells the truth.
                let text = s.enumerated().map { ($0.offset > 0 && $0.element.spaceBefore ? " " : "") + $0.element.text }.joined()
                let ems = text.reduce(0.0) { $0 + glyphWidth($1) }
                if text.count >= 8, ems > 0 {
                    let byWidth = (LBox.around(s.map(\.box))!.width * ptPerPx) / ems
                    if size > byWidth * 1.3 { size = byWidth }
                }
                return LayoutSegment(runs: runs(copy, ink: ink, fontPx: size / ptPerPx), box: LBox.around(s.map(\.box))!, fontSize: size)
            }
            let size = segments[0].fontSize ?? 10
            guard let textBox = LBox.around(words.map(\.box)) else { continue }
            infos.append(Info(line: line, size: size, bullet: bullet, marker: marker, textBox: textBox, segments: segments))
        }
        let contentRight = infos.map(\.textBox.x1).max() ?? width
        var paragraphs: [LayoutParagraph] = []
        var i = 0
        while i < infos.count {
            var group = [infos[i]]
            var j = i + 1
            while merge && j < infos.count {
                let prev = group.last!, next = infos[j]
                guard prev.segments.count == 1, next.segments.count == 1, next.bullet == nil else { break }
                let h = max(prev.textBox.height, next.textBox.height)
                let gap = next.textBox.y0 - prev.textBox.y1
                let sameSize = abs(prev.size - next.size) <= max(prev.size, next.size) * 0.15
                let sameLeft = abs(prev.textBox.x0 - next.textBox.x0) <= width * 0.012
                let sameCenter = abs(prev.textBox.midX - next.textBox.midX) <= width * 0.015 && !sameLeft
                guard gap <= h * 0.75, gap > -h * 0.3, sameSize, sameLeft || sameCenter else { break }
                // A list item continues only with its own wrapped text.
                if group[0].bullet != nil && contentRight - prev.textBox.x1 > (next.segments.first?.box.width ?? 0) + h * 1.5 { break }
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
            paragraphs.append(LayoutParagraph(lines: lines, box: box, fontSize: size, alignment: alignment, bullet: group[0].bullet, marker: group[0].marker, letterSpacing: spacing, linePitch: pitch))
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
    static func fittingSpacing(text: String, width: Double, size: Double, bold: Bool, exact: Bool = false) -> Double {
        let count = Double(max(1, text.count - 1))
        guard text.count >= 3 else { return 0 }
        let extra = (width - naturalWidth(text, size: size, bold: bold)) / count
        if exact { return max(-size * 0.06, min(size * 0.15, extra)) }
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
        let region = LBox(box.x0 - h * 1.9, box.y0 + h * 0.15, box.x0 - h * 0.1, box.y1 - h * 0.15)
        guard region.x0 > 0 else { return nil }
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min, count = 0
        for y in Int(region.y0)..<Int(region.y1) { for x in Int(region.x0)..<Int(region.x1) where ink.isDark(x, y) {
            count += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard count > 4 else { return nil }
        let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
        // A bullet is a small, filled, roughly square dot set apart from the text.
        guard bw <= h * 0.45, bh <= h * 0.45, bw >= h * 0.12, abs(bw - bh) <= max(bw, bh) * 0.35,
              Double(count) >= bw * bh * 0.55, box.x0 - Double(maxX + 1) >= h * 0.25 else { return nil }
        return LBox(Double(minX), Double(minY), Double(maxX + 1), Double(maxY + 1))
    }

    /// A box mark whose middle is paper: an empty checkbox rather than a dot.
    static func hollow(_ ink: Ink, _ b: LBox) -> Bool {
        let inner = b.inset(min(b.width, b.height) * 0.3)
        guard inner.width >= 2, inner.height >= 2 else { return false }
        var dark = 0, total = 0
        for y in Int(inner.y0)..<Int(inner.y1) { for x in Int(inner.x0)..<Int(inner.x1) { total += 1; if ink.isDark(x, y) { dark += 1 } } }
        return total > 0 && Double(dark) / Double(total) < 0.35
    }

    /// On a page of checkbox headings, a box misread as a letter or digit
    /// ("ㅁ", "1", "]") at the start of a bold line is a checkbox too.
    static func normalizeCheckboxes(_ paragraphs: inout [LayoutParagraph]) {
        let lookalikes: Set<String> = ["ㅁ", "口", "ロ", "□", "☐", "1", "l", "I", "|", "]", "[]", "0", "o", "O"]
        func leading(_ p: LayoutParagraph) -> String? {
            guard let run = p.lines.first?.segments.first?.runs.first else { return nil }
            let token = String(run.text.prefix { $0 != " " })
            return token.count < run.text.count ? token : nil
        }
        // "1별지 제13호서식]": an opening bracket read as a digit or letter.
        for i in paragraphs.indices { for l in paragraphs[i].lines.indices { for g in paragraphs[i].lines[l].segments.indices { for r in paragraphs[i].lines[l].segments[g].runs.indices {
            paragraphs[i].lines[l].segments[g].runs[r].text = restoredBracket(paragraphs[i].lines[l].segments[g].runs[r].text)
        } } } }
        let boxes = paragraphs.filter { $0.marker == "□" || ["ㅁ", "口", "ロ", "□", "☐"].contains(leading($0) ?? "") }.count
        guard boxes >= 2 else { return }
        // Bullets on a checkbox page are checkboxes that printed too heavy to look hollow.
        for i in paragraphs.indices where paragraphs[i].bullet != nil && paragraphs[i].marker == nil { paragraphs[i].marker = "□" }
        for i in paragraphs.indices where paragraphs[i].marker == nil && paragraphs[i].alignment == .left {
            guard let token = leading(paragraphs[i]), lookalikes.contains(token) else { continue }
            let strong = ["ㅁ", "口", "ロ", "□", "☐"].contains(token)
            guard strong || paragraphs[i].lines[0].segments[0].runs.contains(where: \.bold) else { continue }
            var run = paragraphs[i].lines[0].segments[0].runs[0]
            run.text = String(run.text.dropFirst(token.count).drop { $0 == " " })
            if run.text.isEmpty { paragraphs[i].lines[0].segments[0].runs.removeFirst() } else { paragraphs[i].lines[0].segments[0].runs[0] = run }
            paragraphs[i].marker = "□"
            let b = paragraphs[i].lines[0].box
            paragraphs[i].bullet = LBox(b.x0, b.y0, b.x0 + b.height * 0.7, b.y1)
        }
    }

    /// Final clean-up of paragraph text after any re-reading: checkbox lines
    /// lose a misread box glyph, brackets read as digits come back, and stray
    /// punctuation specks at a line end are dropped.
    static func tidyParagraphs(_ page: inout PageLayout) {
        let lookalikes: Set<String> = ["ㅁ", "口", "ロ", "□", "☐", "1", "l", "I", "|", "]", "[]", "0", "o", "O"]
        for index in page.items.indices {
            guard case .paragraph(var p) = page.items[index] else { continue }
            for l in p.lines.indices { for g in p.lines[l].segments.indices { for r in p.lines[l].segments[g].runs.indices {
                p.lines[l].segments[g].runs[r].text = restoredBracket(p.lines[l].segments[g].runs[r].text)
            } } }
            for l in p.lines.indices {
                guard let g = p.lines[l].segments.indices.last, let r = p.lines[l].segments[g].runs.indices.last else { continue }
                var text = p.lines[l].segments[g].runs[r].text
                if let range = text.range(of: #"\s+[.,~·`'_\-]{2,}$"#, options: .regularExpression) { text.removeSubrange(range); p.lines[l].segments[g].runs[r].text = text }
            }
            if p.marker != nil, var run = p.lines.first?.segments.first?.runs.first {
                let token = String(run.text.prefix { $0 != " " })
                if lookalikes.contains(token), token.count < run.text.count {
                    run.text = String(run.text.dropFirst(token.count).drop { $0 == " " })
                    p.lines[0].segments[0].runs[0] = run
                }
            }
            page.items[index] = .paragraph(p)
        }
    }

    static func restoredBracket(_ text: String) -> String {
        guard let close = text.firstIndex(of: "]"), !text[..<close].contains("[") else { return text }
        let chars = Array(text[..<close])
        var k = chars.count - 2
        while k >= 0 {
            let spaced = chars[k + 1] == " " && k + 2 < chars.count && isWide(chars[k + 2])
            if "1lI|".contains(chars[k]), isWide(chars[k + 1]) || spaced, k == 0 || chars[k - 1] == " " {
                var out = chars; out[k] = "["
                if spaced { out.remove(at: k + 1) }
                return String(out) + text[close...]
            }
            k -= 1
        }
        return text
    }

    /// A ruled table cell wall that a recognized word runs straight across was
    /// never there (letter strokes looked like a rule); join the two cells.
    static func mergeCrossedWalls(_ table: inout LayoutTable, words: [Word]) {
        var changed = true
        // Cells stacked with no printed rule between them are one merged cell.
        while changed {
            changed = false
            for a in table.cells.indices {
                let A = table.cells[a]
                guard !A.bottom, let b = table.cells.firstIndex(where: { $0.column == A.column && $0.columnSpan == A.columnSpan && $0.row == A.row + A.rowSpan && !$0.top }) else { continue }
                let B = table.cells[b]
                // Only a label sitting in one half: two labels mean two cells.
                func filled(_ c: LayoutCell) -> Bool { words.contains { c.box.contains(x: $0.box.midX, y: $0.box.midY) } }
                guard filled(A) != filled(B) else { continue }
                var m = A
                m.rowSpan = A.rowSpan + B.rowSpan
                m.box = LBox(A.box.x0, A.box.y0, A.box.x1, B.box.y1)
                m.bottom = B.bottom; m.left = A.left && B.left; m.right = A.right && B.right
                m.fill = A.fill ?? B.fill
                table.cells[a] = m
                table.cells.remove(at: b)
                changed = true
                break
            }
        }
        changed = true
        while changed {
            changed = false
            outer: for a in table.cells.indices {
                let A = table.cells[a]
                let wall = table.columns[A.column + A.columnSpan]
                guard let b = table.cells.firstIndex(where: { $0.row == A.row && $0.rowSpan == A.rowSpan && $0.column == A.column + A.columnSpan }) else { continue }
                let B = table.cells[b]
                let inA = words.filter { A.box.contains(x: $0.box.midX, y: $0.box.midY) }
                let inB = words.filter { B.box.contains(x: $0.box.midX, y: $0.box.midY) }
                guard !inA.isEmpty, !inB.isEmpty else { continue }
                for w in words where w.box.midY > A.box.y0 && w.box.midY < A.box.y1 {
                    let margin = max(4, w.box.height * 0.25)
                    guard w.box.x0 < wall - margin, w.box.x1 > wall + margin, w.text.count >= 2 else { continue }
                    // The text runs on as one line: the next word starts right after.
                    guard let next = inB.min(by: { $0.box.x0 < $1.box.x0 }), next.box.x0 - w.box.x1 < w.box.height,
                          abs(next.box.midY - w.box.midY) < w.box.height * 0.5 else { continue }
                    var m = A
                    m.columnSpan = A.columnSpan + B.columnSpan
                    m.box = LBox(A.box.x0, A.box.y0, B.box.x1, A.box.y1)
                    m.right = B.right; m.top = A.top && B.top; m.bottom = A.bottom && B.bottom
                    m.fill = A.fill ?? B.fill
                    table.cells[a] = m
                    table.cells.remove(at: b)
                    changed = true
                    break outer
                }
            }
        }
    }

    /// Cells in a row with a colored header cell share its color when they
    /// measure the same tint (single cells are judged more strictly alone).
    static func spreadRowFills(_ cells: inout [LayoutCell], ink: Ink) {
        for i in cells.indices where cells[i].fill == nil {
            guard let raw = ink.fill(cells[i].box) else { continue }
            let chroma = Int(max(raw.r, raw.g, raw.b)) - Int(min(raw.r, raw.g, raw.b))
            guard chroma >= 6 || max(raw.r, raw.g, raw.b) <= 238 else { continue }
            let row = cells[i].row
            guard row == 0, let src = cells.first(where: { $0.fill != nil && $0.row == row && $0.rowSpan == cells[i].rowSpan }),
                  let srcRaw = ink.fill(src.box) else { continue }
            let d = abs(Int(raw.r) - Int(srcRaw.r)) + abs(Int(raw.g) - Int(srcRaw.g)) + abs(Int(raw.b) - Int(srcRaw.b))
            if d < 24 { cells[i].fill = src.fill }
        }
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
        self.boldThreshold = other.boldThreshold
    }
}
