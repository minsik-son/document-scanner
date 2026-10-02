import UIKit
import Vision

/// Platform side of layout reconstruction: page pixels, on-device text
/// recognition and picture crops for the Office writers.
enum OfficeLayoutPages {
    /// Long side used for analysis; about 240 dpi for a Letter or A4 page.
    static let analysisSide: CGFloat = 2700

    struct Prepared {
        let raster: LayoutRaster
        let image: CGImage
    }

    /// Draws the page upright into an sRGB buffer so recognition and pixel
    /// analysis share one coordinate space whatever the photo orientation.
    static func prepare(_ image: UIImage, maxSide: CGFloat = analysisSide) throws -> Prepared {
        let pixelW = image.size.width * image.scale, pixelH = image.size.height * image.scale
        guard pixelW >= 16, pixelH >= 16 else { throw ScannerError.message("This page is too small to read.") }
        let scale = min(1, maxSide / max(pixelW, pixelH))
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

    /// Recognizes text and rebuilds the page layout. Pictures are cut out
    /// immediately so the page image does not need to stay in memory.
    static func analyze(_ image: UIImage, pageSize: (Double, Double)? = nil) throws -> PageLayout {
        try autoreleasepool {
            let prepared = try prepare(image)
            try Task.checkCancellation()
            let blocks = try TextRecognition.recognize(prepared.image)
            try Task.checkCancellation()
            var page = DocumentLayoutAnalyzer.analyze(prepared.raster, blocks: blocks, pageSize: pageSize)
            if refineCells { refineTableText(&page, image: prepared.image) }
            for i in page.graphics.indices {
                page.graphics[i].png = png(prepared.raster, page.graphics[i].box, cutout: page.graphics[i].cutout)
            }
            return page
        }
    }

    static var refineCells = true
    /// Reads each ruled-table cell again on its own. Without neighbouring
    /// cells and borders, short codes and bold text are read more reliably.
    static func refineTableText(_ page: inout PageLayout, image: CGImage) {
        for index in page.items.indices {
            guard case .table(var table) = page.items[index], table.ruled else { continue }
            for i in table.cells.indices where !table.cells[i].lines.isEmpty {
                let cell = table.cells[i]
                let inset = max(5, min(cell.box.width, cell.box.height) * 0.08)
                let rect = CGRect(x: cell.box.x0 + inset, y: cell.box.y0 + inset, width: cell.box.width - inset * 2, height: cell.box.height - inset * 2).integral
                guard rect.width > 8, rect.height > 8, let crop = image.cropping(to: rect) else { continue }
                let old = cell.text
                let wide = old.contains { DocumentLayoutAnalyzer.isWide($0) }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.recognitionLanguages = wide ? ["ko-KR", "en-US"] : ["en-US"]
                guard (try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])) != nil else { continue }
                let observations = (request.results ?? []).sorted { abs($0.boundingBox.midY - $1.boundingBox.midY) < 0.3 ? $0.boundingBox.minX < $1.boundingBox.minX : $0.boundingBox.midY > $1.boundingBox.midY }
                let candidates = observations.compactMap { $0.topCandidates(1).first }
                guard !candidates.isEmpty, candidates.allSatisfy({ $0.confidence >= 0.5 }) else { continue }
                let text = candidates.map(\.string).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, text != old else { continue }
                let accepted = (candidates.map(\.confidence).min() ?? 0) >= 0.8 && acceptsReread(old: old, new: text)
                if let log = refineLog { log("\(accepted ? "✓" : "✗") \(old) → \(text) (\(String(format: "%.2f", candidates.map(\.confidence).min() ?? 0)))") }
                guard accepted else { continue }
                let like = cell.lines.flatMap { $0 }
                table.cells[i].lines = [LayoutText.styled(text, like: like)]
            }
            DocumentLayoutAnalyzer.fixCodeColumns(&table)
            page.items[index] = .table(table)
        }
    }
    static var refineLog: ((String) -> Void)?

    /// A reread replaces the page reading only for small, plausible
    /// corrections: same scripts, same Korean text, no new misspellings.
    static func acceptsReread(old: String, new: String) -> Bool {
        func allowed(_ c: Character) -> Bool {
            guard let s = c.unicodeScalars.first else { return true }
            return s.isASCII || DocumentLayoutAnalyzer.isWide(c) || !CharacterSet.letters.contains(s)
        }
        guard new.allSatisfy(allowed) else { return false }
        let oldWide = old.filter { DocumentLayoutAnalyzer.isWide($0) }, newWide = new.filter { DocumentLayoutAnalyzer.isWide($0) }
        guard oldWide == newWide else { return false }
        guard distance(Array(old), Array(new)) <= max(2, old.count / 4) else { return false }
        // Correctly spelled words in the first reading must survive unchanged.
        let newWords = Set(new.split { !$0.isLetter }.map(String.init))
        let kept = old.split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 && $0 != $0.uppercased() && !newWords.contains($0) }
        if !kept.isEmpty, misspellings(kept.joined(separator: " ")) < kept.count { return false }
        return misspellings(new) <= misspellings(old)
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

    /// PNG of a page region. Cut-outs keep the ink and make paper transparent,
    /// so rules and line art can sit behind text without hiding it.
    static func png(_ raster: LayoutRaster, _ box: LBox, cutout: Bool) -> Data? {
        let x0 = max(0, Int(box.x0)), y0 = max(0, Int(box.y0))
        let x1 = min(raster.width, Int(box.x1.rounded(.up))), y1 = min(raster.height, Int(box.y1.rounded(.up)))
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
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
    static let missingPicture: OfficeLayoutExport.ImageProvider = { _, _, _ in
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
