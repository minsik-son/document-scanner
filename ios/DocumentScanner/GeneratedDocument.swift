import PDFKit
import UIKit

extension LibraryStore {
    // Prepare all assets before committing the new library row. Cancel/failure never changes the input.
    func saveGeneratedPDF(_ data: Data, title: String, folder: String = "Scans") async throws -> UUID {
        guard let pdf = PDFDocument(data: data), !pdf.isLocked, (1...100).contains(pdf.pageCount) else { throw ScannerError.message("The generated PDF is invalid.") }
        var document = ScanDocument(title: title); document.folder = folder
        document.paper = .original; document.margin = .none
        let original = UUID().uuidString + ".pdf"
        var files: [URL] = []
        do {
            try data.write(to: url(original), options: [.atomic, .completeFileProtectionUnlessOpen]); files.append(url(original))
            for i in 0..<pdf.pageCount {
                try Task.checkCancellation()
                let result = try await OfflineWork.perform { () throws -> (Data, [TextBlock]) in
                    guard let input = PDFDocument(data: data), let page = input.page(at: i),
                          let bytes = page.thumbnail(of: CGSize(width: 1200, height: 1600), for: .mediaBox).jpegData(compressionQuality: 0.94) else { throw ScannerError.message("The PDF preview couldn't be created.") }
                    return (bytes, DocumentPDF.textBlocks(page))
                }
                let name = UUID().uuidString + ".jpg"
                try result.0.write(to: url(name), options: [.atomic, .completeFileProtectionUnlessOpen]); files.append(url(name))
                var page = ScanPage(imageFile: name)
                page.sourcePDF = original; page.sourcePDFPage = i; page.textBlocks = result.1
                page.ocrComplete = !result.1.isEmpty; page.ocrProcessingVersion = PDFExport.textProcessingVersion
                document.pages.append(page)
            }
            try Task.checkCancellation()
            document.searchable = document.pages.allSatisfy { !$0.textBlocks.isEmpty }
            try savePDF(data, document: document)
            return document.id
        } catch { for file in files { try? FileManager.default.removeItem(at: file) }; throw error }
    }
}
