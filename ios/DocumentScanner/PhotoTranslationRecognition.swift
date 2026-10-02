import Foundation
import Vision

/// Photo translation has a user-selected source language. Unlike searchable scans,
/// it must not choose unrelated script models to interpret tiny labels in pictures.
enum PhotoTranslationRecognition {
    private struct Reading { let block:TextBlock;let confidence:Float }
    static func recognize(_ image:CGImage,language:String,secondaryLanguage:String? = nil) throws -> [TextBlock] {
        let supported = try TextRecognition.supportedLanguages()
        let prefix = language.split(separator:"-").first.map(String.init) ?? language
        let matches = supported.filter { $0 == language || $0.hasPrefix(language+"-") }
        let fallback = supported.filter { $0.split(separator:"-").first.map(String.init) == prefix }
        guard let primary = matches.first ?? fallback.first else {
            throw ScannerError.message("Text recognition isn't available for this source language on this iPhone. Choose another language or edit the recognized text.")
        }
        let languages = [primary] + supported.filter { $0.hasPrefix("en-") && $0 != primary }
        func read(_ cg:CGImage,within area:CGRect,using overrides:[String]? = nil) throws -> [Reading] {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate;request.minimumTextHeight = 0
            request.recognitionLanguages = overrides ?? languages;request.automaticallyDetectsLanguage = false
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage:cg,options:[:]).perform([request])
            func mapped(_ box:CGRect) -> CGRect {
                CGRect(x:area.minX+box.minX*area.width,y:area.minY+(1-box.maxY)*area.height,width:box.width*area.width,height:box.height*area.height)
            }
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let local = observation.boundingBox
                // Discard cut-off tile lines, but keep lines at the real page boundary.
                if area != CGRect(x:0,y:0,width:1,height:1) {
                    if (area.minX > 0 && local.minX < 0.015) || (area.maxX < 1 && local.maxX > 0.985) ||
                        (area.minY > 0 && local.maxY > 0.985) || (area.maxY < 1 && local.minY < 0.015) { return nil }
                }
                let text = candidate.string
                let regex = try! NSRegularExpression(pattern:"\\S+")
                let words = regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { match -> TextWord? in
                    guard let range = Range(match.range,in:text),let geometry = try? candidate.boundingBox(for:range) else { return nil }
                    let b = mapped(geometry.boundingBox)
                    return TextWord(text:String(text[range]),x:b.minX,y:b.minY,width:b.width,height:b.height)
                }
                // Word boxes exclude the large margins of slanted whole-line observations.
                let b = mapped(local)
                return Reading(block:TextBlock(text:text,x:b.minX,y:b.minY,width:b.width,height:b.height,words:words.isEmpty ? nil : words,confidence:candidate.confidence),confidence:candidate.confidence)
            }
        }
        var readings = try read(image,within:CGRect(x:0,y:0,width:1,height:1))
        // A second, overlapping close-up pass helps small labels without changing the scan.
        if readings.count > 20 || readings.contains(where:{ $0.block.height < 0.012 }) {
            for y in [0.0,0.44] { for x in [0.0,0.44] {
                let area = CGRect(x:x,y:y,width:0.56,height:0.56)
                let pixels = CGRect(x:area.minX*CGFloat(image.width),y:area.minY*CGFloat(image.height),width:area.width*CGFloat(image.width),height:area.height*CGFloat(image.height)).integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
                guard let crop = image.cropping(to:pixels) else { continue }
                let actual = CGRect(x:pixels.minX/CGFloat(image.width),y:pixels.minY/CGFloat(image.height),width:pixels.width/CGFloat(image.width),height:pixels.height/CGFloat(image.height))
                for candidate in try read(crop,within:actual) {
                    let b = box(candidate.block)
                    let conflicts = readings.indices.filter { i in
                        let a = box(readings[i].block),overlap = a.intersection(b)
                        return !overlap.isNull && overlap.width*overlap.height > min(a.width*a.height,b.width*b.height)*0.4
                    }
                    if conflicts.isEmpty { readings.append(candidate) }
                    else if conflicts.count == 1,let i = conflicts.first {
                        let a = box(readings[i].block),overlap = a.intersection(b)
                        // Replace only equivalent complete lines, never a partial crop of a paragraph.
                        if overlap.width*overlap.height > max(a.width*a.height,b.width*b.height)*0.65,
                           candidate.confidence > readings[i].confidence+0.04 { readings[i] = candidate }
                    }
                }
            } }
        }
        // Keep existing target-language text in mixed documents recognizable too. This is
        // restricted to the selected pair, not every unrelated script available on the OS.
        if let secondaryLanguage,secondaryLanguage != language,
           let secondary = supported.first(where:{ $0 == secondaryLanguage || $0.hasPrefix(secondaryLanguage+"-") }),
           let scriptRange = nativeScript(secondaryLanguage),nativeScript(language) != scriptRange {
            for candidate in try read(image,within:CGRect(x:0,y:0,width:1,height:1),using:[secondary]+languages) {
                let letters = candidate.block.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
                let native = letters.filter { scriptRange.contains($0.value) }.count
                guard candidate.confidence >= 0.3,native >= 2,native*5 > letters.count else { continue }
                let b = box(candidate.block)
                let conflicts = readings.indices.filter { i in
                    let a = box(readings[i].block),overlap = a.intersection(b)
                    return !overlap.isNull && overlap.width*overlap.height > min(a.width*a.height,b.width*b.height)*0.65
                }
                for i in conflicts.reversed() { readings.remove(at:i) }
                readings.append(candidate)
            }
        }
        return readings.map(\.block)
    }
    private static func nativeScript(_ language:String) -> ClosedRange<UInt32>? {
        switch language.split(separator:"-").first {
        case "ko": return 0xAC00...0xD7FF
        case "ja": return 0x3040...0x30FF
        case "zh", "yue": return 0x3400...0x9FFF
        case "ar", "fa", "ur": return 0x0600...0x08FF
        case "ru", "uk", "bg": return 0x0400...0x052F
        case "th": return 0x0E00...0x0E7F
        default: return nil
        }
    }
    private static func box(_ b:TextBlock) -> CGRect { CGRect(x:b.x,y:b.y,width:b.width,height:b.height) }
}
