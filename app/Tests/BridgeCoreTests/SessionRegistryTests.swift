import Foundation
import Testing

@testable import BridgeCore

extension Completion {
  /// What is to be said, if anything.
  var delivery: Delivery? {
    if case .delivery(let delivery) = self { delivery } else { nil }
  }
}

struct SessionRegistryTests {
  let time = TestTime()
  let registry: SessionRegistry
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")
  let c = SessionID(rawValue: "22222222-0000-0000-0000-000000000003")

  init() { registry = SessionRegistry(time: time) }

  func join(_ id: SessionID, _ title: String = "Example session", modVersion: String? = nil) async {
    try? await registry.join(JoinBody(sessionId: id, title: title, modVersion: modVersion))
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

  @Test func openRequestsCountQueuedAndInFlight() async throws {
    await join(a)
    #expect(await !registry.hasOpenRequests)
    let first = request(1)
    try await registry.enqueue(first, for: a)
    #expect(await registry.hasOpenRequests)
    _ = try await registry.poll(a)
    #expect(await registry.hasOpenRequests)
    _ = try await registry.complete(answer(first))
    #expect(await !registry.hasOpenRequests)
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
  /// until the owner joins it again every call from it is told it was removed (not "unknown",
  /// which the mod answers by joining again).
  @Test func removedSessionIsToldSoUntilTheOwnerJoinsItAgain() async throws {
    for id in [a, b, c] { await join(id, id.rawValue) }
    try await registry.enqueue(request(1), for: a)
    let delivery = await registry.remove(a)
    #expect(delivery?.status == .failed && delivery?.text == "session left")
    #expect(await registry.target == c)
    #expect(await registry.rows().map(\.sessionId) == [b, c])
    await #expect(throws: RegistryError.removedSession(a)) { try await registry.poll(a) }
    #expect(RegistryError.removedSession(a).httpStatus == 410)
    await #expect(throws: RegistryError.removedSession(a)) { try await registry.setTarget(a) }
    // the mod's own join, following a new title or reconnecting, does not undo the Remove
    await #expect(throws: RegistryError.removedSession(a)) {
      try await registry.join(JoinBody(sessionId: a, title: "Renamed"))
    }
    #expect(await registry.rows().map(\.sessionId) == [b, c])
    try await registry.join(JoinBody(sessionId: a, title: "Alpha", owner: true))  // `/live on`
    #expect(try await registry.poll(a) == nil)
  }

  /// A title is cut at join, so no label can crowd an answer out of its 2,000-character line.
  @Test func longTitleIsCut() async throws {
    await join(a, String(repeating: "Long title ", count: 300))
    let label = try #require(await registry.rows().first?.label)
    #expect(label.count == SessionRegistry.maxTitle)
    let line = AnswerShaper.forVoice("Done.", status: .ok, label: label).text
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
    #expect(try await registry.complete(answer(request(1))) == .superseded)
    _ = try await registry.poll(a)
    let delivery = try await registry.complete(answer(request(2))).delivery
    #expect(delivery == Delivery(session: a, label: "Example session", status: .ok, text: "done"))
  }

  /// While Claude waits on a question, the next handoff is its reply: it goes out at once, beside
  /// the request in flight, and that request's answer is still delivered.
  @Test func handoffWhileClaudeAsksIsTheReply() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    await registry.setActivity(ActivityBody(sessionId: a, state: .approval, question: "Which?"))
    try await registry.enqueue(request(2), for: a)
    #expect(try await registry.poll(a) == .reply(request(2), forRequest: request(1).id))
    #expect(try await registry.poll(a) == nil)
    #expect(try await registry.complete(answer(request(1))).delivery?.text == "done")
    // the question was answered: the next handoff is a request again
    try await registry.enqueue(request(3), for: a)
    #expect(try await registry.poll(a) == .request(request(3)))
  }

  /// A reply to a question the request in flight did not ask (a typed turn's) is itself the
  /// request in flight: its answer closes it.
  @Test func aReplyWithNothingInFlightGoesInFlight() async throws {
    await join(a)
    await registry.setActivity(ActivityBody(sessionId: a, state: .approval, question: "Which?"))
    try await registry.enqueue(request(2), for: a)
    #expect(try await registry.poll(a) == .reply(request(2), forRequest: request(2).id))
    #expect(await registry.hasOpenRequests)
    #expect(try await registry.complete(answer(request(2))).delivery?.text == "done")
    #expect(await !registry.hasOpenRequests)
  }

  /// With a request in flight the reply is for that request, which its answer still closes.
  @Test func aReplyLeavesARequestInFlightAlone() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    await registry.setActivity(ActivityBody(sessionId: a, state: .approval, question: "Which?"))
    try await registry.enqueue(request(2), for: a)
    #expect(try await registry.poll(a) == .reply(request(2), forRequest: request(1).id))
    await #expect(throws: RegistryError.unknownRequest(request(2).id)) {
      try await registry.complete(answer(request(2)))
    }
    #expect(try await registry.complete(answer(request(1))).delivery?.text == "done")
    #expect(await !registry.hasOpenRequests)
  }

  /// A request queued after the reply is the newer one: only its answer is delivered.
  @Test func aReplyLeavesLatestToANewerQueuedRequest() async throws {
    await join(a)
    await registry.setActivity(ActivityBody(sessionId: a, state: .approval, question: "Which?"))
    try await registry.enqueue(request(2), for: a)
    try await registry.enqueue(request(3), for: a)
    #expect(try await registry.poll(a) == .reply(request(2), forRequest: request(2).id))
    #expect(try await registry.complete(answer(request(2))) == .superseded)
    #expect(try await registry.poll(a) == .request(request(3)))
    #expect(try await registry.complete(answer(request(3))).delivery?.text == "done")
  }

  /// A question answered in Claude Code before the reply went out leaves that reply to go as a
  /// request of its own; an approval without a question takes no reply.
  @Test func replyOutlivingItsQuestionGoesAsARequest() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    await registry.setActivity(ActivityBody(sessionId: a, state: .approval, question: "Which?"))
    try await registry.enqueue(request(2), for: a)
    await registry.setActivity(ActivityBody(sessionId: a, state: .working))
    #expect(try await registry.poll(a) == nil)
    #expect(try await registry.complete(answer(request(1))) == .superseded)
    #expect(try await registry.poll(a) == .request(request(2)))
    await registry.setActivity(ActivityBody(sessionId: a, state: .approval))
    try await registry.enqueue(request(3), for: a)
    #expect(try await registry.poll(a) == nil)
  }

  @Test func updateDoesNotCloseTheRequest() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    #expect(try await registry.complete(answer(request(1), .update)).delivery?.status == .update)
    let question = try await registry.complete(answer(request(1), .question))
    #expect(question.delivery?.status == .question)
    // After the request closed, a later update is still tied to it.
    #expect(try await registry.complete(answer(request(1), .update)).delivery?.status == .update)
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

  /// A session whose mod is older than the app, or that names no version (a mod from before the
  /// field), is listed by its label, in the order the sessions joined.
  @Test func sessionsOnAnOlderModAreListed() async throws {
    let app = try #require(AppVersion("0.3.1"))
    await join(a, "Alpha", modVersion: "0.3.0")
    await join(b, "Beta", modVersion: "0.3.1")
    await join(c, "Gamma")
    #expect(await registry.labelsOnAnOlderMod(than: app) == ["Alpha", "Gamma"])
  }

  /// A session that joins again with a mod as new as the app leaves the list.
  @Test func aJoinWithACurrentModLeavesTheList() async throws {
    let app = try #require(AppVersion("0.3.1"))
    await join(a, "Alpha", modVersion: "0.3.0")
    await join(a, "Alpha", modVersion: "0.3.1")
    #expect(await registry.labelsOnAnOlderMod(than: app) == [])
  }

  /// `/clear` gives the session a new id: it keeps its place, the target and its request.
  @Test func joinReplacingAnIdMovesTheSession() async throws {
    await join(a, "Alpha")
    await join(b, "Beta")
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    try await registry.join(JoinBody(sessionId: c, title: "Alpha", replaces: a))
    #expect(await registry.target == c)
    #expect(await registry.rows().map(\.sessionId) == [c, b])
    let delivery = try await registry.complete(answer(request(1), from: c)).delivery
    #expect(delivery == Delivery(session: c, label: "Alpha", status: .ok, text: "done"))
  }

  /// A request in flight whose answer is withheld.
  func withheld() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    await registry.withholdAnswer(of: a)
  }

  /// Whatever the turn ended with, the request closes as failed and none of it goes on.
  @Test(arguments: [AnswerStatus.ok, .question, .failed])
  func aWithheldAnswerClosesAsFailed(status: AnswerStatus) async throws {
    try await withheld()
    let delivery = try #require(try await registry.complete(answer(request(1), status)).delivery)
    #expect(delivery.status == .failed)
    #expect(!delivery.text.contains("done"))
    #expect(await !registry.hasOpenRequests)
  }

  @Test func aWithheldUpdateIsDroppedAndClosesNothing() async throws {
    try await withheld()
    #expect(try await registry.complete(answer(request(1), .update)) == .dropped)
    #expect(await registry.hasOpenRequests)
    #expect(try await registry.complete(answer(request(1))).delivery?.status == .failed)
  }

  @Test func aWithheldSupersededAnswerIsDropped() async throws {
    try await withheld()
    try await registry.enqueue(request(2), for: a)
    #expect(try await registry.complete(answer(request(1))) == .dropped)
  }

  @Test func theMarkGoesWithItsRequest() async throws {
    try await withheld()
    _ = try await registry.complete(answer(request(1)))
    try await registry.enqueue(request(2), for: a)
    _ = try await registry.poll(a)
    #expect(try await registry.complete(answer(request(2))).delivery?.status == .ok)
  }

  @Test func withNothingInFlightNoRequestIsMarked() async throws {
    await join(a)
    await registry.withholdAnswer(of: a)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    #expect(try await registry.complete(answer(request(1))).delivery?.status == .ok)
  }

  @Test func aQueuedRequestIsNotMarked() async throws {
    try await withheld()
    try await registry.enqueue(request(2), for: a)
    _ = try await registry.complete(answer(request(1)))
    _ = try await registry.poll(a)
    #expect(try await registry.complete(answer(request(2))).delivery?.status == .ok)
  }

  @Test func theMarkFollowsClear() async throws {
    try await withheld()
    try await registry.join(JoinBody(sessionId: c, title: "Alpha", replaces: a))
    #expect(try await registry.complete(answer(request(1), from: c)).delivery?.status == .failed)
  }

  /// The same id joining again is a new session, with a new request.
  @Test func theMarkDoesNotOutliveItsSession() async throws {
    try await withheld()
    await registry.leave(a)
    await join(a)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    #expect(try await registry.complete(answer(request(1))).delivery?.status == .ok)
  }

  /// A closed withheld request takes no later update: it would be a follow-up of the same text.
  @Test func aWithheldRequestClosedTakesNoUpdate() async throws {
    try await withheld()
    _ = try await registry.complete(answer(request(1)))
    await #expect(throws: RegistryError.unknownRequest(request(1).id)) {
      try await registry.complete(answer(request(1), .update))
    }
  }

  @Test func aWithheldRequestTimedOutTakesNoUpdate() async throws {
    try await withheld()
    #expect(await run(600).map(\.text) == ["timed out"])
    await #expect(throws: RegistryError.unknownRequest(request(1).id)) {
      try await registry.complete(answer(request(1), .update))
    }
  }

  /// A background turn in the follow-up window, typed into: nothing is open to mark.
  @Test func withNothingOpenTheFollowUpEnds() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    _ = try await registry.complete(answer(request(1)))
    await registry.withholdAnswer(of: a)
    await #expect(throws: RegistryError.unknownRequest(request(1).id)) {
      try await registry.complete(answer(request(1), .update))
    }
  }

  /// A request waiting to go out is still the one whose answer is said.
  @Test func aQueuedRequestStaysTheLatest() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    _ = try await registry.poll(a)
    _ = try await registry.complete(answer(request(1)))
    try await registry.enqueue(request(2), for: a)
    await registry.withholdAnswer(of: a)
    _ = try await registry.poll(a)
    #expect(try await registry.complete(answer(request(2))).delivery?.status == .ok)
  }

  /// A withheld request a newer one superseded leaves that newer one the latest.
  @Test func aWithheldSupersededRequestLeavesTheNewerOneTheLatest() async throws {
    try await withheld()
    try await registry.enqueue(request(2), for: a)
    _ = try await registry.complete(answer(request(1)))
    _ = try await registry.poll(a)
    #expect(try await registry.complete(answer(request(2))).delivery?.status == .ok)
  }

  @Test func leavingWithAnOpenRequestFailsIt() async throws {
    await join(a)
    try await registry.enqueue(request(1), for: a)
    #expect(await registry.leave(a)?.text == "session left")
    #expect(await registry.target == nil)
  }

  /// Only a line the app opens asks for context (`Bridge.openLine`): a session that becomes the
  /// target is asked for nothing.
  @Test func becomingTargetAsksForNothing() async throws {
    await join(a)
    await join(b, "Other session")
    #expect(try await registry.poll(a) == nil)
    try await registry.setTarget(b)
    #expect(try await registry.poll(b) == nil)
    await registry.leave(b)  // the target falls back to Example session
    #expect(try await registry.poll(a) == nil)
  }

  @Test func activityShowsInRows() async {
    await join(a)
    await registry.setActivity(ActivityBody(sessionId: a, state: .approval))
    #expect(await registry.rows().map(\.activity) == [.approval])
  }
}
