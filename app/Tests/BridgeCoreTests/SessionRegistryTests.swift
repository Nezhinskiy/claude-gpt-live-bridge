import Foundation
import Testing

@testable import BridgeCore

struct SessionRegistryTests {
  let time = TestTime()
  let registry: SessionRegistry
  let a = SessionID("00000000-0000-0000-0000-000000000001")
  let b = SessionID("11111111-0000-0000-0000-000000000002")
  let c = SessionID("22222222-0000-0000-0000-000000000003")

  init() { registry = SessionRegistry(time: time) }

  func join(_ id: SessionID, _ title: String = "Example session", autoContext: Bool = false) async {
    await registry.join(JoinBody(sessionId: id, title: title, autoContext: autoContext))
  }

  func request(_ n: Int) -> VoiceRequest {
    VoiceRequest(id: RequestID("request-\(n)"), brief: "Example request \(n)", transcript: [])
  }

  func answer(
    _ request: VoiceRequest, _ status: AnswerStatus = .ok, from session: SessionID? = nil
  ) -> AnswerBody {
    AnswerBody(sessionId: session ?? a, id: request.id, status: status, text: "done", reason: nil)
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
    #expect(delivery == Delivery(label: "Example session", status: .ok, text: "done"))
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
        Delivery(label: "Example session", status: .failed, text: "session closed")
      ])
    #expect(await registry.rows().map(\.sessionId) == [b])
    #expect(await registry.target == b)
  }

  @Test func requestTimesOutAfterTenMinutes() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    try await registry.enqueue(request(2), for: a)
    _ = try await registry.poll(a)
    time.advance(by: .seconds(599))
    _ = try await registry.poll(a)
    #expect(await registry.sweep() == [])
    time.advance(by: .seconds(1))
    _ = try await registry.poll(a)
    #expect(await registry.sweep() == [])  // request 1 was superseded by request 2
    #expect(try await registry.poll(a) == .request(request(2)))
    time.advance(by: .seconds(600))
    _ = try await registry.poll(a)
    #expect(
      await registry.sweep() == [
        Delivery(label: "Example session", status: .failed, text: "timed out")
      ])
  }

  @Test func leavingWithAnOpenRequestFailsIt() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    #expect(await registry.leave(a)?.text == "session left")
    #expect(await registry.target == nil)
  }

  @Test func becomingTargetWithAutoContextAsksForContext() async throws {
    await join(a)
    await join(b, "Other session", autoContext: true)
    #expect(try await registry.poll(b) == nil)
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
