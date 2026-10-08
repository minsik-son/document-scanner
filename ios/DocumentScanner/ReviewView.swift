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
    /// Page shown large in the review; the strip below picks another one.
    @State private var current = 0
    /// Edit mode: the compact list for reordering and deleting pages.
    @State private var reordering = false

    var body: some View {
        NavigationStack {
            Group {
                if captureOnOpen && cameraFirst {
                    Color.black.ignoresSafeArea().toolbar(.hidden, for: .navigationBar)
                } else if let doc = document {
                    if saved {
                        // The finished PDF itself; back returns to the home screen.
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(TK.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Saved on this iPhone").font(.system(size: 16, weight: .bold)).foregroundStyle(TK.grey900)
                                    Text(doc.searchable ? "\(doc.title) · text can be copied" : doc.title)
                                        .font(.system(size: 13)).foregroundStyle(TK.grey600).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                if let saved = store.document(documentID), let file = saved.pdfFile {
                                    ShareLink(item: SharedPDF.url(for: store.url(file), title: saved.title)) {
                                        Label("Share", systemImage: "square.and.arrow.up").font(.system(size: 15, weight: .semibold))
                                            .padding(.horizontal, 14).frame(height: 36).background(TK.blueSoft, in: Capsule()).foregroundStyle(TK.blue)
                                    }.accessibilityLabel("Share PDF")
                                }
                            }
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            if textNotice != nil || textRetryNeeded || saving || error != nil || doc.captureStyle == .card {
                                VStack(alignment: .leading, spacing: 8) {
                                    if let textNotice { Text(L(textNotice)).font(.system(size: 13)).foregroundStyle(TK.grey600) }
                                    if textRetryNeeded { Button("Retry text recognition") { save(forceText: false) }.font(.system(size: 14, weight: .semibold)).disabled(saving) }
                                    if saving { ProgressView(saveProgress).font(.system(size: 13)) }
                                    if let error { Text(L(error)).font(.system(size: 13)).foregroundStyle(TK.red) }
                                    if doc.captureStyle == .card {
                                        Button("Arrange ID card on one page") { identityLayout = true }.buttonStyle(ChipStyle(selected: false))
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12)
                            }
                            if let file = store.document(documentID)?.pdfFile {
                                PDFPreview(url: store.url(file)).ignoresSafeArea(edges: .bottom)
                                    .accessibilityIdentifier("saved-pdf")
                            } else { Spacer() }
                        }
                        .background(TK.paper)
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
                            Section {
                                TextField("Document name", text: Binding(get: { document?.title ?? "" }, set: { document?.title = $0; document?.autoTitled = false; persistDraft() }))
                                if document?.autoTitled == true {
                                    Label("Named automatically from the text when you save", systemImage: "sparkles").font(.footnote).foregroundStyle(.secondary)
                                }
                                DisclosureGroup("Save options", isExpanded: $options) {
                                    Picker("Folder", selection: Binding(get: { document?.folder ?? "Scans" }, set: { document?.folder = $0; persistDraft() })) { ForEach(store.manifest.folders, id: \.self) { Text($0).tag($0) } }
                                    Picker("Paper", selection: Binding(get: { document?.paper ?? .letter }, set: { document?.paper = $0; persistDraft() })) { ForEach(PaperSize.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                                    Toggle("Landscape", isOn: Binding(get: { document?.landscape ?? false }, set: { value in change { $0.landscape = value } }))
                                    Picker("Margins", selection: Binding(get: { document?.margin ?? .small }, set: { document?.margin = $0; persistDraft() })) { ForEach(PageMargin.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                                    if doc.pages.contains(where: { $0.trimming != .zero }) { Text("For no added white space, choose Original paper and None margins. A4 and US Letter keep their shape and may add white space.").font(.caption).foregroundStyle(.secondary) }
                                    if doc.pages.contains(where: { $0.sourcePDF != nil }) { Text("Changing PDF paper or margins keeps text and links but flattens interactive forms. The imported original is retained.").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            if let error { Section { Text(L(error)).foregroundStyle(.red) } }
                        }.listStyle(.insetGrouped).disabled(saving)
                        .environment(\.editMode, .constant(reordering ? .active : .inactive))
                        .safeAreaInset(edge: .bottom) {
                            VStack(spacing: 12) {
                                Button { openCamera(retaking: nil) } label: { Label("Add pages", systemImage: "camera") }
                                    .buttonStyle(SecondaryButton()).disabled(saving)
                                if saving { Text(L(saveProgress)).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("save-progress") }
                                Button { save() } label: { if saving { ProgressView().tint(Design.blueInk).frame(maxWidth: .infinity) } else { Text(doc.isDraft ? "Save PDF" : "Save changes") } }.buttonStyle(PrimaryButton()).disabled(saving || doc.pages.isEmpty)
                            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8).background(.white)
                        }
                    }
                } else { ProgressView() }
            }
            .navigationTitle(saved ? "PDF" : "Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if saved {
                        Button { finishSaved() } label: {
                            HStack(spacing: 4) { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)); Text(L(savedBackTitle)) }
                        }.disabled(saving || finishing).accessibilityIdentifier("saved-done")
                    } else { Button(document?.isDraft == true ? "Close" : "Cancel") { cancelEditing() }.disabled(saving) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !saved {
                        HStack(spacing: 2) {
                            Button { restoreHistory(undo: true) } label: { Image(systemName: "arrow.uturn.backward") }
                                .disabled(undoHistory.isEmpty || saving).accessibilityLabel("Undo")
                            Button { restoreHistory(undo: false) } label: { Image(systemName: "arrow.uturn.forward") }
                                .disabled(redoHistory.isEmpty || saving).accessibilityLabel("Redo")
                            Button(reordering ? "Done" : "Edit") { withAnimation { reordering.toggle() } }.disabled(saving)
                                .accessibilityHint("Reorder or delete pages")
                        }
                    }
                }
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
    /// The page to check, shown big, with its actions and every page in a strip below.
    @ViewBuilder private func pagePreview(_ doc: ScanDocument) -> some View {
        let index = min(current, doc.pages.count - 1)
        let page = doc.pages[index]
        VStack(spacing: 14) {
            Button { editPage = page } label: {
                PageThumbnail(page: page)
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
                pageAction("Adjust", icon: "slider.horizontal.3") { editPage = page }
                    .accessibilityHint("Crop, rotate, and adjust")
                pageAction("Retake", icon: "camera.rotate") { openCamera(retaking: page.id) }
                Menu {
                    Button("Duplicate page") { change { value in var copy = page; copy.id = UUID(); value.pages.insert(copy, at: index+1) } }
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
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        if doc.title.isEmpty { doc.title = "Scan \(Date().formatted(date: .abbreviated, time: .shortened))"; doc.autoTitled = true }
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
                if subscription.isPro, let saved = store.document(result.document.id) {
                    let data = result.data, title = saved.title
                    Task.detached(priority: .utility) { AutoExport.export(data, title: title) }
                }
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
    @State private var erasingFingers = false
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
            ToneThumbnails(page: page) { tone in
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
    let onSelect: (Enhancement) -> Void
    @State private var images: [Enhancement: UIImage] = [:]
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
        .task(id: key) {
            let request = key, root = store.root
            let rendered = await Task.detached(priority: .utility) { (try? Imaging.renderToneThumbnails(request, root: root, maxDimension: 240)) ?? [:] }.value
            if Task.isCancelled { return }
            if !rendered.isEmpty { images = rendered }
        }
    }
}
