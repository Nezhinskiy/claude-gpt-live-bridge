import Foundation

/// The words of the lines still being spoken, for the menu, in the order they started: at most one
/// for each speaker, as codex's deltas name only the role. They stay apart from `Conversation`,
/// as they are not final.
struct GrowingLines: Sendable {
  private(set) var lines: [Conversation.Line] = []

  /// `words` follow what `speaker` has said so far. A line starts at its first word, without the
  /// space codex's deltas start with; a blank delta starts nothing.
  mutating func add(_ words: String, from speaker: Conversation.Line.Speaker) {
    if let index = lines.firstIndex(where: { $0.speaker == speaker }) {
      lines[index].text += words
    } else if let first = words.firstIndex(where: { !$0.isWhitespace }) {
      lines.append(Conversation.Line(speaker: speaker, text: String(words[first...])))
    }
  }

  /// `speaker`'s line got its final text, `final`. Words past it are the start of the next line.
  /// A delta names no turn, so words that do not match the final text cannot be told apart, and go.
  mutating func finish(_ speaker: Conversation.Line.Speaker, with final: String) {
    guard let index = lines.firstIndex(where: { $0.speaker == speaker }) else { return }
    let said = lines[index].text
    let next = said.hasPrefix(final) ? said.dropFirst(final.count).drop(while: \.isWhitespace) : ""
    if next.isEmpty {
      lines.remove(at: index)
    } else {
      lines[index].text = String(next)
    }
  }
}
