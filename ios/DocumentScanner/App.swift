import SwiftUI

@main
struct DocumentScannerApp: App {
    @State private var store: LibraryStore?
    @State private var startupStarted = false
    /// The branded loading screen stays on top until first-run work is done and
    /// the first screen has been laid out and drawn underneath it.
    @State private var showStartup = true
    @StateObject private var lock = AppLock()
    @StateObject private var subscription = SubscriptionStore()
    @StateObject private var advertisements = HomeAdvertisementStore()
    @StateObject private var completionAdvertisements = CompletionAdvertisementStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ZStack {
                if let store {
                    FirstRunView().environmentObject(store)
                        .environment(\.colorScheme, .light)
                        .environment(\.startupCovered, showStartup)
                        // Not reachable (VoiceOver, UI tests) until it is revealed.
                        .accessibilityHidden(showStartup)
                }
                if showStartup {
                    StartupView().transition(.opacity).zIndex(1)
                }
            }
            .environmentObject(subscription).environmentObject(lock)
            .environmentObject(advertisements)
            .environmentObject(completionAdvertisements)
            .task {
                guard !startupStarted else { return }
                startupStarted = true
                lock.sceneChanged(scenePhase)
                // Let the branded view render before any startup work.
                await Task.yield()
#if DEBUG
                // Isolated UI previews only; production never delays startup.
                if ProcessInfo.processInfo.arguments.contains("--ui-test-session"),
                   ProcessInfo.processInfo.arguments.contains("--hold-launch-screen") { return }
#endif
                await prepareFirstScreen()
            }
            .onChange(of: scenePhase) { _, phase in
                lock.sceneChanged(phase)
                if phase == .active { Task { await subscription.refreshEntitlements() } }
            }
            .tint(Design.blue).preferredColorScheme(showStartup ? .dark : .light)
        }
    }

    /// Everything that used to stutter the first seconds after install happens
    /// behind the loading screen: opening the library, StoreKit's first
    /// entitlement read, Google Mobile Ads start-up (and the home ad request),
    /// and the first layout/draw of onboarding or home. Each wait is bounded, so
    /// a slow network or StoreKit never holds the app on the loading screen.
    @MainActor private func prepareFirstScreen() async {
        let adsWanted = HomeAdConfiguration.testAdsEnabled && !HomeAdvertisementStore.lastKnownPro
        if adsWanted {
            // Starts the SDK and requests the home ad in parallel with the library.
            advertisements.preload(locked: lock.locked)
        }
        async let library = makeLibrary()
        async let entitlements: Void = subscription.waitUntilResolved(timeout: .milliseconds(1000))
        async let sdk: Void = Self.waitForAds(adsWanted)
        store = await library
        _ = await (entitlements, sdk)
        // The first screen now lays out and draws once underneath the cover,
        // so its first-frame cost is not visible.
        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.easeOut(duration: 0.28)) { showStartup = false }
    }
    @MainActor private static func waitForAds(_ wanted: Bool) async {
        guard wanted else { return }
        await AdvertisingSDK.waitForStart(timeout: .milliseconds(1200))
    }
}
enum Design {
    static let blue = Color(red: 55/255, green: 105/255, blue: 159/255)
    static let cameraBlue = Color(red: 37/255, green: 99/255, blue: 235/255)
    static let pastelBlue = Color(red: 186/255, green: 216/255, blue: 255/255)
    static let softBlue = Color(red: 234/255, green: 243/255, blue: 255/255)
    static let blueInk = Color(red: 36/255, green: 78/255, blue: 131/255)
    static let ink = Color(red: 32/255, green: 35/255, blue: 41/255)
    static let muted = Color(red: 244/255, green: 245/255, blue: 246/255)
}
enum OfficeHeaderPalette {
    case word, excel, slides
    var gradient: LinearGradient {
        let colors:[Color]
        switch self {
        case .word: colors = [Color(red:0.85,green:0.91,blue:1),Color(red:0.91,green:0.96,blue:1),Color(red:0.94,green:0.93,blue:0.99)]
        case .excel: colors = [Color(red:0.85,green:0.95,blue:0.89),Color(red:0.92,green:0.98,blue:0.92),Color(red:0.91,green:0.96,blue:0.97)]
        case .slides: colors = [Color(red:1,green:0.88,blue:0.77),Color(red:1,green:0.95,blue:0.86),Color(red:1,green:0.92,blue:0.93)]
        }
        return LinearGradient(colors:colors,startPoint:.topLeading,endPoint:.bottomTrailing)
    }
    var ink:Color {
        switch self {
        case .word: return Design.blueInk
        case .excel: return Color(red:0.12,green:0.36,blue:0.26)
        case .slides: return Color(red:0.53,green:0.27,blue:0.12)
        }
    }
}
struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body, design: .default, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 18)
            .foregroundStyle(Design.blueInk).background(Design.pastelBlue.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 18))
            .opacity(isEnabled ? 1 : 0.5)
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var completion: ((Bool, Error?) -> Void)? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let view = UIActivityViewController(activityItems: items, applicationActivities: nil)
        view.completionWithItemsHandler = { _, completed, _, error in completion?(completed, error) }
        return view
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
struct SharedFile: Identifiable { let id = UUID(); let url: URL }
struct ScanRoute: Identifiable { let id: UUID }

@MainActor
private func makeLibrary() async -> LibraryStore {
#if DEBUG
    // Explicit UI-test sessions have isolated storage and never touch the user's library.
    let args = ProcessInfo.processInfo.arguments
    if let flag = args.firstIndex(of: "--ui-test-session"), args.indices.contains(flag+1),
       let session = UUID(uuidString: args[flag+1]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScannerUITests-" + session.uuidString)
        let store = await LibraryStore.open(root: root)
        if (args.contains("--seed-draft") || args.contains("--seed-saved")), store.documents.isEmpty {
            store.perform {
                let id = try store.createDraft()
                let needsEdgeReview = args.contains("--seed-unchecked")
                for i in 1...(needsEdgeReview ? 1 : 2) {
                    let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800)).image { context in
                        UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
                        ("SCANNER TEST PAGE \(i)" as NSString).draw(at: CGPoint(x: 45, y: 100), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 32), .foregroundColor: UIColor.black])
                        if args.contains("--seed-office-table") {
                            let rows = [["Product","Quantity","Price"],["Paper","12","24.50"],["Pens","8","16.00"],["Folders","5","10.00"]]
                            UIColor.black.setStroke()
                            for row in 0...4 { let p = UIBezierPath();p.move(to:CGPoint(x:30,y:200+row*90));p.addLine(to:CGPoint(x:570,y:200+row*90));p.lineWidth = 2;p.stroke() }
                            for col in 0...3 { let p = UIBezierPath();p.move(to:CGPoint(x:30+col*180,y:200));p.addLine(to:CGPoint(x:30+col*180,y:560));p.lineWidth = 2;p.stroke() }
                            for (r,row) in rows.enumerated() { for (c,value) in row.enumerated() {
                                (value as NSString).draw(at:CGPoint(x:40+c*180,y:230+r*90),withAttributes:[.font:UIFont.systemFont(ofSize:22),.foregroundColor:UIColor.black])
                            } }
                        }
                    }
                    try store.appendImage(image, to: id, detectedCrop: needsEdgeReview ? nil : .full)
                }
                if var doc = store.document(id) {
                    doc.title = "Test document"
                    try store.update(doc)
                    if args.contains("--seed-saved") {
                        try store.savePDF(Imaging.pdf(doc, root: store.root), document: doc)
                    }
                }
            }
        }
        return store
    }
#endif
    return await LibraryStore.open()
}
