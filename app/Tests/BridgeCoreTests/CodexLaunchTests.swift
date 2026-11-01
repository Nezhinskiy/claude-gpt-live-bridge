import Foundation
import Testing

@testable import BridgeCore

struct CodexLaunchTests {
  func features() throws -> String {
    String(decoding: try adrFixture("codex-features-list", extension: "txt"), as: UTF8.self)
  }

  @Test func argvPinsTheSandbox() {
    let argv = CodexLaunch.argv(disable: [])
    #expect(argv.first == "app-server")
    for value in [
      "sandbox_mode=\"read-only\"", "approval_policy=\"never\"", "web_search=\"disabled\"",
      "notify=[]", "model_reasoning_effort=\"low\"",
    ] {
      let index = argv.firstIndex(of: value)
      #expect(index.map { argv[$0 - 1] } == "-c", "\(value) follows -c")
    }
  }

  @Test func argvDisablesOnlyPresentFeatures() throws {
    let present = try CodexLaunch.presentFeatures(featuresListOutput: try features())
    #expect(present.contains("instant_interrupt"))  // a stage of two words
    #expect(!present.contains("js_repl"))  // stage `removed`
    let argv = CodexLaunch.argv(disable: CodexLaunch.wantDisabled.filter(present.contains))
    let pairs = zip(argv, argv.dropFirst()).filter { $0.0 == "--disable" }.map(\.1)
    #expect(pairs.contains("hooks") && pairs.contains("plugins") && pairs.contains("apps"))
    #expect(pairs.contains("shell_tool"))  // a tool the codex model could call
    #expect(!pairs.contains("goals"))  // codex no longer knows it
    #expect(!argv.contains("js_repl"))
  }

  /// Output codex might print after an upgrade or a crash must not launch with fewer
  /// `--disable` flags.
  @Test(arguments: ["", "garbage", "hooks stable maybe", "hooks true", "\n\n"])
  func unreadableFeaturesListFailsClosed(output: String) {
    #expect {
      try CodexLaunch.presentFeatures(featuresListOutput: output)
    } throws: { error in
      if case CodexProblem.protocolMismatch = error { true } else { false }
    }
  }

  @Test func missingCodexIsNotInstalled() async throws {
    let empty = try temporaryDirectory()
    #expect(CodexLaunch.locate(explicit: nil, searchPath: [empty.path]) == nil)
    await #expect(throws: CodexProblem.notInstalled) {
      try await JSONRPCClient.launchVerified(codex: empty.appending(path: "codex"), cwd: empty)
    }
    #expect(CodexProblem.notInstalled.sentence.contains("not installed"))
  }

  @Test func findsCodexOutsideLaunchdPath() throws {
    let fake = try FakeCodex()
    let found = CodexLaunch.locate(explicit: nil, searchPath: ["/usr/bin", fake.dir.path])
    #expect(found?.standardizedFileURL == fake.codex.standardizedFileURL)
    #expect(CodexLaunch.locate(explicit: fake.codex.path, searchPath: []) == fake.codex)
  }

  /// No real "plan without realtime" error has been observed (ADR 0001 (k)); these messages are
  /// constructed. The unknown one is the observed version error, shown verbatim.
  @Test func realtimeErrorsAreClassified() throws {
    let plan = CodexProblem.classify(realtimeError: "Realtime is not available on your plan")
    #expect(plan == .realtimeUnavailable)
    #expect(plan.sentence.contains("ChatGPT plan"))
    #expect(CodexProblem.classify(realtimeError: "401 Unauthorized: please log in") == .notLoggedIn)
    let observed = try #require(
      try adrJSON("realtime-error-version-unsupported")["params"]?["message"]?.string)
    #expect(CodexProblem.classify(realtimeError: observed) == .realtimeError(observed))
    #expect(CodexProblem.realtimeError(observed).sentence.contains(observed))
  }
}

/// A fake `codex` in its own directory, with canned JSON-RPC replies (`fake-app-server.sh`).
struct FakeCodex {
  let dir: URL
  var codex: URL { dir.appending(path: "codex") }

  init(loggedIn: Bool = true) throws {
    dir = try temporaryDirectory()
    let script = try #require(
      Bundle.module.url(
        forResource: "fake-app-server", withExtension: "sh", subdirectory: "Fixtures"))
    try FileManager.default.copyItem(at: script, to: codex)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
    try adrFixture("codex-features-list", extension: "txt").write(
      to: dir.appending(path: "features.txt"))
    try write("initialize.json", #"{"userAgent":"fake","codexHome":"/Users/example/.codex"}"#)
    let account = loggedIn ? #"{"type":"chatgpt","planType":"plus"}"# : "null"
    try write("account_read.json", #"{"account":\#(account),"requiresOpenaiAuth":true}"#)
  }

  func write(_ name: String, _ text: String) throws {
    try Data(text.utf8).write(to: dir.appending(path: name))
  }

  func log(_ name: String) -> String {
    (try? String(contentsOf: dir.appending(path: name), encoding: .utf8)) ?? ""
  }
}
