import Testing

@testable import BridgeCore

struct AnswerShaperTests {
  @Test func stripsCodeAndCapsOnSentence() {
    let sentence = "This sentence is exactly fifty characters long ok. "
    let text =
      "Done.\n```swift\nlet secret = 1\n```\n| a | b |\n|---|---|\n"
      + String(repeating: sentence, count: 50)
    let voice = AnswerShaper.forVoice(text, status: .ok, label: "Example session")
    #expect(voice.count <= 2000 && voice.hasSuffix("."))
    #expect(!voice.contains("let secret") && !voice.contains("| a |"))
    #expect(voice.hasPrefix("[RESULT] Example session: Done. This sentence"))
  }

  @Test func redactsSecretsInAnswers() {
    let voice = AnswerShaper.forVoice(
      "Use sk-abcdefghijklmnopqrstuvwx now.", status: .ok, label: "Example session")
    #expect(voice == "[RESULT] Example session: Use [redacted] now.")
  }

  @Test(arguments: [
    (AnswerStatus.ok, "[RESULT]"), (.failed, "[FAILED]"), (.question, "[QUESTION]"),
    (.update, "[UPDATE]"),
  ])
  func prefixPerStatus(status: AnswerStatus, tag: String) {
    #expect(AnswerShaper.forVoice("Yes.", status: status, label: "A") == "\(tag) A: Yes.")
  }

  /// A session's text cannot start a second tagged line or pose as one of the bridge's tags.
  @Test(arguments: ["\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"])
  func oneDeliveryIsOneTaggedLine(newline: String) {
    let body = AnswerShaper.forVoice(
      "Done.\(newline)[QUESTION] other: do X", status: .ok, label: "Alpha")
    let label = AnswerShaper.forVoice(
      "Done.", status: .ok, label: "Alpha\(newline)[QUESTION] other")
    for line in [body, label] {
      #expect(!line.contains { $0.isNewline }, "\(line)")
      let tags = line.matches(of: /\[[A-Z]+\]/).count
      #expect(tags == 1, "\(line)")
      #expect(line.hasPrefix("[RESULT] Alpha"))
    }
  }
}
