import Foundation

/// Why the voice cannot start or just stopped, as one sentence for the popover and the band.
public enum CodexProblem: LocalizedError, Equatable, Sendable {
  case notInstalled, notLoggedIn
  /// MCP servers that could not be turned off for the voice thread (fail closed).
  case mcpNotDisabled([String])
  /// codex answered in a shape this version does not understand, or not at all.
  case protocolMismatch(String)
  case exited(Int32)
  /// A `thread/realtime/error` message (ADR 0001 (k)), shown in codex's own words.
  case realtimeError(String)

  public var errorDescription: String? { sentence }

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
    case .realtimeError(let message):
      "Realtime voice failed (codex said: \(message))." + Self.hint(for: message.lowercased())
    }
  }

  /// A guess at the cause from codex's wording; no plan-without-realtime error has been observed.
  private static func hint(for text: String) -> String {
    if text.contains(/\b(log ?in|sign ?in|unauthori[sz]ed|authenticat\w*|401)\b/) {
      return " Run `codex login` with your ChatGPT account."
    }
    if text.contains(/\bplan\b|realtime[^.]*\b(not available|unavailable|not enabled)\b/) {
      return " Your ChatGPT plan may not include realtime voice in Codex."
    }
    return ""
  }
}

/// How the app finds and starts `codex app-server` for the voice thread.
public enum CodexLaunch {
  /// codex features that give the codex model a tool or a side effect; each is turned off if
  /// codex has it. The primary controls stay the read-only sandbox, `approval_policy="never"`
  /// and interrupting every codex turn; this list only narrows what an uninterrupted turn has.
  public static let wantDisabled = [
    "hooks", "apps", "plugins", "computer_use", "browser_use", "in_app_browser", "multi_agent",
    "image_generation", "memories", "goals",
    // shell and code execution, file reads, tool and skill installs
    "shell_tool", "unified_exec", "unified_exec_tty", "shell_snapshot", "code_mode",
    "code_mode_host", "view_image", "sleep_tool", "request_permissions_tool", "tool_suggest",
    "skill_search", "skill_mcp_dependency_install", "multi_agent_v2",
    // plugins, browsers, automation and web search by other names
    "remote_plugin", "plugin_discovery_prefetch", "browser_use_external",
    "browser_use_full_cdp_access", "browser_annotation_api", "in_app_local_automation",
    "standalone_web_search", "web_search_request", "web_search_cached",
  ]

  /// The first `codex` in `searchPath`.
  public static func locate(searchPath: [String]) -> URL? {
    let files = FileManager.default
    return searchPath.lazy.map { URL(filePath: $0).appending(path: "codex") }
      .first { files.isExecutableFile(atPath: $0.path) }
  }

  /// The user's own shell's `PATH`, then the usual install places: an app started by `open`
  /// gets launchd's minimal `PATH`, which rarely holds `codex` or the `node` an npm install of
  /// codex runs on. codex is started with this `PATH` too.
  public static func defaultSearchPath() -> [String] {
    let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return shellPath(shell)
      + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin"]
  }

  /// `PATH` as `shell` sets it for a Terminal window (login and interactive), or `[]` when it
  /// gives no answer within `timeout`. Output goes to a file: a shell's leftover children could
  /// hold a pipe open.
  static func shellPath(_ shell: String, timeout: Duration = .seconds(3)) -> [String] {
    let out = FileManager.default.temporaryDirectory.appending(path: "path-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: out) }
    let marker = "LIVEBRIDGE_PATH="
    let process = Process()
    process.executableURL = URL(filePath: shell)
    process.arguments = ["-l", "-i", "-c", "printf '\\n\(marker)%s\\n' \"$PATH\""]
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard FileManager.default.createFile(atPath: out.path, contents: nil),
      let file = try? FileHandle(forWritingTo: out)
    else { return [] }
    process.standardOutput = file
    guard (try? process.run()) != nil else { return [] }
    let deadline = ContinuousClock.now + timeout
    while process.isRunning, ContinuousClock.now < deadline { usleep(20_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }  // -i shells ignore TERM
    let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    let line = text.split(separator: "\n").last { $0.hasPrefix(marker) }
    return line?.dropFirst(marker.count).split(separator: ":").map(String.init) ?? []
  }

  /// The names in `codex features list` output (`name  stage  enabled`, the stage one or more
  /// words), except stage `removed`. Output that is empty or has any other line throws
  /// `protocolMismatch`: launching with fewer `--disable` flags would fail open.
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
}
