import SwiftUI

/// Runs a state change without animation, so a full-screen camera appears at once.
enum Instant {
    static func run(_ change: () -> Void) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

struct ReviewView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    let documentID: UUID
    var captureOnOpen = false
    var completionAdEnabled = false
    var onCompleted: () -> Void = {}
    @EnvironmentObject private var completionAds: CompletionAdvertisementStore
    @EnvironmentObject private var homeAds: HomeAdvertisementStore
    @EnvironmentObject private var subscription: SubscriptionStore
    @EnvironmentObject private var lock: AppLock
    @Environment(\.scenePhase) private var scenePhase
    @State private var adSession = UUID()
    @State private var finishing = false
    @State private var startedAdSession = false
    private var adPolicy: HomeAdEligibility {
        HomeAdEligibility(subscriptionResolved: subscription.entitlementsResolved,
                          isPro: subscription.isPro, online: homeAds.online,
                          foreground: scenePhase == .active, homeVisible: completionAdEnabled && saved && !saving,
                          unlocked: !lock.locked, configured: HomeAdConfiguration.testAdsEnabled)
    }
    @State private var document: ScanDocument?
    @State private var camera = false
    /// A new scan opens straight into the camera; the review list appears only
    /// after the first page, never as an empty screen in front of the camera.
    @State private var cameraFirst = true
    @State private var identityLayout = false
    @State private var editPage: ScanPage?
    @State private var saving = false
    @State private var saveProgress = "Saving PDF…"
    @State private var textNotice: String?
    @State private var textRetryNeeded = false
    @State private var saved = false
    @State private var error: String?
    @State private var options = false
    @State private var cropReviewPage: ScanPage?
    @State private var resumeSaveAfterCrop = false
    @State private var cropWasConfirmed = false
    @State private var undoHistory: [ScanDocument] = []
    @State private var redoHistory: [ScanDocument] = []
    @State private var deletingLast = false
    @State private var retakingPage: UUID?
    @State private var workingDraftID: UUID?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if captureOnOpen && cameraFirst {
                    Color.black.ignoresSafeArea().toolbar(.hidden, for: .navigationBar)
                } else if let doc = document {
                    if saved {
                        VStack(spacing: 24) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Design.blue)
                            Text("Saved on this iPhone").font(.title.bold())
                            Text(doc.title).foregroundStyle(.secondary)
                            if doc.searchable { Text("Text can be selected and copied in your PDF.").font(.subheadline).foregroundStyle(.secondary) }
                            if let textNotice { Text(textNotice).font(.subheadline).foregroundStyle(.secondary) }
                            if textRetryNeeded { Button("Retry text recognition") { save(forceText: false) }.disabled(saving) }
                            if saving { ProgressView(saveProgress) }
                            if let error { Text(error).font(.subheadline).foregroundStyle(.red) }
                            if let file = store.document(documentID)?.pdfFile { ShareLink(item: store.url(file)) { Label("Share PDF", systemImage: "square.and.arrow.up") }.buttonStyle(PrimaryButton()) }
                            if doc.captureStyle == .card {
                                Button("Arrange ID card on one page") { identityLayout = true }.buttonStyle(.bordered)
                            }
                            Button("Done") {
                                guard !finishing else { return }; finishing = true
                                if completionAdEnabled {
                                    completionAds.finish(session: adSession, policy: adPolicy,
                                                         onPresented: { homeAds.suppressAfterCompletion() },
                                                         completion: { onCompleted(); dismiss() })
                                } else { onCompleted(); dismiss() }
                            }.font(.headline).disabled(saving || finishing).accessibilityIdentifier("saved-done")
                        }.padding(24)
                    } else {
                        List {
                            Section {
                                ForEach(Array(doc.pages.enumerated()), id: \.element.id) { index, page in
                                    HStack(spacing: 12) {
                                        Button { editPage = page } label: {
                                            HStack(spacing: 16) { PageThumbnail(page: page).frame(width: 74, height: 96); VStack(alignment: .leading, spacing: 6) { Text("Page \(index+1)").font(.headline); Text(page.cropReviewNeeded == true ? "Check page edges" : "Crop, rotate, and adjust").font(.subheadline).foregroundStyle(page.cropReviewNeeded == true ? Color.orange : Color.secondary) }; Spacer() }.foregroundStyle(Design.ink)
                                        }.accessibilityLabel("Edit page \(index+1)").buttonStyle(.borderless)
                                        Menu {
                                            Button("Duplicate page") { change { value in var copy = page; copy.id = UUID(); value.pages.insert(copy, at: index+1) } }
                                            Button("Retake page") { openCamera(retaking: page.id) }
                                            Button("Apply tone and adjustments to all pages") { change { $0.applyAppearance(from: page) } }
                                                .disabled(doc.pages.contains { $0.preservesPDF })
                                            Button("Move earlier") { change { $0.pages.swapAt(index, index-1) } }.disabled(index == 0)
                                            Button("Move later") { change { $0.pages.swapAt(index, index+1) } }.disabled(index == doc.pages.count-1)
                                        } label: { Image(systemName:"ellipsis.circle").frame(width:44,height:44) }
                                        .accessibilityLabel("Page \(index+1) actions").accessibilityIdentifier("page-actions-\(index+1)")
                                    }
                                }.onMove { source, destination in change { $0.pages.move(fromOffsets: source, toOffset: destination) } }
                                .onDelete { indices in
                                    if indices.count == doc.pages.count { deletingLast = true }
                                    else { change { $0.pages.remove(atOffsets: indices) } }
                                }
                                if doc.pages.isEmpty { Text("Add a page to get started.").foregroundStyle(.secondary) }
                            } header: { Text("\(doc.pages.count) pages") }
                            Section {
                                TextField("Document name", text: Binding(get: { document?.title ?? "" }, set: { document?.title = $0; persistDraft() }))
                                DisclosureGroup("Save options", isExpanded: $options) {
                                    Picker("Folder", selection: Binding(get: { document?.folder ?? "Scans" }, set: { document?.folder = $0; persistDraft() })) { ForEach(store.manifest.folders, id: \.self) { Text($0).tag($0) } }
                                    Picker("Paper", selection: Binding(get: { document?.paper ?? .letter }, set: { document?.paper = $0; persistDraft() })) { ForEach(PaperSize.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                                    Toggle("Landscape", isOn: Binding(get: { document?.landscape ?? false }, set: { value in change { $0.landscape = value } }))
                                    Picker("Margins", selection: Binding(get: { document?.margin ?? .small }, set: { document?.margin = $0; persistDraft() })) { ForEach(PageMargin.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                                    if doc.pages.contains(where: { $0.trimming != .zero }) { Text("For no added white space, choose Original paper and None margins. A4 and US Letter keep their shape and may add white space.").font(.caption).foregroundStyle(.secondary) }
                                    if doc.pages.contains(where: { $0.sourcePDF != nil }) { Text("Changing PDF paper or margins keeps text and links but flattens interactive forms. The imported original is retained.").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            if let error { Section { Text(error).foregroundStyle(.red) } }
                        }.listStyle(.insetGrouped).disabled(saving)
                        .safeAreaInset(edge: .bottom) {
                            VStack(spacing: 12) {
                                Button { openCamera(retaking: nil) } label: { Label("Add pages", systemImage: "camera") }.font(.headline).padding(8).disabled(saving)
                                if saving { Text(saveProgress).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("save-progress") }
                                Button { save() } label: { if saving { ProgressView().tint(Design.blueInk).frame(maxWidth: .infinity) } else { Text(doc.isDraft ? "Save PDF" : "Save changes") } }.buttonStyle(PrimaryButton()).disabled(saving || doc.pages.isEmpty)
                            }.padding(20).background(.white)
                        }
                    }
                } else { ProgressView() }
            }
            .navigationTitle(saved ? "" : "Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { if !saved { Button(document?.isDraft == true ? "Close" : "Cancel") { cancelEditing() }.disabled(saving) } }
                ToolbarItemGroup(placement: .bottomBar) {
                    if !saved { Button("Undo") { restoreHistory(undo: true) }.disabled(undoHistory.isEmpty || saving); Button("Redo") { restoreHistory(undo: false) }.disabled(redoHistory.isEmpty || saving) }
                }
                ToolbarItem(placement: .topBarTrailing) { if !saved { EditButton().disabled(saving) } }
            }
            .overlay(alignment: .top) { if saving { Button("Cancel export") { saveTask?.cancel() }.padding(10).background(.regularMaterial, in: Capsule()) } }
            .alert("Delete the last page?", isPresented: $deletingLast) {
                Button("Move document to Trash", role: .destructive) { if let doc = store.document(documentID) { store.moveToTrash(doc); if store.problem == nil { cancelEditing() } } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Removing the last page moves this document to Trash, where it can be restored.") }
            .interactiveDismissDisabled(saving)
            .onAppear {
                guard document == nil else { return }
                document = store.document(documentID)
                if captureOnOpen {
                    Instant.run { camera = true }
                }
            }
            .onAppear {
                if completionAdEnabled && !startedAdSession {
                    startedAdSession = true; homeAds.beginDocumentTask()
                }
            }
            .onChange(of: adPolicy, initial: true) { _, policy in
                if completionAdEnabled && !finishing { completionAds.prepare(session: adSession, policy: policy) }
            }
            .onDisappear { if completionAdEnabled { completionAds.cancel(session: adSession) } }
            .fullScreenCover(isPresented: $camera, onDismiss: {
                if let workingDraftID, let staging = store.document(workingDraftID) { change { $0.pages = staging.pages } }
                else { document = store.document(documentID) }
                if captureOnOpen && cameraFirst {
                    // Closing the camera without a page leaves nothing to review.
                    if (document?.pages.isEmpty ?? true) {
                        Instant.run { dismiss() }
                    } else { cameraFirst = false }
                }
            }) { CameraView(documentID: workingDraftID ?? documentID, retakingPageID: retakingPage) }
            .sheet(isPresented: $identityLayout) { LocalDocumentToolsView(documentID: documentID, tool: .identity) }
            .sheet(item: $editPage) { page in
                PageEditor(page: page) { updated in
                    if let i = document?.pages.firstIndex(where: { $0.id == updated.id }) { change { $0.pages[i] = updated; $0.searchable = false } }
                }
            }
            .sheet(item: $cropReviewPage, onDismiss: {
                if resumeSaveAfterCrop && cropWasConfirmed {
                    cropWasConfirmed = false
                    save()
                } else { resumeSaveAfterCrop = false }
            }) { page in
                CropView(page: page, confirmationRequired: true) { quad in
                    if let i = document?.pages.firstIndex(where: { $0.id == page.id }) {
                        document?.pages[i].crop = quad
                        document?.pages[i].trimming = .zero
                        document?.pages[i].cropReviewNeeded = false
                        document?.pages[i].ocrComplete = false
                        document?.pages[i].textBlocks = []
                        document?.searchable = false
                        persistDraft()
                        cropWasConfirmed = true
                    }
                }
            }
        }
    }
    private func change(_ action: (inout ScanDocument) -> Void) {
        guard var value = document, !saving else { return }
        undoHistory.append(value); if undoHistory.count > 40 { undoHistory.removeFirst() }; redoHistory = []
        action(&value); document = value; persistDraft()
    }
    private func restoreHistory(undo: Bool) {
        guard let current = document else { return }
        if undo, let old = undoHistory.popLast() { redoHistory.append(current); document = old }
        else if !undo, let next = redoHistory.popLast() { undoHistory.append(current); document = next }
        persistDraft()
    }
    private func openCamera(retaking: UUID?) {
        guard let doc = document else { return }
        do {
            if !doc.isDraft && workingDraftID == nil { workingDraftID = try store.makeEditingDraft(doc) }
            guard persistDraft() else { return }; retakingPage = retaking; camera = true
        } catch { self.error = error.localizedDescription }
    }
    private func cancelEditing() {
        do { if let id = workingDraftID, let draft = store.document(id) { try store.permanentlyDelete(draft) }; dismiss() }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult private func persistDraft() -> Bool {
        guard var doc = document else { return false }
        if !doc.isDraft {
            guard let id = workingDraftID else { return true }
            doc.editingOriginalID = doc.id; doc.id = id; doc.isDraft = true; doc.pdfFile = nil
        }
        do { try store.update(doc); return true } catch { self.error = "Your latest change wasn't saved. \(error.localizedDescription)"; return false }
    }
    private func save(forceText: Bool = false) {
        guard var doc = document else { return }
        doc.title = doc.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if doc.title.isEmpty { doc.title = "Scan \(Date().formatted(date: .abbreviated, time: .shortened))" }
        document = doc
        if let unchecked = doc.pages.first(where: { $0.cropReviewNeeded == true }) {
            resumeSaveAfterCrop = true; cropWasConfirmed = false
            cropReviewPage = unchecked
            return
        }
        resumeSaveAfterCrop = false; saving = true; error = nil; saveProgress = "Preparing PDF…"
        let root = store.root
        saveTask = Task {
            do {
                let result = try await PDFExport.prepare(doc, root: root, forceText: forceText) { saveProgress = $0 }
                try Task.checkCancellation()
                try store.savePDF(result.data, document: result.document, replacingDraft: workingDraftID)
                workingDraftID = nil
                document = store.document(documentID)
                textNotice = result.textNotice; textRetryNeeded = !result.failedTextPages.isEmpty
                saved = true
            } catch is CancellationError { self.error = "Export canceled. Your pages and existing PDF are unchanged." }
            catch { self.error = "PDF wasn't saved. Your previously saved pages are still available. \(error.localizedDescription)" }
            saving = false
        }
    }
}

struct PageEditor: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    @State var page: ScanPage
    var onAddPage: ((ScanPage) throws -> Void)? = nil
    var onCancelCapture: (() throws -> Void)? = nil
    var doneTitle = "Done"
    var dismissOnSave = true
    var scanStyle = CaptureStyle.document
    let onSave: (ScanPage) throws -> Void
    @State private var cropping = false
    @State private var trimming = false
    @State private var erasing = false
    @State private var comparingOriginal = false
    @State private var detecting = false
    @State private var previewReady = false
    @State private var message: String?
    @State private var saveError: String?
    @State private var selectedTool = EditorTool.tone
    @State private var selectedAdjustment = Adjustment.brightness
    @State private var pendingAction: FinishAction?
    @State private var rasterConfirmation = false
    @State private var rasterAction: FinishAction?
    private enum EditorTool: String, CaseIterable {
        case crop = "Crop", tone = "Tone", adjust = "Adjust"
        var icon: String {
            switch self { case .crop: "crop"; case .tone: "circle.lefthalf.filled"; case .adjust: "slider.horizontal.3" }
        }
    }
    private enum FinishAction { case done, addPage }
    private enum Adjustment: String, CaseIterable { case brightness = "Brightness", contrast = "Contrast", sharpness = "Sharpness", cleanup = "Cleanup" }
    private var captureReview: Bool { onCancelCapture != nil }
    private var displayedPage: ScanPage {
        var value = page
        if comparingOriginal { value.enhancement = .original; value.adjustments = nil }
        return value
    }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 16) {
                        ScanPreview(page: displayedPage) { previewReady = $0 }
                            .frame(height: max(260, geometry.size.height * 0.60))
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(alignment: .topTrailing) {
                                Button { comparingOriginal.toggle() } label: {
                                    Label(comparingOriginal ? "Show scan" : "Original", systemImage: "square.on.square")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12).frame(minHeight: 44)
                                        .background(.regularMaterial, in: Capsule())
                                }
                                .accessibilityLabel(comparingOriginal ? "Show scan" : "Compare original")
                                .accessibilityIdentifier("compare-original")
                                .padding(8)
                            }
                        if page.cropReviewNeeded == true {
                            Button(scanStyle == .card ? "Card edges weren't found. Set the four corners" : "Page edges weren't found. Check crop") { cropping = true }.font(.subheadline)
                        }
                        VStack(spacing: 16) {
                            HStack(spacing: 4) {
                                ForEach(EditorTool.allCases, id: \.self) { tool in
                                    Button { selectedTool = tool } label: {
                                        VStack(spacing: 6) {
                                            Image(systemName: tool.icon).font(.system(size: 20))
                                            Text(tool.rawValue).font(.subheadline.weight(.medium))
                                        }
                                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                                        .foregroundStyle(selectedTool == tool ? Design.blue : Color.secondary)
                                        .background(selectedTool == tool ? Design.blue.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 14))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(selectedTool == tool ? .isSelected : [])
                                    .accessibilityIdentifier("editor-tool-" + tool.rawValue.lowercased())
                                }
                            }
                            toolOptions
                        }
                        .disabled(detecting)
                        if detecting { ProgressView("Finding page edges…") }
                        if let message { Text(message).font(.subheadline).foregroundStyle(.red) }
                    }.padding(20)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if captureReview {
                    HStack(spacing: 12) {
                        if onAddPage != nil { Button { finish(.addPage) } label: { Label("Add page", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 18).background(Design.muted, in: RoundedRectangle(cornerRadius: 16)) }
                            .accessibilityIdentifier("review-add-page") }
                        Button(doneTitle) { finish(.done) }.buttonStyle(PrimaryButton()).accessibilityIdentifier("review-done")
                    }.disabled(detecting || !previewReady).padding(.horizontal, 20).padding(.vertical, 12).background(.white)
                }
            }
            .navigationTitle(captureReview ? "Review scan" : "Edit page").navigationBarTitleDisplayMode(.inline)
            .alert("Convert this PDF page for image editing?", isPresented: $rasterConfirmation) {
                Button("Apply image edits") { if let action = rasterAction { commitFinish(action) } }
                Button("Cancel", role: .cancel) { rasterAction = nil }
            } message: { Text("Text will be recognized again. Original links and forms on this page will not be kept in the edited output. The imported original remains stored.") }
            .alert("This action couldn't be completed", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
            .toolbar {
                if captureReview {
                    ToolbarItem(placement: .cancellationAction) {
                        // Cancel rejects this new capture, including when its
                        // preview failed. Previously accepted pages stay intact.
                        Button("Cancel") {
                            do { try onCancelCapture?() }
                            catch { saveError = error.localizedDescription }
                        }.disabled(detecting).accessibilityIdentifier("capture-review-cancel")
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Apply") { finish(.done) }.disabled(detecting || !previewReady) }
                }
            }
            .sheet(isPresented: $trimming) {
                TrimMarginsView(page:page) { value in page.trimming = value; changed() }
            }
            .fullScreenCover(isPresented: $erasing) {
                PageEraseSheet(page: page) { strokes in
                    var list = page.activeErasures
                    list.append(PageErasure(strokes: strokes.map { PageErasure.Stroke(points: $0.points, width: Double($0.width)) }, crop: page.crop, turns: page.turns, trim: page.edgeTrim))
                    page.erasures = list; changed()
                }
            }
            .sheet(isPresented: $cropping, onDismiss: {
                if let action = pendingAction, page.cropReviewNeeded != true { pendingAction = nil; finish(action) }
                else { pendingAction = nil }
            }) {
                CropView(page: page, confirmationRequired: captureReview && page.cropReviewNeeded == true) { quad in
                    page.crop = quad; page.cropReviewNeeded = false; page.trimming = .zero; changed()
                }
            }
        }
    }
    @ViewBuilder
    private var toolOptions: some View {
        switch selectedTool {
        case .crop:
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                cropAction("Page edges", icon: "crop", identifier: "edit-page-edges") { cropping = true }
                cropAction("Trim margins", icon: "rectangle.inset.filled", identifier: "trim-margins") { trimming = true }
                cropAction("Auto scan", icon: "viewfinder", identifier: "auto-scan") { autoScan() }
                cropAction("Rotate", icon: "rotate.right", identifier: "rotate-page") {
                    page.turns = (page.turns + 1) % 4
                    page.trimming = page.trimming.rotatedClockwise()
                    changed()
                }
            }
        case .tone:
            HStack(spacing: 8) {
                ForEach(Enhancement.allCases, id: \.self) { tone in
                    Button {
                        guard page.enhancement != tone else { return }
                        page.enhancement = tone
                        if tone == .original && selectedAdjustment == .cleanup { selectedAdjustment = .brightness }
                        changed()
                    } label: {
                        Text(tone.rawValue).font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 48)
                            .padding(.horizontal, 4)
                            .foregroundStyle(page.enhancement == tone ? Design.blue : .primary)
                            .background(page.enhancement == tone ? Design.blue.opacity(0.08) : Design.muted, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page.enhancement == tone ? .isSelected : [])
                    .accessibilityIdentifier("editor-tone-" + tone.rawValue)
                }
            }
        case .adjust:
            VStack(spacing: 8) {
                HStack {
                    Menu {
                        Picker("Adjustment", selection: $selectedAdjustment) {
                            ForEach(Adjustment.allCases.filter { $0 != .cleanup || page.enhancement != .original }, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(selectedAdjustment.rawValue).font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        }.frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("adjustment-picker")
                    Spacer()
                    Text(adjustmentValue).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("adjustment-value")
                }
                Slider(value: adjustmentBinding, in: adjustmentRange)
                    .accessibilityLabel(selectedAdjustment.rawValue)
                    .accessibilityIdentifier(selectedAdjustment.rawValue.lowercased() + "-slider")
                HStack(spacing: 8) {
                    Button { erasing = true } label: { Label("Erase spots", systemImage: "eraser.line.dashed") }
                        .buttonStyle(ChipStyle(selected: false)).disabled(!previewReady).accessibilityIdentifier("editor-erase")
                    if !page.activeErasures.isEmpty {
                        Button { page.erasures = Array(page.activeErasures.dropLast()); if page.erasures?.isEmpty == true { page.erasures = nil }; changed() } label: {
                            Label("Undo erase", systemImage: "arrow.uturn.backward")
                        }.buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("editor-erase-undo")
                    }
                    Spacer(minLength: 0)
                }
                Button("Reset adjustments") {
                    page.enhancement = .document; page.enhancementAmount = nil; page.adjustments = nil; changed()
                }
                .font(.footnote).frame(minHeight: 44)
            }
            .padding(.horizontal, 12)
        }
    }
    private func cropAction(_ title: String, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, 8)
                .background(Design.muted, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
    private var adjustmentRange: ClosedRange<Double> {
        switch selectedAdjustment { case .brightness: -0.25...0.25; case .contrast: 0.7...1.6; case .sharpness: -1...1; case .cleanup: 0.5...1.5 }
    }
    private var adjustmentBinding: Binding<Double> {
        Binding(get: {
            switch selectedAdjustment { case .brightness: page.appearance.brightness; case .contrast: page.appearance.contrast; case .sharpness: page.appearance.sharpness; case .cleanup: page.enhancementStrength }
        }, set: { value in
            switch selectedAdjustment {
            case .brightness: page.appearance.brightness = value
            case .contrast: page.appearance.contrast = value
            case .sharpness: page.appearance.sharpness = value
            case .cleanup: page.enhancementStrength = value
            }
            changed()
        })
    }
    private var adjustmentValue: String {
        let value = adjustmentBinding.wrappedValue
        switch selectedAdjustment {
        case .brightness: return String(format: "%+.0f", value*400)
        case .sharpness: return String(format: "%+.0f", value*100)
        case .contrast, .cleanup: return String(format: "%.0f%%", value*100)
        }
    }
    private func changed() {
        comparingOriginal = false
        page.textBlocks = []; page.ocrComplete = false; page.ocrProcessingVersion = nil; page.correctedText = nil
    }
    private func finish(_ action: FinishAction) {
        if captureReview && page.cropReviewNeeded == true { pendingAction = action; cropping = true; return }
        if page.sourcePDF != nil && !page.preservesPDF { rasterAction = action; rasterConfirmation = true; return }
        commitFinish(action)
    }
    private func commitFinish(_ action: FinishAction) {
        do {
            if action == .addPage { try onAddPage?(page) }
            else { try onSave(page); if dismissOnSave { dismiss() } }
        } catch { saveError = error.localizedDescription }
    }
    private func autoScan() {
        guard let image = UIImage(contentsOfFile: store.url(page.imageFile).path) else { message = "This photo couldn't be opened."; return }
        detecting = true; message = nil
        Task {
            let mode = scanStyle
            let detected = await Task.detached { mode.detect(image, capturedPhoto: true) }.value
            detecting = false; page.enhancement = mode.enhancement; changed()
            if let detected { page.crop = detected; page.cropReviewNeeded = false; page.trimming = .zero }
            else { page.cropReviewNeeded = true; message = "Set the four corners in Crop."; cropping = true }
        }
    }
}
struct CropView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) var dismiss
    let page: ScanPage
    var confirmationRequired = false
    var temporaryImage: UIImage? = nil
    let apply: (ScanQuad) -> Void
    @State private var quad = ScanQuad.full
    @State private var original: UIImage?
    @State private var detectionMessage: String?
    @State private var activeCorner: Int?
    var body: some View {
        NavigationStack {
            VStack {
                Text(confirmationRequired ? "Page edges weren't found. Confirm all four corners before saving." : "Drag each corner to the edge of the paper.").foregroundStyle(.secondary).padding()
                GeometryReader { geometry in
                    if let original {
                        let scale = min(geometry.size.width/original.size.width, geometry.size.height/original.size.height)
                        let size = CGSize(width: original.size.width*scale, height: original.size.height*scale)
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: original).resizable().frame(width: size.width, height: size.height)
                            Path { path in
                                path.move(to: CGPoint(x: quad.points[0].x*size.width, y: quad.points[0].y*size.height))
                                for p in quad.points.dropFirst() { path.addLine(to: CGPoint(x: p.x*size.width, y: p.y*size.height)) }; path.closeSubpath()
                            }.stroke(Design.blue, lineWidth: 3)
                            ForEach(0..<4, id: \.self) { i in corner(i, size: size) }
                            if let i = activeCorner {
                                let point = quad.points[i]
                                Image(uiImage:original).resizable().frame(width:size.width*3,height:size.height*3)
                                    .offset(x:(0.5-point.x)*size.width*3,y:(0.5-point.y)*size.height*3)
                                    .frame(width:112,height:112).clipped()
                                    .overlay { Image(systemName:"plus").foregroundStyle(Design.blue) }
                                    .clipShape(Circle()).overlay(Circle().stroke(.white,lineWidth:3))
                                    .position(x:min(size.width-56,max(56,point.x*size.width)),y:point.y*size.height > 150 ? point.y*size.height-90 : point.y*size.height+90)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }.coordinateSpace(name: "crop").frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }.padding(24)
                HStack {
                    Button("Reset crop") { quad = .full }
                    Spacer()
                    Button("Detect edges") {
                        guard let original else { return }
                        Task {
                            if let detected = await Task.detached(operation: { Imaging.detect(original) }).value { quad = detected; detectionMessage = nil }
                            else { detectionMessage = "Edges weren't found. Drag the corners to the paper, or confirm the full image." }
                        }
                    }
                }.padding(24)
                if let detectionMessage { Text(detectionMessage).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            }.navigationTitle("Crop").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply(quad); dismiss() }.disabled(!quad.valid) }
            }.onAppear { quad = page.crop; original = temporaryImage ?? UIImage(contentsOfFile: store.url(page.imageFile).path) }
        }
    }
    private func corner(_ i: Int, size: CGSize) -> some View {
                                Circle().fill(.white).frame(width: 22, height: 22).overlay(Circle().stroke(Design.blue, lineWidth: 3)).frame(width: 44, height: 44).contentShape(Rectangle())
                                    .position(x: quad.points[i].x*size.width, y: quad.points[i].y*size.height)
                                    .gesture(DragGesture(coordinateSpace: .named("crop")).onChanged { value in
                                        activeCorner = i
                                        var candidate = quad
                                        candidate.points[i] = ScanPoint(x: min(1, max(0, value.location.x/size.width)), y: min(1, max(0, value.location.y/size.height)))
                                        if candidate.valid { quad = candidate }
                                    }.onEnded { _ in activeCorner = nil })
                                    .accessibilityLabel(["Top left", "Top right", "Bottom right", "Bottom left"][i] + " corner")
                                    .accessibilityValue("Horizontal \(Int(quad.points[i].x*100)) percent, vertical \(Int(quad.points[i].y*100)) percent")
                                    .accessibilityAction(named: "Move left") { moveCorner(i, dx: -0.01, dy: 0) }
                                    .accessibilityAction(named: "Move right") { moveCorner(i, dx: 0.01, dy: 0) }
                                    .accessibilityAction(named: "Move up") { moveCorner(i, dx: 0, dy: -0.01) }
                                    .accessibilityAction(named: "Move down") { moveCorner(i, dx: 0, dy: 0.01) }
    }
    private func moveCorner(_ i: Int, dx: Double, dy: Double) {
        var next = quad
        next.points[i].x = min(1,max(0,next.points[i].x+dx)); next.points[i].y = min(1,max(0,next.points[i].y+dy))
        if next.valid { quad = next }
    }

}

/// Smart erase on a scanned page: paint over stains or shadows left after the
/// automatic cleanup. The strokes are stored on the page and applied when it
/// renders, so the original photo is never changed.
struct PageEraseSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let page: ScanPage
    let apply: ([ImageToolEngine.Stroke]) -> Void
    @State private var image: UIImage?
    @State private var strokes: [ImageToolEngine.Stroke] = []
    @State private var brush = 0.035
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            ToolPage(title: "Erase spots", subtitle: "Paint over stains, shadows or marks. Pinch to zoom in for small spots.", scrolls: false) {
                if let image { ErasePainter(image: image, strokes: $strokes, brush: $brush) }
                else if let failure { ToastMessage(text: failure) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            } actions: {
                Button("Erase") { apply(strokes); dismiss() }.buttonStyle(CTAButtonStyle()).disabled(strokes.isEmpty).accessibilityIdentifier("page-erase-apply")
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.accessibilityIdentifier("page-erase-close") } }
        }
        .task {
            let page = page, root = store.root
            // Paint on a screen-sized render; strokes are normalized, so they
            // apply to the full-resolution page on export.
            do { image = try await ScanPreviewRenderer().render(page, root: root, maxDimension: 2400) }
            catch { failure = error.localizedDescription }
        }
    }
}
