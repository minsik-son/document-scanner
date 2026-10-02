import SwiftUI

/// Shared artwork for Home and the complete tool directory.
struct ToolArtwork: View {
    let name: String
    var size: CGFloat = 64
    var body: some View {
        Image("tool-" + name).resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
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
            if pro { Text("PRO").font(.system(size: 9, weight: .bold)).foregroundStyle(Design.blue) }
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
