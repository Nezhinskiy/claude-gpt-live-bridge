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

  /// An npm install of codex is a `#!/usr/bin/env node` script: its runtime is found only
  /// through the search path, which the app passes on to codex.
  @Test func launchPassesTheSearchPathToCodex() async throws {
    let fake = try FakeCodex(interpreter: "fake-node")
    await #expect(throws: CodexProblem.exited(127)) {
      try await JSONRPCClient.launchVerified(
        codex: fake.codex, cwd: fake.dir, searchPath: ["/usr/bin", "/bin"])
    }
    let client = try await JSONRPCClient.launchVerified(
      codex: fake.codex, cwd: fake.dir, searchPath: [fake.bin.path, "/usr/bin", "/bin"])
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

  /// A client waiting on its own idle codex does not hold up another client's replies (the
  /// owner's "no reply to initialize" when a second codex was started).
  @Test func eachClientGetsItsRepliesWhileTheOtherIsIdle() async throws {
    let (first, second) = (try FakeCodex(), try FakeCodex())
    let clients = [first, second].map {
      JSONRPCClient(executable: $0.codex, arguments: ["app-server"], cwd: $0.dir)
    }
    for client in clients { try await client.start() }
    for client in clients.reversed() + clients {
      let _: JSONValue = try await client.request(
        "initialize", JSONValue.object([:]), timeout: .seconds(5))
    }
    for client in clients { await client.close() }
  }

  /// Only `\n` ends a message: U+2028 inside a JSON string is part of it.
  @Test func onlyNewlineEndsAMessage() async throws {
    let fake = try FakeCodex()
    try fake.write("initialize.json", "{\"userAgent\":\"a\u{2028}b\u{85}c\"}")
    let client = JSONRPCClient(executable: fake.codex, arguments: ["app-server"], cwd: fake.dir)
    try await client.start()
    let reply: JSONValue = try await client.request(
      "initialize", JSONValue.object([:]), timeout: .seconds(5))
    #expect(reply["userAgent"] == "a\u{2028}b\u{85}c")
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
