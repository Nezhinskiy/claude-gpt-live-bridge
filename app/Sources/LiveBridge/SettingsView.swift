import AppKit
import BridgeCore
import SwiftUI

/// LiveBridge's Settings window: the voice and its prompt, notifications, automatic
/// context and Open at login.
struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section("Voice") {
        Picker("Voice", selection: $model.voice) {
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
          "Prompt", text: $model.prompt, prompt: Text("Speak with me in Spanish"), axis: .vertical
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
      Section("Notifications") {
        Toggle("Notify when a result is waiting", isOn: $model.notifyResults)
        Text("With the chime, a notification names the session; it never shows the result.")
          .font(.caption).foregroundStyle(.secondary)
        if model.notifyResults, model.notificationsDenied {
          Label(Notifier.deniedSentence, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).symbolRenderingMode(.multicolor)
          Button("Open Notifications Settings") { NSWorkspace.shared.open(Notifier.settingsURL) }
        }
      }
      Section("Context") {
        Toggle(
          "Load a session's context automatically when it becomes the target",
          isOn: $model.autoContext)
        Text("Otherwise only Load context in the menu sends it.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("General") {
        Toggle("Open at login", isOn: $model.openAtLogin)
        if let problem = model.loginProblem {
          Label(problem, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).symbolRenderingMode(.multicolor)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
    .background(FrontWindow())
    .onAppear {
      NSApp.activate()
      model.listVoices()
    }
    .task { await model.refreshNotificationStatus() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in Task { await model.refreshNotificationStatus() } }
  }

  /// codex's voices; until they are listed, the choice already made, so the picker shows it.
  private var choices: [String] {
    if case .loaded(let voices) = model.voices { return voices }
    return model.voice.map { [$0] } ?? []
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
          model.voice.map { "The line keeps \($0.capitalized)." }
            ?? "The line keeps codex's default voice."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Try Again") { model.listVoices() }
      }
    }
  }
}

/// Brings the Settings window to the front: a menu bar app (`LSUIElement`) is not active, so the
/// window would otherwise open behind the frontmost app's.
private struct FrontWindow: NSViewRepresentable {
  final class Fronting: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      NSApp.activate()
      window.makeKeyAndOrderFront(nil)
      window.orderFrontRegardless()
    }
  }

  func makeNSView(context: Context) -> Fronting { Fronting() }
  func updateNSView(_ view: Fronting, context: Context) {}
}
