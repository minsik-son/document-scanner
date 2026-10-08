import SwiftUI
import StoreKit

/// Colours, art and small pieces shared by the Pro entry points: the home
/// header badge, the Me membership banner, the benefits card and the paywall.
enum ProStyle {
    static let gradient = LinearGradient(colors: [Color(red: 0.24, green: 0.48, blue: 1), Color(red: 0.48, green: 0.36, blue: 1), Color(red: 1, green: 0.42, blue: 0.55)],
                                         startPoint: .leading, endPoint: .trailing)
    static let trial = LinearGradient(colors: [Color(red: 1, green: 0.69, blue: 0.13), Color(red: 1, green: 0.48, blue: 0.35)], startPoint: .leading, endPoint: .trailing)
    static let trialBanner = LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.26), Color(red: 1, green: 0.42, blue: 0.55), Color(red: 0.71, green: 0.36, blue: 1)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)
    static let gold = LinearGradient(colors: [Color(red: 1, green: 0.88, blue: 0.54), Color(red: 1, green: 0.64, blue: 0.11)], startPoint: .top, endPoint: .bottom)
    static let titleGradient = LinearGradient(colors: [Color(red: 0.62, green: 0.72, blue: 1), Color(red: 0.84, green: 0.66, blue: 1), Color(red: 1, green: 0.62, blue: 0.71)],
                                              startPoint: .leading, endPoint: .trailing)
    static let night = Color(red: 0.06, green: 0.063, blue: 0.14)
    static let violet = Color(red: 0.48, green: 0.36, blue: 1)
}

/// Pro look: a dusk band behind the top of Home, All tools and Settings over a soft
/// lavender page. Screens where a document is being worked on keep the plain page.
enum ProTheme {
    static let page = Color(red: 0.945, green: 0.941, blue: 0.98)
    static let dusk = LinearGradient(colors: [Color(red: 0.129, green: 0.110, blue: 0.333), Color(red: 0.180, green: 0.153, blue: 0.439), Color(red: 0.231, green: 0.196, blue: 0.565)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
    static let action = LinearGradient(colors: [Color(red: 0.357, green: 0.486, blue: 1), Color(red: 0.545, green: 0.361, blue: 0.965)], startPoint: .leading, endPoint: .trailing)
    static let goldPill = LinearGradient(colors: [Color(red: 1, green: 0.84, blue: 0.42), Color(red: 1, green: 0.70, blue: 0.25)], startPoint: .leading, endPoint: .trailing)
    static let goldInk = Color(red: 0.35, green: 0.23, blue: 0)
}

/// Dusk band (status bar plus `band` points) fading into the lavender page.
struct ProPageBackground: View {
    let band: CGFloat
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ProTheme.dusk.frame(height: proxy.safeAreaInsets.top + band)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [ProTheme.page.opacity(0), ProTheme.page], startPoint: .top, endPoint: .bottom).frame(height: 22)
                    }
                ProTheme.page
            }
            .ignoresSafeArea()
        }
        .accessibilityHidden(true)
    }
}

/// A soft highlight that sweeps across a button every few seconds.
struct ProShine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false
    var body: some View {
        GeometryReader { geometry in
            if !reduceMotion {
                LinearGradient(colors: [.clear, .white.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geometry.size.width * 0.35)
                    .rotationEffect(.degrees(18))
                    .offset(x: moving ? geometry.size.width * 1.3 : -geometry.size.width * 0.5)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.3).delay(1.8).repeatForever(autoreverses: false)) { moving = true }
                    }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct CrownShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.minY + y * h) }
        p.move(to: pt(0.12, 0.34)); p.addLine(to: pt(0.31, 0.52)); p.addLine(to: pt(0.5, 0.2))
        p.addLine(to: pt(0.69, 0.52)); p.addLine(to: pt(0.88, 0.34)); p.addLine(to: pt(0.8, 0.76)); p.addLine(to: pt(0.2, 0.76))
        p.closeSubpath()
        p.addRoundedRect(in: CGRect(x: r.minX + 0.2 * w, y: r.minY + 0.79 * h, width: 0.6 * w, height: 0.11 * h), cornerSize: CGSize(width: 0.04 * w, height: 0.04 * w))
        return p
    }
}

struct CrownIcon: View {
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            CrownShape().fill(ProStyle.gold)
            ForEach([CGPoint(x: 0.12, y: 0.32), CGPoint(x: 0.5, y: 0.17), CGPoint(x: 0.88, y: 0.32)], id: \.x) { tip in
                Circle().fill(Color(red: 1, green: 0.82, blue: 0.37)).frame(width: size * 0.13, height: size * 0.13)
                    .position(x: tip.x * size, y: tip.y * size)
            }
        }.frame(width: size, height: size)
            .shadow(color: Color.orange.opacity(0.35), radius: 2, y: 1)
            .accessibilityHidden(true)
    }
}

/// Stacked pages with a crown and sparkles: the Pro illustration.
struct ProArt: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width / 120, g.size.height / 110)
            ZStack {
                Ellipse().fill(.black.opacity(0.16)).frame(width: 84 * s, height: 13 * s).offset(y: 46 * s)
                RoundedRectangle(cornerRadius: 9 * s).fill(Color(red: 0.79, green: 0.84, blue: 1))
                    .frame(width: 52 * s, height: 68 * s).rotationEffect(.degrees(-10)).offset(x: -16 * s, y: 0)
                VStack(alignment: .leading, spacing: 5 * s) {
                    Capsule().fill(ProStyle.violet).frame(width: 30 * s, height: 5 * s)
                    Capsule().fill(Color(red: 0.78, green: 0.81, blue: 0.9)).frame(width: 38 * s, height: 4 * s)
                    Capsule().fill(Color(red: 0.78, green: 0.81, blue: 0.9)).frame(width: 33 * s, height: 4 * s)
                    HStack(spacing: 3 * s) {
                        RoundedRectangle(cornerRadius: 2 * s).fill(Color(red: 0.29, green: 0.55, blue: 1)).frame(width: 12 * s, height: 6 * s)
                        RoundedRectangle(cornerRadius: 2 * s).fill(Color(red: 1, green: 0.56, blue: 0.67)).frame(width: 15 * s, height: 6 * s)
                    }.padding(4 * s).background(Color(red: 0.9, green: 0.93, blue: 1), in: RoundedRectangle(cornerRadius: 4 * s))
                    Capsule().fill(Color(red: 0.78, green: 0.81, blue: 0.9)).frame(width: 22 * s, height: 4 * s)
                }
                .frame(width: 56 * s, height: 74 * s)
                .background(LinearGradient(colors: [.white, Color(red: 0.91, green: 0.93, blue: 1)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 10 * s))
                .rotationEffect(.degrees(6)).offset(x: 12 * s, y: -4 * s)
                .shadow(color: .black.opacity(0.12), radius: 6 * s, y: 4 * s)
                CrownIcon(size: 34 * s).offset(x: -26 * s, y: -34 * s)
                Image(systemName: "sparkle").font(.system(size: 15 * s, weight: .bold)).foregroundStyle(.white).offset(x: 48 * s, y: -42 * s)
                Image(systemName: "sparkle").font(.system(size: 10 * s, weight: .bold)).foregroundStyle(.white).offset(x: -46 * s, y: 18 * s)
                Image(systemName: "sparkle").font(.system(size: 8 * s, weight: .bold)).foregroundStyle(.white).offset(x: 50 * s, y: 30 * s)
            }.frame(width: g.size.width, height: g.size.height)
        }.accessibilityHidden(true)
    }
}

/// Top-left of Home: "Get PRO" for free users, the trial countdown during a
/// trial, and a quiet crown once Pro is active.
struct ProHeaderBadge: View {
    @EnvironmentObject var subscription: SubscriptionStore
    let openPaywall: () -> Void
    let openMembership: () -> Void
    var body: some View {
        if !subscription.isPro {
            pill(ProStyle.gradient, glow: ProStyle.violet) {
                Text("Get ") + Text("PRO").fontWeight(.black)
            } action: { openPaywall() }
                .accessibilityLabel("Get Pro").accessibilityIdentifier("home-pro")
        } else if let days = subscription.trialDaysLeft {
            pill(ProStyle.trial, glow: .orange) {
                Text(days == 1 ? "Trial · 1 day left" : "Trial · \(days) days left")
            } action: { openMembership() }
                .accessibilityIdentifier("home-pro-trial")
        } else {
            Button(action: openMembership) {
                HStack(spacing: 5) {
                    Image(systemName: "crown.fill").font(.system(size: 12, weight: .bold))
                    Text("PRO").font(.system(size: 13, weight: .black)).tracking(0.4)
                }
                .foregroundStyle(ProTheme.goldInk)
                .padding(.horizontal, 13).frame(height: 32)
                .background(ProTheme.goldPill, in: Capsule())
                .contentShape(Capsule())
            }.buttonStyle(.plain).accessibilityLabel("Pro membership").accessibilityIdentifier("home-pro-active")
        }
    }
    private func pill<Label: View>(_ fill: LinearGradient, glow: Color, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22).background(.white.opacity(0.22), in: Circle())
                label().font(.system(size: 12.5, weight: .heavy))
            }
            .padding(.leading, 4).padding(.trailing, 12).frame(height: 30)
            .foregroundStyle(.white)
            .background(fill, in: Capsule())
            .overlay(ProShine().clipShape(Capsule()))
            .shadow(color: glow.opacity(0.3), radius: 6, y: 3)
        }.buttonStyle(.plain)
    }
}

/// The banner at the top of Me: what plan you have and what to do next.
struct MembershipBanner: View {
    @EnvironmentObject var subscription: SubscriptionStore
    let explore: () -> Void
    let manage: () -> Void
    var body: some View {
        Group {
            if !subscription.isPro { free }
            else if let days = subscription.trialDaysLeft { trial(days) }
            else { member }
        }
    }
    private var free: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unlock\n\(AppInfo.name) Pro").font(.system(.title3, weight: .black)).fixedSize(horizontal: false, vertical: true)
                Text("Office export, translation, photo tools and no ads.").font(.footnote).opacity(0.92)
                    .frame(maxWidth: 190, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                Button(action: explore) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.caption.weight(.bold))
                        Text(subscription.trialEligible && subscription.trialDays != nil ? "Try free" : "See plans")
                    }
                    .font(.subheadline.weight(.heavy)).foregroundStyle(Color(red: 0.29, green: 0.23, blue: 0.84))
                    .padding(.horizontal, 16).padding(.vertical, 10).background(.white, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                }.buttonStyle(.plain).padding(.top, 8)
                    .accessibilityLabel("Explore Pro")
                if let lifetime = subscription.products.first(where: { $0.id == SubscriptionStore.lifetimeID }),
                   FoundingOffer.applies(to: lifetime), let days = FoundingOffer.daysLeft {
                    // The launch price on the lifetime plan, with the days it has left.
                    Text(days == 1 ? "Lifetime \(lifetime.displayPrice) · founding price, 1 day left" : "Lifetime \(lifetime.displayPrice) · founding price, \(days) days left")
                        .font(.caption2.weight(.heavy)).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.white.opacity(0.22), in: Capsule()).padding(.top, 4)
                        .accessibilityIdentifier("founding-banner")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            ProArt().frame(width: 96, height: 90).offset(x: 6, y: 6)
        }
        .bannerStyle(AnyShapeStyle(ProStyle.gradient), glow: ProStyle.violet)
    }
    private func trial(_ days: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.white.opacity(0.3), lineWidth: 6)
                    Circle().trim(from: 0, to: subscription.trialProgress).stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(days)d").font(.system(.subheadline, weight: .black))
                }.frame(width: 60, height: 60).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Free trial").font(.system(.title3, weight: .black))
                    activeChip
                    if let end = subscription.trialEndsAt {
                        Text(trialDetail(end)).font(.caption).opacity(0.92).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            manageButton(tint: Color(red: 0.89, green: 0.33, blue: 0.48))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bannerStyle(AnyShapeStyle(ProStyle.trialBanner), glow: .orange)
    }
    private var member: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    CrownIcon(size: 26)
                    Text("Pro Member").font(.system(.title3, weight: .black)).foregroundStyle(ProStyle.gold)
                }
                activeChip
                Text(L(memberDetail)).font(.caption).opacity(0.8).frame(maxWidth: 190, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if subscription.planID != nil {
                    manageButton(tint: .white, filled: false).padding(.top, 6)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            ProArt().frame(width: 92, height: 86).offset(x: 6, y: 6)
        }
        .bannerStyle(AnyShapeStyle(ProTheme.dusk), glow: Color(red: 1, green: 0.78, blue: 0.35))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color(red: 1, green: 0.84, blue: 0.42).opacity(0.55), lineWidth: 1))
    }
    private var activeChip: some View {
        Text("Pro is active").font(.caption2.weight(.heavy)).padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.2), in: Capsule())
    }
    private func manageButton(tint: Color, filled: Bool = true) -> some View {
        Button(action: manage) {
            Text("Manage subscription").font(.subheadline.weight(.heavy))
                .foregroundStyle(filled ? tint : .white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.14)), in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("manage-subscription")
    }
    private func trialDetail(_ end: Date) -> String {
        let date = end.formatted(date: .abbreviated, time: .omitted)
        guard subscription.willRenew else { return "Ends \(date). Renewal is off." }
        if let price = subscription.renewalPrice { return "Ends \(date) · then \(price)/\(subscription.renewalUnit)" }
        return "Ends \(date)"
    }
    private var memberDetail: String {
        if subscription.lifetime { return "Unlocked for life" }
        if let date = subscription.expiresAt, subscription.planID != nil {
            let plan = subscription.planID == SubscriptionStore.yearlyID ? "Yearly plan" : "Monthly plan"
            return subscription.willRenew ? "\(plan) · renews \(date.formatted(date: .abbreviated, time: .omitted))"
                                          : "\(plan) · ends \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return subscription.statusText
    }
}

private extension View {
    func bannerStyle(_ fill: AnyShapeStyle, glow: Color) -> some View {
        self.padding(18)
            .foregroundStyle(.white)
            .background {
                ZStack(alignment: .topTrailing) {
                    Rectangle().fill(fill)
                    Canvas { context, size in
                        for x in stride(from: CGFloat(8), to: size.width, by: 16) {
                            for y in stride(from: CGFloat(8), to: size.height, by: 16) {
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.2, height: 2.2)), with: .color(.white.opacity(0.16)))
                            }
                        }
                    }
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.4), .clear], center: .center, startRadius: 0, endRadius: 110))
                        .frame(width: 220, height: 220).offset(x: 70, y: -90)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: glow.opacity(0.28), radius: 14, y: 8)
    }
}

/// "My benefits": every Pro tool family with its free tries left, plus the
/// Pro-only extras. Free users see what they can still try; Pro members a check.
struct ProBenefitsCard: View {
    @EnvironmentObject var subscription: SubscriptionStore
    @State private var trials = ProTrials()
    @State private var tick = 0
    private enum Extra: String, CaseIterable { case noAds = "No ads", autoSave = "Auto-save" }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
    var body: some View {
        let _ = tick
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("My benefits").font(.headline).foregroundStyle(Design.ink)
                Spacer()
                if !subscription.isPro { Text("Free tries on this iPhone").font(.caption).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: columns, alignment: .center, spacing: 14) {
                ForEach(ProFeature.allCases, id: \.self) { feature in
                    cell(title: feature.shortTitle, art: ToolArtwork(name: feature.icon, size: 46), caption: caption(feature),
                         warn: !subscription.isPro && trials.remaining(feature) == 0)
                        .accessibilityIdentifier("benefit-" + feature.rawValue)
                }
                cell(title: Extra.noAds.rawValue, art: Image(systemName: "nosign").font(.system(size: 20, weight: .semibold)).foregroundStyle(TK.grey500)
                        .frame(width: 46, height: 46).background(TK.grey100, in: RoundedRectangle(cornerRadius: 13, style: .continuous)),
                     caption: subscription.isPro ? "On" : "Pro only", warn: false)
                cell(title: Extra.autoSave.rawValue, art: ToolArtwork(name: "auto-save", size: 46),
                     caption: subscription.isPro ? "On" : "Pro only", warn: false)
            }
            if !subscription.isPro {
                Divider()
                Text("Scanning, PDF, text recognition and signing are always free.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear { trials = ProTrials(); tick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .proTrialsChanged)) { _ in tick += 1 }
    }
    private func cell<Art: View>(title: String, art: Art, caption: String, warn: Bool) -> some View {
        VStack(spacing: 5) {
            art.overlay(alignment: .bottomTrailing) {
                if subscription.isPro {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .black)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(Color(red: 0.09, green: 0.64, blue: 0.29), in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2)).offset(x: 4, y: 4)
                }
            }
            Text(L(title)).font(.caption.weight(.bold)).foregroundStyle(Design.ink).lineLimit(1).minimumScaleFactor(0.75)
            Text(L(caption)).font(.caption2.weight(warn ? .bold : .regular)).foregroundStyle(warn ? TK.red : .secondary)
                .lineLimit(2).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
    private func caption(_ feature: ProFeature) -> String {
        if subscription.isPro { return "Unlimited" }
        return "\(trials.remaining(feature)) of \(feature.limit) left"
    }
}


/// Shown once, right after someone becomes Pro.
struct WelcomeToProView: View {
    @Environment(\.dismiss) private var dismiss
    private let rows: [(icon: String, text: String)] = [
        ("word", "Word, Excel & PowerPoint export"), ("redact", "Hide personal info & fill forms"),
        ("restore", "Restore & fix photos"), ("compress", "Split, compress & lock PDFs"),
    ]
    var body: some View {
        ZStack {
            ProTheme.dusk.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(ProTheme.dusk)
                    Image(systemName: "crown.fill").font(.system(size: 38, weight: .bold)).foregroundStyle(ProStyle.gold)
                }.frame(width: 88, height: 88).accessibilityHidden(true)
                Text("Welcome to Pro").font(.system(.title, weight: .black)).foregroundStyle(Color(red: 0.12, green: 0.10, blue: 0.30)).padding(.top, 16)
                Text("Everything is unlocked. The app now wears a Pro look.").font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.top, 6)
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows, id: \.icon) { row in
                        HStack(spacing: 12) {
                            ToolArtwork(name: row.icon, size: 38)
                            Text(L(row.text)).font(.subheadline.weight(.semibold)).foregroundStyle(Design.ink)
                            Spacer(minLength: 0)
                        }
                    }
                }.padding(.top, 22)
                Button { dismiss() } label: {
                    Text("Start scanning").font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(ProTheme.action, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }.buttonStyle(.plain).padding(.top, 24).accessibilityIdentifier("welcome-pro-start")
            }
            .padding(24)
            .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 20)
        }
    }
}
