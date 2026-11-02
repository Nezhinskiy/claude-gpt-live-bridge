import Foundation

/// A line for the voice and the session it came from (`nil`: the bridge's own).
public struct VoiceLine: Equatable, Sendable {
  public var text: String
  public var session: SessionID?
}

/// What happens to the call: owner actions, local voice detection, the realtime session, timers.
public enum CallEvent: Equatable, Sendable {
  case start, stop, speechStarted, speechEnded, connected
  case connectFailed(String)
  /// The voice finished a reply; the text is its transcript.
  case assistantFinishedSpeaking(String)
  case silenceElapsed
  /// The voice handed a request to this session; nil when none is joined, and the failure
  /// follows as a delivery.
  case handedOff(SessionID?)
  /// `resultWindowSeconds` passed since the latest handoff.
  case resultWindowElapsed
  /// `graceMilliseconds` passed since everyone fell silent.
  case graceElapsed
  /// The voice is saying something (a transcript delta); the owner's words were recognised.
  case assistantSpeaking, userTranscribed
  case deliver(VoiceLine)
  case remoteClosed(String)
  case audioFailed(String)
  /// Another session became the target; an open line carries the previous one's conversation.
  case targetChanged
}

/// What the bridge does in reply, in order.
public enum CallEffect: Equatable, Sendable {
  case openRealtime, closeRealtime, startLocalVAD, stopLocalVAD, flushPreroll
  case addContext(String)
  /// Replaces any armed timer; when it elapses the bridge sends `silenceElapsed`.
  case armSilenceTimer(seconds: Int)
  /// Replaces any armed window; when it elapses the bridge sends `resultWindowElapsed`.
  case armResultWindow(seconds: Int)
  /// Replaces any armed grace; when it elapses the bridge sends `graceElapsed`.
  case armGrace(milliseconds: Int)
  /// Asks the open line to say a result now.
  case speak(String)
  case chime
  case problem(String?)
}

/// The billing-aware call. The realtime session is open only while someone speaks or a handed-off
/// request may still be answered: speech opens it, silence or a new target closes it, and the
/// microphone stays with local voice detection in between. After a handoff the line waits up to
/// `resultWindowSeconds` from the latest one for that session's result, and says it as soon as
/// nobody is speaking. A result that arrives while the line is closed is announced by a chime and
/// waits in `pending` until the owner next speaks. Pure: the bridge runs the effects.
public struct CallMachine: Sendable {
  public static let noiseSentence =
    "The voice hung up: the microphone heard sound but no words for 90 seconds."
  public private(set) var phase: CallPhase = .off
  /// Results the voice has not said yet: waiting for the owner to speak, or given to the open
  /// session. A hang-up keeps them, so none is lost; one may be spoken twice.
  public private(set) var pending: [VoiceLine] = []
  /// The results given before the voice's current reply began; only that reply can say them.
  private var replyCanSay: [VoiceLine]?
  /// The sessions handed a request whose result the open line waits for; while any is, silence
  /// does not close it, until `resultWindowSeconds` after the latest handoff.
  public private(set) var awaited: Set<SessionID> = []
  /// Awaited results that arrived while someone spoke; said once everyone is silent.
  private var toSpeak: [VoiceLine] = []
  /// The silence timer elapsed while the line waited for a result.
  private var isSilenceDue = false
  /// The voice is saying a reply: a transcript delta came and its reply has not finished.
  private var isVoiceSpeaking = false
  /// The next finished reply is the handoff's acknowledgement, which says no result.
  private var isAckUnfinished = false
  /// Local voice detection hears sound; the timer then allows `noiseCapSeconds`.
  private var isSoundOn = false
  public static let silenceSeconds = 20
  public static let noiseCapSeconds = 90
  /// How long after the latest handoff the line stays open for its result. Billed.
  public static let resultWindowSeconds = 120
  /// How long everyone must have been silent before a held result is said.
  public static let graceMilliseconds = 800

  public init() {}

  /// Silence is counted from the last speech, recognised words or reply; while sound goes on
  /// without words, the line still closes after `noiseCapSeconds`.
  private mutating func armSilence() -> CallEffect {
    isSilenceDue = false
    return .armSilenceTimer(seconds: isSoundOn ? Self.noiseCapSeconds : Self.silenceSeconds)
  }

  /// The grace before a held result is said, once neither the owner nor the voice is speaking.
  private var graceIfQuiet: [CallEffect] {
    toSpeak.isEmpty || isSoundOn || isVoiceSpeaking
      ? [] : [.armGrace(milliseconds: Self.graceMilliseconds)]
  }

  public mutating func handle(_ event: CallEvent) -> [CallEffect] {
    switch (phase, event) {
    case (_, .stop):
      return end(with: [.closeRealtime, .stopLocalVAD])
    case (_, .audioFailed(let reason)):
      return end(with: [.closeRealtime, .stopLocalVAD, .problem(reason)])
    case (.off, .start):
      phase = .listening
      return [.startLocalVAD, .problem(nil)]
    case (.off, _):
      return []
    case (_, .speechEnded):
      isSoundOn = false
      return phase == .live ? [armSilence()] + graceIfQuiet : []
    case (.listening, .speechStarted):
      isSoundOn = true
      phase = .connecting
      return [.openRealtime]
    case (.listening, .deliver(let result)):
      pending.append(result)
      return [.chime]
    case (.connecting, .deliver(let result)):
      pending.append(result)
      return []
    case (.connecting, .connected):
      phase = .live
      return [.flushPreroll] + pending.map { .addContext($0.text) } + [armSilence(), .problem(nil)]
    case (.connecting, .connectFailed(let reason)), (.connecting, .remoteClosed(let reason)),
      (.live, .remoteClosed(let reason)):
      return [.problem(reason)] + hangUp()
    case (.live, .deliver(let result)):  // a result the voice never speaks still hangs up
      pending.append(result)
      guard let session = result.session, awaited.remove(session) != nil else {
        return [.addContext(result.text), armSilence()]
      }
      if isSoundOn || isVoiceSpeaking {
        toSpeak.append(result)
        return [armSilence()]
      }
      return [.speak(result.text), armSilence()]
    case (.live, .speechStarted):
      isSoundOn = true
      return [armSilence()]
    case (.live, .assistantSpeaking):
      replyCanSay = replyCanSay ?? pending
      isVoiceSpeaking = true
      return [armSilence()]
    case (.live, .userTranscribed):
      return [armSilence()]
    case (.live, .handedOff(let session)):
      isAckUnfinished = true
      guard let session else { return [] }
      awaited.insert(session)
      return [.armResultWindow(seconds: Self.resultWindowSeconds)]
    case (.live, .assistantFinishedSpeaking(let text)):
      let canSay = replyCanSay ?? []
      replyCanSay = nil
      isVoiceSpeaking = false
      if !isAckUnfinished {
        pending.removeAll { canSay.contains($0) && Self.says(text, $0.text) }
      }
      isAckUnfinished = false
      return [armSilence()] + graceIfQuiet
    case (.live, .graceElapsed):
      guard !toSpeak.isEmpty, !isSoundOn, !isVoiceSpeaking else { return [] }
      defer { toSpeak = [] }
      return toSpeak.map { .speak($0.text) } + [armSilence()]
    case (.live, .resultWindowElapsed):
      guard !awaited.isEmpty else { return [] }
      awaited = []
      return isSilenceDue ? [.closeRealtime] + hangUp() : []
    case (.connecting, .targetChanged), (.live, .targetChanged):
      return [.closeRealtime] + hangUp()
    case (.live, .silenceElapsed):
      if !awaited.isEmpty, !isSoundOn {
        isSilenceDue = true
        return []
      }
      return [.closeRealtime] + (isSoundOn ? [.problem(Self.noiseSentence)] : []) + hangUp()
    default:
      return []
    }
  }

  /// Drops waiting results, such as one a newer request to the same session superseded.
  public mutating func withdraw(where isSuperseded: (VoiceLine) -> Bool) {
    pending.removeAll(where: isSuperseded)
  }

  /// Back to local listening; `pending` is kept, and a chime says so when the line was open.
  private mutating func hangUp() -> [CallEffect] {
    defer {
      phase = .listening
      awaited = []
      toSpeak = []
      isSilenceDue = false
      isVoiceSpeaking = false
      isAckUnfinished = false
      replyCanSay = nil
    }
    return phase == .live && !pending.isEmpty ? [.chime] : []
  }

  private mutating func end(with effects: [CallEffect]) -> [CallEffect] {
    self = CallMachine()
    return effects
  }

  /// Whether a reply's transcript says a `[TAG] label: body` result: two of the body's
  /// distinctive words (four letters or more, not in `commonWords`), or the label without its
  /// ` · id` suffix together with one of them. The label alone counts only for a body with no
  /// distinctive word, which could not be heard otherwise: "Alpha is still working" names a
  /// session without saying its result. Case and diacritics are ignored, and the tag is not a
  /// word of the result.
  static func says(_ transcript: String, _ result: String) -> Bool {
    let said = words(transcript)
    let line = result.trimmingPrefix(#/\[[^\]]*\] /#)
    let colon = line.firstRange(of: ": ")
    let head = line[..<(colon?.lowerBound ?? line.startIndex)]
    let label = words(head.split(separator: " · ").first.map(String.init) ?? "")
    let named =
      !label.isEmpty && said.indices.contains(where: { said[$0...].starts(with: label) })
    let body = words(String(line[(colon?.upperBound ?? line.startIndex)...]))
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
