import Foundation

/// What the update's network requests follow and keep (the spec's step 2): a redirect only over
/// https to a named host on the default port, and nothing past the byte limit.
public enum DownloadRules {
  /// The hosts the image download may be redirected to: GitHub's release asset hosts.
  public static let assetHosts: Set<String> = [
    "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
  ]
  /// The hosts the release check may be redirected to.
  public static let apiHosts: Set<String> = ["api.github.com"]

  /// `url` is https, on the default port, to one of `hosts`.
  public static func allowsRedirect(to url: URL, hosts: Set<String>) -> Bool {
    guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
      let host = url.host()?.lowercased()
    else { return false }
    return hosts.contains(host)
  }

  /// A transfer that declared `declared` bytes (negative when it did not say) and has delivered
  /// `received` is over `maxBytes`, and is cut off.
  public static func exceeds(maxBytes: Int, declared: Int64, received: Int64) -> Bool {
    declared > Int64(maxBytes) || received > Int64(maxBytes)
  }
}
