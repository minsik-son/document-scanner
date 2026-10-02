import PDFKit
import UIKit

enum CompressionPreset: String, CaseIterable {
  case balanced = "Balanced"
  case smaller = "Smaller file"
  case quality = "Higher quality"
  var pixels: Int { self == .smaller ? 1600 : (self == .balanced ? 2400 : 3200) }
  var quality: CGFloat { self == .smaller ? 0.55 : (self == .balanced ? 0.75 : 0.9) }
}
enum DocumentPDF {
  static func compose(_ document: ScanDocument, root: URL, compression: CompressionPreset? = nil)
    throws -> Data
  {
    let output = PDFDocument()
    for page in document.pages {
      try Task.checkCancellation()
      let result: PDFPage = try autoreleasepool {
        let base: PDFPage
        if page.preservesPDF {
          guard let name = page.sourcePDF, let index = page.sourcePDFPage,
            let original = PDFDocument(url: root.appendingPathComponent(name)),
            let source = original.page(at: index), let copy = source.copy() as? PDFPage
          else {
            throw ScannerError.message(
              "The original PDF page is unavailable. Your saved PDF has not been changed.")
          }
          copy.rotation = (copy.rotation + page.turns * 90) % 360
          let trimmed = try trimPage(copy, edges:page.trimming)
          if document.paper != .original || document.margin != .none {
            let rect = trimmed.bounds(for: .mediaBox)
            let natural =
              trimmed.rotation % 180 == 0 ? rect.size : CGSize(width: rect.height, height: rect.width)
            base = try layout(
              trimmed, size: document.paper == .original ? natural : document.outputSize,
              margin: document.margin.points)
          } else {
            base = trimmed
          }
        } else {
          var single = document
          var scan = page
          scan.sourcePDF = nil
          scan.annotations = nil
          single.pages = [scan]
          let bytes: Data
          if let compression {
            let rendered = try Imaging.previewThumbnail(
              Imaging.render(scan, root: root), maxDimension: compression.pixels)
            guard let jpeg = rendered.jpegData(compressionQuality: compression.quality),
              let image = UIImage(data: jpeg)
            else { throw ScannerError.message("Compression couldn't finish.") }
            let size =
              document.paper == .original
              ? CGSize(width: image.size.width * 0.5, height: image.size.height * 0.5)
              : document.outputSize
            let bounds = CGRect(origin: .zero, size: size)
            bytes = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
              context.beginPage()
              UIColor.white.setFill()
              context.fill(bounds)
              let available = bounds.insetBy(dx: document.margin.points, dy: document.margin.points)
              let scale = min(
                available.width / image.size.width, available.height / image.size.height)
              let rect = CGRect(
                x: (size.width - image.size.width * scale) / 2,
                y: (size.height - image.size.height * scale) / 2, width: image.size.width * scale,
                height: image.size.height * scale)
              image.draw(in: rect)
              PDFTextLayer.draw(blocks: scan.textBlocks, in: context.cgContext, imageRect: rect)
            }
          } else {
            bytes = try Imaging.pdf(single, root: root)
          }
          guard let rendered = PDFDocument(data: bytes)?.page(at: 0) else {
            throw ScannerError.message("This page couldn't be exported.")
          }
          base = rendered
        }
        let marks = page.annotations ?? []
        let addOCR =
          page.preservesPDF
          && (base.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !page.textBlocks.isEmpty
        guard !marks.isEmpty || addOCR else { return base }
        // Flatten the visible marks into a shareable copy, retaining the
        // editable objects in the library. PDF drawing retains base text.
        let bounds = base.bounds(for: .mediaBox)
        let size =
          base.rotation % 180 == 0
          ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData {
          context in
          context.beginPage()
          let cg = context.cgContext
          drawPage(base, in: cg, size: size, margin: 0)
          if addOCR {
            PDFTextLayer.draw(
              blocks: page.textBlocks, in: cg, imageRect: CGRect(origin: .zero, size: size))
          }
          draw(marks, size: size, context: cg)
        }
        guard let flattened = PDFDocument(data: bytes)?.page(at: 0) else {
          throw ScannerError.message("Annotations couldn't be exported.")
        }
        for annotation in base.annotations where annotation.type == "Link" {
          if let copy = annotation.copy() as? PDFAnnotation, let ref = base.pageRef {
            copy.bounds = annotation.bounds.applying(
              ref.getDrawingTransform(
                .mediaBox, rect: CGRect(origin: .zero, size: size),
                rotate: Int32(base.rotation) - ref.rotationAngle, preserveAspectRatio: true))
            flattened.addAnnotation(copy)
          }
        }
        return flattened
      }
      output.insert(result, at: output.pageCount)
    }
    guard let data = output.dataRepresentation(), output.pageCount == document.pages.count else {
      throw ScannerError.message("The PDF couldn't be completed.")
    }
    return data
  }
  static func trimPage(_ page: PDFPage, edges: PageTrim) throws -> PDFPage {
    guard edges.valid else { throw ScannerError.message("The PDF margin settings are invalid.") }
    guard edges != .zero else { return page }
    let box = page.bounds(for:.mediaBox)
    let size = page.rotation % 180 == 0 ? box.size : CGSize(width:box.height,height:box.width)
    let kept = edges.rect(in:size)
    let bytes = UIGraphicsPDFRenderer(bounds:CGRect(origin:.zero,size:kept.size)).pdfData { c in
      c.beginPage(); c.cgContext.translateBy(x:-kept.minX,y:-kept.minY)
      drawPage(page,in:c.cgContext,size:size,margin:0)
    }
    guard let result = PDFDocument(data:bytes)?.page(at:0), let ref = page.pageRef else { throw ScannerError.message("This PDF could not be trimmed.") }
    let transform = ref.getDrawingTransform(.mediaBox,rect:CGRect(origin:.zero,size:size),rotate:Int32(page.rotation)-ref.rotationAngle,preserveAspectRatio:true)
    let outputBounds = CGRect(origin:.zero,size:kept.size)
    for annotation in page.annotations where annotation.type == "Link" {
      let rect = annotation.bounds.applying(transform).offsetBy(dx:-kept.minX,dy:-edges.bottom*size.height).intersection(outputBounds)
      if !rect.isEmpty, !rect.isNull, let copy = annotation.copy() as? PDFAnnotation { copy.bounds = rect; result.addAnnotation(copy) }
    }
    return result
  }
  // Keep native glyphs/vectors when fitting mixed documents to a common sheet.
  static func drawPage(_ page: PDFPage, in cg: CGContext, size: CGSize, margin: CGFloat) {
    guard let ref = page.pageRef else { return }
    cg.saveGState()
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    let rect = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
    cg.concatenate(
      ref.getDrawingTransform(
        .mediaBox, rect: rect, rotate: Int32(page.rotation) - ref.rotationAngle,
        preserveAspectRatio: true))
    cg.drawPDFPage(ref)
    for annotation in page.annotations where annotation.type != "Link" {
      annotation.draw(with: .mediaBox, in: cg)
    }
    cg.restoreGState()
  }
  private static func layout(_ page: PDFPage, size: CGSize, margin: CGFloat) throws -> PDFPage {
    let bounds = CGRect(origin: .zero, size: size)
    let bytes = UIGraphicsPDFRenderer(bounds: bounds).pdfData { c in
      c.beginPage()
      UIColor.white.setFill()
      c.fill(bounds)
      drawPage(page, in: c.cgContext, size: size, margin: margin)
    }
    guard let result = PDFDocument(data: bytes)?.page(at: 0), let ref = page.pageRef else {
      throw ScannerError.message("PDF page layout failed.")
    }
    let transform = ref.getDrawingTransform(
      .mediaBox, rect: bounds.insetBy(dx: margin, dy: margin),
      rotate: Int32(page.rotation) - ref.rotationAngle, preserveAspectRatio: true)
    for annotation in page.annotations where annotation.type == "Link" {
      if let copy = annotation.copy() as? PDFAnnotation {
        copy.bounds = annotation.bounds.applying(transform)
        result.addAnnotation(copy)
      }
    }
    return result
  }
  static func draw(_ annotations: [PageAnnotation], size: CGSize, context: CGContext) {
    // SwiftUI Canvas supplies a CGContext without a UIKit current context.
    UIGraphicsPushContext(context)
    defer { UIGraphicsPopContext() }
    for item in annotations {
      let rect = CGRect(
        x: item.x * size.width, y: item.y * size.height, width: item.width * size.width,
        height: item.height * size.height)
      context.saveGState()
      let color: UIColor =
        item.color == "blue"
        ? .systemBlue
        : (item.color == "red" ? .systemRed : (item.color == "yellow" ? .systemYellow : .black))
      if item.kind == .text {
        (item.text as NSString).draw(
          in: rect,
          withAttributes: [
            .font: UIFont.systemFont(ofSize: max(8, item.lineWidth * 6)), .foregroundColor: color,
          ])
      } else if let data = item.imageData, let image = UIImage(data: data) {
        image.draw(in: rect)
      } else {
        context.setStrokeColor(color.withAlphaComponent(item.kind == .highlight ? 0.3 : 1).cgColor)
        context.setLineWidth(item.kind == .highlight ? item.lineWidth * 6 : item.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in item.strokes where !stroke.isEmpty {
          context.beginPath()
          for (index, point) in stroke.enumerated() {
            let p = CGPoint(
              x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            if index == 0 { context.move(to: p) } else { context.addLine(to: p) }
          }
          context.strokePath()
        }
      }
      context.restoreGState()
    }
  }
  static func protect(_ data: Data, password: String) throws -> Data {
    guard (8...32).contains(password.utf8.count),
      password.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }),
      let pdf = PDFDocument(data: data)
    else {
      throw ScannerError.message(
        "Use 8–32 English letters, numbers, spaces or symbols for this PDF password.")
    }
    let options: [PDFDocumentWriteOption: Any] = [
      .userPasswordOption: password, .ownerPasswordOption: String(UUID().uuidString.prefix(32)),
      PDFDocumentWriteOption(rawValue: kCGPDFContextEncryptionKeyLength as String): 128,
    ]
    guard let protected = pdf.dataRepresentation(options: options),
      let check = PDFDocument(data: protected), check.isLocked, check.unlock(withPassword: password)
    else {
      throw ScannerError.message("Password protection could not be verified. No file was shared.")
    }
    return protected
  }
  static func textBlocks(_ page: PDFPage) -> [TextBlock] {
    let bounds = page.bounds(for: .mediaBox)
    guard let selection = page.selection(for: bounds), bounds.width > 0, bounds.height > 0 else {
      return []
    }
    return selection.selectionsByLine().compactMap { line in
      guard let text = line.string, !text.isEmpty else { return nil }
      let r = line.bounds(for: page)
      return TextBlock(
        text: text, x: (r.minX - bounds.minX) / bounds.width,
        y: (bounds.maxY - r.maxY) / bounds.height, width: r.width / bounds.width,
        height: r.height / bounds.height)
    }
  }
}
