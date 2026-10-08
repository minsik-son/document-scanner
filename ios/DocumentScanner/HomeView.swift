import SwiftUI
import StoreKit
import PhotosUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject private var ads: HomeAdvertisementStore
    @EnvironmentObject private var subscription: SubscriptionStore
    @AppStorage(QuickToolPrefs.key) private var quickToolsRaw = ""
    @State private var editingQuickTools = false
    @State private var paywall = false
    @State private var welcomePro = false
    @State private var firstScanDone = false
    @AppStorage(OnboardingFlags.startScan) private var startScanFromIntro = false
    @AppStorage(OnboardingFlags.scanTip) private var scanTip = false
    @AppStorage(OnboardingFlags.firstScanPending) private var firstScanPending = false
    @AppStorage("pro-welcome-shown") private var welcomeShown = false
    /// Scans saved from Home; the third one brings a one-time Pro card and a review prompt.
    @AppStorage("home-saved-count") private var savedCount = 0
    /// 0 not yet, 1 showing, 2 closed for good.
    @AppStorage("home-pro-card") private var proCard = 0
    @AppStorage("pro-purchased-at") private var purchasedAt = 0.0
    @State private var query = ""
    @State private var kindFilter: DocumentKind?
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
        store.active.filter { (tab != "Favorites" || $0.favorite) && (folder == nil || $0.folder == folder) && (kindFilter == nil || $0.kind == kindFilter) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || (!PrivateLock.isLocked($0, in: store.manifest) && $0.text.localizedCaseInsensitiveContains(query))) }
    }
    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 18) {
                    // Like many utility apps: no screen title. Pro sits top left
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
                        scanCard
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
                        let kindCounts = Dictionary(grouping: store.active.compactMap(\.kind), by: { $0 }).mapValues(\.count)
                        let kinds = DocumentKind.allCases.filter { $0 != .other && (kindCounts[$0] ?? 0) > 0 }
                        if tab != "Folders" && !kinds.isEmpty {
                            // Sorted on this iPhone from each document's text.
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(kinds) { kind in
                                        Button { kindFilter = kindFilter == kind ? nil : kind } label: {
                                            Label("\(kind.plural) \(kindCounts[kind] ?? 0)", systemImage: kind.symbol).font(.footnote.weight(.semibold))
                                                .padding(.horizontal, 12).padding(.vertical, 7)
                                                .background(kindFilter == kind ? Design.blue.opacity(0.1) : .white, in: Capsule())
                                        }.foregroundStyle(kindFilter == kind ? Design.blue : .secondary)
                                            .accessibilityIdentifier("kind-filter-" + kind.rawValue)
                                    }
                                }
                            }.scrollIndicators(.hidden)
                        }
                        if tab == "Folders" {
                            ScrollView(.horizontal) {
                                HStack { ForEach(store.manifest.folders, id: \.self) { name in
                                    Button(L(name)) { folder = folder == name ? nil : name }.padding(12)
                                        .background(folder == name ? Design.blue.opacity(0.1) : .white, in: Capsule())
                                } }
                            }.scrollIndicators(.hidden)
                        }
                    }
                }.padding(.top, 4).padding(.bottom, 8)
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                if showsProCard {
                    proTrialCard
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                if filtered.isEmpty {
                    VStack(spacing: 16) {
                        ToolArtwork(name: "scan", size: 72)
                        Text(query.isEmpty ? "Paperwork, simplified" : "No documents found").font(.title2.bold())
                        Text(query.isEmpty ? "Scan a page. Save a PDF.\nEverything stays on this iPhone." : "Try another document name.").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 28).background(.white, in: RoundedRectangle(cornerRadius: 24))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))
                    if showsAd { adRow }
                } else if grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 20) {
                        ForEach(filtered) { doc in
                            NavigationLink { DocumentView(documentID: doc.id, initialPage: matchingPage(doc)) } label: {
                                VStack { if PrivateLock.isLocked(doc, in: store.manifest) { LockedThumb().frame(height: 150) } else if let page = doc.pages.first { PageThumbnail(page: page, pdfFile: doc.pdfFile).frame(height: 150) }; Text(L(doc.title)).font(.headline).lineLimit(2); Text("\(doc.pages.count) pages").font(.caption) }.padding(12).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 20))
                            }.buttonStyle(.plain).contextMenu { trashAction(doc) }
                        }
                    }.listRowSeparator(.hidden).listRowBackground(Color.clear)
                    if showsAd { adRow }
                } else {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, doc in
                        NavigationLink { DocumentView(documentID: doc.id, initialPage: matchingPage(doc)) } label: { DocumentRow(document: doc, query: query).padding(.horizontal, 14).background(.white, in: RoundedRectangle(cornerRadius: 20)) }
                            .accessibilityIdentifier("document-row-" + doc.id.uuidString)
                            .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                            // Native List actions arbitrate horizontal swipes against scrolling
                            // and navigation, including reversal and full-swipe cancellation.
                            .swipeActions(edge: .leading, allowsFullSwipe: true) { trashAction(doc) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) { trashAction(doc) }
                        // Free users: one ad below the third document, or after the last when there are fewer.
                        if showsAd && index == min(2, filtered.count - 1) { adRow }
                    }
                }
            }
            .id(showingDocuments)
            .listStyle(.plain)
            .onScrollPhaseChange { _, phase in ads.setScrolling(phase != .idle) }
            .scrollContentBackground(.hidden)
            .background { if subscription.isPro { ProPageBackground(band: 118) } else { Design.muted.ignoresSafeArea() } }
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.defaultMinListRowHeight, 0)
            .disabled(importing)
            .safeAreaInset(edge: .bottom) {
                bottomNavigation
            }
            .overlay { if importing { ProgressView("Importing pages…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .fullScreenCover(isPresented: $advanced) { AdvancedOfflineHub() }
            .sheet(isPresented: $paywall) { PaywallView(start: .general) }
            .fullScreenCover(isPresented: $welcomePro) { WelcomeToProView() }
            .fullScreenCover(isPresented: $firstScanDone) {
                FirstScanDoneView(seeDocument: { firstScanDone = false; showingDocuments = true }, goHome: { firstScanDone = false })
            }
            .onAppear {
                if purchasedAt > 0, Date().timeIntervalSince1970 - purchasedAt > 86400 { ReviewPrompter.request(.dayAfterPurchase) }
                // "Scan now" on the last intro page opens the camera straight away.
                if startScanFromIntro { startScanFromIntro = false; startCapture() }
                if !store.active.isEmpty { scanTip = false }
            }
            .onChange(of: subscription.isPro) { _, pro in
                // After a purchase (not on launch): wait for the paywall sheet to close.
                guard pro, !welcomeShown else { return }
                if purchasedAt == 0 { purchasedAt = Date().timeIntervalSince1970 }
                welcomeShown = true
                Task { try? await Task.sleep(for: .seconds(0.7)); welcomePro = true }
            }
            .fullScreenCover(item: $quick) { QuickToolView(tool: $0) }
            .sheet(isPresented: $editingQuickTools) { QuickToolsEditor() }
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
                           onCompleted: { showingDocuments = false; query = ""; celebrateFirstScan(); countSave() }, savedBackTitle: "Home")
            }
            .confirmationDialog("Import pages", isPresented: $importMenu) {
                Button("Choose photos") { photos = true }
                Button("Choose PDF or image") { files = true }
            } message: { Text("PDF text and links are preserved. Image adjustments may require converting a page to an image.") }
            .task { store.refreshInsights() }
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
    private func startCapture() {
        scanTip = false
        store.perform { let id = try store.createDraft(); newCapture = true; Instant.run { route = ScanRoute(id: id) } }
    }
    private var homeUncovered: Bool {
        route == nil && !advanced && quick == nil && !settings && !paywall && !photos && !files && !importMenu && !importing && fileBatch == nil
    }
    private var showsAd: Bool { query.isEmpty && !showingDocuments && !subscription.isPro }
    private var adRow: some View {
        HomeAdvertisementSlot(homeUncovered: homeUncovered, reserveSpace: false) { EmptyView() }
            .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
    private var showsProCard: Bool { proCard == 1 && !subscription.isPro && query.isEmpty && !showingDocuments }
    /// After the third saved scan, once: what Pro adds. Never a full-screen paywall.
    private var proTrialCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(subscription.trialEligible && subscription.trialDays != nil ? "Try Pro free for \(subscription.trialDays ?? 7) days" : "Get more done with Pro")
                    .font(.headline).foregroundStyle(Design.ink)
                Spacer()
                Button { proCard = 2 } label: { Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel("Close").accessibilityIdentifier("home-pro-card-close")
            }
            Text("Word export, photo translation, PDF tools and no ads. Cancel anytime.").font(.subheadline).foregroundStyle(TK.grey700)
            Button { proCard = 2; paywall = true } label: {
                Text("See what's in Pro").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9).background(TK.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }.buttonStyle(.plain).padding(.top, 4).accessibilityIdentifier("home-pro-card-open")
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(TK.blueSoft, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("home-pro-card")
    }
    private func countSave() {
        savedCount += 1
        guard savedCount == 3 else { return }
        if proCard == 0 && !subscription.isPro { proCard = 1 }
        ReviewPrompter.request(.thirdSave)
    }
    /// The first page ever saved after the intro gets a short celebration.
    private func celebrateFirstScan() {
        guard firstScanPending, !store.active.isEmpty else { return }
        firstScanPending = false
        Task { try? await Task.sleep(for: .seconds(0.6)); firstScanDone = true }
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
                startCapture()
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(subscription.isPro ? AnyShapeStyle(ProTheme.action) : AnyShapeStyle(Design.cameraBlue), in: Circle())
                    .overlay { Circle().stroke(.white, lineWidth: 5).padding(-5) }
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
        .overlay(alignment: .top) {
            // After "Maybe later": one tip over the camera button, gone after a tap or a scan.
            if scanTip && store.active.isEmpty {
                Button { scanTip = false } label: {
                    Text("Ready when you are. Tap here to scan")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Design.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Design.ink).frame(width: 12, height: 12).rotationEffect(.degrees(45)).offset(y: 5)
                        }
                }
                .buttonStyle(.plain).offset(y: -50).transition(.opacity)
                .accessibilityIdentifier("home-scan-tip")
            }
        }
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
                Text(L(title)).font(.system(.caption2, weight: selected ? .bold : .medium))
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
                    startCapture()
                } label: {
                    Label("Scan", systemImage: "camera").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .foregroundStyle(subscription.isPro ? .white : Design.blueInk)
                        .background(subscription.isPro ? AnyShapeStyle(ProTheme.action) : AnyShapeStyle(Design.pastelBlue), in: Capsule())
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
                Button { editingQuickTools = true } label: {
                    Text("Edit").font(.caption.weight(.semibold)).foregroundStyle(TK.grey600)
                        .padding(.vertical, 6).padding(.horizontal, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("home-edit-quick-tools")
                Button { advanced = true } label: {
                    HStack(spacing: 2) {
                        Text("More tools")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }.font(.caption.weight(.semibold)).foregroundStyle(TK.blue)
                    .padding(.vertical, 6).padding(.leading, 8).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("home-more-tools")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 4) {
                ForEach(quickTools) { item in shortcut(item) }
                Button { advanced = true } label: {
                    VStack(spacing: 4) {
                        ToolArtwork(name: "all-tools")
                        Text("All tools").font(.system(.caption, weight: .medium)).foregroundStyle(Design.ink)
                    }.frame(maxWidth: .infinity, minHeight: 88, alignment: .top).contentShape(Rectangle())
                }.accessibilityLabel("Tools").accessibilityIdentifier("home-tools")
            }
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 26))
    }
    private var quickTools: [HomeShortcut] { QuickToolPrefs.load(quickToolsRaw, pro: subscription.isPro) }
    private func open(_ item: HomeShortcut) {
        switch item {
        case .photos: photos = true
        case .qr: quick = .qr
        case .stitch: quick = .stitch
        case .library(let tool): quick = .library(tool)
        case .advanced(let tool): quick = .advanced(tool)
        }
    }
    private func shortcut(_ item: HomeShortcut) -> some View {
        Button { open(item) } label: {
            VStack(spacing: 4) {
                ToolArtwork(name: item.icon).overlay(alignment: .topTrailing) {
                    if item.pro { ProBadge().offset(x: 6, y: -4) }
                }
                Text(L(item.title)).font(.system(.caption, weight: .medium)).foregroundStyle(Design.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 88, alignment: .top).contentShape(Rectangle())
        }.accessibilityLabel(item == .qr ? "Open QR code" : item.title).disabled(importing || !store.storageAvailable)
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
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    var query: String = ""
    private var locked: Bool { PrivateLock.isLocked(document, in: store.manifest) }
    var body: some View {
        HStack(spacing: 16) {
            Group { if locked { LockedThumb() } else if let page = document.pages.first { PageThumbnail(page: page, pdfFile: document.pdfFile) } else { Image(systemName: "doc") } }.frame(width: 56, height: 72).background(Design.muted, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(L(document.title)).font(.headline).lineLimit(2)
                Text("\(document.pages.count) pages · \(document.kind.map { $0 == .other ? document.folder : $0.label } ?? document.folder)").font(.subheadline).foregroundStyle(.secondary)
                if !query.isEmpty, !locked, let index = document.pages.firstIndex(where: { $0.plainText.localizedCaseInsensitiveContains(query) }) { Text("Text match on page \(index+1)").font(.caption).foregroundStyle(Design.blue) }
                Text(document.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if document.favorite { Image(systemName: "star.fill").foregroundStyle(.orange) }
        }.foregroundStyle(Design.ink).padding(.vertical, 14)
    }
}


/// Stands in for a locked document's first page.
struct LockedThumb: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Design.blue.opacity(0.08))
            Image(systemName: "lock.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Design.blue)
        }.accessibilityLabel("Locked")
    }
}

/// Asks for an App Store rating only at good moments, once each: right after the
/// third saved scan, after sharing a Pro tool's result for the first time, and the
/// day after someone becomes Pro. iOS still decides whether the prompt appears.
@MainActor
enum ReviewPrompter {
    enum Moment: String { case thirdSave, firstProShare, dayAfterPurchase }
    static func request(_ moment: Moment) {
        let info = ProcessInfo.processInfo
        if info.environment["XCTestConfigurationFilePath"] != nil || info.arguments.contains("--ui-test-session") { return }
        let key = "review-asked-" + moment.rawValue
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task { try? await Task.sleep(for: .seconds(1)); AppStore.requestReview(in: scene) }
    }
}
