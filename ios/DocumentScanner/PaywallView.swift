import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var subscription: SubscriptionStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selected = SubscriptionStore.yearlyID
    @State private var privacy = false
    private var product: Product? { subscription.products.first { $0.id == selected } }
    private var plans: [Product] { subscription.products.sorted { $0.id == SubscriptionStore.yearlyID && $1.id != SubscriptionStore.yearlyID } }
    private var saving: Int? {
        guard let yearly = subscription.products.first(where: { $0.id == SubscriptionStore.yearlyID }),
              let monthly = subscription.products.first(where: { $0.id == SubscriptionStore.monthlyID }), monthly.price > 0 else { return nil }
        return SubscriptionStore.annualSavingsPercent(yearly: yearly.price, monthly: monthly.price)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    spotlight.accessibilityHidden(true)
                    VStack(spacing: 10) {
                        Text("DOCUMENT SCANNER PRO").font(.system(.caption, weight: .bold)).tracking(1.5).foregroundStyle(Design.blue)
                        Text("Every page.\nMore possibilities.").font(.system(.largeTitle, weight: .bold)).multilineTextAlignment(.center).foregroundStyle(Design.ink)
                        Text("A little less paperwork.\nA lot more room to do your thing.").font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 20) {
                        benefit("Make it yours", subtitle: "Sign, write, highlight and add watermarks.", icon: "signature")
                        benefit("Get your PDFs in order", subtitle: "Merge, split, extract and compress pages.", icon: "doc.on.doc")
                        benefit("Work without interruptions", subtitle: "No ads. Password-protected PDF exports.", icon: "checkmark.shield")
                    }.padding(22).background(.white, in: RoundedRectangle(cornerRadius: 26))
                    VStack(spacing: 12) {
                        if plans.isEmpty {
                            Text("Plans are currently unavailable. You can keep scanning for free.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                            Button("Reload plans") { Task { await subscription.load() } }.disabled(subscription.busy)
                        } else {
                            ForEach(plans) { plan in planCard(plan) }
                        }
                    }
                    Text("Scanning and selectable PDF text are free.\nYour existing documents stay yours, even after Pro ends.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if typeSize.isAccessibilitySize { purchaseFooter }
                }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
            }.background(Design.muted)
                .safeAreaInset(edge: .bottom, spacing: 0) { if !typeSize.isAccessibilitySize { purchaseFooter } }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(Design.ink).frame(width: 36, height: 36) }
                            .accessibilityLabel("Close").disabled(subscription.busy)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Restore purchases") { Task { await subscription.restore() } }.font(.subheadline).disabled(subscription.busy)
                    }
                }
                .onChange(of: subscription.isPro) { _, active in if active { dismiss() } }
                .onChange(of: subscription.products.map(\.id), initial: true) { _, ids in
                    if !ids.contains(selected), let first = plans.first { selected = first.id }
                }
                .interactiveDismissDisabled(subscription.busy)
                .sheet(isPresented: $privacy) { PrivacyView() }
        }
    }
    private var spotlight: some View {
        ZStack {
            Circle().fill(Design.softBlue).frame(width: 140, height: 140)
            RoundedRectangle(cornerRadius: 16).fill(Design.pastelBlue).frame(width: 88, height: 110).rotationEffect(.degrees(-14)).offset(x: -15, y: 4)
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "doc.text").font(.system(size: 38, weight: .light)).foregroundStyle(Design.blue)
                Capsule().fill(Design.pastelBlue).frame(width: 46, height: 5)
                Capsule().fill(Design.softBlue).frame(width: 34, height: 5)
            }.frame(width: 88, height: 110).background(.white, in: RoundedRectangle(cornerRadius: 16)).rotationEffect(.degrees(8)).offset(x: 9, y: -1)
                .shadow(color: Design.ink.opacity(0.06), radius: 8, y: 6)
            Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(Design.blueInk)
                .frame(width: 42, height: 42).background(Design.pastelBlue, in: Circle()).overlay(Circle().stroke(.white, lineWidth: 4)).offset(x: 53, y: 40)
        }.frame(height: 150).frame(maxWidth: .infinity)
    }
    private func benefit(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 21, weight: .medium)).foregroundStyle(Design.blue)
                .frame(width: 44, height: 44).background(Design.softBlue, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Design.ink)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func planCard(_ plan: Product) -> some View {
        let annual = plan.id == SubscriptionStore.yearlyID
        let active = selected == plan.id
        return Button { selected = plan.id } label: {
            HStack(spacing: 14) {
                Image(systemName: active ? "largecircle.fill.circle" : "circle").font(.title3).foregroundStyle(active ? Design.blue : .secondary)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(annual ? "Yearly" : "Monthly").font(.subheadline.weight(.semibold))
                        if annual, let saving { Text("SAVE \(saving)%").font(.system(.caption2, weight: .bold)).foregroundStyle(Design.blueInk).padding(.horizontal, 8).padding(.vertical, 4).background(Design.pastelBlue, in: Capsule()) }
                    }
                    Text("\(plan.displayPrice) / \(annual ? "year" : "month")").font(.title3.bold())
                    if annual { Text("\((plan.price / 12).formatted(plan.priceFormatStyle)) / month, billed yearly").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(18).foregroundStyle(Design.ink)
                .background(active ? Design.softBlue : .white, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(active ? Design.blue : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain).disabled(subscription.busy)
            .accessibilityIdentifier(annual ? "plan-yearly" : "plan-monthly").accessibilityAddTraits(active ? .isSelected : [])
    }
    private var purchaseFooter: some View {
        VStack(spacing: 12) {
            if let message = subscription.message { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("purchase-status") }
            if let product {
                Button { Task { await subscription.purchase(product) } } label: {
                    if subscription.busy { ProgressView().tint(Design.blueInk).frame(maxWidth: .infinity) }
                    else { Text("Subscribe for \(product.displayPrice)/\(product.id == SubscriptionStore.yearlyID ? "year" : "month")") }
                }.buttonStyle(PrimaryButton()).disabled(subscription.busy).accessibilityIdentifier("subscribe-button")
                Text("Auto-renews until canceled. Payment is charged to your Apple Account. Cancel at least 24 hours before renewal in App Store account settings.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 24) {
                Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Button("Privacy") { privacy = true }
            }.font(.caption)
        }.padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: .infinity).background(.white)
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
                    Text("The free version can show Google AdMob advertisements on Home and after a saved document is finished. The first completed document has no full-screen ad. Later opportunities occur every three completed document tasks, at least 10 minutes apart and at most twice per day. Ads never delay saving, and unavailable ads are skipped. Pro users do not load or display advertisements. This development build uses official test advertisements only; release-build advertising is disabled pending live setup.")
                    Text("The app does not send your scanned pages, document names, or recognized text to the advertising SDK. Google may process device, network and ad-interaction information to serve advertisements. Scanning and PDF creation remain available offline.")
                    Link("Google advertising privacy information", destination: URL(string: "https://policies.google.com/technologies/ads")!)
                    Text("Sharing sends only the items you select to the app or destination you choose. Exported backups are not encrypted. Files saved outside this app are controlled by that destination.")
                    Text("Apple processes subscription payments. The app uses Apple's verified purchase records to check Pro access. Device backups may include app data according to your iPhone backup settings.")
                    Text("To remove local documents, move them to Trash and permanently delete them. Copies you previously exported must be removed separately.")
                    Text("Development preview: a published privacy policy and developer contact must be supplied before App Store distribution.").font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }.navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
