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
    /// Hex RGB of the stamp text.
    var color: UInt32 = 0x4E5968
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
        guard stamp.valid, stamp.logo == nil || UIImage(data: stamp.logo!) != nil else { throw ScannerError.message("Check the watermark and page selection.") }
        return try overlaid(source, indices: indices) { size, context in drawStamp(stamp, size: size, context: context) }
    }
    static func timestamped(_ source: Data, indices: [Int], stamp: TimestampStamp) throws -> Data {
        try overlaid(source, indices: indices) { size, context in drawTimestamp(stamp, size: size, context: context) }
    }
    /// Draws an overlay on the selected pages of a PDF, keeping text and links.
    static func overlaid(_ source: Data, indices: [Int], draw: (CGSize, CGContext) -> Void) throws -> Data {
        guard let pdf = PDFDocument(data: source), !pdf.isLocked,
              !indices.isEmpty, indices.allSatisfy({ (0..<pdf.pageCount).contains($0) }) else { throw ScannerError.message("Check the watermark and page selection.") }
        let output = PDFDocument()
        for i in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: i), let copy = page.copy() as? PDFPage else { throw ScannerError.message("A PDF page is unavailable.") }
            if !indices.contains(i) { output.insert(copy, at: output.pageCount); continue }
            let size = try pageSize(page)
            let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { c in
                c.beginPage()
                DocumentPDF.drawPage(page, in: c.cgContext, size: size, margin: 0)
                draw(size, c.cgContext)
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
    static func drawStamp(_ stamp: DocumentStamp, size: CGSize, context: CGContext) {
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
            points = [0.12, 0.31, 0.5, 0.69, 0.88].flatMap { y in [0.25, 0.75].map { x in CGPoint(x: size.width*x, y: size.height*y) } }
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
                let color = UIColor(red: CGFloat((stamp.color >> 16) & 0xff) / 255, green: CGFloat((stamp.color >> 8) & 0xff) / 255, blue: CGFloat(stamp.color & 0xff) / 255, alpha: 1)
                (stamp.text as NSString).draw(in: CGRect(x: -w/2, y: -h/2, width: w+1, height: h+2), withAttributes: [.font: UIFont.systemFont(ofSize: 36*scale, weight: .semibold), .foregroundColor: color])
            }
            UIGraphicsPopContext(); context.restoreGState()
        }
    }
    /// Page preview with an overlay, for live editing screens.
    static func renderPreview(_ page: PDFPage, maxSide: CGFloat = 1100, draw: (CGSize, CGContext) -> Void) throws -> UIImage {
        let size = try pageSize(page)
        let scale = min(1, maxSide / max(size.width, size.height)) * 2
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: size))
            DocumentPDF.drawPage(page, in: c.cgContext, size: size, margin: 0)
            draw(size, c.cgContext)
        }
    }
    static func drawTimestamp(_ stamp: TimestampStamp, size: CGSize, context: CGContext) {
        let unit = min(size.width, size.height) / 612 * stamp.scale
        let lines = stamp.lines
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let margin = 22 * unit
        func place(_ box: CGSize) -> CGPoint {
            switch stamp.corner {
            case .topLeft: return CGPoint(x: margin, y: margin)
            case .topRight: return CGPoint(x: size.width - margin - box.width, y: margin)
            case .bottomLeft: return CGPoint(x: margin, y: size.height - margin - box.height)
            case .bottomRight: return CGPoint(x: size.width - margin - box.width, y: size.height - margin - box.height)
            }
        }
        switch stamp.template {
        case .dateTime:
            let big = UIFont.systemFont(ofSize: 40 * unit, weight: .bold), small = UIFont.systemFont(ofSize: 13 * unit, weight: .semibold)
            let a = lines.time as NSString, b = lines.date as NSString
            let sa = a.size(withAttributes: [.font: big]), sb = b.size(withAttributes: [.font: small])
            var note: NSString?; var sn = CGSize.zero
            if !stamp.note.isEmpty { note = stamp.note as NSString; sn = note!.size(withAttributes: [.font: small]) }
            let box = CGSize(width: max(sa.width, sb.width, sn.width), height: sa.height + sb.height + (note == nil ? 0 : sn.height + 2 * unit))
            let pad = 10 * unit
            let frame = place(CGSize(width: box.width + pad * 2, height: box.height + pad * 1.4))
            // A soft plate keeps the label readable on both paper and photos.
            (stamp.white ? UIColor.black.withAlphaComponent(0.32) : UIColor.white.withAlphaComponent(0.78)).setFill()
            UIBezierPath(roundedRect: CGRect(origin: frame, size: CGSize(width: box.width + pad * 2, height: box.height + pad * 1.4)), cornerRadius: 10 * unit).fill()
            let o = CGPoint(x: frame.x + pad, y: frame.y + pad * 0.7)
            let shadow = NSShadow(); shadow.shadowColor = UIColor.black.withAlphaComponent(stamp.white ? 0.35 : 0); shadow.shadowBlurRadius = 2 * unit
            a.draw(at: o, withAttributes: [.font: big, .foregroundColor: stamp.ink, .shadow: shadow])
            b.draw(at: CGPoint(x: o.x, y: o.y + sa.height), withAttributes: [.font: small, .foregroundColor: stamp.ink, .shadow: shadow])
            note?.draw(at: CGPoint(x: o.x, y: o.y + sa.height + sb.height + 2 * unit), withAttributes: [.font: small, .foregroundColor: stamp.ink, .shadow: shadow])
        case .onSite:
            let title = UIFont.systemFont(ofSize: 15 * unit, weight: .bold), body = UIFont.systemFont(ofSize: 10 * unit, weight: .medium)
            let rows: [(String, String)] = [("Time", lines.date + " " + lines.time)] + (stamp.note.isEmpty ? [] : [("Note", stamp.note)])
            let rowSizes = rows.map { ("\($0.0)  \($0.1)" as NSString).size(withAttributes: [.font: body]) }
            let width = max(150 * unit, (rowSizes.map(\.width).max() ?? 0) + 20 * unit)
            let header = 26 * unit, rowH = 17 * unit
            let box = CGSize(width: width, height: header + rowH * CGFloat(rows.count) + 8 * unit)
            let o = place(box)
            UIColor(red: 0.19, green: 0.51, blue: 0.96, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: o.x, y: o.y, width: box.width, height: header), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 6 * unit, height: 6 * unit)).fill()
            UIColor.white.withAlphaComponent(0.92).setFill()
            UIBezierPath(roundedRect: CGRect(x: o.x, y: o.y + header, width: box.width, height: box.height - header), byRoundingCorners: [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: 6 * unit, height: 6 * unit)).fill()
            ("On-site record" as NSString).draw(at: CGPoint(x: o.x + 10 * unit, y: o.y + 5 * unit), withAttributes: [.font: title, .foregroundColor: UIColor.white])
            for (i, row) in rows.enumerated() {
                let y = o.y + header + 4 * unit + rowH * CGFloat(i)
                (row.0 as NSString).draw(at: CGPoint(x: o.x + 10 * unit, y: y), withAttributes: [.font: body, .foregroundColor: UIColor(red: 0.19, green: 0.51, blue: 0.96, alpha: 1)])
                (row.1 as NSString).draw(at: CGPoint(x: o.x + 48 * unit, y: y), withAttributes: [.font: body, .foregroundColor: UIColor(white: 0.15, alpha: 1)])
            }
        case .clockIn:
            let label = UIFont.systemFont(ofSize: 11 * unit, weight: .bold), big = UIFont.monospacedDigitSystemFont(ofSize: 24 * unit, weight: .bold), small = UIFont.systemFont(ofSize: 9 * unit, weight: .medium)
            let width = 130 * unit, top = 20 * unit, mid = 36 * unit
            let box = CGSize(width: width, height: top + mid + 16 * unit)
            let o = place(box)
            UIColor(red: 0.09, green: 0.73, blue: 0.6, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: o.x, y: o.y, width: width, height: top), byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 5 * unit, height: 5 * unit)).fill()
            UIColor.white.setFill(); UIBezierPath(rect: CGRect(x: o.x, y: o.y + top, width: width, height: mid)).fill()
            UIColor.black.withAlphaComponent(0.55).setFill()
            UIBezierPath(roundedRect: CGRect(x: o.x, y: o.y + top + mid, width: width, height: 16 * unit), byRoundingCorners: [.bottomLeft, .bottomRight], cornerRadii: CGSize(width: 5 * unit, height: 5 * unit)).fill()
            let t = (stamp.note.isEmpty ? "Clock-in" : stamp.note) as NSString
            let ts = t.size(withAttributes: [.font: label])
            t.draw(at: CGPoint(x: o.x + (width - ts.width) / 2, y: o.y + (top - ts.height) / 2), withAttributes: [.font: label, .foregroundColor: UIColor.white])
            let time = lines.time as NSString, ss = time.size(withAttributes: [.font: big])
            time.draw(at: CGPoint(x: o.x + (width - ss.width) / 2, y: o.y + top + (mid - ss.height) / 2), withAttributes: [.font: big, .foregroundColor: UIColor(white: 0.1, alpha: 1)])
            let d = lines.date as NSString, ds = d.size(withAttributes: [.font: small])
            d.draw(at: CGPoint(x: o.x + (width - ds.width) / 2, y: o.y + top + mid + (16 * unit - ds.height) / 2), withAttributes: [.font: small, .foregroundColor: UIColor.white])
        case .digital:
            let big = UIFont.monospacedDigitSystemFont(ofSize: 26 * unit, weight: .heavy), small = UIFont.monospacedSystemFont(ofSize: 9 * unit, weight: .bold)
            let time = lines.timeSeconds as NSString, d = lines.compactDate as NSString
            let ss = time.size(withAttributes: [.font: big]), ds = d.size(withAttributes: [.font: small])
            let box = CGSize(width: max(ss.width, ds.width) + 20 * unit, height: ss.height + ds.height + 14 * unit)
            let o = place(box)
            UIColor(white: 0.85, alpha: 0.95).setFill()
            UIBezierPath(roundedRect: CGRect(origin: o, size: box), cornerRadius: 7 * unit).fill()
            UIColor(white: 0.25, alpha: 1).setStroke()
            let frame = UIBezierPath(roundedRect: CGRect(origin: o, size: box).insetBy(dx: 2 * unit, dy: 2 * unit), cornerRadius: 6 * unit); frame.lineWidth = 1.5 * unit; frame.stroke()
            d.draw(at: CGPoint(x: o.x + 10 * unit, y: o.y + 6 * unit), withAttributes: [.font: small, .foregroundColor: UIColor(white: 0.15, alpha: 1)])
            time.draw(at: CGPoint(x: o.x + 10 * unit, y: o.y + 6 * unit + ds.height), withAttributes: [.font: big, .foregroundColor: UIColor(white: 0.1, alpha: 1)])
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

enum TimestampTemplate: String, CaseIterable, Identifiable {
    case dateTime = "Date & time", onSite = "On-site", clockIn = "Clock-in", digital = "Digital"
    var id: String { rawValue }
}
enum StampCorner: String, CaseIterable, Identifiable {
    case topLeft = "Top left", topRight = "Top right", bottomLeft = "Bottom left", bottomRight = "Bottom right"
    var id: String { rawValue }
}
/// A timestamp label. This records a chosen date, not a certified capture time.
struct TimestampStamp: Equatable {
    var template = TimestampTemplate.dateTime
    var date = Date()
    var includeSeconds = false
    var note = ""
    var corner = StampCorner.bottomRight
    var scale: CGFloat = 1
    var white = true
    var ink: UIColor { white ? .white : UIColor(white: 0.12, alpha: 1) }
    struct Lines { let time: String; let timeSeconds: String; let date: String; let compactDate: String }
    var lines: Lines {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = includeSeconds ? "HH:mm:ss" : "HH:mm"; let time = f.string(from: date)
        f.dateFormat = "HH:mm:ss"; let seconds = f.string(from: date)
        f.dateFormat = "EEE · MMM d, yyyy"; let long = f.string(from: date)
        f.dateFormat = "yyyy/MM/dd EEE"; let compact = f.string(from: date).uppercased()
        return Lines(time: time, timeSeconds: seconds, date: long, compactDate: compact)
    }
}
