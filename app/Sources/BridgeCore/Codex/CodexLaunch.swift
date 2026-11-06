import Foundation

/// Why the voice cannot start or just stopped, as one sentence for the menu and the band.
public enum CodexProblem: LocalizedError, Equatable, Sendable {
  case notInstalled, notLoggedIn
  /// MCP servers that could not be turned off for the voice thread (fail closed).
  case mcpNotDisabled([String])
  /// codex answered in a shape this version does not understand, or not at all.
  case protocolMismatch(String)
  case exited(Int32)
  /// codex gave no reply to this request in time: it hangs, and is started again.
  case timedOut(String)
  /// A `thread/realtime/error` message (ADR 0001 (k)), shown in codex's own words.
  case realtimeError(String)

  public var errorDescription: String? { sentence }

  /// codex is gone or hangs: the controller is ended, and the next line launches a fresh one.
  public var endsCodex: Bool {
    switch self {
    case .exited, .timedOut: true
    default: false
    }
  }

  public var sentence: String {
    switch self {
    case .notInstalled:
      "Codex is not installed: install the codex CLI and sign in with your ChatGPT account."
    case .notLoggedIn: "Codex is not signed in: run `codex login` with your ChatGPT account."
    case .mcpNotDisabled(let names):
      "Codex MCP servers could not be turned off for the voice: \(names.joined(separator: ", "))."
    case .protocolMismatch(let detail): "Codex did not answer as expected (\(detail))."
    case .exited(126), .exited(127):
      "Codex could not start: its runtime (such as node) was not found on your shell's PATH."
    case .exited(let status):
      status < 0
        ? "Codex stopped unexpectedly." : "Codex stopped unexpectedly (exit status \(status))."
    case .timedOut(let method): "Codex stopped answering (\(method)), so it is started again."
    case .realtimeError(let message) where isUsageLimit:
      "Your ChatGPT plan's usage limit is reached, so the voice is paused. Claude Code keeps "
        + "working. \(message)"
    case .realtimeError(let message) where isRefusal: Problem.lineRefused(message).sentence
    case .realtimeError(let message):
      "Realtime voice failed (codex said: \(message))." + Self.hint(for: message.lowercased())
    }
  }

  /// codex's words for a spent budget. This path carries no error code, so the wording is the
  /// only signal; which limit stopped the voice is not known, so nothing calls it a voice limit.
  var isUsageLimit: Bool {
    guard case .realtimeError(let message) = self else { return false }
    return message.lowercased().contains(
      /you[’']ve hit your usage limit|you hit your spend cap|your workspace is out of credits|quota exceeded/
    )
  }

  /// Any other answer that a new line would get too: codex's fallback for a 429 with no known
  /// body, and a plan without voice. Nothing here shows a budget was spent.
  var isRefusal: Bool {
    guard case .realtimeError(let message) = self else { return false }
    return message.lowercased().contains(/last status: 429|to use codex with your chatgpt plan/)
  }

  /// A guess at the cause from codex's wording; no plan-without-realtime error has been observed.
  private static func hint(for text: String) -> String {
    if text.contains(/\b(log ?in|sign ?in|unauthori[sz]ed|authenticat\w*|401)\b/) {
      return " Run `codex login` with your ChatGPT account."
    }
    if text.contains(/\bplan\b|realtime[^.]*\b(not available|unavailable|not enabled)\b/) {
      return " Your ChatGPT plan's Codex may not include voice."
    }
    return ""
  }
}

/// How the app finds and starts `codex app-server` for the voice thread.
public enum CodexLaunch {
  /// The codex features the voice keeps on. Every other feature `codex features list` reports
  /// is turned off, so one a later codex adds is off too (fail closed). The primary controls
  /// stay the read-only sandbox, `approval_policy="never"` and interrupting every codex turn;
  /// this narrows what an uninterrupted turn has. Derived against codex 0.166.0: the realtime
  /// voice works with every feature off (`scripts/smoke.sh`). `secret_auth_storage` only says
  /// where codex keeps the login: turning it off would hide a keychain login, and it runs no tool.
  /// The two proxy features only choose how codex reaches OpenAI behind a proxy.
  public static let allowed: Set<String> = [
    "respect_system_proxy", "secret_auth_storage", "system_proxy_fallback",
  ]

  /// The first executable `program` (`codex` unless named) in `searchPath`.
  public static func locate(_ program: String = "codex", searchPath: [String]) -> URL? {
    let files = FileManager.default
    return searchPath.lazy.map { URL(filePath: $0).appending(path: program) }
      .first { files.isExecutableFile(atPath: $0.path) }
  }

  /// The user's own shell's `PATH`, then the usual install places: an app started by `open`
  /// gets launchd's minimal `PATH`, which rarely holds `codex` or the `node` an npm install of
  /// codex runs on. codex is started with this `PATH` too.
  public static func defaultSearchPath() async -> [String] {
    let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return await shellPath(shell)
      + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin"]
  }

  /// `PATH` as `shell` sets it for a Terminal window (login and interactive), or `[]` when it
  /// gives no answer within `timeout`.
  static func shellPath(_ shell: String, timeout: Duration = .seconds(3)) async -> [String] {
    let marker = "LIVEBRIDGE_PATH="
    let script = "printf '\\n\(marker)%s\\n' \"$PATH\""
    let answer = try? await run(URL(filePath: shell), ["-l", "-i", "-c", script], timeout: timeout)
    let line = answer?.output.split(separator: "\n").last { $0.hasPrefix(marker) }
    return line?.dropFirst(marker.count).split(separator: ":").map(String.init) ?? []
  }

  /// The names in `codex features list` output (`name  stage  enabled`, the stage one or more
  /// words), except stage `removed`, which `--disable` no longer changes. Output that is empty
  /// or has any other line throws `protocolMismatch`.
  public static func presentFeatures(featuresListOutput: String) throws -> Set<String> {
    var names: Set<String> = []
    for line in featuresListOutput.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard let name = fields.first, let enabled = fields.last, fields.count >= 3,
        ["true", "false"].contains(enabled),
        fields.dropFirst().dropLast().allSatisfy({ $0.allSatisfy(\.isLetter) })
      else { throw CodexProblem.protocolMismatch("unreadable `codex features list` line") }
      if !fields.dropFirst().dropLast().contains("removed") { names.insert(String(name)) }
    }
    guard !names.isEmpty else { throw CodexProblem.protocolMismatch("no codex features listed") }
    return names
  }

  /// `codex app-server` pinned read-only, never asking, with no web search and no notify
  /// hook. `disable` must hold only names codex reports, or it refuses to start.
  public static func argv(disable: [String]) -> [String] {
    [
      "app-server", "-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"never\"", "-c",
      "web_search=\"disabled\"", "-c", "notify=[]", "-c", "model_reasoning_effort=\"low\"",
    ] + disable.flatMap { ["--disable", $0] }
  }

  /// Runs `codex features list`, starts `codex app-server` with every feature but `allowed`
  /// turned off, initialises it and checks the ChatGPT sign-in. Throws `CodexProblem`.
  public static func launch(
    codex: URL, cwd: URL, searchPath: [String] = [], probeTimeout: Duration = .seconds(10)
  ) async throws -> JSONRPCClient {
    guard
      let features = try await run(
        codex, ["features", "list"], searchPath: searchPath, timeout: probeTimeout)
    else { throw CodexProblem.protocolMismatch("no answer to `codex features list`") }
    guard features.status == 0 else { throw CodexProblem.exited(features.status) }
    let present = try presentFeatures(featuresListOutput: features.output)
    let client = JSONRPCClient(
      executable: codex, arguments: argv(disable: present.subtracting(allowed).sorted()),
      cwd: cwd, searchPath: searchPath)
    do {
      try await client.start()
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
      let hello: JSONValue = [
        "clientInfo": [
          "name": "livebridge", "title": "LiveBridge",
          "version": .string(version as? String ?? "dev"),
        ],
        "capabilities": ["experimentalApi": true, "requestAttestation": false],
      ]
      let _: JSONValue = try await client.request("initialize", hello, timeout: .seconds(20))
      await client.notify("initialized")
      let account: JSONValue = try await client.request(
        "account/read", JSONValue.object([:]), timeout: .seconds(20))
      guard account["account"]?.object != nil else { throw CodexProblem.notLoggedIn }
      return client
    } catch {
      await client.close()
      throw error is CodexProblem ? error : CodexProblem.protocolMismatch("\(error)")
    }
  }

  /// Runs `executable` in `cwd` (the app's own when nil) and returns its exit status and
  /// standard output, with its standard error too when `mergingErrors`, or `nil` when it gives
  /// no answer within `timeout` (it is then killed: an interactive shell ignores `SIGTERM`).
  /// Throws `notInstalled` when it cannot start. Output goes to a file: a child it leaves
  /// running could hold a pipe open.
  public static func run(
    _ executable: URL, _ arguments: [String], searchPath: [String] = [], cwd: URL? = nil,
    mergingErrors: Bool = false, timeout: Duration
  ) async throws -> (status: Int32, output: String)? {
    let out = FileManager.default.temporaryDirectory.appending(path: "lb-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: out) }
    guard FileManager.default.createFile(atPath: out.path, contents: nil),
      let file = try? FileHandle(forWritingTo: out)
    else { return nil }
    defer { try? file.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.use(searchPath: searchPath)
    process.currentDirectoryURL = cwd
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = file
    process.standardError = mergingErrors ? file : FileHandle.nullDevice
    do { try process.run() } catch { throw CodexProblem.notInstalled }
    let deadline = ContinuousClock.now + timeout
    while process.isRunning, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    guard !process.isRunning else {
      kill(process.processIdentifier, SIGKILL)
      return nil
    }
    return (process.terminationStatus, (try? String(contentsOf: out, encoding: .utf8)) ?? "")
  }
}

extension Process {
  /// Starts the child with this `PATH`, so a `#!/usr/bin/env node` codex finds its runtime.
  func use(searchPath: [String]) {
    guard !searchPath.isEmpty else { return }
    environment = ProcessInfo.processInfo.environment.merging(
      ["PATH": searchPath.joined(separator: ":")]) { $1 }
  }
}
