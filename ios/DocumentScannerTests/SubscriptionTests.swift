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
