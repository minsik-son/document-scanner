import SwiftUI
import QuartzCore

#if DEBUG
/// Debug builds only (`--measure-splash`): counts main-thread frame hitches from
/// launch until the startup cover is gone, so the logo's smoothness can be
/// compared before and after a change. A UI test reads `splash-metrics`.
@MainActor
final class SplashMetrics: NSObject, ObservableObject {
    static let shared = SplashMetrics()
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--measure-splash") }
    @Published private(set) var summary = ""
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0, hitches = 0, dropped = 0
    private var worst: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var stalls: [String] = []
    private var firstTick: CFTimeInterval = 0
    private var coverTime: CFTimeInterval = 0

    func start() {
        guard Self.enabled, link == nil else { return }
        started = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard last > 0 else { firstTick = now - started; return }
        let expected = max(1.0 / 120, link.duration)
        let gap = now - last
        frames += 1
        if gap > expected * 1.5 {
            hitches += 1; dropped += Int((gap / expected).rounded()) - 1
            stalls.append(String(format: "%.0f+%.0f", (last - started) * 1000, gap * 1000))
        }
        worst = max(worst, gap)
    }
    /// Called when the cover is gone; keeps counting a little longer to catch
    /// hitches caused by work that starts after the reveal (ads, appearance).
    func coverGone() {
        guard link != nil else { return }
        coverTime = CACurrentMediaTime() - started
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(2500)); self.stop() }
    }
    func stop() {
        guard let link else { return }
        link.invalidate(); self.link = nil
        let total = CACurrentMediaTime() - started
        summary = String(format: "first=%.0fms frames=%d hitches=%d worst=%.0fms cover=%.2fs total=%.2fs stalls(ms at+len)=%@", firstTick * 1000, frames, hitches, worst * 1000, coverTime, total, stalls.joined(separator: ",") as NSString)
        print("SPLASH-METRICS " + summary)
    }
}
#endif
