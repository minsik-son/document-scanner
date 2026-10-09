import SwiftUI

/// What to do with a finished scan, in one row: share the PDF or turn it into
/// Word, Excel, PowerPoint or pictures without going through the Tools tab.
/// Office conversions use the same free tries as the tools (then Pro).
struct DocumentExportBar: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var subscription: SubscriptionStore
    let documentID: UUID
    @State private var route: Route?

    enum Route: String, Identifiable {
        case word, excel, slides, images
        var id: String { rawValue }
        var tool: AdvancedTool? {
            switch self { case .word: return .word; case .excel: return .excel; case .slides: return .slides; case .images: return nil }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if let doc = store.document(documentID), let file = doc.pdfFile {
                ShareLink(item: SharedPDF.url(for: store.url(file), title: doc.title)) {
                    item("PDF", systemImage: "square.and.arrow.up", pro: false)
                }
                .accessibilityLabel(L("Send as PDF")).accessibilityIdentifier("export-pdf")
            }
            button(.word, "Word", "doc.text")
            button(.excel, "Excel", "tablecells")
            button(.slides, "PPT", "rectangle.on.rectangle")
            button(.images, "Images", "photo.on.rectangle")
        }
        .padding(.top, 8).padding(.bottom, 4)
        .background(.white)
        .overlay(alignment: .top) { Divider() }
        .sheet(item: $route) { route in
            if let tool = route.tool {
                NavigationStack {
                    AdvancedOfflineToolView(tool: tool, documentID: documentID, autoStart: true)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { self.route = nil }.accessibilityIdentifier("export-close") } }
                }
            } else {
                PDFToolFlow(tool: .images, documentID: documentID)
            }
        }
    }

    private func button(_ r: Route, _ title: String, _ symbol: String) -> some View {
        Button { route = r } label: { item(title, systemImage: symbol, pro: r != .images && !subscription.isPro) }
            .buttonStyle(.plain)
            .accessibilityLabel(r == .images ? L("Save as images") : String(format: L("Convert to %@"), title))
            .accessibilityIdentifier("export-" + r.rawValue)
    }

    private func item(_ title: String, systemImage: String, pro: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 21, weight: .medium))
                .frame(height: 26)
                .overlay(alignment: .topTrailing) {
                    if pro {
                        Image(systemName: "crown.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(3).background(Color.orange, in: Circle()).offset(x: 10, y: -6)
                            .accessibilityHidden(true)
                    }
                }
            Text(L(title)).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(TK.grey900)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
    }
}
