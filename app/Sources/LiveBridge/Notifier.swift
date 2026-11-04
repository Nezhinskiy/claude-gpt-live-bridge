import AppKit
import BridgeCore
import UserNotifications

/// Shows the bridge's notices in Notification Center: alerts only, no sound (the app plays its
/// own chime). Permission is asked the first time a notice is posted or the setting is turned
/// on. Clicking a notice opens the menu bar menu; an update notice's Install action installs
/// the release it names. Without an app bundle (a bare `swift run`)
/// there is no Notification Center to post to, and notices are dropped. Unchecked: its stored
/// properties are set once, and the notification center may be used from any thread.
final class Notifier: NSObject, ResultNotifying, UNUserNotificationCenterDelegate,
  @unchecked Sendable
{
  /// The Notifications pane of System Settings, at LiveBridge's entry.
  static let settingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id="
      + Paths.bundleID)!
  /// What Settings says when the owner refused notifications.
  static let deniedSentence = "Notifications are off for LiveBridge in System Settings."
  /// The category of a notice that offers Install, and that action.
  static let updateCategory = "update"
  static let installAction = "install"
  /// Where an update notice keeps the version its Install action installs.
  private static let versionKey = "version"

  private let center: UNUserNotificationCenter?
  /// Opens the menu bar menu; set once at launch.
  @MainActor var onOpen: () -> Void = {}
  /// Installs the release of this version; set once at launch.
  @MainActor var onInstall: (AppVersion) -> Void = { _ in }

  override init() {
    center = Bundle.main.bundleIdentifier == nil ? nil : .current()
    super.init()
    center?.delegate = self
    let install = UNNotificationAction(identifier: Self.installAction, title: "Install")
    center?.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.updateCategory, actions: [install], intentIdentifiers: [])
    ])
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

  /// An update notice, `update-available-<X.Y.Z>` or `update-installed-<X.Y.Z>`. It is posted
  /// whatever the results setting says, since the owner asked for updates; with `installs`, it
  /// has an Install action for that version.
  func postUpdate(identifier: String, title: String, body: String, installs: AppVersion?) async {
    guard let center, await authorize() else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if let installs {
      content.categoryIdentifier = Self.updateCategory
      content.userInfo = [Self.versionKey: installs.description]
    }
    try? await center.add(
      UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
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
    let install =
      response.actionIdentifier == Self.installAction
      ? (response.notification.request.content.userInfo[Self.versionKey] as? String)
        .flatMap { AppVersion($0) } : nil
    await MainActor.run {
      if let install { onInstall(install) } else { onOpen() }
    }
  }
}
