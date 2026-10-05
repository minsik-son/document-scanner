import SwiftUI
import PhotosUI

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
    let picked: ([UIImage]) -> Void
    var body: some View {
        ToolPage(title: title, subtitle: subtitle) {
            ToolHero(art: tool.art)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: multiple ? "Add your photos" : "Add a photo")
                PhotoSourceChoices(multiple: multiple, frontCamera: frontCamera, picked: picked,
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
    let finish: () -> Void
    @State private var files: ExportedFiles?
    var body: some View {
        ToolDonePage(title: title, detail: "You'll find it in Documents. The original photo is unchanged.",
                     primary: finish, secondaryTitle: images.count > 1 ? "Share \(images.count) images" : "Share image",
                     secondary: { files = try? PhotoToolSaving.share(images, name: name) }) {
            if !images.isEmpty {
                HStack(spacing: -40) {
                    ForEach(Array(images.prefix(3).enumerated()), id: \.offset) { i, image in
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 210)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
                            .rotationEffect(.degrees(images.count > 1 ? Double(i) * 6 - 3 : 0))
                            .zIndex(Double(-i))
                    }
                }.padding(.top, 6)
            }
        }
        .sheet(item: $files) { files in ShareSheet(items: files.urls) { _, _ in ExportFiles.remove(files.directory) } }
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
    @State private var step = 0
    @State private var forward = true
    @State private var subject: ImageToolEngine.PortraitSubject?
    @State private var size = ImageToolEngine.PhotoSize.all[0]
    @State private var backdrop = ImageToolEngine.Backdrop.white
    @State private var adjust = ImageToolEngine.PortraitAdjust()
    @State private var photo: UIImage?
    @State private var sheet = false
    @State private var sheetImage: UIImage?
    @State private var saved: UIImage?
    var body: some View {
        StepStack(step: step, forward: forward) {
            switch step {
            case 0:
                PhotoSourcePage(tool: .portrait, title: "Make an ID photo", subtitle: "Face the camera on a plain background. We'll do the cut-out, size and background.", frontCamera: true, work: work) { images in
                    guard let image = images.first else { return }
                    work.run("Finding your face…") {
                        subject = try await OfflineWork.perform { try ImageToolEngine.portraitSubject(image) }
                        go(1)
                    }
                }
            case 1: sizePage
            case 2: alignPage
            case 3: backdropPage
            case 4: resultPage
            default: PhotoToolDone(title: "Your ID photo is saved", images: [saved].compactMap { $0 }, name: "ID photo") { dismiss() }
            }
        }
        .stepChrome(step: $step, forward: $forward, last: 5, work: work)
    }
    private func go(_ next: Int) { forward = next > step; step = next }
    private var sizePage: some View {
        ToolPage(title: "Which size do you need?", subtitle: "Check the rules of the office you're applying to.") {
            VStack(spacing: 10) {
                ForEach(ImageToolEngine.PhotoSize.all) { option in
                    Button { size = option } label: { OptionCard(title: option.title, detail: option.detail, selected: size == option) }
                        .buttonStyle(.plain).accessibilityIdentifier("size-" + option.id)
                }
            }
        } actions: {
            Button("Next") { adjust = ImageToolEngine.PortraitAdjust(); render(); go(2) }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("portrait-size-next")
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
    private var backdropPage: some View {
        ToolPage(title: "Pick a background", subtitle: "Most passports need white or light grey.") {
            ZStack {
                if let photo { Image(uiImage: photo).resizable().scaledToFit().shadow(color: .black.opacity(0.12), radius: 10, y: 4) }
                else { ProgressView() }
            }.frame(maxWidth: .infinity).frame(height: 320)
            HStack(spacing: 14) {
                ForEach(ImageToolEngine.Backdrop.allCases) { option in
                    Button { backdrop = option; render() } label: {
                        Circle().fill(Color(option.color)).frame(width: 46, height: 46)
                            .overlay(Circle().strokeBorder(TK.grey300, lineWidth: 1))
                            .overlay(Circle().strokeBorder(backdrop == option ? TK.blue : .clear, lineWidth: 3).padding(-5))
                    }.accessibilityLabel(option.rawValue).accessibilityAddTraits(backdrop == option ? .isSelected : [])
                }
            }.frame(maxWidth: .infinity)
        } actions: {
            Button("Next") { go(4) }.buttonStyle(CTAButtonStyle()).disabled(photo == nil).accessibilityIdentifier("portrait-backdrop-next")
        }
    }
    private var resultPage: some View {
        ToolPage(title: sheet ? "Ready to print" : "Your ID photo", subtitle: sheet ? "A 4 × 6 in sheet. Print at 100% and cut along the lines." : "\(size.title). Print at 300 dpi or use it online.") {
            if let shown = sheet ? sheetImage : photo {
                Image(uiImage: shown).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 320)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            }
            HStack(spacing: 10) {
                Button("Single photo") { sheet = false }.buttonStyle(ChipStyle(selected: !sheet))
                Button("Print sheet") {
                    if let photo { sheetImage = ImageToolEngine.printSheet(photo, size: size) }
                    sheet = true
                }.buttonStyle(ChipStyle(selected: sheet)).accessibilityIdentifier("portrait-sheet")
            }
        } actions: {
            Button("Save photo") { save() }.buttonStyle(CTAButtonStyle()).disabled(photo == nil).accessibilityIdentifier("portrait-save")
        }
    }
    private func render() {
        guard let subject else { return }
        let s = size, b = backdrop, a = adjust
        work.preview {
            photo = try await OfflineWork.perform { try ImageToolEngine.portrait(subject, size: s, backdrop: b, adjust: a) }
        }
    }
    private func save() {
        guard let photo else { return }
        let s = size, asSheet = sheet
        work.run("Saving…") {
            let output = asSheet ? (sheetImage ?? ImageToolEngine.printSheet(photo, size: s)) : photo
            let mm = asSheet ? CGSize(width: 152.4, height: 101.6) : CGSize(width: s.width, height: s.height)
            _ = try await PhotoToolSaving.save([output], title: "ID photo", millimeters: mm, recognize: false, store: store)
            saved = output; go(4)
        }
    }
}

// MARK: - Smart erase

private struct EraseTool: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var work = ToolWork()
    @State private var step = 0
    @State private var forward = true
    @State private var original: UIImage?
    @State private var input: UIImage?
    @State private var strokes: [ImageToolEngine.Stroke] = []
    @State private var current: ImageToolEngine.Stroke?
    @State private var brush = 0.035
    @State private var result: UIImage?
    var body: some View {
        StepStack(step: step, forward: forward) {
            switch step {
            case 0:
                PhotoSourcePage(tool: .erase, title: "Erase anything", subtitle: "Paint over handwriting, stains or objects. We'll fill the spot from its surroundings.", work: work) { images in
                    guard let image = images.first else { return }
                    original = image; input = image; strokes = []; go(1)
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
        ToolPage(title: "Paint over what to erase", subtitle: "Cover it fully with a little margin.", scrolls: false) {
            if let input {
                GeometryReader { geo in
                    let rect = AVFit.rect(for: input.size, in: geo.size)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: input).resizable().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
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
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let p = CGPoint(x: min(1, max(0, (value.location.x - rect.minX) / rect.width)), y: min(1, max(0, (value.location.y - rect.minY) / rect.height)))
                        if current == nil { current = ImageToolEngine.Stroke(points: [p], width: brush) } else { current?.points.append(p) }
                    }.onEnded { _ in if let current { strokes.append(current) }; current = nil })
                    .accessibilityLabel("Photo. Drag to paint over what to erase.").accessibilityIdentifier("erase-canvas")
                }
                .padding(8).background(TK.grey100, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .frame(maxHeight: .infinity)
            }
            HStack(spacing: 16) {
                Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(TK.grey500)
                Slider(value: $brush, in: 0.012...0.12).tint(TK.blue).accessibilityLabel("Brush size")
                Image(systemName: "circle.fill").font(.system(size: 20)).foregroundStyle(TK.grey500)
                Button { if !strokes.isEmpty { strokes.removeLast() } } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44) }
                    .disabled(strokes.isEmpty).accessibilityLabel("Undo")
            }.foregroundStyle(TK.grey700)
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
