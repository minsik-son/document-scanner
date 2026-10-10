import Foundation
import UIKit
import Combine
import CryptoKit
import PDFKit

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var manifest = LibraryManifest()
    @Published var problem: String?
    @Published private(set) var storageAvailable = true
    let root: URL
    private let fm = FileManager.default
    var documents: [ScanDocument] { manifest.documents }
    var active: [ScanDocument] { documents.filter { $0.deletedAt == nil && !$0.isDraft }.sorted { $0.updatedAt > $1.updatedAt } }
    var drafts: [ScanDocument] { documents.filter { $0.isDraft && $0.deletedAt == nil && !$0.pages.isEmpty } }
    var trash: [ScanDocument] { documents.filter { $0.deletedAt != nil } }
    private var indexURL: URL { root.appendingPathComponent("library.json") }
    convenience init(root: URL? = nil) {
        self.init(snapshot: LibraryOpening.read(root: root))
    }
    private init(snapshot: LibraryOpening.Snapshot) {
        root = snapshot.root; manifest = snapshot.manifest
        storageAvailable = snapshot.storageAvailable; problem = snapshot.problem
    }
    static func open(root: URL? = nil) async -> LibraryStore {
        let snapshot = await Task.detached(priority: .userInitiated) {
            LibraryOpening.read(root: root, maintenance: true)
        }.value
        return LibraryStore(snapshot: snapshot)
    }
    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    func document(_ id: UUID) -> ScanDocument? { documents.first { $0.id == id } }
    func commit(_ next: LibraryManifest) throws {
        guard storageAvailable else { throw ScannerError.message("Library storage is unavailable. Existing files have not been changed.") }
        let data = try JSONEncoder().encode(next)
        try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        manifest = next
    }
    func update(_ doc: ScanDocument) throws {
        var next = manifest
        var copy = doc; copy.updatedAt = Date()
        if let i = next.documents.firstIndex(where: { $0.id == doc.id }) { next.documents[i] = copy }
        else { next.documents.append(copy) }
        try commit(next)
    }
    func createDraft() throws -> UUID {
        // Opening and dismissing the camera must not grow the library. Reuse only
        // a session that has never acquired a page or a PDF; captured work is separate.
        if let existing = documents.filter(Self.isEmptyDraft).max(by: { $0.updatedAt < $1.updatedAt }) {
            var next = manifest
            next.documents.removeAll { Self.isEmptyDraft($0) && $0.id != existing.id }
            // Commit even when the record already exists so an unavailable index
            // cannot acknowledge a new capture session as ready to save.
            try commit(next)
            return existing.id
        }
        var doc = ScanDocument(title: ScanDocument.defaultTitle())
        doc.autoTitled = true
        try update(doc)
        return doc.id
    }
    func discardEmptyDrafts() throws {
        var next = manifest
        next.documents.removeAll(where: Self.isEmptyDraft)
        guard next.documents.count != manifest.documents.count else { return }
        try commit(next)
    }
    private static func isEmptyDraft(_ document: ScanDocument) -> Bool {
        document.isDraft && document.deletedAt == nil && document.pages.isEmpty && document.pdfFile == nil
    }
    func appendImage(_ image: UIImage, to id: UUID, detectedCrop: ScanQuad? = nil, enhancement: Enhancement = .document, style: CaptureStyle? = nil, turns: Int = 0) throws {
        guard var doc = document(id) else { throw ScannerError.message("This scan is no longer available.") }
        guard let data = image.jpegData(compressionQuality: 0.94) else { throw ScannerError.message("This photo couldn't be saved. Try taking it again.") }
        let name = UUID().uuidString + ".jpg"
        try data.write(to: url(name), options: [.atomic, .completeFileProtectionUnlessOpen])
        var page = ScanPage(imageFile: name)
        page.enhancement = enhancement
        page.identityBackgroundCleanup = style == .card ? true : nil
        if let style { page.enhancementStrength = style.strength; doc.captureStyle = style }
        page.cropReviewNeeded = (enhancement != .original || style != nil) && (detectedCrop == nil || detectedCrop?.valid == false)
        if let crop = detectedCrop, crop.valid { page.crop = crop }
        // A photographed sheet of paper is drawn flat (not ID cards, slides or whiteboards).
        if style == nil || style == .document { page.flatten = true }
        // Sideways capture: the photo stays as taken, the page is shown rotated.
        page.turns = ((turns % 4) + 4) % 4
        doc.pages.append(page)
        do { try update(doc) } catch { try? fm.removeItem(at: url(name)); throw error }
    }
    func discardCapturedPage(_ pageID: UUID, from documentID: UUID) throws {
        guard var doc = document(documentID), let page = doc.pages.last, page.id == pageID else {
            throw ScannerError.message("The captured page is no longer available. Your other pages have not been changed.")
        }
        doc.pages.removeLast()
        // Commit the user's cancellation before removing pixels. A failed write
        // keeps both the page and its original available for retry.
        try update(doc)
        let referenced = Set(documents.flatMap { $0.assetNames })
        if !referenced.contains(page.imageFile) { try? fm.removeItem(at: url(page.imageFile)) }
    }
    func savePDF(_ data: Data, document: ScanDocument, replacingDraft: UUID? = nil) throws {
        let name = UUID().uuidString + ".pdf"
        try data.write(to: url(name), options: [.atomic, .completeFileProtectionUnlessOpen])
        let previous = self.document(document.id)?.pdfFile
        var doc = DocumentInsight.apply(document); doc.pdfFile = name; doc.isDraft = false; doc.editingOriginalID = nil
        do {
            var next = manifest; doc.updatedAt = Date()
            if let i = next.documents.firstIndex(where: { $0.id == doc.id }) { next.documents[i] = doc } else { next.documents.append(doc) }
            if let id = replacingDraft { next.documents.removeAll { $0.id == id && $0.editingOriginalID == doc.id } }
            try commit(next)
        } catch { try? fm.removeItem(at: url(name)); throw error }
        if let previous { try? fm.removeItem(at: url(previous)) }
    }
    /// Sorts documents saved before smart sorting existed (or imported with text). Names are left alone.
    func refreshInsights() {
        var next = manifest; var changed = false
        for i in next.documents.indices where next.documents[i].kind == nil && !next.documents[i].isDraft && next.documents[i].deletedAt == nil {
            var d = next.documents[i]; let auto = d.autoTitled; d.autoTitled = false
            d = DocumentInsight.apply(d); d.autoTitled = auto
            if d.kind != nil { next.documents[i] = d; changed = true }
        }
        if changed { try? commit(next) }
    }
    func setKind(_ kind: DocumentKind, for doc: ScanDocument) { perform { var d = doc; d.kind = kind; d.kindChosen = true; try update(d) } }
    func rename(_ doc: ScanDocument, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        perform { var d = doc; d.title = clean; d.autoTitled = false; try update(d) }
    }
    func setAppLocked(_ locked: Bool, for doc: ScanDocument) { perform { var d = doc; d.appLocked = locked ? true : nil; try update(d) } }
    func setFolderLocked(_ locked: Bool, folder: String) {
        perform {
            var next = manifest; var set = Set(next.lockedFolders ?? [])
            if locked { set.insert(folder) } else { set.remove(folder) }
            next.lockedFolders = set.isEmpty ? nil : Array(set).sorted()
            try commit(next)
        }
    }
    func toggleFavorite(_ doc: ScanDocument) { perform { var d = doc; d.favorite.toggle(); try update(d) } }
    func moveToTrash(_ doc: ScanDocument) { perform { var d = doc; d.deletedAt = Date(); try update(d) } }
    func restore(_ doc: ScanDocument) { perform { var d = doc; d.deletedAt = nil; try update(d) } }
    func permanentlyDelete(_ doc: ScanDocument) throws {
        var next = manifest; next.documents.removeAll { $0.id == doc.id }; try commit(next)
        let referenced = Set(documents.flatMap { $0.assetNames })
        removeOCRCache(for: doc.pages.map(\.id))
        for name in doc.assetNames where !referenced.contains(name) {
            try? fm.removeItem(at: url(name))
        }
    }
    func purgeExpiredTrash(now: Date = Date()) throws {
        let expired = trash.filter { now.timeIntervalSince($0.deletedAt ?? now) >= 30 * 86400 }
        guard !expired.isEmpty else { return }
        let ids = Set(expired.map(\.id))
        var next = manifest; next.documents.removeAll { ids.contains($0.id) }; try commit(next)
        let referenced = Set(documents.flatMap(\.assetNames))
        removeOCRCache(for: expired.flatMap { $0.pages.map(\.id) })
        for name in Set(expired.flatMap(\.assetNames)).subtracting(referenced) { try? fm.removeItem(at: url(name)) }
    }
    func cleanAbandonedAssets(now: Date = Date()) throws {
        guard storageAvailable else { return }
        let referenced = Set(documents.flatMap(\.assetNames))
        for file in try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.contentModificationDateKey,.isRegularFileKey]) {
            guard ["jpg","pdf"].contains(file.pathExtension), UUID(uuidString:file.deletingPathExtension().lastPathComponent) != nil,
                  !referenced.contains(file.lastPathComponent) else { continue }
            let values = try file.resourceValues(forKeys:[.contentModificationDateKey,.isRegularFileKey])
            if values.isRegularFile == true, let date = values.contentModificationDate, now.timeIntervalSince(date) > 86400 { try fm.removeItem(at:file) }
        }
    }
    private func removeOCRCache(for ids: [UUID]) {
        let cache = root.appendingPathComponent("OCRCache", isDirectory: true)
        let files = (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        for file in files where ids.contains(where: { file.lastPathComponent.hasPrefix($0.uuidString + "-") }) { try? fm.removeItem(at: file) }
    }
    func recordBackupCreated() throws { var next = manifest; next.lastBackupCreated = Date(); try commit(next) }

    func saveCopies(_ copies: [(ScanDocument, Data)]) throws {
        var next = manifest
        var written: [URL] = []
        do {
            for (value, bytes) in copies {
                var doc = value; doc.id = UUID(); doc.isDraft = false; doc.createdAt = Date(); doc.updatedAt = Date(); doc.deletedAt = nil
                let name = UUID().uuidString + ".pdf"
                try bytes.write(to: url(name), options: [.atomic, .completeFileProtectionUnlessOpen]); written.append(url(name)); doc.pdfFile = name
                for i in doc.pages.indices { doc.pages[i].id = UUID() }
                next.documents.append(doc)
            }
            try commit(next)
        } catch { for file in written { try? fm.removeItem(at: file) }; throw error }
    }

    func importNativePDF(_ source: URL, password: String = "") async throws -> UUID {
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let local = try await CoordinatedInput.copy(source)
        defer { try? fm.removeItem(at:local.deletingLastPathComponent()) }
        guard let input = PDFDocument(url: local), !input.isLocked || input.unlock(withPassword: password) else { throw ScannerError.message("This PDF needs the correct password.") }
        guard input.pageCount > 0, input.pageCount <= 100 else { throw ScannerError.message("Import 1–100 PDF pages at a time.") }
        let plain = PDFDocument()
        for index in 0..<input.pageCount {
            guard let page = input.page(at: index)?.copy() as? PDFPage else { throw ScannerError.message("A PDF page is damaged.") }
            plain.insert(page, at: index)
        }
        guard let data = plain.dataRepresentation(), let check = PDFDocument(data: data), !check.isLocked else { throw ScannerError.message("This PDF couldn't be imported safely.") }
        var doc = ScanDocument(title: source.deletingPathExtension().lastPathComponent)
        doc.paper = .original; doc.margin = .none
        let original = UUID().uuidString + ".pdf"
        var written: [URL] = []
        do {
            try data.write(to: url(original), options: [.atomic, .completeFileProtectionUnlessOpen]); written.append(url(original))
            for index in 0..<plain.pageCount {
                try Task.checkCancellation()
                let snapshot = data
                let result = try await Task.detached { () throws -> (UIImage, [TextBlock]) in
                    guard let page = PDFDocument(data: snapshot)?.page(at: index) else { throw ScannerError.message("A PDF page couldn't be read.") }
                    let bounds = page.bounds(for: .mediaBox)
                    guard bounds.width > 0, bounds.height > 0 else { throw ScannerError.message("Invalid PDF page size.") }
                    return (page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox), DocumentPDF.textBlocks(page))
                }.value
                let name = UUID().uuidString + ".jpg"
                guard let bytes = result.0.jpegData(compressionQuality: 0.94) else { throw ScannerError.message("A PDF preview couldn't be saved.") }
                try bytes.write(to: url(name), options: [.atomic, .completeFileProtectionUnlessOpen]); written.append(url(name))
                var page = ScanPage(imageFile: name); page.sourcePDF = original; page.sourcePDFPage = index
                page.textBlocks = result.1; page.ocrComplete = !result.1.isEmpty; page.ocrProcessingVersion = PDFExport.textProcessingVersion
                doc.pages.append(page)
            }
            try Task.checkCancellation()
            try update(doc)
            return doc.id
        } catch { for file in written { try? fm.removeItem(at: file) }; throw error }
    }

    func makeEditingDraft(_ original: ScanDocument) throws -> UUID {
        var draft = original; draft.id = UUID(); draft.isDraft = true; draft.pdfFile = nil; draft.editingOriginalID = original.id
        try update(draft); return draft.id
    }
    func saveSignatures(_ signatures: [PageAnnotation]) throws { var next = manifest; next.signatures = signatures; try commit(next) }

    func addFolder(_ value: String) throws {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !manifest.folders.contains(name) else { return }
        var next = manifest; next.folders.append(name); try commit(next)
    }
    func perform(_ work: () throws -> Void) { do { try work() } catch { problem = error.localizedDescription } }

    struct Backup: Codable {
        var version: Int
        var manifest: LibraryManifest
        var assets: [String: Data]
        var hashes: [String: String]
    }
    func exportBackup(includeSignatures: Bool = false) throws -> URL {
        // Local, explicitly unencrypted backup. No purchases, biometric data, or diagnostics.
        var snapshot = manifest
        if !includeSignatures { snapshot.signatures = nil }
        return try BackupArchive.write(manifest:snapshot,root:root)
    }
    func exportBackupAsync(includeSignatures: Bool) async throws -> URL {
        var snapshot = manifest; if !includeSignatures { snapshot.signatures = nil }
        let root = root, value = snapshot
        let worker = Task.detached { try BackupArchive.write(manifest:value,root:root) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func importBackup(_ source: URL, keepBoth: Bool = false) throws {
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let staged = try BackupArchive.isStreaming(source) ? BackupArchive.stage(source) : nil
        defer { if let staged { try? fm.removeItem(at:staged.directory) } }
        let backup: Backup
        if let staged { backup = Backup(version:1,manifest:staged.manifest,assets:[:],hashes:[:]) }
        else {
            let size = (try source.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max
            guard size <= 280_000_000 else { throw ScannerError.message("This legacy JSON backup exceeds the safe import size. Use a new streaming backup.") }
            backup = try JSONDecoder().decode(Backup.self,from:Data(contentsOf:source))
        }
        guard backup.version == 1, backup.manifest.version == 1 else { throw ScannerError.message("This backup needs a newer app. Nothing in your library was changed.") }
        for (name,data) in backup.assets {
            guard name == URL(fileURLWithPath:name).lastPathComponent, SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == backup.hashes[name] else { throw ScannerError.message("This backup is damaged. Nothing in your library was changed.") }
        }
        try restorePayload(backup, staged: staged, keepBoth: keepBoth)
    }
    func importBackupAsync(_ source: URL, keepBoth: Bool) async throws {
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let worker = Task.detached { () throws -> BackupArchive.Staged? in
            if try BackupArchive.isStreaming(source) { return try BackupArchive.stage(source) }
            return nil
        }
        let staged = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        defer { if let staged { try? fm.removeItem(at:staged.directory) } }
        try Task.checkCancellation()
        if let staged { try restorePayload(Backup(version:1,manifest:staged.manifest,assets:[:],hashes:[:]),staged:staged,keepBoth:keepBoth) }
        else { try importBackup(source,keepBoth:keepBoth) }
    }
    private func restorePayload(_ backup: Backup, staged: BackupArchive.Staged?, keepBoth: Bool) throws {
        func assetData(_ name: String) -> Data? { if let staged { return staged.assets[name].flatMap { try? Data(contentsOf:$0) } }; return backup.assets[name] }
        guard Set(backup.manifest.documents.map(\.id)).count == backup.manifest.documents.count,
              (backup.manifest.signatures ?? []).allSatisfy({ $0.kind == .signature && $0.valid }) else { throw ScannerError.message("This backup contains invalid metadata.") }
        var next = manifest
        var written: [URL] = []
        do {
            for var doc in backup.manifest.documents {
                try Task.checkCancellation()
                if next.documents.contains(where: { $0.id == doc.id }) {
                    if !keepBoth { continue }
                    doc.id = UUID(); doc.title += " (restored copy)"
                    for i in doc.pages.indices { doc.pages[i].id = UUID() }
                }
                var copiedPDFs: [String: String] = [:]
                guard Set(doc.pages.map(\.id)).count == doc.pages.count,
                      doc.pages.allSatisfy({ $0.crop.valid && $0.trimming.valid && ($0.annotations ?? []).allSatisfy(\.valid) && $0.textBlocks.allSatisfy { block in
                          [block.x, block.y, block.width, block.height].allSatisfy(\.isFinite) && block.width >= 0 && block.height >= 0
                      } }) else { throw ScannerError.message("This backup contains invalid pages.") }
                for i in doc.pages.indices {
                    let old = doc.pages[i].imageFile
                    guard let bytes = assetData(old), UIImage(data: bytes) != nil else { throw ScannerError.message("A page is missing or damaged in this backup.") }
                    let name = UUID().uuidString + ".jpg"; try bytes.write(to: url(name), options: [.atomic, .completeFileProtectionUnlessOpen]); written.append(url(name)); doc.pages[i].imageFile = name
                }
                for i in doc.pages.indices {
                    if let old = doc.pages[i].sourcePDF {
                        guard let bytes = assetData(old), let pdf = PDFDocument(data: bytes), !pdf.isLocked,
                              let index = doc.pages[i].sourcePDFPage, index >= 0, index < pdf.pageCount else { throw ScannerError.message("An original PDF is missing or invalid.") }
                        if let copied = copiedPDFs[old] { doc.pages[i].sourcePDF = copied; continue }
                        let name = UUID().uuidString + ".pdf"
                        try bytes.write(to: url(name), options: [.atomic, .completeFileProtectionUnlessOpen]); written.append(url(name))
                        doc.pages[i].sourcePDF = name; copiedPDFs[old] = name
                    }
                }
                if let old = doc.pdfFile {
                    guard let bytes = assetData(old), let pdf = PDFDocument(data: bytes), !pdf.isLocked, pdf.pageCount == doc.pages.count else { throw ScannerError.message("A PDF is missing or damaged in this backup.") }
                    let name = UUID().uuidString + ".pdf"; try bytes.write(to: url(name), options: [.atomic, .completeFileProtectionUnlessOpen]); written.append(url(name)); doc.pdfFile = name
                }
                next.documents.append(doc)
            }
            if let signatures = backup.manifest.signatures {
                var existing = next.signatures ?? []
                for signature in signatures where !existing.contains(where: { $0.id == signature.id }) { existing.append(signature) }
                next.signatures = existing
            }
            next.folders = Array(Set(next.folders + backup.manifest.folders)).sorted()
            try commit(next)
        } catch { for file in written { try? fm.removeItem(at: file) }; throw error }
    }
}
