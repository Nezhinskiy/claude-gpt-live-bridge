import Foundation

/// What the audio page posts with `window.webkit.messageHandlers.bridge.postMessage`: local
/// voice detection, the input level and failures.
public enum AudioEvent: Sendable, Equatable {
  case speechStarted, speechEnded
  /// The input level while the line is open, 0 to 1; it drives only the menu bar meter.
  case level(Double)
  /// The microphone or the peer connection failed.
  case failed(Problem)

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
    default: return nil
    }
  }
}

/// The audio page: microphone, voice detection, pre-roll and the WebRTC peer.
public protocol AudioSide: Sendable {
  func startListening() async
  func stopListening() async
  func makeOffer() async throws -> String
  /// Applies the answer SDP and returns once the session is ready (the data channel's
  /// `session.started`, ADR 0001 (d)).
  func applyAnswer(_ sdp: String) async throws
  func flushPreroll() async
  func closePeer() async
  /// The short sound for a result that waits until the owner next speaks.
  func chime() async
  /// The short sound that confirms a handoff reached a session (BR-001).
  func confirmHandoff() async
}
