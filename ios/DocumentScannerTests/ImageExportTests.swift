import XCTest
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import DocumentScanner

final class ImageExportTests: XCTestCase {
    private func pdf(pages: Int) -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).pdfData { c in
            for i in 0..<pages {
                c.beginPage()
                ("PAGE \(i + 1)" as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 40)])
                UIColor.systemTeal.setFill(); c.fill(CGRect(x: 60, y: 200, width: 300, height: 120))
            }
        }
        return PDFDocument(data: data)!
    }

    func testEveryFormatWritesARealFileOfThatType() throws {
        let document = pdf(pages: 2)
        for format in ImageExportFormat.allCases where format.available {
            let files = try ExportFiles.images(document, indices: [0, 1], pixels: 800, format: format)
            defer { ExportFiles.remove(files.directory) }
            XCTAssertEqual(files.urls.count, 2, format.title)
            for url in files.urls {
                XCTAssertEqual(url.pathExtension, format.fileExtension)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), format.title)
                XCTAssertEqual(CGImageSourceGetType(source) as String?, format.type.identifier, format.title)
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(max(image.width, image.height), 800, accuracy: 2, format.title)
            }
        }
    }

    func testTIFFCanHoldAllPagesInOneFile() throws {
        let files = try ExportFiles.images(pdf(pages: 3), indices: [0, 1, 2], pixels: 600, format: .tiff, combined: true)
        defer { ExportFiles.remove(files.directory) }
        XCTAssertEqual(files.urls.count, 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(files.urls[0] as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
    }

    func testHEICIsSmallerThanPNG() throws {
        guard ImageExportFormat.heic.available else { throw XCTSkip("No HEIC encoder here.") }
        let document = pdf(pages: 1)
        func size(_ f: ImageExportFormat) throws -> Int {
            let files = try ExportFiles.images(document, indices: [0], pixels: 1600, format: f)
            defer { ExportFiles.remove(files.directory) }
            return try files.urls[0].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        XCTAssertLessThan(try size(.heic), try size(.png))
    }
}
