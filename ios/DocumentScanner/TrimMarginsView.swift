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
            ToolPage(title: "Trim margins", subtitle: "Remove borders or empty space. Keep text and barcodes inside the blue box.") {
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
                                Text(edge.rawValue).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey700)
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
                } else if let problem { Text(problem).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.red) }
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
                }.frame(width:size.width,height:size.height).position(x:g.size.width/2,y:g.size.height/2)
                    .accessibilityLabel("Page with selected margins")
            }
        }
    }
}
