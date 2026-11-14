import Foundation

/// The `/bin/sh` the menu's Uninstall LiveBridge leaves running as the app quits. It waits for the
/// app's process to exit, at most a minute, as `build-app.sh --uninstall` quits the app before it
/// removes anything, so the app does not write its files again. It then moves each one that exists
/// into one folder in the Trash, under the name of the folder it came from
/// (`Caches/com.getlivebridge.livebridge`), since three of them share a name. Every value is a
/// positional argument, never script text.
public enum UninstallScript {
  static let script = """
    n=0
    while /bin/kill -0 "$1" 2>/dev/null && [ "$n" -lt 300 ]; do /bin/sleep 0.2; n=$((n + 1)); done
    folder=$2
    shift 2
    for path; do
      [ -e "$path" ] || continue
      parent=${path%/*}
      into="$folder/${parent##*/}"
      /bin/mkdir -p "$into" && /bin/mv "$path" "$into/"
    done
    """

  /// The arguments of `/bin/sh` that move `paths` into the Trash folder `trash` once `pid` exits.
  public static func arguments(pid: Int32, trash: String, paths: [String]) -> [String] {
    ["-c", script, "sh", String(pid), trash] + paths
  }
}
