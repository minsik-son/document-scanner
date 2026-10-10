import SwiftUI

// Crop the finished page, after perspective/illumination correction. Changing the
// selection is cheap: the sheet reuses one untrimmed raster and never re-runs OCR.
struct TrimMarginsView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let page: ScanPage
    let apply: (PageTrim) -> Void
    @State private var edges = PageTrim.zero
    @State private var image: UIImage?
    @State private var showResult = false
    @State private var problem: String?
    private enum Edge: String, CaseIterable { case top = "Top", bottom = "Bottom", left = "Left", right = "Right"
        var key: WritableKeyPath<PageTrim,Double> {
            switch self { case .top: \.top; case .bottom: \.bottom; case .left: \.left; case .right: \.right }
        }
    }
    var body: some View {
        NavigationStack {
            ToolPage(title: "Trim margins", subtitle: "Drag the corners or sides of the blue box, or use the sliders. Keep text and barcodes inside it.") {
                if let image {
                    preview(image).frame(maxWidth:.infinity).frame(height:300)
                        .background(TK.grey100,in:RoundedRectangle(cornerRadius:20, style: .continuous))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button { showResult.toggle() } label: { Label("Result", systemImage: showResult ? "eye.fill" : "eye") }
                                .buttonStyle(ChipStyle(selected: showResult)).accessibilityIdentifier("trim-show-result")
                            ForEach([1,2,5],id:\.self) { percent in
                                let v = Double(percent)/100
                                Button("\(percent)%") { edges = PageTrim(top:v,right:v,bottom:v,left:v) }
                                    .buttonStyle(ChipStyle(selected: edges == PageTrim(top:v,right:v,bottom:v,left:v))).accessibilityIdentifier("trim-preset-\(percent)")
                            }
                            Button("Reset") { edges = .zero }.buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("trim-reset")
                        }
                    }
                    ForEach(Edge.allCases,id:\.self) { edge in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(L(edge.rawValue)).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey700)
                                Spacer()
                                Text(String(format:"%.1f%%",edges[keyPath:edge.key]*100)).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.blue).monospacedDigit()
                                    .accessibilityIdentifier("trim-value-"+edge.rawValue.lowercased())
                            }
                            Slider(value:Binding(get:{ edges[keyPath:edge.key] },set:{ edges[keyPath:edge.key] = $0 }),in:0...0.44,step:0.001).tint(TK.blue)
                                .accessibilityLabel(edge.rawValue+" trim").accessibilityIdentifier("trim-"+edge.rawValue.lowercased())
                        }
                    }
                    Text("Your original is kept. For no added white space, save with Paper: Original and Margins: None.").font(.system(size: 13)).foregroundStyle(TK.grey500)
                    if page.sourcePDF != nil { Text("PDF text stays selectable. Forms are flattened.").font(.system(size: 13)).foregroundStyle(TK.grey500) }
                    if !(page.annotations ?? []).isEmpty { Text("Check existing annotations after trimming.").font(.system(size: 13)).foregroundStyle(TK.grey500) }
                } else if let problem { Text(L(problem)).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.red) }
                else { ProgressView().frame(maxWidth:.infinity,minHeight:300) }
            } actions: {
                Button("Apply") { apply(edges); dismiss() }.buttonStyle(CTAButtonStyle()).disabled(image == nil || !edges.valid).accessibilityIdentifier("trim-apply")
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.accessibilityIdentifier("trim-cancel") } }
            .task {
                edges = page.trimming
                var untrimmed = page; untrimmed.trimming = .zero
                do { image = try await ScanPreviewRenderer().render(untrimmed,root:store.root,maxDimension:1600) }
                catch is CancellationError { }
                catch { problem = error.localizedDescription }
            }
        }
    }
    /// The eight drag points on the blue box.
    private enum Handle: String, CaseIterable {
        case topLeft = "tl", top = "t", topRight = "tr", right = "r", bottomRight = "br", bottom = "b", bottomLeft = "bl", left = "l"
        var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
        var moves: (left: Bool, top: Bool, right: Bool, bottom: Bool) {
            switch self {
            case .topLeft: (true, true, false, false)
            case .top: (false, true, false, false)
            case .topRight: (false, true, true, false)
            case .right: (false, false, true, false)
            case .bottomRight: (false, false, true, true)
            case .bottom: (false, false, false, true)
            case .bottomLeft: (true, false, false, true)
            case .left: (true, false, false, false)
            }
        }
        func point(in r: CGRect) -> CGPoint {
            let m = moves
            let x = m.left ? r.minX : (m.right ? r.maxX : r.midX)
            let y = m.top ? r.minY : (m.bottom ? r.maxY : r.midY)
            return CGPoint(x: x, y: y)
        }
        var label: String {
            switch self {
            case .topLeft: "Top left corner"; case .top: "Top edge"; case .topRight: "Top right corner"; case .right: "Right edge"
            case .bottomRight: "Bottom right corner"; case .bottom: "Bottom edge"; case .bottomLeft: "Bottom left corner"; case .left: "Left edge"
            }
        }
    }
    /// Moves the handle's edges to the finger, keeping each margin within range and
    /// the box at least 12% of the page across.
    private func move(_ handle: Handle, to location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let x = min(max(location.x / size.width, 0), 1), y = min(max(location.y / size.height, 0), 1)
        var e = edges
        let m = handle.moves
        if m.left { e.left = min(x, 0.44, 0.88 - e.right) }
        if m.right { e.right = min(1 - x, 0.44, 0.88 - e.left) }
        if m.top { e.top = min(y, 0.44, 0.88 - e.bottom) }
        if m.bottom { e.bottom = min(1 - y, 0.44, 0.88 - e.top) }
        for k in [\PageTrim.left, \PageTrim.right, \PageTrim.top, \PageTrim.bottom] { e[keyPath: k] = (max(0, e[keyPath: k]) * 1000).rounded() / 1000 }
        edges = e
    }
    @ViewBuilder private func preview(_ image: UIImage) -> some View {
        if showResult, let cg = image.cgImage,
           let cropped = cg.cropping(to:edges.rect(in:CGSize(width:cg.width,height:cg.height)).integral) {
            Image(uiImage:UIImage(cgImage:cropped)).resizable().interpolation(.high).scaledToFit().padding(8).accessibilityLabel("Trimmed page preview")
        } else {
            GeometryReader { g in
                let scale = min((g.size.width-16)/image.size.width,(g.size.height-16)/image.size.height)
                let size = CGSize(width:image.size.width*scale,height:image.size.height*scale)
                let rect = edges.rect(in:size)
                ZStack(alignment:.topLeading) {
                    Image(uiImage:image).resizable().frame(width:size.width,height:size.height)
                    Path { path in path.addRect(CGRect(origin:.zero,size:size));path.addRect(rect) }
                        .fill(.black.opacity(0.5),style:FillStyle(eoFill:true))
                    Rectangle().stroke(TK.blue,lineWidth:2).frame(width:rect.width,height:rect.height).offset(x:rect.minX,y:rect.minY)
                        .allowsHitTesting(false)
                    // Drag a corner or the middle of a side to move those edges.
                    ForEach(Handle.allCases, id: \.self) { handle in
                        let p = handle.point(in: rect)
                        Circle().fill(.white).overlay(Circle().stroke(TK.blue, lineWidth: 2.5))
                            .frame(width: handle.isCorner ? 18 : 14, height: handle.isCorner ? 18 : 14)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                            .position(x: p.x, y: p.y)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim-canvas")).onChanged { value in
                                move(handle, to: value.location, in: size)
                            })
                            .accessibilityElement().accessibilityLabel(L(handle.label)).accessibilityIdentifier("trim-handle-" + handle.rawValue)
                    }
                }.frame(width:size.width,height:size.height).coordinateSpace(name: "trim-canvas").position(x:g.size.width/2,y:g.size.height/2)
                    .accessibilityElement(children: .contain).accessibilityLabel("Page with selected margins")
            }
        }
    }
}
