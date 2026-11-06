import Foundation
import Testing

@testable import BridgeCore

@Suite struct CallTapeTests {
  let directory: URL
  let file: URL
  /// One stereo frame's bytes, little-endian: left 1, right 2.
  static let frame = Data([1, 0, 2, 0])

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "call-tape-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    file = directory.appending(path: "call.wav")
  }

  private func chunk(frames: Int) -> String {
    Data((0..<frames).flatMap { _ in Self.frame }).base64EncodedString()
  }

  private func uint32(_ data: Data, at offset: Int) -> UInt32 {
    data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
  }

  private func marks() throws -> [[String: Any]] {
    try String(contentsOf: CallTape.marksFile(for: file), encoding: .utf8)
      .split(separator: "\n")
      .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
  }

  @Test func theFileIsAPlayableStereoWaveAfterEveryChunk() throws {
    let tape = CallTape(file: file)
    tape.start()
    tape.append(chunk(frames: 2))
    tape.append(chunk(frames: 1))
    let data = try Data(contentsOf: file)
    #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
    #expect(uint32(data, at: 4) == UInt32(data.count - 8))
    #expect(uint32(data, at: 24) == 48000)
    #expect(data[22] == 2)
    #expect(uint32(data, at: 40) == 12)
    #expect(data.count == 44 + 12)
    #expect(data.suffix(4) == Self.frame)
  }

  @Test func startingAgainBeginsANewTape() throws {
    let tape = CallTape(file: file)
    tape.start()
    tape.append(chunk(frames: 4))
    tape.start()
    tape.append(chunk(frames: 1))
    #expect(try Data(contentsOf: file).count == 44 + 4)
  }

  @Test func aMarkCarriesTheTimeOnTheTape() throws {
    let tape = CallTape(file: file)
    tape.start()
    tape.append(chunk(frames: 24000))
    tape.mark("handoff")
    let last = try #require(try marks().last)
    #expect(last["mark"] as? String == "handoff")
    #expect(last["at"] as? Double == 0.5)
  }

  @Test func theFirstChunkSaysWhenTheTapeBeganOnTheWallClock() throws {
    let tape = CallTape(file: file, now: { Date(timeIntervalSince1970: 1000) })
    tape.start()
    tape.append(chunk(frames: 24000))
    tape.append(chunk(frames: 24000))
    let began = try marks().filter { $0["mark"] as? String == "began" }
    #expect(began.count == 1)
    #expect(began.first?["wall"] as? Double == 999.5)
  }

  @Test func aChunkThatIsNotBase64IsDropped() throws {
    let tape = CallTape(file: file)
    tape.start()
    tape.append("not base64!")
    #expect(try Data(contentsOf: file).count == 44)
  }
}
