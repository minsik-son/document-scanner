import XCTest
import UIKit
@testable import DocumentScanner

/// Runs the Convert & read tools (Word / Excel / PowerPoint rebuild, Math scan,
/// Photo translation) over the private test corpus in
/// Verification/private/samples/convert/<set>/manifest.json — synthetic pages with
/// exact ground truth plus public datasets and real scans. Skipped when the corpus
/// isn't on this Mac. One JSON result per item goes to convert/results/<set>/<id>.json
/// and is scored by convert/tools/score.py. Resumable: items with a result are skipped
/// unless CONVERT_RERUN is set; create convert/STOP to stop early.
/// Environment: CONVERT_SETS=syn,pub,real (default all), CONVERT_KINDS=office,math…,
/// CONVERT_LIMIT=n per set, CONVERT_SAVE=n office files kept per set for inspection.
final class ConvertCorpusTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Verification/private/samples/convert")
    /// Settings from the environment, overridden by convert/config.json (handy when
    /// the test is started from Xcode): sets, kinds, limit, stride, save, rerun, refine.
    private var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        if let data = try? Data(contentsOf: Self.root.appendingPathComponent("config.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in json { e["CONVERT_" + k.uppercased()] = "\(v)" }
        }
        return e
    }
    private var stopRequested: Bool { FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("STOP").path) }

    private func items(_ set: String) -> [[String: Any]] {
        let url = Self.root.appendingPathComponent(set).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return json["items"] as? [[String: Any]] ?? []
    }

    // MARK: Office files → text, without leaving the test (stored ZIP from LocalZIP).
    private func entries(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        var offset = 0
        func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        while offset + 30 <= data.count, u32(offset) == 0x04034b50 {
            let size = u32(offset + 18), nameLength = u16(offset + 26), extra = u16(offset + 28)
            guard offset + 30 + nameLength + extra + size <= data.count else { break }
            let name = String(decoding: data[(data.startIndex + offset + 30)..<(data.startIndex + offset + 30 + nameLength)], as: UTF8.self)
            let start = data.startIndex + offset + 30 + nameLength + extra
            if name.hasSuffix(".xml") || name.hasSuffix(".rels") { result[name] = String(decoding: data[start..<(start + size)], as: UTF8.self) }
            offset = offset + 30 + nameLength + extra + size
        }
        return result
    }
    private static let wordText = try! NSRegularExpression(pattern: "<w:t(?: [^>]*)?>([^<]*)</w:t>|<w:p[ >]|<w:tab/>|<w:br/>")
    private static let drawingText = try! NSRegularExpression(pattern: "<a:t>([^<]*)</a:t>|<a:p>|<a:br/>|<a:br>")
    private static let sheetCell = try! NSRegularExpression(pattern: "<c r=\"([A-Z]+[0-9]+)\"[^>]*?(?:/>|>(.*?)</c>)", options: [.dotMatchesLineSeparators])
    private static let inline = try! NSRegularExpression(pattern: "<t(?: [^>]*)?>([^<]*)</t>")
    private func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
    private func text(_ xml: String, _ regex: NSRegularExpression) -> String {
        var out = ""
        let ns = xml as NSString
        for m in regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range)
            if m.range(at: 1).location != NSNotFound { out += unescape(ns.substring(with: m.range(at: 1))) }
            else if token.hasPrefix("<w:tab") { out += "\t" }
            else { out += "\n" }
        }
        return out.replacingOccurrences(of: "\n+", with: "\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func xmlErrors(_ parts: [String: String]) -> [String] {
        parts.compactMap { name, xml in
            let parser = XMLParser(data: Data(xml.utf8))
            return parser.parse() ? nil : "\(name): \(parser.parserError?.localizedDescription ?? "?")"
        }.sorted()
    }
    private func sheetCells(_ parts: [String: String]) -> [String: String] {
        var shared: [String] = []
        if let sst = parts["xl/sharedStrings.xml"] {
            let ns = sst as NSString
            shared = sst.components(separatedBy: "<si>").dropFirst().map { si in
                let s = si as NSString
                return Self.inline.matches(in: si, range: NSRange(location: 0, length: s.length)).map { unescape(s.substring(with: $0.range(at: 1))) }.joined()
            }
            _ = ns
        }
        var cells: [String: String] = [:]
        for (name, xml) in parts where name.hasPrefix("xl/worksheets/sheet") {
            let ns = xml as NSString, prefix = name == "xl/worksheets/sheet1.xml" ? "" : (name as NSString).lastPathComponent + "!"
            for m in Self.sheetCell.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
                let ref = ns.substring(with: m.range(at: 1))
                guard m.range(at: 2).location != NSNotFound else { continue }
                let body = ns.substring(with: m.range(at: 2)), whole = ns.substring(with: m.range)
                let b = body as NSString
                if whole.contains("t=\"s\""), let v = body.range(of: "<v>(\\d+)</v>", options: .regularExpression) {
                    let index = Int(body[v].dropFirst(3).dropLast(4)) ?? -1
                    if shared.indices.contains(index) { cells[prefix + ref] = shared[index] }
                } else if body.contains("<t") {
                    cells[prefix + ref] = Self.inline.matches(in: body, range: NSRange(location: 0, length: b.length)).map { unescape(b.substring(with: $0.range(at: 1))) }.joined()
                } else if let v = body.range(of: "<v>([^<]*)</v>", options: .regularExpression) {
                    cells[prefix + ref] = String(body[v].dropFirst(3).dropLast(4))
                }
            }
        }
        return cells
    }

    // MARK: Layout → JSON for the scorer
    private func box(_ b: LBox, _ page: PageLayout) -> [Double] {
        let w = Double(max(page.width, 1)), h = Double(max(page.height, 1))
        return [b.x0 / w, b.y0 / h, b.width / w, b.height / h].map { ($0 * 10000).rounded() / 10000 }
    }
    private func describe(_ page: PageLayout) -> [String: Any] {
        var items: [[String: Any]] = []
        for item in page.items {
            switch item {
            case .paragraph(let p):
                items.append(["type": "p", "text": p.lines.map(\.text).joined(separator: "\n"), "box": box(p.box, page), "size": p.fontSize,
                              "align": p.alignment.rawValue, "bullet": p.bullet != nil, "marker": p.marker ?? "",
                              "bold": p.lines.flatMap { $0.segments.flatMap(\.runs) }.contains { $0.bold },
                              "boldShare": { let r = p.lines.flatMap { $0.segments.flatMap(\.runs) }; let n = r.reduce(0) { $0 + $1.text.count }; return n == 0 ? 0 : Double(r.filter(\.bold).reduce(0) { $0 + $1.text.count }) / Double(n) }()])
            case .table(let t):
                items.append(["type": "t", "box": box(t.box, page), "rows": t.rowCount, "cols": t.columnCount, "ruled": t.ruled,
                              "cells": t.cells.map { ["r": $0.row, "c": $0.column, "rs": $0.rowSpan, "cs": $0.columnSpan, "text": $0.text,
                                                      "fill": $0.fill?.hex ?? "", "align": $0.alignment.rawValue] }])
            }
        }
        return ["items": items, "graphics": page.graphics.count, "positioned": page.positioned, "form": page.form, "columns": page.columns ?? [], "width": page.width, "height": page.height]
    }

    // MARK: Per kind
    private func office(_ image: UIImage, slides: Bool, save: URL?) throws -> [String: Any] {
        var r: [String: Any] = [:]
        var t = Date()
        let page = try OfficeLayoutPages.analyze(image)
        r["analyzeSeconds"] = Date().timeIntervalSince(t)
        r["layout"] = describe(page)
        t = Date()
        var problems: [String] = []
        func run(_ name: String, _ make: () throws -> Data) -> [String: String]? {
            do {
                let data = try make()
                if let save { try? data.write(to: save.appendingPathExtension(name)) }
                let parts = entries(data)
                problems += xmlErrors(parts).map { "\(name) \($0)" }
                if parts.isEmpty { problems.append("\(name): empty package") }
                return parts
            } catch { problems.append("\(name) failed: \(error.localizedDescription)"); return nil }
        }
        if let docx = run("docx", { try OfficeLayoutExport.word([page], image: OfficeLayoutPages.missingPicture) }) {
            r["docxText"] = text(docx["word/document.xml"] ?? "", Self.wordText)
        }
        if let xlsx = run("xlsx", { try OfficeLayoutExport.excel([page], image: OfficeLayoutPages.missingPicture) }) {
            r["xlsxCells"] = sheetCells(xlsx)
        }
        if let pptx = run("pptx", { try OfficeLayoutExport.powerpoint([page], theme: OfficeLayoutPages.theme(), image: OfficeLayoutPages.missingPicture) }) {
            r["pptxText"] = pptx.filter { $0.key.hasPrefix("ppt/slides/slide") }.sorted { $0.key < $1.key }.map { text($0.value, Self.drawingText) }.joined(separator: "\n")
        }
        r["exportSeconds"] = Date().timeIntervalSince(t)
        r["exportProblems"] = problems
        _ = slides
        return r
    }
    private func math(_ image: UIImage) throws -> [String: Any] {
        let scan = try MathDocumentEngine.prepare(image)
        let text = try MathDocumentEngine.recognize(scan.image)
        var lines: [[String: Any]] = []
        for line in LocalMath.numbered(text.split(separator: "\n").map(String.init)) {
            // What the app's Calculate does with each line of the reading.
            let expr = LocalMath.expression(line)
            var entry: [String: Any] = ["text": line, "expr": expr ?? ""]
            if let expr, let v = try? LocalMath.evaluate(expr) { entry["value"] = v } else { entry["error"] = true }
            lines.append(entry)
        }
        if let solved = try? LocalMath.solve(text) { lines.append(["solve": solved]) }
        var exports: [String] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for format in MathDocumentEngine.Format.allCases {
                do { let d = try MathDocumentEngine.export(text, format: format, reference: scan.image); if d.isEmpty { exports.append("\(format.rawValue): empty") } }
                catch { exports.append("\(format.rawValue): \(error.localizedDescription)") }
            }
        }
        return ["text": text, "lines": lines, "detected": scan.detected, "exportProblems": exports]
    }
    private func evaluateTruth(_ gt: [String: Any]) -> [[String: Any]] {
        // The calculator itself, on the exact expressions (no OCR involved).
        (gt["math"] as? [[String: Any]] ?? []).map { line in
            let shown = line["text"] as? String ?? ""
            var r: [String: Any] = ["shown": shown]
            if let e = LocalMath.expression(shown), let v = try? LocalMath.evaluate(e) { r["value"] = v } else { r["error"] = true }
            if let expr = line["expr"] as? String { r["exprValue"] = (try? LocalMath.evaluate(expr)) ?? NSNull() }
            return r
        }
    }
    private func translate(_ image: UIImage, lang: String) throws -> [String: Any] {
        let target = ["en", "fr", "de", "es", "it", "pt", "pt-BR"].contains(lang) ? "ko" : "en"
        let scan = try PhotoTranslation.scan(image, sourceLanguage: lang == "pt-BR" ? "pt" : lang, targetLanguage: target)
        var regions = scan.regions
        for i in regions.indices where !regions[i].keepOriginal {
            let n = regions[i].source.count
            // Stand-in translations of a realistic length (Korean shorter, English longer).
            regions[i].target = target == "ko"
                ? Array(repeating: "번역된 문장", count: max(1, n / 9)).joined(separator: " ")
                : Array(repeating: "translated text", count: max(1, n / 5)).joined(separator: " ")
        }
        let composed = try PhotoTranslation.compose(scan.image, regions: regions)
        return ["regions": scan.regions.map { ["text": $0.source, "box": [$0.box.minX, $0.box.minY, $0.box.width, $0.box.height],
                                               "keep": $0.keepOriginal, "unclear": $0.unclear, "marker": $0.isMarker] },
                "edges": scan.edgesDetected, "replaced": composed.replaced, "kept": composed.kept, "unchanged": composed.unchanged,
                "issues": composed.issues.count, "reasons": Dictionary(grouping: composed.reasons.values, by: \.rawValue).mapValues(\.count), "unclear": composed.unclear, "notice": scan.notice ?? ""]
    }

    static func script(_ lang: String) -> String {
        for p in ["ko", "ja", "zh-Hans", "zh-Hant", "th", "ru", "ar"] where lang.hasPrefix(p) { return p }
        return "latin"
    }
    static func passFilter(_ script: String) -> ([String]) -> Bool {
        { pass in
            let latin = pass.contains("de-DE") || pass.contains("fr-FR")
            if script == "latin" { return latin }
            return latin || pass.first?.hasPrefix(script) == true
        }
    }

    // MARK: Run
    func testConvertCorpus() throws {
        let sets = (env["CONVERT_SETS"] ?? "syn,pub,real").split(separator: ",").map(String.init)
        let kinds = env["CONVERT_KINDS"].map { Set($0.split(separator: ",").map(String.init)) }
        let limit = Int(env["CONVERT_LIMIT"] ?? "") ?? Int.max
        let keep = Int(env["CONVERT_SAVE"] ?? "") ?? 2
        let rerun = ["1", "true"].contains(env["CONVERT_RERUN"] ?? "")
        let stride = max(1, Int(env["CONVERT_STRIDE"] ?? "") ?? 1)
        // Re-reading every cell and line is most of the analysis time; a first broad
        // pass can leave it off and a smaller pass checks it.
        let refine = env["CONVERT_REFINE"].map { $0 != "0" && $0 != "false" } ?? true
        OfficeLayoutPages.refineCells = refine
        defer { OfficeLayoutPages.refineCells = true }
        let byScript = env["CONVERT_PASSES"] == "lang"
        // CONVERT_BASELINE=1 turns the newer layout fixes off for before/after runs.
        let baseline = ["1", "true"].contains(env["CONVERT_BASELINE"] ?? "")
        DocumentLayoutAnalyzer.detectsColumns = !baseline; DocumentLayoutAnalyzer.keepsRecognizedLines = !baseline; DocumentLayoutAnalyzer.splitsAlignedColumns = !baseline
        defer { DocumentLayoutAnalyzer.detectsColumns = true; DocumentLayoutAnalyzer.keepsRecognizedLines = true; DocumentLayoutAnalyzer.splitsAlignedColumns = true }
        // Switches for the photo-to-Office fidelity work (all on in the app): CONVERT_OFF=hollow,uncovered,darkfill,original
        let off = Set((env["CONVERT_OFF"] ?? "").split(separator: ",").map(String.init))
        DocumentLayoutAnalyzer.hollowsSolidAreas = !off.contains("hollow")
        TextRecognition.keepsUncoveredWords = !off.contains("uncovered")
        DocumentLayoutAnalyzer.readsDarkFills = !off.contains("darkfill")
        OfficeLayoutPages.readsOriginalTone = !off.contains("original")
        defer { DocumentLayoutAnalyzer.hollowsSolidAreas = true; TextRecognition.keepsUncoveredWords = true; DocumentLayoutAnalyzer.readsDarkFills = true; OfficeLayoutPages.readsOriginalTone = true }
        var total = 0
        for set in sets {
            var todo = items(set).filter { kinds?.contains($0["kind"] as? String ?? "") ?? true }
            todo = todo.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
            if todo.count > limit { todo = Array(todo.prefix(limit)) }
            guard !todo.isEmpty else { continue }
            let out = Self.root.appendingPathComponent((refine ? "results" : "results-fast") + (byScript ? "-lang" : "") + (baseline ? "-base" : "") + (env["CONVERT_TAG"].map { "-" + $0 } ?? "")).appendingPathComponent(set)
            let saved = Self.root.appendingPathComponent("files").appendingPathComponent(set)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
            let lock = NSLock(); var done = 0, failed = 0, savedCount: [String: Int] = [:]
            let started = Date()
            // CONVERT_PASSES=lang: read each page with only its own script model plus
            // Latin (pages are grouped by script); the app runs every model.
            let groups: [(String, [Int])] = byScript
                ? Dictionary(grouping: todo.indices, by: { Self.script(todo[$0]["lang"] as? String ?? "en") }).map { ($0.key, $0.value) }
                : [("all", Array(todo.indices))]
            for (group, indices) in groups {
            TextRecognition.passFilter = byScript ? Self.passFilter(group) : nil
            DispatchQueue.concurrentPerform(iterations: indices.count) { k in
                let i = indices[k]
                autoreleasepool {
                    if stopRequested { return }
                    let item = todo[i]
                    let id = item["id"] as? String ?? "item\(i)", kind = item["kind"] as? String ?? "office"
                    let file = out.appendingPathComponent(id + ".json")
                    if !rerun, FileManager.default.fileExists(atPath: file.path) { return }
                    let path = Self.root.appendingPathComponent(set).appendingPathComponent((item["files"] as? [String])?.first ?? "")
                    var result: [String: Any] = ["id": id, "set": item["set"] ?? set, "kind": kind]
                    let t = Date()
                    do {
                        guard let image = UIImage(contentsOfFile: path.path) else { throw ScannerError.message("image missing") }
                        result["imageSize"] = [image.size.width * image.scale, image.size.height * image.scale]
                        switch kind {
                        case "math":
                            result.merge(try math(image)) { $1 }
                            result["truth"] = evaluateTruth(item["gt"] as? [String: Any] ?? [:])
                        case "translate":
                            result.merge(try translate(image, lang: item["lang"] as? String ?? "en")) { $1 }
                        default:
                            lock.lock(); let tag = (item["set"] as? String ?? set); let n = savedCount[tag, default: 0]; savedCount[tag] = n + 1; lock.unlock()
                            result.merge(try office(image, slides: kind == "slides", save: n < keep ? saved.appendingPathComponent(id) : nil)) { $1 }
                        }
                        result["ok"] = true
                    } catch {
                        result["ok"] = false; result["error"] = error.localizedDescription
                        lock.lock(); failed += 1; lock.unlock()
                    }
                    result["seconds"] = Date().timeIntervalSince(t)
                    if let data = try? JSONSerialization.data(withJSONObject: result) { try? data.write(to: file) }
                    lock.lock(); done += 1; let n = done; lock.unlock()
                    if n % 50 == 0 { print("CONVERT \(set) \(n)/\(todo.count) \(Int(Date().timeIntervalSince(started)))s") }
                }
            }
            }
            TextRecognition.passFilter = nil
            print("CONVERT \(set) finished \(done) new, \(failed) failed, \(Int(Date().timeIntervalSince(started)))s")
            total += done
        }
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent("STOP"))
        if total == 0 && sets.allSatisfy({ items($0).isEmpty }) { throw XCTSkip("No convert corpus on this Mac.") }
    }
}
