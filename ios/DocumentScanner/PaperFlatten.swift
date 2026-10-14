import Foundation
import CoreImage
import CryptoKit

/// Which page photo to flatten; the key keeps one analysis per photo and crop, so
/// every rendering of a page (preview, thumbnail, PDF) uses the same flat page.
struct FlattenRequest: Equatable {
    var key: String?
}

extension ScanPage {
    /// Photographed paper pages are drawn flat (curls, bends, cut corners) unless
    /// the user turned it off for the page.
    var flattenRequest: FlattenRequest? {
        guard flatten == true, identityBackgroundCleanup != true, sourcePDF == nil, crop != .full else { return nil }
        return FlattenRequest(key: PaperFlatten.key(imageFile: imageFile, crop: crop))
    }
}

/// Finds (once per photo and crop) and applies the flat page. Results, including
/// "couldn't flatten", are kept in memory and in Caches, so the analysis runs once.
enum PaperFlatten {
    static let analysisSide: CGFloat = 1400
    private final class Box { let mesh: FlattenMesh?; init(_ m: FlattenMesh?) { mesh = m } }
    private static let memory: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 40; return c }()
    private static let gate = NSLock()

    static func key(imageFile: String, crop: ScanQuad) -> String {
        "flat-v\(FlattenMesh.version)|\(imageFile)|" + crop.points.map { String(format: "%.4f,%.4f", $0.x, $0.y) }.joined(separator: ";")
    }
    private static var folder: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("FlattenCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static func file(_ key: String) -> URL? {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(name + ".json")
    }
    private struct Stored: Codable { var mesh: FlattenMesh? }

    /// The flat page for a photo, or nil when it can't be found reliably (then the
    /// page is drawn with the ordinary four-corner correction).
    static func mesh(for source: CIImage, crop: ScanQuad, key: String?) -> FlattenMesh? {
        if let key, let box = memory.object(forKey: key as NSString) { return box.mesh }
        gate.lock(); defer { gate.unlock() }
        if let key, let box = memory.object(forKey: key as NSString) { return box.mesh }
        if let key, let url = file(key), let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            memory.setObject(Box(stored.mesh), forKey: key as NSString); return stored.mesh
        }
        let result = analyze(source, crop: crop)
        if let key {
            memory.setObject(Box(result), forKey: key as NSString)
            if let url = file(key), let data = try? JSONEncoder().encode(Stored(mesh: result)) { try? data.write(to: url, options: .atomic) }
        }
        return result
    }

    static func analyze(_ source: CIImage, crop: ScanQuad) -> FlattenMesh? {
        let e = source.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let s = min(1, analysisSide / max(e.width, e.height))
        let small = source.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: s, y: s))
        guard let cg = DocumentProcessing.context.createCGImage(small, from: CGRect(x: 0, y: 0, width: (e.width * s).rounded(.down), height: (e.height * s).rounded(.down)),
                                                               format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return PaperFlattener.analyze(cg, crop: crop)
    }

    // The map holds each grid point's offset from a plain four-corner (perspective)
    // mapping, not its position: Core Image works in half floats, which store a
    // position thousands of pixels out only to the nearest 2–4 px (rules came out
    // stepped and letters doubled), but a small offset to a fraction of a pixel.
    private static let kernel: CIKernel? = CIKernel(source: """
    kernel vec4 flattenMesh(sampler src, sampler map, vec4 m, vec2 size, vec3 h0, vec3 h1, vec3 h2) {
        vec2 d = destCoord();
        vec2 offset = sample(map, samplerTransform(map, vec2(m.x + d.x * m.y, m.z + d.y * m.w))).xy;
        vec3 q = vec3(d.x / size.x, 1.0 - d.y / size.y, 1.0);
        vec2 base = vec2(dot(h0, q), dot(h1, q)) / dot(h2, q);
        return sample(src, samplerTransform(src, base + offset));
    }
    """)

    /// The page drawn flat at about the photo's own resolution, with missing paper
    /// filled in the paper's colour. Origin at zero.
    static func apply(_ mesh: FlattenMesh, to source: CIImage) -> CIImage? {
        guard let kernel, mesh.cols >= 2, mesh.rows >= 2, mesh.points.count == mesh.cols * mesh.rows * 2 else { return nil }
        let e = source.extent
        // Natural size: how long the page's rows and columns are in the photo.
        func len(_ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int) -> CGFloat {
            let a = (r0 * mesh.cols + c0) * 2, b = (r1 * mesh.cols + c1) * 2
            return hypot(CGFloat(mesh.points[b] - mesh.points[a]) * e.width, CGFloat(mesh.points[b + 1] - mesh.points[a + 1]) * e.height)
        }
        var width: CGFloat = 0, height: CGFloat = 0
        for r in [0, mesh.rows / 2, mesh.rows - 1] { width = max(width, (0..<(mesh.cols - 1)).reduce(0) { $0 + len(r, $1, r, $1 + 1) }) }
        for c in [0, mesh.cols / 2, mesh.cols - 1] { height = max(height, (0..<(mesh.rows - 1)).reduce(0) { $0 + len($1, c, $1 + 1, c) }) }
        // Keep the page's true shape, at the larger of the two measured scales.
        let scale = max(width, height * CGFloat(mesh.aspect))
        var outW = scale, outH = scale / CGFloat(mesh.aspect)
        let limit = max(e.width, e.height)
        if max(outW, outH) > limit { let f = limit / max(outW, outH); outW *= f; outH *= f }
        outW = outW.rounded(); outH = outH.rounded()
        guard outW >= 16, outH >= 16 else { return nil }
        // Where each grid point is in the source (Core Image coordinates), and the
        // perspective mapping through the four corner points (u, v from the top left).
        func node(_ r: Int, _ c: Int) -> SIMD2<Double> {
            let i = r * mesh.cols + c
            return SIMD2(Double(e.minX) + Double(mesh.points[i * 2]) * Double(e.width), Double(e.minY) + (1 - Double(mesh.points[i * 2 + 1])) * Double(e.height))
        }
        let H = PaperFlattener.homography(from: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)],
                                          to: [node(0, 0), node(0, mesh.cols - 1), node(mesh.rows - 1, mesh.cols - 1), node(mesh.rows - 1, 0)])
        var map = [Float](repeating: 0, count: mesh.cols * mesh.rows * 4)
        for r in 0..<mesh.rows {
            for c in 0..<mesh.cols {
                let i = r * mesh.cols + c
                let base = PaperFlattener.apply(H, SIMD2(Double(c) / Double(mesh.cols - 1), Double(r) / Double(mesh.rows - 1)))
                let p = node(r, c)
                map[i * 4] = Float(p.x - base.x); map[i * 4 + 1] = Float(p.y - base.y); map[i * 4 + 3] = 1
            }
        }
        let mapImage = CIImage(bitmapData: map.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: mesh.cols * 16,
                               size: CGSize(width: mesh.cols, height: mesh.rows), format: .RGBAf, colorSpace: nil).clampedToExtent()
        let out = CGRect(x: 0, y: 0, width: outW, height: outH)
        let m = CIVector(x: 0.5, y: CGFloat(mesh.cols - 1) / outW, z: 0.5, w: CGFloat(mesh.rows - 1) / outH)
        let src = source.clampedToExtent()
        guard var flat = kernel.apply(extent: out, roiCallback: { index, _ in index == 0 ? e : CGRect(x: 0, y: 0, width: mesh.cols, height: mesh.rows) },
                                      arguments: [src, mapImage, m, CIVector(x: outW, y: outH),
                                                  CIVector(x: H[0][0], y: H[1][0], z: H[2][0]), CIVector(x: H[0][1], y: H[1][1], z: H[2][1]), CIVector(x: H[0][2], y: H[1][2], z: H[2][2])]) else { return nil }
        // Fill where there is no paper.
        if mesh.missing.count == mesh.maskCols * mesh.maskRows, mesh.missing.contains(where: { $0 > 0 }), mesh.paper.count == 3,
           let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
           let color = CIColor(red: CGFloat(mesh.paper[0]), green: CGFloat(mesh.paper[1]), blue: CGFloat(mesh.paper[2]), colorSpace: sRGB) {
            let mask = CIImage(bitmapData: mesh.missing, bytesPerRow: mesh.maskCols, size: CGSize(width: mesh.maskCols, height: mesh.maskRows), format: .L8, colorSpace: nil)
                .clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: outW / CGFloat(mesh.maskCols), y: outH / CGFloat(mesh.maskRows)))
                .applyingGaussianBlur(sigma: Double(outW / CGFloat(mesh.maskCols)) * 0.6)
                .cropped(to: out)
            let paper = CIImage(color: color).cropped(to: out)
            flat = paper.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: flat, kCIInputMaskImageKey: mask]).cropped(to: out)
        }
        return flat
    }
}
