import PDFKit
import SwiftUI

enum DocumentTool: String, Identifiable, CaseIterable {
  case offline = "More offline tools"
  case watermark = "Watermark"
  case timestamp = "Timestamp"
  case identity = "ID card layout"
  case longImage = "Long image"
  case annotate = "Sign & annotate"
  case merge = "Merge documents"
  case split = "Split PDF"
  case extract = "Extract pages"
  case compress = "Compress PDF"
  case protect = "Protect with password"
  case images = "Export images"
  case print = "Print"
  var localTool: Bool { [.watermark, .timestamp, .identity, .longImage].contains(self) }
  var id: String { rawValue }
  /// Signing (signature only) and merging two documents are free; the full
  /// editors are unlocked inside each tool.
  var pro: Bool { ![.offline, .images, .print, .identity, .annotate, .merge].contains(self) }
  static let freeMergeDocuments = 1
}
struct DocumentToolsView: View {
  @EnvironmentObject var store: LibraryStore
  @EnvironmentObject var subscription: SubscriptionStore
  @Environment(\.dismiss) private var dismiss
  let documentID: UUID
  let tool: DocumentTool
  @State private var paywall = false
  @State private var range = ""
  @State private var splitAfter = "1"
  @State private var selected: [UUID] = []
  @State private var preset = CompressionPreset.balanced
  @State private var png = false
  @State private var pixels = 2400
  @State private var password = ""
  @State private var repeated = ""
  @State private var busy = false
  @State private var message: String?
  @State private var share: ExportedFiles?
  @State private var job: Task<Void, Never>?
  var document: ScanDocument? { store.document(documentID) }
  var body: some View {
    NavigationStack {
      Form {
        if let doc = document {
          Section {
            Text(doc.title).font(.headline)
            Text("\(doc.pages.count) pages").foregroundStyle(.secondary)
          }
          if tool == .merge {
            Section("Add documents in this order") {
              ForEach(selected, id: \.self) { id in
                if let doc = store.document(id) { Text(doc.title) }
              }.onMove { selected.move(fromOffsets: $0, toOffset: $1) }
              ForEach(store.active.filter { $0.id != documentID && !selected.contains($0.id) }) {
                other in
                Button(other.title) {
                  if subscription.isPro || selected.count < DocumentTool.freeMergeDocuments {
                    selected.append(other.id)
                  } else { paywall = true }
                }
              }
              if !subscription.isPro {
                Text("Free: merge 2 documents. Pro: merge any number.").font(.caption)
                  .accessibilityIdentifier("merge-free-limit")
              }
              if !selected.isEmpty { Button("Clear selection") { selected = [] } }
              Text("The open document comes first. Originals are kept.").font(.caption)
            }
          }
          if tool == .extract || tool == .images {
            Section("Pages") {
              TextField("All pages, or 1, 3–5", text: $range).keyboardType(.numbersAndPunctuation)
              Text("Leave empty for all pages. Ranges use a hyphen, for example 3-5.").font(
                .caption)
            }
          }
          if tool == .split {
            Section {
              TextField("Split after page", text: $splitAfter).keyboardType(.numberPad)
              Text("Creates two new documents and keeps the original.").font(.caption)
            }
          }
          if tool == .compress {
            Section {
              Picker("Quality", selection: $preset) {
                ForEach(CompressionPreset.allCases, id: \.self) { Text($0.rawValue) }
              }
              Text(
                "Compresses scan images. Imported vector PDF pages retain their text and links. The actual size is shown after processing; a smaller file is not always possible."
              ).font(.caption)
            }
          }
          if tool == .protect {
            Section {
              SecureField("Password", text: $password)
              SecureField("Confirm password", text: $repeated)
              Text("Use 8–32 English letters, numbers, spaces or symbols.").font(.caption)
              Text(
                "Protects an exported copy only. The library document stays unchanged. A forgotten password cannot be recovered."
              ).font(.caption)
            }
          }
          if tool == .images {
            Section {
              Toggle("PNG (lossless)", isOn: $png)
              Picker("Longest side", selection: $pixels) {
                Text("1200 px").tag(1200)
                Text("2400 px").tag(2400)
                Text("3600 px").tag(3600)
              }
            }
          }
          if busy {
            Section {
              ProgressView("Preparing your document…")
              Button("Cancel operation") { job?.cancel() }
            }
          }
          if let message { Section { Text(message).accessibilityIdentifier("tool-result") } }
          Section {
            Button(
              tool == .protect || tool == .images
                ? "Prepare export" : (tool == .print ? "Open print options" : "Create copy")
            ) { run() }.disabled(
              busy || (tool == .protect && (password.isEmpty || password != repeated)))
          }
        }
      }.navigationTitle(tool.rawValue).navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }.disabled(busy).accessibilityIdentifier("document-tool-close")
          }
          if tool == .merge { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        }
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $paywall) { PaywallView() }
        .sheet(item: $share, onDismiss: { ExportFiles.cleanExpired() }) { files in
          ShareSheet(items: files.urls, completion: { _, _ in ExportFiles.remove(files.directory) })
        }
    }.onDisappear { job?.cancel() }
  }
  private func run() {
    guard let doc = document else { return }
    if tool == .print {
      guard let file = doc.pdfFile else {
        message = "Save the PDF first."
        return
      }
      let printer = UIPrintInteractionController.shared
      printer.printingItem = store.url(file)
      printer.present(animated: true) { _, _, error in
        if let error { message = error.localizedDescription }
      }
      return
    }
    busy = true
    message = nil
    let root = store.root
    job = Task { @MainActor in
      defer {
        busy = false
        job = nil
      }
      do {
        if tool == .protect {
          guard password == repeated, !password.isEmpty, let file = doc.pdfFile else {
            throw ScannerError.message("Check the password and save your PDF first.")
          }
          let secret = password
          let bytes = try await Task.detached {
            try DocumentPDF.protect(
              Data(contentsOf: root.appendingPathComponent(file)), password: secret)
          }.value
          try Task.checkCancellation()
          share = try ExportFiles.write([(doc.title + "-protected.pdf", bytes)])
          password = ""
          repeated = ""
        } else if tool == .images {
          let indices = try PageRange.parse(range, count: doc.pages.count)
          let format = png
          let limit = pixels
          guard let file = doc.pdfFile else { throw ScannerError.message("Save the PDF first.") }
          share = try await Task.detached {
            guard let pdf = PDFDocument(url: root.appendingPathComponent(file)) else {
              throw ScannerError.message("PDF unavailable.")
            }
            return try ExportFiles.images(pdf, indices: indices, pixels: limit, png: format)
          }.value
          if Task.isCancelled, let files = share {
            ExportFiles.remove(files.directory)
            share = nil
            throw CancellationError()
          }
        } else {
          var copies: [ScanDocument] = []
          if tool == .merge {
            guard !selected.isEmpty else {
              throw ScannerError.message("Choose another document to merge.")
            }
            var copy = doc
            copy.title += " (merged)"
            for id in selected { if let other = store.document(id) { copy.pages += other.pages } }
            copies = [copy]
          } else if tool == .split {
            guard let n = Int(splitAfter), n > 0, n < doc.pages.count else {
              throw ScannerError.message(
                "Enter a page between 1 and \(max(1, doc.pages.count - 1)).")
            }
            var first = doc
            var second = doc
            first.title += " (part 1)"
            second.title += " (part 2)"
            first.pages = Array(doc.pages.prefix(n))
            second.pages = Array(doc.pages.dropFirst(n))
            copies = [first, second]
          } else {
            var copy = doc
            if tool == .extract {
              copy.pages = try PageRange.parse(range, count: doc.pages.count).map { doc.pages[$0] }
              copy.title += " (extracted)"
            } else {
              copy.title += " (compressed)"
            }
            copies = [copy]
          }
          var ready: [(ScanDocument, Data)] = []
          let quality = preset
          for var copy in copies {
            try Task.checkCancellation()
            copy.searchable = copy.pages.contains { !$0.textBlocks.isEmpty }
            let snapshot = copy
            let compress = tool == .compress
            let bytes = try await Task.detached {
              try DocumentPDF.compose(snapshot, root: root, compression: compress ? quality : nil)
            }.value
            ready.append((copy, bytes))
          }
          try Task.checkCancellation()
          try store.saveCopies(ready)
          if tool == .compress, let data = ready.first?.1 {
            let before = doc.pdfFile.flatMap { try? Data(contentsOf: store.url($0)).count } ?? 0
            message =
              "Copy saved. Original: \(ByteCountFormatter.string(fromByteCount: Int64(before), countStyle: .file)). Copy: \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))."
          } else {
            message = "\(ready.count) new document(s) saved. Your originals are unchanged."
          }
        }
      } catch is CancellationError {
        message = "Canceled. Your original documents are unchanged."
      } catch { message = error.localizedDescription }
    }
  }
}
enum PageRange {
  static func parse(_ text: String, count: Int) throws -> [Int] {
    guard count > 0 else { throw ScannerError.message("This document has no pages.") }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Array(0..<count) }
    var result: [Int] = []
    for piece in text.replacingOccurrences(of: "–", with: "-").split(
      separator: ",", omittingEmptySubsequences: false)
    {
      let ends = piece.trimmingCharacters(in: .whitespaces).split(
        separator: "-", omittingEmptySubsequences: false)
      guard ends.count == 1 || ends.count == 2,
        let first = Int(ends[0].trimmingCharacters(in: .whitespaces)),
        let last = Int(ends.last!.trimmingCharacters(in: .whitespaces)), first > 0, last >= first,
        last <= count
      else {
        throw ScannerError.message("Use page numbers from 1 to \(count), for example 1, 3-5.")
      }
      for i in first...last where !result.contains(i - 1) { result.append(i - 1) }
    }
    return result
  }
}
struct ExportedFiles: Identifiable {
  let id = UUID()
  let directory: URL
  let urls: [URL]
}
enum ExportFiles {
  static var root: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "ScannerExports", isDirectory: true)
  }
  static func write(_ files: [(String, Data)]) throws -> ExportedFiles {
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      let urls = try files.enumerated().map { index, item -> URL in
        let safe = item.0.replacingOccurrences(of: "/", with: "_").replacingOccurrences(
          of: ":", with: "_")
        let url = directory.appendingPathComponent("\(index+1)-" + safe)
        try item.1.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        return url
      }
      return ExportedFiles(directory: directory, urls: urls)
    } catch {
      remove(directory)
      throw error
    }
  }
  static func images(_ pdf: PDFDocument, indices: [Int], pixels: Int, png: Bool) throws
    -> ExportedFiles
  {
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      var urls: [URL] = []
      for index in indices {
        let url = try autoreleasepool { () throws -> URL in
          guard let page = pdf.page(at: index) else {
            throw ScannerError.message("Page unavailable.")
          }
          let image = page.thumbnail(of: CGSize(width: pixels, height: pixels), for: .mediaBox)
          guard let bytes = png ? image.pngData() : image.jpegData(compressionQuality: 0.94) else {
            throw ScannerError.message("Image export failed.")
          }
          let url = directory.appendingPathComponent("Page-\(index+1)." + (png ? "png" : "jpg"))
          try bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
          return url
        }
        urls.append(url)
      }
      return ExportedFiles(directory: directory, urls: urls)
    } catch {
      remove(directory)
      throw error
    }
  }
  static func remove(_ directory: URL) {
    if directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
      try? FileManager.default.removeItem(at: directory)
    }
  }
  static func cleanExpired() {
    let directories =
      (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
    for url in directories {
      if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
        Date().timeIntervalSince(date) > 86400
      {
        remove(url)
      }
    }
  }
}
