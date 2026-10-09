import Foundation

/// Used before the observable store is exposed, so maintenance cannot race edits/imports.
enum LibraryOpening {
    struct Snapshot {
        let root: URL
        var manifest = LibraryManifest()
        var problem: String?
        var storageAvailable = true
    }
    static func read(root: URL?, maintenance: Bool = false) -> Snapshot {
        let fm = FileManager.default
        let root = root ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DocumentScanner", isDirectory: true)
        var result = Snapshot(root: root)
        let index = root.appendingPathComponent("library.json")
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            if fm.fileExists(atPath: index.path) {
                result.manifest = try JSONDecoder().decode(LibraryManifest.self, from: Data(contentsOf: index))
                guard result.manifest.version == 1 else {
                    throw ScannerError.message("This library needs a newer version of the app. Your files have not been changed.")
                }
            }
        } catch {
            result.storageAvailable = false
            result.problem = "Your library couldn't be opened. Your files have not been changed. \(error.localizedDescription)"
            return result
        }
        guard maintenance else { return result }
        // Thumbnails saved before cache v5 were keyed by the container path, which
        // iOS changes on every update, so each update left a whole unused set behind.
        // Clear them once; current thumbnails are rebuilt on demand.
        let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
        let marker = thumbnails.appendingPathComponent(".cache-v5")
        if !fm.fileExists(atPath: marker.path) {
            try? fm.removeItem(at: thumbnails)
            try? fm.createDirectory(at: thumbnails, withIntermediateDirectories: true)
            fm.createFile(atPath: marker.path, contents: Data())
        }
        do {
            let now = Date()
            let expired = result.manifest.documents.filter { $0.deletedAt.map { now.timeIntervalSince($0) >= 30 * 86400 } ?? false }
            if !expired.isEmpty {
                let ids = Set(expired.map(\.id))
                var next = result.manifest
                next.documents.removeAll { ids.contains($0.id) }
                // Commit index before removing assets; a failed write retains all data.
                try JSONEncoder().encode(next).write(to: index, options: [.atomic, .completeFileProtectionUnlessOpen])
                result.manifest = next
                let referenced = Set(next.documents.flatMap(\.assetNames))
                for name in Set(expired.flatMap(\.assetNames)).subtracting(referenced) {
                    try? fm.removeItem(at: root.appendingPathComponent(name))
                }
                let pageIDs = Set(expired.flatMap { $0.pages.map { $0.id.uuidString } })
                let cache = root.appendingPathComponent("OCRCache")
                for file in (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
                    if pageIDs.contains(String(file.lastPathComponent.prefix(36))) { try? fm.removeItem(at: file) }
                }
            }
            let referenced = Set(result.manifest.documents.flatMap(\.assetNames))
            for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
                guard ["jpg", "pdf"].contains(file.pathExtension), UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                      !referenced.contains(file.lastPathComponent) else { continue }
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                if values.isRegularFile == true, let date = values.contentModificationDate, now.timeIntervalSince(date) > 86400 {
                    try fm.removeItem(at: file)
                }
            }
            // Bound disposable thumbnail storage to 64 MB, keeping the newest files.
            let files = (try? fm.contentsOfDirectory(at: root.appendingPathComponent("Thumbnails"), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            let entries = files.compactMap { file -> (URL, Date, Int)? in
                guard let value = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
                return (file, value.contentModificationDate ?? .distantPast, value.fileSize ?? 0)
            }.sorted { $0.1 > $1.1 }
            var bytes = 0
            for (file, _, size) in entries { bytes += size; if bytes > 64 * 1024 * 1024 { try? fm.removeItem(at: file) } }
        } catch { result.problem = error.localizedDescription }
        ExportFiles.cleanExpired()
        return result
    }
}
