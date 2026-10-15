import SwiftUI
import PDFKit
import LocalAuthentication
import QuickLook
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
        case .images: return "Turn pages into JPG, PNG, HEIC or TIFF pictures."
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
    /// Saved as a document in the app; otherwise the file is saved to Files (or Photos) first.
    var inLibrary = true
}

/// A PDF tool: choose a document, do the one job, see the result.
struct PDFToolFlow: View {
    let tool: LibraryTool
    var documentID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            // Free users see the free-try screen before choosing a document.
            ProTrialGate(feature: tool.proFeature, title: tool.headline, detail: tool.promise, art: tool.art, close: { dismiss() }) {
                PDFToolRoot(tool: tool, preselected: documentID) { dismiss() }
            }
        }
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
            else if step == 2, let result { PDFToolDone(result: result, proTool: tool.pro, close: close) }
        }
        .stepChrome(step: $step, forward: $forward, last: 2, work: work)
        .toolbar {
            if step == 0 || step == 2 { ToolbarItem(placement: .cancellationAction) { Button("Close", action: close).accessibilityIdentifier("tool-close") } }
        }
        .sheet(isPresented: $paywall, onDismiss: {
            if subscription.isPro, let id = pending { proceed(id) }
            pending = nil
        }) { PaywallView(start: .general) }
        // Merge and long image take several PDFs at once.
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: multiple) { response in
            guard case .success(let urls) = response, !urls.isEmpty else { return }
            work.run(urls.count == 1 ? "Adding your PDF…" : "Adding your PDFs…") {
                for url in urls { select(try await store.importNativePDF(url)) }
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
            if let id = preselected, store.document(id) != nil { tool == .longImage ? proceed(id) : select(id) }
        }
    }
    /// Tools that join several documents.
    private var multiple: Bool { tool == .merge || tool == .longImage }
    private var landing: some View {
        ToolPage(title: tool.headline, subtitle: tool.promise) {
            ToolHero(art: tool.art)
            VStack(alignment: .leading, spacing: 4) {
                Button { scanning = true } label: {
                    ChoiceRow(symbol: "camera.fill", title: "Scan with the camera", detail: "Saved as a new PDF, then opened here", tint: TK.blue, soft: TK.blueSoft)
                }.buttonStyle(.plain).accessibilityIdentifier("pdf-scan")
                Button { importing = true } label: {
                    ChoiceRow(symbol: "folder.fill", title: multiple ? "Choose PDFs from Files" : "Choose a PDF from Files",
                              detail: multiple ? "Pick several at once. They're added to your documents" : "It's added to your documents", tint: TK.orange, soft: TK.orangeSoft)
                }.buttonStyle(.plain).accessibilityIdentifier("pdf-import")
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: multiple ? "Choose documents in order" : "From your documents")
                if documents.isEmpty {
                    Text("No saved documents yet. Scan or import one first.").font(.system(size: 15)).foregroundStyle(TK.grey500).padding(.vertical, 12)
                } else {
                    DocumentChoiceList(documents: documents, selected: chosen, multiple: multiple,
                                       disabled: { tool == .split && $0.pages.count < 2 }) { select($0.id) }
                }
            }
            if let message = work.message { ToastMessage(text: message) }
        } actions: {
            if tool == .merge {
                Button(chosen.count < 2 ? "Choose 2 or more" : "Next · \(chosen.count) documents") { forward = true; step = 1 }
                    .buttonStyle(CTAButtonStyle()).disabled(chosen.count < 2).accessibilityIdentifier("merge-next")
                if !subscription.isPro { Text("Free: merge 2 documents. Pro: any number.").font(.system(size: 13)).foregroundStyle(TK.grey500).accessibilityIdentifier("merge-free-limit") }
            } else if tool == .longImage {
                Button(chosen.isEmpty ? "Choose documents" : chosen.count == 1 ? "Next" : "Next · \(chosen.count) documents") { forward = true; step = 1 }
                    .buttonStyle(CTAButtonStyle()).disabled(chosen.isEmpty).accessibilityIdentifier("long-image-documents-next")
            }
        }
    }
    private func select(_ id: UUID) {
        if tool == .longImage {
            if let i = chosen.firstIndex(of: id) { chosen.remove(at: i) } else { chosen.append(id) }
            return
        }
        if tool == .merge {
            if let i = chosen.firstIndex(of: id) { chosen.remove(at: i); return }
            if !subscription.isPro && chosen.count >= DocumentTool.freeMergeDocuments + 1 { pending = nil; paywall = true; return }
            chosen.append(id); return
        }
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
        case .longImage:
            let docs = chosen.compactMap { store.document($0) }
            LongImageToolStep(documents: docs.isEmpty ? [doc] : docs, work: work, finish: finish)
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
        if doc.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { doc.title = ScanDocument.defaultTitle(); doc.autoTitled = true }
        let result = try await PDFExport.prepare(doc, root: store.root)
        try store.savePDF(result.data, document: result.document)
        return id
    }
}

private struct PDFToolDone: View {
    let result: PDFToolResult
    /// A Pro tool's result: sharing it the first time may ask for a rating.
    var proTool = false
    let close: () -> Void
    @State private var sharing: ExportedFiles?
    private var imageURLs: [URL] {
        guard let urls = result.files?.urls, !urls.isEmpty else { return [] }
        return urls.allSatisfy { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) } ? urls : []
    }
    /// Pictures go to Photos, files outside the app's documents to Files; then sharing.
    private var saveFirst: SaveFirst? {
        guard let files = result.files else { return nil }
        let share = { sharing = files }
        if !imageURLs.isEmpty { return SaveFirst(urls: imageURLs, photos: true, shareTitle: result.shareTitle, share: share) }
        if !result.inLibrary { return SaveFirst(urls: files.urls, shareTitle: result.shareTitle, share: share) }
        return nil
    }
    var body: some View {
        ToolDonePage(title: result.title, detail: result.detail,
                     primaryTitle: "Done", primary: close,
                     secondaryTitle: result.files == nil ? nil : result.shareTitle,
                     secondary: result.files == nil ? nil : { sharing = result.files },
                     save: saveFirst) {
            if let urls = result.files?.urls, !urls.isEmpty { ResultReview(urls: urls).padding(.top, 6) }
        }
            .sheet(item: $sharing, onDismiss: { if proTool { ReviewPrompter.request(.firstProShare) } }) { files in ShareSheet(items: files.urls) }
            .onDisappear { if let files = result.files { ExportFiles.remove(files.directory) } }
    }
}

/// Every page of a tool's result, first to last, so it can be checked before
/// it is shared. Pages render lazily off the main thread; tap one to zoom.
private struct ResultReview: View {
    let urls: [URL]
    @State private var zoom: ResultZoom?
    @State private var office: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Check the result")
            ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                if urls.count > 1 {
                    Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 15, weight: .bold)).foregroundStyle(TK.grey800)
                        .padding(.top, 6)
                }
                switch url.pathExtension.lowercased() {
                case "pdf": ResultPDFPages(url: url) { zoom = ResultZoom(url: url, page: $0) }
                case "jpg", "jpeg", "png": ResultPageImage(url: url, page: nil)
                case "txt":
                    Text((try? String(contentsOf: url, encoding: .utf8)) ?? "").font(.system(size: 15)).foregroundStyle(TK.grey900)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(TK.grey50, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(TK.grey200))
                default:
                    // Word, Excel and PowerPoint files: Quick Look shows every page inline.
                    InlineQuickLook(url: url).frame(height: 560)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TK.grey200))
                    Button { office = url } label: { Label("Open full screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.blue)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fullScreenCover(isPresented: Binding(get: { office != nil }, set: { if !$0 { office = nil } })) {
            if let office { OfficeQuickLook(url: office) }
        }
        .fullScreenCover(item: $zoom) { target in
            NavigationStack {
                PDFPreview(url: target.url, initialPage: target.page).ignoresSafeArea(edges: .bottom)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { zoom = nil } } }
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
private struct ResultZoom: Identifiable { let id = UUID(); let url: URL; let page: Int }

/// Quick Look embedded in the page (no navigation bar) for Office results.
private struct InlineQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Source { Source(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let view = QLPreviewController(); view.dataSource = context.coordinator; return view
    }
    func updateUIViewController(_ view: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; view.reloadData() }
    }
    final class Source: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private struct ResultPDFPages: View {
    let url: URL
    let open: (Int) -> Void
    @State private var info: (count: Int, locked: Bool)?
    var body: some View {
        Group {
            if let info {
                if info.locked {
                    Label("This PDF is locked with a password, so its pages can't be previewed here.", systemImage: "lock.fill")
                        .font(.system(size: 15)).foregroundStyle(TK.grey600)
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(0..<info.count, id: \.self) { i in
                            Button { open(i) } label: {
                                VStack(spacing: 6) {
                                    ResultPageImage(url: url, page: i)
                                    Text("Page \(i + 1) of \(info.count)").font(.system(size: 13, weight: .medium)).foregroundStyle(TK.grey500)
                                }
                            }.buttonStyle(.plain).accessibilityLabel("Page \(i + 1) of \(info.count)")
                        }
                    }
                }
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
        }
        .task(id: url) {
            let u = url
            info = await Task.detached { () -> (count: Int, locked: Bool) in
                guard let doc = CGPDFDocument(u as CFURL) else { return (0, false) }
                return (doc.numberOfPages, !doc.isUnlocked)
            }.value
        }
    }
}

/// One rendered page (or image file) at reading size, with its shape reserved
/// before it loads so the list doesn't jump.
private struct ResultPageImage: View {
    let url: URL
    let page: Int?
    @State private var image: UIImage?
    @State private var aspect: CGFloat = 0.773
    var body: some View {
        ZStack {
            Rectangle().fill(.white)
            if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView() }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(TK.grey200, lineWidth: 1))
        .task(id: "\(url.path)#\(page ?? -1)") {
            let u = url, p = page
            let rendered: UIImage? = await Task.detached {
                if let p {
                    guard let doc = CGPDFDocument(u as CFURL), let pg = doc.page(at: p + 1) else { return nil }
                    let box = pg.getBoxRect(.cropBox)
                    let turned = abs(pg.rotationAngle) % 180 == 90
                    let size = turned ? CGSize(width: box.height, height: box.width) : box.size
                    guard size.width > 0, size.height > 0 else { return nil }
                    let scale = min(1100 / max(size.width, size.height), 3)
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                    let target = CGSize(width: size.width * scale, height: size.height * scale)
                    return UIGraphicsImageRenderer(size: target, format: format).image { c in
                        UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: target))
                        let cg = c.cgContext
                        cg.translateBy(x: 0, y: target.height); cg.scaleBy(x: 1, y: -1)
                        cg.concatenate(pg.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: target), rotate: 0, preserveAspectRatio: true))
                        cg.drawPDFPage(pg)
                    }
                }
                return UIImage(contentsOfFile: u.path)?.preparingThumbnail(of: CGSize(width: 1200, height: 12000))
            }.value
            if let rendered {
                aspect = rendered.size.width / max(1, rendered.size.height)
                image = rendered
            }
        }
    }
}

/// Saving helpers shared by the PDF tools.
@MainActor enum PDFTools {
    /// "Report (watermark) (merged)" → "Report (merged)": one tool suffix at a time.
    nonisolated static func named(_ title: String, _ suffix: String) -> String {
        var base = title
        let known = try? NSRegularExpression(pattern: #"\s\((watermark|timestamp|merged|part \d+|extracted|compressed|locked|redacted)\)$"#)
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
    @State private var allText = ""
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
                    Text(L(text)).font(.system(size: 16)).foregroundStyle(TK.grey900).textSelection(.enabled)
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
            HStack(spacing: 10) {
                // Shared as plain text so Mail, Messages and chat apps put it in the message body.
                ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(SecondaryCTAStyle()).disabled(!read || text.isEmpty).accessibilityIdentifier("ocr-share")
                Button(copied ? "Copied" : "Copy text") { UIPasteboard.general.string = text; withAnimation { copied = true } }
                    .buttonStyle(CTAButtonStyle()).disabled(!read || text.isEmpty).accessibilityIdentifier("ocr-copy")
            }
        }
        .task(id: page) { recognize(page) }
        .sheet(isPresented: $correcting) { OCRTextEditor(documentID: document.id, pageIndex: page) }
        .sheet(item: $share) { files in ShareSheet(items: [allText]) { _, _ in ExportFiles.remove(files.directory) } }
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
            allText = prepared.document.text
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
            Button(LS(document.pages.count == 1 ? "Add to 1 page" : "Add to \(document.pages.count) pages")) { apply() }
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
        // The label shows the time the user stamps it, not when the scan was made.
        .onAppear { stamp.date = Date() }
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
                HStack(spacing: 8) { ForEach(StampCorner.allCases) { c in Button(L(c.rawValue)) { stamp.corner = c }.buttonStyle(ChipStyle(selected: stamp.corner == c)) } }
            }
            ToolSlider(title: "Size", value: Binding(get: { Double(stamp.scale) }, set: { stamp.scale = CGFloat($0) }), range: 0.6...2) { "\(Int($0 * 100))%" }
            if stamp.template == .dateTime {
                Toggle(isOn: $stamp.white) { Text("Dark label (white text)").font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey800) }.tint(TK.blue)
            }
        } actions: {
            Button("Change style") { detailsShown = false }.buttonStyle(SecondaryCTAStyle()).accessibilityIdentifier("timestamp-style")
            Button(LS(document.pages.count == 1 ? "Add to 1 page" : "Add to \(document.pages.count) pages")) { apply() }
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
            // A stamp as it is printed on the page: the same colours in dark mode.
            .environment(\.colorScheme, .light)
            Text(L(template.rawValue)).font(.system(size: 14, weight: .semibold)).foregroundStyle(selected ? TK.blue : TK.grey700)
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
                            Text(L(doc.title)).font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900).lineLimit(2)
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

/// What extracted pages become.
private enum ExtractFormat: String, CaseIterable, Identifiable {
    case pdf, word, powerpoint, excel, images, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pdf: return "Keep as PDF"
        case .word: return "Word document"
        case .powerpoint: return "PowerPoint slides"
        case .excel: return "Excel spreadsheet"
        case .images: return "Images"
        case .text: return "Plain text"
        }
    }
    var detail: String {
        switch self {
        case .pdf: return "Same look as the original. Saved as a new document."
        case .word: return "Editable text with the page layout (.docx)."
        case .powerpoint: return "One slide per page, with editable text (.pptx)."
        case .excel: return "Tables become cells you can edit (.xlsx)."
        case .images: return "One picture per page, ready for Photos or chat."
        case .text: return "Just the words, as a .txt file."
        }
    }
    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .word: return "doc.text"
        case .powerpoint: return "rectangle.on.rectangle"
        case .excel: return "tablecells"
        case .images: return "photo.on.rectangle"
        case .text: return "text.alignleft"
        }
    }
}

private struct ExtractToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    @State private var selected: [Int] = []
    @State private var choosing = false
    @State private var format = ExtractFormat.pdf
    private var count: String { selected.count == 1 ? "1 page" : "\(selected.count) pages" }
    var body: some View {
        ZStack {
            if choosing { formatPage.transition(.move(edge: .trailing).combined(with: .opacity)) }
            else { pagesPage.transition(.move(edge: .leading).combined(with: .opacity)) }
        }
        .animation(.snappy(duration: 0.3), value: choosing)
    }
    private var pagesPage: some View {
        ToolPage(title: "Which pages?", subtitle: "Pages are saved in the order you tap them.") {
            PageSelection(document: document, selected: $selected, numbered: true)
        } actions: {
            Button(selected.isEmpty ? "Select pages" : "Next · \(count)") { choosing = true }
                .buttonStyle(CTAButtonStyle()).disabled(selected.isEmpty).accessibilityIdentifier("extract-next")
        }
    }
    private var formatPage: some View {
        ToolPage(title: "Save \(count) as", subtitle: "Keep the PDF, or turn the pages into another kind of file.") {
            VStack(spacing: 10) {
                ForEach(ExtractFormat.allCases) { option in
                    Button { format = option } label: {
                        OptionCard(title: option.title, detail: option.detail, selected: format == option) {
                            Image(systemName: option.symbol).font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(format == option ? TK.blue : TK.grey400)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("extract-format-" + option.rawValue)
                }
            }
            if let message = work.message { ToastMessage(text: message) }
        } actions: {
            Button("Change pages") { choosing = false }.buttonStyle(SecondaryCTAStyle())
            Button("Extract \(count)") { extract() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("extract-run")
        }
    }
    private func extract() {
        let doc = document, picks = selected, kind = format
        if kind == .pdf {
            work.run("Extracting…") {
                var copy = doc; copy.title = PDFTools.named(doc.title, "extracted"); copy.pages = picks.map { doc.pages[$0] }
                let saved = try await PDFTools.saveCopies([copy], store: store)
                finish(PDFToolResult(title: picks.count == 1 ? "Extracted 1 page" : "Extracted \(picks.count) pages", detail: "Saved as \(copy.title). The original is unchanged.",
                                     files: PDFTools.share(saved.map { ($0.0.title + ".pdf", $0.1) })))
            }
            return
        }
        guard let file = doc.pdfFile else { work.message = "Save this document as a PDF first."; return }
        let url = store.url(file), name = PDFTools.named(doc.title, "extracted")
        let known = picks.map { doc.pages.indices.contains($0) && doc.pages[$0].ocrComplete ? doc.pages[$0].plainText : nil }
        work.run("Extracting…") {
            var images: [UIImage] = []
            for (n, index) in picks.enumerated() {
                work.busy = "Reading page \(n + 1) of \(picks.count)…"
                images.append(try await OfflineWork.perform { try ExtractRender.page(url, index: index) })
            }
            work.busy = "Creating the file…"
            let snapshot = images
            let files: [(String, Data)] = try await OfflineWork.perform {
                switch kind {
                case .images:
                    return snapshot.enumerated().map { i, image in
                        (snapshot.count == 1 ? "\(name).jpg" : "\(name)-\(i + 1).jpg", image.jpegData(compressionQuality: 0.92) ?? Data())
                    }
                case .text:
                    let text = try snapshot.enumerated().map { i, image in
                        try known[i] ?? Imaging.recognize(image).map(\.text).joined(separator: "\n")
                    }.joined(separator: "\n\n")
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ScannerError.message("No text was found on these pages.") }
                    return [(name + ".txt", Data(text.utf8))]
                default:
                    let layouts = try snapshot.map { try OfficeLayoutPages.analyze($0) }
                    switch kind {
                    case .word: return [(name + ".docx", try OfficeLayoutExport.word(layouts, image: OfficeLayoutPages.missingPicture))]
                    case .excel: return [(name + ".xlsx", try OfficeLayoutExport.excel(layouts, image: OfficeLayoutPages.missingPicture))]
                    default: return [(name + ".pptx", try OfficeLayoutExport.powerpoint(layouts, theme: OfficeLayoutPages.theme(), image: OfficeLayoutPages.missingPicture))]
                    }
                }
            }
            let title = kind == .images ? (files.count == 1 ? "Your image is ready" : "\(files.count) images are ready") : "\(kind.title) is ready"
            finish(PDFToolResult(title: title,
                                 detail: picks.count == 1 ? "Made from 1 page of \(doc.title). The original is unchanged." : "Made from \(picks.count) pages of \(doc.title). The original is unchanged.",
                                 files: PDFTools.share(files), shareTitle: kind == .images ? "Share images" : "Share file", inLibrary: false))
        }
    }
}

/// Renders one page of a saved PDF as a picture for conversion.
enum ExtractRender {
    nonisolated static func page(_ url: URL, index: Int, maxSide: CGFloat = 2400) throws -> UIImage {
        guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: index + 1) else { throw ScannerError.message("This PDF can't be opened.") }
        let box = page.getBoxRect(.cropBox)
        let turned = abs(page.rotationAngle) % 180 == 90
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { throw ScannerError.message("Unsupported PDF page dimensions.") }
        let scale = min(maxSide / max(size.width, size.height), 4)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { c in
            UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: target))
            let cg = c.cgContext
            cg.translateBy(x: 0, y: target.height); cg.scaleBy(x: 1, y: -1)
            // getDrawingTransform never scales a page up, so a page smaller than
            // `target` used to come out small in one corner. Scale explicitly and
            // let the transform only handle rotation and the crop box origin.
            cg.scaleBy(x: target.width / size.width, y: target.height / size.height)
            cg.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            cg.drawPDFPage(page)
        }
    }
}

private struct ExportImagesToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    @State private var selected: [Int] = []
    @State private var choosing = false
    /// Remembered between exports.
    @AppStorage("export-image-format") private var formatChoice = ImageExportFormat.jpg.rawValue
    @State private var combined = true
    @State private var pixels = 2400
    private var format: ImageExportFormat { ImageExportFormat(rawValue: formatChoice).flatMap { $0.available ? $0 : nil } ?? .jpg }
    private var count: String { selected.count == 1 ? "1 page" : "\(selected.count) pages" }
    var body: some View {
        ZStack {
            if choosing { optionsPage.transition(.move(edge: .trailing).combined(with: .opacity)) }
            else { pagesPage.transition(.move(edge: .leading).combined(with: .opacity)) }
        }
        .animation(.snappy(duration: 0.3), value: choosing)
        .onAppear { if selected.isEmpty { selected = Array(document.pages.indices) } }
    }
    private var pagesPage: some View {
        ToolPage(title: "Which pages?", subtitle: "Each page becomes one picture.") {
            PageSelection(document: document, selected: $selected)
        } actions: {
            Button(selected.isEmpty ? "Select pages" : "Next · \(count)") { choosing = true }
                .buttonStyle(CTAButtonStyle()).disabled(selected.isEmpty).accessibilityIdentifier("images-next")
        }
    }
    private var optionsPage: some View {
        ToolPage(title: "Choose the image type", subtitle: selected.count == 1 ? "\(count) will become a picture." : "\(count) will become pictures.") {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Format")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(ImageExportFormat.allCases.filter(\.available)) { item in
                        Button { formatChoice = item.rawValue } label: {
                            Text(item.title).font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(format == item ? TK.blueDeep : TK.grey900)
                                .frame(maxWidth: .infinity).frame(height: 48)
                                .background(format == item ? TK.blueSoft : TK.grey50, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(format == item ? TK.blue.opacity(0.5) : TK.grey200, lineWidth: format == item ? 1.5 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(format == item ? .isSelected : [])
                        .accessibilityIdentifier("images-\(item.rawValue)")
                    }
                }
                Text(L(format.detail)).font(.system(size: 14)).foregroundStyle(TK.grey600).fixedSize(horizontal: false, vertical: true)
                if format == .tiff && selected.count > 1 {
                    Toggle(L("One TIFF file with all pages"), isOn: $combined).font(.system(size: 15, weight: .medium))
                        .accessibilityIdentifier("images-tiff-combined")
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Size")
                sizeOption(1600, "Standard", "1600 px · good for phones and email")
                sizeOption(2400, "High", "2400 px · clear when zoomed in. Recommended.")
                sizeOption(3600, "Maximum", "3600 px · for printing and fine detail")
            }
            if let message = work.message { ToastMessage(text: message) }
        } actions: {
            Button("Change pages") { choosing = false }.buttonStyle(SecondaryCTAStyle())
            Button(format == .tiff && combined && selected.count > 1 ? L("Export one TIFF file") : LS(selected.count == 1 ? "Export 1 image" : "Export \(selected.count) images")) { export() }
                .buttonStyle(CTAButtonStyle()).accessibilityIdentifier("images-run")
        }
    }
    private func sizeOption(_ value: Int, _ title: String, _ detail: String) -> some View {
        Button { pixels = value } label: { OptionCard(title: title, detail: detail, selected: pixels == value) }
            .buttonStyle(.plain).accessibilityIdentifier("images-size-\(value)")
    }
    private func export() {
        let doc = document, picks = selected.sorted(), format = self.format, size = pixels, combined = self.combined && self.format == .tiff && selected.count > 1
        work.run("Making images…") {
            let url = store.url(doc.pdfFile ?? "")
            let files = try await OfflineWork.perform { () throws -> ExportedFiles in
                guard let pdf = PDFDocument(url: url) else { throw ScannerError.message("This PDF can't be opened.") }
                return try ExportFiles.images(pdf, indices: picks, pixels: size, format: format, combined: combined)
            }
            finish(PDFToolResult(title: combined ? "Your TIFF file is ready" : picks.count == 1 ? "1 image is ready" : "\(picks.count) images are ready",
                                 detail: combined ? String(format: L("%lld pages in one file."), picks.count) : "Share them or save them to Photos.",
                                 files: files, shareTitle: combined ? "Share file" : "Share images", inLibrary: false))
        }
    }
}

private struct LongImageToolStep: View {
    @EnvironmentObject private var store: LibraryStore
    /// In the order chosen; their pages are joined one document after another.
    let documents: [ScanDocument]
    @ObservedObject var work: ToolWork
    let finish: (PDFToolResult) -> Void
    /// Chosen pages per document.
    @State private var selected: [[Int]]
    @State private var choosing = false
    @State private var width = 1080
    @State private var gap = 0
    init(documents: [ScanDocument], work: ToolWork, finish: @escaping (PDFToolResult) -> Void) {
        self.documents = documents; self.work = work; self.finish = finish
        _selected = State(initialValue: documents.map { Array($0.pages.indices.prefix(100)) })
    }
    private var total: Int { selected.reduce(0) { $0 + $1.count } }
    private var count: String { total == 1 ? "1 page" : "\(total) pages" }
    /// (document, page) in the order they're joined.
    private var picks: [(Int, Int)] { selected.enumerated().flatMap { k, pages in pages.sorted().map { (k, $0) } } }
    var body: some View {
        ZStack {
            if choosing { optionsPage.transition(.move(edge: .trailing).combined(with: .opacity)) }
            else { pagesPage.transition(.move(edge: .leading).combined(with: .opacity)) }
        }
        .animation(.snappy(duration: 0.3), value: choosing)
    }
    private var pagesPage: some View {
        ToolPage(title: "Which pages?", subtitle: "They're joined top to bottom into one image.") {
            if documents.count == 1 {
                PageSelection(document: documents[0], selected: $selected[0])
            } else {
                ForEach(documents.indices, id: \.self) { k in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: "\(k + 1). \(documents[k].title)").font(.system(size: 17, weight: .bold)).foregroundStyle(TK.grey900).lineLimit(2)
                        PageSelection(document: documents[k], selected: $selected[k])
                    }
                }
            }
        } actions: {
            Button(total == 0 ? "Select pages" : "Next · \(count)") { choosing = true }
                .buttonStyle(CTAButtonStyle()).disabled(total == 0).accessibilityIdentifier("long-image-next")
        }
    }
    private var optionsPage: some View {
        ToolPage(title: "How should it look?", subtitle: "\(count) joined top to bottom.") {
            ScrollView {
                VStack(spacing: CGFloat(gap) / 4) {
                    ForEach(Array(picks.prefix(8).enumerated()), id: \.offset) { _, pick in
                        PDFPageThumb(document: documents[pick.0], index: pick.1).frame(width: 120).background(.white)
                    }
                }.padding(10).frame(maxWidth: .infinity)
            }.frame(height: 240).background(TK.grey100, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Width")
                widthOption(720, "Small", "720 px · lightest file for chat")
                widthOption(1080, "Standard", "1080 px · sharp on phones. Recommended.")
                widthOption(1440, "Large", "1440 px · for tablets and zooming in")
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Space between pages")
                gapOption(0, "None", "Pages touch, like one continuous sheet")
                gapOption(12, "Thin", "A small line of space between pages")
                gapOption(32, "Wide", "Clear gaps so each page stands apart")
            }
            if let message = work.message { ToastMessage(text: message) }
        } actions: {
            Button("Change pages") { choosing = false }.buttonStyle(SecondaryCTAStyle())
            Button("Create long image") { create() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("long-image-run")
        }
    }
    private func widthOption(_ value: Int, _ title: String, _ detail: String) -> some View {
        Button { width = value } label: { OptionCard(title: title, detail: detail, selected: width == value) }.buttonStyle(.plain)
    }
    private func gapOption(_ value: Int, _ title: String, _ detail: String) -> some View {
        Button { withAnimation(.snappy) { gap = value } } label: { OptionCard(title: title, detail: detail, selected: gap == value) }.buttonStyle(.plain)
    }
    private func create() {
        let docs = documents, chosen = picks, w = width, g = gap
        work.run("Joining pages…") {
            let source: Data, indices: [Int]
            if docs.count == 1 {
                source = try PDFTools.data(docs[0], store: store); indices = chosen.map(\.1)
            } else {
                // The chosen pages of every document, in order, as one PDF to join.
                let sources = try docs.map { try PDFTools.data($0, store: store) }
                let order = chosen.map { [$0.0, $0.1] }
                source = try await OfflineWork.perform {
                    let combined = PDFDocument()
                    let pdfs = sources.map { PDFDocument(data: $0) }
                    for pick in order {
                        guard let page = pdfs[pick[0]]?.page(at: pick[1])?.copy() as? PDFPage else { throw ScannerError.message("A page couldn't be read.") }
                        combined.insert(page, at: combined.pageCount)
                    }
                    guard let data = combined.dataRepresentation() else { throw ScannerError.message("A page couldn't be read.") }
                    return data
                }
                indices = Array(0..<chosen.count)
            }
            let files = try await OfflineWork.perform { try LocalDocumentTools.longImages(source, indices: indices, width: w, gap: g) }
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
            Button(LS(selected.isEmpty ? "Select pages" : selected.count == 1 ? "Print 1 page" : "Print \(selected.count) pages")) { print() }
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
    private var changed: Bool { order.map(\.id) != document.pages.map(\.id) }
    var body: some View {
        ToolPage(title: "Drag pages into order", subtitle: "Touch and hold a page, then move it.") {
            HStack(spacing: 8) {
                Button("Reverse") { withAnimation { order.reverse() } }.buttonStyle(ChipStyle(selected: false))
                Button("Original order") { withAnimation { order = document.pages } }.buttonStyle(ChipStyle(selected: false)).disabled(!changed)
            }
            ReorderGrid(order: $order, document: document) { position, by in move(position, by: by) }
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
/// Home-screen style reordering: touch and hold lifts a page, it follows the
/// finger, and the other pages slide out of the way live. No drag preview.
private struct ReorderGrid: View {
    @Binding var order: [ScanPage]
    let document: ScanDocument
    let nudge: (Int, Int) -> Void
    @State private var width: CGFloat = 0
    @State private var dragID: UUID?
    @State private var dragCenter: CGPoint = .zero
    @State private var grab: CGSize?
    @GestureState private var active = false
    private let columns = 3
    private let gap: CGFloat = 14, rowGap: CGFloat = 18, label: CGFloat = 22
    private var cellW: CGFloat { max(1, (width - gap * CGFloat(columns - 1)) / CGFloat(columns)) }
    private var cellH: CGFloat { cellW / 0.75 + label }
    private var rows: Int { (order.count + columns - 1) / columns }
    private func center(_ i: Int) -> CGPoint {
        CGPoint(x: CGFloat(i % columns) * (cellW + gap) + cellW / 2, y: CGFloat(i / columns) * (cellH + rowGap) + cellH / 2)
    }
    private func slot(at p: CGPoint) -> Int {
        let col = min(columns - 1, max(0, Int(floor((p.x + gap / 2) / (cellW + gap)))))
        let row = min(max(0, rows - 1), max(0, Int(floor((p.y + rowGap / 2) / (cellH + rowGap)))))
        return min(order.count - 1, row * columns + col)
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            if width > 0 {
                ForEach(Array(order.enumerated()), id: \.element.id) { position, page in
                    let original = document.pages.firstIndex(where: { $0.id == page.id }) ?? position
                    let lifted = dragID == page.id
                    VStack(spacing: 6) {
                        PDFPageThumb(document: document, index: original)
                            .frame(width: cellW, height: cellW / 0.75).background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TK.grey200, lineWidth: 1))
                        Text("\(position + 1)").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(position == original ? TK.grey600 : TK.blue)
                            .frame(height: label - 6)
                    }
                    .frame(width: cellW, height: cellH)
                    .contentShape(Rectangle())
                    .scaleEffect(lifted ? 1.08 : 1)
                    .shadow(color: .black.opacity(lifted ? 0.22 : 0), radius: 14, y: 8)
                    .position(lifted ? dragCenter : center(position))
                    .zIndex(lifted ? 1 : 0)
                    .gesture(drag(page))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Page \(original + 1), position \(position + 1)")
                    .accessibilityActions {
                        Button("Move earlier") { nudge(position, -1) }
                        Button("Move later") { nudge(position, 1) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: rows == 0 || width == 0 ? 120 : CGFloat(rows) * cellH + CGFloat(rows - 1) * rowGap)
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
        })
        .coordinateSpace(name: "reorder")
        .animation(.snappy(duration: 0.26), value: order.map(\.id))
        .onChange(of: active) { _, now in
            if !now, dragID != nil { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragID = nil }; grab = nil }
        }
    }
    private func drag(_ page: ScanPage) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("reorder")))
            .updating($active) { value, state, _ in if case .second(true, _) = value { state = true } }
            .onChanged { value in
                guard case .second(true, let d) = value, let from = order.firstIndex(where: { $0.id == page.id }) else { return }
                if dragID != page.id {
                    let c = center(from)
                    dragCenter = c; grab = nil
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { dragID = page.id }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                guard let d else { return }
                if grab == nil { let c = center(from); grab = CGSize(width: c.x - d.startLocation.x, height: c.y - d.startLocation.y) }
                let offset = grab ?? .zero
                dragCenter = CGPoint(x: d.location.x + offset.width, y: d.location.y + offset.height)
                let target = slot(at: dragCenter)
                if target != from {
                    order.move(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target)
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragID = nil }
                grab = nil
            }
    }
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
        ToolPage(title: "How small?", subtitle: String(format: L("Now %@. Pages are saved as pictures; text stays searchable."), PDFTools.size(original))) {
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
            Text(L(title)).font(.system(size: 14, weight: .semibold)).foregroundStyle(TK.grey500)
            Text(L(value)).font(.system(size: 24, weight: .bold)).foregroundStyle(color).minimumScaleFactor(0.6).lineLimit(1)
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
    @State private var lockNote: String?
    @FocusState private var focus: Int?
    private var current: ScanDocument { store.document(document.id) ?? document }
    /// Turning a lock on is immediate; turning it off asks for Face ID first.
    private func lockBinding(folder: Bool) -> Binding<Bool> {
        Binding(get: {
            folder ? (store.manifest.lockedFolders ?? []).contains(current.folder) : current.appLocked == true
        }, set: { on in
            lockNote = nil
            Task {
                if !on, !(await PrivateLock.authenticate("Remove the lock")) { lockNote = "The lock wasn't removed."; return }
                if on {
                    var e: NSError?
                    guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &e) else { lockNote = "Set a device passcode in iPhone Settings first."; return }
                }
                if on { PrivateLock.shared.keepOpen(current) }
                if folder { store.setFolderLocked(on, folder: current.folder) } else { store.setAppLocked(on, for: current) }
            }
        })
    }
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
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: "Also lock it in this app")
                Toggle(isOn: lockBinding(folder: false)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This document").font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900)
                        Text("Face ID or your passcode to open it here").font(.system(size: 13)).foregroundStyle(TK.grey500)
                    }
                }.tint(TK.blue).accessibilityIdentifier("protect-app-lock")
                Toggle(isOn: lockBinding(folder: true)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Everything in “\(current.folder)”").font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900)
                        Text("Locks the whole folder, including new scans").font(.system(size: 13)).foregroundStyle(TK.grey500)
                    }
                }.tint(TK.blue).accessibilityIdentifier("protect-folder-lock")
                if let lockNote { Text(L(lockNote)).font(.system(size: 13)).foregroundStyle(TK.red) }
            }
            .padding(16).background(TK.grey50, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Label("The password is only for the shared copy. Locking in the app works without it.", systemImage: "info.circle").font(.system(size: 14)).foregroundStyle(TK.grey500)
        } actions: {
            Button("Lock and share") { protect() }.buttonStyle(CTAButtonStyle()).disabled(!(lengthOK && asciiOK && matches)).accessibilityIdentifier("protect-run")
        }
        .onAppear { focus = 0 }
    }
    private func field(_ title: String, text: Binding<String>, tag: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(title)).font(.system(size: 14, weight: .semibold)).foregroundStyle(focus == tag ? TK.blue : TK.grey500)
            SecureField("", text: text).font(.system(size: 22, weight: .semibold)).textContentType(.newPassword)
                .focused($focus, equals: tag).submitLabel(tag == 0 ? .next : .done).onSubmit { focus = tag == 0 ? 1 : nil }
                .padding(.vertical, 8).overlay(alignment: .bottom) { Rectangle().fill(focus == tag ? TK.blue : TK.grey300).frame(height: focus == tag ? 2 : 1) }
                .accessibilityLabel(title).accessibilityIdentifier(tag == 0 ? "protect-password" : "protect-confirm")
        }
    }
    private func check(_ ok: Bool, _ text: String) -> some View {
        Label { Text(L(text)).foregroundStyle(ok ? TK.grey800 : TK.grey500) } icon: { Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? TK.teal : TK.grey300) }
            .font(.system(size: 15, weight: .medium))
    }
    private func protect() {
        let secret = password, doc = document
        work.run("Locking a copy…") {
            let source = try PDFTools.data(doc, store: store)
            let bytes = try await OfflineWork.perform { try DocumentPDF.protect(source, password: secret) }
            password = ""; repeated = ""
            let files = try ExportFiles.write([(PDFTools.named(doc.title, "locked") + ".pdf", bytes)])
            finish(PDFToolResult(title: "Locked copy is ready", detail: "Save it to Files, then share it. It isn't saved in your documents.", files: files, shareTitle: "Share locked PDF", inLibrary: false))
        }
    }
}

// MARK: - Redact personal info

/// Personal details found on a page by on-device text recognition.
enum Redaction {
    struct Box: Identifiable, Equatable {
        let id = UUID()
        /// Normalized to the page, origin top-left.
        var rect: CGRect
        var kind: String
        var on = true
    }
    /// The one mapping from a normalized box (origin top-left) to a frame on
    /// screen or on the page picture. The preview and the saved copy both use it.
    nonisolated static func place(_ r: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height,
               width: r.width * frame.width, height: r.height * frame.height)
    }
    /// Labels whose value is a personal number even without a known format
    /// ("Insurance member ID: RFC 4418 2209 7731"). Found boxes stay tappable.
    private static let memberLabel = #"\b(id|member|membership|policy|account|acct|customer|subscriber|patient)\b|계좌|회원번호|회원 번호|보험|고객번호|가입자|증권번호|환자번호"#
    private static let accountWords = ["account", "acct", "a/c", "bank", "transit", "routing", "iban", "swift", "계좌", "은행", "예금주", "입금"]
    private static let passportWords = ["passport", "여권"]
    private static let licenceWords = ["licence", "license", "driver", "운전면허", "면허번호"]
    /// Finds ID, card, account and phone numbers and emails on a rendered page.
    nonisolated static func detect(_ image: UIImage) throws -> [Box] {
        try readParts(image).flatMap { part in boxes(in: part.blocks, card: part.card).map { var b = $0; b.rect = part.place($0.rect); return b } }
    }
    /// The page's text as the finder sees it, placed on the page.
    nonisolated static func read(_ image: UIImage) throws -> [TextBlock] { try readParts(image).flatMap { part in part.blocks.map(part.place) } }
    /// `card`: the blocks are one licence, ID or residence card by itself.
    nonisolated static func boxes(in blocks: [TextBlock], card: Bool = false) -> [Box] {
        var boxes: [Box] = []
        for block in blocks {
            let text = block.text, ns = text as NSString
            let context = rowContext(block, in: blocks)
            // Character range of each recognized word inside the line.
            var wordRanges: [(NSRange, CGRect)] = []
            var cursor = 0
            for w in block.words ?? [] {
                let r = ns.range(of: w.text, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
                guard r.location != NSNotFound else { continue }
                wordRanges.append((r, CGRect(x: w.x, y: w.y, width: w.width, height: w.height))); cursor = r.location + r.length
            }
            let lineRect = CGRect(x: block.x, y: block.y, width: block.width, height: block.height)
            for (kind, range) in matches(text, context: context) {
                let hit = wordRanges.filter { NSIntersectionRange($0.0, range).length > 0 }.map(\.1)
                var rect = hit.isEmpty ? lineRect : hit.dropFirst().reduce(hit[0]) { $0.union($1) }
                if hit.isEmpty, ns.length > 0 {
                    // Estimate the span from character positions on the line.
                    let a = CGFloat(range.location) / CGFloat(ns.length), b = CGFloat(range.location + range.length) / CGFloat(ns.length)
                    rect = CGRect(x: lineRect.minX + lineRect.width * a, y: lineRect.minY, width: lineRect.width * (b - a), height: lineRect.height)
                }
                rect = rect.insetBy(dx: -0.004, dy: -0.003)
                if !boxes.contains(where: { $0.rect.intersects(rect) && $0.kind == kind }) { boxes.append(Box(rect: rect, kind: kind)) }
            }
        }
        // Names, birth dates and addresses on licences and ID cards.
        for (kind, found) in cardFields(blocks, card: card) {
            let rect = found.insetBy(dx: -max(0.004, found.height * 0.1), dy: -max(0.003, found.height * 0.15)), area = rect.width * rect.height
            if boxes.contains(where: { let i = $0.rect.intersection(rect); return !i.isNull && i.width * i.height >= 0.7 * area }) { continue }
            boxes.append(Box(rect: rect, kind: kind))
        }
        return boxes
    }
    /// Each recognized word's character range in its line, with its box.
    nonisolated static func wordRanges(_ block: TextBlock) -> [(NSRange, CGRect)] {
        let ns = block.text as NSString
        var out: [(NSRange, CGRect)] = [], cursor = 0
        for w in block.words ?? [] {
            let r = ns.range(of: w.text, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
            guard r.location != NSNotFound else { continue }
            out.append((r, CGRect(x: w.x, y: w.y, width: w.width, height: w.height))); cursor = r.location + r.length
        }
        return out
    }
    /// The line plus labels in the same row to its left ("Account number | 1234567").
    nonisolated static func rowContext(_ block: TextBlock, in blocks: [TextBlock]) -> String {
        let row = blocks.filter { other in
            other.x + other.width <= block.x + 0.01 && block.x - (other.x + other.width) < 0.45
                && min(other.y + other.height, block.y + block.height) - max(other.y, block.y) > 0.5 * min(other.height, block.height)
        }.sorted { $0.x < $1.x }.map(\.text)
        return (row + [block.text]).joined(separator: " ")
    }
    /// `context` is the line plus the labels beside it; it decides whether a bare
    /// number is an account, passport or licence number.
    /// Cyrillic letters Vision sometimes returns for Latin ones (М96261858). Same length, so ranges still match the line.
    nonisolated static func latinLookalikes(_ s: String) -> String {
        let map: [Character: Character] = ["А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X", "о": "o", "а": "a", "е": "e", "р": "p", "с": "c", "х": "x"]
        return String(s.map { map[$0] ?? $0 })
    }
    nonisolated static func matches(_ raw: String, context: String? = nil) -> [(String, NSRange)] {
        let text = latinLookalikes(raw)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let ctx = latinLookalikes(context ?? text).lowercased()
        var out: [(String, NSRange)] = []
        func add(_ kind: String, _ r: NSRange) { if !out.contains(where: { NSIntersectionRange($0.1, r).length > 0 }) { out.append((kind, r)) } }
        func regex(_ p: String, _ kind: String, caseless: Bool = true, _ ok: (String) -> Bool = { _ in true }) {
            guard let re = try? NSRegularExpression(pattern: p, options: caseless ? [.caseInsensitive] : []) else { return }
            for m in re.matches(in: text, range: full) where ok(ns.substring(with: m.range)) { add(kind, m.range) }
        }
        let hangul = text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
        regex(#"(?<!\d)\d{6}\s?-\s?[1-8]\d{6}(?!\d)"#, "ID number")                     // Korean resident / foreigner registration
        regex(#"(?<![\d-])\d{2}-\d{2}-\d{6}-\d{2}(?![\d-])"#, "ID number")               // Korean driver's licence
        if !hangul || ctx.contains("ssn") || ctx.contains("social") {
            regex(#"(?<![\d-])\d{3}-\d{2}-\d{4}(?![\d-])"#, "ID number") { ssn($0) }        // US SSN
            regex(#"(?<![\d-])\d{3}[ -]\d{3}[ -]\d{3}(?![\d-])"#, "ID number") { s in       // Canadian SIN
                luhn(s.filter(\.isNumber), lengths: 9...9) || ctx.contains("sin") || ctx.contains("social insurance")
            }
        }
        regex(#"(?<![\d+])(?:\d[ -]?){12,18}\d(?!\d)"#, "Card number") { s in let d = s.filter(\.isNumber); return luhn(d) && cardPrefix(d) }
        regex(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "Email")
        regex(#"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b"#, "Account number", caseless: false) { s in iban(s) || ctx.contains("iban") }
        if passportWords.contains(where: { ctx.contains($0) }) {
            regex(#"\b[A-Z]{1,2}\d{6,8}\b|\b[A-Z]\d{3}[A-Z]\d{4}\b"#, "ID number", caseless: false)
        }
        regex(#"\b[MSRODG]\d{8}\b|\b[MSRODG]\d{3}[A-Z]\d{4}\b"#, "ID number", caseless: false) // Korean passport
        if licenceWords.contains(where: { ctx.contains($0) }) || ctx.range(of: #"\bdl\b"#, options: .regularExpression) != nil {
            regex(#"\b[A-Z0-9][A-Z0-9-]{5,18}\d\b"#, "ID number") { s in s.filter(\.isNumber).count >= 6 && !s.contains("--") }
        }
        if accountWords.contains(where: { ctx.contains($0) }) {
            regex(#"(?<!\d)\d[\d -]{5,}\d(?!\d)"#, "Account number") { $0.filter(\.isNumber).count >= 7 }
        }
        for r in PhoneCheck.find(in: text, context: context) { add("Phone", r) }
        // A labelled value with at least four digits ("member ID: RFC 4418 2209 7731").
        if ctx.range(of: memberLabel, options: .regularExpression) != nil {
            regex(#"(?<![\w/.:-])(?:[A-Z]{1,4}[ -]?)?\d[\dA-Z -]*\d(?![\w/.:-])"#, "ID number", caseless: false) { s in
                let digits = s.filter(\.isNumber).count
                return digits >= 4 && !isDateOrAmount(s)
            }
        }
        return out
    }
    /// Dates, times, years and money are never personal numbers.
    nonisolated static func isDateOrAmount(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.range(of: #"^\d{1,4}[./-]\d{1,2}[./-]\d{1,4}$"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil { return true }
        return false
    }
    nonisolated static func luhn(_ digits: String, lengths: ClosedRange<Int> = 13...19) -> Bool {
        guard lengths.contains(digits.count) else { return false }
        var sum = 0
        for (i, c) in digits.reversed().enumerated() {
            var d = Int(String(c)) ?? 0
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
    /// Issuer prefixes and lengths of real payment cards (Visa, Mastercard, Amex,
    /// Discover, JCB, Diners, UnionPay and Korean domestic cards).
    nonisolated static func cardPrefix(_ d: String) -> Bool {
        let n = d.count
        func p(_ s: String) -> Bool { d.hasPrefix(s) }
        let two = Int(d.prefix(2)) ?? 0, four = Int(d.prefix(4)) ?? 0, three = Int(d.prefix(3)) ?? 0
        if p("4") { return [13, 16, 19].contains(n) }
        if (51...55).contains(two) || (2221...2720).contains(four) { return n == 16 }
        if p("34") || p("37") { return n == 15 }
        if p("6011") || p("65") || (644...649).contains(three) || p("62") { return (16...19).contains(n) }
        if (3528...3589).contains(four) { return (16...19).contains(n) }
        if p("36") || p("38") || (300...305).contains(three) { return n == 14 || n == 16 }
        if p("9") { return n == 16 }
        return false
    }
    nonisolated static func ssn(_ s: String) -> Bool {
        let d = s.filter(\.isNumber)
        guard d.count == 9 else { return false }
        let area = Int(d.prefix(3)) ?? 0, group = Int(d.dropFirst(3).prefix(2)) ?? 0, serial = Int(d.suffix(4)) ?? 0
        return area > 0 && area != 666 && area < 900 && group > 0 && serial > 0
    }
    nonisolated static func iban(_ s: String) -> Bool {
        let c = s.replacingOccurrences(of: " ", with: "")
        guard (15...34).contains(c.count) else { return false }
        let moved = c.dropFirst(4) + c.prefix(4)
        var rem = 0
        for ch in moved {
            guard let v = ch.isNumber ? Int(String(ch)) : (ch.asciiValue.map { Int($0) - 55 }) else { return false }
            for digit in String(v) { rem = (rem * 10 + Int(String(digit))!) % 97 }
        }
        return rem == 1
    }
    /// A new PDF of page pictures with the boxes filled solid black. No text layer
    /// is kept, so hidden details can't be copied or searched back out.
    nonisolated static func apply(_ url: URL, boxes: [Int: [CGRect]], pageCount: Int) throws -> Data {
        guard let source = CGPDFDocument(url as CFURL) else { throw ScannerError.message("This PDF can't be opened.") }
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData), let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ScannerError.message("The redacted PDF couldn't be made.") }
        for i in 0..<pageCount {
            try autoreleasepool {
                guard let page = source.page(at: i + 1) else { return }
                let box = page.getBoxRect(.cropBox)
                let turned = abs(page.rotationAngle) % 180 == 90
                var media = CGRect(origin: .zero, size: turned ? CGSize(width: box.height, height: box.width) : box.size)
                let image = try ExtractRender.page(url, index: i, maxSide: 2200)
                let redacted = UIGraphicsImageRenderer(size: image.size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true; return f }()).image { c in
                    image.draw(at: .zero)
                    UIColor.black.setFill()
                    for r in boxes[i] ?? [] { c.fill(place(r, in: CGRect(origin: .zero, size: image.size))) }
                }
                guard let jpeg = redacted.jpegData(compressionQuality: 0.85), let provider = CGDataProvider(data: jpeg as CFData),
                      let cg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ScannerError.message("The redacted PDF couldn't be made.") }
                pdf.beginPage(mediaBox: &media)
                pdf.draw(cg, in: media)
                pdf.endPage()
            }
        }
        pdf.closePDF()
        return out as Data
    }
}

// MARK: - Licences, ID and residence cards

extension Redaction {
    /// Text read from one part of a page: the whole page, or one card lying on it.
    /// Blocks are normalized to `frame`; `frame` is normalized to the page.
    struct Part {
        var blocks: [TextBlock]
        var frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        /// A card on its own (licence, ID or residence card): names, birth dates and addresses are hidden too.
        var card = false
        func place(_ r: CGRect) -> CGRect {
            CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height, width: r.width * frame.width, height: r.height * frame.height)
        }
        func place(_ b: TextBlock) -> TextBlock {
            var o = b
            let r = place(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
            o.x = Double(r.minX); o.y = Double(r.minY); o.width = Double(r.width); o.height = Double(r.height)
            o.words = b.words?.map { w in
                let q = place(CGRect(x: w.x, y: w.y, width: w.width, height: w.height))
                return TextWord(text: w.text, x: Double(q.minX), y: Double(q.minY), width: Double(q.width), height: Double(q.height))
            }
            return o
        }
    }

    /// Reads the page. Cards lying on a page (a licence scanned front and back) are cut out and
    /// read up close; small pictures are enlarged first so short lines aren't missed.
    nonisolated static func readParts(_ image: UIImage) throws -> [Part] {
        guard let cg = image.cgImage else { return [Part(blocks: try Imaging.recognize(image))] }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let layout = cardLayout(cg)
        if layout.cards.isEmpty { return [Part(blocks: try recognizeClose(cg), card: cardShaped(W / max(1, H)))] }
        var parts: [Part] = []
        for r in layout.cards {
            let px = CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H).integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard px.width > 8, px.height > 8, let crop = cg.cropping(to: px) else { continue }
            parts.append(Part(blocks: try recognizeClose(crop), frame: CGRect(x: px.minX / W, y: px.minY / H, width: px.width / W, height: px.height / H), card: true))
        }
        if layout.other || parts.isEmpty {
            // Writing elsewhere on the page keeps the ordinary rules.
            let frames = parts.map(\.frame)
            let rest = try TextRecognition.recognize(cg).filter { b in !frames.contains { $0.contains(CGPoint(x: b.x + b.width / 2, y: b.y + b.height / 2)) } }
            parts.append(Part(blocks: rest))
        }
        return parts
    }
    /// Vision skips lines only a few pixels tall, so small pictures are enlarged before reading.
    nonisolated static func recognizeClose(_ cg: CGImage) throws -> [TextBlock] {
        let long = CGFloat(max(cg.width, cg.height))
        guard long > 0, long < 1600, let big = enlarged(cg, by: min(3, 2000 / long)) else { return try TextRecognition.recognize(cg) }
        return try TextRecognition.recognize(big)
    }
    nonisolated static func enlarged(_ cg: CGImage, by s: CGFloat) -> CGImage? {
        let w = Int(CGFloat(cg.width) * s), h = Int(CGFloat(cg.height) * s)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
    /// A picture that is one card lying flat: ID-1 cards are 1.586:1, residence cards a little squarer.
    /// A4 (1.41) and Letter (1.29) pages fall outside, and so do upright pictures.
    nonisolated static func cardShaped(_ aspect: CGFloat) -> Bool { (1.45...1.75).contains(aspect) }
    /// Cards lying on a mostly blank page, found on a small grey copy as solid, card-shaped patches.
    /// `other` is true when something else is on the page too.
    nonisolated static func cardLayout(_ cg: CGImage) -> (cards: [CGRect], other: Bool) {
        let W = 160, H = Int((CGFloat(cg.height) / CGFloat(max(1, cg.width)) * 160).rounded())
        guard (60...480).contains(H) else { return ([], true) }
        var px = [UInt8](repeating: 255, count: W * H)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard drawn else { return ([], true) }
        var border: [Int] = []
        for x in 0..<W { border.append(Int(px[x])); border.append(Int(px[(H - 1) * W + x])) }
        for y in 0..<H { border.append(Int(px[y * W])); border.append(Int(px[y * W + W - 1])) }
        border.sort()
        let paper = border[border.count / 2]
        let ink = px.map { abs(Int($0) - paper) > 12 }
        var grown = ink
        for y in 0..<H {
            for x in 0..<W where ink[y * W + x] {
                for yy in max(0, y - 2)...min(H - 1, y + 2) { for xx in max(0, x - 2)...min(W - 1, x + 2) { grown[yy * W + xx] = true } }
            }
        }
        var seen = [Bool](repeating: false, count: W * H)
        var cards: [CGRect] = [], other = false
        for start in 0..<(W * H) where grown[start] && !seen[start] {
            var stack = [start]; seen[start] = true
            var x0 = W, x1 = 0, y0 = H, y1 = 0
            while let p = stack.popLast() {
                let x = p % W, y = p / W
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                var next: [Int] = []
                if y > 0 { next.append(p - W) }
                if y < H - 1 { next.append(p + W) }
                if x > 0 { next.append(p - 1) }
                if x < W - 1 { next.append(p + 1) }
                for q in next where grown[q] && !seen[q] { seen[q] = true; stack.append(q) }
            }
            let w = x1 - x0 + 1, h = y1 - y0 + 1
            var filled = 0
            for y in y0...y1 { for x in x0...x1 where ink[y * W + x] { filled += 1 } }
            let r = CGRect(x: CGFloat(x0) / CGFloat(W), y: CGFloat(y0) / CGFloat(H), width: CGFloat(w) / CGFloat(W), height: CGFloat(h) / CGFloat(H))
            let area = r.width * r.height, aspect = CGFloat(w) / CGFloat(h), fill = CGFloat(filled) / CGFloat(w * h)
            if r.width >= 0.2, (0.6...2.1).contains(aspect), fill >= 0.5, (0.03...0.6).contains(area) { cards.append(r) }
            else if area >= 0.002 { other = true }
        }
        return (cards, other)
    }

    // MARK: Fields on a card

    private enum IDRx {
        static func make(_ p: String, _ caseless: Bool = false) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: caseless ? [.caseInsensitive] : [])
        }
        static let cjkLabels: [(String, NSRegularExpression)] = [
            ("name", make(#"^\s*(?:氏\s*名|姓\s*名|성\s*명|이\s*름)"#)),
            ("dob", make(#"^\s*(?:出\s*生(?:日期)?|生年月日|생년월일)"#)),
            ("address", make(#"^\s*(?:住\s*所|住\s*址|주\s*소)"#)),
            ("number", make(#"^\s*(?:公民身份号码|证件号码|番\s*号|면허번호|주민번호|주민등록번호|個人番号)"#)),
            ("other", make(#"^\s*(?:性\s*别|性別|民\s*族|交\s*付|有効|签发机关|有效期限|国籍|조건|적성검사|발급)"#)),
        ]
        static let lead = make(#"^[\s\-*.]*(?:\d{1,2}[a-z]?[.,:]?\s*)?"#)
        static let gluedLow = make(#"^(ln|fn)(?=[a-z]{2,})"#)
        static let gluedCaps = make(#"^\s*(?:\d{1,2}\s*)?(LN|FN)[A-Z]"#)
        static let words = make(#"[a-z]+|\d+"#)
        static let twoDigits = make(#"\d{2,}"#)
        static let separators = make(#"^[\s:#./!|\-]*"#)
        static let mrzLine = make(#"^[A-Z0-9<]{25,}$"#)
        static let token = make(#"(?<![\w/])[A-Z0-9][A-Z0-9\-]{5,22}[A-Z0-9](?![\w/])"#)
        static let shortDate = make(#"^\d{1,4}[./\-]\d{1,2}[./\-]\d{1,4}$"#)
        static let spaced = make(#"(?<!\d)\d{3,4}(?: \d{3,4}){2,3}(?!\d)"#)
        static let numberPiece = make(#"^[\d\s\-]{3,}$"#)
        static let aamva = make(#"^\s*(1|2|8)\s?([A-Z][A-Z' ,.\-]+|\d+ .+)$"#)
        static let street = make(#"^(?:\d{1,2}[:.]\s?)?\d+\s+[A-Z0-9][A-Z0-9 .'-]*\b(ST|STREET|AVE|AVENUE|RD|ROAD|DR|DRIVE|BLVD|WAY|LN|LANE|CT|CRES|PL|HWY)\b"#)
        static let postal = make(#"\b[A-Z]{2}\s+\d{5}(-\d{4})?\b|\b[A-Z]\d[A-Z]\s?\d[A-Z]\d\b"#)
        static let cjkAddress = make(#"[都道府県市区町村省县路街]\S*\d|[시도구군]\s\S+[로길동]\s?\d|\d+\s?동\s?\d+\s?호|[室座栋幢]$|号楼|单元|아파트"#)
        static let rrn = make(#"\d{6}-[1-8]\d{6}"#)
        static let rrnLoose = make(#"\d{6}-\d{7}"#)
        static let hangulName = make(#"[가-힣]{2,4}"#)
        static let capsLine = make(#"^[A-Z][A-Z'.\-]*(?:,?\s+[A-Z][A-Z'.\-]*){0,3},?$"#)
        static let bornSuffix = make(#"\d\s*日\s*生$"#)
        static let ymd = make(#"(?<!\d)(19\d\d|20\d\d)\s?[./\- 年]\s?(\d{1,2})\s?[./\- 月]\s?(\d{1,2})日?(?!\d)"#)
        static let mdy = make(#"(?<!\d)(\d{1,2})[./\-](\d{1,2})[./\-](19\d\d|20\d\d)(?!\d)"#)
        static let yMonD = make(#"(?<!\d)(19\d\d|20\d\d)[\s./\-]([A-Za-z]{3})[A-Za-z]*\.?[\s./\-](\d{1,2})(?!\d)"#)
        static let ymdMisread = make(#"(?<!\d)(19\d\d|20\d\d)[./\-](\d{2})[71](\d{2})(?!\d)"#)
        static let dMonY = make(#"(?<!\d)(\d{1,2})\s*([A-Za-z]{3})[A-Za-zÀ-ÿ]*\.?\s*(?:/\s*[A-Za-zÀ-ÿ]{3,5}\.?)?[\s:,]*((?:19|20)?\d\d)(?!\d)"#)
        static let era = make(#"(明治|大正|昭和|平成|令和)\s*(\d{1,2}|元)\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日\s*生?"#)
    }
    /// Words printed on licences, ID and residence cards in the five markets we test against.
    private static let idWords = ["driver", "licence", "license", "permis", "identification", "identity", "id card", "passport", "passeport", "dln",
                                  "date of birth", "naissance", "resident", "citizenship", "status", "services card", "photo card", "health number",
                                  "주민등록", "운전면허", "면허", "運転免許", "個人番号", "マイナンバー", "公安委員会", "免許", "有効", "身份", "居民", "居留", "在留", "证件", "签发", "外国人"]
    /// Label words, with what the value next to them is.
    /// Labels of numbers that identify a business document, not a person (see `businessRow`).
    private static let businessWords: Set<String> = Set(("order invoice inv isbn issn policy pol reference ref tracking receipt transaction txn booking " +
        "confirmation ticket case claim serial model sku item po purchase business gst hst vat tax postal zip postcode shipment waybill " +
        "commande facture rechnung bestellung pedido fattura ordine").split(separator: " ").map(String.init))
    private static let businessWordsCJK = ["주문", "접수", "사업자", "송장", "운송장", "영수증", "거래", "승인번호", "우편번호", "청구번호", "문서번호", "관리번호",
                                           "注文", "請求", "受付", "伝票", "郵便番号", "订单", "发票", "单号", "邮编", "訂單", "發票", "郵遞區號"]
    private static let labelWords: [String: String] = {
        var v: [String: String] = [:]
        for w in "name names nom noms surname surnames given family famille prenom prenoms alias emprunt last first lastname firstname".split(separator: " ") { v[String(w)] = "name" }
        for w in "birth naissance dob ddn born birthdate".split(separator: " ") { v[String(w)] = "dob" }
        for w in "address adresse addr domicile".split(separator: " ") { v[String(w)] = "address" }
        for w in "number numero dln dl lic passport passeport registration inscription phn sin ssn".split(separator: " ") { v[String(w)] = "number" }
        for w in "of de date d du la the and et no n id le full personal health social insurance security".split(separator: " ") { v[String(w)] = "filler" }
        for w in ("place lieu issue issued delivrance expiry expiration expires exp iss nationality nationalite sex sexe authority autorite height hgt eyes yeux " +
                  "hair weight wgt class classe restrictions endorsements type country pays issuing emetteur band group groupe registre conditions donor veteran signature taille").split(separator: " ") { v[String(w)] = "other" }
        return v
    }()
    /// Card words that are never a person's name.
    private static let cardWords: Set<String> = Set(("driver drivers driver's licence license permis conduire canada ontario british columbia california washington " +
        "massachusetts usa can passport passeport photo card carte permanent resident resident's residente government gouvernement of du de the et and class none " +
        "end rest restrictions endorsements sex eyes hair hgt wgt brn blk blu donor veteran enhanced real id dl exp iss dd nationality canadian canadienne brown " +
        "blue black green hazel people's republic china foreign issued national immigration administration certificate status indian citizenship citoyennete " +
        "affairs northern services identification health province state department motor vehicles transport ministry new york texas florida korea japan " +
        "corrected lenses required organ category categorie categories golden star cardholder's signature apt duplicate temporary valid until").split(separator: " ").map(String.init))
    private static let gluedLabels: [(String, [String])] = [("name", ["name", "nom"]), ("dob", ["dobddn", "birth", "naissance"]), ("address", ["address", "adresse"]), ("number", ["number", "numero"])]
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let eras: [String: Int] = ["明治": 1867, "大正": 1911, "昭和": 1925, "平成": 1988, "令和": 2018]

    nonisolated static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased() }
    private nonisolated static func digits(_ s: String) -> Int { s.unicodeScalars.filter { $0.properties.generalCategory == .decimalNumber }.count }
    private nonisolated static func alnum(_ s: String) -> Int { s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count }
    private nonisolated static func letters(_ s: String) -> Int { s.unicodeScalars.filter { $0.properties.isAlphabetic && $0.properties.generalCategory != .decimalNumber }.count }
    private nonisolated static func full(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }
    private nonisolated static func has(_ rx: NSRegularExpression, _ s: String) -> Bool { rx.firstMatch(in: s, range: full(s)) != nil }

    private nonisolated static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if abs(a.count - b.count) > 2 { return 3 }
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var cur = [i + 1]
            for (j, cb) in b.enumerated() { cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1))) }
            prev = cur
        }
        return prev[b.count]
    }
    /// What a label word stands for, allowing a letter or two misread ("Nares" for "Names").
    private nonisolated static func labelRole(_ word: String) -> String? {
        if let r = labelWords[word] { return r }
        guard word.count >= 4 else { return nil }
        let w = Array(word)
        var best: (Int, String)?
        for (v, r) in labelWords where v.count >= 4 {
            let d = distance(w, Array(v))
            if d <= (v.count <= 6 ? 1 : 2), best == nil || d < best!.0 { best = (d, r) }
        }
        return best?.1
    }
    private nonisolated static func pickRole(_ roles: [String]) -> String {
        if roles.contains("other") { return "other" }
        for k in ["dob", "name", "address"] where roles.contains(k) { return k }
        return "number"
    }
    /// A field label at the start of a line: what its value is, where the label ends,
    /// and whether the line is only the label (the value is beside or under it).
    nonisolated static func idLabel(_ text: String) -> (kind: String, end: Int, only: Bool)? {
        let ns = text as NSString, n = ns.length
        for (kind, rx) in IDRx.cjkLabels {
            if let m = rx.firstMatch(in: text, range: full(text)) {
                return (kind, m.range.upperBound, alnum(ns.substring(from: m.range.upperBound)) < 2)
            }
        }
        let f = fold(text), fs = f as NSString
        let start = IDRx.lead.firstMatch(in: f, range: full(f))?.range.upperBound ?? 0
        let body = fs.substring(from: min(start, fs.length))
        if has(IDRx.gluedLow, body), has(IDRx.gluedCaps, text) { return ("name", min(n, start + 2), false) }
        let words = IDRx.words.matches(in: body, range: full(body)).map { (w: (body as NSString).substring(with: $0.range), end: $0.range.upperBound + start) }
        guard !words.isEmpty else { return nil }
        if !has(IDRx.twoDigits, body) {
            let alpha = words.map(\.w).filter { digits($0) == 0 }
            let roles = alpha.map(labelRole)
            let known = roles.compactMap { $0 }, strong = known.filter { $0 != "filler" }
            if !strong.isEmpty, known.count * 2 >= roles.count, roles.count <= 7 { return (pickRole(strong), n, true) }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if strong.isEmpty, trimmed.count <= 12, alpha.contains(where: { $0 == "no" || $0 == "id" }), known.count * 2 >= roles.count { return ("number", n, true) }
            let plain = body.filter { $0 >= "a" && $0 <= "z" }
            if (3...12).contains(plain.count) {
                for (kind, keys) in gluedLabels where keys.contains(where: { plain.contains($0) }) { return (kind, n, true) }
            }
            return nil
        }
        var roles: [String] = [], end = 0
        for w in words {
            if digits(w.w) > 0 { break }
            guard let r = labelRole(w.w) else { break }
            roles.append(r); end = w.end
        }
        let strong = roles.filter { $0 != "filler" }
        guard !strong.isEmpty else { return nil }
        end = min(end, n)
        let after = ns.substring(from: end)
        end += IDRx.separators.firstMatch(in: after, range: full(after))?.range.length ?? 0
        return (pickRole(strong), end, alnum(ns.substring(from: min(end, n))) < 2)
    }
    private nonisolated static func plausible(_ kind: String, _ text: String) -> Bool {
        let d = digits(text)
        switch kind {
        case "number": return d >= 4
        case "dob": return d >= 1
        case "name": return d <= 1 && letters(text) >= 2
        default: return text.trimmingCharacters(in: .whitespaces).count >= 3
        }
    }
    /// A line that is just a name in capitals ("ALEX JORDAN", "SAMPLE,").
    nonisolated static func capsName(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard has(IDRx.capsLine, t) else { return false }
        let words = t.components(separatedBy: CharacterSet(charactersIn: " ,")).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.'-")) }.filter { !$0.isEmpty }
        guard !words.isEmpty, words.reduce(0, { $0 + $1.count }) >= 3, words.contains(where: { $0.count > 2 }) else { return false }
        if words.contains(where: { cardWords.contains(fold($0)) }) { return false }
        return !(words.count == 1 && words[0].count > 14)
    }
    /// Dates on a line with their year.
    nonisolated static func dates(_ text: String) -> [(year: Int, range: NSRange)] {
        let ns = text as NSString
        func int(_ m: NSTextCheckingResult, _ i: Int) -> Int { Int(ns.substring(with: m.range(at: i))) ?? 0 }
        func day(_ month: Int, _ day: Int) -> Bool { (1...12).contains(month) && (1...31).contains(day) }
        var out: [(Int, NSRange)] = []
        for m in IDRx.ymd.matches(in: text, range: full(text)) where day(int(m, 2), int(m, 3)) { out.append((int(m, 1), m.range)) }
        // "1972/11720": the second slash read as a 7 or 1.
        for m in IDRx.ymdMisread.matches(in: text, range: full(text)) where day(int(m, 2), int(m, 3)) { out.append((int(m, 1), m.range)) }
        for m in IDRx.yMonD.matches(in: text, range: full(text)) where months.contains(fold(ns.substring(with: m.range(at: 2)))) && (1...31).contains(int(m, 3)) { out.append((int(m, 1), m.range)) }
        for m in IDRx.mdy.matches(in: text, range: full(text)) where day(int(m, 1), int(m, 2)) || day(int(m, 2), int(m, 1)) { out.append((int(m, 3), m.range)) }
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        for m in IDRx.dMonY.matches(in: text, range: full(text)) where months.contains(fold(ns.substring(with: m.range(at: 2)))) && (1...31).contains(int(m, 1)) {
            var y = int(m, 3)
            if y < 100 { y += y > thisYear - 2000 ? 1900 : 2000 }
            out.append((y, m.range))
        }
        for m in IDRx.era.matches(in: text, range: full(text)) where day(int(m, 3), int(m, 4)) {
            let n = ns.substring(with: m.range(at: 2)) == "元" ? 1 : int(m, 2)
            if n >= 1 { out.append(((eras[ns.substring(with: m.range(at: 1))] ?? 0) + n, m.range)) }
        }
        return out
    }
    private nonisolated static func compactDate(_ s: String) -> Bool {
        guard s.count == 8, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        let n = s.compactMap { $0.wholeNumberValue }
        let a = n[0] * 1000 + n[1] * 100 + n[2] * 10 + n[3], b = n[4] * 10 + n[5], c = n[6] * 10 + n[7]
        if (1900...2100).contains(a), (1...12).contains(b), (1...31).contains(c) { return true }
        let m = n[0] * 10 + n[1], d = n[2] * 10 + n[3], y = n[4] * 1000 + n[5] * 100 + n[6] * 10 + n[7]
        return (1...31).contains(m) && (1...31).contains(d) && (1900...2100).contains(y)
    }

    /// Names, birth dates, addresses and card numbers on a licence, ID or residence card.
    /// Runs when the part is a card on its own, or its text reads like one.
    nonisolated static func cardFields(_ blocks: [TextBlock], card: Bool) -> [(String, CGRect)] {
        let all = blocks.map(\.text).joined(separator: " ")
        let lowered = all.lowercased(), folded = fold(all)
        func marks(_ t: String) -> Int { t.filter { $0 == "<" || $0 == "＜" || $0 == "く" }.count }
        let mrz = blocks.contains { marks($0.text) >= 3 }
        let infos = blocks.map { idLabel($0.text) }
        let kinds = Set(infos.compactMap { $0?.kind }.filter { $0 != "other" })
        let keyword = idWords.contains { lowered.contains($0) || folded.contains($0) }
        let strong = card || mrz || has(IDRx.rrn, all) || (keyword && !kinds.isEmpty)
        guard strong || kinds.count >= 2 else { return [] }
        let names = ["name": "Name", "dob": "Date of birth", "address": "Address", "number": "ID number"]
        var out: [(String, CGRect)] = []
        var used = Set<Int>()
        func rect(_ b: TextBlock) -> CGRect { CGRect(x: b.x, y: b.y, width: b.width, height: b.height) }
        func span(_ b: TextBlock, _ lo: Int, _ hi: Int) -> CGRect {
            let n = Double(max(1, (b.text as NSString).length))
            let a = max(0, Double(lo) - 1), z = min(n, Double(hi) + 1)
            let guess = CGRect(x: b.x + b.width * a / n, y: b.y, width: b.width * (z - a) / n, height: b.height)
            // Proportional guesses drift on mixed-width text; the words it touches keep it honest.
            let range = NSRange(location: lo, length: max(0, hi - lo))
            return wordRanges(b).filter { NSIntersectionRange($0.0, range).length > 0 }.reduce(guess) { $0.union($1.1) }
        }
        func overlapY(_ a: TextBlock, _ b: TextBlock) -> Double { min(a.y + a.height, b.y + b.height) - max(a.y, b.y) }
        /// On an ordinary page (not a card) a number labelled as an order, invoice, reference,
        /// tracking or business number, or a postal code on its own, is not about the person:
        /// the label in the same line or just left of it on the row says so.
        func businessRow(_ j: Int) -> Bool {
            guard !card else { return false }
            let b = blocks[j]
            let row = blocks.indices.filter { k in
                let c = blocks[k]
                return k == j || (c.x + c.width <= b.x + 0.02 && b.x - (c.x + c.width) < 0.4 && overlapY(b, c) > 0.4 * min(b.height, c.height))
            }
            return row.contains { k in
                let f = fold(blocks[k].text)
                if businessWordsCJK.contains(where: { f.contains($0) }) { return true }
                return IDRx.words.matches(in: f, range: full(f)).contains { m in businessWords.contains((f as NSString).substring(with: m.range)) }
            }
        }
        func isLabel(_ j: Int) -> Bool { infos[j]?.only == true }
        func add(_ j: Int, _ kind: String) { out.append((names[kind] ?? kind, rect(blocks[j]))); used.insert(j) }
        /// Address lines that run on under block `j`; stops at the first line that is a label or a date.
        func continuation(_ j: Int, anchor: Double) {
            var last = blocks[j]
            for _ in 0..<2 {
                let next = blocks.indices.filter { k in
                    let d = blocks[k], gap = d.y - (last.y + last.height)
                    return k != j && d.y > last.y && gap >= -0.5 * d.height && gap < 1.2 * max(d.height, last.height) && abs(d.x - anchor) < 0.15 && d.x < last.x + last.width
                }.min { blocks[$0].y < blocks[$1].y }
                guard let k = next, infos[k] == nil, dates(blocks[k].text).isEmpty else { break }
                add(k, "address"); last = blocks[k]
            }
        }
        for (i, b) in blocks.enumerated() {
            let t = b.text, ns = t as NSString, n = ns.length
            // Machine-readable lines on passports and residence cards.
            if marks(t) >= 3 || (has(IDRx.mrzLine, t.replacingOccurrences(of: " ", with: "")) && digits(t) >= 8) { add(i, "number"); continue }
            let label = infos[i]
            if let label, label.kind != "other", !(label.kind == "number" && businessRow(i)) {
                let kind = label.kind
                if !label.only {
                    let value = ns.substring(from: min(label.end, n))
                    if plausible(kind, value) {
                        out.append((names[kind]!, span(b, label.end, n))); used.insert(i)
                        if kind == "address" { continuation(i, anchor: b.x + b.width * Double(label.end) / Double(max(1, n))) }
                    }
                } else {
                    // The value to the right on the same row…
                    let row = blocks.indices.filter { j in
                        let c = blocks[j]
                        return j != i && c.x >= b.x + b.width - 0.02 && c.x - (b.x + b.width) < 0.35 && overlapY(b, c) > 0.4 * min(c.height, b.height) && !isLabel(j)
                    }.sorted { blocks[$0].x < blocks[$1].x }
                    var got: Int?, before: [Int] = []
                    for j in row {
                        if plausible(kind, blocks[j].text) { got = j; break }
                        if blocks[j].text.trimmingCharacters(in: .whitespaces).count <= 2 { before.append(j); continue }
                        break
                    }
                    if let got {
                        for j in before { add(j, kind) }
                        add(got, kind)
                        // Values split in pieces: 石見 + 修, 第 + 600800101440 + 号, 1234 + 5678 9012.
                        var c = blocks[got]
                        let rest = blocks.indices.filter { k in k != i && blocks[k].x > blocks[got].x && overlapY(blocks[got], blocks[k]) > 0.4 * min(blocks[got].height, blocks[k].height) && !isLabel(k) }
                            .sorted { blocks[$0].x < blocks[$1].x }
                        for k in rest where !used.contains(k) && blocks[k].x > c.x {
                            let d = blocks[k]
                            let piece = d.text.trimmingCharacters(in: .whitespaces).count <= 2
                                || (kind == "name" && plausible(kind, d.text) && c.text.count <= 3)
                                || (kind == "number" && has(IDRx.numberPiece, d.text))
                            guard d.x - (c.x + c.width) < 0.12, piece else { break }
                            add(k, kind); c = d
                        }
                        if kind == "address" { continuation(got, anchor: blocks[got].x) }
                    } else {
                        // …or the line or two under it.
                        let bottom = b.y + b.height
                        let below = blocks.indices.filter { j in
                            let c = blocks[j], gap = c.y - bottom
                            return j != i && gap >= -0.5 * b.height && gap < 2 * max(b.height, c.height) && c.x >= b.x - 0.05 && c.x < b.x + b.width
                        }.sorted { blocks[$0].y < blocks[$1].y }
                        let take = kind == "name" || kind == "address" ? 2 : 1
                        var last = b, taken = 0
                        for j in below {
                            let c = blocks[j]
                            if taken >= take || isLabel(j) || !plausible(kind, c.text) { break }
                            if taken > 0, c.y - (last.y + last.height) > max(c.height, last.height) { break }
                            add(j, kind); last = c; taken += 1
                        }
                    }
                }
            }
            if strong {
                // Licence and document numbers: long letter-digit runs that aren't dates.
                for m in IDRx.token.matches(in: t, range: full(t)) {
                    let s = ns.substring(with: m.range)
                    if m.range.location > 0, ns.substring(with: NSRange(location: m.range.location - 1, length: 1)) == "*" { continue }
                    if digits(s) >= 5, s.filter({ $0 != "-" }).count <= 18, !has(IDRx.shortDate, s), !compactDate(s), !businessRow(i) { out.append(("ID number", span(b, m.range.location, m.range.upperBound))) }
                }
            }
            for m in IDRx.spaced.matches(in: t, range: full(t)) { out.append(("ID number", span(b, m.range.location, m.range.upperBound))) }
            // US and Canadian licences number their fields: 1 family name, 2 given names, 8 address.
            if label == nil, let m = IDRx.aamva.firstMatch(in: t, range: full(t)) {
                let field = ns.substring(with: m.range(at: 1))
                out.append((field == "8" ? "Address" : "Name", span(b, m.range(at: 2).location, n)))
                if field == "8" { continuation(i, anchor: b.x) }
            }
            if has(IDRx.street, t.uppercased()) { add(i, "address"); continuation(i, anchor: b.x) }
            if has(IDRx.postal, t.uppercased()), !businessRow(i) { add(i, "address") }
            if has(IDRx.cjkAddress, t) { add(i, "address") }
            // Korean resident cards: the name sits right above the registration number.
            if has(IDRx.rrnLoose, t) {
                for (k, d) in blocks.enumerated() where b.y - (d.y + d.height) >= 0 && b.y - (d.y + d.height) < 1.5 * b.height && abs(d.x - b.x) < 0.05 && has(IDRx.hangulName, d.text) { add(k, "name") }
            }
            if strong, label == nil, b.width > b.height, capsName(t) { add(i, "name") }
            // Numbers printed sideways along the edge (ghost licence number or birth date).
            if strong, b.height > 3 * b.width, digits(t) >= 6 { add(i, "number") }
            if has(IDRx.bornSuffix, t) { add(i, "dob") }
        }
        // The date of birth is the earliest date on the card. A date can be split over two or three blocks on a row.
        if strong {
            var found: [(year: Int, blocks: [Int], range: NSRange?)] = []
            for (i, b) in blocks.enumerated() {
                found += dates(b.text).map { ($0.year, [i], $0.range) }
                var chain = [i], text = b.text
                for _ in 0..<2 {
                    let last = blocks[chain.last!]
                    let next = blocks.indices.filter { k in
                        let gap = blocks[k].x - (last.x + last.width)
                        return !chain.contains(k) && gap >= 0 && gap < 0.06 && overlapY(last, blocks[k]) > 0.5 * min(last.height, blocks[k].height)
                    }.min { blocks[$0].x < blocks[$1].x }
                    guard let k = next else { break }
                    let head = (text as NSString).length
                    text += " " + blocks[k].text
                    for d in dates(text) where d.range.upperBound > head + 1 && d.range.location < head { found.append((d.year, chain + [k], nil)) }
                    chain.append(k)
                }
            }
            let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())
            if let first = found.map(\.year).min(), first <= thisYear - 12 {
                for d in found where d.year == first {
                    if let r = d.range { out.append(("Date of birth", span(blocks[d.blocks[0]], r.location, r.upperBound))) } else { for k in d.blocks { add(k, "dob") } }
                }
            }
        }
        return out
    }
}

/// Finds personal details in a saved document, lets the person check each box,
/// then saves a copy with them blacked out for good.
struct RedactTool: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var subscription: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var work = ToolWork()
    @State private var step = 0
    @State private var forward = true
    @State private var doc: ScanDocument?
    @State private var boxes: [Int: [Redaction.Box]] = [:]
    @State private var page = 0
    @State private var image: UIImage?
    @State private var draft: CGRect?
    @State private var result: PDFToolResult?
    @State private var paywall = false
    @State private var scanning = false
    @State private var importing = false
    /// The box being edited: corner handles resize it, and the bar above the page shows or deletes it.
    @State private var selectedBox: UUID?
    /// A box's place when a move or resize began.
    @State private var boxOrigin: CGRect?
    @State private var history: [[Int: [Redaction.Box]]] = []
    private var documents: [ScanDocument] { store.active.filter { $0.pdfFile != nil } }
    private var total: Int { boxes.values.reduce(0) { $0 + $1.filter(\.on).count } }
    var body: some View {
        StepStack(step: step, forward: forward) {
            if step == 0 { choosePage }
            else if step == 1 { editPage }
            else if let result { PDFToolDone(result: result, proTool: true) { dismiss() } }
        }
        .stepChrome(step: $step, forward: $forward, last: 2, work: work)
        .sheet(isPresented: $paywall) { PaywallView() }
        .fullScreenCover(isPresented: $scanning) {
            ToolScanCamera { draft in
                guard let draft else { return }
                work.run("Saving your scan…") { openNew(try await ToolScanCamera.save(draft, store: store)) }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { response in
            guard case .success(let url) = response else { return }
            work.run("Adding your PDF…") { openNew(try await store.importNativePDF(url)) }
        }
    }
    private var choosePage: some View {
        ToolPage(title: "Hide personal info", subtitle: "ID, card and account numbers, phone numbers and emails are found and blacked out in a new copy.") {
            ToolHero(art: .redact)
            // Like the other PDF tools: scan a page now, or bring a PDF from Files.
            VStack(alignment: .leading, spacing: 4) {
                Button { scanning = true } label: {
                    ChoiceRow(symbol: "camera.fill", title: "Scan with the camera", detail: "Saved as a new PDF, then opened here", tint: TK.blue, soft: TK.blueSoft)
                }.buttonStyle(.plain).accessibilityIdentifier("redact-scan")
                Button { importing = true } label: {
                    ChoiceRow(symbol: "folder.fill", title: "Choose a PDF from Files", detail: "It's added to your documents", tint: TK.orange, soft: TK.orangeSoft)
                }.buttonStyle(.plain).accessibilityIdentifier("redact-import")
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "From your documents")
                if documents.isEmpty { Text("No saved documents yet. Scan or import one first.").foregroundStyle(TK.grey500) }
                else { DocumentChoiceList(documents: documents) { start($0) } }
            }
            if let message = work.message { ToastMessage(text: message) }
            Label("Found on this iPhone. Nothing is uploaded.", systemImage: "lock.shield").font(.system(size: 13)).foregroundStyle(TK.grey500)
        } actions: { EmptyView() }
    }
    private var editPage: some View {
        ToolPage(title: total == 0 ? "Nothing found yet" : total == 1 ? "1 item to hide" : "\(total) items to hide",
                 subtitle: "Drag on the page to add a black box. Tap a box to move it, resize it from its corners, show it or delete it.", scrolls: false) {
            if let doc, doc.pages.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(doc.pages.indices, id: \.self) { i in
                            let n = boxes[i]?.filter(\.on).count ?? 0
                            Button("Page \(i + 1)" + (n > 0 ? " · \(n)" : "")) { show(i) }.buttonStyle(ChipStyle(selected: page == i))
                        }
                    }
                }
            }
            if let image {
                editBar
                GeometryReader { geo in
                    let fit = FitRect.rect(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height).position(x: fit.midX, y: fit.midY)
                        ForEach(boxes[page] ?? []) { box in
                            let r = Redaction.place(box.rect, in: fit)
                            let chosen = box.id == selectedBox
                            Group {
                                if box.on { Rectangle().fill(.black) }
                                else { Rectangle().strokeBorder(TK.red, style: StrokeStyle(lineWidth: 1.5, dash: [4])) }
                            }
                            .overlay { if chosen { Rectangle().strokeBorder(TK.blue, lineWidth: 2).padding(-3) } }
                            .frame(width: max(8, r.width), height: max(8, r.height))
                            .contentShape(Rectangle())
                            // Tap a box to pick it; drag a box to move it.
                            .onTapGesture { selectedBox = box.id }
                            .gesture(DragGesture(minimumDistance: 4)
                                .onChanged { v in moveBox(box.id, by: v.translation, in: fit) }
                                .onEnded { _ in boxOrigin = nil })
                            .position(x: r.midX, y: r.midY)
                            .accessibilityLabel(L(box.kind) + (box.on ? ", hidden" : ", visible"))
                            .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                        }
                        // The picked box: a handle on each corner resizes it; the opposite corner stays put.
                        if let box = boxes[page]?.first(where: { $0.id == selectedBox }) {
                            let r = Redaction.place(box.rect, in: fit)
                            ForEach(0..<4, id: \.self) { corner in
                                Circle().fill(.white).frame(width: 16, height: 16)
                                    .overlay(Circle().strokeBorder(TK.blue, lineWidth: 2))
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                                    .position(x: corner % 2 == 0 ? r.minX : r.maxX, y: corner < 2 ? r.minY : r.maxY)
                                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("redact-page"))
                                        .onChanged { v in resizeBox(box.id, corner: corner, to: v.location, in: fit) }
                                        .onEnded { _ in boxOrigin = nil })
                                    .accessibilityLabel("Resize")
                                    .accessibilityIdentifier("redact-handle-\(corner)")
                            }
                        }
                        if let draft {
                            Rectangle().fill(.black.opacity(0.6)).frame(width: draft.width, height: draft.height).position(x: draft.midX, y: draft.midY)
                        }
                    }
                    .coordinateSpace(name: "redact-page")
                    .contentShape(Rectangle())
                    .onTapGesture { selectedBox = nil }
                    // Drag on the page (not on a box) to add a black box; it is picked right away.
                    .gesture(DragGesture(minimumDistance: 10).onChanged { v in
                        draft = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                       width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                    }.onEnded { _ in
                        if let d = draft?.intersection(fit), !d.isNull, d.width > 4, d.height > 4 {
                            let n = CGRect(x: (d.minX - fit.minX) / fit.width, y: (d.minY - fit.minY) / fit.height, width: d.width / fit.width, height: d.height / fit.height)
                            remember()
                            let added = Redaction.Box(rect: n, kind: "Added")
                            boxes[page, default: []].append(added)
                            selectedBox = added.id
                        }
                        draft = nil
                    })
                }
                .frame(maxHeight: .infinity)
                .background(TK.grey100, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let message = work.message { ToastMessage(text: message) }
        } actions: {
            Button(total == 0 ? "Draw boxes to hide" : "Hide \(total) and save a copy") { save() }
                .buttonStyle(CTAButtonStyle()).disabled(total == 0).accessibilityIdentifier("redact-save")
        }
    }
    /// Above the page: what can be done with the picked box, and Undo.
    private var editBar: some View {
        HStack(spacing: 8) {
            if let box = boxes[page]?.first(where: { $0.id == selectedBox }) {
                Button { remember(); updateBox(box.id) { $0.on.toggle() } } label: {
                    Label(box.on ? "Show" : "Hide", systemImage: box.on ? "eye" : "eye.slash")
                }
                .buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("redact-toggle")
                Button(role: .destructive) {
                    remember(); boxes[page]?.removeAll { $0.id == box.id }; selectedBox = nil
                } label: { Label("Delete", systemImage: "trash") }
                .buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("redact-delete")
            } else {
                Text("Drag to add a box. Tap a box to change it.").font(.system(size: 13)).foregroundStyle(TK.grey600)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { undoBoxes() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 20) }
                .buttonStyle(ChipStyle(selected: false)).disabled(history.isEmpty)
                .accessibilityLabel("Undo").accessibilityIdentifier("redact-undo-box")
        }
        .frame(minHeight: 40)
    }
    private func remember() {
        history.append(boxes); if history.count > 40 { history.removeFirst() }
    }
    private func undoBoxes() {
        guard let last = history.popLast() else { return }
        boxes = last
        if boxes[page]?.contains(where: { $0.id == selectedBox }) != true { selectedBox = nil }
    }
    private func updateBox(_ id: UUID, _ change: (inout Redaction.Box) -> Void) {
        guard var list = boxes[page], let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i]); boxes[page] = list
    }
    /// Drags a box by `translation`, keeping it on the page.
    private func moveBox(_ id: UUID, by translation: CGSize, in fit: CGRect) {
        guard fit.width > 0, fit.height > 0, let rect = boxes[page]?.first(where: { $0.id == id })?.rect else { return }
        if boxOrigin == nil { remember(); boxOrigin = rect; selectedBox = id }
        guard let origin = boxOrigin else { return }
        updateBox(id) {
            $0.rect.origin.x = min(1 - origin.width, max(0, origin.minX + translation.width / fit.width))
            $0.rect.origin.y = min(1 - origin.height, max(0, origin.minY + translation.height / fit.height))
        }
    }
    /// Moves one corner of a box to `point`; the opposite corner stays where it was.
    private func resizeBox(_ id: UUID, corner: Int, to point: CGPoint, in fit: CGRect) {
        guard fit.width > 0, fit.height > 0, let rect = boxes[page]?.first(where: { $0.id == id })?.rect else { return }
        if boxOrigin == nil { remember(); boxOrigin = rect }
        guard let origin = boxOrigin else { return }
        let left = corner % 2 == 0, top = corner < 2
        let fixedX = left ? origin.maxX : origin.minX, fixedY = top ? origin.maxY : origin.minY
        let px = min(1, max(0, (point.x - fit.minX) / fit.width)), py = min(1, max(0, (point.y - fit.minY) / fit.height))
        let w = max(8 / fit.width, left ? fixedX - px : px - fixedX)
        let h = max(8 / fit.height, top ? fixedY - py : py - fixedY)
        updateBox(id) { $0.rect = CGRect(x: left ? fixedX - w : fixedX, y: top ? fixedY - h : fixedY, width: w, height: h) }
    }
    /// A page just scanned or a PDF just added: open it here.
    private func openNew(_ id: UUID) { if let added = store.document(id) { start(added) } }
    private func start(_ chosen: ScanDocument) {
        guard let file = chosen.pdfFile else { return }
        let url = store.url(file), count = chosen.pages.count
        doc = chosen; boxes = [:]; page = 0; image = nil; history = []; selectedBox = nil
        work.run("Looking for personal info…") {
            for i in 0..<count {
                work.busy = count > 1 ? "Looking for personal info… page \(i + 1) of \(count)" : "Looking for personal info…"
                let found = try await OfflineWork.perform { try Redaction.detect(ExtractRender.page(url, index: i, maxSide: 3000)) }
                boxes[i] = found
            }
            forward = true; step = 1
            show(boxes.filter { !$0.value.isEmpty }.keys.min() ?? 0)
        }
    }
    private func show(_ index: Int) {
        guard let file = doc?.pdfFile else { return }
        page = index; image = nil; selectedBox = nil
        let url = store.url(file)
        Task { image = try? await OfflineWork.perform { try ExtractRender.page(url, index: index, maxSide: 1400) } }
    }
    private func save() {
        guard let doc, let file = doc.pdfFile else { return }
        let url = store.url(file), count = doc.pages.count
        let rects = boxes.mapValues { $0.filter(\.on).map(\.rect) }
        let title = PDFTools.named(doc.title, "redacted")
        work.run(total == 1 ? "Hiding 1 item…" : "Hiding \(total) items…") {
            let data = try await OfflineWork.perform { try Redaction.apply(url, boxes: rects, pageCount: count) }
            _ = try await store.saveGeneratedPDF(data, title: title, folder: doc.folder)
            result = PDFToolResult(title: "Personal info hidden", detail: "Saved as \(title). The blacked-out details are removed, not just covered. The original is unchanged.",
                                   files: PDFTools.share([(title + ".pdf", data)]))
            forward = true; step = 2
        }
    }
}

/// Aspect-fit rectangle helper for the redaction canvas.
enum FitRect {
    static func rect(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let s = min(box.width / size.width, box.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }
}
