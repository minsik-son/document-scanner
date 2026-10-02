import XCTest
import UIKit
@testable import DocumentScanner

@MainActor
final class StartupPerformanceTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) } }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testAsyncOpeningRetainsActiveAndRecentTrashAndPurgesOnlyExpired() async throws {
        let root = try root(), store = LibraryStore(root: root)
        let active = try store.createDraft()
        var doc = try XCTUnwrap(store.document(active)); doc.isDraft = false
        try store.update(doc)
        var recent = ScanDocument(title: "Recent trash"); recent.deletedAt = Date()
        try store.update(recent)
        var expired = ScanDocument(title: "Expired"); expired.deletedAt = Date().addingTimeInterval(-31 * 86400)
        try store.update(expired)
        let reopened = await LibraryStore.open(root: root)
        XCTAssertTrue(reopened.storageAvailable)
        XCTAssertNotNil(reopened.document(active))
        XCTAssertNotNil(reopened.document(recent.id))
        XCTAssertNil(reopened.document(expired.id))
        XCTAssertNil(LibraryStore(root: root).document(expired.id))
    }
    func testAsyncOpeningNeverCleansAssetsWhenIndexIsCorrupt() async throws {
        let root = try root()
        let invalid = Data("bad index".utf8)
        try invalid.write(to: root.appendingPathComponent("library.json"))
        let asset = root.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([1, 2, 3]).write(to: asset)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: asset.path)
        let store = await LibraryStore.open(root: root)
        XCTAssertFalse(store.storageAvailable)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), invalid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path))
    }
    func testSavedPDFThumbnailSkipsPhotoProcessingEntirely() async throws {
        let root = try root()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300))
        let data = renderer.pdfData { context in
            context.beginPage(); UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        try data.write(to: root.appendingPathComponent("saved.pdf"))
        let counter = RenderCounter()
        let cache = PageThumbnailCache(renderer: { _, _ in counter.render() })
        let image = try await cache.image(for: ScanPage(imageFile: "missing.jpg"), root: root, pdfFile: "saved.pdf")
        XCTAssertGreaterThan(image.size.height, 0)
        XCTAssertEqual(counter.count, 0, "Home should rasterize its saved PDF, never re-run photo enhancement")
    }
    func testThumbnailReusesMemoryAndDiskAndInvalidatesAppearanceAndSource() async throws {
        let root = try root()
        let source = root.appendingPathComponent("page.jpg")
        try Data([1]).write(to: source)
        let page = ScanPage(imageFile: "page.jpg")
        let counter = RenderCounter()
        let cache = PageThumbnailCache(renderer: { _, _ in counter.render() })
        let first = try await cache.image(for: page, root: root)
        let second = try await cache.image(for: page, root: root)
        XCTAssertTrue(first === second)
        XCTAssertEqual(counter.count, 1)
        let freshCache = PageThumbnailCache(renderer: { _, _ in counter.render() })
        _ = try await freshCache.image(for: page, root: root)
        XCTAssertEqual(counter.count, 1, "Relaunch should reuse the processed disk thumbnail")
        var rotated = page; rotated.turns = 1
        _ = try await cache.image(for: rotated, root: root)
        XCTAssertEqual(counter.count, 2)
        try Data([1, 2]).write(to: source)
        _ = try await cache.image(for: page, root: root)
        XCTAssertEqual(counter.count, 3, "Replacing the source must invalidate old pixels")
    }
}
private final class RenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func render() -> UIImage {
        lock.lock(); value += 1; lock.unlock()
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 48)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        }
    }
}
