import BridgeCore
import Foundation
import Observation
import SwiftUI
import os

/// LiveBridge.app: a menu bar app with no Dock icon (`LSUIElement`).
@main
struct LiveBridgeApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    MenuBarExtra("LiveBridge") {
      VStack(alignment: .leading, spacing: 8) {
        Text(model.status?.call.rawValue ?? "off")
        if let problem = model.problem { Text(problem) }
        Button(model.status?.call == .off ? "Start" : "Stop") {
          model.perform(model.status?.call == .off ? .start : .stop)
        }
        Button("Quit LiveBridge") { NSApplication.shared.terminate(nil) }
      }
      .padding()
    }
    .menuBarExtraStyle(.window)
  }
}

/// The composition root: the bridge, its Unix-socket server, the audio page, and what the menu
/// bar shows.
@MainActor @Observable
final class AppModel {
  private(set) var status: StatusReply?
  /// The input level while the line is open, 0 to 1.
  private(set) var level = 0.0
  private var startupProblem: String?
  @ObservationIgnored private var bridge: Bridge?
  @ObservationIgnored private var server: UnixHTTPServer?
  @ObservationIgnored private let audio = AudioHost(fakeMic: AppModel.fakeMic)
  private static let log = Logger(subsystem: "io.github.nezhinskiy.livebridge", category: "call")

  var problem: String? { startupProblem ?? status?.problem }

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
      audio.onLevel = { [weak self] in self?.level = $0 }
      Task { for await event in events { await bridge.audioEvent(event) } }
      Task { [weak self] in
        for await status in bridge.updates { self?.show(status) }
      }
    } catch {
      startupProblem = "LiveBridge could not start its bridge: \(error.localizedDescription)"
    }
  }

  func perform(_ action: CallAction) { Task { await bridge?.perform(action) } }

  private func show(_ next: StatusReply) {
    if next.call != status?.call || next.problem != status?.problem {
      Self.log.info(
        "call \(next.call.rawValue, privacy: .public), problem: \(next.problem != nil, privacy: .public)"
      )
    }
    if next.call != .live { level = 0 }
    status = next
  }

  /// A fresh codex app-server for the voice, launched with its tool features turned off.
  nonisolated private static func voice(cwd: URL) async throws -> any RealtimeControlling {
    guard let codex = CodexLaunch.locate(explicit: nil, searchPath: CodexLaunch.defaultSearchPath())
    else { throw CodexProblem.notInstalled }
    let client = try await JSONRPCClient.launchVerified(codex: codex, cwd: cwd)
    return RealtimeSession(client: client, voice: nil, cwd: cwd)
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
