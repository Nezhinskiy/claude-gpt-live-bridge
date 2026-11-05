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
  /// A line the bridge says opens a closed line: the target's answer or question.
  static func opening(_ line: VoiceLine) -> CallEvent { .deliver(line, opensLine: true) }
  static let asking = alphas(.asking, "Which branch?")
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
      "failedConnectChimesForUnheardResults", unheard, .connectFailed(r), .listening,
      [.problem(r), .chime], pending: [a]),
    row(
      "closeWhileConnectingChimesForUnheardResults", unheard, .remoteClosed(r), .listening,
      [.problem(r), .chime], pending: [a]),
    row(
      "aLineThatOpensTheLineOpensIt", [.start], opening(result), .connecting,
      [.openRealtimeForResult], pending: [result]),
    row(
      "theOpenedLineSaysWhatOpenedIt", [.start, opening(result)], .connected, .live,
      [.flushPreroll, .speak(result), arm, .problem(nil)], pending: [result]),
    row(
      "theOpenedLineHoldsItWhileTheOwnerSpeaks", [.start, opening(result), .speechStarted],
      .connected, .live, [.flushPreroll, cap, .problem(nil)], pending: [result]),
    row(
      "aHeldOpenerIsSaidAfterTheGrace",
      [.start, opening(result), .speechStarted, .connected, .speechEnded], .graceElapsed, .live,
      [.speak(result), arm], pending: [result]),
    row(
      "aFailedOpeningThenSpeechGivesItAsContext",
      [.start, opening(result), .connectFailed(r), .speechStarted], .connected, .live,
      [.flushPreroll, .addContext(result), cap, .problem(nil)], pending: [result]),
    row(
      "theOpenedLineGetsOtherUnheardLinesAsContext", [.start, deliver(a), opening(result)],
      .connected, .live,
      [.flushPreroll, .addContext(a), .speak(result), arm, .problem(nil)], pending: [a, result]),
    row(
      "anOpenedLineLeftSilentChimes", [.start, opening(result), .connected], .silenceElapsed,
      .listening, [.closeRealtime, .chime], pending: [result]),
    row(
      "aFailedOpeningChimes", [.start, opening(result)], .connectFailed(r), .listening,
      [.problem(r), .chime], pending: [result]),
    row(
      "anOpeningLineWhileConnectingWaitsForTheConnect", connecting, opening(result),
      .connecting, [], pending: [result]),
    row(
      "anOpeningLineOnALiveLineIsALine", live, opening(a), .live, [.addContext(a), arm],
      pending: [a]),
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
    row(
      "handoffIsConfirmedAndOpensTheResultWindow", live, .handedOff(alpha), .live,
      [.confirmHandoff, window]),
    row(
      "aLaterHandoffIsConfirmedAndRestartsTheWindow", waiting, .handedOff(alpha), .live,
      [.confirmHandoff, window]),
    row("handoffToNoSessionIsNotConfirmedAndOpensNoWindow", live, .handedOff(nil), .live, []),
    row(
      "aHandoffWhileConnectingIsConfirmed", connecting, .handedOff(alpha), .connecting,
      [.confirmHandoff]),
    row(
      "aHandoffAsTheLineClosesIsConfirmed", [.start], .handedOff(alpha), .listening,
      [.confirmHandoff]),
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
      "targetChangeClosesTheOpenLine", live + [deliver(a)], .conversationChanged, .listening,
      [.closeRealtime, .chime], pending: [a]),
    row(
      "targetChangeWhileConnectingCloses", connecting, .conversationChanged, .listening,
      [.closeRealtime]),
    row("targetChangeWhileListeningChangesNothing", [.start], .conversationChanged, .listening, []),
  ]

  @Test(arguments: table) func transition(_ row: Transition) {
    var machine = CallMachine()
    for event in row.given { _ = machine.handle(event) }
    #expect(machine.handle(row.event) == row.effects)
    #expect(machine.phase == row.phase)
    #expect(machine.pending == row.pending)
  }

  /// After `/clear` the line waits for the session under its new id, and its unheard results
  /// are the new id's.
  @Test func aRenamedSessionKeepsItsWaitAndItsResults() {
    let cleared = SessionID(rawValue: "22222222-0000-0000-0000-000000000003")
    var machine = CallMachine()
    for event in Self.waiting + [Self.deliver(Self.update)] { _ = machine.handle(event) }
    machine.rename(Self.alpha, to: cleared)
    #expect(machine.awaited == [cleared] && machine.pending.map(\.session) == [cleared])
    var answer = Self.result
    answer.session = cleared
    #expect(machine.handle(.deliver(answer)) == [.speak(answer), Self.arm])
  }

  /// A `/clear` while the line an answer opened still connects keeps that answer to be said.
  @Test func aRenameWhileTheOpenedLineConnectsStillSaysIt() {
    let cleared = SessionID(rawValue: "22222222-0000-0000-0000-000000000003")
    var machine = CallMachine()
    for event in [CallEvent.start, Self.opening(Self.result)] { _ = machine.handle(event) }
    machine.rename(Self.alpha, to: cleared)
    var said = Self.result
    said.session = cleared
    #expect(machine.handle(.connected) == [.flushPreroll, .speak(said), Self.arm, .problem(nil)])
  }

  /// A question withdrawn while the line it opened still connects leaves nothing to say: the
  /// line closes, and nothing chimes.
  @Test func withdrawingWhatOpenedTheLineClosesIt() {
    var machine = CallMachine()
    for event in [CallEvent.start, Self.opening(Self.asking)] { _ = machine.handle(event) }
    #expect(machine.withdraw { $0 == Self.asking } == [.closeRealtime])
    #expect(machine.phase == .listening)
  }

  /// A line the owner opened by speaking stays, whatever is withdrawn from it.
  @Test func withdrawingKeepsALineTheOwnerOpened() {
    var machine = CallMachine()
    for event in [CallEvent.start, Self.deliver(Self.asking), .speechStarted] {
      _ = machine.handle(event)
    }
    #expect(machine.withdraw { $0 == Self.asking } == [])
    #expect(machine.phase == .connecting)
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
