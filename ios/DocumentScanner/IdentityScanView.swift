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
            Group {
                if let savedID, let result = store.document(savedID) { savedPage(result) } else { sidesPage }
            }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if savedID == nil { Button("Close") { if draft?.pages.isEmpty == false { discard = true } else { finish() } }.disabled(saving).accessibilityIdentifier("id-cancel") }
                }
            }
            .overlay { if saving { BusyOverlay(text: "Saving ID PDF…") } }
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
    @ViewBuilder private var errorRow: some View {
        if let error {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(TK.red)
                Text(error).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("id-error")
                Spacer(minLength: 0)
            }.padding(16).background(TK.grey100, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
    /// One page: both sides, the sheet and its paper.
    private var sidesPage: some View {
        ToolPage(title: complete ? "Both sides, one page" : "Scan both sides of your ID",
                 subtitle: complete ? "Check the sheet, then save it as a PDF." : "Front first, then the back. Each side fits a card-size area.") {
            HStack(alignment: .top, spacing: 12) {
                side(0, title: "Front")
                side(1, title: "Back")
            }
            if complete {
                Group {
                    if let file = preview?.urls.first {
                        PDFPreview(url: file, singlePage: true).frame(height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityIdentifier("id-sheet-preview")
                    } else if preparing {
                        ProgressView().frame(maxWidth: .infinity).frame(height: 240)
                    }
                }
                .padding(10).background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Paper")
                    HStack(spacing: 8) {
                        Button("A4") { paper = .a4 }.buttonStyle(ChipStyle(selected: paper == .a4))
                        Button("US Letter") { paper = .letter }.buttonStyle(ChipStyle(selected: paper == .letter))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Name")
                    TextField("Document name", text: $title).font(.system(size: 17))
                        .padding(.horizontal, 16).frame(height: 52)
                        .background(TK.grey50, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityIdentifier("id-document-name")
                }
            }
            errorRow
            Label("Processed on this iPhone", systemImage: "lock.shield").font(.system(size: 13)).foregroundStyle(TK.grey500)
        } actions: {
            if complete {
                Button("Save PDF") { save() }.buttonStyle(CTAButtonStyle()).disabled(preparing || saving || preview == nil)
                    .accessibilityIdentifier("id-save-pdf")
            } else {
                Button(draft?.pages.isEmpty == false ? "Scan back" : "Scan front") { openCamera() }
                    .buttonStyle(CTAButtonStyle()).disabled(draftID == nil)
            }
        }
    }
    private func savedPage(_ result: ScanDocument) -> some View {
        ToolPage(title: "") {
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(TK.blueSoft).frame(width: 132, height: 132)
                    Circle().fill(TK.blue).frame(width: 84, height: 84)
                    Image(systemName: "checkmark").font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
                }.padding(.top, 16).accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Saved on this iPhone").font(.system(size: 24, weight: .bold)).foregroundStyle(TK.grey900)
                    Text("Front and back on one page").font(.system(size: 16)).foregroundStyle(TK.grey600).multilineTextAlignment(.center)
                }
                if let file = result.pdfFile {
                    PDFPreview(url: store.url(file), singlePage: true).frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                errorRow
            }.frame(maxWidth: .infinity)
        } actions: {
            if let file = result.pdfFile {
                ShareLink(item: store.url(file)) { Text("Share PDF") }.buttonStyle(SecondaryCTAStyle())
            }
            Button("Done") { finish() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("id-saved-done")
        }
    }
    @ViewBuilder private func side(_ index: Int, title: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey600)
            if let document = draft, document.pages.indices.contains(index) {
                let page = document.pages[index]
                Button { editing = page } label: { PageThumbnail(page: page).frame(height: 72).frame(maxWidth: .infinity) }
                    .buttonStyle(.plain).accessibilityLabel("Edit " + title.lowercased())
                Button("Retake") { openCamera(retaking: page.id) }.buttonStyle(ChipStyle(selected: false))
                    .accessibilityIdentifier("id-retake-" + title.lowercased())
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TK.grey300, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .frame(height: 72).overlay(Image(systemName: "creditcard").font(.system(size: 24)).foregroundStyle(TK.grey400))
                Text("Not scanned").font(.system(size: 13)).foregroundStyle(TK.grey500).frame(height: 40)
            }
        }.frame(maxWidth: .infinity).padding(14).background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
