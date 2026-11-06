/// Why the call cannot start or just stopped. The wire carries its sentence; in the app its kind
/// says what the menu offers with it.
public enum Problem: Sendable, Equatable {
  /// No Claude Code session has joined, so Start has nothing to talk to.
  case noSession
  /// macOS refuses LiveBridge the microphone.
  case microphoneDenied
  case codex(CodexProblem)
  /// The service refused the voice on the line's data channel, which codex does not report.
  case lineRefused(String)
  /// Any other, in its own words: the audio page, a voice session that closed, the noise cap.
  case other(String)

  /// A failure as the owner sees it: codex's own problems keep their kind.
  public init(_ error: any Error) {
    self = (error as? CodexProblem).map(Problem.codex) ?? .other(error.localizedDescription)
  }

  /// An `error` on the line's data channel, when it is about usage. The code decides: the
  /// service's prose is not codex's, and only a refusal of this kind ends a call.
  static func refusal(code: String, message: String) -> Problem? {
    code.contains("usage") || code.contains("quota") ? .lineRefused(message) : nil
  }

  /// One sentence for the menu and the band, with no control characters: the engine refuses a
  /// band that holds one, and the text can be the service's.
  public var sentence: String {
    String(
      String.UnicodeScalarView(
        wording.unicodeScalars.filter { $0.properties.generalCategory != .control }))
  }

  private var wording: String {
    switch self {
    case .noSession:
      "No Claude Code session has joined: run \(StatusPresentation.joinCommand) in a session, "
        + "then start."
    case .microphoneDenied:
      "LiveBridge cannot use the microphone. Allow LiveBridge in System Settings > Privacy & "
        + "Security > Microphone, then start again."
    case .codex(let problem): problem.sentence
    case .lineRefused(let message):
      "ChatGPT did not allow the voice just now, so it is paused. Claude Code keeps working. "
        + "\(message)"
    case .other(let sentence): sentence
    }
  }

  /// A new line would fail the same way, so speech must not keep opening them.
  public var pausesCall: Bool {
    switch self {
    case .codex(let problem): problem.isUsageLimit || problem.isRefusal
    case .lineRefused: true
    default: false
    }
  }

  /// The menu offers to open the Microphone pane of System Settings.
  public var opensMicrophoneSettings: Bool { self == .microphoneDenied }

  /// codex is missing or not signed in: the menu explains how, with a command to copy.
  public var help: CodexHelp? {
    switch self {
    case .codex(.notLoggedIn): .signIn
    case .codex(.notInstalled): .install
    default: nil
    }
  }
}
