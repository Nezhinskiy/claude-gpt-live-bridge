import Foundation

/// Why the voice cannot start or just stopped, as one sentence for the popover and the band.
public enum CodexProblem: Error, Equatable, Sendable {
  case notInstalled, notLoggedIn, realtimeUnavailable
  /// MCP servers that could not be turned off for the voice thread (fail closed).
  case mcpNotDisabled([String])
  /// codex answered in a shape this version does not understand, or not at all.
  case protocolMismatch(String)
  case exited(Int32)
  /// A realtime error codex reported that is not recognised; shown as it is.
  case realtimeError(String)

  public var sentence: String {
    switch self {
    case .notInstalled:
      "Codex is not installed: install the codex CLI and sign in with your ChatGPT account."
    case .notLoggedIn: "Codex is not signed in: run `codex login` with your ChatGPT account."
    case .realtimeUnavailable: "Your ChatGPT plan does not include realtime voice in Codex."
    case .mcpNotDisabled(let names):
      "Codex MCP servers could not be turned off for the voice: \(names.joined(separator: ", "))."
    case .protocolMismatch(let detail): "Codex did not answer as expected (\(detail))."
    case .exited(let status): "Codex stopped unexpectedly (exit status \(status))."
    case .realtimeError(let message): "Realtime voice failed: \(message)"
    }
  }

  /// Reads a `thread/realtime/error` message (ADR 0001 (k)): sign-in wording means not logged
  /// in, plan or availability wording means no realtime on this plan; anything else is shown.
  public static func classify(realtimeError message: String) -> CodexProblem {
    let text = message.lowercased()
    let has = { (words: [String]) in words.contains { text.contains($0) } }
    if has(["log in", "login", "sign in", "unauthorized", "authenticat", "401"]) {
      return .notLoggedIn
    }
    if has(["plan", "not available", "unavailable", "not enabled", "upgrade", "subscription"]) {
      return .realtimeUnavailable
    }
    return .realtimeError(message)
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

  /// `explicit` if it is executable, else the first `codex` in `searchPath`.
  public static func locate(explicit: String?, searchPath: [String]) -> URL? {
    let files = FileManager.default
    if let explicit, files.isExecutableFile(atPath: explicit) { return URL(filePath: explicit) }
    return searchPath.lazy.map { URL(filePath: $0).appending(path: "codex") }
      .first { files.isExecutableFile(atPath: $0.path) }
  }

  /// The login shell's `PATH`, then the usual install places: an app started by `open` gets
  /// launchd's minimal `PATH`, which rarely holds `codex`.
  public static func defaultSearchPath() -> [String] {
    let shell = Process()
    let output = Pipe()
    shell.executableURL = URL(filePath: "/bin/zsh")
    shell.arguments = ["-lc", "printf %s \"$PATH\""]
    shell.standardOutput = output
    shell.standardError = FileHandle.nullDevice
    var path: [String] = []
    if (try? shell.run()) != nil {
      let data = output.fileHandleForReading.readDataToEndOfFile()
      shell.waitUntilExit()
      path = String(decoding: data, as: UTF8.self).split(separator: ":").map(String.init)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
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
