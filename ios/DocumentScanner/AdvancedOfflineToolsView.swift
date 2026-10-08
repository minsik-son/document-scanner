import SwiftUI
import PhotosUI
import PDFKit
import Translation
import QuickLook
import VisionKit
import UniformTypeIdentifiers

enum AdvancedTool:String,Identifiable,CaseIterable {
    case word = "Word export", excel = "Excel export", slides = "PowerPoint export", translate = "Photo translation"
    case book = "Book pages", portrait = "ID photo", erase = "Spot eraser", marks = "Remove colored marks", restore = "Restore photo"
    case mega = "Mega scan", count = "Count objects", measure = "Measure", mesh = "3D scan", math = "Math scan"
    var id:String { rawValue }
    /// Hidden for now; the code stays for a later update.
    var hidden:Bool { self == .count }
    var office:Bool { [.word,.excel,.slides].contains(self) }
    var textTool:Bool { [.word,.excel,.translate,.math].contains(self) }
    var detail:String {
        switch self {
        case .word:return "Editable DOCX that keeps tables, merged cells and colours. Check the text before exporting."
        case .excel:return "Editable XLSX cells. Tabs separate columns and new lines separate rows. Values are exported as text, never formulas."
        case .slides:return "Create a PPTX with one page per slide. Keep the page image or use editable OCR text."
        case .translate:return "Translate using languages already installed on this iPhone. This tool does not download models. iOS 26 or later required."
        case .book:return "Split a book spread at the gutter and adjust a simple page-curve model. Preview both pages before saving."
        case .portrait:return "Remove the background, center the detected face and choose the photo dimensions. Check the requirements of your issuing authority."
        case .erase:return "Drag over a small mark. Nearby edge colors fill the selection. Best for plain paper; complex textures may show a seam."
        case .marks:return "Reduce colored pen and highlighter marks while protecting dark ink. Colored document content can also be affected."
        case .restore:return "Reduce noise and improve contrast and detail. This does not reconstruct missing faces or torn parts of a photo."
        case .mega:return "Arrange 2–8 overlapping photos on one canvas. Crop and straighten each photo first. Match shared features with the horizontal/vertical controls."
        case .count:return "Find separated dark or light objects against a contrasting background. Tap to add or remove count markers. Touching objects may need manual correction."
        case .measure:return "Measure the distance between two surface points with the camera."
        case .mesh:return "Capture a local, untextured surface mesh with supported LiDAR hardware."
        case .math:return "Scan, review recognized text and export TXT, Word, PDF, RTF or HTML. Handwriting and complex math need manual review. An arithmetic calculator is also available."
        }
    }
}
struct AdvancedOfflineHub: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var subscription: SubscriptionStore
    /// Its own ad, separate from the one on Home.
    @StateObject private var toolAds = HomeAdvertisementStore(placement: .tools)
    @State private var paywall = false
    @State private var smartRoute: SmartTool?
    @State private var advancedRoute: AdvancedTool?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query = ""
    @State private var quick: QuickTool?
    @State private var capture: ScanRoute?
    @State private var unsupported: AdvancedTool?
    var documentID: UUID? = nil
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 2 : 4) }
    private func matches(_ title: String) -> Bool { query.isEmpty || title.localizedCaseInsensitiveContains(query) }
    private var hasMatches: Bool {
        ToolSection.all.contains { section in section.entries.contains { $0.available && (matches($0.title) || $0.keywords.contains(where: matches)) } }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // No large title: close and search share the top row, a common pattern in scanner apps.
                    HStack(spacing: 10) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Design.ink)
                                .frame(width: 44, height: 44).background(.white, in: Circle())
                        }.accessibilityLabel("Close")
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search all tools", text: $query).autocorrectionDisabled()
                                .accessibilityIdentifier("tool-search")
                            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                        }.padding(.horizontal, 14).frame(height: 44).background(.white, in: Capsule())
                    }
                    if subscription.isPro && query.isEmpty {
                        HStack {
                            Label("All \(PaywallView.proToolCount) Pro tools unlocked", systemImage: "sparkles").font(.footnote.weight(.semibold))
                            Spacer()
                            Text("PRO").font(.system(size: 10, weight: .black)).foregroundStyle(ProTheme.goldInk)
                                .padding(.horizontal, 7).padding(.vertical, 3).background(ProTheme.goldPill, in: Capsule())
                        }
                        .foregroundStyle(.white).padding(.horizontal, 4).padding(.top, -8)
                    }
                    // Sections follow what the user is trying to get done.
                    ForEach(Array(ToolSection.all.enumerated()), id: \.offset) { index, section in
                        toolSection(section)
                        if index == 1 && query.isEmpty {
                            // Free users: one native ad card mid-page, styled like Home's. Nothing until it loads.
                            HomeAdvertisementSlot(homeUncovered: quick == nil && capture == nil && !paywall && smartRoute == nil && advancedRoute == nil, reserveSpace: false) {
                                EmptyView()
                            }
                            .environmentObject(toolAds)
                        }
                    }
                    if !hasMatches { ContentUnavailableView("No tools found", systemImage: "magnifyingglass", description: Text("Try another tool name.")) }
                    Label("Processed on this iPhone", systemImage: "iphone").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 20)
            }.background { if subscription.isPro { ProPageBackground(band: 96) } else { Design.muted.ignoresSafeArea() } }
                .navigationTitle("All tools")
                .toolbar(.hidden, for: .navigationBar)
                .buttonStyle(.plain)
                .sheet(item: $quick) { QuickToolView(tool: $0, documentID: documentID) }
                .sheet(isPresented: $paywall) { PaywallView(start: .smartTool) }
                .navigationDestination(item: $smartRoute) { $0.destination }
                .navigationDestination(item: $advancedRoute) { tool in
                    if tool == .measure { MeasureToolView() }
                    else if tool == .mesh { MeshToolView() }
                    else { AdvancedOfflineToolView(tool: tool, documentID: documentID) }
                }
                .fullScreenCover(item: $capture, onDismiss: { store.perform { try store.discardEmptyDrafts() } }) { ReviewView(documentID: $0.id, captureOnOpen: true) }
                .alert("Something needs attention", isPresented: Binding(get: { store.problem != nil }, set: { if !$0 { store.problem = nil } })) { Button("OK") { store.problem = nil } } message: { Text(store.problem ?? "") }
                .alert("Requires iOS 26", isPresented: Binding(get: { unsupported != nil }, set: { if !$0 { unsupported = nil } })) { Button("OK") { unsupported = nil } } message: {
                    Text("Photo translation uses Apple's on-device translation, available on iOS 26 or later. Update iOS to use it.")
                }
        }
    }
    @ViewBuilder private func toolSection(_ section: ToolSection) -> some View {
        let visible = section.entries.filter { $0.available && (matches($0.title) || $0.keywords.contains(where: matches)) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(L(section.title)).font(.headline).accessibilityIdentifier("tool-section-" + section.id)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(visible) { entry in tile(entry) }
                }
            }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 26))
        }
    }
    @ViewBuilder private func tile(_ entry: ToolEntry) -> some View {
        switch entry {
        case .scan: Button { startScan(.document) } label: { ToolTile(title: entry.title, icon: "scan") }
        case .whiteboard: Button { startScan(.whiteboard) } label: { ToolTile(title: entry.title, icon: "whiteboard") }
        case .qr: Button { quick = .qr } label: { ToolTile(title: entry.title, icon: "qr") }.accessibilityLabel("QR code")
        case .stitch: Button { quick = .stitch } label: { ToolTile(title: entry.title, icon: "stitch") }.accessibilityLabel("Stitch screenshots")
        case .library(let tool):
            Button { quick = .library(tool) } label: { ToolTile(title: tool.rawValue, icon: tool.icon, pro: tool.pro, feature: tool.proFeature) }
                .accessibilityLabel(tool.rawValue + (tool.pro ? ", Pro" : ""))
                .accessibilityIdentifier(tool == .identity ? "id-scan-tool" : "library-tool-" + tool.icon)
        case .advanced(let tool):
            Button {
                if tool == .translate && !PhotoTranslationSupport.available { unsupported = tool } else { advancedRoute = tool }
            } label: { ToolTile(title: tool.rawValue, icon: tool.icon, pro: tool.pro, feature: tool.proFeature) }.accessibilityLabel(tool.rawValue)
        case .smart(let tool):
            Button { if tool.proFeature == nil && locked(tool.pro) { paywall = true } else { smartRoute = tool } } label: { ToolTile(title: tool.title, icon: tool.icon, pro: tool.pro, feature: tool.proFeature) }
                .accessibilityIdentifier("smart-tool-" + tool.rawValue)
        }
    }
    /// Pro tools without a free try (Auto-save) open the subscription page for free users.
    /// Every other Pro tool opens and shows its free-try screen first.
    private func locked(_ pro: Bool) -> Bool {
        guard pro, !subscription.isPro else { return false }
        #if DEBUG
        // UI tests reach Pro tools unless they test the gate itself.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-test-session") && !args.contains("--test-pro-gate") { return false }
        #endif
        return true
    }
    private func startScan(_ style: CaptureStyle) {
        guard store.storageAvailable else { return }
        store.perform {
            let id = try store.createDraft()
            if var doc = store.document(id) { doc.captureStyle = style; try store.update(doc) }
            Instant.run { capture = ScanRoute(id: id) }
        }
    }
}
/// Entry point for advanced tools. Pro tools show a lock screen with a few
/// free tries before the actual tool opens.
struct AdvancedOfflineToolView:View {
    let tool:AdvancedTool
    var documentID:UUID?
    var body:some View {
        if tool == .translate && !PhotoTranslationSupport.available {
            // Before any free try is used: this iPhone cannot run Apple's translation.
            ContentUnavailableView("Requires iOS 26", systemImage: "character.bubble",
                                   description: Text("Photo translation uses Apple's on-device translation, available on iOS 26 or later. Update iOS to use it."))
        } else {
            gate
        }
    }
    private var gate: some View {
        ProTrialGate(feature: tool.proFeature, title: tool.rawValue, detail: tool.detail, art: tool.art) {
            if tool.imageTool {
                ImageToolFlow(tool:tool, documentID:documentID)
            } else {
                AdvancedOfflineToolContent(tool:tool, documentID:documentID)
            }
        }
    }
}
extension AdvancedTool {
    /// Photo tools with their own step-by-step flow.
    var imageTool: Bool { [.book, .portrait, .erase, .marks, .restore, .mega, .count].contains(self) }
}
/// Every way into a Pro tool goes through here: Pro members go straight in,
/// free users see the free-try screen first (before choosing any document),
/// and families without a free try open the subscription page.
struct ProTrialGate<Content: View>: View {
    @EnvironmentObject private var subscription: SubscriptionStore
    let feature: ProFeature?
    let title: String
    let detail: String
    let art: ToolArt
    /// Shown as Close on the free-try screen when the gate is a sheet's root.
    var close: (() -> Void)? = nil
    let content: () -> Content
    @State private var unlocked = false
    @State private var paywall = false
    @State private var trials = ProTrials()
    @State private var refresh = 0
    init(feature: ProFeature?, title: String, detail: String, art: ToolArt, close: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.feature = feature; self.title = title; self.detail = detail; self.art = art; self.close = close; self.content = content
    }
    var body: some View {
        if subscription.isPro || unlocked || trials.bypassed || feature == nil {
            content()
        } else if let feature {
            let _ = refresh
            ProToolLockView(title: title, detail: detail, art: art, feature: feature,
                            remaining: trials.remaining(feature), adUnlocksLeft: trials.adUnlocksLeftToday(feature),
                            tryFree: { ProTrialSession.begin(feature); unlocked = true },
                            upgrade: { paywall = true },
                            rewarded: { trials.grantAdUse(feature); refresh += 1 })
                .sheet(isPresented: $paywall) { PaywallView(start: .feature(feature)) }
                .toolbar { if let close { ToolbarItem(placement: .cancellationAction) { Button("Close", action: close).accessibilityIdentifier("tool-close") } } }
        }
    }
}
struct ProToolLockView:View {
    let title:String
    let detail:String
    let art:ToolArt
    let feature:ProFeature
    let remaining:Int
    var adUnlocksLeft = 0
    let tryFree:() -> Void
    let upgrade:() -> Void
    var rewarded:(() -> Void)? = nil
    @StateObject private var ad = RewardedAdStore()
    init(title: String, detail: String, art: ToolArt, feature: ProFeature, remaining: Int, adUnlocksLeft: Int = 0,
         tryFree: @escaping () -> Void, upgrade: @escaping () -> Void, rewarded: (() -> Void)? = nil) {
        self.title = title; self.detail = detail; self.art = art; self.feature = feature; self.remaining = remaining
        self.adUnlocksLeft = adUnlocksLeft; self.tryFree = tryFree; self.upgrade = upgrade; self.rewarded = rewarded
    }
    var body:some View {
        ToolPage(title: title, subtitle: detail) {
            ToolHero(art: art)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: remaining > 0 ? "sparkles" : "crown.fill").foregroundStyle(remaining > 0 ? TK.blue : TK.orange)
                Text(L(status))
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pro-trial-status")
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(remaining > 0 ? TK.grey50 : TK.orangeSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } actions: {
            if remaining > 0 {
                Button("Try free (\(remaining) left)", action:tryFree).buttonStyle(CTAButtonStyle())
                    .accessibilityIdentifier("pro-try-free")
                Button("Upgrade to Pro", action:upgrade).buttonStyle(SecondaryCTAStyle())
                    .accessibilityIdentifier("pro-upgrade")
                Text("Files you make with a free try are yours to keep.").font(.system(size: 13)).foregroundStyle(TK.grey500)
                    .frame(maxWidth: .infinity)
            } else {
                Button("Upgrade to Pro", action:upgrade).buttonStyle(CTAButtonStyle())
                    .accessibilityIdentifier("pro-upgrade")
                if adUnlocksLeft > 0, ad.ready, let rewarded {
                    Button { ad.show { rewarded() } } label: { Label("Watch a short ad · 1 more use", systemImage: "play.rectangle") }
                        .buttonStyle(SecondaryCTAStyle()).accessibilityIdentifier("pro-rewarded-ad")
                    Text(adUnlocksLeft == 1 ? "1 ad unlock left today" : "\(adUnlocksLeft) ad unlocks left today")
                        .font(.system(size: 13)).foregroundStyle(TK.grey500).frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { if remaining == 0 && adUnlocksLeft > 0 && rewarded != nil { ad.load() } }
    }
    private var status: String {
        if remaining > 0 {
            return remaining == 1
                ? "\(title) is part of Pro. You have 1 free try of \(feature.title) on this iPhone."
                : "\(title) is part of Pro. You have \(remaining) free tries of \(feature.title) on this iPhone."
        }
        let canWatch = ad.ready && adUnlocksLeft > 0 && rewarded != nil
        if feature.limit == 1 {
            return canWatch ? "You've used your free try of \(feature.title). Upgrade to keep using it, or watch a short ad for one more."
                            : "You've used your free try of \(feature.title). Upgrade to keep using it."
        }
        return canWatch ? "You've used your \(feature.limit) free tries of \(feature.title). Upgrade to keep using it, or watch a short ad for one more."
                        : "You've used your \(feature.limit) free tries of \(feature.title). Upgrade to keep using it."
    }
}
struct AdvancedOfflineToolContent:View {
    @EnvironmentObject private var store:LibraryStore
    let tool:AdvancedTool
    var documentID:UUID?
    @State private var photos:[PhotosPickerItem] = []
    @State private var inputs:[UIImage] = []
    @State private var output:[UIImage] = []
    @State private var pageIndex = 0
    @State private var selectedDocument:UUID?
    @State private var current = 0
    private enum WordStep { case source, review, ready }
    @State private var wordStep = WordStep.source
    @State private var wordReviewPage = 0
    @State private var wordCamera = false
    @State private var wordFilePicker = false
    @State private var wordPDF: URL?
    @State private var wordPDFPages = 0
    @State private var wordSourceName = ""
    @State private var text = ""
    /// Reconstructed page layouts behind the review text (Word export keeps their formatting).
    @State private var wordLayouts: [PageLayout] = []
    @State private var wordLayoutText = ""
    /// The review shows plain text instead of tables.
    @State private var wordPlainText = false
    @FocusState private var editingText: Bool
    @State private var translated = ""
    @State private var from = "en"
    @State private var to = "ko"
    @State private var languages:[String] = ["en","ko","ja","zh-Hans","fr","de","es","pt","it","ar"]
    @State private var busy = false
    @State private var cancelling = false
    @State private var phase = "Processing on this iPhone…"
    @State private var message:String?
    @State private var job:Task<Void,Never>?
    @State private var files:ExportedFiles?
    @State private var sharing = false
    @State private var quickLook = false
    @State private var saved = false
    @State private var zoomImage:UIImage?
    @State private var zoom = false
    @State private var strength = 0.7
    @State private var curve = 0.0
    @State private var split = 0.5
    @State private var twoPages = true
    @State private var photoSize = "35 × 45 mm"
    @State private var blue = false
    @State private var selection:CGRect = .zero
    @State private var countPoints:[CGPoint] = []
    @State private var threshold = 0.5
    @State private var minimumArea = 0.002
    @State private var lightObjects = false
    @State private var editableSlides = false
    @State private var allPages = false
    @State private var offsets:[CGPoint] = []
    init(tool:AdvancedTool,documentID:UUID? = nil) {
        self.tool = tool;self.documentID = documentID
        _selectedDocument = State(initialValue:documentID)
    }
    private var doc:ScanDocument? { selectedDocument.flatMap { store.document($0) } }
    private var input:UIImage? { inputs.indices.contains(current) ? inputs[current] : nil }
    private struct Options: Equatable {
        let text, from, to, photoSize: String
        let strength, curve, split, threshold, minimumArea: Double
        let twoPages, blue, lightObjects, editableSlides, allPages: Bool
        let current: Int
        let selection: CGRect
        let offsets: [CGPoint]
    }
    private var options: Options {
        Options(text: text, from: from, to: to, photoSize: photoSize,
                strength: strength, curve: curve, split: split, threshold: threshold, minimumArea: minimumArea,
                twoPages: twoPages, blue: blue, lightObjects: lightObjects, editableSlides: editableSlides,
                allPages: allPages, current: current, selection: selection, offsets: offsets)
    }
    private func finishWork() { busy = false; cancelling = false }
    private func cancelWork() { cancelling = true; phase = "Canceling…"; job?.cancel() }
    private func report(_ error: Error) {
        message = error is CancellationError ? "Canceled. No result was saved." : error.localizedDescription
    }
    var body:some View {
        if tool == .slides || tool == .excel { PowerPointExportView(documentID:documentID,excel:tool == .excel) }
        else if tool == .translate || tool == .math { CameraTextToolView(tool:tool, documentID:documentID) }
        else { standardBody }
    }
    // MARK: Word export: one page per step (DESIGN-SYSTEM.md)

    @State private var wordForward = true
    private var wordStepIndex: Int { wordStep == .source ? 0 : wordStep == .review ? 1 : 2 }
    private var standardBody: some View {
        StepStack(step: wordStepIndex, forward: wordForward) {
            switch wordStep {
            case .source: wordSourcePage
            case .review: wordReviewStepPage
            case .ready: wordReadyPage
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy || wordStep != .source).interactiveDismissDisabled(busy)
        .toolbar {
            if wordStep != .source && !busy {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        editingText = false; wordForward = false
                        if wordStep == .ready { clearOutput(); wordStep = .review }
                        else { message = nil; wordStep = .source }
                    } label: { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)) }
                        .accessibilityLabel("Back").accessibilityIdentifier("word-step-back")
                }
            }
        }
        .overlay { if busy { BusyOverlay(text: phase) { cancelWork() } } }
        .sheet(isPresented: $sharing) { if let files { ShareSheet(items: files.urls) } }
        .fullScreenCover(isPresented: $quickLook) { if let url = files?.urls.first { OfficeQuickLook(url: url) } }
        .fullScreenCover(isPresented: $wordCamera) {
            OfficeScanCamera { result in
                wordCamera = false
                switch result {
                case .success(let images): if !images.isEmpty { acceptWordImages(images, name: "Scanned document") }
                case .failure(let error): report(error)
                }
            }
        }
        .fileImporter(isPresented: $wordFilePicker, allowedContentTypes: [.pdf, .image]) { result in
            switch result {
            case .success(let url): loadWordFile(url)
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { report(error) }
            }
        }
        .fullScreenCover(isPresented: $zoom) { if let image = zoomImage { EnlargedScanPreview(initialImage: image) { image } } }
        .onChange(of: photos) { _, items in loadPhotos(items) }
        .onChange(of: options) { _, _ in clearOutput(clearMessage: false) }
        .onChange(of: allPages) { _, _ in text = "" }
        .onChange(of: text) { _, value in if value.isEmpty { wordLayouts = []; wordLayoutText = "" } }
        .task { if inputs.isEmpty, doc != nil { loadPage() } }
        .onDisappear { if !zoom && !sharing && !quickLook && !wordCamera && !wordFilePicker { job?.cancel(); if let files { ExportFiles.remove(files.directory) }; clearWordPDF() } }
    }

    /// Step 1: the document. Without one, the ways to add it are the page.
    private var wordSourcePage: some View {
        ToolPage(title: "Make a Word file", subtitle: "Scan or import a page. We keep its tables, colours and layout.") {
            if let image = input {
                HStack(alignment: .top, spacing: 14) {
                    Button { zoomImage = image; zoom = true } label: {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: 96, height: 128)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TK.grey200, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview selected document").accessibilityHint("Opens a larger preview with zoom")
                    .accessibilityIdentifier("word-input-preview")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(doc?.title ?? wordSourceName).font(.system(size: 17, weight: .semibold)).foregroundStyle(TK.grey900).lineLimit(2)
                        Text(wordPageCount > 1 ? "\(wordPageCount) pages" : "1 page").font(.system(size: 14)).foregroundStyle(TK.grey600)
                        if wordPageCount > 1 {
                            HStack(spacing: 8) {
                                Button { wordPageSelection.wrappedValue = max(0, wordPageSelection.wrappedValue - 1) } label: { Image(systemName: "chevron.left") }
                                    .buttonStyle(ChipStyle(selected: false)).disabled(wordPageSelection.wrappedValue == 0).accessibilityLabel("Previous page")
                                Text("\(wordPageSelection.wrappedValue + 1) / \(wordPageCount)").font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey700)
                                Button { wordPageSelection.wrappedValue = min(wordPageCount - 1, wordPageSelection.wrappedValue + 1) } label: { Image(systemName: "chevron.right") }
                                    .buttonStyle(ChipStyle(selected: false)).disabled(wordPageSelection.wrappedValue >= wordPageCount - 1).accessibilityLabel("Next page")
                            }.padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14).background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                if wordPageCount > 1 {
                    VStack(spacing: 10) {
                        Button { allPages = true } label: { OptionCard(title: "All \(wordPageCount) pages", detail: "One Word file with every page", selected: allPages) }
                            .buttonStyle(.plain).accessibilityIdentifier("word-all-pages")
                        Button { allPages = false } label: { OptionCard(title: "This page only", detail: "Page \(wordPageSelection.wrappedValue + 1)", selected: !allPages) }
                            .buttonStyle(.plain).accessibilityIdentifier("word-one-page")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Use another document")
                    HStack(spacing: 8) {
                        Button { wordCamera = true } label: { Label("Scan", systemImage: "camera") }.buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("word-camera")
                        PhotosPicker(selection: $photos, maxSelectionCount: 30, selectionBehavior: .ordered, matching: .images) { Label("Photos", systemImage: "photo") }
                            .buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("word-photo")
                        Button { wordFilePicker = true } label: { Label("File", systemImage: "doc") }.buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("word-file")
                    }
                }
            } else {
                ToolHero(art: .word)
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Add your document")
                    Button { wordCamera = true } label: { ChoiceRow(symbol: "camera.fill", title: "Scan pages", detail: "Use the camera now") }
                        .buttonStyle(.plain).accessibilityIdentifier("word-camera")
                    PhotosPicker(selection: $photos, maxSelectionCount: 30, selectionBehavior: .ordered, matching: .images) {
                        ChoiceRow(symbol: "photo.on.rectangle.angled", title: "Choose photos", detail: "Up to 30 pages, in order", tint: TK.teal, soft: TK.tealSoft)
                    }.buttonStyle(.plain).accessibilityIdentifier("word-photo")
                    Button { wordFilePicker = true } label: {
                        ChoiceRow(symbol: "folder.fill", title: "Choose a file", detail: "A PDF or an image", tint: TK.orange, soft: TK.orangeSoft)
                    }.buttonStyle(.plain).accessibilityIdentifier("word-file")
                    if !store.active.isEmpty {
                        Menu {
                            ForEach(store.active) { document in
                                Button(L(document.title)) { clearWordPDF(); allPages = false; selectedDocument = document.id; pageIndex = 0; loadPage() }
                            }
                        } label: {
                            ChoiceRow(symbol: "doc.text.fill", title: "Use a saved scan", detail: "From your documents", tint: TK.purple, soft: TK.purpleSoft)
                        }.buttonStyle(.plain)
                    }
                    Button { message = nil; wordReviewPage = 0; wordForward = true; wordStep = .review } label: {
                        ChoiceRow(symbol: "keyboard", title: "Type or paste text", detail: "No scan needed", tint: TK.grey600, soft: TK.grey100)
                    }.buttonStyle(.plain).accessibilityIdentifier("word-type-text")
                }
            }
            if let message { ToastMessage(text: message).accessibilityIdentifier("offline-status") }
            Label("Processed on this iPhone", systemImage: "lock.shield").font(.system(size: 13)).foregroundStyle(TK.grey500)
        } actions: {
            Button("Extract text") { readText() }.buttonStyle(CTAButtonStyle())
                .disabled(input == nil).accessibilityIdentifier("word-extract")
        }
    }

    /// Step 2: check the text, as tables when the page has them.
    private var wordReviewStepPage: some View {
        let pageTexts = text.components(separatedBy: "\u{000c}")
        return ToolPage(title: "Check your text", subtitle: showsWordLayout ? "Tap a cell to correct it. Tables stay tables in Word." : "Correct anything we misread before making the file.") {
            if pageTexts.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pageTexts.indices, id: \.self) { i in
                            Button("Page \(i + 1)") { editingText = false; wordReviewPage = i }.buttonStyle(ChipStyle(selected: wordReviewPage == i))
                        }
                    }
                }
            }
            if showsWordLayout {
                WordLayoutReview(page: wordLayoutPage(wordReviewPage))
            } else {
                TextEditor(text: wordReviewText).focused($editingText)
                    .font(.system(size: 16)).scrollContentBackground(.hidden)
                    .padding(12).frame(minHeight: 320)
                    .background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("Text for your Word file").accessibilityIdentifier("offline-text")
            }
            if !wordLayouts.isEmpty {
                Button { toggleWordPlainText() } label: { Label(wordPlainText ? "Show as tables" : "Edit as plain text", systemImage: wordPlainText ? "tablecells" : "text.alignleft") }
                    .buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("word-plain-text")
            }
            if let message { ToastMessage(text: message).accessibilityIdentifier("offline-status") }
        } actions: {
            Button("Create Word file") { run() }.buttonStyle(CTAButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("offline-run")
        }
    }

    /// Step 3: the file is ready.
    private var wordReadyPage: some View {
        ToolPage(title: "") {
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(TK.blueSoft).frame(width: 132, height: 132)
                    Circle().fill(TK.blue).frame(width: 84, height: 84)
                    Image(systemName: "checkmark").font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
                }.padding(.top, 24).accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Your Word file is ready").font(.system(size: 24, weight: .bold)).foregroundStyle(TK.grey900)
                    Text(files?.urls.first?.lastPathComponent ?? "Document.docx").font(.system(size: 16)).foregroundStyle(TK.grey600)
                }
            }.frame(maxWidth: .infinity)
        } actions: {
            Button("Preview") { quickLook = true }.buttonStyle(SecondaryCTAStyle()).disabled(files == nil).accessibilityIdentifier("word-preview")
            Button("Share Word file") { sharing = true }.buttonStyle(CTAButtonStyle()).disabled(files == nil).accessibilityIdentifier("word-share")
        }
    }
    private var showsWordLayout: Bool {
        !wordPlainText && wordLayouts.indices.contains(wordReviewPage) && !wordLayouts[wordReviewPage].items.isEmpty
    }
    private func wordLayoutPage(_ index:Int) -> Binding<PageLayout> {
        Binding(get: { wordLayouts.indices.contains(index) ? wordLayouts[index] : wordLayouts[0] }, set: { value in
            guard wordLayouts.indices.contains(index) else { return }
            wordLayouts[index] = value
            // The export maps this text back onto the edited layouts unchanged.
            let updated = LayoutText.text(wordLayouts)
            wordLayoutText = updated; text = updated
        })
    }
    private func toggleWordPlainText() {
        editingText = false
        guard wordPlainText else { wordPlainText = true; return }
        if text == wordLayoutText { wordPlainText = false; return }
        if LayoutText.related(text,wordLayoutText), let pages = LayoutText.apply(text,to:wordLayouts) {
            wordLayouts = pages
            let updated = LayoutText.text(pages)
            wordLayoutText = updated; text = updated; wordPlainText = false; message = nil
        } else {
            message = "The text no longer matches the page layout, so it will be exported as plain text."
        }
    }
    private var wordReviewText: Binding<String> {
        Binding(get: {
            let values = text.components(separatedBy:"\u{000c}")
            return values.indices.contains(wordReviewPage) ? values[wordReviewPage] : ""
        }, set: { value in
            var values = text.components(separatedBy:"\u{000c}")
            if values.indices.contains(wordReviewPage) { values[wordReviewPage] = value.replacingOccurrences(of:"\u{000c}",with:"\n") }
            text = values.joined(separator:"\u{000c}")
        })
    }
    private var wordPageCount: Int { doc?.pages.count ?? (wordPDF != nil ? wordPDFPages : inputs.count) }
    private var wordPageSelection: Binding<Int> {
        Binding(get: { doc != nil || wordPDF != nil ? pageIndex : current }, set: { index in
            text = ""; clearOutput()
            if doc != nil { pageIndex = index; loadPage() }
            else if wordPDF != nil { loadWordPDFPage(index) }
            else { current = index }
        })
    }
    private func clearOutput(clearMessage: Bool = true) { output = [];translated = "";saved = false;if clearMessage { message = nil };if let files { ExportFiles.remove(files.directory) };files = nil }
    private func align() {
        guard current > 0,inputs.indices.contains(current),offsets.count == inputs.count else { return }
        let index = current,reference = inputs[index-1],floating = inputs[index],origin = offsets[index-1]
        busy = true;message = nil;phase = "Processing on this iPhone…"
        job = Task { defer { finishWork() };do {
            let p = try await OfflineWork.perform { try OfflineImageEngine.alignment(reference:reference,floating:floating) }
            try Task.checkCancellation();offsets[index] = CGPoint(x:origin.x+p.x,y:origin.y+p.y)
            message = "Alignment suggested. Preview the shared features and adjust if needed."
        } catch { report(error) } }
    }
    private func loadPhotos(_ items:[PhotosPickerItem]) {
        if tool == .word { wordStep = .source }
        guard !items.isEmpty else { return };busy = true;clearOutput();phase = "Opening photos…"
        job = Task { defer { finishWork() };do {
            var images:[UIImage] = []
            var remainingPixels = 48_000_000
            for (index, item) in items.enumerated() {
                try Task.checkCancellation(); phase = "Opening photo \(index + 1) of \(items.count)…"
                guard let bytes = try await item.loadTransferable(type:Data.self) else { throw ScannerError.message("Photo unavailable.") };let budget = remainingPixels
                let image = try await OfflineWork.perform { try OfflineWork.photo(bytes, remainingPixels: budget) };try Task.checkCancellation();images.append(image)
                remainingPixels -= (image.cgImage?.width ?? 0) * (image.cgImage?.height ?? 0)
            }
            if tool == .word { clearWordPDF(); wordSourceName = "\(images.count) selected photos" }
            selectedDocument = nil;allPages = tool == .word && images.count > 1;text = ""
            inputs = images;current = 0;selection = .zero;countPoints = [];offsets = images.indices.map { CGPoint(x:Double($0)*Double(images[0].size.width)*0.75,y:0) }
        } catch { report(error) } }
    }
    private func clearWordPDF() {
        if let wordPDF { try? FileManager.default.removeItem(at:wordPDF) }
        wordPDF = nil; wordPDFPages = 0
    }
    private func acceptWordImages(_ images:[UIImage], name:String) {
        clearWordPDF(); clearOutput(); selectedDocument = nil
        inputs = images; current = 0; pageIndex = 0; text = ""; allPages = images.count > 1
        wordSourceName = name; wordStep = .source
    }
    private func loadWordFile(_ url:URL) {
        busy = true; message = nil; phase = "Opening document…"
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("word-input-\(UUID().uuidString).pdf")
        job = Task {
            defer { finishWork() }
            do {
                let result = try await OfflineWork.perform { try WordFileInput.open(url, pdfCopy:copy) }
                try Task.checkCancellation()
                acceptWordImages([result.image],name:url.lastPathComponent)
                if result.pdfPages > 0 { wordPDF = copy; wordPDFPages = result.pdfPages; allPages = result.pdfPages > 1 }
            } catch { try? FileManager.default.removeItem(at:copy); report(error) }
        }
    }
    private func loadWordPDFPage(_ index:Int) {
        guard let url = wordPDF else { return }
        busy = true; message = nil; phase = "Opening page…"
        job = Task {
            defer { finishWork() }
            do {
                let image = try await OfflineWork.perform { try WordFileInput.page(url,index:index) }
                try Task.checkCancellation(); inputs = [image]; current = 0; pageIndex = index
            } catch { report(error) }
        }
    }
    private func loadPage() {
        if tool == .word { wordStep = .source }
        inputs = [];text = "";clearOutput()
        guard let doc,doc.pages.indices.contains(pageIndex) else { return }
        busy = true;clearOutput();phase = "Opening page…";let page = doc.pages[pageIndex],root = store.root
        job?.cancel();job = Task { defer { finishWork() };do {
            let image = try await OfflineWork.perform { try Imaging.render(page,root:root) };try Task.checkCancellation()
            inputs = [image];current = 0;countPoints = [];selection = .zero;offsets = [.zero];text = tool == .excel ? OfficeExport.tableText(page.textBlocks) : page.plainText
        } catch { report(error) } }
    }
    private func readText() {
        let pages = allPages ? doc?.pages : nil,root = store.root,source = input,excel = tool == .excel
        let pdfURL = tool == .word ? wordPDF : nil
        let pdfIndices = allPages ? Array(0..<wordPDFPages) : [pageIndex]
        let cameraPages = tool == .word && allPages && doc == nil && wordPDF == nil ? inputs : []
        busy = true;message = nil;phase = "Processing on this iPhone…"
        job = Task { defer { finishWork() };do {
            let word = tool == .word
            let (value, layouts) = try await OfflineWork.perform { () throws -> (String, [PageLayout]) in
                var layouts:[PageLayout] = []
                func read(_ image:UIImage) throws -> String {
                    if word {
                        // Word keeps the page layout: tables, sizes, weights and positions.
                        let layout = try OfficeLayoutPages.analyze(image)
                        layouts.append(layout)
                        return LayoutText.text([layout])
                    }
                    guard let cg = image.cgImage else { throw ScannerError.message("Image unavailable.") }
                    let blocks = try TextRecognition.recognize(cg)
                    return excel ? OfficeExport.tableText(blocks) : blocks.map(\.text).joined(separator:"\n")
                }
                var results:[String] = []
                if let pdfURL {
                    for index in pdfIndices {
                        try Task.checkCancellation()
                        results.append(try autoreleasepool {
                            try word ? read(WordFileInput.page(pdfURL,index:index)) : WordFileInput.text(pdfURL,index:index,recognize:read)
                        })
                    }
                } else if !cameraPages.isEmpty {
                    for image in cameraPages { try Task.checkCancellation(); results.append(try autoreleasepool { try read(image) }) }
                } else if let pages {
                    guard pages.count <= 30 else { throw ScannerError.message("Choose at most 30 pages.") }
                    for (index, page) in pages.enumerated() { try Task.checkCancellation();Task { @MainActor in if busy && !cancelling { phase = "Reading page \(index+1) of \(pages.count)…" } };results.append(try autoreleasepool { try read(Imaging.render(page,root:root)) }) }
                } else if let source { results = [try read(source)] }
                return (results.joined(separator:tool == .slides || tool == .word ? "\u{000c}" : "\n\n"), layouts)
            };try Task.checkCancellation();text = value;wordLayouts = layouts;wordLayoutText = value;message = value.isEmpty ? "No text found. Type or paste the text to continue." : (tool == .word ? nil : "Review the text before exporting.")
            if tool == .word { wordReviewPage = 0; wordPlainText = false; wordForward = true; wordStep = .review }
        } catch { report(error) } }
    }
    private var portraitDimensions:CGSize { photoSize == "35 × 45 mm" ? CGSize(width:35,height:45) : CGSize(width:50.8,height:50.8) }
    private func run() {
        editingText = false
        clearOutput();busy = true;phase = tool.office ? "Creating Office file…" : "Processing image…"
        let source = input,images = inputs,positions = offsets,body = text,layouts = wordLayouts,layoutText = wordLayoutText,amount = strength,rect = selection,curve = curve,split = split,two = twoPages,blue = blue,size = portraitDimensions,threshold = threshold,minimum = minimumArea,light = lightObjects,editable = editableSlides,pages = allPages ? doc?.pages : nil,root = store.root,from = from,to = to
        job = Task { defer { finishWork() };do {
            if tool == .translate {
                guard !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,body.count <= 20000 else { throw ScannerError.message("Enter 1–20,000 characters to translate.") }
                if from == to { translated = body;return }
                guard #available(iOS 26.0,*) else { throw ScannerError.message("Strict offline translation requires iOS 26 or later.") }
                let sourceLanguage = Locale.Language(identifier:from),target = Locale.Language(identifier:to)
                guard await LanguageAvailability().status(from:sourceLanguage,to:target) == .installed else { TranslationLanguageGuide.present(source: from, target: to); return }
                let session = TranslationSession(installedSource:sourceLanguage,target:target)
                let result = try await session.translate(body).targetText;try Task.checkCancellation();translated = result;return
            }
            if tool == .math { translated = try LocalMath.solve(body);return }
            if tool.office {
                let result = try await OfflineWork.perform { () throws -> (String,Data) in
                    if tool == .word {
                        guard !body.isEmpty else { throw ScannerError.message("Read, type or paste text first.") }
                        if !layouts.isEmpty, LayoutText.related(body, layoutText), let pages = LayoutText.apply(body, to: layouts) {
                            return ("Document.docx", try OfficeLayoutExport.word(pages, image: OfficeLayoutPages.missingPicture))
                        }
                        return ("Document.docx",try OfficeExport.word(body))
                    }
                    if tool == .excel { guard !body.isEmpty else { throw ScannerError.message("Read, type or paste cells first.") };return ("Table.xlsx",try OfficeExport.excel(body)) }
                    let pageCount = pages?.count ?? images.count
                    let texts = editable && pages != nil ? body.components(separatedBy:"\u{000c}") : [body]
                    if editable && (texts.count != pageCount || texts.contains(where: { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty })) {
                        throw ScannerError.message("Read text for each page first. Keep the page separators when editing, or export page images.")
                    }
                    let data = try OfficeExport.powerpoint(pageCount: pageCount, texts: texts, editable: editable) { index in
                        try Task.checkCancellation()
                        Task { @MainActor in if busy && !cancelling { phase = "Creating slide \(index+1) of \(pageCount)…" } }
                        if let pages { return try Imaging.render(pages[index],root:root) }
                        return images[index]
                    }
                    return ("Slides.pptx",data)
                };try Task.checkCancellation();files = try ExportFiles.write([result]);Task { @MainActor in ProTrialSession.commit() }
                if tool == .word { wordForward = true; wordStep = .ready; message = nil }
                else { message = "File created on this iPhone. Preview before sharing." }
                // Show the finished file at full size right away, like a scan result.
                quickLook = true
                return
            }
            guard let source else { throw ScannerError.message("Choose a photo or document page first.") }
            if tool == .count {
                countPoints = try await OfflineWork.perform { try OfflineImageEngine.count(source,threshold:threshold,minimumArea:minimum,lightObjects:light) }
                message = "\(countPoints.count) candidates. Tap the input image to correct the markers, then preview the corrected count.";return
            }
            output = try await OfflineWork.perform { () throws -> [UIImage] in
                switch tool {
                case .book:return try OfflineImageEngine.book(source,split:split,curve:curve,twoPages:two)
                case .portrait:return [try OfflineImageEngine.portrait(source,blue:blue,widthMM:size.width,heightMM:size.height)]
                case .erase:return [try OfflineImageEngine.erase(source,rect:rect)]
                case .marks:return [try OfflineImageEngine.removeColoredMarks(source,strength:amount)]
                case .restore:return [try OfflineImageEngine.restored(source,amount:amount)]
                case .mega:return [try OfflineImageEngine.mega(images,offsets:positions)]
                default:throw ScannerError.message("Choose an available tool.")
                }
            };try Task.checkCancellation()
        } catch { report(error) } }
    }
    private func annotatedCount(_ image:UIImage) -> UIImage {
        let f = UIGraphicsImageRendererFormat();f.scale = 1
        return UIGraphicsImageRenderer(size:image.size,format:f).image { _ in
            image.draw(at:.zero)
            for (i,p) in countPoints.enumerated() { let point = CGPoint(x:p.x*image.size.width,y:p.y*image.size.height);("\(i+1)" as NSString).draw(at:point,withAttributes:[.font:UIFont.boldSystemFont(ofSize:max(18,image.size.width/45)),.foregroundColor:UIColor.white,.backgroundColor:UIColor.systemBlue]) }
        }
    }
    private func saveCopy() {
        let images = output,size = tool == .portrait ? portraitDimensions : nil
        let recognize = [.book,.erase,.marks,.mega].contains(tool)
        busy = true;phase = "Preparing PDF…";job = Task { defer { finishWork() };do {
            let result = try await OfflineWork.perform { () throws -> (Data,Bool) in
                var blocks:[[TextBlock]] = [], failed = false
                for (index, image) in images.enumerated() {
                    try Task.checkCancellation()
                    Task { @MainActor in if busy && !cancelling { phase = "Preparing page \(index+1) of \(images.count)…" } }
                    if recognize,let cg = image.cgImage { do { blocks.append(try TextRecognition.recognize(cg)) } catch is CancellationError { throw CancellationError() } catch { blocks.append([]);failed = true } }
                    else { blocks.append([]) }
                }
                return (try OfflineImageEngine.pdf(images,millimeters:size,text:blocks),failed)
            }
            try Task.checkCancellation();_ = try await store.saveGeneratedPDF(result.0,title:tool.rawValue);saved = true;Task { @MainActor in ProTrialSession.commit() }
            message = result.1 ? "Copy saved. Some text could not be recognized; retry from the document's Text tool." : "Copy saved on this iPhone. Original unchanged."
        } catch { report(error) } }
    }
    private func exportImages() {
        let images = output
        busy = true;phase = "Preparing image export…"
        job = Task { defer { finishWork() }; do {
            let entries = try await OfflineWork.perform {
                try images.enumerated().map { index, image -> (String, Data) in
                    try Task.checkCancellation()
                    guard let bytes = image.pngData() else { throw ScannerError.message("Could not encode the result.") }
                    return ("Result-\(index+1).png", bytes)
                }
            }
            try Task.checkCancellation()
            if let files { ExportFiles.remove(files.directory) }
            files = try ExportFiles.write(entries);message = "Image export ready.";Task { @MainActor in ProTrialSession.commit() }
        } catch { report(error) } }
    }

}
/// A temporary input for Word conversion; importing never adds a saved library document.
enum WordFileInput {
    struct Opened {
        let image: UIImage
        let pdfPages: Int
    }
    static func open(_ url:URL, pdfCopy:URL) throws -> Opened {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys:[.fileSizeKey,.contentTypeKey])
        guard let size = values.fileSize, size > 0, size <= 100_000_000 else {
            throw ScannerError.message("Choose a PDF or image smaller than 100 MB.")
        }
        try Task.checkCancellation()
        if values.contentType?.conforms(to:.pdf) == true || url.pathExtension.lowercased() == "pdf" {
            try FileManager.default.copyItem(at:url,to:pdfCopy)
            do {
                let pdf = try document(pdfCopy)
                return Opened(image:try render(pdf,index:0),pdfPages:pdf.pageCount)
            } catch { try? FileManager.default.removeItem(at:pdfCopy); throw error }
        }
        return Opened(image:try OfflineWork.photo(Data(contentsOf:url)),pdfPages:0)
    }
    private static func document(_ url:URL) throws -> PDFDocument {
        guard let pdf = PDFDocument(url:url), !pdf.isLocked else {
            throw ScannerError.message("This PDF couldn't be opened. If it is password-protected, unlock it first.")
        }
        guard (1...30).contains(pdf.pageCount) else { throw ScannerError.message("Choose a PDF with 1–30 pages.") }
        return pdf
    }
    static func page(_ url:URL,index:Int) throws -> UIImage { try render(document(url),index:index) }
    static func text(_ url:URL,index:Int,recognize:(UIImage)throws->String) throws -> String {
        let pdf = try document(url)
        guard let page = pdf.page(at:index) else { throw ScannerError.message("This page is unavailable.") }
        // Keep existing selectable text; only scanned pages need OCR.
        if let text = page.string, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return text }
        return try recognize(render(pdf,index:index))
    }
    private static func render(_ pdf:PDFDocument,index:Int) throws -> UIImage {
        try Task.checkCancellation()
        guard let page = pdf.page(at:index) else { throw ScannerError.message("This page is unavailable.") }
        let bounds = page.bounds(for:.cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw ScannerError.message("This PDF contains an invalid page.")
        }
        let scale = 2400 / max(bounds.width,bounds.height)
        let size = CGSize(width:max(1,bounds.width*scale),height:max(1,bounds.height*scale))
        // PDFKit handles rotated pages and non-zero crop origins.
        let thumbnail = page.thumbnail(of:size,for:.cropBox)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size:thumbnail.size,format:format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin:.zero,size:thumbnail.size))
            thumbnail.draw(at:.zero)
        }
    }
}

/// Camera for the Word, Excel and PowerPoint tools. Uses the app's own scanner:
/// after each shot the page is shown to check its quality, then the user adds
/// another page or finishes and continues with the export. Pages are kept in a
/// temporary draft that is removed once the pictures are handed back.
struct OfficeScanCamera: View {
    @EnvironmentObject private var store: LibraryStore
    var singlePage = false
    var finishTitle = "Continue"
    /// Camera mode it opens in, e.g. the card frame for business cards.
    var style: CaptureStyle = .document
    let completion: (Result<[UIImage],Error>) -> Void
    @State private var draftID: UUID?
    @State private var finished = false
    var body: some View {
        Group {
            if let draftID { CameraView(documentID: draftID, finishTitle: finishTitle, singlePage: singlePage) }
            else { Color.black.ignoresSafeArea() }
        }
        .onAppear {
            guard draftID == nil else { return }
            do {
                let id = try store.createDraft()
                if var doc = store.document(id) { doc.captureStyle = style; try store.update(doc) }
                draftID = id
            } catch { finish(.failure(error)) }
        }
        .onDisappear { collect() }
    }
    private func collect() {
        guard !finished else { return }
        guard let draftID, let doc = store.document(draftID) else { finish(.success([])); return }
        let pages = Array(doc.pages.prefix(30)), root = store.root
        Task { @MainActor in
            do {
                let images = try await OfflineWork.perform { try pages.map { try Imaging.render($0, root: root) } }
                try? store.permanentlyDelete(doc)
                finish(.success(images))
            } catch {
                try? store.permanentlyDelete(doc)
                finish(.failure(error))
            }
        }
    }
    private func finish(_ result: Result<[UIImage],Error>) {
        guard !finished else { return }
        finished = true
        completion(result)
    }
}

struct WordDocumentCamera: UIViewControllerRepresentable {
    let completion: (Result<[UIImage],Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion:completion) }
    func makeUIViewController(context:Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller:VNDocumentCameraViewController,context:Context) {}
    final class Coordinator: NSObject,VNDocumentCameraViewControllerDelegate {
        let completion:(Result<[UIImage],Error>)->Void
        init(completion:@escaping(Result<[UIImage],Error>)->Void) { self.completion = completion }
        func documentCameraViewControllerDidCancel(_ controller:VNDocumentCameraViewController) { completion(.success([])) }
        func documentCameraViewController(_ controller:VNDocumentCameraViewController,didFailWithError error:Error) { completion(.failure(error)) }
        func documentCameraViewController(_ controller:VNDocumentCameraViewController,didFinishWith scan:VNDocumentCameraScan) {
            guard scan.pageCount <= 30 else { completion(.failure(ScannerError.message("Scan up to 30 pages at a time."))); return }
            var images:[UIImage] = [], pixels = 0
            for index in 0..<scan.pageCount {
                let image = scan.imageOfPage(at:index)
                pixels += (image.cgImage?.width ?? Int(image.size.width*image.scale)) * (image.cgImage?.height ?? Int(image.size.height*image.scale))
                guard pixels <= 48_000_000 else {
                    completion(.failure(ScannerError.message("These scans exceed the editing memory limit. Scan fewer pages at a time."))); return
                }
                images.append(Imaging.normalized(image))
            }
            completion(.success(images))
        }
    }
}

struct OfficeQuickLook:UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let url:URL
    func makeCoordinator() -> Coordinator { Coordinator(url:url,close:{ dismiss() }) }
    func makeUIViewController(context:Context) -> UINavigationController {
        let view = QLPreviewController(); view.dataSource = context.coordinator
        let done = UIBarButtonItem(title:"Done",style:.done,target:context.coordinator,action:#selector(Coordinator.close))
        done.accessibilityIdentifier = "office-preview-done"
        // Quick Look adds its own Share button.
        view.navigationItem.rightBarButtonItem = done
        let navigation = UINavigationController(rootViewController:view)
        navigation.modalPresentationStyle = .fullScreen
        return navigation
    }
    func updateUIViewController(_ uiViewController:UINavigationController,context:Context) {}
    class Coordinator:NSObject,QLPreviewControllerDataSource {
        let url:URL;let action:()->Void
        init(url:URL,close:@escaping ()->Void) { self.url = url;self.action = close }
        @objc func close() { action() }
        func numberOfPreviewItems(in controller:QLPreviewController) -> Int { 1 }
        func previewController(_ controller:QLPreviewController,previewItemAt index:Int) -> QLPreviewItem { url as NSURL }
    }
}

/// Camera-first tools. Captures are temporary and never create saved library PDFs.
struct CameraTextToolView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let tool: AdvancedTool
    var documentID: UUID?
    private enum Step { case camera, review, result }
    @State private var step = Step.camera
    @StateObject private var camera = CameraController()
    @State private var visible = false
    @State private var image: UIImage?
    @State private var documentScan: TranslationScan?
    @State private var mathScan: MathScan?
    @State private var photo: PhotosPickerItem?
    @State private var text = ""
    @State private var lines: [String] = []
    @State private var result = ""
    @State private var from = "en"
    @State private var to = "ko"
    @State private var languages = ["en", "ko", "ja", "zh-Hans", "fr", "de", "es"]
    @State private var busy = false
    @State private var phase = "Reading text…"
    @State private var error: String?
    @State private var flash = false
    @State private var importing = false
    @State private var zoom = false
    @State private var job: Task<Void, Never>?
    @FocusState private var editing: Bool
    private var math: Bool { tool == .math }
    private var canRun: Bool { !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !busy }
    var body: some View {
        Group {
            if step == .camera { captureScreen }
            else if math, let mathScan { MathDocumentView(scan:mathScan,onRetake:returnToCamera) }
            else if !math, let documentScan { PhotoTranslationView(scan:documentScan,from:from,to:to,onRetake:returnToCamera) }
            else { reviewScreen }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(step == .camera ? .hidden : .visible, for:.navigationBar)
        .toolbar {
            if step != .camera && math && mathScan == nil {
                ToolbarItem(placement:.topBarLeading) {
                    Button {
                        editing = false; error = nil
                        if step == .result { result = ""; step = .review } else { returnToCamera() }
                    } label: { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)) }
                    .disabled(busy).accessibilityLabel("Back").accessibilityIdentifier("text-tool-back")
                }
                ToolbarItem(placement:.topBarTrailing) { Button("Close") { dismiss() }.disabled(busy) }
            }
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.image,.pdf]) { response in
            switch response {
            case .success(let url): openFile(url)
            case .failure(let failure): if (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }; startCamera()
            }
        }
        .fullScreenCover(isPresented:$zoom) { if let image { EnlargedScanPreview(initialImage:image) { image } } }
        .onChange(of:photo) { _, item in
            guard let item else { return }
            beginWork("Opening photo…")
            job = Task {
                defer { busy = false; photo = nil; startCamera() }
                do {
                    guard let data = try await item.loadTransferable(type:Data.self) else { throw ScannerError.message("This photo couldn't be opened.") }
                    let source = try await OfflineWork.perform { try OfflineWork.photo(data) }
                    try await recognize(source)
                } catch { report(error) }
            }
        }
        .onChange(of:scenePhase) { _, value in if value == .active { startCamera() } else { camera.stop() } }
        .onChange(of:result) { _, value in if !value.isEmpty { ProTrialSession.commit() } }
        .onChange(of:text) { _, _ in result = "" }
        .onChange(of:from) { _, _ in result = ""; error = nil }
        .onChange(of:to) { _, _ in result = ""; error = nil }
        .onAppear { visible = true; startCamera() }
        .onDisappear { visible = false; camera.stop(); if !zoom { job?.cancel() } }
        .task {
            if !math {
                let supported = await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier).sorted()
                if !supported.isEmpty { languages = Array(Set(supported + [from,to])).sorted() }
            }
        }
    }
    /// Full-screen camera (DESIGN-SYSTEM.md, camera tools): close and flash on
    /// top, one hint above the shutter, library left and more options right.
    private var captureScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(controller:camera,tracking:camera.tracking).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: { Image(systemName:"xmark").font(.system(size: 18, weight: .semibold)).frame(width:44,height:44) }
                        .accessibilityLabel("Close camera").accessibilityIdentifier("text-tool-close")
                    Spacer()
                    Text(L(tool.rawValue)).font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 36).background(.black.opacity(0.35), in: Capsule())
                    Spacer()
                    Button { flash.toggle() } label: { Image(systemName:flash ? "bolt.fill" : "bolt.slash").font(.system(size: 18, weight: .semibold)).frame(width:44,height:44) }
                        .accessibilityLabel(flash ? "Turn flash off" : "Turn flash on")
                }.padding(.horizontal, 12)
                Spacer()
                if !simulatedCamera, let problem = camera.problem {
                    VStack(spacing:12) {
                        Text("Camera unavailable").font(.system(size: 17, weight: .semibold))
                        Text(L(problem)).font(.system(size: 15)).multilineTextAlignment(.center)
                        HStack(spacing: 8) {
                            Button("Try again") { startCamera() }.buttonStyle(ChipStyle(selected: false))
                            Button("Settings") { if let url = URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.buttonStyle(ChipStyle(selected: false))
                        }
                    }.padding(20).background(.black.opacity(0.75),in:RoundedRectangle(cornerRadius:20, style: .continuous)).padding(.horizontal, 24)
                    Spacer()
                }
                Text(error ?? (math ? "Point at the math on your page" : "Point at the page to translate"))
                    .font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(error == nil ? Color.black.opacity(0.55) : TK.red, in: Capsule())
                    .accessibilityIdentifier(error == nil ? "text-tool-hint" : "text-tool-error")
                    .padding(.horizontal, 24)
                HStack {
                    PhotosPicker(selection:$photo,matching:.images) { Image(systemName:"photo").font(.system(size: 22, weight: .semibold)).frame(width:56,height:56).background(.black.opacity(0.35), in: Circle()) }
                        .accessibilityLabel("Choose photo").accessibilityIdentifier("text-tool-photo")
                    Spacer()
                    Button(action:capture) {
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width:76,height:76).overlay(Circle().fill(.white).padding(8))
                    }.disabled(!camera.ready && !simulatedCamera)
                        .accessibilityLabel(math ? "Capture expression" : "Capture text").accessibilityIdentifier("text-tool-capture")
                    Spacer()
                    Menu {
                        Button("Choose file",systemImage:"doc") { camera.stop(); importing = true }
                        if math { Button("Type expression",systemImage:"keyboard") {
                            camera.stop(); image = nil; text = ""; lines = []; error = nil; step = .review
                        }.accessibilityIdentifier("text-tool-type") }
                        if let documentID, let document = store.document(documentID), !document.pages.isEmpty {
                            Menu("Use document page") {
                                ForEach(Array(document.pages.enumerated()),id:\.element.id) { index, page in
                                    Button("Page \(index+1)") { openPage(page) }
                                }
                            }
                        }
                    } label: { Image(systemName:"ellipsis").font(.system(size: 22, weight: .semibold)).frame(width:56,height:56).background(.black.opacity(0.35), in: Circle()) }
                        .accessibilityLabel("More input options").accessibilityIdentifier("text-tool-more")
                }.padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 12)
            }
            .foregroundStyle(.white)
            .disabled(busy)
            if busy { BusyOverlay(text: phase, cancel: phase == "Capturing…" ? nil : { job?.cancel() }) }
        }
    }
    /// Typed or recognized expression (math) and the answer, as tool pages.
    private var reviewScreen: some View {
        StepStack(step: step == .result ? 1 : 0, forward: step == .result) {
            if step == .result {
                ToolPage(title: math ? "Your answer" : "Your translation", subtitle: text) {
                    Text(L(result)).font(.system(size: math && !result.contains("\n") ? 40 : 22, weight: .bold)).foregroundStyle(TK.grey900)
                        .textSelection(.enabled).accessibilityIdentifier("text-tool-result")
                    HStack(spacing: 8) {
                        Button { UIPasteboard.general.string = result } label: { Label("Copy", systemImage: "doc.on.doc") }.buttonStyle(ChipStyle(selected: false))
                        ShareLink(item: result) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(ChipStyle(selected: false))
                    }
                } actions: {
                    Button("Scan another") { returnToCamera() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("text-tool-another")
                }
            } else {
                ToolPage(title: math ? "Check your expression" : "Check your text", subtitle: math ? "Arithmetic only: + − × ÷, powers, parentheses and functions like sqrt(81)." : "Correct anything the camera may have missed.") {
                    if let image {
                        Button { zoom = true } label: {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(maxHeight: 200)
                                .padding(10).background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }.buttonStyle(.plain).accessibilityLabel("Enlarge captured image")
                    }
                    if math && lines.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) { ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Button(L(line)) { text = line }.buttonStyle(ChipStyle(selected: text == line)) } }
                        }
                    }
                    TextEditor(text: $text).focused($editing).font(.system(size: 17)).scrollContentBackground(.hidden)
                        .padding(12).frame(minHeight: 150)
                        .background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityIdentifier("offline-text").accessibilityLabel(math ? "Expression" : "Recognized text")
                    if let error {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(TK.red)
                            Text(L(error)).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800).accessibilityIdentifier("text-tool-error")
                            Spacer(minLength: 0)
                        }.padding(16).background(TK.grey100, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                } actions: {
                    Button(math ? "Calculate" : "Translate") { run() }.buttonStyle(CTAButtonStyle()).disabled(!canRun).accessibilityIdentifier("offline-run")
                }
            }
        }
        .overlay { if busy { BusyOverlay(text: phase) { job?.cancel() } } }
    }
    private func startCamera() {
        guard visible,step == .camera,scenePhase == .active,!busy,!importing,!simulatedCamera else { return }
        Task { await camera.start() }
    }
    private func returnToCamera() {
        job?.cancel(); busy = false; editing = false; image = nil; documentScan = nil; mathScan = nil; text = ""; result = ""; lines = []; error = nil
        step = .camera; camera.beginNextPage(); startCamera()
    }
    private func beginWork(_ label:String) { job?.cancel(); camera.stop(); error = nil; busy = true; phase = label }
    private func report(_ failure:Error) { error = failure is CancellationError ? "Canceled. Nothing was saved." : failure.localizedDescription }
    private func capture() {
        guard !busy else { return }
        busy = true; error = nil; phase = "Capturing…"
        if simulatedCamera { read(testImage()); return }
        camera.capture(flash:flash) { response in
            camera.finishSaving()
            switch response {
            case .success(let image): read(image)
            case .failure(let failure): busy = false; report(failure)
            }
        }
    }
    private func read(_ source:UIImage) {
        beginWork("Reading text…")
        job = Task { defer { busy = false; startCamera() }; do { try await recognize(source) } catch { report(error) } }
    }
    private func recognize(_ source:UIImage) async throws {
        if !math {
            phase = "Correcting the scan and finding text…"
            let prepared = try await OfflineWork.perform { try PhotoTranslation.scan(source) }
            try Task.checkCancellation(); documentScan = prepared; step = .review; return
        }
        phase = "Preparing the digital scan…"
        let prepared = try await OfflineWork.perform { try MathDocumentEngine.prepare(source) }
        try Task.checkCancellation(); mathScan = prepared; step = .review

    }
    private func openFile(_ url:URL) {
        beginWork("Opening file…")
        job = Task {
            defer { busy = false; startCamera() }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("text-input-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at:copy) }
            do {
                let opened = try await OfflineWork.perform { try WordFileInput.open(url,pdfCopy:copy) }
                try await recognize(opened.image)
                if opened.pdfPages > 1 {
                    let notice = "Read page 1 of \(opened.pdfPages). This tool processes one page at a time."
                    if !math { documentScan?.notice = notice } else { mathScan?.notice = notice }
                }
            } catch { report(error) }
        }
    }
    private func openPage(_ page:ScanPage) {
        let root = store.root; beginWork("Reading page…")
        job = Task { defer { busy = false; startCamera() }; do {
            let source = try await OfflineWork.perform { try Imaging.render(page,root:root) }
            try await recognize(source)
        } catch { report(error) } }
    }
    private func run() {
        editing = false; beginWork(math ? "Calculating…" : "Translating…")
        let body = text, source = from, target = to
        job = Task { defer { busy = false }; do {
            if math { result = try LocalMath.solve(body) }
            else {
                guard body.count <= 20000 else { throw ScannerError.message("Use up to 20,000 characters at a time.") }
                guard #available(iOS 26.0,*) else { throw ScannerError.message("Offline translation requires iOS 26 or later.") }
                if source == target { result = body }
                else {
                    let a = Locale.Language(identifier:source), b = Locale.Language(identifier:target)
                    guard await LanguageAvailability().status(from:a,to:b) == .installed else {
                        TranslationLanguageGuide.present(source: source, target: target)
                        return
                    }
                    let session = TranslationSession(installedSource:a,target:b)
                    result = try await session.translate(body).targetText
                }
            }
            try Task.checkCancellation(); step = .result
        } catch { result = ""; report(error) } }
    }
    private var simulatedCamera:Bool {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of:"--ui-test-session"),args.indices.contains(i+1),UUID(uuidString:args[i+1]) != nil { return args.contains("--simulate-camera") }
#endif
        return false
    }
    private func testImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size:CGSize(width:1000,height:700),format:format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x:0,y:0,width:1000,height:700))
            ((math ? "12 + 8 * 3\n45 - 9 = 36" : "Welcome to the library") as NSString).draw(at:CGPoint(x:90,y:220),withAttributes:[.font:UIFont.systemFont(ofSize:55),.foregroundColor:UIColor.black])
        }
    }
}


// MARK: - Smart tools (on-device)

enum SmartTool: String, CaseIterable, Identifiable {
    case redact, fillForm, businessCard, autoSave
    var id: String { rawValue }
    var title: String {
        switch self {
        case .redact: return "Hide personal info"
        case .fillForm: return "Fill a form"
        case .businessCard: return "Business card to contact"
        case .autoSave: return "Auto-save to cloud"
        }
    }
    var icon: String {
        switch self {
        case .redact: return "redact"
        case .fillForm: return "fill-form"
        case .businessCard: return "card-contact"
        case .autoSave: return "auto-save"
        }
    }
    var pro: Bool { self == .autoSave || self == .redact || self == .fillForm }
    /// Asking needs Apple Intelligence; the tile is hidden elsewhere.
    var shown: Bool { true }
    @ViewBuilder var destination: some View {
        switch self {
        case .redact:
            ProTrialGate(feature: .redact, title: title, detail: "ID, card and account numbers, phone numbers and emails are found and blacked out in a new copy.", art: .redact) { RedactTool() }
        case .fillForm:
            ProTrialGate(feature: .fillForm, title: title, detail: "Name, email, phone, address and today's date go next to their labels. Add your signature, then save.", art: .fillForm) { FillFormTool() }
        case .businessCard: BusinessCardTool()
        case .autoSave: AutoSaveTool()
        }
    }
}

/// Scan a business card and open a filled-in new contact.
struct BusinessCardTool: View {
    @State private var fields: DocumentInsight.CardFields?
    @State private var card: Data?
    @State private var reading = false
    @State private var problem: String?
    @State private var showContact = false
    var body: some View {
        ToolPage(title: "Business card to contact", subtitle: "Scan a card. Name, company, phone, email and address are filled in for you to check.") {
            ToolHero(art: .cardContact)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Add a card")
                PhotoSourceChoices(allowCamera: false, documentScan: true, scanStyle: .card, picked: { images in
                    guard let image = images.first else { return }
                    read(image)
                }, failed: { problem = $0 }, busy: { reading = $0 })
            }
            if reading { HStack(spacing: 8) { ProgressView(); Text("Reading the card…").foregroundStyle(TK.grey600) } }
            if let problem { ToastMessage(text: problem) }
            Label("Read on this iPhone. Nothing is saved until you tap Done on the contact.", systemImage: "lock.iphone")
                .font(.footnote).foregroundStyle(TK.grey500)
        } actions: { EmptyView() }
        .sheet(isPresented: $showContact) { if let fields { NewContactView(fields: fields, cardImage: card).ignoresSafeArea() } }
    }
    private func read(_ image: UIImage) {
        reading = true; problem = nil
        Task {
            do {
                let blocks = try await OfflineWork.perform { try Imaging.recognize(image) }
                let text = blocks.map(\.text).joined(separator: "\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScannerError.message("No text was found. Try a brighter, sharper photo of the card.") }
                fields = DocumentInsight.cardFields(text: text)
                card = image.preparingThumbnail(of: CGSize(width: 640, height: 640))?.jpegData(compressionQuality: 0.8)
                showContact = true
            } catch { problem = error.localizedDescription }
            reading = false
        }
    }
}

/// Pick a document, then fill its blanks from the saved profile and sign.
struct FillFormTool: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var target: FormTarget?
    @State private var profile = false
    @State private var scanning = false
    private var documents: [ScanDocument] { store.active.filter { $0.pdfFile != nil } }
    var body: some View {
        ToolPage(title: "Fill a form", subtitle: "Name, email, phone, address and today's date go next to their labels. Add your signature, then save.") {
            ToolHero(art: .fillForm)
            Button { profile = true } label: {
                ChoiceRow(symbol: "person.text.rectangle", title: "My info", detail: FormProfile.load().isEmpty ? "Add the answers to fill in" : "\(FormProfile.load().count) answers saved on this iPhone")
            }.buttonStyle(.plain).accessibilityIdentifier("form-profile")
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Choose the form")
                if documents.isEmpty { Text("No saved documents yet. Scan or import the form first.").foregroundStyle(TK.grey500) }
                else { DocumentChoiceList(documents: documents) { target = FormTarget(id: $0.id) } }
            }
        } actions: { EmptyView() }
        .sheet(isPresented: $profile) { FormProfileEditor() }
        .fullScreenCover(item: $target) { AnnotationEditor(documentID: $0.id, autoFill: true, trialUnlocked: ProTrialSession.active == .fillForm) }
    }
    private struct FormTarget: Identifiable { let id: UUID }
}

/// Choose the folder that receives every new scan.
struct AutoSaveTool: View {
    @State private var paywall = false
    var body: some View {
        ToolPage(title: "Auto-save to cloud", subtitle: "Every new scan is also saved as a PDF in a folder you choose — iCloud Drive, Dropbox, Google Drive or this iPhone.") {
            ToolHero(art: .autoSave)
            AutoExportRow(openPaywall: { paywall = true })
                .padding(16).background(TK.grey50, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("You can change or turn this off any time here or in Settings.").font(.footnote).foregroundStyle(TK.grey500)
        } actions: { EmptyView() }
        .sheet(isPresented: $paywall) { PaywallView() }
    }
}
