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
  private func icon(_ kind: AnnotationKind) -> String {
    switch kind {
    case .signature: return "signature"
    case .text: return "textformat"
    case .pen: return "pencil.tip"
    case .highlight: return "highlighter"
    }
  }
  private let colors: [(String, Color)] = [("black", .black), ("blue", TK.blue), ("red", TK.red), ("yellow", TK.yellow)]
  var body: some View {
    NavigationStack {
      ToolPage(title: "Sign & annotate", subtitle: nil) {
        if let doc = document {
          if doc.pages.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 8) {
                ForEach(doc.pages.indices, id: \.self) { i in Button("Page \(i+1)") { index = i }.buttonStyle(ChipStyle(selected: index == i)) }
              }
            }
          }
          Group {
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
              ProgressView().frame(height: 300)
            }
          }
          .frame(maxHeight: 360)
          .padding(12).frame(maxWidth: .infinity)
          .background(TK.grey100, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
          // Tools: one row of chips; Pro tools show a crown.
          ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(AnnotationKind.allCases, id: \.self) { kind in
              Button {
                if allowed(kind) { mode = kind } else { paywall = true }
              } label: {
                Label(kind.rawValue, systemImage: allowed(kind) ? icon(kind) : "crown.fill").labelStyle(.titleAndIcon)
              }
              .buttonStyle(ChipStyle(selected: mode == kind))
              .fixedSize()
              .accessibilityLabel(kind.rawValue)
            }
          }
          }
          HStack(spacing: 8) {
            if mode == .text {
              Button {
                remember()
                let item = PageAnnotation(kind: .text, text: "Your text")
                setMarks(marks + [item])
                selected = item.id
              } label: { Label("Add text box", systemImage: "plus") }.buttonStyle(ChipStyle(selected: false))
            }
            if mode == .signature { Button { signature = true } label: { Label("Add signature", systemImage: "plus") }.buttonStyle(ChipStyle(selected: false)) }
            if mode == .pen || mode == .highlight { Text("Draw on the page").font(.system(size: 15)).foregroundStyle(TK.grey600) }
            Spacer(minLength: 0)
            Button {
              if let old = history.popLast() { setMarks(old); selected = nil }
            } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.buttonStyle(ChipStyle(selected: false)).disabled(history.isEmpty)
          }
          if !subscription.isPro {
            Text("Signatures are free. Text, pen and highlight are Pro.").font(.system(size: 13)).foregroundStyle(TK.grey500)
              .accessibilityIdentifier("annotate-free-limit")
          }
          if let id = selected, let item = marks.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
              HStack {
                Text(item.kind.rawValue).font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900)
                Spacer()
                Button(role: .destructive) {
                  remember(); setMarks(marks.filter { $0.id != id }); selected = nil
                } label: { Label("Remove", systemImage: "trash") }.buttonStyle(ChipStyle(selected: false))
              }
              if item.kind == .text {
                TextField("Text", text: field(id, \.text, default: ""), axis: .vertical)
                  .font(.system(size: 17)).padding(.horizontal, 14).padding(.vertical, 12)
                  .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                  .accessibilityIdentifier("annotation-text")
              }
              HStack(spacing: 12) {
                ForEach(colors, id: \.0) { name, color in
                  Button { field(id, \.color, default: "black").wrappedValue = name } label: {
                    Circle().fill(color).frame(width: 30, height: 30)
                      .overlay(Circle().strokeBorder(item.color == name ? TK.blue : TK.grey200, lineWidth: item.color == name ? 3 : 1).padding(-4))
                  }.accessibilityLabel(name.capitalized).accessibilityAddTraits(item.color == name ? .isSelected : [])
                }
              }
              ToolSlider(title: item.kind == .text ? "Text size" : "Stroke", value: field(id, \.lineWidth, default: 2), range: 1...8, format: { String(format: "%.0f", $0) })
              if item.kind == .signature || item.kind == .text {
                ToolSlider(title: "Width", value: field(id, \.width, default: 0.4), range: 0.1...max(0.1, 1 - item.x))
                ToolSlider(title: "Height", value: field(id, \.height, default: 0.12), range: 0.05...max(0.05, 1 - item.y))
                Text("Drag on the page to move it.").font(.system(size: 13)).foregroundStyle(TK.grey500)
              }
            }
            .padding(16).background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
          }
          if let error {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: "exclamationmark.circle.fill").foregroundStyle(TK.red)
              Text(error).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800)
              Spacer(minLength: 0)
            }.padding(16).background(TK.grey100, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
          Text("Marks don't securely redact text. PDF forms are flattened; the original is kept.").font(.system(size: 13)).foregroundStyle(TK.grey500)
        }
      } actions: {
        Button("Save") { save() }.buttonStyle(CTAButtonStyle()).disabled(busy || preview == nil)
      }
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.disabled(busy) }
        }
        .overlay { if busy { BusyOverlay(text: "Saving annotations…") } }
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
  private var empty: Bool { strokes.allSatisfy { $0.isEmpty } && photoData == nil }
  var body: some View {
    NavigationStack {
      ToolPage(title: "Draw your signature", subtitle: "A handwritten signature, not a certified digital one.") {
        GeometryReader { g in
          Canvas { context, size in
            if let data = photoData, let image = UIImage(data: data) {
              context.draw(Image(uiImage: image), in: CGRect(origin: .zero, size: size))
            }
            for stroke in strokes {
              var path = Path()
              for (i, p) in stroke.enumerated() {
                if i == 0 { path.move(to: CGPoint(x: p.x * size.width, y: p.y * size.height)) }
                else { path.addLine(to: CGPoint(x: p.x * size.width, y: p.y * size.height)) }
              }
              context.stroke(path, with: .color(.black), lineWidth: 2.5)
            }
          }
          .contentShape(Rectangle()).gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
              photoData = nil
              if !active { strokes.append([]); active = true }
              strokes[strokes.count - 1].append(
                .init(x: min(1, max(0, value.location.x / g.size.width)), y: min(1, max(0, value.location.y / g.size.height))))
            }.onEnded { _ in active = false })
        }
        .frame(height: 190)
        .background(TK.grey50, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(TK.grey300, style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
        .overlay { if empty { Text("Sign here").font(.system(size: 17)).foregroundStyle(TK.grey400).allowsHitTesting(false) } }
        HStack(spacing: 8) {
          Button { strokes = []; photoData = nil } label: { Label("Clear", systemImage: "eraser") }.buttonStyle(ChipStyle(selected: false)).disabled(empty)
          PhotosPicker(selection: $photo, matching: .images) { Label("Import", systemImage: "photo") }.buttonStyle(ChipStyle(selected: false))
          Button { saveReusable.toggle() } label: { Label("Keep for next time", systemImage: saveReusable ? "checkmark" : "bookmark") }
            .buttonStyle(ChipStyle(selected: saveReusable))
            .onChange(of: saveReusable) { _, on in if on && !canSaveMore { saveReusable = false; paywall = true } }
        }
        if !saved.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Saved signatures")
            ForEach(saved) { item in
              let number = (saved.firstIndex(where: { $0.id == item.id }) ?? 0) + 1
              HStack {
                Button { var copy = item; copy.id = UUID(); apply(copy); dismiss() } label: {
                  ChoiceRow(symbol: "signature", title: "Signature \(number)", detail: "Tap to use")
                }.buttonStyle(.plain)
                Button(role: .destructive) { saved.removeAll { $0.id == item.id }; persist() } label: { Image(systemName: "trash") }
                  .buttonStyle(ChipStyle(selected: false)).accessibilityLabel("Delete signature \(number)")
              }
            }
          }
        }
        if !subscription.isPro { Text("Free: 1 saved signature. Pro: unlimited.").font(.system(size: 13)).foregroundStyle(TK.grey500) }
        if let error { Text(error).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.red) }
      } actions: {
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
        }.buttonStyle(CTAButtonStyle()).disabled(empty)
      }
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
      .sheet(isPresented: $paywall) { PaywallView() }
      .onAppear { saved = store.manifest.signatures ?? [] }
      .onChange(of: photo) { _, item in
        Task {
          if let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) {
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
