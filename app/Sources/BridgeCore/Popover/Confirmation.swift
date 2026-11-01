/// What the popover asks before it erases a session's conversation.
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
        + "Run /live on in that session to join again.",
      confirm: "Remove")
  }
}
