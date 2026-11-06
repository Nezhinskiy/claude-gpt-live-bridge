import Foundation
import Testing

@testable import BridgeCore

struct CodexLimitsTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let method = "account/rateLimits/read"

  func slot(_ percent: Double, _ minutes: Double?, _ reset: Double? = 1_800_003_600) -> JSONValue {
    var slot: [String: JSONValue] = ["usedPercent": .number(percent)]
    if let minutes { slot["windowDurationMins"] = .number(minutes) }
    if let reset { slot["resetsAt"] = .number(reset) }
    return .object(slot)
  }

  func bucket(_ id: JSONValue, primary: JSONValue, secondary: JSONValue = .null) -> JSONValue {
    ["limitId": id, "primary": primary, "secondary": secondary]
  }

  func reply(
    byId: JSONValue = .null, single: JSONValue = .null, allowed: JSONValue = .null
  ) -> JSONValue {
    [
      "ordinaryUsageAllowed": allowed, "rateLimits": single, "rateLimitsByLimitId": byId,
      "accountId": "00000000-0000-0000-0000-000000000001",
    ]
  }

  func read(_ reply: JSONValue) async throws -> UsageLimits {
    let rpc = try FakeRPC()
    await rpc.set(method, [reply])
    return try await CodexLimits.read(client: rpc, now: now)
  }

  func codex(primary: JSONValue, secondary: JSONValue = .null) -> JSONValue {
    reply(byId: ["codex": bucket("codex", primary: primary, secondary: secondary)])
  }

  @Test func readsBothWindowsOfTheCodexBucket() async throws {
    let got = try await read(
      codex(primary: slot(7, 300, 1_800_003_600), secondary: slot(19, 10080, 1_800_500_000)))
    let five = Date(timeIntervalSince1970: 1_800_003_600)
    let week = Date(timeIntervalSince1970: 1_800_500_000)
    #expect(got.fiveHour == LimitWindow(usedPercent: 7, resetsAt: five))
    #expect(got.week == LimitWindow(usedPercent: 19, resetsAt: week))
    #expect(got.readAt == now && !got.isBlocked)
  }

  @Test func asksWithoutResetCreditDetails() async throws {
    let rpc = try FakeRPC()
    await rpc.set(method, [codex(primary: slot(7, 300))])
    _ = try await CodexLimits.read(client: rpc, now: now)
    #expect(await rpc.params(method) == [["excludeResetCreditDetails": true]])
  }

  @Test func aWeekInThePrimarySlotIsTheWeek() async throws {
    let got = try await read(codex(primary: slot(19, 10080)))
    #expect(got.week?.usedPercent == 19)
    #expect(got.fiveHour == nil)
  }

  @Test func aWindowOfAnotherLengthIsIgnored() async throws {
    let other = try await read(codex(primary: slot(5, 43200), secondary: slot(6, 43200)))
    #expect(other.fiveHour == nil && other.week == nil)
    for (minutes, counts) in [(285.0, true), (315, true), (284, false), (316, false)] {
      let got = try await read(codex(primary: slot(5, minutes)))
      #expect((got.fiveHour != nil) == counts, "\(minutes) minutes")
      #expect(got.week == nil)
    }
    for (minutes, counts) in [(9576.0, true), (10584, true), (9575, false), (10585, false)] {
      let got = try await read(codex(primary: slot(5, minutes)))
      #expect((got.week != nil) == counts, "\(minutes) minutes")
      #expect(got.fiveHour == nil)
    }
  }

  @Test func bothSlotsOfOneLengthLeaveThePrimary() async throws {
    let got = try await read(codex(primary: slot(1, 300), secondary: slot(2, 300)))
    #expect(got.fiveHour?.usedPercent == 1)
  }

  @Test func fallsBackToTheSingleBucket() async throws {
    for id: JSONValue in ["codex", .null] {
      let got = try await read(reply(single: bucket(id, primary: slot(7, 300))))
      #expect(got.fiveHour?.usedPercent == 7)
    }
    let absent = try await read(reply(single: ["primary": slot(7, 300)]))
    #expect(absent.fiveHour?.usedPercent == 7)
  }

  @Test func anotherBucketIsNotRead() async throws {
    let byId = reply(byId: ["other": bucket("other", primary: slot(7, 300))])
    let single = reply(single: bucket("other", primary: slot(7, 300)))
    for value in [byId, single] {
      let got = try await read(value)
      #expect(got.fiveHour == nil && got.week == nil)
    }
  }

  @Test func ordinaryUsageNotAllowedIsABlock() async throws {
    let window = codex(primary: slot(7, 300))
    func blocked(_ allowed: JSONValue) async throws -> Bool {
      var value = try #require(window.object)
      value["ordinaryUsageAllowed"] = allowed
      return try await read(.object(value)).isBlocked
    }
    #expect(try await blocked(false))
    #expect(try await !blocked(true))
    #expect(try await !blocked(.null))
  }

  @Test func aReplyThatIsNotAnObjectIsAProblem() async throws {
    await #expect(throws: CodexProblem.self) { try await read("nonsense") }
    await #expect(throws: CodexProblem.self) { try await read(["a"]) }
  }
}
