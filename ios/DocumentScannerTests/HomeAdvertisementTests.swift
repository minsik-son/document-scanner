import XCTest
import GoogleMobileAds
@testable import DocumentScanner

final class HomeAdvertisementTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "scanner-home-ad-last-known-pro")
        super.tearDown()
    }

    @MainActor
    func testLaunchPreloadSurvivesUnresolvedSubscriptionButNotPro() {
        let store = HomeAdvertisementStore()
        let ad = NativeAd()
        store.cache(ad)
        var policy = HomeAdEligibility(subscriptionResolved: false, isPro: false, online: true,
                                       foreground: true, homeVisible: true, unlocked: true, configured: true, settled: true)
        XCTAssertFalse(policy.canRequest, "Nothing is shown before entitlements resolve")
        store.update(policy)
        XCTAssertTrue(store.nativeAd === ad, "A launch preload must not be discarded while StoreKit is still loading")
        policy.subscriptionResolved = true; policy.isPro = true; store.update(policy)
        XCTAssertNil(store.nativeAd, "Pro users never keep an ad")
        XCTAssertTrue(HomeAdvertisementStore.lastKnownPro)
    }

    @MainActor
    func testLaunchPreloadIsSkippedForKnownProLockedOrUnconfigured() {
        let store = HomeAdvertisementStore()
        HomeAdvertisementStore.lastKnownPro = true
        store.preload(locked: false, configured: true)
        XCTAssertFalse(store.hasPendingPreload)
        HomeAdvertisementStore.lastKnownPro = false
        store.preload(locked: true, configured: true)
        XCTAssertFalse(store.hasPendingPreload)
        store.preload(locked: false, configured: false)
        XCTAssertFalse(store.hasPendingPreload)
        XCTAssertEqual(store.requestCount, 0)
    }

    @MainActor
    func testPreparationStartsBelowFoldAndSurvivesScrollingButNotPro() {
        let store = HomeAdvertisementStore()
        var policy = HomeAdEligibility(subscriptionResolved:true,isPro:false,online:true,
            foreground:true,homeVisible:true,unlocked:true,configured:true, settled: true)
        store.update(policy,visible:false)
        XCTAssertTrue(store.hasScheduledPreparation,"Home must preload even before the slot becomes visible")
        store.setScrolling(true)
        XCTAssertTrue(store.hasScheduledPreparation,"Scrolling must not restart SDK preparation")
        store.setScrolling(false)
        XCTAssertTrue(store.hasScheduledPreparation)
        XCTAssertEqual(store.requestCount,0,"Only one deferred preparation should be scheduled")
        policy.isPro = true;store.update(policy)
        XCTAssertFalse(store.hasScheduledPreparation)
    }

    @MainActor
    func testScrollAndNavigationRetainAdButProAndSuppressionDiscardIt() {
        let store = HomeAdvertisementStore()
        let ad = NativeAd()
        var policy = HomeAdEligibility(subscriptionResolved: true, isPro: false, online: true,
                                       foreground: true, homeVisible: true, unlocked: true, configured: true, settled: true)
        store.cache(ad)
        for _ in 0..<10 {
            store.update(policy, visible: false)
            XCTAssertTrue(store.nativeAd === ad)
            store.update(policy, visible: true)
            XCTAssertTrue(store.nativeAd === ad)
        }
        store.suspend()
        XCTAssertTrue(store.nativeAd === ad)
        policy.homeVisible = false; store.update(policy)
        XCTAssertTrue(store.nativeAd === ad)
        XCTAssertEqual(store.requestCount, 0)
        policy.isPro = true; store.update(policy)
        XCTAssertNil(store.nativeAd)
        store.cache(ad); store.suppressAfterCompletion()
        XCTAssertNil(store.nativeAd)
    }
    func testPackagedAdMobConfiguration() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String,
                       HomeAdConfiguration.appID)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "GADDelayAppMeasurementInit") as? Bool, true)
    }
    func testOnlyVerifiedFreeVisibleOnlineHomeCanRequestAds() {
        // Exhaustive combinations also cover purchase, lock and background transitions.
        for bits in 0..<128 {
            let value: (Int) -> Bool = { bits & (1 << $0) != 0 }
            let policy = HomeAdEligibility(subscriptionResolved: value(0), isPro: value(1),
                                           online: value(2), foreground: value(3),
                                           homeVisible: value(4), unlocked: value(5), configured: value(6), settled: true)
            XCTAssertEqual(policy.canRequest, bits == 125, "Unexpected eligibility for \(bits)")
        }
    }
}
