import XCTest
import CoreImage
import UIKit
@testable import DocumentScanner

/// Which models the quality runs use: Verification/private/neural/use.txt lists
/// "unwarp", "restore" (comma or newline separated). No file: all on.
enum NeuralTestSettings {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Verification/private/neural")
    static func apply() {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("use.txt"), encoding: .utf8) else { NeuralModels.use = .init(); return }
        let set = Set(text.split(whereSeparator: { ",\n ".contains($0) }).map(String.init))
        NeuralModels.use = .init(unwarp: set.contains("unwarp"), restore: set.contains("restore"))
    }
}

final class NeuralModelsTests: XCTestCase {
    override func tearDown() { NeuralModels.use = .init(); super.tearDown() }

    func testModelsAreBundled() {
        for name in ["PageUnwarp", "PhotoRestore", "PhotoRestoreGentle", "PhotoRestoreStrong"] {
            XCTAssertNotNil(NeuralModels.model(name), name)
        }
    }

    private func pixels(_ cg: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return px
    }
    private func reference(_ name: String) throws -> CGImage {
        guard let image = UIImage(contentsOfFile: NeuralTestSettings.folder.appendingPathComponent(name).path)?.cgImage else { throw XCTSkip("No reference \(name).") }
        return image
    }

    /// The converted models give what the original PyTorch models give
    /// (Verification/private/neural/*-in/out, made with the training code).
    func testUnwarpMatchesReference() throws {
        let input = try reference("unwarp-in.png")
        let data = try Data(contentsOf: NeuralTestSettings.folder.appendingPathComponent("unwarp-out.json"))
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[[Double]]])
        let model = try XCTUnwrap(NeuralModels.model("PageUnwarp"))
        let buffer = try XCTUnwrap(NeuralModels.pixelBuffer(CIImage(cgImage: input), width: 488, height: 712))
        let grid = try XCTUnwrap(NeuralModels.planes(try XCTUnwrap(NeuralModels.predict(model, buffer, output: "grid"))))
        XCTAssertEqual(grid.c, 2); XCTAssertEqual(grid.h, 45); XCTAssertEqual(grid.w, 31)
        var worst = 0.0
        for k in 0..<2 { for y in 0..<45 { for x in 0..<31 { worst = max(worst, abs(Double(grid.at(k, y, x)) - expected[k][y][x])) } } }
        print("NEURAL unwarp max grid difference \(worst)")
        XCTAssertLessThan(worst, 0.02)
    }

    func testRestoreMatchesReference() throws {
        let input = try reference("restore-in.png"), expected = try reference("restore-out.png")
        let model = try XCTUnwrap(NeuralModels.model("PhotoRestore"))
        let buffer = try XCTUnwrap(NeuralModels.pixelBuffer(CIImage(cgImage: input), width: 256, height: 256))
        let out = try XCTUnwrap(NeuralModels.planes(try XCTUnwrap(NeuralModels.predict(model, buffer, output: "restored"))))
        XCTAssertEqual(out.w, 1024)
        let px = pixels(expected)
        var total = 0.0
        for y in stride(from: 0, to: 1024, by: 2) { for x in stride(from: 0, to: 1024, by: 2) { for k in 0..<3 {
            total += abs(Double(max(0, min(1, out.at(k, y, x)))) * 255 - Double(px[(y * 1024 + x) * 4 + k])) } } }
        let mean = total / Double(512 * 512 * 3)
        print("NEURAL restore mean difference \(mean)")
        XCTAssertLessThan(mean, 3)
    }

    /// A small photo comes back exactly twice its size through the tiled restorer.
    func testRestoreEnlargesSmallPhotos() throws {
        let size = CGSize(width: 700, height: 500)
        let photo = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            for i in 0..<70 {
                UIColor(hue: CGFloat(i) / 70, saturation: 0.5, brightness: 0.8, alpha: 1).setFill()
                ctx.fill(CGRect(x: CGFloat(i) * 10, y: 0, width: 10, height: 500))
            }
        }
        let out = try ImageToolEngine.restore(photo, level: .standard, fixColor: false)
        XCTAssertEqual(out.size.width * out.scale, 1400); XCTAssertEqual(out.size.height * out.scale, 1000)
    }

    /// Restoration samples (Verification/private/neural/restore/in): each written
    /// with the hand-written and the learned restorer for scoring.
    func testRestoreSamples() throws {
        let dir = NeuralTestSettings.folder.appendingPathComponent("restore")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("in"), includingPropertiesForKeys: nil)) ?? [])
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw XCTSkip("No restoration samples.") }
        let out = dir.appendingPathComponent("out"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var log: [String] = []
        for url in files {
            let name = url.deletingPathExtension().lastPathComponent
            guard let photo = UIImage(contentsOfFile: url.path) else { continue }
            for (tag, learned) in [("classic", false), ("neural", true)] {
                NeuralModels.use.restore = learned
                let t = CFAbsoluteTimeGetCurrent()
                let image = try ImageToolEngine.restore(photo, level: .standard, fixColor: true)
                let seconds = CFAbsoluteTimeGetCurrent() - t
                try image.pngData()?.write(to: out.appendingPathComponent("\(name)-\(tag).png"))
                log.append(String(format: "%@ %@ %.2fs %dx%d", name, tag, seconds, Int(image.size.width * image.scale), Int(image.size.height * image.scale)))
            }
        }
        NeuralModels.use = .init()
        try log.joined(separator: "\n").write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        print(log.joined(separator: "\n"))
    }
}
