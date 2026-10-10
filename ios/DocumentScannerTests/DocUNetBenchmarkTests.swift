import XCTest
import CoreImage
import UIKit
@testable import DocumentScanner

/// The DocUNet benchmark (Ma et al., CVPR 2018): 130 phone photos of curled,
/// folded and crumpled pages and a flatbed scan of each page. Only on the
/// developer Mac (research data, never committed). Writes results to
/// Verification/private/docunet; Verification/private/docunet/score.py scores them.
final class DocUNetBenchmarkTests: XCTestCase {
    private static let ios = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let out = ios.appendingPathComponent("Verification/private/docunet")
    private var data: URL? {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return nil }
        let url = URL(fileURLWithPath: home).appendingPathComponent("Documents/dev/Project/Test Documents")
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Original photos").path) ? url : nil
    }
    /// docunet/config.json: {"limit": n, "only": "1_1,2_2", "skipDone": true}
    private var config: [String: Any] {
        guard let d = try? Data(contentsOf: Self.out.appendingPathComponent("config.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }
    private func photos(_ data: URL) -> [URL] {
        let dir = data.appendingPathComponent("Original photos")
        var list = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        func key(_ u: URL) -> (Int, Int) {
            let p = u.deletingPathExtension().lastPathComponent.split(separator: "_").compactMap { Int($0) }
            return (p.first ?? 0, p.count > 1 ? p[1] : 0)
        }
        list.sort { key($0) < key($1) }
        if let only = config["only"] as? String { let s = Set(only.split(separator: ",").map(String.init)); list = list.filter { s.contains($0.deletingPathExtension().lastPathComponent) } }
        if let limit = config["limit"] as? Int { list = Array(list.prefix(limit)) }
        return list
    }
    private func ocr(_ image: UIImage) -> String {
        guard let cg = image.cgImage, let blocks = try? TextRecognition.recognize(cg) else { return "" }
        return blocks.map(\.text).joined(separator: "\n")
    }
    private func jpeg(_ image: UIImage, _ url: URL, maxSide: CGFloat = 2000) {
        let s = min(1, maxSide / max(image.size.width * image.scale, image.size.height * image.scale))
        var img = image
        if s < 1 {
            let size = CGSize(width: (image.size.width * image.scale * s).rounded(), height: (image.size.height * image.scale * s).rounded())
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
            img = UIGraphicsImageRenderer(size: size, format: f).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        try? img.jpegData(compressionQuality: 0.92)?.write(to: url)
    }
    private func cg(_ ci: CIImage) throws -> UIImage {
        UIImage(cgImage: try XCTUnwrap(DocumentProcessing.context.createCGImage(ci, from: ci.extent)))
    }
    private func write(_ json: Any, _ url: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
    }

    /// Goal 1: does the scan come out right? Crop found, page flattened, and the
    /// text readable, compared with the flatbed scan of the same page.
    func testScanQuality() throws {
        guard let data else { throw XCTSkip("DocUNet benchmark not on this Mac.") }
        let dir = Self.out.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let skipDone = config["skipDone"] as? Bool ?? true
        var gtText: [String: String] = [:]
        for url in photos(data) {
            let id = url.deletingPathExtension().lastPathComponent
            let resultURL = dir.appendingPathComponent("\(id).json")
            if skipDone, FileManager.default.fileExists(atPath: resultURL.path) { continue }
            try autoreleasepool {
                guard let raw = UIImage(contentsOfFile: url.path) else { return }
                let photo = Imaging.normalized(Imaging.limited(raw, maxPixels: 12_000_000))
                let source = CIImage(cgImage: try XCTUnwrap(photo.cgImage))
                var r: [String: Any] = ["id": id, "width": photo.size.width * photo.scale, "height": photo.size.height * photo.scale]
                // The crop the camera finds (rectangle, else the paper outline).
                var t = CFAbsoluteTimeGetCurrent()
                let rect = DocumentProcessing.detect(photo.cgImage!)
                let found = rect ?? PaperFlattener.findPage(photo.cgImage!)
                r["detectSeconds"] = CFAbsoluteTimeGetCurrent() - t
                r["crop"] = rect != nil ? "rectangle" : (found != nil ? "outline" : "none")
                let crop = found ?? .full
                r["quad"] = crop.points.flatMap { [$0.x, $0.y] }
                t = CFAbsoluteTimeGetCurrent()
                let mesh = crop == .full ? nil : PaperFlatten.analyze(source, crop: crop)
                r["flattenSeconds"] = CFAbsoluteTimeGetCurrent() - t
                r["flattened"] = mesh != nil
                func render(_ flat: Bool, _ tone: Enhancement) throws -> UIImage {
                    try cg(DocumentProcessing.render(source, crop: crop, turns: 0, enhancement: tone, flatten: flat && crop != .full ? FlattenRequest(key: nil) : nil))
                }
                let flatO = try render(true, .original), plainO = try render(false, .original)
                let flatD = mesh != nil ? try render(true, .document) : try render(false, .document)
                let plainD = try render(false, .document)
                jpeg(flatO, dir.appendingPathComponent("\(id)-flat.jpg"))
                jpeg(plainO, dir.appendingPathComponent("\(id)-plain.jpg"))
                jpeg(flatD, dir.appendingPathComponent("\(id)-flat-doc.jpg"))
                t = CFAbsoluteTimeGetCurrent()
                r["ocrFlat"] = ocr(flatD)
                r["ocrPlain"] = ocr(plainD)
                r["ocrSeconds"] = CFAbsoluteTimeGetCurrent() - t
                let page = String(id.split(separator: "_").first ?? "")
                if gtText[page] == nil {
                    let gtURL = dir.appendingPathComponent("gt-\(page).txt")
                    if let s = try? String(contentsOf: gtURL, encoding: .utf8) { gtText[page] = s }
                    else if let gt = UIImage(contentsOfFile: data.appendingPathComponent("Scans from a flatbed scanner/\(page).png").path) {
                        let s = ocr(Imaging.limited(gt, maxPixels: 12_000_000)); gtText[page] = s
                        try? s.write(to: gtURL, atomically: true, encoding: .utf8)
                    }
                }
                write(r, resultURL)
                print(String(format: "DOCUNET %@ crop=%@ flat=%@ %.2fs", id, r["crop"] as! String, mesh != nil ? "yes" : "no", r["flattenSeconds"] as! Double))
            }
        }
    }

    /// Goal 2: Word, Excel and PowerPoint from the scanned page (the app's scan →
    /// convert path) next to the same conversion of the flatbed scan.
    func testOfficeFidelity() throws {
        guard let data else { throw XCTSkip("DocUNet benchmark not on this Mac.") }
        let dir = Self.out.appendingPathComponent("office")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let skipDone = config["skipDone"] as? Bool ?? true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docunet-pages")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func convert(_ image: UIImage, _ name: String) -> [String: Any] {
            var r: [String: Any] = [:]
            let t = CFAbsoluteTimeGetCurrent()
            do {
                let layout = try OfficeLayoutPages.analyze(image)
                r["analyzeSeconds"] = CFAbsoluteTimeGetCurrent() - t
                try OfficeLayoutExport.word([layout], image: OfficeLayoutPages.missingPicture).write(to: dir.appendingPathComponent("\(name).docx"))
                try OfficeLayoutExport.excel([layout], image: OfficeLayoutPages.missingPicture).write(to: dir.appendingPathComponent("\(name).xlsx"))
                try OfficeLayoutExport.powerpoint([layout], theme: OfficeLayoutPages.theme(), image: OfficeLayoutPages.missingPicture).write(to: dir.appendingPathComponent("\(name).pptx"))
                var paragraphs = 0, tables: [[Int]] = []
                for item in layout.items {
                    switch item {
                    case .paragraph: paragraphs += 1
                    case .table(let tb): tables.append([tb.rowCount, tb.columnCount])
                    }
                }
                r["paragraphs"] = paragraphs; r["tables"] = tables; r["graphics"] = layout.graphics.count
                r["text"] = LayoutText.text([layout])
            } catch { r["error"] = error.localizedDescription }
            return r
        }
        var gtDone = Set<String>()
        for url in photos(data) {
            let id = url.deletingPathExtension().lastPathComponent
            let resultURL = dir.appendingPathComponent("\(id).json")
            if skipDone, FileManager.default.fileExists(atPath: resultURL.path) { continue }
            try autoreleasepool {
                guard let raw = UIImage(contentsOfFile: url.path) else { return }
                // The page as the app stores and renders it after a camera scan.
                let photo = Imaging.normalized(Imaging.limited(raw, maxPixels: 12_000_000))
                let file = "\(id).jpg"
                try XCTUnwrap(photo.jpegData(compressionQuality: 0.95)).write(to: root.appendingPathComponent(file))
                var page = ScanPage(imageFile: file)
                if let crop = Imaging.detectPage(photo), crop.valid { page.crop = crop }
                page.enhancement = .document
                page.flatten = true
                let rendered = try Imaging.render(page, root: root)
                jpeg(rendered, dir.appendingPathComponent("\(id)-page.jpg"))
                var r = convert(rendered, id)
                r["id"] = id
                write(r, resultURL)
                let pageNo = String(id.split(separator: "_").first ?? "")
                if !gtDone.contains(pageNo), !FileManager.default.fileExists(atPath: dir.appendingPathComponent("gt-\(pageNo).json").path),
                   let gt = UIImage(contentsOfFile: data.appendingPathComponent("Scans from a flatbed scanner/\(pageNo).png").path) {
                    var g = convert(Imaging.limited(gt, maxPixels: 12_000_000), "gt-\(pageNo)")
                    g["id"] = "gt-\(pageNo)"
                    write(g, dir.appendingPathComponent("gt-\(pageNo).json"))
                }
                gtDone.insert(pageNo)
                try? FileManager.default.removeItem(at: root.appendingPathComponent(file))
                print("DOCUNET-OFFICE \(id) paragraphs=\(r["paragraphs"] ?? "-") tables=\(r["tables"] ?? "-")")
            }
        }
    }

    /// Why no crop was found: every Vision candidate (document segmentation and
    /// rectangles) with its paper evidence, drawn on the photo.
    func testDetectionCandidates() throws {
        guard let data else { throw XCTSkip("DocUNet benchmark not on this Mac.") }
        let dir = Self.out.appendingPathComponent("detect")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ids = (config["detectIds"] as? String)?.split(separator: ",").map(String.init) ?? []
        var log: [String] = []
        for id in ids {
            guard let url = photosAll(data).first(where: { $0.deletingPathExtension().lastPathComponent == id }), let raw = UIImage(contentsOfFile: url.path) else { continue }
            let photo = Imaging.normalized(Imaging.limited(raw, maxPixels: 12_000_000))
            let cgPhoto = try XCTUnwrap(photo.cgImage)
            let cands = DocumentProcessing.candidates(cgPhoto)
            let W = CGFloat(cgPhoto.width), H = CGFloat(cgPhoto.height)
            let s = 900 / max(W, H)
            let size = CGSize(width: (W * s).rounded(), height: (H * s).rounded())
            let f = UIGraphicsImageRendererFormat(); f.scale = 1
            let img = UIGraphicsImageRenderer(size: size, format: f).image { ctx in
                photo.draw(in: CGRect(origin: .zero, size: size))
                for c in cands {
                    let path = UIBezierPath()
                    for (k, p) in c.quad.points.enumerated() {
                        let pt = CGPoint(x: p.x * size.width, y: p.y * size.height)
                        if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    path.close(); path.lineWidth = c.kind == .document ? 5 : 2
                    (c.accepted ? UIColor.green : (c.kind == .document ? UIColor.red : UIColor.orange)).setStroke(); path.stroke()
                }
            }
            try? img.jpegData(compressionQuality: 0.8)?.write(to: dir.appendingPathComponent("\(id).jpg"))
            for c in cands {
                log.append(String(format: "%@ %@ conf=%.2f interior=%.2f edge=%.2f strong=%d accepted=%@ area=%.2f", id, c.kind == .document ? "document" : "rect", c.confidence, c.interior, c.edge, c.strongEdges, c.accepted ? "Y" : "n", DocumentProcessing.area(c.quad)))
            }
            if cands.isEmpty { log.append("\(id) no candidates") }
        }
        try log.joined(separator: "\n").write(to: dir.appendingPathComponent("candidates.txt"), atomically: true, encoding: .utf8)
    }
    private func photosAll(_ data: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: data.appendingPathComponent("Original photos"), includingPropertiesForKeys: nil)) ?? [])
    }
}
