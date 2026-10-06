import UIKit
import CoreImage.CIFilterBuiltins
import PDFKit

// Image and OCR work runs away from the UI actor. Originals are never overwritten.
enum Imaging {
    static func normalized(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let pixelSize: CGSize
        if let cg = image.cgImage {
            switch image.imageOrientation {
            case .left, .right, .leftMirrored, .rightMirrored:
                pixelSize = CGSize(width: cg.height, height: cg.width)
            default:
                pixelSize = CGSize(width: cg.width, height: cg.height)
            }
        } else { pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale) }
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: pixelSize))
        }
    }
    /// Scales a normalized (scale 1) photo down to at most `maxPixels`, keeping its aspect.
    /// High-resolution captures (24 MP) stay usable by tools with tighter memory budgets.
    static func limited(_ image: UIImage, maxPixels: Int) -> UIImage {
        let pixels = image.size.width*image.size.height*image.scale*image.scale
        guard pixels > CGFloat(maxPixels) else { return image }
        let factor = sqrt(CGFloat(maxPixels)/pixels)
        let size = CGSize(width: floor(image.size.width*image.scale*factor), height: floor(image.size.height*image.scale*factor))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
    static func detect(_ image: UIImage) -> ScanQuad? {
        guard let cg = image.cgImage else { return nil }
        return DocumentProcessing.detect(cg)
    }
    static func preparePhoto(_ image: UIImage) -> (UIImage, ScanQuad?) {
        let normalized = normalized(image)
        return (normalized, detect(normalized))
    }
    static func source(_ page: ScanPage, root: URL) throws -> CIImage {
        guard let image = UIImage(contentsOfFile: root.appendingPathComponent(page.imageFile).path), let ci = CIImage(image: image) else { throw ScannerError.message("This page could not be opened. Your original has not been changed.") }
        return ci
    }
    /// Full-resolution renders peak at several hundred MB on 24 MP pages, so
    /// they run one at a time (PDF export, text recognition and thumbnails would
    /// otherwise overlap). Renders are synchronous and never wait on each other.
    private static let renderGate = DispatchSemaphore(value: 1)
    static func render(_ page: ScanPage, root: URL) throws -> UIImage {
        renderGate.wait(); defer { renderGate.signal() }
        try Task.checkCancellation()
        return try autoreleasepool { try renderUngated(page, root: root) }
    }
    private static func renderUngated(_ page: ScanPage, root: URL) throws -> UIImage {
        let ci = try source(page, root: root)
        let base = try DocumentProcessing.render(ci, crop: page.crop, turns: page.turns, enhancement: page.enhancement, strength: page.enhancementStrength, identityCleanup: page.identityBackgroundCleanup == true && page.cropReviewNeeded != true)
        let output = try trim(DocumentProcessing.adjust(base, settings: page.appearance), edges: page.trimming)
        guard let cg = DocumentProcessing.context.createCGImage(output, from: output.extent) else { throw ScannerError.message("The page could not be processed.") }
        return try applyErasures(UIImage(cgImage: cg), page: page)
    }
    /// Fills the spots painted out in the page editor.
    static func applyErasures(_ image: UIImage, page: ScanPage) throws -> UIImage {
        // One pass for all erasures: the page is rasterized once, and each
        // painted cluster is filled on its own.
        let strokes = page.activeErasures.flatMap(\.strokes).filter { !$0.points.isEmpty }
        guard !strokes.isEmpty else { return image }
        try Task.checkCancellation()
        return try autoreleasepool { try ImageToolEngine.erase(image, strokes: strokes.map { ImageToolEngine.Stroke(points: $0.points, width: CGFloat($0.width)) }) }
    }
    static func trim(_ image: CIImage, edges: PageTrim) throws -> CIImage {
        guard edges.valid else { throw ScannerError.message("The margin settings are invalid. Reset margins and try again.") }
        guard edges != .zero else { return image }
        let extent = image.extent
        let x0 = ceil(extent.minX + edges.left*extent.width), x1 = floor(extent.maxX - edges.right*extent.width)
        let y0 = ceil(extent.minY + edges.bottom*extent.height), y1 = floor(extent.maxY - edges.top*extent.height)
        guard x1-x0 >= 1, y1-y0 >= 1 else { throw ScannerError.message("Keep a larger area of the page.") }
        return image.cropped(to:CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0)).transformed(by:CGAffineTransform(translationX:-x0,y:-y0))
    }
    // Downsample only a completed document render. Resizing before the nonlinear
    // paper/ink filters changes which pixels are interpreted as text or background.
    static func previewThumbnail(_ image: UIImage, maxDimension: Int) throws -> UIImage {
        guard maxDimension > 0 else { throw ScannerError.message("The preview size is invalid.") }
        let limit = CGFloat(maxDimension)
        guard max(image.size.width, image.size.height) > limit else { return image }
        guard let thumbnail = image.preparingThumbnail(of: CGSize(width: limit, height: limit)) else {
            throw ScannerError.message("The preview couldn't be resized. Try again.")
        }
        return thumbnail
    }
    static func adjust(_ image: UIImage, settings: PageAdjustments) throws -> UIImage {
        guard let cg = image.cgImage else { throw ScannerError.message("This preview couldn't be opened.") }
        let result = DocumentProcessing.adjust(CIImage(cgImage: cg), settings: settings)
        guard let output = DocumentProcessing.context.createCGImage(result, from: result.extent) else {
            throw ScannerError.message("These adjustments couldn't be previewed. Try again.")
        }
        return UIImage(cgImage: output)
    }
    static func recognize(_ image: UIImage) throws -> [TextBlock] {
        guard let cg = image.cgImage else { throw ScannerError.message("This page couldn't be prepared for text recognition. Your scanned page is still saved.") }
        return try TextRecognition.recognize(cg)
    }
    static func pdf(_ document: ScanDocument, root: URL) throws -> Data {
        guard !document.pages.isEmpty else { throw ScannerError.message("Add at least one page before saving.") }
        if document.pages.contains(where: { $0.preservesPDF || !($0.annotations ?? []).isEmpty }) { return try DocumentPDF.compose(document, root: root) }
        // Render one page at a time to keep full-resolution memory bounded.
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: document.outputSize))
        var failure: Error?
        let data = renderer.pdfData { context in
            for page in document.pages {
                autoreleasepool {
                    do {
                        let image = try render(page, root: root)
                        let size = document.paper == .original ? CGSize(width: image.size.width * 0.5, height: image.size.height * 0.5) : document.outputSize
                        let bounds = CGRect(origin: .zero, size: size)
                        context.beginPage(withBounds: bounds, pageInfo: [:])
                        UIColor.white.setFill(); context.cgContext.fill(bounds)
                        let available = bounds.insetBy(dx: document.margin.points, dy: document.margin.points)
                        let scale = min(available.width/image.size.width, available.height/image.size.height)
                        let rect = CGRect(x: (size.width-image.size.width*scale)/2, y: (size.height-image.size.height*scale)/2, width: image.size.width*scale, height: image.size.height*scale)
                        image.draw(in: rect)
                        PDFTextLayer.draw(blocks: page.textBlocks, in: context.cgContext, imageRect: rect)
                    } catch { failure = error }
                }
                if failure != nil { break }
            }
        }
        if let failure { throw failure }
        return data
    }
    static func importPDF(_ url: URL, receive: (UIImage) async throws -> Void) async throws {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw ScannerError.message("This PDF cannot be opened. Unlock it before importing.") }
        guard pdf.pageCount <= 100 else { throw ScannerError.message("Import up to 100 pages at a time.") }
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { throw ScannerError.message("This PDF contains an invalid page.") }
            let scale = min(2, 2400/max(bounds.width, bounds.height))
            let size = CGSize(width: bounds.width*scale, height: bounds.height*scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                context.cgContext.translateBy(x: 0, y: size.height); context.cgContext.scaleBy(x: scale, y: -scale)
                context.cgContext.translateBy(x: -bounds.minX, y: -bounds.minY)
                page.draw(with: .mediaBox, to: context.cgContext)
            }
            try await receive(image)
        }
    }
}
