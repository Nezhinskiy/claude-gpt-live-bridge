import Foundation

/// What the open line shows of the lines still being spoken, in the order they started: at most
/// one for each speaker, as codex's deltas name only the role. A line's final text replaces it.
/// These are kept apart from `Conversation`, so until it is final a line is never saved and never
/// seeds the voice.
struct GrowingLines: Sendable {
  private var growing: [Conversation.Line] = []

  /// The lines to show, without the space codex's first delta starts with. codex can send an
  /// empty delta after a final text, which shows nothing.
  var lines: [Conversation.Line] {
    growing.compactMap { line in
      let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : Conversation.Line(speaker: line.speaker, text: text)
    }
  }

  /// `words` follow what `speaker` has said so far.
  mutating func add(_ words: String, from speaker: Conversation.Line.Speaker) {
    if let index = growing.firstIndex(where: { $0.speaker == speaker }) {
      growing[index].text += words
    } else {
      growing.append(Conversation.Line(speaker: speaker, text: words))
    }
  }

  /// `speaker`'s line got its final text.
  mutating func finish(_ speaker: Conversation.Line.Speaker) {
    growing.removeAll { $0.speaker == speaker }
  }
}
