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
            Text(title).font(.system(size: 26, weight: .bold)).foregroundStyle(TK.grey900)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("tool-page-title")
            if let subtitle {
                Text(subtitle).font(.system(size: 17)).foregroundStyle(TK.grey600).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey600)
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
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(TK.grey900)
                if let detail { Text(detail).font(.system(size: 14)).foregroundStyle(TK.grey600).fixedSize(horizontal: false, vertical: true) }
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
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(selected ? TK.blueDeep : TK.grey900)
                if let detail { Text(detail).font(.system(size: 14)).foregroundStyle(TK.grey600).fixedSize(horizontal: false, vertical: true) }
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
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey700)
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
    var cancel: (() -> Void)? = nil
    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 18) {
                if let progress { ProgressView(value: progress).tint(TK.blue).frame(width: 180) }
                else { ProgressView().controlSize(.large).tint(TK.blue) }
                Text(text).font(.system(size: 17, weight: .semibold)).foregroundStyle(TK.grey900).multilineTextAlignment(.center)
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
            Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800).fixedSize(horizontal: false, vertical: true)
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
                    Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(TK.grey900).multilineTextAlignment(.center)
                        .accessibilityIdentifier("tool-done-title")
                    Text(detail).font(.system(size: 16)).foregroundStyle(TK.grey600).multilineTextAlignment(.center)
                }
                extra()
            }.frame(maxWidth: .infinity)
        } actions: {
            if let secondaryTitle, let secondary {
                Button(secondaryTitle, action: secondary).buttonStyle(SecondaryCTAStyle()).accessibilityIdentifier("tool-done-secondary")
            }
            Button(primaryTitle, action: primary).buttonStyle(CTAButtonStyle()).accessibilityIdentifier("tool-done-primary")
        }
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { appeared = true } }
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
        Text(text).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
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
            image = try Imaging.previewThumbnail(Imaging.render(doc.pages[index], root: root), maxDimension: 560)
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
                Button { choose(doc) } label: {
                    HStack(spacing: 14) {
                        Group { if let page = doc.pages.first { PageThumbnail(page: page, pdfFile: doc.pdfFile) } else { Image(systemName: "doc") } }
                            .frame(width: 52, height: 66).background(TK.grey100, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(doc.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900).lineLimit(2)
                            Text("\(doc.pages.count) \(doc.pages.count == 1 ? "page" : "pages") · \(doc.updatedAt.formatted(date: .abbreviated, time: .omitted))")
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
    var allowCamera = true
    let picked: ([UIImage]) -> Void
    let failed: (String) -> Void
    var busy: (Bool) -> Void = { _ in }
    @State private var camera = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var pickerStart: PickerStart?
    var body: some View {
        VStack(spacing: 6) {
            if let current = currentID.flatMap({ store.document($0) }), !current.pages.isEmpty {
                Button { useCurrent(current) } label: {
                    ChoiceRow(symbol: "doc.richtext.fill", title: multiple ? "Use this document's pages" : "Use this document",
                              detail: "\(current.title) · \(current.pages.count) \(current.pages.count == 1 ? "page" : "pages")")
                }.buttonStyle(.plain).accessibilityIdentifier("source-current")
            }
            if allowCamera && CameraPhotoPicker.available {
                Button { camera = true } label: { ChoiceRow(symbol: "camera.fill", title: "Take a photo", detail: "Use the camera now") }
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
            CameraPhotoPicker(front: frontCamera) { image in
                camera = false
                if let image { picked([image]) }
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
