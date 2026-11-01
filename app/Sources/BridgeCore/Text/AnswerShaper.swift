/// Turns a session's answer into one line the voice can say: no code, no tables, no secrets,
/// at most `maxCharacters`, tagged with its status and the session's label.
public enum AnswerShaper {
  public static let maxCharacters = 2000

  public static func forVoice(_ text: String, status: AnswerStatus, label: String) -> String {
    let tag = "[\(tags[status] ?? "RESULT")] \(label): "
    let prose = text.replacing(/```[\s\S]*?(```|\z)/, with: "\n")
      .split(separator: "\n").filter { !$0.trimmingPrefix(/\s*/).hasPrefix("|") }
      .joined(separator: " ")
    var body = Redaction.redact(prose).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if body.isEmpty { body = "the answer is code or a table only; it is in the session." }
    return tag + cap(body, to: maxCharacters - tag.count)
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
