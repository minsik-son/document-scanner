import AppKit
import PDFKit
import CoreImage

// Compile with Models, DocumentProcessing, DocumentClarity, TextRecognition, PDFTextLayer and
// EmbeddedPDFImage. This uses the same processor/OCR/text layer as the app.
@main
struct CheckScanQuality {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 || args.count == 4 else {
            print("Usage: check-scan-quality input.pdf output-directory [reference-image]")
            return
        }
        let sourceURL = URL(fileURLWithPath: args[1])
        let outputURL = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        guard let pdf = PDFDocument(url: sourceURL), let page = pdf.page(at: 0), !pdf.isLocked else { throw ScannerError.message("The input PDF couldn't be opened.") }
        let cg: CGImage
        if let corePDF = CGPDFDocument(sourceURL as CFURL), let corePage = corePDF.page(at: 1),
           let photo = EmbeddedPDFImage.singlePhoto(corePage) {
            cg = photo
            print("Using embedded photo at original resolution:", photo.width, "x", photo.height)
        } else {
            let thumbnail = page.thumbnail(of: NSSize(width: 3600, height: 3600), for: .mediaBox)
            guard let raster = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ScannerError.message("The PDF couldn't be rendered.") }
            cg = raster
            print("Using rendered PDF page:", raster.width, "x", raster.height)
        }
        let ci = CIImage(cgImage: cg)
        let crop = DocumentProcessing.detect(cg) ?? .full
        print("Detected crop:", crop.points, "area:", DocumentProcessing.area(crop))
        let cleaned = try DocumentProcessing.render(ci, crop: crop, turns: 0, enhancement: .document)
        guard let scan = DocumentProcessing.context.createCGImage(cleaned, from: cleaned.extent) else { throw ScannerError.message("The scan couldn't be rendered.") }
        try writeImage(cg, to: outputURL.appendingPathComponent("before.png"))
        try writeImage(scan, to: outputURL.appendingPathComponent("after.png"))
        let blocks = try TextRecognition.recognize(scan)
        let pdfURL = outputURL.appendingPathComponent("improved-scan.pdf")
        let imageRect = try writePDF(scan, blocks: blocks, to: pdfURL)
        let exported = PDFDocument(url: pdfURL)
        let words = blocks.flatMap { $0.words ?? [] }
        let selectedWords = words.filter { word in
            let box = CGRect(x: imageRect.minX + CGFloat(word.x)*imageRect.width,
                             y: imageRect.maxY - CGFloat(word.y+word.height)*imageRect.height,
                             width: CGFloat(word.width)*imageRect.width, height: CGFloat(word.height)*imageRect.height)
            let selection = exported?.page(at: 0)?.selection(for: box)?.string ?? ""
            return selection.filter { !$0.isWhitespace }.contains(word.text.filter { !$0.isWhitespace })
        }.count
        let koreanWords = words.filter { $0.text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
        let koreanSelected = koreanWords.filter { word in
            let box = CGRect(x: imageRect.minX + CGFloat(word.x)*imageRect.width,
                             y: imageRect.maxY - CGFloat(word.y+word.height)*imageRect.height,
                             width: CGFloat(word.width)*imageRect.width, height: CGFloat(word.height)*imageRect.height)
            return exported?.page(at: 0)?.selection(for: box)?.string?.contains(word.text) == true
        }.count
        let hangulBefore = (page.string ?? "").unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        let hangulAfter = (exported?.string ?? "").unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
        let report = """
        Input PDF pages: \(pdf.pageCount)
        Input selectable text characters: \(page.string?.count ?? 0)
        Embedded source: \(cg.width) x \(cg.height)
        Revised image: \(scan.width) x \(scan.height)
        OCR lines: \(blocks.count)
        OCR word boxes: \(blocks.reduce(0) { $0 + ($1.words?.count ?? 0) })
        Words selected at their image positions: \(selectedWords) / \(words.count)
        Korean regions selected at their image positions: \(koreanSelected) / \(koreanWords.count)
        Korean syllables in the PDF text: \(hangulBefore) before / \(hangulAfter) after
        Available OCR language identifiers on this OS: \(try TextRecognition.supportedLanguages().joined(separator: ", "))
        Revised PDF selectable text characters: \(exported?.string?.count ?? 0)
        Processing uses the supplied PDF image. Original camera pixels are not available in this PDF.
        \nRecognized text:\n\(exported?.string ?? "")
        """
        try report.write(to: outputURL.appendingPathComponent("quality-report.txt"), atomically: true, encoding: .utf8)
        var images: [(CGImage, String)] = [(cg, "OUR · supplied PDF"), (scan, "OUR · revised processing")]
        if args.count == 4 {
            let referenceURL = URL(fileURLWithPath: args[3])
            guard let image = NSImage(contentsOf: referenceURL), let reference = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ScannerError.message("The reference image couldn't be opened.") }
            images.append((reference, "CamScanner · reference"))
        }
        let width = 720.0, height = 1000.0
        let comparison = NSImage(size: NSSize(width: width*Double(images.count), height: height+50))
        comparison.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width*Double(images.count), height: height+50).fill()
        for (i, entry) in images.enumerated() {
            let (image, label) = entry
            let imageSize = CGSize(width: image.width, height: image.height)
            let scale = min((width-30)/imageSize.width, (height-20)/imageSize.height)
            let size = CGSize(width: imageSize.width*scale, height: imageSize.height*scale)
            NSImage(cgImage: image, size: imageSize).draw(in: NSRect(x: Double(i)*width + (width-size.width)/2, y: (height-size.height)/2, width: size.width, height: size.height))
            (label as NSString).draw(at: NSPoint(x: Double(i)*width+24, y: height+12), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.black])
        }
        comparison.unlockFocus()
        if let tiff = comparison.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: outputURL.appendingPathComponent("comparison.png")) }
        print("Input selectable characters:", page.string?.count ?? 0, "Revised selectable characters:", exported?.string?.count ?? 0)
        print("Words selected at their image positions:", selectedWords, "/", words.count)
        print("Korean regions:", koreanSelected, "/", koreanWords.count, "Hangul syllables:", hangulBefore, "->", hangulAfter)
        print("Created local comparison and selectable-text improved-scan.pdf using shared app processing and OCR.")
    }
    static func writeImage(_ image: CGImage, to url: URL) throws {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ScannerError.message("Image export failed.") }
        try png.write(to: url)
    }
    static func writePDF(_ image: CGImage, blocks: [TextBlock], to url: URL) throws -> CGRect {
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else { throw ScannerError.message("PDF export failed.") }
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        let scale = min(576/Double(image.width), 756/Double(image.height))
        let size = CGSize(width: Double(image.width)*scale, height: Double(image.height)*scale)
        let imageRect = CGRect(x: (612-size.width)/2, y: (792-size.height)/2, width: size.width, height: size.height)
        context.draw(image, in: imageRect)
        PDFTextLayer.draw(blocks: blocks, in: context, imageRect: imageRect, coordinateSystem: .bottomLeft)
        context.endPDFPage(); context.closePDF()
        return imageRect
    }
}
