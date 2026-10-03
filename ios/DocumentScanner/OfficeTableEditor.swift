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
                            Text(OfficeExport.column(column)).font(.caption.bold()).frame(width:140,height:32).background(Design.softBlue)
                        }
                    }
                    ForEach(table.cells.indices,id:\.self) { row in
                        HStack(spacing:1) {
                            Text("\(row+1)").font(.caption).frame(width:34,height:52).background(Design.muted)
                            ForEach(table.cells[row].indices,id:\.self) { column in
                                Button { selected = CellSelection(row:row,column:column) } label: {
                                    Text(table.isCovered(row:row,column:column) ? "Merged" : table.cells[row][column])
                                        .font(.subheadline).lineLimit(2).frame(width:132,height:44,alignment:.leading).padding(4)
                                        .background(table.isCovered(row:row,column:column) ? Design.muted : Color(uiColor:.systemBackground))
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
            Form { TextEditor(text:$value).frame(minHeight:180).accessibilityIdentifier("excel-cell-value") }
                .navigationTitle("Edit \(title)").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("Done") { onSave(value);dismiss() }.accessibilityIdentifier("excel-cell-save") }
                }
        }
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
            Form {
                Section {
                    TextEditor(text: $value).frame(minHeight: 140).accessibilityIdentifier("word-cell-value")
                } footer: { Text("The cell keeps its size, colour and merged area in Word.") }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { onSave(value); dismiss() }.accessibilityIdentifier("word-cell-save") }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
