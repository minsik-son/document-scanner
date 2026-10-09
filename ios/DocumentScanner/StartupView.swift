import SwiftUI

struct StartupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            VStack(spacing: 24) {
                // Plays once: a photographed page slides into the brackets shown on
                // the launch screen, gets scanned and becomes the clean logo.
                SplashAnimation(animates: !reduceMotion)
                    .frame(width: SplashAnimation.side, height: SplashAnimation.side)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(verbatim: AppInfo.name).font(.system(.title2, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Fast, easy scanning.").font(.body)
                        .foregroundStyle(Color(red: 0.55, green: 0.80, blue: 0.95))
                }
            }.padding(.horizontal, 24).offset(y: -20)
            VStack {
                Spacer()
                ProgressView().tint(.white).accessibilityLabel("Opening your documents")
                    .padding(.bottom, 42)
            }
        }.accessibilityIdentifier("startup-screen")
    }
}

/// The launch logo as Core Animation layers. The keyframes run in the render
/// server, so they stay smooth at the display's full frame rate even while the
/// main thread is busy opening the library and drawing the first screen
/// (the frame-by-frame APNG it replaces was swapped by main-thread callbacks).
struct SplashAnimation: UIViewRepresentable {
    static let side: CGFloat = 168
    /// The logo settles here; the startup cover is held at least this long.
    static var duration: TimeInterval { Double(SplashMotion.parts[0].alpha.count - 1) / SplashMotion.fps }
    var animates: Bool
    func makeUIView(context: Context) -> SplashLayerView { SplashLayerView(animates: animates) }
    func updateUIView(_ view: SplashLayerView, context: Context) {}
}

final class SplashLayerView: UIView {
    private let animates: Bool
    private var built = false
    init(animates: Bool) {
        self.animates = animates
        super.init(frame: CGRect(x: 0, y: 0, width: SplashAnimation.side, height: SplashAnimation.side))
        clipsToBounds = true
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: CGSize { CGSize(width: SplashAnimation.side, height: SplashAnimation.side) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !built, bounds.width > 0 else { return }
        built = true
        // Fires in the render server's time when every keyframe has played, however
        // late the first frame was committed. The startup cover waits for it.
        CATransaction.begin()
        CATransaction.setCompletionBlock { SplashClock.finish() }
        defer { CATransaction.commit() }
        if !animates { SplashClock.finish() }
        let unit = bounds.width / SplashMotion.canvas
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        for part in SplashMotion.parts {
            let piece = CALayer()
            piece.contents = UIImage(named: part.image)?.cgImage
            piece.contentsGravity = .resize
            piece.minificationFilter = .trilinear
            piece.bounds = CGRect(x: 0, y: 0, width: part.size.width * unit, height: part.size.height * unit)
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: center.x + value(part.x, i) * unit, y: center.y - value(part.y, i) * unit)
            }
            // The model is the settled logo; the animations run from frame 0 to it.
            let last = part.alpha.count - 1
            piece.position = point(last)
            piece.opacity = Float(value(part.alpha, last))
            piece.setValue(-value(part.rotation, last), forKeyPath: "transform.rotation.z")
            piece.setValue(value(part.scaleX, last), forKeyPath: "transform.scale.x")
            piece.setValue(value(part.scaleY, last), forKeyPath: "transform.scale.y")
            layer.addSublayer(piece)
            guard animates else { continue }
            let frames = 0...last
            if part.x.count > 1 || part.y.count > 1 {
                add(piece, "position", frames.map { NSValue(cgPoint: point($0)) })
            }
            if part.rotation.count > 1 { add(piece, "transform.rotation.z", part.rotation.map { -$0 }) }
            if part.scaleX.count > 1 { add(piece, "transform.scale.x", part.scaleX) }
            if part.scaleY.count > 1 { add(piece, "transform.scale.y", part.scaleY) }
            if part.alpha.count > 1 { add(piece, "opacity", part.alpha) }
        }
    }
    private func value(_ values: [Double], _ i: Int) -> Double { values[min(i, values.count - 1)] }
    private func add(_ piece: CALayer, _ keyPath: String, _ values: [Any]) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = values.indices.map { NSNumber(value: Double($0) / Double(values.count - 1)) }
        animation.calculationMode = .linear
        animation.duration = SplashAnimation.duration
        // Starts when this layer is first committed, so a busy launch never skips frames;
        // until then the backwards fill shows frame 0 (the launch screen's brackets).
        animation.fillMode = .backwards
        // Uses the display's highest rate (120 Hz on ProMotion).
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
#if DEBUG
        // UI previews: freeze the logo at a given time (seconds) to compare with the Blender render.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--splash-time"), i + 1 < args.count, let t = Double(args[i + 1]) {
            animation.speed = 0; animation.timeOffset = t; animation.fillMode = .both
        }
#endif
        piece.add(animation, forKey: keyPath)
    }
}

/// Lets app start-up wait until the logo has finished playing.
@MainActor
enum SplashClock {
    private static var finished = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []
    nonisolated static func finish() {
        Task { @MainActor in release() }
    }
    private static func release() {
        guard !finished else { return }
        finished = true
        waiters.forEach { $0.resume() }; waiters = []
    }
    /// Returns when the logo has played, or after `timeout` in case it never ran.
    static func wait(timeout: Duration) async {
        guard !finished else { return }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            release()
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// The startup cover in its own hosting controller, so its fade-out is a UIKit
/// (Core Animation) animation that the render server plays even if the main
/// thread is busy with the screen being revealed underneath.
struct StartupCover: UIViewControllerRepresentable {
    var fading: Bool
    var faded: () -> Void
    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView: AnyView(StartupView().environment(\.locale, AppLanguage.locale)))
        host.view.backgroundColor = .clear
        return host
    }
    func updateUIViewController(_ host: UIHostingController<AnyView>, context: Context) {
        guard fading, !context.coordinator.started else { return }
        context.coordinator.started = true
        let done = faded
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            host.view.alpha = 0
        } completion: { _ in done() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var started = false }
}
