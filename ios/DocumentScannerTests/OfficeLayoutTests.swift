import XCTest
import UIKit
@testable import DocumentScanner

/// Rebuilds the sample scans as Word, Excel and PowerPoint files and checks
/// that structure and formatting survive. Files are also written to
/// Verification/office-layout for visual comparison.
final class OfficeLayoutTests: XCTestCase {
    private func tables(_ page: PageLayout) -> [LayoutTable] {
        page.items.compactMap { item -> LayoutTable? in if case .table(let t) = item { return t }; return nil }
    }
    private func image(_ name: String) throws -> UIImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "jpg"))
        return try XCTUnwrap(UIImage(contentsOfFile: url.path))
    }
    private var verification: URL? {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return nil }
        let folder = URL(fileURLWithPath: home).appendingPathComponent("Documents/ChatGPT/정치 중립/scanner-product/ios/Verification/office-layout")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func entries(_ data: Data) throws -> [String: String] {
        // Stored (uncompressed) ZIP written by LocalZIP.
        var result: [String: String] = [:]
        var offset = 0
        func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        while offset + 30 <= data.count, u32(offset) == 0x04034b50 {
            let size = u32(offset + 18), nameLength = u16(offset + 26), extra = u16(offset + 28)
            let name = String(decoding: data[(data.startIndex + offset + 30)..<(data.startIndex + offset + 30 + nameLength)], as: UTF8.self)
            let start = data.startIndex + offset + 30 + nameLength + extra
            result[name] = String(decoding: data[start..<(start + size)], as: UTF8.self)
            offset = offset + 30 + nameLength + extra + size
        }
        return result
    }
    private func export(_ page: PageLayout, name: String) throws -> (docx: [String: String], xlsx: [String: String], pptx: [String: String]) {
        let word = try OfficeLayoutExport.word([page], image: OfficeLayoutPages.missingPicture)
        let excel = try OfficeLayoutExport.excel([page], image: OfficeLayoutPages.missingPicture)
        let slides = try OfficeLayoutExport.powerpoint([page], theme: OfficeLayoutPages.theme(), image: OfficeLayoutPages.missingPicture)
        if let folder = verification {
            try word.write(to: folder.appendingPathComponent("\(name).docx"))
            try excel.write(to: folder.appendingPathComponent("\(name).xlsx"))
            try slides.write(to: folder.appendingPathComponent("\(name).pptx"))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var copy = page; for i in copy.graphics.indices { copy.graphics[i].png = nil }
            try encoder.encode(copy).write(to: folder.appendingPathComponent("\(name).layout.json"))
        }
        for data in [word, excel, slides] {
            for (part, xml) in try entries(data) where part.hasSuffix(".xml") || part.hasSuffix(".rels") {
                let parser = XMLParser(data: Data(xml.utf8))
                XCTAssertTrue(parser.parse(), "\(name) \(part) is not well-formed: \(parser.parserError?.localizedDescription ?? "")")
            }
        }
        return (try entries(word), try entries(excel), try entries(slides))
    }

    func testRuledColorTableKeepsMergesFillsAndBorders() throws {
        let page = try OfficeLayoutPages.analyze(image("OfficeSampleTable"))
        let tables = page.items.compactMap { if case .table(let t) = $0 { return t }; return nil }
        XCTAssertEqual(tables.count, 1)
        let table = try XCTUnwrap(tables.first)
        XCTAssertTrue(table.ruled)
        XCTAssertEqual(table.columnCount, 5)
        XCTAssertEqual(table.rowCount, 30)
        func cell(_ text: String) -> LayoutCell? { table.cells.first { $0.text.contains(text) } }
        let montreal = try XCTUnwrap(cell("Montreal"))
        XCTAssertEqual(montreal.rowSpan, 3); XCTAssertEqual(montreal.columnSpan, 2)
        XCTAssertEqual(cell("Toronto")?.rowSpan, 7)
        XCTAssertEqual(cell("Vanouver")?.rowSpan, 8)
        XCTAssertEqual(cell("Seattle")?.rowSpan, 7)
        // Colored bands: Utah yellow, Vancouver blue, Toronto pale yellow; plain rows stay white.
        let utah = try XCTUnwrap(cell("Utah")?.fill), van = try XCTUnwrap(cell("Vanouver")?.fill)
        XCTAssertGreaterThan(Int(utah.r), Int(utah.b) + 60)
        XCTAssertGreaterThan(Int(van.b), Int(van.r) + 60)
        XCTAssertNotNil(cell("Toronto")?.fill)
        XCTAssertNil(cell("Bellevue")?.fill)
        XCTAssertTrue(table.cells.allSatisfy { $0.top && $0.left && $0.bottom && $0.right })
        XCTAssertEqual(cell("Decarie")?.alignment, .right)
        // One body size for the whole table.
        XCTAssertEqual(Set(table.cells.filter { !$0.lines.isEmpty }.map(\.fontSize)).count, 1)
        let files = try export(page, name: "OfficeSampleTable")
        let document = try XCTUnwrap(files.docx["word/document.xml"])
        XCTAssertTrue(document.contains("<w:vMerge w:val=\"restart\"/>"))
        XCTAssertTrue(document.contains("<w:gridSpan w:val=\"2\"/>"))
        XCTAssertTrue(document.contains("w:fill=\"\(van.hex)\""))
        XCTAssertTrue(document.contains("데카리"))
        let sheet = try XCTUnwrap(files.xlsx["xl/worksheets/sheet1.xml"])
        XCTAssertTrue(sheet.contains("<mergeCell "))
        XCTAssertTrue(files.xlsx["xl/styles.xml"]?.contains("FF\(utah.hex)") == true)
        let slide = try XCTUnwrap(files.pptx["ppt/slides/slide1.xml"])
        XCTAssertTrue(slide.contains("rowSpan=\"8\""))
        XCTAssertTrue(slide.contains("vMerge=\"1\""))
    }

    /// Rereading cells on their own must not make recognition worse.
    func testCellRereadFixesCodes() throws {
        let expected = ["HDC","HSC","HSJ","HBL","HDD","HFC","HNY","HRH","HSS","MNY","GBV","HTG","GLW","HBE","HFW","HLW","HRD","HTM","HUW","GWM","HAR","HWJ","EUB","HCQ","HDB","HDN","HLL","HPC","HRM","HVT"]
        func correct(_ page: PageLayout) -> Int {
            let cells: [LayoutCell] = tables(page).first?.cells ?? []
            let codes = cells.filter { $0.column == 3 }.map(\.text)
            return zip(codes, expected).filter { $0 == $1 }.count
        }
        var log: [String] = []
        OfficeLayoutPages.refineLog = { log.append($0) }
        defer { OfficeLayoutPages.refineLog = nil; OfficeLayoutPages.refineCells = true }
        OfficeLayoutPages.refineCells = false
        let before = correct(try OfficeLayoutPages.analyze(image("OfficeSampleTable")))
        OfficeLayoutPages.refineCells = true
        let refined = try OfficeLayoutPages.analyze(image("OfficeSampleTable"))
        let after = correct(refined)
        let report = "codes correct before \(before) after \(after)\n" + log.joined(separator: "\n")
        print(report)
        if let folder = verification { try report.write(to: folder.appendingPathComponent("cell-reread.txt"), atomically: true, encoding: .utf8) }
        XCTAssertGreaterThanOrEqual(after, before, report)
        let all: [LayoutCell] = tables(refined).first?.cells ?? []
        XCTAssertTrue(all.contains { $0.text.contains("데카리") }, report)
    }

    func testPriceListKeepsHeadingsColumnsBulletsAndFooter() throws {
        let page = try OfficeLayoutPages.analyze(image("OfficeSamplePriceList"))
        let paragraphs = page.items.compactMap { if case .paragraph(let p) = $0 { return p }; return nil }
        let tables = page.items.compactMap { if case .table(let t) = $0 { return t }; return nil }
        let table = try XCTUnwrap(tables.first)
        XCTAssertFalse(table.ruled)
        XCTAssertEqual(table.columnCount, 4)
        XCTAssertEqual(table.rowCount, 8)
        XCTAssertTrue(table.cells.filter { $0.row == 0 }.allSatisfy { $0.lines.first?.first?.underline == true }, "Underlined column headings")
        XCTAssertEqual(table.cell(row: 2, column: 0)?.text, "", "Second One Bedroom plan row keeps an empty first column")
        let title = try XCTUnwrap(paragraphs.first { $0.lines.first?.text.contains("Prices at a Glance") == true })
        XCTAssertEqual(title.alignment, .center)
        XCTAssertTrue(title.lines[0].segments[0].runs.allSatisfy(\.bold))
        XCTAssertEqual(paragraphs.filter { $0.bullet != nil }.count, 6)
        let trust = try XCTUnwrap(paragraphs.first { $0.lines.first?.text.contains("Terra Law") == true })
        XCTAssertTrue(trust.lines[0].segments[0].runs.contains { $0.bold && $0.text.contains("Terra Law") })
        XCTAssertTrue(trust.lines[0].segments[0].runs.contains { !$0.bold && $0.text.contains("Certified") })
        let footnote = try XCTUnwrap(paragraphs.first { $0.lines.first?.text.hasPrefix("Prices do not include") == true })
        XCTAssertLessThan(footnote.fontSize, title.fontSize * 0.6)
        XCTAssertGreaterThanOrEqual(page.graphics.count, 2, "Logo rules are kept as pictures")
        let files = try export(page, name: "OfficeSamplePriceList")
        let document = try XCTUnwrap(files.docx["word/document.xml"])
        XCTAssertTrue(document.contains("<w:numPr>"))
        XCTAssertTrue(document.contains("<w:jc w:val=\"center\"/>"))
        XCTAssertTrue(document.contains("<w:u w:val=\"single\"/>"))
        XCTAssertTrue(document.contains("wp:anchor"))
        XCTAssertTrue(files.docx.keys.contains { $0.hasPrefix("word/media/") })
        XCTAssertTrue(files.pptx["ppt/slides/slide1.xml"]?.contains("<a:buChar char=\"•\"/>") == true)
        XCTAssertTrue(files.xlsx.keys.contains("xl/drawings/drawing1.xml"))
    }

    /// A plain camera photo of a page on a desk: flattened like a scan, then rebuilt.
    func testRawPhotoIsFlattenedAndRebuilt() throws {
        let photo = try image("OfficeSamplePhoto")
        let flat = try OfficeLayoutPages.flattenedIfPhoto(photo)
        let aspect = flat.size.height / flat.size.width
        XCTAssertEqual(aspect, 11 / 8.5, accuracy: 0.01, "Snapped to Letter")
        if let folder = verification {
            let cg = try XCTUnwrap(OfficeLayoutPages.prepare(flat).image)
            try UIImage(cgImage: cg).pngData()?.write(to: folder.appendingPathComponent("OfficeSamplePhoto.flat.png"))
            let reading = try OfficeLayoutPages.prepare(flat, maxSide: OfficeLayoutPages.readingSide).image
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(try TextRecognition.recognize(reading)).write(to: folder.appendingPathComponent("OfficeSamplePhoto.ocr.json"))
        }
        // Already-flat scans are left alone.
        let scan = try image("OfficeSamplePriceList")
        XCTAssertEqual(try OfficeLayoutPages.flattenedIfPhoto(scan).size, Imaging.normalized(scan).size)
        var log: [String] = []
        OfficeLayoutPages.refineLog = { log.append($0) }
        defer { OfficeLayoutPages.refineLog = nil }
        let page = try OfficeLayoutPages.analyze(photo)
        if let folder = verification { try log.joined(separator: "\n").write(to: folder.appendingPathComponent("photo-reread.txt"), atomically: true, encoding: .utf8) }
        let tables = tables(page)
        XCTAssertEqual(tables.first?.columnCount, 4)
        let paragraphs = page.items.compactMap { item -> LayoutParagraph? in if case .paragraph(let p) = item { return p }; return nil }
        XCTAssertGreaterThanOrEqual(paragraphs.filter { $0.bullet != nil }.count, 5)
        _ = try export(page, name: "OfficeSamplePhoto")
    }

    /// Personal forms kept outside the repository (Verification/private).
    private func privateSample(_ name: String) throws -> (UIImage, URL) {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { throw XCTSkip("Private samples are only on the developer Mac.") }
        let folder = URL(fileURLWithPath: home).appendingPathComponent("Documents/ChatGPT/정치 중립/scanner-product/ios/Verification/private")
        guard let image = UIImage(contentsOfFile: folder.appendingPathComponent(name).path) else { throw XCTSkip("\(name) is not available.") }
        return (image, folder)
    }

    /// A photographed government form: dozens of boxes side by side.
    func testFormPhotoKeepsBoxesInPlace() throws {
        let (photo, folder) = try privateSample("T4Form.jpg")
        let flat = try OfficeLayoutPages.flattenedIfPhoto(photo)
        let cg = try XCTUnwrap(OfficeLayoutPages.prepare(flat).image)
        try UIImage(cgImage: cg).pngData()?.write(to: folder.appendingPathComponent("T4Form.flat.png"))
        let reading = try OfficeLayoutPages.prepare(flat, maxSide: OfficeLayoutPages.readingSide).image
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(try TextRecognition.recognize(reading)).write(to: folder.appendingPathComponent("T4Form.ocr.json"))
        var log: [String] = []
        OfficeLayoutPages.refineLog = { log.append($0) }
        defer { OfficeLayoutPages.refineLog = nil }
        let page = try OfficeLayoutPages.analyze(photo)
        try log.joined(separator: "\n").write(to: folder.appendingPathComponent("T4Form-reread.txt"), atomically: true, encoding: .utf8)
        var copy = page; for i in copy.graphics.indices { copy.graphics[i].png = nil }
        try encoder.encode(copy).write(to: folder.appendingPathComponent("T4Form.layout.json"))
        try OfficeLayoutExport.word([page], image: OfficeLayoutPages.missingPicture).write(to: folder.appendingPathComponent("T4Form.docx"))
        try OfficeLayoutExport.excel([page], image: OfficeLayoutPages.missingPicture).write(to: folder.appendingPathComponent("T4Form.xlsx"))
        try OfficeLayoutExport.powerpoint([page], theme: OfficeLayoutPages.theme(), image: OfficeLayoutPages.missingPicture).write(to: folder.appendingPathComponent("T4Form.pptx"))
        try page.graphics.first?.png?.write(to: folder.appendingPathComponent("T4Form.art.png"))
        try LayoutText.text([page]).write(to: folder.appendingPathComponent("T4Form-kept.txt"), atomically: true, encoding: .utf8)
        // The boxes are one picture behind the page; text that was read
        // reliably sits on top of it, everything else stays as printed.
        XCTAssertTrue(page.form)
        XCTAssertTrue(page.positioned)
        XCTAssertEqual(page.graphics.count, 1)
        XCTAssertFalse(page.items.contains { if case .table = $0 { return true }; return false })
        XCTAssertGreaterThan(page.items.count, 30)
    }

    func testReviewedTextKeepsFormatting() throws {
        let page = try OfficeLayoutPages.analyze(image("OfficeSamplePriceList"))
        let text = LayoutText.text([page])
        XCTAssertEqual(LayoutText.apply(text, to: [page]), [page])
        let corrected = text.replacingOccurrences(of: "AT*", with: "A1*").replacingOccurrences(of: "El - E7", with: "E1 - E7")
        let edited = try XCTUnwrap(LayoutText.apply(corrected, to: [page])?.first)
        let table = try XCTUnwrap(edited.items.compactMap { if case .table(let t) = $0 { return t }; return nil }.first)
        XCTAssertTrue(table.cells.contains { $0.text == "A1*" })
        XCTAssertEqual(edited.items.count, page.items.count)
        XCTAssertTrue(LayoutText.related(corrected, text))
        XCTAssertFalse(LayoutText.related("Something new", text))
        XCTAssertNil(LayoutText.apply(text + "\u{000c}Second", to: [page]))
    }

    private func rotated(_ image: UIImage, degrees: CGFloat) -> UIImage {
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.98, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            context.cgContext.rotate(by: degrees * .pi / 180)
            image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
    }

    /// A crooked photo of the table still gives each label its own merged cell.
    /// A photographed notice: a shaded header table, a checklist and a footer.
    /// Dumps the intermediate data for offline tuning.
    func testNoticePhotoKeepsHeaderFillCheckboxesAndFooter() throws {
        let (photo, root) = try privateSample("Notice.jpg")
        let folder = root.appendingPathComponent("notice")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var flat = try OfficeLayoutPages.flattenedIfPhoto(photo)
        var prepared = try OfficeLayoutPages.prepare(flat)
        let skew = DocumentLayoutAnalyzer.skewAngle(prepared.raster)
        if abs(skew) >= 0.25 { flat = OfficeLayoutPages.straightened(flat, degrees: skew); prepared = try OfficeLayoutPages.prepare(flat) }
        try UIImage(cgImage: try XCTUnwrap(prepared.image)).pngData()?.write(to: folder.appendingPathComponent("flat.png"))
        let reading = try OfficeLayoutPages.prepare(flat, maxSide: OfficeLayoutPages.readingSide).image
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(try TextRecognition.recognize(reading)).write(to: folder.appendingPathComponent("ocr.json"))
        let page = try OfficeLayoutPages.analyze(photo)
        var copy = page; for i in copy.graphics.indices { copy.graphics[i].png = nil }
        try encoder.encode(copy).write(to: folder.appendingPathComponent("layout.json"))
        try OfficeLayoutExport.word([page], image: OfficeLayoutPages.missingPicture).write(to: folder.appendingPathComponent("Notice.docx"))
        try "skew \(skew) raster \(prepared.raster.width)x\(prepared.raster.height) page \(page.pageWidth)x\(page.pageHeight)".write(to: folder.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)
        // The shaded header row keeps its color in every cell.
        let table = try XCTUnwrap(tables(page).first)
        XCTAssertEqual(table.cells.filter { $0.row == 0 }.count, 3)
        XCTAssertTrue(table.cells.filter { $0.row == 0 }.allSatisfy { $0.fill != nil })
        // The last row's label is one cell across the first two columns.
        XCTAssertEqual(table.cells.first { $0.text.contains("별지") }?.columnSpan, 2)
        // Checkbox headings stay checkboxes; the page number is not a list item.
        let paragraphs = page.items.compactMap { item -> LayoutParagraph? in if case .paragraph(let p) = item { return p }; return nil }
        XCTAssertGreaterThanOrEqual(paragraphs.filter { $0.marker == "□" }.count, 4)
        XCTAssertTrue(paragraphs.allSatisfy { $0.marker != nil || $0.bullet == nil })
        for p in paragraphs where p.marker != nil {
            let first = p.lines.first?.segments.first?.text ?? ""
            XCTAssertFalse(first.hasPrefix("]") || first.hasPrefix("1 ") || first.hasPrefix("ㅁ"), "Misread box left in: \(first)")
        }
        XCTAssertFalse(paragraphs.contains { $0.lines.contains { $0.text.contains("1 별지") || $0.text.contains("1별지") } })
        let docx = try entries(try OfficeLayoutExport.word([page], image: OfficeLayoutPages.missingPicture))["word/document.xml"] ?? ""
        XCTAssertFalse(docx.contains("w:numId"), "Checkboxes are printed marks, not Word bullets")
    }

    func testCrookedTableKeepsEachMergedLabel() throws {
        let photo = rotated(try image("OfficeSampleTable"), degrees: 1.2)
        let raster = try OfficeLayoutPages.prepare(photo).raster
        XCTAssertEqual(DocumentLayoutAnalyzer.skewAngle(raster), 1.0, accuracy: 0.35)
        let page = try OfficeLayoutPages.analyze(photo)
        let table = try XCTUnwrap(tables(page).first)
        XCTAssertEqual(table.rowCount, 30)
        XCTAssertEqual(table.columnCount, 5)
        func cell(_ text: String) -> LayoutCell? { table.cells.first { $0.text.contains(text) } }
        XCTAssertEqual(cell("TOT")?.column, 0)
        XCTAssertEqual(cell("Toronto")?.column, 1)
        XCTAssertEqual(cell("TOT")?.rowSpan, 7)
        XCTAssertEqual(cell("USA1")?.rowSpan, 2)
        XCTAssertEqual(cell("USA2")?.rowSpan, 7)
        XCTAssertEqual(cell("Toronto")?.rowSpan, 7)
        XCTAssertFalse(cell("TOT")?.text.contains("USA") ?? true, "Labels in neighbouring merged cells stay apart")
        if let folder = verification {
            try? LayoutText.text([page]).write(to: folder.appendingPathComponent("CrookedTable.txt"), atomically: true, encoding: .utf8)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var copy = page; for i in copy.graphics.indices { copy.graphics[i].png = nil }
            try? encoder.encode(copy).write(to: folder.appendingPathComponent("CrookedTable.layout.json"))
        }
    }

    func testRecognitionSlipsAreTidied() {
        XCTAssertEqual(DocumentLayoutAnalyzer.joinedDottedNumbers("10.41.22. xx"), "10.41.22.xx")
        XCTAssertEqual(DocumentLayoutAnalyzer.joinedDottedNumbers("192.168 .10.xx"), "192.168.10.xx")
        XCTAssertEqual(DocumentLayoutAnalyzer.joinedDottedNumbers("It was 3.5. 4 people came"), "It was 3.5. 4 people came")
        XCTAssertEqual(DocumentLayoutAnalyzer.joinedDottedNumbers("See section 2. Then"), "See section 2. Then")
        func cell(_ row: Int, _ text: String) -> LayoutCell {
            var c = LayoutCell(row: row, column: 0, box: LBox(0, Double(row), 1, Double(row + 1))); c.lines = [[LayoutRun(text: text)]]; return c
        }
        var names = LayoutTable(columns: [0, 1], rows: [0, 1, 2, 3, 4],
                                cells: [cell(0, "Finch(핀치)"), cell(1, "Tigard(타이거드"), cell(2, "Steeles(스틸스)"), cell(3, "Lynwood Gmart")], ruled: true)
        DocumentLayoutAnalyzer.tidyRecognizedText(&names)
        XCTAssertEqual(names.cells.map(\.text), ["Finch(핀치)", "Tigard(타이거드)", "Steeles(스틸스)", "Lynwood Gmart"])
        var prose = LayoutTable(columns: [0, 1], rows: [0, 1, 2], cells: [cell(0, "Total (see note"), cell(1, "Other")], ruled: true)
        DocumentLayoutAnalyzer.tidyRecognizedText(&prose)
        XCTAssertEqual(prose.cells[0].text, "Total (see note", "A single open bracket is not guessed")
    }
}
