import UIKit
import CryptoKit
import PDFKit

/// Serial background rendering bounds GPU/memory pressure when many rows appear together.
/// Cache only the final, fully processed image; PDF/editor rendering stays unchanged.
actor PageThumbnailCache {
    static let shared = PageThumbnailCache()
    typealias Renderer = (ScanPage, URL) throws -> UIImage
    private let memory = NSCache<NSString, UIImage>()
    private let renderer: Renderer
    init(renderer: @escaping Renderer = { try Imaging.renderThumbnail($0, root: $1, maxDimension: 700) }) {
        self.renderer = renderer
        memory.totalCostLimit = 32 * 1024 * 1024
        memory.countLimit = 60
    }
    func image(for page: ScanPage, root: URL, pdfFile: String? = nil) throws -> UIImage {
        try Task.checkCancellation()
        var appearance = page
        appearance.textBlocks = []; appearance.ocrComplete = false
        appearance.ocrProcessingVersion = nil
        if appearance.identityBackgroundCleanup != true { appearance.cropReviewNeeded = nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(appearance)
        if page.identityBackgroundCleanup == true { data.append(Data("identity-edges-v2".utf8)) }
        let source = root.appendingPathComponent(pdfFile ?? page.imageFile)
        let attributes = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        // Not the library's absolute path: iOS moves the app's container on every
        // update or reinstall, which made every saved thumbnail miss and re-render
        // from the full-size scan at the next launch.
        data.append(Data("thumbnail-v5|\(pdfFile ?? page.imageFile)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(attributes.fileSize ?? 0)".utf8))
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        // In memory, the library folder keeps two libraries (UI-test sessions) apart.
        let memoryKey = root.path + "|" + key
        if let cached = memory.object(forKey: memoryKey as NSString) { return cached }
        let directory = root.appendingPathComponent("Thumbnails", isDirectory: true)
        let file = directory.appendingPathComponent(key + ".jpg")
        if let cached = UIImage(contentsOfFile: file.path)?.preparingForDisplay() {
            remember(cached, key: memoryKey); return cached
        }
        let thumbnail: UIImage = try autoreleasepool {
            try Task.checkCancellation()
            if let pdfFile, let pdfPage = PDFDocument(url: root.appendingPathComponent(pdfFile))?.page(at: 0) {
                return pdfPage.thumbnail(of: CGSize(width: 700, height: 700), for: .mediaBox)
            }
            let rendered = try renderer(page, root)
            return try Imaging.previewThumbnail(rendered, maxDimension: 700)
        }
        try Task.checkCancellation()
        remember(thumbnail, key: memoryKey)
        // Cache failure must never fail document access.
        if let bytes = thumbnail.jpegData(compressionQuality: 0.94) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
            var cacheDirectory = directory; try? cacheDirectory.setResourceValues(excluded)
            try? bytes.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        return thumbnail
    }
    private func remember(_ image: UIImage, key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        memory.setObject(image, forKey: key as NSString, cost: cost)
    }
}
