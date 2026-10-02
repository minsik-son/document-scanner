import SwiftUI

/// Shared artwork for Home and the complete tool directory.
struct ToolArtwork: View {
    let name: String
    var size: CGFloat = 64
    var body: some View {
        Image("tool-" + name).resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
struct ToolTile: View {
    let title: String
    let icon: String
    var pro = false
    var body: some View {
        VStack(spacing: 4) {
            ToolArtwork(name: icon, size: 64)
            Text(title).font(.system(.caption, weight: .medium)).multilineTextAlignment(.center)
                .foregroundStyle(Design.ink).fixedSize(horizontal: false, vertical: true)
            if pro { Text("PRO").font(.system(size: 9, weight: .bold)).foregroundStyle(Design.blue) }
        }.frame(maxWidth: .infinity, minHeight: 100, alignment: .top)
            .contentShape(Rectangle()).accessibilityElement(children: .ignore)
            .accessibilityLabel(title + (pro ? ", Pro" : ""))
    }
}
extension AdvancedTool {
    var icon: String {
        switch self {
        case .erase: return "eraser"
        default: return String(describing: self)
        }
    }
}

enum LibraryTool: String, Identifiable, CaseIterable {
    case ocr = "Extract text", reorder = "Reorder pages", watermark = "Watermark", timestamp = "Timestamp"
    case identity = "ID scan", longImage = "Long image", annotate = "Sign & annotate"
    case merge = "Merge documents", split = "Split PDF", extract = "Extract pages"
    case compress = "Compress PDF", protect = "Protect with password", images = "Export images", print = "Print"
    var id: String { rawValue }
    var documentTool: DocumentTool? { self == .identity ? .identity : DocumentTool(rawValue: rawValue) }
    var pro: Bool { documentTool?.pro ?? false }
    var icon: String {
        switch self {
        case .longImage: return "long-image"
        case .annotate: return "signature"
        default: return String(describing: self)
        }
    }
}
enum QuickTool: Identifiable {
    case advanced(AdvancedTool), library(LibraryTool), qr, stitch
    var id: String {
        switch self {
        case .advanced(let tool): return "advanced-" + tool.id
        case .library(let tool): return "library-" + tool.id
        case .qr: return "qr"
        case .stitch: return "stitch"
        }
    }
}
struct QuickToolView: View {
    let tool: QuickTool
    var documentID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        switch tool {
        case .advanced(let value):
            NavigationStack {
                AdvancedOfflineToolView(tool: value, documentID: documentID)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            }
        case .library(let value):
            if value == .identity { IdentityScanView() }
            else { LibraryToolPicker(tool: value, documentID: documentID) }
        case .qr: QRCodeView()
        case .stitch: ScreenshotStitchView()
        }
    }
}

/// Library tools share the existing editors and purchase gates; the directory
/// only supplies document selection when no document is already open.
struct LibraryToolPicker: View {
    let tool: LibraryTool
    var documentID: UUID? = nil
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var subscription: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: ScanRoute?
    @State private var pending: UUID?
    @State private var paywall = false
    @State private var started = false
    private var documents: [ScanDocument] {
        store.active.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ToolArtwork(name: tool.icon)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Choose a document").font(.headline)
                            Text("Select a saved PDF to get started.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if documents.isEmpty {
                    ContentUnavailableView(store.active.isEmpty ? "No saved documents" : "No matching documents", systemImage: "doc", description: Text(store.active.isEmpty ? "Scan or import a document from Home first." : "Try another document name."))
                }
                ForEach(documents) { doc in
                    Button { open(doc.id) } label: { DocumentRow(document: doc) }.buttonStyle(.plain)
                        .accessibilityIdentifier("tool-document-" + doc.id.uuidString)
                }
            }.searchable(text: $query, prompt: "Search documents")
                .navigationTitle(tool.rawValue).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .sheet(isPresented: $paywall, onDismiss: {
                    if subscription.isPro, let id = pending { selected = ScanRoute(id: id) }
                    pending = nil
                }) { PaywallView() }
                .fullScreenCover(item: $selected) { route in
                    if tool == .reorder { ReviewView(documentID: route.id) }
                    else if tool == .ocr {
                        NavigationStack {
                            DocumentView(documentID: route.id, openTextOnAppear: true)
                                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { selected = nil } } }
                        }
                    } else if let value = tool.documentTool {
                        if value.localTool { LocalDocumentToolsView(documentID: route.id, tool: value) }
                        else if value == .annotate { AnnotationEditor(documentID: route.id) }
                        else { DocumentToolsView(documentID: route.id, tool: value) }
                    }
                }
                .onAppear {
                    guard !started else { return }; started = true
                    if let id = documentID, store.document(id) != nil { open(id) }
                }
        }
    }
    private func open(_ id: UUID) {
        if tool.pro && !subscription.isPro { pending = id; paywall = true }
        else { selected = ScanRoute(id: id) }
    }
}
