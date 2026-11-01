import Testing

@testable import BridgeCore

/// One test per rule of the voice prompt: each rule's key sentence is present.
struct VoicePromptTests {
  @Test func answersAsTheFrontDeskInTheOwnersLanguage() {
    #expect(VoicePrompt.text.contains("voice front desk for the owner's Claude Code session"))
    #expect(VoicePrompt.text.contains("Answer in the language the owner speaks."))
  }

  @Test func delegatesCorrectionsAndStops() {
    #expect(VoicePrompt.text.contains("every correction or stop of work that is running"))
    #expect(
      VoicePrompt.text.contains("When you are not sure whether something is meant for Claude"))
  }

  @Test func briefIsSelfContained() {
    #expect(VoicePrompt.text.contains("Write each handoff as a self-contained brief"))
    #expect(VoicePrompt.text.contains("names, numbers and paths word for word"))
    #expect(VoicePrompt.text.contains("only what is new since your previous brief"))
  }

  @Test func confirmsOnceBeforeOutwardActions() {
    #expect(VoicePrompt.text.contains("(delete, push, publish, send, deploy, pay)"))
    #expect(VoicePrompt.text.contains("the owner confirmed by voice"))
  }

  @Test func speaksEachResultOnce() {
    #expect(VoicePrompt.text.contains("once, at the next pause, after you answer"))
    #expect(VoicePrompt.text.contains("Never make up a result while you wait."))
  }

  @Test func questionRoutesBack() {
    #expect(VoicePrompt.text.contains("their next answer goes back to that session"))
  }
}
