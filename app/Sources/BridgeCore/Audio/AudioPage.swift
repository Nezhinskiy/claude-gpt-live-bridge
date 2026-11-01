import Foundation

/// The audio page's contract with the app: its one URL, the files it may load, and the messages
/// it posts. The page is served from the app bundle under its own scheme, a stable origin that
/// WebKit treats as a secure context (ADR 0001 (a)).
public enum AudioPage {
  public static let scheme = "livebridge-audio"
  public static let host = "app"
  public static let url = URL(string: "\(scheme)://\(host)/index.html")!

  /// The page may only ever be the app page, and only in the main frame: no other URL, no
  /// subframe.
  public static func allowsNavigation(to url: URL?, mainFrame: Bool) -> Bool {
    mainFrame && url == Self.url
  }

  /// The bundled file a page request names: a plain file name on the app host, nothing else.
  public static func resourceName(for url: URL) -> String? {
    guard url.scheme == scheme, url.host == host else { return nil }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].isEmpty, !parts[1].hasPrefix(".") else { return nil }
    return String(parts[1])
  }
}

/// A message the page posts with `window.webkit.messageHandlers.bridge.postMessage`.
public enum PageMessage: Sendable, Equatable {
  case speechStarted, speechEnded
  /// The input level while the line is open, 0 to 1, for the menu bar meter.
  case level(Double)
  /// The microphone or the peer connection failed; the sentence is for the owner.
  case audioFailed(String)

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
    case "audioFailed":
      self = .audioFailed(message["reason"] as? String ?? "The audio stopped unexpectedly.")
    default: return nil
    }
  }

  /// What the call hears of it; the level only drives the menu bar.
  public var audioEvent: AudioEvent? {
    switch self {
    case .speechStarted: .speechStarted
    case .speechEnded: .speechEnded
    case .level: nil
    case .audioFailed(let reason): .failed(reason)
    }
  }
}
