import XCTest
@testable import DocumentScanner

@MainActor
final class CompletionAdvertisementTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let frequencyKey = "scanner-completion-ad-frequency-v1"
    private var allowed: HomeAdEligibility {
        HomeAdEligibility(subscriptionResolved: true, isPro: false, online: true,
                          foreground: true, homeVisible: true, unlocked: true, configured: true)
    }
    override func setUp() { suite = "CompletionAds-" + UUID().uuidString; defaults = UserDefaults(suiteName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }
    private func seed(_ value: CompletionAdFrequency) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: frequencyKey)
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    func testFirstTaskExemptionAndEveryThreeSubsequentCompletions() {
        var frequency = CompletionAdFrequency()
        let date = Date()
        var opportunities: [Int] = []
        for count in 1...11 {
            if frequency.permitsNextCompletion(at: date) { opportunities.append(count) }
            frequency.completedTasks += 1
        }
        XCTAssertEqual(opportunities, [4, 7, 10])
    }
    func testCooldownDailyLimitNextDayAndClockRollback() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        var frequency = CompletionAdFrequency(completedTasks: 3)
        frequency.recordPresentation(at: morning, calendar: calendar)
        XCTAssertFalse(frequency.permitsNextCompletion(at: morning.addingTimeInterval(599), calendar: calendar))
        XCTAssertFalse(frequency.permitsNextCompletion(at: morning.addingTimeInterval(-600), calendar: calendar))
        XCTAssertTrue(frequency.permitsNextCompletion(at: morning.addingTimeInterval(600), calendar: calendar))
        frequency.recordPresentation(at: morning.addingTimeInterval(600), calendar: calendar)
        XCTAssertFalse(frequency.permitsNextCompletion(at: morning.addingTimeInterval(1200), calendar: calendar))
        XCTAssertTrue(frequency.permitsNextCompletion(at: morning.addingTimeInterval(86400), calendar: calendar))
        frequency.recordPresentation(at: morning.addingTimeInterval(86400), calendar: calendar)
        XCTAssertEqual(frequency.presentationsOnLastDay, 1)
    }
    func testPresentationAndCompletionPersistAndDuplicateDoneIsIgnored() async throws {
        try seed(CompletionAdFrequency(completedTasks: 3))
        let ad = TestCompletionAd()
        let store = CompletionAdvertisementStore(defaults: defaults, loader: { ad })
        let id = UUID(); var suppressions = 0; var returns = 0
        store.prepare(session: id, policy: allowed); await settle()
        store.finish(session: id, policy: allowed, onPresented: { suppressions += 1 }, completion: { returns += 1 })
        store.finish(session: id, policy: allowed, onPresented: { suppressions += 1 }, completion: { returns += 1 })
        XCTAssertEqual(ad.shows, 1); XCTAssertEqual(suppressions, 1); XCTAssertEqual(returns, 0)
        ad.close(); ad.close()
        XCTAssertEqual(returns, 1)
        let restored = CompletionAdvertisementStore(defaults: defaults, loader: { ad })
        XCTAssertEqual(restored.frequency.completedTasks, 4)
        XCTAssertEqual(restored.frequency.presentationsOnLastDay, 1)
        XCTAssertNotNil(restored.frequency.lastPresentation)
    }
    func testNoFillReturnsImmediatelyAndNeverDisplaysLateResult() async throws {
        try seed(CompletionAdFrequency(completedTasks: 3))
        let ad = TestCompletionAd()
        var continuation: CheckedContinuation<CompletionAdPresenting, Never>?
        let store = CompletionAdvertisementStore(defaults: defaults, loader: {
            await withCheckedContinuation { continuation = $0 }
        })
        let id = UUID(); var returns = 0
        store.prepare(session: id, policy: allowed); await settle()
        XCTAssertNotNil(continuation)
        store.finish(session: id, policy: allowed, onPresented: { XCTFail("Late ad") }, completion: { returns += 1 })
        XCTAssertEqual(returns, 1)
        continuation?.resume(returning: ad); await settle()
        XCTAssertEqual(ad.shows, 0)
        XCTAssertNil(store.frequency.lastPresentation)
        XCTAssertEqual(store.frequency.completedTasks, 4)
    }
    func testProOfflineBackgroundLockedOrCoveredAtDoneDiscardsPreparedAd() async throws {
        for gate in 0..<7 {
            try seed(CompletionAdFrequency(completedTasks: 3))
            let ad = TestCompletionAd()
            let store = CompletionAdvertisementStore(defaults: defaults, loader: { ad })
            let id = UUID()
            store.prepare(session: id, policy: allowed); await settle()
            var blocked = allowed
            switch gate {
            case 0: blocked.isPro = true
            case 1: blocked.online = false
            case 2: blocked.foreground = false
            case 3: blocked.unlocked = false
            case 4: blocked.homeVisible = false
            case 5: blocked.subscriptionResolved = false
            default: blocked.configured = false
            }
            var returned = false
            store.finish(session: id, policy: blocked, onPresented: { XCTFail("Blocked ad") }, completion: { returned = true })
            XCTAssertTrue(returned); XCTAssertEqual(ad.shows, 0)
        }
    }
    func testCancellationDoesNotCountAndValidationFailureDoesNotConsumeDailyCap() async throws {
        try seed(CompletionAdFrequency(completedTasks: 3))
        let ad = TestCompletionAd(); ad.invalid = true
        let store = CompletionAdvertisementStore(defaults: defaults, loader: { ad })
        let canceled = UUID()
        store.prepare(session: canceled, policy: allowed); await settle(); store.cancel(session: canceled)
        XCTAssertEqual(store.frequency.completedTasks, 3)
        let saved = UUID(); var returned = false
        store.prepare(session: saved, policy: allowed); await settle()
        store.finish(session: saved, policy: allowed, onPresented: { XCTFail("Invalid ad") }, completion: { returned = true })
        XCTAssertTrue(returned); XCTAssertEqual(ad.shows, 0); XCTAssertNil(store.frequency.lastPresentation)
    }
    func testHomeAdsRemainSuppressedUntilAnotherDocumentTask() {
        let home = HomeAdvertisementStore()
        home.suppressAfterCompletion()
        XCTAssertTrue(home.suppressedAfterCompletion)
        home.stop()
        XCTAssertTrue(home.suppressedAfterCompletion)
        home.beginDocumentTask()
        XCTAssertFalse(home.suppressedAfterCompletion)
    }
}

@MainActor
private final class TestCompletionAd: CompletionAdPresenting {
    var shows = 0
    var invalid = false
    var finished: (() -> Void)?
    func validate() throws { if invalid { throw NSError(domain: "TestAd", code: 1) } }
    func show(onPresented: @escaping () -> Void, onFinished: @escaping () -> Void) {
        shows += 1; finished = onFinished; onPresented()
    }
    func close() { finished?() }
}
