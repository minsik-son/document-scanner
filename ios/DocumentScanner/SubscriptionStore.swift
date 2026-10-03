import Foundation
import StoreKit
import Combine
import UserNotifications

@MainActor
final class SubscriptionStore: ObservableObject {
    static let monthlyID = "com.documentscanner.pro.monthly"
    static let yearlyID = "com.documentscanner.pro.yearly"
    /// One-time purchase that unlocks Pro permanently (non-consumable).
    static let lifetimeID = "com.documentscanner.pro.lifetime"
    static let productIDs = [yearlyID, monthlyID, lifetimeID]
    static func annualSavingsPercent(yearly: Decimal, monthly: Decimal) -> Int? {
        guard monthly > 0, yearly >= 0, yearly < monthly * 12 else { return nil }
        var percent = (Decimal(1) - yearly / (monthly * 12)) * 100
        var rounded = Decimal()
        // Round before converting; long fractional Decimal values can overflow
        // NSDecimalNumber.intValue on some OS versions.
        NSDecimalRound(&rounded, &percent, 0, .down)
        let value = NSDecimalNumber(decimal: rounded).intValue
        return (1...100).contains(value) ? value : nil
    }
    /// Debug builds run by the developer have every Pro feature unlocked, so
    /// paywalls and upgrade prompts stay out of the way while building.
    /// Never in Release builds, and never under unit or UI tests, which check
    /// the real free and paid behaviour.
    static let developmentUnlock: Bool = {
        #if DEBUG
        let info = ProcessInfo.processInfo
        if info.environment["XCTestConfigurationFilePath"] != nil { return false }
        if info.arguments.contains("--ui-test-session") { return false }
        return true
        #else
        return false
        #endif
    }()
    @Published private(set) var products: [Product] = []
    @Published private(set) var isPro = SubscriptionStore.developmentUnlock
    @Published private(set) var entitlementsResolved = false
    @Published private(set) var busy = false
    @Published private(set) var statusText = "Free"
    @Published private(set) var expiresAt: Date?
    @Published private(set) var lifetime = false
    @Published var message: String?
    /// End of a running free trial (introductory offer), nil when not in one.
    @Published private(set) var trialEndsAt: Date?
    @Published private(set) var trialStartedAt: Date?
    @Published private(set) var willRenew = false
    /// Product of the active subscription, nil for free, lifetime and development unlock.
    @Published private(set) var planID: String?
    /// Whether this Apple Account can still start the yearly plan's free trial.
    @Published private(set) var trialEligible = false
    @Published private(set) var trialDays: Int?
    static let trialProductID = yearlyID
    var trialDaysLeft: Int? {
        guard let end = trialEndsAt, end > Date() else { return nil }
        return max(1, Int((end.timeIntervalSinceNow / 86400).rounded(.up)))
    }
    /// Share of the trial already used, for the countdown ring.
    var trialProgress: Double {
        guard let end = trialEndsAt else { return 0 }
        let start = trialStartedAt ?? end.addingTimeInterval(-Double(trialDays ?? 7) * 86400)
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(1, max(0.04, Date().timeIntervalSince(start) / total))
    }
    var renewalPrice: String? { products.first { $0.id == (planID ?? Self.trialProductID) }?.displayPrice }
    var renewalUnit: String { (planID ?? Self.trialProductID) == Self.monthlyID ? "month" : "year" }
    private var listener: Task<Void, Never>?
    private var expiryRefresh: Task<Void, Never>?
    private var refreshGeneration = 0
    init() {
        listener = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await self.refreshEntitlements()
                    await transaction.finish()
                }
            }
        }
        Task { await refreshEntitlements(); await load(); await refreshEntitlements() }
    }
    deinit { listener?.cancel(); expiryRefresh?.cancel() }
    /// Lets the loading screen wait briefly for the first entitlement read, so
    /// home knows whether to show the ad. Never waits longer than `timeout`.
    func waitUntilResolved(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while !entitlementsResolved, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
    func load() async {
        do { products = try await Product.products(for: Self.productIDs) }
        catch { message = "Plans couldn't be loaded. Connect to the internet and try again." }
        await refreshTrialOffer()
    }
    /// Reads the yearly plan's free trial and whether it can still be started.
    func refreshTrialOffer() async {
        guard let yearly = products.first(where: { $0.id == Self.trialProductID }), let info = yearly.subscription,
              let offer = info.introductoryOffer, offer.paymentMode == .freeTrial else { trialDays = nil; trialEligible = false; return }
        let unit: Int
        switch offer.period.unit {
        case .day: unit = 1
        case .week: unit = 7
        case .month: unit = 30
        case .year: unit = 365
        @unknown default: unit = 0
        }
        trialDays = unit > 0 ? unit * offer.period.value * max(1, offer.periodCount) : nil
        trialEligible = await info.isEligibleForIntroOffer
    }
    func refreshEntitlements() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        var active = false
        var owned = false
        var nextExpiry: Date?
        var trialEnd: Date?, trialStart: Date?, plan: String?, renews = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == Self.lifetimeID,
               transaction.productType == .nonConsumable, transaction.revocationDate == nil {
                owned = true; continue
            }
            guard case .verified(let transaction) = result,
                  [Self.monthlyID, Self.yearlyID].contains(transaction.productID),
                  transaction.revocationDate == nil, !transaction.isUpgraded,
                  let expiry = transaction.expirationDate, expiry > Date() else { continue }
            active = true
            nextExpiry = min(nextExpiry ?? expiry, expiry)
            plan = transaction.productID
            if transaction.offer?.type == .introductory, transaction.offer?.paymentMode == .freeTrial {
                trialEnd = expiry; trialStart = transaction.purchaseDate
            }
        }
        var status = active ? "Pro is active" : "Free"
        for product in products {
            guard let info = product.subscription else { continue }
            do {
                for item in try await info.status {
                    guard case .verified(let transaction) = item.transaction,
                          transaction.revocationDate == nil, !transaction.isUpgraded,
                          case .verified(let renewal) = item.renewalInfo else { continue }
                    if item.state == .inGracePeriod, let until = renewal.gracePeriodExpirationDate, until > Date() {
                        active = true; nextExpiry = until; status = "Pro is active during Apple's billing grace period. Update your payment method."
                    } else if item.state == .subscribed, let expiry = transaction.expirationDate, expiry > Date() {
                        active = true; nextExpiry = max(nextExpiry ?? expiry, expiry)
                        status = renewal.willAutoRenew ? "Pro is active" : "Pro remains active until the paid period ends. Renewal is off."
                        renews = renewal.willAutoRenew
                    } else if !active && item.state == .inBillingRetryPeriod { status = "Payment needs attention. Manage your subscription to restore Pro." }
                }
            } catch { if active { status = "Pro is active through the last verified paid period. Subscription status could not be refreshed." } }
        }
        guard generation == refreshGeneration else { return }
        if owned { active = true; nextExpiry = nil; status = "Pro is unlocked for life" }
        if Self.developmentUnlock && !active { status = "Pro is unlocked in this development build" }
        statusText = status; expiresAt = nextExpiry
        lifetime = owned
        planID = owned ? nil : plan
        trialEndsAt = owned ? nil : trialEnd; trialStartedAt = owned ? nil : trialStart
        willRenew = renews
        updateTrialReminder()
        await refreshTrialOffer()
        isPro = active || Self.developmentUnlock
        entitlementsResolved = true
        expiryRefresh?.cancel()
        if let nextExpiry {
            let delay = max(1, min(nextExpiry.timeIntervalSinceNow, 86400))
            expiryRefresh = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                await self?.refreshEntitlements()
            }
        }
    }
    /// A local reminder two days before a free trial turns into a paid plan.
    private func updateTrialReminder() {
        let id = "pro-trial-reminder"
        let center = UNUserNotificationCenter.current()
        let info = ProcessInfo.processInfo
        let testing = info.environment["XCTestConfigurationFilePath"] != nil || info.arguments.contains("--ui-test-session")
        guard !testing else { return }
        guard let end = trialEndsAt, willRenew else { center.removePendingNotificationRequests(withIdentifiers: [id]); return }
        let fire = end.addingTimeInterval(-2 * 86400)
        guard fire > Date().addingTimeInterval(60) else { center.removePendingNotificationRequests(withIdentifiers: [id]); return }
        let price = renewalPrice.map { "\($0)/\(renewalUnit)" } ?? "the plan price"
        let day = end.formatted(date: .abbreviated, time: .omitted)
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Your free trial ends in 2 days"
            content.body = "On \(day) Pro renews at \(price). Open Me to keep it or cancel."
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
    }
    func purchase(_ product: Product) async {
        busy = true; message = nil; defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else { message = "The purchase couldn't be verified. Your documents are unchanged."; return }
                await refreshEntitlements(); await transaction.finish()
            case .pending: message = "Purchase is awaiting approval. You can keep using your documents."
            case .userCancelled: break
            @unknown default: message = "The purchase didn't complete. Please try again."
            }
        } catch { message = error.localizedDescription }
    }
    func restore() async {
        busy = true; message = nil; defer { busy = false }
        do { try await AppStore.sync(); await refreshEntitlements(); message = isPro ? "Your purchase is restored." : "No active subscription or lifetime purchase was found. Existing documents are still available." }
        catch { message = error.localizedDescription }
    }
}

/// Families of Pro tools that free users can try a few times before upgrading.
enum ProFeature: String, CaseIterable {
    case office, translate, image
    var title: String {
        switch self {
        case .office: return "Office export"
        case .translate: return "Photo translation"
        case .image: return "Photo tools"
        }
    }
}

extension AdvancedTool {
    /// Pro family for gated advanced tools; nil means always free.
    var proFeature: ProFeature? {
        switch self {
        case .word, .excel, .slides, .math: return .office
        case .translate: return .translate
        case .book, .portrait, .erase, .marks, .restore, .mega: return .image
        case .count, .measure, .mesh: return nil
        }
    }
    var pro: Bool { proFeature != nil }
}

/// Counts free tries of Pro tools on this device. UI tests get their own
/// session-scoped counters and skip the gate unless `--test-pro-gate` is passed.
struct ProTrials {
    static let limit = 3
    let defaults: UserDefaults
    let bypassed: Bool
    private let prefix: String
    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        var prefix = "pro-trial."
        var bypassed = false
        #if DEBUG
        if let i = arguments.firstIndex(of: "--ui-test-session") {
            bypassed = !arguments.contains("--test-pro-gate")
            if i + 1 < arguments.count { prefix += arguments[i + 1] + "." }
        }
        #endif
        self.prefix = prefix; self.bypassed = bypassed
    }
    func used(_ feature: ProFeature) -> Int { defaults.integer(forKey: prefix + feature.rawValue) }
    func remaining(_ feature: ProFeature) -> Int { max(0, Self.limit - used(feature)) }
    /// Uses one free try. Returns false when none are left.
    @discardableResult func consume(_ feature: ProFeature) -> Bool {
        guard remaining(feature) > 0 else { return false }
        defaults.set(used(feature) + 1, forKey: prefix + feature.rawValue)
        return true
    }
}

