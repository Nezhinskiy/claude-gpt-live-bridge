/// Why the call cannot start or just stopped. The wire carries its sentence; in the app its kind
/// says what the menu offers with it.
public enum Problem: Sendable, Equatable {
  /// No Claude Code session has joined, so Start has nothing to talk to.
  case noSession
  /// macOS refuses LiveBridge the microphone.
  case microphoneDenied
  case codex(CodexProblem)
  /// Any other, in its own words: the audio page, a voice session that closed, the noise cap.
  case other(String)

  /// A failure as the owner sees it: codex's own problems keep their kind.
  public init(_ error: any Error) {
    self = (error as? CodexProblem).map(Problem.codex) ?? .other(error.localizedDescription)
  }

  /// One sentence for the menu and the band.
  public var sentence: String {
    switch self {
    case .noSession:
      "No Claude Code session has joined: run \(StatusPresentation.joinCommand) in a session, "
        + "then start."
    case .microphoneDenied:
      "LiveBridge cannot use the microphone. Allow LiveBridge in System Settings > Privacy & "
        + "Security > Microphone, then start again."
    case .codex(let problem): problem.sentence
    case .other(let sentence): sentence
    }
  }

  /// The plan's limit stopped the voice: a new line would fail the same way until it resets.
  public var isUsageLimit: Bool {
    if case .codex(let problem) = self { problem.isUsageLimit } else { false }
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
