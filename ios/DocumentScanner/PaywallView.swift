import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var subscription: SubscriptionStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selected = SubscriptionStore.yearlyID
    @State private var privacy = false
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
                    hero.accessibilityHidden(true)
                    VStack(spacing: 10) {
                        Text("PAGEFRAME PRO").font(.system(.caption2, weight: .heavy)).tracking(1.6).lineLimit(1).minimumScaleFactor(0.5)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(.white.opacity(0.12), in: Capsule())
                        (Text("Every page.\n") + Text("More possibilities.").foregroundStyle(ProStyle.titleGradient))
                            .font(.system(.title, weight: .black)).multilineTextAlignment(.center)
                            .minimumScaleFactor(0.5).frame(maxWidth: .infinity)
                    }.padding(.horizontal, 20)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 8) {
                        feature("Word · Excel · PPT", icon: "doc.richtext.fill", tint: Color(red: 0.18, green: 0.42, blue: 1))
                        feature("Translate photos", icon: "character.bubble.fill", tint: Color(red: 0.13, green: 0.75, blue: 0.57))
                        feature("Extract text (OCR)", icon: "text.viewfinder", tint: Color(red: 0.25, green: 0.55, blue: 1))
                        feature("Hide personal info", icon: "eye.slash.fill", tint: Color(red: 0.05, green: 0.66, blue: 0.62))
                        feature("Fill forms · Auto-save", icon: "list.bullet.rectangle.fill", tint: Color(red: 0.36, green: 0.42, blue: 0.95))
                        feature("Restore & fix photos", icon: "wand.and.stars", tint: Color(red: 1, green: 0.55, blue: 0.15))
                        feature("Split · Compress · Lock", icon: "lock.doc.fill", tint: Color(red: 1, green: 0.42, blue: 0.55))
                        feature("No ads", icon: "nosign", tint: ProStyle.violet)
                    }.padding(.horizontal, 16).padding(.top, 18)
                    Text("All \(Self.proToolCount) Pro tools, unlimited signatures and merges")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 10)
                    VStack(spacing: 10) {
                        if plans.isEmpty {
                            Text("Plans are currently unavailable. You can keep scanning for free.").multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7))
                            Button("Reload plans") { Task { await subscription.load() } }.disabled(subscription.busy)
                        } else {
                            ForEach(plans) { plan in planCard(plan) }
                        }
                    }.padding(.horizontal, 16).padding(.top, 20)
                    Text("Scanning, PDF and signing stay free. Your documents stay yours, even after Pro ends.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.72)).multilineTextAlignment(.center)
                        .padding(12).frame(maxWidth: .infinity).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 16).padding(.top, 14)
                    if typeSize.isAccessibilitySize { purchaseFooter.padding(.top, 12) }
                }.padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    ProStyle.night
                    RadialGradient(colors: [Color(red: 0.36, green: 0.29, blue: 1), Color(red: 0.16, green: 0.17, blue: 0.48), ProStyle.night],
                                   center: .top, startRadius: 0, endRadius: 420)
                        .frame(height: 520)
                }.ignoresSafeArea()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { if !typeSize.isAccessibilitySize { purchaseFooter } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(.white.opacity(0.16), in: Circle())
                    }.accessibilityLabel("Close").disabled(subscription.busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Restore purchases") { Task { await subscription.restore() } }.font(.subheadline).foregroundStyle(.white.opacity(0.8)).disabled(subscription.busy)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .onChange(of: subscription.isPro) { _, active in if active { dismiss() } }
            .onChange(of: subscription.products.map(\.id), initial: true) { _, ids in
                if !ids.contains(selected), let first = plans.first { selected = first.id }
            }
            .interactiveDismissDisabled(subscription.busy)
            .sheet(isPresented: $privacy) { PrivacyView().environment(\.colorScheme, .light) }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
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
        Text(text).font(.system(size: 12, weight: .heavy)).padding(.horizontal, 12).padding(.vertical, 6).background(.white.opacity(0.14), in: Capsule())
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
            Text(title).font(.caption.weight(.bold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
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
                        if lifetime { Text("One-time purchase. No subscription.") }
                        else if annual {
                            if subscription.trialEligible, let days = subscription.trialDays { Text("\(days) days free · \((plan.price / 12).formatted(plan.priceFormatStyle))/month, billed yearly") }
                            else { Text("\((plan.price / 12).formatted(plan.priceFormatStyle)) / month, billed yearly") }
                        } else { Text("Cancel anytime") }
                    }.font(.caption).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(lifetime ? "\(plan.displayPrice) once" : "\(plan.displayPrice) / \(annual ? "year" : "month")").font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(active ? AnyShapeStyle(Color(red: 0.1, green: 0.11, blue: 0.25)) : AnyShapeStyle(.white.opacity(0.06)), in: shape)
            .overlay(shape.strokeBorder(active ? AnyShapeStyle(ProStyle.gradient) : AnyShapeStyle(.white.opacity(0.12)), lineWidth: active ? 2 : 1.5))
            .overlay(alignment: .topTrailing) {
                if annual, let saving {
                    Text("BEST · SAVE \(saving)%").font(.caption2.weight(.heavy)).padding(.horizontal, 9).padding(.vertical, 3)
                        .background(ProStyle.gradient, in: Capsule()).offset(x: -14, y: -10)
                }
            }
            .padding(.top, annual ? 6 : 0)
        }.buttonStyle(.plain).disabled(subscription.busy)
            .accessibilityIdentifier(lifetime ? "plan-lifetime" : annual ? "plan-yearly" : "plan-monthly").accessibilityAddTraits(active ? .isSelected : [])
    }
    private var purchaseFooter: some View {
        VStack(spacing: 10) {
            if let message = subscription.message { Text(message).font(.footnote).foregroundStyle(.white.opacity(0.75)).accessibilityIdentifier("purchase-status") }
            if let product {
                Button { Task { await subscription.purchase(product) } } label: {
                    VStack(spacing: 2) {
                        if subscription.busy { ProgressView().tint(.white) }
                        else if let days = trialDays {
                            Text("Start \(days)-day free trial").font(.headline.weight(.heavy))
                            Text("then \(product.displayPrice)/year").font(.caption.weight(.semibold)).opacity(0.85)
                        }
                        else if product.id == SubscriptionStore.lifetimeID { Text("Buy once for \(product.displayPrice)").font(.headline.weight(.heavy)) }
                        else { Text("Subscribe for \(product.displayPrice)/\(product.id == SubscriptionStore.yearlyID ? "year" : "month")").font(.headline.weight(.heavy)) }
                    }
                    .frame(maxWidth: .infinity).frame(minHeight: 54).padding(.vertical, 4)
                    .foregroundStyle(.white)
                    .background(ProStyle.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { if !typeSize.isAccessibilitySize { ProShine().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)) } }
                    .shadow(color: ProStyle.violet.opacity(0.4), radius: 12, y: 6)
                }.buttonStyle(.plain).disabled(subscription.busy).accessibilityIdentifier("subscribe-button")
                Text(legal(product))
                    .font(.caption2).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 24) {
                Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Button("Privacy") { privacy = true }
            }.font(.caption).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10).frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [ProStyle.night.opacity(0), ProStyle.night, ProStyle.night], startPoint: .top, endPoint: .bottom).padding(.top, -24))
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
                    Text("The free version can show a Google AdMob advertisement on Home. There are no full-screen advertisements, and ads never delay scanning or saving. Unavailable ads are skipped. Pro users do not load or display advertisements. This development build uses official test advertisements only; release-build advertising is disabled pending live setup.")
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
