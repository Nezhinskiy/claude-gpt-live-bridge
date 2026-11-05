import Foundation

/// The latest release as GitHub's `releases/latest` reply gives it. Only the tag is trusted
/// from the reply, and only after it parses; every URL is built from the version, never taken
/// from the reply.
public struct Release: Equatable, Sendable {
  public let version: AppVersion
  /// Where the disk image is downloaded from.
  public let imageURL: URL
  /// The release's page on GitHub, which has the image for a download by hand.
  public let pageURL: URL

  /// The release in `reply`, or why it cannot be one: not JSON (`network`), a tag that is not
  /// `vX.Y.Z` (`badTag`), no asset named `LiveBridge.dmg` (`noImage`).
  public static func parse(_ reply: Data) throws(UpdateProblem) -> Release {
    let decoded: Reply
    do {
      decoded = try JSONDecoder().decode(Reply.self, from: reply)
    } catch {
      throw .network("GitHub's reply was not a release.")
    }
    guard let version = AppVersion(tag: decoded.tagName) else { throw .badTag(decoded.tagName) }
    guard decoded.assets?.contains(where: { $0.name == imageName }) == true else {
      throw .noImage
    }
    let base = "https://github.com/\(repository)/releases"
    guard let imageURL = URL(string: "\(base)/download/\(version.tag)/\(imageName)"),
      let pageURL = URL(string: "\(base)/tag/\(version.tag)")
    else { throw .badTag(decoded.tagName) }
    return Release(version: version, imageURL: imageURL, pageURL: pageURL)
  }

  /// The asset every release carries.
  static let imageName = "LiveBridge.dmg"
  /// The repository that publishes the releases.
  public static let repository = "getLiveBridge/LiveBridge"
  /// Its page on GitHub, where the menu's star item goes.
  public static let repositoryPage = URL(string: "https://github.com/\(repository)")!
  /// GitHub's latest release of LiveBridge.
  public static let latestURL = URL(
    string: "https://api.github.com/repos/\(repository)/releases/latest")!

  private struct Reply: Decodable {
    let tagName: String
    let assets: [Asset]?

    struct Asset: Decodable { let name: String }

    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case assets
    }
  }
}
