import Foundation

/// Writes reconstructed page layouts as editable Word, Excel and PowerPoint
/// files: real tables with merged cells, fills and borders; paragraphs with
/// size, weight, alignment, bullets and spacing; artwork as pictures placed
/// where it was on the page.
enum OfficeLayoutExport {
    /// Returns PNG data for a page region. `cutout` asks for ink only on a
    /// transparent background.
    typealias ImageProvider = (_ page: Int, _ box: LBox, _ cutout: Bool) throws -> Data

    static let latinFont = "Arial"
    static let eastAsianFont = "Malgun Gothic"
    static func hasWide(_ s: String) -> Bool { s.contains { DocumentLayoutAnalyzer.isWide($0) } }
    static func x(_ s: String) -> String { OfficeExport.xml(s) }
    static func i(_ v: Double) -> Int { Int(v.rounded()) }

    // MARK: - Word
    static func word(_ pages: [PageLayout], image: ImageProvider) throws -> Data {
        guard let first = pages.first else { throw ScannerError.message("Choose at least one page.") }
        let tw = first.pointsPerPixel * 20 // twips per pixel
        // One section for the whole file; margins fit every page's content.
        let content = pages.map(\.contentBox)
        let left = max(180, i((content.map(\.x0).min() ?? 0) * tw) - 20)
        let right = max(180, i((Double(first.width) - (content.map(\.x1).max() ?? Double(first.width))) * tw) - 20)
        let top = max(180, i((content.map(\.y0).min() ?? 0) * tw) - 60)
        let pageW = i(first.pageWidth * 20), pageH = i(first.pageHeight * 20)
        let areaLeft = Double(left) / tw, areaRight = Double(pageW - right) / tw
        var body = ""
        var media: [(String, Data)] = []
        var rels: [(String, String, String)] = [("rId1", "styles", "styles.xml"), ("rId2", "numbering", "numbering.xml")]
        var drawingID = 1
        for (pageIndex, page) in pages.enumerated() {
            let scale = page.pointsPerPixel * 20
            // Anchor paragraph: holds the page's pictures and starts the page.
            var anchors = ""
            for g in page.graphics {
                let data = try g.png ?? image(pageIndex, g.box, g.cutout)
                let name = "image\(media.count + 1).png", rid = "rId\(rels.count + 1)"
                media.append(("word/media/\(name)", data)); rels.append((rid, "image", "media/\(name)"))
                anchors += wordAnchor(g.box, emu: page.pointsPerPixel * 12700, rid: rid, id: drawingID); drawingID += 1
            }
            let breakBefore = pageIndex > 0 ? "<w:pageBreakBefore/>" : ""
            body += "<w:p><w:pPr>\(breakBefore)<w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/><w:rPr><w:sz w:val=\"2\"/></w:rPr></w:pPr>\(anchors)</w:p>"
            var cursor = Double(top) / scale + 1 / scale * 20 // pixels already used on the page
            for item in page.items {
                switch item {
                case .paragraph(let p):
                    let lineH = max(p.linePitch, p.fontSize / page.pointsPerPixel * 1.18)
                    let lineTop = p.lines[0].box.midY - lineH / 2
                    let before = max(0, lineTop - cursor)
                    body += wordParagraph(p, before: before * scale, lineHeight: lineH * scale, areaLeft: areaLeft, areaRight: areaRight, scale: scale)
                    cursor = lineTop + lineH * Double(p.lines.count)
                case .table(let t):
                    let gap = t.box.y0 - cursor
                    if gap > 1 { body += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"\(max(20, i(gap * scale)))\" w:lineRule=\"exact\"/><w:rPr><w:sz w:val=\"2\"/></w:rPr></w:pPr></w:p>" }
                    body += wordTable(t, areaLeft: areaLeft, scale: scale, pointsPerPixel: page.pointsPerPixel)
                    cursor = max(cursor, t.box.y0) + t.box.height
                }
            }
        }
        // A document must end with a paragraph (tables cannot be last).
        body += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/><w:rPr><w:sz w:val=\"2\"/></w:rPr></w:pPr></w:p>"
        let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"\(OfficeExport.officeNS)\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""
        let document = OfficeExport.declaration + "<w:document \(ns)><w:body>\(body)<w:sectPr><w:pgSz w:w=\"\(pageW)\" w:h=\"\(pageH)\"\(first.pageWidth > first.pageHeight ? " w:orient=\"landscape\"" : "")/><w:pgMar w:top=\"\(top)\" w:right=\"\(right)\" w:bottom=\"360\" w:left=\"\(left)\" w:header=\"0\" w:footer=\"0\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
        let fonts = "<w:rFonts w:ascii=\"\(latinFont)\" w:hAnsi=\"\(latinFont)\" w:eastAsia=\"\(eastAsianFont)\" w:cs=\"\(latinFont)\"/>"
        let styles = OfficeExport.declaration + "<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:docDefaults><w:rPrDefault><w:rPr>\(fonts)<w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/><w:lang w:val=\"en-US\" w:eastAsia=\"ko-KR\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style><w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"57\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"57\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style></w:styles>"
        let numbering = OfficeExport.declaration + "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"singleLevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"•\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"\(latinFont)\" w:hAnsi=\"\(latinFont)\"/></w:rPr></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num></w:numbering>"
        var entries: [(String, Data)] = [("word/document.xml", Data(document.utf8)), ("word/styles.xml", Data(styles.utf8)), ("word/numbering.xml", Data(numbering.utf8)),
                                         ("word/_rels/document.xml.rels", Data(OfficeExport.relationships(rels).utf8))]
        entries += media
        return try OfficeExport.package(entries, main: "word/document.xml", types: [("word/document.xml", "wordprocessingml.document.main"), ("word/styles.xml", "wordprocessingml.styles"), ("word/numbering.xml", "wordprocessingml.numbering")])
    }

    static func wordRun(_ run: LayoutRun, size: Double, spacing: Double = 0) -> String {
        var props = "<w:rFonts w:ascii=\"\(latinFont)\" w:hAnsi=\"\(latinFont)\" w:eastAsia=\"\(eastAsianFont)\" w:cs=\"\(latinFont)\"/>"
        if run.bold { props += "<w:b/><w:bCs/>" }
        if let c = run.color { props += "<w:color w:val=\"\(c.hex)\"/>" }
        if abs(spacing) >= 0.05 { props += "<w:spacing w:val=\"\(i(spacing * 20))\"/>" }
        let half = i(size * 2)
        props += "<w:sz w:val=\"\(half)\"/><w:szCs w:val=\"\(half)\"/>"
        if run.underline { props += "<w:u w:val=\"single\"/>" }
        return "<w:r><w:rPr>\(props)</w:rPr><w:t xml:space=\"preserve\">\(x(run.text))</w:t></w:r>"
    }

    static func wordParagraph(_ p: LayoutParagraph, before: Double, lineHeight: Double, areaLeft: Double, areaRight: Double, scale: Double) -> String {
        var ppr = ""
        if p.bullet != nil { ppr += "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr>" }
        // Tab stops for lines split into separate segments (e.g. footer text and a logo).
        var tabs: [(String, Int)] = []
        if let line = p.lines.first, line.segments.count > 1 {
            for (k, seg) in line.segments.enumerated() where k > 0 {
                let rightAligned = abs(seg.box.x1 - areaRight) < (areaRight - areaLeft) * 0.04
                tabs.append(rightAligned ? ("right", i((seg.box.x1 - areaLeft) * scale)) : ("left", i((seg.box.x0 - areaLeft) * scale)))
            }
        }
        if !tabs.isEmpty { ppr += "<w:tabs>" + tabs.map { "<w:tab w:val=\"\($0.0)\" w:pos=\"\($0.1)\"/>" }.joined() + "</w:tabs>" }
        let rule = p.lines.count > 1 ? "exact" : "atLeast"
        ppr += "<w:spacing w:before=\"\(i(before))\" w:after=\"0\" w:line=\"\(max(120, i(lineHeight)))\" w:lineRule=\"\(rule)\"/>"
        switch p.alignment {
        case .left:
            let indent = i((p.box.x0 - areaLeft) * scale)
            if let b = p.bullet { ppr += "<w:ind w:left=\"\(max(0, indent))\" w:hanging=\"\(max(0, i((p.box.x0 - b.x0) * scale)))\"/>" }
            else if indent > 0 { ppr += "<w:ind w:left=\"\(indent)\"/>" }
        case .center:
            let shift = (p.box.midX - (areaLeft + areaRight) / 2) * 2 * scale
            if shift > 0 { ppr += "<w:ind w:left=\"\(i(shift))\"/>" } else if shift < 0 { ppr += "<w:ind w:right=\"\(i(-shift))\"/>" }
            ppr += "<w:jc w:val=\"center\"/>"
        case .right:
            let indent = i((areaRight - p.box.x1) * scale)
            if indent > 0 { ppr += "<w:ind w:right=\"\(indent)\"/>" }
            ppr += "<w:jc w:val=\"right\"/>"
        }
        var runs = ""
        for (n, line) in p.lines.enumerated() {
            for (k, seg) in line.segments.enumerated() {
                if k > 0 { runs += "<w:r><w:tab/></w:r>" }
                let size = seg.fontSize ?? p.fontSize
                for run in seg.runs { runs += wordRun(run, size: size, spacing: p.letterSpacing) }
            }
            if n + 1 < p.lines.count {
                if line.wraps { runs += "<w:r><w:t xml:space=\"preserve\"> </w:t></w:r>" } else { runs += "<w:r><w:br/></w:r>" }
            }
        }
        return "<w:p><w:pPr>\(ppr)</w:pPr>\(runs)</w:p>"
    }

    static func wordTable(_ t: LayoutTable, areaLeft: Double, scale: Double, pointsPerPixel: Double) -> String {
        let widths = (0..<t.columnCount).map { max(60, i((t.columns[$0 + 1] - t.columns[$0]) * scale)) }
        let border = "w:val=\"single\" w:sz=\"8\" w:space=\"0\" w:color=\"000000\""
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"\(widths.reduce(0, +))\" w:type=\"dxa\"/><w:tblInd w:w=\"\(i((t.columns[0] - areaLeft) * scale))\" w:type=\"dxa\"/>"
        xml += "<w:tblBorders><w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:bottom w:val=\"nil\"/><w:right w:val=\"nil\"/><w:insideH w:val=\"nil\"/><w:insideV w:val=\"nil\"/></w:tblBorders>"
        xml += "<w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"57\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"57\" w:type=\"dxa\"/></w:tblCellMar><w:tblLook w:val=\"0000\"/></w:tblPr>"
        xml += "<w:tblGrid>" + widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
        for r in 0..<t.rowCount {
            let h = i((t.rows[r + 1] - t.rows[r]) * scale)
            // Exact heights keep the page geometry when every line fits the row.
            let fits = t.cells.filter { $0.row == r && $0.rowSpan == 1 }.allSatisfy { Double(max(1, $0.lines.count)) * $0.fontSize * 23 <= Double(h) }
            xml += "<w:tr><w:trPr><w:trHeight w:val=\"\(h)\" w:hRule=\"\(fits ? "exact" : "atLeast")\"/><w:cantSplit/></w:trPr>"
            var c = 0
            while c < t.columnCount {
                guard let cell = t.cells.first(where: { $0.column == c && r >= $0.row && r < $0.row + $0.rowSpan }) else {
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(widths[c])\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"; c += 1; continue
                }
                let span = max(1, min(cell.columnSpan, t.columnCount - c))
                let width = widths[c..<(c + span)].reduce(0, +)
                var tcpr = "<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
                if span > 1 { tcpr += "<w:gridSpan w:val=\"\(span)\"/>" }
                if cell.rowSpan > 1 { tcpr += cell.row == r ? "<w:vMerge w:val=\"restart\"/>" : "<w:vMerge/>" }
                let sides = [("top", cell.top), ("left", cell.left), ("bottom", cell.bottom), ("right", cell.right)]
                tcpr += "<w:tcBorders>" + sides.map { "<w:\($0.0) " + ($0.1 ? border : "w:val=\"nil\"") + "/>" }.joined() + "</w:tcBorders>"
                if let fill = cell.fill { tcpr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill.hex)\"/>" }
                tcpr += "<w:vAlign w:val=\"center\"/>"
                var content = ""
                if cell.row == r && !cell.lines.isEmpty {
                    let jc = cell.alignment == .left ? "left" : (cell.alignment == .center ? "center" : "right")
                    for line in cell.lines {
                        content += "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/><w:jc w:val=\"\(jc)\"/></w:pPr>" + line.map { wordRun($0, size: cell.fontSize, spacing: cell.letterSpacing) }.joined() + "</w:p>"
                    }
                } else {
                    content = "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/><w:rPr><w:sz w:val=\"\(i(cell.fontSize * 2))\"/></w:rPr></w:pPr></w:p>"
                }
                xml += "<w:tc><w:tcPr>\(tcpr)</w:tcPr>\(content)</w:tc>"
                c += span
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    static func wordAnchor(_ box: LBox, emu: Double, rid: String, id: Int) -> String {
        let cx = max(1, i(box.width * emu)), cy = max(1, i(box.height * emu))
        return "<w:r><w:drawing><wp:anchor distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\" simplePos=\"0\" relativeHeight=\"\(id)\" behindDoc=\"1\" locked=\"0\" layoutInCell=\"1\" allowOverlap=\"1\"><wp:simplePos x=\"0\" y=\"0\"/><wp:positionH relativeFrom=\"page\"><wp:posOffset>\(i(box.x0 * emu))</wp:posOffset></wp:positionH><wp:positionV relativeFrom=\"page\"><wp:posOffset>\(i(box.y0 * emu))</wp:posOffset></wp:positionV><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/><wp:wrapNone/><wp:docPr id=\"\(id)\" name=\"Picture \(id)\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(id)\" name=\"Picture \(id)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(rid)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:anchor></w:drawing></w:r>"
    }

    // MARK: - Excel
    final class ExcelStyles {
        var fonts: [String] = ["<font><sz val=\"11\"/><color theme=\"1\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"]
        var fills: [String] = ["<fill><patternFill patternType=\"none\"/></fill>", "<fill><patternFill patternType=\"gray125\"/></fill>"]
        var borders: [String] = ["<border><left/><right/><top/><bottom/><diagonal/></border>"]
        var xfs: [String] = ["<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"]
        private var fontIndex: [String: Int] = [:], fillIndex: [String: Int] = [:], borderIndex: [String: Int] = [:], xfIndex: [String: Int] = [:]
        static func fontXML(size: Double, bold: Bool, underline: Bool, color: LayoutColor?, wide: Bool, tag: String = "font") -> String {
            let name = wide ? OfficeLayoutExport.eastAsianFont : OfficeLayoutExport.latinFont
            let rgb = "FF" + (color ?? .black).hex
            // Element order matters for Excel: b, u, sz, color, name/rFont, family.
            let nameTag = tag == "rPr" ? "rFont" : "name"
            return "<\(tag)>\(bold ? "<b/>" : "")\(underline ? "<u/>" : "")<sz val=\"\(String(format: "%.1f", size))\"/><color rgb=\"\(rgb)\"/><\(nameTag) val=\"\(name)\"/><family val=\"2\"/></\(tag)>"
        }
        func font(size: Double, bold: Bool, underline: Bool, color: LayoutColor?, wide: Bool) -> Int {
            let xml = Self.fontXML(size: size, bold: bold, underline: underline, color: color, wide: wide)
            if let i = fontIndex[xml] { return i }
            fonts.append(xml); fontIndex[xml] = fonts.count - 1; return fonts.count - 1
        }
        func fill(_ color: LayoutColor?) -> Int {
            guard let color else { return 0 }
            let xml = "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF\(color.hex)\"/><bgColor indexed=\"64\"/></patternFill></fill>"
            if let i = fillIndex[xml] { return i }
            fills.append(xml); fillIndex[xml] = fills.count - 1; return fills.count - 1
        }
        func border(top: Bool, left: Bool, bottom: Bool, right: Bool) -> Int {
            guard top || left || bottom || right else { return 0 }
            func side(_ n: String, _ on: Bool) -> String { on ? "<\(n) style=\"thin\"><color rgb=\"FF000000\"/></\(n)>" : "<\(n)/>" }
            let xml = "<border>\(side("left", left))\(side("right", right))\(side("top", top))\(side("bottom", bottom))<diagonal/></border>"
            if let i = borderIndex[xml] { return i }
            borders.append(xml); borderIndex[xml] = borders.count - 1; return borders.count - 1
        }
        func xf(font: Int, fill: Int, border: Int, horizontal: LayoutAlignment, wrap: Bool) -> Int {
            let h = horizontal == .left ? "left" : (horizontal == .center ? "center" : "right")
            let xml = "<xf numFmtId=\"49\" fontId=\"\(font)\" fillId=\"\(fill)\" borderId=\"\(border)\" xfId=\"0\" applyNumberFormat=\"1\" applyFont=\"1\" applyFill=\"1\" applyBorder=\"1\" applyAlignment=\"1\"><alignment horizontal=\"\(h)\" vertical=\"center\"\(wrap ? " wrapText=\"1\"" : "")/></xf>"
            if let i = xfIndex[xml] { return i }
            xfs.append(xml); xfIndex[xml] = xfs.count - 1; return xfs.count - 1
        }
        var xml: String {
            OfficeExport.declaration + "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"\(fonts.count)\">\(fonts.joined())</fonts><fills count=\"\(fills.count)\">\(fills.joined())</fills><borders count=\"\(borders.count)\">\(borders.joined())</borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"\(xfs.count)\">\(xfs.joined())</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
        }
    }

    /// Lays one page out on a worksheet grid: table rows and text lines become
    /// rows, table and text edges become columns.
    struct SheetGrid {
        var xs: [Double] = []
        var ys: [Double] = []
        func column(at x: Double) -> Int {
            var best = 0, distance = Double.infinity
            for (k, v) in xs.enumerated() where k < xs.count - 1 { let d = abs(v - x); if d < distance { distance = d; best = k } }
            return best
        }
        func columnEnding(at x: Double) -> Int {
            var best = xs.count - 2, distance = Double.infinity
            for k in 1..<xs.count { let d = abs(xs[k] - x); if d < distance { distance = d; best = k - 1 } }
            return max(0, best)
        }
        func row(at y: Double) -> Int {
            var best = 0, distance = Double.infinity
            for (k, v) in ys.enumerated() where k < ys.count - 1 { let d = abs(v - y); if d < distance { distance = d; best = k } }
            return best
        }
        func rowEnding(at y: Double) -> Int {
            var best = ys.count - 2, distance = Double.infinity
            for k in 1..<ys.count { let d = abs(ys[k] - y); if d < distance { distance = d; best = k - 1 } }
            return max(0, best)
        }
    }

    static func sheetGrid(_ page: PageLayout) -> SheetGrid {
        let content = page.contentBox
        var xs = [content.x0, content.x1]
        var bands: [(Double, Double)] = []
        for item in page.items {
            switch item {
            case .table(let t):
                xs += t.columns
                for r in 0..<t.rowCount { bands.append((t.rows[r], t.rows[r + 1])) }
            case .paragraph(let p):
                let lineH = max(p.linePitch, p.fontSize / page.pointsPerPixel * 1.18)
                for line in p.lines {
                    bands.append((line.box.midY - lineH / 2, line.box.midY + lineH / 2))
                    for (k, seg) in line.segments.enumerated() {
                        if p.alignment == .left || k > 0 { xs.append(k == 0 ? (p.bullet?.x0 ?? seg.box.x0) : seg.box.x0) }
                        if p.alignment == .right { xs.append(seg.box.x1) }
                    }
                }
            }
        }
        let tolerance = Double(page.width) * 0.006
        var merged: [Double] = []
        for v in xs.sorted() { if let last = merged.last, v - last < tolerance { continue }; merged.append(v) }
        if merged.count < 2 { merged = [content.x0, content.x1] }
        // Rows: bands in order; overlapping bands share rows, gaps become spacer rows.
        bands.sort { $0.0 < $1.0 }
        var ys: [Double] = [min(content.y0, bands.first?.0 ?? content.y0)]
        for band in bands {
            let last = ys.last!
            if band.0 > last + 2 { ys.append(band.0) }
            if band.1 > ys.last! + 2 { ys.append(band.1) }
        }
        if ys.count < 2 { ys.append(ys[0] + 20) }
        return SheetGrid(xs: merged, ys: ys)
    }

    static func excel(_ pages: [PageLayout], image: ImageProvider) throws -> Data {
        guard !pages.isEmpty else { throw ScannerError.message("Choose at least one page.") }
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let styles = ExcelStyles()
        var entries: [(String, Data)] = [], types: [(String, String)] = [], workbookRels: [(String, String, String)] = []
        var sheets = ""
        var mediaCount = 0
        for (pageIndex, page) in pages.enumerated() {
            let grid = sheetGrid(page)
            let pt = page.pointsPerPixel
            var cells: [Int: [Int: String]] = [:]  // row -> column -> xml
            var merges: [String] = []
            var occupied = Set<Int>()
            func ref(_ r: Int, _ c: Int) -> String { "\(OfficeExport.column(c))\(r + 1)" }
            func put(_ r: Int, _ c: Int, _ xml: String) { cells[r, default: [:]][c] = xml }
            func styleRange(_ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int, style: Int) {
                for r in r0...r1 { for c in c0...c1 where !(r == r0 && c == c0) { put(r, c, "<c r=\"\(ref(r, c))\" s=\"\(style)\"/>") } }
            }
            func inline(_ runs: [LayoutRun], size: Double) -> String {
                if runs.count == 1 || Set(runs.map { "\($0.bold)\($0.underline)\($0.color?.hex ?? "")" }).count == 1 {
                    return "<is><t xml:space=\"preserve\">\(x(runs.map(\.text).joined()))</t></is>"
                }
                return "<is>" + runs.map { "<r>" + ExcelStyles.fontXML(size: size, bold: $0.bold, underline: $0.underline, color: $0.color, wide: hasWide($0.text), tag: "rPr") + "<t xml:space=\"preserve\">\(x($0.text))</t></r>" }.joined() + "</is>"
            }
            for item in page.items {
                switch item {
                case .table(let t):
                    let colIndex = t.columns.map { grid.column(at: $0) }
                    let rowIndex = t.rows.map { grid.row(at: $0) }
                    for cell in t.cells {
                        let r0 = rowIndex[cell.row], c0 = colIndex[cell.column]
                        let r1 = max(r0, (cell.row + cell.rowSpan < rowIndex.count ? rowIndex[cell.row + cell.rowSpan] : grid.ys.count - 1) - 1)
                        let c1 = max(c0, (cell.column + cell.columnSpan < colIndex.count ? colIndex[cell.column + cell.columnSpan] : grid.xs.count - 1) - 1)
                        guard !occupied.contains(r0 * 100000 + c0) else { continue }
                        let text = cell.text
                        let firstRun = cell.lines.first?.first
                        let font = styles.font(size: cell.fontSize, bold: firstRun?.bold ?? false, underline: firstRun?.underline ?? false, color: firstRun?.color, wide: hasWide(text))
                        let style = styles.xf(font: font, fill: styles.fill(cell.fill), border: styles.border(top: cell.top, left: cell.left, bottom: cell.bottom, right: cell.right), horizontal: cell.alignment, wrap: cell.lines.count > 1)
                        let runs = cell.lines.enumerated().flatMap { k, line -> [LayoutRun] in
                            k == 0 ? line : [LayoutRun(text: "\n", bold: line.first?.bold ?? false)] + line
                        }
                        put(r0, c0, text.isEmpty ? "<c r=\"\(ref(r0, c0))\" s=\"\(style)\"/>" : "<c r=\"\(ref(r0, c0))\" s=\"\(style)\" t=\"inlineStr\">\(inline(runs, size: cell.fontSize))</c>")
                        for r in r0...r1 { for c in c0...c1 { occupied.insert(r * 100000 + c) } }
                        if r1 > r0 || c1 > c0 { merges.append("\(ref(r0, c0)):\(ref(r1, c1))"); styleRange(r0, c0, r1, c1, style: style) }
                    }
                case .paragraph(let p):
                    let lineH = max(p.linePitch, p.fontSize / pt * 1.18)
                    for line in p.lines {
                        let r = grid.row(at: line.box.midY - lineH / 2)
                        for (k, seg) in line.segments.enumerated() {
                            var c0: Int, c1: Int
                            let nextStart = k + 1 < line.segments.count ? grid.column(at: line.segments[k + 1].box.x0) - 1 : grid.xs.count - 2
                            switch p.alignment {
                            case .left: c0 = grid.column(at: k == 0 ? (p.bullet?.x0 ?? seg.box.x0) : seg.box.x0); c1 = max(c0, nextStart)
                            case .center: c0 = 0; c1 = grid.xs.count - 2
                            case .right: c0 = k == 0 ? 0 : grid.column(at: seg.box.x0); c1 = grid.columnEnding(at: seg.box.x1)
                            }
                            if line.segments.count > 1 && p.alignment != .left { c0 = grid.column(at: seg.box.x0); c1 = max(c0, nextStart) }
                            guard !occupied.contains(r * 100000 + c0) else { continue }
                            while c1 > c0 && occupied.contains(r * 100000 + c1) { c1 -= 1 }
                            let size = seg.fontSize ?? p.fontSize
                            let first = seg.runs.first
                            let font = styles.font(size: size, bold: first?.bold ?? false, underline: first?.underline ?? false, color: first?.color, wide: hasWide(seg.text))
                            let style = styles.xf(font: font, fill: 0, border: 0, horizontal: line.segments.count > 1 ? .left : p.alignment, wrap: false)
                            var runs = seg.runs
                            if k == 0 && p.bullet != nil { runs.insert(LayoutRun(text: "•  "), at: 0) }
                            put(r, c0, "<c r=\"\(ref(r, c0))\" s=\"\(style)\" t=\"inlineStr\">\(inline(runs, size: size))</c>")
                            for c in c0...c1 { occupied.insert(r * 100000 + c) }
                            if c1 > c0 { merges.append("\(ref(r, c0)):\(ref(r, c1))") }
                        }
                    }
                }
            }
            // Column widths in Excel character units (Calibri 11: 7 px per character at 96 dpi).
            let cols = (0..<(grid.xs.count - 1)).map { k -> String in
                let px96 = (grid.xs[k + 1] - grid.xs[k]) * pt * 96 / 72
                let width = max(0.3, ((px96 - 5) / 7 * 100).rounded() / 100)
                return "<col min=\"\(k + 1)\" max=\"\(k + 1)\" width=\"\(String(format: "%.2f", width))\" customWidth=\"1\"/>"
            }.joined()
            var rowsXML = ""
            for r in 0..<(grid.ys.count - 1) {
                let height = min(409, max(2, (grid.ys[r + 1] - grid.ys[r]) * pt))
                let content = (cells[r] ?? [:]).sorted { $0.key < $1.key }.map(\.value).joined()
                rowsXML += "<row r=\"\(r + 1)\" ht=\"\(String(format: "%.2f", height))\" customHeight=\"1\">\(content)</row>"
            }
            let n = pageIndex + 1
            var sheetRels: [(String, String, String)] = []
            var drawingXML = ""
            if !page.graphics.isEmpty {
                var anchors = ""
                var drawingRels: [(String, String, String)] = []
                for (k, g) in page.graphics.enumerated() {
                    let data = try g.png ?? image(pageIndex, g.box, g.cutout)
                    mediaCount += 1
                    entries.append(("xl/media/image\(mediaCount).png", data))
                    drawingRels.append(("rId\(k + 1)", "image", "../media/image\(mediaCount).png"))
                    let emu = pt * 12700
                    func colPos(_ v: Double) -> (Int, Int) { let c = max(0, grid.xs.lastIndex(where: { $0 <= v }) ?? 0); return (min(c, grid.xs.count - 2), max(0, i((v - grid.xs[min(c, grid.xs.count - 2)]) * emu))) }
                    func rowPos(_ v: Double) -> (Int, Int) { let r = max(0, grid.ys.lastIndex(where: { $0 <= v }) ?? 0); return (min(r, grid.ys.count - 2), max(0, i((v - grid.ys[min(r, grid.ys.count - 2)]) * emu))) }
                    let from = (colPos(g.box.x0), rowPos(g.box.y0))
                    anchors += "<xdr:oneCellAnchor><xdr:from><xdr:col>\(from.0.0)</xdr:col><xdr:colOff>\(from.0.1)</xdr:colOff><xdr:row>\(from.1.0)</xdr:row><xdr:rowOff>\(from.1.1)</xdr:rowOff></xdr:from><xdr:ext cx=\"\(i(g.box.width * emu))\" cy=\"\(i(g.box.height * emu))\"/><xdr:pic><xdr:nvPicPr><xdr:cNvPr id=\"\(k + 2)\" name=\"Picture \(k + 1)\"/><xdr:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></xdr:cNvPicPr></xdr:nvPicPr><xdr:blipFill><a:blip r:embed=\"rId\(k + 1)\"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill><xdr:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(i(g.box.width * emu))\" cy=\"\(i(g.box.height * emu))\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></xdr:spPr></xdr:pic><xdr:clientData/></xdr:oneCellAnchor>"
                }
                let drawing = OfficeExport.declaration + "<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"\(OfficeExport.officeNS)\">\(anchors)</xdr:wsDr>"
                entries.append(("xl/drawings/drawing\(n).xml", Data(drawing.utf8)))
                entries.append(("xl/drawings/_rels/drawing\(n).xml.rels", Data(OfficeExport.relationships(drawingRels).utf8)))
                types.append(("xl/drawings/drawing\(n).xml", "drawing"))
                sheetRels.append(("rId1", "drawing", "../drawings/drawing\(n).xml"))
                drawingXML = "<drawing r:id=\"rId1\"/>"
            }
            let marginIn = { (v: Double) in String(format: "%.2f", max(0.2, v * pt / 72)) }
            let content = page.contentBox
            let sheet = OfficeExport.declaration + "<worksheet xmlns=\"\(ns)\" xmlns:r=\"\(OfficeExport.officeNS)\"><sheetPr><pageSetUpPr fitToPage=\"1\"/></sheetPr><sheetViews><sheetView showGridLines=\"0\" workbookViewId=\"0\"/></sheetViews><sheetFormatPr defaultRowHeight=\"15\"/><cols>\(cols)</cols><sheetData>\(rowsXML)</sheetData>\(merges.isEmpty ? "" : "<mergeCells count=\"\(merges.count)\">" + merges.map { "<mergeCell ref=\"\($0)\"/>" }.joined() + "</mergeCells>")<pageMargins left=\"\(marginIn(content.x0))\" right=\"\(marginIn(Double(page.width) - content.x1))\" top=\"\(marginIn(content.y0))\" bottom=\"0.3\" header=\"0\" footer=\"0\"/><pageSetup paperSize=\"\(page.pageHeight > 830 ? 9 : 1)\" orientation=\"\(page.pageWidth > page.pageHeight ? "landscape" : "portrait")\" fitToWidth=\"1\" fitToHeight=\"0\"/>\(drawingXML)</worksheet>"
            entries.append(("xl/worksheets/sheet\(n).xml", Data(sheet.utf8)))
            if !sheetRels.isEmpty { entries.append(("xl/worksheets/_rels/sheet\(n).xml.rels", Data(OfficeExport.relationships(sheetRels).utf8))) }
            types.append(("xl/worksheets/sheet\(n).xml", "spreadsheetml.worksheet"))
            workbookRels.append(("rId\(n)", "worksheet", "worksheets/sheet\(n).xml"))
            sheets += "<sheet name=\"Page \(n)\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
        }
        workbookRels.append(("rId\(pages.count + 1)", "styles", "styles.xml"))
        let workbook = OfficeExport.declaration + "<workbook xmlns=\"\(ns)\" xmlns:r=\"\(OfficeExport.officeNS)\"><sheets>\(sheets)</sheets></workbook>"
        entries += [("xl/workbook.xml", Data(workbook.utf8)), ("xl/_rels/workbook.xml.rels", Data(OfficeExport.relationships(workbookRels).utf8)), ("xl/styles.xml", Data(styles.xml.utf8))]
        types += [("xl/workbook.xml", "spreadsheetml.sheet.main"), ("xl/styles.xml", "spreadsheetml.styles")]
        return try OfficeExport.package(entries, main: "xl/workbook.xml", types: types)
    }

    // MARK: - PowerPoint
    static func powerpoint(_ pages: [PageLayout], theme: Data, image: ImageProvider) throws -> Data {
        guard let first = pages.first, pages.count <= 30 else { throw ScannerError.message("Choose 1–30 pages for a presentation.") }
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main", a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let slideW = max(914400, min(51206400, i(first.pageWidth * 12700))), slideH = max(914400, min(51206400, i(first.pageHeight * 12700)))
        let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        var entries: [(String, Data)] = [("ppt/theme/theme1.xml", theme)], types: [(String, String)] = [("ppt/theme/theme1.xml", "theme")], rels: [(String, String, String)] = []
        var mediaCount = 0
        for (pageIndex, page) in pages.enumerated() {
            let emu = page.pointsPerPixel * 12700 * Double(slideW) / (page.pageWidth * 12700)
            var shapes = ""
            var slideRels = [("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]
            var id = 2
            for g in page.graphics {
                let data = try g.png ?? image(pageIndex, g.box, g.cutout)
                mediaCount += 1
                entries.append(("ppt/media/image\(mediaCount).png", data))
                let rid = "rId\(slideRels.count + 1)"
                slideRels.append((rid, "image", "../media/image\(mediaCount).png"))
                shapes += "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"Picture \(id)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(rid)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\(i(g.box.x0 * emu))\" y=\"\(i(g.box.y0 * emu))\"/><a:ext cx=\"\(max(1, i(g.box.width * emu)))\" cy=\"\(max(1, i(g.box.height * emu)))\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
                id += 1
            }
            for item in page.items {
                switch item {
                case .paragraph(let par):
                    shapes += slideParagraph(par, emu: emu, pt: page.pointsPerPixel, id: &id)
                case .table(let t):
                    shapes += slideTable(t, emu: emu, id: id); id += 1
                }
            }
            let n = pageIndex + 1, path = "ppt/slides/slide\(n).xml"
            entries.append((path, Data((OfficeExport.declaration + "<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(OfficeExport.officeNS)\"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"FFFFFF\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>\(group)\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>").utf8)))
            entries.append(("ppt/slides/_rels/slide\(n).xml.rels", Data(OfficeExport.relationships(slideRels).utf8)))
            types.append((path, "presentationml.slide")); rels.append(("rId\(n + 1)", "slide", "slides/slide\(n).xml"))
        }
        let ids = (0..<pages.count).map { "<p:sldId id=\"\($0 + 256)\" r:id=\"rId\($0 + 2)\"/>" }.joined()
        let pres = OfficeExport.declaration + "<p:presentation xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(OfficeExport.officeNS)\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx=\"\(slideW)\" cy=\"\(slideH)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        let colorMap = "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        entries += [("ppt/presentation.xml", Data(pres.utf8)), ("ppt/_rels/presentation.xml.rels", Data(OfficeExport.relationships([("rId1", "slideMaster", "slideMasters/slideMaster1.xml")] + rels).utf8)),
                    ("ppt/slideMasters/slideMaster1.xml", Data((OfficeExport.declaration + "<p:sldMaster xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(OfficeExport.officeNS)\"><p:cSld><p:spTree>\(group)</p:spTree></p:cSld>\(colorMap)<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>").utf8)),
                    ("ppt/slideMasters/_rels/slideMaster1.xml.rels", Data(OfficeExport.relationships([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")]).utf8)),
                    ("ppt/slideLayouts/slideLayout1.xml", Data((OfficeExport.declaration + "<p:sldLayout xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(OfficeExport.officeNS)\" type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>").utf8)),
                    ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Data(OfficeExport.relationships([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]).utf8))]
        types += [("ppt/presentation.xml", "presentationml.presentation.main"), ("ppt/slideMasters/slideMaster1.xml", "presentationml.slideMaster"), ("ppt/slideLayouts/slideLayout1.xml", "presentationml.slideLayout")]
        return try OfficeExport.package(entries, main: "ppt/presentation.xml", types: types)
    }

    static func drawingRun(_ run: LayoutRun, size: Double, spacing: Double = 0) -> String {
        let wide = hasWide(run.text)
        var attrs = "lang=\"\(wide ? "ko-KR" : "en-US")\" sz=\"\(i(size * 100))\""
        if run.bold { attrs += " b=\"1\"" }
        if run.underline { attrs += " u=\"sng\"" }
        if abs(spacing) >= 0.05 { attrs += " spc=\"\(i(spacing * 100))\"" }
        let color = "<a:solidFill><a:srgbClr val=\"\((run.color ?? .black).hex)\"/></a:solidFill>"
        return "<a:r><a:rPr \(attrs) dirty=\"0\">\(color)<a:latin typeface=\"\(latinFont)\"/><a:ea typeface=\"\(eastAsianFont)\"/><a:cs typeface=\"\(latinFont)\"/></a:rPr><a:t>\(x(run.text))</a:t></a:r>"
    }

    static func slideParagraph(_ p: LayoutParagraph, emu: Double, pt: Double, id: inout Int) -> String {
        var xml = ""
        let lineH = max(p.linePitch, p.fontSize / pt * 1.18)
        func box(_ b: LBox, lines: Int, body: String, wrap: Bool, align: LayoutAlignment) -> String {
            let top = b.y0 - (lineH - (b.height / Double(lines))) / 2
            let height = lineH * Double(lines)
            // Unwrapped boxes get extra width so font differences never break a line.
            let slack = wrap ? b.width * 0.03 : b.width * 0.25
            var x0 = b.x0, width = b.width + slack
            if align == .center { x0 -= slack / 2 } else if align == .right { x0 -= slack }
            let algn = align == .left ? "l" : (align == .center ? "ctr" : "r")
            let shape = "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Text \(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(i(x0 * emu))\" y=\"\(i(top * emu))\"/><a:ext cx=\"\(max(1, i(width * emu)))\" cy=\"\(max(1, i(height * emu)))\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap=\"\(wrap ? "square" : "none")\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" anchor=\"t\"><a:noAutofit/></a:bodyPr><a:lstStyle/>" + body.replacingOccurrences(of: "ALGN", with: algn) + "</p:txBody></p:sp>"
            id += 1
            return shape
        }
        let spacing = "<a:lnSpc><a:spcPts val=\"\(i(lineH * pt * 100))\"/></a:lnSpc>"
        if p.lines.contains(where: { $0.segments.count > 1 }) {
            // Each segment is placed on its own.
            for line in p.lines { for (k, seg) in line.segments.enumerated() {
                let body = "<a:p><a:pPr algn=\"ALGN\">\(spacing)</a:pPr>" + seg.runs.map { drawingRun($0, size: seg.fontSize ?? p.fontSize, spacing: p.letterSpacing) }.joined() + "</a:p>"
                xml += box(seg.box, lines: 1, body: body, wrap: false, align: k == 0 ? p.alignment : .left)
            } }
            return xml
        }
        var b = p.box
        var ppr: String
        if let bullet = p.bullet {
            let indent = i((p.box.x0 - bullet.x0) * emu)
            ppr = "<a:pPr algn=\"ALGN\" marL=\"\(indent)\" indent=\"-\(indent)\">\(spacing)<a:buFont typeface=\"\(latinFont)\"/><a:buChar char=\"•\"/></a:pPr>"
            b.x0 = bullet.x0
        } else { ppr = "<a:pPr algn=\"ALGN\">\(spacing)<a:buNone/></a:pPr>" }
        var body = "<a:p>\(ppr)"
        for (n, line) in p.lines.enumerated() {
            for run in line.segments.flatMap(\.runs) { body += drawingRun(run, size: line.segments.first?.fontSize ?? p.fontSize, spacing: p.letterSpacing) }
            if n + 1 < p.lines.count {
                if line.wraps { body += drawingRun(LayoutRun(text: " "), size: p.fontSize) }
                else { body += "<a:br><a:rPr lang=\"en-US\" sz=\"\(i(p.fontSize * 100))\"/></a:br>" }
            }
        }
        body += "</a:p>"
        let wraps = p.lines.contains { $0.wraps }
        return box(b, lines: p.lines.count, body: body, wrap: wraps, align: p.alignment)
    }

    static func slideTable(_ t: LayoutTable, emu: Double, id: Int) -> String {
        let widths = (0..<t.columnCount).map { i((t.columns[$0 + 1] - t.columns[$0]) * emu) }
        let heights = (0..<t.rowCount).map { i((t.rows[$0 + 1] - t.rows[$0]) * emu) }
        func line(_ side: String, _ on: Bool) -> String {
            on ? "<a:\(side) w=\"12700\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:srgbClr val=\"000000\"/></a:solidFill><a:prstDash val=\"solid\"/></a:\(side)>" : "<a:\(side) w=\"0\"><a:noFill/></a:\(side)>"
        }
        var rows = ""
        for r in 0..<t.rowCount {
            rows += "<a:tr h=\"\(heights[r])\">"
            for c in 0..<t.columnCount {
                let owner = t.cells.first { r >= $0.row && r < $0.row + $0.rowSpan && c >= $0.column && c < $0.column + $0.columnSpan }
                var attrs = ""
                var paragraphs = "<a:p><a:endParaRPr lang=\"en-US\" sz=\"\(i((owner?.fontSize ?? 10) * 100))\"/></a:p>"
                if let cell = owner {
                    if cell.row == r && cell.column == c {
                        if cell.columnSpan > 1 { attrs += " gridSpan=\"\(cell.columnSpan)\"" }
                        if cell.rowSpan > 1 { attrs += " rowSpan=\"\(cell.rowSpan)\"" }
                        if !cell.lines.isEmpty {
                            let algn = cell.alignment == .left ? "l" : (cell.alignment == .center ? "ctr" : "r")
                            paragraphs = cell.lines.map { "<a:p><a:pPr algn=\"\(algn)\"/>" + $0.map { drawingRun($0, size: cell.fontSize, spacing: cell.letterSpacing) }.joined() + "</a:p>" }.joined()
                        }
                    } else {
                        if c > cell.column { attrs += " hMerge=\"1\"" }
                        if r > cell.row { attrs += " vMerge=\"1\"" }
                    }
                }
                let cell = owner ?? LayoutCell(row: r, column: c, box: LBox(0, 0, 0, 0))
                let fill = cell.fill.map { "<a:solidFill><a:srgbClr val=\"\($0.hex)\"/></a:solidFill>" } ?? "<a:noFill/>"
                rows += "<a:tc\(attrs)><a:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs)</a:txBody><a:tcPr marL=\"45720\" marR=\"45720\" marT=\"0\" marB=\"0\" anchor=\"ctr\">\(line("lnL", cell.left))\(line("lnR", cell.right))\(line("lnT", cell.top))\(line("lnB", cell.bottom))\(fill)</a:tcPr></a:tc>"
            }
            rows += "</a:tr>"
        }
        let box = t.box
        return "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"\(id)\" name=\"Table \(id)\"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=\"1\"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x=\"\(i(box.x0 * emu))\" y=\"\(i(box.y0 * emu))\"/><a:ext cx=\"\(widths.reduce(0, +))\" cy=\"\(heights.reduce(0, +))\"/></p:xfrm><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tblPr/><a:tblGrid>" + widths.map { "<a:gridCol w=\"\($0)\"/>" }.joined() + "</a:tblGrid>\(rows)</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    }
}
