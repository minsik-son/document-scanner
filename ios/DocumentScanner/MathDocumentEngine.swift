import UIKit
import CoreImage
import CoreText

struct MathScan {
    let original: UIImage
    let image: UIImage
    let crop: ScanQuad
    let detected: Bool
    var notice: String?
}

/// Image OCR produces a reviewable transcription, not a structural math/LaTeX model.
/// Never infer an exponent or fraction from an ambiguous character substitution.
enum MathDocumentEngine {
    static func prepare(_ source: UIImage, crop: ScanQuad? = nil) throws -> MathScan {
        try Task.checkCancellation()
        let original = Imaging.normalized(source)
        guard let cg = original.cgImage, cg.width * cg.height <= 20_000_000 else {
            throw ScannerError.message("Choose a photo up to 20 megapixels.")
        }
        let detected = crop ?? Imaging.detect(original)
        let quad = detected ?? .full
        let prepared = try DocumentProcessing.render(CIImage(cgImage:cg),crop:quad,turns:0,enhancement:.document)
        guard let output = DocumentProcessing.context.createCGImage(prepared,from:prepared.extent) else {
            throw ScannerError.message("The scan couldn't be prepared. Try another photo.")
        }
        try Task.checkCancellation()
        return MathScan(original:original,image:UIImage(cgImage:output),crop:quad,detected:detected != nil)
    }
    static func recognize(_ image: UIImage) throws -> String {
        guard let cg = image.cgImage else { throw ScannerError.message("The scan couldn't be read.") }
        // Dictionary correction can turn mathematical variable names into words.
        let blocks = try TextRecognition.recognize(cg,languageCorrection:false)
        try Task.checkCancellation()
        return blocks.map(\.text).joined(separator:"\n")
    }
    enum Format: String, CaseIterable, Identifiable {
        case txt = "Plain text", word = "Word", pdf = "PDF", rtf = "Rich text", html = "HTML"
        var id: String { rawValue }
        var extensionName: String {
            switch self { case .txt:return "txt";case .word:return "docx";case .pdf:return "pdf";case .rtf:return "rtf";case .html:return "html" }
        }
        var detail: String {
            switch self {
            case .txt:return "UTF-8 text · easy to copy and edit"
            case .word:return "DOCX · editable text, not Word equation objects"
            case .pdf:return "Selectable text · optional scan reference"
            case .rtf:return "Editable text for document editors"
            case .html:return "A document you can open in a browser"
            }
        }
    }
    static func export(_ text: String, format: Format, reference: UIImage? = nil) throws -> Data {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ScannerError.message("Add or correct the recognized text before exporting.") }
        guard text.utf8.count <= 200_000 else { throw ScannerError.message("Export up to 200 KB of text at a time.") }
        try Task.checkCancellation()
        switch format {
        case .txt:return Data(text.utf8)
        case .word:return try OfficeExport.word(text)
        case .html:
            return Data(("<!doctype html><html lang=\"und\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Math transcription</title><style>body{max-width:48rem;margin:3rem auto;padding:0 1.5rem;font:18px/1.6 system-ui;color:#172334}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}</style></head><body><pre>"+OfficeExport.xml(text)+"</pre></body></html>").utf8)
        case .rtf:
            let value = NSAttributedString(string:text,attributes:[.font:UIFont.systemFont(ofSize:14)])
            return try value.data(from:NSRange(location:0,length:value.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
        case .pdf:return try pdf(text,reference:reference)
        }
    }
    private static func pdf(_ text:String, reference:UIImage?) throws -> Data {
        let paragraph = NSMutableParagraphStyle();paragraph.lineSpacing = 6;paragraph.lineBreakMode = .byCharWrapping
        let value = NSAttributedString(string:text,attributes:[.font:UIFont.systemFont(ofSize:14),.foregroundColor:UIColor.black,.paragraphStyle:paragraph])
        let setter = CTFramesetterCreateWithAttributedString(value)
        let bounds = CGRect(x:0,y:0,width:595,height:842)
        let body = CGRect(x:42,y:50,width:511,height:742)
        var position = 0, failed = false
        let data = UIGraphicsPDFRenderer(bounds:bounds).pdfData { renderer in
            while position < value.length {
                if Task.isCancelled { failed = true;break }
                renderer.beginPage()
                let frame = CTFramesetterCreateFrame(setter,CFRange(location:position,length:0),CGPath(rect:body,transform:nil),nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { failed = true;break }
                let ctx = renderer.cgContext;ctx.saveGState()
                ctx.translateBy(x:0,y:bounds.height);ctx.scaleBy(x:1,y:-1);ctx.textMatrix = .identity
                CTFrameDraw(frame,ctx);ctx.restoreGState()
                position += visible.length
            }
            if let reference, !failed {
                renderer.beginPage()
                ("Scan reference" as NSString).draw(at:CGPoint(x:42,y:24),withAttributes:[.font:UIFont.systemFont(ofSize:12),.foregroundColor:UIColor.darkGray])
                let scale = min(body.width/reference.size.width,body.height/reference.size.height)
                let size = CGSize(width:reference.size.width*scale,height:reference.size.height*scale)
                reference.draw(in:CGRect(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2,width:size.width,height:size.height))
            }
        }
        try Task.checkCancellation()
        guard !failed else { throw ScannerError.message("The text couldn't fit in the PDF. Try a smaller selection.") }
        return data
    }
}
