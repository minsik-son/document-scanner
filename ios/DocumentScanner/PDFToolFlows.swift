import SwiftUI
import PDFKit
import UniformTypeIdentifiers

extension LibraryTool {
    var art: ToolArt {
        switch self {
        case .ocr: return .ocr
        case .annotate: return .annotate
        case .watermark: return .watermark
        case .timestamp: return .timestamp
        case .merge: return .merge
        case .split: return .split
        case .extract: return .extract
        case .reorder: return .reorder
        case .compress: return .compress
        case .protect: return .protect
        case .images: return .images
        case .longImage: return .longImage
        case .print: return .print
        case .identity: return .portrait
        }
    }
    var headline: String {
        switch self {
        case .ocr: return "Copy text from a document"
        case .annotate: return "Sign and mark up"
        case .watermark: return "Add a watermark"
        case .timestamp: return "Add a timestamp"
        case .merge: return "Merge documents"
        case .split: return "Split a document"
        case .extract: return "Extract pages"
        case .reorder: return "Change the page order"
        case .compress: return "Make a PDF smaller"
        case .protect: return "Lock with a password"
        case .images: return "Save pages as images"
        case .longImage: return "Make one long image"
        case .print: return "Print pages"
        case .identity: return "ID scan"
        }
    }
    var promise: String {
        switch self {
        case .ocr: return "Read the words on any page, then copy or share them."
        case .annotate: return "Add your signature, text, a pen or highlights."
        case .watermark: return "Stamp text across your pages so copies can't be reused."
        case .timestamp: return "Label pages with a date, time and note."
        case .merge: return "Join files into one PDF in the order you choose."
        case .split: return "Cut one document into separate files."
        case .extract: return "Pick pages and save them as a new document."
        case .reorder: return "Drag pages into the right order."
        case .compress: return "Shrink the file to send it by email or chat."
        case .protect: return "Share a copy that opens only with your password."
        case .images: return "Turn pages into JPG or PNG pictures."
        case .longImage: return "Join pages top to bottom for messaging apps."
        case .print: return "Choose pages and print from this iPhone."
        case .identity: return ""
        }
    }
}

/// Everything the last page of a PDF tool needs to show.
struct PDFToolResult {
    var title: String
    var detail: String
    var files: ExportedFiles?
    var shareTitle = "Share PDF"
}

/// A PDF tool: choose a document, do the one job, see the result.
struct PDFToolFlow: View {
    let tool: LibraryTool
    var documentID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack { PDFToolRoot(tool: tool, preselected: documentID) { dismiss() } }
    }
}

private struct PDFToolRoot: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var subscription: SubscriptionStore
    let tool: LibraryTool
    let preselected: UUID?
    let close: () -> Void
    @StateObject private var work = ToolWork()
    @State private var step = 0
    @State private var forward = true
    @State private var chosen: [UUID] = []
    @State private var paywall = false
    @State private var pending: UUID?
    @State private var importing = false
    @State private var scanning = false
    @State private var annotate: ScanRoute?
    @State private var result: PDFToolResult?
    @State private var started = false
    private var documents: [ScanDocument] { store.active.filter { $0.pdfFile != nil } }
    private var primary: ScanDocument? { chosen.first.flatMap { store.document($0) } }
    var body: some View {
        StepStack(step: step, forward: forward) {
            if step == 0 { landing }
            else if step == 1, let doc = primary { toolStep(doc) }
            else if step == 2, let result { PDFToolDone(result: result, close: close) }
        }
        .stepChrome(step: $step, forward: $forward, last: 2, work: work)
        .toolbar {
            if step == 0 || step == 2 { ToolbarItem(placement: .cancellationAction) { Button("Close", action: close).accessibilityIdentifier("tool-close") } }
        }
        .sheet(isPresented: $paywall, onDismiss: {
            if subscription.isPro, let id = pending { proceed(id) }
            pending = nil
        }) { PaywallView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { response in
            guard case .success(let url) = response else { return }
            work.run("Adding your PDF…") {
                let id = try await store.importNativePDF(url)
                select(id)
            }
        }
        .fullScreenCover(isPresented: $scanning) {
            ToolScanCamera { draft in
                guard let draft else { return }
                work.run("Saving your scan…") { select(try await ToolScanCamera.save(draft, store: store)) }
            }
        }
        .fullScreenCover(item: $annotate) { route in AnnotationEditor(documentID: route.id) }
        .onAppear {
            guard !started else { return }; started = true
            if let id = preselected, store.document(id) != nil { select(id) }
        }
    }
    private var landing: some View {
        ToolPage(title: tool.headline, subtitle: tool.promise) {
            ToolHero(art: tool.art)
            VStack(alignment: .leading, spacing: 4) {
                Button { scanning = true } label: {
                    ChoiceRow(symbol: "camera.fill", title: "Scan with the camera", detail: "Saved as a new PDF, then opened here", tint: TK.blue, soft: TK.blueSoft)
                }.buttonStyle(.plain).accessibilityIdentifier("pdf-scan")
                Button { importing = true } label: {
                    ChoiceRow(symbol: "folder.fill", title: "Choose a PDF from Files", detail: "It's added to your documents", tint: TK.orange, soft: TK.orangeSoft)
                }.buttonStyle(.plain).accessibilityIdentifier("pdf-import")
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: tool == .merge ? "Choose documents in order" : "From your documents")
                if documents.isEmpty {
                    Text("No saved documents yet. Scan or import one first.").font(.system(size: 15)).foregroundStyle(TK.grey500).padding(.vertical, 12)
                } else {
                    DocumentChoiceList(documents: documents, selected: chosen, multiple: tool == .merge,
                                       disabled: { tool == .split && $0.pages.count < 2 }) { select($0.id) }
                }
            }
            if let message = work.message { ToastMessage(text: message) }
            if tool.pro && !subscription.isPro {
                Label("Part of Pro", systemImage: "crown.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(TK.orange)
            }
        } actions: {
            if tool == .merge {
                Button(chosen.count < 2 ? "Choose 2 or more" : "Next · \(chosen.count) documents") { forward = true; step = 1 }
                    .buttonStyle(CTAButtonStyle()).disabled(chosen.count < 2).accessibilityIdentifier("merge-next")
                if !subscription.isPro { Text("Free: merge 2 documents. Pro: any number.").font(.system(size: 13)).foregroundStyle(TK.grey500).accessibilityIdentifier("merge-free-limit") }
            }
        }
    }
    private func select(_ id: UUID) {
        if tool == .merge {
            if let i = chosen.firstIndex(of: id) { chosen.remove(at: i); return }
            if !subscription.isPro && chosen.count >= DocumentTool.freeMergeDocuments + 1 { pending = nil; paywall = true; return }
            chosen.append(id); return
        }
        if tool.pro && !subscription.isPro { pending = id; paywall = true; return }
        proceed(id)
    }
    private func proceed(_ id: UUID) {
        if tool == .merge { if !chosen.contains(id) { chosen.append(id) }; return }
        chosen = [id]
        if tool == .annotate { annotate = ScanRoute(id: id); return }
        forward = true; step = 1
    }
    private func finish(_ value: PDFToolResult) { result = value; forward = true; step = 2 }
    @ViewBuilder private func toolStep(_ doc: ScanDocument) -> some View {
        switch tool {
        case .ocr: OCRToolStep(document: doc, work: work)
        case .watermark: WatermarkToolStep(document: doc, work: work, finish: finish)
        case .timestamp: TimestampToolStep(document: doc, work: work, finish: finish)
        case .merge: MergeToolStep(order: $chosen, work: work, finish: finish) { forward = false; step = 0 }
        case .split: SplitToolStep(document: doc, work: work, finish: finish)
        case .extract: ExtractToolStep(document: doc, work: work, finish: finish)
        case .reorder: ReorderToolStep(document: doc, work: work, finish: finish)
        case .compress: CompressToolStep(document: doc, work: work, finish: finish)
        case .protect: ProtectToolStep(document: doc, work: work, finish: finish)
        case .images: ExportImagesToolStep(document: doc, work: work, finish: finish)
        case .longImage: LongImageToolStep(document: doc, work: work, finish: finish)
        case .print: PrintToolStep(document: doc, work: work)
        case .annotate, .identity: EmptyView()
        }
    }
}

/// Camera for PDF tools: scan one or more pages, then they become a saved PDF
/// document the tool opens. Returns nil when nothing was captured.
private struct ToolScanCamera: View {
    @EnvironmentObject private var store: LibraryStore
    let completion: (UUID?) -> Void
    @State private var draftID: UUID?
    @State private var finished = false
    var body: some View {
        Group {
            if let draftID { CameraView(documentID: draftID, finishTitle: "Use this scan") }
            else { Color.black.ignoresSafeArea() }
        }
        .onAppear {
            guard draftID == nil else { return }
            do {
                let id = try store.createDraft()
                if var doc = store.document(id) { doc.captureStyle = .document; try store.update(doc) }
                draftID = id
            } catch { done(nil) }
        }
        .onDisappear {
            guard let draftID, let doc = store.document(draftID), !doc.pages.isEmpty else { done(nil); return }
            done(draftID)
        }
    }
    private func done(_ id: UUID?) { guard !finished else { return }; finished = true; completion(id) }
    @MainActor static func save(_ id: UUID, store: LibraryStore) async throws -> UUID {
        guard var doc = store.document(id), !doc.pages.isEmpty else { throw ScannerError.message("This scan is no longer available.") }
        if doc.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { doc.title = "Scan \(Date().formatted(date: .abbreviated, time: .shortened))" }
        let result = try await PDFExport.prepare(doc, root: store.root)
        try store.savePDF(result.data, document: result.document)
        return id
    }
}

private struct PDFToolDone: View {
    let result: PDFToolResult
    let close: () -> Void
    @State private var sharing: ExportedFiles?
    @State private var preview: UIImage?
    private var imageURLs: [URL] {
        guard let urls = result.files?.urls, !urls.isEmpty else { return [] }
        return urls.allSatisfy { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) } ? urls : []
    }
    var body: some View {
        ToolDonePage(title: result.title, detail: result.detail,
                     primaryTitle: imageURLs.isEmpty ? "Done" : "Save to Photos",
                     primary: imageURLs.isEmpty ? close : {
                         for url in imageURLs { if let image = UIImage(contentsOfFile: url.path) { UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil) } }
                         close()
                     },
                     secondaryTitle: result.files == nil ? nil : result.shareTitle,
                     secondary: result.files == nil ? nil : { sharing = result.files }) {
            if let preview {
                let aspect = preview.size.width / max(1, preview.size.height)
                let height = min(230, 300 / max(0.1, aspect))
                Image(uiImage: preview).resizable().frame(width: height * aspect, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TK.grey200, lineWidth: 1))
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 4).padding(.top, 4)
                    .transition(.opacity)
            }
        }
            .task {
                guard let url = result.files?.urls.first else { return }
                let image: UIImage? = await Task.detached {
                    if url.pathExtension.lowercased() == "pdf" {
                        return PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 600, height: 600), for: .mediaBox)
                    }
                    return UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 600, height: 600))
                }.value
                withAnimation(.easeOut(duration: 0.25)) { preview = image }
            }
            .sheet(item: $sharing) { files in ShareSheet(items: files.urls) }
            .onDisappear { if let files = result.files { ExportFiles.remove(files.directory) } }
    }
}

/// Saving helpers shared by the PDF tools.
@MainActor enum PDFTools {
    /// "Report (watermark) (merged)" → "Report (merged)": one tool suffix at a time.
    nonisolated static func named(_ title: String, _ suffix: String) -> String {
        var base = title
        let known = try? NSRegularExpression(pattern: #"\s\((watermark|timestamp|merged|part \d+|extracted|compressed|locked)\)$"#)
        while let known, let match = known.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)), let range = Range(match.range, in: base) {
            base.removeSubrange(range)
        }
        return base + " (" + suffix + ")"
    }
    static func data(_ doc: ScanDocument, store: LibraryStore) throws -> Data {
        guard let file = doc.pdfFile else { throw ScannerError.message("Save this document as a PDF first.") }
        return try Data(contentsOf: store.url(file))
    }
    /// New documents made from pages of existing ones; originals are unchanged.
    static func saveCopies(_ copies: [ScanDocument], store: LibraryStore) async throws -> [(ScanDocument, Data)] {
        let root = store.root
        var ready: [(ScanDocument, Data)] = []
        for var copy in copies {
            try Task.checkCancellation()
            copy.searchable = copy.pages.contains { !$0.textBlocks.isEmpty }
            let snapshot = copy
            let bytes = try await OfflineWork.perform { try DocumentPDF.compose(snapshot, root: root) }
            ready.append((copy, bytes))
        }
        try store.saveCopies(ready)
        return ready
    }
    static func share(_ items: [(String, Data)]) -> ExportedFiles? { try? ExportFiles.write(items) }
    static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

// MARK: - Extract text

private struct OCRToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var subscription: SubscriptionStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    @State private var page = 0
    @State private var copied = false
    @State private var correcting = false
    @State private var share: ExportedFiles?
    @State private var paywall = false
    private var current: ScanDocument { store.document(document.id) ?? document }
    private var text: String { current.pages.indices.contains(page) ? current.pages[page].plainText : "" }
    private var read: Bool { current.pages.indices.contains(page) && current.pages[page].ocrComplete }
    var body: some View {
        ToolPage(title: current.pages.count > 1 ? "Text on page \(page + 1)" : "Text on this page", subtitle: "Select any part, or copy it all.") {
            if current.pages.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(current.pages.indices, id: \.self) { i in
                            Button { page = i; copied = false } label: {
                                PDFPageThumb(document: current, index: i).frame(width: 54, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(i == page ? TK.blue : TK.grey200, lineWidth: i == page ? 2.5 : 1))
                            }.accessibilityLabel("Page \(i + 1)").accessibilityAddTraits(i == page ? .isSelected : [])
                        }
                    }.padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                if !read { HStack(spacing: 10) { ProgressView(); Text("Reading…").foregroundStyle(TK.grey600) }.frame(maxWidth: .infinity, minHeight: 160) }
                else if text.isEmpty { Text("No text was found on this page. A sharper, brighter scan helps.").foregroundStyle(TK.grey600).frame(maxWidth: .infinity, minHeight: 120) }
                else {
                    Text(text).font(.system(size: 16)).foregroundStyle(TK.grey900).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("ocr-text")
                }
            }
            .padding(18).background(TK.grey50, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(TK.grey200))
            if read && !text.isEmpty {
                Button { correcting = true } label: { Label("Fix recognition mistakes", systemImage: "pencil") }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.blue)
            }
            if let message = work.message { ToastMessage(text: message) }
        } actions: {
            if current.pages.count > 1 {
                Button { shareAll() } label: { HStack(spacing: 6) { Text("Share all pages as text"); if !subscription.isPro { Image(systemName: "crown.fill").foregroundStyle(TK.orange) } } }
                    .buttonStyle(SecondaryCTAStyle()).disabled(work.busy != nil)
            }
            Button(copied ? "Copied" : "Copy text") { UIPasteboard.general.string = text; withAnimation { copied = true } }
                .buttonStyle(CTAButtonStyle()).disabled(!read || text.isEmpty).accessibilityIdentifier("ocr-copy")
        }
        .task(id: page) { recognize(page) }
        .sheet(isPresented: $correcting) { OCRTextEditor(documentID: document.id, pageIndex: page) }
        .sheet(item: $share) { files in ShareSheet(items: files.urls) { _, _ in ExportFiles.remove(files.directory) } }
        .sheet(isPresented: $paywall) { PaywallView() }
    }
    private func recognize(_ index: Int) {
        guard current.pages.indices.contains(index), !current.pages[index].ocrComplete else { return }
        let page = current.pages[index], root = store.root
        work.run("Reading page \(index + 1)…") {
            let blocks = try await OfflineWork.perform { try Imaging.recognize(Imaging.render(page, root: root)) }
            guard var updated = store.document(document.id), let i = updated.pages.firstIndex(where: { $0.id == page.id }) else { return }
            updated.pages[i].textBlocks = blocks; updated.pages[i].ocrComplete = true
            updated.pages[i].ocrProcessingVersion = PDFExport.textProcessingVersion
            let prepared = try await PDFExport.prepare(updated, root: root)
            try store.savePDF(prepared.data, document: prepared.document)
        }
    }
    private func shareAll() {
        guard subscription.isPro else { paywall = true; return }
        let root = store.root, doc = current
        work.run("Reading every page…") {
            let prepared = try await PDFExport.prepare(doc, root: root) { label in work.busy = label }
            try store.savePDF(prepared.data, document: prepared.document)
            share = try ExportFiles.write([(doc.title + ".txt", Data(prepared.document.text.utf8))])
        }
    }
}

// MARK: - Watermark

private struct WatermarkToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    @State private var stamp: DocumentStamp = {
        var s = DocumentStamp(); s.text = "CONFIDENTIAL"; s.opacity = 0.22; s.width = 0.55; s.angle = -30; s.repeated = true; s.color = 0x4E5968; return s
    }()
    @State private var preview: UIImage?
    private let colors: [UInt32] = [0x4E5968, 0x191F28, 0xF04452, 0x3182F6, 0x18B99A, 0xFF8A3D, 0x7B61FF]
    var body: some View {
        ToolPage(title: "Add a watermark", subtitle: "It's added to every page of a new copy.") {
            PreviewStage(image: preview)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Text")
                TextField("Watermark text", text: $stamp.text).font(.system(size: 20, weight: .semibold)).foregroundStyle(TK.grey900)
                    .padding(.vertical, 10).overlay(alignment: .bottom) { Rectangle().fill(TK.blue).frame(height: 2) }
                    .submitLabel(.done).accessibilityIdentifier("watermark-text")
            }
            HStack(spacing: 12) {
                ForEach(colors, id: \.self) { hex in
                    Button { stamp.color = hex } label: {
                        Circle().fill(Color(hex: hex)).frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(stamp.color == hex ? TK.blue : .clear, lineWidth: 3).padding(-5))
                    }.accessibilityLabel("Color \(String(format: "%06X", hex))")
                }
            }.frame(maxWidth: .infinity)
            ToolSlider(title: "Size", value: $stamp.width, range: 0.15...0.8)
            ToolSlider(title: "Opacity", value: $stamp.opacity, range: 0.05...0.8)
            HStack(spacing: 8) {
                Button("Diagonal") { stamp.angle = -30 }.buttonStyle(ChipStyle(selected: stamp.angle == -30))
                Button("Straight") { stamp.angle = 0 }.buttonStyle(ChipStyle(selected: stamp.angle == 0))
                Button("Steep") { stamp.angle = -50 }.buttonStyle(ChipStyle(selected: stamp.angle == -50))
            }
            Toggle(isOn: $stamp.repeated) { Text("Repeat across the page").font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey800) }.tint(TK.blue)
            if let message = work.message { ToastMessage(text: message) }
        } actions: {
            Button("Add to \(document.pages.count) \(document.pages.count == 1 ? "page" : "pages")") { apply() }
                .buttonStyle(CTAButtonStyle()).disabled(!stamp.valid).accessibilityIdentifier("watermark-apply")
        }
        .task(id: stampKey) { await render() }
    }
    private var stampKey: String { "\(stamp.text)|\(stamp.color)|\(stamp.width)|\(stamp.opacity)|\(stamp.angle)|\(stamp.repeated)" }
    /// Runs in the view's own task: a newer key cancels it, and nothing else
    /// sharing `work` can cancel it and leave the spinner up.
    private func render() async {
        guard stamp.valid else { return }
        let s = stamp
        preview = await PreviewStage.render(document, store: store, work: work) { size, ctx in LocalDocumentTools.drawStamp(s, size: size, context: ctx) } ?? preview
    }
    private func apply() {
        let s = stamp, doc = document
        work.run("Adding the watermark…") {
            let source = try PDFTools.data(doc, store: store)
            let output = try await OfflineWork.perform { try LocalDocumentTools.stamped(source, indices: Array(0..<doc.pages.count), stamp: s) }
            _ = try await store.saveGeneratedPDF(output, title: PDFTools.named(doc.title, "watermark") + "", folder: doc.folder)
            finish(PDFToolResult(title: "Watermark added", detail: "Saved as a new document. The original is unchanged.",
                                 files: PDFTools.share([(PDFTools.named(doc.title, "watermark") + ".pdf", output)])))
        }
    }
}

/// Live page preview with a soft stage.
private struct PreviewStage: View {
    let image: UIImage?
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit().shadow(color: .black.opacity(0.12), radius: 8, y: 3) }
            else { ProgressView() }
        }
        .frame(maxWidth: .infinity).frame(height: 300).padding(14)
        .background(TK.grey100, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("tool-preview")
    }
    /// Renders the first page with an overlay after a short debounce. Returns nil
    /// only when cancelled; a failure shows its message and a placeholder, so the
    /// stage never spins forever.
    @MainActor static func render(_ doc: ScanDocument, store: LibraryStore, work: ToolWork,
                                  draw: @escaping @Sendable (CGSize, CGContext) -> Void) async -> UIImage? {
        do {
            try await Task.sleep(nanoseconds: 120_000_000)
            guard let file = doc.pdfFile else { throw ScannerError.message("Save this document as a PDF first.") }
            let url = store.url(file)
            let image = try await OfflineWork.perform {
                guard let page = PDFDocument(url: url)?.page(at: 0) else { throw ScannerError.message("This PDF can't be opened.") }
                return try LocalDocumentTools.renderPreview(page, draw: draw)
            }
            if work.message != nil && work.busy == nil { work.message = nil }
            return image
        } catch is CancellationError {
            return nil
        } catch {
            work.message = error.localizedDescription
            return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { c in
                UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
                ("Preview unavailable" as NSString).draw(at: CGPoint(x: 72, y: 190), withAttributes: [.font: UIFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: UIColor.gray])
            }
        }
    }
}

// MARK: - Timestamp

private struct TimestampToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    @State private var stamp = TimestampStamp()
    @State private var detailsShown = false
    @State private var preview: UIImage?
    var body: some View {
        Group {
            if detailsShown { detailsPage.transition(.move(edge: .trailing).combined(with: .opacity)) }
            else { stylePage.transition(.move(edge: .leading).combined(with: .opacity)) }
        }
        .animation(.snappy(duration: 0.3), value: detailsShown)
        .onAppear { stamp.date = document.createdAt }
        .task(id: key) { await render() }
    }
    private var stylePage: some View {
        ToolPage(title: "Pick a timestamp style", subtitle: "A label with the date you choose. It isn't a certified capture time.") {
            PreviewStage(image: preview)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(TimestampTemplate.allCases) { template in
                    Button { stamp.template = template } label: { TemplateTile(template: template, selected: stamp.template == template) }
                        .buttonStyle(.plain).accessibilityIdentifier("timestamp-" + template.rawValue)
                }
            }
        } actions: {
            Button("Next") { detailsShown = true }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("timestamp-next")
        }
    }
    private var detailsPage: some View {
        ToolPage(title: "Check the details", subtitle: "Set the date and an optional note.") {
            PreviewStage(image: preview)
            DatePicker("Date and time", selection: $stamp.date).font(.system(size: 16, weight: .semibold)).tint(TK.blue)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: stamp.template == .clockIn ? "Label" : "Note (place, name or project)")
                TextField(stamp.template == .clockIn ? "Clock-in" : "Optional", text: $stamp.note).font(.system(size: 18, weight: .semibold))
                    .padding(.vertical, 10).overlay(alignment: .bottom) { Rectangle().fill(TK.grey300).frame(height: 1) }
                    .accessibilityIdentifier("timestamp-note")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { ForEach(StampCorner.allCases) { c in Button(c.rawValue) { stamp.corner = c }.buttonStyle(ChipStyle(selected: stamp.corner == c)) } }
            }
            ToolSlider(title: "Size", value: Binding(get: { Double(stamp.scale) }, set: { stamp.scale = CGFloat($0) }), range: 0.6...2) { "\(Int($0 * 100))%" }
            if stamp.template == .dateTime {
                Toggle(isOn: $stamp.white) { Text("Dark label (white text)").font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey800) }.tint(TK.blue)
            }
        } actions: {
            Button("Change style") { detailsShown = false }.buttonStyle(SecondaryCTAStyle()).accessibilityIdentifier("timestamp-style")
            Button("Add to \(document.pages.count) \(document.pages.count == 1 ? "page" : "pages")") { apply() }
                .buttonStyle(CTAButtonStyle()).accessibilityIdentifier("timestamp-apply")
        }
    }
    private var key: String { "\(stamp.template.rawValue)|\(stamp.date.timeIntervalSince1970)|\(stamp.note)|\(stamp.corner.rawValue)|\(stamp.scale)|\(stamp.white)" }
    private func render() async {
        let s = stamp
        preview = await PreviewStage.render(document, store: store, work: work) { size, ctx in LocalDocumentTools.drawTimestamp(s, size: size, context: ctx) } ?? preview
    }
    private func apply() {
        let s = stamp, doc = document
        work.run("Adding the timestamp…") {
            let source = try PDFTools.data(doc, store: store)
            let output = try await OfflineWork.perform { try LocalDocumentTools.timestamped(source, indices: Array(0..<doc.pages.count), stamp: s) }
            _ = try await store.saveGeneratedPDF(output, title: PDFTools.named(doc.title, "timestamp") + "", folder: doc.folder)
            finish(PDFToolResult(title: "Timestamp added", detail: "Saved as a new document. The original is unchanged.",
                                 files: PDFTools.share([(PDFTools.named(doc.title, "timestamp") + ".pdf", output)])))
        }
    }
}
private struct TemplateTile: View {
    let template: TimestampTemplate
    let selected: Bool
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(TK.grey800)
                switch template {
                case .dateTime:
                    VStack(alignment: .leading, spacing: 1) {
                        Text("10:00").font(.system(size: 22, weight: .bold)); Text("Fri · Oct 2").font(.system(size: 9, weight: .semibold))
                    }.foregroundStyle(.white)
                case .onSite:
                    VStack(spacing: 0) {
                        Text("On-site").font(.system(size: 10, weight: .bold)).foregroundStyle(.white).frame(maxWidth: .infinity).padding(3).background(TK.blue)
                        Text("Time 10:00").font(.system(size: 9, weight: .medium)).foregroundStyle(TK.grey800).frame(maxWidth: .infinity).padding(3).background(.white)
                    }.clipShape(RoundedRectangle(cornerRadius: 4)).padding(.horizontal, 16)
                case .clockIn:
                    VStack(spacing: 0) {
                        Text("Clock-in").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).frame(maxWidth: .infinity).padding(2).background(TK.teal)
                        Text("10:00").font(.system(size: 16, weight: .bold)).foregroundStyle(TK.grey900).frame(maxWidth: .infinity).background(.white)
                    }.clipShape(RoundedRectangle(cornerRadius: 4)).padding(.horizontal, 22)
                case .digital:
                    Text("08:25:55").font(.system(size: 16, weight: .heavy, design: .monospaced)).foregroundStyle(TK.grey900)
                        .padding(.horizontal, 8).padding(.vertical, 4).background(Color(hex: 0xD9DDE2), in: RoundedRectangle(cornerRadius: 5))
                }
            }.frame(height: 76)
            Text(template.rawValue).font(.system(size: 14, weight: .semibold)).foregroundStyle(selected ? TK.blue : TK.grey700)
        }
        .padding(8).background(selected ? TK.blueSoft : TK.grey50, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? TK.blue : TK.grey200, lineWidth: selected ? 2 : 1))
        .accessibilityElement(children: .combine).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Merge

private struct MergeToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var order: [UUID]
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    let addMore: () -> Void
    private var docs: [ScanDocument] { order.compactMap { store.document($0) } }
    var body: some View {
        ToolPage(title: "Set the order", subtitle: "Drag the handles. Your originals are kept.", scrolls: false) {
            List {
                ForEach(docs) { doc in
                    HStack(spacing: 14) {
                        Text("\((order.firstIndex(of: doc.id) ?? 0) + 1)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(TK.blue, in: Circle())
                        PDFPageThumb(document: doc, index: 0).frame(width: 46, height: 60).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(doc.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900).lineLimit(2)
                            Text("\(doc.pages.count) pages").font(.system(size: 13)).foregroundStyle(TK.grey500)
                        }
                    }.listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { order.remove(atOffsets: $0) }
            }
            .listStyle(.plain).environment(\.editMode, .constant(.active)).scrollContentBackground(.hidden)
            .accessibilityIdentifier("merge-order")
            Text("\(docs.reduce(0) { $0 + $1.pages.count }) pages in total").font(.system(size: 14, weight: .medium)).foregroundStyle(TK.grey500)
        } actions: {
            Button("Add more", action: addMore).buttonStyle(SecondaryCTAStyle())
            Button("Merge \(docs.count) documents") { merge() }.buttonStyle(CTAButtonStyle()).disabled(docs.count < 2).accessibilityIdentifier("merge-run")
        }
    }
    private func merge() {
        let parts = docs
        work.run("Merging…") {
            guard var copy = parts.first else { return }
            copy.title = PDFTools.named(parts[0].title, "merged")
            copy.pages = parts.flatMap(\.pages)
            let saved = try await PDFTools.saveCopies([copy], store: store)
            finish(PDFToolResult(title: "Merged into one PDF", detail: "\(copy.pages.count) pages from \(parts.count) documents, saved as \(copy.title).",
                                 files: PDFTools.share(saved.map { ($0.0.title + ".pdf", $0.1) })))
        }
    }
}

// MARK: - Split

private struct SplitToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    @State private var cuts: Set<Int> = []
    var body: some View {
        ToolPage(title: "Where should we cut?", subtitle: "Tap between pages to add a cut.") {
            HStack(spacing: 8) {
                Button("Every page") { cuts = Set(0..<(document.pages.count - 1)) }.buttonStyle(ChipStyle(selected: cuts.count == document.pages.count - 1))
                Button("In half") { cuts = [document.pages.count / 2 - 1] }.buttonStyle(ChipStyle(selected: cuts == [document.pages.count / 2 - 1]))
                Button("Clear") { cuts = [] }.buttonStyle(ChipStyle(selected: false)).disabled(cuts.isEmpty)
            }
            VStack(spacing: 0) {
                ForEach(document.pages.indices, id: \.self) { i in
                    HStack(spacing: 16) {
                        PDFPageThumb(document: document, index: i).frame(width: 56, height: 74)
                            .clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TK.grey200))
                        Text("Page \(i + 1)").font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey800)
                        Spacer()
                        Text("File \(fileNumber(i))").font(.system(size: 13, weight: .bold)).foregroundStyle(TK.teal)
                            .padding(.horizontal, 10).padding(.vertical, 4).background(TK.tealSoft, in: Capsule())
                    }.padding(.vertical, 6)
                    if i < document.pages.count - 1 {
                        Button { if cuts.contains(i) { cuts.remove(i) } else { cuts.insert(i) } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "scissors").font(.system(size: 15, weight: .bold))
                                Rectangle().fill(cuts.contains(i) ? TK.teal : TK.grey200).frame(height: 2)
                                    .mask(HStack(spacing: 4) { ForEach(0..<40, id: \.self) { _ in Rectangle().frame(width: 6) } })
                                Text(cuts.contains(i) ? "Cut" : "Tap to cut").font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(cuts.contains(i) ? TK.teal : TK.grey400).frame(height: 36).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(cuts.contains(i) ? "Remove cut after page \(i + 1)" : "Cut after page \(i + 1)")
                            .accessibilityIdentifier("split-cut-\(i + 1)")
                    }
                }
            }
        } actions: {
            Button(cuts.isEmpty ? "Choose where to cut" : "Split into \(cuts.count + 1) files") { split() }
                .buttonStyle(CTAButtonStyle()).disabled(cuts.isEmpty).accessibilityIdentifier("split-run")
        }
    }
    private func fileNumber(_ page: Int) -> Int { cuts.filter { $0 < page }.count + 1 }
    private func split() {
        let doc = document, sorted = cuts.sorted()
        work.run("Splitting…") {
            var parts: [ScanDocument] = []
            var start = 0
            for (n, end) in (sorted.map { $0 + 1 } + [doc.pages.count]).enumerated() {
                var part = doc; part.title = PDFTools.named(doc.title, "part \(n + 1)"); part.pages = Array(doc.pages[start..<end]); start = end
                parts.append(part)
            }
            let saved = try await PDFTools.saveCopies(parts, store: store)
            finish(PDFToolResult(title: "Split into \(parts.count) files", detail: "Each part is a new document. The original is unchanged.",
                                 files: PDFTools.share(saved.map { ($0.0.title + ".pdf", $0.1) }), shareTitle: "Share files"))
        }
    }
}

// MARK: - Page selection tools

/// Pages chosen in a grid. Every tool that needs a page selection uses this.
private struct PageSelection: View {
    let document: ScanDocument
    @Binding var selected: [Int]
    var numbered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(selected.count) of \(document.pages.count) selected").font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey600)
                    .accessibilityIdentifier("page-selection-count")
                Spacer()
                Button(selected.count == document.pages.count ? "Deselect all" : "Select all") {
                    selected = selected.count == document.pages.count ? [] : Array(document.pages.indices)
                }.font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.blue).accessibilityIdentifier("page-select-all")
            }
            PageGrid(document: document) { index in
                SelectionBadge(selected: selected.contains(index), number: numbered ? selected.firstIndex(of: index).map { $0 + 1 } : nil)
            } tap: { index in
                if let i = selected.firstIndex(of: index) { selected.remove(at: i) } else { selected.append(index) }
            }
        }
    }
}

private struct ExtractToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    @State private var selected: [Int] = []
    var body: some View {
        ToolPage(title: "Which pages?", subtitle: "Pages are saved in the order you tap them.") {
            PageSelection(document: document, selected: $selected, numbered: true)
        } actions: {
            Button(selected.isEmpty ? "Select pages" : "Extract \(selected.count) \(selected.count == 1 ? "page" : "pages")") { extract() }
                .buttonStyle(CTAButtonStyle()).disabled(selected.isEmpty).accessibilityIdentifier("extract-run")
        }
    }
    private func extract() {
        let doc = document, picks = selected
        work.run("Extracting…") {
            var copy = doc; copy.title = PDFTools.named(doc.title, "extracted"); copy.pages = picks.map { doc.pages[$0] }
            let saved = try await PDFTools.saveCopies([copy], store: store)
            finish(PDFToolResult(title: "Extracted \(picks.count) \(picks.count == 1 ? "page" : "pages")", detail: "Saved as \(copy.title). The original is unchanged.",
                                 files: PDFTools.share(saved.map { ($0.0.title + ".pdf", $0.1) })))
        }
    }
}

private struct ExportImagesToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    @State private var selected: [Int] = []
    @State private var png = false
    @State private var pixels = 2400
    var body: some View {
        ToolPage(title: "Save as images", subtitle: "Each page becomes one picture.") {
            HStack(spacing: 8) {
                Button("JPG") { png = false }.buttonStyle(ChipStyle(selected: !png))
                Button("PNG") { png = true }.buttonStyle(ChipStyle(selected: png)).accessibilityIdentifier("images-png")
                Spacer(minLength: 12)
                Menu {
                    Button("Standard · 1600 px") { pixels = 1600 }
                    Button("High · 2400 px") { pixels = 2400 }
                    Button("Maximum · 3600 px") { pixels = 3600 }
                } label: { Label("\(pixels) px", systemImage: "chevron.up.chevron.down").font(.system(size: 15, weight: .semibold)) }
            }
            PageSelection(document: document, selected: $selected)
        } actions: {
            Button(selected.isEmpty ? "Select pages" : "Export \(selected.count) \(selected.count == 1 ? "image" : "images")") { export() }
                .buttonStyle(CTAButtonStyle()).disabled(selected.isEmpty).accessibilityIdentifier("images-run")
        }
        .onAppear { if selected.isEmpty { selected = Array(document.pages.indices) } }
    }
    private func export() {
        let doc = document, picks = selected.sorted(), format = png, size = pixels
        work.run("Making images…") {
            let url = store.url(doc.pdfFile ?? "")
            let files = try await OfflineWork.perform { () throws -> ExportedFiles in
                guard let pdf = PDFDocument(url: url) else { throw ScannerError.message("This PDF can't be opened.") }
                return try ExportFiles.images(pdf, indices: picks, pixels: size, png: format)
            }
            finish(PDFToolResult(title: "\(picks.count) \(picks.count == 1 ? "image is" : "images are") ready", detail: "Share them or save them to Photos.", files: files, shareTitle: "Share images"))
        }
    }
}

private struct LongImageToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    @State private var selected: [Int] = []
    @State private var width = 1080
    @State private var gap = 0
    var body: some View {
        ToolPage(title: "One long image", subtitle: "Pages are joined top to bottom.") {
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    VStack(spacing: CGFloat(gap) / 4) {
                        ForEach(selected.sorted().prefix(8), id: \.self) { i in
                            PDFPageThumb(document: document, index: i).frame(width: 96).background(.white)
                        }
                    }.padding(8)
                }.frame(width: 116, height: 260).background(TK.grey100, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(text: "Width")
                    HStack(spacing: 6) { ForEach([720, 1080, 1440], id: \.self) { w in Button("\(w)") { width = w }.buttonStyle(ChipStyle(selected: width == w)) } }
                    SectionLabel(text: "Space between pages")
                    HStack(spacing: 6) {
                        Button("None") { gap = 0 }.buttonStyle(ChipStyle(selected: gap == 0))
                        Button("Thin") { gap = 12 }.buttonStyle(ChipStyle(selected: gap == 12))
                        Button("Wide") { gap = 32 }.buttonStyle(ChipStyle(selected: gap == 32))
                    }
                }
            }
            PageSelection(document: document, selected: $selected)
        } actions: {
            Button("Create long image") { create() }.buttonStyle(CTAButtonStyle()).disabled(selected.isEmpty).accessibilityIdentifier("long-image-run")
        }
        .onAppear { if selected.isEmpty { selected = Array(document.pages.indices.prefix(100)) } }
    }
    private func create() {
        let doc = document, picks = selected.sorted(), w = width, g = gap
        work.run("Joining pages…") {
            let source = try PDFTools.data(doc, store: store)
            let files = try await OfflineWork.perform { try LocalDocumentTools.longImages(source, indices: picks, width: w, gap: g) }
            finish(PDFToolResult(title: "Your long image is ready", detail: files.urls.count > 1 ? "Very long results are split into \(files.urls.count) numbered parts." : "Share it or save it to Photos.",
                                 files: files, shareTitle: "Share image"))
        }
    }
}

private struct PrintToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    @State private var selected: [Int] = []
    var body: some View {
        ToolPage(title: "Which pages to print?", subtitle: "Printer settings open next.") {
            PageSelection(document: document, selected: $selected)
        } actions: {
            Button(selected.isEmpty ? "Select pages" : "Print \(selected.count) \(selected.count == 1 ? "page" : "pages")") { print() }
                .buttonStyle(CTAButtonStyle()).disabled(selected.isEmpty).accessibilityIdentifier("print-run")
        }
        .onAppear { if selected.isEmpty { selected = Array(document.pages.indices) } }
    }
    private func print() {
        let picks = selected.sorted()
        do {
            let source = try PDFTools.data(document, store: store)
            guard let pdf = PDFDocument(data: source) else { throw ScannerError.message("This PDF can't be opened.") }
            let out = PDFDocument()
            for i in picks { if let page = pdf.page(at: i)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) } }
            guard let data = out.dataRepresentation() else { throw ScannerError.message("The pages couldn't be prepared.") }
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil); info.jobName = document.title; info.outputType = .general
            controller.printInfo = info
            controller.printingItem = data
            controller.present(animated: true) { _, _, error in if let error { work.message = error.localizedDescription } }
        } catch { work.message = error.localizedDescription }
    }
}

// MARK: - Reorder

private struct ReorderToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    @State private var order: [ScanPage] = []
    @State private var dragging: ScanPage?
    private var changed: Bool { order.map(\.id) != document.pages.map(\.id) }
    var body: some View {
        ToolPage(title: "Drag pages into order", subtitle: "Touch and hold a page, then move it.") {
            HStack(spacing: 8) {
                Button("Reverse") { withAnimation { order.reverse() } }.buttonStyle(ChipStyle(selected: false))
                Button("Original order") { withAnimation { order = document.pages } }.buttonStyle(ChipStyle(selected: false)).disabled(!changed)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 18) {
                ForEach(Array(order.enumerated()), id: \.element.id) { position, page in
                    let original = document.pages.firstIndex(where: { $0.id == page.id }) ?? position
                    VStack(spacing: 6) {
                        PDFPageThumb(document: document, index: original)
                            .frame(maxWidth: .infinity).aspectRatio(0.75, contentMode: .fit).background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(dragging?.id == page.id ? TK.blue : TK.grey200, lineWidth: dragging?.id == page.id ? 2 : 1))
                            .shadow(color: .black.opacity(dragging?.id == page.id ? 0.18 : 0), radius: 8, y: 4)
                        Text("\(position + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(position == original ? TK.grey600 : TK.blue)
                    }
                    .onDrag { dragging = page; return NSItemProvider(object: page.id.uuidString as NSString) }
                    .onDrop(of: [.text], delegate: PageDrop(target: page, order: $order, dragging: $dragging))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Page \(original + 1), position \(position + 1)")
                    .accessibilityActions {
                        Button("Move earlier") { move(position, by: -1) }
                        Button("Move later") { move(position, by: 1) }
                    }
                }
            }
        } actions: {
            Button("Save new order") { save() }.buttonStyle(CTAButtonStyle()).disabled(!changed).accessibilityIdentifier("reorder-save")
        }
        .onAppear { if order.isEmpty { order = document.pages } }
    }
    private func move(_ position: Int, by delta: Int) {
        let target = position + delta
        guard order.indices.contains(target) else { return }
        withAnimation { order.swapAt(position, target) }
    }
    private func save() {
        var doc = store.document(document.id) ?? document
        let root = store.root
        doc.pages = order
        let snapshot = doc
        work.run("Saving the new order…") {
            let data = try await OfflineWork.perform { try DocumentPDF.compose(snapshot, root: root) }
            try store.savePDF(data, document: snapshot)
            finish(PDFToolResult(title: "Page order saved", detail: "\(snapshot.title) now follows your order.", files: PDFTools.share([(snapshot.title + ".pdf", data)])))
        }
    }
}
private struct PageDrop: DropDelegate {
    let target: ScanPage
    @Binding var order: [ScanPage]
    @Binding var dragging: ScanPage?
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != target.id,
              let from = order.firstIndex(where: { $0.id == dragging.id }), let to = order.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.snappy) { order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

// MARK: - Compress

private struct CompressToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    @State private var preset = CompressionPreset.balanced
    @State private var output: Data?
    private var original: Int { document.pdfFile.flatMap { try? store.url($0).resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0 }
    var body: some View {
        Group {
            if let output { resultView(output) } else { choose }
        }.animation(.easeInOut, value: output != nil)
    }
    private var choose: some View {
        ToolPage(title: "How small?", subtitle: "Now \(PDFTools.size(original)). Pages are saved as pictures; text stays searchable.") {
            VStack(spacing: 10) {
                option(.smaller, "Smallest file", "Best for email and chat. Photos lose some detail.")
                option(.balanced, "Balanced", "Smaller file with clear text. Recommended.")
                option(.quality, "High quality", "Keeps fine detail for printing.")
            }
            if let message = work.message { ToastMessage(text: message) }
        } actions: {
            Button("Compress") { compress() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("compress-run")
        }
    }
    private func option(_ value: CompressionPreset, _ title: String, _ detail: String) -> some View {
        Button { preset = value } label: { OptionCard(title: title, detail: detail, selected: preset == value) }
            .buttonStyle(.plain).accessibilityIdentifier("compress-" + value.rawValue)
    }
    private func resultView(_ data: Data) -> some View {
        let saved = original > 0 ? max(0, 100 - data.count * 100 / original) : 0
        return ToolPage(title: saved > 0 ? "\(saved)% smaller" : "Already as small as it gets", subtitle: saved > 0 ? "Check the copy before you share it." : "This document can't get smaller with this setting.") {
            HStack(spacing: 14) {
                sizeBox("Before", PDFTools.size(original), TK.grey500)
                Image(systemName: "arrow.right").font(.system(size: 20, weight: .bold)).foregroundStyle(TK.grey400)
                sizeBox("After", PDFTools.size(data.count), TK.blue)
            }.accessibilityElement(children: .combine).accessibilityIdentifier("compress-result")
            if let page = PDFDocument(data: data)?.page(at: 0) {
                PreviewStage(image: page.thumbnail(of: CGSize(width: 700, height: 700), for: .mediaBox))
            }
        } actions: {
            Button("Try another setting") { output = nil }.buttonStyle(SecondaryCTAStyle())
            Button("Save compressed copy") { save(data) }.buttonStyle(CTAButtonStyle()).disabled(saved == 0).accessibilityIdentifier("compress-save")
        }
    }
    private func sizeBox(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(TK.grey500)
            Text(value).font(.system(size: 24, weight: .bold)).foregroundStyle(color).minimumScaleFactor(0.6).lineLimit(1)
        }.frame(maxWidth: .infinity).padding(.vertical, 18).background(TK.grey50, in: RoundedRectangle(cornerRadius: 18))
    }
    private func compress() {
        let doc = document, root = store.root, quality = preset
        work.run("Compressing…") {
            var copy = doc; copy.searchable = doc.pages.contains { !$0.textBlocks.isEmpty }
            let snapshot = copy
            output = try await OfflineWork.perform { try DocumentPDF.compose(snapshot, root: root, compression: quality) }
        }
    }
    private func save(_ data: Data) {
        var copy = document; copy.title = PDFTools.named(document.title, "compressed")
        copy.searchable = document.pages.contains { !$0.textBlocks.isEmpty }
        let snapshot = copy
        work.run("Saving…") {
            try store.saveCopies([(snapshot, data)])
            finish(PDFToolResult(title: "Compressed copy saved", detail: "\(PDFTools.size(original)) → \(PDFTools.size(data.count)). The original is unchanged.",
                                 files: PDFTools.share([(snapshot.title + ".pdf", data)])))
        }
    }
}

// MARK: - Protect

private struct ProtectToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    @State private var password = ""
    @State private var repeated = ""
    @FocusState private var focus: Int?
    private var lengthOK: Bool { (8...32).contains(password.count) }
    private var asciiOK: Bool { !password.isEmpty && password.allSatisfy { $0.isASCII && !$0.isNewline } }
    private var matches: Bool { !password.isEmpty && password == repeated }
    var body: some View {
        ToolPage(title: "Set a password", subtitle: "Anyone opening the shared copy will need it. It can't be recovered if you forget it.") {
            VStack(spacing: 22) {
                field("Password", text: $password, tag: 0)
                field("Enter it again", text: $repeated, tag: 1)
            }
            VStack(alignment: .leading, spacing: 10) {
                check(lengthOK, "8 to 32 characters")
                check(asciiOK, "English letters, numbers, spaces or symbols")
                check(matches, "Both entries match")
            }
            Label("Your saved document stays unlocked on this iPhone.", systemImage: "info.circle").font(.system(size: 14)).foregroundStyle(TK.grey500)
        } actions: {
            Button("Lock and share") { protect() }.buttonStyle(CTAButtonStyle()).disabled(!(lengthOK && asciiOK && matches)).accessibilityIdentifier("protect-run")
        }
        .onAppear { focus = 0 }
    }
    private func field(_ title: String, text: Binding<String>, tag: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(focus == tag ? TK.blue : TK.grey500)
            SecureField("", text: text).font(.system(size: 22, weight: .semibold)).textContentType(.newPassword)
                .focused($focus, equals: tag).submitLabel(tag == 0 ? .next : .done).onSubmit { focus = tag == 0 ? 1 : nil }
                .padding(.vertical, 8).overlay(alignment: .bottom) { Rectangle().fill(focus == tag ? TK.blue : TK.grey300).frame(height: focus == tag ? 2 : 1) }
                .accessibilityLabel(title).accessibilityIdentifier(tag == 0 ? "protect-password" : "protect-confirm")
        }
    }
    private func check(_ ok: Bool, _ text: String) -> some View {
        Label { Text(text).foregroundStyle(ok ? TK.grey800 : TK.grey500) } icon: { Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? TK.teal : TK.grey300) }
            .font(.system(size: 15, weight: .medium))
    }
    private func protect() {
        let secret = password, doc = document
        work.run("Locking a copy…") {
            let source = try PDFTools.data(doc, store: store)
            let bytes = try await OfflineWork.perform { try DocumentPDF.protect(source, password: secret) }
            password = ""; repeated = ""
            let files = try ExportFiles.write([(PDFTools.named(doc.title, "locked") + ".pdf", bytes)])
            finish(PDFToolResult(title: "Locked copy is ready", detail: "Share it now. It isn't saved in your documents.", files: files, shareTitle: "Share locked PDF"))
        }
    }
}
