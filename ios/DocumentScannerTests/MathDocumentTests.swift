import XCTest
import PDFKit
@testable import DocumentScanner

final class MathDocumentTests: XCTestCase {
    private let transcription = "수식 검토\nx² + y² = z²\n(a+b)/(c+d)\n√9 = 3\na < b & c > d"
    private func fixture() -> UIImage {
        let f = UIGraphicsImageRendererFormat();f.scale = 1
        return UIGraphicsImageRenderer(size:CGSize(width:1000,height:700),format:f).image { c in
            UIColor(white:0.92,alpha:1).setFill();c.fill(CGRect(x:0,y:0,width:1000,height:700))
            ("12 + 8 * 3\n45 - 9 = 36" as NSString).draw(in:CGRect(x:90,y:180,width:820,height:350),withAttributes:[.font:UIFont.systemFont(ofSize:55),.foregroundColor:UIColor.black])
        }
    }
    func testDigitizesThenRecognizesAllLinesWithoutCalculating() throws {
        let source = fixture()
        let scan = try MathDocumentEngine.prepare(source,crop:.full)
        XCTAssertEqual(scan.original.size,source.size)
        let text = try MathDocumentEngine.recognize(scan.image)
        XCTAssertTrue(text.contains("12"),text)
        XCTAssertTrue(text.contains("45"),text)
        XCTAssertGreaterThanOrEqual(text.components(separatedBy:"\n").count,2)
        let shot = XCTAttachment(image:scan.image);shot.name = "math-corrected-engine-scan";shot.lifetime = .keepAlways;add(shot)
    }
    func testTextAndDocumentExportsPreserveUnicodeAndDoNotExecuteMarkup() throws {
        let txt = try MathDocumentEngine.export(transcription,format:.txt)
        XCTAssertEqual(String(data:txt,encoding:.utf8),transcription)
        let word = try MathDocumentEngine.export(transcription,format:.word)
        let xml = try XCTUnwrap(entries(word)["word/document.xml"])
        XCTAssertTrue(XMLParser(data:xml).parse())
        let source = String(decoding:xml,as:UTF8.self)
        for line in transcription.components(separatedBy:"\n") { XCTAssertTrue(source.contains(OfficeExport.xml(line)),source) }
        let rtf = try MathDocumentEngine.export(transcription,format:.rtf)
        let decoded = try NSAttributedString(data:rtf,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
        XCTAssertEqual(decoded.string,transcription)
        let html = String(decoding:try MathDocumentEngine.export(transcription+"\n<script>alert(1)</script>",format:.html),as:UTF8.self)
        XCTAssertTrue(html.contains("&lt;script&gt;"));XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("x² + y² = z²"));XCTAssertTrue(html.contains("charset=\"utf-8\""))
    }
    func testPDFHasSelectableReviewedTextAndOptionalSeparateScan() throws {
        let textOnly = try XCTUnwrap(PDFDocument(data:MathDocumentEngine.export(transcription,format:.pdf)))
        let combined = try XCTUnwrap(PDFDocument(data:MathDocumentEngine.export(transcription,format:.pdf,reference:fixture())))
        XCTAssertEqual(textOnly.pageCount,1);XCTAssertEqual(combined.pageCount,2)
        let extracted = textOnly.string ?? ""
        for line in transcription.components(separatedBy:"\n") { XCTAssertTrue(extracted.contains(line),extracted) }
        XCTAssertTrue((combined.page(at:0)?.string ?? "").contains("수식 검토"))
        let preview = try XCTUnwrap(combined.page(at:0)).thumbnail(of:CGSize(width:595,height:842),for:.mediaBox)
        let shot = XCTAttachment(image:preview);shot.name = "math-selectable-pdf-text";shot.lifetime = .keepAlways;add(shot)
    }
    func testLongPDFPaginatesWithoutDroppingTailAndRejectsEmptyOversizedInput() throws {
        let body = (1...180).map { "Line \($0): (a+b)/(c+d) = x^2" }.joined(separator:"\n")
        let pdf = try XCTUnwrap(PDFDocument(data:MathDocumentEngine.export(body,format:.pdf)))
        XCTAssertGreaterThan(pdf.pageCount,1)
        let text = pdf.string ?? ""
        for n in 1...180 { XCTAssertTrue(text.contains("Line \(n):"),"Missing \(n)") }
        for format in MathDocumentEngine.Format.allCases {
            XCTAssertThrowsError(try MathDocumentEngine.export("  \n",format:format))
            XCTAssertThrowsError(try MathDocumentEngine.export(String(repeating:"a",count:200001),format:format))
        }
    }
    private func entries(_ data:Data) -> [String:Data] {
        func value(_ at:Int,_ bytes:Int) -> Int { (0..<bytes).reduce(0) { $0 | Int(data[at+$1]) << (8*$1) } }
        var offset = 0,result:[String:Data] = [:]
        while offset+30 <= data.count && value(offset,4) == 0x04034b50 {
            let size = value(offset+18,4), n = value(offset+26,2),extra = value(offset+28,2),start = offset+30+n+extra
            guard start+size <= data.count else { return [:] }
            result[String(decoding:data[(offset+30)..<(offset+30+n)],as:UTF8.self)] = data.subdata(in:start..<(start+size))
            offset = start+size
        };return result
    }
}
