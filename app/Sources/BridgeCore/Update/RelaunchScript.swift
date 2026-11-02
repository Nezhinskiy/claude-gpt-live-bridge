import Darwin
import Foundation

/// The `/bin/sh` that reopens the app after an update (the spec's step 9). It waits for the old
/// process to exit, then, until a `LiveBridge` of this user runs, `open`s the app and waits a
/// second, at most `attempts` times. One `open` is not enough: for a moment after the old
/// process is gone, LaunchServices still holds it, and `open` may target it, fail (-600, -609)
/// and still exit 0. An instance found before an `open`, the mod's included, ends the loop; after
/// the last attempt it gives up silently. Every value is a positional argument, never script text.
public enum RelaunchScript {
  /// The process name looked for.
  public static let processName = "LiveBridge"

  static let script = """
    while /bin/kill -0 "$1" 2>/dev/null; do "$5" 0.2; done
    n=0
    while [ "$n" -lt "$6" ]; do
      "$4" -x -U "$8" "$7" >/dev/null 2>&1 && exit 0
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
      "-c", script, "sh", String(pid), app, open, pgrep, sleep, String(attempts), processName,
      String(getuid()),
    ]
  }
}
