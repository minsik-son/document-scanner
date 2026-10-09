import SwiftUI

/// Formats a finished scan can be turned into besides the PDF.
enum ConversionRoute: String, Identifiable {
    case word, excel, slides, images
    var id: String { rawValue }
    var tool: AdvancedTool? {
        switch self { case .word: return .word; case .excel: return .excel; case .slides: return .slides; case .images: return nil }
    }
}

/// Opens a conversion of a saved document: Word and Excel start reading at once,
/// slides open on the style choice, images use the export-images flow.
struct ConversionDestination: View {
    let route: ConversionRoute
    let documentID: UUID
    let close: () -> Void
    var body: some View {
        if let tool = route.tool {
            NavigationStack {
                AdvancedOfflineToolView(tool: tool, documentID: documentID, autoStart: true)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close", action: close).accessibilityIdentifier("export-close") } }
            }
        } else {
            PDFToolFlow(tool: .images, documentID: documentID)
        }
    }
}

extension ConversionRoute {
    /// Saved choice of the review's format row ("pdf" or a route). UI-test
    /// sessions keep their own, so one test's choice never leaks into the next.
    static var formatKey: String {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--ui-test-session"), i + 1 < args.count { return "review-output-format." + args[i + 1] }
#endif
        return "review-output-format"
    }
}
