/// What the menu's problem banner explains when codex is missing or not signed in, with the
/// command to copy into Terminal.
public struct CodexHelp: Sendable, Equatable {
  public static let loginCommand = "codex login"
  /// codex ships as a Homebrew cask; npm is the other way the README names.
  public static let installCommand = "brew install --cask codex"
  public static let npmInstallCommand = "npm install -g @openai/codex"

  /// The banner's button.
  public let button: String
  public let steps: String
  /// What the copy button puts on the clipboard.
  public let command: String
  public var copy: String { "Copy \(command)" }

  public static let signIn = CodexHelp(
    button: "How to sign in",
    steps:
      "Open Terminal, run \(loginCommand) and sign in with a ChatGPT plan whose Codex includes "
      + "voice. Then press Start again.",
    command: loginCommand)

  public static let install = CodexHelp(
    button: "How to install codex",
    steps:
      "Open Terminal and run \(installCommand) (or \(npmInstallCommand)), then run "
      + "\(loginCommand) and sign in with a ChatGPT plan whose Codex includes voice. Then "
      + "press Start again.",
    command: installCommand)
}
