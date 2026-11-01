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

  /// Every feature codex lists is turned off but the allowed ones, also one this app has
  /// never heard of; a `removed` one is left alone, as `--disable` no longer changes it.
  @Test func argvDisablesEveryListedFeatureButTheAllowed() throws {
    let listed =
      try features() + "brand_new_tool                           stable             true\n"
    let present = try CodexLaunch.presentFeatures(featuresListOutput: listed)
    #expect(present.isSuperset(of: ["instant_interrupt", "web_search_cached", "brand_new_tool"]))
    #expect(present.isDisjoint(with: ["js_repl", "realtime_conversation"]))
    #expect(CodexLaunch.allowed.isSubset(of: present))
  }

  @Test func launchDisablesFeaturesAndInitializes() async throws {
    let fake = try FakeCodex()
    let client = try await CodexLaunch.launch(codex: fake.codex, cwd: fake.dir)
    let present = try CodexLaunch.presentFeatures(featuresListOutput: try features())
    let argv = fake.log("argv.log").split(whereSeparator: \.isWhitespace).map(String.init)
    let disabled = zip(argv, argv.dropFirst()).filter { $0.0 == "--disable" }.map(\.1)
    #expect(Set(disabled) == present.subtracting(CodexLaunch.allowed))
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
      try await CodexLaunch.launch(
        codex: fake.codex, cwd: fake.dir, searchPath: ["/usr/bin", "/bin"])
    }
    let client = try await CodexLaunch.launch(
      codex: fake.codex, cwd: fake.dir, searchPath: [fake.bin.path, "/usr/bin", "/bin"])
    await client.close()
  }

  @Test func loggedOutCodexIsNotLoggedIn() async throws {
    let fake = try FakeCodex(loggedIn: false)
    await #expect(throws: CodexProblem.notLoggedIn) {
      try await CodexLaunch.launch(codex: fake.codex, cwd: fake.dir)
    }
  }

  /// A codex that hangs on `features list` cannot hold Start up for ever.
  @Test func hungFeaturesListGivesUp() async throws {
    let fake = try FakeCodex()
    try fake.write("features.hang", "")
    let start = ContinuousClock.now
    await #expect(throws: CodexProblem.self) {
      try await CodexLaunch.launch(
        codex: fake.codex, cwd: fake.dir, probeTimeout: .milliseconds(300))
    }
    #expect(ContinuousClock.now - start < .seconds(5))
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
      try await CodexLaunch.launch(codex: empty.appending(path: "codex"), cwd: empty)
    }
  }

  @Test func findsCodexOutsideLaunchdPath() throws {
    let fake = try FakeCodex()
    let found = CodexLaunch.locate(searchPath: ["/usr/bin", fake.dir.path])
    #expect(found?.standardizedFileURL == fake.codex.standardizedFileURL)
  }

  /// The PATH comes from the user's own shell, read as a Terminal window would start it; what
  /// its start-up files print is skipped, and a shell that hangs gives up after the timeout.
  @Test func searchPathComesFromTheUserShell() async throws {
    let dir = try temporaryDirectory()
    let shell = dir.appending(path: "shell")
    try Data("#!/bin/sh\necho 'Welcome back'\nPATH=/example/bin:/usr/bin:/bin\neval \"$4\"\n".utf8)
      .write(to: shell)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
    #expect(await CodexLaunch.shellPath(shell.path) == ["/example/bin", "/usr/bin", "/bin"])
    try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: shell)
    let start = ContinuousClock.now
    #expect(await CodexLaunch.shellPath(shell.path, timeout: .milliseconds(300)).isEmpty)
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
