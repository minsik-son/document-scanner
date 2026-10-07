import SwiftUI
import ContactsUI
import PDFKit

struct DocumentView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var subscription: SubscriptionStore
    @Environment(\.dismiss) var dismiss
    let documentID: UUID
    var initialPage = 0
    var openTextOnAppear = false
    @State private var didOpenInitialText = false
    @State private var activeTool: DocumentTool?
    @State private var pendingTool: DocumentTool?
    @State private var toolPaywall = false
    @State private var correcting = false
    @State private var textFile: SharedFile?
    @State private var editing = false
    @State private var recognizing = false
    @State private var recognitionTask: Task<Void, Never>?
    @State private var text = false
    @State private var trash = false
    @State private var selectedPage = 0
    @State private var problem: String?
    @State private var paywall = false
    @State private var pendingBatch = false
    @State private var textShare: SharedText?
    @State private var availableText: String?
    @State private var progress = "Reading text…"
    @State private var naming = false
    @State private var newContact = false
    var document: ScanDocument? { store.document(documentID) }
    var body: some View {
        Group {
            if let doc = document {
                VStack(spacing: 0) {
                    if let file = doc.pdfFile { PDFPreview(url: store.url(file), initialPage: initialPage).background(Design.muted) }
                    VStack(alignment: .leading, spacing: 16) {
                        Button { naming = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: (doc.kind ?? .other).symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(Design.blue)
                                    .frame(width: 36, height: 36).background(Design.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.title).font(.headline).foregroundStyle(Design.ink).lineLimit(1)
                                    Text("\((doc.kind ?? .other).label) · \(doc.pages.count) pages · \(doc.textStatus)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "pencil").foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("document-name-type")
                        if doc.kind == .businessCard {
                            Button { newContact = true } label: { Label("Save to Contacts", systemImage: "person.crop.circle.badge.plus") }
                                .buttonStyle(PrimaryButton()).accessibilityIdentifier("business-card-contact")
                        }
                        HStack {
                            Button { editing = true } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                            Spacer()
                            Button { text = true } label: { Label("Text", systemImage: "text.viewfinder") }
                            Menu { ForEach(DocumentTool.allCases) { tool in
                                Button(tool.rawValue + (tool.pro ? " · PRO" : "")) {
                                    if tool.pro && !subscription.isPro { pendingTool = tool; toolPaywall = true }
                                    else { activeTool = tool }
                                }
                            } } label: { Label("Tools", systemImage: "ellipsis.circle") }.accessibilityIdentifier("document-tools")
                            Spacer()
                            Button { store.toggleFavorite(doc) } label: { Image(systemName: doc.favorite ? "star.fill" : "star").frame(width: 44, height: 44) }.accessibilityLabel(doc.favorite ? "Remove favorite" : "Favorite")
                        }.font(.headline)
                        if let file = doc.pdfFile { ShareLink(item: store.url(file)) { Label("Share PDF", systemImage: "square.and.arrow.up") }.buttonStyle(PrimaryButton()) }
                    }.padding(24)
                }.navigationTitle(doc.title).navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .onAppear { if openTextOnAppear && !didOpenInitialText { didOpenInitialText = true; text = true } }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { trash = true } label: { Image(systemName: "trash") }.accessibilityLabel("Move to trash") } }
                .sheet(isPresented: $newContact) { NewContactView(fields: DocumentInsight.cardFields(doc), cardImage: cardImage(doc)).ignoresSafeArea() }
                .sheet(isPresented: $naming) { DocumentNameSheet(document: doc).presentationDetents([.medium, .large]) }
                .confirmationDialog("Move this document to Trash?", isPresented: $trash) { Button("Move to Trash", role: .destructive) { store.moveToTrash(doc); if store.problem == nil { dismiss() } } } message: { Text("You can restore it from Settings → Trash.") }
                .sheet(isPresented: $toolPaywall, onDismiss: {
                    if subscription.isPro { activeTool = pendingTool }; pendingTool = nil
                }) { PaywallView() }
                .sheet(item: $activeTool) { tool in
                    if tool == .offline { AdvancedOfflineHub(documentID: documentID) }
                    else if tool == .identity { LocalDocumentToolsView(documentID: documentID, tool: tool) }
                    else if tool == .annotate { AnnotationEditor(documentID: documentID) }
                    else if let flow = LibraryTool(rawValue: tool.rawValue) { PDFToolFlow(tool: flow, documentID: documentID) }
                }
                .fullScreenCover(isPresented: $editing) { ReviewView(documentID: documentID) }
                .sheet(isPresented: $text) {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                Text("Extract text on this iPhone").font(.title2.bold())
                                Picker("Page", selection: $selectedPage) { ForEach(doc.pages.indices, id: \.self) { i in Text("Page \(i+1)").tag(i) } }
                                Button { recognizePage() } label: { if recognizing { ProgressView().tint(Design.blueInk) } else { Text(doc.pages.indices.contains(selectedPage) && doc.pages[selectedPage].ocrComplete ? "Read page text again" : "Extract page text") } }.buttonStyle(PrimaryButton()).disabled(recognizing)
                                Button("Update PDF text") { updatePDFText() }.buttonStyle(.bordered).disabled(recognizing)
                                Text("New PDFs include selectable text automatically. Update older PDFs here.").font(.footnote).foregroundStyle(.secondary)
                                Button {
                                    if subscription.isPro { shareAllText() }
                                    else { pendingBatch = true; paywall = true }
                                } label: { HStack { Text("Share all page text"); Spacer(); Text("PRO").font(.caption.bold()) } }.buttonStyle(.bordered).disabled(recognizing)
                                if recognizing { Text(progress).font(.subheadline).foregroundStyle(.secondary); Button("Cancel recognition") { recognitionTask?.cancel() } }
                                if let problem { Text(problem).foregroundStyle(.red) }
                                if let availableText { Button("Share available text") { textShare = SharedText(value: availableText) }.buttonStyle(.bordered).disabled(recognizing) }
                                if let current = document, current.pages.indices.contains(selectedPage) {
                                    let page = current.pages[selectedPage]
                                    if page.ocrComplete && page.textBlocks.isEmpty { Text("No text was found on this page. Try a clearer scan.").foregroundStyle(.secondary) }
                                    Text(page.plainText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    if !page.plainText.isEmpty {
                                        Button("Correct recognized text") { correcting = true }.disabled(recognizing)
                                        Button("Save text file") {
                                            do { let files = try ExportFiles.write([("Page-\(selectedPage+1).txt", Data(page.plainText.utf8))]); textFile = SharedFile(url: files.urls[0]) }
                                            catch { problem = error.localizedDescription }
                                        }
                                    }
                                    if !page.plainText.isEmpty { ShareLink(item: page.plainText) { Label("Share text", systemImage: "square.and.arrow.up") } }
                                }
                            }.padding(24)
                        }.sheet(isPresented: $paywall, onDismiss: {
                            if pendingBatch && subscription.isPro { pendingBatch = false; shareAllText() }
                            else { pendingBatch = false }
                        }) { PaywallView() }
                        .sheet(isPresented: $correcting) { OCRTextEditor(documentID: documentID, pageIndex: selectedPage) }
                        .sheet(item: $textFile) { file in ShareSheet(items: [file.url], completion: { _, _ in ExportFiles.remove(file.url.deletingLastPathComponent()) }) }
                        .sheet(item: $textShare) { ShareSheet(items: [$0.value]) }
                        .interactiveDismissDisabled(recognizing).navigationTitle("Page text").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { text = false }.disabled(recognizing) } }
                    }
                }
            } else { ContentUnavailableView("Document unavailable", systemImage: "doc") }
        }
    }
    private func updatePDFText() {
        guard let doc = document else { return }
        recognizing = true; problem = nil; availableText = nil
        let root = store.root
        recognitionTask = Task {
            do {
                let result = try await PDFExport.prepare(doc, root: root, forceText: true) { progress = $0 }
                try store.savePDF(result.data, document: result.document)
                problem = result.textNotice
            } catch { problem = "PDF text wasn't updated. Your saved PDF is still available. \(error.localizedDescription)" }
            recognizing = false
        }
    }
    private func shareAllText() {
        guard subscription.isPro, let doc = document else { return }
        recognizing = true; problem = nil; availableText = nil
        let root = store.root
        recognitionTask = Task {
            do {
                let result = try await PDFExport.prepare(doc, root: root) { progress = $0 }
                try store.savePDF(result.data, document: result.document)
                problem = result.textNotice
                if !result.document.text.isEmpty {
                    if result.failedTextPages.isEmpty { let files = try ExportFiles.write([(doc.title + ".txt", Data(result.document.text.utf8))]); textFile = SharedFile(url:files.urls[0]) }
                    else { availableText = result.document.text }
                }
            } catch { problem = "Text couldn't be prepared. Your saved PDF is still available. \(error.localizedDescription)" }
            recognizing = false
        }
    }
    private func recognizePage() {
        guard let doc = document, doc.pages.indices.contains(selectedPage) else { return }
        let page = doc.pages[selectedPage], root = store.root
        recognizing = true; problem = nil; progress = "Reading page \(selectedPage + 1)…"
        recognitionTask = Task {
            do {
                let blocks = try await Task.detached { try Imaging.recognize(Imaging.render(page, root: root)) }.value
                guard var current = document, let index = current.pages.firstIndex(where: { $0.id == page.id }) else { recognizing = false; return }
                current.pages[index].textBlocks = blocks; current.pages[index].ocrComplete = true
                current.pages[index].ocrProcessingVersion = PDFExport.textProcessingVersion
                let result = try await PDFExport.prepare(current, root: root) { progress = $0 }
                try store.savePDF(result.data, document: result.document)
                problem = result.textNotice
            } catch { problem = "Text could not be extracted. \(error.localizedDescription)" }
            recognizing = false
        }
    }
}
private struct SharedText: Identifiable {
    let id = UUID()
    let value: String
}
struct PDFPreview: UIViewRepresentable {
    let url: URL
    var singlePage = false
    var initialPage = 0
    var openTextOnAppear = false
    @State private var didOpenInitialText = false
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = singlePage ? .singlePage : .singlePageContinuous; view.backgroundColor = .secondarySystemBackground; view.document = PDFDocument(url: url); if let page = view.document?.page(at: initialPage) { DispatchQueue.main.async { view.go(to: page) } }; return view }
    func updateUIView(_ view: PDFView, context: Context) { if view.document?.documentURL != url { view.document = PDFDocument(url: url) } }
}


/// Rename a document and set its kind. Offers the name made from its text.
struct DocumentNameSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let document: ScanDocument
    @State private var title = ""
    @State private var kind = DocumentKind.other
    private var suggestion: String? {
        DocumentInsight.suggestTitle(document, kind: kind).flatMap { $0 == title ? nil : $0 }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Document name", text: $title).accessibilityIdentifier("document-name-field")
                    if let suggestion {
                        Button { title = suggestion } label: { Label(suggestion, systemImage: "sparkles") }
                            .accessibilityIdentifier("document-name-suggestion")
                    }
                }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(DocumentKind.allCases) { option in
                            Button { kind = option } label: {
                                Label(option.label, systemImage: option.symbol).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(kind == option ? Design.blue.opacity(0.12) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                                    .foregroundStyle(kind == option ? Design.blue : Design.ink)
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 4)
                } header: { Text("Type") } footer: { Text("Sorted automatically on this iPhone. Your choice is kept.") }
            }
            .navigationTitle("Name & type").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { title = document.title; kind = document.kind ?? DocumentInsight.classify(document) }
        }
    }
    private func save() {
        guard var doc = store.document(document.id) else { dismiss(); return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean != doc.title { doc.title = clean; doc.autoTitled = false }
        if kind != doc.kind { doc.kind = kind; doc.kindChosen = true }
        store.perform { try store.update(doc) }
        dismiss()
    }
}


extension DocumentView {
    /// The first page as a small JPEG for the contact photo field.
    func cardImage(_ doc: ScanDocument) -> Data? {
        guard let page = doc.pages.first, let image = try? Imaging.renderThumbnail(page, root: store.root, maxDimension: 640) else { return nil }
        return image.jpegData(compressionQuality: 0.8)
    }
}

/// Apple's new-contact screen, filled in from a business card. Nothing is saved
/// until the person taps Done there.
struct NewContactView: UIViewControllerRepresentable {
    let fields: DocumentInsight.CardFields
    var cardImage: Data?
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(close: { dismiss() }) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let contact = CNMutableContact()
        let parts = fields.name.split(separator: " ").map(String.init)
        if parts.count >= 2 { contact.givenName = parts.dropLast().joined(separator: " "); contact.familyName = parts.last ?? "" }
        else { contact.givenName = fields.name }
        contact.organizationName = fields.organization
        contact.jobTitle = fields.jobTitle
        contact.phoneNumbers = fields.phones.enumerated().map { i, p in CNLabeledValue(label: i == 0 ? CNLabelWork : CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: p)) }
        contact.emailAddresses = fields.emails.map { CNLabeledValue(label: CNLabelWork, value: $0 as NSString) }
        contact.urlAddresses = fields.urls.map { CNLabeledValue(label: CNLabelWork, value: $0 as NSString) }
        if !fields.address.isEmpty {
            let address = CNMutablePostalAddress(); address.street = fields.address
            contact.postalAddresses = [CNLabeledValue<CNPostalAddress>(label: CNLabelWork, value: address)]
        }
        contact.note = "Scanned business card"
        if let cardImage { contact.imageData = cardImage }
        let view = CNContactViewController(forNewContact: contact)
        view.delegate = context.coordinator
        return UINavigationController(rootViewController: view)
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) { close() }
    }
}
