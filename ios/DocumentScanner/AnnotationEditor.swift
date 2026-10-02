import PDFKit
import PhotosUI
import SwiftUI

struct AnnotationEditor: View {
  @EnvironmentObject var store: LibraryStore
  @EnvironmentObject var subscription: SubscriptionStore
  @State private var paywall = false
  /// Free users can place signatures; text, pen and highlight are Pro.
  private func allowed(_ kind: AnnotationKind) -> Bool { kind == .signature || subscription.isPro }
  @Environment(\.dismiss) private var dismiss
  let documentID: UUID
  @State private var document: ScanDocument?
  @State private var index = 0
  @State private var preview: UIImage?
  @State private var previewPageSize = CGSize(width: 612, height: 792)
  @State private var selected: UUID?
  @State private var mode = AnnotationKind.text
  @State private var signature = false
  @State private var busy = false
  @State private var error: String?
  @State private var dragOrigin: CGPoint?
  @State private var drawing: UUID?
  @State private var history: [[PageAnnotation]] = []
  private var marks: [PageAnnotation] { document?.pages[index].annotations ?? [] }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          if let doc = document {
            Picker("Page", selection: $index) {
              ForEach(doc.pages.indices, id: \.self) { Text("Page \($0+1)").tag($0) }
            }
            if let preview {
              GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                  Image(uiImage: preview).resizable().scaledToFit()
                  Canvas { context, _ in
                    context.withCGContext { cg in
                      cg.saveGState()
                      cg.scaleBy(
                        x: size.width / previewPageSize.width,
                        y: size.height / previewPageSize.height)
                      DocumentPDF.draw(marks, size: previewPageSize, context: cg)
                      cg.restoreGState()
                    }
                  }
                  if let item = marks.first(where: { $0.id == selected }) {
                    Rectangle().stroke(.blue, style: StrokeStyle(lineWidth: 1, dash: [4]))
                      .frame(width: item.width * size.width, height: item.height * size.height)
                      .position(
                        x: (item.x + item.width / 2) * size.width,
                        y: (item.y + item.height / 2) * size.height)
                  }
                }.contentShape(Rectangle()).gesture(
                  DragGesture(minimumDistance: 0).onChanged { value in
                    if mode == .pen || mode == .highlight {
                      if drawing == nil {
                        remember()
                        var item = PageAnnotation(kind: mode)
                        item.x = 0
                        item.y = 0
                        item.width = 1
                        item.height = 1
                        item.color = mode == .highlight ? "yellow" : "black"
                        item.strokes = [[]]
                        drawing = item.id
                        selected = item.id
                        setMarks(marks + [item])
                      }
                      guard let i = marks.firstIndex(where: { $0.id == drawing }) else { return }
                      var items = marks
                      items[i].strokes[0].append(
                        ScanPoint(
                          x: min(1, max(0, value.location.x / size.width)),
                          y: min(1, max(0, value.location.y / size.height))))
                      setMarks(items)
                    } else if let i = marks.firstIndex(where: { $0.id == selected }) {
                      if dragOrigin == nil {
                        remember()
                        dragOrigin = CGPoint(x: marks[i].x, y: marks[i].y)
                      }
                      var items = marks
                      items[i].x = min(
                        1 - items[i].width,
                        max(0, dragOrigin!.x + value.translation.width / size.width))
                      items[i].y = min(
                        1 - items[i].height,
                        max(0, dragOrigin!.y + value.translation.height / size.height))
                      setMarks(items)
                    }
                  }.onEnded { _ in
                    dragOrigin = nil
                    drawing = nil
                  })
              }.aspectRatio(preview.size.width / preview.size.height, contentMode: .fit)
            } else {
              ProgressView("Loading page…").frame(height: 260)
            }
            Picker("Tool", selection: $mode) {
              ForEach(AnnotationKind.allCases, id: \.self) { Text($0.rawValue) }
            }.pickerStyle(.segmented)
              .onChange(of: mode) { old, new in
                if !allowed(new) { mode = allowed(old) ? old : .signature; paywall = true }
              }
            if !subscription.isPro {
              Text("Signatures are free. Text, pen and highlight are Pro.").font(.caption)
                .foregroundStyle(.secondary).accessibilityIdentifier("annotate-free-limit")
            }
            if mode == .text {
              Button("Add text box") {
                remember()
                let item = PageAnnotation(kind: .text, text: "Your text")
                setMarks(marks + [item])
                selected = item.id
              }
            }
            if mode == .signature { Button("Add signature") { signature = true } }
            if mode == .pen || mode == .highlight {
              Text("Draw on the page. Each stroke remains editable.").font(.caption)
            }
            ForEach(marks) { item in
              Button {
                selected = item.id
                if allowed(item.kind) { mode = item.kind }
              } label: {
                HStack {
                  Text(item.kind.rawValue + (item.text.isEmpty ? "" : ": " + item.text)).lineLimit(
                    1)
                  Spacer()
                  if selected == item.id { Image(systemName: "checkmark") }
                }
              }.padding(8)
            }
            if let id = selected, let item = marks.first(where: { $0.id == id }) {
              if item.kind == .text {
                TextField("Text", text: field(id, \.text, default: ""), axis: .vertical)
                  .textFieldStyle(.roundedBorder).accessibilityIdentifier("annotation-text")
              }
              Picker("Color", selection: field(id, \.color, default: "black")) {
                ForEach(["black", "blue", "red", "yellow"], id: \.self) { Text($0.capitalized) }
              }
              Text("Size / stroke weight").font(.caption)
              Slider(value: field(id, \.lineWidth, default: 2), in: 1...8).accessibilityLabel(
                "Stroke weight")
              if item.kind == .signature || item.kind == .text {
                Text("Position and size").font(.caption)
                Slider(value: field(id, \.x, default: 0), in: 0...max(0.01, 1 - item.width))
                  .accessibilityLabel("Horizontal position")
                Slider(value: field(id, \.y, default: 0), in: 0...max(0.01, 1 - item.height))
                  .accessibilityLabel("Vertical position")
                Slider(value: field(id, \.width, default: 0.4), in: 0.1...max(0.1, 1 - item.x))
                  .accessibilityLabel("Annotation width")
                Slider(value: field(id, \.height, default: 0.12), in: 0.05...max(0.05, 1 - item.y))
                  .accessibilityLabel("Annotation height")
              }
              Button("Remove selected", role: .destructive) {
                remember()
                setMarks(marks.filter { $0.id != id })
                selected = nil
              }
            }
            HStack {
              Button("Undo") {
                if let old = history.popLast() {
                  setMarks(old)
                  selected = nil
                }
              }.disabled(history.isEmpty)
              Spacer()
              Text(
                "Annotations do not securely redact text. PDF forms are flattened in the output; the imported original is retained."
              ).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
          }
        }.padding(20)
      }.navigationTitle("Sign & annotate").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }.disabled(busy)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }.disabled(busy || preview == nil)
          }
        }.overlay {
          if busy { ProgressView("Saving annotations…").padding().background(.regularMaterial) }
        }
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $paywall) { PaywallView() }
        .sheet(isPresented: $signature) {
          SignatureEditor(root: store.root) { item in
            remember()
            setMarks(marks + [item])
            selected = item.id
          }
        }
        .task(id: index) {
          if document == nil {
            document = store.document(documentID)
            if !subscription.isPro { mode = .signature }
          }
          await loadPreview()
        }
    }
  }
  private func field<T>(_ id: UUID, _ key: WritableKeyPath<PageAnnotation, T>, default value: T)
    -> Binding<T>
  {
    Binding(
      get: { marks.first(where: { $0.id == id })?[keyPath: key] ?? value },
      set: { value in
        var items = marks
        if let i = items.firstIndex(where: { $0.id == id }) {
          items[i][keyPath: key] = value
          setMarks(items)
        }
      })
  }
  private func setMarks(_ values: [PageAnnotation]) { document?.pages[index].annotations = values }
  private func remember() {
    history.append(marks)
    if history.count > 30 { history.removeFirst() }
  }
  private func loadPreview() async {
    preview = nil
    history = []
    selected = nil
    guard var doc = document else { return }
    var page = doc.pages[index]
    page.annotations = nil
    doc.pages = [page]
    let root = store.root
    let snapshot = doc
    do {
      let result = try await Task.detached { () throws -> (UIImage, CGSize) in
        let data = try DocumentPDF.compose(snapshot, root: root)
        guard let page = PDFDocument(data: data)?.page(at: 0) else {
          throw ScannerError.message("Page unavailable.")
        }
        let bounds = page.bounds(for: .mediaBox)
        let size =
          page.rotation % 180 == 0
          ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        return (page.thumbnail(of: CGSize(width: 1200, height: 1600), for: .mediaBox), size)
      }.value
      guard !Task.isCancelled else { return }
      preview = result.0
      previewPageSize = result.1
    } catch { self.error = error.localizedDescription }
  }
  private func save() {
    guard let doc = document else { return }
    busy = true
    Task {
      do {
        let result = try await PDFExport.prepare(doc, root: store.root)
        try store.savePDF(result.data, document: result.document)
        dismiss()
      } catch { self.error = error.localizedDescription }
      busy = false
    }
  }
}
struct SignatureEditor: View {
  @EnvironmentObject var store: LibraryStore
  @EnvironmentObject var subscription: SubscriptionStore
  @State private var paywall = false
  static let freeSavedSignatures = 1
  private var canSaveMore: Bool { subscription.isPro || saved.count < Self.freeSavedSignatures }
  @Environment(\.dismiss) private var dismiss
  let root: URL
  let apply: (PageAnnotation) -> Void
  @State private var strokes: [[ScanPoint]] = []
  @State private var active = false
  @State private var photo: PhotosPickerItem?
  @State private var photoData: Data?
  @State private var saveReusable = false
  @State private var saved: [PageAnnotation] = []
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("Draw your signature") {
          GeometryReader { g in
            Canvas { context, size in
              if let data = photoData, let image = UIImage(data: data) {
                context.draw(Image(uiImage: image), in: CGRect(origin: .zero, size: size))
              }
              for stroke in strokes {
                var path = Path()
                for (i, p) in stroke.enumerated() {
                  if i == 0 {
                    path.move(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
                  } else {
                    path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
                  }
                }
                context.stroke(path, with: .color(.black), lineWidth: 2)
              }
            }.background(.white).contentShape(Rectangle()).gesture(
              DragGesture(minimumDistance: 0).onChanged { value in
                photoData = nil
                if !active {
                  strokes.append([])
                  active = true
                }
                strokes[strokes.count - 1].append(
                  .init(
                    x: min(1, max(0, value.location.x / g.size.width)),
                    y: min(1, max(0, value.location.y / g.size.height))))
              }.onEnded { _ in active = false })
          }.frame(height: 180)
          HStack {
            Button("Clear") {
              strokes = []
              photoData = nil
            }
            Spacer()
            PhotosPicker("Import signature", selection: $photo, matching: .images)
          }
          Text(
            "Imported images retain their background. Use a transparent signature image for a clean result. This is a handwritten signature, not a certified digital signature."
          ).font(.caption)
          Toggle("Save signature for reuse on this iPhone", isOn: $saveReusable)
            .onChange(of: saveReusable) { _, on in
              if on && !canSaveMore { saveReusable = false; paywall = true }
            }
          if !subscription.isPro {
            Text("Free: 1 saved signature. Pro: unlimited.").font(.caption).foregroundStyle(.secondary)
          }
        }
        if !saved.isEmpty {
          Section("Saved signatures") {
            ForEach(saved) { item in
              Button("Use signature \((saved.firstIndex(where: { $0.id == item.id }) ?? 0)+1)") {
                var copy = item
                copy.id = UUID()
                apply(copy)
                dismiss()
              }
            }
            .onDelete { indices in
              saved.remove(atOffsets: indices)
              persist()
            }
          }
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.navigationTitle("Signature").sheet(isPresented: $paywall) { PaywallView() }.toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Use signature") {
            var item = PageAnnotation(kind: .signature)
            item.strokes = strokes
            item.imageData = photoData
            if saveReusable {
              saved.append(item)
              guard persist() else { return }
            }
            apply(item)
            dismiss()
          }.disabled(strokes.allSatisfy { $0.isEmpty } && photoData == nil)
        }
      }.onAppear { saved = store.manifest.signatures ?? [] }
        .onChange(of: photo) { _, item in
          Task {
            if let data = try? await item?.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
            {
              photoData = image.pngData()
              strokes = []
            }
          }
        }
    }
  }
  @discardableResult private func persist() -> Bool {
    do {
      try store.saveSignatures(saved)
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }
}
