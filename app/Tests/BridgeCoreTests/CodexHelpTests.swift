import Testing

@testable import BridgeCore

struct CodexHelpTests {
  @Test func notSignedInOffersCodexLogin() throws {
    let help = try #require(CodexHelp.for(problem: CodexProblem.notLoggedIn.sentence))
    #expect(help == .signIn)
    #expect(help.button == "How to sign in")
    #expect(help.command == "codex login")
    #expect(help.copy == "Copy codex login")
    #expect(help.steps.contains("Terminal"))
    #expect(help.steps.contains("realtime voice"))
    #expect(help.steps.contains("Start"))
  }

  @Test func notInstalledOffersTheInstallCommand() throws {
    let help = try #require(CodexHelp.for(problem: CodexProblem.notInstalled.sentence))
    #expect(help == .install)
    #expect(help.command == "brew install --cask codex")
    #expect(help.steps.contains(CodexHelp.npmInstallCommand))
    #expect(help.steps.contains(CodexHelp.loginCommand))
  }

  @Test func otherProblemsOfferNoHelp() {
    #expect(CodexHelp.for(problem: nil) == nil)
    #expect(CodexHelp.for(problem: CodexProblem.exited(1).sentence) == nil)
    #expect(CodexHelp.for(problem: MicrophoneAccess.deniedSentence) == nil)
  }

  @Test func thePopoverOffersItForTheStatusProblem() {
    let status = StatusReply(
      call: .off, sessions: [], minutesToday: 0, minutesThisCall: 0,
      problem: CodexProblem.notLoggedIn.sentence, lastContext: nil, recentTranscript: [],
      unheard: 0)
    #expect(StatusPresentation(status).codexHelp == .signIn)
  }
}
