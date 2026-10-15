import SwiftUI

/// A recognized page drawn the way it will print: the sheet of paper with its
/// margins, each table and paragraph at its place, cell colours and text sizes.
/// The review steps show it first so the whole layout can be checked at a glance.
struct OfficePageCanvas: View {
    let page: PageLayout
    /// Width of the drawn sheet in points.
    let width: CGFloat

    private var scale: CGFloat { width / CGFloat(max(1, page.width)) }
    private var height: CGFloat { CGFloat(page.height) * scale }
    /// View points per printed point: a 10 pt font is drawn 10 × this.
    private var fontScale: CGFloat { width / CGFloat(max(1, page.pageWidth)) }

    private func rect(_ b: LBox) -> CGRect {
        CGRect(x: b.x0 * scale, y: b.y0 * scale, width: b.width * scale, height: b.height * scale)
    }
    private func color(_ c: LayoutColor?) -> Color? {
        c.map { Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255) }
    }
    private func alignment(_ a: LayoutAlignment) -> Alignment { a == .center ? .center : a == .right ? .trailing : .leading }
    private func textAlignment(_ a: LayoutAlignment) -> TextAlignment { a == .center ? .center : a == .right ? .trailing : .leading }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            ForEach(page.graphics.indices, id: \.self) { i in
                let r = rect(page.graphics[i].box)
                Rectangle().fill(Color(white: 0.92))
                    .overlay(Image(systemName: "photo").font(.system(size: max(6, min(r.width, r.height) * 0.3))).foregroundStyle(Color(white: 0.7)))
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            }
            ForEach(page.items.indices, id: \.self) { index in
                switch page.items[index] {
                case .paragraph(let p): paragraph(p)
                case .table(let t): table(t)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder private func paragraph(_ p: LayoutParagraph) -> some View {
        let size = max(1, p.fontSize * fontScale)
        ForEach(p.lines.indices, id: \.self) { n in
            let line = p.lines[n], r = rect(line.box)
            let runs = line.segments.flatMap(\.runs)
            Text(line.text.replacingOccurrences(of: "\t", with: "   "))
                .font(.system(size: size, weight: runs.contains(where: \.bold) ? .semibold : .regular))
                .foregroundStyle(color(runs.first?.color) ?? .black)
                .lineLimit(1).minimumScaleFactor(0.3)
                .frame(width: max(r.width, p.alignment == .left ? r.width * 1.15 : r.width), height: max(r.height, size * 1.2),
                       alignment: alignment(p.alignment))
                .offset(x: r.minX, y: r.minY)
        }
    }

    @ViewBuilder private func table(_ t: LayoutTable) -> some View {
        ForEach(t.cells.indices, id: \.self) { i in
            let cell = t.cells[i], r = rect(cell.box)
            let runs = cell.lines.flatMap { $0 }
            let size = max(1, (cell.fontSize > 0 ? cell.fontSize : 10) * fontScale)
            ZStack(alignment: alignment(cell.alignment)) {
                Rectangle().fill(color(cell.fill) ?? .white)
                Text(cell.text)
                    .font(.system(size: size, weight: runs.contains(where: \.bold) ? .semibold : .regular))
                    .foregroundStyle(color(runs.first?.color) ?? .black)
                    .multilineTextAlignment(textAlignment(cell.alignment))
                    .lineLimit(max(1, cell.lines.count)).minimumScaleFactor(0.3)
                    .padding(.horizontal, max(0.5, 2 * fontScale))
            }
            .frame(width: r.width, height: r.height)
            .overlay(Rectangle().strokeBorder((t.ruled ? (color(t.lineColor) ?? .black) : .black).opacity(t.ruled ? 0.85 : 0.12), lineWidth: max(0.3, 0.6 * fontScale)))
            .offset(x: r.minX, y: r.minY)
        }
    }
}

enum OfficePagePreview {
    /// The page as a picture, sharp enough to zoom into small cell text.
    @MainActor static func image(_ page: PageLayout, width: CGFloat = 1700) -> UIImage? {
        let renderer = ImageRenderer(content: OfficePageCanvas(page: page, width: width))
        renderer.scale = 1
        return renderer.uiImage
    }
}

/// The whole page, fitted to the screen; tap to open it full screen and zoom in.
struct OfficePageOverview: View {
    let page: PageLayout
    var caption: String = "The whole page as it will print. Tap to zoom."
    /// When set, tapping the page opens the corrections instead of the zoom view.
    var editLabel: String? = nil
    var onEdit: (() -> Void)? = nil
    private struct Zoom: Identifiable { let id = UUID(); let image: UIImage }
    @State private var zoom: Zoom?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                Button {
                    if let onEdit { onEdit(); return }
                    // Item-driven so the cover always receives the rendered page.
                    zoom = OfficePagePreview.image(page).map { Zoom(image: $0) }
                } label: {
                    OfficePageCanvas(page: page, width: w)
                        .overlay(Rectangle().strokeBorder(TK.grey200, lineWidth: 1))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        // A page that opens the corrections has its Correct button under the page instead.
                        .overlay(alignment: .bottomTrailing) {
                            if editLabel == nil {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                    .padding(8).background(.black.opacity(0.55), in: Circle()).padding(8)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page preview")
                .accessibilityHint(editLabel.map { L($0) } ?? L("Opens the whole page full screen to zoom in"))
                .accessibilityIdentifier("office-page-preview")
            }
            .aspectRatio(CGFloat(max(1, page.width)) / CGFloat(max(1, page.height)), contentMode: .fit)
            // Centred when the page is fitted to the height left on a non-scrolling screen.
            .frame(maxWidth: .infinity)
            if !caption.isEmpty { Text(L(caption)).font(.system(size: 13)).foregroundStyle(TK.grey500) }
        }
        .fullScreenCover(item: $zoom) { zoom in
            EnlargedScanPreview(initialImage: zoom.image) { zoom.image }
        }
    }
}

/// Full-screen wait while scanned pages become an Office file: the page is read,
/// its parts are found, and they fill a sheet, a Word page or a slide (timing in
/// `AnimatedWorkPage`); the line under the title is the real progress.
struct OfficeConversionProgress: View {
    enum Kind { case excel, word, slides }
    let kind: Kind
    /// The real progress line ("Reading page 1 of 2…").
    let phase: String
    var done = false
    var onFinished: (() -> Void)? = nil
    var cancel: (() -> Void)? = nil

    private var tint: Color {
        switch kind {
        case .excel: Color(red: 0.129, green: 0.451, blue: 0.275)
        case .word: Color(red: 0.169, green: 0.341, blue: 0.604)
        case .slides: Color(red: 0.824, green: 0.278, blue: 0.149)
        }
    }
    private var title: String {
        switch kind {
        case .excel: "Turning your tables into Excel"
        case .word: "Turning your document into Word"
        case .slides: "Turning your pages into slides"
        }
    }
    private var steps: [String] {
        switch kind {
        case .excel: ["Finding the tables…", "Splitting the cells…", "Putting the text in the cells…", "Making the Excel file…"]
        case .word: ["Finding the text…", "Sorting paragraphs and tables…", "Writing the text out…", "Making the Word file…"]
        case .slides: ["Looking over the page…", "Sorting titles and text…", "Moving it onto slides…", "Making the PowerPoint file…"]
        }
    }

    var body: some View {
        AnimatedWorkPage(title: title, steps: steps, tint: tint, phase: phase, done: done, onFinished: onFinished, cancel: cancel) { t in stage(t) }
    }

    // MARK: Timing (fractions of the 8-second loop, as in the design mockup)

    /// Eased value between keyframes.
    private func kf(_ t: Double, _ stops: [(Double, Double)]) -> Double {
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
    /// The loop position `seconds` later, wrapped into 0…1.
    private func later(_ t: Double, _ seconds: Double) -> Double { let x = t - seconds / 8; return x < 0 ? x + 1 : x }
    /// 0 → 1 while the found parts are marked in the brand colour.
    private func found(_ t: Double) -> Double { kf(t, [(0, 0), (0.23, 0), (0.28, 1), (0.8, 1), (0.88, 0), (1, 0)]) }
    /// 0 → 1 as a part of the new file fills in, `delay` seconds after the others start.
    private func fill(_ t: Double, delay: Double) -> Double { kf(later(t, delay), [(0, 0), (0.57, 0), (0.64, 1), (0.95, 1), (1, 0)]) }

    // MARK: Stage

    @ViewBuilder private func stage(_ t: Double) -> some View {
        let shift: Double = kind == .slides ? -96 : -82
        let shrink: Double = kind == .slides ? 0.56 : 0.6
        ZStack(alignment: .topLeading) {
            source(t)
                .frame(width: 160, height: 212)
                .scaleEffect(kf(t, [(0, 1), (0.46, 1), (0.58, shrink), (1, shrink)]))
                .offset(x: 80 + kf(t, [(0, 0), (0.46, 0), (0.58, shift), (1, shift)]), y: 20)
                .opacity(kf(t, [(0, 0), (0.04, 1), (0.8, 1), (0.88, 0), (1, 0)]))
            target(t)
            Circle().fill(tint).frame(width: 40, height: 40)
                .overlay(Image(systemName: "checkmark").font(.system(size: 20, weight: .heavy)).foregroundStyle(.white))
                .padding(4).background(Circle().fill(TK.paper))
                .scaleEffect(kf(t, [(0, 0), (0.83, 0), (0.87, 1.15), (0.89, 1), (0.95, 1), (1, 0)]))
                .offset(x: kind == .slides ? 232 : 216, y: kind == .excel ? 14 : kind == .word ? 6 : 50)
        }
        .frame(width: 320, height: 260, alignment: .topLeading)
    }

    private func mix(_ amount: Double) -> some View {
        Rectangle().fill(TK.grey300).overlay(Rectangle().fill(tint).opacity(amount))
    }

    /// The scanned page, with a reading line and its parts marked as they are found.
    @ViewBuilder private func source(_ t: Double) -> some View {
        let h = found(t)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(TK.grey200))
            Group {
                switch kind {
                case .excel:
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(TK.grey500).frame(width: 74, height: 7).frame(maxWidth: .infinity)
                        Capsule().fill(TK.grey300).frame(width: 106, height: 4)
                        Capsule().fill(TK.grey300).frame(width: 82, height: 4)
                        ZStack {
                            Rectangle().fill(tint.opacity(0.10 * h))
                            OfficeProgressGrid(rows: 5, columns: [0.22, 0.58, 0.78]).stroke(TK.grey300, lineWidth: 1.2)
                            OfficeProgressGrid(rows: 5, columns: [0.22, 0.58, 0.78]).stroke(tint, lineWidth: 1.4).opacity(h)
                        }.frame(height: 118).padding(.top, 6)
                        Capsule().fill(TK.grey300).frame(width: 62, height: 4).padding(.top, 4)
                    }.padding(.horizontal, 12).padding(.vertical, 14)
                case .word:
                    VStack(alignment: .leading, spacing: 7) {
                        mix(h).frame(width: 76, height: 8).clipShape(Capsule())
                        Spacer().frame(height: 4)
                        ForEach([1.0, 0.94, 0.97, 0.6], id: \.self) { w in mix(h).frame(width: 132 * w, height: 4).clipShape(Capsule()) }
                        RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.08 * h)).frame(height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(TK.grey300, lineWidth: 1.5))
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(tint, lineWidth: 1.5).opacity(h)).padding(.top, 6)
                        ForEach([0.99, 0.88, 0.42], id: \.self) { w in mix(h).frame(width: 132 * w, height: 4).clipShape(Capsule()) }
                    }.padding(.horizontal, 14).padding(.vertical, 16)
                case .slides:
                    VStack(alignment: .leading, spacing: 8) {
                        block(h) { Capsule().fill(TK.grey500).frame(width: 90, height: 9) }
                        block(h) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach([0.92, 0.8, 0.86], id: \.self) { w in Capsule().fill(TK.grey300).frame(width: 124 * w, height: 4) }
                            }
                        }
                        block(h) { RoundedRectangle(cornerRadius: 3).fill(TK.grey200).frame(height: 56) }
                        block(h) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach([0.96, 0.54], id: \.self) { w in Capsule().fill(TK.grey300).frame(width: 124 * w, height: 4) }
                            }
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 12)
                }
            }
            Rectangle().fill(TK.blue).frame(height: 3)
                .offset(y: kf(t, [(0, 0), (0.22, 208), (1, 208)]))
                .opacity(kf(t, [(0, 0), (0.03, 1), (0.22, 1), (0.25, 0), (1, 0)]))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func block<Content: View>(_ h: Double, @ViewBuilder _ content: () -> Content) -> some View {
        content().padding(4).frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08 * h), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(h), lineWidth: 1.5))
    }

    /// The new file filling in: a sheet, a Word page, or slides.
    @ViewBuilder private func target(_ t: Double) -> some View {
        let opacity = kf(t, [(0, 0), (0.48, 0), (0.58, 1), (0.95, 1), (1, 0)])
        let scale = kf(t, [(0, 0.9), (0.48, 0.9), (0.58, 1), (0.8, 1), (0.88, 1.06), (1, 1.06)])
        switch kind {
        case .excel:
            sheet(t).frame(width: 176, height: 188).scaleEffect(scale)
                .offset(x: 132 + kf(t, [(0, 24), (0.48, 24), (0.58, 0), (0.8, 0), (0.88, -64), (1, -64)]), y: 36).opacity(opacity)
        case .word:
            wordPage(t).frame(width: 160, height: 206).scaleEffect(scale)
                .offset(x: 140 + kf(t, [(0, 24), (0.48, 24), (0.58, 0), (0.8, 0), (0.88, -64), (1, -64)]), y: 26).opacity(opacity)
        case .slides:
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint, lineWidth: 1.5))
                    .frame(width: 196, height: 118)
                    .scaleEffect(kf(t, [(0, 1), (0.8, 1), (0.88, 1.06), (1, 1.06)]))
                    .offset(x: 112 + kf(t, [(0, 0), (0.52, 0), (0.62, 10), (0.8, 10), (0.88, -40), (1, -40)]),
                            y: 78 + kf(t, [(0, 0), (0.52, 0), (0.62, -10), (1, -10)]))
                    .opacity(kf(t, [(0, 0), (0.52, 0), (0.62, 1), (0.95, 1), (1, 0)]))
                slide(t).frame(width: 196, height: 118).scaleEffect(scale)
                    .offset(x: 112 + kf(t, [(0, 24), (0.48, 24), (0.58, 0), (0.8, 0), (0.88, -50), (1, -50)]), y: 78).opacity(opacity)
            }
        }
    }

    private func fileBar(_ letter: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: letter).font(.system(size: 10, weight: .heavy)).foregroundStyle(tint)
                .frame(width: 14, height: 14).background(.white, in: RoundedRectangle(cornerRadius: 3))
            Capsule().fill(.white.opacity(0.7)).frame(width: 56, height: 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 24).background(tint)
    }

    private func sheet(_ t: Double) -> some View {
        VStack(spacing: 0) {
            fileBar("X")
            HStack(spacing: 0) {
                Color.clear.frame(width: 18)
                ForEach(["A", "B", "C"], id: \.self) { letter in
                    Text(verbatim: letter).font(.system(size: 9, weight: .semibold)).foregroundStyle(TK.grey700)
                        .frame(maxWidth: .infinity).overlay(alignment: .leading) { Rectangle().fill(TK.grey300).frame(width: 1) }
                }
            }
            .frame(height: 16).background(TK.grey100)
            .overlay(alignment: .bottom) { Rectangle().fill(TK.grey300).frame(height: 1) }
            ForEach(0..<6, id: \.self) { r in
                HStack(spacing: 0) {
                    Text(verbatim: "\(r + 1)").font(.system(size: 9, weight: .semibold)).foregroundStyle(TK.grey700)
                        .frame(width: 18, height: 23).background(TK.grey100)
                    ForEach(0..<3, id: \.self) { c in
                        let amount = fill(t, delay: Double(r * 3 + c) * 0.06)
                        ZStack(alignment: .leading) {
                            (r == 0 ? tint.opacity(0.12) : Color.white)
                            GeometryReader { geo in
                                Capsule().fill(r == 0 ? tint : TK.grey500)
                                    .frame(width: (geo.size.width - 10) * 0.72 * amount, height: 5)
                                    .opacity(amount > 0 ? 1 : 0)
                                    .frame(maxHeight: .infinity).padding(.leading, 5)
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 23)
                        .overlay(alignment: .leading) { Rectangle().fill(TK.grey200).frame(width: 1) }
                    }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(TK.grey200).frame(height: 1) }
            }
            Spacer(minLength: 0)
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint, lineWidth: 1.5))
    }

    private func wordPage(_ t: Double) -> some View {
        let lines: [(height: CGFloat, width: CGFloat, heading: Bool)] = [(8, 0.62, true), (4, 1, false), (4, 0.94, false), (4, 0.97, false), (4, 0.58, false), (4, 0, false), (4, 1, false), (4, 0.86, false), (4, 0.4, false)]
        return VStack(spacing: 0) {
            fileBar("W")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    let amount = fill(t, delay: Double(i) * 0.12)
                    Capsule().fill(line.heading ? tint : TK.grey500)
                        .frame(width: 130 * line.width * amount, height: line.height)
                        .opacity(amount > 0 ? 1 : 0)
                        .frame(maxWidth: .infinity, minHeight: line.height, alignment: .leading)
                }
            }
            .padding(14)
            Spacer(minLength: 0)
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint, lineWidth: 1.5))
    }

    private func slide(_ t: Double) -> some View {
        let lines: [(height: CGFloat, width: CGFloat, bullet: Bool)] = [(9, 0.82, false), (4, 0.9, true), (4, 0.74, true), (4, 0.84, true)]
        return VStack(spacing: 0) {
            Rectangle().fill(tint).frame(height: 6)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let amount = fill(t, delay: Double(i) * 0.18)
                        HStack(spacing: 4) {
                            if line.bullet { Circle().fill(tint).frame(width: 4, height: 4) }
                            Capsule().fill(line.bullet ? TK.grey500 : TK.grey900)
                                .frame(width: 100 * line.width * amount, height: line.height)
                                .opacity(amount > 0 ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: line.height, alignment: .leading)
                    }
                }
                RoundedRectangle(cornerRadius: 4).fill(TK.grey100).frame(width: 58, height: 58)
                    .overlay(Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(TK.grey500))
                    .scaleEffect(kf(t, [(0, 0), (0.64, 0), (0.68, 1.12), (0.7, 1), (0.95, 1), (1, 0)]))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Spacer(minLength: 0)
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint, lineWidth: 1.5))
    }
}

/// A table's outline: its border, `rows` equal rows and column lines at fractions of the width.
private struct OfficeProgressGrid: Shape {
    let rows: Int
    let columns: [CGFloat]
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        for r in 1..<max(1, rows) {
            let y = rect.minY + rect.height * CGFloat(r) / CGFloat(rows)
            p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        for c in columns {
            let x = rect.minX + rect.width * c
            p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return p
    }
}

/// A finished Word or Excel file shown as its pages print, full screen with zoom.
/// Used in place of Quick Look for these files: Apple's viewer sizes Word tables to their
/// text (columns collapse and a form falls apart) and shows a sheet at actual size,
/// while Word, Excel, Pages and LibreOffice open the file as drawn here.
struct OfficeLayoutPreview: View {
    @Environment(\.dismiss) private var dismiss
    let pages: [PageLayout]
    let title: String
    @State private var image: UIImage?
    var body: some View {
        NavigationStack {
            Group {
                if let image { ZoomableScanImage(image: image) }
                else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .background(TK.grey100.ignoresSafeArea())
            .navigationTitle(Text(verbatim: title)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }.fontWeight(.semibold).accessibilityIdentifier("office-preview-done")
                }
            }
        }
        .task { image = Self.stacked(pages) }
    }
    /// Every page, top to bottom, with a grey gap between pages.
    @MainActor static func stacked(_ pages: [PageLayout]) -> UIImage? {
        let width: CGFloat = pages.count > 4 ? 1000 : 1800
        let images = pages.prefix(20).compactMap { OfficePagePreview.image($0, width: width) }
        guard let widest = images.map(\.size.width).max() else { return nil }
        let gap: CGFloat = 36
        let height = images.reduce(0) { $0 + $1.size.height } + gap * CGFloat(images.count - 1)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: widest, height: height), format: format).image { context in
            UIColor(white: 0.9, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: widest, height: height))
            var y: CGFloat = 0
            for page in images {
                page.draw(in: CGRect(x: (widest - page.size.width) / 2, y: y, width: page.size.width, height: page.size.height))
                y += page.size.height + gap
            }
        }
    }
}
