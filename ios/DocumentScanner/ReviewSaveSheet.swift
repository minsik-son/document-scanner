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

/// The save step of a new scan: check the name, then keep it as a PDF or make
/// another format from it. Whatever is chosen, the PDF is saved to the library.
struct ReviewSaveSheet<Options: View>: View {
    @EnvironmentObject private var subscription: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @Binding var title: String
    let autoTitled: Bool
    @ViewBuilder let options: () -> Options
    /// nil saves the PDF only.
    let choose: (ConversionRoute?) -> Void
    @State private var trials = ProTrials()
    @State private var paywall = false
    @State private var showsOptions = false
    @FocusState private var naming: Bool

    private var officeLeft: Int { trials.remaining(.office) }
    private var locked: Bool { !subscription.isPro && !trials.bypassed && officeLeft == 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("How do you want to save it?").font(.system(size: 21, weight: .bold)).foregroundStyle(TK.grey900)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text("File name").font(.system(size: 12, weight: .medium)).foregroundStyle(TK.grey500)
                    HStack {
                        TextField("Document name", text: $title).font(.system(size: 16)).focused($naming)
                            .submitLabel(.done).accessibilityIdentifier("save-name")
                        Image(systemName: "pencil").foregroundStyle(TK.blue).accessibilityHidden(true)
                    }
                    if autoTitled { Text("Named automatically from the text when you save").font(.system(size: 12)).foregroundStyle(TK.grey500) }
                }
                .padding(12).background(TK.grey50, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if locked {
                    Button { paywall = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Unlimited Word, Excel and PowerPoint with Pro").font(.system(size: 15, weight: .bold))
                                Text("You've used your free conversions").font(.system(size: 13))
                            }
                            Spacer(minLength: 8)
                            Text("See Pro").font(.system(size: 13, weight: .bold)).foregroundStyle(TK.orange)
                                .padding(.horizontal, 10).padding(.vertical, 6).background(.white, in: Capsule())
                        }
                        .foregroundStyle(.white).padding(14)
                        .background(LinearGradient(colors: [Color(red: 1, green: 0.58, blue: 0), Color(red: 1, green: 0.37, blue: 0.23)], startPoint: .leading, endPoint: .trailing),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }.buttonStyle(.plain).accessibilityIdentifier("save-pro-banner")
                }
                Button { pick(nil) } label: {
                    HStack(spacing: 12) {
                        badge("PDF", Color(red: 0.90, green: 0.28, blue: 0.30))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save as PDF").font(.system(size: 16, weight: .semibold)).foregroundStyle(TK.grey900)
                            Text("Saved to your library, ready to share").font(.system(size: 13)).foregroundStyle(TK.grey500)
                        }
                        Spacer(minLength: 8)
                        tag(free: true)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TK.blueSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(TK.blue, lineWidth: 1.5))
                }.buttonStyle(.plain).accessibilityIdentifier("save-format-pdf")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    card(.word, "Word", "Tables and layout, editable", "W", Color(red: 0.17, green: 0.34, blue: 0.60))
                    card(.excel, "Excel", "Tables as cells", "X", Color(red: 0.13, green: 0.45, blue: 0.27))
                    card(.slides, "PowerPoint", "One slide per page", "P", Color(red: 0.82, green: 0.28, blue: 0.15))
                    card(.images, "Images", "For Photos and chats", "JPG", Color(white: 0.56))
                }
                DisclosureGroup("PDF options", isExpanded: $showsOptions) { VStack(spacing: 10) { options() }.padding(.top, 8) }
                    .font(.system(size: 15)).tint(TK.grey600).accessibilityIdentifier("save-options")
                Text("Whatever you choose, the PDF stays in your library.").font(.system(size: 12)).foregroundStyle(TK.grey500)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $paywall, onDismiss: { trials = ProTrials() }) { PaywallView(start: .feature(.office)) }
    }

    private func pick(_ route: ConversionRoute?) {
        naming = false
        if route != nil && route != .images && locked { paywall = true; return }
        dismiss(); choose(route)
    }

    private func card(_ route: ConversionRoute, _ name: String, _ detail: String, _ mark: String, _ color: Color) -> some View {
        let pro = route != .images
        let off = pro && locked
        return Button { pick(route) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    badge(mark, color)
                    Spacer(minLength: 4)
                    if pro { tag(free: false, lockedNow: off) } else { tag(free: true) }
                }
                Text(L(name)).font(.system(size: 15, weight: .semibold)).foregroundStyle(TK.grey900)
                Text(L(detail)).font(.system(size: 12)).foregroundStyle(TK.grey500).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(TK.grey200, lineWidth: 1))
            .opacity(off ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(name))
        .accessibilityValue(off ? L("Pro") : (pro && !subscription.isPro ? String(format: L("%lld free left"), officeLeft) : ""))
        .accessibilityIdentifier("save-format-" + route.rawValue)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: text.count > 2 ? 11 : 15, weight: .heavy)).foregroundStyle(.white)
            .frame(width: 36, height: 36).background(color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder private func tag(free: Bool, lockedNow: Bool = false) -> some View {
        if free || subscription.isPro {
            Text("Free").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(red: 0.08, green: 0.50, blue: 0.24))
                .padding(.horizontal, 7).padding(.vertical, 3).background(Color(red: 0.91, green: 0.97, blue: 0.93), in: Capsule())
                .opacity(subscription.isPro && !free ? 0 : 1)
        } else {
            Label(lockedNow ? L("Pro") : String(format: L("%lld free left"), officeLeft), systemImage: lockedNow ? "lock.fill" : "crown.fill")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(Color(red: 0.76, green: 0.25, blue: 0.05))
                .padding(.horizontal, 7).padding(.vertical, 3).background(Color(red: 1, green: 0.95, blue: 0.90), in: Capsule())
        }
    }
}
