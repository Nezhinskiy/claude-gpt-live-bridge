import Foundation

/// A release number, `major.minor.patch`. Parsing is strict: only digits, no leading zeros, at
/// most six digits a part, so a version read from a tag or a bundle can be trusted to build
/// paths and URLs from.
public struct AppVersion: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  /// Nil unless `text` is exactly `X.Y.Z`: `0` or a number without a leading zero, up to six
  /// digits, three times, dot-separated.
  public init?(_ text: String) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    let numbers = parts.compactMap(Self.number)
    guard numbers.count == 3 else { return nil }
    (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
  }

  /// Nil unless `tag` is `v` followed by a version that parses.
  public init?(tag: String) {
    guard tag.hasPrefix("v") else { return nil }
    self.init(String(tag.dropFirst()))
  }

  /// The git tag of this version, `v1.2.3`.
  public var tag: String { "v\(self)" }

  public var description: String { "\(major).\(minor).\(patch)" }

  public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  /// A version is stored as its `X.Y.Z` string.
  public init(from decoder: any Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard let version = AppVersion(text) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Not a version: \(text)"))
    }
    self = version
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  /// One part: ASCII digits only (`Int(_:)` would accept `+2`), `0` or no leading zero, at
  /// most six of them.
  private static func number(_ part: Substring) -> Int? {
    let digits = part.utf8
    guard (1...6).contains(digits.count), digits.allSatisfy({ (48...57).contains($0) }),
      digits.first != 48 || digits.count == 1
    else { return nil }
    return Int(part)
  }
}
