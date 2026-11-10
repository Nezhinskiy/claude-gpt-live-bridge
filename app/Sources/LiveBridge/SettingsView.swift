import AppKit
import BridgeCore
import SwiftUI

/// The Settings window's tabs: what the owner hears during a call, and the rest.
enum SettingsTab: Hashable {
  case voice, general
}

/// LiveBridge's Settings, in two tabs. **Voice**: the voice and its prompt, the line (its timers and
/// how it connects) and the sounds. **General**: sync, notifications, Open at login and updates. The settings are read
/// from and written to `AppModel.settings`, their one copy.
struct SettingsView: View {
  @Bindable var model: AppModel
  /// Counts the reconnects the owner cancelled, so the switch is drawn again as it was.
  @State private var cancelledReconnects = 0

  var body: some View {
    TabView(selection: $model.settingsTab) {
      voiceTab.tabItem { Label("Voice", systemImage: "waveform") }.tag(SettingsTab.voice)
      generalTab.tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
    }
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear { model.listVoices() }
    .task { await model.refreshNotificationStatus() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in Task { await model.refreshNotificationStatus() } }
  }

  private var voiceTab: some View {
    Form {
      Section("Voice") {
        Picker("Voice", selection: setting(\.voice)) {
          Text("Codex default").tag(String?.none)
          ForEach(choices, id: \.self) { Text($0.capitalized).tag(String?.some($0)) }
        }
        .disabled(model.voices == .loading)
        listing
        if let note = model.voiceNote {
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
        Text("A new voice is heard from the next time the voice line opens.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Prompt") {
        TextField(
          "Prompt", text: setting(\.prompt), prompt: Text("Speak with me in Spanish"),
          axis: .vertical
        )
        .lineLimit(3...8)
        .labelsHidden()
        Text(
          "Optional, up to \(VoicePrompt.ownerLimit.formatted()) characters. The voice follows it "
            + "after LiveBridge's own rules, which win where they disagree. It applies from the "
            + "next time the voice line opens."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Line") {
        seconds("Silence before the line closes", \.silenceSeconds)
        if (1...9).contains(model.settings.current.silenceSeconds) {
          warning(
            "Shorter than an ordinary pause: the line will close while you think, and each "
              + "reopening takes a few seconds.")
        }
        seconds("Wait for a first word on a line a result opened", \.firstWordSeconds)
        Text(
          "A line opened by Claude's answer or question waits this long for you or the voice to "
            + "speak; then it closes, and the result chimes."
        )
        .font(.caption).foregroundStyle(.secondary)
        seconds("Sound without words before the line closes", \.noiseSeconds)
        if (1...9).contains(model.settings.current.noiseSeconds) {
          warning(
            "Speech counts as sound without words until it is recognised, so the line can close "
              + "while you speak.")
        }
        Text(
          "Seconds, from 0 to 300; 0 never closes the line for that. The line is billed by the "
            + "minute while it is open, silence included. A change applies from the next words."
        )
        .font(.caption).foregroundStyle(.secondary)
        Toggle(
          "Connect over TCP",
          isOn: Binding {
            model.settings.current.connectsOverTCP
          } set: {
            if !model.setConnectsOverTCP($0) { cancelledReconnects += 1 }
          }
        )
        .id(cancelledReconnects)
        Text(
          "If the voice breaks up on a poor connection, turn this on: the line prefers TCP, which "
            + "can turn breakups into short pauses, and can still fall back to UDP. An open voice "
            + "line reconnects."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Sounds") {
        Toggle("Play sounds for requests and answers", isOn: setting(\.confirmHandoffs))
        Text(
          "The voice sometimes says it is looking without sending the request. An answer has "
            + "its own sound; with no request sound, nothing was queued, so say it again."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var generalTab: some View {
    Form {
      Section("Sync") {
        Toggle("Pause sync while the call is stopped", isOn: setting(\.pauseSyncWhileStopped))
        Text(
          "What you type while the call is off stays out of the voice's conversation, and context "
            + "loads only from the menu, unless the next setting loads a summary, which carries "
            + "that text."
        )
        .font(.caption).foregroundStyle(.secondary)
        Toggle(
          "Load a session's context on its first call", isOn: setting(\.loadContextOnFirstCall))
        Text(
          "A line for a session with no summary yet asks for one, even while sync is paused. It "
            + "is written from the whole transcript, paused text included, and goes to OpenAI."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Notifications") {
        Toggle(
          "Notify when a result is waiting",
          isOn: Binding {
            model.settings.current.notifyResults
          } set: {
            model.setNotifyResults($0)
          })
        Text("With the chime, a notification names the session; it never shows the result.")
          .font(.caption).foregroundStyle(.secondary)
        if model.settings.current.notifyResults, model.notificationsDenied {
          Label(Notifier.deniedSentence, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).symbolRenderingMode(.multicolor)
          Button("Open Notifications Settings") { NSWorkspace.shared.open(Notifier.settingsURL) }
        }
      }
      Section("Login") {
        Toggle("Open at login", isOn: $model.openAtLogin)
        if let problem = model.loginProblem {
          Label(problem, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).symbolRenderingMode(.multicolor)
        }
      }
      UpdateSection(model: model)
    }
    .formStyle(.grouped)
  }

  /// A setting as the controls change it: read from the store and written back to it.
  private func setting<T>(_ key: WritableKeyPath<BridgeCore.Settings, T>) -> Binding<T> {
    Binding {
      model.settings.current[keyPath: key]
    } set: { value in
      model.settings.update { $0[keyPath: key] = value }
    }
  }

  /// One of the line's timers: a field and a stepper, kept in `Timeouts.range`.
  private func seconds(
    _ title: String, _ key: WritableKeyPath<BridgeCore.Settings, Int>
  ) -> some View {
    let range = CallMachine.Timeouts.range
    let value = Binding {
      model.settings.current[keyPath: key]
    } set: { typed in
      model.settings.update {
        $0[keyPath: key] = min(max(typed, range.lowerBound), range.upperBound)
      }
    }
    return LabeledContent(title) {
      HStack(spacing: 4) {
        TextField(title, value: value, format: .number)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 48)
        Stepper(title, value: value, in: range).labelsHidden()
        Text("s").foregroundStyle(.secondary).accessibilityHidden(true)
      }
    }
  }

  private func warning(_ text: String) -> some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.caption).symbolRenderingMode(.multicolor)
  }

  /// codex's voices; until they are listed, the choice already made, so the picker shows it.
  private var choices: [String] {
    if case .loaded(let voices) = model.voices { return voices }
    return model.settings.current.voice.map { [$0] } ?? []
  }

  @ViewBuilder private var listing: some View {
    switch model.voices {
    case .idle, .loaded: EmptyView()
    case .loading:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Asking codex for its voices…").font(.caption).foregroundStyle(.secondary)
      }
    case .failed(let problem):
      VStack(alignment: .leading, spacing: 6) {
        Label(problem, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).symbolRenderingMode(.multicolor)
        Text(
          model.settings.current.voice.map { "The line keeps \($0.capitalized)." }
            ?? "The line keeps codex's default voice."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Try Again") { model.listVoices() }
      }
    }
  }
}

/// The Settings window, one for the app: a menu bar app (`LSUIElement`) is not active, so it is
/// activated first, or the window would open behind the frontmost app's.
@MainActor
final class SettingsWindow {
  private let window: NSWindow

  init(model: AppModel) {
    window = NSWindow(
      contentViewController: NSHostingController(rootView: SettingsView(model: model)))
    window.title = "LiveBridge Settings"
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.center()
  }

  func show() {
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }
}
