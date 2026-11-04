import Foundation
import Testing

@testable import BridgeCore

struct UpdateRecordTests {
  func record(mod: ModOutcome) throws -> UpdateRecord {
    UpdateRecord(
      from: try #require(AppVersion("0.1.2")), to: try #require(AppVersion("0.1.3")), mod: mod,
      noticePosted: false)
  }

  @Test func aRecordRoundTrips() throws {
    let file = try temporaryDirectory().appending(path: "record.json")
    for mod in [ModOutcome.updated, .byHand(commands: UpdateRecord.byHandCommands)] {
      let written = try record(mod: mod)
      try written.write(file)
      #expect(UpdateRecord.read(file) == written)
    }
  }

  @Test func theByHandCommandsAreTheOnesTheUpdaterRuns() {
    #expect(
      UpdateRecord.byHandCommands == [
        "claude plugin marketplace update livebridge", "claude plugin update livebridge@livebridge",
      ])
  }

  @Test func aMissingRecordIsNil() throws {
    let file = try temporaryDirectory().appending(path: "record.json")
    #expect(UpdateRecord.read(file) == nil)
  }

  @Test func anUnreadableRecordIsNil() throws {
    let file = try temporaryDirectory().appending(path: "record.json")
    try Data("not json".utf8).write(to: file)
    #expect(UpdateRecord.read(file) == nil)
  }
}
