import Darwin
import Foundation

/// The `/bin/sh` that reopens the app after an update (the spec's step 9). It waits for the old
/// process to exit, then, until this user runs the app's own executable, `open`s the app and
/// waits a second, at most `attempts` times. One `open` is not enough: for a moment after the old
/// process is gone, LaunchServices still holds it, and `open` may target it, fail (-600, -609)
/// and still exit 0. An instance of the app found before an `open`, the mod's included, ends the
/// loop; a `LiveBridge` run from elsewhere (a debug build) does not. After the last attempt it
/// gives up silently. Every value is a positional argument, never script text.
public enum RelaunchScript {
  /// The `pgrep -f` pattern for a process whose argument list starts with `app`'s executable:
  /// the path with every regular-expression character escaped, anchored at the start and ended
  /// by a space or the end of the list.
  static func pattern(app: String) -> String {
    let executable = app + "/Contents/MacOS/LiveBridge"
    let special = Set(#"\.[]()*+?{}|^$"#)
    let escaped = executable.map { special.contains($0) ? "\\\($0)" : "\($0)" }.joined()
    return "^\(escaped)( |$)"
  }

  static let script = """
    while /bin/kill -0 "$1" 2>/dev/null; do "$5" 0.2; done
    n=0
    while [ "$n" -lt "$6" ]; do
      "$4" -U "$8" -f "$7" >/dev/null 2>&1 && exit 0
      "$3" "$2" >/dev/null 2>&1
      n=$((n + 1))
      "$5" 1
    done
    """

  /// The arguments of `/bin/sh` that reopen `app` once `pid` has exited.
  public static func arguments(
    pid: Int32, app: String, open: String = "/usr/bin/open", pgrep: String = "/usr/bin/pgrep",
    sleep: String = "/bin/sleep", attempts: Int = 10
  ) -> [String] {
    [
      "-c", script, "sh", String(pid), app, open, pgrep, sleep, String(attempts), pattern(app: app),
      String(getuid()),
    ]
  }
}
