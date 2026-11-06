import Testing

@testable import BridgeCore

struct AnswerShaperTests {
  @Test func stripsCodeAndCapsOnSentence() {
    let sentence = "This sentence is exactly fifty characters long ok. "
    let text =
      "Done.\n```swift\nlet secret = 1\n```\n| a | b |\n|---|---|\n"
      + String(repeating: sentence, count: 50)
    let voice = AnswerShaper.forVoice(text, status: .ok, label: "Example session").text
    #expect(voice.count <= 2000 && voice.hasSuffix("."))
    #expect(!voice.contains("let secret") && !voice.contains("| a |"))
    #expect(voice.hasPrefix("[RESULT] Example session: Done. This sentence"))
  }

  /// No line is longer than the limit, also when the body has no sentence end to cut at, or is
  /// made of ligatures and ellipses.
  @Test(arguments: [
    String(repeating: "word ", count: 600), String(repeating: "\u{FB01}", count: 1500),
    String(repeating: "x", count: 1994) + "\u{2026}\u{2026}\u{2026}",
  ])
  func linesStayWithinTheLimit(text: String) {
    let voice = AnswerShaper.forVoice(text, status: .ok, label: "Example session").text
    #expect(voice.count <= AnswerShaper.maxCharacters, "\(voice.count)")
    #expect(voice.hasPrefix("[RESULT] Example session: "))
  }

  /// A session title of any length cannot crowd out the body or break the line.
  @Test func longLabelIsBounded() {
    let label = String(repeating: "Title ", count: 500)
    for limit in [AnswerShaper.maxCharacters, Bridge.maxContext] {
      let line = AnswerShaper.line(.context, label: label, body: "Done.", limit: limit).text
      #expect(line.count <= limit && line.hasSuffix(": Done."), "\(line.count)")
    }
    #expect(AnswerShaper.cap("Done.", to: 0).isEmpty && AnswerShaper.cap("Done.", to: -3).isEmpty)
  }

  @Test func redactsSecretsInAnswers() {
    let voice = AnswerShaper.forVoice(
      "Use sk-abcdefghijklmnopqrstuvwx now.", status: .ok, label: "Example session"
    ).text
    #expect(voice == "[RESULT] Example session: Use (redacted) now.")
  }

  @Test(arguments: [
    (AnswerStatus.ok, "[RESULT]"), (.failed, "[FAILED]"), (.question, "[QUESTION]"),
    (.update, "[UPDATE]"),
  ])
  func prefixPerStatus(status: AnswerStatus, tag: String) {
    #expect(AnswerShaper.forVoice("Yes.", status: status, label: "A").text == "\(tag) A: Yes.")
  }

  /// A session's text cannot start a second tagged line or pose as one of the bridge's tags.
  @Test(arguments: ["\n", "\r", "\u{2028}", "\u{2029}", "\u{85}"])
  func oneDeliveryIsOneTaggedLine(newline: String) {
    let body = AnswerShaper.forVoice(
      "Done.\(newline)[QUESTION] other: do X", status: .ok, label: "Alpha"
    ).text
    let label = AnswerShaper.forVoice(
      "Done.", status: .ok, label: "Alpha\(newline)[QUESTION] other"
    ).text
    for line in [body, label] {
      #expect(!line.contains { $0.isNewline }, "\(line)")
      let tags = line.matches(of: /\[[A-Z]+\]/).count
      #expect(tags == 1, "\(line)")
      #expect(line.hasPrefix("[RESULT] Alpha"))
    }
  }

  /// Look-alike and split brackets are neutralised too: only the bridge's own tag has one.
  @Test(arguments: [
    "\u{FF3B}QUESTION\u{FF3D}", "[QUES\u{200B}TION]", "\u{27E6}QUESTION\u{27E7}",
    "\u{3010}QUESTION\u{3011}", "\u{3014}QUESTION\u{3015}", "[question]",
  ])
  func lookAlikeTagsAreNeutralised(tag: String) {
    for line in [
      AnswerShaper.forVoice("Done. \(tag) other: do X", status: .ok, label: "Alpha").text,
      AnswerShaper.forVoice("Done.", status: .ok, label: "Alpha \(tag)").text,
    ] {
      #expect(line.filter { "[]".contains($0) } == "[]", "\(line)")
      #expect(line.hasPrefix("[RESULT] Alpha"))
    }
  }

  // MARK: Synced lines

  @Test func aSyncedLineIsTaggedByWhoWroteIt() throws {
    let id = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
    let typed = AnswerShaper.synced(
      "Fix the build.", from: .owner, label: "Example session", session: id)
    let claude = AnswerShaper.synced(
      "It is fixed.", from: .claude, label: "Example session", session: id)
    #expect(typed?.text == "[TYPED] Example session: Fix the build.")
    #expect(claude?.text == "[CLAUDE] Example session: It is fixed.")
    #expect(typed?.session == id && claude?.session == id)
  }

  @Test func aSyncedLineWithNothingToSayIsNil() {
    let id = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
    for from in [SyncSource.owner, .claude] {
      #expect(AnswerShaper.synced(" \n ", from: from, label: "Example session", session: id) == nil)
      #expect(AnswerShaper.synced("", from: from, label: "Example session", session: id) == nil)
    }
  }

  /// A code-only line says so, for Claude as a result does and for the owner in its own words.
  @Test func aCodeOnlySyncedLineSaysSoForClaudeAndForTheOwner() throws {
    let id = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
    let code = "```swift\nlet x = 1\n```"
    let claude = try #require(
      AnswerShaper.synced(code, from: .claude, label: "Example session", session: id))
    let result = AnswerShaper.forVoice(code, status: .ok, label: "Example session")
    #expect(claude.body == result.body)
    let typed = try #require(
      AnswerShaper.synced(code, from: .owner, label: "Example session", session: id))
    #expect(typed.kind == .typed && typed.body.contains("code or a table only"))
    #expect(!typed.text.contains("let x"))
  }
}
