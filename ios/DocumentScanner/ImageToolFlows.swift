import SwiftUI
import PhotosUI
import AVFoundation
import StoreKit

// MARK: - Shared flow plumbing

/// Work state shared by the photo tools: one busy label, one message and a
/// cancellable job. Results are never published after cancellation.
@MainActor final class ToolWork: ObservableObject {
    @Published var busy: String?
    @Published var message: String?
    @Published var progress: Double?
    private var job: Task<Void, Never>?
    func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        job?.cancel()
        message = nil; busy = label; progress = nil
        job = Task { @MainActor in
            defer { if !Task.isCancelled { busy = nil; progress = nil } }
            do { try await work() }
            catch is CancellationError { }
            catch { self.message = error.localizedDescription }
        }
    }
    /// Background work whose result replaces older pending results (live previews).
    func preview(_ work: @escaping @MainActor () async throws -> Void) {
        job?.cancel()
        job = Task { @MainActor in
            do { try await work() } catch is CancellationError { } catch { self.message = error.localizedDescription }
        }
    }
    func cancel() { job?.cancel(); job = nil; busy = nil; progress = nil }
}

/// Pages of a flow slide in from the trailing edge going forward, and back.
struct StepStack<Content: View>: View {
    let step: Int
    let forward: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack { content().id(step).transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                                              removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))) }
            .animation(.spring(response: 0.38, dampingFraction: 0.9), value: step)
    }
}

/// Back button, busy overlay and error message for a step flow.
struct StepChrome: ViewModifier {
    @Binding var step: Int
    @Binding var forward: Bool
    var lastStep: Int
    @ObservedObject var work: ToolWork
    var back: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(step > 0)
            .toolbar {
                if step > 0 && step < lastStep {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            work.cancel(); work.message = nil
                            if let back { back() } else { forward = false; step -= 1 }
                        } label: { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)) }
                            .accessibilityLabel("Back").accessibilityIdentifier("tool-back")
                    }
                }
            }
            .overlay { if let busy = work.busy { BusyOverlay(text: busy, progress: work.progress) { work.cancel() } } }
            .interactiveDismissDisabled(work.busy != nil)
    }
}
extension View {
    func stepChrome(step: Binding<Int>, forward: Binding<Bool>, last: Int, work: ToolWork, back: (() -> Void)? = nil) -> some View {
        modifier(StepChrome(step: step, forward: forward, lastStep: last, work: work, back: back))
    }
}

/// First page of every photo tool: what it does and where the picture comes from.
struct PhotoSourcePage: View {
    let tool: AdvancedTool
    let title: String
    let subtitle: String
    var multiple = false
    var frontCamera = false
    @ObservedObject var work: ToolWork
    var recent: AnyView? = nil
    var art: ToolArt? = nil
    let picked: ([UIImage]) -> Void
    var body: some View {
        ToolPage(title: title, subtitle: subtitle) {
            ToolHero(art: art ?? tool.art)
            if let recent { recent }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: multiple ? "Add your photos" : "Add a photo")
                PhotoSourceChoices(multiple: multiple, frontCamera: frontCamera, portraitGuide: tool == .portrait, allowCamera: art != .removeFingers, documentScan: tool == .erase || tool == .marks, picked: picked,
                                   failed: { work.message = $0 }, busy: { work.busy = $0 ? "Opening…" : nil })
            }
            if let message = work.message { ToastMessage(text: message) }
            Label("Processed on this iPhone", systemImage: "lock.shield").font(.system(size: 13)).foregroundStyle(TK.grey500)
        } actions: { EmptyView() }
    }
}

extension AdvancedTool {
    var art: ToolArt {
        switch self {
        case .book: return .book
        case .portrait: return .portrait
        case .erase: return .erase
        case .marks: return .marks
        case .restore: return .restore
        case .mega: return .mega
        case .count: return .count
        case .measure: return .measure
        case .mesh: return .mesh
        case .word: return .word
        case .excel: return .excel
        case .slides: return .ppt
        case .math: return .math
        case .translate: return .translate
        default: return .ocr
        }
    }
}

/// Saves pictures as a new document, with text recognised when they are pages.
@MainActor enum PhotoToolSaving {
    static func save(_ images: [UIImage], title: String, millimeters: CGSize? = nil, recognize: Bool, store: LibraryStore) async throws -> UUID {
        let data = try await OfflineWork.perform { () throws -> Data in
            var blocks: [[TextBlock]] = []
            for image in images {
                try Task.checkCancellation()
                if recognize, let cg = image.cgImage { blocks.append((try? TextRecognition.recognize(cg)) ?? []) } else { blocks.append([]) }
            }
            return try ImageToolEngine.pdf(images, millimeters: millimeters, text: blocks)
        }
        return try await store.saveGeneratedPDF(data, title: title)
    }
    static func share(_ images: [UIImage], name: String) throws -> ExportedFiles {
        try ExportFiles.write(images.enumerated().map { index, image in
            (images.count == 1 ? "\(name).jpg" : "\(name)-\(index + 1).jpg", image.jpegData(compressionQuality: 0.95) ?? Data())
        })
    }
}

/// Done page for photo tools: saved to documents, share the picture.
struct PhotoToolDone: View {
    let title: String
    let images: [UIImage]
    let name: String
    /// Exact files to share instead of re-encoding the images (size-limited uploads).
    var files: [(String, Data)] = []
    let finish: () -> Void
    @State private var exported: ExportedFiles?
    var body: some View {
        ToolDonePage(title: title, detail: "You'll find it in Documents. The original photo is unchanged.",
                     primary: finish, secondaryTitle: !files.isEmpty ? "Share file" : images.count > 1 ? "Share \(images.count) images" : "Share image",
                     secondary: { exported = try? (files.isEmpty ? PhotoToolSaving.share(images, name: name) : ExportFiles.write(files)) }) {
            if !images.isEmpty {
                // Every result at reading size, first to last, to check before sharing.
                LazyVStack(alignment: .leading, spacing: 14) {
                    SectionLabel(text: "Check the result")
                    ForEach(Array(images.enumerated()), id: \.offset) { i, image in
                        VStack(spacing: 6) {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(TK.grey200, lineWidth: 1))
                            if images.count > 1 { Text("\(i + 1) of \(images.count)").font(.system(size: 13, weight: .medium)).foregroundStyle(TK.grey500) }
                        }
                    }
                }.padding(.top, 6)
            }
        }
        .sheet(item: $exported) { files in ShareSheet(items: files.urls) { _, _ in ExportFiles.remove(files.directory) } }
    }
}

/// Routes an image tool to its flow.
struct ImageToolFlow: View {
    let tool: AdvancedTool
    var documentID: UUID? = nil
    var body: some View {
        Group {
            switch tool {
            case .book: BookTool()
            case .portrait: PortraitTool()
            case .erase: EraseTool()
            case .marks: MarksTool()
            case .restore: RestoreTool()
            case .mega: MegaTool()
            case .count: CountTool()
            default: EmptyView()
            }
        }
        .environment(\.toolDocumentID, documentID)
    }
}

// MARK: - Book pages

private struct BookTool: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var work = ToolWork()
    @State private var step = 0
    @State private var forward = true
    @State private var input: UIImage?
    @State private var fold = 0.5
    @State private var twoPages = true
    @State private var curve = 0.0
    @State private var autoCurve = 0.0
    @State private var skipNextRender = false
    @State private var parts: [(UIImage, ImageToolEngine.Spine)] = []
    @State private var pages: [UIImage] = []
    @State private var saved: [UIImage] = []
    var body: some View {
        StepStack(step: step, forward: forward) {
            switch step {
            case 0:
                PhotoSourcePage(tool: .book, title: "Scan a book spread", subtitle: "We'll split the two pages at the fold and straighten the curve.", work: work) { images in
                    guard let image = images.first else { return }
                    work.run("Finding the pages…") {
                        let found = try await OfflineWork.perform { () -> (UIImage, Double) in
                            let page = ImageToolEngine.cropToPage(image)
                            return (page, ImageToolEngine.gutter(page))
                        }
                        input = found.0; fold = found.1; go(1)
                    }
                }
            case 1: foldPage
            case 2: resultPage
            default: PhotoToolDone(title: twoPages ? "Saved \(saved.count) pages" : "Saved your page", images: saved, name: "Book page") { dismiss() }
            }
        }
        .stepChrome(step: $step, forward: $forward, last: 3, work: work)
    }
    private func go(_ next: Int) { forward = next > step; step = next }
    private var foldPage: some View {
        ToolPage(title: "Line up the fold", subtitle: "Drag the line to the middle of the book.") {
            if let input {
                GeometryReader { geo in
                    let rect = AVFit.rect(for: input.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: input).resizable().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                        if twoPages {
                            let x = rect.minX + rect.width * fold
                            Rectangle().fill(TK.blue).frame(width: 3, height: rect.height).offset(x: x - 1.5, y: rect.minY)
                            Image(systemName: "arrow.left.and.right").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 44, height: 44).background(TK.blue, in: Circle()).shadow(radius: 4)
                                .offset(x: x - 22, y: rect.midY - 22)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard twoPages else { return }
                        fold = min(0.8, max(0.2, (value.location.x - rect.minX) / max(1, rect.width)))
                    })
                    .accessibilityElement().accessibilityLabel("Fold position").accessibilityValue("\(Int(fold * 100)) percent")
                    .accessibilityAdjustableAction { fold = min(0.8, max(0.2, fold + ($0 == .increment ? 0.02 : -0.02))) }
                }
                .frame(height: 380).padding(10).background(TK.grey100, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            HStack(spacing: 10) {
                Button("Two pages") { twoPages = true }.buttonStyle(ChipStyle(selected: twoPages)).accessibilityIdentifier("book-two")
                Button("One page") { twoPages = false }.buttonStyle(ChipStyle(selected: !twoPages)).accessibilityIdentifier("book-one")
            }
        } actions: {
            Button("Split pages") { makePages() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("book-next")
        }
    }
    private var resultPage: some View {
        ToolPage(title: twoPages ? "Your two pages" : "Your page", subtitle: autoCurve > 0 ? "We flattened the curve for you. Adjust it if lines still bend." : "Flatten the curve if lines bend toward the spine.") {
            TabView {
                ForEach(pages.indices, id: \.self) { i in
                    Image(uiImage: pages[i]).resizable().scaledToFit().padding(6)
                        .accessibilityLabel("Page \(i + 1)").accessibilityIdentifier("book-page-\(i + 1)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never)).indexViewStyle(.page(backgroundDisplayMode: .always))
            .frame(height: 380).background(TK.grey100, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            ToolSlider(title: "Flatten curve", value: $curve, range: 0...0.45, format: { v in v < 0.01 ? "Off" : "\(Int((v / 0.45 * 100).rounded()))%" })
                .onChange(of: curve) { _, _ in render(preview: true) }
                .accessibilityIdentifier("book-curve")
        } actions: {
            Button("Save pages") { save() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("book-save")
        }
    }
    private func makePages() {
        guard let input else { return }
        let split = fold, two = twoPages
        work.run("Splitting pages…") {
            let found = try await OfflineWork.perform { () throws -> ([(UIImage, ImageToolEngine.Spine)], Double) in
                let parts = try ImageToolEngine.bookPages(input, split: split, twoPages: two)
                let estimates = parts.map { ImageToolEngine.estimateCurve($0.0, spine: $0.1) }
                return (parts, estimates.reduce(0, +) / Double(max(1, estimates.count)))
            }
            parts = found.0; autoCurve = found.1
            pages = try await OfflineWork.perform { try Self.flatten(found.0, curve: found.1, preview: true) }
            skipNextRender = true
            curve = found.1
            go(2)
        }
    }
    nonisolated private static func flatten(_ parts: [(UIImage, ImageToolEngine.Spine)], curve: Double, preview: Bool) throws -> [UIImage] {
        try parts.map { part in
            try Task.checkCancellation()
            let source = preview ? Imaging.limited(part.0, maxPixels: 1_500_000) : part.0
            return try ImageToolEngine.flattenPage(source, spine: part.1, curve: curve)
        }
    }
    private func render(preview: Bool) {
        if skipNextRender { skipNextRender = false; return }
        let current = parts, c = curve
        work.preview {
            pages = try await OfflineWork.perform { try Self.flatten(current, curve: c, preview: true) }
        }
    }
    private func save() {
        let current = parts, c = curve
        work.run("Saving pages…") {
            let full = try await OfflineWork.perform { try Self.flatten(current, curve: c, preview: false) }
            _ = try await PhotoToolSaving.save(full, title: "Book pages", recognize: true, store: store)
            saved = full; go(3)
        }
    }
}

// MARK: - ID photo

private struct PortraitTool: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var work = ToolWork()
    private enum Output: String, CaseIterable { case single = "Single photo", sheet = "Print sheet", online = "Online upload" }
    @State private var step = 0
    @State private var forward = true
    @State private var source: UIImage?
    @State private var subject: ImageToolEngine.PortraitSubject?
    @State private var home = ImageToolEngine.PhotoSize.homeCode
    @State private var size = ImageToolEngine.PhotoSize.preferred(for: ImageToolEngine.PhotoSize.homeCode)
    @State private var sizeChosen = false
    @State private var backdrop = ImageToolEngine.Backdrop.white
    @State private var adjust = ImageToolEngine.PortraitAdjust()
    @State private var outfit = ImageToolEngine.Outfit.none
    @State private var outfitLift = 0.0
    @State private var photo: UIImage?
    @State private var output = Output.single
    @State private var paper = ImageToolEngine.PrintPaper.fourBySix
    @State private var sheetImage: UIImage?
    @State private var digitalSpec: ImageToolEngine.DigitalSpec?
    @State private var digitalData: Data?
    @State private var checks: [ImageToolEngine.PortraitCheck] = []
    @State private var history: [PortraitHistoryEntry] = []
    @State private var entryID: UUID?
    @State private var saved: UIImage?
    @State private var savedFile: [(String, Data)] = []
    var body: some View {
        StepStack(step: step, forward: forward) {
            switch step {
            case 0:
                PhotoSourcePage(tool: .portrait, title: "Make an ID photo", subtitle: "Face the camera on a plain background. We'll do the cut-out, size and background.", frontCamera: true, work: work,
                                recent: history.isEmpty ? nil : AnyView(recentRow)) { images in
                    guard let image = images.first else { return }
                    work.run("Finding your face…") {
                        subject = try await OfflineWork.perform { try ImageToolEngine.portraitSubject(image) }
                        source = image; entryID = nil; outfit = .none; outfitLift = 0
                        go(1)
                    }
                }
                .onAppear { history = PortraitHistory.list() }
            case 1: sizePage
            case 2: alignPage
            case 3: backdropPage
            case 4: resultPage
            default: PhotoToolDone(title: "Your ID photo is saved", images: [saved].compactMap { $0 }, name: "ID photo", files: savedFile) { dismiss() }
            }
        }
        .stepChrome(step: $step, forward: $forward, last: 5, work: work)
        .task {
            // The App Store country is the best sign of where the user lives.
            let store = await Storefront.current?.countryCode
            let code = ImageToolEngine.PhotoSize.homeCode(storefront: store)
            home = code
            if !sizeChosen && entryID == nil { size = ImageToolEngine.PhotoSize.preferred(for: code) }
        }
    }
    private func go(_ next: Int) { forward = next > step; step = next }

    // MARK: Recent

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Recent ID photos")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(history) { entry in
                        Button { reopen(entry) } label: {
                            VStack(spacing: 6) {
                                Group {
                                    if let image = PortraitHistory.photo(entry.id) { Image(uiImage: image).resizable().scaledToFit() }
                                    else { Color(white: 0.94) }
                                }
                                .frame(width: 66, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TK.grey200, lineWidth: 1))
                                Text(ImageToolEngine.PhotoSize.all.first { $0.id == entry.sizeID }?.title.components(separatedBy: " · ").first ?? "ID photo")
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(TK.grey600).lineLimit(1).frame(width: 76)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Reopen ID photo from \(entry.date.formatted(date: .abbreviated, time: .omitted))")
                        .contextMenu {
                            Button(role: .destructive) { PortraitHistory.remove(entry.id); history = PortraitHistory.list() } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }.padding(.vertical, 2)
            }
            Text("Reprint or remake in another size. Kept only on this iPhone.").font(.system(size: 12)).foregroundStyle(TK.grey500)
        }
        .accessibilityIdentifier("portrait-recent")
    }
    private func reopen(_ entry: PortraitHistoryEntry) {
        guard let image = PortraitHistory.source(entry.id) else { PortraitHistory.remove(entry.id); history = PortraitHistory.list(); return }
        work.run("Opening…") {
            subject = try await OfflineWork.perform { try ImageToolEngine.portraitSubject(image) }
            source = image; entryID = entry.id
            size = ImageToolEngine.PhotoSize.all.first { $0.id == entry.sizeID } ?? ImageToolEngine.PhotoSize.all[0]; sizeChosen = true
            backdrop = ImageToolEngine.Backdrop(rawValue: entry.backdrop) ?? .white
            adjust = ImageToolEngine.PortraitAdjust(zoom: entry.zoom, dx: entry.dx, dy: entry.dy)
            outfit = ImageToolEngine.Outfit(rawValue: entry.outfit) ?? .none
            outfitLift = entry.outfitLift
            render(); go(4)
        }
    }

    // MARK: Size

    private var sizePage: some View {
        ToolPage(title: "Which size do you need?", subtitle: "Check the rules of the office you're applying to.") {
            ForEach(ImageToolEngine.PhotoSize.regions(for: home), id: \.self) { region in
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        if let flag = ImageToolEngine.PhotoSize.flag(region) {
                            Text(flag).font(.system(size: 22)).accessibilityHidden(true)
                        } else {
                            Image(systemName: "person.text.rectangle").font(.system(size: 17, weight: .semibold)).foregroundStyle(TK.grey500)
                        }
                        Text(region).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey600)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    ForEach(ImageToolEngine.PhotoSize.all.filter { $0.region == region }) { option in
                        Button { size = option; sizeChosen = true } label: { OptionCard(title: option.title, detail: option.detail, selected: size == option) }
                            .buttonStyle(.plain).accessibilityIdentifier("size-" + option.id)
                    }
                }
            }
        } actions: {
            Button("Next") {
                adjust = ImageToolEngine.PortraitAdjust()
                if !size.allowsOutfit { outfit = .none }
                render(); go(2)
            }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("portrait-size-next")
        }
    }
    private var alignPage: some View {
        let metrics = subject.map { ImageToolEngine.portraitMetrics($0, size: size, adjust: adjust) }
        let fits = metrics.map { $0.head >= size.headMin - 0.05 && $0.head <= size.headMax + 0.05 } ?? false
        return ToolPage(title: "Line up head and shoulders", subtitle: "Drag to move and pinch to resize until the head sits inside the guide.") {
            PortraitAlignView(photo: photo, size: size, metrics: metrics, adjust: $adjust) { render() }
                .frame(maxWidth: .infinity).frame(height: 340)
            if let metrics {
                HStack(spacing: 8) {
                    Image(systemName: fits ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(fits ? TK.teal : TK.orange)
                    Text("Head \(String(format: "%.1f", metrics.head)) mm · needs \(String(format: "%g", size.headMin))–\(String(format: "%g", size.headMax)) mm")
                        .font(.footnote.weight(.semibold)).foregroundStyle(TK.grey700)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("portrait-head-size")
            }
            HStack(spacing: 10) {
                Button { adjust.zoom = max(0.7, adjust.zoom / 1.03); render() } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(ChipStyle(selected: false)).accessibilityLabel("Smaller head")
                Button("Auto fit") { adjust = ImageToolEngine.PortraitAdjust(); render() }
                    .buttonStyle(ChipStyle(selected: adjust == ImageToolEngine.PortraitAdjust())).accessibilityIdentifier("portrait-auto-fit")
                Button { adjust.zoom = min(1.4, adjust.zoom * 1.03); render() } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(ChipStyle(selected: false)).accessibilityLabel("Larger head")
            }.frame(maxWidth: .infinity)
        } actions: {
            Button("Next") { go(3) }.buttonStyle(CTAButtonStyle()).disabled(photo == nil).accessibilityIdentifier("portrait-align-next")
        }
    }

    // MARK: Background and outfit

    private var backdropPage: some View {
        ToolPage(title: size.allowsOutfit ? "Background and outfit" : "Pick a background",
                 subtitle: size.allowsOutfit ? "Pick a colour, and a suit or shirt if you like." : "Most passports need white or light grey.") {
            ZStack {
                if let photo { Image(uiImage: photo).resizable().scaledToFit().shadow(color: .black.opacity(0.12), radius: 10, y: 4) }
                else { ProgressView() }
            }.frame(maxWidth: .infinity).frame(height: 300)
            HStack(spacing: 14) {
                ForEach(ImageToolEngine.Backdrop.allCases) { option in
                    Button { backdrop = option; render() } label: {
                        Circle().fill(Color(option.color)).frame(width: 46, height: 46)
                            .overlay(Circle().strokeBorder(TK.grey300, lineWidth: 1))
                            .overlay(Circle().strokeBorder(backdrop == option ? TK.blue : .clear, lineWidth: 3).padding(-5))
                    }.accessibilityLabel(option.rawValue).accessibilityAddTraits(backdrop == option ? .isSelected : [])
                }
            }.frame(maxWidth: .infinity)
            if size.allowsOutfit {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Outfit")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(ImageToolEngine.Outfit.allCases) { option in
                                Button { outfit = option; render() } label: {
                                    VStack(spacing: 4) {
                                        Group {
                                            if option == .none { Image(systemName: "person.crop.square").font(.system(size: 26)).foregroundStyle(TK.grey500) }
                                            else if let image = UIImage(named: option.rawValue) { Image(uiImage: image).resizable().scaledToFit().padding(4) }
                                            else { Image(systemName: "tshirt").foregroundStyle(TK.grey500) }
                                        }
                                        .frame(width: 64, height: 64)
                                        .background(TK.grey50, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(outfit == option ? TK.blue : TK.grey200, lineWidth: outfit == option ? 2 : 1))
                                        Text(option.title).font(.system(size: 11, weight: .medium)).foregroundStyle(TK.grey700).lineLimit(1).frame(width: 74)
                                    }
                                }
                                .buttonStyle(.plain).accessibilityLabel(option.title).accessibilityAddTraits(outfit == option ? .isSelected : [])
                                .accessibilityIdentifier("outfit-" + option.id)
                            }
                        }
                    }
                    if outfit != .none {
                        HStack(spacing: 10) {
                            Button { outfitLift += 0.5; render() } label: { Label("Higher", systemImage: "arrow.up") }.buttonStyle(ChipStyle(selected: false))
                            Button { outfitLift -= 0.5; render() } label: { Label("Lower", systemImage: "arrow.down") }.buttonStyle(ChipStyle(selected: false))
                        }
                        Text("For résumés and applications. Passport offices don't accept edited clothing.")
                            .font(.system(size: 12)).foregroundStyle(TK.grey500)
                    }
                }
            }
        } actions: {
            Button("Next") { checks = subject.map { ImageToolEngine.portraitChecks($0, size: size, adjust: adjust) } ?? []; prepareOutput(); go(4) }
                .buttonStyle(CTAButtonStyle()).disabled(photo == nil).accessibilityIdentifier("portrait-backdrop-next")
        }
    }

    // MARK: Result

    private var resultPage: some View {
        ToolPage(title: resultTitle, subtitle: resultSubtitle) {
            if let shown = output == .sheet ? sheetImage : photo {
                Image(uiImage: shown).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: output == .sheet ? 240 : 280)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            }
            HStack(spacing: 8) {
                ForEach(Output.allCases.filter { $0 != .online || !size.digital.isEmpty }, id: \.self) { option in
                    Button(option.rawValue) { output = option; prepareOutput() }
                        .buttonStyle(ChipStyle(selected: output == option))
                        .accessibilityIdentifier("portrait-output-" + String(describing: option))
                }
            }
            if output == .sheet {
                HStack(spacing: 8) {
                    ForEach(ImageToolEngine.PrintPaper.allCases) { option in
                        Button(option.rawValue) { paper = option; prepareOutput() }.buttonStyle(ChipStyle(selected: paper == option))
                    }
                }
            }
            if output == .online {
                VStack(spacing: 10) {
                    ForEach(size.digital) { spec in
                        Button { digitalSpec = spec; prepareOutput() } label: {
                            OptionCard(title: spec.title.components(separatedBy: " · ").first ?? spec.title,
                                       detail: spec.title.components(separatedBy: " · ").dropFirst().joined(separator: " · "), selected: digitalSpec == spec) {
                                if digitalSpec == spec, let digitalData {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(digitalData.count), countStyle: .file))
                                        .font(.footnote.weight(.semibold)).foregroundStyle(TK.teal)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            if !checks.isEmpty { checkCard }
        } actions: {
            Button(output == .online ? "Save file" : "Save photo") { save() }.buttonStyle(CTAButtonStyle()).disabled(photo == nil).accessibilityIdentifier("portrait-save")
        }
    }
    private var resultTitle: String {
        switch output { case .single: return "Your ID photo"; case .sheet: return "Ready to print"; case .online: return "Ready to upload" }
    }
    private var resultSubtitle: String {
        switch output {
        case .single: return "\(size.title). Print at 300 dpi or use it online."
        case .sheet:
            let layout = ImageToolEngine.sheetLayout(size, paper: paper)
            return "\(layout.columns * layout.rows) copies on \(paper.rawValue) paper. Print at 100% and cut along the marks."
        case .online: return "Exact pixels and file size for the form. Share the file or save it to Documents."
        }
    }
    private var checkCard: some View {
        let failed = checks.filter { !$0.passed }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Photo check").font(.system(size: 16, weight: .bold)).foregroundStyle(TK.grey900)
                Spacer()
                Text(failed == 0 ? "All good" : "\(failed) to fix").font(.footnote.weight(.semibold))
                    .foregroundStyle(failed == 0 ? TK.teal : TK.orange)
            }
            ForEach(checks) { check in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: check.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(check.passed ? TK.teal : TK.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(TK.grey900)
                        Text(check.detail).font(.system(size: 13)).foregroundStyle(TK.grey600).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("An automatic guide only. The issuing office makes the final decision.").font(.system(size: 11)).foregroundStyle(TK.grey500)
        }
        .padding(16)
        .background(TK.grey50, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("portrait-checks")
    }

    private func render() {
        guard let subject else { return }
        let s = size, b = backdrop, a = adjust, lift = outfitLift
        let clothes = s.allowsOutfit ? outfit : .none
        work.preview {
            photo = try await OfflineWork.perform { try ImageToolEngine.portrait(subject, size: s, backdrop: b, adjust: a, outfit: clothes, outfitLift: lift) }
            prepareOutput()
        }
    }
    private func prepareOutput() {
        guard let photo else { return }
        switch output {
        case .single: break
        case .sheet: sheetImage = ImageToolEngine.printSheet(photo, size: size, paper: paper)
        case .online:
            if digitalSpec == nil || !size.digital.contains(where: { $0 == digitalSpec }) { digitalSpec = size.digital.first }
            if let spec = digitalSpec { digitalData = ImageToolEngine.digitalJPEG(photo, spec: spec, backdrop: backdrop.color) }
        }
    }
    private func save() {
        guard let photo else { return }
        let s = size, mode = output, paper = paper
        work.run("Saving…") {
            var entry = PortraitHistoryEntry(sizeID: s.id, backdrop: backdrop.rawValue, zoom: adjust.zoom, dx: adjust.dx, dy: adjust.dy,
                                             outfit: outfit.rawValue, outfitLift: outfitLift)
            if let entryID { entry.id = entryID }
            if let source { try? PortraitHistory.save(entry, source: source, photo: photo); entryID = entry.id }
            switch mode {
            case .single:
                _ = try await PhotoToolSaving.save([photo], title: "ID photo", millimeters: CGSize(width: s.width, height: s.height), recognize: false, store: store)
                saved = photo; savedFile = []
            case .sheet:
                let sheet = sheetImage ?? ImageToolEngine.printSheet(photo, size: s, paper: paper)
                let mm = ImageToolEngine.sheetLayout(s, paper: paper).sheet
                _ = try await PhotoToolSaving.save([sheet], title: "ID photo sheet", millimeters: mm, recognize: false, store: store)
                saved = sheet; savedFile = []
            case .online:
                guard let spec = digitalSpec, let data = digitalData, let image = UIImage(data: data) else { return }
                _ = try await PhotoToolSaving.save([image], title: "ID photo \(spec.width)x\(spec.height)", millimeters: CGSize(width: s.width, height: s.height), recognize: false, store: store)
                saved = image; savedFile = [("ID photo \(spec.width)x\(spec.height).jpg", data)]
            }
            go(5)
        }
    }
}

// MARK: - Smart erase

/// Smart erase that starts by finding fingers holding the page.
struct FingerRemovalTool: View { var body: some View { EraseTool(fingers: true) } }

private struct EraseTool: View {
    var fingers = false
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var work = ToolWork()
    @State private var step = 0
    @State private var forward = true
    @State private var original: UIImage?
    @State private var input: UIImage?
    @State private var strokes: [ImageToolEngine.Stroke] = []
    @State private var brush = 0.035
    @State private var result: UIImage?
    var body: some View {
        StepStack(step: step, forward: forward) {
            switch step {
            case 0:
                PhotoSourcePage(tool: .erase, title: fingers ? "Remove fingers" : "Erase anything",
                                subtitle: fingers ? "Scan or pick a page you held by hand. Fingers at the edges are found and filled in." : "Paint over handwriting, stains or objects. We'll fill the spot from its surroundings.", work: work, art: fingers ? .removeFingers : nil) { images in
                    guard let image = images.first else { return }
                    original = image; input = image; strokes = []; go(1)
                    if fingers {
                        work.run("Finding fingers…") {
                            let found = try await OfflineWork.perform { try ImageToolEngine.fingerStrokes(image) }
                            strokes = found
                            if found.isEmpty { work.message = "No fingers found at the edges. Paint over them instead." }
                        }
                    }
                }
            case 1: paintPage
            case 2: resultPage
            default: PhotoToolDone(title: "Saved without the marks", images: [result].compactMap { $0 }, name: "Erased") { dismiss() }
            }
        }
        .stepChrome(step: $step, forward: $forward, last: 3, work: work)
    }
    private func go(_ next: Int) { forward = next > step; step = next }
    private var paintPage: some View {
        ToolPage(title: fingers ? "Check the marked fingers" : "Paint over what to erase",
                 subtitle: fingers ? "Fingers are marked in red. Paint more or tap Erase." : "Pinch to zoom in for small spots. Cover it fully with a little margin.", scrolls: false) {
            if let message = work.message { ToastMessage(text: message) }
            if let input { ErasePainter(image: input, strokes: $strokes, brush: $brush) }
        } actions: {
            Button("Erase") { erase() }.buttonStyle(CTAButtonStyle()).disabled(strokes.isEmpty).accessibilityIdentifier("erase-run")
        }
    }
    private var resultPage: some View {
        ToolPage(title: "Check the result", subtitle: "Drag to compare. Erase more if something is left.", scrolls: false) {
            if let original, let result {
                BeforeAfterView(before: original, after: result).frame(maxHeight: .infinity)
                    .padding(8).background(TK.grey100, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        } actions: {
            Button("Erase more") { input = result; strokes = []; go(1) }.buttonStyle(SecondaryCTAStyle()).accessibilityIdentifier("erase-more")
            Button("Save") { save() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("erase-save")
        }
    }
    private func erase() {
        guard let input else { return }
        let marks = strokes
        work.run("Erasing…") {
            result = try await OfflineWork.perform { try ImageToolEngine.erase(input, strokes: marks) }
            go(2)
        }
    }
    private func save() {
        guard let result else { return }
        work.run("Saving…") {
            _ = try await PhotoToolSaving.save([result], title: "Erased photo", recognize: true, store: store)
            go(3)
        }
    }
}


// MARK: - Erase painter

/// Photo canvas for painting what to erase: pinch or buttons to zoom up to 6x,
/// Move mode to pan, and a brush that keeps its on-screen size so zoomed
/// strokes are finer. Used by Smart erase and the page editor.
struct ErasePainter: View {
    let image: UIImage
    @Binding var strokes: [ImageToolEngine.Stroke]
    @Binding var brush: Double
    @State private var current: ImageToolEngine.Stroke?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var moving = false
    @State private var pinching = false
    @State private var pinchStart: CGFloat?
    @State private var dragStart: CGSize?
    @State private var display: UIImage?
    var body: some View {
        VStack(spacing: 12) {
                GeometryReader { geo in
                        let rect = AVFit.rect(for: image.size, in: geo.size)
                        let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                        // Screen point -> unzoomed canvas point.
                        let unzoom: (CGPoint) -> CGPoint = { l in
                            CGPoint(x: center.x + (l.x - center.x - pan.width) / zoom, y: center.y + (l.y - center.y - pan.height) / zoom)
                        }
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: display ?? image).resizable().interpolation(.high)
                                .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                            Canvas { context, _ in
                                for stroke in strokes + [current].compactMap({ $0 }) {
                                    var path = Path()
                                    let pts = stroke.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
                                    guard let first = pts.first else { continue }
                                    path.move(to: first)
                                    if pts.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
                                    for p in pts.dropFirst() { path.addLine(to: p) }
                                    context.stroke(path, with: .color(TK.red.opacity(0.45)), style: StrokeStyle(lineWidth: stroke.width * rect.width, lineCap: .round, lineJoin: .round))
                                }
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(zoom).offset(pan)
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard !pinching else { return }
                            if moving {
                                if dragStart == nil { dragStart = pan }
                                let start = dragStart ?? .zero
                                pan = clampPan(CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height), size: geo.size)
                                return
                            }
                            let c = unzoom(value.location)
                            let p = CGPoint(x: min(1, max(0, (c.x - rect.minX) / rect.width)), y: min(1, max(0, (c.y - rect.minY) / rect.height)))
                            // Same brush size on screen at any zoom, so zooming in gives finer strokes.
                            if current == nil { current = ImageToolEngine.Stroke(points: [p], width: brush / zoom) } else { current?.points.append(p) }
                        }.onEnded { _ in
                            dragStart = nil
                            if let current, !pinching { strokes.append(current) }
                            current = nil
                        })
                        .simultaneousGesture(MagnifyGesture().onChanged { value in
                            pinching = true; current = nil
                            if pinchStart == nil { pinchStart = zoom }
                            zoom = min(6, max(1, (pinchStart ?? 1) * value.magnification))
                            pan = clampPan(pan, size: geo.size)
                        }.onEnded { _ in
                            pinchStart = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pinching = false }
                        })
                        .accessibilityLabel("Photo. Drag to paint over what to erase. Pinch to zoom.").accessibilityIdentifier("erase-canvas")
                    }
                    .padding(8).background(TK.grey100, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if zoom > 1.01 {
                            Button { withAnimation(.snappy) { zoom = 1; pan = .zero; moving = false } } label: {
                                Label(String(format: "%.1f×", zoom), systemImage: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }.buttonStyle(.plain).padding(14).accessibilityIdentifier("erase-zoom-reset")
                        }
                    }
                    .frame(maxHeight: .infinity)
                HStack(spacing: 8) {
                    Button { moving = false } label: { Label("Paint", systemImage: "paintbrush.pointed.fill") }
                        .buttonStyle(ChipStyle(selected: !moving)).accessibilityIdentifier("erase-mode-paint")
                    Button { moving = true } label: { Label("Move", systemImage: "hand.draw.fill") }
                        .buttonStyle(ChipStyle(selected: moving)).disabled(zoom <= 1.01).accessibilityIdentifier("erase-mode-move")
                    Spacer()
                    Button { withAnimation(.snappy) { zoom = min(6, zoom * 1.6) } } label: { Image(systemName: "plus.magnifyingglass").font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 40) }
                        .accessibilityLabel("Zoom in").accessibilityIdentifier("erase-zoom-in")
                    Button { withAnimation(.snappy) { zoom = max(1, zoom / 1.6); if zoom <= 1.01 { zoom = 1; pan = .zero; moving = false } } } label: { Image(systemName: "minus.magnifyingglass").font(.system(size: 18, weight: .semibold)).frame(width: 40, height: 40) }
                        .disabled(zoom <= 1.01).accessibilityLabel("Zoom out")
                }.foregroundStyle(TK.grey700)
                HStack(spacing: 16) {
                    Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(TK.grey500)
                    Slider(value: $brush, in: 0.012...0.12).tint(TK.blue).accessibilityLabel("Brush size")
                    Image(systemName: "circle.fill").font(.system(size: 20)).foregroundStyle(TK.grey500)
                    Button { if !strokes.isEmpty { strokes.removeLast() } } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                        .disabled(strokes.isEmpty).accessibilityLabel("Undo")
                }.foregroundStyle(TK.grey700)
        }
        .task(id: ObjectIdentifier(image)) {
            // Paint on a screen-sized copy; strokes are normalized, so the erase
            // still runs on the full image. Keeps memory low on 12–48 MP photos.
            let side = max(image.size.width, image.size.height) * image.scale
            display = side > 2400 ? await image.byPreparingThumbnail(ofSize: CGSize(width: image.size.width * 2400 / side * image.scale, height: image.size.height * 2400 / side * image.scale)) : image
        }
    }
    /// Keeps the zoomed photo covering the frame.
    private func clampPan(_ p: CGSize, size: CGSize) -> CGSize {
        let mx = size.width * (zoom - 1) / 2, my = size.height * (zoom - 1) / 2
        return CGSize(width: min(mx, max(-mx, p.width)), height: min(my, max(-my, p.height)))
    }
}

// MARK: - Remove colored marks

private struct MarksTool: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var work = ToolWork()
    @State private var step = 0
    @State private var forward = true
    @State private var input: UIImage?
    @State private var preview: UIImage?
    @State private var colors: Set<ImageToolEngine.MarkColor> = Set(ImageToolEngine.MarkColor.allCases)
    @State private var strength = 1.0
    @State private var saved: UIImage?
    var body: some View {
        StepStack(step: step, forward: forward) {
            switch step {
            case 0:
                PhotoSourcePage(tool: .marks, title: "Remove pen and highlighter", subtitle: "Colored ink disappears. Black printed text stays.", work: work) { images in
                    guard let image = images.first else { return }
                    input = image; go(1); render()
                }
            case 1: cleanPage
            default: PhotoToolDone(title: "Saved a clean copy", images: [saved].compactMap { $0 }, name: "Clean page") { dismiss() }
            }
        }
        .stepChrome(step: $step, forward: $forward, last: 2, work: work)
    }
    private func go(_ next: Int) { forward = next > step; step = next }
    private var cleanPage: some View {
        ToolPage(title: "Which ink should go?", subtitle: "Drag the picture to compare.", scrolls: false) {
            if let input {
                Group {
                    if let preview { BeforeAfterView(before: input, after: preview) }
                    else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(maxHeight: .infinity).padding(8).background(TK.grey100, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ImageToolEngine.MarkColor.allCases) { color in
                        Button {
                            if colors.contains(color) { colors.remove(color) } else { colors.insert(color) }
                            render()
                        } label: {
                            HStack(spacing: 6) { Circle().fill(Color(color.swatch)).frame(width: 14, height: 14); Text(color.rawValue) }
                        }.buttonStyle(ChipStyle(selected: colors.contains(color))).accessibilityIdentifier("ink-" + color.rawValue)
                    }
                }
            }
            ToolSlider(title: "Strength", value: $strength, range: 0.3...1).onChange(of: strength) { _, _ in render() }
        } actions: {
            Button("Save clean copy") { save() }.buttonStyle(CTAButtonStyle()).disabled(colors.isEmpty).accessibilityIdentifier("marks-save")
        }
    }
    private func render() {
        guard let input, !colors.isEmpty else { preview = input; return }
        let small = Imaging.limited(input, maxPixels: 2_500_000), set = colors, s = strength
        work.preview { preview = try await OfflineWork.perform { try ImageToolEngine.removeMarks(small, colors: set, strength: s) } }
    }
    private func save() {
        guard let input else { return }
        let set = colors, s = strength
        work.run("Cleaning the full page…") {
            let full = try await OfflineWork.perform { try ImageToolEngine.removeMarks(input, colors: set, strength: s) }
            _ = try await PhotoToolSaving.save([full], title: "Clean page", recognize: true, store: store)
            saved = full; go(2)
        }
    }
}

// MARK: - Restore photo

private struct RestoreTool: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var work = ToolWork()
    @State private var step = 0
    @State private var forward = true
    @State private var input: UIImage?
    @State private var preview: UIImage?
    @State private var level = ImageToolEngine.RestoreLevel.standard
    @State private var fixColor = true
    @State private var saved: UIImage?
    var body: some View {
        StepStack(step: step, forward: forward) {
            switch step {
            case 0:
                PhotoSourcePage(tool: .restore, title: "Restore an old photo", subtitle: "Fix faded colors, dust, small scratches and blur in one step.", work: work) { images in
                    guard let image = images.first else { return }
                    input = image; preview = nil; go(1); render()
                }
            case 1: resultPage
            default: PhotoToolDone(title: "Your restored photo is saved", images: [saved].compactMap { $0 }, name: "Restored") { dismiss() }
            }
        }
        .stepChrome(step: $step, forward: $forward, last: 2, work: work)
    }
    private func go(_ next: Int) { forward = next > step; step = next }
    private var resultPage: some View {
        ToolPage(title: "Restored", subtitle: "Drag to compare with the original.", scrolls: false) {
            if let input {
                Group {
                    if let preview { BeforeAfterView(before: input, after: preview) }
                    else { VStack(spacing: 12) { ProgressView(); Text("Restoring…").foregroundStyle(TK.grey600) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(maxHeight: .infinity).padding(8).background(TK.grey100, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            HStack(spacing: 8) {
                ForEach(ImageToolEngine.RestoreLevel.allCases) { option in
                    Button(option.rawValue) { level = option; render() }.buttonStyle(ChipStyle(selected: level == option))
                        .accessibilityIdentifier("restore-" + option.rawValue)
                }
                Spacer(minLength: 0)
            }
            Toggle(isOn: $fixColor) { Text("Fix faded colors").font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey800) }
                .tint(TK.blue).onChange(of: fixColor) { _, _ in render() }
        } actions: {
            Button("Save photo") { save() }.buttonStyle(CTAButtonStyle()).disabled(preview == nil).accessibilityIdentifier("restore-save")
        }
    }
    private func render() {
        guard let input else { return }
        let small = Imaging.limited(input, maxPixels: 3_000_000), l = level, c = fixColor
        work.preview { preview = try await OfflineWork.perform { try ImageToolEngine.restore(small, level: l, fixColor: c) } }
    }
    private func save() {
        guard let input else { return }
        let l = level, c = fixColor
        work.run("Restoring at full size…") {
            let full = try await OfflineWork.perform { try ImageToolEngine.restore(input, level: l, fixColor: c) }
            _ = try await PhotoToolSaving.save([full], title: "Restored photo", recognize: false, store: store)
            saved = full; go(2)
        }
    }
}

// MARK: - Mega scan

private struct MegaTool: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var work = ToolWork()
    @State private var step = 0
    @State private var forward = true
    @State private var images: [UIImage] = []
    @State private var offsets: [CGPoint] = []
    @State private var result: UIImage?
    @State private var adjusting = false
    var body: some View {
        StepStack(step: step, forward: forward) {
            switch step {
            case 0:
                PhotoSourcePage(tool: .mega, title: "Combine photos into one", subtitle: "For posters, drawings and big documents. Take overlapping photos from left to right, top to bottom.", multiple: true, work: work) { picked in
                    guard picked.count >= 2 else { work.message = "Choose at least 2 overlapping photos."; return }
                    images = Array(picked.prefix(8)); arrange()
                }
            case 1: resultPage
            default: PhotoToolDone(title: "Saved your large scan", images: [result].compactMap { $0 }, name: "Mega scan") { dismiss() }
            }
        }
        .stepChrome(step: $step, forward: $forward, last: 2, work: work)
        .sheet(isPresented: $adjusting) { MegaAdjustSheet(images: $images, offsets: $offsets) { compose() } }
    }
    private func go(_ next: Int) { forward = next > step; step = next }
    private var resultPage: some View {
        ToolPage(title: "Your combined image", subtitle: "\(images.count) photos matched by their overlap.", scrolls: false) {
            if let result {
                Image(uiImage: result).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8).background(TK.grey100, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityIdentifier("mega-result")
            }
            if let message = work.message { ToastMessage(text: message, symbol: "info.circle.fill", tint: TK.orange) }
        } actions: {
            Button("Adjust positions") { adjusting = true }.buttonStyle(SecondaryCTAStyle()).accessibilityIdentifier("mega-adjust")
            Button("Save image") { save() }.buttonStyle(CTAButtonStyle()).disabled(result == nil).accessibilityIdentifier("mega-save")
        }
    }
    private func arrange() {
        let photos = images
        work.run("Matching overlaps…") {
            do { offsets = try await OfflineWork.perform { try ImageToolEngine.autoArrange(photos) } }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Fall back to a left-to-right row the user can adjust.
                var x: CGFloat = 0
                offsets = photos.map { image in defer { x += image.size.width * 0.75 }; return CGPoint(x: x, y: 0) }
                work.message = error.localizedDescription + " You can adjust the positions."
            }
            let note = work.message, positions = offsets
            result = try await OfflineWork.perform { try ImageToolEngine.stitch(photos, offsets: positions) }
            go(1)
            work.message = note
        }
    }
    private func compose() {
        let photos = images, positions = offsets
        work.run("Combining…") { result = try await OfflineWork.perform { try ImageToolEngine.stitch(photos, offsets: positions) } }
    }
    private func save() {
        guard let result else { return }
        work.run("Saving…") {
            _ = try await PhotoToolSaving.save([result], title: "Mega scan", recognize: true, store: store)
            go(2)
        }
    }
}

/// Fine-tuning for combined photos: one photo at a time, nudged against the previous one.
private struct MegaAdjustSheet: View {
    @Binding var images: [UIImage]
    @Binding var offsets: [CGPoint]
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 1
    var body: some View {
        NavigationStack {
            ToolPage(title: "Move photo \(index + 1)", subtitle: "Line up shared details with photo \(index).") {
                Picker("Photo", selection: $index) {
                    ForEach(1..<images.count, id: \.self) { Text("Photo \($0 + 1)").tag($0) }
                }.pickerStyle(.segmented)
                if offsets.indices.contains(index) {
                    let size = images[index].size
                    ToolSlider(title: "Left – right", value: Binding(get: { Double(offsets[index].x - offsets[index - 1].x) }, set: { offsets[index].x = offsets[index - 1].x + $0 }),
                               range: -Double(size.width)...Double(size.width)) { "\(Int($0)) px" }
                    ToolSlider(title: "Up – down", value: Binding(get: { Double(offsets[index].y - offsets[index - 1].y) }, set: { offsets[index].y = offsets[index - 1].y + $0 }),
                               range: -Double(size.height)...Double(size.height)) { "\(Int($0)) px" }
                }
            } actions: {
                Button("Apply") { dismiss(); done() }.buttonStyle(CTAButtonStyle())
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

// MARK: - Count objects

private struct CountTool: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var work = ToolWork()
    @State private var step = 0
    @State private var forward = true
    @State private var input: UIImage?
    @State private var points: [CGPoint] = []
    @State private var radius: CGFloat = 0.03
    @State private var polarity = ImageToolEngine.Polarity.auto
    @State private var sensitivity = 0.5
    @State private var saved: UIImage?
    var body: some View {
        StepStack(step: step, forward: forward) {
            switch step {
            case 0:
                PhotoSourcePage(tool: .count, title: "Count objects", subtitle: "Pipes, coins, pills, boxes – spread them on a plain, contrasting surface.", work: work) { images in
                    guard let image = images.first else { return }
                    input = image; detect(then: { go(1) })
                }
            case 1: countPage
            default: PhotoToolDone(title: "Saved with \(points.count) markers", images: [saved].compactMap { $0 }, name: "Count") { dismiss() }
            }
        }
        .stepChrome(step: $step, forward: $forward, last: 2, work: work)
    }
    private func go(_ next: Int) { forward = next > step; step = next }
    private var countPage: some View {
        ToolPage(title: "", scrolls: false) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(points.count)").font(.system(size: 44, weight: .heavy)).foregroundStyle(TK.grey900).monospacedDigit()
                    .contentTransition(.numericText()).accessibilityIdentifier("count-total")
                Text(points.count == 1 ? "object" : "objects").font(.system(size: 20, weight: .bold)).foregroundStyle(TK.grey700)
                Spacer()
                Text("Tap to add or remove").font(.system(size: 13, weight: .medium)).foregroundStyle(TK.grey500)
            }
            if let input {
                GeometryReader { geo in
                    let rect = AVFit.rect(for: input.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: input).resizable().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                        let r = max(9, min(20, radius * rect.width * 0.6))
                        ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                            Text("\(i + 1)").font(.system(size: r * 0.85, weight: .heavy)).foregroundStyle(.white)
                                .frame(width: r * 2, height: r * 2).background(TK.teal.opacity(0.9), in: Circle())
                                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                                .offset(x: rect.minX + p.x * rect.width - r, y: rect.minY + p.y * rect.height - r)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let p = CGPoint(x: (location.x - rect.minX) / rect.width, y: (location.y - rect.minY) / rect.height)
                        guard (0...1).contains(p.x), (0...1).contains(p.y) else { return }
                        let hit = max(0.02, radius * 0.8)
                        withAnimation(.snappy) {
                            if let i = points.indices.min(by: { hypot(points[$0].x - p.x, points[$0].y - p.y) < hypot(points[$1].x - p.x, points[$1].y - p.y) }),
                               hypot(points[i].x - p.x, points[i].y - p.y) < hit { points.remove(at: i) }
                            else if points.count < 999 { points.append(p) }
                        }
                    }
                    .accessibilityElement().accessibilityLabel("Photo with \(points.count) markers").accessibilityIdentifier("count-canvas")
                }
                .padding(8).background(TK.grey100, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .frame(maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                ForEach(ImageToolEngine.Polarity.allCases) { option in
                    Button(option.rawValue) { polarity = option; detect() }.buttonStyle(ChipStyle(selected: polarity == option))
                }
            }
            ToolSlider(title: "Sensitivity", value: $sensitivity).onChange(of: sensitivity) { _, _ in detect() }
        } actions: {
            Button("Save count") { save() }.buttonStyle(CTAButtonStyle()).disabled(input == nil).accessibilityIdentifier("count-save")
        }
    }
    private func detect(then: (() -> Void)? = nil) {
        guard let input else { return }
        let p = polarity, s = sensitivity
        let task: @MainActor () async throws -> Void = {
            let result = try await OfflineWork.perform { try ImageToolEngine.count(input, polarity: p, sensitivity: s) }
            withAnimation(.snappy) { points = result.points; radius = result.radius }
            then?()
        }
        if then != nil { work.run("Counting…", task) } else { work.preview(task) }
    }
    private func save() {
        guard let input else { return }
        let marks = points, r = radius
        work.run("Saving…") {
            let image = await OfflineWorkHelpers.annotate(input, marks, r)
            _ = try await PhotoToolSaving.save([image], title: "Count · \(marks.count)", recognize: false, store: store)
            saved = image; go(2)
        }
    }
}
enum OfflineWorkHelpers {
    static func annotate(_ image: UIImage, _ points: [CGPoint], _ radius: CGFloat) async -> UIImage {
        await Task.detached { ImageToolEngine.annotated(image, points: points, radius: radius) }.value
    }
}

/// The ID photo with the size's guide on top: crown and chin lines with the
/// allowed head range, a head outline, the shoulder line and the centre
/// line. Dragging moves the photo, pinching resizes the head.
private struct PortraitAlignView: View {
    let photo: UIImage?
    let size: ImageToolEngine.PhotoSize
    let metrics: ImageToolEngine.PortraitMetrics?
    @Binding var adjust: ImageToolEngine.PortraitAdjust
    let changed: () -> Void
    @State private var drag: CGSize = .zero
    @State private var pinch: CGFloat = 1
    var body: some View {
        GeometryReader { geo in
            let aspect = CGFloat(size.width / size.height)
            let h = min(geo.size.height, geo.size.width / aspect), w = h * aspect
            let k = w / CGFloat(size.width)   // points per millimetre
            ZStack {
                Color(white: 0.96)
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill()
                        .frame(width: w, height: h)
                        .scaleEffect(pinch, anchor: .center)
                        .offset(drag)
                }
                guide(k: k, w: w, h: h)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TK.grey300, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        adjust.dx += Double(value.translation.width / k)
                        adjust.dy -= Double(value.translation.height / k)
                        drag = .zero
                        changed()
                    }
                    .simultaneously(with: MagnificationGesture()
                        .onChanged { pinch = $0 }
                        .onEnded { value in
                            adjust.zoom = min(1.4, max(0.7, adjust.zoom * Double(value)))
                            pinch = 1
                            changed()
                        })
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("ID photo with head and shoulder guide")
            .accessibilityAdjustableAction { direction in
                adjust.zoom = direction == .increment ? min(1.4, adjust.zoom * 1.03) : max(0.7, adjust.zoom / 1.03)
                changed()
            }
            .accessibilityIdentifier("portrait-align")
        }
    }
    @ViewBuilder private func guide(k: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        let crown = CGFloat(size.crownGap) * k
        let chinNear = crown + CGFloat(size.headMin) * k, chinFar = crown + CGFloat(size.headMax) * k
        let target = crown + CGFloat(size.headTarget) * k
        let headW = CGFloat(size.headTarget) * k * 0.74
        let fits = metrics.map { $0.head >= size.headMin - 0.05 && $0.head <= size.headMax + 0.05 } ?? false
        let tint = fits ? TK.teal : TK.orange
        ZStack(alignment: .topLeading) {
            // Allowed band for the chin.
            Rectangle().fill(tint.opacity(0.12)).frame(width: w, height: max(1, chinFar - chinNear)).offset(y: chinNear)
            Path { p in p.move(to: CGPoint(x: 0, y: crown)); p.addLine(to: CGPoint(x: w, y: crown)) }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            Path { p in p.move(to: CGPoint(x: 0, y: target)); p.addLine(to: CGPoint(x: w, y: target)) }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            Path { p in p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h)) }
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
            // Head outline and shoulders.
            Ellipse().stroke(Color.white.opacity(0.95), lineWidth: 2)
                .frame(width: headW, height: target - crown).offset(x: (w - headW) / 2, y: crown)
            Path { p in
                let neck = target + (target - crown) * 0.12, shoulder = target + (target - crown) * 0.42
                p.move(to: CGPoint(x: w / 2 - headW * 0.32, y: neck))
                p.addQuadCurve(to: CGPoint(x: max(0, w / 2 - headW * 1.35), y: min(h, shoulder + headW * 0.25)), control: CGPoint(x: w / 2 - headW * 0.45, y: shoulder))
                p.move(to: CGPoint(x: w / 2 + headW * 0.32, y: neck))
                p.addQuadCurve(to: CGPoint(x: min(w, w / 2 + headW * 1.35), y: min(h, shoulder + headW * 0.25)), control: CGPoint(x: w / 2 + headW * 0.45, y: shoulder))
            }.stroke(Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Text("Top of head").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2).background(tint, in: Capsule())
                .offset(x: 6, y: max(0, crown - 18))
            Text("Chin").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2).background(tint, in: Capsule())
                .offset(x: 6, y: min(h - 18, chinFar + 2))
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - ID photo camera

/// Front camera with a head-and-shoulder outline and live hints, so the photo
/// is framed for an ID photo before it's taken.
struct PortraitCameraView: View {
    let completion: (UIImage?) -> Void
    @StateObject private var camera = PortraitCamera()
    @State private var timer = 0
    @State private var countdown: Int?
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let hint = Self.hint(face: camera.faceRect, roll: camera.roll, in: size)
            ZStack {
                Color.black
                PortraitPreview(camera: camera)
                PortraitGuide(size: size, ready: hint.ready)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    HStack {
                        Button { completion(nil) } label: { Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                            .accessibilityLabel("Close")
                        Spacer()
                        Button { timer = timer == 0 ? 3 : 0 } label: {
                            Label(timer == 0 ? "Timer off" : "3 s", systemImage: "timer").font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 12).frame(height: 36).background(.black.opacity(0.35), in: Capsule())
                        }
                        .accessibilityIdentifier("portrait-camera-timer")
                        Button { camera.flip() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                            .accessibilityLabel("Switch camera")
                    }
                    .foregroundStyle(.white).padding(.horizontal, 12).padding(.top, geo.safeAreaInsets.top + 4)
                    Spacer()
                    Text(hint.text)
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(hint.ready ? TK.teal : Color.black.opacity(0.55), in: Capsule())
                        .animation(.easeOut(duration: 0.2), value: hint.text)
                        .accessibilityIdentifier("portrait-camera-hint")
                    Button { shoot() } label: {
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                            .overlay(Circle().fill(hint.ready ? TK.teal : .white).padding(8))
                    }
                    .disabled(countdown != nil)
                    .accessibilityLabel("Take photo")
                    .accessibilityIdentifier("portrait-camera-shutter")
                    .padding(.top, 18).padding(.bottom, geo.safeAreaInsets.bottom + 18)
                }
                if let countdown {
                    Text("\(countdown)").font(.system(size: 96, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .shadow(radius: 8).transition(.scale.combined(with: .opacity)).id(countdown)
                }
                if let failed = camera.failed {
                    Text(failed).font(.system(size: 15)).foregroundStyle(.white).multilineTextAlignment(.center).padding(24)
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .onAppear { camera.completion = completion; camera.start() }
        .onDisappear { camera.stop() }
    }
    private func shoot() {
        guard timer > 0 else { camera.capture(); return }
        Task { @MainActor in
            for n in stride(from: timer, through: 1, by: -1) {
                withAnimation(.easeOut(duration: 0.2)) { countdown = n }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            countdown = nil
            camera.capture()
        }
    }
    /// What to tell the user, from the face box in screen points. The outline
    /// wants the face (brows to chin) about a quarter of the screen tall,
    /// centred a little above the middle.
    static func hint(face: CGRect?, roll: CGFloat, in size: CGSize) -> (text: String, ready: Bool) {
        guard let f = face, size.width > 0, size.height > 0 else { return ("Fit your head inside the outline", false) }
        let w = size.width, h = size.height
        let tilt = roll > 180 ? roll - 360 : roll
        if f.height < h * 0.19 { return ("Move closer", false) }
        if f.height > h * 0.32 { return ("Move back a little", false) }
        if abs(f.midX - w / 2) > w * 0.08 { return (f.midX < w / 2 ? "Move right a little" : "Move left a little", false) }
        if f.midY < h * 0.34 { return ("Lower your head in the frame", false) }
        if f.midY > h * 0.46 { return ("Raise your head in the frame", false) }
        if abs(tilt) > 8 { return ("Keep your head level", false) }
        return ("Looks good. Hold still", true)
    }
}

/// Head oval, neck and shoulder lines drawn over the camera.
private struct PortraitGuide: View {
    let size: CGSize
    let ready: Bool
    var body: some View {
        let w = size.width, h = size.height
        let head = CGRect(x: w * 0.27, y: h * 0.19, width: w * 0.46, height: h * 0.34)
        ZStack {
            // Dim everything outside the head so the outline reads clearly.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addEllipse(in: head)
            }
            .fill(Color.black.opacity(0.28), style: FillStyle(eoFill: true))
            Ellipse().path(in: head)
                .stroke(ready ? TK.teal : .white, style: StrokeStyle(lineWidth: 3, dash: ready ? [] : [10, 7]))
            Path { p in
                let neckY = head.maxY + h * 0.035, shoulderY = head.maxY + h * 0.13
                p.move(to: CGPoint(x: w / 2 - w * 0.09, y: head.maxY - h * 0.01))
                p.addLine(to: CGPoint(x: w / 2 - w * 0.1, y: neckY))
                p.addQuadCurve(to: CGPoint(x: w * 0.02, y: shoulderY + h * 0.08), control: CGPoint(x: w * 0.12, y: neckY + h * 0.01))
                p.move(to: CGPoint(x: w / 2 + w * 0.09, y: head.maxY - h * 0.01))
                p.addLine(to: CGPoint(x: w / 2 + w * 0.1, y: neckY))
                p.addQuadCurve(to: CGPoint(x: w * 0.98, y: shoulderY + h * 0.08), control: CGPoint(x: w * 0.88, y: neckY + h * 0.01))
            }
            .stroke(ready ? TK.teal : .white, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: ready ? [] : [10, 7]))
            Path { p in p.move(to: CGPoint(x: head.minX - 14, y: head.minY)); p.addLine(to: CGPoint(x: head.maxX + 14, y: head.minY)) }
                .stroke(Color.white.opacity(0.6), lineWidth: 1)
            Text("Top of head").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                .position(x: w / 2, y: head.minY - 12)
        }
        .animation(.easeOut(duration: 0.2), value: ready)
        .accessibilityHidden(true)
    }
}

private struct PortraitPreview: UIViewRepresentable {
    let camera: PortraitCamera
    func makeUIView(context: Context) -> PortraitPreviewView {
        let view = PortraitPreviewView()
        view.preview.session = camera.session
        view.preview.videoGravity = .resizeAspectFill
        camera.previewLayer = view.preview
        return view
    }
    func updateUIView(_ view: PortraitPreviewView, context: Context) {}
}
final class PortraitPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// Front camera session with face tracking for the guide.
final class PortraitCamera: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let metadata = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "portrait.camera")
    private var position: AVCaptureDevice.Position = .front
    private var configured = false
    @Published var faceRect: CGRect?
    @Published var roll: CGFloat = 0
    @Published var failed: String?
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    var completion: ((UIImage?) -> Void)?

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.failed = "Allow camera access in Settings to take an ID photo." }
                return
            }
            self.queue.async {
                if !self.configured { self.configure(); self.configured = true }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
    func flip() {
        queue.async {
            self.position = self.position == .front ? .back : .front
            self.configure()
        }
    }
    func capture() {
        queue.async {
            guard self.session.isRunning else { return }
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        for input in session.inputs { session.removeInput(input) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            DispatchQueue.main.async { self.failed = "The camera isn't available." }
            return
        }
        session.addInput(input)
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if !session.outputs.contains(metadata), session.canAddOutput(metadata) {
            session.addOutput(metadata)
            metadata.setMetadataObjectsDelegate(self, queue: .main)
        }
        if metadata.availableMetadataObjectTypes.contains(.face) { metadata.metadataObjectTypes = [.face] }
        if let connection = photoOutput.connection(with: .video), connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let face = objects.compactMap({ $0 as? AVMetadataFaceObject }).first,
              let shown = previewLayer?.transformedMetadataObject(for: face) else { faceRect = nil; return }
        faceRect = shown.bounds
        roll = face.hasRollAngle ? face.rollAngle : 0
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }.map { Imaging.normalized($0) }
        DispatchQueue.main.async {
            if image == nil { self.failed = "The photo couldn't be taken. Try again." ; return }
            self.completion?(image)
        }
    }
}
