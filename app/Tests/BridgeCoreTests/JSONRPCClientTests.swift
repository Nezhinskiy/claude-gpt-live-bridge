import Foundation
import Testing

@testable import BridgeCore

struct JSONRPCClientTests {
  @Test func launchVerifiedDisablesFeaturesAndInitializes() async throws {
    let fake = try FakeCodex()
    let client = try await JSONRPCClient.launchVerified(codex: fake.codex, cwd: fake.dir)
    let argv = fake.log("argv.log")
    #expect(argv.contains("--disable hooks") && argv.contains("--disable plugins"))
    #expect(!argv.contains("goals") && !argv.contains("js_repl"))
    let received = fake.log("received.log")
    #expect(received.contains(#""name":"claude-gpt-live-bridge""#))
    #expect(received.contains(#""experimentalApi":true"#))
    #expect(received.contains(#"{"method":"initialized"}"#))
    await client.close()
  }

  @Test func loggedOutCodexIsNotLoggedIn() async throws {
    let fake = try FakeCodex(loggedIn: false)
    await #expect(throws: CodexProblem.notLoggedIn) {
      try await JSONRPCClient.launchVerified(codex: fake.codex, cwd: fake.dir)
    }
    #expect(CodexProblem.notLoggedIn.sentence.contains("codex login"))
  }

  @Test func requestTimesOut() async throws {
    let fake = try FakeCodex()
    let client = JSONRPCClient(executable: fake.codex, arguments: ["app-server"], cwd: fake.dir)
    try await client.start()
    await #expect(throws: CodexProblem.self) {
      let _: JSONValue = try await client.request(
        "example/unanswered", JSONValue.object([:]), timeout: .milliseconds(200))
    }
    await client.close()
  }

  @Test func serverApprovalRequestIsDeclined() async throws {
    let fake = try FakeCodex()
    let ask = #"{"id":"srv-1","method":"item/commandExecution/requestApproval","params":{}}"#
    try fake.write("initialize.after", ask + "\n")
    let client = JSONRPCClient(executable: fake.codex, arguments: ["app-server"], cwd: fake.dir)
    try await client.start()
    let _: JSONValue = try await client.request(
      "initialize", JSONValue.object([:]), timeout: .seconds(5))
    var asks = await client.serverRequests.makeAsyncIterator()
    let request = try #require(await asks.next())
    #expect(request.method == "item/commandExecution/requestApproval")
    await client.reply(to: request, error: RPCError(code: -32000, message: "declined"))
    #expect(await eventually { fake.log("received.log").contains(#""error":{"code":-32000"#) })
    #expect(fake.log("received.log").contains(#""id":"srv-1""#))
    await client.close()
  }

  @Test func closeKillsProcessGroup() async throws {
    let fake = try FakeCodex()
    let client = JSONRPCClient(executable: fake.codex, arguments: ["app-server"], cwd: fake.dir)
    try await client.start()
    #expect(
      await eventually { Int32(fake.log("child.pid").trimmingCharacters(in: .newlines)) != nil })
    let child = try #require(Int32(fake.log("child.pid").trimmingCharacters(in: .newlines)))
    #expect(kill(child, 0) == 0)
    await client.close()
    #expect(await eventually { kill(child, 0) != 0 })
  }
}
