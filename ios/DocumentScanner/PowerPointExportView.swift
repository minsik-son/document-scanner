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

    @State private var forward = true
    private var pageIndex: Int { export != nil ? 3 : stage }
    var body: some View {
        StepStack(step: pageIndex, forward: forward) {
            if export != nil { readyPage }
            else if stage == 2 { reviewPage }
            else if stage == 1 { modePage }
            else { sourcePage }
        }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(busy || export != nil || stage > 0)
            .interactiveDismissDisabled(busy)
            .toolbar {
                if (export != nil || stage > 0) && !busy {
                    ToolbarItem(placement:.topBarLeading) {
                        Button {
                            forward = false
                            if export != nil { clearExport() } else { stage = 0; tables = []; slideTexts = []; layouts = [] }; message = nil
                        } label: { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)) }
                            .accessibilityLabel("Back").accessibilityIdentifier("ppt-edit")
                    }
                }
            }
            .overlay { if busy { BusyOverlay(text: phase) { job?.cancel() } } }
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
            .fullScreenCover(isPresented:$camera) {
                OfficeScanCamera { result in
                    camera = false
                    switch result {
                    case .success(let images): if !images.isEmpty { addScans(images) }
                    case .failure(let error): message = error.localizedDescription
                    }
                }.ignoresSafeArea()
            }
            .fullScreenCover(isPresented:$preview) { if let url = export?.urls.first { OfficeQuickLook(url:url) } }
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

    @ViewBuilder private var statusRow: some View {
        if let message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(TK.grey500)
                Text(message).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ppt-status")
                Spacer(minLength: 0)
            }.padding(16).background(TK.grey100, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// Step 1: the pages, in slide order.
    private var sourcePage: some View {
        ToolPage(title: excel ? "Turn tables into Excel" : "Turn pages into slides",
                 subtitle: excel ? "Pick the pages with your tables. You'll check every cell next." : "Pick up to 30 pages. Each one becomes a slide.") {
            if pages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Add pages")
                    Button { camera = true } label: { ChoiceRow(symbol: "camera.fill", title: "Scan pages", detail: "Use the camera now") }
                        .buttonStyle(.plain).accessibilityIdentifier("office-camera")
                    Button { photoPicker = true } label: { ChoiceRow(symbol: "photo.on.rectangle.angled", title: "Choose photos", detail: "Several at once, in order", tint: TK.teal, soft: TK.tealSoft) }
                        .buttonStyle(.plain).accessibilityIdentifier("ppt-photos")
                    Button { filePicker = true } label: { ChoiceRow(symbol: "folder.fill", title: "Choose files", detail: "PDFs or images", tint: TK.orange, soft: TK.orangeSoft) }
                        .buttonStyle(.plain).accessibilityIdentifier("ppt-files")
                    Button { libraryPicker = true } label: { ChoiceRow(symbol: "doc.text.fill", title: "Use saved pages", detail: "From your documents", tint: TK.purple, soft: TK.purpleSoft) }
                        .buttonStyle(.plain).accessibilityIdentifier("ppt-library")
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(pages.count) selected · in this order").font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey600)
                        .accessibilityIdentifier("ppt-selection-count")
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in slideRow(page, index: index) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Add more")
                    HStack(spacing: 8) {
                        Button { camera = true } label: { Label("Scan", systemImage: "camera") }.buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("office-camera")
                        Button { photoPicker = true } label: { Label("Photos", systemImage: "photo") }.buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("ppt-photos")
                        Button { filePicker = true } label: { Label("Files", systemImage: "doc") }.buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("ppt-files")
                        Button { libraryPicker = true } label: { Label("Saved", systemImage: "folder") }.buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("ppt-library")
                    }.disabled(pages.count >= 30)
                }
            }
            statusRow
            Label("Processed on this iPhone", systemImage: "lock.shield").font(.system(size: 13)).foregroundStyle(TK.grey500)
        } actions: {
            Button(excel ? "Extract tables" : "Continue") {
                if !excel { forward = true; stage = 1 } else { recognize() }
            }.buttonStyle(CTAButtonStyle()).disabled(busy || pages.isEmpty).accessibilityIdentifier("office-continue")
        }
    }

    /// Step 2 (PowerPoint): how pages become slides.
    private var modePage: some View {
        ToolPage(title: "How should slides look?", subtitle: "You can change this and make the file again.") {
            VStack(spacing: 10) {
                Button { mode = .layout } label: { OptionCard(title: "Editable, same layout", detail: "Text, tables and pictures stay where they are, all editable", selected: mode == .layout) }
                    .buttonStyle(.plain).accessibilityIdentifier("ppt-mode-layout")
                Button { mode = .image } label: { OptionCard(title: "Keep original look", detail: "Each page as a full-resolution picture", selected: mode == .image) }
                    .buttonStyle(.plain).accessibilityIdentifier("ppt-mode-image")
                Button { mode = .text } label: { OptionCard(title: "Editable text only", detail: "Check the text first; no pictures or layout", selected: mode == .text) }
                    .buttonStyle(.plain).accessibilityIdentifier("ppt-mode-text")
            }
            statusRow
        } actions: {
            Button(editable ? "Extract text" : "Create \(formatName)") { if editable { recognize() } else { create() } }
                .buttonStyle(CTAButtonStyle()).disabled(busy || pages.isEmpty)
                .accessibilityIdentifier(editable ? "office-extract" : "ppt-create")
        }
    }

    /// Step 3: check cells (Excel) or slide text.
    private var reviewPage: some View {
        ToolPage(title: excel ? "Check your tables" : "Check your slide text", subtitle: excel ? "Tap a cell to correct it. Merged cells, fills and fonts are kept." : "Pictures and page layout aren't included in text slides.") {
            if excel {
                if tables.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(tables.indices, id: \.self) { i in Button(tables[i].name) { tableIndex = i }.buttonStyle(ChipStyle(selected: tableIndex == i)) } }
                    }
                }
                if tables.indices.contains(tableIndex) { OfficeTableEditor(table: $tables[tableIndex]) }
            } else {
                ForEach(slideTexts.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Slide \(index + 1)")
                        TextEditor(text: $slideTexts[index]).font(.system(size: 16)).scrollContentBackground(.hidden)
                            .padding(12).frame(minHeight: 160)
                            .background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .accessibilityIdentifier("ppt-text-\(index+1)")
                    }
                }
            }
            statusRow
        } actions: {
            Button("Create \(formatName)") { create() }.buttonStyle(CTAButtonStyle())
                .disabled(busy || (!excel && slideTexts.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
                .accessibilityIdentifier("ppt-create")
        }
    }

    /// Done: the file is ready.
    private var readyPage: some View {
        ToolPage(title: "") {
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(TK.blueSoft).frame(width: 132, height: 132)
                    Circle().fill(TK.blue).frame(width: 84, height: 84)
                    Image(systemName: "checkmark").font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
                }.padding(.top, 24).accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text(excel ? "\(tables.count) \(tables.count == 1 ? "table" : "tables") ready" : "\(pages.count) \(pages.count == 1 ? "slide" : "slides") ready")
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(TK.grey900).accessibilityIdentifier("ppt-ready")
                    Text(export?.urls.first?.lastPathComponent ?? (excel ? "Table.xlsx" : "Slides.pptx")).font(.system(size: 16)).foregroundStyle(TK.grey600)
                }
            }.frame(maxWidth: .infinity)
        } actions: {
            Button("Preview") { preview = true }.buttonStyle(SecondaryCTAStyle()).accessibilityIdentifier("ppt-preview")
            Button("Share \(formatName)") { sharing = true }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("ppt-share")
        }
    }
    private func slideRow(_ page:PresentationPage,index:Int) -> some View {
        HStack(spacing:14) {
            PresentationThumbnail(page:page,root:store.root).frame(width:88,height:66)
                .background(TK.grey100,in:RoundedRectangle(cornerRadius:8)).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment:.leading,spacing:4) {
                Text(excel ? "Page \(index+1)" : "Slide \(index+1)").font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900)
                Text(page.title).font(.system(size: 13)).foregroundStyle(TK.grey600).lineLimit(2)
                    .accessibilityIdentifier("ppt-source-\(index+1)")
            }.frame(maxWidth:.infinity,alignment:.leading)
            Menu {
                Button("Move earlier",systemImage:"arrow.up") { pages.swapAt(index,index-1) }.disabled(index == 0)
                Button("Move later",systemImage:"arrow.down") { pages.swapAt(index,index+1) }.disabled(index == pages.count-1)
                Button(excel ? "Remove page" : "Remove slide",systemImage:"trash",role:.destructive) { pages.remove(at:index) }
            } label: { Image(systemName:"ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(TK.grey600).frame(width:44,height:44).contentShape(Rectangle()) }
                .accessibilityLabel("Options for page \(index+1)")
                .accessibilityIdentifier("ppt-options-\(index+1)")
        }
        .padding(12).background(TK.grey50, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                tables = foundTables; tableIndex = 0; slideTexts = texts; layouts = pageLayouts; forward = true; stage = 2
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
                try Task.checkCancellation(); forward = true; export = try ExportFiles.write([(excel ? "Tables.xlsx" : "Slides.pptx",data)])
                // Show the finished file at full size right away, like a scan result.
                preview = true
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
