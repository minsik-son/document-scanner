import Foundation
import CryptoKit
import PDFKit

// Preparing a PDF never modifies the library. The enriched metadata and PDF are
// committed together by LibraryStore.savePDF only after the full export succeeds.
@MainActor
enum PDFExport {
    static let textProcessingVersion = 7

    struct Result {
        var document: ScanDocument
        var data: Data
        var failedTextPages: [Int]

        var textNotice: String? {
            if !failedTextPages.isEmpty {
                let pages = failedTextPages.map(String.init).joined(separator: ", ")
                return "Your PDF is saved. Text recognition couldn't finish on pages \(pages). You can retry without taking new photos."
            }
            if !document.searchable { return "No text was detected. Your scan is saved as an image PDF." }
            return nil
        }
    }

    static func prepare(_ document: ScanDocument, root: URL, forceText: Bool = false,
                        progress: (String) -> Void = { _ in }) async throws -> Result {
        guard !document.pages.isEmpty else { throw ScannerError.message("Add at least one page before saving.") }
        var output = document
        var failed: [Int] = []
        for index in output.pages.indices {
            try Task.checkCancellation()
            let page = output.pages[index]
            if page.preservesPDF, let file = page.sourcePDF, let number = page.sourcePDFPage,
               let nativePDF = PDFDocument(url: root.appendingPathComponent(file)), let native = nativePDF.page(at: number) {
                let blocks = try withExtendedLifetime(nativePDF) {
                    let copy = native.copy() as? PDFPage ?? native
                    copy.rotation = (copy.rotation + page.turns*90) % 360
                    return try DocumentPDF.textBlocks(DocumentPDF.trimPage(copy,edges:page.trimming))
                }
                if !blocks.isEmpty {
                    output.pages[index].textBlocks = blocks; output.pages[index].ocrComplete = true
                    output.pages[index].ocrProcessingVersion = textProcessingVersion; continue
                }
            }
            guard (forceText && page.correctedText != true) || !page.ocrComplete || page.ocrProcessingVersion != textProcessingVersion else { continue }
            progress("Reading text on page \(index + 1) of \(output.pages.count)…")
            // Image errors must fail the export. OCR errors may still produce an
            // image PDF, with a visible retry notice instead of a false success.
            let key = try cacheKey(page)
            var cacheFolder = root.appendingPathComponent("OCRCache", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try? cacheFolder.setResourceValues(values)
            let cacheURL = cacheFolder.appendingPathComponent(page.id.uuidString + "-" + key + ".json")
            let cached = !forceText ? (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([TextBlock].self, from: $0) } : nil
            let blocks: [TextBlock]?
            if let cached { blocks = cached }
            else { blocks = try await Task.detached(priority: .userInitiated) { () throws -> [TextBlock]? in
                let image = try Imaging.render(page, root: root)
                do { return try Imaging.recognize(image) }
                catch { return nil }
            }.value
                if let blocks { try? JSONEncoder().encode(blocks).write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen]) }
            }
            try Task.checkCancellation()
            let validExistingText = page.ocrComplete && page.ocrProcessingVersion == textProcessingVersion
            if blocks != nil || !validExistingText {
                output.pages[index].textBlocks = RedactionGeometry.scrub(blocks ?? [], boxes: page.redactionBoxes)
                output.pages[index].ocrComplete = blocks != nil
                output.pages[index].ocrProcessingVersion = blocks == nil ? nil : textProcessingVersion
            }
            if blocks == nil { failed.append(index + 1) }
        }
        try Task.checkCancellation()
        output.searchable = output.pages.contains { $0.ocrComplete && !$0.textBlocks.isEmpty }
        progress("Saving PDF…")
        let snapshot = output
        let data = try await Task.detached(priority: .userInitiated) { try Imaging.pdf(snapshot, root: root) }.value
        try Task.checkCancellation()
        return Result(document: output, data: data, failedTextPages: failed)
    }
    private static func cacheKey(_ value: ScanPage) throws -> String {
        var page = value
        page.textBlocks = []; page.ocrComplete = false; page.ocrProcessingVersion = textProcessingVersion; page.annotations = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(page)).map { String(format: "%02x", $0) }.joined()
    }

}
