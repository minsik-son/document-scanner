import SwiftUI
import PhotosUI
import AVFoundation
import UIKit
import CoreImage
import CoreMotion

struct CameraView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let documentID: UUID
    var retakingPageID: UUID? = nil
    var identityCapture = false
    @StateObject private var camera = CameraController()
    @StateObject private var orientation = CaptureOrientationMonitor()
    @State private var saving = false
    @State private var style = CaptureStyle.document
    @State private var autoScan = false
    @State private var error: String?
    @State private var capturedPage: ScanPage?
    @State private var visible = false
    @State private var flash = false
    @State private var shutter = 0
    @State private var importedPhoto: PhotosPickerItem?
    var body: some View {
        ZStack {
            if let capturedPage {
                PageEditor(page: capturedPage, onAddPage: !identityCapture && retakingPageID == nil && !cardComplete ? { updated in try returnToCamera(updated) } : nil, onCancelCapture: {
                    try cancelCapture(capturedPage.id)
                }, doneTitle: identityCapture ? (reviewingFront ? (retakingPageID == nil ? "Use front · Continue" : "Use front · Preview") : "Use back · Preview") : "Done",
                           dismissOnSave: !identityCapture, scanStyle: style, onSave: { updated in
                    try keepAdjustments(updated)
                    if identityCapture {
                        if retakingPageID != nil || cardComplete { dismiss() }
                        else {
                            self.capturedPage = nil
                            camera.beginNextPage()
                            camera.setAutoScan(autoScan)
                            Task { await startCamera() }
                        }
                    }
                }).id(capturedPage.id)
            } else { liveCamera }
        }
        .onAppear {
            style = identityCapture ? .card : (store.document(documentID)?.captureStyle ?? .document)
            camera.setCaptureStyle(style)
            if identityCapture { autoScan = true; camera.setAutoScan(true) }
            visible = true; orientation.start(); Task { await startCamera() }
        }
        .onDisappear { visible = false; orientation.stop(); camera.stop() }
        .onChange(of: importedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { saving = true; await receiveCapture(.success(image)) }
                else { error = "This photo couldn't be imported." }
                importedPhoto = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && capturedPage == nil { Task { await startCamera() } }
            else { camera.stop() }
        }
        .onChange(of: camera.autoCaptureRequest) { _, _ in
            if autoScan && !saving && !cardComplete && capturedPage == nil && camera.ready { capturePage() }
            else { camera.cancelAutoRequest() }
        }
    }
    private var liveCamera: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(controller: camera, tracking: camera.tracking, shutter: shutter).ignoresSafeArea()
            VStack {
                HStack {
                    Button("Close") { dismiss() }.disabled(saving).accessibilityIdentifier("camera-close")
                    Spacer()
                    Text(identityCapture ? "Scan ID card" : (retakingPageID == nil ? "Scan document" : "Retake page")).font(.headline)
                    Button { flash.toggle() } label: { Image(systemName: flash ? "bolt.fill" : "bolt.slash").frame(width: 44, height: 44) }.accessibilityLabel(flash ? "Turn flash off" : "Turn flash on")
                    Spacer()
                    if !identityCapture { Button("Done") { dismiss() }.disabled(saving) }
                }.padding().background(.black.opacity(0.6))
                Spacer()
                if let message = error ?? camera.problem {
                    VStack { Text(message); Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }; PhotosPicker("Import photo instead", selection: $importedPhoto, matching: .images) }.padding().background(.black.opacity(0.8))
                        .accessibilityIdentifier("cameraError")
                }
                if !identityCapture { Picker("Scan mode", selection: $style) {
                    ForEach(CaptureStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).tint(.white).accessibilityIdentifier("capture-style")
                    .disabled(saving).onChange(of: style) { _, value in
                        if var doc = store.document(documentID) { doc.captureStyle = value; store.perform { try store.update(doc) } }
                        autoScan = false; camera.setAutoScan(false); camera.setCaptureStyle(value)
                    }
                }
                Text(style.hint).font(.caption).multilineTextAlignment(.center).padding(.horizontal)
                if captureTurns != 0 {
                    // The interface stays portrait; the finished page is rotated upright.
                    Label { Text("Landscape scan") } icon: {
                        Image(systemName: "rectangle.landscape.rotate")
                            .rotationEffect(.degrees(captureTurns == 1 ? -90 : 90))
                    }
                    .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .accessibilityIdentifier("landscape-capture")
                }
                if let last = store.document(documentID)?.pages.last { PageThumbnail(page: last).frame(width: 45, height: 60).background(.white).accessibilityLabel("Last added page") }
                Text(saving ? "Processing page…" : pageCountLabel)
                    .font(.headline).padding(8).background(.black.opacity(0.6), in: Capsule())
                Text(saving ? "Preparing your preview" : guidance)
                    .font(.subheadline).multilineTextAlignment(.center).padding(8)
                    .accessibilityIdentifier("cameraGuidance")
                if camera.problem != nil && !camera.ready && !saving {
                    Button("Try camera again") { Task { await startCamera() } }
                        .padding(8).background(.white.opacity(0.15), in: Capsule())
                }
                HStack(spacing: 28) {
                    Button {
                        autoScan.toggle(); camera.setAutoScan(autoScan)
                    } label: {
                        Text(autoScan ? "Auto on" : "Auto off")
                            .font(.subheadline.weight(.semibold)).frame(minWidth: 76, minHeight: 44)
                            .background(autoScan ? Color.blue : Color.white.opacity(0.15), in: Capsule())
                    }.accessibilityLabel("Automatic capture")
                        .accessibilityValue(autoScan ? "On" : "Off")
                    Button(action: capturePage) {
                        Circle().fill(.white).frame(width: 72, height: 72)
                            .overlay(Circle().stroke(.black, lineWidth: 3).padding(5))
                    }.accessibilityLabel("Capture page").disabled(saving || cardComplete || (!camera.ready && !testCamera))
                    Color.clear.frame(width: 76, height: 44).accessibilityHidden(true)
                }.padding(.bottom, 24)
            }.foregroundStyle(.white)
        }
    }

    /// ID cards keep their own orientation handling; other modes follow how the
    /// phone is held, so a sideways phone produces a landscape page.
    private var captureTurns: Int { style == .card ? 0 : orientation.turns }
    private var cardComplete: Bool { style == .card && retakingPageID == nil && (store.document(documentID)?.pages.count ?? 0) >= 2 }
    private var reviewingFront: Bool {
        if let retakingPageID { return store.document(documentID)?.pages.first?.id == retakingPageID }
        return (store.document(documentID)?.pages.count ?? 0) == 1
    }
    private var pageCountLabel: String {
        let count = store.document(documentID)?.pages.count ?? 0
        if style == .card {
            if let retakingPageID { return store.document(documentID)?.pages.first?.id == retakingPageID ? "Front of card" : "Back of card" }
            return count == 0 ? "Front of card" : (count == 1 ? "Back of card" : "Both sides added")
        }
        return count == 0 ? "No pages yet" : (count == 1 ? "1 page added" : "\(count) pages added")
    }
    private func cancelCapture(_ pageID: UUID) throws {
        try store.discardCapturedPage(pageID, from: documentID)
        // Retain automatic capture's latch so the rejected sheet is not captured
        // again immediately. The manual shutter remains available for a retake.
        capturedPage = nil
        Task { await startCamera() }
    }
    private func returnToCamera(_ page: ScanPage) throws {
        try keepAdjustments(page)
        camera.beginNextPage()
        capturedPage = nil
        Task { await startCamera() }
    }
    private func keepAdjustments(_ page: ScanPage) throws {
        guard var document = store.document(documentID), let index = document.pages.firstIndex(where: { $0.id == page.id }) else {
            throw ScannerError.message("This page is no longer available.")
        }
        document.pages[index] = page; document.searchable = false
        if let target = retakingPageID, let oldIndex = document.pages.firstIndex(where: { $0.id == target }), oldIndex != index {
            document.pages.remove(at: index)
            document.pages[oldIndex] = page
        }
        try store.update(document)
    }
    private func startCamera() async {
        guard visible, scenePhase == .active, capturedPage == nil, !testCamera, !Task.isCancelled else { return }
        camera.setAutoScan(autoScan)
        await camera.start()
    }
    private var testCamera: Bool {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "--ui-test-session"), args.indices.contains(flag+1), UUID(uuidString: args[flag+1]) != nil {
            return args.contains("--simulate-camera")
        }
#endif
        return false
    }

    private var guidance: String {
        if style == .card {
            switch camera.tracking.phase {
            case .finding, .aligning: return "Keep all four card edges visible"
            case .positioning: return "Hold steady · Detecting card edges"
            case .steady: return autoScan ? "Card detected · Capturing automatically" : "Card detected · Tap the shutter"
            case .nextPage: return "Flip or move the card out of view, then show the other side. You can also tap the shutter."
            }
        }
        if !autoScan && camera.tracking.phase == .nextPage { return "Page detected · Tap to scan another page" }
        return camera.tracking.guidance
    }

    private func capturePage() {
        guard !saving, !cardComplete, capturedPage == nil, camera.ready || testCamera else { return }
        saving = true; error = nil; shutter += 1
        // Read the phone's orientation at the moment of the shutter, not when the
        // photo finishes processing.
        let turns = captureTurns
#if DEBUG
        if testCamera {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let size = style == .card ? CGSize(width: 856, height: 540) : CGSize(width: 600, height: 800)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor(white: 0.9, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
                ("CAPTURED PAGE \((store.document(documentID)?.pages.count ?? 0)+1)" as NSString).draw(at: CGPoint(x: 60, y: 140), withAttributes: [.font: UIFont.systemFont(ofSize: 34), .foregroundColor: UIColor.black])
            }
            Task { await receiveCapture(.success(image), turns: turns) }
            return
        }
#endif
        camera.capture(flash: flash) { result in
            Task { @MainActor in await receiveCapture(result, turns: turns) }
        }
    }
    @MainActor private func receiveCapture(_ result: Result<UIImage, Error>, turns: Int = 0) async {
        do {
            let image = try result.get()
            let mode = style
            let prepared = await Task.detached { () -> (UIImage, ScanQuad?) in
                let normalized = Imaging.normalized(image)
                return (normalized, mode.detect(normalized, capturedPhoto: true))
            }.value
            try store.appendImage(prepared.0, to: documentID, detectedCrop: testCamera ? .full : prepared.1, enhancement: mode.enhancement, style: mode, turns: turns)
            // Persist original pixels first. Stop capture while the user decides;
            // neither automatic capture nor app foregrounding skips this review.
            camera.stop()
            capturedPage = store.document(documentID)?.pages.last
        } catch {
            self.error = "This page wasn't saved. \(error.localizedDescription)"
            camera.finishSaving()
        }
        saving = false
    }
}

final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "scanner.camera", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var tracker = LiveDocumentTracker()
    private var completion: ((Result<UIImage, Error>) -> Void)?
    private var captureID: Int64?
    private var active = false
    private var configured = false
    private var busy = false
    private var autoEnabled = false
    private var autoPending = false
    private var captureStyle = CaptureStyle.document
    private var visibleCardArea: ScanQuad?
    private var device: AVCaptureDevice? // Session queue only.
    private var lastAnalysis: TimeInterval = -Double.infinity
    private var generation = 0 // Session queue only.
    private var sessionRequestToken = 0 // Session queue only.
    private var requestToken = 0 // Main actor only.
    private var notificationObservers: [NSObjectProtocol] = []
    @Published private(set) var ready = false
    @Published private(set) var problem: String?
    @Published private(set) var tracking = LiveDocumentSnapshot()
    @Published private(set) var autoCaptureRequest = 0

    override init() {
        super.init()
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            notificationObservers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.sessionFailed() }
            })
        }
        notificationObservers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                let token = self.sessionRequestToken
                DispatchQueue.main.async {
                    Task { @MainActor in
                        guard self.requestToken == token else { return }
                        await self.start()
                    }
                }
            }
        })
    }
    deinit { notificationObservers.forEach(NotificationCenter.default.removeObserver) }

    @MainActor func start() async {
        requestToken += 1
        let token = requestToken
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard requestToken == token else { return }
        guard allowed else {
            ready = false
            problem = "Camera access is off. Allow it in Settings, or import a photo from Documents."
            return
        }
        queue.async {
            do {
                self.sessionRequestToken = token
                if self.active && self.session.isRunning && !self.session.isInterrupted {
                    let isReady = !self.busy
                    DispatchQueue.main.async {
                        guard self.requestToken == token else { return }
                        self.problem = nil; self.ready = isReady
                    }
                    return
                }
                if !self.configured {
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    self.session.inputs.forEach(self.session.removeInput)
                    self.session.outputs.forEach(self.session.removeOutput)
                    self.session.sessionPreset = .photo
                    // Prefer the multi-camera device, like the Camera app: when the phone
                    // is closer than the main lens can focus, iOS switches to the macro-
                    // capable ultra wide automatically instead of producing a soft photo.
                    let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
                    guard let device = types.lazy.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first else {
                        throw ScannerError.message("A camera is unavailable. Use Import on this device.")
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard self.session.canAddInput(input), self.session.canAddOutput(self.photoOutput), self.session.canAddOutput(self.videoOutput) else {
                        throw ScannerError.message("The camera couldn't start.")
                    }
                    self.session.addInput(input)
                    self.session.addOutput(self.photoOutput)
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                    // Largest still the format offers up to ~25 MP (24 MP on recent Pro
                    // phones, 12 MP elsewhere). 48 MP is skipped: it disables multi-frame
                    // processing on some models and multiplies memory for every page.
                    let dimensions = device.activeFormat.supportedMaxPhotoDimensions
                        .filter { Int($0.width)*Int($0.height) <= 25_000_000 }
                        .max { Int($0.width)*Int($0.height) < Int($1.width)*Int($1.height) }
                    if let dimensions { self.photoOutput.maxPhotoDimensions = dimensions }
                    self.device = device
                    self.configureFocus(device, style: self.captureStyle)
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                    self.session.addOutput(self.videoOutput)
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.queue)
                    for output in [self.photoOutput as AVCaptureOutput, self.videoOutput] {
                        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) else {
                            throw ScannerError.message("This camera couldn't provide a portrait scan preview. Try importing a photo instead.")
                        }
                        connection.videoRotationAngle = 90
                        if connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
                        }
                    }
                    self.configured = true
                }
                self.generation += 1
                self.active = true
                self.tracker.clearPreview()
                self.lastAnalysis = -Double.infinity
                if !self.session.isRunning { self.session.startRunning() }
                guard self.session.isRunning, !self.session.isInterrupted else {
                    throw ScannerError.message("The camera is temporarily unavailable. Try again when it is free.")
                }
                let isReady = !self.busy
                DispatchQueue.main.async {
                    guard self.requestToken == token else { return }
                    self.problem = nil; self.ready = isReady; self.tracking = LiveDocumentSnapshot()
                }
            } catch {
                self.active = false; self.generation += 1; self.tracker.clearPreview()
                DispatchQueue.main.async {
                    guard self.requestToken == token else { return }
                    self.ready = false; self.problem = error.localizedDescription
                }
            }
        }
    }

    @MainActor func stop() {
        requestToken += 1; ready = false; tracking = LiveDocumentSnapshot()
        queue.async {
            self.active = false; self.generation += 1; self.autoPending = false
            self.tracker.clearPreview()
            let pending = self.completion
            self.completion = nil; self.captureID = nil; self.busy = false
            if self.session.isRunning { self.session.stopRunning() }
            if let pending {
                DispatchQueue.main.async { pending(.failure(ScannerError.message("Capture was interrupted. Try again when the camera is open."))) }
            }
        }
    }

    func setAutoScan(_ enabled: Bool) {
        queue.async { self.autoEnabled = enabled; self.autoPending = false }
    }
    /// Paper is usually 15–40 cm away: restricting autofocus to near distances makes it
    /// lock faster and stops it hunting toward the background. Whiteboards and slides
    /// can be far away, so they keep the full range. The virtual device starts at 1x
    /// (main lens) rather than its widest lens.
    private func configureFocus(_ device: AVCaptureDevice, style: CaptureStyle) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.isVirtualDevice, device.videoZoomFactor == 1,
           let main = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            device.videoZoomFactor = CGFloat(truncating: main)
        }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = (style == .whiteboard || style == .slides) ? .none : .near
        }
        if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
    }

    func setCaptureStyle(_ style: CaptureStyle) {
        queue.async {
            if let device = self.device { self.configureFocus(device, style: style) }
            self.captureStyle = style; self.tracker.beginNextPage()
            self.autoPending = false; self.lastAnalysis = -Double.infinity
        }
    }
    func setVisibleCardArea(_ area: ScanQuad?) {
        queue.async { self.visibleCardArea = area }
    }
    func cancelAutoRequest() {
        queue.async { self.autoPending = false }
    }
    func beginNextPage() {
        queue.async {
            self.tracker.beginNextPage()
            self.autoPending = false; self.lastAnalysis = -Double.infinity
        }
    }

    private func sessionFailed() {
        guard active else { return }
        active = false; generation += 1; autoPending = false
        let token = sessionRequestToken
        let pending = completion
        completion = nil; captureID = nil; busy = false
        tracker.clearPreview()
        DispatchQueue.main.async {
            pending?(.failure(ScannerError.message("The camera was interrupted. Try scanning this page again.")))
            guard self.requestToken == token else { return }
            self.ready = false; self.tracking = LiveDocumentSnapshot()
            self.problem = "The camera was interrupted. Tap Try camera again when it is available."
        }
    }

    @MainActor func capture(flash: Bool = false, completion: @escaping (Result<UIImage, Error>) -> Void) {
        ready = false
        queue.async {
            guard self.active, self.session.isRunning, !self.session.isInterrupted, !self.busy else {
                DispatchQueue.main.async { completion(.failure(ScannerError.message("The camera isn't ready. Try again."))) }
                return
            }
            self.busy = true; self.autoPending = false; self.tracker.markCapture()
            self.completion = completion
            let settings = AVCapturePhotoSettings()
            // Quality prioritization lets iOS apply its multi-frame processing (Deep
            // Fusion / Photonic Engine) — the same post-capture sharpening as the Camera app.
            settings.photoQualityPrioritization = .quality
            let maximum = self.photoOutput.maxPhotoDimensions
            if maximum.width > 0, maximum.height > 0 { settings.maxPhotoDimensions = maximum }
            if self.photoOutput.supportedFlashModes.contains(flash ? .on : .off) { settings.flashMode = flash ? .on : .off }
            self.captureID = settings.uniqueID
            // Pressing the shutter can start a refocus; a photo taken mid-hunt is soft.
            self.afterFocusSettles(attempt: 0) {
                guard self.active, self.captureID == settings.uniqueID, self.completion != nil else { return }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    /// Waits up to 0.6 s on the session queue for autofocus to finish.
    private func afterFocusSettles(attempt: Int, _ action: @escaping () -> Void) {
        guard let device, device.isAdjustingFocus, attempt < 6 else { action(); return }
        queue.asyncAfter(deadline: .now() + 0.1) { self.afterFocusSettles(attempt: attempt + 1, action) }
    }

    func finishSaving() {
        queue.async {
            self.busy = false
            let running = self.active && self.session.isRunning && !self.session.isInterrupted
            let generation = self.generation
            DispatchQueue.main.async {
                guard running else { return }
                self.publishIfCurrent(generation) { self.ready = true }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active, !busy else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAnalysis >= (captureStyle == .card ? 0.15 : 0.22), let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        let found: ScanQuad? = autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            // Bound segmentation work independently of camera recording resolution.
            let limit: CGFloat = self.captureStyle == .card ? 1280 : 1024
            let scale = min(1, limit / max(image.extent.width, image.extent.height))
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = imageContext.createCGImage(small, from: small.extent) else { return nil }
            return self.captureStyle == .card ? CaptureStyle.card.detect(UIImage(cgImage: cg)) : DocumentProcessing.detect(cg)
        }
        let card = captureStyle == .card
        let eligible = !card || CaptureStyle.fullyVisible(found, in: visibleCardArea)
        // Two consistent analysis frames qualify an ID. No green-state timer:
        // the same qualifying frame publishes green and requests the shutter.
        let state = tracker.update(found, at: now, eligible: eligible,
                                   requiredSteadyDuration: card ? 0.12 : 0.8,
                                   missingReleaseDuration: card ? 0.2 : 0.8)
        let generation = self.generation
        let shouldCapture = autoEnabled && !autoPending && state.canAutoCapture
        if shouldCapture { autoPending = true }
        DispatchQueue.main.async {
            self.publishIfCurrent(generation) {
                self.tracking = state
                if shouldCapture { self.autoCaptureRequest += 1 }
            }
        }
    }

    // Checking generation on the session queue keeps old analysis from repainting
    // a stopped/new session. Delivery on main is also guarded by the UI token.
    private func publishIfCurrent(_ expected: Int, action: @escaping () -> Void) {
        let token = requestToken
        queue.async {
            guard self.active, self.generation == expected else { return }
            DispatchQueue.main.async {
                guard self.requestToken == token else { return }
                action()
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let result: Result<UIImage, Error>
        if let error { result = .failure(error) }
        else if let data = photo.fileDataRepresentation(), let image = UIImage(data: data) { result = .success(image) }
        else { result = .failure(ScannerError.message("The camera didn't return a photo. Try again.")) }
        queue.async { self.deliver(result, captureID: photo.resolvedSettings.uniqueID) }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        queue.async {
            if let error { self.deliver(.failure(error), captureID: resolvedSettings.uniqueID) }
            else if self.captureID == resolvedSettings.uniqueID, self.completion != nil {
                self.deliver(.failure(ScannerError.message("The camera didn't return a photo. Try again.")), captureID: resolvedSettings.uniqueID)
            }
        }
    }
    private func deliver(_ result: Result<UIImage, Error>, captureID: Int64) {
        guard active, self.captureID == captureID, let pending = completion else { return }
        completion = nil; self.captureID = nil
        DispatchQueue.main.async { pending(result) }
    }
}

final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private let fill = CAShapeLayer()
    /// Page edges drawn as lines that run past the corners, so each corner
    /// reads as a cross. They cut in like quick strokes when a page is found.
    private let edges: [CAShapeLayer] = (0..<4).map { _ in CAShapeLayer() }
    /// Two strokes across the page when the shutter fires.
    private let slash = CAShapeLayer()
    private var points: [CGPoint] = []
    private var shownQuad = false
    private var lastPhase: LiveDocumentSnapshot.Phase?
    var onVisibleArea: ((ScanQuad?) -> Void)?
    var tracking = LiveDocumentSnapshot() { didSet { redraw() } }
    var shutter = 0 { didSet { if shutter != oldValue { playShutter() } } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        fill.fillColor = UIColor.systemBlue.withAlphaComponent(0.12).cgColor
        fill.strokeColor = nil
        layer.addSublayer(fill)
        for edge in edges {
            edge.lineWidth = 2.5; edge.lineCap = .round; edge.fillColor = nil
            edge.shadowOffset = .zero; edge.shadowRadius = 5
            layer.addSublayer(edge)
        }
        slash.lineWidth = 3; slash.lineCap = .round; slash.fillColor = nil
        slash.strokeColor = UIColor.white.cgColor
        slash.shadowColor = UIColor.white.cgColor; slash.shadowOpacity = 0.9; slash.shadowRadius = 8; slash.shadowOffset = .zero
        slash.opacity = 0
        layer.addSublayer(slash)
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
            }
        }
        fill.frame = bounds; slash.frame = bounds
        edges.forEach { $0.frame = bounds }
        let rect = bounds.insetBy(dx: 8, dy: 8)
        let corners = [CGPoint(x:rect.minX,y:rect.minY), CGPoint(x:rect.maxX,y:rect.minY),
                       CGPoint(x:rect.maxX,y:rect.maxY), CGPoint(x:rect.minX,y:rect.maxY)]
        let area = ScanQuad(points:corners.map {
            let sensor = preview.captureDevicePointConverted(fromLayerPoint:$0)
            return ScanPoint(x:1-sensor.y,y:sensor.x)
        })
        onVisibleArea?(preview.connection == nil ? nil : area)
        redraw()
    }
    private var animates: Bool { !UIAccessibility.isReduceMotionEnabled }
    private func redraw() {
        guard let quad = tracking.quad else {
            fill.path = nil; edges.forEach { $0.path = nil }
            points = []; shownQuad = false; lastPhase = tracking.phase
            return
        }
        points = quad.points.map {
            preview.layerPointConverted(fromCaptureDevicePoint: LiveDocumentTracker.captureDevicePoint(fromPortrait: $0))
        }
        let steady = tracking.phase == .steady
        let color: UIColor = steady ? .systemGreen : .systemBlue
        let outline = UIBezierPath()
        outline.move(to: points[0]); points.dropFirst().forEach { outline.addLine(to: $0) }; outline.close()
        fill.path = outline.cgPath
        fill.fillColor = color.withAlphaComponent(0.12).cgColor
        for (i, edge) in edges.enumerated() {
            let a = points[i], b = points[(i + 1) % 4]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 1 else { edge.path = nil; continue }
            let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
            let reach = min(34, length * 0.16)
            let line = UIBezierPath()
            line.move(to: CGPoint(x: a.x - ux * reach, y: a.y - uy * reach))
            line.addLine(to: CGPoint(x: b.x + ux * reach, y: b.y + uy * reach))
            edge.path = line.cgPath
            edge.strokeColor = color.cgColor
            edge.shadowColor = color.cgColor
            edge.shadowOpacity = steady ? 0.9 : 0.5
        }
        // A newly found page, or a page that just became steady, gets the strokes.
        if animates && (!shownQuad || (steady && lastPhase != .steady)) { cutIn(fast: shownQuad) }
        shownQuad = true; lastPhase = tracking.phase
    }
    private func cutIn(fast: Bool) {
        let now = CACurrentMediaTime()
        for (i, edge) in edges.enumerated() {
            let stroke = CABasicAnimation(keyPath: "strokeEnd")
            stroke.fromValue = 0; stroke.toValue = 1
            stroke.duration = fast ? 0.18 : 0.26
            stroke.beginTime = now + Double(i) * (fast ? 0.035 : 0.06)
            stroke.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            stroke.fillMode = .backwards
            edge.add(stroke, forKey: "cut")
            let glow = CAKeyframeAnimation(keyPath: "shadowRadius")
            glow.values = [5, 14, 5]; glow.duration = stroke.duration + 0.2; glow.beginTime = stroke.beginTime
            edge.add(glow, forKey: "glow")
        }
    }
    private func playShutter() {
        guard animates else { return }
        let p = points.count == 4 ? points : {
            let r = bounds.insetBy(dx: bounds.width * 0.12, dy: bounds.height * 0.18)
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        }()
        let path = UIBezierPath()
        path.move(to: p[0]); path.addLine(to: p[2])
        path.move(to: p[1]); path.addLine(to: p[3])
        slash.path = path.cgPath
        let now = CACurrentMediaTime()
        let stroke = CABasicAnimation(keyPath: "strokeEnd")
        stroke.fromValue = 0; stroke.toValue = 1; stroke.duration = 0.16
        stroke.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]; fade.keyTimes = [0, 0.45, 1]; fade.duration = 0.42
        let group = CAAnimationGroup()
        group.animations = [stroke, fade]; group.duration = 0.42; group.beginTime = now
        slash.add(group, forKey: "shutter")
        for edge in edges {
            let flash = CAKeyframeAnimation(keyPath: "strokeColor")
            flash.values = [UIColor.white.cgColor, edge.strokeColor ?? UIColor.white.cgColor]
            flash.duration = 0.35
            edge.add(flash, forKey: "flash")
        }
    }
}
struct CameraPreview: UIViewRepresentable {
    let controller: CameraController
    let tracking: LiveDocumentSnapshot
    var shutter = 0
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.preview.session = controller.session; view.preview.videoGravity = .resizeAspectFill
        view.clipsToBounds = true; view.tracking = tracking
        view.onVisibleArea = { [weak controller] area in controller?.setVisibleCardArea(area) }
        return view
    }
    func updateUIView(_ uiView: PreviewSurface, context: Context) {
        uiView.tracking = tracking
        uiView.shutter = shutter
        uiView.setNeedsLayout()
    }
}

/// Maps gravity in device coordinates to the page rotation a capture needs.
/// The camera interface is portrait-only, so photos are always portrait; a phone
/// turned sideways should still produce a landscape page that reads upright.
/// `turns` follows `ScanPage.turns`: clockwise quarter turns.
enum CaptureOrientation {
    static func turns(gravityX x: Double, gravityY y: Double, previous: Int) -> Int {
        // Held nearly flat over a page, x/y carry no reliable orientation:
        // keep the last decision instead of flipping on small hand movements.
        guard hypot(x, y) >= 0.35 else { return previous }
        // 0° upright portrait, +90° top pointing right, -90° top pointing left.
        let angle = atan2(x, -y) * 180 / .pi
        let centers: [Int: Double] = [0: 0, 1: 90, 3: -90]
        let candidate: Int
        switch angle {
        case -45...45: candidate = 0
        case 45...135: candidate = 1
        case -135 ... -45: candidate = 3
        default: return previous // Upside down: not a supported scanning posture.
        }
        guard candidate != previous else { return previous }
        // Hysteresis: change only when clearly past the 45° boundary.
        return abs(angle - centers[candidate]!) <= 35 ? candidate : previous
    }
}

/// Device-motion gravity works with the system rotation lock on and with the
/// app's portrait-only interface, unlike interface orientation.
final class CaptureOrientationMonitor: ObservableObject {
    @Published private(set) var turns = 0
    private let motion = CMMotionManager()
    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 15
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let gravity = data?.gravity else { return }
            let next = CaptureOrientation.turns(gravityX: gravity.x, gravityY: gravity.y, previous: self.turns)
            if next != self.turns { self.turns = next }
        }
    }
    func stop() {
        motion.stopDeviceMotionUpdates()
        turns = 0
    }
    deinit { motion.stopDeviceMotionUpdates() }
}
