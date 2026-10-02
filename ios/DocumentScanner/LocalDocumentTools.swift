import UIKit
import PDFKit
import Vision
import CoreImage.CIFilterBuiltins
import ImageIO

enum StampPosition: String, CaseIterable { case center = "Center", topLeft = "Top left", bottomRight = "Bottom right" }
struct DocumentStamp {
    var text = "COPY"
    var logo: Data?
    var opacity = 0.25
    var width = 0.5
    var angle = -30.0
    var position = StampPosition.center
    var repeated = false
    var valid: Bool {
        text.count <= 160 && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || logo != nil) &&
        opacity.isFinite && (0.05...1).contains(opacity) && width.isFinite && (0.1...0.8).contains(width) &&
        angle.isFinite && (-90...90).contains(angle)
    }
}

enum LocalDocumentTools {
    static func pageSize(_ page: PDFPage) throws -> CGSize {
        let rect = page.bounds(for: .mediaBox)
        let size = page.rotation % 180 == 0 ? rect.size : CGSize(width: rect.height, height: rect.width)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 20000, size.height <= 20000 else { throw ScannerError.message("Unsupported PDF page dimensions.") }
        return size
    }
    static func stamped(_ source: Data, indices: [Int], stamp: DocumentStamp) throws -> Data {
        guard stamp.valid, let pdf = PDFDocument(data: source), !pdf.isLocked,
              !indices.isEmpty, indices.allSatisfy({ (0..<pdf.pageCount).contains($0) }),
              stamp.logo == nil || UIImage(data: stamp.logo!) != nil else { throw ScannerError.message("Check the watermark and page selection.") }
        let output = PDFDocument()
        for i in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: i), let copy = page.copy() as? PDFPage else { throw ScannerError.message("A PDF page is unavailable.") }
            if !indices.contains(i) { output.insert(copy, at: output.pageCount); continue }
            let size = try pageSize(page)
            let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { c in
                c.beginPage()
                DocumentPDF.drawPage(page, in: c.cgContext, size: size, margin: 0)
                drawStamp(stamp, size: size, context: c.cgContext)
            }
            guard let marked = PDFDocument(data: data)?.page(at: 0), let ref = page.pageRef else { throw ScannerError.message("The watermark couldn't be created.") }
            // Keep links aligned after normalizing rotated PDF pages. Form widgets are flattened.
            for link in page.annotations where link.type == "Link" {
                if let item = link.copy() as? PDFAnnotation {
                    item.bounds = link.bounds.applying(ref.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size), rotate: Int32(page.rotation) - ref.rotationAngle, preserveAspectRatio: true))
                    marked.addAnnotation(item)
                }
            }
            output.insert(marked, at: output.pageCount)
        }
        guard let data = output.dataRepresentation() else { throw ScannerError.message("The PDF couldn't be created.") }
        return data
    }
    private static func drawStamp(_ stamp: DocumentStamp, size: CGSize, context: CGContext) {
        let logo = stamp.logo.flatMap(UIImage.init(data:))
        let width = size.width * stamp.width
        let font = UIFont.systemFont(ofSize: 36, weight: .semibold)
        let natural = logo?.size ?? (stamp.text as NSString).size(withAttributes: [.font: font])
        let scale = min(width / max(1, natural.width), size.height * 0.18 / max(1, natural.height))
        let w = natural.width * scale, h = natural.height * scale
        let radians = stamp.angle * .pi / 180
        let halfW = (abs(cos(radians))*w + abs(sin(radians))*h)/2
        let halfH = (abs(sin(radians))*w + abs(cos(radians))*h)/2
        var points: [CGPoint]
        if stamp.repeated {
            points = [0.25, 0.5, 0.75].flatMap { y in [0.28, 0.72].map { x in CGPoint(x: size.width*x, y: size.height*y) } }
        } else {
            switch stamp.position {
            case .center: points = [CGPoint(x: size.width/2, y: size.height/2)]
            case .topLeft: points = [CGPoint(x: 18+halfW, y: 18+halfH)]
            case .bottomRight: points = [CGPoint(x: size.width-18-halfW, y: size.height-18-halfH)]
            }
        }
        for point in points {
            context.saveGState(); context.setAlpha(stamp.opacity)
            context.translateBy(x: point.x, y: point.y); context.rotate(by: radians)
            UIGraphicsPushContext(context)
            if let logo { logo.draw(in: CGRect(x: -w/2, y: -h/2, width: w, height: h)) }
            else {
                (stamp.text as NSString).draw(in: CGRect(x: -w/2, y: -h/2, width: w+1, height: h+2), withAttributes: [.font: UIFont.systemFont(ofSize: 36*scale, weight: .semibold), .foregroundColor: UIColor.darkGray])
            }
            UIGraphicsPopContext(); context.restoreGState()
        }
    }
    static func identitySheet(_ source: Data, front: Int, back: Int?, paper: PaperSize) throws -> Data {
        guard let pdf = PDFDocument(data: source), !pdf.isLocked, (0..<pdf.pageCount).contains(front), let first = pdf.page(at: front),
              back == nil || (back != front && (0..<pdf.pageCount).contains(back!)), paper != .original else { throw ScannerError.message("Select different front and back pages.") }
        let pages = [first] + (back.flatMap { pdf.page(at: $0) }.map { [$0] } ?? [])
        for page in pages { _ = try pageSize(page) }
        let size = paper.size
        let card = CGSize(width: 85.6 * 72 / 25.4, height: 53.98 * 72 / 25.4)
        let totalHeight = card.height*CGFloat(pages.count) + (pages.count == 2 ? 36 : 0)
        return UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { c in
            c.beginPage(); UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: size))
            for (index, page) in pages.enumerated() {
                c.cgContext.saveGState()
                c.cgContext.translateBy(x: (size.width-card.width)/2, y: (size.height-totalHeight)/2 + CGFloat(index)*(card.height+36))
                DocumentPDF.drawPage(page, in: c.cgContext, size: card, margin: 0)
                c.cgContext.restoreGState()
            }
        }
    }
    static func longImages(_ source: Data, indices: [Int], width: Int = 1080, gap: Int = 0) throws -> ExportedFiles {
        guard let pdf = PDFDocument(data: source), !pdf.isLocked, !indices.isEmpty, indices.count <= 100,
              (320...1600).contains(width), (0...40).contains(gap) else { throw ScannerError.message("Check the image size and pages.") }
        var heights: [Int] = []
        for i in indices {
            guard let page = pdf.page(at: i) else { throw ScannerError.message("Page unavailable.") }
            let size = try pageSize(page)
            let height = Double(width)*size.height/size.width
            guard height <= 100000 else { throw ScannerError.message("This page is too tall. Use a smaller image width.") }
            heights.append(max(1, Int(ceil(height))))
        }
        return try strips(heights: heights, width: width, gap: gap) { index, rect, cg in
            guard let page = pdf.page(at: indices[index]) else { return }
            cg.saveGState(); cg.translateBy(x: rect.minX, y: rect.minY)
            DocumentPDF.drawPage(page, in: cg, size: rect.size, margin: 0)
            cg.restoreGState()
        }
    }
    // A bounded canvas per output part keeps very long documents from allocating one giant bitmap.
    static func strips(heights: [Int], width: Int, gap: Int = 0, draw: (Int, CGRect, CGContext) -> Void) throws -> ExportedFiles {
        guard !heights.isEmpty, heights.count <= 100, (1...1600).contains(width), (0...40).contains(gap),
              heights.allSatisfy({ (1...100000).contains($0) }) else { throw ScannerError.message("Invalid image dimensions.") }
        let total = heights.reduce(0,+) + gap*(heights.count-1)
        guard total*width <= 180_000_000 else { throw ScannerError.message("Choose fewer pages or a smaller width for this image.") }
        let directory = ExportFiles.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var urls: [URL] = []
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            for top in stride(from: 0, to: total, by: 10000) {
                try Task.checkCancellation()
                let url = try autoreleasepool { () throws -> URL in
                    let height = min(10000, total-top)
                    let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { c in
                        UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
                        var y = 0
                        for (i, h) in heights.enumerated() {
                            if y+h > top && y < top+height { draw(i, CGRect(x: 0, y: y-top, width: width, height: h), c.cgContext) }
                            y += h+gap
                        }
                    }
                    guard let bytes = image.pngData() else { throw ScannerError.message("The image couldn't be encoded.") }
                    let url = directory.appendingPathComponent(String(format: "Long-image-%03d.png", urls.count+1))
                    try bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]); return url
                }
                urls.append(url)
            }
            return ExportedFiles(directory: directory, urls: urls)
        } catch { ExportFiles.remove(directory); throw error }
    }
    static func previewImage(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1400] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
    static func thumbnail(_ data: Data, maxPixels: Int = 1800) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) else { throw ScannerError.message("This image couldn't be opened.") }
        return UIImage(cgImage: cg)
    }
    static func qrImage(_ text: String) throws -> UIImage {
        guard !text.isEmpty, text.utf8.count <= 1200 else { throw ScannerError.message("Enter 1–1200 bytes of text for this QR code.") }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let qr = filter.outputImage else { throw ScannerError.message("This text couldn't be encoded.") }
        let border: CGFloat = 4
        let extent = qr.extent.insetBy(dx: -border, dy: -border)
        let white = CIImage(color: .white).cropped(to: extent)
        let full = qr.composited(over: white).transformed(by: CGAffineTransform(translationX: border, y: border)).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = DocumentProcessing.context.createCGImage(full, from: full.extent) else { throw ScannerError.message("QR generation failed.") }
        return UIImage(cgImage: cg)
    }
    static func readQR(_ image: UIImage) throws -> [String] {
        guard let cg = Imaging.normalized(image).cgImage else { throw ScannerError.message("This image couldn't be read.") }
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        var found: [String] = []
        do {
            try VNImageRequestHandler(cgImage: cg).perform([request])
            found = (request.results ?? []).compactMap(\.payloadStringValue)
        } catch {
            // Some devices/simulator runtimes cannot create a Vision barcode context.
            // Core Image offers another entirely local QR decoder.
        }
        if found.isEmpty {
            guard let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: DocumentProcessing.context, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { throw ScannerError.message("QR recognition is unavailable on this device.") }
            found = detector.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        }
        return Array(Set(found)).sorted()
    }
}
