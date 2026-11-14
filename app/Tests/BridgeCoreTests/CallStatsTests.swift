import Foundation
import JavaScriptCore
import Testing

@testable import BridgeCore

struct CallStatsRowTests {
  let moment = Date(timeIntervalSince1970: 1_700_000_000.25)
  let utc = TimeZone(identifier: "UTC")!

  func cells(_ body: Any) throws -> [String: String] {
    let row = try #require(CallStats.row(body, at: moment, timeZone: utc))
    let names = CallStats.header.split(separator: ",").map(String.init)
    let values = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    #expect(names.count == values.count)
    return Dictionary(uniqueKeysWithValues: zip(names, values))
  }

  @Test func theTimeIsReadableAndCarriesItsZone() throws {
    let row = try cells(["line": 1])
    #expect(row["time"] == "2023-11-14T22:13:20.250Z")
  }

  @Test func wholeNumbersHaveNoFraction() throws {
    let row = try cells(["line": 3, "packetsLost": NSNumber(value: 12.0)])
    #expect(row["line"] == "3")
    #expect(row["packetsLost"] == "12")
  }

  @Test func fractionsAreKept() throws {
    #expect(try cells(["line": 1, "jitter": 0.0125])["jitter"] == "0.0125")
  }

  /// WebKit leaves out what it does not report: the column stays, empty.
  @Test func aFieldNotReportedIsEmpty() throws {
    #expect(try cells(["line": 1])["jitterBufferDelay"] == "")
  }

  @Test func onlyTheListedNumbersAreWritten() throws {
    let body: [String: Any] = [
      "line": 1, "packetsLost": "secret", "trackIdentifier": "secret", "codecId": "secret",
    ]
    let row = try #require(CallStats.row(body, at: moment, timeZone: utc))
    #expect(!row.contains("secret"))
    #expect(try cells(body)["packetsLost"] == "")
  }

  @Test func aNumberThatIsNotFiniteIsEmpty() throws {
    #expect(try cells(["line": 1, "jitter": Double.infinity])["jitter"] == "")
  }

  @Test func aSampleWithoutItsLineIsDropped() {
    #expect(CallStats.row(["packetsLost": 1], at: moment, timeZone: utc) == nil)
  }

  @Test func aBodyThatIsNotASampleIsDropped() {
    #expect(CallStats.row("packetsLost", at: moment, timeZone: utc) == nil)
  }

  /// The numbers the owner reads a glitch by.
  @Test(arguments: [
    "packetsLost", "packetsReceived", "jitter", "concealedSamples", "totalSamplesReceived",
    "jitterBufferDelay", "packetsDiscarded", "onTcp",
  ])
  func theColumnIsWritten(_ name: String) throws {
    #expect(try cells(["line": 1, name: 7])[name] == "7")
  }

  @Test func theFileIsNamedAfterItsLocalMinuteAndSecond() {
    let moscow = TimeZone(secondsFromGMT: 3 * 3600)!
    #expect(CallStats.fileName(at: moment, timeZone: moscow) == "call-2023-11-15T01-13-20.csv")
  }
}

struct CallStatsLogTests {
  let base = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let utc = TimeZone(identifier: "UTC")!
  let first = Date(timeIntervalSince1970: 1_700_000_000)
  let second = Date(timeIntervalSince1970: 1_700_000_100)

  func lines(_ url: URL) throws -> [Substring] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
  }

  /// A log with debug mode on.
  func log() -> CallStatsLog {
    let log = CallStatsLog(
      directory: { [base] in try CallStats.directory(in: base) }, timeZone: utc)
    log.set(on: true)
    return log
  }

  @Test func theFolderIsOwnerOnlyUnderTheDebugData() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = try CallStats.directory(in: base)
    #expect(folder == base.appending(path: "LiveBridge/debug/call-stats"))
    let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions]
    #expect(mode as? Int == 0o700)
  }

  @Test func theFirstSampleOpensAFileWithItsHeader() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let url = try #require(try log().record(["line": 1], at: first))
    #expect(url.lastPathComponent == "call-2023-11-14T22-13-20.csv")
    let written = try lines(url)
    #expect(written.count == 2)
    #expect(written[0] == Substring(CallStats.header))
  }

  @Test func laterSamplesOfTheCallGoInTheSameFile() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let log = log()
    let url = try #require(try log.record(["line": 1], at: first))
    #expect(try log.record(["line": 1], at: second) == nil)
    #expect(try lines(url).count == 3)
  }

  @Test func aNewCallGetsItsOwnFile() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let log = log()
    let one = try #require(try log.record(["line": 1], at: first))
    log.endCall()
    let two = try #require(try log.record(["line": 2], at: second))
    #expect(one != two)
    #expect(try lines(one).count == 2)
    #expect(try lines(two).count == 2)
  }

  @Test func whileOffNothingIsWrittenAndNoFolderMade() throws {
    var asked = 0
    let log = CallStatsLog(
      directory: { [base] in
        asked += 1
        return try CallStats.directory(in: base)
      }, timeZone: utc)
    #expect(try log.record(["line": 1], at: first) == nil)
    #expect(asked == 0)
    #expect(!FileManager.default.fileExists(atPath: base.path))
  }

  @Test func turnedOffMidCallItClosesTheFileAndDropsWhatFollows() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let log = log()
    let url = try #require(try log.record(["line": 1], at: first))
    log.set(on: false)
    #expect(try log.record(["line": 1], at: second) == nil)
    #expect(try lines(url).count == 2)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        .count == 1)
  }

  @Test func offAndOnAgainInOneCallStartsANewFile() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let log = log()
    let one = try #require(try log.record(["line": 1], at: first))
    log.set(on: false)
    log.set(on: true)
    let two = try #require(try log.record(["line": 1], at: second))
    #expect(one != two)
    #expect(try lines(one).count == 2)
  }

  @Test func aFolderDeletedBetweenCallsIsMadeAgain() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let log = log()
    let one = try #require(try log.record(["line": 1], at: first))
    log.endCall()
    try FileManager.default.removeItem(at: one.deletingLastPathComponent())
    let two = try #require(try log.record(["line": 2], at: second))
    #expect(try lines(two).count == 2)
  }

  @Test func twoCallsInOneSecondKeepBothFiles() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    let log = log()
    let one = try #require(try log.record(["line": 1], at: first))
    log.endCall()
    let two = try #require(try log.record(["line": 2], at: first))
    #expect(one != two)
    #expect(try lines(one).count == 2)
    #expect(try lines(two).count == 2)
  }

  /// A folder that cannot be made fails the call's first sample only; the next call tries again.
  @Test func aFolderThatCannotBeMadeIsReportedOnceACall() throws {
    struct NoFolder: Error {}
    var asked = 0
    let log = CallStatsLog(
      directory: {
        asked += 1
        throw NoFolder()
      }, timeZone: utc)
    log.set(on: true)
    #expect(throws: NoFolder.self) { try log.record(["line": 1], at: first) }
    #expect(try log.record(["line": 1], at: second) == nil)
    #expect(asked == 1)
    log.endCall()
    #expect(throws: NoFolder.self) { try log.record(["line": 1], at: second) }
  }

  @Test func aDroppedSampleOpensNoFile() throws {
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(try log().record("not a sample", at: first) == nil)
    let folder = try CallStats.directory(in: base)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }
}

/// `CallStats.pageScript` against a fake peer, in the JavaScript engine WebKit is built on.
struct CallStatsPageScriptTests {
  let page: JSContext

  /// Switched on, as debug mode does; `fresh()` is the page as it loads.
  init() {
    page = Self.fresh()
    page.evaluateScript(CallStats.switchScript(on: true))
  }

  static func fresh() -> JSContext {
    let page = JSContext()!
    page.evaluateScript(
      """
      var window = this;
      var posted = [];
      var timers = [];
      function setInterval(run, ms) { timers.push({ run, ms }); return timers.length; }
      function clearInterval(id) { timers[id - 1] = null; }
      function tick() { timers.forEach((timer) => timer && timer.run()); }
      window.webkit = { messageHandlers: {} };
      window.webkit.messageHandlers.\(CallStats.handlerName) = {
        postMessage: (message) => posted.push(message),
      };
      window.RTCPeerConnection = class {
        constructor(config) {
          this.config = config;
          this.signalingState = 'stable';
          this.reports = [];
        }
        getStats() {
          window.reads = (window.reads ?? 0) + 1;
          return Promise.resolve(new Map(this.reports.map((report, i) => [report.id ?? i, report])));
        }
      };
      var Native = window.RTCPeerConnection;
      var audio = { type: 'inbound-rtp', kind: 'audio', packetsLost: 2, jitter: 0.5,
                    packetsReceived: 'secret', ssrc: 'x', trackIdentifier: 'secret',
                    mid: 'secret' };
      """)
    page.evaluateScript(CallStats.pageScript)
    return page
  }

  func run(_ script: String) { page.evaluateScript(script) }
  func number(_ script: String) -> Int32 { page.evaluateScript(script).toInt32() }
  func text(_ script: String) -> String { page.evaluateScript(script).toString() }

  @Test func aTickPostsTheIncomingAudioNumbers() {
    run("var peer = new RTCPeerConnection(); peer.reports = [audio]; tick();")
    #expect(number("posted.length") == 1)
    #expect(number("posted[0].packetsLost") == 2)
    #expect(page.evaluateScript("posted[0].jitter").toDouble() == 0.5)
    #expect(number("posted[0].line") == 1)
  }

  @Test func onlyNumbersLeaveThePage() {
    run("var peer = new RTCPeerConnection(); peer.reports = [audio]; tick();")
    #expect(text("Object.keys(posted[0]).sort().join()") == "jitter,line,packetsLost")
  }

  /// The selected pair's local candidate, as Connect over TCP needs to see which transport the
  /// line took: 1 for TCP, 0 for UDP.
  func path(_ protocolName: String) -> String {
    """
    peer.reports = [audio,
      { type: 'transport', id: 'T', selectedCandidatePairId: 'P' },
      { type: 'candidate-pair', id: 'P', localCandidateId: 'L' },
      { type: 'local-candidate', id: 'L', protocol: '\(protocolName)', address: 'secret' }];
    tick();
    """
  }

  @Test func aLineOverTCPIsMarked() {
    run("var peer = new RTCPeerConnection();" + path("tcp"))
    #expect(number("posted[0].onTcp") == 1)
  }

  @Test func aLineOverUDPIsMarkedToo() {
    run("var peer = new RTCPeerConnection();" + path("udp"))
    #expect(number("posted[0].onTcp") == 0)
    #expect(text("Object.keys(posted[0]).sort().join()") == "jitter,line,onTcp,packetsLost")
  }

  @Test func theFieldsAreSampledOnceASecond() {
    run("new RTCPeerConnection();")
    #expect(number("timers[0].ms") == 1000)
  }

  @Test func otherReportsAreNotPosted() {
    run(
      """
      var peer = new RTCPeerConnection();
      peer.reports = [
        { type: 'outbound-rtp', kind: 'audio', packetsLost: 1 },
        { type: 'inbound-rtp', kind: 'video', packetsLost: 1 },
      ];
      tick();
      """)
    #expect(number("posted.length") == 0)
  }

  @Test func aClosedPeerIsNoLongerSampled() {
    run(
      """
      var peer = new RTCPeerConnection();
      peer.reports = [audio];
      peer.signalingState = 'closed';
      tick();
      """)
    #expect(number("posted.length") == 0)
    #expect(number("timers.filter(Boolean).length") == 0)
  }

  /// A sample that lands after the call ended would open a file for a call that is over.
  @Test func aPeerClosedWhileItsStatsArePendingPostsNothing() {
    run(
      """
      var peer = new RTCPeerConnection();
      peer.reports = [audio];
      tick();
      peer.signalingState = 'closed';
      """)
    #expect(number("posted.length") == 0)
  }

  @Test func nothingIsReadUntilSwitchedOn() {
    let page = Self.fresh()
    page.evaluateScript("var peer = new RTCPeerConnection(); peer.reports = [audio]; tick();")
    #expect(page.evaluateScript("timers.length").toInt32() == 1)
    #expect(page.evaluateScript("window.reads ?? 0").toInt32() == 0)  // not even read
    #expect(page.evaluateScript("posted.length").toInt32() == 0)
  }

  @Test func switchedOnItReadsOnceASecond() {
    let page = Self.fresh()
    page.evaluateScript("var peer = new RTCPeerConnection(); peer.reports = [audio];")
    page.evaluateScript(CallStats.switchScript(on: true))
    page.evaluateScript("tick();")
    #expect(page.evaluateScript("posted.length").toInt32() == 1)
  }

  /// Turned off mid-call, it posts nothing more, a reading already asked for included.
  @Test func switchedOffItReadsNoMore() {
    run("var peer = new RTCPeerConnection(); peer.reports = [audio]; tick();")
    run(CallStats.switchScript(on: false) + "tick(); tick();")
    #expect(number("window.reads") == 1)
  }

  @Test func eachPeerIsItsOwnLine() {
    run(
      """
      var one = new RTCPeerConnection();
      var two = new RTCPeerConnection();
      one.reports = [audio];
      two.reports = [audio];
      tick();
      """)
    #expect(text("posted.map((sample) => sample.line).join()") == "1,2")
  }

  @Test func thePageStillGetsARealPeer() {
    run("var peer = new RTCPeerConnection({ bundlePolicy: 'max-bundle' });")
    #expect(page.evaluateScript("peer instanceof Native").toBool())
    #expect(text("peer.config.bundlePolicy") == "max-bundle")
  }
}
