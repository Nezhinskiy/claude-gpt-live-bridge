import AppKit
import BridgeCore
import SwiftUI

/// The Settings window's tabs, in the toolbar's order.
enum SettingsTab: CaseIterable {
  case general, voice, line, context

  var label: String {
    switch self {
    case .general: "General"
    case .voice: "Voice"
    case .line: "Line"
    case .context: "Context"
    }
  }

  /// The SF Symbol above the label.
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .voice: "waveform"
    case .line: "antenna.radiowaves.left.and.right"
    case .context: "text.bubble"
    }
  }
}

/// One tab of LiveBridge's Settings. **General**: notifications, Open at login and updates.
/// **Voice**: the voice, its prompt and the sounds. **Line**: the line's timers and how it connects.
/// **Context**: sync. The settings are read from and written to `AppModel.settings`, their one copy.
struct SettingsView: View {
  @Bindable var model: AppModel
  let tab: SettingsTab
  /// Counts the reconnects the owner cancelled, so the switch is drawn again as it was.
  @State private var cancelledReconnects = 0

  var body: some View {
    Group {
      switch tab {
      case .general: generalTab
      case .voice: voiceTab
      case .line: lineTab
      case .context: contextTab
      }
    }
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
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
    .onAppear { model.listVoices() }
  }

  private var lineTab: some View {
    Form {
      Section("Line") {
        seconds("Silence before the line closes", \.silenceSeconds)
        if (1...9).contains(model.settings.current.silenceSeconds) {
          warning(
            "Shorter than an ordinary pause: the line will close while you think, and each "
              + "reopening takes a few seconds.")
        }
        seconds("Wait for a first word on a line a result opened", \.firstWordSeconds)
        if (1...3).contains(model.settings.current.firstWordSeconds) {
          warning(
            "The voice often starts about 2 seconds after the line connects, so it can be cut off.")
        }
        Text(
          "A line opened by Claude's answer, question or approval notice waits this long for you or "
            + "the voice to speak; then it closes, and the result chimes. 0 waits as long as the "
            + "silence."
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
            + "minute while it is open, silence included. A timer turned on starts on a quiet "
            + "line at once; one already counting keeps its time."
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
    }
    .formStyle(.grouped)
  }

  private var contextTab: some View {
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
    }
    .formStyle(.grouped)
  }

  private var generalTab: some View {
    Form {
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
          warning(Notifier.deniedSentence)
          Button("Open Notifications Settings") { NSWorkspace.shared.open(Notifier.settingsURL) }
        }
      }
      Section("Login") {
        Toggle("Open at login", isOn: $model.openAtLogin)
        if let problem = model.loginProblem {
          warning(problem)
        }
      }
      UpdateSection(model: model)
    }
    .formStyle(.grouped)
    .task { await model.refreshNotificationStatus() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in Task { await model.refreshNotificationStatus() } }
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
    let value = Binding {
      model.settings.current[keyPath: key]
    } set: {
      model.setTimeout(key, $0)
    }
    return LabeledContent(title) {
      HStack(spacing: 4) {
        TextField(title, value: value, format: .number)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 48)
          .accessibilityValue("\(value.wrappedValue) seconds")
        Stepper(title, value: value, in: CallMachine.Timeouts.range)
          .labelsHidden()
          .accessibilityLabel("Change \(title.lowercased())")
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
  private let tabs: SettingsTabs
  private var placed = false

  init(model: AppModel) {
    tabs = SettingsTabs(model: model)
    window = NSWindow(contentViewController: tabs)
    window.title = SettingsTabs.title
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
  }

  func show() {
    tabs.select(tabs.model.settingsTab)
    if !window.isVisible {
      // Sized before it shows, so it opens at its height rather than sliding to it, and
      // centered the first time at that height; after that it opens where it was left.
      tabs.selectedPage?.fitWindow()
      if !placed { window.center() }
      placed = true
    }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }
}

/// The window's tabs in its toolbar, one SwiftUI form each. The tab shown follows
/// `AppModel.settingsTab` both ways.
@MainActor
private final class SettingsTabs: NSTabViewController {
  static let title = "LiveBridge Settings"
  let model: AppModel

  init(model: AppModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
    tabStyle = .toolbar
    // The window keeps its own title instead of taking the tab's label.
    canPropagateSelectedChildViewControllerTitle = false
    for tab in SettingsTab.allCases {
      let item = NSTabViewItem(viewController: SettingsPage(model: model, tab: tab))
      item.label = tab.label
      item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
      addTabViewItem(item)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("SettingsTabs is built in code") }

  func select(_ tab: SettingsTab) {
    selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab)!
  }

  var selectedPage: SettingsPage? {
    tabViewItems[selectedTabViewItemIndex].viewController as? SettingsPage
  }

  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    if let tabViewItem {
      model.settingsTab = SettingsTab.allCases[tabView.indexOfTabViewItem(tabViewItem)]
      (tabViewItem.viewController as? SettingsPage)?.fitWindow()
    }
  }
}

/// One tab: its form hangs from the top, and the window slides to the form's height, top edge
/// still, the way a Mac settings window moves between tabs. AppKit's own fitting snaps, since
/// it sizes the window through layout constraints, so the form gives the window no constraint
/// and reports its height instead.
@MainActor
private final class SettingsPage: NSViewController {
  private let form: NSHostingController<SettingsView>
  private var height: NSKeyValueObservation?

  init(model: AppModel, tab: SettingsTab) {
    form = NSHostingController(rootView: SettingsView(model: model, tab: tab))
    form.sizingOptions = .preferredContentSize
    super.init(nibName: nil, bundle: nil)
    addChild(form)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("SettingsPage is built in code") }

  override func loadView() {
    view = NSView()
    form.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(form.view)
    NSLayoutConstraint.activate([
      form.view.topAnchor.constraint(equalTo: view.topAnchor),
      form.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      form.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    // A hint that comes or goes inside the tab moves the window too.
    height = form.observe(\.preferredContentSize) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.fitWindow() }
    }
  }

  func fitWindow() {
    guard let window = view.window, let content = window.contentView else { return }
    if !window.isVisible { view.layoutSubtreeIfNeeded() }  // the form measures itself in layout
    let size = form.preferredContentSize
    guard size.height > 0 else { return }
    var frame = window.frame
    frame.size.width += size.width - content.frame.width
    frame.size.height += size.height - content.frame.height
    frame.origin.y = window.frame.maxY - frame.height
    // A window low on the screen grows upward instead, so a tall tab's bottom stays reachable.
    if let screen = window.screen?.visibleFrame {
      frame.origin.y = max(frame.origin.y, screen.minY)
    }
    guard frame != window.frame else { return }
    if window.isVisible {
      NSAnimationContext.runAnimationGroup { _ in window.animator().setFrame(frame, display: true) }
    } else {
      window.setFrame(frame, display: false)
    }
  }
}
