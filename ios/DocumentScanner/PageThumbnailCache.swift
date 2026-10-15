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
    /// One page shown big (the save step's preview): tone and lines worked out on a
    /// 2800 px copy and kept at 1400 px, so thin table lines stay whole. Only a few are
    /// kept in memory; small list thumbnails are unaffected.
    private let large: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.countLimit = 3; return c }()
    func largeImage(for page: ScanPage, root: URL) throws -> UIImage {
        try Task.checkCancellation()
        var appearance = page
        appearance.textBlocks = []; appearance.ocrComplete = false; appearance.ocrProcessingVersion = nil
        if appearance.identityBackgroundCleanup != true { appearance.cropReviewNeeded = nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var data = try encoder.encode(appearance)
        let source = root.appendingPathComponent(page.imageFile)
        let attributes = try source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        data.append(Data("large-v1|\(page.imageFile)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(attributes.fileSize ?? 0)".utf8))
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let memoryKey = (root.path + "|" + key) as NSString
        if let cached = large.object(forKey: memoryKey) { return cached }
        let directory = root.appendingPathComponent("Thumbnails", isDirectory: true)
        let file = directory.appendingPathComponent(key + ".jpg")
        if let cached = UIImage(contentsOfFile: file.path)?.preparingForDisplay() { large.setObject(cached, forKey: memoryKey); return cached }
        let image = try autoreleasepool { try Imaging.renderThumbnail(page, root: root, maxDimension: 1400) }
        try Task.checkCancellation()
        large.setObject(image, forKey: memoryKey)
        if let bytes = image.jpegData(compressionQuality: 0.92) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? bytes.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        return image
    }
    private func remember(_ image: UIImage, key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        memory.setObject(image, forKey: key as NSString, cost: cost)
    }
}
