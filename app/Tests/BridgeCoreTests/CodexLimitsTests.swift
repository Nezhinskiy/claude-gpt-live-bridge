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
    #expect(
      got.windows == [
        LimitWindow(span: .minutes(300), usedPercent: 7, resetsAt: five),
        LimitWindow(span: .minutes(10080), usedPercent: 19, resetsAt: week),
      ])
    #expect(got.readAt == now && !got.isBlocked)
  }

  @Test func aReadClosesCodex() async throws {
    let rpc = try FakeRPC()
    await rpc.set(method, [codex(primary: slot(7, 300))])
    let got = try await CodexLimits.readOnce(launch: { rpc }, now: now)
    #expect(got.windows.map(\.span) == [.minutes(300)])
    #expect(await rpc.closes == 1)
  }

  @Test func aFailedReadClosesCodex() async throws {
    let rpc = try FakeRPC()
    await rpc.fail(method, with: .protocolMismatch("example"))
    await #expect(throws: CodexProblem.self) {
      try await CodexLimits.readOnce(launch: { rpc }, now: now)
    }
    #expect(await rpc.closes == 1)
  }

  @Test func aLaunchThatFailsIsAFailedRead() async throws {
    await #expect(throws: CodexProblem.self) {
      try await CodexLimits.readOnce(launch: { throw CodexProblem.notInstalled }, now: now)
    }
  }

  @Test func asksWithoutResetCreditDetails() async throws {
    let rpc = try FakeRPC()
    await rpc.set(method, [codex(primary: slot(7, 300))])
    _ = try await CodexLimits.read(client: rpc, now: now)
    #expect(await rpc.params(method) == [["excludeResetCreditDetails": true]])
  }

  @Test func aWeekInThePrimarySlotIsTheWeek() async throws {
    let got = try await read(codex(primary: slot(19, 10080)))
    #expect(got.windows.map(\.span) == [.minutes(10080)])
  }

  @Test func aWindowOfAnotherLengthShows() async throws {
    let got = try await read(codex(primary: slot(22, 240), secondary: slot(6, 43200)))
    #expect(got.windows.map(\.span) == [.minutes(240), .minutes(43200)])
    #expect(got.windows.first?.span.label == "4 h")
  }

  @Test func aLengthNearAKnownOneIsThatLength() async throws {
    for (minutes, want) in [(285.0, 300), (315, 300), (9576, 10080), (10584, 10080)] {
      let got = try await read(codex(primary: slot(5, minutes)))
      #expect(got.windows.map(\.span) == [.minutes(want)], "\(minutes) minutes")
    }
  }

  @Test func aWindowWithNoDurationShowsAsLimit() async throws {
    let got = try await read(codex(primary: slot(9, nil)))
    #expect(got.windows.map(\.span) == [.unknown])
  }

  @Test func aWindowWithNoPercentIsLeftOut() async throws {
    let noPercent: JSONValue = [
      "windowDurationMins": .number(300), "resetsAt": .number(1_800_003_600),
    ]
    let got = try await read(codex(primary: noPercent, secondary: slot(19, 10080)))
    #expect(got.windows.map(\.span) == [.minutes(10080)])
  }

  @Test func twoOfOneLengthKeepThePrimary() async throws {
    let got = try await read(codex(primary: slot(1, 300), secondary: slot(2, 300)))
    #expect(got.windows.map(\.usedPercent) == [1])
  }

  @Test func anUnknownExtraFieldChangesNothing() async throws {
    var bucket = try #require(bucket("codex", primary: slot(7, 300)).object)
    bucket["tertiary"] = slot(50, 60)
    bucket["somethingNew"] = ["a": .number(1)]
    let got = try await read(reply(byId: ["codex": .object(bucket)]))
    #expect(got.windows.map(\.usedPercent) == [7])
  }

  @Test func fallsBackToTheSingleBucket() async throws {
    for id: JSONValue in ["codex", .null] {
      let got = try await read(reply(single: bucket(id, primary: slot(7, 300))))
      #expect(got.windows.map(\.usedPercent) == [7])
    }
    let absent = try await read(reply(single: ["primary": slot(7, 300)]))
    #expect(absent.windows.map(\.usedPercent) == [7])
  }

  @Test func noBucketMapIsTheSingleBucket() async throws {
    let value: JSONValue = ["rateLimits": bucket("codex", primary: slot(7, 300))]
    #expect(value["rateLimitsByLimitId"] == nil)
    #expect(try await read(value).windows.map(\.usedPercent) == [7])
  }

  @Test func anotherBucketIsNotRead() async throws {
    let byId = reply(byId: ["other": bucket("other", primary: slot(7, 300))])
    let single = reply(single: bucket("other", primary: slot(7, 300)))
    for value in [byId, single] {
      let got = try await read(value)
      #expect(got.windows.isEmpty)
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
