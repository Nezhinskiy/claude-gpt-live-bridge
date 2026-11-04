/// Turns a session's answer into one line the voice can say: no code, no tables, no secrets,
/// at most `maxCharacters`, tagged with its status and the session's label.
public enum AnswerShaper {
  public static let maxCharacters = 2000
  /// The longest label a line carries, so a session title cannot crowd out the body.
  public static let maxLabel = 120

  /// What the voice can say of an answer that is only code or tables.
  static let noProse = "the answer is code or a table only; it is in the session."

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
      body: prose.allSatisfy(\.isWhitespace) ? noProse : prose, session: session)
  }

  /// The text without fenced code blocks and table rows, its lines joined by spaces.
  public static func prose(_ text: String) -> String {
    text.replacing(/```[\s\S]*?(```|\z)/, with: "\n")
      .split(whereSeparator: \.isNewline).filter { !$0.trimmingPrefix(/\s*/).hasPrefix("|") }
      .joined(separator: " ")
  }

  /// Claude's last reply as a `[LAST]` line: its prose, redacted, with its end kept, since a
  /// reply ends with its conclusion and any question Claude waits on.
  public static func lastReply(_ text: String, label: String, session: SessionID? = nil)
    -> VoiceLine
  {
    let prose = prose(text)
    return line(
      .last, label: label, body: prose.allSatisfy(\.isWhitespace) ? noProse : prose,
      keepingEnd: true, session: session)
  }

  /// `[TAG] label: body` as exactly one line of at most `limit` characters, the label cut to
  /// `maxLabel` and the body redacted, its start kept or, `keepingEnd`, its end,
  /// so a session's text cannot pose as another delivery: every opening or closing bracket of
  /// any script becomes `(` or `)`, and every line break a space.
  public static func line(
    _ kind: VoiceLine.Kind, label: String, body: String, limit: Int = maxCharacters,
    keepingEnd: Bool = false, session: SessionID? = nil
  ) -> VoiceLine {
    let label = String(flat(label).prefix(maxLabel))
    let head = VoiceLine(kind: kind, label: label, body: "").text
    let redacted = Redaction.redact(flat(body))
    let room = limit - head.count
    let body = keepingEnd ? capKeepingEnd(redacted, to: room) : cap(redacted, to: room)
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

  /// `text` cut to its last `limit` characters from a sentence start, else after an ellipsis;
  /// empty for a limit below 1.
  static func capKeepingEnd(_ text: String, to limit: Int) -> String {
    guard limit > 0 else { return "" }
    guard text.count > limit else { return text }
    let tail = text.suffix(limit + 1)
    let starts = tail.indices.dropFirst().filter {
      tail[$0].isWhitespace && ".!?".contains(tail[tail.index(before: $0)])
    }
    guard let start = starts.first else { return "…" + String(text.suffix(limit - 1)) }
    return String(tail[start...].dropFirst())
  }
}
