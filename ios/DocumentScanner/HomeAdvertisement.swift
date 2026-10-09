import SwiftUI
import GoogleMobileAds
import UserMessagingPlatform
import Network
import Combine
import OSLog

/// No scan, document name, recognized text or library metadata enters this module.
enum HomeAdConfiguration {
    /// HushScan in AdMob (also GADApplicationIdentifier in Info.plist).
    static let appID = "ca-app-pub-9921649727270589~5824656756"
    static let homeNativeLiveID = "ca-app-pub-9921649727270589/3406287684"
    static let toolsNativeLiveID = "ca-app-pub-9921649727270589/6320314928"
    static let rewardedLiveID = "ca-app-pub-9921649727270589/3986987592"
    static let sampleAppID = "ca-app-pub-3940256099942544~1458002511"
    static let videoTestUnitID = "ca-app-pub-3940256099942544/2521693316"
    /// Google's official iOS rewarded test unit.
    static let rewardedTestUnitID = "ca-app-pub-3940256099942544/1712485313"
    enum Placement { case home, tools }
    /// Debug builds only ever request Google's demo units; Release requests the live ones.
    static func nativeUnitID(_ placement: Placement) -> String {
#if DEBUG
        return videoTestUnitID
#else
        return placement == .home ? homeNativeLiveID : toolsNativeLiveID
#endif
    }
    static var rewardedUnitID: String {
#if DEBUG
        return rewardedTestUnitID
#else
        return rewardedLiveID
#endif
    }
    static var adsEnabled: Bool {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-test-session") { return args.contains("--test-native-ad-sdk") }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
#else
        return true
#endif
    }
}

/// Google's consent message (UMP). Shown only where the law requires it (EEA, UK,
/// Switzerland); elsewhere it resolves at once. No ad is requested before it resolves.
@MainActor
enum AdConsent {
    private static var gathering: Task<Void, Never>?
    static func gather() async {
        if gathering == nil {
            gathering = Task { @MainActor in
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) { _ in done.resume() }
                }
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    ConsentForm.loadAndPresentIfRequired(from: nil) { _ in done.resume() }
                }
            }
        }
        await gathering?.value
    }
    static var canRequestAds: Bool { ConsentInformation.shared.canRequestAds }
    /// Settings shows "Ad privacy choices" only when Google says the user needs it.
    static var privacyOptionsRequired: Bool {
        ConsentInformation.shared.privacyOptionsRequirementStatus == .required
    }
    static func presentPrivacyOptions() {
        ConsentForm.presentPrivacyOptionsForm(from: nil) { _ in }
    }
}

@MainActor
enum AdvertisingSDK {
    private static var startup: Task<Void, Never>?
    /// Starts SDK initialization without waiting for it. This build uses no
    /// mediation adapters, so Google allows ad requests before start completes;
    /// waiting here only added latency to the first home ad.
    static func begin() {
        guard startup == nil else { return }
        MobileAds.shared.requestConfiguration.maxAdContentRating = .general
        startup = Task {
            await AdConsent.gather()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                MobileAds.shared.start { _ in continuation.resume() }
            }
        }
    }
    static func start() async {
        begin()
        await startup?.value
    }
    /// Used by the loading screen: waits for start-up, but never longer than `timeout`.
    static func waitForStart(timeout: Duration) async {
        begin()
        guard let startup else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await startup.value }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }
}

/// No ads in the first 24 hours after install: people meet the app before any advertising.
enum AdTiming {
    private static let key = "scanner-first-launch-at"
    static let quietPeriod: TimeInterval = 86400
    /// When the app was first opened. Older installs that never stored it use the
    /// creation date of the app's Documents folder, which is made at install.
    static var firstLaunchAt: Date {
        if let saved = UserDefaults.standard.object(forKey: key) as? Date { return saved }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let created = folder.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.creationDate] as? Date }
        let value = min(created ?? Date(), Date())
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
    static var settled: Bool {
#if DEBUG
        // UI tests that exercise ads run on a fresh install.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-session") { return true }
#endif
        return Date().timeIntervalSince(firstLaunchAt) >= quietPeriod
    }
}

struct HomeAdEligibility: Equatable {
    var subscriptionResolved: Bool
    var isPro: Bool
    var online: Bool
    var foreground: Bool
    var homeVisible: Bool
    var unlocked: Bool
    var configured: Bool
    var settled = AdTiming.settled
    var canRequest: Bool {
        subscriptionResolved && !isPro && online && foreground && homeVisible && unlocked && configured && settled
    }
}

@MainActor
final class HomeAdvertisementStore: NSObject, ObservableObject, NativeAdLoaderDelegate {
    @Published private(set) var nativeAd: NativeAd?
    @Published private(set) var online = false
    @Published private(set) var status = "Introduction"
    @Published private(set) var suppressedAfterCompletion = false
    private let monitor = NWPathMonitor()
    private var loader: AdLoader?
    private var eligible = false
    private var retentionAllowed = false
    private var loadedAt: Date?
    private var lastPolicy: HomeAdEligibility?
    private var slotVisible = false
    private var scrolling = false
    private(set) var requestCount = 0
    private var generation = 0
    private var lastFailure: Date?
    private var retryTask: Task<Void,Never>?
    private var preparationStartedAt: TimeInterval?
    private var requestStartedAt: TimeInterval?
    private let logger = Logger(subsystem:"com.hushscan.app",category:"HomeAdTiming")
    /// Network status arrives asynchronously from NWPathMonitor.
    private var pathKnown = false
    /// Set by `preload` at launch; resumed once the network status is known.
    private var preloadRequested = false
    private var reportedReadyOnHome = false
    private let launchedAt = ProcessInfo.processInfo.systemUptime
    private static let lastKnownProKey = "scanner-home-ad-last-known-pro"
    /// Only used to decide whether to request ahead of time at launch. Showing an
    /// ad still requires a freshly resolved free entitlement.
    static var lastKnownPro: Bool {
        get { UserDefaults.standard.bool(forKey: lastKnownProKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastKnownProKey) }
    }
    var hasScheduledPreparation: Bool { requestTask != nil }
    var hasPendingPreload: Bool { preloadRequested || loader != nil }
    private var requestTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    func beginDocumentTask() { suppressedAfterCompletion = false }
    func suppressAfterCompletion() { suppressedAfterCompletion = true; stop() }

    private let unitID: String
    init(placement: HomeAdConfiguration.Placement = .home) {
        unitID = HomeAdConfiguration.nativeUnitID(placement)
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.online = path.status == .satisfied
                self.pathKnown = true
                if !self.online { self.stop() }
                else if self.preloadRequested { self.preloadNow() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "scanner.home-ad-network"))
    }
    deinit { monitor.cancel(); requestTask?.cancel(); timeoutTask?.cancel(); retryTask?.cancel() }

    func setScrolling(_ value: Bool) {
        guard scrolling != value else { return }
        scrolling = value
        if let lastPolicy { update(lastPolicy, visible: slotVisible) }
    }

    /// Called at app launch, in parallel with opening the library, so the ad is
    /// usually ready when home first appears. Nothing about documents is involved.
    /// Presentation is still gated by `HomeAdEligibility` in the slot.
    func preload(locked: Bool, configured: Bool = HomeAdConfiguration.adsEnabled) {
        guard configured, !locked, !suppressedAfterCompletion, !Self.lastKnownPro, AdTiming.settled else { return }
        AdvertisingSDK.begin()
        preloadRequested = true
        if pathKnown { preloadNow() }
    }
    private func preloadNow() {
        preloadRequested = false
        guard online, nativeAd == nil, loader == nil, requestTask == nil, !suppressedAfterCompletion else { return }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 60 { return }
        retentionAllowed = true
        generation += 1
        preparationStartedAt = ProcessInfo.processInfo.systemUptime
        requestAd(token: generation)
    }

    func update(_ policy: HomeAdEligibility, visible: Bool = true) {
        lastPolicy = policy; slotVisible = visible
        if policy.subscriptionResolved { Self.lastKnownPro = policy.isPro }
        // Entitlements are still loading on launch. Keep a launch preload in
        // flight instead of discarding it; nothing is shown until they resolve.
        if !policy.subscriptionResolved, policy.configured, policy.unlocked,
           !suppressedAfterCompletion, !Self.lastKnownPro { return }
        if policy.canRequest, nativeAd != nil, !reportedReadyOnHome {
            reportedReadyOnHome = true
            let elapsed = ProcessInfo.processInfo.systemUptime - launchedAt
            logger.notice("Home ad shown \(elapsed, privacy:.public)s after launch")
        }
        retentionAllowed = policy.subscriptionResolved && !policy.isPro && policy.unlocked
            && policy.configured && policy.settled && !suppressedAfterCompletion
        guard retentionAllowed else { stop(); return }
        if let loadedAt, Date().timeIntervalSince(loadedAt) >= 3300 {
            nativeAd = nil; self.loadedAt = nil
        }
        // Load one ad for the eligible home, even when the card is below the fold.
        // Scroll visibility controls presentation, not the lifetime of preparation.
        eligible = policy.canRequest
        guard eligible else { cancelScheduledRequest(); return }
        guard nativeAd == nil, loader == nil, requestTask == nil else { return }
        guard !scrolling else { return }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 60 { scheduleRetry(); return }
        retryTask?.cancel(); retryTask = nil
        generation += 1
        let token = generation
        requestTask = Task { [weak self] in
            // Let the current render pass finish, then request immediately. The
            // previous fixed 250 ms delay and SDK-start wait only added latency.
            await Task.yield()
            guard !Task.isCancelled, let self, self.eligible, self.generation == token else { return }
            AdvertisingSDK.begin()
            self.preparationStartedAt = ProcessInfo.processInfo.systemUptime
            self.requestTask = nil
            // SDK startup is retained during scrolling; defer only the actual load.
            guard !self.scrolling else { return }
            self.requestAd(token: token)
        }
    }

    private func scheduleRetry() {
        guard retryTask == nil, let lastFailure else { return }
        let delay = max(0.25,60-Date().timeIntervalSince(lastFailure))
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(delay)) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            if let policy = self.lastPolicy { self.update(policy,visible:self.slotVisible) }
        }
    }

    /// Scrolling/navigation only suspends the slot; it must not discard its ad.
    func suspend() {
        slotVisible = false; eligible = false
        cancelScheduledRequest()
    }
    private func cancelScheduledRequest() {
        if requestTask != nil { generation += 1 }
        requestTask?.cancel(); requestTask = nil
    }

    private func requestAd(token: Int) {
        guard AdConsent.canRequestAds else {
            // Wait for the consent message to resolve, then try once more.
            Task { [weak self] in
                await AdvertisingSDK.start()
                guard let self, self.generation == token, AdConsent.canRequestAds else { return }
                self.requestAd(token: token)
            }
            return
        }
        // Debug builds request Google's demo unit; Release the live unit for this placement.
        let video = VideoOptions()
        video.shouldStartMuted = true
        let placement = NativeAdViewAdOptions()
        placement.preferredAdChoicesPosition = .topRightCorner
        let value = AdLoader(adUnitID: unitID,
                             rootViewController: nil, adTypes: [.native], options: [video, placement])
        loader = value
        value.delegate = self
        status = "Loading test advertisement"
        let request = Request()
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        requestCount += 1
        let started = ProcessInfo.processInfo.systemUptime
        requestStartedAt = started
        let initialization = started - (preparationStartedAt ?? started)
        logger.notice("Native ad request started \(started - self.launchedAt, privacy:.public)s after launch; wait \(initialization, privacy:.public)s")
        value.load(request)
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.generation == token, self.nativeAd == nil else { return }
            self.logger.notice("Native ad request timed out after 45s; keeping introduction")
            self.lastFailure = Date()
            self.stop(); self.scheduleRetry()
        }
    }

    func stop() {
        eligible = false; retentionAllowed = false; preloadRequested = false
        generation += 1
        requestTask?.cancel(); requestTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        retryTask?.cancel(); retryTask = nil
        loader?.delegate = nil; loader = nil
        nativeAd = nil; loadedAt = nil
        status = "Introduction"
    }

    func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        guard loader === adLoader, retentionAllowed, online else { return }
        timeoutTask?.cancel(); timeoutTask = nil
        loader?.delegate = nil; loader = nil
        lastFailure = nil
        let duration = ProcessInfo.processInfo.systemUptime - (requestStartedAt ?? ProcessInfo.processInfo.systemUptime)
        logger.notice("Native ad received in \(duration, privacy:.public)s (\(ProcessInfo.processInfo.systemUptime - self.launchedAt, privacy:.public)s after launch); video \(nativeAd.mediaContent.hasVideoContent, privacy:.public)")
        cache(nativeAd)
    }
    func cache(_ nativeAd: NativeAd) {
        loadedAt = Date()
        self.nativeAd = nativeAd
        status = nativeAd.mediaContent.hasVideoContent ? "Test video advertisement" : "Test image advertisement"
    }
    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        guard loader === adLoader else { return }
        logger.notice("Native ad load failed; code \((error as NSError).code, privacy:.public)")
        lastFailure = Date()
        stop(); scheduleRetry()
        // No error UI interrupts scanning; the original card remains visible.
    }
}

struct HomeAdvertisementSlot<Fallback: View>: View {
    @EnvironmentObject private var subscription: SubscriptionStore
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var ads: HomeAdvertisementStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.startupCovered) private var startupCovered
    @State private var visible = false
    @State private var removeAds = false
    let homeUncovered: Bool
    /// Home keeps the card's height while the ad loads; other pages show nothing.
    var reserveSpace = true
    @ViewBuilder var fallback: () -> Fallback
    private var policy: HomeAdEligibility {
        HomeAdEligibility(subscriptionResolved: subscription.entitlementsResolved,
                          isPro: subscription.isPro, online: ads.online,
                          foreground: scenePhase == .active,
                          homeVisible: homeUncovered && !startupCovered && !ads.suppressedAfterCompletion,
                          unlocked: !lock.locked, configured: HomeAdConfiguration.adsEnabled)
    }
    private var keepsAd: Bool {
        subscription.entitlementsResolved && !subscription.isPro && !lock.locked && HomeAdConfiguration.adsEnabled
            && !ads.suppressedAfterCompletion && AdTiming.settled
    }
    private var testIdentity: String {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--test-native-ad-sdk"), let ad = ads.nativeAd {
            return "request-\(ads.requestCount)-\(ObjectIdentifier(ad))"
        }
#endif
        return "Advertisement"
    }
    var body: some View {
        Group {
            // Keep showing a loaded ad while the app is backgrounded or in the app
            // switcher; only Pro, a lock, or missing configuration hide it.
            if keepsAd, let ad = ads.nativeAd {
                VStack(spacing: 0) {
                    NativeHomeAdvertisement(ad: ad, active: visible && policy.canRequest)
                        .frame(height: NativeAdLayout.height)
                        .accessibilityIdentifier("home-native-ad")
                        .accessibilityValue(testIdentity)
                    Divider().padding(.horizontal, 14)
                    Button { removeAds = true } label: {
                        HStack {
                            Text("Remove ads with Pro")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        }.font(.subheadline.weight(.semibold)).foregroundStyle(TK.blue)
                            .padding(.horizontal, 14).frame(height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("remove-ads")
                }
                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .sheet(isPresented: $removeAds) { PaywallView(start: .noAds) }
            } else {
                fallback()
                    .frame(height: reserveSpace && HomeAdConfiguration.adsEnabled && !subscription.isPro && AdTiming.settled ? NativeAdLayout.height + 45 : nil)
                    .accessibilityIdentifier("home-introduction")
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            let frame = proxy.frame(in: .global)
            let visible = frame.intersection(UIScreen.main.bounds)
            return !visible.isNull && frame.height > 0 && visible.height > 0
        } action: { visible = $0 }
        .onChange(of: policy, initial: true) { _, value in ads.update(value, visible: visible) }
        .onChange(of: visible) { _, value in ads.update(policy, visible: value) }
        .onDisappear { ads.suspend() }
    }
}

enum NativeAdLayout {
    /// Compact card: label row, then a square media view next to the headline and button.
    static let height: CGFloat = 172
}

/// SDK asset registration preserves click/impression handling and standard video controls.
private struct NativeHomeAdvertisement: UIViewRepresentable {
    let ad: NativeAd
    let active: Bool
    func makeUIView(context: Context) -> HomeNativeAdView { HomeNativeAdView() }
    func updateUIView(_ view: HomeNativeAdView, context: Context) {
        view.bind(ad)
        // Keep the same media view/ad. SDK manages playback for hidden views.
        view.isHidden = !active
    }
    static func dismantleUIView(_ view: HomeNativeAdView, coordinator: ()) { view.nativeAd = nil }
}

private final class HomeNativeAdView: NativeAdView {
    private let media = MediaView()
    private let headline = UILabel()
    private let advertiser = UILabel()
    private let icon = UIImageView()
    private let action = UIButton(type: .system)
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        // Keep the SDK's top-right AdChoices overlay unobscured.
        let badge = UILabel()
        badge.text = "Ad"
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .darkGray
        badge.accessibilityLabel = "Advertisement"
        let test = UILabel()
        test.text = "Test advertisement"
        test.font = .systemFont(ofSize: 11)
        test.textColor = .secondaryLabel
        let labelRow = UIStackView(arrangedSubviews: [badge, test, UIView()])
        labelRow.spacing = 8
        labelRow.alignment = .center
        media.contentMode = .scaleAspectFit
        media.backgroundColor = UIColor(Design.muted)
        media.layer.cornerRadius = 14
        media.clipsToBounds = true
        headline.font = .systemFont(ofSize: 15, weight: .semibold)
        headline.numberOfLines = 3
        advertiser.font = .preferredFont(forTextStyle: .caption1)
        advertiser.textColor = .secondaryLabel
        advertiser.numberOfLines = 1
        action.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        action.titleLabel?.numberOfLines = 2
        action.backgroundColor = UIColor(Design.pastelBlue)
        action.setTitleColor(UIColor(Design.blueInk), for: .normal)
        action.layer.cornerRadius = 12
        action.isUserInteractionEnabled = false
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 8
        icon.clipsToBounds = true
        // Compact: square media on the left, words and the button on the right.
        let nameRow = UIStackView(arrangedSubviews: [icon, advertiser])
        nameRow.spacing = 6; nameRow.alignment = .center
        let right = UIStackView(arrangedSubviews: [nameRow, headline, action, UIView()])
        right.axis = .vertical; right.spacing = 6; right.alignment = .leading
        let bottom = UIStackView(arrangedSubviews: [media, right])
        bottom.spacing = 12; bottom.alignment = .top
        let stack = UIStackView(arrangedSubviews: [labelRow, bottom])
        stack.axis = .vertical; stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            labelRow.heightAnchor.constraint(equalToConstant: 18),
            // AdMob requires at least 120 × 120 pt for a media view.
            media.widthAnchor.constraint(equalToConstant: 120),
            media.heightAnchor.constraint(equalToConstant: 120),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            action.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
            action.heightAnchor.constraint(equalToConstant: 34)
        ])
        headlineView = headline
        advertiserView = advertiser
        iconView = icon
        callToActionView = action
        mediaView = media
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func bind(_ ad: NativeAd) {
        guard nativeAd !== ad else { return }
        headline.text = ad.headline
        advertiser.text = ad.advertiser
        advertiser.isHidden = ad.advertiser == nil
        icon.image = ad.icon?.image
        icon.isHidden = ad.icon == nil
        action.setTitle(ad.callToAction, for: .normal)
        action.isHidden = ad.callToAction == nil
        media.mediaContent = ad.mediaContent
        nativeAd = ad
    }
}

/// One rewarded ad at a time, for the "Watch a short ad · 1 more use" button on a
/// used-up Pro tool. Same gates as the other ads (configuration, Pro, lock, tests).
/// The button only shows when an ad is ready; nobody waits for one to load.
@MainActor
final class RewardedAdStore: NSObject, ObservableObject, FullScreenContentDelegate {
    @Published private(set) var ready = false
    private var ad: RewardedAd?
    private var loading = false
    func load() {
        guard HomeAdConfiguration.adsEnabled, ad == nil, !loading else { return }
        loading = true
        Task { [weak self] in
            await AdvertisingSDK.start()
            guard let self else { return }
            guard AdConsent.canRequestAds else { self.loading = false; return }
            self.loadRewarded()
        }
    }
    private func loadRewarded() {
        let request = Request()
        let extras = Extras()
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        RewardedAd.load(with: HomeAdConfiguration.rewardedUnitID, request: request) { [weak self] loaded, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.loading = false
                guard let loaded else { self.ready = false; return }
                loaded.fullScreenContentDelegate = self
                self.ad = loaded
                self.ready = true
            }
        }
    }
    /// Plays the ad; `reward` runs only if it was watched to the end.
    func show(reward: @escaping () -> Void) {
        guard let ad else { return }
        ad.present(from: nil) { reward() }
    }
    nonisolated func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) {
        Task { @MainActor in self.ad = nil; self.ready = false }
    }
    nonisolated func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in self.ad = nil; self.ready = false }
    }
}
