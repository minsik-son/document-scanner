import UIKit
import Vision

/// Platform side of layout reconstruction: page pixels, on-device text
/// recognition and picture crops for the Office writers.
enum OfficeLayoutPages {
    /// Long side used for analysis; about 240 dpi for a Letter or A4 page.
    static let analysisSide: CGFloat = 2700
    /// Long side used for text recognition of large photos.
    static let readingSide: CGFloat = 3800
    /// Long side small pictures are enlarged to before reading.
    static let minimumSide: CGFloat = 1600

    struct Prepared {
        let raster: LayoutRaster
        let image: CGImage
    }

    /// Draws the page upright into an sRGB buffer so recognition and pixel
    /// analysis share one coordinate space whatever the photo orientation.
    static func prepare(_ image: UIImage, maxSide: CGFloat = analysisSide) throws -> Prepared {
        let pixelW = image.size.width * image.scale, pixelH = image.size.height * image.scale
        guard pixelW >= 16, pixelH >= 16 else { throw ScannerError.message("This page is too small to read.") }
        // Small pictures (a screenshot, a cropped table) are enlarged: text a few
        // pixels tall reads poorly and the layout measures assume page-sized scans.
        let scale = max(min(1, maxSide / max(pixelW, pixelH)), min(3, minimumSide / max(pixelW, pixelH)))
        let w = max(1, Int((pixelW * scale).rounded())), h = max(1, Int((pixelH * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScannerError.message("Not enough memory to read this page.") }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        UIGraphicsPopContext()
        guard let data = context.data, let cg = context.makeImage() else { throw ScannerError.message("Not enough memory to read this page.") }
        let bytes = [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        return Prepared(raster: LayoutRaster(width: w, height: h, rgba: bytes), image: cg)
    }

    /// Tone of the flattened photo the layout (rules, fills) is read from.
    nonisolated(unsafe) static var flattenTone: Enhancement = .document
    /// Standard paper shapes (height / width) that flattened photos snap to.
    static let paperAspects: [Double] = [11 / 8.5, 297 / 210, 14 / 8.5]

    /// A photo of a page lying on a desk is flattened and cleaned like a scan
    /// first: page found, perspective corrected, paper evened out, and the
    /// result given the proportions of the nearest paper size. Pages that are
    /// already scans (no different background around the page) are returned as is.
    static func flattenedIfPhoto(_ image: UIImage) throws -> UIImage { try flattenedPair(image).layout }

    /// The flattened page twice, in the same geometry: cleaned up for the layout
    /// (rules, fills, ink), and with perspective corrected only for reading the
    /// text, since the cleanup's sharpening and levels can make text in a soft
    /// or compressed photo unreadable. A page that is not a photo is both.
    static func flattenedPair(_ image: UIImage) throws -> (layout: UIImage, reading: UIImage) {
        let upright = Imaging.normalized(image)
        guard let cg = upright.cgImage,
              let quad = CaptureStyle.document.detect(upright, capturedPhoto: true) ?? DocumentProcessing.detectSheetFromContent(cg), quad.valid,
              DocumentProcessing.area(quad) < 0.9, hasBackground(around: quad, in: cg) else { return (upright, upright) }
        // Perspective correction keeps the photographed proportions; recover the
        // sheet's real shape from the camera geometry before snapping to paper.
        let aspect = trueAspect(quad, width: Double(cg.width), height: Double(cg.height))
        func flat(_ tone: Enhancement) throws -> UIImage {
            let output = try DocumentProcessing.render(CIImage(cgImage: cg), crop: quad, turns: 0, enhancement: tone, alignedOriginal: true)
            guard let flat = DocumentProcessing.context.createCGImage(output, from: output.extent) else {
                throw ScannerError.message("This photo couldn't be flattened. Try scanning the page instead.")
            }
            let image = UIImage(cgImage: flat)
            return snappedToPaper(aspect.map { resized(image, aspect: $0) } ?? image)
        }
        let layout = try flat(flattenTone)
        return (layout, readsOriginalTone ? try flat(.original) : layout)
    }
    /// Also read the text from the uncleaned page (tests turn it off to compare).
    nonisolated(unsafe) static var readsOriginalTone = true
    /// Height/width of the photographed rectangle in reality (Zhang & He,
    /// whiteboard rectification), with the focal length estimated from the
    /// quad or, when that is unstable, a typical phone wide camera (26 mm).
    static func trueAspect(_ quad: ScanQuad, width: Double, height: Double) -> Double? {
        guard quad.valid else { return nil }
        let p = quad.points.map { [$0.x * width - width / 2, $0.y * height - height / 2, 1.0] }
        let m1 = p[0], m2 = p[1], m4 = p[2], m3 = p[3]   // TL, TR, BR, BL
        func cross(_ a: [Double], _ b: [Double]) -> [Double] { [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]] }
        func dot(_ a: [Double], _ b: [Double]) -> Double { a[0] * b[0] + a[1] * b[1] + a[2] * b[2] }
        let d2 = dot(cross(m2, m4), m3), d3 = dot(cross(m3, m4), m2)
        guard abs(d2) > 1e-9, abs(d3) > 1e-9 else { return nil }
        let k2 = dot(cross(m1, m4), m3) / d2, k3 = dot(cross(m1, m4), m2) / d3
        let n2 = (0..<3).map { k2 * m2[$0] - m1[$0] }, n3 = (0..<3).map { k3 * m3[$0] - m1[$0] }
        let prior = 26 / 43.27 * hypot(width, height)
        var focal = prior
        if abs(n2[2] * n3[2]) > 1e-12 {
            let f2 = -(n2[0] * n3[0] + n2[1] * n3[1]) / (n2[2] * n3[2])
            if f2 > 0, sqrt(f2) > prior * 0.5, sqrt(f2) < prior * 2 { focal = sqrt(f2) }
        }
        let w2 = (n2[0] * n2[0] + n2[1] * n2[1]) / (focal * focal) + n2[2] * n2[2]
        let h2 = (n3[0] * n3[0] + n3[1] * n3[1]) / (focal * focal) + n3[2] * n3[2]
        guard w2 > 0, h2 > 0 else { return nil }
        let aspect = sqrt(h2 / w2)
        return aspect.isFinite && aspect > 0.2 && aspect < 5 ? aspect : nil
    }
    static func resized(_ image: UIImage, aspect: Double) -> UIImage {
        let w = image.size.width * image.scale
        let size = CGSize(width: w, height: (w * aspect).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
    /// True when the area outside the detected page looks unlike the page
    /// (a desk, a table), rather than more of the same paper.
    static func hasBackground(around quad: ScanQuad, in image: CGImage) -> Bool {
        let w = 160, h = max(1, Int(Double(image.height) / Double(image.width) * 160))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        func inside(_ x: Double, _ y: Double) -> Bool {
            var sign = 0
            for i in 0..<4 {
                let a = quad.points[i], b = quad.points[(i + 1) % 4]
                let c = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
                let s = c >= 0 ? 1 : -1
                if sign == 0 { sign = s } else if s != sign { return false }
            }
            return true
        }
        var inSum = 0.0, inCount = 0.0, outSum = 0.0, outCount = 0.0
        for y in 0..<h { for x in 0..<w {
            // Context rows run bottom-up.
            let i = ((h - 1 - y) * w + x) * 4
            let l = Double(data[i]) * 0.299 + Double(data[i + 1]) * 0.587 + Double(data[i + 2]) * 0.114
            if inside((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h)) { inSum += l; inCount += 1 } else { outSum += l; outCount += 1 }
        }}
        guard inCount > 0, outCount > Double(w * h) * 0.04 else { return false }
        return inSum / inCount - outSum / outCount > 28
    }
    static func snappedToPaper(_ image: UIImage) -> UIImage {
        let w = image.size.width * image.scale, h = image.size.height * image.scale
        guard w > 0, h > 0 else { return image }
        let portrait = h >= w
        let aspect = portrait ? h / w : w / h
        guard let target = paperAspects.min(by: { abs($0 / aspect - 1) < abs($1 / aspect - 1) }), abs(target / aspect - 1) < 0.07 else { return image }
        let size = portrait ? CGSize(width: w, height: (w * target).rounded()) : CGSize(width: (h * target).rounded(), height: h)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Recognizes text and rebuilds the page layout. Pictures are cut out
    /// immediately so the page image does not need to stay in memory.
    static func analyze(_ image: UIImage, pageSize: (Double, Double)? = nil) throws -> PageLayout {
        try autoreleasepool {
            var (flat, readFlat) = try flattenedPair(image)
            let separateReading = readFlat !== flat
            var prepared = try prepare(flat)
            // A page photographed or scanned slightly crooked bends every table
            // rule across rows; straighten it first.
            let skew = DocumentLayoutAnalyzer.skewAngle(prepared.raster)
            if abs(skew) >= 0.25 {
                flat = straightened(flat, degrees: skew)
                if separateReading { readFlat = straightened(readFlat, degrees: skew) }
                prepared = try prepare(flat)
            }
            try Task.checkCancellation()
            // Small print reads better from more pixels; layout needs fewer.
            let large = max(flat.size.width, flat.size.height) * flat.scale > analysisSide * 1.1
            var reading = try large ? prepare(separateReading ? readFlat : flat, maxSide: readingSide).image
                : (separateReading ? prepare(readFlat).image : prepared.image)
            // Read both renderings when there are two: the cleaned page reads crisp
            // print best, the uncleaned one soft or compressed photos.
            var cleaned = separateReading ? (large ? try prepare(flat, maxSide: readingSide).image : prepared.image) : reading
            var blocks = try separateReading ? TextRecognition.recognize([cleaned, reading]) : TextRecognition.recognize(reading)
            try Task.checkCancellation()
            // A page scanned on its side: its text reads sideways and would only
            // survive as a picture. Turn it the way that reads best.
            if sidewaysText(blocks, reading) {
                var best = (count: uprightCharacters(blocks, reading), flat: flat, prepared: prepared, reading: reading, blocks: blocks)
                for orientation in [UIImage.Orientation.right, .left] {
                    guard let cg = flat.cgImage else { break }
                    let turned = UIImage(cgImage: cg, scale: flat.scale, orientation: orientation)
                    let p = try prepare(turned)
                    var readTurned = turned
                    if separateReading, let rc = readFlat.cgImage { readTurned = UIImage(cgImage: rc, scale: readFlat.scale, orientation: orientation) }
                    let r = try large ? prepare(readTurned, maxSide: readingSide).image : (separateReading ? prepare(readTurned).image : p.image)
                    let b = try TextRecognition.recognize(r)
                    let n = uprightCharacters(b, r)
                    if n > best.count { best = (n, UIImage(cgImage: p.image), p, r, b) }
                    try Task.checkCancellation()
                }
                flat = best.flat; prepared = best.prepared; reading = best.reading; blocks = best.blocks; cleaned = best.reading
            }
            var page = DocumentLayoutAnalyzer.analyze(prepared.raster, blocks: blocks, pageSize: pageSize)
            // Cells are read again from the cleaned page (crisp, one cell at a time).
            if refineCells {
                refineTableText(&page, image: cleaned, scale: CGFloat(cleaned.width) / CGFloat(prepared.raster.width))
                // Spelling checks run on the main thread, like the refinement's own.
                fixIllReadings(&page)
            }
            DocumentLayoutAnalyzer.tidyParagraphs(&page)
            for i in page.graphics.indices {
                page.graphics[i].png = png(prepared.raster, page.graphics[i])
            }
            return page
        }
    }

    static func sideways(_ b: TextBlock, _ image: CGImage) -> Bool {
        b.height * Double(image.height) > b.width * Double(image.width) * 1.3 && b.text.count >= 2
    }
    static func uprightCharacters(_ blocks: [TextBlock], _ image: CGImage) -> Int {
        blocks.filter { !sideways($0, image) }.reduce(0) { $0 + $1.text.filter { $0.isLetter || $0.isNumber }.count }
    }
    static func sidewaysText(_ blocks: [TextBlock], _ image: CGImage) -> Bool {
        let side = blocks.filter { sideways($0, image) }.reduce(0) { $0 + $1.text.filter { $0.isLetter || $0.isNumber }.count }
        let upright = uprightCharacters(blocks, image)
        // Nothing upright at all: the reader may not have found sideways lines either.
        return (side >= 12 && side > upright * 2) || upright < 8
    }

    /// Turns the page back by `degrees` (positive: content falls to the right),
    /// keeping its size; uncovered corners become paper white.
    static func straightened(_ image: UIImage, degrees: Double) -> UIImage {
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let c = context.cgContext
            c.interpolationQuality = .high
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.rotate(by: -CGFloat(degrees) * .pi / 180)
            image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
    }

    /// "ll" read as "II" or "Il" ("Richmond HII"): a capitalised word that is
    /// not English, but is once those capitals become "ill"/"ll", is that word.
    static func fixIllReadings(_ page: inout PageLayout) {
        let token = try! NSRegularExpression(pattern: "\\b[A-Z][A-Za-z]*I[A-Za-z]*\\b")
        func fixed(_ text: String) -> String {
            let ns = text as NSString
            var out = text
            for m in token.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                let word = ns.substring(with: m.range)
                // Capitals alone are a code ("HII" in a code column); next to a
                // mixed-case word ("Richmond HII") they are a misread name.
                let mixedNearby = text.split(separator: " ").contains { $0.count >= 3 && $0 != $0.uppercased() && $0 != $0.lowercased() }
                guard word.count >= 3, word != word.uppercased() || (word.count <= 4 && mixedNearby),
                      correctlySpelled(String(word.prefix(1)) + word.dropFirst().lowercased()).isEmpty else { continue }
                let head = String(word.prefix(1)), rest = String(word.dropFirst())
                let options = [rest.replacingOccurrences(of: "II", with: "ill"), rest.replacingOccurrences(of: "II", with: "ll"),
                               rest.replacingOccurrences(of: "Il", with: "ll"), rest.replacingOccurrences(of: "lI", with: "ll"),
                               rest.replacingOccurrences(of: "iI", with: "ill"), rest.replacingOccurrences(of: "I", with: "l"),
                               rest.replacingOccurrences(of: "I", with: "ll")].map { head + $0 }.filter { $0 != word }
                guard let good = options.first(where: { !correctlySpelled($0).isEmpty && $0.dropFirst() == $0.dropFirst().lowercased() }) else { continue }
                out = (out as NSString).replacingCharacters(in: m.range, with: good)
            }
            return out
        }
        for index in page.items.indices {
            guard case .table(var table) = page.items[index] else { continue }
            for i in table.cells.indices {
                table.cells[i].lines = table.cells[i].lines.map { line in line.map { run in var run = run; run.text = fixed(run.text); return run } }
            }
            page.items[index] = .table(table)
        }
    }

    static var refineCells = true
    /// Reads each ruled-table cell again on its own. Without neighbouring
    /// cells and borders, short codes and bold text are read more reliably.
    static func refineTableText(_ page: inout PageLayout, image: CGImage, scale: CGFloat = 1) {
        // Form text that two readings agree on, or that is spelled correctly,
        // becomes editable; anything else stays in the form picture as printed.
        var confirmed = Set<String>()
        var disputed: [String: String] = [:]  // a second reading of the same words that differs
        func key(_ box: LBox) -> String { "\(box.x0),\(box.y0),\(box.x1),\(box.y1)" }
        func same(_ a: String, _ b: String) -> Bool {
            let strip = { (t: String) in t.filter { !$0.isWhitespace && $0 != "|" } }
            return strip(a) == strip(b)
        }
        for index in page.items.indices {
            switch page.items[index] {
            case .table(var table):
                for i in table.cells.indices where !table.cells[i].lines.isEmpty {
                    let cell = table.cells[i]
                    let inset = table.ruled ? max(5, min(cell.box.width, cell.box.height) * 0.08) : 2
                    let box = LBox(cell.box.x0 + inset, cell.box.y0 + inset, cell.box.x1 - inset, cell.box.y1 - inset)
                    let old = cell.text
                    guard let text = reread(box, in: image, scale: scale, old: old, prose: false) else { continue }
                    let like = cell.lines.flatMap { $0 }
                    table.cells[i].lines = [restyled(like, as: text) ?? LayoutText.styled(text, like: like)]
                }
                DocumentLayoutAnalyzer.fixCodeColumns(&table)
                DocumentLayoutAnalyzer.harmonizeRanges(&table)
                DocumentLayoutAnalyzer.tidyRecognizedText(&table)
                page.items[index] = .table(table)
            case .paragraph(var paragraph):
                for l in paragraph.lines.indices { for s in paragraph.lines[l].segments.indices {
                    let segment = paragraph.lines[l].segments[s]
                    let h = segment.box.height
                    // Form boxes are tight; a wide margin would pull in the neighbours.
                    let mx = page.form ? 0.35 : 0.6, my = page.form ? 0.25 : 0.3
                    let box = LBox(segment.box.x0 - h * mx, segment.box.y0 - h * my, segment.box.x1 + h * mx, segment.box.y1 + h * my)
                    let letters = segment.text.filter(\.isLetter).count, digits = segment.text.filter(\.isNumber).count
                    let prose = letters >= 8 && digits * 5 < letters
                    var second: String?
                    let text = reread(box, in: image, scale: scale, old: segment.text, prose: prose) { second = $0 }
                    if page.form, let second {
                        if same(second, segment.text) { confirmed.insert(key(segment.box)) }
                        else if second.split(separator: " ").count == segment.text.split(separator: " ").count { disputed[key(segment.box)] = second }
                    }
                    guard let text, let runs = restyled(segment.runs, as: text) else { continue }
                    paragraph.lines[l].segments[s].runs = runs
                } }
                page.items[index] = .paragraph(paragraph)
            }
        }
        if page.form {
            let candidates = page.items.flatMap { item -> [String] in
                guard case .paragraph(let p) = item else { return [] }
                return p.lines.flatMap { $0.segments.map(\.text) }
            }
            let spelled = correctlySpelled((candidates + disputed.values).joined(separator: " "))
            func plausible(_ text: String) -> Bool { DocumentLayoutAnalyzer.plausibleText(text) { spelled.contains($0) } }
            // Agreement only vouches for entries written larger than the printed labels
            // (names, amounts); two readings of tiny print often agree on the same misread.
            let heights = candidatesHeights(page).sorted()
            let label = heights.isEmpty ? 0 : heights[heights.count / 2]
            DocumentLayoutAnalyzer.keepText(&page) { segment in
                let k = key(segment.box)
                if confirmed.contains(k), segment.box.height >= label * 1.2, DocumentLayoutAnalyzer.confirmable(segment.text) { return true }
                // Two different spellings that both look right: either may be wrong.
                if let other = disputed[k], plausible(other) { return false }
                return plausible(segment.text)
            }
        }
    }
    /// Reads one region again, enlarged when the text is small. Returns the new
    /// text only when it is a confident, plausible correction of `old`.
    static func reread(_ box: LBox, in image: CGImage, scale: CGFloat, old: String, prose: Bool, reading: ((String) -> Void)? = nil) -> String? {
        let rect = CGRect(x: box.x0 * scale, y: box.y0 * scale, width: box.width * scale, height: box.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard rect.width > 8, rect.height > 8, var crop = image.cropping(to: rect) else { return nil }
        // Vision reads small print better when it is at least ~40 px tall.
        let enlarge = min(3, max(1, 64 / rect.height))
        if enlarge > 1.15, let space = CGColorSpace(name: CGColorSpace.sRGB),
           let context = CGContext(data: nil, width: Int(rect.width * enlarge), height: Int(rect.height * enlarge), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            if let big = context.makeImage() { crop = big }
        }
        let wide = old.contains { DocumentLayoutAnalyzer.isWide($0) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = prose
        request.recognitionLanguages = wide ? ["ko-KR", "en-US"] : ["en-US"]
        guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])) != nil else { return nil }
        let observations = (request.results ?? []).sorted { abs($0.boundingBox.midY - $1.boundingBox.midY) < 0.3 ? $0.boundingBox.minX < $1.boundingBox.minX : $0.boundingBox.midY > $1.boundingBox.midY }
        let candidates = observations.compactMap { $0.topCandidates(1).first }
        guard !candidates.isEmpty else { return nil }
        let text = candidates.map(\.string).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        reading?(text)
        guard !text.isEmpty, text != old else { return nil }
        let confidence = candidates.map(\.confidence).min() ?? 0
        let accepted = confidence >= (prose ? 0.5 : 0.8) && acceptsReread(old: old, new: text, prose: prose)
        if let log = refineLog { log("\(accepted ? "✓" : "✗") \(old) → \(text) (\(String(format: "%.2f", confidence)))") }
        return accepted ? text : nil
    }
    /// Carries word styles (bold, underline, color) over to corrected text
    /// with the same number of words.
    static func restyled(_ runs: [LayoutRun], as text: String) -> [LayoutRun]? {
        let styles = Set(runs.map { "\($0.bold)\($0.underline)\($0.color?.hex ?? "")" })
        if styles.count <= 1 { return LayoutText.styled(text, like: runs) }
        var oldWords: [LayoutRun] = []
        for run in runs { for word in run.text.split(separator: " ") { var r = run; r.text = String(word); oldWords.append(r) } }
        let newWords = text.split(separator: " ")
        guard newWords.count == oldWords.count else { return nil }
        var result: [LayoutRun] = []
        for (k, word) in newWords.enumerated() {
            var run = oldWords[k]; run.text = (k == 0 ? "" : " ") + word
            if var last = result.last, last.bold == run.bold, last.underline == run.underline, last.color == run.color { last.text += run.text; result[result.count - 1] = last }
            else { result.append(run) }
        }
        return result
    }
    static var refineLog: ((String) -> Void)?

    /// A reread replaces the page reading only for small, plausible
    /// corrections: same scripts, same Korean text, no new misspellings.
    static func acceptsReread(old: String, new: String, prose: Bool = false) -> Bool {
        func allowed(_ c: Character) -> Bool {
            guard let s = c.unicodeScalars.first else { return true }
            return s.isASCII || DocumentLayoutAnalyzer.isWide(c) || !CharacterSet.letters.contains(s)
        }
        guard new.allSatisfy(allowed) else { return false }
        let oldWide = old.filter { DocumentLayoutAnalyzer.isWide($0) }, newWide = new.filter { DocumentLayoutAnalyzer.isWide($0) }
        guard oldWide == newWide else { return false }
        guard distance(Array(old), Array(new)) <= max(2, min(old.count / 4, 6)) else { return false }
        // Codes and numbers keep every digit and letter they had.
        if !prose {
            guard old.filter(\.isNumber).sorted() == new.filter(\.isNumber).sorted(),
                  new.filter(\.isLetter).count >= old.filter(\.isLetter).count else { return false }
        }
        // Spacing-only differences are not corrections.
        guard old.filter({ !$0.isWhitespace }) != new.filter({ !$0.isWhitespace }) else { return false }
        // A digit never turns into a letter or symbol, and a letter never into a
        // symbol: "E1" → "ET" and "0J1" → "0/1" are misreads, not fixes.
        for (a, b) in substitutions(Array(old), Array(new)) {
            // In running text 0/O and 1/l are the usual confusions either way.
            let lookalike = prose && ((a == "0" && b == "O") || (a == "1" && (b == "l" || b == "I")))
            if a.isNumber && !b.isNumber && !lookalike { return false }
            if a.isLetter && !b.isLetter && !b.isNumber { return false }
        }
        // Correctly spelled words in the first reading must survive unchanged.
        let newWords = Set(new.split { !$0.isLetter }.map(String.init))
        // (A word the reread only completed, like "rices" → "Prices", is fine.)
        let kept = old.split { !$0.isLetter }.map(String.init).filter { word in
            word.count >= 3 && word != word.uppercased() && !newWords.contains(word) && !newWords.contains { $0.count > word.count && $0.contains(word) }
        }
        if !kept.isEmpty, misspellings(kept.joined(separator: " ")) < kept.count { return false }
        return misspellings(new) <= misspellings(old)
    }
    /// Character substitutions in an optimal alignment of two strings.
    static func substitutions(_ a: [Character], _ b: [Character]) -> [(Character, Character)] {
        let n = a.count, m = b.count
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n { for j in 1...m {
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            } }
        }
        var pairs: [(Character, Character)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                if a[i - 1] != b[j - 1] { pairs.append((a[i - 1], b[j - 1])) }
                i -= 1; j -= 1
            } else if d[i][j] == d[i - 1][j] + 1 { i -= 1 } else { j -= 1 }
        }
        return pairs
    }
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]; row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
    /// Misspelled mixed-case English words (codes in capitals are ignored).
    static func misspellings(_ text: String) -> Int {
        let words = text.split { !$0.isLetter || !$0.isASCII }.map(String.init).filter { $0.count >= 3 && $0 != $0.uppercased() }
        guard !words.isEmpty else { return 0 }
        let check = { () -> Int in
            let checker = UITextChecker()
            return words.filter { word in
                checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length), startingAt: 0, wrap: false, language: "en_US").location != NSNotFound
            }.count
        }
        return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
    }

    static func candidatesHeights(_ page: PageLayout) -> [Double] {
        page.items.flatMap { item -> [Double] in
            guard case .paragraph(let p) = item else { return [] }
            return p.lines.flatMap { $0.segments.map(\.box.height) }
        }
    }
    /// Words of `text` (as written) that English or French spelling accepts.
    static func correctlySpelled(_ text: String) -> Set<String> {
        // Also the lower-case form of capitals and words without a leading "r" (see plausibleText).
        let written = text.split { !$0.isLetter }.map(String.init).filter { $0.count >= 2 }
        let words = Set(written + written.map { $0.lowercased() } + written.filter { $0.first == "r" }.map { String($0.dropFirst()) })
        guard !words.isEmpty else { return [] }
        let check = { () -> Set<String> in
            let checker = UITextChecker()
            return words.filter { word in
                ["en_US", "fr_FR"].contains { language in
                    checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length), startingAt: 0, wrap: false, language: language).location == NSNotFound
                }
            }
        }
        return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
    }

    /// PNG of a page region. Cut-outs keep the ink and make paper transparent,
    /// so rules and line art can sit behind text without hiding it. Masked
    /// ink (text written as editable text) is left out, except on kept rules.
    static func png(_ raster: LayoutRaster, _ graphic: LayoutGraphic) -> Data? {
        let box = graphic.box, cutout = graphic.cutout
        let x0 = max(0, Int(box.x0)), y0 = max(0, Int(box.y0))
        let x1 = min(raster.width, Int(box.x1.rounded(.up))), y1 = min(raster.height, Int(box.y1.rounded(.up)))
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var masked = [Bool](repeating: false, count: graphic.masks.isEmpty ? 0 : w * h)
        func paint(_ b: LBox, _ value: Bool) {
            for y in stride(from: max(y0, Int(b.y0)), to: min(y1, Int(b.y1.rounded(.up))), by: 1) {
                for x in stride(from: max(x0, Int(b.x0)), to: min(x1, Int(b.x1.rounded(.up))), by: 1) { masked[(y - y0) * w + (x - x0)] = value }
            }
        }
        if !masked.isEmpty { graphic.masks.forEach { paint($0, true) }; graphic.keeps.forEach { paint($0, false) } }
        for y in 0..<h { for x in 0..<w {
            if !masked.isEmpty && masked[y * w + x] { continue }
            let s = ((y + y0) * raster.width + (x + x0)) * 4, d = (y * w + x) * 4
            let r = Int(raster.rgba[s]), g = Int(raster.rgba[s + 1]), b = Int(raster.rgba[s + 2])
            var a = 255
            if cutout { a = max(0, min(255, (215 - (r * 299 + g * 587 + b * 114) / 1000) * 255 / 120)) }
            // Premultiplied alpha.
            pixels[d] = UInt8(r * a / 255); pixels[d + 1] = UInt8(g * a / 255); pixels[d + 2] = UInt8(b * a / 255); pixels[d + 3] = UInt8(a)
        } }
        let cg: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return cg.flatMap { UIImage(cgImage: $0).pngData() }
    }

    static func theme() throws -> Data {
        guard let url = Bundle.main.url(forResource: "OfficeTheme", withExtension: "xml") else { throw ScannerError.message("The presentation theme is missing from the app.") }
        return try Data(contentsOf: url)
    }
    static let missingPicture: OfficeLayoutExport.ImageProvider = { _, _ in
        throw ScannerError.message("A picture on the page couldn't be prepared.")
    }
}

extension OfficeTable {
    /// Editable grid for a reconstructed table.
    init(layout table: LayoutTable, name: String, page: Int, item: Int) {
        var grid = Array(repeating: Array(repeating: "", count: table.columnCount), count: table.rowCount)
        var merges: [Merge] = []
        for cell in table.cells where cell.row < table.rowCount && cell.column < table.columnCount {
            grid[cell.row][cell.column] = cell.text
            if cell.rowSpan > 1 || cell.columnSpan > 1 { merges.append(Merge(row: cell.row, column: cell.column, rows: cell.rowSpan, columns: cell.columnSpan)) }
        }
        self.init(name: name, cells: grid, merges: merges)
        layoutPage = page; layoutItem = item
    }
}

extension LayoutTable {
    /// Writes corrected cell text back, keeping each cell's formatting.
    mutating func apply(_ table: OfficeTable) {
        for i in cells.indices {
            let cell = cells[i]
            guard table.cells.indices.contains(cell.row), table.cells[cell.row].indices.contains(cell.column) else { continue }
            let text = table.cells[cell.row][cell.column]
            guard text != cell.text else { continue }
            let like = cell.lines.flatMap { $0 }
            cells[i].lines = text.components(separatedBy: "\n").map { LayoutText.styled($0, like: like.isEmpty ? [LayoutRun(text: "")] : like) }.filter { !$0.isEmpty }
        }
    }
}
