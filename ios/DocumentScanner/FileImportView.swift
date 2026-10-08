import PDFKit
import SwiftUI

struct FileImportBatch: Identifiable {
  let id = UUID()
  let urls: [URL]
}
struct FileImportView: View {
  @EnvironmentObject var store: LibraryStore
  @Environment(\.dismiss) private var dismiss
  @State var urls: [URL]
  let open: (UUID) -> Void
  @State private var passwords: [URL: String] = [:]
  @State private var imported: [UUID] = []
  @State private var failures: [String] = []
  @State private var busy = false
  @State private var progress = ""
  @State private var job: Task<Void, Never>?
  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(
            "Choose the order before importing. Files stored in iCloud or another provider may need to download. Each PDF stays a separate document; selected images are grouped into one scan."
          ).font(.subheadline)
          Text(
            "PDF text and links are preserved until you crop or apply image adjustments. Originals are never overwritten."
          ).font(.caption).foregroundStyle(.secondary)
        }
        Section("Selected files") {
          ForEach(urls, id: \.self) { url in
            VStack(alignment: .leading) {
              Text(L(url.lastPathComponent))
              if url.pathExtension.lowercased() == "pdf" {
                SecureField(
                  "Password, if required",
                  text: Binding(get: { passwords[url] ?? "" }, set: { passwords[url] = $0 }))
              }
            }
          }.onMove { urls.move(fromOffsets: $0, toOffset: $1) }.onDelete {
            urls.remove(atOffsets: $0)
          }.disabled(busy)
        }
        if busy {
          Section {
            ProgressView(progress)
            Button("Cancel import") { job?.cancel() }
          }
        }
        if !failures.isEmpty {
          Section("Needs attention") {
            ForEach(failures, id: \.self) { Text($0).foregroundStyle(.red) }
          }
        }
        if !imported.isEmpty {
          Section("Imported — tap to review") {
            ForEach(imported, id: \.self) { id in
              if let doc = store.document(id) {
                Button(L(doc.title) + " · " + pagesText(doc.pages.count)) {
                  open(id)
                  dismiss()
                }.disabled(busy)
              }
            }
            Text("Imported pages are also available in Settings → Unfinished scans.").font(.caption)
          }
        }
        Button(imported.isEmpty ? "Import files" : "Retry remaining files") { run() }.disabled(
          busy || urls.isEmpty)
      }.navigationTitle("Import files").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) }
        ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(busy) }
      }.interactiveDismissDisabled(busy)
    }.onDisappear { job?.cancel() }
  }
  private func run() {
    busy = true
    failures = []
    job = Task {
      defer {
        busy = false
        job = nil
        store.perform { try store.discardEmptyDrafts() }
      }
      var imageDraft: UUID?
      for url in urls {
        do {
          try Task.checkCancellation()
          progress = "Downloading or importing \(url.lastPathComponent)…"
          if url.pathExtension.lowercased() == "pdf" {
            let id = try await store.importNativePDF(url, password: passwords[url] ?? "")
            imported.append(id)
          } else {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let local = try await CoordinatedInput.copy(url)
            defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
            let prepared = try await Task.detached { () throws -> (UIImage, ScanQuad?) in
              guard let image = UIImage(contentsOfFile: local.path) else {
                throw ScannerError.message("Image could not be read.")
              }
              return Imaging.preparePhoto(image)
            }.value
            try Task.checkCancellation()
            if imageDraft == nil { imageDraft = try store.createDraft() }
            try store.appendImage(prepared.0, to: imageDraft!, detectedCrop: prepared.1)
            if !imported.contains(imageDraft!) { imported.append(imageDraft!) }
          }
          urls.removeAll { $0 == url }
          passwords[url] = nil
        } catch is CancellationError {
          failures.append("Import canceled. Already imported pages are kept.")
          break
        } catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
      }
    }
  }
}

// File-provider coordination downloads a stable local snapshot before processing.
enum CoordinatedInput {
  static func copy(_ source: URL) async throws -> URL {
    let worker = Task.detached { () throws -> URL in
      let access = source.startAccessingSecurityScopedResource()
      defer { if access { source.stopAccessingSecurityScopedResource() } }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ScannerImport-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.complete])
      let target = directory.appendingPathComponent(source.lastPathComponent)
      var coordinationError: NSError?
      var copyError: Error?
      NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError)
      { available in
        do {
          try Task.checkCancellation()
          try FileManager.default.copyItem(at: available, to: target)
        } catch { copyError = error }
      }
      do {
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        try Task.checkCancellation()
        return target
      } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }
}
