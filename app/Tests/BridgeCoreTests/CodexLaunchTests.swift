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
    #expect(CodexLaunch.locate(searchPath: [empty.path]) == nil)
    await #expect(throws: CodexProblem.notInstalled) {
      try await JSONRPCClient.launchVerified(codex: empty.appending(path: "codex"), cwd: empty)
    }
    #expect(CodexProblem.notInstalled.sentence.contains("not installed"))
  }

  @Test func findsCodexOutsideLaunchdPath() throws {
    let fake = try FakeCodex()
    let found = CodexLaunch.locate(searchPath: ["/usr/bin", fake.dir.path])
    #expect(found?.standardizedFileURL == fake.codex.standardizedFileURL)
  }

  /// The PATH comes from the user's own shell, read as a Terminal window would start it; what
  /// its start-up files print is skipped, and a shell that hangs gives up after the timeout.
  @Test func searchPathComesFromTheUserShell() throws {
    let dir = try temporaryDirectory()
    let shell = dir.appending(path: "shell")
    try Data("#!/bin/sh\necho 'Welcome back'\nPATH=/example/bin:/usr/bin:/bin\neval \"$4\"\n".utf8)
      .write(to: shell)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
    #expect(CodexLaunch.shellPath(shell.path) == ["/example/bin", "/usr/bin", "/bin"])
    try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: shell)
    let start = ContinuousClock.now
    #expect(CodexLaunch.shellPath(shell.path, timeout: .milliseconds(300)).isEmpty)
    #expect(ContinuousClock.now - start < .seconds(5))
  }

  /// No real "plan without realtime" error has been observed (ADR 0001 (k)); these messages are
  /// constructed. codex's own words stay in every sentence, so a wrong hint still shows the cause.
  @Test func realtimeErrorsKeepCodexWordsWithAHint() throws {
    let plan = CodexProblem.realtimeError("Realtime is not available on your plan").sentence
    #expect(plan.contains("not available on your plan") && plan.contains("ChatGPT plan"))
    let login = CodexProblem.realtimeError("401 Unauthorized: please log in").sentence
    #expect(login.contains("401 Unauthorized") && login.contains("codex login"))
    for message in ["503 Service Unavailable", "The planned explanation was cut short"] {
      #expect(!CodexProblem.realtimeError(message).sentence.contains("plan may"), "\(message)")
    }
    let observed = try #require(
      try adrJSON("realtime-error-version-unsupported")["params"]?["message"]?.string)
    #expect(
      CodexProblem.realtimeError(observed).sentence
        == "Realtime voice failed (codex said: \(observed)).")
  }

  /// Every error the popover can show reads as a sentence that names its cause.
  @Test func errorsReadAsSentences() {
    let long = PathsError.socketPathTooLong(String(repeating: "a", count: 120))
    #expect(
      long.localizedDescription.contains("120 bytes") && long.localizedDescription.contains("103"))
    #expect(ServerError.socketInUse("/example").localizedDescription.contains("another copy"))
    let refused = RPCError(code: -32601, message: "method not found")
    #expect(refused.localizedDescription.contains("method not found"))
    #expect(CodexProblem.notInstalled.localizedDescription == CodexProblem.notInstalled.sentence)
    #expect(CodexProblem.exited(127).sentence.contains("runtime"))
  }
}

/// A fake `codex` in its own directory, with canned JSON-RPC replies (`fake-app-server.sh`).
struct FakeCodex {
  let dir: URL
  var codex: URL { dir.appending(path: "codex") }

  /// The directory of `interpreter`, which `codex` runs on through `/usr/bin/env`.
  var bin: URL { dir.appending(path: "bin") }

  /// `interpreter` makes `codex` a `#!/usr/bin/env <interpreter>` script, as an npm install is.
  init(loggedIn: Bool = true, interpreter: String? = nil) throws {
    dir = try temporaryDirectory()
    let script = try #require(
      Bundle.module.url(
        forResource: "fake-app-server", withExtension: "sh", subdirectory: "Fixtures"))
    var text = try String(contentsOf: script, encoding: .utf8)
    if let interpreter {
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      try Self.executable(bin.appending(path: interpreter), "#!/bin/sh\nexec /bin/sh \"$@\"\n")
      text = "#!/usr/bin/env \(interpreter)\n" + text
    }
    try Self.executable(codex, text)
    try adrFixture("codex-features-list", extension: "txt").write(
      to: dir.appending(path: "features.txt"))
    try write("initialize.json", #"{"userAgent":"fake","codexHome":"/Users/example/.codex"}"#)
    let account =
      loggedIn ? try #require(adrJSON("account-read-result")["result"]) : ["account": .null]
    try write(
      "account_read.json", String(decoding: try JSONEncoder().encode(account), as: UTF8.self))
  }

  static func executable(_ url: URL, _ text: String) throws {
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  func write(_ name: String, _ text: String) throws {
    try Data(text.utf8).write(to: dir.appending(path: name))
  }

  func log(_ name: String) -> String {
    (try? String(contentsOf: dir.appending(path: name), encoding: .utf8)) ?? ""
  }
}
