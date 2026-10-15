import SwiftUI

struct OfficeTableEditor: View {
    @Binding var table: OfficeTable
    @State private var selected: CellSelection?
    private struct CellSelection: Identifiable {
        let row:Int; let column:Int
        var id:String { "\(row):\(column)" }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("\(table.cells.count) rows · \(table.columnCount) columns").font(.subheadline).foregroundStyle(.secondary)
            ScrollView([.horizontal,.vertical]) {
                LazyVStack(alignment:.leading,spacing:1) {
                    HStack(spacing:1) {
                        Text("").frame(width:34,height:32)
                        ForEach(0..<table.columnCount,id:\.self) { column in
                            Text(OfficeExport.column(column)).font(.caption.bold()).frame(width:140,height:32).background(TK.blueSoft)
                        }
                    }
                    ForEach(table.cells.indices,id:\.self) { row in
                        HStack(spacing:1) {
                            Text("\(row+1)").font(.caption).frame(width:34,height:52).background(TK.grey100)
                            ForEach(table.cells[row].indices,id:\.self) { column in
                                Button { selected = CellSelection(row:row,column:column) } label: {
                                    Text(table.isCovered(row:row,column:column) ? "Merged" : table.cells[row][column])
                                        .font(.subheadline).lineLimit(2).frame(width:132,height:44,alignment:.leading).padding(4)
                                        .background(table.isCovered(row:row,column:column) ? TK.grey100 : Color(uiColor:.systemBackground))
                                }.buttonStyle(.plain)
                                    .disabled(table.isCovered(row:row,column:column))
                                    .accessibilityLabel("\(OfficeExport.column(column))\(row+1), \(table.cells[row][column])")
                                    .accessibilityIdentifier("excel-cell-\(row)-\(column)")
                            }
                        }
                    }
                }.background(Color.gray.opacity(0.2))
            }.defaultScrollAnchor(.topLeading).frame(height:CGFloat(min(330,33+table.cells.count*53))).clipShape(RoundedRectangle(cornerRadius:10))
            HStack {
                Button("Add row") { table.cells.append(Array(repeating:"",count:table.columnCount)) }
                    .disabled(table.cells.count >= 1000 || (table.cells.count+1)*table.columnCount > 20000)
                Spacer()
                Button("Add column") { for row in table.cells.indices { table.cells[row].append("") } }
                    .disabled(table.columnCount >= 100 || table.cells.count*(table.columnCount+1) > 20000)
            }.font(.subheadline).buttonStyle(.borderless)
            if !table.merges.isEmpty {
                Button("Unmerge cells") { table.merges = [] }.font(.subheadline)
                Text("Merged values appear in the top-left cell.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(item:$selected) { selection in
            OfficeCellEditor(value:table.cells[selection.row][selection.column],title:"\(OfficeExport.column(selection.column))\(selection.row+1)") { value in
                table.cells[selection.row][selection.column] = value
            }
        }
    }
}

private struct OfficeCellEditor:View {
    @Environment(\.dismiss) private var dismiss
    @State var value:String
    let title:String
    let onSave:(String)->Void
    var body:some View {
        NavigationStack {
            ToolPage(title: "Edit \(title)") {
                TextEditor(text:$value).font(.system(size: 17)).scrollContentBackground(.hidden)
                    .padding(12).frame(minHeight:180)
                    .background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("excel-cell-value")
            } actions: {
                Button("Done") { onSave(value);dismiss() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("excel-cell-save")
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}


extension PageLayout {
    /// The page with every correction made in `tables` written into its cells.
    func corrected(by tables: [OfficeTable], page index: Int) -> PageLayout {
        var page = self
        for table in tables where table.layoutPage == index {
            guard let i = table.layoutItem, page.items.indices.contains(i), case .table(var layout) = page.items[i] else { continue }
            layout.apply(table); page.items[i] = .table(layout)
        }
        return page
    }
}

/// One correctable spot on a page: a table cell or a line of text.
struct OfficeEditTarget: Identifiable, Equatable {
    let id: String
    let box: LBox
    let text: String
    /// Shown above the text field ("Edit B3", "Edit Row 2, column 1").
    let title: String
    /// Accessibility identifier of the spot on the page (UI tests, VoiceOver).
    let identifier: String
    /// Lines of running text stay one line; cells may hold several.
    var singleLine = false
}

/// Corrections on the page as it will print. It opens with the whole page
/// fitted to the screen so the layout can be checked at a glance; pinch or
/// double-tap to zoom in, then tap a cell or line to correct it in a panel
/// under the page (a panel, not a sheet, so the page stays in view).
struct OfficePageCorrector: View {
    @Environment(\.dismiss) private var dismiss
    let page: PageLayout
    let targets: [OfficeEditTarget]
    var title = "Correct cells"
    var hint = "Tap a cell to correct it. Merged cells, fills and fonts are kept."
    /// Prefix of the panel's identifiers ("excel" → excel-cell-value).
    var prefix = "excel"
    let save: (OfficeEditTarget, String) -> Void
    /// Puts the page back as it was when the editor opened (Cancel → leave without saving).
    var discard: () -> Void = {}
    @State private var changed = false
    @State private var confirmCancel = false
    @State private var image: UIImage?
    @State private var editing: OfficeEditTarget?
    @State private var draft = ""
    @State private var highlight: LBox?
    @State private var fade: Task<Void, Never>?
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    OfficeCellCanvas(image: image, pageWidth: CGFloat(max(1, page.width)), targets: targets, highlight: highlight, onTap: open)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(TK.grey100)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let editing { panel(editing) } else { hintBar }
            }
            .navigationTitle(L(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { cancel() }.accessibilityIdentifier("office-page-editor-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { commit(); dismiss() }.fontWeight(.semibold).accessibilityIdentifier("office-page-editor-done")
                }
            }
            .alert(L("Leave without saving?"), isPresented: $confirmCancel) {
                Button(L("Leave without saving"), role: .destructive) { discard(); dismiss() }
                Button(L("Keep editing"), role: .cancel) {}
            } message: { Text(L("Corrections made here won't be saved. To keep them, tap Done.")) }
        }
        .interactiveDismissDisabled(changed)
        // Redrawn after each correction; the zoom and position stay where they were.
        .task(id: page) { image = OfficePagePreview.image(page, width: 2600) }
    }

    private var hintBar: some View {
        VStack(spacing: 4) {
            Text(L(hint))
            Text(L("Pinch to zoom · Double-tap to zoom or reset"))
        }
        .font(.system(size: 13)).foregroundStyle(TK.grey600).multilineTextAlignment(.center)
        .padding(12).frame(maxWidth: .infinity).background(.bar)
    }

    private func panel(_ target: OfficeEditTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(format: L("Edit %@"), target.title))
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(TK.grey900).lineLimit(1)
                Spacer()
                Button(L("Close")) { close() }.font(.system(size: 16)).accessibilityIdentifier("\(prefix)-cell-close")
            }
            TextEditor(text: $draft).font(.system(size: 17)).scrollContentBackground(.hidden)
                .focused($typing)
                .padding(8).frame(height: target.singleLine ? 64 : 96)
                .background(TK.grey50, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityIdentifier("\(prefix)-cell-value")
            Button(L("Done")) { commit(); close() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("\(prefix)-cell-save")
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
        .background(TK.paper)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        .shadow(color: .black.opacity(0.08), radius: 12, y: -2)
    }

    /// Leaves without saving: asks first when something was corrected.
    private func cancel() {
        typing = false
        let pending = editing.map { t in (t.singleLine ? draft.replacingOccurrences(of: "\n", with: " ") : draft) != t.text } ?? false
        if changed || pending { confirmCancel = true } else { dismiss() }
    }
    private func open(_ target: OfficeEditTarget) {
        commit()
        fade?.cancel()
        highlight = target.box
        draft = target.text
        editing = target
        typing = true
    }

    /// Writes the panel's text into its spot (also when another spot is tapped).
    private func commit() {
        guard let target = editing else { return }
        let value = target.singleLine ? draft.replacingOccurrences(of: "\n", with: " ") : draft
        if value != target.text { save(target, value); changed = true }
    }

    /// The corrected spot stays marked for a moment after the panel closes.
    private func close() {
        typing = false
        editing = nil
        fade?.cancel()
        fade = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation { highlight = nil }
        }
    }
}

/// Excel: corrections go into the recognized tables; the page shows them.
struct OfficePageEditor: View {
    @Binding var tables: [OfficeTable]
    let layout: PageLayout
    let pageIndex: Int

    private var page: PageLayout { layout.corrected(by: tables, page: pageIndex) }
    private struct Ref { let table: Int, row: Int, column: Int }
    private var refs: [String: Ref] {
        var result: [String: Ref] = [:]
        for (item, entry) in page.items.enumerated() {
            guard case .table(let grid) = entry,
                  let t = tables.firstIndex(where: { $0.layoutPage == pageIndex && $0.layoutItem == item }) else { continue }
            for cell in grid.cells { result["\(t):\(cell.row):\(cell.column)"] = Ref(table: t, row: cell.row, column: cell.column) }
        }
        return result
    }
    private var targets: [OfficeEditTarget] {
        var result: [OfficeEditTarget] = []
        for (item, entry) in page.items.enumerated() {
            guard case .table(let grid) = entry,
                  let t = tables.firstIndex(where: { $0.layoutPage == pageIndex && $0.layoutItem == item }) else { continue }
            for cell in grid.cells where tables[t].cells.indices.contains(cell.row) && tables[t].cells[cell.row].indices.contains(cell.column) {
                let name = "\(OfficeExport.column(cell.column))\(cell.row + 1)"
                result.append(OfficeEditTarget(id: "\(t):\(cell.row):\(cell.column)", box: cell.box, text: tables[t].cells[cell.row][cell.column],
                                               title: name, identifier: t == 0 ? "excel-cell-\(cell.row)-\(cell.column)" : "excel-cell-\(t)-\(cell.row)-\(cell.column)"))
            }
        }
        return result
    }

    @State private var original: [OfficeTable]?
    var body: some View {
        OfficePageCorrector(page: page, targets: targets, save: { target, value in
            guard let ref = refs[target.id] else { return }
            tables[ref.table].cells[ref.row][ref.column] = value
        }, discard: { if let original { tables = original } })
        .onAppear { if original == nil { original = tables } }
    }
}

/// Word: lines of text and table cells are corrected in place on the page.
struct WordPageEditor: View {
    @Binding var page: PageLayout

    private var targets: [OfficeEditTarget] {
        var result: [OfficeEditTarget] = []
        for (index, item) in page.items.enumerated() {
            switch item {
            case .paragraph(let p):
                for (n, line) in p.lines.enumerated() where !line.segments.isEmpty {
                    result.append(OfficeEditTarget(id: "line:\(index):\(n)", box: line.box, text: line.text.replacingOccurrences(of: "\t", with: "    "),
                                                   title: L("Text"), identifier: "word-line-\(index)-\(n)", singleLine: true))
                }
            case .table(let t):
                for (i, cell) in t.cells.enumerated() {
                    result.append(OfficeEditTarget(id: "cell:\(index):\(i)", box: cell.box, text: cell.text,
                                                   title: String(format: L("Row %lld, column %lld"), cell.row + 1, cell.column + 1),
                                                   identifier: "word-cell-\(cell.row)-\(cell.column)"))
                }
            }
        }
        return result
    }

    @State private var original: PageLayout?
    var body: some View {
        OfficePageCorrector(page: page, targets: targets, title: "Correct text",
                            hint: "Tap a cell to correct it. Tables stay tables in Word.", prefix: "word", save: { target, value in
            let parts = target.id.split(separator: ":")
            guard parts.count == 3, let index = Int(parts[1]), let n = Int(parts[2]), page.items.indices.contains(index) else { return }
            if parts[0] == "line" { setLine(index, n, value) } else { setCell(index, n, value) }
        }, discard: { if let original { page = original } })
        .onAppear { if original == nil { original = page } }
    }
    private func setLine(_ index: Int, _ n: Int, _ value: String) {
        guard case .paragraph(let p) = page.items[index], p.lines.indices.contains(n) else { return }
        // Spacing typed in place of a tab stop becomes the tab again.
        let restored = p.lines[n].segments.count > 1 ? value.replacingOccurrences(of: "    ", with: "\t") : value
        guard restored != p.lines[n].text else { return }
        LayoutText.replace(&page, slot: .line(item: index, line: n), with: [restored])
    }
    private func setCell(_ index: Int, _ i: Int, _ value: String) {
        guard case .table(var t) = page.items[index], t.cells.indices.contains(i) else { return }
        let like = t.cells[i].lines.flatMap { $0 }
        t.cells[i].lines = value.components(separatedBy: "\n").compactMap { line in
            let runs = LayoutText.styled(line, like: like.isEmpty ? [LayoutRun(text: "")] : like)
            return runs.isEmpty ? nil : runs
        }
        page.items[index] = .table(t)
    }
}

/// The rendered page in a zooming scroll view; a single tap picks the cell under the finger.
private struct OfficeCellCanvas: UIViewRepresentable {
    let image: UIImage
    /// Width of the layout in pixels (cell boxes are in layout pixels).
    let pageWidth: CGFloat
    let targets: [OfficeEditTarget]
    let highlight: LBox?
    let onTap: (OfficeEditTarget) -> Void

    func makeUIView(context: Context) -> OfficeCellScrollView { OfficeCellScrollView(image: image) }
    func updateUIView(_ view: OfficeCellScrollView, context: Context) {
        view.update(image: image, scale: image.size.width / pageWidth, targets: targets, highlight: highlight, onTap: onTap)
    }
}

final class OfficeCellScrollView: UIScrollView, UIScrollViewDelegate {
    private let pageView = UIImageView()
    private let marker = UIView()
    private var viewport = CGSize.zero
    private var scale: CGFloat = 1
    private var targets: [OfficeEditTarget] = []
    private var onTap: ((OfficeEditTarget) -> Void)?
    private var cellElements: [UIAccessibilityElement] = []

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        pageView.image = image
        pageView.frame = CGRect(origin: .zero, size: image.size)
        pageView.layer.borderColor = UIColor.systemGray4.cgColor
        addSubview(pageView)
        contentSize = image.size
        marker.isUserInteractionEnabled = false
        marker.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        marker.layer.borderColor = UIColor.systemBlue.cgColor
        marker.isHidden = true
        pageView.addSubview(marker)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(pick(_:)))
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        accessibilityIdentifier = "office-page-editor"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(image: UIImage, scale: CGFloat, targets: [OfficeEditTarget], highlight: LBox?, onTap: @escaping (OfficeEditTarget) -> Void) {
        if pageView.image !== image { pageView.image = image }
        self.scale = scale; self.onTap = onTap
        if targets != self.targets { self.targets = targets; cellElements = [] }
        if let box = highlight {
            let moved = marker.isHidden || marker.frame != rect(box)
            marker.frame = rect(box)
            marker.isHidden = false; marker.alpha = 1
            if moved { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.revealMarker() } }
        } else if !marker.isHidden {
            UIView.animate(withDuration: 0.25, animations: { self.marker.alpha = 0 }) { _ in self.marker.isHidden = true }
        }
        updateMarkerBorder()
    }

    /// Keeps the cell being corrected in view above the panel and keyboard.
    private func revealMarker() {
        guard !marker.isHidden, zoomScale > minimumZoomScale * 1.01 else { return }
        scrollRectToVisible(pageView.convert(marker.frame.insetBy(dx: -24, dy: -24), to: self), animated: true)
    }

    private func rect(_ b: LBox) -> CGRect { CGRect(x: b.x0 * scale, y: b.y0 * scale, width: b.width * scale, height: b.height * scale) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if viewport != bounds.size {
            let first = viewport.width != bounds.width
            viewport = bounds.size
            // Start with the whole page in view. When only the height changes
            // (the keyboard or the cell panel) the zoom stays where it is.
            let inset: CGFloat = 16
            let fit = min((bounds.width - inset * 2) / pageView.bounds.width, (bounds.height - inset * 2) / pageView.bounds.height)
            minimumZoomScale = fit
            maximumZoomScale = max(fit * 8, zoomScale)
            if first || zoomScale < fit { setZoomScale(fit, animated: false) }
            revealMarker()
        }
        centerPage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPage(); updateMarkerBorder() }

    private func centerPage() {
        let inset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
        if contentInset != inset { contentInset = inset }
    }
    /// Lines stay the same width on screen at every zoom.
    private func updateMarkerBorder() {
        let z = max(zoomScale, 0.0001)
        marker.layer.borderWidth = 2.5 / z
        pageView.layer.borderWidth = 1 / z
    }

    private func target(at point: CGPoint) -> OfficeEditTarget? {
        // Smallest box under the finger (a merged cell never hides the cells beside it).
        targets.filter { rect($0.box).contains(point) }.min { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
    }

    @objc private func pick(_ gesture: UITapGestureRecognizer) {
        guard let target = target(at: gesture.location(in: pageView)) else { return }
        onTap?(target)
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.05 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let scale = minimumZoomScale * 3
            let point = gesture.location(in: pageView)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    // Each cell is its own accessibility element: VoiceOver reads and opens
    // cells, and UI tests reach them as excel-cell-<row>-<column>.
    override var accessibilityElements: [Any]? {
        get {
            if cellElements.count != targets.count {
                cellElements = targets.map { target in
                    let element = OfficeCellElement(accessibilityContainer: self)
                    element.activate = { [weak self] in self?.onTap?(target) }
                    element.accessibilityLabel = "\(target.title), \(target.text)"
                    element.accessibilityValue = target.text
                    element.accessibilityTraits = .button
                    element.accessibilityIdentifier = target.identifier
                    return element
                }
            }
            for (element, target) in zip(cellElements, targets) {
                element.accessibilityFrameInContainerSpace = convert(rect(target.box), from: pageView)
            }
            return cellElements
        }
        set { }
    }
}

private final class OfficeCellElement: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
}
