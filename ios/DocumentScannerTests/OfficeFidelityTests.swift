import XCTest
import UIKit
import Vision
@testable import DocumentScanner

/// Photo → Word / Excel / PowerPoint, the way the Office tools run it, over the
/// samples in Verification/private/samples/fidelity/manifest.json. Each item's
/// three files and its layout go to fidelity/out/<id>.*; fidelity/score.py checks
/// them against the item's answer key (cell text, spans, fills, the table's place
/// on the page). FIDELITY_ONLY=<id,id> limits the run. Skipped without samples.
final class OfficeFidelityTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Verification/private/samples/fidelity")

    private func describe(_ page: PageLayout) -> [String: Any] {
        let w = Double(max(page.width, 1)), h = Double(max(page.height, 1))
        func box(_ b: LBox) -> [Double] { [b.x0 / w, b.y0 / h, b.width / w, b.height / h].map { ($0 * 10000).rounded() / 10000 } }
        var items: [[String: Any]] = []
        for item in page.items {
            switch item {
            case .paragraph(let p):
                items.append(["type": "p", "text": p.lines.map(\.text).joined(separator: "\n"), "box": box(p.box), "size": p.fontSize])
            case .table(let t):
                items.append(["type": "t", "box": box(t.box), "rows": t.rowCount, "cols": t.columnCount, "ruled": t.ruled, "colsX": t.columns.map { Int($0) }, "rowsY": t.rows.map { Int($0) },
                              "cells": t.cells.map { ["r": $0.row, "c": $0.column, "rs": $0.rowSpan, "cs": $0.columnSpan, "text": $0.text,
                                                      "fill": $0.fill?.hex ?? "", "align": $0.alignment.rawValue] }])
            }
        }
        return ["items": items, "graphics": page.graphics.count, "positioned": page.positioned, "width": page.width, "height": page.height,
                "pageWidth": page.pageWidth, "pageHeight": page.pageHeight]
    }

    func testPhotosRebuildAsOfficeFiles() throws {
        let manifest = Self.root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]], !items.isEmpty else { throw XCTSkip("No fidelity samples on this Mac.") }
        let tag = ProcessInfo.processInfo.environment["FIDELITY_TONE"] ?? (try? String(contentsOf: Self.root.appendingPathComponent("tone.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tag, let tone = Enhancement(rawValue: tag) { OfficeLayoutPages.flattenTone = tone }
        defer { OfficeLayoutPages.flattenTone = .document }
        TextRecognition.keepsUncoveredWords = !FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("nouncovered").path)
        defer { TextRecognition.keepsUncoveredWords = true }
        DocumentLayoutAnalyzer.readsDarkFills = !FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("nodarkfill").path)
        defer { DocumentLayoutAnalyzer.readsDarkFills = true }
        DocumentLayoutAnalyzer.hollowsSolidAreas = !FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("nohollow").path)
        defer { DocumentLayoutAnalyzer.hollowsSolidAreas = true }
        let refine = !FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("norefine").path)
        OfficeLayoutPages.refineCells = refine
        defer { OfficeLayoutPages.refineCells = true }
        let onlyFile = (try? String(contentsOf: Self.root.appendingPathComponent("only.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let only = (ProcessInfo.processInfo.environment["FIDELITY_ONLY"] ?? onlyFile.flatMap { $0.isEmpty ? nil : $0 }).map { Set($0.split(separator: ",").map(String.init)) }
        let out = Self.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for item in items {
            guard let id = item["id"] as? String, let file = item["file"] as? String else { continue }
            if let only, !only.contains(id) { continue }
            guard let image = UIImage(contentsOfFile: Self.root.appendingPathComponent(file).path) else { XCTFail("\(id): image missing"); continue }
            let started = Date()
            if let cg = Imaging.normalized(image).cgImage {
                for c in DocumentProcessing.candidates(cg) {
                    print("FIDELITY-CAND \(id) \(c.kind) conf=\(c.confidence) interior=\(String(format: "%.2f", c.interior)) edge=\(String(format: "%.2f", c.edge)) strong=\(c.strongEdges) accepted=\(c.accepted) area=\(String(format: "%.2f", DocumentProcessing.area(c.quad))) quad=\(c.quad.points.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) }.joined())")
                }
                DocumentProcessing.debugLog = { print("FIDELITY-SHEET \(id) \($0)") }
                let quad = DocumentProcessing.detect(cg) ?? DocumentProcessing.detectSheetFromContent(cg)
                DocumentProcessing.debugLog = nil
                print("FIDELITY-QUAD \(id) \(quad.map { $0.points.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) }.joined() } ?? "nil") background=\(quad.map { OfficeLayoutPages.hasBackground(around: $0, in: cg) } ?? false)")
            }
            // The flattened page the layout is read from, for checking page finding.
            if let flat = try? OfficeLayoutPages.flattenedIfPhoto(image), let jpeg = flat.jpegData(compressionQuality: 0.7) {
                try? jpeg.write(to: out.appendingPathComponent(id + ".flat.jpg"))
            }
            if FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("visionprobe").path),
               let flat = try? OfficeLayoutPages.flattenedIfPhoto(image) {
                for (label, img) in [("photo", image), ("flat", flat), ("flat2x", OfficeLayoutPages.resized(flat, aspect: Double(flat.size.height / flat.size.width)))] {
                    var source = img
                    if label == "flat2x" {
                        let size = CGSize(width: flat.size.width * 2, height: flat.size.height * 2)
                        let f = UIGraphicsImageRendererFormat(); f.scale = 1
                        source = UIGraphicsImageRenderer(size: size, format: f).image { _ in flat.draw(in: CGRect(origin: .zero, size: size)) }
                    }
                    guard let cg = try? OfficeLayoutPages.prepare(source, maxSide: 4000).image else { continue }
                    let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate; r.recognitionLanguages = ["ko-KR", "en-US"]
                    try? VNImageRequestHandler(cgImage: cg).perform([r])
                    print("FIDELITY-VISION \(id) \(label) \(cg.width)x\(cg.height) n=\(r.results?.count ?? 0): " + (r.results ?? []).prefix(12).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | "))
                }
            }
            var fillLines: [String] = []
            DocumentLayoutAnalyzer.debugLog = { fillLines.append($0) }; TextRecognition.log = { fillLines.append($0) }
            defer { DocumentLayoutAnalyzer.debugLog = nil }
            let page = try OfficeLayoutPages.analyze(image)
            try? fillLines.joined(separator: "\n").write(to: out.appendingPathComponent(id + ".fills.txt"), atomically: true, encoding: .utf8)
            var result = describe(page)
            result["seconds"] = Date().timeIntervalSince(started)
            let base = out.appendingPathComponent(id)
            try OfficeLayoutExport.word([page], image: OfficeLayoutPages.missingPicture).write(to: base.appendingPathExtension("docx"))
            try OfficeLayoutExport.excel([page], image: OfficeLayoutPages.missingPicture).write(to: base.appendingPathExtension("xlsx"))
            try OfficeLayoutExport.powerpoint([page], theme: OfficeLayoutPages.theme(), image: OfficeLayoutPages.missingPicture).write(to: base.appendingPathExtension("pptx"))
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: base.appendingPathExtension("json"))
            print("FIDELITY \(id) \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
    }
}
