import UIKit

/// Areas hidden with Hide personal info in the review. They are part of the page
/// like a crop or a filter: every output (PDF, Word, Excel, slides, images) is
/// made from the hidden page, so the covered pixels and the text under them never
/// leave the iPhone.
///
/// Boxes are kept on the cropped sheet before rotation and margins, so turning
/// the page or changing its margins keeps them on the same words. A new crop or
/// tone can move the content a little; the boxes still cover their old place and
/// the review asks to check them before saving (`redactionNeedsCheck`).
/// How a hidden area looks. Every style replaces the pixels, and the text under
/// the area is dropped from every output the same way.
enum RedactionStyle: String, Codable, CaseIterable {
    /// A solid black box.
    case black
    /// Filled with the paper colour around it, as if nothing was written there.
    case erase
    /// Large blocks of the area's average colours.
    case mosaic
    var title: String {
        switch self { case .black: return "Black box"; case .erase: return "Erase"; case .mosaic: return "Mosaic" }
    }
    static let key = "redaction-style"
}

struct PageRedaction: Codable, Equatable {
    /// Hidden areas; origin top-left, 0…1, on the sheet before rotation and margins.
    var boxes: [CGRect]
    /// nil: black (libraries from before the choice).
    var style: RedactionStyle?
    /// Found items the user chose to keep visible, so they are not suggested again.
    var visible: [CGRect]?
    var crop: ScanQuad
    var enhancement: Enhancement
    /// The page was flattened when the boxes were drawn (nil: not flattened).
    var flattened: Bool? = nil
}

extension ScanPage {
    /// Hidden areas on the finished page (origin top-left, 0…1).
    var redactionBoxes: [CGRect] {
        (redaction?.boxes ?? []).map { RedactionGeometry.toPage($0, turns: turns, trim: trimming) }
    }
    var keptVisibleBoxes: [CGRect] {
        (redaction?.visible ?? []).map { RedactionGeometry.toPage($0, turns: turns, trim: trimming) }
    }
    var hasRedaction: Bool { !(redaction?.boxes ?? []).isEmpty }
    /// The page was cropped again or got another tone after it was hidden.
    var redactionNeedsCheck: Bool {
        guard let redaction, !redaction.boxes.isEmpty else { return false }
        return redaction.crop != crop || redaction.enhancement != enhancement || (redaction.flattened ?? false) != (flattenRequest != nil)
    }
    /// Stores boxes drawn on the finished page. Text read before is dropped, so the
    /// next save reads the hidden page again.
    var redactionStyle: RedactionStyle { redaction?.style ?? .black }
    mutating func setRedaction(hidden: [CGRect], visible: [CGRect], style: RedactionStyle = .black) {
        let toSheet = { (r: CGRect) in RedactionGeometry.toSheet(r, turns: self.turns, trim: self.trimming) }
        if hidden.isEmpty && visible.isEmpty { redaction = nil }
        else { redaction = PageRedaction(boxes: hidden.map(toSheet), style: style == .black ? nil : style, visible: visible.isEmpty ? nil : visible.map(toSheet), crop: crop, enhancement: enhancement, flattened: flattenRequest != nil ? true : nil) }
        textBlocks = []; ocrComplete = false; ocrProcessingVersion = nil
    }
    /// Recognized text without anything under a hidden area. Every PDF text layer
    /// and every Office export reads text through this.
    var visibleTextBlocks: [TextBlock] { RedactionGeometry.scrub(textBlocks, boxes: redactionBoxes) }
    /// The page as it looks before hiding (for the hide editor).
    var withoutRedaction: ScanPage { var copy = self; copy.redaction = nil; return copy }
}

enum RedactionGeometry {
    /// Extra margin around every hidden area, so a box drawn tight on a word still
    /// covers it after the tone's small line alignment.
    static let pad: CGFloat = 0.003
    /// Sheet → finished page: turn clockwise `turns` times, then cut the margins.
    static func toPage(_ r: CGRect, turns: Int, trim: PageTrim) -> CGRect {
        var rect = r
        for _ in 0..<(((turns % 4) + 4) % 4) { rect = CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width) }
        let w = max(0.0001, 1 - trim.left - trim.right), h = max(0.0001, 1 - trim.top - trim.bottom)
        return CGRect(x: (rect.minX - trim.left) / w, y: (rect.minY - trim.top) / h, width: rect.width / w, height: rect.height / h)
    }
    /// Finished page → sheet; the inverse of `toPage`.
    static func toSheet(_ r: CGRect, turns: Int, trim: PageTrim) -> CGRect {
        let w = 1 - trim.left - trim.right, h = 1 - trim.top - trim.bottom
        var rect = CGRect(x: r.minX * w + trim.left, y: r.minY * h + trim.top, width: r.width * w, height: r.height * h)
        // One counter-clockwise turn per clockwise turn.
        for _ in 0..<(((turns % 4) + 4) % 4) { rect = CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width) }
        return rect
    }
    /// Drops every recognized word that touches a hidden area; a line keeps its
    /// other words. Lines without word positions are dropped when they touch one.
    static func scrub(_ blocks: [TextBlock], boxes: [CGRect]) -> [TextBlock] {
        guard !boxes.isEmpty else { return blocks }
        let covered = boxes.map { $0.insetBy(dx: -pad, dy: -pad) }
        func hits(_ r: CGRect) -> Bool { covered.contains { $0.intersection(r).width * $0.intersection(r).height > 0.15 * max(1e-9, r.width * r.height) } }
        return blocks.compactMap { block in
            let line = CGRect(x: block.x, y: block.y, width: block.width, height: block.height)
            guard hits(line) else { return block }
            guard let words = block.words, !words.isEmpty else { return nil }
            let kept = words.filter { !hits(CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)) }
            guard !kept.isEmpty else { return nil }
            var out = block
            out.words = kept
            out.text = kept.map(\.text).joined(separator: " ")
            let bounds = kept.dropFirst().reduce(CGRect(x: kept[0].x, y: kept[0].y, width: kept[0].width, height: kept[0].height)) {
                $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height))
            }
            out.x = bounds.minX; out.y = bounds.minY; out.width = bounds.width; out.height = bounds.height
            return out
        }
    }
}

extension Imaging {
    /// Covers the page's hidden areas on a finished render in the page's style.
    static func applyRedactions(_ image: UIImage, page: ScanPage) -> UIImage {
        let boxes = page.redactionBoxes
        guard !boxes.isEmpty, let cg = image.cgImage else { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = image.scale; format.opaque = true
        let size = CGSize(width: cg.width, height: cg.height)
        let out = UIGraphicsImageRenderer(size: size, format: { let f = format; f.scale = 1; return f }()).image { context in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
            for box in boxes {
                let r = RedactionPatch.pixelRect(box, size: size)
                guard r.width >= 1, r.height >= 1 else { continue }
                RedactionPatch.draw(page.redactionStyle, in: r, source: cg, context: context.cgContext)
            }
        }
        guard let result = out.cgImage else { return image }
        return UIImage(cgImage: result, scale: image.scale, orientation: .up)
    }
}

/// The look of one hidden area, shared by the saved page and the hide editor.
enum RedactionPatch {
    /// A finished-page box (0…1, with the safety margin) in pixels of `size`.
    static func pixelRect(_ box: CGRect, size: CGSize) -> CGRect {
        let r = box.insetBy(dx: -RedactionGeometry.pad, dy: -RedactionGeometry.pad)
        return CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
            .integral.intersection(CGRect(origin: .zero, size: size))
    }
    /// Draws the style over `rect` (pixels, origin top-left) into a UIKit context.
    static func draw(_ style: RedactionStyle, in rect: CGRect, source: CGImage, context: CGContext) {
        switch style {
        case .black:
            context.setFillColor(UIColor.black.cgColor); context.fill(rect)
        case .erase:
            context.setFillColor(paperColor(around: rect, in: source)); context.fill(rect)
        case .mosaic:
            // Few, large blocks: about three across the height of a line of text.
            let block = max(8, min(rect.width, rect.height) / 3)
            let cols = max(1, Int((rect.width / block).rounded(.up))), rows = max(1, Int((rect.height / block).rounded(.up)))
            guard let patch = source.cropping(to: rect), let small = averaged(patch, cols: cols, rows: rows) else {
                context.setFillColor(UIColor.gray.cgColor); context.fill(rect); return
            }
            context.saveGState()
            context.interpolationQuality = .none
            // UIKit contexts are flipped; draw the small picture upright.
            context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            context.draw(small, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }
    /// The patch shrunk to cols × rows by averaging (each pixel is one block's average).
    private static func averaged(_ image: CGImage, cols: Int, rows: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        return ctx.makeImage()
    }
    /// The most common colour on a thin ring just outside the area (the paper),
    /// so erased text leaves the page's own background, not white on a coloured cell.
    static func paperColor(around rect: CGRect, in image: CGImage) -> CGColor {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let ring = max(3, min(rect.width, rect.height) * 0.25)
        let outer = rect.insetBy(dx: -ring, dy: -ring).intersection(bounds).integral
        guard outer.width >= 1, outer.height >= 1, let crop = image.cropping(to: outer) else { return UIColor.white.cgColor }
        let w = crop.width, h = crop.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return UIColor.white.cgColor }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Pixels of the inner area (the text) don't vote. Rows in memory run top-down.
        let inner = rect.offsetBy(dx: -outer.minX, dy: -outer.minY)
        var votes: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for y in Swift.stride(from: 0, to: h, by: 1) {
            for x in Swift.stride(from: 0, to: w, by: 1) where !inner.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                let i = (y * w + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
                let v = votes[key] ?? (0, 0, 0, 0)
                votes[key] = (v.count + 1, v.r + r, v.g + g, v.b + b)
            }
        }
        guard let best = votes.values.max(by: { $0.count < $1.count }), best.count > 0 else { return UIColor.white.cgColor }
        let n = CGFloat(best.count) * 255
        return UIColor(red: CGFloat(best.r) / n, green: CGFloat(best.g) / n, blue: CGFloat(best.b) / n, alpha: 1).cgColor
    }
}
