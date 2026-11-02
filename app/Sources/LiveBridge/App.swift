import BridgeCore
import Foundation
import Observation
import SwiftUI
import os

/// The entry point. `--unregister-login-item` (run by `build-app.sh --uninstall`) removes the
/// app's login item and exits before anything else starts.
@main
enum Main {
  static func main() {
    guard CommandLine.arguments.contains("--unregister-login-item") else {
      return LiveBridgeApp.main()
    }
    let wasEnabled = LoginItem.isEnabled
    try? LoginItem.set(false)
    print(wasEnabled ? "removed the login item" : "no login item was registered")
  }
}

/// LiveBridge.app: a menu bar app with no Dock icon (`LSUIElement`). The menu bar item and its
/// menu are AppKit's (`StatusMenu`); Settings is the one SwiftUI scene.
struct LiveBridgeApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate

  var body: some Scene {
    Settings { SettingsView(model: delegate.model) }
  }
}

/// Owns the app's model and puts its item in the menu bar once the app has launched. A click on
/// one of its notifications opens the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel()
  private var statusMenu: StatusMenu?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let statusMenu = StatusMenu(model: model)
    self.statusMenu = statusMenu
    model.notifier.onOpen = { [weak statusMenu] in statusMenu?.open() }
  }
}

/// Where Settings' voice list stands. The list comes from a short-lived codex app-server.
enum VoiceListing: Equatable {
  case idle, loading
  case loaded([String])
  case failed(String)
}

/// The composition root: the bridge, its Unix-socket server, the audio page, and what the menu
/// bar shows.
@MainActor @Observable
final class AppModel {
  private(set) var status: StatusReply?
  /// The target's whole conversation, which the menu's Conversation submenu lists.
  private(set) var conversation: [String] = []
  private(set) var presentation: StatusPresentation?
  /// Where the menu's Load context stands for the target.
  private(set) var contextLoad = ContextLoadState.ready
  let glyph = StatusGlyph()
  private var appProblem: String?
  /// Why Open at login could not be changed, shown in Settings.
  private(set) var loginProblem: String?
  var openAtLogin = LoginItem.isEnabled {
    didSet {
      guard openAtLogin != LoginItem.isEnabled else { return }
      loginProblem = nil
      do { try LoginItem.set(openAtLogin) } catch {
        loginProblem = "Open at login could not be changed: \(error.localizedDescription)"
        openAtLogin = LoginItem.isEnabled
      }
    }
  }
  /// The voice chosen in Settings; nil is codex's default. It applies from the next opening.
  var voice: String? {
    didSet { settings?.update { [voice] in $0.voice = voice } }
  }
  /// The owner's own prompt for the voice, at most `VoicePrompt.ownerLimit` characters; empty
  /// adds nothing. It applies from the next opening.
  var prompt = "" {
    didSet {
      if prompt.count > VoicePrompt.ownerLimit {
        prompt = String(prompt.prefix(VoicePrompt.ownerLimit))
      }
      settings?.update { [prompt] in $0.prompt = prompt }
    }
  }
  /// Load a session's context automatically when it becomes the target.
  var autoContext = false {
    didSet {
      settings?.update { [autoContext] in $0.autoContext = autoContext }
      Task { [autoContext] in await bridge?.setAutoContext(autoContext) }
    }
  }
  /// Post a notification with the chime for a result waiting while the line is closed.
  var notifyResults = true {
    didSet {
      settings?.update { [notifyResults] in $0.notifyResults = notifyResults }
      let turnedOn = notifyResults && !oldValue  // permission is asked then, not at launch
      Task { [notifyResults] in
        await bridge?.setNotifies(notifyResults)
        if turnedOn { await notifier.authorize() }
        await refreshNotificationStatus()
      }
    }
  }
  /// The owner refused notifications in System Settings.
  private(set) var notificationsDenied = false
  @ObservationIgnored let notifier = Notifier()
  private(set) var voices = VoiceListing.idle
  /// Why the chosen voice was set back to codex's default.
  private(set) var voiceNote: String?
  @ObservationIgnored private var settings: SettingsStore?
  @ObservationIgnored private var codexCwd: URL?
  @ObservationIgnored private var level = 0.0
  @ObservationIgnored private var bridge: Bridge?
  @ObservationIgnored private var server: UnixHTTPServer?
  @ObservationIgnored private var loads = ContextLoads()
  @ObservationIgnored private var loadsTimer: Task<Void, Never>?
  @ObservationIgnored private let audio = AudioHost(fakeMic: AppModel.fakeMic)
  private static let log = Logger(subsystem: "io.github.nezhinskiy.livebridge", category: "call")

  var problem: String? { appProblem ?? status?.problem }

  init() {
    do {
      let data = try Paths.dataDir()
      let cwd = data.appending(path: "codex-cwd")
      try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
      let settings = SettingsStore(file: data.appending(path: "settings.json"))
      self.settings = settings
      codexCwd = cwd
      voice = settings.current.voice
      prompt = settings.current.prompt
      autoContext = settings.current.autoContext
      notifyResults = settings.current.notifyResults
      let time = SystemTime()
      let registry = SessionRegistry(time: time, autoContext: settings.current.autoContext)
      let bridge = Bridge(
        registry: registry,
        realtime: { try await Self.voice(cwd: cwd, settings: settings) },
        audio: audio, meter: UsageMeterStore(file: data.appending(path: "usage.json"), time: time),
        continuityFile: data.appending(path: "continuity.json"), time: time, notifier: notifier)
      let server = try UnixHTTPServer(socketPath: try Paths.socketPath(), router: bridge)
      try server.start()
      self.bridge = bridge
      Task { [notifyResults] in await bridge.setNotifies(notifyResults) }
      self.server = server
      let (events, sink) = AsyncStream.makeStream(of: AudioEvent.self)
      audio.onEvent = { sink.yield($0) }
      audio.onLevel = { [weak self] in self?.showLevel($0) }
      Task { for await event in events { await bridge.audioEvent(event) } }
      Task { [weak self] in
        for await update in bridge.updates { self?.show(update) }
      }
      Task { [weak self] in
        for await id in bridge.contextArrivals { self?.contextArrived(id) }
      }
    } catch {
      appProblem = "LiveBridge could not start its bridge: \(error.localizedDescription)"
      glyph.show(.off, badge: .problem, level: 0)
    }
  }

  func perform(_ action: CallAction) { Task { await bridge?.perform(action) } }
  func setTarget(_ id: SessionID) { Task { await bridge?.setTarget(id) } }

  /// The session row's ×, once the owner confirms it; the menu has closed by then.
  func remove(_ row: SessionRowPresentation) {
    guard Confirm.ask(.remove(label: row.label)) else { return }
    Task { await bridge?.remove(row.id) }
  }

  /// Asks the target for its summary; the item waits until it arrives, 60 s pass or the
  /// session leaves.
  func loadContext() {
    guard contextLoad.isEnabled, let target = targetRow else { return }
    loads.pressed(target.sessionId, at: Date())
    refreshLoads()
    Task { await bridge?.loadContext() }
  }

  /// Forgets the target's conversation, once the owner confirms it.
  func newConversation() {
    guard let target = targetRow, Confirm.ask(.newConversation(label: target.label)) else {
      return
    }
    Task { await bridge?.newConversation() }
  }

  private var targetRow: SessionRow? { status?.sessions.first(where: \.isTarget) }

  private func contextArrived(_ id: SessionID) {
    loads.arrived(id, at: Date())
    refreshLoads()
  }

  /// Shows the target's Load context state, and comes back when a state ends by itself.
  private func refreshLoads() {
    let now = Date()
    let state = targetRow.map { loads.state(of: $0.sessionId, at: now) } ?? .ready
    if state != contextLoad { contextLoad = state }
    loadsTimer?.cancel()
    loadsTimer = nil
    guard let next = loads.nextChange(after: now) else { return }
    loadsTimer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(next.timeIntervalSince(now)))
      guard !Task.isCancelled else { return }
      self?.refreshLoads()
    }
  }

  private func showLevel(_ value: Double) {
    level = value
    if let presentation { glyph.show(presentation.bars, badge: presentation.badge, level: value) }
  }

  private func show(_ update: BridgeUpdate) {
    let next = update.status
    if update.conversation != conversation { conversation = update.conversation }
    if next.call != status?.call || next.problem != status?.problem {
      Self.log.info(
        "call \(next.call.rawValue, privacy: .public), problem: \(next.problem != nil, privacy: .public)"
      )
    }
    if next.call != .live { level = 0 }
    if next != status {
      status = next
      presentation = StatusPresentation(next)
      loads.keep(only: Set(next.sessions.map(\.sessionId)))
      refreshLoads()
    }
    glyph.show(next.call, badge: presentation?.badge ?? .none, level: level)
  }

  /// Reads whether notifications are refused, for Settings.
  func refreshNotificationStatus() async {
    let denied = await notifier.isDenied
    if denied != notificationsDenied { notificationsDenied = denied }
  }

  /// Asks codex for its voices, once per run unless it failed. A chosen voice codex no longer
  /// offers goes back to codex's default; when listing fails the choice is kept.
  func listVoices() {
    switch voices {
    case .loading, .loaded: return
    case .idle, .failed: break
    }
    guard let codexCwd else {
      voices = .failed("LiveBridge could not start, so codex was not asked for its voices.")
      return
    }
    voices = .loading
    Task {
      do {
        let offered = try await Self.offeredVoices(cwd: codexCwd)
        voices = .loaded(offered)
        if let chosen = voice, Voices.effective(chosen, offered: offered) == nil {
          voice = nil
          voiceNote = "Codex no longer offers \(chosen), so its default voice is used."
        }
      } catch {
        voices = .failed("Codex did not list its voices: \(error.localizedDescription)")
      }
    }
  }

  /// A fresh codex app-server for the voice, launched with every feature but `CodexLaunch.allowed`
  /// off. The voice and prompt chosen in Settings are read at each opening.
  nonisolated private static func voice(cwd: URL, settings: SettingsStore)
    async throws -> any RealtimeControlling
  {
    RealtimeSession(
      client: try await launchCodex(cwd: cwd), cwd: cwd, voice: { settings.current.voice },
      prompt: { settings.current.prompt })
  }

  /// The voices, from a codex app-server started for the question and ended after it.
  nonisolated private static func offeredVoices(cwd: URL) async throws -> [String] {
    let client = try await launchCodex(cwd: cwd)
    defer { Task { await client.close() } }
    return try await Voices.list(client: client)
  }

  nonisolated private static func launchCodex(cwd: URL) async throws -> JSONRPCClient {
    let path = await CodexLaunch.defaultSearchPath()
    guard let codex = CodexLaunch.locate(searchPath: path) else { throw CodexProblem.notInstalled }
    return try await CodexLaunch.launch(codex: codex, cwd: cwd, searchPath: path)
  }

  /// `--fake-mic <wav>`: debug builds play the file as the microphone.
  private static var fakeMic: URL? {
    #if DEBUG
      let arguments = CommandLine.arguments
      if let flag = arguments.firstIndex(of: "--fake-mic"), flag + 1 < arguments.count {
        return URL(filePath: arguments[flag + 1])
      }
    #endif
    return nil
  }
}
