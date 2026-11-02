import Testing

@testable import BridgeCore

struct VoicePromptTests {
  /// The owner's prompt from Settings comes after every built-in rule, as its own paragraph.
  @Test func theOwnersPromptComesLast() throws {
    let composed = VoicePrompt.composed(owner: "  Speak with me in Spanish.\n")
    #expect(composed.hasPrefix(VoicePrompt.text + "\n\n"))
    let added = composed.dropFirst(VoicePrompt.text.count)
    #expect(added.hasSuffix("\nSpeak with me in Spanish."))
    #expect(added.components(separatedBy: "\n\n").count == 2)  // one paragraph after the rules
  }

  @Test func anEmptyPromptAddsNothing() {
    #expect(VoicePrompt.composed(owner: "") == VoicePrompt.text)
    #expect(VoicePrompt.composed(owner: " \n\t ") == VoicePrompt.text)
  }

  @Test func theOwnersPromptIsCapped() {
    let long = String(repeating: "é", count: VoicePrompt.ownerLimit + 50)
    let composed = VoicePrompt.composed(owner: long)
    #expect(composed.hasSuffix("\n" + String(repeating: "é", count: VoicePrompt.ownerLimit)))
    #expect(!composed.hasSuffix("\n" + String(repeating: "é", count: VoicePrompt.ownerLimit + 1)))
    #expect(VoicePrompt.ownerLimit == 2_000)
  }
}
