import SwiftUI
import ImageIO

/// Flat vector scenes that show what each tool does. Drawn in code so they
/// stay crisp at any size and match the tool icons' blue, teal and purple.
enum ToolArt: String, CaseIterable {
    case book, portrait, erase, marks, restore, mega, count
    case ocr, annotate, watermark, timestamp, merge, split, extract, reorder, compress, protect, images, longImage, print
    case measure, mesh

    var background: LinearGradient {
        let pair: (Color, Color)
        switch self {
        case .book, .ocr, .merge, .extract, .images, .measure: pair = (Color(hex: 0xEAF3FF), Color(hex: 0xF4F8FF))
        case .portrait, .count, .protect, .mesh, .split: pair = (Color(hex: 0xE6F8F3), Color(hex: 0xF3FBF9))
        case .erase, .marks, .annotate, .reorder, .longImage: pair = (Color(hex: 0xF1EEFF), Color(hex: 0xF8F6FF))
        case .restore, .watermark, .timestamp, .compress, .print, .mega: pair = (Color(hex: 0xFFF3E9), Color(hex: 0xFFF9F3))
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
        case .measure: MeasureArt()
        case .mesh: MeshArt()
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
        Text(text).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
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
private struct ProtectArt: View {
    var body: some View {
        ZStack {
            Paper(width: 120, height: 150, lines: 6)
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(TK.teal).frame(width: 64, height: 52).offset(y: 12)
                Circle().trim(from: 0.5, to: 1).stroke(TK.teal, lineWidth: 9).frame(width: 40, height: 40).offset(y: -12)
                Circle().fill(.white).frame(width: 12).offset(y: 10)
                Capsule().fill(.white).frame(width: 5, height: 13).offset(y: 20)
            }.offset(x: 48, y: 30).shadow(color: TK.teal.opacity(0.35), radius: 8, y: 4)
            Text("••••").font(.system(size: 22, weight: .heavy)).foregroundStyle(TK.teal).offset(x: -18, y: -46)
        }
    }
}
private struct ImagesArt: View {
    var body: some View {
        HStack(spacing: 18) {
            Paper(width: 86, height: 112, lines: 5)
            Arrow()
            ZStack {
                Landscape().frame(width: 92, height: 70).clipShape(RoundedRectangle(cornerRadius: 10)).rotationEffect(.degrees(-8)).offset(x: -10, y: -16)
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                Landscape().frame(width: 92, height: 70).clipShape(RoundedRectangle(cornerRadius: 10)).rotationEffect(.degrees(6)).offset(x: 10, y: 22)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            }
        }
    }
}
private struct LongImageArt: View {
    var body: some View {
        HStack(spacing: 22) {
            VStack(spacing: 6) { ForEach(0..<3, id: \.self) { _ in Paper(width: 50, height: 46, lines: 2) } }
            Arrow(color: TK.purple)
            VStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<2, id: \.self) { _ in Capsule().fill(Color(hex: 0xD6DEE8)).frame(width: 40, height: 5) }
                    }.frame(width: 62, height: 40).background(i % 2 == 0 ? Color.white : Color(hex: 0xF7F5FF))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10)).shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .overlay(alignment: .trailing) { Image(systemName: "arrow.down").font(.system(size: 18, weight: .heavy)).foregroundStyle(TK.purple).offset(x: 22) }
        }
    }
}
private struct PrintArt: View {
    var body: some View {
        ZStack {
            Paper(width: 92, height: 92, lines: 4).offset(y: -42)
            RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x3D7BEB)).frame(width: 170, height: 70)
            RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1B4FB8)).frame(width: 120, height: 10).offset(y: 18)
            Circle().fill(TK.teal).frame(width: 10).offset(x: 62, y: -12)
            Paper(width: 104, height: 54, lines: 2).offset(y: 52)
        }
    }
}
private struct MeasureArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xCFE4FF)).frame(width: 200, height: 110).rotation3DEffect(.degrees(48), axis: (1, 0, 0)).offset(y: 30)
            Path { p in p.move(to: CGPoint(x: 0, y: 30)); p.addLine(to: CGPoint(x: 170, y: 0)) }
                .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round)).frame(width: 170, height: 30).offset(y: 20)
            Circle().fill(.white).frame(width: 18).overlay(Circle().strokeBorder(TK.blue, lineWidth: 4)).offset(x: -85, y: 35)
            Circle().fill(.white).frame(width: 18).overlay(Circle().strokeBorder(TK.blue, lineWidth: 4)).offset(x: 85, y: 5)
            Pill(text: "24.5 cm").offset(y: -16)
            Circle().strokeBorder(.white, lineWidth: 3).frame(width: 46).offset(x: 40, y: -56).opacity(0.9)
            Circle().fill(.white).frame(width: 6).offset(x: 40, y: -56)
        }
    }
}
private struct MeshArt: View {
    var body: some View {
        ZStack {
            Image(systemName: "cube.transparent").font(.system(size: 120, weight: .ultraLight)).foregroundStyle(TK.teal)
            Image(systemName: "viewfinder").font(.system(size: 176, weight: .thin)).foregroundStyle(TK.teal.opacity(0.45))
            Pill(text: "LiDAR", color: TK.teal).offset(x: 92, y: -70)
        }
    }
}
