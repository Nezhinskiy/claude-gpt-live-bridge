/// Turns a session's answer into one line the voice can say: no code, no tables, no secrets,
/// at most `maxCharacters`, tagged with its status and the session's label.
public enum AnswerShaper {
  public static let maxCharacters = 2000
  /// The longest label a line carries, so a session title cannot crowd out the body.
  public static let maxLabel = 120

  public static func forVoice(
    _ text: String, status: AnswerStatus, label: String, session: SessionID? = nil
  ) -> VoiceLine {
    let prose = prose(text)
    let kind: VoiceLine.Kind =
      switch status {
      case .ok: .result
      case .failed: .failed
      case .question: .question
      case .update: .update
      }
    return line(
      kind, label: label,
      body: prose.allSatisfy(\.isWhitespace)
        ? "the answer is code or a table only; it is in the session." : prose,
      session: session)
  }

  /// `text` without its fenced code blocks and table rows, its lines joined by spaces.
  public static func prose(_ text: String) -> String {
    text.replacing(/```[\s\S]*?(```|\z)/, with: "\n")
      .split(whereSeparator: \.isNewline).filter { !$0.trimmingPrefix(/\s*/).hasPrefix("|") }
      .joined(separator: " ")
  }

  /// `[TAG] label: body` as exactly one line of at most `limit` characters, the label cut to
  /// `maxLabel` and the body redacted,
  /// so a session's text cannot pose as another delivery: every opening or closing bracket of
  /// any script becomes `(` or `)`, and every line break a space.
  public static func line(
    _ kind: VoiceLine.Kind, label: String, body: String, limit: Int = maxCharacters,
    session: SessionID? = nil
  ) -> VoiceLine {
    let label = String(flat(label).prefix(maxLabel))
    let head = VoiceLine(kind: kind, label: label, body: "").text
    let body = cap(Redaction.redact(flat(body)), to: limit - head.count)
    return VoiceLine(kind: kind, label: label, body: body, session: session)
  }

  /// Brackets made plain and whitespace runs, line breaks among them, one space.
  static func flat(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.unicodeScalars.map { scalar in
          switch scalar.properties.generalCategory {
          case .openPunctuation: "("
          case .closePunctuation: ")"
          default: scalar
          }
        })
    ).split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// `text` cut to `limit` characters after its last whole sentence, else with an ellipsis;
  /// empty for a limit below 1.
  public static func cap(_ text: String, to limit: Int) -> String {
    guard limit > 0 else { return "" }
    guard text.count > limit else { return text }
    let head = text.prefix(limit + 1)
    let ends = head.indices.dropLast().filter {
      ".!?".contains(head[$0]) && head[head.index(after: $0)].isWhitespace
    }
    guard let end = ends.last else { return String(text.prefix(limit - 1)) + "…" }
    return String(head[...end])
  }
}
