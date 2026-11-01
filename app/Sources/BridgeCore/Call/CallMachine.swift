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
  case silenceElapsed, handedOff
  /// The voice is saying something (a transcript delta); the owner's words were recognised.
  case assistantSpeaking, userTranscribed
  case deliver(VoiceLine)
  case remoteClosed(String)
  case audioFailed(String)
}

/// What the bridge does in reply, in order.
public enum CallEffect: Equatable, Sendable {
  case openRealtime, closeRealtime, startLocalVAD, stopLocalVAD, flushPreroll
  case addContext(String)
  /// Replaces any armed timer; when it elapses the bridge sends `silenceElapsed`.
  case armSilenceTimer(seconds: Int)
  case chime
  case problem(String?)
}

/// The billing-aware call. The realtime session is open only while someone speaks: speech opens
/// it, silence or a finished handoff acknowledgement closes it, and the microphone stays with
/// local voice detection in between. A result that arrives while it is closed is announced by a
/// chime and waits in `pending` until the owner next speaks. Pure: the bridge runs the effects.
public struct CallMachine: Sendable {
  public static let noiseSentence =
    "The voice hung up: the microphone heard sound but no words for 90 seconds."
  public private(set) var phase: CallPhase = .off
  /// Results the voice has not said yet: waiting for the owner to speak, or given to the open
  /// session. A hang-up keeps them, so none is lost; one may be spoken twice.
  public private(set) var pending: [VoiceLine] = []
  /// The results given before the voice's current reply began; only that reply can say them.
  private var replyCanSay: [VoiceLine]?
  /// The line closes once the voice's acknowledgement of a handoff ends, unless a result or the
  /// owner's speech came after the handoff. The silence timer stays armed meanwhile.
  public private(set) var awaitingAck = false
  /// The next finished reply is the handoff's acknowledgement, which says no result.
  private var isAckUnfinished = false
  /// Local voice detection hears sound; the timer then allows `noiseCapSeconds`.
  private var isSoundOn = false
  public let silenceSeconds: Int
  public let noiseCapSeconds: Int

  public init(silenceSeconds: Int = 20, noiseCapSeconds: Int = 90) {
    self.silenceSeconds = silenceSeconds
    self.noiseCapSeconds = noiseCapSeconds
  }

  /// Silence is counted from the last speech, recognised words or reply; while sound goes on
  /// without words, the line still closes after `noiseCapSeconds`.
  private var armSilence: CallEffect {
    .armSilenceTimer(seconds: isSoundOn ? noiseCapSeconds : silenceSeconds)
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
      return phase == .live ? [armSilence] : []
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
      return [.flushPreroll] + pending.map { .addContext($0.text) } + [armSilence, .problem(nil)]
    case (.connecting, .connectFailed(let reason)), (.connecting, .remoteClosed(let reason)),
      (.live, .remoteClosed(let reason)):
      return [.problem(reason)] + hangUp()
    case (.live, .deliver(let result)):  // a result the voice never speaks still hangs up
      pending.append(result)
      awaitingAck = false
      return [.addContext(result.text), armSilence]
    case (.live, .speechStarted):
      isSoundOn = true
      awaitingAck = false
      return [armSilence]
    case (.live, .assistantSpeaking):
      replyCanSay = replyCanSay ?? pending
      return [armSilence]
    case (.live, .userTranscribed):
      return [armSilence]
    case (.live, .handedOff):
      awaitingAck = true
      isAckUnfinished = true
      return []
    case (.live, .assistantFinishedSpeaking(let text)):
      let canSay = replyCanSay ?? []
      replyCanSay = nil
      if !isAckUnfinished {
        pending.removeAll { canSay.contains($0) && Self.says(text, $0.text) }
      } else if awaitingAck {
        return [.closeRealtime] + hangUp()
      }
      isAckUnfinished = false
      return [armSilence]
    case (.live, .silenceElapsed):
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
      awaitingAck = false
      isAckUnfinished = false
      replyCanSay = nil
    }
    return phase == .live && !pending.isEmpty ? [.chime] : []
  }

  private mutating func end(with effects: [CallEffect]) -> [CallEffect] {
    self = CallMachine(silenceSeconds: silenceSeconds, noiseCapSeconds: noiseCapSeconds)
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
