#if DEBUG
  import Foundation
  import Testing

  @testable import BridgeCore

  @Suite struct DebugFlagsTests {
    let directory: URL
    let wav: URL
    let text: URL

    init() throws {
      directory = try temporaryDirectory()
      wav = directory.appending(path: "line.wav")
      text = directory.appending(path: "voice.txt")
      try Data([1]).write(to: wav)
      try Data("Read the script.".utf8).write(to: text)
    }

    @Test func noFlagsMeanNoTools() throws {
      #expect(try DebugFlags(arguments: ["LiveBridge"]) == DebugFlags())
    }

    @Test func aCutFlagBelongsToTheLineAfterIt() throws {
      let flags = try DebugFlags(arguments: [
        "LiveBridge", "--fake-mic", wav.path, "--fake-mic-cut", "4.5", "--fake-mic", wav.path,
      ])
      #expect(flags.fakeMicCuts == [nil, 4.5])
    }

    @Test func aCutThatIsNoNumberIsRefused() {
      #expect(throws: DebugFlags.Refused.self) {
        try DebugFlags(arguments: ["LiveBridge", "--fake-mic-cut", "soon"])
      }
    }

    @Test func theFilmMenuFlagTakesNoValue() throws {
      let flags = try DebugFlags(arguments: [
        "LiveBridge", "--film-menu", "--record-call", wav.path,
      ])
      #expect(flags.filmMenu)
      #expect(flags.tape?.path == wav.path)
    }

    @Test func aFakeMicFlagIsGivenOncePerLineAndKeepsItsOrder() throws {
      let other = directory.appending(path: "other.wav")
      try Data([1]).write(to: other)
      let flags = try DebugFlags(arguments: [
        "LiveBridge", "--fake-mic", other.path, "--fake-mic", wav.path,
      ])
      #expect(flags.fakeMic.map(\.path) == [other.path, wav.path])
    }

    @Test func theToolsCanBeGivenTogether() throws {
      let tape = directory.appending(path: "call.wav")
      let flags = try DebugFlags(arguments: [
        "LiveBridge", "--record-call", tape.path, "--voice-instructions", text.path,
      ])
      #expect(flags.tape?.path == tape.path)
      #expect(flags.voiceInstructions == "Read the script.")
    }

    @Test func aFakeMicFileThatIsNotThereIsRefused() {
      let missing = directory.appending(path: "missing.wav").path
      #expect(throws: DebugFlags.Refused.self) {
        try DebugFlags(arguments: ["LiveBridge", "--fake-mic", missing])
      }
    }

    @Test func instructionsThatCannotBeReadAreRefusedRatherThanFallingBackToTheRules() {
      let missing = directory.appending(path: "missing.txt").path
      #expect(throws: DebugFlags.Refused.self) {
        try DebugFlags(arguments: ["LiveBridge", "--voice-instructions", missing])
      }
    }

    @Test func aTapeInAFolderThatIsNotThereIsRefused() {
      let tape = directory.appending(path: "no/such/call.wav").path
      #expect(throws: DebugFlags.Refused.self) {
        try DebugFlags(arguments: ["LiveBridge", "--record-call", tape])
      }
    }

    @Test func aFlagWithNoValueIsRefused() {
      #expect(throws: DebugFlags.Refused.self) {
        try DebugFlags(arguments: ["LiveBridge", "--record-call"])
      }
    }
  }
#endif
