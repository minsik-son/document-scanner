import SwiftUI
import PDFKit

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
    /// Label of the back button on the finished PDF.
    var savedBackTitle = "Back"
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
                          unlocked: !lock.locked, configured: HomeAdConfiguration.adsEnabled)
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
    /// Back in the editor from the saved page (a step forgotten before saving).
    @State private var editingAfterSave = false
    @State private var error: String?
    @State private var options = false
    @State private var cropReviewPage: ScanPage?
    @State private var resumeSaveAfterCrop = false
    @State private var cropWasConfirmed = false
    @State private var undoHistory: [ScanDocument] = []
    @State private var redoHistory: [ScanDocument] = []
    @State private var confirmDiscard = false
    @State private var deletingLast = false
    @State private var retakingPage: UUID?
    @State private var workingDraftID: UUID?
    @State private var saveTask: Task<Void, Never>?
    /// Page shown large in the review; the strip below picks another one.
    @State private var current = 0
    /// Edit mode: the compact list for reordering and deleting pages.
    @State private var reordering = false
    /// What Save makes, chosen in the row above the button; remembered.
    @AppStorage(ConversionRoute.formatKey) private var outputFormat = "pdf"
    @State private var trials = ProTrials()
    @State private var officePaywall = false
    /// Hide personal info on a page of this review.
    @State private var hiding: HideRoute?
    @State private var conversion: ConversionRoute?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var editTool: String?
    /// The save settings page, opened by Next on a new scan's review.
    @State private var settingsOpen = false
    /// Long side of each picture when a new scan is saved as PNG or JPEG.
    @State private var imagePixels = 2400
    /// Pictures made after a PNG or JPEG save, ready to share or keep in Photos.
    @State private var imageFiles: ExportedFiles?
    @State private var sharingImages: ExportedFiles?
    @State private var savedToPhotos = false
    /// Pictures saved to Photos: their own saved page, then Share or Done.
    @State private var savedPhotosPage: ExportedFiles?
    @State private var openingPDF = false
    /// Conversion asked about in the sheet; it opens once the sheet has closed.
    @State private var confirmConvert: ConversionRoute?
    @State private var startConversion: ConversionRoute?
    /// The picture shown while saving: a PDF, or pictures for PNG and JPEG.
    @State private var savingKind = WorkAnimation.save

    var body: some View {
        NavigationStack {
            Group {
                if captureOnOpen && cameraFirst {
                    Color.black.ignoresSafeArea().toolbar(.hidden, for: .navigationBar)
                } else if let doc = document {
                    if saved {
                        savedScreen(doc)
                    } else {
                        List {
                            if reordering {
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
                            } header: { Text(doc.pages.count == 1 ? "1 page" : "\(doc.pages.count) pages") }
                            } else if !doc.pages.isEmpty {
                                Section { pagePreview(doc) }
                                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
                            } else {
                                Section { Text("Add a page to get started.").foregroundStyle(.secondary) }
                            }
                            if !doc.isDraft { Section {
                                TextField("Document name", text: Binding(get: { document?.title ?? "" }, set: { document?.title = $0; document?.autoTitled = false; persistDraft() }))
                                if document?.autoTitled == true {
                                    Label("Named automatically from the text when you save", systemImage: "sparkles").font(.footnote).foregroundStyle(.secondary)
                                }
                                DisclosureGroup("Save options", isExpanded: $options) { pdfOptionFields(doc) }
                            }
                            }
                            if let error { Section { Text(L(error)).foregroundStyle(.red) } }
                        }.listStyle(.insetGrouped).disabled(saving)
                        .environment(\.editMode, .constant(reordering ? .active : .inactive))
                        .safeAreaInset(edge: .bottom) { saveBar(doc) }
                    }
                } else { ProgressView() }
            }
            .navigationTitle(saved ? "" : "Review")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $settingsOpen) { if let doc = document { saveSettings(doc) } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if saved {
                        Button { finishSaved() } label: {
                            HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)); Text(L(savedBackTitle)) }
                        }.disabled(saving || finishing).accessibilityIdentifier("saved-done")
                    } else {
                        Button(document?.isDraft == true ? "Close" : "Cancel") {
                            // A new scan with pages is never thrown away by one tap.
                            if editingAfterSave { leaveEditAgain() }
                            else if document?.isDraft == true && !(document?.pages.isEmpty ?? true) { confirmDiscard = true } else { cancelEditing() }
                        }.disabled(saving).accessibilityIdentifier("review-close")
                    }
                }
                ToolbarItem(placement: .principal) {
                    // A new scan's name, tap to change it.
                    if !saved, let doc = document, doc.isDraft, !(captureOnOpen && cameraFirst) {
                        Button { renameText = doc.title; renaming = true } label: {
                            HStack(spacing: 5) {
                                Text(doc.title.isEmpty ? L("Review") : doc.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                Image(systemName: "pencil").font(.system(size: 13, weight: .semibold)).foregroundStyle(TK.grey500)
                            }.foregroundStyle(TK.grey900).frame(maxWidth: 200)
                        }
                        .disabled(saving)
                        .accessibilityLabel(String(format: L("Name: %@"), doc.title)).accessibilityHint("Rename")
                        .accessibilityIdentifier("review-name")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !saved {
                        HStack(spacing: 2) {
                            Button { restoreHistory(undo: true) } label: { Image(systemName: "arrow.uturn.backward") }
                                .disabled(undoHistory.isEmpty || saving).accessibilityLabel("Undo")
                            Button { restoreHistory(undo: false) } label: { Image(systemName: "arrow.uturn.forward") }
                                .disabled(redoHistory.isEmpty || saving).accessibilityLabel("Redo")
                            if reordering || document?.isDraft == false {
                                Button(reordering ? "Done" : "Edit") { withAnimation { reordering.toggle() } }.disabled(saving)
                                    .accessibilityHint("Reorder or delete pages")
                            }
                        }
                    }
                }
            }
            .background(saveFlow)
            .alert("Discard this scan?", isPresented: $confirmDiscard) {
                Button("Discard", role: .destructive) { cancelEditing() }
                Button("Keep editing", role: .cancel) {}
            } message: { Text("Its pages will be deleted from this iPhone.") }
            .alert("Delete the last page?", isPresented: $deletingLast) {
                Button("Move document to Trash", role: .destructive) { if let doc = store.document(documentID) { trashWithUndo(store, doc); if store.problem == nil { cancelEditing() } } }
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
            .sheet(item: $editPage, onDismiss: { editTool = nil }) { page in
                PageEditor(page: page, initialTool: editTool) { updated in
                    if let i = document?.pages.firstIndex(where: { $0.id == updated.id }) { change { $0.pages[i] = updated; $0.searchable = false } }
                }
            }
            .sheet(item: $cropReviewPage, onDismiss: {
                if resumeSaveAfterCrop && cropWasConfirmed {
                    cropWasConfirmed = false
                    // A new scan goes on to its save settings; an edited document saves.
                    if let doc = document, doc.isDraft, !settingsOpen { saveTapped(doc) } else { save() }
                } else { resumeSaveAfterCrop = false }
            }) { page in
                CropView(page: page, confirmationRequired: true, detect: { [style = document?.captureStyle ?? .document] in style.detect($0, capturedPhoto: true) }) { quad in
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
        // Saving takes a few seconds (text is read on every page): show the work being done
        // over every screen of the flow, and let it finish on its check once the file is saved.
        .overlay {
            FinishingOverlay(text: saving && !saved ? saveProgress : nil, failed: error != nil) { text, done, cancelled, finished in
                WorkProgressView(kind: savingKind, phase: text, done: done, onFinished: finished) { cancelled(); saveTask?.cancel() }
            }
        }
    }
    /// Rename, the save sheet, PDF options and the conversion that follows a save.
    /// Kept apart from `body` so the compiler type-checks it separately.
    private var saveFlow: some View {
        Color.clear
            .alert("Rename", isPresented: $renaming) {
                TextField("Document name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    document?.title = name; document?.autoTitled = false; persistDraft()
                }
            }
            .sheet(isPresented: $officePaywall) { PaywallView(start: .feature(.office)) }
            .onReceive(NotificationCenter.default.publisher(for: .proTrialsChanged)) { _ in trials = ProTrials() }
            .fullScreenCover(item: $hiding) { route in
                if let doc = document {
                    NavigationStack {
                        ProTrialGate(feature: .redact, title: L("Hide personal info"),
                                     detail: "ID, card and account numbers, phone numbers and emails are found and blacked out in a new copy.",
                                     art: .redact, close: { hiding = nil }, autoTry: true) {
                            RedactionEditor(pages: doc.pages, root: store.root, notice: route.notice, save: applyHiding, index: route.page)
                        }
                    }
                }
            }
            .sheet(item: $confirmConvert, onDismiss: {
                if let route = startConversion { startConversion = nil; conversion = route }
            }) { route in convertSheet(route) }
            .sheet(item: $sharingImages) { files in ShareSheet(items: files.urls) }
            .fullScreenCover(isPresented: $openingPDF) { pdfViewer }
            .onDisappear { if let files = imageFiles { ExportFiles.remove(files.directory) } }
            .sheet(item: $conversion) { route in ConversionDestination(route: route, documentID: documentID) { conversion = nil } }
    }
    /// Format row (new scans), Add pages and Next. An edited document saves its changes here.
    @ViewBuilder private func saveBar(_ doc: ScanDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if doc.isDraft {
                // One row, label beside the choices, so the page above keeps its room.
                HStack(spacing: 12) {
                Text("File type").font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey800).lineLimit(1).fixedSize()
                HStack(spacing: 0) {
                    ForEach(Self.formats, id: \.key) { format in
                        let chosen = currentFormat.key == format.key
                        Button { outputFormat = format.key } label: {
                            Text(verbatim: format.title).font(.system(size: 15, weight: chosen ? .bold : .semibold))
                                .foregroundStyle(chosen ? TK.grey900 : TK.grey600)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                // Raised a step above the track in both modes (white on grey, lighter grey on dark grey).
                                .background(chosen ? Color(light: 0xFFFFFF, dark: 0x4D4D59) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("review-format-\(format.key)")
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                .padding(3).background(TK.grey100, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .animation(.easeOut(duration: 0.15), value: outputFormat)
                .disabled(saving)
                }
            }
            if saving && !doc.isDraft { Text(L(saveProgress)).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("save-progress") }
            HStack(spacing: 10) {
                Button { openCamera(retaking: nil) } label: { Label("Add pages", systemImage: "camera").lineLimit(1).minimumScaleFactor(0.8) }
                    .buttonStyle(SecondaryButton()).frame(width: 132).disabled(saving)
                    .accessibilityIdentifier("review-add-pages")
                Button { saveTapped(doc) } label: {
                    if saving && !doc.isDraft { ProgressView().tint(Design.blueInk).frame(maxWidth: .infinity) }
                    else { Text(doc.isDraft ? L("Next") : L("Save changes")).lineLimit(1).minimumScaleFactor(0.8) }
                }
                .buttonStyle(FormatSaveButton(fill: nil))
                .disabled(saving || doc.pages.isEmpty)
                .accessibilityIdentifier("review-save")
            }
        }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8).background(TK.paper)
    }
    private struct OutputFormat { let key: String; let title: String }
    /// What a new scan is saved as. Word, Excel and PowerPoint are offered after the save.
    private static let formats = [OutputFormat(key: "pdf", title: "PDF"), OutputFormat(key: "png", title: "PNG"), OutputFormat(key: "jpg", title: "JPEG")]
    /// The chosen format; a choice remembered from the older row (Word, Images…) reads as PDF.
    private var currentFormat: OutputFormat { Self.formats.first { $0.key == outputFormat } ?? Self.formats[0] }
    /// PNG or JPEG: every page is also made into a picture after the PDF is saved.
    private var imageFormat: ImageExportFormat? { currentFormat.key == "pdf" ? nil : ImageExportFormat(rawValue: currentFormat.key) }
    private var officeLocked: Bool { !subscription.isPro && !trials.bypassed && trials.remaining(.office) == 0 }
    private var officeBadge: String? {
        guard !subscription.isPro, !trials.bypassed else { return nil }
        return officeLocked ? L("Pro") : String(format: L("%lld free left"), trials.remaining(.office))
    }
    /// Next on a new scan: pages are checked first, then the save settings open.
    private func saveTapped(_ doc: ScanDocument) {
        guard doc.isDraft else { save(); return }
        guard pagesReady() else { return }
        settingsOpen = true
    }
    /// Pages to check before saving: hidden areas on a page changed since, and unconfirmed edges.
    private func pagesReady() -> Bool {
        guard let doc = document else { return false }
        // A page cropped or retoned after hiding: check its hidden areas first.
        if let stale = doc.pages.firstIndex(where: \.redactionNeedsCheck) {
            hiding = HideRoute(page: stale, notice: "This page changed after you hid parts of it. Check the boxes, then save.")
            return false
        }
        if let unchecked = doc.pages.first(where: { $0.cropReviewNeeded == true }) {
            resumeSaveAfterCrop = true; cropWasConfirmed = false
            cropReviewPage = unchecked
            return false
        }
        resumeSaveAfterCrop = false
        return true
    }
    /// The second step of a new scan: the file's name and every PDF setting in view, then one Save button.
    @ViewBuilder private func saveSettings(_ doc: ScanDocument) -> some View {
        let image = imageFormat
        let name = Binding(get: { document?.title ?? "" }, set: { document?.title = $0; document?.autoTitled = false; persistDraft() })
        let folder = Binding(get: { document?.folder ?? "Scans" }, set: { document?.folder = $0; persistDraft() })
        let paper = Binding(get: { document?.paper ?? .letter }, set: { document?.paper = $0; persistDraft() })
        let landscape = Binding(get: { document?.landscape ?? false }, set: { value in change { $0.landscape = value } })
        let margin = Binding(get: { document?.margin ?? .small }, set: { document?.margin = $0; persistDraft() })
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(doc.pages.enumerated()), id: \.element.id) { _, page in
                                PageThumbnail(page: page).frame(width: 84, height: 112).padding(6)
                                    .background(TK.grey50, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TK.grey200))
                            }
                        }.padding(.horizontal, 20).padding(.vertical, 2)
                    }
                    .padding(.top, 8).accessibilityHidden(true)
                    Text(L(image == nil ? "Saving as PDF" : image == .png ? "Saving as PNG" : "Saving as JPEG"))
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(TK.grey900).padding(.top, 24)
                        .padding(.horizontal, 20).accessibilityAddTraits(.isHeader)
                    Text(L(image == nil ? "You can turn it into Word, Excel or PowerPoint after saving." : "Each page becomes one picture. The PDF is kept too."))
                        .font(.system(size: 15)).foregroundStyle(TK.grey600).padding(.top, 6).padding(.horizontal, 20)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("File name").font(.system(size: 13)).foregroundStyle(TK.grey600).padding(.top, 20)
                        TextField("Document name", text: name).font(.system(size: 16)).foregroundStyle(TK.grey900)
                            .padding(.horizontal, 14).frame(height: 48)
                            .background(TK.grey100, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(.top, 6)
                            .accessibilityIdentifier("save-name")
                        if document?.autoTitled == true {
                            Label("Named automatically from the text when you save", systemImage: "sparkles").font(.footnote).foregroundStyle(TK.grey600).padding(.top, 6)
                        }
                        settingRow("Folder") {
                            Picker("Folder", selection: folder) { ForEach(store.manifest.folders, id: \.self) { Text(L($0)).tag($0) } }.labelsHidden().tint(TK.grey700)
                        }
                        if image == nil {
                            settingRow("Paper") {
                                Picker("Paper", selection: paper) { ForEach(PaperSize.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) } }
                                    .pickerStyle(.segmented).frame(maxWidth: 230)
                            }
                            settingRow("Orientation") {
                                Picker("Orientation", selection: landscape) { Text("Portrait").tag(false); Text("Landscape").tag(true) }
                                    .pickerStyle(.segmented).frame(maxWidth: 160)
                            }
                            settingRow("Margins", last: true) {
                                Picker("Margins", selection: margin) { ForEach(PageMargin.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) } }
                                    .pickerStyle(.segmented).frame(maxWidth: 210)
                            }
                            if doc.pages.contains(where: { $0.trimming != .zero }) { Text("For no added white space, choose Original paper and None margins. A4 and US Letter keep their shape and may add white space.").font(.caption).foregroundStyle(TK.grey600) }
                            if doc.pages.contains(where: { $0.sourcePDF != nil }) { Text("Changing PDF paper or margins keeps text and links but flattens interactive forms. The imported original is retained.").font(.caption).foregroundStyle(TK.grey600) }
                        } else {
                            settingRow("Size", last: true) {
                                Picker("Size", selection: $imagePixels) { Text("Standard").tag(1600); Text("High").tag(2400); Text("Maximum").tag(3600) }
                                    .pickerStyle(.segmented).frame(maxWidth: 220)
                            }
                        }
                        if let error { Text(L(error)).font(.system(size: 14)).foregroundStyle(TK.red).padding(.top, 12) }
                    }.padding(.horizontal, 20)
                }.padding(.bottom, 20)
            }
            VStack(spacing: 4) {
                Button { save() } label: {
                    if saving {
                        HStack(spacing: 10) { ProgressView().tint(.white); Text(L(saveProgress)).lineLimit(1).minimumScaleFactor(0.8) }
                    } else {
                        Text(L(image == nil ? "Save as PDF" : image == .png ? "Save as PNG" : "Save as JPEG"))
                    }
                }
                .buttonStyle(CTAButtonStyle()).allowsHitTesting(!saving)
                .accessibilityIdentifier("save-confirm")
                if saving {
                    Button("Cancel export") { saveTask?.cancel() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey700).frame(height: 40)
                }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8).background(TK.paper)
        }
        .background(TK.paper)
        .navigationTitle(L(image == nil ? "PDF settings" : "Image settings"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saving)
    }
    private func settingRow<Content: View>(_ title: String, last: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) { Text(L(title)).font(.system(size: 16)).foregroundStyle(TK.grey900); Spacer(minLength: 8); content() }
            .frame(minHeight: 56)
            .overlay(alignment: .bottom) { if !last { Rectangle().fill(TK.grey100).frame(height: 1) } }
    }
    /// After saving: what was saved and how to share it, then the conversions that can follow.
    @ViewBuilder private func savedScreen(_ doc: ScanDocument) -> some View {
        let savedDoc = store.document(documentID) ?? doc
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(TK.blueSoft)
                            Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundStyle(TK.blue)
                        }.frame(width: 64, height: 64).accessibilityHidden(true)
                        Text(L(imageFiles == nil ? "Saved as PDF" : imageFormat == .png ? "PNG images are ready" : "JPEG images are ready"))
                            .font(.system(size: 24, weight: .bold)).foregroundStyle(TK.grey900).padding(.top, 10)
                            .accessibilityAddTraits(.isHeader)
                        Text(savedDetail(savedDoc)).font(.system(size: 14)).foregroundStyle(TK.grey600)
                            .multilineTextAlignment(.center).lineLimit(2)
                    }.padding(.top, 12).padding(.horizontal, 20)
                    HStack(spacing: 8) {
                        if let files = imageFiles {
                            Button { saveImagesToPhotos(files) } label: {
                                savedAction(savedToPhotos ? "Saved to Photos" : "Save to Photos", icon: savedToPhotos ? "checkmark" : "photo.on.rectangle", primary: true)
                            }.buttonStyle(.plain).disabled(savedToPhotos).accessibilityIdentifier("saved-photos")
                            Button { sharingImages = files } label: { savedAction("Share", icon: "square.and.arrow.up", primary: false) }
                                .buttonStyle(.plain).accessibilityLabel("Share images")
                            Button { editAgain() } label: { savedAction("Edit", icon: "pencil", primary: false) }
                                .buttonStyle(.plain).disabled(saving || finishing).accessibilityIdentifier("saved-edit")
                        } else if let file = savedDoc.pdfFile {
                            ShareLink(item: SharedPDF.url(for: store.url(file), title: savedDoc.title)) {
                                savedAction("Share", icon: "square.and.arrow.up", primary: true)
                            }.buttonStyle(.plain).accessibilityLabel("Share PDF")
                            Button { openingPDF = true } label: { savedAction("Open", icon: "doc.text.magnifyingglass", primary: false) }
                                .buttonStyle(.plain).accessibilityIdentifier("saved-open")
                            Button { editAgain() } label: { savedAction("Edit", icon: "pencil", primary: false) }
                                .buttonStyle(.plain).disabled(saving || finishing).accessibilityIdentifier("saved-edit")
                        }
                    }.padding(.horizontal, 20).padding(.top, 18)
                    if textNotice != nil || textRetryNeeded || saving || error != nil || doc.captureStyle == .card {
                        VStack(alignment: .leading, spacing: 8) {
                            if let textNotice { Text(L(textNotice)).font(.system(size: 13)).foregroundStyle(TK.grey600) }
                            if textRetryNeeded { Button("Retry text recognition") { save(forceText: false) }.font(.system(size: 14, weight: .semibold)).disabled(saving) }
                            if saving { ProgressView(L(saveProgress)).font(.system(size: 13)) }
                            if let error { Text(L(error)).font(.system(size: 13)).foregroundStyle(TK.red) }
                            if doc.captureStyle == .card {
                                Button("Arrange ID card on one page") { identityLayout = true }.buttonStyle(ChipStyle(selected: false))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 14)
                    }
                    Rectangle().fill(TK.grey100).frame(height: 10).padding(.top, 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Turn this scan into another format?").font(.system(size: 18, weight: .bold)).foregroundStyle(TK.grey900)
                            .accessibilityAddTraits(.isHeader)
                        Text("Text and tables are read into a file you can edit.").font(.system(size: 14)).foregroundStyle(TK.grey600)
                            .padding(.top, 4).padding(.bottom, 6)
                        ForEach(Self.conversions, id: \.route) { item in convertRow(item) }
                    }.padding(.horizontal, 20).padding(.top, 20)
                }.padding(.bottom, 16)
            }
            Button("Done") { finishSaved() }.buttonStyle(CTAButtonStyle())
                .disabled(saving || finishing).accessibilityIdentifier("saved-finish")
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
        }
        .background(TK.paper)
        .fullScreenCover(item: $savedPhotosPage) { files in
            SavedPage(place: .photos, urls: files.urls, shareTitle: "Share images", shareID: "saved-photos-share") {
                savedPhotosPage = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { finishSaved() }
            }
        }
    }
    private func savedDetail(_ doc: ScanDocument) -> String {
        let pages = doc.pages.count == 1 ? L("1 page") : String(format: L("%lld pages"), doc.pages.count)
        let base = [L(doc.folder), doc.title, pages].joined(separator: " · ")
        return doc.searchable ? String(format: L("%@ · text can be copied"), base) : base
    }
    private func savedAction(_ title: String, icon: String, primary: Bool) -> some View {
        Label(L(title), systemImage: icon).font(.system(size: 15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(primary ? TK.blueDeep : TK.grey800)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(primary ? TK.blueSoft : TK.grey100, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
    }
    private func saveImagesToPhotos(_ files: ExportedFiles) {
        for url in files.urls { if let image = UIImage(contentsOfFile: url.path) { UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil) } }
        savedToPhotos = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        savedPhotosPage = files
    }
    private struct Conversion { let route: ConversionRoute; let letter: String; let title: String; let detail: String; let fill: Color }
    /// Word blue, Excel green, PowerPoint orange: the colours people know these files by.
    private static let conversions = [
        Conversion(route: .word, letter: "W", title: "Convert to Word", detail: "For letters and contracts with lots of text", fill: Color(red: 0.169, green: 0.341, blue: 0.604)),
        Conversion(route: .excel, letter: "X", title: "Convert to Excel", detail: "For receipts and statements with tables", fill: Color(red: 0.129, green: 0.451, blue: 0.275)),
        Conversion(route: .slides, letter: "P", title: "Convert to PowerPoint", detail: "One page becomes one slide", fill: Color(red: 0.824, green: 0.278, blue: 0.149)),
    ]
    private func letterTile(_ item: Conversion, size: CGFloat) -> some View {
        Text(verbatim: item.letter).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(item.fill, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .accessibilityHidden(true)
    }
    private func convertRow(_ item: Conversion) -> some View {
        Button { if officeLocked { officePaywall = true } else { confirmConvert = item.route } } label: {
            HStack(spacing: 14) {
                letterTile(item, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(item.title)).font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900)
                    Text(L(item.detail)).font(.system(size: 13)).foregroundStyle(TK.grey600)
                }
                Spacer(minLength: 8)
                if let badge = officeBadge {
                    Text(badge).font(.system(size: 12, weight: .semibold)).foregroundStyle(officeLocked ? Color.white : TK.blueDeep)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(officeLocked ? TK.inkFill : TK.blueSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(TK.grey400).accessibilityHidden(true)
            }.frame(minHeight: 64).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("saved-convert-\(item.route.rawValue)")
    }
    /// Asks once before a conversion starts: what it makes, and that the PDF stays.
    private func convertSheet(_ route: ConversionRoute) -> some View {
        let item = Self.conversions.first { $0.route == route } ?? Self.conversions[0]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                letterTile(item, size: 44)
                Text(L(item.title + "?")).font(.system(size: 22, weight: .bold)).foregroundStyle(TK.grey900).accessibilityAddTraits(.isHeader)
            }
            Text("Text and tables are read into a file you can edit. Your saved PDF stays as it is.")
                .font(.system(size: 15)).foregroundStyle(TK.grey700).padding(.top, 12).fixedSize(horizontal: false, vertical: true)
            if let badge = officeBadge {
                Label(badge, systemImage: "gift").font(.system(size: 14, weight: .semibold)).foregroundStyle(TK.blueDeep)
                    .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(TK.blueSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(.top, 16)
            }
            Spacer(minLength: 16)
            Button(L(item.title)) { startConversion = route; confirmConvert = nil }
                .buttonStyle(CTAButtonStyle()).accessibilityIdentifier("convert-start")
            Button("Not now") { confirmConvert = nil }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey700).frame(maxWidth: .infinity, minHeight: 48)
        }
        .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 8)
        .presentationDetents([.height(380)]).presentationDragIndicator(.visible)
    }
    /// The saved PDF, full screen, from Open on the saved page.
    private var pdfViewer: some View {
        NavigationStack {
            Group {
                if let file = store.document(documentID)?.pdfFile { PDFPreview(url: store.url(file)).accessibilityIdentifier("saved-pdf") }
                else { Color.clear }
            }
            .navigationTitle(store.document(documentID)?.title ?? "").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { openingPDF = false } } }
        }
    }
    /// Stores the editor's areas on their pages. The first hide spends the free try.
    private func applyHiding(_ result: [UUID: (hidden: [CGRect], visible: [CGRect])], style: RedactionStyle) {
        let before = document?.pages.contains(where: \.hasRedaction) ?? false
        if result.values.contains(where: { !$0.hidden.isEmpty }) {
            AppToast.show("Hidden. It's applied when you save.", symbol: "eye.slash.fill", tint: TK.blue)
        }
        change { doc in
            for (id, value) in result {
                if let i = doc.pages.firstIndex(where: { $0.id == id }) { doc.pages[i].setRedaction(hidden: value.hidden, visible: value.visible, style: style) }
            }
            // One look for the whole document: pages hidden earlier follow the new choice.
            for i in doc.pages.indices where doc.pages[i].hasRedaction && doc.pages[i].redactionStyle != style && result[doc.pages[i].id] == nil {
                doc.pages[i].redaction?.style = style == .black ? nil : style
            }
            doc.searchable = false
        }
        if !before && (document?.pages.contains(where: \.hasRedaction) ?? false) { ProTrialSession.commit() }
    }
    /// The page to check, shown big, with its actions and every page in a strip below.
    @ViewBuilder private func pagePreview(_ doc: ScanDocument) -> some View {
        let index = min(current, doc.pages.count - 1)
        let page = doc.pages[index]
        VStack(spacing: 14) {
            Button { editPage = page } label: {
                PageLargePreview(page: page)
                    .frame(maxWidth: .infinity).frame(height: 360)
                    .padding(18)
                    // A cool grey stage, so a white page stands out from what is around it.
                    .background(Color(red: 0.882, green: 0.902, blue: 0.929), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if doc.pages.count > 1 {
                            Text("\(index + 1) / \(doc.pages.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.55), in: Capsule()).padding(10)
                                .accessibilityLabel("Page \(index + 1) of \(doc.pages.count)")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if page.hasRedaction {
                            Label(String(format: L("%lld hidden"), page.redactionBoxes.count), systemImage: page.redactionNeedsCheck ? "exclamationmark.triangle.fill" : "eye.slash.fill")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(page.redactionNeedsCheck ? Color.orange : Color.black.opacity(0.8), in: Capsule()).padding(10)
                                .accessibilityIdentifier("review-hidden-badge")
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if page.cropReviewNeeded == true {
                            Label("Check page edges", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 7).background(Color.orange, in: Capsule()).padding(12)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(doc.pages.count == 1 ? "Edit page 1" : "Edit current page").accessibilityHint("Crop, rotate, and adjust")
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                // Swipe the big page to move between pages.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -40 { withAnimation { current = min(doc.pages.count - 1, index + 1) } }
                if value.translation.width > 40 { withAnimation { current = max(0, index - 1) } }
            })
            // One calm row of the page's actions, evenly spaced, icon above label.
            HStack(spacing: 0) {
                // Each opens the page editor on its own tab; rotate turns the page in place.
                pageAction("Crop", icon: "crop") { editTool = "Crop"; editPage = page }
                    .accessibilityIdentifier("review-tool-crop")
                pageAction("Filter", icon: "circle.lefthalf.filled") { editTool = "Tone"; editPage = page }
                    .accessibilityIdentifier("review-tool-filter")
                pageAction("Adjust", icon: "slider.horizontal.3") { editTool = "Adjust"; editPage = page }
                    .accessibilityIdentifier("review-tool-adjust")
                pageAction("Rotate", icon: "rotate.right") {
                    change { $0.pages[index].turns = ($0.pages[index].turns + 1) % 4; $0.pages[index].trimming = $0.pages[index].trimming.rotatedClockwise(); $0.searchable = false }
                }
                .accessibilityIdentifier("review-tool-rotate")
                pageAction("Hide", icon: "eye.slash") { hiding = HideRoute(page: index) }
                    .accessibilityIdentifier("review-tool-hide")
                Menu {
                    Button("Reorder pages") { withAnimation { reordering = true } }.disabled(doc.pages.count < 2)
                    Button("Duplicate page") { change { value in var copy = page; copy.id = UUID(); value.pages.insert(copy, at: index+1) } }
                    if page.sourcePDF == nil, page.crop != .full, page.identityBackgroundCleanup != true {
                        Toggle(isOn: Binding(get: { page.flatten == true }, set: { on in
                            change {
                                $0.pages[index].flatten = on
                                $0.pages[index].textBlocks = []; $0.pages[index].ocrComplete = false; $0.pages[index].ocrProcessingVersion = nil
                                $0.searchable = false
                            }
                        })) { Label("Flatten curled page", systemImage: "doc.plaintext") }
                        .accessibilityIdentifier("review-flatten")
                    }
                    Button("Apply tone and adjustments to all pages") { change { $0.applyAppearance(from: page) } }
                        .disabled(doc.pages.contains { $0.preservesPDF })
                    Button("Move earlier") { change { $0.pages.swapAt(index, index-1) }; current = index - 1 }.disabled(index == 0)
                    Button("Move later") { change { $0.pages.swapAt(index, index+1) }; current = index + 1 }.disabled(index == doc.pages.count-1)
                    Button("Retake page") { openCamera(retaking: page.id) }
                    Button("Delete page", role: .destructive) {
                        if doc.pages.count == 1 { deletingLast = true } else { change { $0.pages.remove(at: index) }; current = max(0, index - 1) }
                    }
                } label: { pageActionLabel("More", icon: "ellipsis") }
                .accessibilityLabel("Page \(index+1) actions").accessibilityIdentifier("page-actions-\(index+1)")
            }
            .padding(.vertical, 6)
            .background(TK.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if doc.pages.count > 1 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(doc.pages.enumerated()), id: \.element.id) { i, item in
                            Button {
                                // Tap a page to show it; tap the shown page again to edit it.
                                if i == index { editPage = item } else { withAnimation { current = i } }
                            } label: {
                                VStack(spacing: 4) {
                                    PageThumbnail(page: item).frame(width: 52, height: 68)
                                        .padding(4).background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(i == index ? TK.blue : TK.grey200, lineWidth: i == index ? 2.5 : 1))
                                        .overlay(alignment: .topTrailing) {
                                            if item.cropReviewNeeded == true { Circle().fill(Color.orange).frame(width: 10, height: 10).offset(x: 3, y: -3) }
                                        }
                                    Text("\(i + 1)").font(.system(size: 12, weight: i == index ? .bold : .medium)).foregroundStyle(i == index ? TK.blue : TK.grey600)
                                }
                            }
                            .buttonStyle(.plain).id(item.id)
                            .accessibilityLabel("Edit page \(i+1)")
                            // Long-press and drag a thumbnail onto another to move it there.
                            .draggable(item.id.uuidString) {
                                PageThumbnail(page: item).frame(width: 52, height: 68).padding(4)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first, let from = doc.pages.firstIndex(where: { $0.id.uuidString == id }), from != i else { return false }
                                let moving = doc.pages[from].id
                                change { $0.pages.move(fromOffsets: IndexSet(integer: from), toOffset: i > from ? i + 1 : i) }
                                if let at = document?.pages.firstIndex(where: { $0.id == moving }) { withAnimation { current = at } }
                                return true
                            }
                        }
                    }.padding(.horizontal, 2).padding(.vertical, 2)
                }
                .onChange(of: index) { _, value in if doc.pages.indices.contains(value) { withAnimation { proxy.scrollTo(doc.pages[value].id, anchor: .center) } } }
            }
            }
        }
        .padding(.horizontal, 4).padding(.top, 4)
        .onChange(of: doc.pages.count) { old, new in if new > old, new > 0 { current = new - 1 } }
    }
    /// Folder, paper, orientation and margins of the PDF. In the save sheet each
    /// field is a labelled row (outside a List a Picker shows no label).
    @ViewBuilder private func pdfOptionFields(_ doc: ScanDocument, rows: Bool = false) -> some View {
        let folder = Binding(get: { document?.folder ?? "Scans" }, set: { document?.folder = $0; persistDraft() })
        let paper = Binding(get: { document?.paper ?? .letter }, set: { document?.paper = $0; persistDraft() })
        let landscape = Binding(get: { document?.landscape ?? false }, set: { value in change { $0.landscape = value } })
        let margin = Binding(get: { document?.margin ?? .small }, set: { document?.margin = $0; persistDraft() })
        if rows {
            optionRow("Folder") { Picker("Folder", selection: folder) { ForEach(store.manifest.folders, id: \.self) { Text(L($0)).tag($0) } }.labelsHidden() }
            optionRow("Paper") { Picker("Paper", selection: paper) { ForEach(PaperSize.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) } }.labelsHidden() }
            Toggle("Landscape", isOn: landscape).font(.system(size: 15))
            optionRow("Margins") { Picker("Margins", selection: margin) { ForEach(PageMargin.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) } }.labelsHidden() }
        } else {
            Picker("Folder", selection: folder) { ForEach(store.manifest.folders, id: \.self) { Text($0).tag($0) } }
            Picker("Paper", selection: paper) { ForEach(PaperSize.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Toggle("Landscape", isOn: landscape)
            Picker("Margins", selection: margin) { ForEach(PageMargin.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        }
        if doc.pages.contains(where: { $0.trimming != .zero }) { Text("For no added white space, choose Original paper and None margins. A4 and US Letter keep their shape and may add white space.").font(.caption).foregroundStyle(.secondary) }
        if doc.pages.contains(where: { $0.sourcePDF != nil }) { Text("Changing PDF paper or margins keeps text and links but flattens interactive forms. The imported original is retained.").font(.caption).foregroundStyle(.secondary) }
    }
    private func optionRow<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack { Text(L(title)).font(.system(size: 15)); Spacer(); content() }
    }
    private func pageAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { pageActionLabel(title, icon: icon) }.buttonStyle(.plain)
    }
    private func pageActionLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 19, weight: .medium)).frame(height: 24)
            Text(L(title)).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(TK.grey800)
        .frame(maxWidth: .infinity, minHeight: 56).contentShape(Rectangle())
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
    /// From the saved page back to the editor; saving again replaces the saved file.
    private func editAgain() {
        error = nil; undoHistory = []; redoHistory = []
        editingAfterSave = true
        saved = false
    }
    /// Cancel in the editor after Edit: the saved file stays as it was.
    private func leaveEditAgain() {
        do {
            if let id = workingDraftID, let draft = store.document(id) { try store.permanentlyDelete(draft) }
            workingDraftID = nil
            document = store.document(documentID)
            editingAfterSave = false
            saved = true
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
    private func finishSaved() {
        guard !finishing else { return }; finishing = true
        if completionAdEnabled {
            completionAds.finish(session: adSession, policy: adPolicy,
                                 onPresented: { homeAds.suppressAfterCompletion() },
                                 completion: { onCompleted(); dismiss() })
        } else { onCompleted(); dismiss() }
    }
    private func save(forceText: Bool = false) {
        guard var doc = document else { return }
        doc.title = doc.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if doc.title.isEmpty { doc.title = ScanDocument.defaultTitle(); doc.autoTitled = true }
        document = doc
        guard pagesReady() else { return }
        saving = true; error = nil; saveProgress = "Preparing PDF…"
        let root = store.root
        // PNG or JPEG: only a new scan saved from its settings page makes pictures.
        let pictures = doc.isDraft || editingAfterSave ? imageFormat : nil, pixels = imagePixels
        savingKind = pictures == nil ? .save : .images
        saveTask = Task {
            do {
                let result = try await PDFExport.prepare(doc, root: root, forceText: forceText) { saveProgress = $0 }
                try Task.checkCancellation()
                try store.savePDF(result.data, document: result.document, replacingDraft: workingDraftID)
                if subscription.isPro, let saved = store.document(result.document.id) {
                    let data = result.data, title = saved.title
                    Task.detached(priority: .utility) { AutoExport.export(data, title: title) }
                }
                workingDraftID = nil
                document = store.document(documentID)
                textNotice = result.textNotice; textRetryNeeded = !result.failedTextPages.isEmpty
                if let pictures, let file = store.document(documentID)?.pdfFile {
                    saveProgress = "Making images…"
                    let url = store.url(file)
                    if let old = imageFiles { ExportFiles.remove(old.directory); imageFiles = nil }
                    do {
                        imageFiles = try await OfflineWork.perform { () throws -> ExportedFiles in
                            guard let pdf = PDFDocument(url: url) else { throw ScannerError.message("This PDF can't be opened.") }
                            return try ExportFiles.images(pdf, indices: Array(0..<pdf.pageCount), pixels: pixels, format: pictures)
                        }
                        savedToPhotos = false
                    } catch { self.error = "The images couldn't be made. The PDF is saved. \(error.localizedDescription)" }
                }
                Instant.run { saved = true; settingsOpen = false; editingAfterSave = false }
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
    /// Capture review: discard this capture and go back to the camera.
    var onRetake: (() throws -> Void)? = nil
    var doneTitle = "Done"
    var dismissOnSave = true
    var scanStyle = CaptureStyle.document
    /// Tab to open on ("Crop", "Tone", "Adjust" or "Retouch"); the review's tool row picks it.
    var initialTool: String? = nil
    /// Called once, when the page's first preview has been rendered.
    var onPreviewReady: (() -> Void)? = nil
    let onSave: (ScanPage) throws -> Void
    @State private var cropping = false
    @State private var trimming = false
    @State private var erasing = false
    @State private var erasingFingers = false
    @State private var comparingOriginal = false
    @State private var detecting = false
    @State private var previewReady = false
    /// Set once the page's first preview is up (or after 3 s): the tone row waits for it,
    /// so its small renders don't compete with the big one the user is waiting for.
    @State private var firstPreviewShown = false
    @State private var message: String?
    @State private var saveError: String?
    @State private var confirmStop = false
    @State private var selectedTool = EditorTool.tone
    @State private var selectedAdjustment = Adjustment.brightness
    @State private var pendingAction: FinishAction?
    @State private var rasterConfirmation = false
    @State private var rasterAction: FinishAction?
    private enum EditorTool: String, CaseIterable {
        case crop = "Crop", tone = "Tone", adjust = "Adjust", retouch = "Retouch"
        var icon: String {
            switch self { case .crop: "crop"; case .tone: "circle.lefthalf.filled"; case .adjust: "slider.horizontal.3"; case .retouch: "wand.and.stars" }
        }
    }
    private enum FinishAction { case done, addPage }
    private enum Adjustment: String, CaseIterable {
        case brightness = "Brightness", contrast = "Contrast", sharpness = "Sharpness", cleanup = "Cleanup"
        var icon: String {
            switch self { case .brightness: "sun.max"; case .contrast: "circle.righthalf.filled"; case .sharpness: "triangle"; case .cleanup: "sparkles" }
        }
    }
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
                        ScanPreview(page: displayedPage, onReady: { ready in
                            if ready && !previewReady { onPreviewReady?() }
                            if ready { firstPreviewShown = true }
                            previewReady = ready
                        })
                            .task { try? await Task.sleep(for: .seconds(3)); firstPreviewShown = true }
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
                                            Text(L(tool.rawValue)).font(.subheadline.weight(.medium))
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
                        if let message { Text(L(message)).font(.subheadline).foregroundStyle(.red) }
                    }.padding(20)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if captureReview {
                    HStack(spacing: 12) {
                        if onAddPage != nil { Button { finish(.addPage) } label: { Label("Add page", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 18).background(Design.muted, in: RoundedRectangle(cornerRadius: 16)) }
                            .accessibilityIdentifier("review-add-page") }
                        Button(L(doneTitle)) { finish(.done) }.buttonStyle(PrimaryButton()).accessibilityIdentifier("review-done")
                    }.disabled(detecting || !previewReady).padding(.horizontal, 20).padding(.vertical, 12).background(TK.paper)
                }
            }
            .onAppear { if let initialTool, let tool = EditorTool(rawValue: initialTool) { selectedTool = tool } }
            .navigationTitle(captureReview ? "Review scan" : "Edit page").navigationBarTitleDisplayMode(.inline)
            .alert("Convert this PDF page for image editing?", isPresented: $rasterConfirmation) {
                Button("Apply image edits") { if let action = rasterAction { commitFinish(action) } }
                Button("Cancel", role: .cancel) { rasterAction = nil }
            } message: { Text("Text will be recognized again. Original links and forms on this page will not be kept in the edited output. The imported original remains stored.") }
            .alert("Stop scanning?", isPresented: $confirmStop) {
                Button("Stop scanning", role: .destructive) {
                    do { try onCancelCapture?() }
                    catch { saveError = error.localizedDescription }
                }
                Button("Keep editing", role: .cancel) {}
            } message: { Text("This page won't be saved.") }
            .alert("This action couldn't be completed", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
            .toolbar {
                if captureReview {
                    ToolbarItem(placement: .cancellationAction) {
                        // Cancel leaves scanning (after a confirmation); this capture
                        // is discarded and previously accepted pages stay intact.
                        Button("Cancel") { confirmStop = true }
                            .disabled(detecting).accessibilityIdentifier("capture-review-cancel")
                    }
                    if onRetake != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                do { try onRetake?() }
                                catch { saveError = error.localizedDescription }
                            } label: { Label("Retake", systemImage: "camera.rotate").labelStyle(.titleAndIcon) }
                            .disabled(detecting).accessibilityIdentifier("capture-review-retake")
                        }
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
                PageEraseSheet(page: page, findFingers: erasingFingers) { strokes in
                    var list = page.activeErasures
                    list.append(PageErasure(strokes: strokes.map { PageErasure.Stroke(points: $0.points, width: Double($0.width)) }, crop: page.crop, turns: page.turns, trim: page.edgeTrim))
                    page.erasures = list; changed()
                }
            }
            .sheet(isPresented: $cropping, onDismiss: {
                if let action = pendingAction, page.cropReviewNeeded != true { pendingAction = nil; finish(action) }
                else { pendingAction = nil }
            }) {
                CropView(page: page, confirmationRequired: captureReview && page.cropReviewNeeded == true, detect: { [style = scanStyle] in style.detect($0, capturedPhoto: true) }) { quad in
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
            ToneThumbnails(page: page, ready: firstPreviewShown) { tone in
                guard page.enhancement != tone else { return }
                page.enhancement = tone
                if tone == .original && selectedAdjustment == .cleanup { selectedAdjustment = .brightness }
                changed()
            }
        case .adjust:
            VStack(spacing: 14) {
                // Every adjustment is visible at once; the slider below edits the chosen one.
                HStack(spacing: 8) {
                    ForEach(Adjustment.allCases.filter { $0 != .cleanup || page.enhancement != .original }, id: \.self) { item in
                        let on = selectedAdjustment == item
                        Button { selectedAdjustment = item } label: {
                            VStack(spacing: 4) {
                                Image(systemName: item.icon).font(.system(size: 17, weight: .medium))
                                Text(L(item.rawValue)).font(.caption.weight(on ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .foregroundStyle(on ? Design.blue : .primary)
                            .background(on ? Design.blue.opacity(0.10) : Design.muted, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Design.blue.opacity(0.5) : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.rawValue)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("adjustment-" + item.rawValue.lowercased())
                    }
                }
                VStack(spacing: 4) {
                    HStack {
                        Text(L(selectedAdjustment.rawValue)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(L(adjustmentValue)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityIdentifier("adjustment-value")
                    }
                    Slider(value: adjustmentBinding, in: adjustmentRange)
                        .accessibilityLabel(selectedAdjustment.rawValue)
                        .accessibilityIdentifier(selectedAdjustment.rawValue.lowercased() + "-slider")
                }
                .padding(.horizontal, 4)
                Button {
                    page.enhancement = .document; page.enhancementAmount = nil; page.adjustments = nil; changed()
                } label: {
                    Label("Reset adjustments", systemImage: "arrow.counterclockwise").font(.footnote.weight(.medium))
                }
                .foregroundStyle(.secondary).frame(minHeight: 36)
            }
            .padding(.horizontal, 4)
        case .retouch:
            VStack(spacing: 10) {
                retouchCard("Erase spots", detail: "Paint over stains, marks or dust to remove them", icon: "eraser.line.dashed", identifier: "editor-erase") {
                    erasingFingers = false; erasing = true
                }
                retouchCard("Remove fingers", detail: "Finds fingers holding the page and paints them out", icon: "hand.raised", identifier: "editor-fingers") {
                    erasingFingers = true; erasing = true
                }
                if !page.activeErasures.isEmpty {
                    Button { page.erasures = Array(page.activeErasures.dropLast()); if page.erasures?.isEmpty == true { page.erasures = nil }; changed() } label: {
                        Label("Undo last erase", systemImage: "arrow.uturn.backward").font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(.secondary).frame(minHeight: 36)
                    .accessibilityIdentifier("editor-erase-undo")
                }
            }
        }
    }
    private func retouchCard(_ title: String, detail: String, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(Design.blue)
                    .frame(width: 44, height: 44).background(Design.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(title)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(L(detail)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Design.muted, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(!previewReady).accessibilityIdentifier(identifier)
    }
    private func cropAction(_ title: String, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(L(title), systemImage: icon).font(.subheadline)
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
    /// "Detect edges" finds the page the way a camera scan does (rectangle, else
    /// the paper outline of a curled sheet); cards pass their own detector.
    var detect: @Sendable (UIImage) -> ScanQuad? = { Imaging.detectPage($0) }
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
                            let detect = detect
                            if let detected = await Task.detached(operation: { detect(original) }).value { quad = detected; detectionMessage = nil }
                            else { detectionMessage = "Edges weren't found. Drag the corners to the paper, or confirm the full image." }
                        }
                    }
                }.padding(24)
                if let detectionMessage { Text(L(detectionMessage)).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
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

/// Spot eraser on a scanned page: paint over stains or shadows left after the
/// automatic cleanup. The strokes are stored on the page and applied when it
/// renders, so the original photo is never changed.
struct PageEraseSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let page: ScanPage
    var findFingers = false
    let apply: ([ImageToolEngine.Stroke]) -> Void
    @State private var image: UIImage?
    @State private var fingerNote: String?
    @State private var strokes: [ImageToolEngine.Stroke] = []
    @State private var brush = 0.035
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            ToolPage(title: "Erase spots", subtitle: "Paint over stains, shadows or marks. Pinch to zoom in for small spots.", scrolls: false) {
                if let image {
                    HStack(spacing: 8) {
                        Button { detectFingers(image) } label: { Label("Find fingers", systemImage: "hand.raised") }
                            .buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("page-erase-fingers")
                        if let fingerNote { Text(L(fingerNote)).font(.footnote).foregroundStyle(TK.grey600).lineLimit(2) }
                        Spacer(minLength: 0)
                    }
                    ErasePainter(image: image, strokes: $strokes, brush: $brush)
                }
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
            do {
                let rendered = try await ScanPreviewRenderer().render(page, root: root, maxDimension: 2400)
                image = rendered
                if findFingers { detectFingers(rendered) }
            } catch { failure = error.localizedDescription }
        }
    }
    /// Paints over fingers found at the page edges; the person can still adjust before erasing.
    private func detectFingers(_ image: UIImage) {
        fingerNote = "Looking for fingers…"
        Task {
            let found = (try? await Task.detached { try ImageToolEngine.fingerStrokes(image) }.value) ?? []
            if found.isEmpty { fingerNote = "No fingers found at the edges. Paint over them instead." }
            else { strokes += found; fingerNote = "Fingers marked. Check the red area, then tap Erase." }
        }
    }
}

/// Tone choices shown as small previews of this page in each tone, so the
/// result is visible before tapping.
private struct ToneThumbnails: View {
    @EnvironmentObject var store: LibraryStore
    let page: ScanPage
    var ready = true
    let onSelect: (Enhancement) -> Void
    @State private var images: [Enhancement: UIImage] = [:]
    private struct Request: Equatable { let page: ScanPage; let ready: Bool }
    /// Everything but the tone itself decides what the previews look like.
    private var key: ScanPage { var p = page; p.enhancement = .original; return p }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Enhancement.allCases, id: \.self) { tone in
                        let selected = page.enhancement == tone
                        Button { onSelect(tone) } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Design.muted
                                    if let image = images[tone] {
                                        Image(uiImage: image).resizable().interpolation(.medium).scaledToFill()
                                    } else {
                                        ProgressView()
                                    }
                                }
                                .frame(width: 84, height: 108)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Design.blue : Color.black.opacity(0.08), lineWidth: selected ? 2.5 : 1))
                                Text(L(tone.rawValue)).font(.footnote.weight(selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? Design.blue : .primary)
                                    .lineLimit(1).minimumScaleFactor(0.75).frame(width: 88)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(tone)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("editor-tone-" + tone.rawValue)
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 2)
            }
            .onAppear { proxy.scrollTo(page.enhancement, anchor: .center) }
        }
        .task(id: Request(page: key, ready: ready)) {
            guard ready else { return }
            let request = key, root = store.root
            let rendered = await Task.detached(priority: .utility) { (try? Imaging.renderToneThumbnails(request, root: root, maxDimension: 240)) ?? [:] }.value
            if Task.isCancelled { return }
            if !rendered.isEmpty { images = rendered }
        }
    }
}

/// Opens the hide editor on a page of the review.
struct HideRoute: Identifiable {
    let id = UUID()
    let page: Int
    var notice: String? = nil
}

/// The review's save button: the app's pastel blue for PDF, the format's own
/// colour with white text for Word, Excel, PowerPoint and images.
struct FormatSaveButton: ButtonStyle {
    let fill: Color?
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        if let fill {
            configuration.label.font(.system(.body, design: .default, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 18)
                .foregroundStyle(.white)
                .background(fill.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 18))
                .opacity(isEnabled ? 1 : 0.5)
        } else {
            PrimaryButton().makeBody(configuration: configuration)
        }
    }
}
