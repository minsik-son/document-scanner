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
private struct CountArt: View {
    private let spots: [(CGFloat, CGFloat)] = [(-70, -30), (-25, -42), (20, -30), (64, -40), (-48, 12), (-2, 4), (44, 12), (-24, 50), (22, 50), (70, 40)]
    var body: some View {
        ZStack {
            ForEach(Array(spots.enumerated()), id: \.offset) { i, p in
                ZStack {
                    Circle().fill(Color(hex: 0xC5CDD6)).frame(width: 36)
                    Circle().strokeBorder(TK.teal, lineWidth: 3).frame(width: 36)
                    Text("\(i + 1)").font(.system(size: 13, weight: .heavy)).foregroundStyle(TK.grey900)
                }.offset(x: p.0, y: p.1)
            }
            Pill(text: "10 objects", color: TK.teal).offset(x: 104, y: -76)
        }
    }
}
private struct OCRArt: View {
    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                Paper(width: 104, height: 132, lines: 6, accent: TK.blue.opacity(0.5))
                Corners().stroke(TK.teal, style: StrokeStyle(lineWidth: 4, lineCap: .round)).frame(width: 124, height: 152)
            }
            Arrow()
            VStack(alignment: .leading, spacing: 8) {
                Text("Aa").font(.system(size: 30, weight: .heavy)).foregroundStyle(TK.blue)
                ForEach(0..<4, id: \.self) { i in Capsule().fill(TK.grey300).frame(width: i == 3 ? 46 : 82, height: 7) }
            }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 14)).shadow(color: .black.opacity(0.1), radius: 8, y: 4)
        }
    }
    struct Corners: Shape {
        func path(in r: CGRect) -> Path {
            let l: CGFloat = 22
            return Path { p in
                p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
                p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
                p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
                p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
            }
        }
    }
}
private struct SignArt: View {
    var body: some View {
        ZStack {
            Paper(width: 160, height: 150, lines: 5)
            Path { p in
                p.move(to: CGPoint(x: 0, y: 30))
                p.addCurve(to: CGPoint(x: 40, y: 10), control1: CGPoint(x: 10, y: -10), control2: CGPoint(x: 30, y: 50))
                p.addCurve(to: CGPoint(x: 80, y: 22), control1: CGPoint(x: 50, y: -20), control2: CGPoint(x: 60, y: 50))
                p.addCurve(to: CGPoint(x: 110, y: 14), control1: CGPoint(x: 90, y: 0), control2: CGPoint(x: 100, y: 30))
            }.stroke(TK.purple, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .frame(width: 110, height: 40).offset(x: 0, y: 38)
            Capsule().fill(TK.grey300).frame(width: 110, height: 2).offset(y: 62)
            Image(systemName: "pencil.tip").font(.system(size: 44, weight: .bold)).foregroundStyle(TK.purple).rotationEffect(.degrees(-35)).offset(x: 86, y: 12)
        }
    }
}
private struct WatermarkArt: View {
    var body: some View {
        ZStack {
            Paper(width: 150, height: 156, lines: 7)
            VStack(spacing: 18) {
                ForEach(0..<3, id: \.self) { _ in
                    Text("CONFIDENTIAL").font(.system(size: 15, weight: .heavy)).foregroundStyle(TK.orange.opacity(0.5))
                }
            }.rotationEffect(.degrees(-28)).frame(width: 150, height: 156).clipped()
            Badge(symbol: "seal.fill", color: TK.orange, size: 40).offset(x: 72, y: -66)
        }
    }
}
private struct TimestampArt: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Landscape().frame(width: 200, height: 136).clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("09:41").font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                Text("Fri · Oct 2, 2026").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 3) { Image(systemName: "mappin.circle.fill").foregroundStyle(TK.orange); Text("On site").foregroundStyle(.white) }.font(.system(size: 11, weight: .semibold))
            }.padding(12).shadow(color: .black.opacity(0.35), radius: 4)
        }
        .padding(7).background(.white, in: RoundedRectangle(cornerRadius: 18)).shadow(color: .black.opacity(0.12), radius: 10, y: 5)
        .overlay(alignment: .topTrailing) { Badge(symbol: "clock.fill", color: TK.orange).offset(x: 14, y: -14) }
    }
}
private struct MergeArt: View {
    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Paper(width: 70, height: 92, lines: 4, accent: TK.teal.opacity(0.6)).offset(x: -14, y: -14)
                Paper(width: 70, height: 92, lines: 4, accent: TK.blue.opacity(0.6)).offset(x: 14, y: 14)
            }
            Arrow()
            ZStack {
                Paper(width: 84, height: 112, lines: 5).offset(x: 6, y: 6)
                Paper(width: 84, height: 112, lines: 5, accent: TK.blue.opacity(0.6))
                Badge(symbol: "plus", size: 30).offset(x: 42, y: -56)
            }
        }
    }
}
private struct SplitArt: View {
    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Paper(width: 86, height: 116, lines: 5)
                Rectangle().fill(TK.teal).frame(width: 110, height: 2).mask(HStack(spacing: 4) { ForEach(0..<14, id: \.self) { _ in Rectangle().frame(width: 4) } })
                Badge(symbol: "scissors", color: TK.teal, size: 32).offset(x: -54)
            }
            Arrow(color: TK.teal)
            VStack(spacing: 10) { Paper(width: 70, height: 52, lines: 2); Paper(width: 70, height: 52, lines: 2) }
        }
    }
}
private struct ExtractArt: View {
    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 8) {
                HStack(spacing: 8) { cell(true); cell(false) }
                HStack(spacing: 8) { cell(false); cell(true) }
            }
            Arrow()
            ZStack(alignment: .topTrailing) {
                Paper(width: 78, height: 102, lines: 4).offset(x: 6, y: 6)
                Paper(width: 78, height: 102, lines: 4, accent: TK.blue.opacity(0.6))
            }
        }
    }
    private func cell(_ on: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            Paper(width: 48, height: 62, lines: 3)
            if on { Badge(symbol: "checkmark", size: 22).offset(x: 6, y: -6) }
        }.opacity(on ? 1 : 0.55)
    }
}
private struct ReorderArt: View {
    var body: some View {
        ZStack {
            HStack(spacing: 14) {
                numbered(2); numbered(1); numbered(3)
            }
            Path { p in p.move(to: CGPoint(x: 0, y: 30)); p.addQuadCurve(to: CGPoint(x: 66, y: 30), control: CGPoint(x: 33, y: -12)) }
                .stroke(TK.purple, style: StrokeStyle(lineWidth: 4, lineCap: .round)).frame(width: 66, height: 30).offset(x: -34, y: -78)
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 14)).foregroundStyle(TK.purple).offset(x: 0, y: -50)
        }
    }
    private func numbered(_ n: Int) -> some View {
        ZStack(alignment: .bottom) {
            Paper(width: 70, height: 92, lines: 4)
            Text("\(n)").font(.system(size: 14, weight: .heavy)).foregroundStyle(.white).frame(width: 28, height: 28).background(TK.purple, in: Circle()).offset(y: 12)
        }
    }
}
private struct CompressArt: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.right").font(.system(size: 24, weight: .heavy)).foregroundStyle(TK.orange)
            Paper(width: 92, height: 120, lines: 5)
            Image(systemName: "arrow.left").font(.system(size: 24, weight: .heavy)).foregroundStyle(TK.orange)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                Text("4.2 MB").strikethrough().foregroundStyle(TK.grey500)
                Image(systemName: "arrow.right").foregroundStyle(TK.grey500)
                Text("1.1 MB").foregroundStyle(TK.orange)
            }.font(.system(size: 13, weight: .bold)).padding(.horizontal, 12).padding(.vertical, 6).background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.1), radius: 6, y: 3).offset(y: 22)
        }
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
