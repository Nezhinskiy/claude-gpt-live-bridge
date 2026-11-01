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

/// LiveBridge.app: a menu bar app with no Dock icon (`LSUIElement`).
struct LiveBridgeApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      PopoverView(model: model)
    } label: {
      Image(nsImage: model.glyph.image)
        .accessibilityLabel(model.presentation?.accessibilityLabel ?? "LiveBridge")
    }
    .menuBarExtraStyle(.window)
  }
}

/// The composition root: the bridge, its Unix-socket server, the audio page, and what the menu
/// bar shows.
@MainActor @Observable
final class AppModel {
  private(set) var status: StatusReply?
  private(set) var presentation: StatusPresentation?
  let glyph = StatusGlyph()
  private var appProblem: String?
  var openAtLogin = LoginItem.isEnabled {
    didSet {
      guard openAtLogin != LoginItem.isEnabled else { return }
      do { try LoginItem.set(openAtLogin) } catch {
        appProblem = "Open at login could not be changed: \(error.localizedDescription)"
        openAtLogin = LoginItem.isEnabled
      }
    }
  }
  @ObservationIgnored private var level = 0.0
  @ObservationIgnored private var bridge: Bridge?
  @ObservationIgnored private var server: UnixHTTPServer?
  @ObservationIgnored private let audio = AudioHost(fakeMic: AppModel.fakeMic)
  private static let log = Logger(subsystem: "io.github.nezhinskiy.livebridge", category: "call")

  var problem: String? { appProblem ?? status?.problem }

  init() {
    do {
      let data = try Paths.dataDir()
      let cwd = data.appending(path: "codex-cwd")
      try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
      let time = SystemTime()
      let bridge = Bridge(
        registry: SessionRegistry(time: time), realtime: { try await Self.voice(cwd: cwd) },
        audio: audio, meter: UsageMeterStore(file: data.appending(path: "usage.json"), time: time),
        continuityFile: data.appending(path: "continuity.json"), time: time)
      let server = try UnixHTTPServer(socketPath: try Paths.socketPath(), router: bridge)
      try server.start()
      self.bridge = bridge
      self.server = server
      let (events, sink) = AsyncStream.makeStream(of: AudioEvent.self)
      audio.onEvent = { sink.yield($0) }
      audio.onLevel = { [weak self] in self?.showLevel($0) }
      Task { for await event in events { await bridge.audioEvent(event) } }
      Task { [weak self] in
        for await status in bridge.updates { self?.show(status) }
      }
    } catch {
      appProblem = "LiveBridge could not start its bridge: \(error.localizedDescription)"
      glyph.show(.off, badge: .problem, level: 0)
    }
  }

  func perform(_ action: CallAction) { Task { await bridge?.perform(action) } }
  func setTarget(_ id: SessionID) { Task { await bridge?.setTarget(id) } }
  func loadContext() { Task { await bridge?.loadContext() } }
  func newConversation() { Task { await bridge?.newConversation() } }

  private func showLevel(_ value: Double) {
    level = value
    if let presentation { glyph.show(presentation.bars, badge: presentation.badge, level: value) }
  }

  private func show(_ next: StatusReply) {
    if next.call != status?.call || next.problem != status?.problem {
      Self.log.info(
        "call \(next.call.rawValue, privacy: .public), problem: \(next.problem != nil, privacy: .public)"
      )
    }
    if next.call != .live { level = 0 }
    if next != status {
      status = next
      presentation = StatusPresentation(next)
    }
    glyph.show(next.call, badge: presentation?.badge ?? .none, level: level)
  }

  /// A fresh codex app-server for the voice, launched with its tool features turned off.
  nonisolated private static func voice(cwd: URL) async throws -> any RealtimeControlling {
    let path = await CodexLaunch.defaultSearchPath()
    guard let codex = CodexLaunch.locate(searchPath: path) else { throw CodexProblem.notInstalled }
    let client = try await CodexLaunch.launch(codex: codex, cwd: cwd, searchPath: path)
    return RealtimeSession(client: client, cwd: cwd)
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
