import UIKit
import CoreImage

/// First use of the scan pipeline pays one-time costs: Core Image compiles its
/// kernels for the GPU, and Vision loads its edge and text models. After an
/// install or update iOS has discarded those caches, so the first camera frame,
/// the first filter and the first save were visibly slower. Once the startup
/// cover is gone, a small made-up page goes through the same steps in the
/// background, at low priority, so the user's first real scan doesn't wait.
enum Warmup {
    enum Step: CaseIterable { case detect, tone, text }
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var textStarted = false
    /// Milliseconds each step took, for tests and the debug log.
    nonisolated(unsafe) private(set) static var timings: [String: Double] = [:]

    @MainActor static func start(after delay: Duration = .milliseconds(1500)) {
        guard !started else { return }
        started = true
#if DEBUG
        // UI tests measure their own flows; keep this background work out of them.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-session") { return }
#endif
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            // Edge finding and tone are cheap to prepare; text recognition is
            // prepared when the camera opens (`prepareText`), only for people who scan.
            run([.detect, .tone])
        }
    }

    /// Called when the scan camera opens: the text model loads while pages are
    /// being taken, so the first save doesn't wait for it.
    @MainActor static func prepareText() {
        guard !textStarted else { return }
        textStarted = true
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-session") { return }
#endif
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(800))
            run([.text])
        }
    }

    static func run(_ steps: Set<Step> = Set(Step.allCases)) {
        autoreleasepool {
            guard let page = samplePage().cgImage else { return }
            func step(_ name: String, _ work: () throws -> Void) {
                let t = CFAbsoluteTimeGetCurrent()
                try? work()
                timings[name] = (CFAbsoluteTimeGetCurrent() - t) * 1000
            }
            // Live edge finding (camera).
            if steps.contains(.detect) { step("detect") { _ = DocumentProcessing.detect(page) } }
            // The Document tone: paper and clarity kernels, line alignment.
            if steps.contains(.tone) {
                step("tone") {
                    let out = try DocumentProcessing.render(CIImage(cgImage: page), crop: .full, turns: 0, enhancement: .document)
                    _ = DocumentProcessing.context.createCGImage(out, from: out.extent)
                }
            }
            // Text recognition (every save).
            if steps.contains(.text) { step("text") { _ = try TextRecognition.recognize(page) } }
        }
    }

    /// A small page with a title, lines and a box: enough for every step to do real work.
    static func samplePage() -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            UIColor(white: 0.55, alpha: 1).setFill(); c.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.97, alpha: 1).setFill(); c.fill(CGRect(x: 90, y: 110, width: 720, height: 980))
            let font: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 34), .foregroundColor: UIColor.black]
            ("Warm up" as NSString).draw(at: CGPoint(x: 140, y: 170), withAttributes: font)
            UIColor.black.setStroke()
            for row in 0..<6 {
                let path = UIBezierPath(rect: CGRect(x: 140, y: 280 + row * 70, width: 620, height: 70)); path.lineWidth = 2; path.stroke()
            }
        }
    }
}
