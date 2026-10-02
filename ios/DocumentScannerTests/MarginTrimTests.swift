import XCTest
import UIKit
import PDFKit
@testable import DocumentScanner

@MainActor final class MarginTrimTests: XCTestCase {
    private var roots:[URL] = []
    private func store() -> LibraryStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root);return LibraryStore(root:root)
    }
    override func tearDown() async throws { for root in roots { try? FileManager.default.removeItem(at:root) } }
    private func fixture() -> UIImage {
        let format = UIGraphicsImageRendererFormat();format.scale = 1
        return UIGraphicsImageRenderer(size:CGSize(width:600,height:800),format:format).image { c in
            UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:600,height:800))
            UIColor.red.setFill();c.fill(CGRect(x:0,y:0,width:20,height:800));c.fill(CGRect(x:580,y:0,width:20,height:800));c.fill(CGRect(x:0,y:780,width:600,height:20))
            ("CLEAN DOCUMENT 12345" as NSString).draw(at:CGPoint(x:80,y:120),withAttributes:[.font:UIFont.systemFont(ofSize:28),.foregroundColor:UIColor.black])
        }
    }
    private func rgba(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating:0,count:cg.width*cg.height*4)
        let context = try XCTUnwrap(CGContext(data:&bytes,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height));return bytes
    }
    func testTrimPersistencePreviewExportAndResetKeepOriginal() async throws {
        let library = store(), id = try library.createDraft()
        try library.appendImage(fixture(),to:id,detectedCrop:.full,enhancement:.original)
        var doc = try XCTUnwrap(library.document(id));let file = library.url(doc.pages[0].imageFile)
        let original = try Data(contentsOf:file)
        doc.pages[0].trimming = PageTrim(top:0.05,right:0.05,bottom:0.1,left:0.05)
        doc.paper = .original;doc.margin = .none;try library.update(doc)
        let reopened = LibraryStore(root:library.root)
        doc = try XCTUnwrap(reopened.document(id))
        let exported = try Imaging.render(doc.pages[0],root:library.root)
        let renderer = ScanPreviewRenderer()
        let preview = try await renderer.render(doc.pages[0],root:library.root,maxDimension:nil)
        XCTAssertEqual(exported.size,CGSize(width:540,height:680));XCTAssertEqual(preview.size,exported.size)
        let a = try rgba(preview), b = try rgba(exported)
        XCTAssertEqual(a.count,b.count)
        let average = zip(a,b).reduce(0.0) { $0 + Double(abs(Int($1.0)-Int($1.1))) } / Double(a.count)
        XCTAssertLessThan(average,1.0)
        XCTAssertGreaterThan(b[1],240,"The red edge must be removed, leaving white paper.")
        let result = try await PDFExport.prepare(doc,root:library.root)
        let pdf = try XCTUnwrap(PDFDocument(data:result.data)), page = try XCTUnwrap(pdf.page(at:0))
        XCTAssertEqual(page.bounds(for:.mediaBox).size,CGSize(width:270,height:340))
        XCTAssertTrue(pdf.string?.contains("12345") == true)
        XCTAssertTrue(page.bounds(for:.mediaBox).contains(try XCTUnwrap(page.selection(for:page.bounds(for:.mediaBox))).bounds(for:page)))
        var reset = doc.pages[0];reset.trimming = .zero
        let resetPreview = try await renderer.render(reset,root:library.root,maxDimension:nil)
        XCTAssertEqual(resetPreview.size,CGSize(width:600,height:800))
        XCTAssertEqual(try Data(contentsOf:file),original)
    }
    func testTrimKeepsNativeTextLinksAndRotationWithoutRasterizing() async throws {
        let library = store(), file = library.url("input.pdf")
        let bytes = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:600,height:800)).pdfData { c in
            c.beginPage();("NATIVE SELECTABLE TEXT" as NSString).draw(at:CGPoint(x:80,y:150),withAttributes:[.font:UIFont.systemFont(ofSize:24)])
        }
        let native = try XCTUnwrap(PDFDocument(data:bytes)), page = try XCTUnwrap(native.page(at:0))
        let link = PDFAnnotation(bounds:CGRect(x:80,y:610,width:300,height:40),forType:.link,withProperties:nil);link.url=URL(string:"https://example.com")
        page.addAnnotation(link);try XCTUnwrap(native.dataRepresentation()).write(to:file)
        let id = try await library.importNativePDF(file)
        var doc = try XCTUnwrap(library.document(id));doc.pages[0].trimming = PageTrim(top:0.1,right:0.1,bottom:0.1,left:0.1)
        XCTAssertTrue(doc.pages[0].preservesPDF)
        let result = try await PDFExport.prepare(doc,root:library.root)
        let output = try XCTUnwrap(PDFDocument(data:result.data)?.page(at:0))
        XCTAssertEqual(output.bounds(for:.mediaBox).size,CGSize(width:480,height:640))
        XCTAssertTrue(output.string?.contains("NATIVE SELECTABLE TEXT") == true)
        let mappedLink = try XCTUnwrap(output.annotations.first { $0.url != nil })
        XCTAssertEqual(mappedLink.bounds.minX,20,accuracy:1);XCTAssertEqual(mappedLink.bounds.minY,530,accuracy:1)
        doc.pages[0].turns = 1
        let rotated = try XCTUnwrap(PDFDocument(data:DocumentPDF.compose(doc,root:library.root))?.page(at:0))
        XCTAssertEqual(rotated.bounds(for:.mediaBox).size,CGSize(width:640,height:480));XCTAssertTrue(rotated.string?.contains("NATIVE") == true)
    }
    func testEdgesRotateWithPageAndLegacyPagesHaveNoTrim() throws {
        let value = PageTrim(top:0.1,right:0.2,bottom:0.3,left:0.05)
        XCTAssertEqual(value.rotatedClockwise(),PageTrim(top:0.05,right:0.1,bottom:0.2,left:0.3))
        XCTAssertEqual((0..<4).reduce(value) { v,_ in v.rotatedClockwise() },value)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(ScanPage(imageFile:"old.jpg"))) as? [String:Any])
        json.removeValue(forKey:"edgeTrim")
        let old = try JSONDecoder().decode(ScanPage.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(old.trimming,.zero)
        XCTAssertFalse(PageTrim(top:Double.nan).valid);XCTAssertFalse(PageTrim(left:0.5).valid)
    }
    func testBackupRetainsTrimRecipe() throws {
        let library = store(), id = try library.createDraft();try library.appendImage(fixture(),to:id,detectedCrop:.full)
        var doc = try XCTUnwrap(library.document(id));doc.pages[0].trimming = PageTrim(right:0.04,bottom:0.06);try library.update(doc)
        let file = try library.exportBackup();defer{try? FileManager.default.removeItem(at:file)}
        let restored = store();try restored.importBackup(file)
        XCTAssertEqual(restored.drafts.first?.pages[0].trimming,doc.pages[0].trimming)
    }
}
