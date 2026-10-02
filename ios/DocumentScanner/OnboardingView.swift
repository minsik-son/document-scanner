import SwiftUI

struct FirstRunView: View {
    @AppStorage private var completed: Bool

    init() {
        var key = "scanner-onboarding-v1"
        var alreadySeen = false
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--ui-test-session"), args.indices.contains(index + 1),
           let session = UUID(uuidString: args[index + 1]) {
            key += "-" + session.uuidString
            // Existing feature tests skip the tour; onboarding tests exercise the
            // same persistence path using their own isolated defaults key.
            alreadySeen = !args.contains("--test-onboarding")
        }
#endif
        _completed = AppStorage(wrappedValue: alreadySeen, key)
    }

    var body: some View {
        if completed { HomeView() }
        else { OnboardingView { completed = true } }
    }
}

/// True while the app's loading screen still covers the first screen.
private struct StartupCoveredKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var startupCovered: Bool {
        get { self[StartupCoveredKey.self] }
        set { self[StartupCoveredKey.self] = newValue }
    }
}

// First-run tour. Modeled on the short, single-message pages of Korean finance
// apps: one bold left-aligned headline, one sentence, one illustration that
// shows the result, and one primary action. Each page's scene starts playing
// as soon as the page is visible and loops (play ≈1.5 s, hold, soft fade,
// replay). It is driven by a frame clock, so it never needs a tap to start.
// Reduce Motion shows the finished state without movement.
struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    /// When each page's loop started. Restarted whenever a page becomes visible.
    @State private var startedAt: [Date?] = [nil, nil, nil]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.startupCovered) private var startupCovered
    private let durations: [Double] = [1.6, 1.5, 1.4]
    private let lastPage = 2

    var body: some View {
        VStack(spacing: 0) {
            header
            TabView(selection: $page) {
                content(0, title: "Just point your camera.\nWe'll find the page.",
                        detail: "Edges are found automatically, and tilted shots come out straight.") {
                    looping(0) { ScanHero(t: $0, presence: $1) }
                }.tag(0)
                content(1, title: "White paper.\nSharp text.",
                        detail: "Shadows and yellow tint are cleaned up for you. Every page can still be fine-tuned.") {
                    looping(1) { EnhanceHero(t: $0, presence: $1) }
                }.tag(1)
                content(2, title: "Your documents\nstay on your iPhone.",
                        detail: "Scan, save as PDF and recognize text without an account. Core tools work offline.") {
                    looping(2) { LibraryHero(t: $0, presence: $1) }
                }.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: page, initial: true) { _, value in restart(value) }
            .onChange(of: startupCovered) { _, covered in if !covered { restart(page) } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { restart(page) } }
            footer
        }
        .background(PastelOnboardingBackground())
        .sensoryFeedback(.selection, trigger: page)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { move(to: page - 1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .opacity(page > 0 ? 1 : 0).disabled(page == 0)
            .accessibilityHidden(page == 0)
            .accessibilityLabel("Back").accessibilityIdentifier("onboarding-back")

            HStack(spacing: 6) {
                ForEach(0...lastPage, id: \.self) { index in
                    Capsule().fill(index <= page ? OnboardingPalette.blue : OnboardingPalette.track)
                        .frame(height: 4)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.9), value: page)
            .accessibilityElement().accessibilityLabel("Introduction page \(page + 1) of \(lastPage + 1)")

            Button(action: onFinish) {
                Text("Skip").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(OnboardingPalette.secondary)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Skip introduction").accessibilityIdentifier("onboarding-skip")
        }
        .buttonStyle(.plain).foregroundStyle(Design.ink)
        .padding(.horizontal, 12).padding(.top, 4)
    }

    private var footer: some View {
        Button {
            if page == lastPage { onFinish() } else { move(to: page + 1) }
        } label: {
            Text(page == lastPage ? "Get started" : "Next")
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(.white)
                .background(OnboardingPalette.blue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentTransition(.opacity)
        }
        .buttonStyle(PressableStyle())
        .accessibilityIdentifier("onboarding-next")
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
    }

    private func content<Hero: View>(_ index: Int, title: String, detail: String, @ViewBuilder hero: () -> Hero) -> some View {
        let heroView = hero()
        return GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(.title, weight: .bold)).tracking(-0.6).lineSpacing(4)
                        .foregroundStyle(Design.ink).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("onboarding-title-\(index)")
                    Text(detail)
                        .font(.system(size: 17)).lineSpacing(3)
                        .foregroundStyle(OnboardingPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                    Spacer(minLength: 24)
                    heroView
                        .frame(width: 300, height: 300)
                        // One offscreen Metal pass per frame instead of many
                        // separate shadow/blend layers.
                        .drawingGroup()
                        .scaleEffect(min(1, (geometry.size.width - 48) / 300))
                        .frame(maxWidth: .infinity)
                        .frame(height: min(320, max(240, geometry.size.height * 0.55)))
                        .dynamicTypeSize(.large)
                        .contentShape(Rectangle())
                        .onTapGesture { restart(index) }
                        .accessibilityHidden(true)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 24).padding(.top, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }
            .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
        }
    }

    private func move(to value: Int) {
        guard (0...lastPage).contains(value) else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9)) { page = value }
    }

    private func restart(_ index: Int) {
        guard startedAt.indices.contains(index), !startupCovered else { return }
        startedAt[index] = Date()
    }

    private func looping<Drawing: View>(_ index: Int, @ViewBuilder scene: @escaping (Double, Double) -> Drawing) -> some View {
        let running = page == index && scenePhase == .active && !startupCovered
        return LoopingScene(start: running ? startedAt[index] : nil, duration: durations[index],
                            reduceMotion: reduceMotion, scene: scene)
    }
}

/// Plays a scene from a frame clock: `t` runs 0→1 over `duration`, the result
/// holds, fades briefly, and the loop starts again. Off-screen pages are paused
/// at their start pose, so swiping in never shows a half-finished frame.
private struct LoopingScene<Drawing: View>: View {
    let start: Date?
    let duration: Double
    let reduceMotion: Bool
    let scene: (Double, Double) -> Drawing
    static var hold: Double { 1.6 }
    static var fade: Double { 0.25 }
    var body: some View {
        if reduceMotion {
            scene(1, 1)
        } else {
            TimelineView(.animation(minimumInterval: nil, paused: start == nil)) { context in
                let frame = Self.frame(elapsed: start.map { context.date.timeIntervalSince($0) }, duration: duration)
                scene(frame.t, frame.presence)
            }
        }
    }
    /// `presence` fades the foreground out at the end of a loop and back in at
    /// the start of the next, so the reset to the start pose is not a jump.
    static func frame(elapsed: Double?, duration: Double) -> (t: Double, presence: Double) {
        guard let elapsed, elapsed > 0, duration > 0 else { return (0, 1) }
        let cycle = duration + hold + fade
        let phase = elapsed.truncatingRemainder(dividingBy: cycle)
        let t = min(1, phase / duration)
        if phase > duration + hold { return (1, 1 - (phase - duration - hold) / fade) }
        if elapsed >= cycle, phase < 0.2 { return (t, phase / 0.2) }
        return (t, 1)
    }
}

/// Soft pastel wash like the original tour: white at the top, a pale aqua glow
/// on the left and a pale butter-yellow glow on the right, fading out near the
/// buttons. Static (no per-frame cost).
private struct PastelOnboardingBackground: View {
    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [[0, 0], [0.5, 0], [1, 0],
                     [0, 0.52], [0.52, 0.48], [1, 0.5],
                     [0, 1], [0.5, 1], [1, 1]],
            colors: [.white, .white, .white,
                     Color(red: 0.86, green: 0.96, blue: 0.98), Color(red: 0.985, green: 0.99, blue: 0.975), Color(red: 1.0, green: 0.975, blue: 0.86),
                     Color(red: 0.92, green: 0.975, blue: 0.99), Color(red: 0.99, green: 0.995, blue: 0.985), Color(red: 1.0, green: 0.985, blue: 0.92)])
        .ignoresSafeArea()
    }
}

private enum OnboardingPalette {
    static let blue = Color(red: 0.192, green: 0.510, blue: 0.965)
    static let track = Color(red: 0.898, green: 0.910, blue: 0.922)
    static let secondary = Color(red: 0.31, green: 0.35, blue: 0.39)
    static let stage = Color(red: 0.949, green: 0.957, blue: 0.965)
    static let ink = Color(red: 0.13, green: 0.15, blue: 0.18)
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: - Timing helpers. `t` runs linearly 0...1; each element maps its own
// window of `t` through an easing curve, so one value drives the whole scene.
private enum Ease {
    static func window(_ t: Double, _ start: Double, _ end: Double) -> Double {
        min(1, max(0, (t - start) / (end - start)))
    }
    static func out(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func inOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    /// Slight overshoot, like a soft spring settling.
    static func spring(_ x: Double) -> Double {
        let c1 = 1.2, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}

/// A simple document drawn in code: crisp vector shapes at every size.
private struct PaperSheet: View {
    var ink: Double = 1
    var accent: Color = OnboardingPalette.blue
    var body: some View {
        let text = Color(white: 0.55 - 0.40 * ink)
        VStack(alignment: .leading, spacing: 9) {
            Capsule().fill(text).frame(width: 84, height: 9)
            Capsule().fill(text.opacity(0.5)).frame(width: 56, height: 5)
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1).padding(.vertical, 3)
            ForEach(0..<5, id: \.self) { row in
                Capsule().fill(text.opacity(0.18 + 0.32 * ink))
                    .frame(height: 5).padding(.trailing, CGFloat([0, 22, 8, 34, 14][row]))
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<5, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.25 + 0.55 * ink))
                        .frame(height: CGFloat([14, 22, 18, 28, 20][bar]))
                }
            }.frame(height: 28)
        }
        .padding(16)
        .frame(width: 160, height: 208, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct Pill: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(OnboardingPalette.ink, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

/// Page 1: corner guides lock onto a tilted page on a desk, a scan line passes,
/// the shutter flashes, and the page comes out flat and cropped.
private struct ScanHero: View {
    var t: Double
    var presence: Double = 1
    var body: some View {
        let guides = Ease.out(Ease.window(t, 0, 0.28))
        let sweep = Ease.inOut(Ease.window(t, 0.18, 0.52))
        let flat = Ease.spring(Ease.window(t, 0.52, 0.82))
        let badge = Ease.spring(Ease.window(t, 0.76, 1))
        let flash = max(0, 1 - abs(t - 0.52) / 0.07)
        ZStack {
            // White card floating on the pastel background; inset so its soft
            // shadow stays inside the illustration's drawing group.
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.white)
                .shadow(color: Color(red: 0.25, green: 0.35, blue: 0.45).opacity(0.08), radius: 14, y: 6)
                .padding(8)
            ZStack {
            // The desk disappears as the page is cropped out of the photo.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.80, green: 0.72, blue: 0.62), Color(red: 0.70, green: 0.61, blue: 0.51)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(18).opacity(1 - flat)
            PaperSheet()
                .shadow(color: .black.opacity(0.10 + 0.12 * (1 - flat)), radius: 14, y: 6)
                .rotation3DEffect(.degrees(16 * (1 - flat)), axis: (x: 1, y: 0.2, z: 0), perspective: 0.6)
                .rotationEffect(.degrees(-9 * (1 - flat)))
                .scaleEffect(0.9 + 0.1 * flat)
                .overlay {
                    Rectangle()
                        .fill(LinearGradient(colors: [OnboardingPalette.blue.opacity(0), OnboardingPalette.blue.opacity(0.35)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 176, height: 26)
                        .offset(y: -115 + 220 * sweep)
                        .opacity(sweep > 0 && sweep < 1 ? 1 : 0)
                }
            CornerGuides(inset: 14 * (1 - guides) + 6 * (1 - flat))
                .stroke(flat > 0.5 ? OnboardingPalette.blue : .white,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: 184, height: 232)
                .scaleEffect(1.18 - 0.18 * guides)
                .opacity(guides * (1 - 0.4 * Ease.window(t, 0.9, 1)))
            Color.white.opacity(0.75 * flash).clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous)).padding(8)
            Pill(title: "Edges found", symbol: "checkmark.circle.fill")
                .scaleEffect(0.7 + 0.3 * badge).opacity(min(1, badge * 1.4))
                .offset(y: 118 + 10 * (1 - badge))
            }.opacity(presence)
        }
    }
}

private struct CornerGuides: Shape {
    var inset: Double
    var animatableData: Double { get { inset } set { inset = newValue } }
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: -inset, dy: -inset), length: CGFloat = 26
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}

/// Page 2: a before/after wipe from a yellowed, shadowed photo of paper to the
/// cleaned page, so the benefit is visible without reading.
private struct EnhanceHero: View {
    var t: Double
    var presence: Double = 1
    var body: some View {
        let reveal = Ease.inOut(Ease.window(t, 0.08, 0.72))
        let handle = 1 - Ease.window(t, 0.72, 0.84)
        let badge = Ease.spring(Ease.window(t, 0.74, 1))
        let width: CGFloat = 160
        ZStack {
            // White card floating on the pastel background; inset so its soft
            // shadow stays inside the illustration's drawing group.
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.white)
                .shadow(color: Color(red: 0.25, green: 0.35, blue: 0.45).opacity(0.08), radius: 14, y: 6)
                .padding(8)
            ZStack {
            ZStack(alignment: .leading) {
                PaperSheet(ink: 0.25)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.86, blue: 0.64), Color(red: 0.62, green: 0.58, blue: 0.55)],
                                                 startPoint: .topTrailing, endPoint: .bottomLeading))
                            .opacity(0.62).blendMode(.multiply)
                    }
                PaperSheet(ink: 1)
                    .mask(alignment: .leading) { Rectangle().frame(width: width * reveal) }
                // Divider handle between before and after.
                ZStack {
                    Rectangle().fill(.white).frame(width: 3, height: 208)
                    Circle().fill(.white).frame(width: 34, height: 34)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .overlay(Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(OnboardingPalette.blue))
                }
                .offset(x: width * reveal - 17)
                .opacity(handle * min(1, t * 8))
            }
            .frame(width: width, height: 208)
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            .scaleEffect(1 + 0.03 * badge)
            Text("Original").font(.system(size: 12, weight: .semibold)).foregroundStyle(OnboardingPalette.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5).background(.white, in: Capsule())
                .offset(x: -88, y: -122).opacity(1 - reveal)
            Pill(title: "Auto-enhanced", symbol: "sparkles")
                .scaleEffect(0.7 + 0.3 * badge).opacity(min(1, badge * 1.4))
                .offset(y: 118 + 10 * (1 - badge))
            }.opacity(presence)
        }
    }
}

/// Page 3: three saved documents settle into a stack and a privacy badge
/// confirms where they live.
private struct LibraryHero: View {
    var t: Double
    var presence: Double = 1
    private static let cards: [(label: String, color: Color, x: Double, y: Double, angle: Double)] = [
        ("PDF", Color(red: 0.93, green: 0.33, blue: 0.31), -52, 6, -9),
        ("TXT", Color(red: 0.19, green: 0.51, blue: 0.97), 52, 10, 8),
        ("JPG", Color(red: 0.16, green: 0.68, blue: 0.47), 0, -6, 0)
    ]
    var body: some View {
        let badge = Ease.spring(Ease.window(t, 0.55, 0.85))
        let chips = Ease.out(Ease.window(t, 0.72, 1))
        ZStack {
            // White card floating on the pastel background; inset so its soft
            // shadow stays inside the illustration's drawing group.
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(.white)
                .shadow(color: Color(red: 0.25, green: 0.35, blue: 0.45).opacity(0.08), radius: 14, y: 6)
                .padding(8)
            ZStack {
            ForEach(Self.cards.indices, id: \.self) { index in
                let card = Self.cards[index]
                let p = Ease.spring(Ease.window(t, 0.08 * Double(index), 0.08 * Double(index) + 0.45))
                PaperSheet(accent: card.color)
                    .overlay(alignment: .topTrailing) {
                        Text(card.label).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(card.color, in: RoundedRectangle(cornerRadius: 5)).padding(10)
                    }
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 5)
                    .scaleEffect(0.72 * (0.9 + 0.1 * p))
                    .rotationEffect(.degrees(card.angle * p))
                    .offset(x: card.x * p, y: card.y - 24 + 90 * (1 - p))
                    .opacity(min(1, p * 2))
            }
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold))
                    Text("Saved on this iPhone").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 9)
                .background(OnboardingPalette.ink, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .scaleEffect(0.7 + 0.3 * badge).opacity(min(1, badge * 1.4))
                HStack(spacing: 6) {
                    chip("Works offline", symbol: "wifi.slash")
                    chip("No account", symbol: "person.crop.circle.badge.checkmark")
                }
                .opacity(chips).offset(y: 6 * (1 - chips))
            }
            .offset(y: 100)
            }.opacity(presence)
        }
    }
    private func chip(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
            .foregroundStyle(OnboardingPalette.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white, in: Capsule())
    }
}
