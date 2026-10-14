import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit

// MARK: - Design tokens
//
// Tool screens follow one rule: one page does one thing. Every page states
// what it is for in a large title, shows one main picture or control, and
// ends with one primary button at the bottom.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: opacity)
    }
}

enum TK {
    static let blue = Color(hex: 0x3182F6)
    static let blueDeep = Color(hex: 0x1B64DA)
    static let blueSoft = Color(hex: 0xE8F3FF)
    static let teal = Color(hex: 0x18B99A)
    static let tealSoft = Color(hex: 0xE3F8F3)
    static let purple = Color(hex: 0x7B61FF)
    static let purpleSoft = Color(hex: 0xF0EDFF)
    static let orange = Color(hex: 0xFF8A3D)
    static let orangeSoft = Color(hex: 0xFFF1E6)
    static let red = Color(hex: 0xF04452)
    static let redSoft = Color(hex: 0xFFEEEF)
    static let yellow = Color(hex: 0xFFC342)
    static let grey50 = Color(hex: 0xF9FAFB)
    static let grey100 = Color(hex: 0xF2F4F6)
    static let grey200 = Color(hex: 0xE5E8EB)
    static let grey300 = Color(hex: 0xD1D6DB)
    static let grey400 = Color(hex: 0xB0B8C1)
    static let grey500 = Color(hex: 0x8B95A1)
    static let grey600 = Color(hex: 0x6B7684)
    static let grey700 = Color(hex: 0x4E5968)
    static let grey800 = Color(hex: 0x333D4B)
    static let grey900 = Color(hex: 0x191F28)
    static let paper = Color.white
}

// MARK: - Buttons

struct CTAButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var tint: Color = TK.blue
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(enabled ? Color.white : TK.grey500)
            .background(enabled ? tint.opacity(configuration.isPressed ? 0.85 : 1) : TK.grey200, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
struct SecondaryCTAStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(enabled ? TK.grey700 : TK.grey400)
            .background(TK.grey100.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
struct ChipStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 16).frame(minHeight: 40)
            .foregroundStyle(selected ? TK.blue : TK.grey700)
            .background(selected ? TK.blueSoft : TK.grey100, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? TK.blue.opacity(0.35) : .clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Page scaffold

/// A tool page: large title and one-line explanation, the page's single
/// purpose in the middle and its actions pinned to the bottom.
struct ToolPage<Content: View, Actions: View>: View {
    var title: String
    var subtitle: String? = nil
    var scrolls = true
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        Group {
            if scrolls {
                ScrollView { stack }.scrollDismissesKeyboard(.interactively)
            } else { stack.frame(maxHeight: .infinity, alignment: .top) }
        }
        .background(TK.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) { actions() }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                .background(LinearGradient(colors: [TK.paper.opacity(0), TK.paper, TK.paper], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TK.paper, for: .navigationBar)
    }
    private var stack: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !title.isEmpty { ToolTitle(title: title, subtitle: subtitle) }
            content()
        }
        .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
        .frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
    }
}
struct ToolTitle: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(title)).font(.system(size: 26, weight: .bold)).foregroundStyle(TK.grey900)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("tool-page-title")
            if let subtitle {
                Text(L(subtitle)).font(.system(size: 17)).foregroundStyle(TK.grey600).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(L(text)).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey600)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A large tappable row: tinted icon, title, optional detail and a chevron.
struct ChoiceRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var tint: Color = TK.blue
    var soft: Color = TK.blueSoft
    var chevron = true
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 48, height: 48).background(soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title)).font(.system(size: 17, weight: .semibold)).foregroundStyle(TK.grey900)
                if let detail { Text(L(detail)).font(.system(size: 14)).foregroundStyle(TK.grey600).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if chevron { Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(TK.grey400) }
        }
        .padding(.vertical, 10).contentShape(Rectangle())
    }
}

/// Selectable option card used for sizes, levels and templates.
struct OptionCard<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    let selected: Bool
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L(title)).font(.system(size: 17, weight: .semibold)).foregroundStyle(selected ? TK.blueDeep : TK.grey900)
                if let detail { Text(L(detail)).font(.system(size: 14)).foregroundStyle(TK.grey600).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22)).foregroundStyle(selected ? TK.blue : TK.grey300)
        }
        .padding(18)
        .background(selected ? TK.blueSoft : TK.grey50, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(selected ? TK.blue.opacity(0.5) : TK.grey200, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
extension OptionCard where Trailing == EmptyView {
    init(title: String, detail: String? = nil, selected: Bool) {
        self.init(title: title, detail: detail, selected: selected) { EmptyView() }
    }
}

/// Labeled slider in the Toss style: title and value on one line.
struct ToolSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    /// Labels under both ends, for sliders whose middle means "off".
    var ends: (String, String)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L(title)).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey700)
                Spacer()
                Text(format(value)).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.blue).monospacedDigit()
            }
            Slider(value: $value, in: range).tint(ends == nil ? TK.blue : TK.grey300).accessibilityLabel(title)
            if let ends {
                HStack {
                    Text(ends.0); Spacer(); Text("Off"); Spacer(); Text(ends.1)
                }.font(.system(size: 12, weight: .medium)).foregroundStyle(TK.grey500)
            }
        }
    }
}

// MARK: - Hero and empty states

/// Intro block of a tool: illustration card and a short promise.
struct ToolHero: View {
    let art: ToolArt
    var body: some View {
        ToolIllustration(art: art)
            .frame(maxWidth: .infinity).frame(height: 210)
            .background(art.background, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Progress, toast and done

struct BusyOverlay: View {
    let text: String
    var progress: Double? = nil
    /// The job ended well: an animated wait plays to its check, then calls `onFinished`.
    var done = false
    var onFinished: (() -> Void)? = nil
    var cancel: (() -> Void)? = nil
    /// A long job gets its own picture; kept for the rest of the job once chosen.
    @State private var animation: WorkAnimation?
    init(text: String, progress: Double? = nil, done: Bool = false, onFinished: (() -> Void)? = nil, cancel: (() -> Void)? = nil) {
        self.text = text; self.progress = progress; self.done = done; self.onFinished = onFinished; self.cancel = cancel
        _animation = State(initialValue: WorkAnimation(phase: text))
    }
    var body: some View {
        Group {
            if let animation {
                WorkProgressView(kind: animation, phase: text, progress: progress, done: done, onFinished: onFinished, cancel: cancel)
            } else {
                card
                    .onAppear { if done { onFinished?() } }
                    .onChange(of: done) { _, value in if value { onFinished?() } }
            }
        }
        .onChange(of: text) { _, value in if animation == nil, let kind = WorkAnimation(phase: value) { animation = kind } }
    }
    private var card: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 18) {
                if let progress { ProgressView(value: progress).tint(TK.blue).frame(width: 180) }
                else { ProgressView().controlSize(.large).tint(TK.blue) }
                Text(L(text)).font(.system(size: 17, weight: .semibold)).foregroundStyle(TK.grey900).multilineTextAlignment(.center)
                    .accessibilityIdentifier("tool-busy-text")
                if let cancel {
                    Button("Cancel", action: cancel).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey600)
                        .accessibilityIdentifier("tool-cancel")
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 28)
            .frame(minWidth: 240)
            .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        }
        .transition(.opacity)
    }
}

struct ToastMessage: View {
    let text: String
    var symbol = "exclamationmark.circle.fill"
    var tint = TK.red
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(L(text)).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16).background(TK.grey100, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("tool-message")
    }
}

/// Final page of every tool: what happened, in one sentence, and what's next.
struct ToolDonePage<Extra: View>: View {
    let title: String
    let detail: String
    var primaryTitle = "Done"
    let primary: () -> Void
    var secondaryTitle: String? = nil
    var secondary: (() -> Void)? = nil
    @ViewBuilder var extra: () -> Extra
    @State private var appeared = false
    var body: some View {
        ToolPage(title: "", scrolls: true) {
            VStack(spacing: 22) {
                ZStack {
                    Circle().fill(TK.blueSoft).frame(width: 132, height: 132).scaleEffect(appeared ? 1 : 0.6)
                    Circle().fill(TK.blue).frame(width: 84, height: 84).scaleEffect(appeared ? 1 : 0.4)
                    Image(systemName: "checkmark").font(.system(size: 38, weight: .bold)).foregroundStyle(.white)
                        .scaleEffect(appeared ? 1 : 0.2)
                }.padding(.top, 24).accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text(L(title)).font(.system(size: 24, weight: .bold)).foregroundStyle(TK.grey900).multilineTextAlignment(.center)
                        .accessibilityIdentifier("tool-done-title")
                    Text(L(detail)).font(.system(size: 16)).foregroundStyle(TK.grey600).multilineTextAlignment(.center)
                }
                extra()
            }.frame(maxWidth: .infinity)
        } actions: {
            if let secondaryTitle, let secondary {
                Button(secondaryTitle, action: secondary).buttonStyle(SecondaryCTAStyle()).accessibilityIdentifier("tool-done-secondary")
            }
            Button(primaryTitle, action: primary).buttonStyle(CTAButtonStyle()).accessibilityIdentifier("tool-done-primary")
        }
        .onAppear {
            // A result exists: an open free try of a Pro tool is spent now.
            ProTrialSession.commit()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { appeared = true }
        }
    }
}
extension ToolDonePage where Extra == EmptyView {
    init(title: String, detail: String, primaryTitle: String = "Done", primary: @escaping () -> Void,
         secondaryTitle: String? = nil, secondary: (() -> Void)? = nil) {
        self.init(title: title, detail: detail, primaryTitle: primaryTitle, primary: primary,
                  secondaryTitle: secondaryTitle, secondary: secondary) { EmptyView() }
    }
}

// MARK: - Before / after comparison

/// Drag the handle to compare the original with the result.
struct BeforeAfterView: View {
    let before: UIImage
    let after: UIImage
    @State private var position: CGFloat = 0.5
    var body: some View {
        GeometryReader { geo in
            let rect = AVFit.rect(for: after.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: after).resizable().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                Image(uiImage: before).resizable().frame(width: rect.width, height: rect.height)
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, rect.width * position)) }
                    .offset(x: rect.minX, y: rect.minY)
                let x = rect.minX + rect.width * position
                Rectangle().fill(.white).frame(width: 2, height: rect.height).offset(x: x - 1, y: rect.minY)
                    .shadow(color: .black.opacity(0.25), radius: 2)
                Image(systemName: "arrowtriangle.left.and.line.vertical.and.arrowtriangle.right")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(TK.grey800)
                    .frame(width: 40, height: 40).background(.white, in: Circle()).shadow(color: .black.opacity(0.2), radius: 4)
                    .offset(x: x - 20, y: rect.midY - 20)
                HStack {
                    label("Before").opacity(position > 0.18 ? 1 : 0)
                    Spacer(minLength: 0)
                    label("After").opacity(position < 0.82 ? 1 : 0)
                }
                .padding(10).frame(width: rect.width).offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                position = min(1, max(0, (value.location.x - rect.minX) / max(1, rect.width)))
            })
            .accessibilityElement()
            .accessibilityLabel("Before and after comparison")
            .accessibilityValue("\(Int(position * 100)) percent original")
            .accessibilityAdjustableAction { direction in
                position = min(1, max(0, position + (direction == .increment ? 0.1 : -0.1)))
            }
            .accessibilityIdentifier("before-after")
        }
    }
    private func label(_ text: String) -> some View {
        Text(L(text)).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.45), in: Capsule())
    }
}
enum AVFit {
    static func rect(for image: CGSize, in box: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / image.width, box.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2, width: size.width, height: size.height)
    }
}

/// Image framed on a soft grey stage.
struct ImageStage: View {
    let image: UIImage
    var height: CGFloat = 360
    var body: some View {
        Image(uiImage: image).resizable().scaledToFit()
            .frame(maxWidth: .infinity).frame(height: height)
            .padding(12)
            .background(TK.grey100, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Camera picker

/// The system camera for single photos (portraits, objects, book spreads).
struct CameraPhotoPicker: UIViewControllerRepresentable {
    var front = false
    let completion: (UIImage?) -> Void
    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if front, UIImagePickerController.isCameraDeviceAvailable(.front) { picker.cameraDevice = .front }
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            completion((info[.originalImage] as? UIImage).map { Imaging.normalized($0) })
        }
    }
}

// MARK: - Document thumbnails and pickers

/// A rendered page preview from the saved PDF (or the scan when no PDF exists).
struct PDFPageThumb: View {
    @EnvironmentObject private var store: LibraryStore
    let document: ScanDocument
    let index: Int
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Color.white.overlay(ProgressView().controlSize(.small)) }
        }
        .task(id: "\(document.pdfFile ?? document.id.uuidString)-\(index)") {
            let root = store.root, doc = document, i = index
            image = try? await PDFThumbCache.shared.image(doc, index: i, root: root)
        }
    }
}
actor PDFThumbCache {
    static let shared = PDFThumbCache()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.countLimit = 120 }
    func image(_ doc: ScanDocument, index: Int, root: URL) throws -> UIImage {
        let key = "\(doc.pdfFile ?? doc.id.uuidString)#\(index)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        try Task.checkCancellation()
        let image: UIImage
        if let file = doc.pdfFile, let page = PDFDocument(url: root.appendingPathComponent(file))?.page(at: index) {
            image = page.thumbnail(of: CGSize(width: 420, height: 560), for: .mediaBox)
        } else if doc.pages.indices.contains(index) {
            image = try Imaging.renderThumbnail(doc.pages[index], root: root, maxDimension: 560)
        } else { throw ScannerError.message("Page unavailable.") }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Saved documents as large, simple rows. Single choice or checkboxes.
struct DocumentChoiceList: View {
    @EnvironmentObject private var store: LibraryStore
    var documents: [ScanDocument]
    var selected: [UUID] = []
    var multiple = false
    var disabled: (ScanDocument) -> Bool = { _ in false }
    let choose: (ScanDocument) -> Void
    var body: some View {
        VStack(spacing: 4) {
            ForEach(documents) { doc in
                let off = disabled(doc)
                let locked = PrivateLock.isLocked(doc, in: store.manifest)
                Button { Task { if await PrivateLock.shared.unlock(doc, in: store.manifest) { choose(doc) } } } label: {
                    HStack(spacing: 14) {
                        Group { if locked { LockedThumb() } else if let page = doc.pages.first { PageThumbnail(page: page, pdfFile: doc.pdfFile) } else { Image(systemName: "doc") } }
                            .frame(width: 52, height: 66).background(TK.grey100, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L(doc.title)).font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900).lineLimit(2)
                            Text(LS(doc.pages.count == 1 ? "1 page · \(doc.updatedAt.appFormatted(date: .abbreviated, time: .omitted))" : "\(doc.pages.count) pages · \(doc.updatedAt.appFormatted(date: .abbreviated, time: .omitted))"))
                                .font(.system(size: 13)).foregroundStyle(TK.grey500)
                        }
                        Spacer(minLength: 8)
                        if multiple {
                            let index = selected.firstIndex(of: doc.id)
                            ZStack {
                                Circle().strokeBorder(index == nil ? TK.grey300 : TK.blue, lineWidth: 2).frame(width: 26, height: 26)
                                if let index {
                                    Circle().fill(TK.blue).frame(width: 26, height: 26)
                                    Text("\(index + 1)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                        } else {
                            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(TK.grey400)
                        }
                    }
                    .padding(.vertical, 8).contentShape(Rectangle()).opacity(off ? 0.4 : 1)
                }
                .buttonStyle(.plain).disabled(off)
                .accessibilityIdentifier("tool-document-" + doc.id.uuidString)
                .accessibilityLabel(doc.title)
                .accessibilityAddTraits(multiple && selected.contains(doc.id) ? .isSelected : [])
            }
        }
    }
}

/// Page grid with numbered badges; used by extract, split, export and print.
struct PageGrid<Overlay: View>: View {
    let document: ScanDocument
    var columns = 3
    @ViewBuilder var overlay: (Int) -> Overlay
    let tap: (Int) -> Void
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 18) {
            ForEach(document.pages.indices, id: \.self) { index in
                Button { tap(index) } label: {
                    VStack(spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            PDFPageThumb(document: document, index: index)
                                .frame(maxWidth: .infinity).aspectRatio(0.75, contentMode: .fit)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(TK.grey200))
                            overlay(index)
                        }
                        Text("\(index + 1)").font(.system(size: 13, weight: .semibold)).foregroundStyle(TK.grey600)
                    }
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("page-cell-\(index + 1)")
                    .accessibilityLabel("Page \(index + 1)")
            }
        }
    }
}

/// Selected-state badge for page grids.
struct SelectionBadge: View {
    let selected: Bool
    var number: Int? = nil
    var body: some View {
        ZStack {
            Circle().fill(selected ? TK.blue : .white.opacity(0.9)).frame(width: 26, height: 26)
            Circle().strokeBorder(selected ? TK.blue : TK.grey300, lineWidth: 2).frame(width: 26, height: 26)
            if selected {
                if let number { Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                else { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
            }
        }.padding(6).accessibilityHidden(true)
    }
}

// MARK: - Source picking for photo tools

/// Where a photo tool's picture comes from. One page with large choices.
/// The document a tool was opened from, if any.
private struct ToolDocumentKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var toolDocumentID: UUID? {
        get { self[ToolDocumentKey.self] }
        set { self[ToolDocumentKey.self] = newValue }
    }
}

struct PickerStart: Identifiable {
    let id = UUID()
    let document: ScanDocument?
}

struct PhotoSourceChoices: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.toolDocumentID) private var currentID
    var multiple = false
    var frontCamera = false
    /// Shows the head-and-shoulder guide camera for ID photos.
    var portraitGuide = false
    var allowCamera = true
    /// Adds the edge-detecting document scanner (crops and straightens the page).
    var documentScan = false
    /// Mode the scan camera opens in (business cards use the card frame).
    var scanStyle: CaptureStyle = .document
    /// Mega scan: the camera keeps taking overlapping photos until Combine.
    var multiShot = false
    let picked: ([UIImage]) -> Void
    let failed: (String) -> Void
    var busy: (Bool) -> Void = { _ in }
    @State private var camera = false
    @State private var docCamera = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var pickerStart: PickerStart?
    var body: some View {
        VStack(spacing: 6) {
            if let current = currentID.flatMap({ store.document($0) }), !current.pages.isEmpty {
                Button { useCurrent(current) } label: {
                    ChoiceRow(symbol: "doc.richtext.fill", title: multiple ? "Use this document's pages" : "Use this document",
                              detail: current.pages.count == 1 ? "\(current.title) · 1 page" : "\(current.title) · \(current.pages.count) pages")
                }.buttonStyle(.plain).accessibilityIdentifier("source-current")
            }
            if documentScan && CameraPhotoPicker.available {
                Button { docCamera = true } label: { ChoiceRow(symbol: "camera.viewfinder", title: allowCamera ? "Scan a document" : "Scan with the camera", detail: "Finds the page edges and straightens it") }
                    .buttonStyle(.plain).accessibilityIdentifier("source-scan")
            }
            if multiShot && (CameraPhotoPicker.available || MegaCameraView.simulated) {
                Button { camera = true } label: { ChoiceRow(symbol: "camera.fill", title: "Take overlapping photos", detail: "Shoot piece by piece; the last edge stays on screen to line up") }
                    .buttonStyle(.plain).accessibilityIdentifier("source-camera")
            } else if allowCamera && CameraPhotoPicker.available {
                Button { camera = true } label: { ChoiceRow(symbol: "camera.fill", title: "Take a photo", detail: documentScan ? "For objects, walls and scenes" : "Use the camera now") }
                    .buttonStyle(.plain).accessibilityIdentifier("source-camera")
            }
            PhotosPicker(selection: $photos, maxSelectionCount: multiple ? 8 : 1, selectionBehavior: .ordered, matching: .images) {
                ChoiceRow(symbol: "photo.on.rectangle.angled", title: multiple ? "Choose photos" : "Choose a photo", detail: multiple ? "Pick 2–8 overlapping photos in order" : "From your photo library", tint: TK.teal, soft: TK.tealSoft)
            }.buttonStyle(.plain).accessibilityIdentifier("source-photos")
            if !multiple {
                Button { importing = true } label: { ChoiceRow(symbol: "folder.fill", title: "Choose a file", detail: "An image or the first page of a PDF", tint: TK.orange, soft: TK.orangeSoft) }
                    .buttonStyle(.plain).accessibilityIdentifier("source-file")
                if !store.active.isEmpty {
                    Button { pickerStart = PickerStart(document: nil) } label: { ChoiceRow(symbol: "doc.text.fill", title: "Use a saved scan", detail: "A page from your documents", tint: TK.purple, soft: TK.purpleSoft) }
                        .buttonStyle(.plain).accessibilityIdentifier("source-documents")
                }
            }
        }
        .fullScreenCover(isPresented: $camera) {
            if multiShot {
                MegaCameraView { images in
                    camera = false
                    if !images.isEmpty { picked(images) }
                }
            } else if portraitGuide {
                PortraitCameraView { image in
                    camera = false
                    if let image { picked([image]) }
                }
            } else {
                CameraPhotoPicker(front: frontCamera) { image in
                    camera = false
                    if let image { picked([image]) }
                }.ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $docCamera) {
            OfficeScanCamera(singlePage: true, finishTitle: "Use this scan", style: scanStyle) { result in
                docCamera = false
                switch result {
                case .success(let images): if let first = images.first { picked([first]) }
                case .failure(let error): failed(error.localizedDescription)
                }
            }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .pdf]) { result in
            switch result {
            case .success(let url): openFile(url)
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { failed(error.localizedDescription) }
            }
        }
        .sheet(item: $pickerStart) { start in
            SavedPagePicker(initial: start.document) { image in pickerStart = nil; if let image { picked([image]) } }
        }
        .onChange(of: photos) { _, items in load(items) }
    }
    private func useCurrent(_ document: ScanDocument) {
        if !multiple && document.pages.count > 1 { pickerStart = PickerStart(document: document); return }
        let pages = Array(document.pages.prefix(multiple ? 8 : 1)), root = store.root
        busy(true)
        Task {
            defer { busy(false) }
            do {
                let images = try await OfflineWork.perform { try pages.map { try Imaging.render($0, root: root) } }
                picked(images)
            } catch { failed(error.localizedDescription) }
        }
    }
    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        busy(true)
        Task {
            defer { busy(false); photos = [] }
            do {
                var images: [UIImage] = []
                var budget = 64_000_000
                for item in items {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw ScannerError.message("A photo couldn't be opened.") }
                    let limit = budget
                    let image = try await OfflineWork.perform { try ToolInput.photo(data, maxPixels: min(limit, 24_000_000)) }
                    budget -= Int(image.size.width * image.size.height)
                    images.append(image)
                }
                picked(images)
            } catch { failed(error.localizedDescription) }
        }
    }
    private func openFile(_ url: URL) {
        busy(true)
        Task {
            defer { busy(false) }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("tool-input-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: copy) }
            do {
                let opened = try await OfflineWork.perform { try WordFileInput.open(url, pdfCopy: copy) }
                picked([ToolInput.limited(opened.image, maxPixels: 24_000_000)])
            } catch { failed(error.localizedDescription) }
        }
    }
}

enum ToolInput {
    /// Opens a photo with EXIF orientation applied, scaled down only when it
    /// exceeds the editing budget of the photo tools.
    static func photo(_ data: Data, maxPixels: Int) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { throw ScannerError.message("This photo couldn't be opened.") }
        let scale = min(1, (Double(maxPixels) / Double(w * h)).squareRoot())
        let side = Int(Double(max(w, h)) * scale)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(1, side), kCGImageSourceShouldCacheImmediately: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ScannerError.message("This photo couldn't be opened.") }
        return UIImage(cgImage: cg)
    }
    static func limited(_ image: UIImage, maxPixels: Int) -> UIImage {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        guard pixels > CGFloat(maxPixels) else { return Imaging.normalized(image) }
        return Imaging.limited(Imaging.normalized(image), maxPixels: maxPixels)
    }
}

/// Pick one page of a saved document as a picture.
struct SavedPagePicker: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let picked: (UIImage?) -> Void
    @State private var document: ScanDocument?
    @State private var busy = false
    init(initial: ScanDocument? = nil, picked: @escaping (UIImage?) -> Void) {
        self.picked = picked
        _document = State(initialValue: initial)
    }
    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    ToolPage(title: "Which page?", subtitle: document.title) {
                        PageGrid(document: document) { _ in EmptyView() } tap: { index in load(document, index) }
                    } actions: { EmptyView() }
                } else {
                    ToolPage(title: "Choose a scan", subtitle: "Pick the document with your page.") {
                        DocumentChoiceList(documents: store.active) { doc in
                            if doc.pages.count == 1 { load(doc, 0) } else { document = doc }
                        }
                    } actions: { EmptyView() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if document != nil { Button { document = nil } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back") }
                    else { Button("Close") { picked(nil) } }
                }
            }
            .overlay { if busy { BusyOverlay(text: "Opening page…") } }
        }
    }
    private func load(_ doc: ScanDocument, _ index: Int) {
        let page = doc.pages[index], root = store.root
        busy = true
        Task {
            defer { busy = false }
            let image = try? await OfflineWork.perform { try Imaging.render(page, root: root) }
            picked(image)
        }
    }
}

// MARK: - Animated waits

/// Eased value between keyframes; `t` and the stops are fractions of one loop.
func loopValue(_ t: Double, _ stops: [(Double, Double)]) -> Double {
    guard let first = stops.first, let last = stops.last else { return 0 }
    if t <= first.0 { return first.1 }
    for (a, b) in zip(stops, stops.dropFirst()) where t <= b.0 {
        let span = b.0 - a.0
        guard span > 0 else { return b.1 }
        let x = (t - a.0) / span
        return a.1 + (b.1 - a.1) * x * x * (3 - 2 * x)
    }
    return last.1
}

/// The loop position `seconds` later in an 8-second loop, wrapped into 0…1.
func loopLater(_ t: Double, _ seconds: Double) -> Double { let x = t - seconds / 8; return x < 0 ? x + 1 : x }

/// A full-screen wait that shows the work being done: a title, the real progress
/// line, a picture that loops every 8 seconds with four step labels under it, and
/// Cancel. With Reduce Motion the picture rests on its finished state.
struct AnimatedWorkPage<Stage: View>: View {
    let title: String
    let steps: [String]
    let tint: Color
    /// The real progress line ("Reading page 1 of 2…").
    let phase: String
    var progress: Double? = nil
    /// The job ended well: the picture plays on to its check, then `onFinished` runs.
    var done = false
    var onFinished: (() -> Void)? = nil
    var cancel: (() -> Void)? = nil
    @ViewBuilder let stage: (Double) -> Stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    /// The job has reached its last stage (making or saving the file).
    @State private var finished = false
    /// The job began at its last stage (the pages were read earlier): start the picture there too.
    @State private var startsAtFile = false
    /// When the job ended, and where the picture was then.
    @State private var doneAt: Date?
    @State private var doneFrom = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L(title)).font(.system(size: 26, weight: .bold)).foregroundStyle(TK.grey900)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 24)
                .accessibilityAddTraits(.isHeader)
            Text(L(phase)).font(.system(size: 15)).foregroundStyle(TK.grey600).padding(.top, 8)
                .accessibilityIdentifier("tool-busy-text")
                .onAppear { if workPhaseIsFinal(phase) { finished = true; startsAtFile = true } }
                .onChange(of: phase) { _, value in if workPhaseIsFinal(value) { finished = true } }
            if let progress {
                ProgressView(value: progress).tint(tint).padding(.top, 10)
            }
            Spacer(minLength: 12)
            TimelineView(.animation(paused: reduceMotion)) { context in
                let elapsed = context.date.timeIntervalSince(start)
                let t = doneAt.map { Self.finishing(from: doneFrom, since: context.date.timeIntervalSince($0), reduceMotion: reduceMotion) }
                    ?? Self.picture(elapsed, fromFile: startsAtFile, reduceMotion: reduceMotion)
                let once = doneAt != nil ? 0.9 : Self.labels(elapsed, fromFile: startsAtFile, finished: finished)
                VStack(spacing: 14) {
                    stage(t).frame(width: 320, height: 260, alignment: .topLeading)
                    ZStack {
                        ForEach(steps.indices, id: \.self) { i in
                            Text(L(steps[i])).font(.system(size: 18, weight: .bold)).foregroundStyle(TK.grey900)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .opacity(Self.labelOpacity(i, once))
                        }
                    }.frame(height: 26)
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { i in
                            Capsule().fill(i <= Self.step(once) ? tint : TK.grey200).frame(width: 28, height: 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 12)
            if let cancel {
                Button("Cancel", action: cancel).buttonStyle(SecondaryCTAStyle()).accessibilityIdentifier("tool-cancel")
                    .opacity(doneAt == nil ? 1 : 0).disabled(doneAt != nil)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TK.paper.ignoresSafeArea())
        .transition(.opacity)
        .onAppear { if done { finish() } }
        .onChange(of: done) { _, value in if value { finish() } }
    }

    /// The job is done: carry the picture on from where it is to the check, then close.
    private func finish() {
        guard doneAt == nil else { return }
        let from = Self.picture(Date().timeIntervalSince(start), fromFile: startsAtFile, reduceMotion: reduceMotion)
        doneFrom = from; doneAt = Date(); finished = true
        let wait = (reduceMotion ? 0 : Self.finishDuration(from)) + 0.5
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            onFinished?()
        }
    }
    /// Seconds to play from `from` to the check: the rest of the picture at its own pace,
    /// sped up when much is left so the user is not kept waiting.
    static func finishDuration(_ from: Double) -> Double { min(max((0.95 - from) * 8, 0.8), 1.6) }
    static func finishing(from: Double, since: Double, reduceMotion: Bool) -> Double {
        if reduceMotion { return 0.95 }
        let p = min(1, since / finishDuration(from))
        return from + (0.95 - from) * p
    }

    /// Where the picture is: it plays once to the end of its third part (the work
    /// itself), then repeats only that part until the job is done. Its last part
    /// (the finished file and the check) is never shown, so it never looks done early.
    static func picture(_ elapsed: Double, fromFile: Bool, reduceMotion: Bool) -> Double {
        if reduceMotion { return 0.8 }
        let raw = (fromFile ? 0.5 : 0) + elapsed / 8
        return raw <= 0.8 ? raw : 0.58 + (raw - 0.8).truncatingRemainder(dividingBy: 0.22)
    }
    /// Where the step labels are: they move forward once with the picture, rest on the
    /// third step while the work goes on, and show the last step only when the job
    /// has reached it. They never start over.
    static func labels(_ elapsed: Double, fromFile: Bool, finished: Bool) -> Double {
        finished ? 0.9 : min((fromFile ? 0.5 : 0) + elapsed / 8, 0.6)
    }
    static func step(_ t: Double) -> Int { t < 0.25 ? 0 : t < 0.5 ? 1 : t < 0.82 ? 2 : 3 }
    static func labelOpacity(_ i: Int, _ t: Double) -> Double {
        switch i {
        case 0: loopValue(t, [(0, 1), (0.22, 1), (0.25, 0), (1, 0)])
        case 1: loopValue(t, [(0, 0), (0.23, 0), (0.26, 1), (0.47, 1), (0.5, 0), (1, 0)])
        case 2: loopValue(t, [(0, 0), (0.48, 0), (0.51, 1), (0.8, 1), (0.83, 0), (1, 0)])
        default: loopValue(t, [(0, 0), (0.81, 0), (0.84, 1), (0.97, 1), (1, 0)])
        }
    }
}

/// The check (or other mark) that pops when the work finishes.
struct WorkDoneBadge: View {
    let t: Double
    var fill: Color
    var symbol = "checkmark"
    var body: some View {
        Circle().fill(fill).frame(width: 40, height: 40)
            .overlay(Image(systemName: symbol).font(.system(size: 19, weight: .heavy)).foregroundStyle(.white))
            .padding(4).background(Circle().fill(.white))
            .scaleEffect(loopValue(t, [(0, 0), (0.83, 0), (0.87, 1.15), (0.89, 1), (0.95, 1), (1, 0)]))
    }
}

/// Shows a job's wait while `text` (its progress line) is set. When the job ends
/// well (not `failed`, not canceled) the wait stays up a moment longer so its
/// picture can play on to the check; a failed or canceled job closes it at once.
/// `content` gets the line, whether the job is done, a call to make when the user
/// cancels, and a call to make when the finish has played.
struct FinishingOverlay<Content: View>: View {
    let text: String?
    var failed = false
    @ViewBuilder let content: (String, Bool, @escaping () -> Void, @escaping () -> Void) -> Content
    @State private var last = ""
    @State private var finishing = false
    @State private var cancelled = false
    var body: some View {
        ZStack {
            if text != nil || finishing {
                let done = finishing && text == nil
                // While the finish plays, the screen underneath already works: a tap goes
                // straight through, so nobody waits on the check.
                content(text ?? last, done, { cancelled = true }, { finishing = false })
                    .allowsHitTesting(!done)
                    .accessibilityHidden(done)
            }
        }
        .onAppear { if let text { last = text } }
        .onChange(of: text) { old, new in
            if let new {
                last = new
                if old == nil { cancelled = false; finishing = false }
            } else if old != nil {
                finishing = !failed && !cancelled
            }
        }
    }
}

/// A progress line for a job's last stage: the file is being made or saved.
func workPhaseIsFinal(_ phase: String) -> Bool {
    ["Creating", "Making the", "Rebuilding", "Preparing translated"].contains { phase.hasPrefix($0) }
        || ["Saving PDF…", "Saving…"].contains(phase)
}

/// Long jobs that get their own picture while the user waits.
enum WorkAnimation: Equatable {
    case save, images, compress, redact, translate, restore, merge

    /// The picture for a job's first progress line, or nil for short jobs.
    init?(phase: String) {
        if phase.hasPrefix("Looking for personal info") { self = .redact; return }
        switch phase {
        case "Saving your scan…", "Preparing PDF…", "Saving PDF…": self = .save
        case "Making images…", "Preparing image export…": self = .images
        case "Compressing…": self = .compress
        case "Reading the source language…", "Translating text areas…", "Rebuilding your page…": self = .translate
        case "Restoring at full size…", "Erasing…", "Cleaning the full page…": self = .restore
        case "Merging…", "Joining pages…": self = .merge
        default: return nil
        }
    }
    var title: String {
        switch self {
        case .save: "Saving your scan as a PDF"
        case .images: "Saving the pages as pictures"
        case .compress: "Making the PDF smaller"
        case .redact: "Finding and hiding personal info"
        case .translate: "Translating the text in your photo"
        case .restore: "Cleaning up your photo"
        case .merge: "Combining into one PDF"
        }
    }
    var steps: [String] {
        switch self {
        case .save: ["Gathering the pages…", "Reading the text so it can be searched…", "Binding it into one file…", "Saving the PDF…"]
        case .images: ["Laying out the pages…", "Turning pages into pictures…", "Setting the picture quality…", "Saving the pictures…"]
        case .compress: ["Looking over the pages…", "Adjusting the picture quality…", "Making the file smaller…", "Saving the new PDF…"]
        case .redact: ["Reading the text…", "Finding numbers and contact details…", "Hiding what was found…", "Making the hidden copy…"]
        case .translate: ["Finding the text…", "Reading the text…", "Translating…", "Putting it back on the photo…"]
        case .restore: ["Looking over the photo…", "Finding spots and creases…", "Erasing spots…", "Saving the clean photo…"]
        case .merge: ["Opening the files…", "Putting them in your order…", "Joining them into one…", "Saving the PDF…"]
        }
    }
    var tint: Color {
        switch self {
        case .save, .translate: TK.blue
        case .images: Color(hex: 0x7C3AED)
        case .compress: TK.teal
        case .redact: TK.red
        case .restore: TK.orange
        case .merge: TK.blueDeep
        }
    }
}

/// The animated wait for a long job (see `WorkAnimation`).
struct WorkProgressView: View {
    let kind: WorkAnimation
    let phase: String
    var progress: Double? = nil
    var done = false
    var onFinished: (() -> Void)? = nil
    var cancel: (() -> Void)? = nil

    var body: some View {
        AnimatedWorkPage(title: kind.title, steps: kind.steps, tint: kind.tint, phase: phase, progress: progress,
                         done: done, onFinished: onFinished, cancel: cancel) { t in
            stage(t)
        }
    }

    private func kf(_ t: Double, _ stops: [(Double, Double)]) -> Double { loopValue(t, stops) }
    private var tint: Color { kind.tint }

    /// The picture at loop position `t` (0…1). Internal so tests can render single frames.
    @ViewBuilder func stage(_ t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            switch kind {
            case .save: saveStage(t)
            case .images: imagesStage(t)
            case .compress: compressStage(t)
            case .redact: redactStage(t)
            case .translate: translateStage(t)
            case .restore: restoreStage(t)
            case .merge: mergeStage(t)
            }
        }
        .frame(width: 320, height: 260, alignment: .topLeading)
    }

    // MARK: Pieces

    private func sheet(_ width: CGFloat, _ height: CGFloat, radius: CGFloat = 6) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.white)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(TK.grey300))
            .frame(width: width, height: height)
    }
    private func bar(_ width: CGFloat, _ height: CGFloat = 4, _ color: Color = TK.grey300) -> some View {
        Capsule().fill(color).frame(width: max(0, width), height: height)
    }
    private func pdfTag() -> some View {
        Text(verbatim: "PDF").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3).background(TK.red, in: RoundedRectangle(cornerRadius: 6))
    }
    private func fade(_ t: Double, from: Double = 0, in duration: Double = 0.06) -> Double {
        kf(t, [(0, 0), (from, 0), (from + duration, 1), (0.95, 1), (1, 0)])
    }

    // MARK: 1 · Saving a scan: pages fly in and stack, the text is read, the stack is bound into a PDF.

    @ViewBuilder private func saveStage(_ t: Double) -> some View {
        sheet(120, 160)
            .rotationEffect(.degrees(kf(t, [(0, -14), (0.2, -4), (0.48, -4), (0.58, 0), (1, 0)])))
            .offset(x: 100 + kf(t, [(0, -110), (0.2, -12), (0.48, -12), (0.58, -4), (1, -4)]),
                    y: 50 + kf(t, [(0, 30), (0.2, -12), (0.48, -12), (0.58, -4), (1, -4)]))
            .opacity(fade(t, from: 0, in: 0.08) * kf(t, [(0, 1), (0.5, 1), (0.58, 0), (1, 0)]))
        sheet(120, 160)
            .rotationEffect(.degrees(kf(t, [(0, 14), (0.03, 14), (0.22, 3), (0.48, 3), (0.58, 0), (1, 0)])))
            .offset(x: 100 + kf(t, [(0, 110), (0.03, 110), (0.22, -6), (0.48, -6), (0.58, -2), (1, -2)]),
                    y: 50 + kf(t, [(0, 30), (0.03, 30), (0.22, -6), (0.48, -6), (0.58, -2), (1, -2)]))
            .opacity(fade(t, from: 0.03, in: 0.08) * kf(t, [(0, 1), (0.5, 1), (0.58, 0), (1, 0)]))
        // The front page turns into a PDF file: its corner folds over while the text is read,
        // then a red PDF label slides across it and a light sweeps over the label while saving.
        let fold = 30 * kf(t, [(0, 0), (0.3, 0), (0.5, 1), (0.95, 1), (1, 0)])
        let label = kf(t, [(0, 0), (0.48, 0), (0.55, 1.06), (0.58, 1), (0.95, 1), (1, 0)])
        ZStack(alignment: .topLeading) {
            sheet(120, 160)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array([0.6, 1, 0.92, 0.96, 0.7, 1, 0.84, 0.5].enumerated()), id: \.offset) { i, w in
                    let read = kf(loopLater(t, Double(i) * 0.1), [(0, 0), (0.28, 0), (0.36, 1), (0.95, 1), (1, 0)])
                    bar(min(88 * w, 84 - fold * 0.6), i == 0 ? 7 : 4, TK.grey300).overlay(Capsule().fill(tint).opacity(read * (1 - label * 0.55)))
                }
            }
            .padding(.leading, 18).padding(.top, 16)
            Rectangle().fill(tint).frame(width: 120, height: 3)
                .offset(y: kf(t, [(0, 0), (0.25, 0), (0.46, 156), (1, 156)]))
                .opacity(kf(t, [(0, 0), (0.25, 0), (0.27, 1), (0.46, 1), (0.48, 0), (1, 0)]))
            // Folded corner: the page behind is cut away and the flap lies on top.
            Path { p in p.move(to: CGPoint(x: 120 - fold, y: 0)); p.addLine(to: CGPoint(x: 121, y: -1)); p.addLine(to: CGPoint(x: 121, y: fold)); p.closeSubpath() }
                .fill(TK.paper).opacity(fold > 1 ? 1 : 0)
            Path { p in p.move(to: CGPoint(x: 120 - fold, y: 0)); p.addLine(to: CGPoint(x: 120 - fold, y: fold - 4)); p.addQuadCurve(to: CGPoint(x: 120 - fold + 4, y: fold), control: CGPoint(x: 120 - fold, y: fold)); p.addLine(to: CGPoint(x: 120, y: fold)); p.closeSubpath() }
                .fill(Color(hex: 0xFFD6D2))
                .overlay(Path { p in p.move(to: CGPoint(x: 120 - fold, y: 0)); p.addLine(to: CGPoint(x: 120, y: fold)) }.stroke(TK.grey300, lineWidth: 1))
                .opacity(fold > 1 ? 1 : 0)
        }
        .frame(width: 120, height: 160, alignment: .topLeading)
        .offset(x: 100, y: 50 + kf(t, [(0, 70), (0.06, 70), (0.24, 0), (1, 0)]))
        .opacity(fade(t, from: 0.06, in: 0.08))
        // The red PDF label, a little wider than the page on both sides.
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0xE5484D))
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.45), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 36).rotationEffect(.degrees(18))
                .offset(x: kf(t, [(0, -110), (0.6, -110), (0.76, 110), (1, 110)]))
            Text(verbatim: "PDF").font(.system(size: 27, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                .scaleEffect(kf(t, [(0, 0.4), (0.5, 0.4), (0.56, 1.1), (0.59, 1), (1, 1)]))
                .opacity(kf(t, [(0, 0), (0.5, 0), (0.54, 1), (0.95, 1), (1, 0)]))
        }
        .frame(width: 136, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .scaleEffect(x: label, y: 1, anchor: .leading)
        .offset(x: 92, y: 136)
        .opacity(label > 0.01 ? 1 : 0)
        WorkDoneBadge(t: t, fill: tint).offset(x: 200, y: 182)
    }

    // MARK: 2 · Pictures: each page flashes and comes out of the PDF as a photo, then sharpens.

    @ViewBuilder private func imagesStage(_ t: Double) -> some View {
        let sharp = kf(t, [(0, 0), (0.52, 0), (0.66, 1), (1, 1)])
        ZStack(alignment: .topLeading) {
            sheet(120, 160)
            VStack(alignment: .leading, spacing: 8) {
                bar(72, 7, TK.grey500); bar(92); bar(84)
                RoundedRectangle(cornerRadius: 3).fill(TK.grey100).frame(width: 92, height: 40)
                bar(88); bar(60)
            }.padding(14)
            pdfTag().offset(x: 72, y: 130)
            Color.white.opacity(kf(t, [(0, 0), (0.26, 0), (0.27, 0.85), (0.3, 0), (0.36, 0), (0.37, 0.85), (0.4, 0), (0.46, 0), (0.47, 0.85), (0.5, 0), (1, 0)]))
        }
        .frame(width: 120, height: 160, alignment: .topLeading)
        .offset(x: 50 + kf(t, [(0, 0), (0.8, 0), (0.9, -20), (1, -20)]), y: 50 + kf(t, [(0, 16), (0.06, 0), (1, 0)]))
        .opacity(kf(t, [(0, 0), (0.06, 1), (0.8, 1), (0.9, 0), (1, 0)]))
        ForEach(0..<3, id: \.self) { i in
            let s = 0.26 + 0.1 * Double(i)
            let to: [(Double, Double, Double)] = [(126, -44, 7), (138, 16, -3), (118, 74, 5)]
            let end: [(Double, Double, Double)] = [(70, -44, -6), (82, 16, 0), (94, 76, 6)]
            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 5) {
                    bar(54, 5, TK.grey600); bar(70, 3, TK.grey400); bar(60, 3, TK.grey400); bar(64, 3, TK.grey400)
                }
                .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(hex: 0xF0EDFF), in: RoundedRectangle(cornerRadius: 4))
                .blur(radius: 1.5 * (1 - sharp))
                Image(systemName: "photo").font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            }
            .padding(6).frame(width: 96, height: 120)
            .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(TK.grey300))
            .scaleEffect(kf(t, [(0, 0.9), (s, 0.9), (s + 0.1, 1), (1, 1)]))
            .rotationEffect(.degrees(kf(t, [(0, 0), (s, 0), (s + 0.1, to[i].2), (0.8, to[i].2), (0.88, end[i].2), (1, end[i].2)])))
            .offset(x: 60 + kf(t, [(0, 0), (s, 0), (s + 0.1, to[i].0), (0.8, to[i].0), (0.88, end[i].0), (1, end[i].0)]),
                    y: 70 + kf(t, [(0, 0), (s, 0), (s + 0.1, to[i].1), (0.8, to[i].1), (0.88, end[i].1), (1, end[i].1)]))
            .opacity(fade(t, from: s, in: 0.02))
        }
        WorkDoneBadge(t: t, fill: tint).offset(x: 236, y: 0)
    }

    // MARK: 3 · Smaller: a press comes down on the file and the size bar shrinks.

    @ViewBuilder private func compressStage(_ t: Double) -> some View {
        let press = kf(t, [(0, 0), (0.26, 0), (0.4, 0.35), (0.56, 0.65), (0.72, 1), (0.95, 1), (1, 0)])
        let dark = Color(hex: 0x0E8A72)
        Capsule().fill(dark).frame(width: 172, height: 8).offset(x: 74, y: 6 + 50 * press)
        ZStack(alignment: .topLeading) {
            sheet(120, 150, radius: 8)
            VStack(alignment: .leading, spacing: 7) {
                bar(72, 7, TK.grey500)
                RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xE3F8F3)).frame(width: 96, height: 48)
                    .overlay(Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(dark))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint, lineWidth: 2)
                        .opacity(kf(t, [(0, 0), (0.24, 0), (0.28, 1), (0.48, 1), (0.52, 0), (1, 0)])))
                bar(96); bar(80)
            }.padding(12)
            pdfTag().offset(x: 72, y: 120)
        }
        .frame(width: 120, height: 150, alignment: .topLeading)
        .scaleEffect(1 - 0.32 * press, anchor: .bottom)
        .offset(x: 100, y: 26)
        .opacity(fade(t, in: 0.05))
        ZStack(alignment: .leading) {
            Capsule().fill(TK.grey100).frame(width: 220, height: 8)
            Capsule().fill(tint).frame(width: 220 * (1 - 0.74 * press), height: 8)
        }
        .offset(x: 50, y: 206)
        WorkDoneBadge(t: t, fill: dark).offset(x: 236, y: 20)
    }

    // MARK: 4 · Personal info: the page is read, numbers are found, black bars cover them.

    @ViewBuilder private func redactStage(_ t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            sheet(260, 170, radius: 10)
            VStack(alignment: .leading, spacing: 14) {
                bar(100, 8, TK.grey500)
                ForEach(Array([(0.52, false, 0.0), (0.64, true, 0.0), (0.72, true, 0.25), (0.58, true, 0.5)].enumerated()), id: \.offset) { _, row in
                    let found = kf(loopLater(t, row.2), [(0, 0), (0.26, 0), (0.32, 1), (0.52, 1), (0.58, 0), (1, 0)])
                    let cover = kf(loopLater(t, row.2), [(0, 0), (0.5, 0), (0.6, 1), (0.95, 1), (1, 0)])
                    HStack(spacing: 12) {
                        bar(36, 5, TK.grey400)
                        bar(170 * row.0, 6, TK.grey700)
                            .overlay {
                                if row.1 {
                                    RoundedRectangle(cornerRadius: 4).strokeBorder(tint, lineWidth: 2)
                                        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                                        .padding(-6).opacity(found)
                                }
                            }
                            .overlay(alignment: .leading) {
                                if row.1 {
                                    RoundedRectangle(cornerRadius: 2).fill(TK.grey900)
                                        .frame(width: (170 * row.0 + 6) * cover, height: 14).offset(x: -3)
                                }
                            }
                    }
                    .frame(height: 12)
                }
            }
            .padding(18)
            Rectangle().fill(TK.blue).frame(width: 260, height: 3)
                .offset(y: kf(t, [(0, 0), (0.03, 0), (0.23, 166), (1, 166)]))
                .opacity(kf(t, [(0, 0), (0.03, 0), (0.05, 1), (0.23, 1), (0.25, 0), (1, 0)]))
        }
        .frame(width: 260, height: 170, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .offset(x: 30, y: 46 + kf(t, [(0, 14), (0.05, 0), (1, 0)]))
        .opacity(fade(t, in: 0.05))
        WorkDoneBadge(t: t, fill: TK.grey900, symbol: "checkmark.shield.fill").offset(x: 256, y: 22)
    }

    // MARK: 5 · Photo translation: the sign's text is found, read and replaced with the translation.

    @ViewBuilder private func translateStage(_ t: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Color(hex: 0xDCE3EA)
            Rectangle().fill(Color(hex: 0xC5CED8)).frame(width: 260, height: 52).offset(y: 128)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array([(10.0, 0.78, 0.58, 0.0), (6.0, 1.0, 0.86, 0.2), (6.0, 0.64, 0.74, 0.4)].enumerated()), id: \.offset) { _, line in
                    let box = kf(loopLater(t, line.3), [(0, 0), (0.26, 0), (0.32, 1), (0.58, 1), (0.64, 0), (1, 0)])
                    let old = kf(t, [(0, 1), (0.52, 1), (0.6, 0), (0.96, 0), (1, 1)])
                    let new = kf(loopLater(t, line.3), [(0, 0), (0.56, 0), (0.68, 1), (0.95, 1), (1, 0)])
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(tint, lineWidth: 2)
                            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            .frame(width: 140 * line.1 + 12, height: line.0 + 10).offset(x: -6).opacity(box)
                        bar(140 * line.1, line.0, TK.grey800).opacity(old)
                        bar(140 * line.2 * new, line.0, TK.blueDeep).opacity(new > 0 ? 1 : 0)
                    }
                    .frame(height: line.0)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
            .frame(width: 172, height: 112, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .rotationEffect(.degrees(-3))
            .offset(x: 44, y: 30)
            Rectangle().fill(TK.blue).frame(width: 3, height: 180)
                .offset(x: kf(t, [(0, 0), (0.03, 0), (0.23, 260), (1, 260)]))
                .opacity(kf(t, [(0, 0), (0.03, 0), (0.05, 1), (0.23, 1), (0.25, 0), (1, 0)]))
        }
        .frame(width: 260, height: 180, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .offset(x: 30, y: 40)
        Image(systemName: "translate").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6).background(TK.blueDeep, in: Capsule())
            .scaleEffect(kf(t, [(0, 0), (0.5, 0), (0.54, 1.15), (0.56, 1), (0.95, 1), (1, 0)]))
            .offset(x: 40, y: 18)
        WorkDoneBadge(t: t, fill: tint).offset(x: 254, y: 16)
    }

    // MARK: 6 · Clean-up: spots are circled, then a line sweeps across leaving a clean photo.

    @ViewBuilder private func restoreStage(_ t: Double) -> some View {
        let wipe = kf(t, [(0, 0), (0.52, 0), (0.8, 1), (0.96, 1), (1, 0)])
        let rings = kf(t, [(0, 0), (0.26, 0), (0.32, 1), (0.52, 1), (0.56, 0), (1, 0)])
        let spots: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(30, 30, 30, 26), (124, 98, 22, 20), (180, 70, 16, 14)]
        ZStack(alignment: .topLeading) {
            Color(hex: 0xCFE3FF)
            Circle().fill(TK.yellow).frame(width: 40, height: 40).offset(x: 150, y: 22)
            Ellipse().fill(Color(hex: 0x7BC79A)).frame(width: 200, height: 140).offset(x: -40, y: 92)
            Ellipse().fill(Color(hex: 0x5DAE80)).frame(width: 220, height: 150).offset(x: 90, y: 108)
            ZStack(alignment: .topLeading) {
                Color(red: 0.545, green: 0.431, blue: 0.275).opacity(0.32)
                ForEach(spots.indices, id: \.self) { i in
                    Ellipse().fill(Color(red: 0.43, green: 0.31, blue: 0.16).opacity(0.55))
                        .frame(width: spots[i].2, height: spots[i].3).offset(x: spots[i].0, y: spots[i].1)
                }
                Rectangle().fill(.white.opacity(0.75)).frame(width: 240, height: 2).rotationEffect(.degrees(-8)).offset(y: 76)
            }
            .mask(alignment: .trailing) { Rectangle().frame(width: 228 * (1 - wipe)) }
            ForEach(spots.indices, id: \.self) { i in
                Ellipse().strokeBorder(TK.orange, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    .frame(width: spots[i].2 + 12, height: spots[i].3 + 12)
                    .offset(x: spots[i].0 - 6, y: spots[i].1 - 6).opacity(rings)
            }
            Rectangle().fill(.white).frame(width: 3, height: 160).offset(x: 228 * wipe)
                .opacity(kf(t, [(0, 0), (0.51, 0), (0.53, 1), (0.8, 1), (0.82, 0), (1, 0)]))
        }
        .frame(width: 228, height: 160, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TK.grey300))
        .scaleEffect(kf(t, [(0, 1), (0.04, 1), (0.12, 1.04), (0.18, 1.04), (0.24, 1), (1, 1)]))
        .offset(x: 40, y: 44)
        let sparks: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [(34, 30, 24), (238, 196, 18)]
        ForEach(sparks.indices, id: \.self) { i in
            Image(systemName: "sparkle").font(.system(size: sparks[i].size, weight: .bold)).foregroundStyle(TK.yellow)
                .scaleEffect(kf(t, [(0, 0), (0.8, 0), (0.86, 1), (0.94, 1), (1, 0)]))
                .offset(x: sparks[i].x, y: sparks[i].y)
        }
        WorkDoneBadge(t: t, fill: Color(hex: 0xE8701F)).offset(x: 252, y: 18)
    }

    // MARK: 7 · Combining: the files take their order and slide into one stack.

    @ViewBuilder private func mergeStage(_ t: Double) -> some View {
        let files: [(left: Double, color: Color, x: [(Double, Double)], y: [(Double, Double)], from: Double)] = [
            (20, TK.blue, [(0, 0), (0.5, 0), (0.66, 90), (1, 90)], [(0, 16), (0.06, 0), (0.5, 0), (0.66, -10), (1, -10)], 0),
            (118, TK.teal, [(0, 0), (0.28, 0), (0.36, 49), (0.44, 98), (0.5, 98), (0.66, 0), (1, 0)],
             [(0, 16), (0.02, 16), (0.08, 0), (0.28, 0), (0.36, -26), (0.44, 0), (0.5, 0), (0.66, -5), (1, -5)], 0.02),
            (216, TK.orange, [(0, 0), (0.28, 0), (0.36, -49), (0.44, -98), (0.5, -98), (0.66, -90), (1, -90)],
             [(0, 16), (0.04, 16), (0.1, 0), (0.28, 0), (0.36, 22), (0.44, 0), (1, 0)], 0.04),
        ]
        ForEach(files.indices, id: \.self) { i in
            let file = files[i]
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(file.color).frame(height: 6)
                VStack(alignment: .leading, spacing: 6) { bar(46, 6, TK.grey500); bar(70, 3); bar(62, 3); bar(66, 3) }.padding(9)
                Spacer(minLength: 0)
            }
            .frame(width: 88, height: 116)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(TK.grey300))
            .offset(x: file.left + kf(t, file.x), y: 70 + kf(t, file.y))
            .opacity(fade(t, from: file.from, in: 0.06))
        }
        WorkDoneBadge(t: t, fill: tint).offset(x: 196, y: 36)
    }
}
