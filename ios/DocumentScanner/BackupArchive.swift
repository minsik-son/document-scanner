import CryptoKit
import Foundation

// Version 2 is a length-delimited, streaming archive (not encrypted). Header and
// every immutable asset are checksummed; no archive-provided path is extracted.
// Old JSON v1 backups remain readable by LibraryStore.
enum BackupArchive {
  static let magic = Data("SCANBACKUP2\n".utf8)
  struct Asset: Codable {
    let name: String
    let size: UInt64
    let hash: String
  }
  struct Header: Codable {
    let manifest: LibraryManifest
    let assets: [Asset]
  }
  struct Staged {
    let manifest: LibraryManifest
    let directory: URL
    let assets: [String: URL]
  }
  static func digest(_ url: URL) throws -> (UInt64, String) {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    var size: UInt64 = 0
    while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
      try Task.checkCancellation()
      size += UInt64(chunk.count)
      hash.update(data: chunk)
    }
    return (size, hash.finalize().map { String(format: "%02x", $0) }.joined())
  }
  static func write(manifest: LibraryManifest, root: URL) throws -> URL {
    let names = Set(manifest.documents.flatMap(\.assetNames)).sorted()
    let assets = try names.map { name -> Asset in
      guard name == URL(fileURLWithPath: name).lastPathComponent else {
        throw ScannerError.message("An invalid library asset cannot be backed up.")
      }
      let value = try digest(root.appendingPathComponent(name))
      return Asset(name: name, size: value.0, hash: value.1)
    }
    let header = try JSONEncoder().encode(Header(manifest: manifest, assets: assets))
    guard header.count <= 50_000_000 else {
      throw ScannerError.message(
        "Backup metadata is too large. Remove unused reusable signatures or split the library backup."
      )
    }
    let out = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Scanner-\(UUID().uuidString).scanbackup")
    FileManager.default.createFile(
      atPath: out.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
    let file = try FileHandle(forWritingTo: out)
    do {
      try file.write(contentsOf: magic)
      var length = UInt64(header.count).bigEndian
      try withUnsafeBytes(of: &length) { try file.write(contentsOf: Data($0)) }
      try file.write(contentsOf: header)
      try file.write(contentsOf: Data(SHA256.hash(data: header)))
      for asset in assets {
        let input = try FileHandle(forReadingFrom: root.appendingPathComponent(asset.name))
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
          try Task.checkCancellation()
          try file.write(contentsOf: chunk)
        }
      }
      try file.synchronize()
      try file.close()
      return out
    } catch {
      try? file.close()
      try? FileManager.default.removeItem(at: out)
      throw error
    }
  }
  static func isStreaming(_ url: URL) throws -> Bool {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    return try file.read(upToCount: magic.count) == magic
  }
  static func stage(_ source: URL) throws -> Staged {
    let reader = try FileHandle(forReadingFrom: source)
    defer { try? reader.close() }
    func read(_ count: Int) throws -> Data {
      guard let data = try reader.read(upToCount: count), data.count == count else {
        throw ScannerError.message("The backup is incomplete.")
      }
      return data
    }
    guard try read(magic.count) == magic else {
      throw ScannerError.message("Unsupported backup format.")
    }
    let length = try read(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    guard length > 0, length <= 50_000_000 else {
      throw ScannerError.message("Invalid backup header size.")
    }
    let data = try read(Int(length))
    let expected = try read(32)
    guard Data(SHA256.hash(data: data)) == expected else {
      throw ScannerError.message("The backup metadata is damaged.")
    }
    let header = try JSONDecoder().decode(Header.self, from: data)
    guard header.manifest.version == 1, header.assets.count <= 100_000,
      Set(header.assets.map(\.name)).count == header.assets.count
    else { throw ScannerError.message("Invalid backup manifest.") }
    let assetOffset = try reader.offset()
    let fileSize = try reader.seekToEnd()
    try reader.seek(toOffset: assetOffset)
    var total = assetOffset
    for asset in header.assets {
      let next = total.addingReportingOverflow(asset.size)
      guard !next.overflow, asset.name == URL(fileURLWithPath: asset.name).lastPathComponent,
        next.partialValue <= fileSize
      else { throw ScannerError.message("Invalid backup asset length or name.") }
      total = next.partialValue
    }
    guard total == fileSize else {
      throw ScannerError.message("The backup has unexpected trailing data.")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ScannerRestore-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.complete])
    do {
      var files: [String: URL] = [:]
      for asset in header.assets {
        let url = directory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(
          atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]
        )
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var remaining = asset.size
        var hash = SHA256()
        while remaining > 0 {
          try Task.checkCancellation()
          let chunk = try read(Int(min(remaining, 1_048_576)))
          hash.update(data: chunk)
          try output.write(contentsOf: chunk)
          remaining -= UInt64(chunk.count)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.hash else {
          throw ScannerError.message("A backup asset is damaged. Nothing was restored.")
        }
        files[asset.name] = url
      }
      return Staged(manifest: header.manifest, directory: directory, assets: files)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
}
