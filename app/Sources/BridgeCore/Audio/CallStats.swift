// The `--call-stats` debug tool: numbers about the incoming voice, in a local file, to help tell
// a network glitch from any other. Debug builds only, and not by a setting: the README promises
// no telemetry, so `#if DEBUG` compiles it out of a release, and
// scripts/tests/release-guards.test.sh looks there for its names.
#if DEBUG
  import Foundation

  public enum CallStats {
    /// The message handler the page script posts to.
    public static let handlerName = "callStats"

    /// What is read from the incoming audio's `inbound-rtp` report, and written. All are running
    /// totals of the line, but `jitter`, which is the current value in seconds.
    static let fields = [
      "packetsReceived", "packetsLost", "packetsDiscarded", "jitter", "concealedSamples",
      "silentConcealedSamples", "concealmentEvents", "totalSamplesReceived",
      "insertedSamplesForDeceleration",
      "removedSamplesForAcceleration", "jitterBufferDelay", "jitterBufferEmittedCount",
    ]

    static let header = (["time", "line"] + fields).joined(separator: ",")

    /// Runs before the page's own script, so the page needs no code for this: every peer it makes
    /// is sampled once a second until it closes. Only the numbers in `fields` leave the report.
    public static let pageScript = """
      (() => {
        const fields = [\(fields.map { "'\($0)'" }.joined(separator: ","))];
        const handler = window.webkit.messageHandlers.\(handlerName);
        let lines = 0;

        function sample(report, line) {
          report.forEach((entry) => {
            if (entry.type !== 'inbound-rtp' || entry.kind !== 'audio') return;
            const numbers = { line };
            for (const name of fields) {
              if (typeof entry[name] === 'number') numbers[name] = entry[name];
            }
            handler.postMessage(numbers);
          });
        }

        function watch(peer) {
          const line = ++lines;
          const timer = setInterval(async () => {
            if (peer.signalingState === 'closed') return clearInterval(timer);
            const report = await peer.getStats();
            if (peer.signalingState !== 'closed') sample(report, line);
          }, 1000);
        }

        window.RTCPeerConnection = class extends window.RTCPeerConnection {
          constructor(...settings) {
            super(...settings);
            watch(this);
          }
        };
      })();
      """

    /// One line of the file: the time, the line it was on, and the listed numbers; a number the
    /// page did not send stays empty. Nil for anything that is not a sample.
    static func row(_ body: Any, at date: Date, timeZone: TimeZone = .current) -> String? {
      guard let sample = body as? [String: Any], let line = number(sample["line"]) else {
        return nil
      }
      let time = ISO8601DateFormatter()
      time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      time.timeZone = timeZone
      let cells = [time.string(from: date), line] + fields.map { number(sample[$0]) ?? "" }
      return cells.joined(separator: ",")
    }

    private static func number(_ value: Any?) -> String? {
      guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
      return number.stringValue
    }

    static func fileName(at date: Date, timeZone: TimeZone = .current) -> String {
      let name = DateFormatter()
      name.locale = Locale(identifier: "en_US_POSIX")
      name.timeZone = timeZone
      name.dateFormat = "'call-'yyyy-MM-dd'T'HH-mm-ss'.csv'"
      return name.string(from: date)
    }

    /// `<data dir>/debug/call-stats`.
    public static func directory() throws -> URL {
      try directory(in: .applicationSupportDirectory)
    }

    static func directory(in base: URL) throws -> URL {
      try Paths.ownerOnlyDirectory(Paths.dataDir(in: base).appending(path: "debug/call-stats"))
    }
  }

  /// One file per call, made by the call's first sample: a call whose line never opened leaves
  /// none.
  public final class CallStatsLog {
    private let directory: URL
    private let timeZone: TimeZone
    private var file: FileHandle?

    public init(directory: URL, timeZone: TimeZone = .current) {
      self.directory = directory
      self.timeZone = timeZone
    }

    /// Adds the sample; returns the file when this sample opened it.
    public func record(_ body: Any, at date: Date) throws -> URL? {
      guard let row = CallStats.row(body, at: date, timeZone: timeZone) else { return nil }
      var opened: URL?
      if file == nil {
        let url = directory.appending(path: CallStats.fileName(at: date, timeZone: timeZone))
        try Data((CallStats.header + "\n").utf8).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        file = handle
        opened = url
      }
      try file?.write(contentsOf: Data((row + "\n").utf8))
      return opened
    }

    /// The next sample starts a new file.
    public func endCall() {
      try? file?.close()
      file = nil
    }
  }
#endif
