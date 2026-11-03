import Darwin
import Foundation

/// The pure readings the `Updater` makes of the image and of the programs it runs.
enum UpdateBundleCheck {
  /// What `hdiutil attach -plist` attached: the device to detach and the mount point, if any.
  struct Volume: Equatable {
    var device: String?
    var mountPoint: URL?
  }

  /// The first mounted entity in `hdiutil attach -plist` output; its mount point is detached,
  /// or the first device when nothing was mounted.
  static func volume(attachPlist: String) -> Volume {
    let plist = try? PropertyListSerialization.propertyList(
      from: Data(attachPlist.utf8), format: nil)
    let entities = (plist as? [String: Any])?["system-entities"] as? [[String: Any]] ?? []
    if let mountPoint = entities.lazy.compactMap({ $0["mount-point"] as? String }).first {
      return Volume(device: mountPoint, mountPoint: URL(filePath: mountPoint))
    }
    return Volume(device: entities.lazy.compactMap { $0["dev-entry"] as? String }.first)
  }

  /// `url` is a directory and not a symbolic link.
  static func isDirectory(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
  }

  /// The property list dictionary in `file`, or nil.
  static func info(_ file: URL) -> [String: Any]? {
    (try? Data(contentsOf: file)).flatMap {
      try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
    }
  }

  /// `os` meets an `LSMinimumSystemVersion` such as `14.0`: one to three integer parts, the
  /// missing ones 0. A minimum that does not read so is not met.
  static func runs(on os: OperatingSystemVersion, minimum: String) -> Bool {
    let parts = minimum.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return false }
    let numbers = parts.compactMap { part -> Int? in
      guard (1...6).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber)
      else { return nil }
      return Int(part)
    }
    guard numbers.count == parts.count else { return false }
    let required = numbers + Array(repeating: 0, count: 3 - numbers.count)
    let running = [os.majorVersion, os.minorVersion, os.patchVersion]
    return !running.lexicographicallyPrecedes(required)
  }

  /// The value of the `CDHash=` line in `codesign -dvvv` output, or nil.
  static func cdhash(codesignOutput: String) -> String? {
    let line = codesignOutput.split(whereSeparator: \.isNewline).first { $0.hasPrefix("CDHash=") }
    return line.map { String($0.dropFirst("CDHash=".count)) }.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// The version of the plugin `id` in `claude plugin list --json` output, or nil.
  static func modVersion(pluginList: String, id: String) -> AppVersion? {
    let list = try? JSONDecoder().decode(JSONValue.self, from: Data(pluginList.utf8))
    let plugin = list?.array?.first { $0["id"]?.string == id }
    return plugin?["version"]?.string.flatMap { AppVersion($0) }
  }
}
