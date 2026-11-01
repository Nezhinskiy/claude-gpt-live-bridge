import AppKit
import BridgeCore
import UserNotifications

/// Shows the bridge's notices in Notification Center: alerts only, no sound (the app plays its
/// own chime). Permission is asked the first time a notice is posted or the setting is turned
/// on. Clicking a notice opens the menu bar popover. Without an app bundle (a bare `swift run`)
/// there is no Notification Center to post to, and notices are dropped. Unchecked: its one
/// stored property is set once, and the notification center may be used from any thread.
final class Notifier: NSObject, ResultNotifying, UNUserNotificationCenterDelegate,
  @unchecked Sendable
{
  /// The Notifications pane of System Settings, at LiveBridge's entry.
  static let settingsURL = URL(
    string:
      "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=io.github.nezhinskiy.livebridge"
  )!
  /// What Settings says when the owner refused notifications.
  static let deniedSentence = "Notifications are off for LiveBridge in System Settings."

  private let center: UNUserNotificationCenter?

  override init() {
    center = Bundle.main.bundleIdentifier == nil ? nil : .current()
    super.init()
    center?.delegate = self
  }

  func post(_ notice: ResultNotice) async {
    guard let center, await authorize() else { return }
    let content = UNMutableNotificationContent()
    content.title = notice.title
    content.body = notice.body
    content.threadIdentifier = notice.identifier
    // the same identifier replaces the notice still shown instead of adding another
    center.removeDeliveredNotifications(withIdentifiers: [notice.identifier])
    try? await center.add(
      UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
  }

  /// Asks for permission the first time; true when notices may be shown.
  @discardableResult func authorize() async -> Bool {
    guard let center else { return false }
    switch await center.notificationSettings().authorizationStatus {
    case .notDetermined: return (try? await center.requestAuthorization(options: [.alert])) ?? false
    case .denied: return false
    default: return true
    }
  }

  /// The owner refused notifications (or turned them off in System Settings).
  var isDenied: Bool {
    get async { await center?.notificationSettings().authorizationStatus == .denied }
  }

  /// Shown also while LiveBridge is the active app, as when its Settings window is open.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions { [.banner, .list] }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    // MenuBarExtra has no API to open its popover, and a click sent to its button is ignored.
    await MainActor.run { NSApp.activate() }
  }
}
