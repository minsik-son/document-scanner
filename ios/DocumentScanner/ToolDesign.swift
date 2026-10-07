import SwiftUI

/// Shared artwork for Home and the complete tool directory.
struct ToolArtwork: View {
    let name: String
    var size: CGFloat = 64
    var body: some View {
        Group {
            if UIImage(named: "tool-" + name) != nil {
                Image("tool-" + name).resizable().interpolation(.high).scaledToFit()
            } else {
                // Until its illustrated icon arrives: a soft tile with a symbol.
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x5B8CFF), Color(hex: 0x3D6BF2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(size * 0.08)
                    .overlay(Image(systemName: Self.fallback[name] ?? "square.grid.2x2").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}
extension ToolArtwork {
    static let fallback: [String: String] = [
        "card-contact": "person.crop.rectangle.badge.plus", "ask-document": "sparkles",
        "remove-fingers": "hand.raised.fill", "auto-save": "folder.badge.plus",
    ]
}
struct ToolTile: View {
    let title: String
    let icon: String
    var pro = false
    var body: some View {
        VStack(spacing: 4) {
            ToolArtwork(name: icon, size: 64)
            Text(title).font(.system(.caption, weight: .medium)).multilineTextAlignment(.center)
                .foregroundStyle(Design.ink).fixedSize(horizontal: false, vertical: true)
            if pro { ProBadge() }
        }.frame(maxWidth: .infinity, minHeight: 100, alignment: .top)
            .contentShape(Rectangle()).accessibilityElement(children: .ignore)
            .accessibilityLabel(title + (pro ? ", Pro" : ""))
    }
}
extension AdvancedTool {
    var icon: String {
        switch self {
        case .erase: return "eraser"
        default: return String(describing: self)
        }
    }
}

enum LibraryTool: String, Identifiable, CaseIterable {
    case ocr = "Extract text", reorder = "Reorder pages", watermark = "Watermark", timestamp = "Timestamp"
    case identity = "ID scan", longImage = "Long image", annotate = "Sign & annotate"
    case merge = "Merge documents", split = "Split PDF", extract = "Extract pages"
    case compress = "Compress PDF", protect = "Protect with password", images = "Export images", print = "Print"
    var id: String { rawValue }
    var documentTool: DocumentTool? { self == .identity ? .identity : DocumentTool(rawValue: rawValue) }
    var pro: Bool { documentTool?.pro ?? false }
    var icon: String {
        switch self {
        case .longImage: return "long-image"
        case .annotate: return "signature"
        default: return String(describing: self)
        }
    }
}
enum QuickTool: Identifiable {
    case advanced(AdvancedTool), library(LibraryTool), qr, stitch
    var id: String {
        switch self {
        case .advanced(let tool): return "advanced-" + tool.id
        case .library(let tool): return "library-" + tool.id
        case .qr: return "qr"
        case .stitch: return "stitch"
        }
    }
}
struct QuickToolView: View {
    let tool: QuickTool
    var documentID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        switch tool {
        case .advanced(let value):
            NavigationStack {
                AdvancedOfflineToolView(tool: value, documentID: documentID)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            }
        case .library(let value):
            if value == .identity { IdentityScanView() }
            else { PDFToolFlow(tool: value, documentID: documentID) }
        case .qr: QRCodeView()
        case .stitch: ScreenshotStitchView()
        }
    }
}

/// A tool that can sit in Home's Quick tools grid. Each user picks and orders
/// their own; free users only see free tools there.
enum HomeShortcut: Hashable, Identifiable {
    case photos, qr, stitch
    case library(LibraryTool)
    case advanced(AdvancedTool)

    var id: String {
        switch self {
        case .photos: return "photos"
        case .qr: return "qr"
        case .stitch: return "stitch"
        case .library(let tool): return "library-" + String(describing: tool)
        case .advanced(let tool): return "advanced-" + String(describing: tool)
        }
    }
    init?(id: String) {
        guard let match = Self.all.first(where: { $0.id == id }) else { return nil }
        self = match
    }
    /// Every tool that opens straight from Home (Measure and 3D scan need their own screens).
    static let all: [HomeShortcut] = [.photos, .qr, .stitch]
        + LibraryTool.allCases.map { .library($0) }
        + AdvancedTool.allCases.filter { $0 != .measure && $0 != .mesh && !$0.hidden }.map { .advanced($0) }
    static let maximum = 7
    static func defaults(pro: Bool) -> [HomeShortcut] {
        pro ? [.photos, .library(.ocr), .advanced(.word), .advanced(.excel), .library(.annotate), .library(.compress), .qr]
            : [.photos, .library(.ocr), .library(.annotate), .library(.merge), .library(.identity), .library(.images), .qr]
    }

    var title: String {
        switch self {
        case .photos: return "Import photos"
        case .qr: return "QR code"
        case .stitch: return "Stitch"
        case .library(let tool):
            switch tool {
            case .ocr: return "Text"
            case .annotate: return "Sign"
            case .compress: return "Compress"
            case .identity: return "ID scan"
            case .images: return "To images"
            case .merge: return "Merge"
            case .split: return "Split"
            case .extract: return "Extract"
            case .protect: return "Password"
            case .reorder: return "Reorder"
            case .longImage: return "Long image"
            case .watermark: return "Watermark"
            case .timestamp: return "Timestamp"
            case .print: return "Print"
            }
        case .advanced(let tool):
            switch tool {
            case .word: return "Word"
            case .excel: return "Excel"
            case .slides: return "PowerPoint"
            case .translate: return "Translate"
            case .math: return "Math"
            case .book: return "Book"
            case .portrait: return "ID photo"
            case .erase: return "Erase"
            case .marks: return "Pen marks"
            case .restore: return "Restore"
            case .mega: return "Mega scan"
            case .count: return "Count"
            case .measure: return "Measure"
            case .mesh: return "3D scan"
            }
        }
    }
    var icon: String {
        switch self {
        case .photos: return "import-photo"
        case .qr: return "qr"
        case .stitch: return "stitch"
        case .library(let tool): return tool.icon
        case .advanced(let tool): return tool.icon
        }
    }
    var pro: Bool {
        switch self {
        case .photos, .qr, .stitch: return false
        case .library(let tool): return tool.pro
        case .advanced(let tool): return tool.pro
        }
    }
}

/// The user's Quick tools, saved on this iPhone.
enum QuickToolPrefs {
    static let key = "homeQuickTools"
    static func load(_ raw: String, pro: Bool) -> [HomeShortcut] {
        let saved = raw.split(separator: ",").compactMap { HomeShortcut(id: String($0)) }
        let list = raw.isEmpty ? HomeShortcut.defaults(pro: pro) : saved
        // Free users get free tools only; Pro tools stay saved for when they upgrade.
        return Array((pro ? list : list.filter { !$0.pro }).prefix(HomeShortcut.maximum))
    }
    static func encode(_ list: [HomeShortcut]) -> String { list.map(\.id).joined(separator: ",") }
}

/// Small "PRO" mark on tool icons. Hidden for Pro members.
struct ProBadge: View {
    @EnvironmentObject private var subscription: SubscriptionStore
    var body: some View {
        if !subscription.isPro {
            Text("PRO").font(.system(size: 9, weight: .heavy)).tracking(0.4).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(LinearGradient(colors: [TK.purple, TK.blue], startPoint: .leading, endPoint: .trailing), in: Capsule())
                .shadow(color: TK.purple.opacity(0.35), radius: 3, y: 1)
                .accessibilityHidden(true)
        }
    }
}

/// Pick and order the tools on Home.
struct QuickToolsEditor: View {
    @EnvironmentObject private var subscription: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(QuickToolPrefs.key) private var raw = ""
    @State private var chosen: [HomeShortcut] = []
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(chosen) { item in
                        row(item) {
                            Button { chosen.removeAll { $0 == item } } label: {
                                Image(systemName: "minus.circle.fill").font(.system(size: 22)).foregroundStyle(TK.red)
                            }.buttonStyle(.plain).accessibilityLabel("Remove \(item.title)")
                        }
                    }
                    .onMove { chosen.move(fromOffsets: $0, toOffset: $1) }
                } header: { Text("On Home · \(chosen.count) of \(HomeShortcut.maximum)") }
                  footer: { Text("Drag to reorder. All tools stays in the last spot.") }
                Section("Add a tool") {
                    ForEach(available) { item in
                        let locked = item.pro && !subscription.isPro
                        row(item) {
                            if locked {
                                Image(systemName: "lock.fill").font(.system(size: 15)).foregroundStyle(TK.grey400)
                            } else {
                                Button { chosen.append(item) } label: {
                                    Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(chosen.count >= HomeShortcut.maximum ? TK.grey300 : TK.blue)
                                }.buttonStyle(.plain).disabled(chosen.count >= HomeShortcut.maximum).accessibilityLabel("Add \(item.title)")
                            }
                        }.opacity(locked ? 0.55 : 1)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Quick tools").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Reset") { chosen = HomeShortcut.defaults(pro: subscription.isPro) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { raw = QuickToolPrefs.encode(chosen); dismiss() }.bold().accessibilityIdentifier("quick-tools-done")
                }
            }
            .onAppear { chosen = QuickToolPrefs.load(raw, pro: subscription.isPro) }
        }
    }
    private var available: [HomeShortcut] {
        HomeShortcut.all.filter { !chosen.contains($0) }.sorted { ($0.pro ? 1 : 0, $0.title) < ($1.pro ? 1 : 0, $1.title) }
    }
    private func row<Trailing: View>(_ item: HomeShortcut, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            ToolArtwork(name: item.icon, size: 40)
            Text(item.title).font(.system(size: 16, weight: .medium)).foregroundStyle(TK.grey900)
            if item.pro { ProBadge() }
            Spacer()
            trailing()
        }.padding(.vertical, 2)
    }
}
