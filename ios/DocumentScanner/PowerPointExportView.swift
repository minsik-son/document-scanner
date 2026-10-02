import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit
import VisionKit

struct PresentationPage: Identifiable {
    enum Source { case library(ScanPage), photo(URL), pdf(URL, Int) }
    let id = UUID()
    let title: String
    let source: Source
    var libraryID: UUID? { if case .library(let page) = source { return page.id }; return nil }
    func recognizedText(root:URL) throws -> String {
        func read(_ image:UIImage) throws -> String {
            guard let cg = image.cgImage else { throw ScannerError.message("Page unavailable.") }
            return try TextRecognition.recognize(cg).map(\.text).joined(separator:"\n")
        }
        if case .pdf(let url,let index) = source { return try WordFileInput.text(url,index:index,recognize:read) }
        return try read(image(root:root))
    }
    func image(root:URL) throws -> UIImage {
        switch source {
        case .library(let page): return try Imaging.render(page,root:root)
        case .photo(let url): return try OfflineWork.photo(Data(contentsOf:url))
        case .pdf(let url,let index): return try WordFileInput.page(url,index:index)
        }
    }
}

/// Input files belong to this screen, never to the user's saved document library.
private final class PresentationWorkspace: ObservableObject {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-\(UUID().uuidString)",isDirectory:true)
    deinit { try? FileManager.default.removeItem(at:directory) }
}

struct PowerPointExportView: View {
    @EnvironmentObject private var store: LibraryStore
    let documentID: UUID?
    var excel = false
    @State private var stage = 0
    @State private var camera = false
    /// How pages become slides: rebuilt editable layout, page pictures, or plain text.
    enum SlideMode { case layout, image, text }
    @State private var mode = SlideMode.layout
    private var editable: Bool { mode == .text }
    @State private var layouts: [PageLayout] = []
    @State private var slideTexts: [String] = []
    @State private var tables: [OfficeTable] = []
    @State private var tableIndex = 0
    private var formatName: String { excel ? "Excel" : "PowerPoint" }
    @StateObject private var workspace = PresentationWorkspace()
    @State private var pages: [PresentationPage] = []
    @State private var photos: [PhotosPickerItem] = []
    @State private var photoPicker = false
    @State private var filePicker = false
    @State private var libraryPicker = false
    @State private var initialized = false
    @State private var busy = false
    @State private var phase = ""
    @State private var job: Task<Void,Never>?
    @State private var message: String?
    @State private var export: ExportedFiles?
    @State private var preview = false
    @State private var sharing = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        content
            .navigationTitle("\(formatName) export").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(busy || export != nil || stage > 0)
            .interactiveDismissDisabled(busy)
            .toolbar {
                if (export != nil || stage > 0) && !busy {
                    ToolbarItem(placement:.topBarLeading) {
                        Button { if export != nil { clearExport() } else { stage = 0; tables = []; slideTexts = []; layouts = [] }; message = nil } label: { Label("Back",systemImage:"chevron.left") }
                            .accessibilityIdentifier("ppt-edit")
                    }
                } else if pages.count > 1 && !busy && stage == 0 {
                    ToolbarItem(placement:.topBarTrailing) {
                        Button(editMode == .active ? "Done" : "Reorder") { editMode = editMode == .active ? .inactive : .active }
                    }
                }
            }
            .safeAreaInset(edge:.bottom) { primaryAction }
            .photosPicker(isPresented:$photoPicker,selection:$photos,maxSelectionCount:max(1,30-pages.count),selectionBehavior:.ordered,matching:.images)
            .onChange(of:photos) { _,items in if !items.isEmpty { addPhotos(items) } }
            .fileImporter(isPresented:$filePicker,allowedContentTypes:[.pdf,.image],allowsMultipleSelection:true) { result in
                switch result {
                case .success(let urls): if !urls.isEmpty { addFiles(urls) }
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
                }
            }
            .sheet(isPresented:$libraryPicker) {
                PresentationLibraryPicker(existing:Set(pages.compactMap(\.libraryID)),limit:30-pages.count) { additions in
                    pages += additions; message = nil
                }
            }
            .sheet(isPresented:$camera) {
                WordDocumentCamera { result in
                    camera = false
                    switch result {
                    case .success(let images): if !images.isEmpty { addScans(images) }
                    case .failure(let error): message = error.localizedDescription
                    }
                }.ignoresSafeArea()
            }
            .sheet(isPresented:$preview) { if let url = export?.urls.first { OfficeQuickLook(url:url) } }
            .sheet(isPresented:$sharing) { if let export { ShareSheet(items:export.urls) } }
            .task {
                guard !initialized else { return }; initialized = true
                if let documentID,let document = store.document(documentID) {
                    if document.pages.count <= 30 {
                        pages = document.pages.enumerated().map { PresentationPage(title:"\(document.title) · Page \($0.offset+1)",source:.library($0.element)) }
                    } else { libraryPicker = true; message = "Choose up to 30 pages for your presentation." }
                }
            }
            .onDisappear {
                if !camera && !photoPicker && !filePicker && !libraryPicker && !preview && !sharing {
                    job?.cancel(); clearExport()
                }
            }
    }

    private var content: some View {
        List {
            Section { introduction.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            if let export {
                Section {
                    Label(excel ? "\(tables.count) tables ready" : "\(pages.count) \(pages.count == 1 ? "slide" : "slides") ready",systemImage:"checkmark.circle.fill")
                        .foregroundStyle(Design.blueInk).accessibilityIdentifier("ppt-ready")
                    Text(export.urls.first?.lastPathComponent ?? "Slides.pptx").font(.subheadline)
                    Button("Preview \(formatName)") { preview = true }.accessibilityIdentifier("ppt-preview")
                }
            } else if stage == 2 {
                if excel {
                    Section {
                        Picker("Table",selection:$tableIndex) {
                            ForEach(tables.indices,id:\.self) { Text(tables[$0].name).tag($0) }
                        }
                        if tables.indices.contains(tableIndex) { OfficeTableEditor(table:$tables[tableIndex]) }
                    } footer: { Text("Check names, numbers and merged cells. Each page becomes a worksheet that keeps its layout: merged cells, fills, borders, fonts and pictures. Values are exported as text to preserve leading zeros.") }
                } else {
                    ForEach(slideTexts.indices,id:\.self) { index in
                        Section("Slide \(index+1)") {
                            TextEditor(text:$slideTexts[index]).frame(minHeight:180).accessibilityIdentifier("ppt-text-\(index+1)")
                        }
                    }
                    Section { Text("Creates editable text slides. Original pictures, fonts and page layout are not included.").font(.footnote).foregroundStyle(.secondary) }
                }
            } else if stage == 1 {
                Section("Choose your slide content") {
                    Button { mode = .layout } label: {
                        Label("Editable, same layout",systemImage:mode == .layout ? "checkmark.circle.fill" : "circle")
                    }.accessibilityIdentifier("ppt-mode-layout")
                    Text("Text, tables and pictures stay where they are on the page, with their sizes, colors and borders. Everything stays editable.").font(.subheadline).foregroundStyle(.secondary)
                    Button { mode = .image } label: {
                        Label("Keep original appearance",systemImage:mode == .image ? "checkmark.circle.fill" : "circle")
                    }.accessibilityIdentifier("ppt-mode-image")
                    Text("Each selected page becomes a full-resolution image on a slide.").font(.subheadline).foregroundStyle(.secondary)
                    Button { mode = .text } label: {
                        Label("Editable text",systemImage:mode == .text ? "checkmark.circle.fill" : "circle")
                    }.accessibilityIdentifier("ppt-mode-text")
                    Text("Extract and check the text first. Pictures and original layout won't be included.").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    HStack(alignment:.top,spacing:12) {
                        Button {
                            if VNDocumentCameraViewController.isSupported { camera = true }
                            else { message = "The camera is unavailable. Choose photos or files instead." }
                        } label: { sourceLabel("Scan",icon:"camera") }.accessibilityIdentifier("office-camera")
                        Button { photoPicker = true } label: { sourceLabel("Photos",icon:"photo.on.rectangle") }.accessibilityIdentifier("ppt-photos")
                        Button { filePicker = true } label: { sourceLabel("Files",icon:"doc") }.accessibilityIdentifier("ppt-files")
                        Button { libraryPicker = true } label: { sourceLabel("Saved pages",icon:"folder") }.accessibilityIdentifier("ppt-library")
                    }.buttonStyle(.plain).padding(.vertical,8).disabled(pages.count >= 30)
                }
                if pages.isEmpty {
                    Section {
                        ContentUnavailableView("Choose your pages",systemImage:"photo.stack",description:Text(excel ? "Select photos or PDF pages containing tables." : "Select several photos or document pages at once. Each one becomes a slide."))
                    }
                } else {
                    Section {
                        ForEach(Array(pages.enumerated()),id:\.element.id) { index,page in
                            slideRow(page,index:index)
                        }
                        .onMove { from,to in pages.move(fromOffsets:from,toOffset:to) }
                        .onDelete { indices in pages.remove(atOffsets:indices) }
                    } header: {
                        Text("\(pages.count) selected · Page order").accessibilityIdentifier("ppt-selection-count")
                    } footer: {
                        Text(excel ? "Select the pages containing your tables. You can check every cell before exporting." : "Choose pages now. Choose how your slides will look next.")
                    }
                }
            }
            if let message { Section { Text(message).foregroundStyle(.secondary).accessibilityIdentifier("ppt-status") } }
        }
        .environment(\.editMode,$editMode).disabled(busy)
    }

    private var headerPalette: OfficeHeaderPalette { excel ? .excel : .slides }
    private var introduction: some View {
        HStack(spacing:16) {
            VStack(alignment:.leading,spacing:10) {
                Text(export != nil ? "Your \(formatName) is ready" : stage == 2 ? (excel ? "Check your tables" : "Check your slide text") : stage == 1 ? "Make it your presentation" : excel ? "Turn tables into Excel" : "Turn pages into slides")
                    .font(.system(.title2,design:.rounded,weight:.bold)).foregroundStyle(headerPalette.ink)
                    .fixedSize(horizontal:false,vertical:true)
                Text(export != nil ? "Preview your file, then save or share." : stage == 2 ? "Tap to correct anything before exporting." : stage == 1 ? "Keep the page design and edit everything on it." : "Choose up to 30 pages. Everything is processed on this iPhone.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.frame(maxWidth:.infinity,alignment:.leading)
            ToolArtwork(name:excel ? "excel" : "slides",size:72)
        }.padding(22)
            .background(headerPalette.gradient,in:RoundedRectangle(cornerRadius:24))
    }
    private func sourceLabel(_ label:String,icon:String) -> some View {
        VStack(spacing:8) {
            Image(systemName:icon).font(.title3).frame(height:36)
            Text(label).font(.caption.weight(.medium)).fixedSize(horizontal:false,vertical:true)
        }.frame(maxWidth:.infinity).foregroundStyle(Design.blueInk).contentShape(Rectangle())
    }
    private func slideRow(_ page:PresentationPage,index:Int) -> some View {
        HStack(spacing:14) {
            PresentationThumbnail(page:page,root:store.root).frame(width:88,height:66)
                .background(Design.muted,in:RoundedRectangle(cornerRadius:8)).clipped()
            VStack(alignment:.leading,spacing:5) {
                Text("Page \(index+1)").font(.headline)
                Text(page.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityIdentifier("ppt-source-\(index+1)")
            }.frame(maxWidth:.infinity,alignment:.leading)
            Menu {
                Button("Move earlier",systemImage:"arrow.up") { pages.swapAt(index,index-1) }.disabled(index == 0)
                Button("Move later",systemImage:"arrow.down") { pages.swapAt(index,index+1) }.disabled(index == pages.count-1)
                Button(excel ? "Remove page" : "Remove slide",systemImage:"trash",role:.destructive) { pages.remove(at:index) }
            } label: { Image(systemName:"ellipsis").frame(width:44,height:44).contentShape(Rectangle()) }
                .accessibilityLabel("Options for page \(index+1)")
                .accessibilityIdentifier("ppt-options-\(index+1)")
        }.padding(.vertical,6)
    }
    private var primaryAction: some View {
        VStack(spacing:12) {
            if busy {
                HStack { ProgressView();Text(phase).font(.subheadline);Spacer();Button("Cancel") { job?.cancel() } }
            } else if export != nil {
                Button("Share \(formatName)") { sharing = true }.buttonStyle(PrimaryButton()).accessibilityIdentifier("ppt-share")
            } else {
                Button(stage == 0 ? (excel ? "Extract tables" : "Continue") : stage == 1 && editable ? "Extract text" : "Create \(formatName)") {
                    if stage == 0 && !excel { stage = 1; editMode = .inactive }
                    else if stage == 0 || (stage == 1 && editable) { recognize() }
                    else { create() }
                }.buttonStyle(PrimaryButton()).disabled(pages.isEmpty || (stage == 2 && !excel && slideTexts.allSatisfy { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }))
                    .accessibilityIdentifier(stage == 0 ? "office-continue" : stage == 1 && editable ? "office-extract" : "ppt-create")
            }
        }.padding().background(.regularMaterial)
    }
    private func clearExport() {
        if let export { ExportFiles.remove(export.directory) }; export = nil
    }
    private func batchDirectory() -> URL { workspace.directory.appendingPathComponent(UUID().uuidString,isDirectory:true) }
    private func addPhotos(_ items:[PhotosPickerItem]) {
        let directory = batchDirectory(),capacity = 30-pages.count
        busy = true; message = nil;phase = "Opening photos…"
        job = Task {
            defer { busy = false; photos = [] }
            do {
                guard items.count <= capacity else { throw ScannerError.message("Choose up to \(capacity) more pages.") }
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                var additions:[PresentationPage] = []
                for (index,item) in items.enumerated() {
                    try Task.checkCancellation(); phase = "Opening photo \(index+1) of \(items.count)…"
                    guard let data = try await item.loadTransferable(type:Data.self) else { throw ScannerError.message("A selected photo is unavailable. Try again.") }
                    let url = directory.appendingPathComponent("\(index).image")
                    try await OfflineWork.perform {
                        guard data.count <= 100_000_000 else { throw ScannerError.message("Choose images smaller than 100 MB.") }
                        _ = try OfflineWork.photo(data)
                        try data.write(to:url,options:[.atomic,.completeFileProtectionUnlessOpen])
                    }
                    additions.append(PresentationPage(title:"Photo \(index+1)",source:.photo(url)))
                }
                try Task.checkCancellation(); pages += additions
            } catch { try? FileManager.default.removeItem(at:directory); message = error is CancellationError ? "Canceled. Your selected pages are unchanged." : error.localizedDescription }
        }
    }
    private func addFiles(_ urls:[URL]) {
        let directory = batchDirectory(),capacity = 30-pages.count
        busy = true; message = nil;phase = "Opening files…"
        job = Task {
            defer { busy = false }
            do {
                let additions = try await OfflineWork.perform {
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    var result:[PresentationPage] = []
                    for (index,url) in urls.enumerated() {
                        try Task.checkCancellation()
                        let copy = directory.appendingPathComponent("\(index).pdf")
                        let opened = try autoreleasepool { try WordFileInput.open(url,pdfCopy:copy) }
                        if opened.pdfPages > 0 {
                            guard result.count+opened.pdfPages <= capacity else { throw ScannerError.message("Choose at most 30 pages in total, including all PDF pages.") }
                            result += (0..<opened.pdfPages).map { PresentationPage(title:"\(url.lastPathComponent) · Page \($0+1)",source:.pdf(copy,$0)) }
                        } else {
                            guard result.count < capacity else { throw ScannerError.message("Choose at most 30 pages in total.") }
                            let file = directory.appendingPathComponent("\(index).png")
                            guard let data = opened.image.pngData() else { throw ScannerError.message("This image couldn't be imported.") }
                            try data.write(to:file,options:[.atomic,.completeFileProtectionUnlessOpen])
                            result.append(PresentationPage(title:url.lastPathComponent,source:.photo(file)))
                        }
                    }
                    return result
                }
                try Task.checkCancellation(); pages += additions
            } catch { try? FileManager.default.removeItem(at:directory); message = error is CancellationError ? "Canceled. Your selected pages are unchanged." : error.localizedDescription }
        }
    }
    private func addScans(_ images:[UIImage]) {
        guard pages.count+images.count <= 30 else { message = "Choose up to 30 pages in total."; return }
        let directory = batchDirectory()
        busy = true; phase = "Opening scans…"; message = nil
        job = Task {
            defer { busy = false }
            do {
                let additions = try await OfflineWork.perform {
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    return try images.enumerated().map { index,image in
                        try Task.checkCancellation()
                        let url = directory.appendingPathComponent("\(index).png")
                        guard let data = image.pngData() else { throw ScannerError.message("Couldn't open this scan.") }
                        try data.write(to:url,options:[.atomic,.completeFileProtectionUnlessOpen])
                        return PresentationPage(title:"Scan \(index+1)",source:.photo(url))
                    }
                }
                try Task.checkCancellation();pages += additions
            } catch { try? FileManager.default.removeItem(at:directory);message = error.localizedDescription }
        }
    }
    private func recognize() {
        let selection = pages,root = store.root
        busy = true; message = nil;editMode = .inactive
        job = Task {
            defer { busy = false }
            do {
                var foundTables:[OfficeTable] = [],texts:[String] = [],pageLayouts:[PageLayout] = []
                for (index,page) in selection.enumerated() {
                    try Task.checkCancellation();phase = "Reading page \(index+1) of \(selection.count)…"
                    if excel {
                        let layout = try await OfflineWork.perform { try OfficeLayoutPages.analyze(page.image(root:root)) }
                        pageLayouts.append(layout)
                        var count = 0
                        for (item, content) in layout.items.enumerated() {
                            guard case .table(let table) = content else { continue }
                            count += 1
                            foundTables.append(OfficeTable(layout:table,name:"Page \(index+1) · Table \(count)",page:index,item:item))
                        }
                        guard foundTables.count <= 100 else { throw ScannerError.message("Choose fewer pages. Up to 100 tables can be exported at once.") }
                    } else {
                        let text = try await OfflineWork.perform { try page.recognizedText(root:root) }
                        texts.append(text)
                    }
                }
                try Task.checkCancellation()
                if excel && pageLayouts.allSatisfy({ $0.items.isEmpty }) { message = "No text was found. Try a clearer scan or another page."; return }
                tables = foundTables; tableIndex = 0; slideTexts = texts; layouts = pageLayouts; stage = 2
                if excel && foundTables.isEmpty { message = "No tables were found. Each page's text keeps its layout on its worksheet." }
                if !excel && texts.contains(where: { $0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) { message = "Some pages contain no readable text. Add text before creating your presentation, or use original appearance." }
            } catch { message = error is CancellationError ? "Canceled. Your selected pages are unchanged." : error.localizedDescription }
        }
    }
    private func create() {
        let selection = pages,root = store.root,tableSnapshot = tables,textSnapshot = slideTexts,asText = editable,slideMode = mode,layoutSnapshot = layouts
        busy = true; message = nil; editMode = .inactive; phase = "Creating \(formatName)…"
        job = Task {
            defer { busy = false }
            do {
                var rebuilt:[PageLayout] = []
                if !excel && slideMode == .layout {
                    for (index,page) in selection.enumerated() {
                        try Task.checkCancellation();phase = "Rebuilding page \(index+1) of \(selection.count)…"
                        rebuilt.append(try await OfflineWork.perform { try OfficeLayoutPages.analyze(page.image(root:root)) })
                    }
                    phase = "Creating PowerPoint…"
                }
                let slides = rebuilt
                let data = try await OfflineWork.perform {
                    if excel {
                        var pages = layoutSnapshot
                        for table in tableSnapshot {
                            guard let p = table.layoutPage, let i = table.layoutItem, pages.indices.contains(p), pages[p].items.indices.contains(i),
                                  case .table(var layout) = pages[p].items[i] else { continue }
                            layout.apply(table); pages[p].items[i] = .table(layout)
                        }
                        return try OfficeLayoutExport.excel(pages,image:OfficeLayoutPages.missingPicture)
                    }
                    if slideMode == .layout { return try OfficeLayoutExport.powerpoint(slides,theme:OfficeLayoutPages.theme(),image:OfficeLayoutPages.missingPicture) }
                    return try OfficeExport.powerpoint(pageCount:selection.count,texts:textSnapshot,editable:asText) { index in
                        try selection[index].image(root:root)
                    }
                }
                try Task.checkCancellation(); export = try ExportFiles.write([(excel ? "Tables.xlsx" : "Slides.pptx",data)])
            } catch { message = error is CancellationError ? "Canceled. Your selected pages are unchanged." : error.localizedDescription }
        }
    }

}

private struct PresentationThumbnail: View {
    let page: PresentationPage
    let root: URL
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage:image).resizable().scaledToFit() }
            else if failed { Image(systemName:"exclamationmark.triangle").foregroundStyle(.secondary).accessibilityLabel("Page unavailable") }
            else { ProgressView() }
        }.task(id:page.id) {
            do {
                let result:UIImage
                if case .library(let scan) = page.source {
                    result = try await PageThumbnailCache.shared.image(for:scan,root:root)
                } else {
                    result = try await OfflineWork.perform {
                        switch page.source {
                        case .photo(let url): return try LocalDocumentTools.thumbnail(Data(contentsOf:url),maxPixels:350)
                        case .pdf(let url,let index):
                            guard let pdf = PDFDocument(url:url),let page = pdf.page(at:index) else { throw ScannerError.message("Page unavailable.") }
                            return page.thumbnail(of:CGSize(width:350,height:350),for:.cropBox)
                        case .library: throw ScannerError.message("Page unavailable.")
                        }
                    }
                }
                try Task.checkCancellation(); image = result
            } catch { if !(error is CancellationError) { failed = true } }
        }
    }
}

private struct PresentationLibraryPicker: View {
    @EnvironmentObject private var store:LibraryStore
    @Environment(\.dismiss) private var dismiss
    let existing:Set<UUID>
    let limit:Int
    let onAdd:([PresentationPage])->Void
    @State private var selected:[UUID] = []
    private var available:[PresentationPage] {
        store.active.flatMap { document in
            document.pages.enumerated().map { PresentationPage(title:"\(document.title) · Page \($0.offset+1)",source:.library($0.element)) }
        }
    }
    var body:some View {
        NavigationStack {
            List {
                if available.isEmpty { ContentUnavailableView("No saved pages",systemImage:"doc",description:Text("Choose photos or files to get started.")) }
                ForEach(store.active) { document in
                    Section(document.title) {
                        ForEach(Array(document.pages.enumerated()),id:\.element.id) { index,page in
                            Button {
                                if selected.contains(page.id) { selected.removeAll { $0 == page.id } }
                                else if selected.count < limit { selected.append(page.id) }
                            } label: {
                                HStack {
                                    PageThumbnail(page:page).frame(width:50,height:65)
                                    Text("Page \(index+1)").foregroundStyle(.primary)
                                    Spacer()
                                    if let position = selected.firstIndex(of:page.id) {
                                        Text("\(position+1)").font(.subheadline.bold()).foregroundStyle(Design.blueInk)
                                    }
                                    Image(systemName:selected.contains(page.id) || existing.contains(page.id) ? "checkmark.circle.fill" : "circle")
                                }.padding(.vertical,4).contentShape(Rectangle())
                            }
                            .disabled(existing.contains(page.id) || (!selected.contains(page.id) && selected.count >= limit))
                            .accessibilityIdentifier("ppt-library-page-\(index+1)")
                            .accessibilityValue(existing.contains(page.id) ? "Already added" : selected.contains(page.id) ? "Selected" : "Not selected")
                        }
                    }
                }
            }
            .navigationTitle("Choose pages").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button("Add \(selected.count)") {
                        let candidates = available
                        onAdd(selected.compactMap { id in candidates.first { $0.libraryID == id } }); dismiss()
                    }.disabled(selected.isEmpty).accessibilityIdentifier("ppt-add-pages")
                }
            }
        }
    }
}
