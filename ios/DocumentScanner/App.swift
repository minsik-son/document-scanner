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
    @AppStorage(AppLanguage.key) private var language = ""
    var body: some Scene {
        WindowGroup {
            ZStack {
                if let store {
                    FirstRunView().environmentObject(store)
                        // In-app language: every Text picks its strings from this locale;
                        // .id rebuilds the screens when the language changes.
                        .environment(\.locale, AppLanguage.locale)
                        .id(language)
                        .environment(\.colorScheme, .light)
                        .environment(\.startupCovered, showStartup)
                        // Not reachable (VoiceOver, UI tests, touches) until it is revealed.
                        .accessibilityHidden(showStartup)
                        .allowsHitTesting(!showStartup)
                }
                if showStartup {
                    // The cover has no controls. While it fades out it must not swallow
                    // the first tap or swipe meant for the screen underneath.
                    StartupView().allowsHitTesting(false).transition(.opacity).zIndex(1)
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
#if DEBUG
                // Screenshot of the missing-language guide for App Review notes.
                if ProcessInfo.processInfo.arguments.contains("--preview-translation-guide") {
                    try? await Task.sleep(for: .seconds(2))
                    TranslationLanguageGuide.present(source: "ko", target: "en")
                }
#endif
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
/// Name, version and public links in one place. The name shown in the app is the
/// home-screen name from Info.plist, so the two can never disagree.
enum AppInfo {
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "HushScan" }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    /// Published privacy policy and support pages (GitHub Pages, docs/ folder of the repository).
    static let privacyPolicy = "https://minsik-son.github.io/document-scanner/privacy.html"
    static let support = "https://minsik-son.github.io/document-scanner/support.html"
    /// Apple's standard licensed application end user license agreement.
    static let terms = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    static var privacyPolicyURL: URL { URL(string: privacyPolicy)! }
    static var supportURL: URL { URL(string: support)! }
    static var termsURL: URL { URL(string: terms)! }
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
/// Same size as PrimaryButton, white with a light rim, for the second action.
struct SecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.body, design: .default, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 18)
            .foregroundStyle(Design.blueInk)
            .background(configuration.isPressed ? Design.muted : .white, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(red: 0.898, green: 0.910, blue: 0.922), lineWidth: 1.5))
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


/// The app's own language setting (Settings › Language). Defaults to the
/// device language when it is one we ship, otherwise English.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, ko, ja, es, ptBR = "pt-BR", de, fr, it, pl, tr, indonesian = "id", vi, th, zhHans = "zh-Hans", zhHant = "zh-Hant"
    var id: String { rawValue }
    /// Each language is named in itself, as in the iOS language list.
    var nativeName: String {
        switch self {
        case .en: "English"
        case .ko: "한국어"
        case .ja: "日本語"
        case .es: "Español"
        case .ptBR: "Português (Brasil)"
        case .de: "Deutsch"
        case .fr: "Français"
        case .it: "Italiano"
        case .pl: "Polski"
        case .tr: "Türkçe"
        case .indonesian: "Bahasa Indonesia"
        case .vi: "Tiếng Việt"
        case .th: "ไทย"
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        }
    }
    static let key = "app-language"
    static var current: AppLanguage {
        if let saved = UserDefaults.standard.string(forKey: key), let value = AppLanguage(rawValue: saved) { return value }
        return matching(Locale.preferredLanguages.first ?? "en")
    }
    /// Maps a device language code (e.g. "zh-Hant-TW", "zh-HK", "pt-PT", "es-MX") to a language we ship.
    static func matching(_ code: String) -> AppLanguage {
        let parts = code.split(separator: "-").map(String.init)
        guard let base = parts.first else { return .en }
        switch base {
        case "zh":
            let rest = Set(parts.dropFirst())
            return rest.contains("Hant") || rest.contains("TW") || rest.contains("HK") || rest.contains("MO") ? .zhHant : .zhHans
        case "pt": return .ptBR
        case "in": return .indonesian   // legacy code for Indonesian
        default: return AppLanguage(rawValue: base) ?? .en
        }
    }
    static var locale: Locale { Locale(identifier: current.rawValue) }
    /// Strings for the chosen language (English lives in the source itself).
    static var bundle: Bundle {
        guard current != .en, let path = Bundle.main.path(forResource: current.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
    static func choose(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
        // System-provided text (share sheets, permission prompts) follows on the next launch.
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}

/// Translates a runtime string (tool names, messages built from literals) into the
/// chosen app language. Strings without a translation come back unchanged.
func L(_ text: String) -> String {
    AppLanguage.current == .en ? text : Localizer.shared.translate(text)
}
func L(_ key: LocalizedStringKey) -> LocalizedStringKey { key }
func L(_ text: AttributedString) -> AttributedString { text }
func L(_ text: Substring) -> String { L(String(text)) }
/// Single-overload form for ternaries of literals, which `L` can't disambiguate.
func LS(_ text: String) -> String { L(text) }

/// Looks strings up in the chosen language. A string that was built at runtime
/// ("Reading page 3 of 8…") has no key of its own, so it is matched against the
/// format keys ("Reading page %lld of %lld…"), its values pulled out and the
/// translated format filled in — counts get the language's plural rules from the
/// .stringsdict, and text values are translated too.
final class Localizer {
    static let shared = Localizer()
    private struct Pattern { let key: String; let regex: NSRegularExpression; let numbers: [Bool]; let weight: Int }
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var cachedLanguage: AppLanguage?
    private lazy var patterns: [Pattern] = Localizer.loadPatterns()

    func translate(_ text: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let language = AppLanguage.current
        if language != cachedLanguage { cache.removeAll(); cachedLanguage = language }
        if let hit = cache[text] { return hit }
        let result = resolve(text, depth: 0)
        cache[text] = result
        return result
    }

    private func lookup(_ key: String) -> String? {
        let missing = "\u{1}"
        let value = AppLanguage.bundle.localizedString(forKey: key, value: missing, table: nil)
        return value == missing ? nil : value
    }

    private func resolve(_ text: String, depth: Int) -> String {
        if let value = lookup(text) { return value }
        guard depth < 3, !text.isEmpty, text.count < 600 else { return text }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        for pattern in patterns {
            guard let match = pattern.regex.firstMatch(in: text, range: whole) else { continue }
            var args: [CVarArg] = []
            for (index, isNumber) in pattern.numbers.enumerated() {
                let piece = ns.substring(with: match.range(at: index + 1))
                if isNumber {
                    guard let number = Int(piece.replacingOccurrences(of: ",", with: "")) else { break }
                    args.append(number)
                } else {
                    args.append(resolve(piece, depth: depth + 1) as NSString)
                }
            }
            guard args.count == pattern.numbers.count, let format = lookup(pattern.key) else { continue }
            return String(format: format, locale: AppLanguage.locale, arguments: args)
        }
        return text
    }

    private static func loadPatterns() -> [Pattern] {
        guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "ko"),
              let table = NSDictionary(contentsOfFile: path) as? [String: String],
              let spec = try? NSRegularExpression(pattern: "%%|%(?:\\d+\\$)?(lld|ld|d|@)") else { return [] }
        var result: [Pattern] = []
        for key in table.keys where key.contains("%") {
            let ns = key as NSString
            var regex = "^", numbers: [Bool] = [], cursor = 0, literal = 0
            for match in spec.matches(in: key, range: NSRange(location: 0, length: ns.length)) {
                let text = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                regex += NSRegularExpression.escapedPattern(for: text); literal += text.count
                if match.range(at: 1).location == NSNotFound {
                    regex += "%"; literal += 1
                } else {
                    let isNumber = ns.substring(with: match.range(at: 1)) != "@"
                    numbers.append(isNumber)
                    regex += isNumber ? "(-?\\d[\\d,]*)" : "(.+?)"
                }
                cursor = match.range.location + match.range.length
            }
            let tail = ns.substring(from: cursor)
            regex += NSRegularExpression.escapedPattern(for: tail) + "$"; literal += tail.count
            guard !numbers.isEmpty, literal >= 3,
                  let compiled = try? NSRegularExpression(pattern: regex, options: [.dotMatchesLineSeparators]) else { continue }
            result.append(Pattern(key: key, regex: compiled, numbers: numbers, weight: literal))
        }
        return result.sorted { $0.weight > $1.weight }
    }
}
