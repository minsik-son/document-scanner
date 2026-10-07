import Combine
import LocalAuthentication
import SwiftUI

@MainActor
final class AppLock: ObservableObject {
  @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "scanner-app-lock")
  @Published private(set) var locked = false
  @Published private(set) var authenticating = false
  @Published var message: String?
  private var window: UIWindow?
  private var context: LAContext?
  init() { locked = enabled }
  func setEnabled(_ value: Bool) async {
    guard !authenticating else { return }
    if await authenticate(
      reason: value ? "Enable document protection" : "Turn off document protection")
    {
      enabled = value
      UserDefaults.standard.set(value, forKey: "scanner-app-lock")
      locked = false
      hide()
    }
  }
  func sceneChanged(_ phase: ScenePhase) {
    if phase == .background {
      if enabled {
        locked = true
        context?.invalidate()
        show(interactive: false)
      }
    } else if phase == .inactive {
      if enabled && !authenticating { show(interactive: false) }
    } else if enabled && locked {
      show(interactive: true)
      if !authenticating { Task { await unlock() } }
    } else {
      hide()
    }
  }
  func unlock() async {
    guard !authenticating else { return }
    if await authenticate(reason: "Unlock your documents") {
      locked = false
      hide()
    } else {
      show(interactive: true)
    }
  }
  private func authenticate(reason: String) async -> Bool {
    authenticating = true
    message = nil
    let value = LAContext()
    value.localizedCancelTitle = "Cancel"
    context = value
    defer {
      authenticating = false
      context = nil
    }
    var error: NSError?
    guard value.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      message = "Set a device passcode in iPhone Settings to use app lock."
      return false
    }
    do {
      return try await value.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    } catch {
      message =
        "Authentication did not complete. Try Face ID, Touch ID or your device passcode again."
      return false
    }
  }
  private func show(interactive: Bool) {
    guard
      let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(
        where: { $0.activationState != .unattached })
    else { return }
    if window == nil {
      window = UIWindow(windowScene: scene)
      window?.windowLevel = .alert + 1
    }
    window?.rootViewController = UIHostingController(
      rootView: LockScreen(lock: self, interactive: interactive))
    window?.isHidden = false
  }
  private func hide() {
    window?.isHidden = true
    window?.rootViewController = nil
    window = nil
  }
}
private struct LockScreen: View {
  @ObservedObject var lock: AppLock
  let interactive: Bool
  var body: some View {
    ZStack {
      Color.white.ignoresSafeArea()
      VStack(spacing: 24) {
        Image(systemName: "lock.shield").font(.system(size: 60)).foregroundStyle(Design.blue)
        Text("Your documents are locked").font(.title2.bold())
        if interactive {
          if let message = lock.message { Text(L(message)).multilineTextAlignment(.center) }
          Button("Unlock") { Task { await lock.unlock() } }.buttonStyle(PrimaryButton()).disabled(
            lock.authenticating)
        }
      }.padding(32)
    }.accessibilityIdentifier("app-lock-screen")
  }
}


/// Locks single documents or whole folders inside the app. Unlocking lasts until
/// the app goes to the background.
@MainActor
final class PrivateLock: ObservableObject {
  static let shared = PrivateLock()
  @Published private(set) var unlocked = Set<UUID>()
  @Published private(set) var unlockedFolders = Set<String>()
  private var observer: NSObjectProtocol?
  private init() {
    observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.unlocked = []; self?.unlockedFolders = [] }
    }
  }
  /// The person who just set a lock keeps access until the app goes to the background.
  func keepOpen(_ doc: ScanDocument) { unlocked.insert(doc.id); unlockedFolders.insert(doc.folder) }
  static func isLocked(_ doc: ScanDocument, in manifest: LibraryManifest) -> Bool {
    doc.appLocked == true || (manifest.lockedFolders ?? []).contains(doc.folder)
  }
  /// Locked and not yet opened with Face ID in this session.
  func hidden(_ doc: ScanDocument, in manifest: LibraryManifest) -> Bool {
    guard Self.isLocked(doc, in: manifest) else { return false }
    return !unlocked.contains(doc.id) && !unlockedFolders.contains(doc.folder)
  }
  func unlock(_ doc: ScanDocument, in manifest: LibraryManifest) async -> Bool {
    guard hidden(doc, in: manifest) else { return true }
    guard await Self.authenticate("Open \(doc.title)") else { return false }
    unlocked.insert(doc.id)
    if (manifest.lockedFolders ?? []).contains(doc.folder) { unlockedFolders.insert(doc.folder) }
    return true
  }
  static func authenticate(_ reason: String) async -> Bool {
    let context = LAContext(); context.localizedCancelTitle = "Cancel"
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
    return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
  }
}
