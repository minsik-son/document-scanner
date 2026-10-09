import SwiftUI
import AVFoundation

/// Mega scan's camera: one photo after another without leaving the camera.
/// The edge of the last photo stays on screen, faded, so the next photo can be
/// lined up to overlap it, which is what the matching needs.
struct MegaCameraView: View {
    /// The photos in the order taken; empty when closed without any.
    let completion: ([UIImage]) -> Void
    @StateObject private var camera = MegaCamera()
    @State private var shots: [UIImage] = []
    @State private var direction = Direction.right
    @State private var flash = false
    static let maxShots = 8
    /// The overlap the faded edge shows: about a third of the photo.
    static let overlap: CGFloat = 0.32
    enum Direction { case right, down }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if Self.simulated {
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.4)], startPoint: .top, endPoint: .bottom)
                } else {
                    MegaPreview(camera: camera)
                }
                if let last = shots.last { ghost(last, in: geo.size) }
                Color.white.opacity(flash ? 0.7 : 0).allowsHitTesting(false)
                VStack(spacing: 0) {
                    topBar.padding(.top, geo.safeAreaInsets.top + 4)
                    Spacer()
                    Text(L(hint)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(.horizontal, 20)
                        .accessibilityIdentifier("mega-camera-hint")
                    bottomBar.padding(.top, 14).padding(.bottom, geo.safeAreaInsets.bottom + 14)
                }
                if let failed = camera.failed {
                    Text(L(failed)).font(.system(size: 15)).foregroundStyle(.white).multilineTextAlignment(.center).padding(24)
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .onAppear {
            camera.taken = { image in
                guard let image else { return }
                withAnimation(.easeOut(duration: 0.25)) { shots.append(image) }
            }
            if !Self.simulated { camera.start() }
        }
        .onDisappear { camera.stop() }
    }

    private var hint: String {
        if shots.isEmpty { return "Start at the top-left of the paper. Fill the screen with it." }
        if shots.count >= Self.maxShots { return "That's the most photos. Tap Combine." }
        return direction == .right ? "Move right until the faded edge lines up, then shoot."
                                   : "Move down until the faded edge lines up, then shoot."
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { completion([]) } label: { Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                .accessibilityLabel("Close").accessibilityIdentifier("mega-camera-close")
            Spacer()
            // Where the next photo goes: the faded edge follows it.
            HStack(spacing: 0) {
                directionButton(.right, "Next: right", "arrow.right")
                directionButton(.down, "Next: below", "arrow.down")
            }
            .background(Color.black.opacity(0.4), in: Capsule())
            Spacer()
            Text("\(shots.count)/\(Self.maxShots)").font(.system(size: 15, weight: .bold).monospacedDigit())
                .frame(width: 44).accessibilityIdentifier("mega-camera-count")
        }
        .foregroundStyle(.white).padding(.horizontal, 12)
    }
    private func directionButton(_ value: Direction, _ title: String, _ symbol: String) -> some View {
        Button { direction = value } label: {
            Label(L(title), systemImage: symbol).font(.system(size: 13, weight: .semibold))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 11).frame(height: 34)
                .background(direction == value ? Color.white.opacity(0.9) : .clear, in: Capsule())
                .foregroundStyle(direction == value ? Color.black : .white)
        }
        .accessibilityAddTraits(direction == value ? .isSelected : [])
        .accessibilityIdentifier(value == .right ? "mega-camera-right" : "mega-camera-down")
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            // The last photo; tap to take it back.
            ZStack(alignment: .topTrailing) {
                if let last = shots.last {
                    Button { withAnimation { _ = shots.popLast() } } label: {
                        Image(uiImage: last).resizable().scaledToFill().frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white, lineWidth: 2))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "arrow.uturn.backward.circle.fill").font(.system(size: 18)).foregroundStyle(.white, .black.opacity(0.6)).offset(x: 6, y: -6)
                            }
                    }
                    .accessibilityLabel("Remove last photo").accessibilityIdentifier("mega-camera-undo")
                } else { Color.clear.frame(width: 54, height: 54) }
            }.frame(width: 112)
            Spacer()
            Button { shoot() } label: {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                    .overlay(Circle().fill(.white).padding(8))
            }
            .disabled(shots.count >= Self.maxShots)
            .accessibilityLabel("Take photo").accessibilityIdentifier("mega-camera-shutter")
            Spacer()
            Button { completion(shots) } label: {
                Text(String(format: L("Combine %lld"), shots.count)).font(.system(size: 15, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(shots.count >= 2 ? TK.blue : Color.white.opacity(0.25), in: Capsule())
                    .foregroundStyle(.white)
            }
            .disabled(shots.count < 2).frame(width: 112)
            .accessibilityIdentifier("mega-camera-done")
        }
        .padding(.horizontal, 16)
    }

    /// The edge of the last photo that the next one should overlap, faded, where it
    /// should appear in the new view (its right third on the left, or its bottom
    /// third at the top).
    @ViewBuilder private func ghost(_ image: UIImage, in size: CGSize) -> some View {
        let k = Self.overlap
        Image(uiImage: image).resizable().scaledToFill()
            .frame(width: size.width, height: size.height)
            .offset(x: direction == .right ? -size.width * (1 - k) : 0, y: direction == .down ? -size.height * (1 - k) : 0)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .mask(alignment: .topLeading) {
                Rectangle().frame(width: direction == .right ? size.width * k : size.width, height: direction == .down ? size.height * k : size.height)
            }
            .opacity(0.45)
            .overlay(alignment: .topLeading) {
                Rectangle().fill(.white).frame(width: direction == .right ? 2 : size.width, height: direction == .down ? 2 : size.height)
                    .offset(x: direction == .right ? size.width * k : 0, y: direction == .down ? size.height * k : 0)
                    .opacity(0.8)
            }
            .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }

    private func shoot() {
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        withAnimation(.easeIn(duration: 0.25).delay(0.08)) { flash = false }
        if Self.simulated { camera.taken?(Self.simulatedShot(shots.count, direction: direction)); return }
        camera.capture()
    }

    static var simulated: Bool {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--ui-test-session"), i + 1 < args.count { return args.contains("--simulate-camera") }
#endif
        return false
    }
#if DEBUG
    /// UI tests: overlapping pieces of one drawn poster, left to right.
    static func simulatedShot(_ index: Int, direction: Direction) -> UIImage {
        let poster = CGSize(width: 2400, height: 1800)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let piece = CGSize(width: 1000, height: 1300)
        let origin = CGPoint(x: min(poster.width - piece.width, CGFloat(index) * 640), y: direction == .down ? 450 : 120)
        return UIGraphicsImageRenderer(size: piece, format: format).image { c in
            c.cgContext.translateBy(x: -origin.x, y: -origin.y)
            UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: poster))
            for i in 0..<14 {
                UIColor(hue: CGFloat(i) / 14, saturation: 0.6, brightness: 0.85, alpha: 1).setFill()
                c.cgContext.fillEllipse(in: CGRect(x: 80 + CGFloat(i) * 165, y: 200 + CGFloat((i * 7) % 5) * 260, width: 140, height: 140))
            }
            for row in 0..<6 {
                ("POSTER ROW \(row + 1) · MEGA SCAN TEST" as NSString).draw(at: CGPoint(x: 90 + CGFloat(row) * 60, y: 160 + CGFloat(row) * 260),
                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.black])
            }
        }
    }
#endif
}

private struct MegaPreview: UIViewRepresentable {
    let camera: MegaCamera
    func makeUIView(context: Context) -> PortraitPreviewView {
        let view = PortraitPreviewView()
        view.preview.session = camera.session
        view.preview.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: PortraitPreviewView, context: Context) {}
}

/// Back camera that hands every photo to `taken` and keeps running.
final class MegaCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "mega.camera")
    private var configured = false
    @Published var failed: String?
    var taken: ((UIImage?) -> Void)?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.failed = "Allow camera access in Settings to take photos." }
                return
            }
            self.queue.async {
                if !self.configured { self.configure(); self.configured = true }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
    func capture() {
        queue.async {
            guard self.session.isRunning else { return }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }
    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            DispatchQueue.main.async { self.failed = "The camera isn't available." }
            return
        }
        session.addInput(input)
        if session.canAddOutput(output) { session.addOutput(output); output.maxPhotoQualityPrioritization = .balanced }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }.map { Imaging.normalized($0) }
        DispatchQueue.main.async {
            if image == nil { self.failed = "The photo couldn't be taken. Try again." }
            self.taken?(image)
        }
    }
}
