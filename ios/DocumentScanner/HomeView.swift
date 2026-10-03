import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject private var ads: HomeAdvertisementStore
    @EnvironmentObject private var subscription: SubscriptionStore
    @State private var paywall = false
    @State private var query = ""
    @State private var showingDocuments = false
    @State private var advanced = false
    @State private var quick: QuickTool?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var tab = "Recent"
    @State private var folder: String?
    @State private var route: ScanRoute?
    @State private var settings = false
    @State private var importMenu = false
    @State private var photos = false
    @State private var files = false
    @State private var selections: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var newCapture = false
    @State private var pendingResume: UUID?
    @State private var fileBatch: FileImportBatch?
    @State private var pendingImport: UUID?
    @AppStorage("scanner-grid") private var grid = false
    var filtered: [ScanDocument] {
        store.active.filter { (tab != "Favorites" || $0.favorite) && (folder == nil || $0.folder == folder) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 18) {
                    // Like CamScanner and Alarmy: no screen title. Pro sits top left
                    // (Get PRO, trial countdown or a crown), Import top right, search below.
                    HStack(spacing: 10) {
                        ProHeaderBadge(openPaywall: { paywall = true }, openMembership: { settings = true })
                        Spacer()
                        Button { importMenu = true } label: {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 17, weight: .semibold)).foregroundStyle(Design.ink)
                                .frame(width: 40, height: 40).background(.white, in: Circle())
                        }.accessibilityLabel("Import").disabled(importing || !store.storageAvailable)
                    }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(showingDocuments ? "Search your documents" : "Search documents", text: $query).autocorrectionDisabled()
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear document search") }
                    }.padding(.horizontal, 14).frame(height: 44).background(.white, in: Capsule())
                    if query.isEmpty && !showingDocuments {
                        HomeAdvertisementSlot(homeUncovered: route == nil && !advanced && quick == nil && !settings && !paywall && !photos && !files && !importMenu && !importing && fileBatch == nil) {
                            scanCard
                        }
                        shortcutsCard
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Your documents").font(.title3.bold())
                            Text("\(store.active.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button { grid.toggle() } label: {
                                Image(systemName: grid ? "list.bullet" : "square.grid.2x2").frame(width: 36, height: 36)
                            }.accessibilityLabel(grid ? "Show list" : "Show grid")
                        }
                        HStack(spacing: 8) {
                            ForEach(["Recent", "Favorites", "Folders"], id: \.self) { value in
                                Button { tab = value; folder = nil } label: {
                                    Text(LocalizedStringKey(value)).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                                        .background(tab == value ? Design.blue.opacity(0.09) : .white, in: Capsule())
                                }.foregroundStyle(tab == value ? Design.blue : .secondary)
                            }
                        }
                        if tab == "Folders" {
                            ScrollView(.horizontal) {
                                HStack { ForEach(store.manifest.folders, id: \.self) { name in
                                    Button(name) { folder = folder == name ? nil : name }.padding(12)
                                        .background(folder == name ? Design.blue.opacity(0.1) : .white, in: Capsule())
                                } }
                            }.scrollIndicators(.hidden)
                        }
                    }
                }.padding(.top, 4).padding(.bottom, 8)
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                if filtered.isEmpty {
                    VStack(spacing: 16) {
                        ToolArtwork(name: "scan", size: 72)
                        Text(query.isEmpty ? "Paperwork, simplified" : "No documents found").font(.title2.bold())
                        Text(query.isEmpty ? "Scan a page. Save a PDF.\nEverything stays on this iPhone." : "Try another document name.").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 28).background(.white, in: RoundedRectangle(cornerRadius: 24))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))
                } else if grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 20) {
                        ForEach(filtered) { doc in
                            NavigationLink { DocumentView(documentID: doc.id, initialPage: matchingPage(doc)) } label: {
                                VStack { if let page = doc.pages.first { PageThumbnail(page: page, pdfFile: doc.pdfFile).frame(height: 150) }; Text(doc.title).font(.headline).lineLimit(2); Text("\(doc.pages.count) pages").font(.caption) }.padding(12).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 20))
                            }.buttonStyle(.plain).contextMenu { trashAction(doc) }
                        }
                    }.listRowSeparator(.hidden).listRowBackground(Color.clear)
                } else {
                    ForEach(filtered) { doc in
                        NavigationLink { DocumentView(documentID: doc.id, initialPage: matchingPage(doc)) } label: { DocumentRow(document: doc, query: query).padding(.horizontal, 14).background(.white, in: RoundedRectangle(cornerRadius: 20)) }
                            .accessibilityIdentifier("document-row-" + doc.id.uuidString)
                            .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                            // Native List actions arbitrate horizontal swipes against scrolling
                            // and navigation, including reversal and full-swipe cancellation.
                            .swipeActions(edge: .leading, allowsFullSwipe: true) { trashAction(doc) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) { trashAction(doc) }
                    }
                }
            }
            .id(showingDocuments)
            .listStyle(.plain)
            .onScrollPhaseChange { _, phase in ads.setScrolling(phase != .idle) }
            .scrollContentBackground(.hidden)
            .background(Design.muted)
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.defaultMinListRowHeight, 0)
            .disabled(importing)
            .safeAreaInset(edge: .bottom) {
                bottomNavigation
            }
            .overlay { if importing { ProgressView("Importing pages…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .fullScreenCover(isPresented: $advanced) { AdvancedOfflineHub() }
            .sheet(isPresented: $paywall) { PaywallView() }
            .fullScreenCover(item: $quick) { QuickToolView(tool: $0) }
            .sheet(isPresented: $settings, onDismiss: {
                if let id = pendingResume {
                    pendingResume = nil; newCapture = false; route = ScanRoute(id: id)
                }
            }) {
                SettingsView { id in pendingResume = id; settings = false }
            }
            .fullScreenCover(item: $route, onDismiss: {
                if !importing { store.perform { try store.discardEmptyDrafts() } }
            }) { value in
                ReviewView(documentID: value.id, captureOnOpen: newCapture, completionAdEnabled: false,
                           onCompleted: { showingDocuments = false; query = "" })
            }
            .confirmationDialog("Import pages", isPresented: $importMenu) {
                Button("Choose photos") { photos = true }
                Button("Choose PDF or image") { files = true }
            } message: { Text("PDF text and links are preserved. Image adjustments may require converting a page to an image.") }
            .photosPicker(isPresented: $photos, selection: $selections, maxSelectionCount: 50, selectionBehavior: .ordered, matching: .images)
            .onChange(of: selections) { _, items in if !items.isEmpty { importPhotos(items) } }
            .sheet(item: $fileBatch, onDismiss: { if let id = pendingImport { pendingImport = nil; newCapture = false; route = ScanRoute(id: id) } }) { batch in
                FileImportView(urls: batch.urls) { pendingImport = $0 }
            }
            .fileImporter(isPresented: $files, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                switch result { case .success(let urls): fileBatch = FileImportBatch(urls: Array(NSOrderedSet(array: urls)) as? [URL] ?? urls); case .failure(let error): store.problem = error.localizedDescription }
            }
            .alert("Something needs attention", isPresented: Binding(get: { store.problem != nil }, set: { if !$0 { store.problem = nil } })) { Button("OK") { store.problem = nil } } message: { Text(store.problem ?? "") }
        }
    }
    private var bottomNavigation: some View {
        HStack(alignment: .bottom, spacing: 0) {
            navigationButton("Home", symbol: "house.fill", selected: !showingDocuments, identifier: "nav-home") {
                showingDocuments = false
            }
            navigationButton("Documents", symbol: "doc.on.doc.fill", selected: showingDocuments, identifier: "nav-documents") {
                showingDocuments = true
            }
            Button {
                store.perform { let id = try store.createDraft(); newCapture = true; Instant.run { route = ScanRoute(id: id) } }
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Design.cameraBlue, in: Circle())
                    .overlay { Circle().stroke(.white, lineWidth: 5).padding(-5) }
                    .shadow(color: Design.cameraBlue.opacity(0.18), radius: 8, y: 4)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
            }.buttonStyle(.plain)
                .accessibilityLabel("Scan document").accessibilityIdentifier("scan-document")
                .disabled(importing || !store.storageAvailable)
            navigationButton("Tools", symbol: "square.grid.2x2.fill", selected: advanced, identifier: "nav-tools") {
                advanced = true
            }
            navigationButton("Me", symbol: "person.crop.circle.fill", selected: settings, identifier: "nav-settings") {
                settings = true
            }
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 4)
        .background(alignment: .bottom) {
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(.white).padding(.top, 15).ignoresSafeArea(edges: .bottom)
        }
        .disabled(importing)
    }
    private func navigationButton(_ title: String, symbol: String, selected: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 21, weight: .medium))
                    .frame(height: 25)
                Text(title).font(.system(.caption2, weight: selected ? .bold : .medium))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(selected ? Design.blue : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paper, meet\npeace of mind.").font(.system(.title2, weight: .bold))
                    Text("Clear scans. Everything in place.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ToolArtwork(name: "scan", size: 90)
            }
            HStack(spacing: 10) {
                Button { photos = true } label: {
                    Label("Import", systemImage: "plus").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .foregroundStyle(Design.ink).background(Design.muted, in: Capsule())
                }.accessibilityIdentifier("hero-import")
                Button {
                    store.perform { let id = try store.createDraft(); newCapture = true; Instant.run { route = ScanRoute(id: id) } }
                } label: {
                    Label("Scan", systemImage: "camera").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .foregroundStyle(Design.blueInk).background(Design.pastelBlue, in: Capsule())
                }.disabled(!store.storageAvailable).accessibilityIdentifier("hero-scan")
            }.buttonStyle(.plain)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 26))
    }
    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Quick tools").font(.headline)
                Spacer()
                Text("On your iPhone").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 4) {
                shortcut("Photos", icon: "import-photo") { photos = true }
                shortcut("Text", icon: "ocr") { quick = .library(.ocr) }
                shortcut("Word", icon: "word", pro: true) { quick = .advanced(.word) }
                shortcut("Excel", icon: "excel", pro: true) { quick = .advanced(.excel) }
                shortcut("Sign", icon: "signature") { quick = .library(.annotate) }
                shortcut("Compress", icon: "compress", pro: true) { quick = .library(.compress) }
                shortcut("QR code", icon: "qr") { quick = .qr }
                Button { advanced = true } label: {
                    VStack(spacing: 4) {
                        ToolArtwork(name: "all-tools")
                        Text("All tools").font(.system(.caption, weight: .medium)).foregroundStyle(Design.ink)
                    }.frame(maxWidth: .infinity, minHeight: 88, alignment: .top).contentShape(Rectangle())
                }.accessibilityLabel("Tools").accessibilityIdentifier("home-tools")
            }
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 26))
    }
    private func shortcut(_ title: String, icon: String, pro: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ToolArtwork(name: icon).overlay(alignment: .topTrailing) {
                    if pro { Text("PRO").font(.system(size: 8, weight: .bold)).foregroundStyle(Design.blue).padding(3).background(.white, in: Capsule()) }
                }
                Text(title).font(.system(.caption, weight: .medium)).foregroundStyle(Design.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 88, alignment: .top).contentShape(Rectangle())
        }.accessibilityLabel(title == "QR code" ? "Open QR code" : title).disabled(importing || !store.storageAvailable)
    }
    private func matchingPage(_ doc: ScanDocument) -> Int { query.isEmpty ? 0 : (doc.pages.firstIndex { $0.plainText.localizedCaseInsensitiveContains(query) } ?? 0) }
    @ViewBuilder
    private func trashAction(_ document: ScanDocument) -> some View {
        if store.storageAvailable {
            Button(role: .destructive) { store.moveToTrash(document) } label: {
                Image(systemName: "trash")
            }
            .tint(.red)
            .accessibilityLabel("Move \(document.title) to Trash")
            .accessibilityIdentifier("trash-document-" + document.id.uuidString)
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        importing = true
        Task {
            var draft: UUID?
            do {
                let id = try store.createDraft(); draft = id
                for item in items {
                    guard let bytes = try await item.loadTransferable(type: Data.self), let image = UIImage(data: bytes) else { throw ScannerError.message("A photo could not be imported. Pages already imported are saved as a draft.") }
                    let prepared = await Task.detached { Imaging.preparePhoto(image) }.value
                    try store.appendImage(prepared.0, to: id, detectedCrop: prepared.1)
                }
            } catch { store.problem = error.localizedDescription }
            importing = false; selections = []
            store.perform { try store.discardEmptyDrafts() }
            if let draft, store.document(draft)?.pages.isEmpty == false { newCapture = false; route = ScanRoute(id: draft) }
        }
    }

}
struct PageThumbnail: View {
    @EnvironmentObject var store: LibraryStore
    let page: ScanPage
    var pdfFile: String? = nil
    private struct Request: Equatable { let page: ScanPage; let pdfFile: String? }
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFit() } else { Image(systemName: "doc").foregroundStyle(.secondary) } }
            .task(id: Request(page: page, pdfFile: pdfFile)) {
                let root = store.root
                let rendered = try? await PageThumbnailCache.shared.image(for: page, root: root, pdfFile: pdfFile)
                // A slider/crop change cancels this task. An older render must
                // never repaint over the preview for the latest page settings.
                guard !Task.isCancelled else { return }
                image = rendered
            }
    }
}
struct DocumentRow: View {
    let document: ScanDocument
    var query: String = ""
    var body: some View {
        HStack(spacing: 16) {
            Group { if let page = document.pages.first { PageThumbnail(page: page, pdfFile: document.pdfFile) } else { Image(systemName: "doc") } }.frame(width: 56, height: 72).background(Design.muted, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(document.title).font(.headline).lineLimit(2)
                Text("\(document.pages.count) pages · \(document.folder)").font(.subheadline).foregroundStyle(.secondary)
                if !query.isEmpty, let index = document.pages.firstIndex(where: { $0.plainText.localizedCaseInsensitiveContains(query) }) { Text("Text match on page \(index+1)").font(.caption).foregroundStyle(Design.blue) }
                Text(document.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if document.favorite { Image(systemName: "star.fill").foregroundStyle(.orange) }
        }.foregroundStyle(Design.ink).padding(.vertical, 14)
    }
}
