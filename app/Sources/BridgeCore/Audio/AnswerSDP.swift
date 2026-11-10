/// The media server's SDP answer, as the audio page applies it.
enum AnswerSDP {
  /// The priority the UDP candidates get under **Connect over TCP**, far below the TCP
  /// candidates' in the answers seen; the value tested on a real call (2026-11-10).
  static let udpPriority = "1000"

  /// The answer with its UDP candidates' priority lowered, so WebKit prefers its TCP candidates
  /// (port 443) and can still fall back to UDP. An answer with no TCP candidate is returned as it
  /// came. Only the priority field of `a=candidate:` lines whose transport is `udp`, in any case,
  /// changes; every other byte, line endings included, stays.
  static func preferringTCP(_ sdp: String) -> String {
    var lines = sdp.components(separatedBy: "\n").map { $0.components(separatedBy: " ") }
    guard lines.contains(where: { isCandidate($0, over: "tcp") }) else { return sdp }
    for index in lines.indices where isCandidate(lines[index], over: "udp") {
      lines[index][3] = udpPriority
    }
    return lines.map { $0.joined(separator: " ") }.joined(separator: "\n")
  }

  /// `a=candidate:<foundation> <component> <transport> <priority> …` with that transport and a
  /// numeric priority.
  private static func isCandidate(_ fields: [String], over transport: String) -> Bool {
    fields.count > 3 && fields[0].hasPrefix("a=candidate:")
      && fields[2].lowercased() == transport && UInt32(fields[3]) != nil
  }
}
