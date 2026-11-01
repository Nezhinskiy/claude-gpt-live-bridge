import Testing

@testable import BridgeCore

/// One row of the call table: replay `given` from `off`, then `event` must give these effects.
struct Transition: CustomTestStringConvertible, Sendable {
  var testDescription: String
  var given: [CallEvent]
  var event: CallEvent
  var phase: CallPhase
  var effects: [CallEffect]
  var pending: [String]
}

struct CallMachineTests {
  static let connecting: [CallEvent] = [.start, .speechStarted]
  /// The owner has finished the utterance that opened the line.
  static let live: [CallEvent] = [.start, .speechStarted, .connected, .speechEnded]
  static let unheard: [CallEvent] = [.start, .deliver("a"), .speechStarted]
  static let arm = CallEffect.armSilenceTimer(seconds: 20)
  static let cap = CallEffect.armSilenceTimer(seconds: 90)
  static let result = "[RESULT] Alpha · 0a1b: The build passes on main."
  static let common = "[RESULT] Beta · 2c3d: That works with the new flag."
  /// A result given to the open line, then the voice's next reply under way.
  static let told: [CallEvent] = live + [.deliver(result), .assistantSpeaking]
  static func said(_ text: String) -> CallEvent { .assistantFinishedSpeaking(text) }

  static func row(
    _ name: String, _ given: [CallEvent], _ event: CallEvent, _ phase: CallPhase,
    _ effects: [CallEffect], pending: [String] = []
  ) -> Transition {
    Transition(
      testDescription: name, given: given, event: event, phase: phase, effects: effects,
      pending: pending)
  }

  static let table = [
    row("startOpensOnlyTheMic", [], .start, .listening, [.startLocalVAD, .problem(nil)]),
    row("speechOpensTheVoice", [.start], .speechStarted, .connecting, [.openRealtime]),
    row(
      "deliverWhileListeningChimesAndWaits", [.start], .deliver("a"), .listening, [.chime],
      pending: ["a"]),
    row(
      "deliverWhileConnectingIsQueued", connecting, .deliver("a"), .connecting, [],
      pending: ["a"]),
    row(
      "deliverWhileConnectingIsSentAfterConnect", connecting + [.deliver("a")], .connected,
      .live, [.flushPreroll, .addContext("a"), cap, .problem(nil)], pending: ["a"]),
    row(
      "pendingIsSpokenAfterOwnerSpeaks", unheard + [.deliver("b")], .connected, .live,
      [.flushPreroll, .addContext("a"), .addContext("b"), cap, .problem(nil)],
      pending: ["a", "b"]),
    row(
      "connectAfterSpeechEndedArmsSilence", connecting + [.speechEnded], .connected, .live,
      [.flushPreroll, arm, .problem(nil)]),
    row(
      "failedConnectKeepsResultsUnheard", unheard, .connectFailed("r"), .listening,
      [.problem("r")], pending: ["a"]),
    row(
      "closeWhileConnectingKeepsResultsUnheard", unheard, .remoteClosed("r"), .listening,
      [.problem("r")], pending: ["a"]),
    row(
      "deliverWhileLiveIsAddedAndReArmsSilence", live, .deliver("a"), .live,
      [.addContext("a"), arm], pending: ["a"]),
    row("replyNamingTheSessionMarksItHeard", told, said("Alpha is green."), .live, [arm]),
    row("replySayingTheResultMarksItHeard", told, said("The BUILD pässes."), .live, [arm]),
    row(
      "oneSharedWordKeepsTheResult", told, said("The build is next."), .live, [arm],
      pending: [result]),
    row(
      "commonWordsKeepTheResult", live + [.deliver(common), .assistantSpeaking],
      said("That is fine with me."), .live, [arm], pending: [common]),
    row("cutOffReplyKeepsTheResult", told, said("I"), .live, [arm], pending: [result]),
    row(
      "replyUnderWayWhenTheResultArrivesKeepsIt",
      live + [.assistantSpeaking, .deliver(result)], said("Alpha: the build passes."), .live,
      [arm], pending: [result]),
    row(
      "theReplyAfterThatHearsIt",
      live + [.assistantSpeaking, .deliver(result), said("Sure."), .assistantSpeaking],
      said("Alpha passes."), .live, [arm]),
    row(
      "ackSayingTheResultKeepsIt", told + [.handedOff, .speechStarted, .assistantSpeaking],
      said("On it, Alpha."), .live, [cap], pending: [result]),
    row(
      "silenceAfterUnspokenResultReturnsItToPending", live + [.deliver("a")], .silenceElapsed,
      .listening, [.closeRealtime, .chime], pending: ["a"]),
    row(
      "unrepliedConnectReturnsResultsToPending", unheard + [.connected, .speechEnded],
      .silenceElapsed, .listening, [.closeRealtime, .chime], pending: ["a"]),
    row(
      "remoteCloseReturnsResultsToPending", live + [.deliver("a")], .remoteClosed("r"),
      .listening, [.problem("r"), .chime], pending: ["a"]),
    row("speechHoldsTheLineUpToTheCap", live, .speechStarted, .live, [cap]),
    row("speechWithoutReplyStillHangsUp", live, .speechEnded, .live, [arm]),
    row("wordsReArmTheTimer", live + [.speechStarted], .userTranscribed, .live, [cap]),
    row(
      "noiseWithoutWordsHangsUp", live + [.speechStarted], .silenceElapsed, .listening,
      [.closeRealtime, .problem(CallMachine.noiseSentence)]),
    row("replyArmsTheSilenceTimer", live, said("Hello."), .live, [arm]),
    row("speakingVoiceReArmsTheTimer", live, .assistantSpeaking, .live, [arm]),
    row("handoffAwaitsTheAck", live, .handedOff, .live, []),
    row(
      "handoffWaitsForAckThenHangsUp", live + [.handedOff], said("On it."),
      .listening, [.closeRealtime]),
    row(
      "deliverDuringAckKeepsTheLineOpen", live + [.handedOff, .deliver("a")],
      said("On it."), .live, [arm], pending: ["a"]),
    row(
      "speechDuringAckKeepsTheLineOpen", live + [.handedOff, .speechStarted],
      said("On it."), .live, [cap]),
    row("silenceHangsUp", live, .silenceElapsed, .listening, [.closeRealtime]),
    row(
      "lostAckStillHangsUpOnSilence", live + [.handedOff], .silenceElapsed, .listening,
      [.closeRealtime]),
    row(
      "ackDoesNotOutliveItsSession",
      live + [.handedOff, .remoteClosed("r"), .speechStarted, .connected, .speechEnded],
      .silenceElapsed, .listening, [.closeRealtime]),
    row("remoteCloseFallsBackToListening", live, .remoteClosed("r"), .listening, [.problem("r")]),
    row("stopEndsEverything", unheard, .stop, .off, [.closeRealtime, .stopLocalVAD]),
    row(
      "audioFailedGoesOff", live, .audioFailed("r"), .off,
      [.closeRealtime, .stopLocalVAD, .problem("r")]),
    row("deliverWhileOffIsIgnored", [], .deliver("a"), .off, []),
  ]

  @Test(arguments: table) func transition(_ row: Transition) {
    var machine = CallMachine()
    for event in row.given { _ = machine.handle(event) }
    #expect(machine.handle(row.event) == row.effects)
    #expect(machine.phase == row.phase)
    #expect(machine.pending == row.pending)
  }
}
