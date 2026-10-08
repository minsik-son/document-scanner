import SwiftUI
import StoreKit

/// Where the paywall was opened from; the feature carousel starts on that slide.
enum PaywallStart: Equatable {
    case feature(ProFeature), smartTool, noAds, general
}

struct PaywallView: View {
    @EnvironmentObject var subscription: SubscriptionStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selected = SubscriptionStore.yearlyID
    @State private var privacy = false
    let start: PaywallStart
    init(start: PaywallStart = .general) { self.start = start }
    private var product: Product? { subscription.products.first { $0.id == selected } }
    private var plans: [Product] {
        subscription.products.sorted {
            (SubscriptionStore.productIDs.firstIndex(of: $0.id) ?? 99) < (SubscriptionStore.productIDs.firstIndex(of: $1.id) ?? 99)
        }
    }
    private var saving: Int? {
        guard let yearly = subscription.products.first(where: { $0.id == SubscriptionStore.yearlyID }),
              let monthly = subscription.products.first(where: { $0.id == SubscriptionStore.monthlyID }), monthly.price > 0 else { return nil }
        return SubscriptionStore.annualSavingsPercent(yearly: yearly.price, monthly: monthly.price)
    }
    /// Free trial days for the selected plan, when this account can still start one.
    private var trialDays: Int? {
        guard selected == SubscriptionStore.trialProductID, subscription.trialEligible else { return nil }
        return subscription.trialDays
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ProFeatureCarousel(start: start)
                    HStack(spacing: 12) {
                        Capsule().fill(TossPay.line).frame(height: 1)
                        Text("Unlimited access").font(.subheadline.weight(.semibold)).fixedSize()
                        Capsule().fill(TossPay.line).frame(height: 1)
                    }.padding(.horizontal, 40).padding(.top, 22)
                    VStack(spacing: 10) {
                        if plans.isEmpty {
                            Text("Plans are currently unavailable. You can keep scanning for free.").multilineTextAlignment(.center).foregroundStyle(TossPay.sub)
                            Button("Reload plans") { Task { await subscription.load() } }.disabled(subscription.busy)
                        } else {
                            ForEach(plans) { plan in planCard(plan) }
                        }
                    }.padding(.horizontal, 16).padding(.top, 20)
                    Text("Scanning, PDF and signing stay free. Your documents stay yours, even if you cancel.")
                        .font(.footnote).foregroundStyle(TossPay.sub).multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.top, 14)
                    if typeSize.isAccessibilitySize { purchaseFooter.padding(.top, 12) }
                }.padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea(edges: .top)
            .background(Color.white.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { if !typeSize.isAccessibilitySize { purchaseFooter } }
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(.black.opacity(0.25), in: Circle())
                }
                .accessibilityLabel("Close").disabled(subscription.busy)
                .padding(.trailing, 16).padding(.top, 6)
            }
            .toolbar(.hidden, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .onChange(of: subscription.isPro) { _, active in if active { dismiss() } }
            .onChange(of: subscription.products.map(\.id), initial: true) { _, ids in
                if !ids.contains(selected), let first = plans.first { selected = first.id }
            }
            .interactiveDismissDisabled(subscription.busy)
            .sheet(isPresented: $privacy) { PrivacyView().environment(\.colorScheme, .light) }
        }
        .environment(\.colorScheme, .light)
        .foregroundStyle(TossPay.ink)
    }
    private var hero: some View {
        ZStack {
            Canvas { context, size in
                for i in 0..<36 {
                    let x = CGFloat((i * 89) % 320) / 320 * size.width, y = CGFloat((i * 53) % 230) / 230 * size.height
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.8, height: 1.8)), with: .color(.white.opacity(0.3)))
                }
            }
            Circle().fill(RadialGradient(colors: [Color(red: 0.73, green: 0.65, blue: 1).opacity(0.6), .clear], center: .center, startRadius: 0, endRadius: 120))
                .frame(width: 240, height: 240)
            Circle().stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 7])).frame(width: 184, height: 184)
            ProArt().frame(width: 176, height: 160)
            chip(".docx").offset(x: -112, y: -26)
            chip("OCR").offset(x: 112, y: -50)
            chip(".xlsx").offset(x: 110, y: 62)
        }.frame(height: 230).frame(maxWidth: .infinity).clipped()
    }
    private func chip(_ text: String) -> some View {
        Text(L(text)).font(.system(size: 12, weight: .heavy)).padding(.horizontal, 12).padding(.vertical, 6).background(.white.opacity(0.14), in: Capsule())
    }
    /// Every tool that shows a Pro badge, so the count stays right as tools change.
    static var proToolCount: Int {
        AdvancedTool.allCases.filter { $0.pro && !$0.hidden }.count
            + LibraryTool.allCases.filter(\.pro).count
            + SmartTool.allCases.filter { $0.pro && $0.shown }.count
    }
    private func feature(_ title: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(tint, in: RoundedRectangle(cornerRadius: 8))
            Text(L(title)).font(.caption.weight(.bold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(10).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
    private func planCard(_ plan: Product) -> some View {
        let annual = plan.id == SubscriptionStore.yearlyID
        let lifetime = plan.id == SubscriptionStore.lifetimeID
        let active = selected == plan.id
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button { selected = plan.id } label: {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lifetime ? "Lifetime" : annual ? "Yearly" : "Monthly").font(.headline)
                    Group {
                        if lifetime, let end = FoundingOffer.endDate, FoundingOffer.active {
                            if let regular = FoundingOffer.regularPrice(for: plan) {
                                Text("Launch price until \(end.formatted(.dateTime.month(.abbreviated).day())), then \(regular)")
                            } else {
                                Text("Launch price until \(end.formatted(.dateTime.month(.abbreviated).day()))")
                            }
                        }
                        else if lifetime { Text("One-time purchase. No subscription.") }
                        else if annual {
                            if subscription.trialEligible, let days = subscription.trialDays { Text("\(days) days free · \((plan.price / 12).formatted(plan.priceFormatStyle))/month, billed yearly") }
                            else { Text("\((plan.price / 12).formatted(plan.priceFormatStyle)) / month, billed yearly") }
                        } else { Text("Cancel anytime") }
                    }.font(.caption).foregroundStyle(TossPay.sub).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 1) {
                    if lifetime, FoundingOffer.active, let regular = FoundingOffer.regularPrice(for: plan) {
                        Text(verbatim: regular).font(.caption).strikethrough().foregroundStyle(TossPay.sub)
                    }
                    Text(LS(lifetime ? "\(plan.displayPrice) once" : annual ? "\(plan.displayPrice) / year" : "\(plan.displayPrice) / month")).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(active ? AnyShapeStyle(TossPay.selected) : AnyShapeStyle(Color.white), in: shape)
            .overlay(shape.strokeBorder(active ? AnyShapeStyle(TossPay.blue) : AnyShapeStyle(TossPay.line), lineWidth: active ? 2 : 1.5))
            .overlay(alignment: .topTrailing) {
                if annual, let saving {
                    Text("BEST · SAVE \(saving)%").font(.caption2.weight(.heavy)).foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 3)
                        .background(TossPay.blue, in: Capsule()).offset(x: -14, y: -10)
                }
            }
            .overlay(alignment: .topLeading) {
                if lifetime, let days = FoundingOffer.daysLeft {
                    Text(days == 1 ? "FOUNDING PRICE · 1 DAY LEFT" : "FOUNDING PRICE · \(days) DAYS LEFT")
                        .font(.caption2.weight(.heavy)).foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 3)
                        .background(FoundingOffer.ribbon, in: Capsule()).offset(x: 14, y: -10)
                        .accessibilityIdentifier("founding-price")
                }
            }
            .padding(.top, annual || (lifetime && FoundingOffer.active) ? 6 : 0)
        }.buttonStyle(.plain).disabled(subscription.busy)
            .accessibilityIdentifier(lifetime ? "plan-lifetime" : annual ? "plan-yearly" : "plan-monthly").accessibilityAddTraits(active ? .isSelected : [])
    }
    private var purchaseFooter: some View {
        VStack(spacing: 10) {
            if let message = subscription.message { Text(L(message)).font(.footnote).foregroundStyle(TossPay.sub).accessibilityIdentifier("purchase-status") }
            if let product {
                Button { Task { await subscription.purchase(product) } } label: {
                    VStack(spacing: 2) {
                        if subscription.busy { ProgressView().tint(.white) }
                        else if let days = trialDays {
                            Text("Start \(days)-day free trial").font(.headline.weight(.heavy))
                            Text("then \(product.displayPrice)/year").font(.caption.weight(.semibold)).opacity(0.85)
                        }
                        else if product.id == SubscriptionStore.lifetimeID { Text("Buy once for \(product.displayPrice)").font(.headline.weight(.heavy)) }
                        else { Text(LS(product.id == SubscriptionStore.yearlyID ? "Subscribe for \(product.displayPrice)/year" : "Subscribe for \(product.displayPrice)/month")).font(.headline.weight(.heavy)) }
                    }
                    .frame(maxWidth: .infinity).frame(minHeight: 54).padding(.vertical, 4)
                    .foregroundStyle(.white)
                    .background(TossPay.blue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                }.buttonStyle(.plain).disabled(subscription.busy).accessibilityIdentifier("subscribe-button")
                Text(legal(product))
                    .font(.caption2).foregroundStyle(TossPay.sub).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 18) {
                Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Text("|").opacity(0.3)
                Button("Privacy") { privacy = true }
                Text("|").opacity(0.3)
                Button("Restore purchases") { Task { await subscription.restore() } }.disabled(subscription.busy)
            }.font(.caption).foregroundStyle(TossPay.sub)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10).frame(maxWidth: .infinity)
        .background(Color.white)
    }
    private func legal(_ product: Product) -> String {
        if product.id == SubscriptionStore.lifetimeID {
            return "One-time payment charged to your Apple Account. Pro stays unlocked; restore it on your other devices with Restore purchases."
        }
        if let days = trialDays {
            return "Free for \(days) days, then \(product.displayPrice)/year renews automatically until canceled. We'll remind you 2 days before the trial ends. Cancel anytime in Me or your Apple Account settings."
        }
        return "Auto-renews until canceled. Payment is charged to your Apple Account. Cancel at least 24 hours before renewal in App Store account settings."
    }
}
struct PrivacyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Your documents stay with you").font(.title.bold())
                    Text("This build stores your scans and recognized text in the app on this iPhone. Camera processing and text recognition happen on device. There is no developer-operated document server or account system.")
                    Text("The free version can show one Google AdMob advertisement on Home, below your documents, and one in Tools. A short video ad plays only when you choose to watch one for an extra free try of a Pro tool. Ads never open full screen on their own and never delay scanning or saving. No ads appear in the first day after install. Pro users do not load or display advertisements. This development build uses official test advertisements only; release-build advertising is disabled pending live setup.")
                    Text("The app does not send your scanned pages, document names, or recognized text to the advertising SDK. Google may process device, network and ad-interaction information to serve advertisements. Scanning and PDF creation remain available offline.")
                    Link("Google advertising privacy information", destination: URL(string: "https://policies.google.com/technologies/ads")!)
                    Text("Sharing sends only the items you select to the app or destination you choose. Exported backups are not encrypted. Files saved outside this app are controlled by that destination.")
                    Text("Apple processes subscription and one-time payments. The app uses Apple's verified purchase records to check Pro access. Device backups may include app data according to your iPhone backup settings.")
                    Text("To remove local documents, move them to Trash and permanently delete them. Copies you previously exported must be removed separately.")
                    Text("Development preview: a published privacy policy and developer contact must be supplied before App Store distribution.").font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }.navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}


/// The top of the paywall: one Pro feature per slide, with its animation,
/// advancing on its own every few seconds (CamScanner-style, our colours).
struct ProFeatureCarousel: View {
    private struct Slide { let title: String; let detail: String; let art: String?; let stage: Color }
    /// Only Pro benefits: text recognition, copying and search are free, so they are not here.
    private static let slides: [Slide] = [
        Slide(title: "Word · Excel · PowerPoint", detail: "Turn any scan into a file you can edit", art: "art-word", stage: TossPay.stage),
        Slide(title: "Translate photos", detail: "Read signs, menus and letters in your language", art: "art-translate", stage: Color(hex: 0xE3F5EC)),
        Slide(title: "Hide personal info", detail: "Cover ID, card and phone numbers in one tap", art: "art-redact", stage: Color(hex: 0xEFEAFE)),
        Slide(title: "Fill forms in seconds", detail: "Your name, address and signature, placed for you", art: "art-fill-form", stage: Color(hex: 0xFFEFE0)),
        Slide(title: "Restore old photos", detail: "Bring faded prints back to life", art: "art-restore", stage: Color(hex: 0xFFF4D6)),
        Slide(title: "Lock & compress PDFs", detail: "Password-protect and shrink big files", art: "art-protect", stage: Color(hex: 0xFDE8EF)),
        Slide(title: "Auto-save to iCloud Drive or Dropbox", detail: "Every new scan lands in your folder", art: "art-auto-save", stage: Color(hex: 0xF3EEE6)),
        Slide(title: "Unlimited signatures & merges", detail: "Save every signature and combine any number of PDFs", art: "art-merge", stage: Color(hex: 0xE9F3DC)),
        Slide(title: "No ads", detail: "Every screen stays clean", art: nil, stage: Color(hex: 0xFFE9E6)),
    ]
    static func index(for start: PaywallStart) -> Int {
        switch start {
        case .feature(.office): return 0
        case .feature(.translate): return 1
        case .feature(.redact): return 2
        case .feature(.fillForm): return 3
        case .feature(.image): return 4
        case .feature(.pdf): return 5
        case .smartTool: return 6
        case .noAds: return slides.count - 1
        case .general: return 0
        }
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index: Int
    init(start: PaywallStart = .general) { _index = State(initialValue: Self.index(for: start)) }
    var body: some View {
        VStack(spacing: 14) {
            TabView(selection: $index) {
                ForEach(Self.slides.indices, id: \.self) { i in slide(Self.slides[i], live: i == index).tag(i) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 430)
            HStack(spacing: 6) {
                ForEach(Self.slides.indices, id: \.self) { i in
                    Capsule().fill(i == index ? AnyShapeStyle(TossPay.blue) : AnyShapeStyle(TossPay.dotOff))
                        .frame(width: i == index ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: index)
            .accessibilityElement().accessibilityLabel("Feature \(index + 1) of \(Self.slides.count)")
            Text("All \(PaywallView.proToolCount) Pro tools, unlimited signatures and merges")
                .font(.caption.weight(.semibold)).foregroundStyle(TossPay.sub)
        }
    }
    private func slide(_ slide: Slide, live: Bool) -> some View {
        // Two flat colours, no gradient: a pale stage of the slide's own colour for the art, white below for the words.
        VStack(spacing: 0) {
            ZStack {
                slide.stage
                Group {
                    if let art = slide.art {
                        AnimatedPNG(asset: art, stillFrame: 60, animates: live && !reduceMotion)
                            .frame(width: 320, height: 200)
                    } else {
                        ProArt().frame(width: 190, height: 170)
                    }
                }
                .padding(.top, 40)
                .accessibilityHidden(true)
            }
            .frame(height: 300)
            VStack(spacing: 6) {
                Text(L(slide.title)).font(.system(.title, weight: .black)).multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6).lineLimit(2)
                Text(L(slide.detail)).font(.subheadline).foregroundStyle(TossPay.sub).multilineTextAlignment(.center)
            }
            .foregroundStyle(TossPay.ink).padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        }
    }
}


/// Launch offer for the lifetime plan: the first 30 days after release sell it at
/// the founding price (set in App Store Connect as a scheduled price change).
/// The paywall shows the days left and the regular price it goes back to.
enum FoundingOffer {
    static let days = 30
    /// Release day. Set this before submitting; Release builds hide the offer until it is set.
    static let launchDay: DateComponents? = nil
    static let ribbon = Color(red: 1, green: 0.541, blue: 0)                  // #FF8A00
    /// Regular lifetime price after the offer, per App Store currency.
    static let regularPrices: [String: Decimal] = ["USD": Decimal(string: "59.99")!, "KRW": 79000]
    static var launchDate: Date? {
        if let launchDay, let date = Calendar.current.date(from: launchDay) { return Calendar.current.startOfDay(for: date) }
        #if DEBUG
        // Preview in development builds: as if the app came out a week ago.
        return Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: Date()))
        #else
        return nil
        #endif
    }
    static var endDate: Date? { launchDate.flatMap { Calendar.current.date(byAdding: .day, value: days, to: $0) } }
    static var daysLeft: Int? {
        guard let end = endDate, end > Date() else { return nil }
        let left = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: end).day ?? 1
        return max(1, left)
    }
    static var active: Bool { daysLeft != nil }
    static func regularPrice(for product: Product) -> String? {
        guard let value = regularPrices[product.priceFormatStyle.currencyCode], value > product.price else { return nil }
        return value.formatted(product.priceFormatStyle)
    }
}

/// Paywall colours: Toss-style light page with one blue.
enum TossPay {
    static let blue = Color(red: 0.192, green: 0.510, blue: 0.965)      // #3182F6
    static let stage = Color(red: 0.910, green: 0.953, blue: 1)        // #E8F3FF
    static let selected = Color(red: 0.957, green: 0.976, blue: 1)     // #F4F9FF
    static let ink = Color(red: 0.098, green: 0.122, blue: 0.157)      // #191F28
    static let sub = Color(red: 0.420, green: 0.463, blue: 0.518)      // #6B7684
    static let line = Color(red: 0.898, green: 0.910, blue: 0.922)     // #E5E8EB
    static let dotOff = Color(red: 0.820, green: 0.839, blue: 0.859)   // #D1D6DB
}
