import Foundation

/// When the app checks for an update and which copy of it may be updated.
public enum UpdatePolicy {
  /// The time between two automatic checks: a day.
  public static let interval: TimeInterval = 86_400
  /// How often the app asks whether a check is due.
  public static let tick: Duration = .seconds(900)
  /// The one place an update installs into.
  public static let installedPath = "/Applications/LiveBridge.app"

  /// A check is due when the toggle is on and a day has passed since the last one, there was
  /// none, or the clock now reads before it (a moved clock must not stop checks).
  public static func isCheckDue(now: Date, lastCheck: Date?, enabled: Bool) -> Bool {
    guard enabled else { return false }
    guard let lastCheck else { return true }
    return now < lastCheck || now.timeIntervalSince(lastCheck) >= interval
  }

  /// The setting when the owner has made it, otherwise on for a release build and off for a
  /// build from source.
  public static func checksAutomatically(setting: Bool?, isSourceBuild: Bool) -> Bool {
    setting ?? !isSourceBuild
  }

  /// This is the installed copy when the running bundle, resolved, is `installedPath` and that
  /// path is not itself a symbolic link.
  public static func isInstalledCopy(resolvedBundlePath: String, installedPathIsSymlink: Bool)
    -> Bool
  {
    resolvedBundlePath == installedPath && !installedPathIsSymlink
  }
}
