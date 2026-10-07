import SwiftUI
import ImageIO

/// Flat vector scenes that show what each tool does. Drawn in code so they
/// stay crisp at any size and match the tool icons' blue, teal and purple.
enum ToolArt: String, CaseIterable {
    case book, portrait, erase, marks, restore, mega, count
    case ocr, annotate, watermark, timestamp, merge, split, extract, reorder, compress, protect, images, longImage, print
    case measure, mesh
    case word, excel, ppt, math, translate
    case cardContact, askDocument, removeFingers, autoSave, redact, fillForm

    var background: LinearGradient {
        let pair: (Color, Color)
        switch self {
        case .book, .ocr, .merge, .extract, .images, .measure, .word, .translate, .cardContact, .fillForm: pair = (Color(hex: 0xEAF3FF), Color(hex: 0xF4F8FF))
        case .portrait, .count, .protect, .mesh, .split, .excel, .autoSave, .redact: pair = (Color(hex: 0xE6F8F3), Color(hex: 0xF3FBF9))
        case .erase, .marks, .annotate, .reorder, .longImage, .math, .askDocument, .removeFingers: pair = (Color(hex: 0xF1EEFF), Color(hex: 0xF8F6FF))
        case .restore, .watermark, .timestamp, .compress, .print, .mega, .ppt: pair = (Color(hex: 0xFFF3E9), Color(hex: 0xFFF9F3))
        }
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct ToolIllustration: View {
    let art: ToolArt
    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 320, geo.size.height / 200)
            scene.frame(width: 320, height: 200).scaleEffect(scale).frame(width: geo.size.width, height: geo.size.height)
        }
    }
    @ViewBuilder private var scene: some View {
        switch art {
        case .book: BookArt()
        case .portrait: PortraitArt()
        case .erase: EraseArt()
        case .marks: MarksArt()
        case .restore: RestoreArt()
        case .mega: MegaArt()
        case .count: CountArt()
        case .ocr: OCRArt()
        case .annotate: SignArt()
        case .watermark: WatermarkArt()
        case .timestamp: TimestampArt()
        case .merge: MergeArt()
        case .split: SplitArt()
        case .extract: ExtractArt()
        case .reorder: ReorderArt()
        case .compress: CompressArt()
        case .protect: ProtectArt()
        case .images: ImagesArt()
        case .longImage: LongImageArt()
        case .print: PrintArt()
        case .measure: LoopArt(asset: "art-measure", still: 60)
        case .mesh: LoopArt(asset: "art-mesh", still: 60)
        case .word: WordArt()
        case .excel: ExcelArt()
        case .ppt: SlidesArt()
        case .math: MathArt()
        case .translate: TranslateArt()
        case .cardContact: LoopArt(asset: "art-card-contact", still: 60)
        case .askDocument: LoopArt(asset: "art-ask-document", still: 60)
        case .removeFingers: LoopArt(asset: "art-remove-fingers", still: 60)
        case .autoSave: LoopArt(asset: "art-auto-save", still: 60)
        case .redact: LoopArt(asset: "art-redact", still: 60)
        case .fillForm: LoopArt(asset: "art-fill-form", still: 60)
        }
    }
}

// MARK: - Shared pieces

private struct Paper: View {
    var width: CGFloat = 96
    var height: CGFloat = 124
    var lines = 5
    var lineColor = Color(hex: 0xD6DEE8)
    var accent: Color? = nil
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white)
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 9) {
                    if let accent { Capsule().fill(accent).frame(width: width * 0.45, height: 8) }
                    ForEach(0..<lines, id: \.self) { i in
                        Capsule().fill(lineColor).frame(width: width * (i % 3 == 2 ? 0.48 : 0.7), height: 6)
                    }
                }.padding(14)
            }
            .shadow(color: Color(hex: 0x1B3A6B).opacity(0.12), radius: 10, y: 5)
    }
}
private struct Badge: View {
    let symbol: String
    var color = TK.blue
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(color, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: color.opacity(0.35), radius: 6, y: 3)
    }
}
private struct Arrow: View {
    var color = TK.blue
    var body: some View {
        Image(systemName: "arrow.right").font(.system(size: 22, weight: .heavy)).foregroundStyle(color.opacity(0.85))
    }
}
private struct Pill: View {
    let text: String
    var color = TK.blue
    var body: some View {
        Text(L(text)).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5).background(color, in: Capsule())
    }
}
private struct Landscape: View {
    var faded = false
    var body: some View {
        ZStack {
            Rectangle().fill(faded ? Color(hex: 0xD9C7A3) : Color(hex: 0x9FD3FF))
            Circle().fill(faded ? Color(hex: 0xEADBBE) : Color(hex: 0xFFC342)).frame(width: 26).offset(x: 26, y: -22)
            Triangle().fill(faded ? Color(hex: 0xA99677) : Color(hex: 0x3D7BEB)).frame(width: 90, height: 56).offset(x: -18, y: 22)
            Triangle().fill(faded ? Color(hex: 0xB9A685) : Color(hex: 0x18B99A)).frame(width: 74, height: 44).offset(x: 30, y: 28)
        }
    }
}
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: rect.midX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.closeSubpath() }
    }
}
private struct Scribble: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            let steps = 6
            for i in 1...steps {
                let x = rect.minX + rect.width * CGFloat(i) / CGFloat(steps)
                p.addQuadCurve(to: CGPoint(x: x, y: rect.midY), control: CGPoint(x: x - rect.width / CGFloat(steps * 2), y: i % 2 == 0 ? rect.minY : rect.maxY))
            }
        }
    }
}

// MARK: - Scenes

/// 3D-rendered book (art-book-* assets): a page lifts off the open book,
/// flattens, gets a check badge, and sparkles twinkle. Loops every 3.4 s;
/// with Reduce Motion it shows the finished state.
/// Blender-rendered loop (page lifts out of the book, unbends, check pops).
/// Plays the bundled APNG; Reduce Motion shows the settled frame.
private struct BookArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-book-flat", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}

/// Loops an APNG from a data asset with ImageIO.
struct AnimatedPNG: UIViewRepresentable {
    let asset: String
    var stillFrame = 0
    var animates = true

    final class Coordinator { var token = UUID() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        start(view, context.coordinator)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {}

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.token = UUID()
    }

    private func start(_ view: UIImageView, _ coordinator: Coordinator) {
        guard let data = NSDataAsset(name: asset)?.data else { return }
        if !animates {
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let frame = CGImageSourceCreateImageAtIndex(source, min(stillFrame, max(0, CGImageSourceGetCount(source) - 1)), nil) {
                view.image = UIImage(cgImage: frame)
            }
            return
        }
        let token = UUID()
        coordinator.token = token
        CGAnimateImageDataWithBlock(data as CFData, nil) { [weak view, weak coordinator] _, frame, stop in
            guard let view, let coordinator, coordinator.token == token else { stop.pointee = true; return }
            view.image = UIImage(cgImage: frame)
        }
    }
}
/// Blender-rendered loop: crop frame locks on, ID photo slides out, check pops.
private struct PortraitArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-id-photo", stillFrame: 56, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: a scribble appears, the eraser scrubs it, it vanishes.
private struct EraseArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-erase", stillFrame: 80, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: a scan sweep lifts highlighter and pen marks off the page.
private struct MarksArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-marks", stillFrame: 64, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: a magic wand flips the faded photo into a restored one.
private struct RestoreArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-restore", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: three overlapping photos fly onto one large canvas.
private struct MegaArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-mega", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: teal rings pop onto each object on the tray, then a check.
private struct CountArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-count", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: a scan frame locks on, the scan line sweeps, and an editable text card pops out.
private struct OCRArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-ocr", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: a fountain pen signs the document and a comment bubble pops.
private struct SignArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-sign", stillFrame: 64, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: a rubber stamp presses a watermark emblem onto the page.
private struct WatermarkArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-watermark", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: clock hands spin, then a time chip slides onto the photo.
/// Blender-rendered loop: clock hands spin, then a time chip slides onto the photo.
private struct TimestampArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-timestamp", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: two documents slide together into one stack, then a check.
private struct MergeArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-merge", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: scissors snip the stack and two pages fly out.
private struct SplitArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-split", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: one page lifts out of the stack, gets selected and checked.
private struct ExtractArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-extract", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: two pages swap places along arcs while the swap badge spins.
private struct ReorderArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-reorder", stillFrame: 44, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: press plates squeeze the PDF into a smaller file.
private struct CompressArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-compress", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: a padlock drops onto the PDF, its shackle clicks shut, and a shield pops.
private struct ProtectArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-protect", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: two photos fan out of the PDF page as image files.
private struct ImagesArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-images", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: three screenshots snap into one tall stitched image.
private struct LongImageArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-long-image", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: the printer hums and a page slides out of the slot.
private struct PrintArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-print", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
/// Blender-rendered loop: scanned page turns into an editable Word page, table pops in, check badge
private struct WordArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-word", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}

/// Blender-rendered loop: paper table becomes a spreadsheet, values fill row by row, chart badge
private struct ExcelArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-excel", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}

/// Blender-rendered loop: page becomes a slide, more slides fan out, play badge
private struct SlidesArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-ppt", stillFrame: 62, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}

/// Blender-rendered loop: scan frame and line read the page, symbols type into an editable card
private struct MathArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-math", stillFrame: 66, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}

/// Blender-rendered loop: swap badge spins, translated page slides out, globe pops
private struct TranslateArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: "art-translate", stillFrame: 60, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}


/// Blender-rendered loop for the Smart tools.
private struct LoopArt: View {
    let asset: String
    let still: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AnimatedPNG(asset: asset, stillFrame: still, animates: !reduceMotion)
            .id(reduceMotion)
            .frame(width: 320, height: 200)
            .accessibilityHidden(true)
    }
}
