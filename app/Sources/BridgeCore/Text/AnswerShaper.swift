/// Turns a session's answer into one line the voice can say: no code, no tables, no secrets,
/// at most `maxCharacters`, tagged with its status and the session's label.
public enum AnswerShaper {
  public static let maxCharacters = 2000

  public static func forVoice(_ text: String, status: AnswerStatus, label: String) -> String {
    let prose = text.replacing(/```[\s\S]*?(```|\z)/, with: "\n")
      .split(whereSeparator: \.isNewline).filter { !$0.trimmingPrefix(/\s*/).hasPrefix("|") }
      .joined(separator: " ")
    let tag =
      switch status {
      case .ok: "RESULT"
      case .failed: "FAILED"
      case .question: "QUESTION"
      case .update: "UPDATE"
      }
    return line(
      tag: tag, label: label,
      body: prose.allSatisfy(\.isWhitespace)
        ? "the answer is code or a table only; it is in the session." : prose)
  }

  /// `[TAG] label: body` as exactly one line of at most `limit` characters, the body redacted,
  /// so a session's text cannot pose as another delivery: every opening or closing bracket of
  /// any script becomes `(` or `)`, and every line break a space.
  public static func line(
    tag: String, label: String, body: String, limit: Int = maxCharacters
  ) -> String {
    let head = "[\(tag)] \(flat(label)): "
    return head + cap(Redaction.redact(flat(body)), to: limit - head.count)
  }

  /// NFKC with format characters (zero-width and the like) removed, so redaction sees a token
  /// whole; brackets made plain and whitespace runs one space.
  static func flat(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.precomposedStringWithCompatibilityMapping.unicodeScalars.compactMap {
          scalar -> Unicode.Scalar? in
          switch scalar.properties.generalCategory {
          case .format: nil
          case .openPunctuation: "("
          case .closePunctuation: ")"
          default: scalar
          }
        })
    ).split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// `text` cut to `limit` characters after its last whole sentence, else with an ellipsis.
  public static func cap(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    let head = text.prefix(limit + 1)
    let ends = head.indices.dropLast().filter {
      ".!?".contains(head[$0]) && head[head.index(after: $0)].isWhitespace
    }
    guard let end = ends.last else { return String(text.prefix(limit - 1)) + "…" }
    return String(head[...end])
  }
}
