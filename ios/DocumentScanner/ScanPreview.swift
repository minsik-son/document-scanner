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
                let result = try PerfTrace.measure("preview prepare (flatten, lighting)") { try DocumentProcessing.prepare(source, crop: page.crop, turns: page.turns, enhancement: page.enhancement, identityCleanup: key.identityCleanup, flatten: key.flatten) }
                try Task.checkCancellation()
                prepared = result; geometry = key; toneStrength = nil; toneImage = nil
            }
            guard let prepared else { throw ScannerError.message("The preview couldn't be prepared.") }
            if let maxDimension, !interactive {
                // Exactly Imaging.render (same decode, same prepared geometry, full
                // resolution tone and adjustments), then the same resize as export.
                let finished = try DocumentProcessing.finish(prepared, strength: page.enhancementStrength)
                let adjusted = try Imaging.trim(DocumentProcessing.adjust(finished, settings: page.appearance), edges: page.trimming)
                guard let raster = PerfTrace.measure("preview tone \(Int(adjusted.extent.width))x\(Int(adjusted.extent.height))", { DocumentProcessing.context.createCGImage(adjusted, from: adjusted.extent) }) else {
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


/// The camera's instant result: a quick page from the preview frame, its soft
/// "before" look, and when the shutter was pressed (so the animation continues
/// across screens). Both images are made and decoded off the main thread, so the
/// animation only moves them (no per-frame blur).
struct InstantPlaceholder: Equatable {
    let image: UIImage
    let soft: UIImage
    let start: Date
    nonisolated static func make(_ page: UIImage, start: Date) -> InstantPlaceholder? {
        guard let cg = page.cgImage else { return nil }
        // The page is shown about 1000 px tall on a phone.
        let scale = min(1, 1100 / CGFloat(max(cg.width, cg.height)))
        let clean = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = clean.extent.integral
        let soft = clean.clampedToExtent().applyingGaussianBlur(sigma: 2.2).cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.6])
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: CIImage(color: CIColor(red: 0.80, green: 0.78, blue: 0.73)).cropped(to: extent)])
        guard let a = DocumentProcessing.context.createCGImage(clean, from: extent),
              let b = DocumentProcessing.context.createCGImage(soft, from: extent),
              let shown = UIImage(cgImage: a).preparingForDisplay(), let before = UIImage(cgImage: b).preparingForDisplay() else { return nil }
        return InstantPlaceholder(image: shown, soft: before, start: start)
    }
}

/// The scan-to-PDF animation over the instant result. The preview page sits on
/// the canvas like a sheet of paper; a blue scan beam sweeps it from soft and
/// warm to clean, keeps passing while the page is saved and enhanced, and when
/// `done` the page lifts, its corner folds, a PDF badge lands and a check appears.
struct ScanBeamPage: View {
    let placeholder: InstantPlaceholder
    let done: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let reveal: TimeInterval = 1.2
    private static let pass: TimeInterval = 1.5
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: done || reduceMotion)) { timeline in
            let t = max(0, timeline.date.timeIntervalSince(placeholder.start))
            #if DEBUG
            let _ = HitchMeter.shared.tick(timeline.date, done: done)
            #endif
            let revealing = !reduceMotion && t < Self.reveal
            let progress = revealing ? Self.ease(t / Self.reveal) : 1
            let beam = revealing ? progress : Self.ease((t - Self.reveal).truncatingRemainder(dividingBy: Self.pass) / Self.pass)
            ZStack {
                Design.muted
                sheet(revealed: progress, beam: beam, beamOpacity: done || reduceMotion ? 0 : (revealing ? 1 : 0.55))
                    .padding(.horizontal, 30).padding(.vertical, 26)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.62), value: done)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L(done ? "Done" : "Preparing PDF…"))
    }
    private static func ease(_ x: Double) -> CGFloat { CGFloat(x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2) }
    private func sheet(revealed: CGFloat, beam: CGFloat, beamOpacity: Double) -> some View {
        GeometryReader { box in
            let image = placeholder.image
            let aspect = image.size.width / max(1, image.size.height)
            let width = min(box.size.width, box.size.height * aspect)
            let height = width / aspect
            ZStack(alignment: .top) {
                Image(uiImage: image).resizable()
                // Not yet swept: the soft "before" image, cut at the beam (a clip,
                // not a mask, so nothing is rendered offscreen each frame).
                Image(uiImage: placeholder.soft).resizable()
                    .frame(width: width, height: height)
                    .frame(width: width, height: max(0, height * (1 - revealed)), alignment: .bottom)
                    .clipped()
                    .frame(width: width, height: height, alignment: .bottom)
                // The beam: a soft glow trailing a bright scan line (gradients only).
                VStack(spacing: 0) {
                    LinearGradient(colors: [Design.blue.opacity(0), Design.blue.opacity(0.10), Design.blue.opacity(0.32)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 64)
                    Rectangle().fill(Design.blue).frame(height: 2.5)
                    LinearGradient(colors: [Design.blue.opacity(0.35), Design.blue.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 6)
                }
                .offset(y: height * beam - 66.5)
                .opacity(beamOpacity)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            // The paper's shadow comes from a still shape behind it, so the moving
            // beam never forces an offscreen shadow pass.
            .background {
                RoundedRectangle(cornerRadius: 4).fill(.white)
                    .shadow(color: .black.opacity(done ? 0.16 : 0.09), radius: done ? 14 : 6, y: done ? 8 : 3)
            }
            .overlay(alignment: .topTrailing) {
                // The folded corner.
                ZStack(alignment: .topTrailing) {
                    Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 30, y: 0)); p.addLine(to: CGPoint(x: 30, y: 30)); p.closeSubpath() }.fill(Design.muted)
                    Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 30, y: 30)); p.addLine(to: CGPoint(x: 0, y: 30)); p.closeSubpath() }
                        .fill(LinearGradient(colors: [Color(red: 0.86, green: 0.88, blue: 0.91), Color(red: 0.74, green: 0.78, blue: 0.83)], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .frame(width: 30, height: 30)
                .scaleEffect(done ? 1 : 0.01, anchor: .topTrailing)
            }
            .scaleEffect(done ? 1.02 : 1)
            .offset(y: done ? -4 : 0)
            .overlay(alignment: .bottomTrailing) {
                Text("PDF").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(red: 0.94, green: 0.27, blue: 0.32), in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: Color(red: 0.94, green: 0.27, blue: 0.32).opacity(0.35), radius: 6, y: 3)
                    .offset(x: 10, y: 10)
                    .scaleEffect(done ? 1 : 0.01)
                    .rotationEffect(.degrees(done ? -6 : -30))
            }
            .overlay {
                Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 64, height: 64).background(Design.blue, in: Circle())
                    .shadow(color: Design.blue.opacity(0.35), radius: 10, y: 4)
                    .scaleEffect(done ? 1 : 0.01).opacity(done ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The steps behind the "Preparing PDF" screen, ticked off as they finish.
struct ScanProgressSteps: View {
    enum Stage: Int { case saving, enhancing, done }
    let stage: Stage
    private let steps = ["Saving the photo", "Flattening the page and evening out the light", "Making the PDF"]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                let state = index < active ? 2 : (index == active ? 1 : 0)
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(state == 2 ? Design.blue : Design.muted).frame(width: 26, height: 26)
                        if state == 2 { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                        else if state == 1 { ProgressView().controlSize(.small) }
                    }
                    Text(L(title)).font(.subheadline.weight(state == 1 ? .semibold : .regular))
                        .foregroundStyle(state == 0 ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
                .animation(.easeInOut(duration: 0.25), value: state)
            }
        }
        .padding(18)
        .background(Design.muted.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
    }
    /// The step in progress (3 = all done). Making the PDF follows the enhanced page.
    private var active: Int { stage == .saving ? 0 : (stage == .enhancing ? 1 : 3) }
}

#if DEBUG
/// Debug builds: logs frames of the scan animation that arrive late (a hitch).
final class HitchMeter: @unchecked Sendable {
    static let shared = HitchMeter()
    private var last: Date?
    @discardableResult func tick(_ date: Date, done: Bool) -> Bool {
        defer { last = done ? nil : date }
        guard let last, !done else { return false }
        let gap = date.timeIntervalSince(last)
        if gap > 0.05 && gap < 5 { PerfTrace.note(String(format: "  animation hitch %.0f ms", gap * 1000)) }
        return true
    }
}
#endif
