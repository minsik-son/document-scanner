import XCTest
import PDFKit
@testable import DocumentScanner

@MainActor final class AdvancedOfflineTests:XCTestCase {
    func testOfficePageBoundariesAndMergedTables() throws {
        let word = try entries(OfficeExport.word("First page\u{000c}Second page"))
        let document = String(decoding:try XCTUnwrap(word["word/document.xml"]),as:UTF8.self)
        XCTAssertTrue(document.contains("<w:br w:type=\"page\"/>"))
        let first = OfficeTable(name:"One",cells:[["Merged",""],["00123","=SUM(A1)"]],merges:[.init(row:0,column:0,rows:1,columns:2)])
        let second = OfficeTable(name:"Two",cells:[["한글","中文"],["", "42"]])
        let workbook = try entries(OfficeExport.excel(tables:[first,second]))
        let sheet = String(decoding:try XCTUnwrap(workbook["xl/worksheets/sheet1.xml"]),as:UTF8.self)
        XCTAssertTrue(sheet.contains("mergeCell ref=\"A1:B1\""))
        XCTAssertTrue(sheet.contains("00123"));XCTAssertFalse(sheet.contains("<f>"))
        XCTAssertTrue(String(decoding:try XCTUnwrap(workbook["xl/worksheets/sheet2.xml"]),as:UTF8.self).contains("한글"))
    }
    func testOnDeviceStructuredTableRecognition() async throws {
        guard #available(iOS 26.0,*) else { throw XCTSkip("Structured table recognition requires iOS 26") }
        let format = UIGraphicsImageRendererFormat();format.scale = 1
        let image = UIGraphicsImageRenderer(size:CGSize(width:1200,height:800),format:format).image { renderer in
            UIColor.white.setFill();renderer.fill(CGRect(x:0,y:0,width:1200,height:800))
            let rows = [["Product","Quantity","Price"],["Paper","12","24.50"],["Pens","8","16.00"],["Folders","5","10.00"]]
            UIColor.black.setStroke()
            for row in 0...4 { let path = UIBezierPath();path.move(to:CGPoint(x:60,y:100+row*130));path.addLine(to:CGPoint(x:1140,y:100+row*130));path.lineWidth = 3;path.stroke() }
            for col in 0...3 { let path = UIBezierPath();path.move(to:CGPoint(x:60+col*360,y:100));path.addLine(to:CGPoint(x:60+col*360,y:620));path.lineWidth = 3;path.stroke() }
            for (r,row) in rows.enumerated() { for (c,text) in row.enumerated() {
                (text as NSString).draw(at:CGPoint(x:80+c*360,y:140+r*130),withAttributes:[.font:UIFont.systemFont(ofSize:36),.foregroundColor:UIColor.black])
            } }
        }
        let tables = try await OfficeTableRecognition.recognize(image,page:1)
        let table = try XCTUnwrap(tables.first)
        XCTAssertFalse(table.inferred,"Must recover actual table structure, not just fallback OCR")
        XCTAssertEqual(table.cells.count,4);XCTAssertEqual(table.columnCount,3)
        XCTAssertEqual(table.cells[1][0],"Paper");XCTAssertEqual(table.cells[2][1],"8")
    }
    private func fixture() -> UIImage {
        let f = UIGraphicsImageRendererFormat();f.scale = 1
        return UIGraphicsImageRenderer(size:CGSize(width:400,height:300),format:f).image { c in
            UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:400,height:300))
            UIColor.black.setFill();c.fill(CGRect(x:40,y:50,width:40,height:40));c.fill(CGRect(x:180,y:100,width:50,height:50));c.fill(CGRect(x:300,y:200,width:30,height:30))
        }
    }
    private func entries(_ data:Data) throws -> [String:Data] {
        func value(_ at:Int,_ bytes:Int) -> Int { (0..<bytes).reduce(0) { $0 | Int(data[at+$1]) << (8*$1) } }
        var offset = 0,result:[String:Data] = [:]
        while offset+30 <= data.count && value(offset,4) == 0x04034b50 {
            let size = value(offset+18,4), n = value(offset+26,2),extra = value(offset+28,2),start = offset+30+n+extra
            guard start+size <= data.count else { throw ScannerError.message("Invalid ZIP size") }
            let name = String(decoding:data[(offset+30)..<(offset+30+n)],as:UTF8.self),bytes = data.subdata(in:start..<(start+size))
            XCTAssertEqual(UInt32(value(offset+14,4)),LocalZIP.crc(bytes));result[name] = bytes;offset = start+size
        }
        XCTAssertEqual(value(offset,4),0x02014b50)
        XCTAssertEqual(value(data.count-22,4),0x06054b50)
        for (name,bytes) in result where name.hasSuffix(".xml") || name.hasSuffix(".rels") { XCTAssertTrue(XMLParser(data:bytes).parse(),"Invalid XML: \(name)") }
        return result
    }
    func testExcelKeepsLeadingAndInteriorEmptyCells() throws {
        func cell(_ text: String, _ x: Double, _ y: Double) -> TextBlock { TextBlock(text: text,x:x,y:y,width:0.12,height:0.04) }
        let blocks = [cell("A",0.1,0.1),cell("B",0.4,0.1),cell("C",0.7,0.1),
                      cell("B2",0.407,0.3),cell("A3",0.1,0.5),cell("C3",0.695,0.5)]
        let text = OfficeExport.tableText(blocks)
        XCTAssertEqual(text,"A\tB\tC\n\tB2\nA3\t\tC3")
        let archive = try entries(OfficeExport.excel(text))
        let xml = String(decoding:try XCTUnwrap(archive["xl/worksheets/sheet1.xml"]),as:UTF8.self)
        XCTAssertTrue(xml.contains("r=\"B2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">B2"))
        XCTAssertTrue(xml.contains("r=\"C3\" t=\"inlineStr\"><is><t xml:space=\"preserve\">C3"))
    }
    func testNativeResolutionSurvivesDecodeEditingAndSlideExport() throws {
        let format = UIGraphicsImageRendererFormat();format.scale = 1
        let original = UIGraphicsImageRenderer(size:CGSize(width:2600,height:100),format:format).image { c in
            UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:2600,height:100))
        }
        let data = try XCTUnwrap(original.pngData())
        let decoded = try OfflineWork.photo(data)
        XCTAssertEqual(decoded.cgImage?.width,2600)
        XCTAssertEqual(try OfflineImageEngine.removeColoredMarks(decoded,strength:0.7).cgImage?.width,2600)
        XCTAssertEqual(try OfflineImageEngine.erase(decoded,rect:CGRect(x:0.3,y:0.3,width:0.2,height:0.2)).cgImage?.width,2600)
        let package = try entries(OfficeExport.powerpoint([decoded],texts:[],editable:false))
        let image = UIImage(data:try XCTUnwrap(package["ppt/media/image1.png"]))
        XCTAssertEqual(image?.cgImage?.width,2600)
        XCTAssertThrowsError(try OfflineWork.photo(data,remainingPixels:100))
    }
    func testCancellationReachesBackgroundWorker() async throws {
        let started = expectation(description:"Worker started")
        let stopped = expectation(description:"Worker stopped")
        let work = Task {
            try await OfflineWork.perform { () throws -> Int in
                defer { stopped.fulfill() }
                started.fulfill()
                while true { try Task.checkCancellation(); Thread.sleep(forTimeInterval:0.001) }
            }
        }
        await fulfillment(of:[started],timeout:3)
        work.cancel()
        do { _ = try await work.value; XCTFail("Canceled work must not publish a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of:[stopped],timeout:3)
    }
    func testBookCurvePreservesInkAtTopAndBottom() throws {
        let format = UIGraphicsImageRendererFormat();format.scale = 1
        let source = UIGraphicsImageRenderer(size:CGSize(width:400,height:300),format:format).image { c in
            UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:400,height:300))
            UIColor.red.setFill();c.fill(CGRect(x:0,y:0,width:400,height:6))
            UIColor.blue.setFill();c.fill(CGRect(x:0,y:294,width:400,height:6))
        }
        for curve in [-0.2,0.2] {
            let result = try XCTUnwrap(OfflineImageEngine.book(source,split:0.5,curve:curve,twoPages:false).first)
            let pixels = try OfflineImageEngine.raster(result).bytes
            let red = stride(from:0,to:pixels.count,by:4).filter { pixels[$0]>200 && pixels[$0+2]<50 }.count
            let blue = stride(from:0,to:pixels.count,by:4).filter { pixels[$0+2]>200 && pixels[$0]<50 }.count
            XCTAssertGreaterThan(red,1000);XCTAssertGreaterThan(blue,1000)
        }
    }
    func testExportOfficeCompatibilityFixtures() throws {
        let samples:[(String,String,Data)] = [
            ("Offline-Word.docx","org.openxmlformats.wordprocessingml.document",try OfficeExport.word("한글 English\nOffline document")),
            ("Offline-Excel.xlsx","org.openxmlformats.spreadsheetml.sheet",try OfficeExport.excel("Name\tValue\n한국어\t00123")),
            ("Offline-Slides.pptx","org.openxmlformats.presentationml.presentation",try OfficeExport.powerpoint([fixture()],texts:["한글 English"],editable:false)),
            ("Offline-Editable-Slides.pptx","org.openxmlformats.presentationml.presentation",try OfficeExport.powerpoint([fixture()],texts:["한글 English"],editable:true))
        ]
        for (name,type,bytes) in samples { _ = try entries(bytes);let attachment = XCTAttachment(data:bytes,uniformTypeIdentifier:type);attachment.name = name;attachment.lifetime = .keepAlways;add(attachment) }
    }
    func testWordUnicodeEscapingAndZIPIntegrity() throws {
        let data = try OfficeExport.word("한글 & English <sample>\nالعربية 日本語")
        let package = try entries(data),xml = String(decoding:try XCTUnwrap(package["word/document.xml"]),as:UTF8.self)
        XCTAssertTrue(xml.contains("한글 &amp; English &lt;sample&gt;"));XCTAssertTrue(xml.contains("العربية 日本語"))
        XCTAssertEqual(LocalZIP.crc(Data("123456789".utf8)),0xcbf43926)
        XCTAssertThrowsError(try LocalZIP.encode([("../bad",Data())]));XCTAssertThrowsError(try LocalZIP.encode([("same",Data()),("same",Data())]))
    }
    func testExcelCellsAndFormulaSafety() throws {
        let zip = try entries(OfficeExport.excel("Name\tValue\n한글\t=HYPERLINK(\"bad\")\n00123\t-42"))
        let xml = String(decoding:try XCTUnwrap(zip["xl/worksheets/sheet1.xml"]),as:UTF8.self)
        XCTAssertTrue(xml.contains("r=\"B2\" t=\"inlineStr\""));XCTAssertFalse(xml.contains("<f>"));XCTAssertTrue(xml.contains("00123"))
        XCTAssertEqual(OfficeExport.column(25),"Z");XCTAssertEqual(OfficeExport.column(26),"AA")
        let blocks = [TextBlock(text:"B",x:0.5,y:0.1,width:0.1,height:0.04),TextBlock(text:"C",x:0.1,y:0.3,width:0.1,height:0.04),TextBlock(text:"A",x:0.1,y:0.1,width:0.1,height:0.04)]
        XCTAssertEqual(OfficeExport.tableText(blocks),"A\tB\nC")
    }
    func testPowerPointImageAndEditablePackages() throws {
        for editable in [false,true] {
            let package = try entries(OfficeExport.powerpoint([fixture(),fixture()],texts:["한글 one","two"],editable:editable))
            XCTAssertNotNil(package["ppt/slides/slide2.xml"]);XCTAssertNotNil(package["ppt/slideLayouts/slideLayout1.xml"])
            XCTAssertEqual(package["ppt/media/image1.png"] == nil,editable)
            if editable { XCTAssertTrue(String(decoding:package["ppt/slides/slide1.xml"]!,as:UTF8.self).contains("한글 one")) }
        }
        XCTAssertThrowsError(try OfficeExport.powerpoint([],texts:[],editable:false))
    }
    func testPresentationSelectedOrderAndFullImageDimensions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var pages:[PresentationPage] = []
        for (index,size) in [CGSize(width:900,height:1200),CGSize(width:1600,height:800)].enumerated() {
            let image = UIGraphicsImageRenderer(size:size,format:format).image { c in
                (index == 0 ? UIColor.red : UIColor.blue).setFill();c.fill(CGRect(origin:.zero,size:size))
            }
            let url = directory.appendingPathComponent("\(index).png")
            try XCTUnwrap(image.pngData()).write(to:url)
            pages.append(PresentationPage(title:"\(index)",source:.photo(url)))
        }
        pages.swapAt(0,1)
        let package = try entries(OfficeExport.powerpoint(pageCount:pages.count,texts:[],editable:false) { try pages[$0].image(root:directory) })
        let first = try XCTUnwrap(UIImage(data:try XCTUnwrap(package["ppt/media/image1.png"])))
        let second = try XCTUnwrap(UIImage(data:try XCTUnwrap(package["ppt/media/image2.png"])))
        XCTAssertEqual(first.size,CGSize(width:1600,height:800))
        XCTAssertEqual(second.size,CGSize(width:900,height:1200))
        XCTAssertNotNil(package["ppt/slides/slide2.xml"])
        XCTAssertNil(package["ppt/slides/slide3.xml"])
        pages.removeFirst()
        let reduced = try entries(OfficeExport.powerpoint(pageCount:pages.count,texts:[],editable:false) { try pages[$0].image(root:directory) })
        XCTAssertNil(reduced["ppt/slides/slide2.xml"])
        XCTAssertEqual(UIImage(data:try XCTUnwrap(reduced["ppt/media/image1.png"]))?.size,second.size)
    }
    func testObjectCountCoordinatesAndThresholdValidation() throws {
        let points = try OfflineImageEngine.count(fixture(),threshold:0.5,minimumArea:0.002,lightObjects:false)
        XCTAssertEqual(points.count,3)
        XCTAssertTrue(points.contains { abs($0.x-0.15)<0.02 && abs($0.y-0.233)<0.02 })
        XCTAssertThrowsError(try OfflineImageEngine.count(fixture(),threshold:.nan,minimumArea:0.002,lightObjects:false))
    }
    func testErasePreservesPixelsOutsideSelection() throws {
        let original = fixture(),before = try OfflineImageEngine.raster(original)
        let result = try OfflineImageEngine.erase(original,rect:CGRect(x:0.08,y:0.13,width:0.15,height:0.20)),after = try OfflineImageEngine.raster(result)
        let outside = (120*400+200)*4,inside = (65*400+60)*4
        XCTAssertEqual(Array(before.bytes[outside..<(outside+4)]),Array(after.bytes[outside..<(outside+4)]))
        XCTAssertGreaterThan(after.bytes[inside],220);XCTAssertLessThan(before.bytes[inside],10)
        XCTAssertThrowsError(try OfflineImageEngine.erase(original,rect:.zero))
    }
    func testColoredMarkCleanupProtectsBlackInk() throws {
        let image = fixture(),clean = try OfflineImageEngine.removeColoredMarks(image,strength:1)
        let a = try OfflineImageEngine.raster(image),b = try OfflineImageEngine.raster(clean)
        XCTAssertEqual(a.bytes,b.bytes)
        let f = UIGraphicsImageRendererFormat();f.scale = 1
        let yellow = UIGraphicsImageRenderer(size:CGSize(width:40,height:40),format:f).image { c in UIColor.yellow.setFill();c.fill(CGRect(x:0,y:0,width:40,height:40)) }
        let y = try OfflineImageEngine.raster(OfflineImageEngine.removeColoredMarks(yellow,strength:1))
        XCTAssertGreaterThan(y.bytes[2],240)
    }
    func testBookSplitAndCurveBounds() throws {
        let image = fixture(),pages = try OfflineImageEngine.book(image,split:0.5,curve:0,twoPages:true)
        XCTAssertEqual(pages.count,2);XCTAssertEqual(pages[0].cgImage?.width,200);XCTAssertEqual(pages[1].cgImage?.height,300)
        XCTAssertEqual(try OfflineImageEngine.book(image,split:0.5,curve:0.12,twoPages:false).count,1)
        XCTAssertThrowsError(try OfflineImageEngine.book(image,split:0.5,curve:.nan,twoPages:true))
    }
    func testMegaRegistrationFindsKnownPhotoOffset() throws {
        let f = UIGraphicsImageRendererFormat();f.scale = 1
        let source = UIGraphicsImageRenderer(size:CGSize(width:600,height:400),format:f).image { c in
            UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:600,height:400))
            var seed:UInt32 = 971
            for y in stride(from:0,to:400,by:12) { for x in stride(from:0,to:600,by:12) { seed = 1664525 &* seed &+ 1013904223;UIColor(white:CGFloat((seed >> 16)%200)/255,alpha:1).setFill();c.fill(CGRect(x:x,y:y,width:10,height:10)) } }
        }
        let a = UIImage(cgImage:try XCTUnwrap(source.cgImage?.cropping(to:CGRect(x:0,y:0,width:400,height:300))))
        let b = UIImage(cgImage:try XCTUnwrap(source.cgImage?.cropping(to:CGRect(x:120,y:48,width:400,height:300))))
        let result = try OfflineImageEngine.alignment(reference:a,floating:b)
        XCTAssertEqual(result.x,120,accuracy:3);XCTAssertEqual(result.y,48,accuracy:3)
    }
    func testMegaCanvasAndBudget() throws {
        let image = fixture(),out = try OfflineImageEngine.mega([image,image],offsets:[.zero,CGPoint(x:300,y:-50)])
        XCTAssertEqual(out.size,CGSize(width:700,height:350))
        XCTAssertThrowsError(try OfflineImageEngine.mega([image,image],offsets:[.zero,CGPoint(x:15000,y:15000)]))
        XCTAssertThrowsError(try OfflineImageEngine.mega([image],offsets:[.zero]))
    }
    func testImagePDFPhysicalDimensionsAndSelectableText() throws {
        let text = TextBlock(text:"한글 English",x:0.1,y:0.2,width:0.6,height:0.1)
        let data = try OfflineImageEngine.pdf([fixture()],millimeters:CGSize(width:35,height:45),text:[[text]])
        let pdf = try XCTUnwrap(PDFDocument(data:data)),page = try XCTUnwrap(pdf.page(at:0))
        XCTAssertEqual(page.bounds(for:.mediaBox).width,35/25.4*72,accuracy:0.01)
        XCTAssertTrue(pdf.string?.contains("한글") == true);XCTAssertTrue(pdf.string?.contains("English") == true)
    }
    func testMathPrecedenceDomainsAndNoCodeEvaluation() throws {
        XCTAssertEqual(try LocalMath.evaluate("8 − 2 × 3"),2)
        XCTAssertEqual(try LocalMath.evaluate("2+3*4"),14);XCTAssertEqual(try LocalMath.evaluate("-2^2"),-4)
        XCTAssertEqual(try LocalMath.evaluate("2^3^2"),512);XCTAssertEqual(try LocalMath.evaluate("sqrt(81)+sin(pi/2)"),10,accuracy:0.0001)
        for invalid in ["1/0","sqrt(-1)","2+","shell(1)","1;2","("+String(repeating:"(",count:100)+"1"] { XCTAssertThrowsError(try LocalMath.evaluate(invalid)) }
    }
    /// Lines as the camera reads an exercise sheet (from the convert corpus).
    func testMathSolvesPhotographedExerciseLines() throws {
        let cases: [(String, String)] = [
            ("① 225÷25 =", "9"), ("Q2. 14 × 1.2 =", "16.8"), ("Q2.14 × 1.2=", "16.8"), ("3) (56 - 75) × 110 =", "-2090"),
            ("5) (7 + 6)⁴ =", "28561"), ("√(8 × 5) + (2 + 2)² =", "22.32455532"), ("Q5. √144 =", "12"),
            ("(35-97.08)x(47.6+476) = -32505.09", "-32505.088"), ("12,5 + 1,250", "1262.5"), ("2(3+4)", "14"),
            ("⑥ 55.1×198 = 10909.8", "10909.8"), ("V(11*4)", "6.633249581")]
        for (line, value) in cases { XCTAssertEqual(try LocalMath.solve(line), value, line) }
        // An item number beside the sum is never read as part of the first number.
        XCTAssertEqual(try LocalMath.solve("2 57 * 30"), "1710")
        XCTAssertThrowsError(try LocalMath.evaluate("2 57 * 30"))
        XCTAssertNil(LocalMath.expression("Name:")); XCTAssertNil(LocalMath.expression("Date : __————----"))
        XCTAssertEqual(try LocalMath.solve("Homework\nName:\n1) 2+3 =\n2) 10 ÷ 4 = ____"), "2+3 = 5\n10÷4 = 2.5")
        // Numbering that lost its space keeps counting down the sheet.
        XCTAssertEqual(try LocalMath.solve("1. 2+3\n2.18x151+56.1\n3. 4×5\n4.576+85"), "2+3 = 5\n18×151+56.1 = 2774.1\n4×5 = 20\n576+85 = 661")
        XCTAssertEqual(try LocalMath.solve("@ 55.1×198 = 10909.8"), "10909.8")
    }
    /// Recognition can return U+FFFE; the Office XML must stay readable.
    func testOfficeXMLDropsCharactersXMLForbids() throws {
        let escaped = OfficeExport.xml("a\u{FFFE}b\u{0B}c<&>")
        XCTAssertEqual(escaped, "abc&lt;&amp;&gt;")
        XCTAssertTrue(XMLParser(data: Data("<t>\(escaped)</t>".utf8)).parse())
    }
    func testMeshWorldGeometryAndValidation() throws {
        let text = try MeshExport.obj(vertices:[SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(0,1,0)],faces:[[0,1,2]],offset:4)
        XCTAssertTrue(text.contains("f 5 6 7"));XCTAssertThrowsError(try MeshExport.obj(vertices:[.zero],faces:[[0,1,2]]))
    }
    func testRestorationDimensionsAndInputValidation() throws {
        let image = fixture(),out = try OfflineImageEngine.restored(image,amount:0.7)
        XCTAssertEqual(out.size,image.size);XCTAssertThrowsError(try OfflineImageEngine.restored(image,amount:.infinity))
    }
    func testWordFileInputPreservesPDFTextAndRendersRotatedPages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("source.pdf"), copy = root.appendingPathComponent("copy.pdf")
        let data = UIGraphicsPDFRenderer(bounds:CGRect(x:0,y:0,width:300,height:400)).pdfData { context in
            for label in ["First page", "Second page"] {
                context.beginPage()
                (label as NSString).draw(at:CGPoint(x:30,y:30),withAttributes:[.font:UIFont.systemFont(ofSize:18)])
            }
        }
        let pdf = try XCTUnwrap(PDFDocument(data:data));pdf.page(at:1)?.rotation = 90
        XCTAssertTrue(pdf.write(to:source))
        let opened = try WordFileInput.open(source,pdfCopy:copy)
        XCTAssertEqual(opened.pdfPages,2)
        XCTAssertGreaterThan(opened.image.size.height,opened.image.size.width)
        let rotated = try WordFileInput.page(copy,index:1)
        XCTAssertGreaterThan(rotated.size.width,rotated.size.height)
        let text = try WordFileInput.text(copy,index:1) { _ in XCTFail("Native text should not need OCR");return "" }
        XCTAssertTrue(text.contains("Second page"))
        XCTAssertThrowsError(try WordFileInput.page(copy,index:9))
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.path))
    }
    func testWordFileInputImageAndScannedPDFFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("photo.png"), copy = root.appendingPathComponent("copy.pdf")
        try XCTUnwrap(fixture().pngData()).write(to:source)
        let opened = try WordFileInput.open(source,pdfCopy:copy)
        XCTAssertEqual(opened.pdfPages,0);XCTAssertEqual(opened.image.size,fixture().size)
        XCTAssertFalse(FileManager.default.fileExists(atPath:copy.path))
        let pdf = PDFDocument();pdf.insert(try XCTUnwrap(PDFPage(image:fixture())),at:0)
        let scanned = root.appendingPathComponent("scan.pdf");XCTAssertTrue(pdf.write(to:scanned))
        var didRecognize = false
        let text = try WordFileInput.text(scanned,index:0) { image in
            didRecognize = true;XCTAssertGreaterThan(image.size.width,0);return "Recognized text"
        }
        XCTAssertTrue(didRecognize);XCTAssertEqual(text,"Recognized text")
        try Data("invalid PDF".utf8).write(to:scanned)
        XCTAssertThrowsError(try WordFileInput.open(scanned,pdfCopy:copy))
        XCTAssertFalse(FileManager.default.fileExists(atPath:copy.path))
    }
}
