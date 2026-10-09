import PDFKit
import PhotosUI
import SwiftUI

struct AnnotationEditor: View {
  @EnvironmentObject var store: LibraryStore
  @EnvironmentObject var subscription: SubscriptionStore
  @State private var paywall = false
  /// Free users can place signatures; text, pen and highlight are Pro.
  private func allowed(_ kind: AnnotationKind) -> Bool { kind == .signature || pro }
  /// Pro, or a free try of Fill a form is open.
  private var pro: Bool { subscription.isPro || trialUnlocked }
  @Environment(\.dismiss) private var dismiss
  let documentID: UUID
  /// Opened from Fill a form: fill from the saved profile once the page is ready.
  var autoFill = false
  /// Opened inside a free try of Fill a form: text boxes are allowed.
  var trialUnlocked = false
  @State private var document: ScanDocument?
  @State private var profileEditor = false
  @State private var filling = false
  @State private var fillNote: String?
  @State private var autoFilled = false
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
                Label(L(kind.rawValue), systemImage: allowed(kind) ? icon(kind) : "crown.fill").labelStyle(.titleAndIcon)
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
            if mode == .text {
              Button { fillForm() } label: { Label("Fill from my info", systemImage: "wand.and.stars") }
                .buttonStyle(ChipStyle(selected: false)).disabled(filling || preview == nil).accessibilityIdentifier("form-fill")
            }
            if mode == .pen || mode == .highlight { Text("Draw on the page").font(.system(size: 15)).foregroundStyle(TK.grey600) }
            Spacer(minLength: 0)
            Button {
              if let old = history.popLast() { setMarks(old); selected = nil }
            } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.buttonStyle(ChipStyle(selected: false)).disabled(history.isEmpty)
          }
          if mode == .text {
            HStack(spacing: 8) {
              if let fillNote { Text(L(fillNote)).font(.system(size: 13)).foregroundStyle(TK.grey600) }
              Spacer(minLength: 0)
              Button("My info") { profileEditor = true }.font(.system(size: 14, weight: .semibold)).foregroundStyle(TK.blue)
            }
          }
          if !pro {
            Text("Signatures are free. Text, pen and highlight are Pro.").font(.system(size: 13)).foregroundStyle(TK.grey500)
              .accessibilityIdentifier("annotate-free-limit")
          }
          if let id = selected, let item = marks.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
              HStack {
                Text(L(item.kind.rawValue)).font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900)
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
              Text(L(error)).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.grey800)
              Spacer(minLength: 0)
            }.padding(16).background(TK.grey100, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
        }
      } actions: {
        // Above the button, never behind it.
        Text("Marks don't securely redact text. PDF forms are flattened; the original is kept.").font(.system(size: 12)).foregroundStyle(TK.grey500)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
          // Solid backing so scrolled controls never show through the note.
          .padding(.top, 10).background(TK.paper).padding(.top, -10)
          .accessibilityIdentifier("annotate-redact-note")
        Button("Save") { save() }.buttonStyle(CTAButtonStyle()).disabled(busy || preview == nil)
      }
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() }.disabled(busy) }
        }
        .overlay { if busy { BusyOverlay(text: "Saving annotations…") } }
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $paywall) { PaywallView() }
        .sheet(isPresented: $profileEditor, onDismiss: { if autoFill && !autoFilled && !FormProfile.load().isEmpty { autoFilled = true; fillForm() } }) { FormProfileEditor() }
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
            if !pro { mode = .signature }
          }
          await loadPreview()
          if autoFill && !autoFilled && preview != nil {
            if FormProfile.load().isEmpty { profileEditor = true } else { autoFilled = true; fillForm() }
          }
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
  /// Reads the page, finds labels such as Name, Email, Phone, Address, Date and
  /// Signature, and places the saved answers next to them as movable text boxes.
  private func fillForm() {
    guard pro else { paywall = true; return }
    let profile = FormProfile.load()
    guard !profile.isEmpty else { profileEditor = true; return }
    guard let preview else { return }
    mode = .text; filling = true; fillNote = "Reading the form…"
    let signatures = store.manifest.signatures ?? []
    Task {
      defer { filling = false }
      let blocks = (try? await Task.detached { try Imaging.recognize(preview) }.value) ?? []
      let spots = FormProfile.place(blocks: blocks, profile: profile, image: preview.cgImage)
      guard !spots.isEmpty else { fillNote = "No form labels found. Add text boxes by hand."; return }
      remember()
      var items = marks
      for spot in spots {
        if spot.key == "signature" {
          guard var sig = signatures.last else { continue }
          sig.id = UUID(); sig.x = spot.rect.minX; sig.y = max(0, spot.rect.minY - spot.rect.height * 0.6)
          sig.width = min(0.3, 1 - sig.x); sig.height = min(0.09, 1 - sig.y)
          items.append(sig)
        } else {
          var item = PageAnnotation(kind: .text, text: spot.value)
          item.x = spot.rect.minX; item.y = spot.rect.minY; item.width = spot.rect.width; item.height = spot.rect.height
          item.color = "blue"
          items.append(item)
        }
      }
      setMarks(items)
      fillNote = spots.count == 1 ? "Filled 1 field. Drag to adjust." : "Filled \(spots.count) fields. Drag to adjust."
    }
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
        if trialUnlocked { ProTrialSession.commit() }
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
        if let error { Text(L(error)).font(.system(size: 15, weight: .medium)).foregroundStyle(TK.red) }
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


/// Answers saved on this iPhone for filling forms.
struct FormProfile {
  static let fields: [(key: String, title: String, labels: [String])] = [
    ("name", "Full name", ["full name", "name", "applicant name", "applicant", "your name", "print name", "printed name", "customer name", "contact name", "name of applicant",
                           "성명", "성 명", "이름", "신청인", "신청자", "성명(한글)"]),
    ("email", "Email", ["e-mail address", "email address", "e-mail", "email", "이메일", "전자우편", "전자 우편", "이메일 주소"]),
    ("phone", "Phone", ["telephone number", "phone number", "mobile number", "contact number", "daytime phone", "cell phone", "telephone", "phone", "mobile", "cell", "tel",
                        "전화번호", "휴대폰", "휴대전화", "핸드폰", "연락처", "전화"]),
    ("address", "Address", ["home address", "street address", "mailing address", "residential address", "current address", "address", "주소", "현주소", "자택 주소"]),
    ("city", "City", ["city/town", "city", "town", "시/군/구", "도시"]),
    ("postal", "Postal code", ["postal code", "post code", "zip code", "postcode", "zip", "우편번호"]),
    ("company", "Company", ["company name", "business name", "organization", "organisation", "company", "employer", "회사명", "회사", "소속", "직장"]),
  ]
  static func load() -> [String: String] {
    (UserDefaults.standard.dictionary(forKey: "form-profile") as? [String: String] ?? [:]).filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
  }
  static func save(_ values: [String: String]) { UserDefaults.standard.set(values, forKey: "form-profile") }

  struct Spot { let key: String; let value: String; let rect: CGRect }
  /// Where each answer goes: right after its label (past a table's cell line when the
  /// page image is given), or below it when the label sits at the right edge.
  static func place(blocks: [TextBlock], profile: [String: String], image: CGImage? = nil) -> [Spot] {
    var spots: [Spot] = []
    var used = Set<String>()
    let today = Date().appFormatted(date: .numeric, time: .omitted)
    let extra: [(String, [String])] = [("date", ["today's date", "date signed", "date", "날짜", "일자", "작성일", "신청일"]),
                                       ("signature", ["applicant's signature", "applicant signature", "your signature", "signature", "sign here", "서명"])]
    // Longest label first, so "email address" is an email and not an address.
    let all = (fields.map { ($0.key, $0.labels) } + extra).flatMap { key, labels in labels.map { (key, $0) } }.sorted { $0.1.count > $1.1.count }
    let ink = image.flatMap(InkMap.init)
    for block in blocks.sorted(by: { $0.y < $1.y }) {
      let text = block.text.lowercased().trimmingCharacters(in: .whitespaces)
      guard let (key, label) = all.first(where: { text.hasPrefix($0.1) && !used.contains($0.0) }) else { continue }
      // Label alone (or with a colon or blank line), not a sentence that starts with the word.
      let rest = text.dropFirst(label.count).trimmingCharacters(in: CharacterSet(charactersIn: " :：.-_()*"))
      guard rest.count <= 2 || rest.allSatisfy({ $0 == "_" || $0 == "." }) else { continue }
      let value: String
      if key == "date" { value = today } else if key == "signature" { value = "" } else { guard let v = profile[key] else { continue }; value = v }
      // End of the label word inside the line.
      var end = block.x + block.width * min(1, Double(label.count + 1) / Double(max(1, block.text.count)))
      if let words = block.words, let last = words.first(where: { label.hasSuffix($0.text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":："))) }) {
        end = last.x + last.width
      }
      // In a table the answer goes in the next cell: skip past the cell's border.
      // The band reaches past the text so letters such as l or | never count as a border.
      if let ink, let line = ink.verticalLine(from: end, to: min(0.95, end + 0.4), top: block.y - block.height * 0.3, bottom: block.y + block.height * 1.3) { end = line }
      let h = max(0.022, block.height * 1.4)
      var rect = CGRect(x: end + 0.012, y: max(0, block.y - block.height * 0.2), width: min(0.5, 0.98 - end - 0.012), height: h)
      if rect.width < 0.15 { rect = CGRect(x: block.x, y: min(1 - h, block.y + block.height * 1.1), width: min(0.5, 0.98 - block.x), height: h) }
      guard rect.width > 0.05 else { continue }
      used.insert(key)
      spots.append(Spot(key: key, value: value, rect: rect))
    }
    return spots
  }
}

/// A small grayscale copy of a page for finding printed rules (table borders).
struct InkMap {
  let width: Int, height: Int
  private let dark: [Bool]
  init?(_ image: CGImage) {
    let scale = min(1, 900 / Double(max(image.width, image.height)))
    width = max(1, Int(Double(image.width) * scale)); height = max(1, Int(Double(image.height) * scale))
    var pixels = [UInt8](repeating: 255, count: width * height)
    guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // Dark relative to the page: below 60% of the median brightness.
    let median = Int(pixels.sorted()[pixels.count / 2])
    let cut = UInt8(max(40, median * 6 / 10))
    dark = pixels.map { $0 < cut }
  }
  /// x (0–1) of the first vertical rule between `from` and `to` that crosses most of the
  /// text row (top/bottom are 0–1 from the top of the page).
  func verticalLine(from: Double, to: Double, top: Double, bottom: Double) -> Double? {
    // The bitmap's first row is the top of the page.
    let y0 = max(0, Int(top * Double(height))), y1 = min(height - 1, Int(bottom * Double(height)))
    guard y1 > y0 + 2 else { return nil }
    let x0 = max(0, Int(from * Double(width)) + 1), x1 = min(width - 1, Int(to * Double(width)))
    guard x1 > x0 else { return nil }
    for x in x0...x1 {
      var n = 0
      for y in y0...y1 {
        let near = (max(0, x - 1)...min(width - 1, x + 1)).contains { dark[y * width + $0] }
        if near { n += 1 }
      }
      if Double(n) >= 0.85 * Double(y1 - y0 + 1) { return Double(x + 2) / Double(width) }
    }
    return nil
  }
}

/// Edit the answers used by Fill from my info.
struct FormProfileEditor: View {
  @Environment(\.dismiss) private var dismiss
  @State private var values: [String: String] = UserDefaults.standard.dictionary(forKey: "form-profile") as? [String: String] ?? [:]
  var body: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(FormProfile.fields, id: \.key) { field in
            TextField(field.title, text: Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 }))
              .textContentType(field.key == "email" ? .emailAddress : field.key == "phone" ? .telephoneNumber : field.key == "name" ? .name : field.key == "postal" ? .postalCode : field.key == "address" ? .fullStreetAddress : nil)
          }
        } footer: { Text("Saved only on this iPhone. Dates are filled with today, and Signature uses your latest saved signature.") }
      }
      .navigationTitle("My info").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Save") { FormProfile.save(values); dismiss() } }
      }
    }
  }
}
