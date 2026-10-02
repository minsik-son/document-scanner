import XCTest
import StoreKit
import StoreKitTest
@testable import DocumentScanner

@MainActor
final class SubscriptionTests: XCTestCase {
    func testAnnualSavingsUsesActualPricesAndNeverRoundsUp() {
        XCTAssertEqual(SubscriptionStore.annualSavingsPercent(yearly:Decimal(string:"29.99")!,monthly:Decimal(string:"4.99")!),49)
        XCTAssertNil(SubscriptionStore.annualSavingsPercent(yearly:120,monthly:10))
        XCTAssertNil(SubscriptionStore.annualSavingsPercent(yearly:30,monthly:0))
        XCTAssertEqual(SubscriptionStore.annualSavingsPercent(yearly:60,monthly:10),50)
    }
    func testProTrialsCountPerFamilyAndStopAtLimit() throws {
        let name = "ProTrialsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let trials = ProTrials(defaults: defaults, arguments: [])
        XCTAssertFalse(trials.bypassed)
        XCTAssertEqual(trials.remaining(.office), ProTrials.limit)
        for _ in 0..<ProTrials.limit { XCTAssertTrue(trials.consume(.office)) }
        XCTAssertFalse(trials.consume(.office)); XCTAssertEqual(trials.remaining(.office), 0)
        XCTAssertEqual(trials.remaining(.translate), ProTrials.limit, "Families are counted separately")
        XCTAssertEqual(ProTrials(defaults: defaults, arguments: []).remaining(.office), 0, "Tries persist")
    }
    func testProTrialsUITestSessionBypassAndIsolation() throws {
        let name = "ProTrialsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(ProTrials(defaults: defaults, arguments: ["--ui-test-session", "A"]).bypassed)
        let gated = ProTrials(defaults: defaults, arguments: ["--ui-test-session", "A", "--test-pro-gate"])
        XCTAssertFalse(gated.bypassed); gated.consume(.image)
        XCTAssertEqual(gated.remaining(.image), ProTrials.limit - 1)
        XCTAssertEqual(ProTrials(defaults: defaults, arguments: ["--ui-test-session", "B", "--test-pro-gate"]).remaining(.image), ProTrials.limit)
        XCTAssertEqual(ProTrials(defaults: defaults, arguments: []).remaining(.image), ProTrials.limit)
    }
    func testAdvancedToolFamilies() {
        XCTAssertEqual(AdvancedTool.word.proFeature, .office); XCTAssertEqual(AdvancedTool.math.proFeature, .office)
        XCTAssertEqual(AdvancedTool.translate.proFeature, .translate); XCTAssertEqual(AdvancedTool.restore.proFeature, .image)
        XCTAssertFalse(AdvancedTool.measure.pro); XCTAssertFalse(AdvancedTool.count.pro)
        XCTAssertFalse(DocumentTool.annotate.pro); XCTAssertFalse(DocumentTool.merge.pro)
        XCTAssertTrue(DocumentTool.compress.pro); XCTAssertTrue(DocumentTool.protect.pro)
    }
    func testLifetimePurchaseUnlocksProWithoutExpiry() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scanner", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true; session.clearTransactions()
        defer { session.clearTransactions() }
        let store = SubscriptionStore()
        await store.load(); await store.refreshEntitlements()
        XCTAssertFalse(store.isPro)
        let lifetime = try XCTUnwrap(store.products.first { $0.id == SubscriptionStore.lifetimeID })
        XCTAssertEqual(lifetime.price, Decimal(string: "39.99")); XCTAssertEqual(lifetime.type, .nonConsumable)
        await store.purchase(lifetime); await store.refreshEntitlements()
        XCTAssertTrue(store.isPro); XCTAssertTrue(store.lifetime); XCTAssertNil(store.expiresAt)
    }
    func testUSPricesVerifiedPurchaseAndExpiration() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Scanner", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()
        defer { session.clearTransactions() }
        let store = SubscriptionStore()
        XCTAssertFalse(store.entitlementsResolved)
        await store.load(); await store.refreshEntitlements()
        XCTAssertTrue(store.entitlementsResolved)
        XCTAssertFalse(store.isPro)
        let monthly = try XCTUnwrap(store.products.first { $0.id == SubscriptionStore.monthlyID })
        let yearly = try XCTUnwrap(store.products.first { $0.id == SubscriptionStore.yearlyID })
        XCTAssertEqual(monthly.price, Decimal(string: "4.99"))
        XCTAssertEqual(yearly.price, Decimal(string: "29.99"))
        await store.purchase(yearly)
        await store.refreshEntitlements()
        XCTAssertTrue(store.isPro)
        XCTAssertFalse(HomeAdEligibility(subscriptionResolved: store.entitlementsResolved,
                                        isPro: store.isPro, online: true, foreground: true,
                                        homeVisible: true, unlocked: true, configured: true).canRequest)
        try session.expireSubscription(productIdentifier: yearly.id)
        // StoreKit propagates expiry asynchronously to currentEntitlements.
        for _ in 0..<40 {
            await store.refreshEntitlements()
            if !store.isPro { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(store.isPro)
    }
}
