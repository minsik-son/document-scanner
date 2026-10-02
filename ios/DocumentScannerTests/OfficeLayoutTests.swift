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
}
