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
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    Text("Remove unwanted borders or empty space. Check that text and barcodes stay inside the blue area.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let image {
                        preview(image).frame(maxWidth:.infinity).frame(height:300).background(Design.muted,in:RoundedRectangle(cornerRadius:12))
                        Toggle("Show trimmed result",isOn:$showResult).accessibilityIdentifier("trim-show-result")
                        HStack {
                            ForEach([1,2,5],id:\.self) { percent in
                                Button("\(percent)% all sides") { let v = Double(percent)/100; edges = PageTrim(top:v,right:v,bottom:v,left:v) }
                                    .buttonStyle(.bordered).accessibilityIdentifier("trim-preset-\(percent)")
                            }
                        }
                        ForEach(Edge.allCases,id:\.self) { edge in
                            VStack(spacing:4) {
                                HStack { Text(edge.rawValue); Spacer(); Text(String(format:"%.1f%%",edges[keyPath:edge.key]*100)).foregroundStyle(.secondary).monospacedDigit().accessibilityIdentifier("trim-value-"+edge.rawValue.lowercased()) }
                                Slider(value:Binding(get:{ edges[keyPath:edge.key] },set:{ edges[keyPath:edge.key] = $0 }),in:0...0.44,step:0.001)
                                    .accessibilityLabel(edge.rawValue+" trim").accessibilityIdentifier("trim-"+edge.rawValue.lowercased())
                            }
                        }
                        Button("Reset margins") { edges = .zero }.accessibilityIdentifier("trim-reset")
                        Text("Trimming keeps your original. To export without added white space, choose Save options → Paper: Original and Margins: None.").font(.caption).foregroundStyle(.secondary)
                        if page.sourcePDF != nil { Text("PDF text stays selectable. Interactive forms are flattened in the trimmed output.").font(.caption).foregroundStyle(.secondary) }
                        if !(page.annotations ?? []).isEmpty { Text("Review the positions of existing annotations after trimming.").font(.caption).foregroundStyle(.secondary) }
                    } else if let problem { Text(problem).foregroundStyle(.red) }
                    else { ProgressView("Preparing page…").frame(maxWidth:.infinity,minHeight:300) }
                }.padding(20)
            }.navigationTitle("Trim margins").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("trim-cancel") }
                    ToolbarItem(placement:.confirmationAction) { Button("Apply") { apply(edges); dismiss() }.disabled(image == nil || !edges.valid).accessibilityIdentifier("trim-apply") }
                }
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
                    Rectangle().stroke(Design.blue,lineWidth:2).frame(width:rect.width,height:rect.height).offset(x:rect.minX,y:rect.minY)
                }.frame(width:size.width,height:size.height).position(x:g.size.width/2,y:g.size.height/2)
                    .accessibilityLabel("Page with selected margins")
            }
        }
    }
}
