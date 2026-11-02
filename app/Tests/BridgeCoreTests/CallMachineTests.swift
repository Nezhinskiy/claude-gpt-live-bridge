import Testing

@testable import BridgeCore

/// One row of the call table: replay `given` from `off`, then `event` must give these effects.
struct Transition: CustomTestStringConvertible, Sendable {
  var testDescription: String
  var given: [CallEvent]
  var event: CallEvent
  var phase: CallPhase
  var effects: [CallEffect]
  var pending: [VoiceLine]
}

struct CallMachineTests {
  static let connecting: [CallEvent] = [.start, .speechStarted]
  /// The owner has finished the utterance that opened the line.
  static let live: [CallEvent] = [.start, .speechStarted, .connected, .speechEnded]
  static let unheard: [CallEvent] = [.start, deliver(a), .speechStarted]
  static let arm = CallEffect.armSilenceTimer(seconds: 20)
  static let r = Problem.other("r")
  static let cap = CallEffect.armSilenceTimer(seconds: 90)
  static let alpha = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  static let beta = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")
  /// Lines of the bridge's own, which no session waits for.
  static let a = VoiceLine(kind: .failed, label: "LiveBridge", body: "a")
  static let b = VoiceLine(kind: .failed, label: "LiveBridge", body: "b")
  static func alphas(_ kind: VoiceLine.Kind, _ body: String) -> VoiceLine {
    VoiceLine(kind: kind, label: "Alpha · 0a1b", body: body, session: alpha)
  }
  static let result = alphas(.result, "The build passes on main.")
  static let common = VoiceLine(
    kind: .result, label: "Beta · 2c3d", body: "That works with the new flag.", session: beta)
  static let done = alphas(.result, "Done.")
  static let approval = alphas(.approval, "Claude is waiting for your approval")
  static let update = alphas(.update, "Tests pass.")
  /// A result given to the open line, then the voice's next reply under way.
  static let told: [CallEvent] = live + [deliver(result), .assistantSpeaking]
  static func said(_ text: String) -> CallEvent { .assistantFinishedSpeaking(text) }
  static func deliver(_ line: VoiceLine) -> CallEvent { .deliver(line) }
  /// A line from Alpha, the session the request was handed to.
  static let fromAlpha = deliver(result)
  static let window = CallEffect.armResultWindow(seconds: 120)
  static let grace = CallEffect.armGrace(milliseconds: 800)
  /// A request handed to Alpha and acknowledged; the owner has stopped talking.
  static let waiting: [CallEvent] = live + [.handedOff(alpha), .assistantSpeaking, said("On it.")]

  static func row(
    _ name: String, _ given: [CallEvent], _ event: CallEvent, _ phase: CallPhase,
    _ effects: [CallEffect], pending: [VoiceLine] = []
  ) -> Transition {
    Transition(
      testDescription: name, given: given, event: event, phase: phase, effects: effects,
      pending: pending)
  }

  static let table = [
    row("startOpensOnlyTheMic", [], .start, .listening, [.startLocalVAD, .problem(nil)]),
    row("speechOpensTheVoice", [.start], .speechStarted, .connecting, [.openRealtime]),
    row(
      "deliverWhileListeningChimesAndWaits", [.start], deliver(a), .listening, [.chime],
      pending: [a]),
    row(
      "deliverWhileConnectingIsQueued", connecting, deliver(a), .connecting, [],
      pending: [a]),
    row(
      "deliverWhileConnectingIsSentAfterConnect", connecting + [deliver(a)], .connected,
      .live, [.flushPreroll, .addContext(a), cap, .problem(nil)], pending: [a]),
    row(
      "pendingIsSpokenAfterOwnerSpeaks", unheard + [deliver(b)], .connected, .live,
      [.flushPreroll, .addContext(a), .addContext(b), cap, .problem(nil)],
      pending: [a, b]),
    row(
      "connectAfterSpeechEndedArmsSilence", connecting + [.speechEnded], .connected, .live,
      [.flushPreroll, arm, .problem(nil)]),
    row(
      "failedConnectKeepsResultsUnheard", unheard, .connectFailed(r), .listening,
      [.problem(r)], pending: [a]),
    row(
      "closeWhileConnectingKeepsResultsUnheard", unheard, .remoteClosed(r), .listening,
      [.problem(r)], pending: [a]),
    row(
      "deliverWhileLiveIsAddedAndReArmsSilence", live, deliver(a), .live,
      [.addContext(a), arm], pending: [a]),
    row(
      "replyNamingOnlyTheSessionKeepsTheResult", told, said("Alpha is still working."), .live,
      [arm], pending: [result]),
    row("labelAndOneBodyWordMarkItHeard", told, said("Alpha's build is green."), .live, [arm]),
    row(
      "labelAloneHearsAResultWithNoDistinctWord", live + [deliver(done), .assistantSpeaking],
      said("Alpha is done."), .live, [arm]),
    row("replySayingTheResultMarksItHeard", told, said("The BUILD pässes."), .live, [arm]),
    row(
      "oneSharedWordKeepsTheResult", told, said("The build is next."), .live, [arm],
      pending: [result]),
    row(
      "commonWordsKeepTheResult", live + [deliver(common), .assistantSpeaking],
      said("That is fine with me."), .live, [arm], pending: [common]),
    row("cutOffReplyKeepsTheResult", told, said("I"), .live, [arm], pending: [result]),
    row(
      "replyUnderWayWhenTheResultArrivesKeepsIt",
      live + [.assistantSpeaking, deliver(result)], said("Alpha: the build passes."), .live,
      [arm], pending: [result]),
    row(
      "theReplyAfterThatHearsIt",
      live + [.assistantSpeaking, deliver(result), said("Sure."), .assistantSpeaking],
      said("Alpha passes."), .live, [arm]),
    row(
      "ackSayingTheResultKeepsIt", told + [.handedOff(alpha), .speechStarted, .assistantSpeaking],
      said("On it, Alpha."), .live, [cap], pending: [result]),
    row(
      "silenceAfterUnspokenResultReturnsItToPending", live + [deliver(a)], .silenceElapsed,
      .listening, [.closeRealtime, .chime], pending: [a]),
    row(
      "unrepliedConnectReturnsResultsToPending", unheard + [.connected, .speechEnded],
      .silenceElapsed, .listening, [.closeRealtime, .chime], pending: [a]),
    row(
      "remoteCloseReturnsResultsToPending", live + [deliver(a)], .remoteClosed(r),
      .listening, [.problem(r), .chime], pending: [a]),
    row("speechHoldsTheLineUpToTheCap", live, .speechStarted, .live, [cap]),
    row("speechWithoutReplyStillHangsUp", live, .speechEnded, .live, [arm]),
    row("wordsReArmTheTimer", live + [.speechStarted], .userTranscribed, .live, [cap]),
    row(
      "noiseWithoutWordsHangsUp", live + [.speechStarted], .silenceElapsed, .listening,
      [.closeRealtime, .problem(CallMachine.noise)]),
    row("replyArmsTheSilenceTimer", live, said("Hello."), .live, [arm]),
    row("speakingVoiceReArmsTheTimer", live, .assistantSpeaking, .live, [arm]),
    row("handoffOpensTheResultWindow", live, .handedOff(alpha), .live, [window]),
    row("aLaterHandoffRestartsTheWindow", waiting, .handedOff(alpha), .live, [window]),
    row("handoffToNoSessionOpensNoWindow", live, .handedOff(nil), .live, []),
    row(
      "ackKeepsTheLineOpenForTheResult", live + [.handedOff(alpha), .assistantSpeaking],
      said("On it."), .live, [arm]),
    row(
      "deliverFromAnotherSessionDuringTheWindowIsOnlyContext", waiting, deliver(a), .live,
      [.addContext(a), arm], pending: [a]),
    row(
      "speechDuringAckKeepsTheLineOpen", live + [.handedOff(alpha), .speechStarted],
      said("On it."), .live, [cap]),
    row("silenceHangsUp", live, .silenceElapsed, .listening, [.closeRealtime]),
    row("silenceDuringTheWindowKeepsTheLineOpen", waiting, .silenceElapsed, .live, []),
    row(
      "noiseStillHangsUpDuringTheWindow", waiting + [.speechStarted], .silenceElapsed,
      .listening, [.closeRealtime, .problem(CallMachine.noise)]),
    row(
      "windowExpiryAfterSilenceHangsUp", waiting + [.silenceElapsed], .resultWindowElapsed,
      .listening, [.closeRealtime]),
    row(
      "windowExpiryKeepsWaitingResultsUnheard", waiting + [deliver(a), .silenceElapsed],
      .resultWindowElapsed, .listening, [.closeRealtime, .chime], pending: [a]),
    row(
      "windowExpiryWhileTalkingLeavesItToSilence", waiting + [.silenceElapsed, .speechStarted],
      .resultWindowElapsed, .live, []),
    row(
      "silenceAfterAnExpiredWindowHangsUp",
      waiting + [.speechStarted, .resultWindowElapsed, .speechEnded], .silenceElapsed,
      .listening, [.closeRealtime]),
    row(
      "aResultAfterTheWindowIsOnlyContext", waiting + [.speechStarted, .resultWindowElapsed],
      fromAlpha, .live, [.addContext(result), cap], pending: [result]),
    row(
      "earlyResultIsSpokenAtOnce", waiting, fromAlpha, .live, [.speak(result), arm],
      pending: [result]),
    row(
      "anApprovalIsSaidAtOnce", waiting, deliver(approval), .live, [.speak(approval), arm],
      pending: [approval]),
    row(
      "anApprovalLeavesTheLineWaiting", waiting + [deliver(approval)], .silenceElapsed, .live, [],
      pending: [approval]),
    row(
      "anUpdateLeavesTheLineWaiting", waiting + [deliver(update)], .silenceElapsed, .live, [],
      pending: [update]),
    row(
      "theResultAfterAnApprovalIsSaid", waiting + [deliver(approval)], fromAlpha, .live,
      [.speak(result), arm], pending: [approval, result]),
    row(
      "earlyResultEndsTheWindow", waiting + [fromAlpha], .silenceElapsed, .listening,
      [.closeRealtime, .chime], pending: [result]),
    row(
      "theSpokenResultIsHeardThenSilenceHangsUp",
      waiting + [fromAlpha, .assistantSpeaking, said("Alpha's build passes.")], .silenceElapsed,
      .listening, [.closeRealtime]),
    row(
      "aSecondSessionKeepsTheWindowOpen",
      waiting + [.handedOff(beta), said("On it."), fromAlpha], .silenceElapsed, .live, [],
      pending: [result]),
    row(
      "resultWhileTheOwnerSpeaksWaits", waiting + [.speechStarted], fromAlpha, .live, [cap],
      pending: [result]),
    row(
      "theOwnersSilenceStartsTheGrace", waiting + [.speechStarted, fromAlpha], .speechEnded,
      .live, [arm, grace], pending: [result]),
    row(
      "theGraceSpeaksIt", waiting + [.speechStarted, fromAlpha, .speechEnded], .graceElapsed,
      .live, [.speak(result), arm], pending: [result]),
    row(
      "speechDuringTheGraceHoldsIt",
      waiting + [.speechStarted, fromAlpha, .speechEnded, .speechStarted], .graceElapsed, .live,
      [], pending: [result]),
    row(
      "aGraceSpeaksItOnlyOnce",
      waiting + [.speechStarted, fromAlpha, .speechEnded, .graceElapsed], .graceElapsed, .live,
      [], pending: [result]),
    row(
      "resultWhileTheVoiceSpeaksWaits", live + [.handedOff(alpha), .assistantSpeaking],
      fromAlpha, .live, [arm], pending: [result]),
    row(
      "theVoiceFinishingStartsTheGrace",
      live + [.handedOff(alpha), .assistantSpeaking, fromAlpha], said("On it."), .live,
      [arm, grace], pending: [result]),
    row(
      "theOwnerStillSpeakingDefersTheGrace",
      live + [.handedOff(alpha), .speechStarted, .assistantSpeaking, fromAlpha], said("On it."),
      .live, [cap], pending: [result]),
    row(
      "aHangUpDropsWhatWaitedToBeSpoken",
      waiting + [.speechStarted, fromAlpha, .remoteClosed(r), .speechStarted, .connected],
      .graceElapsed, .live, [], pending: [result]),
    row(
      "theWindowDoesNotOutliveItsSession",
      live + [.handedOff(alpha), .remoteClosed(r), .speechStarted, .connected, .speechEnded],
      .silenceElapsed, .listening, [.closeRealtime]),
    row("remoteCloseFallsBackToListening", live, .remoteClosed(r), .listening, [.problem(r)]),
    row("stopEndsEverything", unheard, .stop, .off, [.closeRealtime, .stopLocalVAD]),
    row(
      "audioFailedGoesOff", live, .audioFailed(r), .off,
      [.closeRealtime, .stopLocalVAD, .problem(r)]),
    row("deliverWhileOffIsIgnored", [], deliver(a), .off, []),
    row(
      "targetChangeClosesTheOpenLine", live + [deliver(a)], .targetChanged, .listening,
      [.closeRealtime, .chime], pending: [a]),
    row(
      "targetChangeWhileConnectingCloses", connecting, .targetChanged, .listening, [.closeRealtime]),
    row("targetChangeWhileListeningChangesNothing", [.start], .targetChanged, .listening, []),
  ]

  @Test(arguments: table) func transition(_ row: Transition) {
    var machine = CallMachine()
    for event in row.given { _ = machine.handle(event) }
    #expect(machine.handle(row.event) == row.effects)
    #expect(machine.phase == row.phase)
    #expect(machine.pending == row.pending)
  }

  /// A result held while the owner spoke is withdrawn with the rest: nothing is left to say.
  @Test func aWithdrawnHeldResultIsNotSaid() {
    var machine = CallMachine()
    for event in Self.waiting + [.speechStarted, Self.fromAlpha] { _ = machine.handle(event) }
    machine.withdraw { $0.session == Self.alpha }
    #expect(machine.handle(.speechEnded) == [Self.arm])
    #expect(machine.handle(.graceElapsed) == [])
    #expect(machine.pending.isEmpty)
  }
}
