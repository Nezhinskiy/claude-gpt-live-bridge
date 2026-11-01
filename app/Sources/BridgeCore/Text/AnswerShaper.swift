/// Turns a session's answer into one line the voice can say: no code, no tables, no secrets,
/// at most `maxCharacters`, tagged with its status and the session's label.
public enum AnswerShaper {
  public static let maxCharacters = 2000

  public static func forVoice(_ text: String, status: AnswerStatus, label: String) -> String {
    let prose = text.replacing(/```[\s\S]*?(```|\z)/, with: "\n")
      .split(whereSeparator: \.isNewline).filter { !$0.trimmingPrefix(/\s*/).hasPrefix("|") }
      .joined(separator: " ")
    var body = Redaction.redact(normalized(prose))
    if body.allSatisfy(\.isWhitespace) {
      body = "the answer is code or a table only; it is in the session."
    }
    let tag = tags[status] ?? "RESULT"
    return line(
      tag: tag, label: label, body: cap(body, to: maxCharacters - tag.count - label.count - 4))
  }

  /// `[TAG] label: body` as exactly one line, so a session's text cannot pose as another
  /// delivery: after `normalized`, every opening or closing bracket of any script becomes `(`
  /// or `)`, and every line break a space.
  public static func line(tag: String, label: String, body: String) -> String {
    let flat = { (text: String) in
      String(
        String.UnicodeScalarView(
          normalized(text).unicodeScalars.map {
            switch $0.properties.generalCategory {
            case .openPunctuation: "("
            case .closePunctuation: ")"
            default: $0
            }
          })
      ).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    return "[\(tag)] \(flat(label)): \(flat(body))"
  }

  /// NFKC with format characters (zero-width and the like) removed; run before redaction, so
  /// such a character inside a token cannot hide it.
  public static func normalized(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
          $0.properties.generalCategory != .format
        }))
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

  static let tags: [AnswerStatus: String] = [
    .ok: "RESULT", .failed: "FAILED", .question: "QUESTION", .update: "UPDATE",
  ]
}
