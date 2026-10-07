import SwiftUI

struct EnlargedScanPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage
    @State private var loading = true
    @State private var problem: String?
    let loadFullResolution: () async throws -> UIImage

    init(initialImage: UIImage, loadFullResolution: @escaping () async throws -> UIImage) {
        _image = State(initialValue: initialImage)
        self.loadFullResolution = loadFullResolution
    }

    var body: some View {
        NavigationStack {
            ZoomableScanImage(image: image)
                .background(.black)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if loading { ProgressView("Loading full detail…").tint(.white) }
                        if let problem { Text(L(problem)) }
                        Text("Pinch to zoom · Double-tap to zoom or reset")
                    }
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center).padding(12).frame(maxWidth: .infinity).background(.black)
                }
                .navigationTitle("Page preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }.accessibilityIdentifier("close-enlarged-preview")
                    }
                }
                .toolbarBackground(.black, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task {
            do {
                let fullImage = try await loadFullResolution()
                try Task.checkCancellation()
                image = fullImage
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                problem = "Full detail couldn't load. The current preview is still available."
            }
            loading = false
        }
    }
}

private struct ZoomableScanImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ScanImageScrollView { ScanImageScrollView(image: image) }
    func updateUIView(_ view: ScanImageScrollView, context: Context) { view.setImage(image) }
}

// UIScrollView supplies native pinch, bounded panning and momentum. The image's
// logical bounds stay fixed when the full-resolution raster replaces the first
// frame, so an in-progress gesture never jumps or resets.
final class ScanImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let pageView = UIImageView()
    private var viewport = CGSize.zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        pageView.image = image
        pageView.contentMode = .scaleAspectFit
        pageView.frame = CGRect(origin: .zero, size: image.size)
        addSubview(pageView)
        contentSize = image.size
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        isAccessibilityElement = true
        accessibilityLabel = "Page image"
        accessibilityIdentifier = "zoomable-page"
        accessibilityTraits = .image
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Zoom in", target: self, selector: #selector(zoomIn)),
            UIAccessibilityCustomAction(name: "Zoom out", target: self, selector: #selector(zoomOut)),
            UIAccessibilityCustomAction(name: "Fit page", target: self, selector: #selector(fitPage))
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        guard pageView.image !== image else { return }
        pageView.image = image
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if viewport != bounds.size {
            viewport = bounds.size
            let fit = min(bounds.width / pageView.bounds.width, bounds.height / pageView.bounds.height)
            minimumZoomScale = fit
            maximumZoomScale = fit * 6
            setZoomScale(fit, animated: false)
        }
        centerPage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPage() }

    private func centerPage() {
        let inset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
        if contentInset != inset { contentInset = inset }
        accessibilityValue = "\(Int((zoomScale / max(minimumZoomScale, 0.0001) * 100).rounded()))%"
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.05 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let scale = minimumZoomScale * 2.5
            let point = gesture.location(in: pageView)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func zoomIn() -> Bool { setZoomScale(min(maximumZoomScale, zoomScale * 1.5), animated: true); return true }
    @objc private func zoomOut() -> Bool { setZoomScale(max(minimumZoomScale, zoomScale / 1.5), animated: true); return true }
    @objc private func fitPage() -> Bool { setZoomScale(minimumZoomScale, animated: true); return true }
}
