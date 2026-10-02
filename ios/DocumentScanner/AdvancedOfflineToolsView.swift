import SwiftUI
import PhotosUI
import PDFKit
import Translation
import QuickLook
import VisionKit
import UniformTypeIdentifiers

enum AdvancedTool:String,Identifiable,CaseIterable {
    case word = "Word export", excel = "Excel export", slides = "PowerPoint export", translate = "Photo translation"
    case book = "Book pages", portrait = "ID photo", erase = "Smart erase", marks = "Remove colored marks", restore = "Restore photo"
    case mega = "Mega scan", count = "Count objects", measure = "Measure", mesh = "3D scan", math = "Math scan"
    var id:String { rawValue }
    var office:Bool { [.word,.excel,.slides].contains(self) }
    var textTool:Bool { [.word,.excel,.translate,.math].contains(self) }
    var detail:String {
        switch self {
        case .word:return "Editable text in DOCX. OCR layout is simplified; check the text before exporting."
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query = ""
    @State private var quick: QuickTool?
    @State private var capture: ScanRoute?
    var documentID: UUID? = nil
    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 2 : 4) }
    private func matches(_ title: String) -> Bool { query.isEmpty || title.localizedCaseInsensitiveContains(query) }
    private var hasMatches: Bool {
        (AdvancedTool.allCases.map(\.rawValue) + LibraryTool.allCases.map(\.rawValue) + ["QR code", "Stitch screenshots", "Scan document", "Whiteboard", "ID card"]).contains { matches($0) }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search tools", text: $query).autocorrectionDisabled()
                            .accessibilityIdentifier("tool-search")
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                    }.padding(16).background(.white, in: Capsule())
                    if query.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text("Everyday essentials").font(.headline); Spacer(); ToolArtwork(name: "all-tools", size: 30) }
                            LazyVGrid(columns: columns, spacing: 12) {
                                Button { startScan(.document) } label: { ToolTile(title: "Scan document", icon: "scan") }
                                Button { quick = .qr } label: { ToolTile(title: "QR code", icon: "qr") }.accessibilityLabel("QR code")
                                Button { quick = .stitch } label: { ToolTile(title: "Stitch screenshots", icon: "stitch") }.accessibilityLabel("Stitch screenshots")
                                Button { startScan(.whiteboard) } label: { ToolTile(title: "Whiteboard", icon: "whiteboard") }
                                Button { quick = .library(.identity) } label: { ToolTile(title: "ID scan", icon: "identity") }.accessibilityIdentifier("id-scan-tool")
                            }
                        }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 26))
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            if matches("QR code") { Button { quick = .qr } label: { ToolTile(title: "QR code", icon: "qr") } }
                            if matches("Stitch screenshots") { Button { quick = .stitch } label: { ToolTile(title: "Stitch screenshots", icon: "stitch") } }
                            if matches("Scan document") { Button { startScan(.document) } label: { ToolTile(title: "Scan document", icon: "scan") } }
                            if matches("ID scan") || matches("ID card") { Button { quick = .library(.identity) } label: { ToolTile(title: "ID scan", icon: "identity") }.accessibilityIdentifier("id-scan-tool") }
                            if matches("Whiteboard") { Button { startScan(.whiteboard) } label: { ToolTile(title: "Whiteboard", icon: "whiteboard") } }
                        }
                    }
                    advancedSection("Convert & read", tools: [.word, .excel, .slides, .translate, .math])
                    advancedSection("Edit images", tools: [.book, .portrait, .erase, .marks, .restore, .mega, .count])
                    librarySection("PDF tools", tools: [.ocr, .annotate, .watermark, .timestamp, .merge, .split, .extract, .reorder, .compress, .protect, .images, .longImage, .print])
                    advancedSection("Camera utilities", tools: [.measure, .mesh])
                    if !hasMatches { ContentUnavailableView("No tools found", systemImage: "magnifyingglass", description: Text("Try another tool name.")) }
                    Label("Processed on this iPhone", systemImage: "iphone").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.padding(20)
            }.background(Design.muted)
                .navigationTitle("All tools").navigationBarTitleDisplayMode(.large)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close") } }
                .buttonStyle(.plain)
                .sheet(item: $quick) { QuickToolView(tool: $0, documentID: documentID) }
                .fullScreenCover(item: $capture, onDismiss: { store.perform { try store.discardEmptyDrafts() } }) { ReviewView(documentID: $0.id, captureOnOpen: true) }
                .alert("Something needs attention", isPresented: Binding(get: { store.problem != nil }, set: { if !$0 { store.problem = nil } })) { Button("OK") { store.problem = nil } } message: { Text(store.problem ?? "") }
        }
    }
    @ViewBuilder private func advancedSection(_ title: String, tools: [AdvancedTool]) -> some View {
        let visible = tools.filter { matches($0.rawValue) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.headline)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(visible) { tool in
                        NavigationLink {
                            if tool == .measure || tool == .mesh { SpatialToolsView(mesh: tool == .mesh) }
                            else { AdvancedOfflineToolView(tool: tool, documentID: documentID) }
                        } label: { ToolTile(title: tool.rawValue, icon: tool.icon, pro: tool.pro) }.accessibilityLabel(tool.rawValue)
                    }
                }
            }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 26))
        }
    }
    @ViewBuilder private func librarySection(_ title: String, tools: [LibraryTool]) -> some View {
        let visible = tools.filter { matches($0.rawValue) }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.headline)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(visible) { tool in
                        Button { quick = .library(tool) } label: { ToolTile(title: tool.rawValue, icon: tool.icon, pro: tool.pro) }
                            .accessibilityLabel(tool.rawValue + (tool.pro ? ", Pro" : ""))
                    }
                }
            }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 26))
        }
    }
    private func startScan(_ style: CaptureStyle) {
        guard store.storageAvailable else { return }
        store.perform {
            let id = try store.createDraft()
            if var doc = store.document(id) { doc.captureStyle = style; try store.update(doc) }
            capture = ScanRoute(id: id)
        }
    }
}
/// Entry point for advanced tools. Pro tools show a lock screen with a few
/// free tries before the actual tool opens.
struct AdvancedOfflineToolView:View {
    @EnvironmentObject private var subscription:SubscriptionStore
    let tool:AdvancedTool
    var documentID:UUID?
    @State private var unlocked = false
    @State private var paywall = false
    @State private var trials = ProTrials()
    var body:some View {
        if let feature = tool.proFeature, !subscription.isPro, !unlocked, !trials.bypassed {
            ProToolLockView(tool:tool, feature:feature, remaining:trials.remaining(feature),
                            tryFree:{ if trials.consume(feature) { unlocked = true } },
                            upgrade:{ paywall = true })
                .sheet(isPresented:$paywall) { PaywallView() }
        } else {
            AdvancedOfflineToolContent(tool:tool, documentID:documentID)
        }
    }
}
struct ProToolLockView:View {
    let tool:AdvancedTool
    let feature:ProFeature
    let remaining:Int
    let tryFree:() -> Void
    let upgrade:() -> Void
    var body:some View {
        ScrollView {
            VStack(spacing:18) {
                ToolArtwork(name:tool.icon, size:96).padding(.top, 32)
                Text(tool.rawValue).font(.title2.bold()).foregroundStyle(Design.ink)
                Text("PRO").font(.caption.weight(.bold)).foregroundStyle(Design.blue)
                Text(tool.detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text(remaining > 0
                     ? "\(feature.title) is part of Pro. You have \(remaining) free \(remaining == 1 ? "try" : "tries") left on this iPhone."
                     : "You've used your free tries of \(feature.title.lowercased()). Upgrade to keep using it.")
                    .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(Design.ink)
                    .accessibilityIdentifier("pro-trial-status")
                Button("Upgrade to Pro", action:upgrade).buttonStyle(PrimaryButton())
                    .accessibilityIdentifier("pro-upgrade")
                if remaining > 0 {
                    Button("Try free (\(remaining) left)", action:tryFree).font(.headline)
                        .accessibilityIdentifier("pro-try-free")
                }
            }.padding(24).frame(maxWidth:520).frame(maxWidth:.infinity)
        }.navigationTitle(tool.rawValue).navigationBarTitleDisplayMode(.inline)
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
    private var standardBody:some View {
        ScrollViewReader { proxy in
        toolForm
            .safeAreaInset(edge:.bottom) { bottomActions }
            .navigationTitle(tool.rawValue).navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(busy || (tool == .word && wordStep != .source)).interactiveDismissDisabled(busy)
            .toolbar {
                if tool == .word && wordStep != .source && !busy {
                    ToolbarItem(placement:.topBarLeading) {
                        Button { 
                            editingText = false
                            if wordStep == .ready { clearOutput(); wordStep = .review }
                            else { message = nil; wordStep = .source }
                        } label: { Label("Back",systemImage:"chevron.left") }
                        .accessibilityIdentifier("word-step-back")
                    }
                }
            }
            .sheet(isPresented:$sharing) { if let files { ShareSheet(items:files.urls) } }
            .sheet(isPresented:$quickLook) { if let url = files?.urls.first { OfficeQuickLook(url:url) } }
            .fullScreenCover(isPresented:$wordCamera) {
                WordDocumentCamera { result in
                    wordCamera = false
                    switch result {
                    case .success(let images): if !images.isEmpty { acceptWordImages(images, name: "Scanned document") }
                    case .failure(let error): report(error)
                    }
                }
            }
            .fileImporter(isPresented:$wordFilePicker, allowedContentTypes:[.pdf, .image]) { result in
                switch result {
                case .success(let url): loadWordFile(url)
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { report(error) }
                }
            }
            .fullScreenCover(isPresented:$zoom) { if let image = zoomImage { EnlargedScanPreview(initialImage:image) { image } } }
            .onChange(of:photos) { _,items in loadPhotos(items) }
            .onChange(of:options) { _,_ in clearOutput(clearMessage: false) }
            .onChange(of:allPages) { _,_ in text = "" }
            .onChange(of:countPoints) { _,_ in if tool == .count { clearOutput(clearMessage: false) } }
            .task {
                if inputs.isEmpty,doc != nil { loadPage() }
                if tool == .translate { languages = await LanguageAvailability().supportedLanguages.map { $0.minimalIdentifier }.sorted() }
            }
            .onDisappear { if !zoom && !sharing && !quickLook && !wordCamera && !wordFilePicker { job?.cancel(); if let files { ExportFiles.remove(files.directory) }; clearWordPDF() } }
            .onChange(of: files?.directory) { _, directory in if directory != nil { withAnimation { proxy.scrollTo("prepared-export", anchor: .center) } } }
            .onChange(of: output.count) { _, count in if count > 0 { withAnimation { proxy.scrollTo("processed-output", anchor: .center) } } }
        }
    }
    private var bottomActions: some View {
                VStack(spacing: 12) {
                if busy { HStack { ProgressView(); Text(phase).font(.subheadline); Spacer(); Button("Cancel", action: cancelWork).disabled(cancelling).accessibilityIdentifier("offline-cancel") } }
                if tool == .word {
                    if !busy { wordPrimaryAction }
                } else {
                Button(tool.office ? "Create Office file" : tool == .translate ? "Translate offline" : tool == .math ? "Calculate" : tool == .count ? "Find objects" : "Preview result") { run() }.buttonStyle(PrimaryButton()).disabled(busy || (doc != nil && inputs.isEmpty)).accessibilityIdentifier("offline-run")
                }
                }.padding().background(.regularMaterial)
    }

    private var toolForm: some View {
        Form {
            if tool == .word { wordContent } else {
            Section { Text(tool.detail).font(.subheadline).foregroundStyle(.secondary) }
            inputSection
            if let image = input {
                Section("Input") {
                    imageEditor(image)
                    if inputs.count > 1 { Picker("Image",selection:$current) { ForEach(inputs.indices,id:\.self) { Text("Image \($0+1)").tag($0) } }.onChange(of:current) { _,_ in selection = .zero } }
                }
            }
            controls
            if tool.textTool || (tool == .slides && editableSlides) {
                Section("Review recognized text") {
                    Button("Read text from input") { readText() }.disabled(input == nil && doc == nil)
                    TextEditor(text:$text).focused($editingText).frame(minHeight:180).accessibilityIdentifier("offline-text")
                    if tool == .excel { Button("Insert column separator") { text += "\t" };Text("Use tabs between cells. OCR groups nearby lines; complex tables need correction.").font(.caption) }
                }
            }
            if !translated.isEmpty { Section("Result") { Text(translated).textSelection(.enabled);ShareLink(item:translated) { Label("Share result",systemImage:"square.and.arrow.up") } } }
            if !output.isEmpty {
                Section("Preview") {
                    ForEach(output.indices,id:\.self) { i in Image(uiImage:output[i]).resizable().scaledToFit().frame(maxHeight:300).accessibilityLabel("Processed result \(i+1)").onTapGesture { zoomImage = output[i];zoom = true } }
                    Text("Tap a result to zoom.").font(.caption).foregroundStyle(.secondary)
                    Button("Save PDF copy") { saveCopy() }.disabled(saved).accessibilityIdentifier("offline-save")
                    Button("Prepare image export") { exportImages() }
                }.id("processed-output")
            }
            if let files { Section("Export ready") { Text(files.urls.map(\.lastPathComponent).joined(separator:"\n")).font(.caption);Button("Preview exported file") { quickLook = true };Button("Share export") { sharing = true } }.id("prepared-export") }
            
            }
            if let message { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("offline-status") }
        }.disabled(busy).scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var wordContent: some View {
        Section {
            WordExportIntroCard(
                step: wordStep == .source ? 1 : wordStep == .review ? 2 : 3,
                title: wordStep == .source ? "Choose your document" : wordStep == .review ? "Check your text" : "Your Word file is ready",
                detail: wordStep == .source ? "We'll extract the text first." : wordStep == .review ? "Correct any recognition errors before creating your file." : "Preview it, then save or send a copy."
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        switch wordStep {
        case .source:
            wordSourceSection
            Section {
                Menu {
                    ForEach(store.active) { document in
                        Button(document.title) {
                            clearWordPDF(); allPages = false
                            selectedDocument = document.id; pageIndex = 0; loadPage()
                        }
                    }
                } label: { Label("Choose from saved documents", systemImage:"folder") }
                .disabled(store.active.isEmpty)
                Button("Type or paste text instead") { message = nil; wordReviewPage = 0; wordStep = .review }
                    .accessibilityIdentifier("word-type-text")
            }
        case .review:
            Section {
                if text.components(separatedBy:"\u{000c}").count > 1 {
                    Picker("Page",selection:$wordReviewPage) {
                        ForEach(text.components(separatedBy:"\u{000c}").indices,id:\.self) { Text("Page \($0+1)").tag($0) }
                    }
                }
                TextEditor(text:wordReviewText).focused($editingText).frame(minHeight:300)
                    .accessibilityLabel("Text for your Word file").accessibilityIdentifier("offline-text")
            } footer: {
                Text("Exports editable text with separate document pages. Original fonts, pictures and table layout are not reconstructed.")
            }
        case .ready:
            if let files {
                Section {
                    Label(files.urls.first?.lastPathComponent ?? "Document.docx",systemImage:"doc.text")
                        .font(.headline).padding(.vertical,12)
                    Button("Preview Word file") { quickLook = true }.accessibilityIdentifier("word-preview")
                }.id("prepared-export")
            }
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
    private var wordSourceSection: some View {
        Section {
            VStack(spacing: 16) {
                if let image = input {
                    Button { zoomImage = image; zoom = true } label: {
                        Image(uiImage:image).resizable().scaledToFit()
                            .frame(maxWidth:.infinity).frame(height:260)
                            .padding(12).background(Design.muted, in:RoundedRectangle(cornerRadius:18))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Preview selected document")
                        .accessibilityHint("Opens a larger preview with zoom")
                        .accessibilityIdentifier("word-input-preview")
                    Text(doc?.title ?? wordSourceName).font(.subheadline.weight(.medium))
                        .lineLimit(2).frame(maxWidth:.infinity, alignment:.leading)
                } else {
                    VStack(spacing:12) {
                        ToolArtwork(name:"scan", size:80)
                        Text("Add your document").font(.headline)
                        Text("Scan a page, choose a photo,\nor import a PDF or image.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth:.infinity).padding(.vertical,30)
                        .background(Design.muted, in:RoundedRectangle(cornerRadius:18))
                }
                HStack(alignment:.top, spacing:8) {
                    Button {
                        if VNDocumentCameraViewController.isSupported { wordCamera = true }
                        else { message = "The scanner isn't available on this device. Choose a photo or file instead." }
                    } label: { wordSourceLabel("Take photo", symbol:"camera") }
                        .accessibilityIdentifier("word-camera")
                    PhotosPicker(selection:$photos,maxSelectionCount:30,selectionBehavior:.ordered,matching:.images) {
                        wordSourceLabel("Choose photo", symbol:"photo")
                    }.accessibilityIdentifier("word-photo")
                    Button { wordFilePicker = true } label: { wordSourceLabel("Choose file", symbol:"doc") }
                        .accessibilityIdentifier("word-file")
                }.buttonStyle(.plain)
                if wordPageCount > 1 {
                    Picker("Preview page", selection:wordPageSelection) {
                        ForEach(0..<wordPageCount,id:\.self) { Text("Page \($0+1) of \(wordPageCount)").tag($0) }
                    }
                    Toggle("Extract all pages", isOn:$allPages)
                }
            }.padding(.vertical,8)
        }
    }
    private func wordSourceLabel(_ title:String, symbol:String) -> some View {
        VStack(spacing:8) {
            Image(systemName:symbol).font(.system(size:21,weight:.medium))
                .frame(width:48,height:44).background(Design.softBlue,in:RoundedRectangle(cornerRadius:14))
            Text(title).font(.caption.weight(.medium)).multilineTextAlignment(.center)
                .fixedSize(horizontal:false,vertical:true)
        }.foregroundStyle(Design.blueInk).frame(maxWidth:.infinity).contentShape(Rectangle())
    }
    @ViewBuilder private var wordPrimaryAction: some View {
        switch wordStep {
        case .source:
            Button("Extract text") { readText() }.buttonStyle(PrimaryButton())
                .disabled(input == nil).accessibilityIdentifier("word-extract")
        case .review:
            Button("Create Word file") { run() }.buttonStyle(PrimaryButton())
                .disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("offline-run")
        case .ready:
            Button("Share Word file") { sharing = true }.buttonStyle(PrimaryButton())
                .disabled(files == nil).accessibilityIdentifier("word-share")
        }
    }

    @ViewBuilder private var inputSection:some View {
        Section("Source") {
            PhotosPicker(selection:$photos,maxSelectionCount:tool == .mega ? 8 : 1,selectionBehavior:.ordered,matching:.images) { Label(tool == .mega ? "Choose overlapping photos" : "Choose photo",systemImage:"photo") }
            Picker("Library document",selection:Binding(get: { selectedDocument }, set: { selectedDocument = $0; pageIndex = 0; loadPage() })) { Text("Choose a document").tag(nil as UUID?);ForEach(store.active) { doc in Text(doc.title).tag(doc.id as UUID?) } }
            if let doc {
                Picker("Page",selection:Binding(get: { pageIndex }, set: { pageIndex = $0; loadPage() })) { ForEach(doc.pages.indices,id:\.self) { Text("Page \($0+1)").tag($0) } }
                if tool.office { Toggle("Use all document pages (up to 30)",isOn:$allPages) }
            }
        }
    }
    @ViewBuilder private func imageEditor(_ image:UIImage) -> some View {
        let aspect = image.size.width/image.size.height
        HStack { Spacer(minLength:0);GeometryReader { geo in
            Image(uiImage:image).resizable().scaledToFit()
                .overlay {
                    if tool == .erase && !selection.isEmpty { Rectangle().stroke(.blue,lineWidth:2).background(.blue.opacity(0.1)).frame(width:selection.width*geo.size.width,height:selection.height*geo.size.height).position(x:selection.midX*geo.size.width,y:selection.midY*geo.size.height) }
                    if tool == .count { ForEach(Array(countPoints.enumerated()),id:\.offset) { i,p in Text("\(i+1)").font(.caption2.bold()).foregroundStyle(.white).padding(4).background(.blue,in:Circle()).position(x:p.x*geo.size.width,y:p.y*geo.size.height) } }
                    if tool == .book && twoPages { Rectangle().fill(.blue).frame(width:2).position(x:split*geo.size.width,y:geo.size.height/2) }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onEnded { value in
                    if tool == .erase {
                        let x1 = min(1,max(0,value.startLocation.x/geo.size.width)), y1 = min(1,max(0,value.startLocation.y/geo.size.height)),x2 = min(1,max(0,value.location.x/geo.size.width)),y2 = min(1,max(0,value.location.y/geo.size.height))
                        selection = CGRect(x:min(x1,x2),y:min(y1,y2),width:abs(x1-x2),height:abs(y1-y2))
                    } else if tool == .count {
                        let p = CGPoint(x:min(1,max(0,value.location.x/geo.size.width)),y:min(1,max(0,value.location.y/geo.size.height)))
                        if let i = countPoints.indices.min(by:{ hypot(countPoints[$0].x-p.x,countPoints[$0].y-p.y) < hypot(countPoints[$1].x-p.x,countPoints[$1].y-p.y) }),hypot(countPoints[i].x-p.x,countPoints[i].y-p.y) < 0.04 { countPoints.remove(at:i) }
                        else if countPoints.count < 500 { countPoints.append(p) }
                    }
                },including:tool == .erase || tool == .count ? .all : .subviews)
        }.aspectRatio(aspect,contentMode:.fit).frame(maxWidth:min(320,280*aspect));Spacer(minLength:0) }
    }
    @ViewBuilder private var controls:some View {
        if ![AdvancedTool.word, .excel, .math, .erase].contains(tool) {
        Section("Options") {
            switch tool {
            case .book:
                Toggle("Split into two pages",isOn:$twoPages)
                if twoPages { Text("Gutter: \(Int(split*100))%");Slider(value:$split,in:0.2...0.8) }
                Text("Page curve: \(Int(curve*100))%");Slider(value:$curve,in:-0.2...0.2);Button("Reset curve") { curve = 0 }
            case .portrait:
                Picker("Size",selection:$photoSize) { Text("35 × 45 mm").tag("35 × 45 mm");Text("2 × 2 inches").tag("2 × 2 inches") };Toggle("Blue background",isOn:$blue)
            case .restore,.marks: Text("Strength");Slider(value:$strength,in:0...1)
            case .count:
                Text("\(countPoints.count) objects").font(.headline);Toggle("Light objects on dark background",isOn:$lightObjects);Text("Threshold");Slider(value:$threshold,in:0.05...0.95);Text("Minimum size");Slider(value:$minimumArea,in:0.0001...0.02)
                Button("Preview corrected count") { if let input { output = [annotatedCount(input)];saved = false } }.disabled(input == nil);Button("Clear markers") { countPoints = [] }
            case .mega:
                if offsets.indices.contains(current),current > 0 {
                    Button("Align with previous image") { align() }
                    Stepper("Horizontal: \(Int(offsets[current].x)) px",value:$offsets[current].x,in:-16000...16000,step:1)
                    Slider(value:$offsets[current].x,in:-16000...16000,step:1).accessibilityLabel("Horizontal position")
                    Stepper("Vertical: \(Int(offsets[current].y)) px",value:$offsets[current].y,in:-16000...16000,step:1)
                    Slider(value:$offsets[current].y,in:-16000...16000,step:1).accessibilityLabel("Vertical position")
                };Text("Select Image 2 or later to set its position. Later images cover earlier ones in overlapping areas.").font(.caption)
            case .slides: Toggle("Editable text instead of page images",isOn:$editableSlides)
            case .translate:
                Picker("From",selection:$from) { ForEach(languages,id:\.self) { Text(Locale.current.localizedString(forIdentifier:$0) ?? $0).tag($0) } }
                Picker("To",selection:$to) { ForEach(languages,id:\.self) { Text(Locale.current.localizedString(forIdentifier:$0) ?? $0).tag($0) } }
            default: EmptyView()
            }
        }
    }
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
            let value = try await OfflineWork.perform { () throws -> String in
                func read(_ image:UIImage) throws -> String {
                    guard let cg = image.cgImage else { throw ScannerError.message("Image unavailable.") }
                    let blocks = try TextRecognition.recognize(cg)
                    return excel ? OfficeExport.tableText(blocks) : blocks.map(\.text).joined(separator:"\n")
                }
                var results:[String] = []
                if let pdfURL {
                    for index in pdfIndices {
                        try Task.checkCancellation()
                        results.append(try autoreleasepool {
                            try WordFileInput.text(pdfURL,index:index,recognize:read)
                        })
                    }
                } else if !cameraPages.isEmpty {
                    for image in cameraPages { try Task.checkCancellation(); results.append(try autoreleasepool { try read(image) }) }
                } else if let pages {
                    guard pages.count <= 30 else { throw ScannerError.message("Choose at most 30 pages.") }
                    for (index, page) in pages.enumerated() { try Task.checkCancellation();Task { @MainActor in if busy && !cancelling { phase = "Reading page \(index+1) of \(pages.count)…" } };results.append(try autoreleasepool { try read(Imaging.render(page,root:root)) }) }
                } else if let source { results = [try read(source)] }
                return results.joined(separator:tool == .slides || tool == .word ? "\u{000c}" : "\n\n")
            };try Task.checkCancellation();text = value;message = value.isEmpty ? "No text found. Type or paste the text to continue." : (tool == .word ? nil : "Review the text before exporting.")
            if tool == .word { wordReviewPage = 0; wordStep = .review }
        } catch { report(error) } }
    }
    private var portraitDimensions:CGSize { photoSize == "35 × 45 mm" ? CGSize(width:35,height:45) : CGSize(width:50.8,height:50.8) }
    private func run() {
        editingText = false
        clearOutput();busy = true;phase = tool.office ? "Creating Office file…" : "Processing image…"
        let source = input,images = inputs,positions = offsets,body = text,amount = strength,rect = selection,curve = curve,split = split,two = twoPages,blue = blue,size = portraitDimensions,threshold = threshold,minimum = minimumArea,light = lightObjects,editable = editableSlides,pages = allPages ? doc?.pages : nil,root = store.root,from = from,to = to
        job = Task { defer { finishWork() };do {
            if tool == .translate {
                guard !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,body.count <= 20000 else { throw ScannerError.message("Enter 1–20,000 characters to translate.") }
                if from == to { translated = body;return }
                guard #available(iOS 26.0,*) else { throw ScannerError.message("Strict offline translation requires iOS 26 or later.") }
                let sourceLanguage = Locale.Language(identifier:from),target = Locale.Language(identifier:to)
                guard await LanguageAvailability().status(from:sourceLanguage,to:target) == .installed else { throw ScannerError.message("These languages are not installed. Install them in Apple's Translate app separately, then return here. No download was started.") }
                let session = TranslationSession(installedSource:sourceLanguage,target:target)
                let result = try await session.translate(body).targetText;try Task.checkCancellation();translated = result;return
            }
            if tool == .math { translated = String(try LocalMath.evaluate(body));return }
            if tool.office {
                let result = try await OfflineWork.perform { () throws -> (String,Data) in
                    if tool == .word { guard !body.isEmpty else { throw ScannerError.message("Read, type or paste text first.") };return ("Document.docx",try OfficeExport.word(body)) }
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
                };try Task.checkCancellation();files = try ExportFiles.write([result])
                if tool == .word { wordStep = .ready; message = nil }
                else { message = "File created on this iPhone. Preview before sharing." }
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
            try Task.checkCancellation();_ = try await store.saveGeneratedPDF(result.0,title:tool.rawValue);saved = true
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
            files = try ExportFiles.write(entries);message = "Image export ready."
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

private struct WordExportIntroCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let step: Int
    let title: String
    let detail: String

    private let blue = Color(red: 0.17, green: 0.32, blue: 0.57)
    private let violet = Color(red: 0.40, green: 0.28, blue: 0.56)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(LinearGradient(colors: [blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityHidden(true)
                Text("Step \(step) of 3")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(blue)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    ForEach(1...3, id: \.self) { index in
                        Capsule().fill(index == step ? blue.opacity(0.75) : blue.opacity(0.14))
                            .frame(width: index == step ? 18 : 5, height: 5)
                    }
                }.accessibilityHidden(true)
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(LinearGradient(colors: [blue, violet], startPoint: .leading, endPoint: .trailing))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("word-step-title")
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 0.36, green: 0.39, blue: 0.46))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                artwork
            }
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(OfficeHeaderPalette.word.gradient)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.blue.opacity(0.12), Color.purple.opacity(0.09), Color.cyan.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        }
    }

    private var artwork: some View {
        ZStack {
            Circle().fill(.white.opacity(0.65)).frame(width: 82, height: 82)
            ToolArtwork(name: step == 2 ? "ocr" : "word", size: 94)
                .rotationEffect(.degrees(-7))
            Image(systemName: step == 3 ? "checkmark.circle.fill" : "sparkle")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(step == 3 ? blue : violet.opacity(0.65))
                .background(Circle().fill(.white).padding(-3))
                .offset(x: 32, y: -32)
            Circle().fill(Color(red: 0.92, green: 0.75, blue: 0.64))
                .frame(width: 6, height: 6).offset(x: -37, y: 30)
        }
        .frame(width: 98, height: 104)
        .accessibilityHidden(true)
    }
}

struct OfficeQuickLook:UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let url:URL
    func makeCoordinator() -> Coordinator { Coordinator(url:url,close:{ dismiss() }) }
    func makeUIViewController(context:Context) -> UINavigationController { let view = QLPreviewController();view.dataSource = context.coordinator;view.navigationItem.rightBarButtonItem = UIBarButtonItem(title:"Done",style:.done,target:context.coordinator,action:#selector(Coordinator.close));return UINavigationController(rootViewController:view) }
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
        .navigationTitle(tool.rawValue).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar(step == .camera ? .hidden : .visible, for:.navigationBar)
        .toolbar {
            if step != .camera && math && mathScan == nil {
                ToolbarItem(placement:.topBarLeading) {
                    Button {
                        editing = false; error = nil
                        if step == .result { result = ""; step = .review } else { returnToCamera() }
                    } label: { Label("Back",systemImage:"chevron.left") }
                    .disabled(busy).accessibilityIdentifier("text-tool-back")
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
    private var captureScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(controller:camera,tracking:camera.tracking).ignoresSafeArea()
            VStack(spacing:18) {
                HStack {
                    Button { dismiss() } label: { Image(systemName:"xmark").font(.title3).frame(width:44,height:44) }
                        .accessibilityLabel("Close camera").accessibilityIdentifier("text-tool-close")
                    Spacer(); Text(tool.rawValue).font(.headline); Spacer()
                    Button { flash.toggle() } label: { Image(systemName:flash ? "bolt.fill" : "bolt.slash").frame(width:44,height:44) }
                        .accessibilityLabel(flash ? "Turn flash off" : "Turn flash on")
                }
                if !math { languagePicker.padding(10).background(.black.opacity(0.65),in:Capsule()) }
                Spacer()
                if !simulatedCamera, let problem = camera.problem {
                    VStack(spacing:12) {
                        Text("Camera unavailable").font(.headline)
                        Text(problem).font(.subheadline).multilineTextAlignment(.center)
                        HStack {
                            Button("Try again") { startCamera() }
                            Button("Settings") { if let url = URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                        }
                    }.padding().background(.black.opacity(0.75),in:RoundedRectangle(cornerRadius:20))
                }
                Text(math ? "Point at the math on your page" : "Point at the document to translate")
                    .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text(math ? "Straighten the scan, then review and export the text." : "Scan the page, then replace its text in place.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                if let error { Text(error).font(.footnote).accessibilityIdentifier("text-tool-error") }
                HStack {
                    PhotosPicker(selection:$photo,matching:.images) { Image(systemName:"photo").font(.title2).frame(width:64,height:64) }
                        .accessibilityLabel("Choose photo").accessibilityIdentifier("text-tool-photo")
                    Spacer()
                    Button(action:capture) {
                        Circle().fill(.white).frame(width:76,height:76).overlay(Circle().stroke(.black,lineWidth:3).padding(5))
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
                    } label: { Image(systemName:"ellipsis").font(.title2).frame(width:64,height:64) }
                        .accessibilityLabel("More input options").accessibilityIdentifier("text-tool-more")
                }.padding(.horizontal,22).padding(.bottom,12)
            }.padding(.horizontal,20).foregroundStyle(.white)
                .background(alignment:.bottom) { LinearGradient(colors:[.clear,.black.opacity(0.9)],startPoint:.center,endPoint:.bottom).ignoresSafeArea() }
                .disabled(busy)
            if busy {
                VStack(spacing:18) {
                    ProgressView().tint(.white); Text(phase).foregroundStyle(.white)
                    Button("Cancel") { job?.cancel() }.tint(.white).disabled(phase == "Capturing…")
                }.padding(28).background(.black.opacity(0.9),in:RoundedRectangle(cornerRadius:22))
            }
        }
    }
    private var reviewScreen: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                VStack(alignment:.leading,spacing:8) {
                    Text(step == .result ? "Ready" : "Review").font(.caption.weight(.semibold)).foregroundStyle(Design.blueInk)
                    Text(step == .result ? (math ? "Your answer" : "Your translation") : (math ? "Check your expression" : "Check your text"))
                        .font(.system(size:28,weight:.bold)).foregroundStyle(.primary)
                    Text(step == .result ? "Ready to copy or share." : "Correct anything the camera may have missed.").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(22)
                    .background(OfficeHeaderPalette.word.gradient,in:RoundedRectangle(cornerRadius:24))
                if step == .review {
                    if let image {
                        Button { zoom = true } label: {
                            Image(uiImage:image).resizable().scaledToFit().frame(maxWidth:.infinity).frame(maxHeight:220)
                                .padding(12).background(Design.muted,in:RoundedRectangle(cornerRadius:20))
                        }.buttonStyle(.plain).accessibilityLabel("Enlarge captured image")
                    }
                    if !math { languagePicker.foregroundStyle(Design.blueInk) }
                    if math && lines.count > 1 {
                        Menu("Choose a recognized line") { ForEach(Array(lines.enumerated()),id:\.offset) { _, line in Button(line) { text = line } } }
                    }
                    TextEditor(text:$text).focused($editing).frame(minHeight:150).padding(12)
                        .background(.white,in:RoundedRectangle(cornerRadius:18))
                        .accessibilityIdentifier("offline-text").accessibilityLabel(math ? "Expression" : "Recognized text")
                    Text(math ? "Arithmetic only: + − × ÷, powers, parentheses and functions such as sqrt(81). Trigonometry uses radians. Word problems and algebra equations aren't supported." : "Translation stays on this iPhone. Both languages must already be installed in Apple's Translate app. Requires iOS 26 or later.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text(text).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(result).font(math ? .system(size:40,weight:.bold) : .title3).textSelection(.enabled).accessibilityIdentifier("text-tool-result")
                    HStack(spacing:24) {
                        Button { UIPasteboard.general.string = result } label: { Label("Copy",systemImage:"doc.on.doc") }
                        ShareLink(item:result) { Label("Share",systemImage:"square.and.arrow.up") }
                    }.buttonStyle(.bordered)
                }
            }.padding(20)
        }.background(Design.muted).scrollDismissesKeyboard(.interactively).disabled(busy)
            .safeAreaInset(edge:.bottom) {
                VStack(spacing:12) {
                    if let error { Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("text-tool-error") }
                    if busy { HStack { ProgressView(); Text(phase); Spacer(); Button("Cancel") { job?.cancel() } } }
                    else {
                        Button(step == .result ? "Scan another" : math ? "Calculate" : "Translate") {
                            if step == .result { returnToCamera() } else { run() }
                        }.buttonStyle(PrimaryButton()).disabled(step == .review && !canRun)
                            .accessibilityIdentifier(step == .result ? "text-tool-another" : "offline-run")
                    }
                }.padding().background(.regularMaterial)
            }
    }
    private var languagePicker: some View {
        HStack {
            Picker("From",selection:$from) { ForEach(languages,id:\.self) { Text(Locale.current.localizedString(forIdentifier:$0) ?? $0).tag($0) } }.accessibilityIdentifier("text-tool-from")
            Image(systemName:"arrow.right").accessibilityHidden(true)
            Picker("To",selection:$to) { ForEach(languages,id:\.self) { Text(Locale.current.localizedString(forIdentifier:$0) ?? $0).tag($0) } }.accessibilityIdentifier("text-tool-to")
        }.pickerStyle(.menu).tint(step == .camera ? .white : Design.blueInk).frame(maxWidth:.infinity)
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
            if math { result = String(try LocalMath.evaluate(body)) }
            else {
                guard body.count <= 20000 else { throw ScannerError.message("Use up to 20,000 characters at a time.") }
                guard #available(iOS 26.0,*) else { throw ScannerError.message("Offline translation requires iOS 26 or later.") }
                if source == target { result = body }
                else {
                    let a = Locale.Language(identifier:source), b = Locale.Language(identifier:target)
                    guard await LanguageAvailability().status(from:a,to:b) == .installed else {
                        throw ScannerError.message("Install these languages in Apple's Translate app, then return and try again. No download was started.")
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
