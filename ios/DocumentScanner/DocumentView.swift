import SwiftUI
import ContactsUI
import EventKitUI
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
    @State private var asking = false
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
                        Button { asking = true } label: { Label("Key info", systemImage: "list.bullet.rectangle") }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("document-key-info")
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
                .sheet(isPresented: $asking) { KeyInfoSheet(documentID: doc.id).presentationDetents([.medium, .large]) }
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


/// Dates, amounts, phone numbers, emails, links, addresses and account numbers
/// found in a document's text, each with a one-tap action, plus in-document search.
/// Apple's data detectors on this iPhone: instant, offline, every device.
struct KeyInfoSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let documentID: UUID
    @State private var items: [DocumentInsight.KeyItem] = []
    @State private var pages: [String] = []
    @State private var reading = false
    @State private var problem: String?
    @State private var query = ""
    @State private var copied: String?
    @State private var event: KeyEvent?
    private var doc: ScanDocument? { store.document(documentID) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find in this document", text: $query).autocorrectionDisabled().accessibilityIdentifier("key-info-search")
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                    }
                }
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    let hits = matches
                    Section(hits.isEmpty ? "No matches" : "\(hits.count) \(hits.count == 1 ? "match" : "matches")") {
                        ForEach(Array(hits.prefix(60).enumerated()), id: \.offset) { _, hit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(highlighted(hit.line)).font(.subheadline)
                                if pages.count > 1 { Text("Page \(hit.page + 1)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                } else if reading {
                    Section { HStack(spacing: 8) { ProgressView(); Text("Reading the pages…").foregroundStyle(.secondary) } }
                } else if let problem {
                    Section { Text(problem).foregroundStyle(.secondary) }
                } else if items.isEmpty {
                    Section { Text("No dates, amounts or contact details were found.").foregroundStyle(.secondary) }
                } else {
                    ForEach(DocumentInsight.KeyItem.Kind.allCases, id: \.self) { kind in
                        let group = items.filter { $0.kind == kind }
                        if !group.isEmpty {
                            Section(kind.title) {
                                ForEach(group) { item in row(item) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Key info").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay(alignment: .bottom) {
                if let copied { Text("Copied \(copied)").font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule()).padding(.bottom, 16).transition(.opacity) }
            }
            .sheet(item: $event) { EventEditor(title: $0.title, date: $0.date).ignoresSafeArea() }
        }
        .task { await load() }
    }
    @ViewBuilder private func row(_ item: DocumentInsight.KeyItem) -> some View {
        Button { act(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.kind.symbol).foregroundStyle(Design.blue).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.value).font(.body.weight(.semibold)).foregroundStyle(Design.ink).lineLimit(2)
                    if !item.context.isEmpty { Text(item.context).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 6)
                Text(item.kind.action).font(.caption.weight(.semibold)).foregroundStyle(Design.blue)
            }
        }
        .contextMenu { Button("Copy", systemImage: "doc.on.doc") { copy(item.value) } }
    }
    private var matches: [(line: String, page: Int)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [(String, Int)] = []
        for (p, text) in pages.enumerated() {
            for line in text.split(whereSeparator: \.isNewline) where line.localizedCaseInsensitiveContains(q) { out.append((String(line), p)) }
        }
        return out.map { (line: $0.0, page: $0.1) }
    }
    private func highlighted(_ line: String) -> AttributedString {
        var a = AttributedString(line)
        let q = query.trimmingCharacters(in: .whitespaces)
        var search = a.startIndex..<a.endIndex
        while let r = a[search].range(of: q, options: .caseInsensitive) {
            a[r].backgroundColor = .yellow.opacity(0.5); a[r].font = .subheadline.bold()
            search = r.upperBound..<a.endIndex
        }
        return a
    }
    private func act(_ item: DocumentInsight.KeyItem) {
        switch item.kind {
        case .date: if let date = item.date { event = KeyEvent(title: doc?.title ?? "Reminder", date: date) } else { copy(item.value) }
        case .phone:
            let digits = item.value.filter { $0.isNumber || $0 == "+" }
            if let url = URL(string: "tel:" + digits) { openURL(url) }
        case .email: if let url = URL(string: "mailto:" + item.value) { openURL(url) }
        case .link: if let url = item.url { openURL(url) }
        case .address:
            var c = URLComponents(string: "https://maps.apple.com/"); c?.queryItems = [URLQueryItem(name: "q", value: item.value)]
            if let url = c?.url { openURL(url) }
        case .amount, .account: copy(item.value)
        }
    }
    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        withAnimation { copied = value }
        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); withAnimation { copied = nil } }
    }
    private func load() async {
        guard let current = doc else { return }
        var d = current
        if d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !d.pages.isEmpty {
            reading = true
            do {
                let prepared = try await PDFExport.prepare(d, root: store.root)
                try store.savePDF(prepared.data, document: prepared.document)
                d = prepared.document
            } catch { problem = error.localizedDescription }
            reading = false
        }
        pages = d.pages.map(\.plainText)
        let text = d.text
        items = await Task.detached { DocumentInsight.keyInfo(text) }.value
        if problem == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problem = "No text was found in this document." }
    }
}
private struct KeyEvent: Identifiable { let id = UUID(); let title: String; let date: Date }

/// Apple's add-event screen, prefilled. Nothing is added until the person taps Add.
struct EventEditor: UIViewControllerRepresentable {
    let title: String
    let date: Date
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(close: { dismiss() }) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let view = EKEventEditViewController(); view.eventStore = store
        let e = EKEvent(eventStore: store); e.title = title; e.startDate = date
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hasTime = (parts.hour ?? 0) != 0 || (parts.minute ?? 0) != 0
        e.isAllDay = !hasTime; e.endDate = hasTime ? date.addingTimeInterval(3600) : date
        view.event = e; view.editViewDelegate = context.coordinator
        return view
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { close() }
    }
}
