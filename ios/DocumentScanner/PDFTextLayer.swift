import Foundation
import CoreGraphics
import CoreText

enum PDFTextLayer {
    enum CoordinateSystem { case topLeft, bottomLeft }

    // OCR coordinates describe the final processed image, with a top-left origin.
    // Text uses the same fitted image rectangle as the photo, never the whole PDF page.
    static func draw(blocks: [TextBlock], in context: CGContext, imageRect: CGRect,
                     coordinateSystem: CoordinateSystem = .topLeft) {
        for block in blocks {
            if let words = block.words, !words.isEmpty {
                for word in words { draw(text: word.text, x: word.x, y: word.y, width: word.width, height: word.height,
                                         in: context, imageRect: imageRect, coordinateSystem: coordinateSystem) }
            } else {
                draw(text: block.text, x: block.x, y: block.y, width: block.width, height: block.height,
                     in: context, imageRect: imageRect, coordinateSystem: coordinateSystem)
            }
        }
    }

    private static func draw(text: String, x: Double, y: Double, width: Double, height: Double,
                             in context: CGContext, imageRect: CGRect, coordinateSystem: CoordinateSystem) {
        guard !text.isEmpty, [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return }
        let box = CGRect(x: imageRect.minX + x * imageRect.width,
                         y: coordinateSystem == .topLeft ? imageRect.minY + y * imageRect.height : imageRect.maxY - (y + height) * imageRect.height,
                         width: width * imageRect.width, height: height * imageRect.height)
        // SF Arabic's contextual glyph subset can lose the base Unicode mapping
        // when exported by Core Graphics. The static system face retains it.
        let arabic = text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
        let font = arabic ? CTFontCreateWithName("GeezaPro" as CFString, 12, nil)
                          : (CTFontCreateUIFontForLanguage(.system, 12, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 12, nil))
        if let scalar = text.unicodeScalars.first(where: { (0x0900...0x0DFF).contains($0.value) }) {
            drawIndicText(text, scriptScalar: scalar.value, in: context, box: box, coordinateSystem: coordinateSystem)
            return
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        guard advance > 0, ascent + descent > 0 else { return }
        let verticalScale = box.height / (ascent + descent)
        context.saveGState()
        if coordinateSystem == .topLeft {
            context.translateBy(x: box.minX, y: box.maxY - descent * verticalScale)
            context.scaleBy(x: box.width / advance, y: -verticalScale)
        } else {
            context.translateBy(x: box.minX, y: box.minY + descent * verticalScale)
            context.scaleBy(x: box.width / advance, y: verticalScale)
        }
        context.textMatrix = .identity
        context.textPosition = .zero
        // Rendering mode 3 embeds real Unicode text without changing a single image pixel.
        context.setTextDrawingMode(.invisible)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawIndicText(_ text: String, scriptScalar: UInt32, in context: CGContext,
                                      box: CGRect, coordinateSystem: CoordinateSystem) {
        // Visual shaping places some Indic vowels before the consonant. PDFKit
        // can then copy them in the wrong Unicode order (e.g. िह instead of हि).
        // The visible scan already contains the correctly shaped ink. Encode the
        // invisible layer with nominal glyphs in logical order, avoiding ligature
        // aliases and retaining every Unicode scalar for search/copy.
        let name: String
        switch scriptScalar {
        case 0x0900...0x097F: name = "KohinoorDevanagari-Regular"
        case 0x0980...0x09FF: name = "KohinoorBangla-Regular"
        case 0x0A00...0x0A7F: name = "GurmukhiMN"
        case 0x0A80...0x0AFF: name = "GujaratiSangamMN"
        case 0x0B00...0x0B7F: name = "OriyaSangamMN"
        case 0x0B80...0x0BFF: name = "TamilSangamMN"
        case 0x0C00...0x0C7F: name = "TeluguSangamMN"
        case 0x0C80...0x0CFF: name = "KannadaSangamMN"
        case 0x0D00...0x0D7F: name = "MalayalamSangamMN"
        default: name = "SinhalaSangamMN"
        }
        let baseFont = CTFontCreateWithName(name as CFString, 12, nil)
        let scalars = Array(text.unicodeScalars)
        let slot = box.width / CGFloat(max(1, scalars.count))
        for (index, scalar) in scalars.enumerated() {
            let value = String(scalar)
            let codes = Array(value.utf16)
            let font = CTFontCreateForString(baseFont, value as CFString, CFRange(location: 0, length: codes.count))
            var glyphs = [CGGlyph](repeating: 0, count: codes.count)
            CTFontGetGlyphsForCharacters(font, codes, &glyphs, codes.count)
            guard var glyph = glyphs.first(where: { $0 != 0 }) else { continue }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            let descent = CTFontGetDescent(font)
            let scale = box.height / max(1, CTFontGetAscent(font) + descent)
            context.saveGState()
            context.translateBy(x: box.minX + CGFloat(index)*slot,
                                y: coordinateSystem == .topLeft ? box.maxY-descent*scale : box.minY+descent*scale)
            context.scaleBy(x: slot/max(1, advance.width), y: coordinateSystem == .topLeft ? -scale : scale)
            context.textMatrix = .identity
            context.setTextDrawingMode(.invisible)
            var position = CGPoint.zero
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
            context.restoreGState()
        }
    }
}
