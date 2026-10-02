import UIKit
import Vision

struct OfficeTable: Identifiable, Equatable {
    struct Merge: Equatable { var row: Int; var column: Int; var rows: Int; var columns: Int }
    let id = UUID()
    var name: String
    var cells: [[String]]
    var merges: [Merge] = []
    var inferred = false
    var columnCount: Int { cells.map(\.count).max() ?? 0 }
    mutating func normalize() {
        let width = max(1,columnCount)
        cells = cells.map { $0 + Array(repeating:"",count:width-$0.count) }
    }
    func isCovered(row:Int,column:Int) -> Bool {
        merges.contains { row >= $0.row && row < $0.row+$0.rows && column >= $0.column && column < $0.column+$0.columns && (row != $0.row || column != $0.column) }
    }
}

enum OfficeTableRecognition {
    static func recognize(_ image: UIImage, page: Int) async throws -> [OfficeTable] {
        guard let cg = image.cgImage else { throw ScannerError.message("This page couldn't be read.") }
        if #available(iOS 26.0, *) {
            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.automaticallyDetectLanguage = true
            request.barcodeDetectionOptions.enabled = false
            let observations = try await request.perform(on:cg)
            try Task.checkCancellation()
            var results: [OfficeTable] = []
            for observation in observations {
                for table in observation.document.tables {
                    let cells = table.rows.flatMap { $0 }
                    let rowCount = (cells.map { $0.rowRange.upperBound }.max() ?? -1)+1
                    let columnCount = (cells.map { $0.columnRange.upperBound }.max() ?? -1)+1
                    guard rowCount > 0, columnCount > 0 else { continue }
                    guard rowCount <= 1000, columnCount <= 100, rowCount*columnCount <= 20000 else {
                        throw ScannerError.message("This table is too large. Use a smaller section of the page.")
                    }
                    var result = OfficeTable(name:"Page \(page) · Table \(results.count+1)",cells:Array(repeating:Array(repeating:"",count:columnCount),count:rowCount))
                    var visited = Set<String>()
                    for cell in cells {
                        let row = cell.rowRange.lowerBound, column = cell.columnRange.lowerBound
                        guard row >= 0, column >= 0, visited.insert("\(row):\(column)").inserted else { continue }
                        result.cells[row][column] = cell.content.text.transcript
                        if cell.rowRange.count > 1 || cell.columnRange.count > 1 {
                            result.merges.append(.init(row:row,column:column,rows:cell.rowRange.count,columns:cell.columnRange.count))
                        }
                    }
                    results.append(result)
                }
            }
            if !results.isEmpty { return results }
        }
        let blocks = try await OfflineWork.perform { try TextRecognition.recognize(cg) }
        let text = OfficeExport.tableText(blocks)
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return [] }
        var table = OfficeTable(name:"Page \(page)",cells:text.components(separatedBy:"\n").map { $0.components(separatedBy:"\t") },inferred:true)
        table.normalize()
        guard table.cells.count <= 1000,table.columnCount <= 100,table.cells.count*table.columnCount <= 20000 else { throw ScannerError.message("Too many cells were found. Crop to the table and try again.") }
        return [table]
    }
}

extension OfficeExport {
    static func excel(tables:[OfficeTable]) throws -> Data {
        guard !tables.isEmpty, tables.count <= 100 else { throw ScannerError.message("Choose 1–100 tables.") }
        let ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        var entries:[(String,Data)] = [],types:[(String,String)] = [],rels:[(String,String,String)] = [],sheets = ""
        for (index,table) in tables.enumerated() {
            try Task.checkCancellation()
            guard table.cells.count <= 10000,table.columnCount <= 256,
                  table.cells.flatMap({$0}).reduce(0,{$0+$1.utf8.count}) <= 4_000_000 else { throw ScannerError.message("This table is too large to export.") }
            let n = index+1,path = "xl/worksheets/sheet\(n).xml"
            let rows = table.cells.enumerated().map { r,row in
                "<row r=\"\(r+1)\">" + row.enumerated().map { c,value in
                    "<c r=\"\(column(c))\(r+1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
                }.joined() + "</row>"
            }.joined()
            let merges = table.merges.filter { $0.row >= 0 && $0.column >= 0 && $0.rows > 0 && $0.columns > 0 && $0.row+$0.rows <= table.cells.count && $0.column+$0.columns <= table.columnCount }.map {
                "<mergeCell ref=\"\(column($0.column))\($0.row+1):\(column($0.column+$0.columns-1))\($0.row+$0.rows)\"/>"
            }.joined()
            let sheet = declaration+"<worksheet xmlns=\"\(ns)\"><sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><sheetFormatPr defaultColWidth=\"20\" defaultRowHeight=\"20\"/><sheetData>\(rows)</sheetData>\(merges.isEmpty ? "" : "<mergeCells>\(merges)</mergeCells>")</worksheet>"
            entries.append((path,Data(sheet.utf8)));types.append((path,"spreadsheetml.worksheet"));rels.append(("rId\(n)","worksheet","worksheets/sheet\(n).xml"))
            sheets += "<sheet name=\"Table \(n)\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
        }
        let workbook = declaration+"<workbook xmlns=\"\(ns)\" xmlns:r=\"\(officeNS)\"><sheets>\(sheets)</sheets></workbook>"
        entries += [("xl/workbook.xml",Data(workbook.utf8)),("xl/_rels/workbook.xml.rels",Data(relationships(rels).utf8))]
        types.append(("xl/workbook.xml","spreadsheetml.sheet.main"))
        return try package(entries,main:"xl/workbook.xml",types:types)
    }
}
