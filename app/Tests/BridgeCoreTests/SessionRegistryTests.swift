import Foundation
import Testing

@testable import BridgeCore

struct SessionRegistryTests {
  let time = TestTime()
  let registry: SessionRegistry
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")
  let c = SessionID(rawValue: "22222222-0000-0000-0000-000000000003")

  init() { registry = SessionRegistry(time: time) }

  func join(_ id: SessionID, _ title: String = "Example session") async {
    await registry.join(JoinBody(sessionId: id, title: title))
  }

  func request(_ n: Int) -> VoiceRequest {
    VoiceRequest(
      id: RequestID(rawValue: "request-\(n)"), brief: "Example request \(n)", transcript: [])
  }

  func answer(
    _ request: VoiceRequest, _ status: AnswerStatus = .ok, from session: SessionID? = nil
  ) -> AnswerBody {
    AnswerBody(sessionId: session ?? a, id: request.id, status: status, text: "done", reason: nil)
  }

  /// Sweeps once a second for `seconds` while `a` and `b` poll; what the sweeps delivered.
  func run(_ seconds: Int) async -> [Delivery] {
    var deliveries: [Delivery] = []
    for _ in 0..<seconds {
      time.advance(by: .seconds(1))
      for id in [a, b] { _ = try? await registry.poll(id) }
      deliveries += await registry.sweep()
    }
    return deliveries
  }

  @Test func firstJoinBecomesTarget() async {
    await join(a, "Alpha")
    await join(b, "Beta")
    #expect(await registry.target == a)
    #expect(await registry.rows().map(\.isTarget) == [true, false])
  }

  @Test func leavingTargetMovesTargetToMostRecentlyJoined() async {
    for id in [a, b, c] { await join(id, id.rawValue) }
    await registry.leave(a)
    #expect(await registry.target == c)
    #expect(await registry.rows().map(\.sessionId) == [b, c])
  }

  /// The menu's ×: the session is forgotten, its open request fails as "session left", and
  /// until it joins again every call from it is told it was removed (not "unknown", which the
  /// mod answers by joining again).
  @Test func removedSessionIsToldSoUntilItJoinsAgain() async throws {
    for id in [a, b, c] { await join(id, id.rawValue) }
    try await registry.enqueue(request(1), for: a)
    let delivery = await registry.remove(a)
    #expect(delivery?.status == .failed && delivery?.text == "session left")
    #expect(await registry.target == c)
    #expect(await registry.rows().map(\.sessionId) == [b, c])
    await #expect(throws: RegistryError.removedSession(a)) { try await registry.poll(a) }
    #expect(RegistryError.removedSession(a).httpStatus == 410)
    await #expect(throws: RegistryError.removedSession(a)) { try await registry.setTarget(a) }
    await join(a, "Alpha")
    #expect(try await registry.poll(a) == nil)
  }

  /// A title is cut at join, so no label can crowd an answer out of its 2,000-character line.
  @Test func longTitleIsCut() async throws {
    await join(a, String(repeating: "Long title ", count: 300))
    let label = try #require(await registry.rows().first?.label)
    #expect(label.count == SessionRegistry.maxTitle)
    let line = AnswerShaper.forVoice("Done.", status: .ok, label: label)
    #expect(line.hasSuffix(": Done.") && line.count <= AnswerShaper.maxCharacters)
  }

  @Test func rejoinRenamesWithoutDuplicating() async {
    await join(a, "Alpha")
    await join(a, "Renamed")
    #expect(await registry.rows().map(\.label) == ["Renamed"])
  }

  @Test func oneRequestInFlightPerSession() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    try await registry.enqueue(request(2), for: a)
    #expect(try await registry.poll(a) == .request(request(1)))
    #expect(try await registry.poll(a) == nil)
    _ = try await registry.complete(answer(request(1)))
    #expect(try await registry.poll(a) == .request(request(2)))
  }

  @Test func completeUnknownIdThrowsConflict() async throws {
    await join(a)
    await #expect(throws: RegistryError.unknownRequest(request(1).id)) {
      try await registry.complete(answer(request(1)))
    }
    #expect(RegistryError.unknownRequest(request(1).id).httpStatus == 409)
    await #expect(throws: RegistryError.unknownSession(b)) {
      try await registry.complete(answer(request(1), from: b))
    }
    #expect(RegistryError.unknownSession(b).httpStatus == 404)
  }

  @Test func supersededAnswerIsNotDelivered() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    try await registry.enqueue(request(2), for: a)
    #expect(try await registry.complete(answer(request(1))) == nil)
    _ = try await registry.poll(a)
    let delivery = try await registry.complete(answer(request(2)))
    #expect(delivery == Delivery(session: a, label: "Example session", status: .ok, text: "done"))
  }

  @Test func updateDoesNotCloseTheRequest() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    #expect(try await registry.complete(answer(request(1), .update))?.status == .update)
    #expect(try await registry.complete(answer(request(1), .question))?.status == .question)
    // After the request closed, a later update is still tied to it.
    #expect(try await registry.complete(answer(request(1), .update))?.status == .update)
    await #expect(throws: RegistryError.self) { try await registry.complete(answer(request(1))) }
  }

  @Test func silentSessionExpiresAndFailsItsRequest() async throws {
    await join(a)
    await join(b, "Other session")
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    time.advance(by: .seconds(4))
    _ = try await registry.poll(b)
    #expect(await registry.sweep() == [])
    time.advance(by: .seconds(1))
    #expect(
      await registry.sweep() == [
        Delivery(session: a, label: "Example session", status: .failed, text: "session closed")
      ])
    #expect(await registry.rows().map(\.sessionId) == [b])
    #expect(await registry.target == b)
  }

  @Test func requestTimesOutAfterTenMinutes() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    try await registry.enqueue(request(2), for: a)
    _ = try await registry.poll(a)
    #expect(await run(600) == [])  // request 1 was superseded by request 2
    #expect(try await registry.poll(a) == .request(request(2)))
    #expect(await run(599) == [])
    #expect(await run(1) == [timedOut])
  }

  var timedOut: Delivery {
    Delivery(session: a, label: "Example session", status: .failed, text: "timed out")
  }

  /// The Mac slept: no mod polled and no sweep ran, which is not a session going quiet.
  @Test func sleepNeitherExpiresSessionsNorFailsRequests() async throws {
    await join(a)
    await join(b, "Other session")
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    _ = try await registry.poll(b)
    #expect(await run(590) == [])
    time.advance(by: .seconds(3600))
    #expect(await registry.sweep() == [])
    #expect(await registry.rows().map(\.sessionId) == [a, b])
    #expect(await run(9) == [])
    #expect(await run(1) == [timedOut])  // ten minutes awake in all
  }

  /// `/clear` gives the session a new id: it keeps its place, the target and its request.
  @Test func joinReplacingAnIdMovesTheSession() async throws {
    await join(a, "Alpha")
    await join(b, "Beta")
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    await registry.join(JoinBody(sessionId: c, title: "Alpha", replaces: a))
    #expect(await registry.target == c)
    #expect(await registry.rows().map(\.sessionId) == [c, b])
    let delivery = try await registry.complete(answer(request(1), from: c))
    #expect(delivery == Delivery(session: c, label: "Alpha", status: .ok, text: "done"))
  }

  @Test func leavingWithAnOpenRequestFailsIt() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    #expect(await registry.leave(a)?.text == "session left")
    #expect(await registry.target == nil)
  }

  /// The app's own setting decides.
  /// Settings' automatic context is read each time a session becomes the target.
  @Test func becomingTargetWithAutoContextAsksForContext() async throws {
    let settings = SettingsStore(file: nil)
    let registry = SessionRegistry(time: time, autoContext: { settings.current.autoContext })
    await registry.join(JoinBody(sessionId: a, title: "Example session"))
    #expect(try await registry.poll(a) == nil)  // the setting is off
    settings.update { $0.autoContext = true }
    await registry.join(JoinBody(sessionId: b, title: "Other session"))
    #expect(try await registry.poll(b) == nil)  // not the target
    try await registry.setTarget(b)
    #expect(try await registry.poll(b) == .context)
    #expect(try await registry.poll(b) == nil)
    await registry.requestContext(for: a)
    #expect(try await registry.poll(a) == .context)
  }

  @Test func activityShowsInRows() async {
    await join(a)
    await registry.setActivity(ActivityBody(sessionId: a, state: .approval))
    #expect(await registry.rows().map(\.activity) == [.approval])
  }
}
