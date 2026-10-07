import XCTest
import UIKit
@testable import DocumentScanner

/// Runs the smart tools over a large private sample corpus (public datasets + synthetic
/// documents with ground truth) in Verification/private/samples/smart. Skipped when the
/// corpus isn't on this Mac. Results go to results/<id>.json next to the corpus and are
/// scored by Verification/private/samples/smart/score.py.
final class SmartToolsCorpusTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Verification/private/samples/smart")
    static let koreanSets: Set<String> = ["pii-kr", "bizcard-kr", "id-kr", "kr-docs", "form-kr"]
    static let profile = ["name": "Jordan Lee", "email": "jordan.lee@example.com", "phone": "604-555-0182", "address": "1200 Main Street",
                          "city": "Vancouver", "postal": "V6B 2T4", "company": "Northwind Studio"]

    private func manifest() throws -> [[String: Any]] {
        let url = Self.root.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("No private smart-tools corpus on this Mac.") }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return json?["items"] as? [[String: Any]] ?? []
    }
    private func cacheURL(_ file: String) -> URL {
        Self.root.appendingPathComponent("ocr").appendingPathComponent((file as NSString).lastPathComponent + ".json")
    }
    private func blocks(_ file: String) -> [TextBlock]? {
        guard let data = try? Data(contentsOf: cacheURL(file)) else { return nil }
        return try? JSONDecoder().decode([TextBlock].self, from: data)
    }
    private var stopRequested: Bool { FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("STOP").path) }

    /// Everything the smart tools produce for one item.
    private func evaluate(_ item: [String: Any], pages: [[TextBlock]]) -> [String: Any] {
        let files = item["files"] as? [String] ?? []
        var doc = ScanDocument(title: "Scan 2026-10-06")
        doc.createdAt = Date(timeIntervalSince1970: 1_791_000_000)
        doc.captureStyle = (item["style"] as? String) == "card" ? .card : .document
        doc.autoTitled = true
        doc.pages = pages.enumerated().map { i, b in var p = ScanPage(imageFile: files[i]); p.textBlocks = b; p.ocrComplete = true; return p }
        let kind = DocumentInsight.classify(doc)
        var r: [String: Any] = ["id": item["id"] ?? "", "kind": kind.rawValue, "title": DocumentInsight.suggestTitle(doc, kind: kind) ?? ""]
        r["redact"] = pages.map { page in Redaction.boxes(in: page).map { ["kind": $0.kind, "rect": [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height]] } }
        r["redactText"] = pages.map { page in page.flatMap { b in Redaction.matches(b.text, context: Redaction.rowContext(b, in: page)).map { m in ["kind": m.0, "text": (b.text as NSString).substring(with: m.1)] } } }
        if item["card"] != nil {
            let f = DocumentInsight.cardFields(doc)
            r["card"] = ["name": f.name, "organization": f.organization, "jobTitle": f.jobTitle, "phones": f.phones, "emails": f.emails, "urls": f.urls, "address": f.address]
        }
        if item["form"] != nil, let first = pages.first {
            let image = UIImage(contentsOfFile: Self.root.appendingPathComponent(files[0]).path)?.cgImage
            r["form"] = FormProfile.place(blocks: first, profile: Self.profile, image: image).map { ["key": $0.key, "rect": [$0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height]] }
        }
        r["text"] = String(doc.text.prefix(800))
        return r
    }
    private func write(_ result: [String: Any], dir: String) {
        let url = Self.root.appendingPathComponent(dir).appendingPathComponent("\(result["id"] ?? "x").json")
        if let data = try? JSONSerialization.data(withJSONObject: result) { try? data.write(to: url) }
    }

    /// Step 1: OCR every page once (the app's recognizer, limited to the Latin or Korean
    /// pass the sample needs) and save each item's results as soon as its pages are read.
    func test1RecognizeCorpus() throws {
        let items = try manifest()
        for dir in ["ocr", "results"] { try FileManager.default.createDirectory(at: Self.root.appendingPathComponent(dir), withIntermediateDirectories: true) }
        let lock = NSLock(); var done = 0, failed = 0
        let started = Date()
        for korean in [true, false] {
            // Korean samples get both the Korean and the Latin pass, as in the app (emails and numbers come from the Latin pass).
            TextRecognition.passFilter = korean ? { $0.first?.hasPrefix("ko") == true || $0.contains("fr-FR") } : { $0.contains("fr-FR") }
            let todo = items.filter { Self.koreanSets.contains($0["set"] as? String ?? "") == korean }
            DispatchQueue.concurrentPerform(iterations: todo.count) { i in
                autoreleasepool {
                    if stopRequested { return }
                    let item = todo[i], files = item["files"] as? [String] ?? []
                    var pages: [[TextBlock]] = []
                    for file in files {
                        if let cached = blocks(file) { pages.append(cached); continue }
                        guard let image = UIImage(contentsOfFile: Self.root.appendingPathComponent(file).path),
                              let found = try? Imaging.recognize(image), let data = try? JSONEncoder().encode(found) else { lock.lock(); failed += 1; lock.unlock(); return }
                        try? data.write(to: cacheURL(file)); pages.append(found)
                    }
                    let result = evaluate(item, pages: pages)
                    lock.lock(); write(result, dir: "results"); done += 1; let n = done; lock.unlock()
                    if n % 50 == 0 { print("SMART \(n)/\(items.count) \(Int(Date().timeIntervalSince(started)))s") }
                }
            }
        }
        TextRecognition.passFilter = nil
        print("SMART OCR finished \(done) items, \(failed) failed, \(Int(Date().timeIntervalSince(started)))s")
        XCTAssertEqual(failed, 0)
    }

    /// Step 2: re-run the smart tools on the cached OCR only (fast; use after changing the logic).
    func test2EvaluateCorpus() throws {
        let items = try manifest()
        try FileManager.default.createDirectory(at: Self.root.appendingPathComponent("results2"), withIntermediateDirectories: true)
        var n = 0
        for item in items {
            let files = item["files"] as? [String] ?? []
            let pages = files.compactMap { blocks($0) }
            guard pages.count == files.count, !files.isEmpty else { continue }
            write(evaluate(item, pages: pages), dir: "results2"); n += 1
        }
        print("SMART EVAL wrote \(n) of \(items.count)")
    }
}
