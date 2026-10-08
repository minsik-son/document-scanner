import UIKit

// Minimal standards-based OOXML packages. No macros, external links or executable formulas.
enum OfficeExport {
    static func xml(_ value: String) -> String {
        // Only characters XML allows: a stray U+FFFE from recognition would make
        // Word, Excel and PowerPoint refuse the whole file.
        String(String.UnicodeScalarView(value.unicodeScalars.filter { v in
            let c = v.value
            return c == 9 || c == 10 || c == 13 || (c >= 0x20 && c <= 0xD7FF) || (c >= 0xE000 && c <= 0xFFFD) || c >= 0x10000
        }))
            .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    static let relationshipNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let officeNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static func relationships(_ items: [(String,String,String)]) -> String {
        declaration + "<Relationships xmlns=\"\(relationshipNS)\">" + items.map { "<Relationship Id=\"\($0.0)\" Type=\"\(officeNS)/\($0.1)\" Target=\"\(xml($0.2))\"/>" }.joined() + "</Relationships>"
    }
    static func package(_ entries: [(String,Data)], main: String, types: [(String,String)]) throws -> Data {
        let content = declaration + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/>" + types.map { "<Override PartName=\"/\($0.0)\" ContentType=\"application/vnd.openxmlformats-officedocument.\($0.1)+xml\"/>" }.joined() + "</Types>"
        return try LocalZIP.encode(entries + [("[Content_Types].xml",Data(content.utf8)),("_rels/.rels",Data(relationships([("rId1","officeDocument",main)]).utf8))])
    }
    static func word(_ text: String) throws -> Data {
        guard text.utf8.count <= 4_000_000 else { throw ScannerError.message("Export at most 4 MB of text at a time.") }
        let paragraphs = text.components(separatedBy:"\u{000c}").enumerated().map { index,page in
            let pageBreak = index == 0 ? "" : "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            return pageBreak + page.components(separatedBy:"\n").map { "<w:p><w:r><w:t xml:space=\"preserve\">\(xml($0))</w:t></w:r></w:p>" }.joined()
        }.joined()
        let body = declaration + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(paragraphs)<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\"/></w:sectPr></w:body></w:document>"
        return try package([("word/document.xml",Data(body.utf8))], main:"word/document.xml", types:[("word/document.xml","wordprocessingml.document.main")])
    }
    static func column(_ index: Int) -> String {
        var n = index+1, output = ""
        while n > 0 { n -= 1; output = String(UnicodeScalar(65+n%26)!) + output; n /= 26 }; return output
    }
    static func excel(_ text: String) throws -> Data {
        guard text.utf8.count <= 4_000_000 else { throw ScannerError.message("Export at most 4 MB of text at a time.") }
        let rows = text.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        guard rows.count <= 10000, rows.allSatisfy({ $0.count <= 256 }) else { throw ScannerError.message("Use at most 10,000 rows and 256 columns.") }
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let cells = rows.enumerated().map { r, row in "<row r=\"\(r+1)\">" + row.enumerated().map { c, value in "<c r=\"\(column(c))\(r+1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>" }.joined() + "</row>" }.joined()
        let sheet = declaration + "<worksheet xmlns=\"\(ns)\"><sheetData>\(cells)</sheetData></worksheet>"
        let workbook = declaration + "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(officeNS)\"><sheets><sheet name=\"Extracted text\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
        return try package([("xl/workbook.xml",Data(workbook.utf8)),("xl/worksheets/sheet1.xml",Data(sheet.utf8)),("xl/_rels/workbook.xml.rels",Data(relationships([("rId1","worksheet","worksheets/sheet1.xml")]).utf8))],main:"xl/workbook.xml",types:[("xl/workbook.xml","spreadsheetml.sheet.main"),("xl/worksheets/sheet1.xml","spreadsheetml.worksheet")])
    }
    static func powerpoint(_ images: [UIImage], texts: [String], editable: Bool) throws -> Data {
        return try powerpoint(pageCount: images.count, texts: texts, editable: editable) { images[$0] }
    }
    static func powerpoint(pageCount: Int, texts: [String], editable: Bool, imageAt: (Int) throws -> UIImage) throws -> Data {
        guard pageCount > 0, pageCount <= 30 else { throw ScannerError.message("Choose 1–30 pages for a presentation.") }
        guard let themeURL = Bundle.main.url(forResource:"OfficeTheme",withExtension:"xml") else { throw ScannerError.message("The presentation theme is missing from the app.") }
        let theme = try Data(contentsOf:themeURL)
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main", a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        var entries: [(String,Data)] = [("ppt/theme/theme1.xml",theme)], types: [(String,String)] = [("ppt/theme/theme1.xml","theme")], rels: [(String,String,String)] = []
        var encodedBytes = 0
        for i in 0..<pageCount {
            try Task.checkCancellation()
            let n = i+1, path = "ppt/slides/slide\(n).xml"
            let shape: String
            if editable {
                let paragraphs = (texts.indices.contains(i) ? texts[i] : "").components(separatedBy:"\n").map { "<a:p><a:r><a:rPr lang=\"en-US\" sz=\"1600\"/><a:t>\(xml($0))</a:t></a:r><a:endParaRPr lang=\"en-US\"/></a:p>" }.joined()
                shape = "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Editable page text\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"400000\" y=\"300000\"/><a:ext cx=\"11392000\" cy=\"6258000\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=\"square\"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>"
            } else {
                let (data, size) = try autoreleasepool { () throws -> (Data, CGSize) in
                    let image = try imageAt(i)
                    guard let data = image.pngData() else { throw ScannerError.message("Could not encode the slide.") }
                    return (data, image.size)
                }
                encodedBytes += data.count
                guard encodedBytes < 170_000_000 else { throw ScannerError.message("The presentation is too large. Export fewer pages at a time.") }
                entries.append(("ppt/media/image\(n).png",data))
                let factor = min(12192000/size.width,6858000/size.height)
                let w = Int(size.width*factor), h = Int(size.height*factor)
                shape = "<p:pic><p:nvPicPr><p:cNvPr id=\"2\" name=\"Page \(n)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rId2\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\((12192000-w)/2)\" y=\"\((6858000-h)/2)\"/><a:ext cx=\"\(w)\" cy=\"\(h)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
            }
            entries.append((path,Data((declaration + "<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(officeNS)\"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>\(group)\(shape)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>").utf8)))
            var slideRels = [("rId1","slideLayout","../slideLayouts/slideLayout1.xml")]
            if !editable { slideRels.append(("rId2","image","../media/image\(n).png")) }
            entries.append(("ppt/slides/_rels/slide\(n).xml.rels",Data(relationships(slideRels).utf8)))
            types.append((path,"presentationml.slide")); rels.append(("rId\(n+1)","slide","slides/slide\(n).xml"))
        }
        let ids = (0..<pageCount).map { "<p:sldId id=\"\($0+256)\" r:id=\"rId\($0+2)\"/>" }.joined()
        let pres = declaration + "<p:presentation xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(officeNS)\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        let colorMap = "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        entries += [("ppt/presentation.xml",Data(pres.utf8)),("ppt/_rels/presentation.xml.rels",Data(relationships([("rId1","slideMaster","slideMasters/slideMaster1.xml")]+rels).utf8)),
            ("ppt/slideMasters/slideMaster1.xml",Data((declaration + "<p:sldMaster xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(officeNS)\"><p:cSld><p:spTree>\(group)</p:spTree></p:cSld>\(colorMap)<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>").utf8)),
            ("ppt/slideMasters/_rels/slideMaster1.xml.rels",Data(relationships([("rId1","slideLayout","../slideLayouts/slideLayout1.xml"),("rId2","theme","../theme/theme1.xml")]).utf8)),
            ("ppt/slideLayouts/slideLayout1.xml",Data((declaration + "<p:sldLayout xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(officeNS)\" type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>").utf8)),
            ("ppt/slideLayouts/_rels/slideLayout1.xml.rels",Data(relationships([("rId1","slideMaster","../slideMasters/slideMaster1.xml")]).utf8))]
        types += [("ppt/presentation.xml","presentationml.presentation.main"),("ppt/slideMasters/slideMaster1.xml","presentationml.slideMaster"),("ppt/slideLayouts/slideLayout1.xml","presentationml.slideLayout")]
        return try package(entries,main:"ppt/presentation.xml",types:types)
    }
    // Establish columns across the whole page so a missing cell does not shift
    // later values left. This is a text-table heuristic, not merged-cell recovery.
    static func tableText(_ blocks: [TextBlock]) -> String {
        let valid = blocks.filter { [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 }
        var rows: [[TextBlock]] = []
        for block in valid.sorted(by: { $0.y+$0.height/2 < $1.y+$1.height/2 }) {
            if let i = rows.firstIndex(where: { abs(($0[0].y+$0[0].height/2)-(block.y+block.height/2)) < max(0.008,min($0[0].height,block.height)*0.5) }) { rows[i].append(block) }
            else { rows.append([block]) }
        }
        var anchors: [Double] = []
        for block in valid.sorted(by: { $0.x < $1.x }) {
            if !anchors.contains(where: { abs($0-block.x) <= 0.025 }) { anchors.append(block.x) }
        }
        return rows.map { row in
            var cells = Array(repeating: "", count: anchors.count)
            for block in row.sorted(by: { $0.x < $1.x }) {
                guard let column = anchors.indices.min(by: { abs(anchors[$0]-block.x) < abs(anchors[$1]-block.x) }) else { continue }
                let value = block.text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                cells[column] += (cells[column].isEmpty ? "" : " ") + value
            }
            // Trailing blanks are implicit; leading/interior blanks are essential.
            while cells.last == "" { cells.removeLast() }
            return cells.joined(separator: "\t")
        }.joined(separator: "\n")
    }

}

enum LocalZIP {
    static func crc(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }; return ~crc
    }
    private static func checkedCRC(_ data: Data) throws -> UInt32 {
        var value = UInt32.max
        for (index, byte) in data.enumerated() {
            if index % 16384 == 0 { try Task.checkCancellation() }
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        }
        return ~value
    }
    static func encode(_ files: [(String,Data)]) throws -> Data {
        guard files.count < 65535, Set(files.map(\.0)).count == files.count,
              files.allSatisfy({ !$0.0.hasPrefix("/") && !$0.0.split(separator:"/").contains("..") && $0.0.utf8.count < 65535 }),
              files.reduce(0, { $0+$1.1.count }) < 180_000_000 else { throw ScannerError.message("The Office export is too large or invalid.") }
        var out = Data(), central = Data()
        func u16(_ x: UInt16) -> Data { var n = x.littleEndian; return withUnsafeBytes(of:&n) { Data($0) } }
        func u32(_ x: UInt32) -> Data { var n = x.littleEndian; return withUnsafeBytes(of:&n) { Data($0) } }
        for (name,data) in files {
            try Task.checkCancellation()
            let path = Data(name.utf8), check = try checkedCRC(data), offset = UInt32(out.count), size = UInt32(data.count)
            for part in [u32(0x04034b50),u16(20),u16(0x800),u16(0),u16(0),u16(33),u32(check),u32(size),u32(size),u16(UInt16(path.count)),u16(0),path,data] { out.append(part) }
            for part in [u32(0x02014b50),u16(20),u16(20),u16(0x800),u16(0),u16(0),u16(33),u32(check),u32(size),u32(size),u16(UInt16(path.count)),u16(0),u16(0),u16(0),u16(0),u32(0),u32(offset),path] { central.append(part) }
        }
        let offset = UInt32(out.count); out += central
        for part in [u32(0x06054b50),u16(0),u16(0),u16(UInt16(files.count)),u16(UInt16(files.count)),u32(UInt32(central.count)),u32(offset),u16(0)] { out.append(part) }
        return out
    }
}
