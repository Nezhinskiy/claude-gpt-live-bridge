import Foundation

/// What the audio page posts with `window.webkit.messageHandlers.bridge.postMessage`: local
/// voice detection, the input level and failures.
public enum AudioEvent: Sendable, Equatable {
  case speechStarted, speechEnded
  /// The input level while the line is open, 0 to 1; it drives only the menu bar meter.
  case level(Double)
  /// The microphone or the peer connection failed.
  case failed(Problem)
  /// An `error` event on the line's data channel, in the service's words.
  case lineError(code: String, message: String)

  public init?(body: Any) {
    guard let message = body as? [String: Any], let type = message["type"] as? String else {
      return nil
    }
    switch type {
    case "speechStarted": self = .speechStarted
    case "speechEnded": self = .speechEnded
    case "level":
      guard let value = message["value"] as? Double else { return nil }
      self = .level(value)
    case "microphoneDenied": self = .failed(.microphoneDenied)
    case "audioFailed":
      self = .failed(.other(message["reason"] as? String ?? "The audio stopped unexpectedly."))
    case "lineError":
      self = .lineError(
        code: message["code"] as? String ?? "", message: message["message"] as? String ?? "")
    default: return nil
    }
  }
}

/// The audio page: microphone, voice detection, pre-roll and the WebRTC peer.
public protocol AudioSide: Sendable {
  /// macOS's answer for the microphone, asking the owner first if it never was (its prompt then
  /// shows, for as long as the owner leaves it); nil when the page may open the microphone.
  func microphoneProblem() async -> Problem?
  func startListening() async
  func stopListening() async
  /// `preroll`: the line starts with the 2 s before it opened; false for a line nobody spoke on.
  func makeOffer(preroll: Bool) async throws -> String
  /// Applies the answer SDP and returns once the session is ready (the data channel's
  /// `session.started`, ADR 0001 (d)).
  func applyAnswer(_ sdp: String) async throws
  func flushPreroll() async
  func closePeer() async
  /// The short sound for a result that waits until the owner next speaks.
  func chime() async
  /// The short sound that confirms a handoff was queued for a session (BR-001).
  func confirmHandoff() async
  /// The voice finished a reply. Only a debug build does anything with it: the fake microphone
  /// plays its next line, and the call tape marks the moment.
  func voiceFinished() async
  /// Releases the microphone; the call goes on.
  func muteMicrophone() async
  /// Takes the microphone again, once it is back.
  func unmuteMicrophone() async
}
