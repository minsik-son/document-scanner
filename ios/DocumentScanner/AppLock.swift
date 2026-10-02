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
          if let message = lock.message { Text(message).multilineTextAlignment(.center) }
          Button("Unlock") { Task { await lock.unlock() } }.buttonStyle(PrimaryButton()).disabled(
            lock.authenticating)
        }
      }.padding(32)
    }.accessibilityIdentifier("app-lock-screen")
  }
}
