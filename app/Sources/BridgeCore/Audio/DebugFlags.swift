#if DEBUG
  import Foundation

  /// The debug tools a build was started with. This type exists in debug builds only, and the
  /// release guards look for its name, so they notice a flag that loses its gate: a flag's own
  /// short literal is invisible to them in an optimised binary.
  public struct DebugFlags: Equatable, Sendable {
    public struct Refused: Error, Equatable, CustomStringConvertible {
      public let description: String
    }

    /// `--fake-mic <wav>`, once per line: played as the microphone, each next one when the voice
    /// has finished speaking.
    public var fakeMic: [URL] = []
    /// `--record-call <wav>`: both sides of the call, each call starting the tape over.
    public var tape: URL?
    /// `--voice-instructions <file>`: the file's text, and not the voice's rules.
    public var voiceInstructions: String?

    public init() {}

    /// A tool that cannot work is refused here: a take must not run for a minute without it.
    public init(arguments: [String]) throws {
      for (index, flag) in arguments.enumerated() where flag.hasPrefix("--") {
        guard Self.names.contains(flag) else { continue }
        guard index + 1 < arguments.count else {
          throw Refused(description: "\(flag) needs a value")
        }
        let value = arguments[index + 1]
        switch flag {
        case "--fake-mic":
          guard FileManager.default.isReadableFile(atPath: value) else {
            throw Refused(description: "--fake-mic cannot read \(value)")
          }
          fakeMic.append(URL(filePath: value))
        case "--record-call":
          let folder = URL(filePath: value).deletingLastPathComponent().path
          guard FileManager.default.isWritableFile(atPath: folder) else {
            throw Refused(description: "--record-call cannot write in \(folder)")
          }
          tape = URL(filePath: value)
        default:
          guard let text = try? String(contentsOfFile: value, encoding: .utf8) else {
            throw Refused(description: "--voice-instructions cannot read \(value)")
          }
          voiceInstructions = text
        }
      }
    }

    private static let names = ["--fake-mic", "--record-call", "--voice-instructions"]

    /// This launch's flags. Only a person running a debug build reaches the stop.
    public static let current: DebugFlags = {
      do {
        return try DebugFlags(arguments: CommandLine.arguments)
      } catch {
        fatalError("\(error)")
      }
    }()
  }
#endif
