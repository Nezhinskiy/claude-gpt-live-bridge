import Foundation

/// A line for the voice, `[TAG] label: body`, and the session it came from (`nil`: the
/// bridge's own). `AnswerShaper.line` makes them, the label and the body already shaped.
public struct VoiceLine: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case result = "RESULT"
    case update = "UPDATE"
    case failed = "FAILED"
    case question = "QUESTION"
    case approval = "APPROVAL"
    /// Claude asked the owner a question mid-turn and waits for the reply.
    case asking = "ASKING"
    case context = "CONTEXT"
    case task = "TASK"
    /// A line the owner typed into the session's own terminal.
    case typed = "TYPED"
    /// What Claude said in a turn that is not a voice request.
    case claude = "CLAUDE"

    /// It ends a request, so the line stops waiting for that session: a result, a failure or a
    /// question. An update, an approval notice, a question Claude waits on or context leaves the
    /// request open.
    public var answers: Bool { [.result, .failed, .question].contains(self) }
  }

  /// A question the owner's next handoff answers.
  var asks: Bool { [.question, .asking].contains(kind) }

  public var kind: Kind
  public var label: String
  public var body: String
  public var session: SessionID?

  public var text: String { "[\(kind.rawValue)] \(label): \(body)" }
}

/// What happens to the call: owner actions, local voice detection, the realtime session, timers.
public enum CallEvent: Equatable, Sendable {
  case start, stop, speechStarted, speechEnded, connected
  case connectFailed(Problem)
  /// The voice finished a reply; the text is its transcript.
  case assistantFinishedSpeaking(String)
  case silenceElapsed
  /// The owner releases the microphone while the call goes on, or takes it again.
  case mute, unmute
  /// The service refused the voice while a line or the call was on (`Problem.pausesCall`).
  case refused(Problem)
  /// The voice handed a request to this session; nil when none is joined, and the failure
  /// follows as a delivery.
  case handedOff(SessionID?)
  /// `resultWindowSeconds` passed since the latest handoff.
  case resultWindowElapsed
  /// `graceMilliseconds` passed since everyone fell silent.
  case graceElapsed
  /// The voice is saying something (a transcript delta); the owner's words were recognised.
  case assistantSpeaking, userTranscribed
  /// `opensLine`: the bridge found that the line opens a closed line (the target's answer,
  /// question or approval notice, while the target's conversation holds a turn of the owner's).
  /// `onOwnLine`: the open line is about the line's session, so its question or approval notice is
  /// given to say, whoever started the turn.
  case deliver(VoiceLine, opensLine: Bool = false, onOwnLine: Bool = false)
  case remoteClosed(Problem)
  case audioFailed(Problem)
  /// The open line carries a conversation that is not the target's any more: another session
  /// became the target, or the target's conversation was erased.
  case conversationChanged
  /// The owner changed how the line connects (Settings' Connect over TCP) and chose Reconnect.
  case reconnect
  /// The owner changed one of the line's timers in Settings.
  case timeoutsChanged
  /// A line of a turn that is not a voice request (`.typed` or `.claude`): the voice is given it
  /// as context, not delivered to be said. It chimes and opens nothing.
  case synced(VoiceLine)
}

/// What the bridge does in reply, in order.
public enum CallEffect: Equatable, Sendable {
  case openRealtime, closeRealtime, startLocalVAD, stopLocalVAD, flushPreroll
  /// The call ended by itself: nothing keeps codex running.
  case endCodex
  /// The audio page releases the microphone, or takes it again.
  case muteMicrophone, unmuteMicrophone
  /// Opens the line for a line that arrived: without the pre-roll, as nobody spoke, and without
  /// holding up the delivery while it connects.
  case openRealtimeForResult
  /// Closes the open line and, if the call still wants it once that is done, opens it again: a
  /// new transport for the same line. `preroll` while the owner is speaking.
  case reopenRealtime(preroll: Bool)
  case addContext(VoiceLine)
  /// Replaces any armed timer; when it elapses the bridge sends `silenceElapsed`.
  case armSilenceTimer(seconds: Int)
  /// Cancels the armed silence timer: the timeout that would replace it is off.
  case cancelSilenceTimer
  /// Replaces any armed window; when it elapses the bridge sends `resultWindowElapsed`.
  case armResultWindow(seconds: Int)
  /// Replaces any armed grace; when it elapses the bridge sends `graceElapsed`.
  case armGrace(milliseconds: Int)
  /// Asks the open line to say a result now.
  case speak(VoiceLine)
  case chime
  /// A handoff was queued for a session; without this sound the owner cannot tell it from a
  /// voice that only said it would look (BR-001).
  case confirmHandoff
  /// A session's answer reached the call, and nobody is speaking over it: the owner hears that
  /// Claude has finished before the voice says it. No notification comes with it.
  case confirmAnswer
  case problem(Problem?)
}

/// The billing-aware call. The realtime session is open only while someone speaks or a handed-off
/// request may still be answered: speech, or a line the bridge says opens it, opens it; silence
/// or a new target closes it; the microphone stays with local voice detection in between. After a
/// handoff the line waits up to `resultWindowSeconds` from the latest one for that session's
/// result, and says it as soon as nobody is speaking. Any other line that arrives while the line
/// is closed, and one an opened line left unsaid, is announced by a chime and waits until the
/// owner next speaks. An answer that does not wait has the same sound, without the notification.
/// Pure: the bridge runs the effects.
public struct CallMachine: Sendable {
  public static let noise = Problem.other(
    "The voice hung up: the microphone heard sound but no words for as long as Settings allows.")
  public private(set) var phase: CallPhase = .off
  /// The owner released the microphone: no speech opens the line, but a line that arrived does.
  public private(set) var isMuted = false
  /// The service refused the voice (`pause`): the call is off, and what the voice has not said
  /// still waits, also lines that arrive now, until Start or Stop. Otherwise `off` keeps nothing.
  private var isPaused = false

  private struct Unheard: Sendable {
    let line: VoiceLine
    /// An awaited result that arrived while someone spoke; said once everyone is silent.
    var isHeld = false
  }

  /// The results the voice has not said yet, oldest first: waiting for the owner to speak, or
  /// given to the open session. A hang-up keeps them, so none is lost; one may be spoken twice.
  private var unheard: [Unheard] = []
  public var pending: [VoiceLine] { unheard.map(\.line) }
  /// A line that arrives now waits to be said; a stopped call drops it.
  public var keepsLines: Bool { phase != .off || isPaused }
  /// The sessions whose question the call kept, oldest first, each once. The next handoff goes to
  /// the last of them, so a question that closes gives the route back to the one before it. They
  /// end with the call. A question dropped while off routes nothing, and a pause keeps a route
  /// only while its question still waits to be said.
  private var questionRoutes: [SessionID] = []
  /// The results given before the voice's current reply began; only that reply can say them.
  private var replyCanSay: [VoiceLine]?
  /// The sessions handed a request whose result the open line waits for; while any is, silence
  /// does not close it, until `resultWindowSeconds` after the latest handoff.
  public private(set) var awaited: Set<SessionID> = []
  /// Synced lines that arrived while the line connects, given once it is live.
  private var connectingSynced: [VoiceLine] = []
  /// The silence timer elapsed while the line waited for a result.
  private var isSilenceDue = false
  /// The voice is saying a reply: a transcript delta came and its reply has not finished.
  private var isVoiceSpeaking = false
  /// The next finished reply is the handoff's acknowledgement, which says no result.
  private var isAckUnfinished = false
  /// A line that arrived opened this line, and neither the owner nor the voice has spoken on it
  /// yet: its silence is `timeouts.firstWord`.
  private var isAwaitingFirstWord = false
  /// Local voice detection hears sound; the timer then allows `timeouts.noise`.
  private var isSoundOn = false
  /// A silence timer is counting: armed, and neither elapsed nor cancelled since.
  private var isSilenceArmed = false
  /// The line's timers, which Settings holds.
  public var timeouts = Timeouts()
  /// How long after the latest handoff the line stays open for its result. Billed.
  public static let resultWindowSeconds = 120
  /// How long everyone must have been silent before a held result is said.
  public static let graceMilliseconds = 800

  public init() {}

  /// How long quiet lasts before the line closes, in seconds; 0 switches that timer off.
  public struct Timeouts: Equatable, Sendable {
    /// Silence since the last speech, recognised words or reply.
    public var silence: Int
    /// A line a result opened, until the owner or the voice speaks on it: then the line closes
    /// and the result chimes (ADR 0001 (n)). 0 waits `silence` instead, so a line that opened while
    /// the owner was away stays open for good only with the silence off too.
    public var firstWord: Int
    /// Sound the voice detection hears that gives no recognised words.
    public var noise: Int
    /// What Settings offers.
    public static let range = 0...300

    /// `seconds` as Settings keeps it: the nearer end of `range` when outside it.
    public static func clamped(_ seconds: Int) -> Int {
      min(max(seconds, range.lowerBound), range.upperBound)
    }

    public init(silence: Int = 20, firstWord: Int = 5, noise: Int = 90) {
      self.silence = silence
      self.firstWord = firstWord
      self.noise = noise
    }
  }

  /// Silence is counted from the last speech, recognised words or reply; while sound goes on
  /// without words, the line closes after the noise timeout instead.
  private mutating func armSilence() -> CallEffect {
    isSilenceDue = false
    let firstWord = timeouts.firstWord > 0 ? timeouts.firstWord : timeouts.silence
    let quiet = isAwaitingFirstWord ? firstWord : timeouts.silence
    let seconds = isSoundOn ? timeouts.noise : quiet
    isSilenceArmed = seconds > 0
    return isSilenceArmed ? .armSilenceTimer(seconds: seconds) : .cancelSilenceTimer
  }

  /// The grace before a held result is said, once neither the owner nor the voice is speaking.
  private var graceIfQuiet: [CallEffect] {
    !unheard.contains(where: \.isHeld) || isSomeoneSpeaking
      ? [] : [.armGrace(milliseconds: Self.graceMilliseconds)]
  }

  public mutating func handle(_ event: CallEvent) -> [CallEffect] {
    if case .deliver(let line, _, _) = event, line.asks, keepsLines, let session = line.session {
      questionRoutes.removeAll { $0 == session }
      questionRoutes.append(session)
    }
    switch (phase, event) {
    case (_, .stop):
      return end(with: [.closeRealtime, .stopLocalVAD])
    case (_, .audioFailed(let reason)):
      return end(with: [.closeRealtime, .stopLocalVAD, .problem(reason)])
    case (.off, .start):
      phase = .listening
      isPaused = false
      // the problem first: listening waits on macOS's prompt, whose refusal is a new problem
      return [.problem(nil), .startLocalVAD]
    case (.off, .deliver(let line, _, _)) where isPaused:
      unheard.append(Unheard(line: line))
      return [.chime]
    case (.off, _):
      return []
    case (_, .refused(let reason)):
      return pause(for: reason, closing: [.closeRealtime])
    case (_, .speechStarted) where isMuted:
      return []
    case (_, .mute):
      guard !isMuted else { return [] }
      isMuted = true
      // speech ends at Mute; a quiet line keeps the silence it was counting
      return [.muteMicrophone] + (isSoundOn ? handle(.speechEnded) : [])
    case (_, .unmute):
      guard isMuted else { return [] }
      isMuted = false
      return [.unmuteMicrophone]
    case (_, .speechEnded):
      isSoundOn = false
      return phase == .live ? [armSilence()] + graceIfQuiet : []
    case (.listening, .speechStarted):
      isSoundOn = true
      phase = .connecting
      return [.openRealtime]
    case (.listening, .deliver(let result, let opensLine, _)):
      unheard.append(Unheard(line: result))
      guard opensLine else { return [.chime] }
      phase = .connecting
      isAwaitingFirstWord = true
      // the open first: the sound lets others in, and the attempt must exist by then
      return [.openRealtimeForResult] + arrival(of: result)
    case (.connecting, .deliver(let result, _, _)):
      unheard.append(Unheard(line: result))
      return arrival(of: result)
    case (.connecting, .synced(let line)):
      connectingSynced.append(line)
      return []
    case (.live, .synced(let line)):
      return [.addContext(line)]
    case (.listening, .handedOff(.some)), (.connecting, .handedOff(.some)):
      return [.confirmHandoff]  // queued all the same; no line waits for it
    case (.connecting, .connected):
      phase = .live
      let synced = connectingSynced
      connectingSynced = []
      // the problem first: a refusal while these run must not be erased by them
      return [.problem(nil), .flushPreroll] + pending.map { .addContext($0) }
        + synced.map { .addContext($0) } + [armSilence()]
    case (.connecting, .connectFailed(let reason)), (.connecting, .remoteClosed(let reason)),
      (.live, .remoteClosed(let reason)):
      return reason.pausesCall ? pause(for: reason) : [.problem(reason)] + hangUp()
    case (.live, .deliver(let result, _, let onOwnLine)):
      // a result the voice never speaks still hangs up
      let isAwaited = result.session.map(awaited.contains) ?? false
      let sound = arrival(of: result)
      guard isAwaited || (onOwnLine && [.asking, .approval].contains(result.kind)) else {
        unheard.append(Unheard(line: result))
        return sound + [.addContext(result), armSilence()]
      }
      if result.kind.answers, let session = result.session { awaited.remove(session) }
      let isHeld = isSomeoneSpeaking
      unheard.append(Unheard(line: result, isHeld: isHeld))
      return sound + (isHeld ? [armSilence()] : [.speak(result), armSilence()])
    case (.connecting, .speechStarted):
      isSoundOn = true
      isAwaitingFirstWord = false
      return []
    case (.live, .speechStarted):
      isSoundOn = true
      isAwaitingFirstWord = false
      return [armSilence()]
    case (.live, .assistantSpeaking):
      replyCanSay = replyCanSay ?? pending
      isVoiceSpeaking = true
      isAwaitingFirstWord = false
      return [armSilence()]
    case (.live, .userTranscribed):
      isAwaitingFirstWord = false
      return [armSilence()]
    case (.live, .handedOff(let session)):
      isAckUnfinished = true
      guard let session else { return [] }
      awaited.insert(session)
      return [.confirmHandoff, .armResultWindow(seconds: Self.resultWindowSeconds)]
    case (.live, .assistantFinishedSpeaking(let text)):
      let canSay = replyCanSay ?? []
      replyCanSay = nil
      isVoiceSpeaking = false
      if !isAckUnfinished {
        unheard.removeAll { canSay.contains($0.line) && Self.says(text, $0.line) }
      }
      isAckUnfinished = false
      return [armSilence()] + graceIfQuiet
    case (.live, .graceElapsed):
      let held = unheard.filter(\.isHeld).map(\.line)
      guard !held.isEmpty, !isSoundOn, !isVoiceSpeaking else { return [] }
      unheard = withoutHolds
      return held.map { .speak($0) } + [armSilence()]
    case (.live, .resultWindowElapsed), (.connecting, .resultWindowElapsed):
      // connecting here only when a reconnect reopens the line; its silence is armed again
      guard !awaited.isEmpty else { return [] }
      awaited = []
      return isSilenceDue && phase == .live ? [.closeRealtime] + hangUp() : []
    case (.connecting, .conversationChanged), (.live, .conversationChanged):
      return [.closeRealtime] + hangUp()
    case (.connecting, .reconnect), (.live, .reconnect):
      // Only the transport changes: what is awaited, unheard and timed stays. The old line's
      // reply is cut off, and no end of it will come.
      phase = .connecting
      isVoiceSpeaking = false
      isAckUnfinished = false
      replyCanSay = nil
      return [.reopenRealtime(preroll: isSoundOn)]
    case (.live, .timeoutsChanged):
      // a timer turned on starts now; one already counting is not moved
      guard !isSilenceArmed, !isSilenceDue else { return [] }
      let arm = armSilence()
      return isSilenceArmed ? [arm] : []
    case (.live, .silenceElapsed):
      isSilenceArmed = false
      if !awaited.isEmpty, !isSoundOn {
        isSilenceDue = true
        return []
      }
      return [.closeRealtime] + (isSoundOn ? [.problem(Self.noise)] : []) + hangUp()
    default:
      return []
    }
  }

  /// Drops unheard results, such as one a newer request to the same session superseded, also
  /// one held to be said. A line still connecting for what was dropped closes: nothing is left
  /// to say on it, and nobody spoke.
  @discardableResult
  public mutating func withdraw(where isSuperseded: (VoiceLine) -> Bool) -> [CallEffect] {
    unheard.removeAll { isSuperseded($0.line) }
    guard phase == .connecting, isAwaitingFirstWord, unheard.isEmpty else { return [] }
    return [.closeRealtime] + hangUp()
  }

  /// The session the next handoff goes to, if a question routes it. A route is used once, and it
  /// takes the routes under it along: nothing tells a reply from a new request, so one handoff
  /// follows a question and the next is the target's.
  public mutating func takeQuestionRoute() -> SessionID? {
    defer { questionRoutes = [] }
    return questionRoutes.last
  }

  /// `id`'s question is settled or can get no reply: the next handoff is not about it.
  public mutating func endQuestionRoute(of id: SessionID) {
    questionRoutes.removeAll { $0 == id }
  }

  /// Ends every route, but one whose question still waits to be said: a waiting line is given to
  /// the next line, whichever session it is about, and the reply must reach the session that
  /// asked.
  public mutating func endSaidQuestionRoutes() {
    questionRoutes.removeAll { id in
      !unheard.contains { $0.line.session == id && $0.line.asks }
    }
  }

  /// Forgets the synced lines a connecting line waits to give: the conversation they are in has
  /// just seeded the line with them.
  public mutating func dropSynced() { connectingSynced = [] }

  /// A session got a new id (`/clear`): the line waits for it, and its results stay its own,
  /// under the new id.
  public mutating func rename(_ old: SessionID, to new: SessionID) {
    if awaited.remove(old) != nil { awaited.insert(new) }
    questionRoutes = questionRoutes.map { $0 == old ? new : $0 }
    let moved = { (line: VoiceLine) in
      var line = line
      if line.session == old { line.session = new }
      return line
    }
    unheard = unheard.map { Unheard(line: moved($0.line), isHeld: $0.isHeld) }
    replyCanSay = replyCanSay?.map(moved)
  }

  /// Back to local listening; `pending` is kept, and a chime says it waits.
  private mutating func hangUp() -> [CallEffect] {
    defer {
      phase = .listening
      isAwaitingFirstWord = false
      awaited = []
      unheard = withoutHolds
      isSilenceDue = false
      isSilenceArmed = false
      isVoiceSpeaking = false
      isAckUnfinished = false
      replyCanSay = nil
      connectingSynced = []
    }
    return pending.isEmpty ? [] : [.chime]
  }

  /// The sound for a line that reached a line opening or open: a session's answer, unless someone
  /// is speaking over it.
  private func arrival(of line: VoiceLine) -> [CallEffect] {
    line.session != nil && line.kind.answers && !isSomeoneSpeaking ? [.confirmAnswer] : []
  }

  private var isSomeoneSpeaking: Bool { isSoundOn || isVoiceSpeaking }

  /// A new line would fail the same way, so the call ends, as Stop does, and keeps what waits to
  /// be said. Start tries once more.
  private mutating func pause(for reason: Problem, closing: [CallEffect] = []) -> [CallEffect] {
    let kept = withoutHolds
    let routes = questionRoutes
    let effects = end(
      with: [.problem(reason)] + closing + [.stopLocalVAD, .endCodex]
        + (kept.isEmpty ? [] : [.chime]))
    unheard = kept
    questionRoutes = routes
    endSaidQuestionRoutes()
    isPaused = true
    return effects
  }

  private var withoutHolds: [Unheard] { unheard.map { Unheard(line: $0.line) } }

  private mutating func end(with effects: [CallEffect]) -> [CallEffect] {
    self = CallMachine()
    return effects
  }

  /// Whether a reply's transcript says a result: two of the body's distinctive words (four
  /// letters or more, not in `commonWords`), or the label without its ` · id` suffix together
  /// with one of them. The label alone counts only for a body with no distinctive word, which
  /// could not be heard otherwise: "Alpha is still working" names a session without saying its
  /// result. Case and diacritics are ignored.
  static func says(_ transcript: String, _ result: VoiceLine) -> Bool {
    let said = words(transcript)
    let label = words(result.label.split(separator: " · ").first.map(String.init) ?? "")
    let named =
      !label.isEmpty && said.indices.contains(where: { said[$0...].starts(with: label) })
    let body = words(result.body)
    let distinct = Set(body.filter { $0.count >= 4 }).subtracting(commonWords)
    let heard = distinct.intersection(said).count
    return named ? distinct.isEmpty || heard >= 1 : heard >= 2
  }

  /// Words any reply may say, which therefore say nothing about a result. English and Russian
  /// only: in another language more replies count as saying a result.
  static let commonWords: Set<String> = [
    "about", "also", "been", "claude", "could", "done", "from", "have", "here", "into", "just",
    "like", "more", "okay", "only", "session", "should", "some", "than", "that", "their", "them",
    "then", "there", "they", "this", "very", "were", "what", "when", "which", "will", "with",
    "would", "your", "если", "есть", "когда", "можно", "сейчас", "тоже", "только", "чтобы",
  ]

  private static func words(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .split(whereSeparator: { !$0.isLetter }).map(String.init)
  }
}
