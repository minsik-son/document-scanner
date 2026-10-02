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
      Form {
        Section {
          Text(
            "Correct recognition errors below. The photographed page stays unchanged; corrections update copied text, search and the PDF text layer."
          )
          if let doc = store.document(documentID), doc.pages.indices.contains(pageIndex),
            doc.pages[pageIndex].sourcePDF != nil
          {
            Text(
              "Editing text in an imported PDF creates an image-based page with a corrected text layer. Original links and forms on that page will not be retained."
            ).foregroundStyle(.orange)
          }
        }
        ForEach(blocks.indices, id: \.self) { index in
          Section("Text region \(index+1)") {
            TextField("Recognized text", text: $blocks[index].text, axis: .vertical)
              .accessibilityIdentifier("ocr-region-\(index)")
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.navigationTitle("Correct text").toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(busy)
        }
        ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(busy) }
      }.overlay {
        if busy { ProgressView("Updating PDF text…").padding().background(.regularMaterial) }
      }.interactiveDismissDisabled(busy)
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
