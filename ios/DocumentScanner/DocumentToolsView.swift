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
