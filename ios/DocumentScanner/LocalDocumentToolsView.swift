import SwiftUI
import PhotosUI
import PDFKit

struct LocalDocumentToolsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let documentID: UUID
    let tool: DocumentTool
    @State private var stamp = DocumentStamp()
    @State private var pageRange = ""
    @State private var date = Date()
    @State private var includeTime = true
    @State private var front = 0
    @State private var back = 1
    @State private var bothSides = true
    @State private var paper = PaperSize.a4
    @State private var width = 1080
    @State private var gap = 0
    @State private var logo: PhotosPickerItem?
    @State private var previewFiles: ExportedFiles?
    @State private var share: ExportedFiles?
    @State private var pdfData: Data?
    @State private var busy = false
    @State private var message: String?
    @State private var saved = false
    @State private var job: Task<Void, Never>?
    private var doc: ScanDocument? { store.document(documentID) }
    var body: some View {
        NavigationStack {
            Form {
                if let doc {
                    if let files = previewFiles {
                        Section("Preview") {
                            if pdfData != nil, let url = files.urls.first { PDFPreview(url: url).frame(height: 350).accessibilityIdentifier("local-tool-preview") }
                            else {
                                ForEach(files.urls, id: \.self) { url in
                                    if let image = LocalDocumentTools.previewImage(url) {
                                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 500)
                                    }
                                }
                                Text("\(files.urls.count) PNG file(s). Tall results are split into numbered parts.").font(.caption)
                            }
                            Button("Change settings") { clearPreview() }.disabled(busy)
                        }
                        Section {
                            if pdfData != nil { Button("Save copy") { saveCopy() }.disabled(busy || saved).accessibilityIdentifier("local-tool-save") }
                            Button("Share") { share = files }.disabled(busy)
                        }
                    } else {
                        if tool == .identity {
                            Section("Card sides") {
                                Text("Crop each scan tightly to the card edges first. Photos are fitted without stretching.").font(.footnote)
                                Picker("Front", selection: $front) { ForEach(doc.pages.indices, id: \.self) { Text("Page \($0+1)").tag($0) } }
                                Toggle("Include back", isOn: $bothSides).disabled(doc.pages.count < 2)
                                if bothSides { Picker("Back", selection: $back) { ForEach(doc.pages.indices, id: \.self) { Text("Page \($0+1)").tag($0) } } }
                                Picker("Paper", selection: $paper) { Text("A4").tag(PaperSize.a4); Text("US Letter").tag(PaperSize.letter) }
                                Text("Fits each side inside an 85.6 × 53.98 mm card area. Print at 100% for that size.").font(.caption)
                            }
                        } else {
                            Section("Pages") { TextField("All pages, or 1, 3–5", text: $pageRange).accessibilityIdentifier("local-tool-pages") }
                            if tool == .longImage {
                                Section("Image") {
                                    Picker("Width", selection: $width) { Text("720 px").tag(720); Text("1080 px").tag(1080); Text("1440 px").tag(1440) }
                                    Picker("Page gap", selection: $gap) { Text("None").tag(0); Text("Small").tag(12); Text("Wide").tag(32) }
                                    Text("PNG images retain the appearance of your PDF. Text selection stays available in the original PDF.").font(.caption)
                                }
                            } else {
                                stampSettings
                                Section { Text("Creates a new PDF. Original text and links are retained; interactive forms are flattened. Your original document is kept.").font(.caption) }
                            }
                        }
                        Section { Button("Preview") { prepare() }.disabled(busy || (tool == .identity && bothSides && front == back)).accessibilityIdentifier("local-tool-prepare") }
                    }
                    if busy { Section { ProgressView("Preparing on this iPhone…"); Button("Cancel operation") { job?.cancel() } } }
                    if let message { Section { Text(L(message)).accessibilityIdentifier("local-tool-result") } }
                }
            }
            .navigationTitle(L(tool.rawValue)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .sheet(item: $share) { files in ShareSheet(items: files.urls) }
            .onAppear {
                date = doc?.createdAt ?? Date(); bothSides = (doc?.pages.count ?? 0) > 1
                if tool == .timestamp { stamp.opacity = 0.9; stamp.angle = 0; stamp.width = 0.5; stamp.position = .bottomRight }
            }
            .onChange(of: logo) { _, item in
                guard let item else { return }
                busy = true
                job = Task {
                    defer { busy = false }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw ScannerError.message("The logo couldn't be read.") }
                        let image = try await Task.detached { try LocalDocumentTools.thumbnail(data, maxPixels: 800) }.value
                        try Task.checkCancellation(); stamp.logo = image.pngData()
                    } catch { message = error.localizedDescription }
                }
            }
            .onDisappear { job?.cancel(); if let files = previewFiles { ExportFiles.remove(files.directory) } }
        }
    }
    @ViewBuilder private var stampSettings: some View {
        Section(tool == .timestamp ? "Timestamp" : "Watermark") {
            if tool == .timestamp {
                DatePicker("Date", selection: $date, displayedComponents: includeTime ? [.date, .hourAndMinute] : [.date])
                Toggle("Include time", isOn: $includeTime)
                Text("Defaults to the document date. You can change it; this is a label, not a certified capture time.").font(.caption)
            } else {
                TextField("Watermark text", text: $stamp.text).accessibilityIdentifier("watermark-text")
                PhotosPicker("Choose logo", selection: $logo, matching: .images)
                if stamp.logo != nil { Button("Use text instead") { stamp.logo = nil; logo = nil } }
                Toggle("Repeat across page", isOn: $stamp.repeated)
                LabeledContent("Angle", value: "\(Int(stamp.angle))°")
                Slider(value: $stamp.angle, in: -90...90, step: 5).accessibilityLabel("Watermark angle")
            }
            if !stamp.repeated { Picker("Position", selection: $stamp.position) { ForEach(StampPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) } } }
            LabeledContent("Opacity", value: "\(Int(stamp.opacity*100))%")
            Slider(value: $stamp.opacity, in: 0.05...1).accessibilityLabel("Watermark opacity")
            LabeledContent("Size", value: "\(Int(stamp.width*100))%")
            Slider(value: $stamp.width, in: 0.1...0.8).accessibilityLabel("Watermark size")
        }.disabled(busy)
    }
    private func clearPreview() {
        if let files = previewFiles { ExportFiles.remove(files.directory) }
        previewFiles = nil; pdfData = nil; saved = false; message = nil
    }
    private func prepare() {
        guard let doc, let file = doc.pdfFile else { message = "Save the PDF before using this tool."; return }
        busy = true; message = nil
        let source = store.url(file), root = store.root, range = pageRange, tool = tool, f = front, b: Int? = bothSides ? back : nil, sheet = paper, w = width, spacing = gap
        var settings = stamp
        if tool == .timestamp {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = includeTime ? "yyyy-MM-dd HH:mm z" : "yyyy-MM-dd"
            settings.text = formatter.string(from: date)
        }
        let mark = settings
        job = Task {
            defer { busy = false }
            do {
                let result = try await Task.detached { () throws -> (ExportedFiles, Data?) in
                    let input: Data
                    if tool == .identity {
                        var content = doc; content.paper = .original; content.margin = .none
                        input = try DocumentPDF.compose(content, root: root)
                    } else { input = try Data(contentsOf: source) }
                    let indices = try PageRange.parse(range, count: doc.pages.count)
                    if tool == .longImage { return (try LocalDocumentTools.longImages(input, indices: indices, width: w, gap: spacing), nil) }
                    let output = try tool == .identity ? LocalDocumentTools.identitySheet(input, front: f, back: b, paper: sheet) : LocalDocumentTools.stamped(input, indices: indices, stamp: mark)
                    return (try ExportFiles.write([("Preview.pdf", output)]), output)
                }.value
                if Task.isCancelled { ExportFiles.remove(result.0.directory); throw CancellationError() }
                previewFiles = result.0; pdfData = result.1
            } catch is CancellationError { message = "Cancelled. Your original is unchanged." }
            catch { message = error.localizedDescription }
        }
    }
    private func saveCopy() {
        guard let pdfData, let doc else { return }
        busy = true; message = nil
        job = Task {
            defer { busy = false }
            do {
                _ = try await store.saveGeneratedPDF(pdfData, title: doc.title + " (" + tool.rawValue + ")", folder: doc.folder)
                saved = true; message = "Copy saved on this iPhone."
            } catch { message = error.localizedDescription }
        }
    }
}
