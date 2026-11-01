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
