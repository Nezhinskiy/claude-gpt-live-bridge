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
  /// codex features that could give the voice thread tools; each is turned off if codex has it.
  public static let wantDisabled = [
    "hooks", "apps", "plugins", "computer_use", "browser_use", "in_app_browser", "multi_agent",
    "image_generation", "memories", "goals",
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

  /// The names in `codex features list` output (`name  stage  enabled`), except stage `removed`.
  public static func presentFeatures(featuresListOutput: String) -> Set<String> {
    Set(
      featuresListOutput.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: " ")
        guard fields.count >= 3, !fields.dropFirst().dropLast().contains("removed") else {
          return nil
        }
        return String(fields[0])
      })
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
