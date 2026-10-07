import SwiftUI

struct OCRTextEditor: View {
  @EnvironmentObject var store: LibraryStore
  @Environment(\.dismiss) private var dismiss
  let documentID: UUID
  let pageIndex: Int
  @State private var blocks: [TextBlock] = []
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    NavigationStack {
      ToolPage(title: "Correct the text", subtitle: "Fixes update copied text, search and the PDF text layer. The photo stays as it is.") {
        if let doc = store.document(documentID), doc.pages.indices.contains(pageIndex), doc.pages[pageIndex].sourcePDF != nil {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TK.orange)
            Text("This imported PDF page becomes an image page with corrected text. Its links and forms are not kept.")
              .font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800).fixedSize(horizontal: false, vertical: true)
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(TK.orangeSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        ForEach(blocks.indices, id: \.self) { index in
          VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Text \(index+1)")
            TextField("Recognized text", text: $blocks[index].text, axis: .vertical)
              .font(.system(size: 17)).padding(.horizontal, 16).padding(.vertical, 14)
              .background(TK.grey50, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
              .accessibilityIdentifier("ocr-region-\(index)")
          }
        }
        if let error { Text(L(error)).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.red) }
      } actions: {
        Button("Save") { save() }.buttonStyle(CTAButtonStyle()).disabled(busy)
      }
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.disabled(busy) } }
      .overlay { if busy { BusyOverlay(text: "Updating PDF text…") } }
      .interactiveDismissDisabled(busy)
      .onAppear {
        if let doc = store.document(documentID), doc.pages.indices.contains(pageIndex) {
          blocks = doc.pages[pageIndex].textBlocks
        }
      }
    }
  }
  private func save() {
    guard var doc = store.document(documentID), doc.pages.indices.contains(pageIndex) else {
      return
    }
    for i in blocks.indices where blocks[i].text != doc.pages[pageIndex].textBlocks[i].text {
      blocks[i].words = nil
    }
    doc.pages[pageIndex].textBlocks = blocks
    doc.pages[pageIndex].correctedText = true
    doc.pages[pageIndex].ocrComplete = true
    doc.pages[pageIndex].ocrProcessingVersion = PDFExport.textProcessingVersion
    busy = true
    Task {
      do {
        let result = try await PDFExport.prepare(doc, root: store.root)
        try store.savePDF(result.data, document: result.document)
        dismiss()
      } catch { self.error = error.localizedDescription }
      busy = false
    }
  }
}
