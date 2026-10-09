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
struct PageRedaction: Codable, Equatable {
    /// Hidden areas; origin top-left, 0…1, on the sheet before rotation and margins.
    var boxes: [CGRect]
    /// Found items the user chose to keep visible, so they are not suggested again.
    var visible: [CGRect]?
    var crop: ScanQuad
    var enhancement: Enhancement
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
        return redaction.crop != crop || redaction.enhancement != enhancement
    }
    /// Stores boxes drawn on the finished page. Text read before is dropped, so the
    /// next save reads the hidden page again.
    mutating func setRedaction(hidden: [CGRect], visible: [CGRect]) {
        let toSheet = { (r: CGRect) in RedactionGeometry.toSheet(r, turns: self.turns, trim: self.trimming) }
        if hidden.isEmpty && visible.isEmpty { redaction = nil }
        else { redaction = PageRedaction(boxes: hidden.map(toSheet), visible: visible.isEmpty ? nil : visible.map(toSheet), crop: crop, enhancement: enhancement) }
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
    /// Paints the page's hidden areas solid black on a finished render.
    static func applyRedactions(_ image: UIImage, page: ScanPage) -> UIImage {
        let boxes = page.redactionBoxes
        guard !boxes.isEmpty else { return image }
        let format = UIGraphicsImageRendererFormat(); format.scale = image.scale; format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            image.draw(at: .zero)
            UIColor.black.setFill()
            for box in boxes {
                let r = box.insetBy(dx: -RedactionGeometry.pad, dy: -RedactionGeometry.pad)
                context.fill(CGRect(x: r.minX * image.size.width, y: r.minY * image.size.height,
                                    width: r.width * image.size.width, height: r.height * image.size.height).integral)
            }
        }
    }
}
