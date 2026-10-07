import SwiftUI
import GoogleMobileAds
import Network
import Combine
import OSLog

/// No scan, document name, recognized text or library metadata enters this module.
enum HomeAdConfiguration {
    static let sampleAppID = "ca-app-pub-3940256099942544~1458002511"
    static let videoTestUnitID = "ca-app-pub-3940256099942544/2521693316"
    static var testAdsEnabled: Bool {
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--ui-test-session") { return args.contains("--test-native-ad-sdk") }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
#else
        // Never turn a sample ID into a production monetization path by accident.
        // Live IDs, UMP messaging and store privacy disclosures must be configured first.
        return false
#endif
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

struct HomeAdEligibility: Equatable {
    var subscriptionResolved: Bool
    var isPro: Bool
    var online: Bool
    var foreground: Bool
    var homeVisible: Bool
    var unlocked: Bool
    var configured: Bool
    var canRequest: Bool {
        subscriptionResolved && !isPro && online && foreground && homeVisible && unlocked && configured
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
    private let logger = Logger(subsystem:"com.documentscanner.local",category:"HomeAdTiming")
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

    override init() {
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
    func preload(locked: Bool, configured: Bool = HomeAdConfiguration.testAdsEnabled) {
        guard configured, !locked, !suppressedAfterCompletion, !Self.lastKnownPro else { return }
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
            && policy.configured && !suppressedAfterCompletion
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
        // All requests from this build are Google's official demo unit, including on devices.
        let video = VideoOptions()
        video.shouldStartMuted = true
        let placement = NativeAdViewAdOptions()
        placement.preferredAdChoicesPosition = .topRightCorner
        let value = AdLoader(adUnitID: HomeAdConfiguration.videoTestUnitID,
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
    @State private var visible = false
    let homeUncovered: Bool
    /// Home keeps the card's height while the ad loads; other pages show nothing.
    var reserveSpace = true
    @ViewBuilder var fallback: () -> Fallback
    private var policy: HomeAdEligibility {
        HomeAdEligibility(subscriptionResolved: subscription.entitlementsResolved,
                          isPro: subscription.isPro, online: ads.online,
                          foreground: scenePhase == .active,
                          homeVisible: homeUncovered && !ads.suppressedAfterCompletion,
                          unlocked: !lock.locked, configured: HomeAdConfiguration.testAdsEnabled)
    }
    private var keepsAd: Bool {
        subscription.entitlementsResolved && !subscription.isPro && !lock.locked && HomeAdConfiguration.testAdsEnabled
            && !ads.suppressedAfterCompletion
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
                NativeHomeAdvertisement(ad: ad, active: visible && policy.canRequest)
                    .frame(height: 306)
                    .accessibilityIdentifier("home-native-ad")
                    .accessibilityValue(testIdentity)
            } else {
                fallback()
                    .frame(height: reserveSpace && HomeAdConfiguration.testAdsEnabled && !subscription.isPro ? 306 : nil)
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
        layer.cornerRadius = 24
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
        headline.font = .preferredFont(forTextStyle: .subheadline)
        headline.numberOfLines = 2
        advertiser.font = .preferredFont(forTextStyle: .caption1)
        advertiser.textColor = .secondaryLabel
        advertiser.numberOfLines = 1
        let copy = UIStackView(arrangedSubviews: [headline, advertiser])
        copy.axis = .vertical; copy.spacing = 3
        action.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        action.titleLabel?.numberOfLines = 2
        action.backgroundColor = UIColor(Design.pastelBlue)
        action.setTitleColor(UIColor(Design.blueInk), for: .normal)
        action.layer.cornerRadius = 12
        action.isUserInteractionEnabled = false
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 8
        icon.clipsToBounds = true
        let bottom = UIStackView(arrangedSubviews: [icon, copy, action])
        bottom.spacing = 12; bottom.alignment = .center
        let stack = UIStackView(arrangedSubviews: [labelRow, media, bottom])
        stack.axis = .vertical; stack.spacing = 10
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            labelRow.heightAnchor.constraint(equalToConstant: 20),
            media.heightAnchor.constraint(equalToConstant: 180),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            action.widthAnchor.constraint(equalToConstant: 88),
            action.heightAnchor.constraint(equalToConstant: 44)
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
