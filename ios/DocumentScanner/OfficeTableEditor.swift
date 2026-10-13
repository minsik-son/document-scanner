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


/// Review of a recognized page for Word: text lines stay editable fields and
/// tables are drawn as tables (merged cells, colours) whose cells are tapped
/// to correct them.
struct WordLayoutReview: View {
    @Binding var page: PageLayout
    @State private var editing: CellRef?
    private struct CellRef: Identifiable { let item: Int; let cell: Int; var id: String { "\(item):\(cell)" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(page.items.indices, id: \.self) { index in
                switch page.items[index] {
                case .paragraph(let p):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(p.lines.indices, id: \.self) { n in
                            if !p.lines[n].segments.isEmpty {
                                TextField("Text", text: lineText(index, n), axis: .vertical)
                                    .font(.body).accessibilityIdentifier("word-line-\(index)-\(n)")
                            }
                        }
                    }
                case .table(let t):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Table · \(t.rowCount) rows · \(t.columnCount) columns").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        WordTableGrid(table: t, pointsPerPixel: page.pointsPerPixel) { cell in editing = CellRef(item: index, cell: cell) }
                    }
                    .accessibilityIdentifier("word-table-\(index)")
                }
            }
        }
        .sheet(item: $editing) { ref in
            if case .table(let t) = page.items[ref.item], t.cells.indices.contains(ref.cell) {
                WordCellEditor(value: t.cells[ref.cell].text, title: "Row \(t.cells[ref.cell].row + 1), column \(t.cells[ref.cell].column + 1)") { value in
                    setCell(ref, value)
                }
            }
        }
    }
    private func lineText(_ index: Int, _ n: Int) -> Binding<String> {
        Binding(get: {
            guard case .paragraph(let p) = page.items[index], p.lines.indices.contains(n) else { return "" }
            return p.lines[n].text.replacingOccurrences(of: "\t", with: "    ")
        }, set: { value in
            guard case .paragraph(let p) = page.items[index], p.lines.indices.contains(n) else { return }
            // Spacing typed in place of a tab stop becomes the tab again.
            let restored = p.lines[n].segments.count > 1 ? value.replacingOccurrences(of: "    ", with: "\t") : value
            let text = restored.replacingOccurrences(of: "\n", with: " ")
            guard text != p.lines[n].text else { return }
            LayoutText.replace(&page, slot: .line(item: index, line: n), with: [text])
        })
    }
    private func setCell(_ ref: CellRef, _ value: String) {
        guard case .table(var t) = page.items[ref.item], t.cells.indices.contains(ref.cell) else { return }
        let like = t.cells[ref.cell].lines.flatMap { $0 }
        t.cells[ref.cell].lines = value.components(separatedBy: "\n").compactMap { line in
            let runs = LayoutText.styled(line, like: like.isEmpty ? [LayoutRun(text: "")] : like)
            return runs.isEmpty ? nil : runs
        }
        page.items[ref.item] = .table(t)
    }
}

/// A recognized table drawn at its printed proportions.
struct WordTableGrid: View {
    let table: LayoutTable
    let pointsPerPixel: Double
    let onTap: (Int) -> Void

    private var bodySize: Double {
        let sizes = table.cells.filter { !$0.lines.isEmpty }.map(\.fontSize).sorted()
        return sizes.isEmpty ? 10 : sizes[sizes.count / 2]
    }
    /// Screen points per page pixel: body text shows at a readable 13 pt.
    private var scale: Double {
        let pixelsPerFontPoint = 1 / max(0.01, pointsPerPixel)
        return min(1.4, max(0.2, 13 / (bodySize * pixelsPerFontPoint)))
    }
    var body: some View {
        let s = scale, box = table.box
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                ForEach(table.cells.indices, id: \.self) { i in
                    let cell = table.cells[i]
                    let frame = CGRect(x: (cell.box.x0 - box.x0) * s, y: (cell.box.y0 - box.y0) * s, width: cell.box.width * s, height: cell.box.height * s)
                    Button { onTap(i) } label: {
                        Text(cell.text.isEmpty ? " " : cell.text)
                            .font(.system(size: max(9, min(18, 13 * cell.fontSize / bodySize)),
                                          weight: cell.lines.first?.contains(where: \.bold) == true ? .semibold : .regular))
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(cell.alignment == .center ? .center : cell.alignment == .right ? .trailing : .leading)
                            .lineLimit(cell.rowSpan > 1 ? 4 : 2).minimumScaleFactor(0.5)
                            .padding(.horizontal, 4)
                            .frame(width: frame.width, height: frame.height,
                                   alignment: cell.alignment == .center ? .center : cell.alignment == .right ? .trailing : .leading)
                            .background(cell.fill.map { Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255) } ?? Color(uiColor: .systemBackground))
                            .overlay(Rectangle().strokeBorder(Color.primary.opacity(table.ruled ? 0.55 : 0.15), lineWidth: 0.75))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityLabel("Row \(cell.row + 1), column \(cell.column + 1), \(cell.text.isEmpty ? "empty" : cell.text)")
                    .accessibilityHint("Double-tap to correct this cell")
                    .accessibilityIdentifier("word-cell-\(cell.row)-\(cell.column)")
                }
            }
            .frame(width: box.width * s, height: box.height * s, alignment: .topLeading)
            .environment(\.colorScheme, .light)
        }
        .scrollIndicators(.visible)
    }
}

private struct WordCellEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var value: String
    let title: String
    let onSave: (String) -> Void
    var body: some View {
        NavigationStack {
            ToolPage(title: title, subtitle: "The cell keeps its size, colour and merged area in Word.") {
                TextEditor(text: $value).font(.system(size: 17)).scrollContentBackground(.hidden)
                    .padding(12).frame(minHeight: 140)
                    .background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("word-cell-value")
            } actions: {
                Button("Done") { onSave(value); dismiss() }.buttonStyle(CTAButtonStyle()).accessibilityIdentifier("word-cell-save")
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

/// Corrections on the page as it will print. It opens with the whole form
/// fitted to the screen so the layout can be checked at a glance; pinch or
/// double-tap to zoom in, then tap a cell to correct it.
struct OfficePageEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var tables: [OfficeTable]
    let layout: PageLayout
    let pageIndex: Int
    @State private var image: UIImage?
    @State private var editing: OfficeCellTarget?
    @State private var highlight: LBox?
    @State private var fade: Task<Void, Never>?

    private var page: PageLayout { layout.corrected(by: tables, page: pageIndex) }

    /// Every editable cell on the page and the table it belongs to.
    private var targets: [OfficeCellTarget] {
        var result: [OfficeCellTarget] = []
        for (item, entry) in page.items.enumerated() {
            guard case .table(let grid) = entry,
                  let t = tables.firstIndex(where: { $0.layoutPage == pageIndex && $0.layoutItem == item }) else { continue }
            for cell in grid.cells where tables[t].cells.indices.contains(cell.row) && tables[t].cells[cell.row].indices.contains(cell.column) {
                result.append(OfficeCellTarget(table: t, row: cell.row, column: cell.column, box: cell.box, text: tables[t].cells[cell.row][cell.column]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    OfficeCellCanvas(image: image, pageWidth: CGFloat(max(1, page.width)), targets: targets, highlight: highlight) { target in
                        fade?.cancel(); highlight = target.box; editing = target
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(TK.grey100)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    Text(L("Tap a cell to correct it. Merged cells, fills and fonts are kept."))
                    Text(L("Pinch to zoom · Double-tap to zoom or reset"))
                }
                .font(.system(size: 13)).foregroundStyle(TK.grey600).multilineTextAlignment(.center)
                .padding(12).frame(maxWidth: .infinity).background(.bar)
            }
            .navigationTitle(L("Correct cells"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }.accessibilityIdentifier("office-page-editor-done")
                }
            }
        }
        // Redrawn after each correction; the zoom and position stay where they were.
        .task(id: page) { image = OfficePagePreview.image(page, width: 2600) }
        .sheet(item: $editing, onDismiss: clearHighlight) { target in
            OfficeCellEditor(value: tables[target.table].cells[target.row][target.column],
                             title: "\(OfficeExport.column(target.column))\(target.row + 1)") { value in
                tables[target.table].cells[target.row][target.column] = value
            }
        }
    }

    /// The corrected cell stays marked for a moment after the sheet closes.
    private func clearHighlight() {
        fade?.cancel()
        fade = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation { highlight = nil }
        }
    }
}

struct OfficeCellTarget: Identifiable, Equatable {
    let table: Int, row: Int, column: Int
    let box: LBox
    let text: String
    var id: String { "\(table):\(row):\(column)" }
}

/// The rendered page in a zooming scroll view; a single tap picks the cell under the finger.
private struct OfficeCellCanvas: UIViewRepresentable {
    let image: UIImage
    /// Width of the layout in pixels (cell boxes are in layout pixels).
    let pageWidth: CGFloat
    let targets: [OfficeCellTarget]
    let highlight: LBox?
    let onTap: (OfficeCellTarget) -> Void

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
    private var targets: [OfficeCellTarget] = []
    private var onTap: ((OfficeCellTarget) -> Void)?
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

    func update(image: UIImage, scale: CGFloat, targets: [OfficeCellTarget], highlight: LBox?, onTap: @escaping (OfficeCellTarget) -> Void) {
        if pageView.image !== image { pageView.image = image }
        self.scale = scale; self.onTap = onTap
        if targets != self.targets { self.targets = targets; cellElements = [] }
        if let box = highlight {
            marker.frame = rect(box)
            marker.isHidden = false; marker.alpha = 1
        } else if !marker.isHidden {
            UIView.animate(withDuration: 0.25, animations: { self.marker.alpha = 0 }) { _ in self.marker.isHidden = true }
        }
        updateMarkerBorder()
    }

    private func rect(_ b: LBox) -> CGRect { CGRect(x: b.x0 * scale, y: b.y0 * scale, width: b.width * scale, height: b.height * scale) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if viewport != bounds.size {
            viewport = bounds.size
            // Start with the whole page in view.
            let inset: CGFloat = 16
            let fit = min((bounds.width - inset * 2) / pageView.bounds.width, (bounds.height - inset * 2) / pageView.bounds.height)
            minimumZoomScale = fit
            maximumZoomScale = fit * 8
            setZoomScale(fit, animated: false)
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

    private func target(at point: CGPoint) -> OfficeCellTarget? {
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
                    element.accessibilityLabel = "\(OfficeExport.column(target.column))\(target.row + 1), \(target.text)"
                    element.accessibilityTraits = .button
                    element.accessibilityIdentifier = target.table == 0 ? "excel-cell-\(target.row)-\(target.column)" : "excel-cell-\(target.table)-\(target.row)-\(target.column)"
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
