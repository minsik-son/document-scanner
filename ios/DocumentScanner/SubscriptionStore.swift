import Foundation
import StoreKit
import Combine

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
    @Published private(set) var products: [Product] = []
    @Published private(set) var isPro = false
    @Published private(set) var entitlementsResolved = false
    @Published private(set) var busy = false
    @Published private(set) var statusText = "Free"
    @Published private(set) var expiresAt: Date?
    @Published private(set) var lifetime = false
    @Published var message: String?
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
    }
    func refreshEntitlements() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        var active = false
        var owned = false
        var nextExpiry: Date?
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
                    } else if !active && item.state == .inBillingRetryPeriod { status = "Payment needs attention. Manage your subscription to restore Pro." }
                }
            } catch { if active { status = "Pro is active through the last verified paid period. Subscription status could not be refreshed." } }
        }
        guard generation == refreshGeneration else { return }
        if owned { active = true; nextExpiry = nil; status = "Pro is unlocked for life" }
        statusText = status; expiresAt = nextExpiry
        lifetime = owned
        isPro = active
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

