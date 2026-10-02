import XCTest
import UIKit
import PDFKit
import Translation
@testable import DocumentScanner

final class PhotoTranslationTests: XCTestCase {
    private func fixture() -> (UIImage,[TranslationRegion]) {
        let format = UIGraphicsImageRendererFormat();format.scale = 1;format.opaque = true
        let image = UIGraphicsImageRenderer(size:CGSize(width:1000,height:700),format:format).image { c in
            UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:1000,height:700))
            UIColor(red:0.82,green:0.92,blue:1,alpha:1).setFill();c.fill(CGRect(x:40,y:240,width:920,height:150))
            UIColor.black.setStroke();let rules = UIBezierPath()
            for y in [240,390] { rules.move(to:CGPoint(x:40,y:y));rules.addLine(to:CGPoint(x:960,y:y)) }
            for x in [40,500,960] { rules.move(to:CGPoint(x:x,y:240));rules.addLine(to:CGPoint(x:x,y:390)) };rules.lineWidth = 3;rules.stroke()
            ("Document title" as NSString).draw(at:CGPoint(x:100,y:95),withAttributes:[.font:UIFont.systemFont(ofSize:36),.foregroundColor:UIColor.black])
            ("Hello" as NSString).draw(at:CGPoint(x:90,y:285),withAttributes:[.font:UIFont.systemFont(ofSize:30),.foregroundColor:UIColor.black])
            ("World" as NSString).draw(at:CGPoint(x:550,y:285),withAttributes:[.font:UIFont.systemFont(ofSize:30),.foregroundColor:UIColor.black])
            UIColor.orange.setFill();c.fill(CGRect(x:650,y:480,width:230,height:140))
            UIColor.blue.setFill();c.fill(CGRect(x:670,y:500,width:80,height:80))
        }
        return (image,[
            TranslationRegion(id:0,source:"Document title",target:"문서 제목",box:CGRect(x:0.1,y:95.0/700,width:0.27,height:45.0/700)),
            TranslationRegion(id:1,source:"Hello",target:"안녕하세요",box:CGRect(x:0.09,y:285.0/700,width:0.16,height:38.0/700)),
            TranslationRegion(id:2,source:"World",target:"세계",box:CGRect(x:0.55,y:285.0/700,width:0.15,height:38.0/700))])
    }
    func testReplacesTextKeepsTablePhotoAndSelectableTranslatedPDF() throws {
        let (source,regions) = fixture()
        let result = try PhotoTranslation.compose(source,regions:regions)
        XCTAssertEqual(result.replaced,3,"Issues: \(result.issues)");XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.image.size,source.size)
        for rect in [CGRect(x:0,y:0,width:1000,height:60),CGRect(x:650,y:480,width:230,height:140),CGRect(x:498,y:240,width:5,height:150),CGRect(x:40,y:388,width:920,height:4)] {
            XCTAssertEqual(try bytes(source,rect),try bytes(result.image,rect),"Non-text content must be preserved at \(rect)")
        }
        XCTAssertNotEqual(try bytes(source,CGRect(x:90,y:90,width:300,height:60)),try bytes(result.image,CGRect(x:90,y:90,width:300,height:60)))
        let data = try OfflineImageEngine.pdf([result.image],text:[result.text])
        let pdf = try XCTUnwrap(PDFDocument(data:data));let text = pdf.string ?? ""
        XCTAssertTrue(text.contains("문서 제목"),text);XCTAssertTrue(text.contains("안녕하세요"),text)
        XCTAssertFalse(text.contains("Document title"));XCTAssertFalse(text.contains("Hello"))
        let sourceShot = XCTAttachment(image:source);sourceShot.name = "translation-original-layout";sourceShot.lifetime = .keepAlways;add(sourceShot)
        let outputShot = XCTAttachment(image:result.image);outputShot.name = "translation-reconstructed-layout";outputShot.lifetime = .keepAlways;add(outputShot)
    }
    func testLongAndOverlappingRegionsKeepOriginalInsteadOfDamagingPage() throws {
        let (source,original) = fixture();var regions = original
        regions[0].target = String(repeating:"A very long translation ",count:100)
        regions[1].keepOriginal = true;regions[2].keepOriginal = true
        let result = try PhotoTranslation.compose(source,regions:regions)
        XCTAssertEqual(result.replaced,0);XCTAssertNotNil(result.issues[0])
        XCTAssertEqual(try bytes(source,CGRect(origin:.zero,size:source.size)),try bytes(result.image,CGRect(origin:.zero,size:source.size)))
        var overlap = original;overlap[1].box = overlap[0].box
        let overlapping = try PhotoTranslation.compose(source,regions:overlap)
        XCTAssertNotNil(overlapping.issues[0]);XCTAssertNotNil(overlapping.issues[1])
    }
    func testRepeatCompositionUsesSourceAndPreservesCoordinates() throws {
        let (source,regions) = fixture();var next = regions;next[0].target = "새 제목"
        let first = try PhotoTranslation.compose(source,regions:regions)
        let second = try PhotoTranslation.compose(source,regions:next)
        XCTAssertFalse(second.text.map(\.text).joined().contains("문서 제목"))
        XCTAssertTrue(second.text.map(\.text).joined().contains("새 제목"))
        XCTAssertEqual(first.replaced,second.replaced)
        for block in second.text { XCTAssertGreaterThanOrEqual(block.x,0);XCTAssertGreaterThanOrEqual(block.y,0);XCTAssertLessThanOrEqual(block.x+block.width,1);XCTAssertLessThanOrEqual(block.y+block.height,1) }
    }
    func testScanRunsDocumentEnhancementThenOCR() throws {
        let (source,_) = fixture();let scan = try PhotoTranslation.scan(source,crop:.full)
        XCTAssertFalse(scan.regions.isEmpty)
        XCTAssertTrue(scan.regions.contains { $0.source.contains("Hello") })
        XCTAssertEqual(scan.original.size,source.size)
    }
    func testParagraphGroupingDoesNotJoinColumnsButtonsOrCrossRules() throws {
        let f = UIGraphicsImageRendererFormat();f.scale = 1
        let page = UIGraphicsImageRenderer(size:CGSize(width:1000,height:700),format:f).image { c in
            UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:1000,height:700))
            UIColor.black.setFill();c.fill(CGRect(x:50,y:310,width:380,height:3))
        }
        let blocks = [
            TextBlock(text:"Back up your current environment",x:0.05,y:0.10,width:0.38,height:0.04),
            TextBlock(text:"to external storage before recovery.",x:0.05,y:0.15,width:0.38,height:0.04),
            TextBlock(text:"Another column",x:0.6,y:0.10,width:0.3,height:0.04),
            TextBlock(text:"A separate cell above the rule",x:0.05,y:0.40,width:0.38,height:0.04),
            TextBlock(text:"A separate cell below the rule",x:0.05,y:0.45,width:0.38,height:0.04),
            TextBlock(text:"OK",x:0.6,y:0.3,width:0.04,height:0.04),
            TextBlock(text:"Cancel",x:0.6,y:0.35,width:0.08,height:0.04)]
        let groups = TranslationParagraphs.group(blocks,raster:try TranslationRaster(XCTUnwrap(page.cgImage)))
        XCTAssertEqual(groups.count,6)
        let paragraph = try XCTUnwrap(groups.first { $0.source.hasPrefix("Back up") })
        XCTAssertEqual(paragraph.sourceBoxes.count,2)
        XCTAssertTrue(paragraph.source.contains("to external storage"))
    }
    func testTightLinesAndShadedPaperCanBeReplacedWithoutErasingRule() throws {
        let f = UIGraphicsImageRendererFormat();f.scale = 1
        let page = UIGraphicsImageRenderer(size:CGSize(width:800,height:400),format:f).image { c in
            for y in 0..<400 {
                UIColor(white:0.78+CGFloat(y)*0.0005,alpha:1).setFill();c.fill(CGRect(x:0,y:y,width:800,height:1))
            }
            ("Back up your data" as NSString).draw(at:CGPoint(x:60,y:70),withAttributes:[.font:UIFont.systemFont(ofSize:28),.foregroundColor:UIColor.black])
            ("before recovery" as NSString).draw(at:CGPoint(x:60,y:108),withAttributes:[.font:UIFont.systemFont(ofSize:28),.foregroundColor:UIColor.black])
            UIColor.black.setFill();c.fill(CGRect(x:45,y:145,width:540,height:2))
        }
        let regions = [TranslationRegion(id:0,source:"Back up your data before recovery",target:"복원을 시작하기 전에 데이터를 외부 저장 장치에 백업해 주세요.",box:CGRect(x:60.0/800,y:70.0/400,width:250.0/800,height:74.0/400),sourceBoxes:[CGRect(x:60.0/800,y:70.0/400,width:250.0/800,height:34.0/400),CGRect(x:60.0/800,y:108.0/400,width:220.0/800,height:34.0/400)])]
        let result = try PhotoTranslation.compose(page,regions:regions)
        XCTAssertEqual(result.replaced,1,"\(result.issues)")
        XCTAssertEqual(try bytes(page,CGRect(x:45,y:145,width:540,height:2)),try bytes(result.image,CGRect(x:45,y:145,width:540,height:2)))
        let shot = XCTAttachment(image:result.image);shot.name = "translation-shadow-tight-paragraph";shot.lifetime = .keepAlways;add(shot)
    }
    func testFailureCategoriesAndAvailableTranslationsRemainSeparate() throws {
        let (source,base) = fixture();var regions = base
        regions[0].target = ""
        regions[1].target = String(repeating:"Very long translation ",count:400)
        regions[2].keepOriginal = true
        let result = try PhotoTranslation.compose(source,regions:regions)
        XCTAssertEqual(result.reasons[0],.missing);XCTAssertEqual(result.reasons[1],.space)
        XCTAssertEqual(result.kept,1);XCTAssertEqual(result.replaced,0)
        XCTAssertFalse(regions[1].target.isEmpty,"A layout failure must not discard the translation")
    }
    func testUserManualBodyReflowWithSuppliedTranslations() throws {
        let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"TranslationManualScreenshot",withExtension:"png"))
        let screenshot = try XCTUnwrap(UIImage(contentsOfFile:url.path)?.cgImage)
        // The supplied screenshot already contains a partly translated page. This tests reconstruction,
        // not the live Apple translation model or quality against the unavailable original photo.
        let page = UIImage(cgImage:try XCTUnwrap(screenshot.cropping(to:CGRect(x:165,y:412,width:958,height:1414))))
        let blocks = try TextRecognition.recognize(XCTUnwrap(page.cgImage))
        var regions = TranslationParagraphs.group(blocks,raster:try TranslationRaster(XCTUnwrap(page.cgImage)))
        var selected = Set<Int>()
        for i in regions.indices {
            let value = regions[i].source.lowercased()
            let target:String?
            if value.contains("back up your current") { target = "현재 Windows 사용자 환경을 USB 메모리 같은 외부 저장 장치에 백업하세요." + (value.contains("it is much easier") ? " 데이터가 백업된 위치를 알면 더 쉽게 이용할 수 있습니다." : "") }
            else if value.contains("you can still recover") { target = "운영체제로 부팅할 수 없는 경우에도 빠르게 복구할 수 있습니다." }
            else if value.contains("when you recover") { target = value.contains("please save") ? "하드 디스크를 복구하면 모든 데이터가 삭제됩니다. 중요한 데이터는 복구 전에 외부 저장 장치에 보관하세요." : "하드 디스크를 복구하면 시스템의 모든 데이터가 삭제됩니다." }
            else if value.contains("please save all") { target = "복구를 시작하기 전에 중요한 데이터를 외부 저장 장치에 보관하세요." }
            else if value.contains("turn on the system") { target = "컴퓨터를 켜고 화면의 안내를 따르세요." + (value.contains("press") ? " PC 부팅 과정에서 2~4초 동안 F11 to WinClon 메시지가 나타나면 F11 키를 누르세요." : "") }
            else if value.contains("keyboard and mouse") { target = "키보드와 마우스를 연결해야 합니다." }
            else { target = nil }
            if let target { regions[i].target = target;selected.insert(regions[i].id) }
            else { regions[i].keepOriginal = true }
        }
        XCTAssertGreaterThanOrEqual(selected.count,4,"Recognized: \(regions.map(\.source))")
        let result = try PhotoTranslation.compose(page,regions:regions)
        let failures = result.issues.filter { selected.contains($0.key) }
        for r in regions where failures[r.id] != nil {
            print("LAYOUT \(r.id) \(r.box) height \(r.sourceBoxes)")
            for other in regions where r.id != other.id && other.box.intersects(r.box) {
                print("OVERLAP \(other.id) \(other.box) \(other.source)")
            }
        }
        XCTAssertTrue(failures.isEmpty,"Body paragraphs must fit: \(failures)")
        XCTAssertEqual(result.replaced,selected.count)
        for (name,image) in [("translation-user-manual-input",page),("translation-user-manual-reflow",result.image)] {
            let shot = XCTAttachment(image:image);shot.name = name;shot.lifetime = .keepAlways;add(shot)
        }
        let report = XCTAttachment(string:regions.map { "\($0.id): \($0.source) → \($0.target) | \(result.issues[$0.id] ?? "OK")" }.joined(separator:"\n"))
        report.name = "translation-user-manual-regions";report.lifetime = .keepAlways;add(report)
    }
    func testWordGeometrySeparatesDistantScreenshotLabel() throws {
        let (image,_) = fixture(),raster = try TranslationRaster(XCTUnwrap(image.cgImage))
        let block = TextBlock(text:"Press <F11> now. 09:30",x:0.1,y:0.1,width:0.8,height:0.04,words:[
            TextWord(text:"Press",x:0.1,y:0.1,width:0.06,height:0.04),
            TextWord(text:"<F11>",x:0.17,y:0.1,width:0.06,height:0.04),
            TextWord(text:"now.",x:0.24,y:0.1,width:0.05,height:0.04),
            TextWord(text:"09:30",x:0.82,y:0.11,width:0.08,height:0.02)])
        let split = TranslationParagraphs.splitColumns(block,raster:raster)
        XCTAssertEqual(split.map(\.text),["Press <F11> now.","09:30"])
        XCTAssertLessThan(split[0].x+split[0].width,0.3)
        var normal = block;normal.words?.removeLast();normal.text = "Press <F11> now."
        XCTAssertEqual(TranslationParagraphs.splitColumns(normal,raster:raster).count,1)
    }
    func testFontSizeTracksInkInsteadOfOversizedOCRBox() throws {
        let f = UIGraphicsImageRendererFormat();f.scale = 1;f.opaque = true
        let image = UIGraphicsImageRenderer(size:CGSize(width:700,height:350),format:f).image { c in
            UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:700,height:350))
            for y in [60,200] { ("Backup your files" as NSString).draw(at:CGPoint(x:70,y:y),withAttributes:[.font:UIFont.systemFont(ofSize:24),.foregroundColor:UIColor.black]) }
        }
        let result = try PhotoTranslation.compose(image,regions:[
            TranslationRegion(id:0,source:"Backup your files",target:"파일 백업",box:CGRect(x:0.1,y:60.0/350,width:0.5,height:30.0/350)),
            TranslationRegion(id:1,source:"Backup your files",target:"파일 백업",box:CGRect(x:0.1,y:190.0/350,width:0.5,height:60.0/350))])
        XCTAssertEqual(result.replaced,2)
        let heights = result.text.filter { $0.text.contains("파일") }.map(\.height)
        XCTAssertEqual(heights.count,2)
        if heights.count == 2 { XCTAssertEqual(heights[0],heights[1],accuracy:0.008,"An oversized OCR box must not double the translated font size") }
    }
    func testSelectedLanguageOCRPreservesKoreanAndEnglishWithoutUnrelatedScripts() throws {
        let f = UIGraphicsImageRendererFormat();f.scale = 1
        let image = UIGraphicsImageRenderer(size:CGSize(width:900,height:350),format:f).image { c in
            UIColor.white.setFill();c.fill(CGRect(x:0,y:0,width:900,height:350))
            ("Back up your files before recovery." as NSString).draw(at:CGPoint(x:50,y:60),withAttributes:[.font:UIFont.systemFont(ofSize:30),.foregroundColor:UIColor.black])
            ("복구 전에 파일을 백업하세요." as NSString).draw(at:CGPoint(x:50,y:150),withAttributes:[.font:UIFont.systemFont(ofSize:30),.foregroundColor:UIColor.black])
        }
        let blocks = try PhotoTranslationRecognition.recognize(XCTUnwrap(image.cgImage),language:"en",secondaryLanguage:"ko")
        let text = blocks.map(\.text).joined(separator:" ")
        XCTAssertTrue(text.contains("Back up"),text);XCTAssertTrue(text.contains("백업"),text)
        XCTAssertFalse(text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) || (0x0E00...0x0E7F).contains($0.value) },text)
    }
    @MainActor
    func testInstalledTranslationModelWhenAvailable() async throws {
        guard #available(iOS 26.0,*) else { throw XCTSkip("Installed-language translation requires iOS 26.") }
        let a = Locale.Language(identifier:"en"),b = Locale.Language(identifier:"ko")
        let status = await LanguageAvailability().status(from:a,to:b)
        guard status == .installed else { throw XCTSkip("English/Korean translation assets are not installed in this simulator. No download requested.") }
        let session = TranslationSession(installedSource:a,target:b)
        let source = "It is much easier to operate if you know where the data is backed up. Keyboard and mouse must be connected."
        let response = try await session.translate(source)
        XCTAssertNotEqual(response.targetText,source)
        XCTAssertTrue(response.targetText.unicodeScalars.contains { (0xAC00...0xD7FF).contains($0.value) })
        let report = XCTAttachment(string:source+"\n"+response.targetText);report.name = "installed-model-translation";report.lifetime = .keepAlways;add(report)
    }
    func testLatestUserPDFBodyReconstruction() throws {
        let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"TranslationManualLatest",withExtension:"png"))
        let image = try XCTUnwrap(UIImage(contentsOfFile:url.path))
        // Already-translated user PDF: tests remaining body reconstruction and selected-language OCR,
        // not automatic translation quality or recovery of the unavailable original scan.
        let blocks = try PhotoTranslationRecognition.recognize(XCTUnwrap(image.cgImage),language:"en",secondaryLanguage:"ko")
        var regions = TranslationParagraphs.group(blocks,raster:try TranslationRaster(XCTUnwrap(image.cgImage)))
        var selected = Set<Int>()
        for i in regions.indices {
            let value = regions[i].source.lowercased()
            var target:String? = nil
            if value.contains("it is much easier") { target = "데이터가 백업된 위치를 알면 더 쉽게 이용할 수 있습니다." }
            else if value.hasPrefix("keyboard and mouse") { target = "키보드와 마우스를 연결해야 합니다." }
            else if value.contains("you can still recover") { target = "운영체제로 부팅할 수 없어도 빠르게 복구할 수 있습니다." + (value.contains("keyboard") ? " 키보드와 마우스를 연결해야 합니다." : "") }
            else if value.contains("when you recover") { target = "하드 디스크를 복구하면 시스템의 모든 데이터가 삭제됩니다." + (value.contains("please save") ? " 복구 전에 중요한 데이터를 외부 저장 장치에 보관하세요." : "") }
            else if value.contains("please save") { target = "복구 전에 중요한 데이터를 외부 저장 장치에 보관하세요." }
            else if value.contains("turn on the system") { target = "컴퓨터를 켜고 화면의 안내를 따르세요." + (value.contains("press") ? " PC 부팅 과정에서 2~4초 동안 F11 to WinClon 메시지가 나타나면 F11 키를 누르세요." : "") }
            else if value.contains("press") && value.contains("f11") { target = "PC 부팅 과정에서 2~4초 동안 F11 to WinClon 메시지가 나타나면 F11 키를 누르세요." }
            else if value.hasPrefix("appears on the screen") { target = "메시지는 PC 부팅 과정에서 2~4초 동안 나타납니다." }
            else if value.contains("when winclon") { target = "WinClon이 화면에 나타나면 F2 또는 F3 키를 누르거나 마우스로 복원할 상태를 선택하세요." }
            if let target { regions[i].target = target;selected.insert(regions[i].id) }
            else { regions[i].keepOriginal = true }
        }
        let result = try PhotoTranslation.compose(image,regions:regions)
        let report = regions.map { "\($0.id) \($0.box) lines=\($0.sourceBoxes.count): \($0.source) → \($0.target) | \(result.reasons[$0.id]?.rawValue ?? "OK")" }.joined(separator:"\n")
        print(report)
        let log = XCTAttachment(string:report);log.name = "latest-pdf-body-report";log.lifetime = .keepAlways;add(log)
        let shot = XCTAttachment(image:result.image);shot.name = "latest-pdf-body-output";shot.lifetime = .keepAlways;add(shot)
        XCTAssertTrue(regions.contains { $0.source.contains("Windows의 최신 백업") },"Mixed Korean/English source text must not be replaced by Latin gibberish")
        XCTAssertGreaterThanOrEqual(selected.count,6)
        XCTAssertTrue(result.issues.filter { selected.contains($0.key) }.isEmpty,report)
    }
    private func bytes(_ image:UIImage,_ rect:CGRect) throws -> Data {
        let cg = try XCTUnwrap(image.cgImage?.cropping(to:rect));let color = CGColorSpace(name:CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating:0,count:cg.width*cg.height*4)
        bytes.withUnsafeMutableBytes { pointer in
            let ctx = CGContext(data:pointer.baseAddress,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,space:color,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
        }
        return Data(bytes)
    }
}
