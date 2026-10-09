import SwiftUI
import UIKit

/// One area in the hide editor, on the finished page (origin top-left, 0…1).
struct RedactionMark: Identifiable, Equatable {
    var id = UUID()
    var rect: CGRect
    /// What was found ("Phone", "ID number"…), or "Added" / "Word" / "Hidden" (saved before).
    var kind: String
    var hidden = true
    /// Found automatically; hiding it can be undone with a tap but it isn't deleted.
    var found: Bool { !["Added", "Word", "Hidden"].contains(kind) }
}

/// Hide personal info on the review's own big page. Found numbers are covered at
/// once; tap a box to keep it visible, tap a word to hide it, drag to hide any
/// area, drag a box or its corner to move or resize it, pinch to zoom in.
struct RedactionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let pages: [ScanPage]
    let root: URL
    /// Shown above the page when the editor opens for a check before saving.
    var notice: String? = nil
    /// Hidden and kept-visible areas per page id, only for pages that were opened.
    let save: ([UUID: (hidden: [CGRect], visible: [CGRect])]) -> Void
    @State var index: Int
    @State private var states: [UUID: PageState] = [:]
    @State private var selected: UUID?
    @State private var loading: Task<Void, Never>?

    struct PageState {
        var image: UIImage?
        var words: [CGRect] = []
        var marks: [RedactionMark] = []
        var history: [[RedactionMark]] = []
        var failed: String?
    }
    private var page: ScanPage { pages[min(index, pages.count - 1)] }
    private var state: PageState { states[page.id] ?? PageState() }
    private var marks: Binding<[RedactionMark]> {
        Binding(get: { states[page.id]?.marks ?? [] }, set: { states[page.id, default: PageState()].marks = $0 })
    }
    private var hiddenTotal: Int { states.values.reduce(0) { $0 + $1.marks.filter(\.hidden).count } }
    private var current: RedactionMark? { state.marks.first { $0.id == selected } }

    var body: some View {
        VStack(spacing: 0) {
            if pages.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pages.indices, id: \.self) { i in
                            let n = states[pages[i].id]?.marks.filter(\.hidden).count ?? 0
                            Button(String(format: L("Page %lld"), i + 1) + (n > 0 ? " · \(n)" : "")) { selected = nil; index = i }
                                .buttonStyle(ChipStyle(selected: index == i))
                        }
                    }.padding(.horizontal, 16)
                }.padding(.vertical, 8)
            }
            status.padding(.horizontal, 16).padding(.bottom, 8)
            ZStack {
                if let image = state.image {
                    RedactionCanvas(image: image, words: state.words, marks: marks, selected: $selected) { pushHistory() }
                        .id(page.id)
                        .accessibilityElement()
                        .accessibilityLabel("Page to hide")
                        .accessibilityValue(String(format: L("%lld hidden, %lld visible"), state.marks.filter(\.hidden).count, state.marks.filter { !$0.hidden }.count))
                        .accessibilityIdentifier("redact-canvas")
                } else if let failed = state.failed {
                    Text(L(failed)).font(.system(size: 14)).foregroundStyle(TK.grey600).multilineTextAlignment(.center).padding(24)
                } else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.882, green: 0.902, blue: 0.929))
            controls
        }
        .background(TK.paper)
        .navigationTitle("Hide personal info").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { loading?.cancel(); dismiss() }.accessibilityIdentifier("redact-cancel") }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { finish() }.fontWeight(.semibold).accessibilityIdentifier("redact-done")
                    .disabled(states.isEmpty)
            }
        }
        .onAppear { if loading == nil { load() } }
        .onDisappear { loading?.cancel() }
    }

    @ViewBuilder private var status: some View {
        let found = state.marks.filter(\.found).count
        HStack(spacing: 8) {
            Image(systemName: state.image == nil ? "magnifyingglass" : (found > 0 ? "eye.slash.fill" : "hand.draw")).font(.system(size: 13, weight: .semibold))
            Text(state.image == nil ? L("Looking for personal info…")
                 : found > 0 ? String(format: L("Found %lld items. Tap a box to keep it visible."), found)
                 : L("Nothing found. Drag on the page or tap a word to hide it."))
                .font(.system(size: 13, weight: .semibold)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 9)
        .background(TK.grey900, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine).accessibilityIdentifier("redact-status")
        if let notice { Text(L(notice)).font(.system(size: 13)).foregroundStyle(Color.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6) }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly).frame(width: 44, height: 44) }
                    .disabled(state.history.isEmpty).accessibilityIdentifier("redact-undo")
                if let mark = current {
                    Button(mark.hidden ? "Show" : "Hide") { pushHistory(); update(mark.id) { $0.hidden.toggle() } }
                        .buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("redact-toggle")
                    if !mark.found {
                        Button("Delete", role: .destructive) { pushHistory(); marks.wrappedValue.removeAll { $0.id == mark.id }; selected = nil }
                            .buttonStyle(ChipStyle(selected: false)).accessibilityIdentifier("redact-delete")
                    }
                    Spacer(minLength: 0)
                } else {
                    Text("Tap a word or drag to hide more. Pinch with two fingers to zoom.")
                        .font(.system(size: 12)).foregroundStyle(TK.grey600).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button { finish() } label: {
                Text(hiddenTotal == 0 ? L("Done") : String(format: L("Hide %lld"), hiddenTotal))
            }
            .buttonStyle(PrimaryButton()).disabled(states.isEmpty).accessibilityIdentifier("redact-save")
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8).background(.white)
    }

    private func update(_ id: UUID, _ change: (inout RedactionMark) -> Void) {
        guard let i = marks.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
        change(&marks.wrappedValue[i])
    }
    private func pushHistory() {
        var s = states[page.id] ?? PageState()
        s.history.append(s.marks); if s.history.count > 60 { s.history.removeFirst() }
        states[page.id] = s
    }
    private func undo() {
        guard var s = states[page.id], let last = s.history.popLast() else { return }
        s.marks = last; states[page.id] = s; selected = nil
    }
    private func finish() {
        loading?.cancel()
        var out: [UUID: (hidden: [CGRect], visible: [CGRect])] = [:]
        for (id, s) in states where s.image != nil {
            out[id] = (s.marks.filter(\.hidden).map(\.rect), s.marks.filter { !$0.hidden && $0.found }.map(\.rect))
        }
        save(out); dismiss()
    }
    /// The shown page first, then the others, so every page's count is ready.
    private func load() {
        let order = [index] + pages.indices.filter { $0 != index }
        let pages = pages, root = root
        loading = Task {
            for i in order {
                guard !Task.isCancelled else { return }
                let page = pages[i]
                do {
                    let (image, blocks) = try await OfflineWork.perform { () throws -> (UIImage, [TextBlock]) in
                        let image = try Imaging.renderThumbnail(page.withoutRedaction, root: root, maxDimension: 2200)
                        return (image, try Imaging.recognize(image))
                    }
                    guard !Task.isCancelled else { return }
                    states[page.id] = PageState(image: image, words: Self.words(blocks), marks: Self.marks(for: page, blocks: blocks))
                } catch is CancellationError { return }
                catch { states[page.id] = PageState(failed: "This page couldn't be prepared. Try again.") }
            }
        }
    }
    /// Saved areas, then what is found on the page that isn't already decided.
    static func marks(for page: ScanPage, blocks: [TextBlock]) -> [RedactionMark] {
        var out = page.redactionBoxes.map { RedactionMark(rect: $0, kind: "Hidden") }
        let kept = page.keptVisibleBoxes
        let decided = page.redactionBoxes + kept
        out += kept.map { RedactionMark(rect: $0, kind: "Kept", hidden: false) }
        for box in Redaction.boxes(in: blocks) where !decided.contains(where: { $0.intersects(box.rect) }) {
            out.append(RedactionMark(rect: box.rect, kind: box.kind))
        }
        return out
    }
    static func words(_ blocks: [TextBlock]) -> [CGRect] {
        blocks.flatMap { block -> [CGRect] in
            if let words = block.words, !words.isEmpty { return words.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } }
            return [CGRect(x: block.x, y: block.y, width: block.width, height: block.height)]
        }
    }
}

/// The zoomable page with its boxes (UIKit: pinch and two-finger pan zoom, one
/// finger draws, moves and resizes).
struct RedactionCanvas: UIViewRepresentable {
    let image: UIImage
    let words: [CGRect]
    @Binding var marks: [RedactionMark]
    @Binding var selected: UUID?
    let willChange: () -> Void
    func makeUIView(context: Context) -> RedactionScrollView {
        let view = RedactionScrollView()
        view.overlay.willChange = { context.coordinator.parent.willChange() }
        view.overlay.changed = { marks, selected in
            context.coordinator.parent.marks = marks
            context.coordinator.parent.selected = selected
        }
        return view
    }
    func updateUIView(_ view: RedactionScrollView, context: Context) {
        context.coordinator.parent = self
        if view.image !== image { view.image = image }
        view.overlay.words = words
        if view.overlay.marks != marks { view.overlay.marks = marks }
        if view.overlay.selected != selected { view.overlay.selected = selected }
    }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    final class Coordinator { var parent: RedactionCanvas; init(parent: RedactionCanvas) { self.parent = parent } }
}

final class RedactionScrollView: UIScrollView, UIScrollViewDelegate {
    let content = UIView()
    let imageView = UIImageView()
    let overlay = RedactionOverlayView()
    var image: UIImage? { didSet { imageView.image = image; laidOutSize = .zero; setNeedsLayout() } }
    private var laidOutSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1; maximumZoomScale = 6
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        // One finger belongs to the boxes; two fingers pan the zoomed page.
        panGestureRecognizer.minimumNumberOfTouches = 2
        delaysContentTouches = false
        imageView.contentMode = .scaleToFill
        addSubview(content); content.addSubview(imageView); content.addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize, bounds.width > 0, let image, image.size.width > 0 else { return }
        laidOutSize = bounds.size
        zoomScale = 1
        let inset: CGFloat = 16
        let box = bounds.insetBy(dx: inset, dy: inset).size
        let s = min(box.width / image.size.width, box.height / image.size.height)
        let size = CGSize(width: image.size.width * s, height: image.size.height * s)
        content.frame = CGRect(origin: .zero, size: bounds.size)
        let fit = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        imageView.frame = fit; overlay.frame = fit
        contentSize = bounds.size
        overlay.zoom = 1
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { overlay.zoom = zoomScale }
}

final class RedactionOverlayView: UIView {
    var marks: [RedactionMark] = [] { didSet { setNeedsDisplay() } }
    var selected: UUID? { didSet { setNeedsDisplay() } }
    var words: [CGRect] = []
    var zoom: CGFloat = 1 { didSet { setNeedsDisplay() } }
    var willChange: () -> Void = {}
    var changed: ([RedactionMark], UUID?) -> Void = { _, _ in }
    private enum Mode { case draw(CGPoint), move(UUID, CGRect, CGPoint), resize(UUID, Int, CGRect) }
    private var mode: Mode?
    private var draft: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; contentMode = .redraw
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func view(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * bounds.width, y: r.minY * bounds.height, width: r.width * bounds.width, height: r.height * bounds.height)
    }
    private func unit(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x / max(1, bounds.width))), y: min(1, max(0, p.y / max(1, bounds.height))))
    }
    private func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
    /// The box under a point, the last drawn first; a little slack for thin boxes.
    private func hit(_ p: CGPoint) -> RedactionMark? {
        let slack = 8 / zoom
        return marks.last { view($0.rect).insetBy(dx: -slack, dy: -slack).contains(p) }
    }
    private func publish() { changed(marks, selected) }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        if let mark = hit(p), let i = marks.firstIndex(where: { $0.id == mark.id }) {
            willChange(); marks[i].hidden.toggle(); selected = mark.id; publish(); return
        }
        let u = unit(p)
        if let word = words.first(where: { $0.insetBy(dx: -0.004, dy: -0.004).contains(u) }) {
            willChange()
            let mark = RedactionMark(rect: word.insetBy(dx: -0.002, dy: -0.002), kind: "Word")
            marks.append(mark); selected = mark.id; publish(); return
        }
        selected = nil; publish()
    }
    @objc private func pan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            let start = CGPoint(x: p.x - g.translation(in: self).x, y: p.y - g.translation(in: self).y)
            let tolerance = 18 / zoom
            mode = .draw(start)
            // A corner of the chosen box, then of any box, resizes; inside a box moves it.
            let candidates = marks.filter { $0.id == selected } + marks.reversed()
            outer: for mark in candidates {
                for (c, point) in corners(view(mark.rect)).enumerated() where hypot(point.x - start.x, point.y - start.y) < tolerance {
                    mode = .resize(mark.id, c, mark.rect); break outer
                }
            }
            if case .draw(_)? = mode, let mark = hit(start) { mode = .move(mark.id, mark.rect, start) }
            switch mode! {
            case .move(let id, _, _), .resize(let id, _, _): willChange(); selected = id
            case .draw: break
            }
        case .changed:
            guard let mode else { return }
            switch mode {
            case .draw(let start):
                draft = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
                setNeedsDisplay()
            case .move(let id, let origin, let start):
                guard let i = marks.firstIndex(where: { $0.id == id }) else { return }
                var r = origin.offsetBy(dx: (p.x - start.x) / max(1, bounds.width), dy: (p.y - start.y) / max(1, bounds.height))
                r.origin.x = min(1 - r.width, max(0, r.origin.x)); r.origin.y = min(1 - r.height, max(0, r.origin.y))
                marks[i].rect = r
            case .resize(let id, let corner, let origin):
                guard let i = marks.firstIndex(where: { $0.id == id }) else { return }
                let fixed = corners(origin)[(corner + 2) % 4], u = unit(p)
                let minSide: CGFloat = 0.006
                var r = CGRect(x: min(fixed.x, u.x), y: min(fixed.y, u.y), width: abs(u.x - fixed.x), height: abs(u.y - fixed.y))
                r.size.width = max(minSide, r.width); r.size.height = max(minSide, r.height)
                marks[i].rect = r
            }
        case .ended, .cancelled:
            defer { mode = nil; draft = nil; setNeedsDisplay() }
            if case .draw(_)? = mode, let d = draft, d.width > 6 / zoom, d.height > 6 / zoom, g.state == .ended {
                willChange()
                let r = CGRect(x: d.minX / bounds.width, y: d.minY / bounds.height, width: d.width / bounds.width, height: d.height / bounds.height)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let mark = RedactionMark(rect: r, kind: "Added")
                marks.append(mark); selected = mark.id
            }
            publish()
        default: break
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let line = 1.5 / zoom
        for mark in marks {
            let r = view(mark.rect.insetBy(dx: -RedactionGeometry.pad, dy: -RedactionGeometry.pad))
            if mark.hidden {
                ctx.setFillColor(UIColor.black.cgColor); ctx.fill(r)
            } else {
                ctx.setFillColor(UIColor.systemRed.withAlphaComponent(0.08).cgColor); ctx.fill(r)
                ctx.setStrokeColor(UIColor.systemRed.cgColor); ctx.setLineWidth(line)
                ctx.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom]); ctx.stroke(r); ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        if let mark = marks.first(where: { $0.id == selected }) {
            let r = view(mark.rect.insetBy(dx: -RedactionGeometry.pad, dy: -RedactionGeometry.pad))
            ctx.setStrokeColor(UIColor.systemBlue.cgColor); ctx.setLineWidth(2 / zoom); ctx.stroke(r.insetBy(dx: -1 / zoom, dy: -1 / zoom))
            let radius = 6 / zoom
            for c in corners(r) {
                let dot = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
                ctx.setFillColor(UIColor.white.cgColor); ctx.fillEllipse(in: dot)
                ctx.setStrokeColor(UIColor.systemBlue.cgColor); ctx.setLineWidth(2 / zoom); ctx.strokeEllipse(in: dot)
            }
        }
        if let draft {
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor); ctx.fill(draft)
        }
    }
}
