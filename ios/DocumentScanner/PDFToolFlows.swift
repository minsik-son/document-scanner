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
        if doc.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { doc.title = "Scan \(Date().formatted(date: .abbreviated, time: .shortened))"; doc.autoTitled = true }
        let result = try await PDFExport.prepare(doc, root: store.root)
        try store.savePDF(result.data, document: result.document)
        return id
    }
}

private struct PDFToolDone: View {
    let result: PDFToolResult
    let close: () -> Void
    @State private var sharing: ExportedFiles?
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
            if let urls = result.files?.urls, !urls.isEmpty { ResultReview(urls: urls).padding(.top, 6) }
        }
            .sheet(item: $sharing) { files in ShareSheet(items: files.urls) }
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
        case .images: return "Images (JPG)"
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
    private var count: String { "\(selected.count) \(selected.count == 1 ? "page" : "pages")" }
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
                finish(PDFToolResult(title: "Extracted \(picks.count) \(picks.count == 1 ? "page" : "pages")", detail: "Saved as \(copy.title). The original is unchanged.",
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
                                 detail: "Made from \(picks.count) \(picks.count == 1 ? "page" : "pages") of \(doc.title). The original is unchanged.",
                                 files: PDFTools.share(files), shareTitle: kind == .images ? "Share images" : "Share file"))
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
            cg.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: target), rotate: 0, preserveAspectRatio: true))
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
    @State private var png = false
    @State private var pixels = 2400
    private var count: String { "\(selected.count) \(selected.count == 1 ? "page" : "pages")" }
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
        ToolPage(title: "Choose the image type", subtitle: "\(count) will become \(selected.count == 1 ? "a picture" : "pictures").") {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Format")
                Button { png = false } label: { OptionCard(title: "JPG", detail: "Smaller files. Best for sharing and chat.", selected: !png) }
                    .buttonStyle(.plain).accessibilityIdentifier("images-jpg")
                Button { png = true } label: { OptionCard(title: "PNG", detail: "No compression. Sharpest text, larger files.", selected: png) }
                    .buttonStyle(.plain).accessibilityIdentifier("images-png")
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
            Button("Export \(selected.count) \(selected.count == 1 ? "image" : "images")") { export() }
                .buttonStyle(CTAButtonStyle()).accessibilityIdentifier("images-run")
        }
    }
    private func sizeOption(_ value: Int, _ title: String, _ detail: String) -> some View {
        Button { pixels = value } label: { OptionCard(title: title, detail: detail, selected: pixels == value) }
            .buttonStyle(.plain).accessibilityIdentifier("images-size-\(value)")
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
    @State private var choosing = false
    @State private var width = 1080
    @State private var gap = 0
    private var count: String { "\(selected.count) \(selected.count == 1 ? "page" : "pages")" }
    var body: some View {
        ZStack {
            if choosing { optionsPage.transition(.move(edge: .trailing).combined(with: .opacity)) }
            else { pagesPage.transition(.move(edge: .leading).combined(with: .opacity)) }
        }
        .animation(.snappy(duration: 0.3), value: choosing)
        .onAppear { if selected.isEmpty { selected = Array(document.pages.indices.prefix(100)) } }
    }
    private var pagesPage: some View {
        ToolPage(title: "Which pages?", subtitle: "They're joined top to bottom into one image.") {
            PageSelection(document: document, selected: $selected)
        } actions: {
            Button(selected.isEmpty ? "Select pages" : "Next · \(count)") { choosing = true }
                .buttonStyle(CTAButtonStyle()).disabled(selected.isEmpty).accessibilityIdentifier("long-image-next")
        }
    }
    private var optionsPage: some View {
        ToolPage(title: "How should it look?", subtitle: "\(count) joined top to bottom.") {
            ScrollView {
                VStack(spacing: CGFloat(gap) / 4) {
                    ForEach(selected.sorted().prefix(8), id: \.self) { i in
                        PDFPageThumb(document: document, index: i).frame(width: 120).background(.white)
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
                if let lockNote { Text(lockNote).font(.system(size: 13)).foregroundStyle(TK.red) }
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
    private static let accountWords = ["account", "acct", "a/c", "bank", "transit", "routing", "iban", "swift", "계좌", "은행", "예금주", "입금"]
    private static let passportWords = ["passport", "여권"]
    private static let licenceWords = ["licence", "license", "driver", "운전면허", "면허번호"]
    /// Finds ID, card, account and phone numbers and emails on a rendered page.
    nonisolated static func detect(_ image: UIImage) throws -> [Box] { boxes(in: try Imaging.recognize(image)) }
    nonisolated static func boxes(in blocks: [TextBlock]) -> [Box] {
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
        return boxes
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
        return out
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
                    for r in boxes[i] ?? [] {
                        c.fill(CGRect(x: r.minX * image.size.width, y: r.minY * image.size.height, width: r.width * image.size.width, height: r.height * image.size.height))
                    }
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
    private var documents: [ScanDocument] { store.active.filter { $0.pdfFile != nil } }
    private var total: Int { boxes.values.reduce(0) { $0 + $1.filter(\.on).count } }
    var body: some View {
        StepStack(step: step, forward: forward) {
            if step == 0 { choosePage }
            else if step == 1 { editPage }
            else if let result { PDFToolDone(result: result) { dismiss() } }
        }
        .stepChrome(step: $step, forward: $forward, last: 2, work: work)
        .sheet(isPresented: $paywall) { PaywallView() }
    }
    private var choosePage: some View {
        ToolPage(title: "Hide personal info", subtitle: "ID, card and account numbers, phone numbers and emails are found and blacked out in a new copy.") {
            ToolHero(art: .redact)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Choose a document")
                if documents.isEmpty { Text("No saved documents yet. Scan or import one first.").foregroundStyle(TK.grey500) }
                else { DocumentChoiceList(documents: documents) { start($0) } }
            }
            if let message = work.message { ToastMessage(text: message) }
            Label("Found on this iPhone. Nothing is uploaded.", systemImage: "lock.shield").font(.system(size: 13)).foregroundStyle(TK.grey500)
        } actions: { EmptyView() }
    }
    private var editPage: some View {
        ToolPage(title: total == 0 ? "Nothing found yet" : "\(total) \(total == 1 ? "item" : "items") to hide",
                 subtitle: "Tap a box to keep it visible. Drag on the page to hide anything else.", scrolls: false) {
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
                GeometryReader { geo in
                    let fit = FitRect.rect(image.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image).resizable().frame(width: fit.width, height: fit.height).position(x: fit.midX, y: fit.midY)
                        ForEach(boxes[page] ?? []) { box in
                            let r = CGRect(x: fit.minX + box.rect.minX * fit.width, y: fit.minY + box.rect.minY * fit.height, width: box.rect.width * fit.width, height: box.rect.height * fit.height)
                            Group {
                                if box.on { Rectangle().fill(.black) }
                                else { Rectangle().strokeBorder(TK.red, style: StrokeStyle(lineWidth: 1.5, dash: [4])) }
                            }
                            .frame(width: max(8, r.width), height: max(8, r.height)).position(x: r.midX, y: r.midY)
                            .onTapGesture { toggle(box.id) }
                            .accessibilityLabel(box.kind + (box.on ? ", hidden" : ", visible"))
                        }
                        if let draft {
                            Rectangle().fill(.black.opacity(0.6)).frame(width: draft.width, height: draft.height).position(x: draft.midX, y: draft.midY)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 10).onChanged { v in
                        draft = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                                       width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                    }.onEnded { _ in
                        if let d = draft?.intersection(fit), !d.isNull, d.width > 4, d.height > 4 {
                            let n = CGRect(x: (d.minX - fit.minX) / fit.width, y: (d.minY - fit.minY) / fit.height, width: d.width / fit.width, height: d.height / fit.height)
                            boxes[page, default: []].append(Redaction.Box(rect: n, kind: "Added"))
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
    private func toggle(_ id: UUID) {
        guard var list = boxes[page], let i = list.firstIndex(where: { $0.id == id }) else { return }
        if list[i].kind == "Added" { list.remove(at: i) } else { list[i].on.toggle() }
        boxes[page] = list
    }
    private func start(_ chosen: ScanDocument) {
        guard let file = chosen.pdfFile else { return }
        let url = store.url(file), count = chosen.pages.count
        doc = chosen; boxes = [:]; page = 0; image = nil
        work.run("Looking for personal info…") {
            for i in 0..<count {
                work.busy = count > 1 ? "Looking for personal info… page \(i + 1) of \(count)" : "Looking for personal info…"
                let found = try await OfflineWork.perform { try Redaction.detect(ExtractRender.page(url, index: i, maxSide: 2000)) }
                boxes[i] = found
            }
            forward = true; step = 1
            show(boxes.filter { !$0.value.isEmpty }.keys.min() ?? 0)
        }
    }
    private func show(_ index: Int) {
        guard let file = doc?.pdfFile else { return }
        page = index; image = nil
        let url = store.url(file)
        Task { image = try? await OfflineWork.perform { try ExtractRender.page(url, index: index, maxSide: 1400) } }
    }
    private func save() {
        guard subscription.isPro else { paywall = true; return }
        guard let doc, let file = doc.pdfFile else { return }
        let url = store.url(file), count = doc.pages.count
        let rects = boxes.mapValues { $0.filter(\.on).map(\.rect) }
        let title = PDFTools.named(doc.title, "redacted")
        work.run("Hiding \(total) \(total == 1 ? "item" : "items")…") {
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
