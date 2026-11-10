import Testing

@testable import BridgeCore

/// The media server's answer, shaped as seen on 2026-11-09 (addresses from the documentation
/// ranges): UDP host candidates on 3478 and passive TCP host candidates on 443.
struct AnswerSDPTests {
  static let udp = "a=candidate:1 1 udp 2130706431 192.0.2.10 3478 typ host"
  static let tcp = "a=candidate:2 1 tcp 1671430143 192.0.2.10 443 typ host tcptype passive"
  static let lowered = "a=candidate:1 1 udp 1000 192.0.2.10 3478 typ host"

  static func answer(_ lines: [String], ending: String = "\r\n") -> String {
    (["v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=ice-lite"] + lines + ["a=end-of-candidates"])
      .map { $0 + ending }.joined()
  }

  @Test func lowersTheUDPCandidatesBelowTCP() {
    #expect(
      AnswerSDP.preferringTCP(Self.answer([Self.udp, Self.tcp]))
        == Self.answer([Self.lowered, Self.tcp]))
  }

  @Test func keepsBareNewlines() {
    #expect(
      AnswerSDP.preferringTCP(Self.answer([Self.udp, Self.tcp], ending: "\n"))
        == Self.answer([Self.lowered, Self.tcp], ending: "\n"))
  }

  @Test func readsTheTransportInAnyCase() {
    let upper = Self.udp.replacingOccurrences(of: " udp ", with: " UDP ")
    let lowered = Self.lowered.replacingOccurrences(of: " udp ", with: " UDP ")
    #expect(
      AnswerSDP.preferringTCP(Self.answer([upper, Self.tcp]))
        == Self.answer([lowered, Self.tcp]))
  }

  /// With no TCP candidate there is nothing to prefer: the answer goes as it came.
  @Test func leavesAnAnswerWithoutTCPUntouched() {
    let answer = Self.answer([Self.udp, Self.udp.replacingOccurrences(of: ":1 ", with: ":3 ")])
    #expect(AnswerSDP.preferringTCP(answer) == answer)
  }

  /// Only a candidate's priority changes: other `a=` lines that mention udp, and a candidate line
  /// too short to have a priority, stay as they were.
  @Test func leavesEveryOtherLineUntouched() {
    let others = [
      "a=rtcp-fb:111 transport-cc", "a=x-note udp 5 udp", "a=candidate:9 1 udp",
      "a=candidate:9 1 udp high 192.0.2.10 3478 typ host",
    ]
    #expect(
      AnswerSDP.preferringTCP(Self.answer(others + [Self.udp, Self.tcp]))
        == Self.answer(others + [Self.lowered, Self.tcp]))
  }
}
