import Testing

@testable import BridgeCore

struct ProblemTests {
  @Test func notSignedInOffersCodexLogin() throws {
    let help = try #require(Problem.codex(.notLoggedIn).help)
    #expect(help == .signIn)
    #expect(help.command == CodexHelp.loginCommand)
    #expect(help.copy.contains(help.command))
    #expect(help.steps.contains(CodexHelp.loginCommand))
  }

  @Test func notInstalledOffersTheInstallCommand() throws {
    let help = try #require(Problem.codex(.notInstalled).help)
    #expect(help == .install)
    #expect(help.command == CodexHelp.installCommand)
    #expect(help.steps.contains(CodexHelp.npmInstallCommand))
    #expect(help.steps.contains(CodexHelp.loginCommand))
  }

  /// The kind decides what the menu offers, not the sentence: a problem that only reads like
  /// one of codex's offers nothing.
  @Test func onlyItsKindOffersHelpOrTheMicrophoneSetting() {
    #expect(Problem.codex(.exited(1)).help == nil)
    #expect(
      Problem.microphoneDenied.help == nil && Problem.microphoneDenied.opensMicrophoneSettings)
    let lookalike = Problem.other(CodexProblem.notLoggedIn.sentence)
    #expect(lookalike.help == nil && !lookalike.opensMicrophoneSettings)
    #expect(!Problem.noSession.opensMicrophoneSettings)
  }

  /// codex's own failures keep their kind; any other error is its description.
  @Test func anErrorKeepsCodexsKind() {
    #expect(Problem(CodexProblem.notInstalled) == .codex(.notInstalled))
    #expect(Problem(RPCError(code: 1, message: "no")) == .other("Codex refused a request: no (1)."))
  }
}
