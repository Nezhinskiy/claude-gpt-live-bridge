import Foundation

public enum PathsError: LocalizedError, Equatable {
  /// A Unix socket path must fit `sockaddr_un.sun_path`: at most 103 bytes.
  case socketPathTooLong(String)
  /// The data or run directory cannot be made owner-only.
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
  /// The app's bundle identifier, as `Info.plist` and the scripts give it.
  public static let bundleID = "com.getlivebridge.livebridge"

  /// `~/Library/Application Support/LiveBridge`.
  public static func dataDir() throws -> URL { try dataDir(in: .applicationSupportDirectory) }

  /// What the menu's Uninstall LiveBridge moves to the Trash: the app and every file it keeps
  /// in `library`, the same list `build-app.sh --uninstall` removes.
  public static func uninstalled(app: URL, library: URL) -> [URL] {
    [
      app, library.appending(path: "Application Support/LiveBridge"),
      library.appending(path: "Caches/\(bundleID)"), library.appending(path: "WebKit/\(bundleID)"),
      library.appending(path: "HTTPStorages/\(bundleID)"),
      library.appending(path: "HTTPStorages/\(bundleID).binarycookies"),
      library.appending(path: "Preferences/\(bundleID).plist"),
    ]
  }

  /// `<data dir>/run`, holding the socket.
  public static func runDir() throws -> URL { try runDir(in: .applicationSupportDirectory) }

  /// `<run dir>/bridge.sock`; the mod builds the same path from `CFFIXED_USER_HOME` when it is
  /// set, else from `HOME`, as Foundation does.
  public static func socketPath() throws -> URL { try runDir().appending(path: "bridge.sock") }

  static func dataDir(in base: URL) throws -> URL {
    try ownerOnlyDirectory(base.appending(path: "LiveBridge"))
  }

  static func runDir(in base: URL) throws -> URL {
    try ownerOnlyDirectory(dataDir(in: base).appending(path: "run"))
  }

  /// Creates `url` at mode `0700`, or resets an existing one with any group or other bit. A
  /// symlinked directory is followed: only the owner can put one there.
  static func ownerOnlyDirectory(_ url: URL) throws -> URL {
    let files = FileManager.default
    try files.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let real = url.resolvingSymlinksInPath().path
    func isOwnerOnly() throws -> Bool {
      (try files.attributesOfItem(atPath: real)[.posixPermissions] as? Int ?? 0o777) & 0o077 == 0
    }
    if try !isOwnerOnly() {
      try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: real)
      guard try isOwnerOnly() else { throw PathsError.insecureRunDir(url.path) }
    }
    return url
  }
}
