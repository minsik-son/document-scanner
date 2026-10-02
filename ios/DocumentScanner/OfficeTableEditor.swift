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
