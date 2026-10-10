import SwiftUI
import CoreImage.CIFilterBuiltins
import CoreImage

// Only visual inputs belong in this key. OCR metadata and slider values must not
// decode the source or repeat paper detection/illumination analysis.
private struct PreviewGeometry: Equatable {
    let root: URL
    let imageFile: String
    let crop: ScanQuad
    let turns: Int
    let enhancement: Enhancement
    let identityCleanup: Bool
    let flatten: FlattenRequest?
    init(_ page: ScanPage, root: URL) {
        flatten = page.flattenRequest
        identityCleanup = page.identityBackgroundCleanup == true && page.cropReviewNeeded != true
        self.root = root.standardizedFileURL
        imageFile = page.imageFile; crop = page.crop; turns = page.turns; enhancement = page.enhancement
    }
}

actor ScanPreviewRenderer {
    static let maximumDimension = 1800
    private var geometry: PreviewGeometry?
    private var prepared: DocumentProcessing.PreparedDocument?
    private var toneStrength: Double?
    private var toneImage: CIImage?
    private var toneCap: Int?

    /// `interactive`: a slider frame, from a cached reduced tone (fast, close).
    /// Otherwise the preview is the export's own pixels resized the export's way,
    /// so a settled preview never looks lighter or softer than the saved PDF.
    func render(_ page: ScanPage, root: URL, maxDimension: Int? = ScanPreviewRenderer.maximumDimension, interactive: Bool = false) throws -> UIImage {
        try Task.checkCancellation()
        return try autoreleasepool {
            let key = PreviewGeometry(page, root: root)
            if geometry != key || prepared == nil {
                // Match export's decoding and original-resolution analysis. Keep
                // this graph unquantized: an 8-bit snapshot here clips illumination
                // values before the tone/ink filters get to interpret them.
                prepared = nil; geometry = nil; toneImage = nil; toneStrength = nil
                let source = try Imaging.source(page, root: root)
                let result = try DocumentProcessing.prepare(source, crop: page.crop, turns: page.turns, enhancement: page.enhancement, identityCleanup: key.identityCleanup, flatten: key.flatten)
                try Task.checkCancellation()
                prepared = result; geometry = key; toneStrength = nil; toneImage = nil
            }
            guard let prepared else { throw ScannerError.message("The preview couldn't be prepared.") }
            if let maxDimension, !interactive {
                // Exactly Imaging.render (same decode, same prepared geometry, full
                // resolution tone and adjustments), then the same resize as export.
                let finished = try DocumentProcessing.finish(prepared, strength: page.enhancementStrength)
                let adjusted = try Imaging.trim(DocumentProcessing.adjust(finished, settings: page.appearance), edges: page.trimming)
                guard let raster = DocumentProcessing.context.createCGImage(adjusted, from: adjusted.extent) else {
                    throw ScannerError.message("These adjustments couldn't be previewed. Try again.")
                }
                try Task.checkCancellation()
                let full = Imaging.applyRedactions(try Imaging.applyErasures(UIImage(cgImage: raster), page: page), page: page)
                return try Imaging.previewThumbnail(full, maxDimension: maxDimension)
            }
            guard let maxDimension else {
                // Full resolution is requested rarely (zoomed inspection); don't keep
                // a 24 MP floating-point copy around for it.
                let finished = try DocumentProcessing.finish(prepared, strength: page.enhancementStrength)
                let adjusted = try Imaging.trim(DocumentProcessing.adjust(finished, settings: page.appearance), edges: page.trimming)
                guard let raster = DocumentProcessing.context.createCGImage(adjusted, from: adjusted.extent) else {
                    throw ScannerError.message("These adjustments couldn't be previewed. Try again.")
                }
                return Imaging.applyRedactions(try Imaging.applyErasures(UIImage(cgImage: raster), page: page), page: page)
            }
            if toneImage == nil || toneStrength != page.enhancementStrength || toneCap != maxDimension {
                // Cache only the finished full-resolution tone, at floating-point
                // precision. Slider frames reuse it without another Vision/clarity
                // pass or an sRGB 8-bit boundary before manual adjustments.
                toneImage = nil; toneStrength = nil
                var result = try DocumentProcessing.finish(prepared, strength: page.enhancementStrength)
                // Downsample after the nonlinear paper/ink filters (safe) to a little
                // above the preview size. A full 24 MP RGBAh cache costs ~190 MB.
                let side = max(result.extent.width, result.extent.height), cap = CGFloat(maxDimension) * 1.5
                if side > cap {
                    // Average in sRGB-encoded values, as the export's thumbnail does.
                    // Averaging thin dark strokes in linear light whitens them.
                    let encoded = result.applyingFilter("CILinearToSRGBToneCurve")
                    let f = CIFilter.lanczosScaleTransform(); f.inputImage = encoded; f.scale = Float(cap / side); f.aspectRatio = 1
                    if let scaled = f.outputImage { result = scaled.cropped(to: scaled.extent.integral).applyingFilter("CISRGBToneCurveToLinear") }
                }
                guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                      let raster = DocumentProcessing.context.createCGImage(result, from: result.extent, format: .RGBAh, colorSpace: linear) else {
                    throw ScannerError.message("These adjustments couldn't be previewed. Try again.")
                }
                try Task.checkCancellation()
                toneImage = CIImage(cgImage: raster)
                    .transformed(by: CGAffineTransform(translationX: result.extent.minX, y: result.extent.minY))
                    .cropped(to: result.extent)
                toneStrength = page.enhancementStrength; toneCap = maxDimension
            }
            guard let toneImage else { throw ScannerError.message("The preview couldn't be prepared.") }
            let adjusted = try Imaging.trim(DocumentProcessing.adjust(toneImage, settings: page.appearance), edges: page.trimming)
            guard let raster = DocumentProcessing.context.createCGImage(adjusted, from: adjusted.extent) else {
                throw ScannerError.message("These adjustments couldn't be previewed. Try again.")
            }
            try Task.checkCancellation()
            let fullImage = UIImage(cgImage: raster)
            let sized = try Imaging.previewThumbnail(fullImage, maxDimension: maxDimension)
            let result = Imaging.applyRedactions(try Imaging.applyErasures(sized, page: page), page: page)
            try Task.checkCancellation()
            return result
        }
    }
}

// One render is in flight, with one replaceable pending request. A drag therefore
// presents completed frames continuously instead of waiting for the user to stop.
// Pending intermediate values are discarded, while the final value always renders.
@MainActor
final class ScanPreviewModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var problem: String?
    @Published private(set) var isReady = false
    private struct Request { let page: ScanPage; let root: URL }
    private var pending: Request?
    private var worker: Task<Void, Never>?
    private var workerID = 0
    /// Third argument: an interactive (slider) frame.
    private let render: (ScanPage, URL, Bool) async throws -> UIImage
    private let renderFullResolution: (ScanPage, URL) async throws -> UIImage
    /// After a run of slider frames, render the settled value exactly once more.
    private let settles: Bool
    /// Requests are arriving while a frame renders: the user is dragging.
    private var dragging = false

    init(renderer: ScanPreviewRenderer = ScanPreviewRenderer()) {
        render = { page, root, interactive in try await renderer.render(page, root: root, interactive: interactive) }
        renderFullResolution = { page, root in try await renderer.render(page, root: root, maxDimension: nil) }
        settles = true
    }
    // A controllable renderer also lets tests verify coalescing and cancellation
    // without timing-sensitive sleeps or a GPU performance assumption.
    init(render: @escaping (ScanPage, URL) async throws -> UIImage) {
        self.render = { page, root, _ in try await render(page, root) }; renderFullResolution = render; settles = false
    }
    /// Tests: a renderer told which frames are interactive, with the settle pass on.
    init(renderInteractive: @escaping (ScanPage, URL, Bool) async throws -> UIImage) {
        render = renderInteractive; renderFullResolution = { page, root in try await renderInteractive(page, root, false) }; settles = true
    }

    func fullResolution(_ page: ScanPage, root: URL) async throws -> UIImage {
        try await renderFullResolution(page, root)
    }

    func request(_ page: ScanPage, root: URL) {
        pending = Request(page: page, root: root)
        problem = nil; isReady = false
        guard worker == nil else { dragging = true; return }
        workerID += 1
        let id = workerID
        worker = Task { [weak self] in await self?.renderPending(workerID: id) }
    }

    func cancel() {
        workerID += 1; pending = nil; worker?.cancel(); worker = nil; isReady = false
    }

    private func renderPending(workerID id: Int) async {
        var settle: Request?
        while true {
            if pending == nil, let last = settle {
                // The drag ended on a fast frame: show the exact one.
                pending = last
            }
            guard let request = pending else { break }
            pending = nil
            let interactive = settles && dragging && settle == nil
            do {
                let result = try await render(request.page, request.root, interactive)
                guard id == workerID, !Task.isCancelled else { return }
                // Slider frames may be one render behind, but never briefly show
                // another page, crop, orientation or tone after those inputs change.
                if pending.map({ PreviewGeometry($0.page, root: $0.root) == PreviewGeometry(request.page, root: request.root) && $0.page.trimming == request.page.trimming }) ?? true {
                    image = result
                }
                if interactive { settle = request }
                else { if settle?.page == request.page { settle = nil }; if pending == nil { dragging = false } }
                if pending == nil && !interactive { isReady = true }
            } catch {
                guard id == workerID, !Task.isCancelled else { return }
                settle = nil
                if pending == nil { problem = error.localizedDescription; isReady = false }
            }
            // A newer request replaces the frame still to settle.
            if pending != nil { settle = nil }
        }
        if id == workerID { worker = nil; dragging = false }
    }
}

struct ScanPreview: View {
    @EnvironmentObject var store: LibraryStore
    let page: ScanPage
    var onReady: (Bool) -> Void = { _ in }
    @StateObject private var model = ScanPreviewModel()
    @State private var retry = 0
    @State private var enlarged: EnlargedPreview?
    private struct EnlargedPreview: Identifiable {
        let id = UUID()
        let page: ScanPage
        let image: UIImage
        let root: URL
    }
    private struct Request: Equatable { let page: ScanPage; let retry: Int }
    var body: some View {
        ZStack {
            Design.muted
            if let image = model.image {
                Button {
                    enlarged = EnlargedPreview(page: page, image: image, root: store.root)
                } label: {
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.isReady)
                .accessibilityLabel("Enlarge page preview")
                .accessibilityHint("Opens a full-screen preview with pinch to zoom")
                .accessibilityIdentifier("enlarge-page-preview")
            }
            // Keep the last completed frame visible throughout a gesture. Only
            // initial preparation needs a progress indicator over the empty canvas.
            if model.image == nil && model.problem == nil {
                ProgressView("Enhancing your scan…").padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if let problem = model.problem {
                VStack(spacing: 12) { Text(L(problem)).multilineTextAlignment(.center); Button("Retry preview") { retry += 1 } }
                    .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task(id: Request(page: page, retry: retry)) { model.request(page, root: store.root) }
        .onChange(of: model.isReady, initial: true) { _, ready in onReady(ready) }
        .fullScreenCover(item: $enlarged) { selection in
            EnlargedScanPreview(initialImage: selection.image) {
                try await model.fullResolution(selection.page, root: selection.root)
            }
        }
        .onDisappear {
            if enlarged == nil { model.cancel(); onReady(false) }
        }
    }
}
