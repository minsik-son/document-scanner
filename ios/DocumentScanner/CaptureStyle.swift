import UIKit
import Vision
import CoreImage

enum CaptureStyle: String, Codable, CaseIterable {
    case document = "Document", card = "ID card", whiteboard = "Whiteboard", slides = "Slides"
    var enhancement: Enhancement { self == .slides || self == .card ? .original : .document }
    var strength: Double { self == .whiteboard ? 1.2 : 1 }
    var hint: String {
        switch self {
        case .document: "Keep all four page edges visible"
        case .card: "Keep the whole ID card in view. Capture is automatic, or tap the shutter."
        case .whiteboard: "Include the whole board. Move away from reflections."
        case .slides: "Fill the frame with the slide. Colors are preserved."
        }
    }
    func detect(_ image: UIImage, capturedPhoto: Bool = false) -> ScanQuad? {
        if self == .card && capturedPhoto { return Self.detectCardPhoto(image) }
        if self == .document || self == .whiteboard { return Imaging.detect(image) }
        guard let cg = image.cgImage else { return nil }
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.75; request.minimumSize = self == .card ? 0.12 : 0.2
        request.minimumAspectRatio = self == .card ? 0.45 : 0.35; request.maximumObservations = 16
        if self == .card { request.quadratureTolerance = 30 }
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        return (request.results ?? []).compactMap { observation -> ScanQuad? in
            let quad = ScanQuad(points: [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft].map { ScanPoint(x: Double($0.x), y: 1-Double($0.y)) })
            if self == .card { return Self.cardScore(quad, imageSize: CGSize(width: cg.width, height: cg.height)) != nil ? quad : nil }
            return quad.valid && DocumentProcessing.area(quad) >= 0.15 ? quad : nil
        }.max {
            if self == .card {
                let size = CGSize(width: cg.width, height: cg.height)
                return (Self.cardScore($0, imageSize: size) ?? 0) < (Self.cardScore($1, imageSize: size) ?? 0)
            }
            return DocumentProcessing.area($0) < DocumentProcessing.area($1)
        }
    }

    // Require the whole detected card to fit the actual visible camera area,
    // not a fixed guide. The preview layer supplies aspect-fill coordinates.
    static func fullyVisible(_ card: ScanQuad?, in viewport: ScanQuad?) -> Bool {
        guard let card, let viewport, card.valid, viewport.valid else { return false }
        let minX = viewport.points.map(\.x).min()!, maxX = viewport.points.map(\.x).max()!
        let minY = viewport.points.map(\.y).min()!, maxY = viewport.points.map(\.y).max()!
        return card.points.allSatisfy { (minX...maxX).contains($0.x) && (minY...maxY).contains($0.y) }
    }

    // The captured still gets a second, higher-resolution detection pass.
    // Contrast variants are used only to find corners; original color pixels
    // are retained for the perspective-corrected preview and final PDF.
    private static func detectCardPhoto(_ image: UIImage) -> ScanQuad? {
        guard let cg = image.cgImage else { return nil }
        let source = CIImage(cgImage: cg)
        let scale = min(1, 1800 / max(source.extent.width, source.extent.height))
        let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = DocumentProcessing.context
        guard let pixels = context.createCGImage(small, from: small.extent) else { return nil }
        if let found = CaptureStyle.card.detect(UIImage(cgImage: pixels)) { return found }
        for contrast in [1.6, 2.2] {
            let enhanced = small.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0, kCIInputContrastKey: contrast
            ])
            guard let pixels = context.createCGImage(enhanced, from: small.extent) else { continue }
            if let found = CaptureStyle.card.detect(UIImage(cgImage: pixels)) { return found }
        }
        // Never crop to the guide blindly: it could cut off an unmatched card.
        // The editor asks the user to set the corners when detection fails.
        return nil
    }

    // Evaluate in pixel space: normalized portrait coordinates otherwise make
    // a landscape card look square. Prefer a centered ID-1 shape over a desk,
    // monitor or the photograph printed inside the card. Detection is only
    // geometry; it does not claim to identify or authenticate an ID document.
    static func cardScore(_ quad: ScanQuad, imageSize: CGSize) -> Double? {
        guard quad.valid, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let p = quad.points.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x-b.x, a.y-b.y) }
        let width = (distance(p[0], p[1]) + distance(p[3], p[2])) / 2
        let height = (distance(p[0], p[3]) + distance(p[1], p[2])) / 2
        let ratio = max(width, height) / max(1, min(width, height))
        let area = DocumentProcessing.area(quad)
        let cx = quad.points.map(\.x).reduce(0,+)/4, cy = quad.points.map(\.y).reduce(0,+)/4
        guard (1.25...1.95).contains(ratio), (0.04...0.85).contains(area),
              (0.18...0.82).contains(cx), (0.18...0.82).contains(cy),
              quad.points.allSatisfy({ (0.01...0.99).contains($0.x) && (0.01...0.99).contains($0.y) }) else { return nil }
        return area / (1 + 4 * abs(ratio - 1.586) + hypot(cx-0.5, cy-0.5))
    }
}
