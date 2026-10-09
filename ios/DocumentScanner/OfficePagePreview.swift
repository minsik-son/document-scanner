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
            .overlay(Rectangle().strokeBorder(Color.black.opacity(t.ruled ? 0.85 : 0.12), lineWidth: max(0.3, 0.6 * fontScale)))
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
    @State private var zoomImage: UIImage?
    @State private var zooming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                Button {
                    zoomImage = OfficePagePreview.image(page)
                    zooming = zoomImage != nil
                } label: {
                    OfficePageCanvas(page: page, width: w)
                        .overlay(Rectangle().strokeBorder(TK.grey200, lineWidth: 1))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                                .padding(8).background(.black.opacity(0.55), in: Circle()).padding(8)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page preview")
                .accessibilityHint("Opens the whole page full screen to zoom in")
                .accessibilityIdentifier("office-page-preview")
            }
            .aspectRatio(CGFloat(max(1, page.width)) / CGFloat(max(1, page.height)), contentMode: .fit)
            Text(L(caption)).font(.system(size: 13)).foregroundStyle(TK.grey500)
        }
        .fullScreenCover(isPresented: $zooming) {
            if let zoomImage { EnlargedScanPreview(initialImage: zoomImage) { zoomImage } }
        }
    }
}
