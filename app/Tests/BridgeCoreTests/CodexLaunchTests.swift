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
      + CodexLaunch.allowed.map { "\($0)                      stable             false\n" }.joined()
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
    #expect(received.contains(#""name":"livebridge""#))
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

  /// The updater finds `gh` and `claude` the way the voice finds `codex`.
  @Test func locateFindsTheNamedProgram() throws {
    let dir = try temporaryDirectory()
    let gh = dir.appending(path: "gh")
    try FakeCodex.executable(gh, "#!/bin/sh\n")
    #expect(CodexLaunch.locate("gh", searchPath: [dir.path])?.standardizedFileURL == gh)
    #expect(CodexLaunch.locate(searchPath: [dir.path]) == nil)
    try FakeCodex.executable(dir.appending(path: "codex"), "#!/bin/sh\n")
    #expect(CodexLaunch.locate(searchPath: [dir.path])?.lastPathComponent == "codex")
  }

  /// `codesign -dvvv` reports on standard error, so a caller can have it in the output; codex's
  /// callers keep only standard output.
  @Test func runKeepsStandardErrorOnlyWhenAsked() async throws {
    let script = ["-c", "echo out; echo err >&2"]
    let merged = try await CodexLaunch.run(
      URL(filePath: "/bin/sh"), script, mergingErrors: true, timeout: .seconds(10))
    #expect(merged?.output.contains("err") == true && merged?.output.contains("out") == true)
    let plain = try await CodexLaunch.run(URL(filePath: "/bin/sh"), script, timeout: .seconds(10))
    #expect(plain?.output == "out\n")
  }

  /// `claude` runs in the data folder, so no project's settings apply to it.
  @Test func runStartsInTheGivenDirectory() async throws {
    let dir = try temporaryDirectory()
    let answer = try await CodexLaunch.run(
      URL(filePath: "/bin/pwd"), ["-P"], cwd: dir, timeout: .seconds(10))
    let real = try #require(realpath(dir.path, nil))
    defer { free(real) }
    #expect(answer?.output == String(cString: real) + "\n")
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

  /// codex's own sentences at `rust-v0.166.0` (`codex-rs/protocol/src/error.rs`): this path carries
  /// no error code, so its wording is the only signal.
  static let spent = [
    "You’ve hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more "
      + "credits or try again at 11:33 PM.",
    "You've hit your usage limit. Try again later.",
    "You’ve hit your usage limit for example-model. Switch to another model now, or try again "
      + "later.",
    "You hit your spend cap set in your workspace. Increase your spend cap to continue.",
    "You hit your spend cap set by the owner of your workspace. Ask an owner to increase your "
      + "spend cap to continue.",
    "Your workspace is out of credits. Add credits to continue.",
    "Your workspace is out of credits. Ask your workspace owner to refill in order to continue.",
    "Quota exceeded. Check your plan and billing details.",
  ]
  static let refused = [
    "exceeded retry limit, last status: 429 Too Many Requests",
    "To use Codex with your ChatGPT plan, upgrade to Plus: https://chatgpt.com/explore/plus",
  ]

  @Test(arguments: spent) func aSpentBudgetIsSaidAsAUsageLimit(_ message: String) {
    let problem = Problem.codex(.realtimeError(message))
    #expect(problem.pausesCall)
    #expect(problem.sentence.hasPrefix("Your ChatGPT plan's usage limit is reached"))
    #expect(problem.sentence.contains(message))
  }

  /// Nothing shows these spent a budget: the sentence does not say they did.
  @Test(arguments: refused) func aRefusalIsNotSaidAsAUsageLimit(_ message: String) {
    let problem = Problem.codex(.realtimeError(message))
    #expect(problem.pausesCall)
    #expect(problem.sentence.hasPrefix("ChatGPT did not allow the voice"))
    #expect(problem.sentence.contains(message))
  }

  @Test func thePageSaysItIsNoUsageLimit() {
    let problem = Problem.lineRefused("Unable to verify usage availability.")
    #expect(problem.sentence.hasPrefix("ChatGPT did not allow the voice"))
    #expect(problem.sentence.contains("Unable to verify usage availability."))
  }

  /// The service's own names for a spent budget, in codex's list and in the two reports.
  @Test(arguments: [
    "usage_check_failed", "usage_limit_reached", "insufficient_quota", "credit_balance_exhausted",
    "workspace_spend_limit_exceeded",
  ]) func aCodeAboutUsageIsARefusal(_ code: String) {
    #expect(Problem.refusal(code: code, message: "No.") == .lineRefused("No."))
  }

  @Test func anotherCodeIsNoRefusal() {
    #expect(Problem.refusal(code: "invalid_request", message: "No.") == nil)
  }

  @Test func otherErrorsLeaveTheCallOn() {
    for message in ["503 Service Unavailable", "AVAS realtime calls require realtime v1 or v3"] {
      #expect(!Problem.codex(.realtimeError(message)).pausesCall, "\(message)")
    }
    #expect(!Problem.codex(.notLoggedIn).pausesCall)
    #expect(!Problem.other("You’ve hit your usage limit.").pausesCall)
  }

  /// The engine refuses a band holding one, which takes Start and Stop with it.
  @Test func aSentenceHoldsNoControlCharacters() {
    #expect(Problem.other("one\u{0007}two\u{009B}three").sentence == "onetwothree")
    #expect(Problem.lineRefused("one\u{0000}two").sentence.contains("onetwo"))
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
