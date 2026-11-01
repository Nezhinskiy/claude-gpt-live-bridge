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
  static let live: [CallEvent] = [.start, .speechStarted, .connected]
  static let unheard: [CallEvent] = [.start, .deliver("a"), .speechStarted]
  static let arm = CallEffect.armSilenceTimer(seconds: 20)

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
      .live, [.flushPreroll, .addContext("a"), arm]),
    row(
      "pendingIsSpokenAfterOwnerSpeaks", unheard + [.deliver("b")], .connected, .live,
      [.flushPreroll, .addContext("a"), .addContext("b"), arm]),
    row(
      "failedConnectKeepsResultsUnheard", unheard, .connectFailed("r"), .listening,
      [.problem("r")], pending: ["a"]),
    row(
      "closeWhileConnectingKeepsResultsUnheard", unheard, .remoteClosed("r"), .listening,
      [.problem("r")], pending: ["a"]),
    row(
      "deliverWhileLiveIsAddedAsContext", live, .deliver("a"), .live,
      [.addContext("a"), .cancelSilenceTimer]),
    row("speechHoldsTheLine", live, .speechStarted, .live, [.cancelSilenceTimer]),
    row("speechWithoutReplyStillHangsUp", live, .speechEnded, .live, [arm]),
    row("replyArmsTheSilenceTimer", live, .assistantFinishedSpeaking, .live, [arm]),
    row("handoffAwaitsTheAck", live, .handedOff, .live, []),
    row(
      "handoffWaitsForAckThenHangsUp", live + [.handedOff], .assistantFinishedSpeaking,
      .listening, [.closeRealtime]),
    row("silenceHangsUp", live, .silenceElapsed, .listening, [.closeRealtime]),
    row(
      "lostAckStillHangsUpOnSilence", live + [.handedOff], .silenceElapsed, .listening,
      [.closeRealtime]),
    row(
      "ackDoesNotOutliveItsSession",
      live + [.handedOff, .remoteClosed("r"), .speechStarted, .connected], .silenceElapsed,
      .listening, [.closeRealtime]),
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
