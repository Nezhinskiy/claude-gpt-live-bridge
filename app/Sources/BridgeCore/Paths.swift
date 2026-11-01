import Foundation

public enum PathsError: LocalizedError, Equatable {
  /// A Unix socket path must fit `sockaddr_un.sun_path`: at most 103 bytes.
  case socketPathTooLong(String)
  /// The data or run directory is not a directory owned by this user, or cannot be made
  /// owner-only.
  case insecureRunDir(String)

  public var errorDescription: String? {
    switch self {
    case .socketPathTooLong(let path):
      "the socket path is \(path.utf8.count) bytes and macOS allows at most 103, because the home folder's path is long."
    case .insecureRunDir(let path):
      "\(path) is not a folder only you can open, so the bridge will not use it."
    }
  }
}

/// Where the app keeps its files. The run directory's `0700` mode is the bridge's one access
/// control: whoever can reach the socket inside it is this user.
public enum Paths {
  public static let maxSocketPathBytes = 103

  /// `~/Library/Application Support/claude-gpt-live-bridge`.
  public static func dataDir() throws -> URL { try dataDir(in: .applicationSupportDirectory) }

  /// `<data dir>/run`, holding the socket.
  public static func runDir() throws -> URL { try runDir(in: .applicationSupportDirectory) }

  /// `<run dir>/bridge.sock`; the mod builds the same path from `HOME`.
  public static func socketPath() throws -> URL { try runDir().appending(path: "bridge.sock") }

  static func dataDir(in base: URL) throws -> URL {
    try ownerOnlyDirectory(base.appending(path: "claude-gpt-live-bridge"))
  }

  static func runDir(in base: URL) throws -> URL {
    try ownerOnlyDirectory(dataDir(in: base).appending(path: "run"))
  }

  /// Creates `url` at mode `0700`, or resets an existing one with any group or other bit.
  /// A symlink, or a directory another user owns, is refused.
  static func ownerOnlyDirectory(_ url: URL) throws -> URL {
    let files = FileManager.default
    try files.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    func isOwnerOnly() throws -> Bool {
      let attributes = try files.attributesOfItem(atPath: url.path)  // does not follow a symlink
      guard attributes[.type] as? FileAttributeType == .typeDirectory,
        (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
      else { throw PathsError.insecureRunDir(url.path) }
      return (attributes[.posixPermissions] as? Int ?? 0o777) & 0o077 == 0
    }
    if try !isOwnerOnly() {
      try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
      guard try isOwnerOnly() else { throw PathsError.insecureRunDir(url.path) }
    }
    return url
  }
}
