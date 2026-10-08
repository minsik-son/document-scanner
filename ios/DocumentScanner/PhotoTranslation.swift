import UIKit
import CoreImage
import CoreText
import NaturalLanguage

struct TranslationRegion: Identifiable {
    let id: Int
    var source: String
    var target = ""
    var box: CGRect // Normalized, top-left origin on the corrected scan.
    var keepOriginal = false
    var sourceBoxes: [CGRect] = [] // Original line boxes, preserved when a paragraph is grouped.
    /// Small, low-confidence or misspelled reading, kept in the original unless the user opts in.
    var unclear = false
    /// A list marker (•, ①, "1.") left as photographed pixels; never translated.
    var isMarker = false
    var confidence: Float = 1
}
struct TranslationScan {
    let original: UIImage
    let image: UIImage
    let crop: ScanQuad
    let edgesDetected: Bool
    var regions: [TranslationRegion]
    var notice: String? = nil
    var recognitionLanguage: String? = nil
    /// Same geometry as `image`, before the paper-white tone curve and ink sharpening.
    /// Small gray print survives here, so text is recognized from this image.
    var reading: UIImage? = nil
    var clarityChecked = false
}
struct TranslationComposition {
    let image: UIImage
    let text: [TextBlock]
    let issues: [Int: String]
    let replaced: Int
    var reasons: [Int: TranslationIssue] = [:]
    var kept = 0
    var unchanged = 0
    var unclear = 0
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
        let original = Imaging.limited(Imaging.normalized(source),maxPixels:20_000_000)
        guard let cg = original.cgImage, cg.width*cg.height <= 20_000_000 else {
            throw ScannerError.message("Choose a document photo up to 20 megapixels.")
        }
        let detected = explicitCrop ?? Imaging.detect(original)
        let crop = detected ?? .full
        // Geometry and illumination first; the paper-white tone curve and ink
        // sharpening are applied only to the page that is shown and rebuilt.
        // Recognizing text before that step keeps small, light-gray print legible.
        let base = try DocumentProcessing.prepare(CIImage(cgImage:cg),crop:crop,turns:0,enhancement:.document)
        let finished = try DocumentProcessing.finish(base)
        guard let output = DocumentProcessing.context.createCGImage(finished,from:finished.extent),
              let reading = DocumentProcessing.context.createCGImage(base.image,from:finished.extent) else {
            throw ScannerError.message("The scan couldn't be prepared. Retake the photo.")
        }
        try Task.checkCancellation()
        let blocks = try PhotoTranslationRecognition.recognize(reading,language:sourceLanguage,secondaryLanguage:targetLanguage)
        guard blocks.count <= 400 else { throw ScannerError.message("This page has too many text areas. Crop to a smaller section.") }
        return TranslationScan(original:original,image:UIImage(cgImage:output),crop:crop,edgesDetected:detected != nil,
            regions:TranslationParagraphs.group(blocks,raster:try TranslationRaster(reading)),recognitionLanguage:sourceLanguage,
            reading:UIImage(cgImage:reading))
    }
    private struct Placement { let region:TranslationRegion; let inks:[TranslationRaster.Ink]; let text:NSAttributedString; let rect:CGRect }
    static func compose(_ image:UIImage, regions:[TranslationRegion]) throws -> TranslationComposition {
        guard let cg = image.cgImage, cg.width*cg.height <= 20_000_000 else { throw ScannerError.message("The scan is too large.") }
        let w = cg.width, h = cg.height, bounds = CGRect(x:0,y:0,width:w,height:h)
        var raster = try TranslationRaster(cg)
        let space = CGColorSpace(name:CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        var placements:[Placement] = [], issues:[Int:String] = [:], reasons:[Int:TranslationIssue] = [:], text:[TextBlock] = []
        var kept = 0, unchanged = 0, unclear = 0
        var boxes:[Int:CGRect] = [:]
        guard Set(regions.map(\.id)).count == regions.count else { throw ScannerError.message("Text areas must have unique identifiers.") }
        // Text read at the very edge of the page can reach a hair past it; keep
        // the part on the page instead of refusing the whole page.
        let unit = CGRect(x:0,y:0,width:1,height:1)
        func onPage(_ b:CGRect) -> CGRect? {
            guard [b.minX,b.minY,b.width,b.height].allSatisfy(\.isFinite) else { return nil }
            let c = b.standardized.intersection(unit)
            return c.isNull || c.width <= 0 || c.height <= 0 ? nil : c
        }
        let regions = regions.map { r -> TranslationRegion in
            var r = r
            if let b = onPage(r.box) { r.box = b }
            r.sourceBoxes = r.sourceBoxes.compactMap(onPage)
            return r
        }
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
            // Markers stay as photographed pixels and add nothing to the text layer:
            // a misread circled numeral ("I", "Q") must not become selectable text.
            if region.isMarker { continue }
            if region.keepOriginal { if region.unclear { unclear += 1 } else { kept += 1 };retain(nil);continue }
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
                        .replacingOccurrences(of:TranslationText.wordJoiner,with:"")
                    text.append(TextBlock(text:value,x:(rect.minX+origins[i].x)/CGFloat(w),y:(rect.maxY-origins[i].y-ascent)/CGFloat(h),width:min(width,rect.width)/CGFloat(w),height:(ascent+descent)/CGFloat(h)))
                }
            }
        }
        try Task.checkCancellation()
        text.sort { abs($0.y-$1.y) < min($0.height,$1.height)*0.4 ? $0.x < $1.x : $0.y < $1.y }
        return TranslationComposition(image:composed,text:text,issues:issues,replaced:placements.count,reasons:reasons,kept:kept,unchanged:unchanged,unclear:unclear)
    }
    private static func fit(_ string:String,in size:CGSize,maximum:CGFloat,minimum:CGFloat,color:UIColor) -> NSAttributedString? {
        // Korean wraps between words ("프로세스)." stays whole). Fall back to the
        // plain string only when a single word is wider than the available box.
        let keepWords = TranslationText.keepingHangulWords(string)
        if keepWords != string, let fitted = fitText(keepWords,in:size,maximum:maximum,minimum:minimum,color:color) { return fitted }
        return fitText(string,in:size,maximum:maximum,minimum:minimum,color:color)
    }
    private static func fitText(_ string:String,in size:CGSize,maximum:CGFloat,minimum:CGFloat,color:UIColor) -> NSAttributedString? {
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

enum TranslationText {
    static let wordJoiner = "\u{2060}"
    /// Core Text may break Korean between any two syllables. Joining the letters of
    /// each Hangul word keeps line breaks at spaces, as Korean text expects.
    static func keepingHangulWords(_ text:String) -> String {
        guard text.unicodeScalars.contains(where:{ (0xAC00...0xD7A3).contains($0.value) }) else { return text }
        return text.split(separator:" ",omittingEmptySubsequences:false).map { token -> String in
            guard token.unicodeScalars.contains(where:{ (0xAC00...0xD7A3).contains($0.value) }) else { return String(token) }
            return token.map { String($0) }.joined(separator:wordJoiner)
        }.joined(separator:" ")
    }
}

/// Text that could not be read reliably is not sent to the translator: a model given
/// "Ws unive nina daed" returns a fluent but invented sentence. Such areas stay in the
/// original language, flagged, and the user can still translate them in Review.
@MainActor
enum TranslationQuality {
    static func checked(_ scan:TranslationScan,language:String) -> TranslationScan {
        var result = scan
        result.regions = review(scan.regions,language:language,imageHeight:scan.image.size.height*scan.image.scale)
        result.clarityChecked = true
        return result
    }
    static func review(_ regions:[TranslationRegion],language:String,imageHeight:CGFloat) -> [TranslationRegion] {
        func lines(_ region:TranslationRegion) -> [CGRect] { region.sourceBoxes.isEmpty ? [region.box] : region.sourceBoxes }
        // Body text size: the median line height weighted by characters, so many short
        // labels inside screenshots cannot pull it down.
        var weighted:[(height:CGFloat,weight:Int)] = []
        for region in regions where !region.isMarker {
            let boxes = lines(region),share = max(1,region.source.count/max(1,boxes.count))
            weighted += boxes.map { (height:$0.height*imageHeight,weight:share) }
        }
        weighted.sort { $0.height < $1.height }
        var typical:CGFloat = 0,running = 0
        let total = weighted.reduce(0) { $0+$1.weight }
        for item in weighted { running += item.weight;if running*2 >= total { typical = item.height;break } }
        let checker = UITextChecker()
        let prefix = language.split(separator:"-").first.map(String.init) ?? language
        let spelling = UITextChecker.availableLanguages.first { $0 == prefix || $0.hasPrefix(prefix+"_") }
        return regions.map { region in
            var r = region
            guard !r.isMarker,!r.keepOriginal else { return r }
            let own = lines(r).map { $0.height*imageHeight }.sorted()
            let lineHeight = own[own.count/2]
            // Labels inside screenshots and pictures: a few pixels tall and far
            // smaller than the page's body text.
            let tiny = lineHeight < 11 || (typical > 0 && lineHeight < typical*0.6)
            let garbled = spelling.map { misspelled(r.source,checker:checker,language:$0) } ?? false
            // Codes, counters and stray glyphs ("Z2.P6CS/1001042", "A" from a warning icon)
            // have no word to translate.
            let wordless = r.source.range(of:"\\p{L}{3,}",options:.regularExpression) == nil
            if r.confidence < 0.5 || tiny || garbled || wordless { r.unclear = true;r.keepOriginal = true }
            return r
        }
    }
    /// True when too many ordinary words are not words. Acronyms (PC, POST), product
    /// names with inner capitals (WinClon), capitalized names after the first word,
    /// numbers and other scripts are ignored.
    static func misspelled(_ text:String,checker:UITextChecker,language:String) -> Bool {
        var counted = 0,wrong = 0,first = true
        for token in text.split(whereSeparator:{ !$0.isLetter && $0 != "'" }) {
            let word = String(token)
            defer { first = false }
            guard word.count >= 3,word.unicodeScalars.allSatisfy({ $0.value < 0x0250 }) else { continue }
            if word == word.uppercased() || word.dropFirst().contains(where:{ $0.isUppercase }) { continue }
            if !first,word.first?.isUppercase == true { continue }
            counted += 1
            let range = checker.rangeOfMisspelledWord(in:word,range:NSRange(location:0,length:(word as NSString).length),
                                                      startingAt:0,wrap:false,language:language)
            if range.location != NSNotFound { wrong += 1 }
        }
        guard counted > 0 else { return false }
        return counted <= 2 ? wrong == counted : wrong*3 >= counted
    }
}

/// Short headings and interface labels have no sentence context, so a general model
/// can pick the wrong sense ("Restore" → "되돌리다"). Exact whole-area matches only.
enum TranslationGlossary {
    private static let englishKorean: [String:String] = [
        "backup":"백업","back up":"백업","restore":"복원","recovery":"복구","password":"비밀번호",
        "confirm":"확인","cancel":"취소","ok":"확인","next":"다음","previous":"이전","back":"뒤로",
        "settings":"설정","help":"도움말","close":"닫기","yes":"예","no":"아니요","start":"시작",
        "finish":"완료","done":"완료","delete":"삭제","save":"저장","open":"열기","print":"인쇄",
        "warning":"경고","caution":"주의","note":"참고","contents":"목차","introduction":"소개",
        "index":"색인","features":"기능","specifications":"사양","troubleshooting":"문제 해결",
        "installation":"설치","overview":"개요","appendix":"부록","important":"중요"
    ]
    static func target(for source:String,from:String,to:String) -> String? {
        guard from.hasPrefix("en"),to.hasPrefix("ko") else { return nil }
        let key = source.trimmingCharacters(in:CharacterSet.letters.inverted)
            .split(whereSeparator:\.isWhitespace).joined(separator:" ").lowercased()
        return englishKorean[key]
    }
}

/// Guesses the language of a photographed page from all of its recognized text,
/// not just the first line. Returns nil when the guess is not confident; the
/// screen then asks the person to choose.
enum SourceLanguageGuess {
    nonisolated static func detect(_ texts: [String]) -> String? {
        let joined = texts.joined(separator: "\n")
        guard joined.filter(\.isLetter).count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(joined)
        guard let best = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }), best.value >= 0.6,
              best.key != .undetermined else { return nil }
        return Locale.Language(identifier: best.key.rawValue).minimalIdentifier
    }
}
