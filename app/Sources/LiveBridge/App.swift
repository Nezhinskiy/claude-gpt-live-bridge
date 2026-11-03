import AppKit
import BridgeCore
import Foundation
import Observation
import os

/// The entry point: LiveBridge.app, a menu bar app with no Dock icon (`LSUIElement`), its menu
/// bar item and its Settings window AppKit's. `--unregister-login-item` (run by
/// `build-app.sh --uninstall`) removes the app's login item and exits before anything starts.
@main
enum Main {
  @MainActor static func main() {
    guard !CommandLine.arguments.contains("--unregister-login-item") else {
      let wasEnabled = LoginItem.isEnabled
      try? LoginItem.set(false)
      return print(wasEnabled ? "removed the login item" : "no login item was registered")
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.mainMenu = editMenu()
    withExtendedLifetime(delegate) { app.run() }
  }

  /// The app shows no menu bar, but the Settings window's text fields still take ⌘X, ⌘C, ⌘V,
  /// ⌘A and ⌘Z through these items, and the window closes with ⌘W.
  @MainActor private static func editMenu() -> NSMenu {
    let edit = NSMenu(title: "Edit")
    for (title, action, key) in [
      ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"), ("Close", "performClose:", "w"),
    ] {
      edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
    }
    let menu = NSMenu()
    menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
    return menu
  }
}

/// Owns the app's model and puts its item in the menu bar once the app has launched. A click on
/// one of its notifications opens the menu; an update notice's Install action installs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel()
  private var statusMenu: StatusMenu?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let statusMenu = StatusMenu(model: model)
    self.statusMenu = statusMenu
    model.notifier.onOpen = { [weak statusMenu] in statusMenu?.open() }
    model.notifier.onInstall = { [weak model] in model?.installUpdate($0) }
  }
}

/// Where Settings' voice list stands. The list comes from a short-lived codex app-server.
enum VoiceListing: Equatable {
  case idle, loading
  case loaded([String])
  case failed(String)
}

/// The composition root: the bridge, its Unix-socket server, the audio page, the updater, and
/// what the menu bar shows.
@MainActor @Observable
final class AppModel {
  /// What the bridge last published: the status, its problem and the target's conversation.
  private(set) var update: BridgeUpdate?
  var status: StatusReply? { update?.status }
  private(set) var presentation: StatusPresentation?
  /// Where the menu's Load context stands for the target.
  private(set) var contextLoad = ContextLoadState.ready
  let glyph = StatusGlyph()
  private var appProblem: Problem?
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
  /// The owner refused notifications in System Settings.
  private(set) var notificationsDenied = false
  @ObservationIgnored let notifier = Notifier()
  private(set) var voices = VoiceListing.idle
  /// Why the chosen voice was set back to codex's default.
  private(set) var voiceNote: String?
  /// The settings, which the Settings window shows and changes. Without its data folder the
  /// app does not start, and the window keeps no change.
  @ObservationIgnored let settings: SettingsStore
  @ObservationIgnored private var settingsWindow: SettingsWindow?
  @ObservationIgnored private var codexCwd: URL?
  @ObservationIgnored private var level = 0.0
  @ObservationIgnored private var bridge: Bridge?
  @ObservationIgnored private var server: UnixHTTPServer?
  @ObservationIgnored private var loads = ContextLoads()
  @ObservationIgnored private var loadsTimer: Task<Void, Never>?
  @ObservationIgnored private let audio = AudioHost(fakeMic: AppModel.fakeMic)
  /// The running app's `CFBundleShortVersionString`.
  let versionText: String
  /// This is the copy in `/Applications`, the only one that checks for and installs updates.
  let isInstalledCopy: Bool
  /// Built from source with `build-app.sh --release` (`LBSourceBuild`).
  let isSourceBuild: Bool
  /// Where an update check or install stands.
  private(set) var updateStatus = UpdateStatus.idle
  /// The newer release a check found, until a check finds none or it is installed.
  private(set) var available: Release?
  /// What the last update left, shown in Settings until the next one.
  private(set) var updateRecord: UpdateRecord?
  /// Nil for a copy that does not update: outside `/Applications`, or a version that is not
  /// `X.Y.Z`.
  @ObservationIgnored private(set) var updater: Updater?
  /// When the last automatic check ran and which releases were announced.
  @ObservationIgnored private var updateState: UpdateStateStore?
  @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
  private static let log = Logger(subsystem: Paths.bundleID, category: "call")

  var problem: Problem? { appProblem ?? update?.problem }

  /// Check for updates automatically, as the owner set it or as the build's default.
  var checksAutomatically: Bool {
    UpdatePolicy.checksAutomatically(
      setting: settings.current.checkUpdatesAutomatically, isSourceBuild: isSourceBuild)
  }

  init() {
    let info = Bundle.main
    versionText = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    isSourceBuild = info.object(forInfoDictionaryKey: "LBSourceBuild") as? Bool == true
    let installedIsLink =
      (try? FileManager.default.attributesOfItem(atPath: UpdatePolicy.installedPath)[.type])
      as? FileAttributeType == .typeSymbolicLink
    isInstalledCopy = UpdatePolicy.isInstalledCopy(
      resolvedBundlePath: info.bundleURL.resolvingSymlinksInPath().path,
      installedPathIsSymlink: installedIsLink)
    let data = Result { try Paths.dataDir() }
    let settings = SettingsStore(file: try? data.get().appending(path: "settings.json"))
    self.settings = settings
    do {
      let data = try data.get()
      let cwd = data.appending(path: "codex-cwd")
      try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
      codexCwd = cwd
      let time = SystemTime()
      let registry = SessionRegistry(time: time, autoContext: { settings.current.autoContext })
      let bridge = Bridge(
        registry: registry,
        realtime: { try await Self.voice(cwd: cwd, settings: settings) },
        audio: audio, meter: UsageMeterStore(file: data.appending(path: "usage.json"), time: time),
        continuityFile: data.appending(path: "continuity.json"), time: time, notifier: notifier,
        notifies: { settings.current.notifyResults })
      let server = try UnixHTTPServer(socketPath: try Paths.socketPath(), router: bridge)
      self.bridge = bridge
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
      // A relaunch after an update starts while the old instance may still hold the socket.
      Task { [weak self] in
        do { try await server.start(retryFor: .seconds(10)) } catch {
          self?.bridgeFailed(error)
        }
      }
    } catch {
      bridgeFailed(error)
    }
    startUpdates(dataDir: try? data.get())
  }

  /// For the installed copy: makes the updater, follows its status, cleans up after the last
  /// update and posts its notice once, then checks when due on launch, every
  /// `UpdatePolicy.tick` and on wake. Other copies leave `updates/` to the installed one.
  private func startUpdates(dataDir: URL?) {
    guard isInstalledCopy, let running = AppVersion(versionText), let dataDir else { return }
    let paths = UpdatePaths(
      applications: URL(filePath: "/Applications"), updates: dataDir.appending(path: "updates"),
      dataDir: dataDir)
    let bridge = bridge
    let updater = Updater(
      environment: SystemUpdateEnvironment(releasesURL: Self.releasesURL), paths: paths,
      running: running, hasOpenRequests: { await bridge?.hasOpenRequests ?? false },
      stopCall: { await bridge?.perform(.stop) },
      quit: { Task { @MainActor in NSApp.terminate(nil) } },
      pid: ProcessInfo.processInfo.processIdentifier)
    self.updater = updater
    Task { [weak self] in
      for await status in updater.statuses { self?.showUpdate(status) }
    }
    if let record = Updater.cleanUp(paths: paths) {
      updateRecord = record
      if !record.noticePosted {
        announceInstalled(record, file: paths.updates.appending(path: "record.json"))
      }
    }
    updateState = UpdateStateStore(file: paths.updates.appending(path: "state.json"))
    Task { [weak self] in
      await self?.restoreAnnounced()
      while !Task.isCancelled {
        await self?.checkIfDue()
        try? await Task.sleep(for: UpdatePolicy.tick)
      }
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in await self?.checkIfDue() }
    }
  }

  /// Posts `LiveBridge updated to X.Y.Z` once: the record is marked first, so a crash cannot
  /// post it twice.
  private func announceInstalled(_ record: UpdateRecord, file: URL) {
    var posted = record
    posted.noticePosted = true
    try? posted.write(file)
    let body =
      switch record.mod {
      case .updated:
        "Updated from \(record.from). Claude Code sessions already open keep the old mod until "
          + "they restart."
      case .byHand:
        "Updated from \(record.from). Settings shows the commands that update the Claude Code mod."
      }
    Task {
      await notifier.postUpdate(
        identifier: "update-installed-\(record.to)", title: "LiveBridge updated to \(record.to)",
        body: body, installs: nil)
    }
  }

  /// The automatic check: a newer release not announced before is announced with a notice
  /// whose Install installs it, and the menu offers it. The notice says when the image cannot
  /// be verified on this Mac yet.
  private func checkIfDue() async {
    guard let updater, let updateState,
      let release = await updater.checkIfDue(
        now: Date(), enabled: checksAutomatically, state: updateState)
    else { return }
    available = release
    let problem = await updater.verifierProblem()
    let body = ["Install updates LiveBridge and its Claude Code mod.", problem?.sentence]
      .compactMap { $0 }.joined(separator: " ")
    await notifier.postUpdate(
      identifier: "update-available-\(release.version)",
      title: "LiveBridge \(release.version) is available", body: body, installs: release.version)
  }

  /// A release announced before a relaunch stays in the menu: with automatic checks on, one
  /// check at launch finds it again, without a notice.
  private func restoreAnnounced() async {
    guard let updater, let updateState else { return }
    let release = await updater.restoreAnnounced(
      now: Date(), enabled: checksAutomatically, state: updateState)
    if let release { available = release }
  }

  private func showUpdate(_ status: UpdateStatus) {
    updateStatus = status
    switch status {
    case .available(let release): available = release
    case .upToDate: available = nil
    default: break
    }
  }

  /// Settings' Check for update.
  func checkForUpdate() {
    guard let updater else { return }
    Task { _ = await updater.check() }
  }

  /// Installs the release found: Settings' Install and the menu's item. A build from source
  /// asks first, since the release replaces it.
  func installUpdate() {
    guard let updater, let release = available else { return }
    if isSourceBuild, !Confirm.ask(.replaceSourceBuild(version: release.version)) { return }
    Task { await updater.install(release) }
  }

  /// A notice's Install: opens Settings on the update and installs `version`, checking first
  /// when this run has not found it (a notice from before a relaunch).
  func installUpdate(_ version: AppVersion) {
    showSettings()
    if available?.version == version { return installUpdate() }
    guard let updater else { return }
    Task {
      guard case .available(let release) = await updater.check(), release.version == version
      else { return }
      available = release
      installUpdate()
    }
  }

  private func bridgeFailed(_ error: any Error) {
    bridge = nil
    server = nil
    appProblem = .other("LiveBridge could not start its bridge: \(error.localizedDescription)")
    glyph.show(.off, badge: .problem, level: 0)
  }

  func perform(_ action: CallAction) { Task { await bridge?.perform(action) } }

  /// Opens the Settings window in front of the other apps' windows.
  func showSettings() {
    let window = settingsWindow ?? SettingsWindow(model: self)
    settingsWindow = window
    window.show()
  }

  /// Settings' notifications; macOS asks for permission when they are turned on, not at launch.
  func setNotifyResults(_ on: Bool) {
    settings.update { $0.notifyResults = on }
    Task {
      if on { await notifier.authorize() }
      await refreshNotificationStatus()
    }
  }
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
    if next.call != status?.call || update.problem != self.update?.problem {
      Self.log.info(
        "call \(next.call.rawValue, privacy: .public), problem: \(update.problem != nil, privacy: .public)"
      )
    }
    if next.call != .live { level = 0 }
    let statusChanged = next != status
    if update != self.update { self.update = update }
    if statusChanged {
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
        if let chosen = settings.current.voice, !offered.contains(chosen) {
          settings.update { $0.voice = nil }
          voiceNote = "Codex no longer offers \(chosen), so its default voice is used."
        }
      } catch {
        voices = .failed("Codex did not list its voices: \(error.localizedDescription)")
      }
    }
  }

  /// A fresh codex app-server for the voice, launched with every feature but `CodexLaunch.allowed`
  /// off. The voice and the prompt chosen in Settings are read at each opening.
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

  /// GitHub's latest release of LiveBridge; a debug build takes `LIVEBRIDGE_RELEASES_URL`
  /// instead when it is set, for the by-hand update test.
  private static var releasesURL: URL {
    #if DEBUG
      if let text = ProcessInfo.processInfo.environment["LIVEBRIDGE_RELEASES_URL"],
        let url = URL(string: text)
      {
        return url
      }
    #endif
    return URL(string: "https://api.github.com/repos/getLiveBridge/LiveBridge/releases/latest")!
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
