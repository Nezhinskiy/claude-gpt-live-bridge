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
  static let limit = Problem.codex(.realtimeError("You’ve hit your usage limit."))
  static let cap = CallEffect.armSilenceTimer(seconds: 90)
  /// A line a result opened waits this long for the voice's first word.
  static let firstWord = CallEffect.armSilenceTimer(seconds: 5)
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
  /// A line of the session the open line is about.
  static func onItsLine(_ line: VoiceLine) -> CallEvent { .deliver(line, onOwnLine: true) }
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
    row(
      "startClearsTheProblemThenOpensOnlyTheMic", [], .start, .listening,
      [.problem(nil), .startLocalVAD]),
    row("speechOpensTheVoice", [.start], .speechStarted, .connecting, [.openRealtime]),
    row(
      "muteWhileListeningReleasesTheMicrophone", [.start], .mute, .listening,
      [.muteMicrophone]),
    row("speechWhileMutedIsIgnored", [.start, .mute], .speechStarted, .listening, []),
    row(
      "speechWhileMutedOnALiveLineIsIgnored", live + [.mute], .speechStarted, .live, []),
    row(
      "aResultWhileMutedStillOpensTheLine", [.start, .mute], opening(result), .connecting,
      [.openRealtimeForResult, .confirmAnswer], pending: [result]),
    row(
      "muteWhileSpeakingOnALiveLineEndsTheSpeech", live + [.speechStarted], .mute, .live,
      [.muteMicrophone, arm]),
    row(
      "muteWhileAResultIsHeldGivesItItsGrace", waiting + [.speechStarted, fromAlpha], .mute,
      .live, [.muteMicrophone, arm, grace], pending: [result]),
    row(
      "muteWhileConnectingArmsTheSilenceOnConnect", connecting + [.mute], .connected, .live,
      [.problem(nil), .flushPreroll, arm]),
    row(
      "speechWhileMutedOnAConnectingLineDoesNotPinIt", connecting + [.mute, .speechStarted],
      .connected, .live, [.problem(nil), .flushPreroll, arm]),
    row("muteOnAQuietLiveLineLeavesItsSilenceRunning", live, .mute, .live, [.muteMicrophone]),
    row(
      "muteOnALineAResultOpenedDoesNotExtendTheFirstWordWait",
      [.start, opening(result), .connected], .mute, .live, [.muteMicrophone],
      pending: [result]),
    row("aSecondMuteDoesNothing", live + [.mute], .mute, .live, []),
    row(
      "unmuteTakesTheMicrophoneAgain", [.start, .mute], .unmute, .listening,
      [.unmuteMicrophone]),
    row("unmuteWhileUnmutedDoesNothing", [.start], .unmute, .listening, []),
    row("muteWhileOffDoesNothing", [], .mute, .off, []),
    row(
      "deliverWhileListeningChimesAndWaits", [.start], deliver(a), .listening, [.chime],
      pending: [a]),
    row(
      "deliverWhileConnectingIsQueued", connecting, deliver(a), .connecting, [],
      pending: [a]),
    row(
      "deliverWhileConnectingIsSentAfterConnect", connecting + [deliver(a)], .connected,
      .live, [.problem(nil), .flushPreroll, .addContext(a), cap], pending: [a]),
    row(
      "pendingIsSpokenAfterOwnerSpeaks", unheard + [deliver(b)], .connected, .live,
      [.problem(nil), .flushPreroll, .addContext(a), .addContext(b), cap],
      pending: [a, b]),
    row(
      "connectAfterSpeechEndedArmsSilence", connecting + [.speechEnded], .connected, .live,
      [.problem(nil), .flushPreroll, arm]),
    row(
      "failedConnectChimesForUnheardResults", unheard, .connectFailed(r), .listening,
      [.problem(r), .chime], pending: [a]),
    row(
      "closeWhileConnectingChimesForUnheardResults", unheard, .remoteClosed(r), .listening,
      [.problem(r), .chime], pending: [a]),
    row(
      "aUsageLimitAtOpenEndsTheCall", connecting, .connectFailed(limit), .off,
      [.problem(limit), .stopLocalVAD, .endCodex]),
    row(
      "aUsageLimitMidLineEndsTheCall", live, .remoteClosed(limit), .off,
      [.problem(limit), .stopLocalVAD, .endCodex]),
    row(
      "aUsageLimitKeepsWhatWaits", unheard, .connectFailed(limit), .off,
      [.problem(limit), .stopLocalVAD, .endCodex, .chime], pending: [a]),
    row(
      "aHeldLineIsNoLongerHeldAfterALimit",
      live + [
        .handedOff(alpha), .speechStarted, fromAlpha, .remoteClosed(limit), .start,
        .speechStarted, .connected, .speechEnded,
      ],
      .graceElapsed, .live, [], pending: [result]),
    row(
      "aLineAfterALimitIsKept", connecting + [.connectFailed(limit)], deliver(a), .off, [.chime],
      pending: [a]),
    row(
      "aLineAfterStopIsDropped", connecting + [.stop], deliver(a), .off, []),
    row(
      "stopForgetsWhatALimitKept", unheard + [.connectFailed(limit)], .stop, .off,
      [.closeRealtime, .stopLocalVAD]),
    row(
      "startTriesAgainAfterAUsageLimit", connecting + [.connectFailed(limit)], .start, .listening,
      [.problem(nil), .startLocalVAD]),
    row(
      "aLineAfterStartIsNotKeptByThePause",
      connecting + [.connectFailed(limit), .start, .stop], deliver(a), .off, []),
    row(
      "theServiceRefusingEndsALiveLine", live, .refused(limit), .off,
      [.problem(limit), .closeRealtime, .stopLocalVAD, .endCodex]),
    row(
      "theServiceRefusingEndsAConnectingLine", connecting, .refused(limit), .off,
      [.problem(limit), .closeRealtime, .stopLocalVAD, .endCodex]),
    row(
      "theServiceRefusingEndsAListeningCall", [.start], .refused(limit), .off,
      [.problem(limit), .closeRealtime, .stopLocalVAD, .endCodex]),
    row("theServiceRefusingAStoppedCallDoesNothing", [], .refused(limit), .off, []),
    row(
      "aLineThatOpensTheLineOpensIt", [.start], opening(result), .connecting,
      [.openRealtimeForResult, .confirmAnswer], pending: [result]),
    row(
      "theOpenedLineGetsItAsContextAndWaitsBrieflyForTheVoice", [.start, opening(result)],
      .connected, .live, [.problem(nil), .flushPreroll, .addContext(result), firstWord],
      pending: [result]),
    row(
      "theOwnerSpeakingWhileAnOpenedLineConnectsGetsTheNoiseCap",
      [.start, opening(result), .speechStarted], .connected, .live,
      [.problem(nil), .flushPreroll, .addContext(result), cap], pending: [result]),
    row(
      "anotherLineBeforeTheFirstWordKeepsTheShortWait", [.start, opening(result), .connected],
      deliver(a), .live, [.addContext(a), firstWord], pending: [result, a]),
    row(
      "theOwnersWordsOnAnOpenedLineGetTheUsualSilence", [.start, opening(result), .connected],
      .userTranscribed, .live, [arm], pending: [result]),
    row(
      "theVoiceSpeakingOnAnOpenedLineGetsTheUsualSilence",
      [.start, opening(result), .connected], .assistantSpeaking, .live, [arm],
      pending: [result]),
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
      "earlyResultIsSpokenAtOnce", waiting, fromAlpha, .live,
      [.confirmAnswer, .speak(result), arm], pending: [result]),
    row(
      "anApprovalIsSaidAtOnce", waiting, deliver(approval), .live, [.speak(approval), arm],
      pending: [approval]),
    row(
      "aQuestionOnItsOwnLineIsSaid", live, onItsLine(asking), .live, [.speak(asking), arm],
      pending: [asking]),
    row(
      "anApprovalOnItsOwnLineIsSaid", live, onItsLine(approval), .live, [.speak(approval), arm],
      pending: [approval]),
    row(
      "aQuestionOnAnotherSessionsLineIsContext", live, deliver(asking), .live,
      [.addContext(asking), arm], pending: [asking]),
    row(
      "aResultNobodyWaitsForOnItsOwnLineIsContext", live, onItsLine(result), .live,
      [.confirmAnswer, .addContext(result), arm], pending: [result]),
    row(
      "aQuestionOnItsOwnLineWaitsWhileTheOwnerSpeaks", live + [.speechStarted], onItsLine(asking),
      .live, [cap], pending: [asking]),
    row(
      "aQuestionOnItsOwnLineWaitsWhileTheVoiceSpeaks", live + [.assistantSpeaking],
      onItsLine(asking), .live, [arm], pending: [asking]),
    row(
      "aHeldQuestionIsSaidAfterTheGrace", live + [.speechStarted, onItsLine(asking), .speechEnded],
      .graceElapsed, .live, [.speak(asking), arm], pending: [asking]),
    row(
      "aQuestionOnItsOwnLineEndsNoWait", waiting + [onItsLine(asking)], .silenceElapsed, .live, [],
      pending: [asking]),
    row(
      "anApprovalLeavesTheLineWaiting", waiting + [deliver(approval)], .silenceElapsed, .live, [],
      pending: [approval]),
    row(
      "anUpdateLeavesTheLineWaiting", waiting + [deliver(update)], .silenceElapsed, .live, [],
      pending: [update]),
    row(
      "theResultAfterAnApprovalIsSaid", waiting + [deliver(approval)], fromAlpha, .live,
      [.confirmAnswer, .speak(result), arm], pending: [approval, result]),
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
      "anAnswerNobodyAwaitsStillSounds", live, deliver(result), .live,
      [.confirmAnswer, .addContext(result), arm], pending: [result]),
    row(
      "anAnswerWhileAnAnswerOpensTheLineSounds", [.start, opening(result)], deliver(done),
      .connecting, [.confirmAnswer], pending: [result, done]),
    row(
      "aQuestionSoundsToo", waiting, deliver(alphas(.question, "Which?")), .live,
      [.confirmAnswer, .speak(alphas(.question, "Which?")), arm],
      pending: [alphas(.question, "Which?")]),
    row(
      "aFailureSoundsToo", waiting, deliver(alphas(.failed, "It broke.")), .live,
      [.confirmAnswer, .speak(alphas(.failed, "It broke.")), arm],
      pending: [alphas(.failed, "It broke.")]),
    row(
      "noSoundOverTheOwner", live + [.speechStarted], deliver(result), .live,
      [.addContext(result), cap], pending: [result]),
    row(
      "noSoundOverTheVoice", live + [.assistantSpeaking], deliver(result), .live,
      [.addContext(result), arm], pending: [result]),
    row(
      "noSoundOverTheOwnerWhileConnecting", connecting, deliver(result), .connecting, [],
      pending: [result]),
    row(
      "aWaitingAnswerOnlyChimes", [.start], deliver(result), .listening, [.chime],
      pending: [result]),
    row("noSoundWithTheCallOff", [], deliver(result), .off, []),
    row(
      "noSoundForAnUpdate", waiting, deliver(update), .live, [.speak(update), arm],
      pending: [update]),
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
    #expect(machine.handle(.deliver(answer)) == [.confirmAnswer, .speak(answer), Self.arm])
  }

  /// A question withdrawn while the line it opened still connects leaves nothing to say: the
  /// line closes, and nothing chimes.
  @Test func withdrawingWhatOpenedTheLineClosesIt() {
    var machine = CallMachine()
    for event in [CallEvent.start, Self.opening(Self.asking)] { _ = machine.handle(event) }
    #expect(machine.withdraw { $0 == Self.asking } == [.closeRealtime])
    #expect(machine.phase == .listening)
  }

  /// A line a question opened stays once the owner speaks on it while it connects.
  @Test func withdrawingKeepsAnOpeningLineTheOwnerSpeaksOn() {
    var machine = CallMachine()
    for event in [CallEvent.start, Self.opening(Self.asking), .speechStarted] {
      _ = machine.handle(event)
    }
    #expect(machine.withdraw { $0 == Self.asking } == [])
    #expect(machine.phase == .connecting)
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

  /// A line of a turn that is not a voice request: what the voice is given as context, not delivered to be said.
  static let typed = alphas(.typed, "Rename the folder to out")
  static let claude = alphas(.claude, "Renamed the folder to out.")

  @Test func aSyncedLineGoesIntoALiveLineAtOnce() {
    var machine = CallMachine()
    for event in Self.live { _ = machine.handle(event) }
    #expect(machine.handle(.synced(Self.typed)) == [.addContext(Self.typed)])
    #expect(machine.pending.isEmpty)
  }

  @Test func aConnectingLineTakesSyncedLinesWhenConnected() {
    var machine = CallMachine()
    for event in [CallEvent.start, .speechStarted] { _ = machine.handle(event) }
    #expect(machine.handle(.synced(Self.typed)) == [])
    let effects = machine.handle(.connected)
    #expect(Array(effects.prefix(2)) == [.problem(nil), .flushPreroll])
    #expect(effects.contains(.addContext(Self.typed)))
    #expect(machine.pending.isEmpty)
  }

  @Test func aLineOpenedByAResultTakesThemTooWhenConnected() {
    var machine = CallMachine()
    for event in [CallEvent.start, Self.opening(Self.result)] { _ = machine.handle(event) }
    #expect(machine.handle(.synced(Self.claude)) == [])
    let effects = machine.handle(.connected)
    #expect(
      effects.filter { $0 == .addContext(Self.result) || $0 == .addContext(Self.claude) }
        == [.addContext(Self.result), .addContext(Self.claude)])
  }

  @Test func dropSyncedForgetsThem() {
    var machine = CallMachine()
    for event in Self.connecting + [.synced(Self.typed)] { _ = machine.handle(event) }
    machine.dropSynced()
    #expect(!machine.handle(.connected).contains(.addContext(Self.typed)))
  }

  /// The conversation has them, and seeds the next line.
  @Test func aHangUpDropsThem() {
    var machine = CallMachine()
    for event in Self.connecting + [.synced(Self.typed)] { _ = machine.handle(event) }
    _ = machine.handle(.connectFailed(Self.r))
    _ = machine.handle(.speechStarted)
    #expect(!machine.handle(.connected).contains(.addContext(Self.typed)))
  }

  @Test func aSyncedLineNeverChimesOrOpens() {
    var machine = CallMachine()
    #expect(machine.handle(.synced(Self.typed)) == [])
    _ = machine.handle(.start)
    #expect(machine.handle(.synced(Self.typed)) == [])
    #expect(machine.phase == .listening)
    #expect(machine.pending.isEmpty)
  }

  @Test func aMutedLineStillTakesSyncedLines() {
    var machine = CallMachine()
    for event in Self.live + [.mute] { _ = machine.handle(event) }
    #expect(machine.handle(.synced(Self.claude)) == [.addContext(Self.claude)])
  }

  /// The conversation has them, and seeds the next line; a refusal keeps only what is to be said.
  @Test func aRefusalDropsThem() {
    var machine = CallMachine()
    for event in Self.connecting + [.synced(Self.typed), .refused(Self.limit)] {
      _ = machine.handle(event)
    }
    for event in Self.connecting { _ = machine.handle(event) }
    #expect(!machine.handle(.connected).contains(.addContext(Self.typed)))
  }

  @Test func aPausedCallHoldsNoSyncedLine() {
    var machine = CallMachine()
    for event in Self.live + [.refused(Self.limit)] { _ = machine.handle(event) }
    #expect(machine.handle(.synced(Self.typed)) == [])
    #expect(machine.pending.isEmpty)
  }

  @Test func aLineThePauseKeptAndASyncedLineAreEachGivenOnce() {
    var machine = CallMachine()
    for event in Self.live + [Self.deliver(Self.result), .refused(Self.limit)] {
      _ = machine.handle(event)
    }
    for event in Self.connecting + [.synced(Self.typed)] { _ = machine.handle(event) }
    let added = machine.handle(.connected).filter {
      $0 == .addContext(Self.result) || $0 == .addContext(Self.typed)
    }
    #expect(added == [.addContext(Self.result), .addContext(Self.typed)])
  }

  // MARK: The question routes

  static let betaAsks = VoiceLine(
    kind: .asking, label: "Beta · 2c3d", body: "Which folder?", session: beta)

  /// A machine that went through `events`.
  static func after(_ events: [CallEvent]) -> CallMachine {
    var machine = CallMachine()
    for event in events { _ = machine.handle(event) }
    return machine
  }

  /// Only a question takes a reply: a result routes the next handoff nowhere.
  @Test func aLineThatAsksNothingRoutesNothing() {
    var machine = Self.after(Self.live + [Self.deliver(Self.result)])
    #expect(machine.takeQuestionRoute() == nil)
  }

  @Test func theLastQuestionTakesTheHandoff() {
    var machine = Self.after(Self.live + [Self.deliver(Self.asking), Self.deliver(Self.betaAsks)])
    #expect(machine.takeQuestionRoute() == Self.beta)
  }

  @Test func aQuestionAskedAgainIsTheLastAgain() {
    var machine = Self.after(
      Self.live + [
        Self.deliver(Self.asking), Self.deliver(Self.betaAsks), Self.deliver(Self.asking),
      ])
    #expect(machine.takeQuestionRoute() == Self.alpha)
  }

  /// Nothing tells a reply from a new request: one handoff follows a question, the next does not.
  @Test func aRouteTakesTheRoutesUnderItAlong() {
    var machine = Self.after(Self.live + [Self.deliver(Self.asking), Self.deliver(Self.betaAsks)])
    _ = machine.takeQuestionRoute()
    #expect(machine.takeQuestionRoute() == nil)
  }

  @Test func aRouteMovesWithItsSession() {
    var machine = Self.after(Self.live + [Self.deliver(Self.asking)])
    let new = SessionID(rawValue: "22222222-0000-0000-0000-000000000003")
    machine.rename(Self.alpha, to: new)
    #expect(machine.takeQuestionRoute() == new)
  }

  /// The voice said the question, so the line that replaces this one will not, and an unrelated
  /// handoff must not follow it.
  @Test func aPauseEndsTheRouteOfAQuestionAlreadySaid() {
    var machine = Self.after(
      Self.live + [
        Self.deliver(Self.asking), .assistantSpeaking, Self.said("Alpha asks which branch."),
        .refused(Self.limit),
      ])
    #expect(machine.takeQuestionRoute() == nil)
  }

  /// A result of the session still waits, but a result takes no reply.
  @Test func aPauseEndsTheRouteThoughAResultOfTheSessionWaits() {
    var machine = Self.after(
      Self.live + [
        Self.deliver(Self.asking), Self.deliver(Self.result), .assistantSpeaking,
        Self.said("Alpha asks which branch."), .refused(Self.limit),
      ])
    #expect(machine.takeQuestionRoute() == nil)
  }
}
