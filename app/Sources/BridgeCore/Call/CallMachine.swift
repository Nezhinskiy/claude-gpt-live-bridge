/// What happens to the call: owner actions, local voice detection, the realtime session, timers.
public enum CallEvent: Equatable, Sendable {
  case start, stop, speechStarted, speechEnded, connected
  case connectFailed(String)
  case assistantFinishedSpeaking, silenceElapsed, handedOff
  case deliver(String)
  case remoteClosed(String)
  case audioFailed(String)
}

/// What the bridge does in reply, in order.
public enum CallEffect: Equatable, Sendable {
  case openRealtime, closeRealtime, startLocalVAD, stopLocalVAD, flushPreroll
  case addContext(String)
  case armSilenceTimer(seconds: Int)
  case cancelSilenceTimer, chime
  case problem(String?)
}

/// The billing-aware call. The realtime session is open only while someone speaks: speech opens
/// it, silence or a finished handoff acknowledgement closes it, and the microphone stays with
/// local voice detection in between. A result that arrives while it is closed is announced by a
/// chime and waits in `pending` until the owner next speaks. Pure: the bridge runs the effects.
public struct CallMachine: Sendable {
  public private(set) var phase: CallPhase = .off
  /// Results the voice has not heard yet; each is added as context once a session connects.
  public private(set) var pending: [String] = []
  /// The voice is saying its short acknowledgement of a handoff; the session closes after it.
  public private(set) var awaitingAck = false
  public let silenceSeconds: Int

  public init(silenceSeconds: Int = 20) { self.silenceSeconds = silenceSeconds }

  public mutating func handle(_ event: CallEvent) -> [CallEffect] {
    let armSilence = CallEffect.armSilenceTimer(seconds: silenceSeconds)
    switch (phase, event) {
    case (_, .stop):
      return end(with: [.closeRealtime, .stopLocalVAD])
    case (_, .audioFailed(let reason)):
      return end(with: [.closeRealtime, .stopLocalVAD, .problem(reason)])
    case (.off, .start):
      phase = .listening
      return [.startLocalVAD, .problem(nil)]
    case (.listening, .speechStarted):
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
      defer { pending = [] }
      return [.flushPreroll] + pending.map(CallEffect.addContext) + [armSilence]
    case (.connecting, .connectFailed(let reason)), (.connecting, .remoteClosed(let reason)),
      (.live, .remoteClosed(let reason)):
      hangUp()
      return [.problem(reason)]
    case (.live, .deliver(let result)):
      return [.addContext(result), .cancelSilenceTimer]
    case (.live, .speechStarted):
      return [.cancelSilenceTimer]
    case (.live, .speechEnded):
      return [armSilence]
    case (.live, .handedOff):
      awaitingAck = true
      return []
    case (.live, .assistantFinishedSpeaking):
      guard awaitingAck else { return [armSilence] }
      hangUp()
      return [.closeRealtime]
    case (.live, .silenceElapsed):
      guard !awaitingAck else { return [] }
      hangUp()
      return [.closeRealtime]
    default:
      return []
    }
  }

  /// Back to local listening; `pending` is kept.
  private mutating func hangUp() {
    phase = .listening
    awaitingAck = false
  }

  private mutating func end(with effects: [CallEffect]) -> [CallEffect] {
    self = CallMachine(silenceSeconds: silenceSeconds)
    return effects
  }
}
