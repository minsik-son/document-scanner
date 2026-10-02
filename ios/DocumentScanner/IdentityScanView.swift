import SwiftUI

/// A new ID starts with capture, never a prerequisite saved PDF. The two source
/// sides remain an isolated draft until the user saves the single-sheet result.
struct IdentityScanView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draftID: UUID?
    @State private var camera = false
    @State private var retaking: UUID?
    @State private var editing: ScanPage?
    @State private var paper = PaperSize.a4
    @State private var title = "ID card"
    @State private var preview: ExportedFiles?
    @State private var preparing = false
    @State private var saving = false
    @State private var savedID: UUID?
    @State private var error: String?
    @State private var discard = false
    @State private var previewTask: Task<Void, Never>?
    @State private var revision = UUID()
    private var draft: ScanDocument? { draftID.flatMap(store.document) }
    private var complete: Bool { draft?.pages.count == 2 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let savedID, let result = store.document(savedID) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Design.blue)
                        Text("Saved on this iPhone").font(.title2.bold())
                        Text("Front and back on one page").foregroundStyle(.secondary)
                        if let file = result.pdfFile { PDFPreview(url: store.url(file), singlePage: true).frame(height: 420) }
                        if let file = result.pdfFile { ShareLink("Share PDF", item: store.url(file)).buttonStyle(PrimaryButton()) }
                        Button("Done") { finish() }.accessibilityIdentifier("id-saved-done")
                    } else {
                        Text(complete ? "Both sides. One clean page." : "Scan the front, then the back.")
                            .font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
                        HStack(alignment: .top, spacing: 16) {
                            side(0, title: "Front")
                            side(1, title: "Back")
                        }
                        if let file = preview?.urls.first {
                            PDFPreview(url: file, singlePage: true).frame(height: 340).accessibilityIdentifier("id-sheet-preview")
                        } else if preparing { ProgressView("Preparing your ID sheet…").frame(height: 240) }
                        TextField("Document name", text: $title).textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("id-document-name")
                        Picker("Paper size", selection: $paper) {
                            Text("A4").tag(PaperSize.a4); Text("US Letter").tag(PaperSize.letter)
                        }.pickerStyle(.segmented)
                        Text("Both sides are fitted inside standard card-size areas. Pinch the PDF preview to check details.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !complete {
                            Button(draft?.pages.isEmpty == false ? "Scan back" : "Scan front") { openCamera() }
                                .buttonStyle(PrimaryButton()).disabled(draftID == nil)
                        }
                    }
                    if let error { Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("id-error") }
                }.padding(20)
            }.background(Design.muted)
                .navigationTitle("ID scan").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if savedID == nil { Button("Cancel") { if draft?.pages.isEmpty == false { discard = true } else { finish() } }.disabled(saving).accessibilityIdentifier("id-cancel") }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if savedID == nil && complete {
                        Button { save() } label: {
                            if saving { ProgressView("Saving ID PDF…") } else { Text("Save PDF") }
                        }.buttonStyle(PrimaryButton()).disabled(preparing || saving || preview == nil)
                            .accessibilityIdentifier("id-save-pdf").padding(20).background(.white)
                    }
                }
                .disabled(saving)
                .interactiveDismissDisabled()
                .task {
                    guard draftID == nil, savedID == nil else { return }
                    do {
                        var document = ScanDocument(title: "ID card")
                        document.captureStyle = .card; document.paper = .original; document.margin = .none
                        try store.update(document); draftID = document.id; camera = true
                    } catch { self.error = error.localizedDescription }
                }
                .onChange(of: paper) { _, _ in preparePreview() }
                .fullScreenCover(isPresented: $camera, onDismiss: { preparePreview() }) {
                    if let draftID { CameraView(documentID: draftID, retakingPageID: retaking, identityCapture: true) }
                }
                .sheet(item: $editing, onDismiss: { preparePreview() }) { page in
                    PageEditor(page: page, scanStyle: .card) { updated in
                        guard var document = draft, let index = document.pages.firstIndex(where: { $0.id == updated.id }) else { return }
                        document.pages[index] = updated; try store.update(document)
                    }
                }
                .confirmationDialog("Discard this ID scan?", isPresented: $discard, titleVisibility: .visible) {
                    Button("Discard scan", role: .destructive) { finish() }
                    Button("Keep editing", role: .cancel) {}
                } message: { Text("Neither side has been saved to your document library.") }
        }
    }
    @ViewBuilder private func side(_ index: Int, title: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.headline)
            if let document = draft, document.pages.indices.contains(index) {
                let page = document.pages[index]
                Button { editing = page } label: { PageThumbnail(page: page).frame(height: 64).frame(maxWidth: .infinity) }
                    .accessibilityLabel("Edit " + title.lowercased())
                Button("Retake " + title.lowercased()) { openCamera(retaking: page.id) }
                    .accessibilityIdentifier("id-retake-" + title.lowercased())
            } else {
                Image(systemName: "rectangle.dashed").font(.system(size: 44)).frame(height: 64)
                    .foregroundStyle(.secondary)
                Text("Not captured").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 18))
    }
    private func openCamera(retaking page: UUID? = nil) {
        previewTask?.cancel(); revision = UUID(); clearPreview()
        retaking = page; error = nil; camera = true
    }
    private func clearPreview() {
        if let preview { ExportFiles.remove(preview.directory) }
        preview = nil
    }
    private func preparePreview() {
        previewTask?.cancel(); clearPreview()
        let token = UUID(); revision = token
        guard var document = draft, document.pages.count == 2 else { preparing = false; return }
        document.paper = .original; document.margin = .none
        let source = document, root = store.root, paper = paper
        preparing = true; error = nil
        previewTask = Task {
            do {
                let files = try await OfflineWork.perform {
                    let data = try DocumentPDF.compose(source, root: root)
                    let sheet = try LocalDocumentTools.identitySheet(data, front: 0, back: 1, paper: paper)
                    return try ExportFiles.write([("ID preview.pdf", sheet)])
                }
                guard !Task.isCancelled, revision == token else { ExportFiles.remove(files.directory); return }
                preview = files
            } catch { if !Task.isCancelled && revision == token { self.error = error.localizedDescription } }
            if revision == token { preparing = false }
        }
    }
    private func save() {
        guard var document = draft, document.pages.count == 2, !saving else { return }
        document.paper = .original; document.margin = .none
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines), paper = paper
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let prepared = try await PDFExport.prepare(document, root: store.root)
                let data = try await OfflineWork.perform {
                    try LocalDocumentTools.identitySheet(prepared.data, front: 0, back: 1, paper: paper)
                }
                savedID = try await store.saveGeneratedPDF(data, title: name.isEmpty ? "ID card" : name)
                if !prepared.failedTextPages.isEmpty { error = "Your ID PDF is saved. Some text could not be recognized." }
                if let draft { try store.permanentlyDelete(draft); draftID = nil }
                clearPreview()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func finish() {
        previewTask?.cancel(); revision = UUID()
        do {
            if let draft { try store.permanentlyDelete(draft); draftID = nil }
            clearPreview(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
