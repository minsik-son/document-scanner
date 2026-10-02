import UIKit
import CoreImage
import CoreText

struct TranslationRegion: Identifiable {
    let id: Int
    var source: String
    var target = ""
    var box: CGRect // Normalized, top-left origin on the corrected scan.
    var keepOriginal = false
    var sourceBoxes: [CGRect] = [] // Original line boxes, preserved when a paragraph is grouped.
}
struct TranslationScan {
    let original: UIImage
    let image: UIImage
    let crop: ScanQuad
    let edgesDetected: Bool
    var regions: [TranslationRegion]
    var notice: String? = nil
    var recognitionLanguage: String? = nil
}
struct TranslationComposition {
    let image: UIImage
    let text: [TextBlock]
    let issues: [Int: String]
    let replaced: Int
    var reasons: [Int: TranslationIssue] = [:]
    var kept = 0
    var unchanged = 0
}
enum TranslationIssue: String, CaseIterable {
    case missing = "Translation missing"
    case overlap = "Overlapping text"
    case background = "Background needs review"
    case space = "Translation needs more space"
    var explanation: String {
        switch self {
        case .missing: return "No translation was returned. Retry this area or enter a translation."
        case .overlap: return "Text areas overlap. The original is kept; the translation is available below."
        case .background: return "The text couldn't be safely separated from a line or picture. The translation is available below."
        case .space: return "The translation won't fit without covering nearby content. Copy it below or shorten it."
        }
    }
}

/// Conservative local compositing, not generative image reconstruction.
/// Pixels outside accepted text masks and replacement text stay on the scanned page.
enum PhotoTranslation {
    static func scan(_ source: UIImage, crop explicitCrop: ScanQuad? = nil, sourceLanguage:String = "en",targetLanguage:String = "ko") throws -> TranslationScan {
        try Task.checkCancellation()
        let original = Imaging.normalized(source)
        guard let cg = original.cgImage, cg.width*cg.height <= 20_000_000 else {
            throw ScannerError.message("Choose a document photo up to 20 megapixels.")
        }
        let detected = explicitCrop ?? Imaging.detect(original)
        let crop = detected ?? .full
        let prepared = try DocumentProcessing.render(CIImage(cgImage:cg),crop:crop,turns:0,enhancement:.document)
        guard let output = DocumentProcessing.context.createCGImage(prepared,from:prepared.extent) else {
            throw ScannerError.message("The scan couldn't be prepared. Retake the photo.")
        }
        try Task.checkCancellation()
        let blocks = try PhotoTranslationRecognition.recognize(output,language:sourceLanguage,secondaryLanguage:targetLanguage)
        guard blocks.count <= 400 else { throw ScannerError.message("This page has too many text areas. Crop to a smaller section.") }
        return TranslationScan(original:original,image:UIImage(cgImage:output),crop:crop,edgesDetected:detected != nil,
            regions:TranslationParagraphs.group(blocks,raster:try TranslationRaster(output)),recognitionLanguage:sourceLanguage)
    }
    private struct Placement { let region:TranslationRegion; let inks:[TranslationRaster.Ink]; let text:NSAttributedString; let rect:CGRect }
    static func compose(_ image:UIImage, regions:[TranslationRegion]) throws -> TranslationComposition {
        guard let cg = image.cgImage, cg.width*cg.height <= 20_000_000 else { throw ScannerError.message("The scan is too large.") }
        let w = cg.width, h = cg.height, bounds = CGRect(x:0,y:0,width:w,height:h)
        var raster = try TranslationRaster(cg)
        let space = CGColorSpace(name:CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var placements:[Placement] = [], issues:[Int:String] = [:], reasons:[Int:TranslationIssue] = [:], text:[TextBlock] = []
        var kept = 0, unchanged = 0
        var boxes:[Int:CGRect] = [:]
        guard Set(regions.map(\.id)).count == regions.count else { throw ScannerError.message("Text areas must have unique identifiers.") }
        for region in regions {
            for b in [region.box]+region.sourceBoxes {
                guard [b.minX,b.minY,b.width,b.height].allSatisfy(\.isFinite),b.width > 0,b.height > 0,
                      b.minX >= 0,b.minY >= 0,b.maxX <= 1.001,b.maxY <= 1.001 else {
                    throw ScannerError.message("A text area's position is invalid. Rescan the page.")
                }
            }
            boxes[region.id] = raster.pixelBox(region.box)
        }
        for region in regions {
            try Task.checkCancellation()
            guard let box = boxes[region.id] else { continue }
            func retain(_ reason:TranslationIssue?) {
                if let reason { reasons[region.id] = reason;issues[region.id] = reason.explanation }
                text.append(TextBlock(text:region.source,x:region.box.minX,y:region.box.minY,width:region.box.width,height:region.box.height))
            }
            if region.keepOriginal { kept += 1;retain(nil);continue }
            if region.target.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { retain(.missing);continue }
            if region.target == region.source { unchanged += 1;retain(nil);continue }
            guard region.target.count <= 5000 else { retain(.space);continue }
            let other = boxes.filter { $0.key != region.id }.map(\.value)
            var layoutBox = box
            var actualOverlap = false
            for obstacle in other {
                let overlap = layoutBox.intersection(obstacle)
                guard !overlap.isNull,overlap.width > 0,overlap.height > 0 else { continue }
                let tolerance = min(4,min(layoutBox.height,obstacle.height)*0.2)
                // OCR boxes include slant and antialiasing margins. Split a narrow shared edge
                // instead of treating a bullet touching its paragraph as a second text layer.
                if overlap.width <= tolerance {
                    if obstacle.midX < layoutBox.midX { let end = layoutBox.maxX;layoutBox.origin.x = overlap.midX+0.5;layoutBox.size.width = end-layoutBox.minX }
                    else { layoutBox.size.width = overlap.midX-0.5-layoutBox.minX }
                } else if overlap.height <= tolerance {
                    if obstacle.midY < layoutBox.midY { let end = layoutBox.maxY;layoutBox.origin.y = overlap.midY+0.5;layoutBox.size.height = end-layoutBox.minY }
                    else { layoutBox.size.height = overlap.midY-0.5-layoutBox.minY }
                } else { actualOverlap = true }
            }
            if actualOverlap { retain(.overlap);continue }
            let sourceBoxes = (region.sourceBoxes.isEmpty ? [region.box] : region.sourceBoxes).map { raster.pixelBox($0).intersection(layoutBox) }
            guard sourceBoxes.allSatisfy({ !$0.isNull && $0.width >= 5 && $0.height >= 5 }) else { retain(.overlap);continue }
            let heights = sourceBoxes.map(\.height).sorted(), lineHeight = heights[heights.count/2]
            let inks = sourceBoxes.compactMap { raster.ink(core:$0,lineHeight:lineHeight) }
            guard inks.count == sourceBoxes.count else { retain(.background);continue }
            var rect = inks.dropFirst().reduce(inks[0].rect) { $0.union($1.rect) }.intersection(bounds)
            if other.contains(where:{ $0.intersects(rect) }) { rect = layoutBox.intersection(bounds) }
            let barriers = other.map { $0.insetBy(dx:-1,dy:-1) } + placements.map(\.rect)
            let glyphs = inks.map(\.glyphHeight).sorted()
            // A skewed OCR line can have a tall box although its letters are small.
            // Keep the source's type scale instead of enlarging a short translation to fill that box.
            let maximum = max(6,min(lineHeight*1.05,glyphs[glyphs.count/2]/0.76))
            let preferred = maximum*0.9, minimum = max(5,maximum*0.72)
            var fitted = fit(region.target,in:rect.size,maximum:maximum,minimum:preferred,color:inks[0].foreground)
            if fitted == nil {
                rect = expanded(rect,raster:raster,obstacles:barriers,lineHeight:lineHeight,background:inks[0].background,target:region.target) { candidate in
                    fit(region.target,in:candidate.size,maximum:maximum,minimum:preferred,color:inks[0].foreground) != nil
                }
                fitted = fit(region.target,in:rect.size,maximum:maximum,minimum:preferred,color:inks[0].foreground)
            }
            if fitted == nil { fitted = fit(region.target,in:rect.size,maximum:maximum,minimum:minimum,color:inks[0].foreground) }
            guard let fitted else { retain(.space);continue }
            placements.append(Placement(region:region,inks:inks,text:fitted,rect:rect))
        }
        // All masks were analyzed against the unchanged source. Repeated edits never erase a previous render.
        for item in placements {
            for var ink in item.inks {
                let neighbors = boxes.filter { $0.key != item.region.id && $0.value.intersects(ink.rect.insetBy(dx:-2,dy:-2)) }.map(\.value)
                if !neighbors.isEmpty { ink.mask.removeAll { index in
                    let point = CGPoint(x:index/4%w,y:index/4/w)
                    return neighbors.contains { $0.contains(point) }
                } }
                raster.erase(ink)
            }
        }
        guard let provider = CGDataProvider(data:Data(raster.pixels) as CFData),
              let cleaned = CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:bitmapInfo),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {
            throw ScannerError.message("The translated page couldn't be rendered.")
        }
        let format = UIGraphicsImageRendererFormat();format.scale = 1;format.opaque = true
        let composed = UIGraphicsImageRenderer(size:bounds.size,format:format).image { renderer in
            UIImage(cgImage:cleaned).draw(in:bounds)
            for item in placements {
                let rect = item.rect, c = renderer.cgContext
                c.saveGState();c.clip(to:rect);c.translateBy(x:rect.minX,y:rect.maxY);c.scaleBy(x:1,y:-1);c.textMatrix = .identity
                let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(item.text),CFRange(location:0,length:0),CGPath(rect:CGRect(origin:.zero,size:rect.size),transform:nil),nil)
                CTFrameDraw(frame,c);c.restoreGState()
                // Use the laid-out lines for the PDF text layer, not the source OCR word coordinates.
                let lines = CTFrameGetLines(frame) as! [CTLine]
                var origins = [CGPoint](repeating:.zero,count:lines.count)
                CTFrameGetLineOrigins(frame,CFRange(location:0,length:0),&origins)
                for (i,line) in lines.enumerated() {
                    let range = CTLineGetStringRange(line)
                    guard range.location != kCFNotFound,range.location+range.length <= item.text.length else { continue }
                    var ascent:CGFloat = 0,descent:CGFloat = 0
                    let width = CTLineGetTypographicBounds(line,&ascent,&descent,nil)
                    let value = (item.text.string as NSString).substring(with:NSRange(location:range.location,length:range.length))
                    text.append(TextBlock(text:value,x:(rect.minX+origins[i].x)/CGFloat(w),y:(rect.maxY-origins[i].y-ascent)/CGFloat(h),width:min(width,rect.width)/CGFloat(w),height:(ascent+descent)/CGFloat(h)))
                }
            }
        }
        try Task.checkCancellation()
        text.sort { abs($0.y-$1.y) < min($0.height,$1.height)*0.4 ? $0.x < $1.x : $0.y < $1.y }
        return TranslationComposition(image:composed,text:text,issues:issues,replaced:placements.count,reasons:reasons,kept:kept,unchanged:unchanged)
    }
    private static func fit(_ string:String,in size:CGSize,maximum:CGFloat,minimum:CGFloat,color:UIColor) -> NSAttributedString? {
        func attributed(_ fontSize:CGFloat) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle();paragraph.alignment = .natural;paragraph.lineBreakMode = .byWordWrapping
            return NSAttributedString(string:string,attributes:[.font:UIFont.systemFont(ofSize:fontSize),.foregroundColor:color,.paragraphStyle:paragraph])
        }
        func fits(_ value:NSAttributedString) -> Bool {
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(value),CFRange(location:0,length:0),CGPath(rect:CGRect(origin:.zero,size:size),transform:nil),nil)
            guard CTFrameGetVisibleStringRange(frame).length == value.length else { return false }
            return (CTFrameGetLines(frame) as! [CTLine]).allSatisfy { CTLineGetTypographicBounds($0,nil,nil,nil) <= size.width+0.5 }
        }
        var low = minimum,high = max(minimum,maximum)
        guard fits(attributed(low)) else { return nil }
        for _ in 0..<10 { let mid = (low+high)/2; if fits(attributed(mid)) { low = mid } else { high = mid } }
        return attributed(low)
    }
    private static func expanded(_ base:CGRect,raster:TranslationRaster,obstacles:[CGRect],lineHeight:CGFloat,background:[UInt8],target:String,fits:(CGRect)->Bool) -> CGRect {
        var rect = base
        let step = max(2,lineHeight*0.25)
        let firstLetter = target.unicodeScalars.first { CharacterSet.letters.contains($0) }?.value ?? 0
        let rightToLeft = (0x0590...0x08FF).contains(firstLetter)
        // Preserve the paragraph's starting edge and stop as soon as the translation fits.
        for direction in 0..<2 {
            for _ in 0..<(direction == 0 ? 16 : 12) {
                var next = rect;let strip:CGRect
                if direction == 0 && !rightToLeft { next.size.width += step;strip = CGRect(x:rect.maxX,y:rect.minY,width:step,height:rect.height) }
                else if direction == 0 { next.origin.x -= step;next.size.width += step;strip = CGRect(x:next.minX,y:rect.minY,width:step,height:rect.height) }
                else { next.size.height += step;strip = CGRect(x:rect.minX,y:rect.maxY,width:rect.width,height:step) }
                guard raster.bounds.contains(next),!obstacles.contains(where:{ $0.intersects(next) }),raster.empty(strip,background:background) else { break }
                rect = next
                if fits(rect) { return rect }
            }
        }
        return rect
    }
}
