/// What the app asks before it erases a session's conversation, or replaces a build from source
/// with a release.
public struct Confirmation: Sendable, Equatable {
  public let title: String
  public let message: String
  /// The destructive button's title; the other button is Cancel.
  public let confirm: String

  /// New conversation, with the target `label`.
  public static func newConversation(label: String) -> Confirmation {
    Confirmation(
      title: "Erase the conversation with \(label)?",
      message:
        "The conversation with \(label), what the voice remembers and the loaded context, "
        + "will be erased. The next call with \(label) starts fresh.",
      confirm: "Erase")
  }

  /// The session row's ×.
  public static func remove(label: String) -> Confirmation {
    Confirmation(
      title: "Remove \(label) from LiveBridge?",
      message:
        "\(label) leaves LiveBridge and its conversation with the voice is erased. "
        + "Run \(StatusPresentation.joinCommand) in that session to join again.",
      confirm: "Remove")
  }

  /// Settings' Connect over TCP changed while a line is connecting or open.
  public static func reconnect(overTCP: Bool) -> Confirmation {
    Confirmation(
      title: "Reconnect the voice over \(overTCP ? "TCP" : "UDP")?",
      message:
        "The current voice line closes now and opens again over \(overTCP ? "TCP" : "UDP"). "
        + "What the voice is saying is cut off.",
      confirm: "Reconnect")
  }

  /// Install, in a build from source (`build-app.sh --release`), of release `version`.
  public static func replaceSourceBuild(version: AppVersion) -> Confirmation {
    Confirmation(
      title: "Replace this build from source with LiveBridge \(version)?",
      message:
        "The release image replaces the build from source. It is signed with LiveBridge's "
        + "Developer ID, not a self-signed identity from build-app.sh --make-signing-identity, "
        + "so macOS asks for the microphone again.",
      confirm: "Install")
  }

  /// The command that removes the Claude Code mod, which Uninstall LiveBridge leaves to the owner.
  public static let modUninstallCommand = "claude plugin uninstall \(Updater.modID)"

  /// The menu's Uninstall LiveBridge.
  public static let uninstall = Confirmation(
    title: "Uninstall LiveBridge?",
    message:
      "A call open now ends, and every session leaves LiveBridge, so /live turns off in each. "
      + "LiveBridge removes its login item and its microphone permission and quits, and the app "
      + "and every file it keeps go to the Trash. The Claude Code mod stays: the command that "
      + "removes it, \(modUninstallCommand), is copied for you to run in Terminal.",
    confirm: "Uninstall")

  /// What Uninstall LiveBridge says when the app cannot move itself to the Trash, after `reason`,
  /// the error's own words. `loginItemRestored` is whether the login item it removed first is
  /// back, or there was none: only then has nothing changed.
  public static func cannotTrash(reason: String, loginItemRestored: Bool) -> String {
    let changed =
      loginItemRestored
      ? "Nothing was changed."
      : "LiveBridge stays where it is, but its login item could not be restored, so it no longer "
        + "opens at login. To restore it, turn on General > Open at login in LiveBridge's "
        + "Settings, or add LiveBridge in System Settings > General > Login Items."
    return
      "\(reason) \(changed) The README's Uninstall section shows how to remove LiveBridge by hand."
  }
}
