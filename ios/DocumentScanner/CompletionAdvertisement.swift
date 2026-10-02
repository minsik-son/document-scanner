import SwiftUI
import GoogleMobileAds

/// Device-local counters only. No document identifiers or content are stored here.
struct CompletionAdFrequency: Codable {
    var completedTasks = 0
    var lastPresentation: Date?
    var presentationsOnLastDay = 0

    func permitsNextCompletion(at now: Date, calendar: Calendar = .current) -> Bool {
        let next = completedTasks + 1
        // The first completion is exempt; subsequent opportunities are 4, 7, 10, ...
        guard next > 1, (next - 1).isMultiple(of: 3) else { return false }
        if let lastPresentation {
            guard now.timeIntervalSince(lastPresentation) >= 600 else { return false }
            if calendar.isDate(now, inSameDayAs: lastPresentation), presentationsOnLastDay >= 2 { return false }
        }
        return true
    }
    mutating func recordPresentation(at now: Date, calendar: Calendar = .current) {
        presentationsOnLastDay = lastPresentation.map { calendar.isDate(now, inSameDayAs: $0) } == true
            ? presentationsOnLastDay + 1 : 1
        lastPresentation = now
    }
}

@MainActor
protocol CompletionAdPresenting: AnyObject {
    func validate() throws
    func show(onPresented: @escaping () -> Void, onFinished: @escaping () -> Void)
}

@MainActor
private final class GoogleCompletionAd: NSObject, CompletionAdPresenting, FullScreenContentDelegate {
    private let ad: InterstitialAd
    private var presented: (() -> Void)?
    private var finished: (() -> Void)?
    init(_ ad: InterstitialAd) { self.ad = ad; super.init(); ad.fullScreenContentDelegate = self }
    func validate() throws { try ad.canPresent(from: nil) }
    func show(onPresented: @escaping () -> Void, onFinished: @escaping () -> Void) {
        presented = onPresented; finished = onFinished
        ad.present(from: nil)
    }
    func adWillPresentFullScreenContent(_ ad: FullScreenPresentingAd) {
        let action = presented; presented = nil; action?()
    }
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) { finish() }
    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) { finish() }
    private func finish() {
        let action = finished; finished = nil; presented = nil; action?()
    }
}

@MainActor
final class CompletionAdvertisementStore: ObservableObject {
    typealias Loader = @MainActor () async throws -> CompletionAdPresenting
    private let defaults: UserDefaults
    private let now: () -> Date
    private let load: Loader
    private let key = "scanner-completion-ad-frequency-v1"
    private(set) var frequency: CompletionAdFrequency
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var session: UUID?
    private var ready: CompletionAdPresenting?
    private var loadedAt: Date?
    private var presenting: CompletionAdPresenting?
    private var finishPresentation: (() -> Void)?
    private var completedSessions = Set<UUID>()

    init(defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init, loader: Loader? = nil) {
        let storage = defaults ?? Self.counterDefaults()
        self.defaults = storage; self.now = now
        frequency = storage.data(forKey: key).flatMap { try? JSONDecoder().decode(CompletionAdFrequency.self, from: $0) } ?? CompletionAdFrequency()
        load = loader ?? {
            await AdvertisingSDK.start()
            try Task.checkCancellation()
            let request = Request()
            let extras = Extras(); extras.additionalParameters = ["npa": "1"]; request.register(extras)
            let ad = try await InterstitialAd.load(with: "ca-app-pub-3940256099942544/4411468910", request: request)
            return GoogleCompletionAd(ad)
        }
    }
    private static func counterDefaults() -> UserDefaults {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--ui-test-session"), args.indices.contains(i+1),
           let id = UUID(uuidString: args[i+1]), let isolated = UserDefaults(suiteName: "scanner-ad-tests-" + id.uuidString) { return isolated }
#endif
        return .standard
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(frequency) { defaults.set(data, forKey: key) }
    }
    func prepare(session id: UUID, policy: HomeAdEligibility) {
        guard presenting == nil else { return }
        guard policy.canRequest, frequency.permitsNextCompletion(at: now()) else { cancel(session: id); return }
        if session != id { resetLoad(); session = id }
        if let loadedAt, now().timeIntervalSince(loadedAt) >= 3300 { resetLoad(); session = id }
        guard task == nil, ready == nil, !completedSessions.contains(id) else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            let result = try? await self.load()
            guard !Task.isCancelled, self.generation == token, self.session == id else { return }
            self.task = nil; self.ready = result; self.loadedAt = result == nil ? nil : self.now()
        }
    }
    /// Never awaits a load. A missed opportunity is consumed, never shown later on home.
    func finish(session id: UUID, policy: HomeAdEligibility,
                onPresented: @escaping () -> Void, completion: @escaping () -> Void) {
        guard completedSessions.insert(id).inserted else { return }
        let due = frequency.permitsNextCompletion(at: now())
        frequency.completedTasks += 1; persist()
        let ad = session == id ? ready : nil
        let fresh = loadedAt.map { now().timeIntervalSince($0) >= 0 && now().timeIntervalSince($0) < 3300 } ?? false
        resetLoad()
        guard policy.canRequest, due, fresh, presenting == nil, let ad else { completion(); return }
        do { try ad.validate() } catch { completion(); return }
        presenting = ad
        finishPresentation = completion
        ad.show(onPresented: { [weak self] in
            guard let self, self.presenting != nil else { return }
            self.frequency.recordPresentation(at: self.now()); self.persist()
            onPresented()
        }, onFinished: { [weak self] in
            guard let self else { return }
            self.presenting = nil
            let action = self.finishPresentation; self.finishPresentation = nil
            action?()
        })
    }
    func cancel(session id: UUID) {
        guard session == id else { return }; resetLoad()
    }
    private func resetLoad() {
        generation = UUID(); task?.cancel(); task = nil
        ready = nil; loadedAt = nil; session = nil
    }
}
