#if DEBUG
  import Foundation

  /// The audio of a call in a stereo WAV, the microphone on the left and the voice on the right,
  /// and beside it a JSON-lines file of marks timed on that tape (`--record-call`, debug builds
  /// only). Both stay valid after every write, so a take that dies keeps what it had. A mark's
  /// `at` counts the audio already written, so it can lead its sound by a chunk or two; `began`
  /// comes with the first chunk, so it need not be first; `voiceFinished` is the end of the
  /// voice's transcript, not of its sound.
  public final class CallTape {
    public static let sampleRate = 48000
    private static let headerSize = 44
    private static let bytesPerFrame = 4
    private let file: URL
    private let now: () -> Date
    private var audio: FileHandle?
    private var marks: FileHandle?
    private var bytes = 0

    public init(file: URL, now: @escaping () -> Date = Date.init) {
      self.file = file
      self.now = now
    }

    /// `<name>.marks.jsonl` beside the tape.
    public static func marksFile(for file: URL) -> URL {
      file.deletingPathExtension().appendingPathExtension("marks.jsonl")
    }

    private var seconds: Double {
      Double(bytes / Self.bytesPerFrame) / Double(Self.sampleRate)
    }

    /// Begins a new tape, over any earlier one.
    public func start() {
      bytes = 0
      let marksFile = Self.marksFile(for: file)
      FileManager.default.createFile(atPath: file.path, contents: Self.header(dataBytes: 0))
      FileManager.default.createFile(atPath: marksFile.path, contents: nil)
      audio = try? FileHandle(forWritingTo: file)
      marks = try? FileHandle(forWritingTo: marksFile)
    }

    /// Adds base64 of 16-bit little-endian interleaved stereo; anything else is dropped.
    public func append(_ chunk: String) {
      guard let audio, let data = Data(base64Encoded: chunk) else { return }
      let isFirst = bytes == 0
      _ = try? audio.seekToEnd()
      try? audio.write(contentsOf: data)
      bytes += data.count
      try? audio.seek(toOffset: 0)
      try? audio.write(contentsOf: Self.header(dataBytes: bytes))
      if isFirst { mark("began", wall: now().timeIntervalSince1970 - seconds) }
    }

    /// Notes something that happened now, at the tape's end.
    public func mark(_ name: String, index: Int? = nil) { mark(name, wall: nil, index: index) }

    private func mark(_ name: String, wall: Double?, index: Int? = nil) {
      var fields: [String: Any] = ["mark": name, "at": seconds]
      fields["wall"] = wall
      fields["index"] = index
      guard let line = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
      else { return }
      try? marks?.write(contentsOf: line + Data("\n".utf8))
    }

    private static func header(dataBytes: Int) -> Data {
      func little<Value: FixedWidthInteger>(_ value: Value) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
      }
      var data = Data("RIFF".utf8) + little(UInt32(headerSize - 8 + dataBytes))
      data += Data("WAVEfmt ".utf8) + little(UInt32(16)) + little(UInt16(1)) + little(UInt16(2))
      data += little(UInt32(sampleRate)) + little(UInt32(sampleRate * bytesPerFrame))
      data += little(UInt16(bytesPerFrame)) + little(UInt16(16))
      data += Data("data".utf8) + little(UInt32(dataBytes))
      return data
    }
  }
#endif
