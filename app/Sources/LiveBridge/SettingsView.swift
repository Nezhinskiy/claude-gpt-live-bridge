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
  /// The owner picked Custom… over a listed summary model, which stays in force until a check works.
  @State private var picksCustom = false
  /// The custom model id as typed, kept after a refusal for correcting.
  @State private var customModel = ""
  @State private var isChecking = false
  /// Why the last check did not save the typed id.
  @State private var checkMessage: String?

  var body: some View {
    Group {
      switch tab {
      case .general: generalTab
      case .voice: voiceTab
      case .line: lineTab
      case .context: contextTab
      }
    }
    // No fixed height: the grouped form's ideal height is all of its content, which is what the
    // window measures, and in a window capped at the screen it scrolls in the height it gets.
    .frame(width: 480)
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
            + "is written from the transcript, paused text included, and goes to OpenAI. A mod of "
            + "this version leaves out tool output, thinking and reminders, but not text that "
            + "quotes them."
        )
        .font(.caption).foregroundStyle(.secondary)
        Picker("Summary model", selection: summaryModelChoice) {
          ForEach(SummaryModel.listed, id: \.id) { Text($0.name).tag($0.id) }
          Text("Custom…").tag(Self.custom)
        }
        .disabled(isChecking)  // a check that works stores its model over a later pick
        if summaryModelChoice.wrappedValue == Self.custom {
          customModelField
        }
        Text(
          "Writes the summary the voice gets as context, always at low effort, on your Claude "
            + "usage. If another model fails, Haiku 5.5 writes it instead."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let line = model.update?.lastSummary?.line {
          Text(line).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: model.settingsOpenings) { showModelInForce() }
  }

  /// Settings opened again: the picker shows the model in force, not a Custom… pick or text that
  /// no check saved. A check still running keeps its field, which its result fills in.
  private func showModelInForce() {
    guard !isChecking else { return }
    picksCustom = false
    customModel = isListed ? "" : model.settings.current.summaryModel
    checkMessage = nil
  }

  /// The tag of Custom… in the picker, which no model id can be.
  private static let custom = " custom"

  private var isListed: Bool {
    SummaryModel.listed.contains { $0.id == model.settings.current.summaryModel }
  }

  /// The picker's choice: a listed model is stored at once, with no check; Custom… only shows the
  /// field, and the stored model stays in force.
  private var summaryModelChoice: Binding<String> {
    Binding {
      picksCustom || !isListed ? Self.custom : model.settings.current.summaryModel
    } set: { picked in
      checkMessage = nil
      guard picked != Self.custom else {
        picksCustom = true
        return
      }
      picksCustom = false
      model.settings.update { $0.summaryModel = picked }
    }
  }

  /// The custom id and **Check and save**, which alone spends a request; text that cannot be an id,
  /// or the id already stored, checks nothing.
  private var customModelField: some View {
    let id = SummaryModel.accepted(customModel)
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField("Model id", text: $customModel, prompt: Text("claude-…"))
          .labelsHidden()
          .onSubmit { check(id) }
        Button(isChecking ? "Checking…" : "Check and save") { check(id) }
          .disabled(isChecking || id == nil || id == model.settings.current.summaryModel)
      }
      if let checkMessage {
        warning(checkMessage)
      }
    }
    .onAppear {
      if !isListed, customModel.isEmpty { customModel = model.settings.current.summaryModel }
    }
  }

  private func check(_ id: String?) {
    guard !isChecking, let id, id != model.settings.current.summaryModel else { return }
    isChecking = true
    checkMessage = nil
    Task {
      checkMessage = await model.checkSummaryModel(id).message
      isChecking = false
    }
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
      Section("Debug") {
        Toggle(
          "Debug mode",
          isOn: Binding {
            model.settings.current.debugMode
          } set: {
            model.setDebugMode($0)
          })
        Text(
          "Records the voice's network numbers once a second during a call, one CSV per call, in "
            + "LiveBridge's data folder under debug/call-stats. No audio, no transcript, no "
            + "session names; nothing leaves this Mac."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Show Debug Files") { model.showDebugFiles() }
      }
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
    // On another screen, or a screen whose visible frame changed, the tab is fitted again.
    let center = NotificationCenter.default
    for (name, object) in [
      (NSWindow.didChangeScreenNotification, window),
      (NSApplication.didChangeScreenParametersNotification, nil),
    ] {
      center.addObserver(forName: name, object: object, queue: .main) { [tabs] _ in
        MainActor.assumeIsolated { tabs.selectedPage?.fitWindow() }
      }
    }
  }

  func show() {
    tabs.select(tabs.model.settingsTab)
    if !window.isVisible {
      tabs.model.settingsOpenings += 1
      // Sized before it shows, so it opens at its height rather than sliding to it, and
      // centered the first time at that height; after that it opens where it was left.
      // `center()` puts it above the middle, which can push a tall window's top under the menu
      // bar, so the centred window is fitted again.
      tabs.selectedPage?.fitWindow()
      if !placed {
        window.center()
        tabs.selectedPage?.fitWindow()
      }
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
/// still, the way a Mac settings window moves between tabs, but no taller than the screen's
/// visible frame (`SettingsWindowFit`); a taller form scrolls. AppKit's own fitting snaps, since
/// it sizes the window through layout constraints, so the form gives the window no constraint
/// and reports its height instead.
@MainActor
private final class SettingsPage: NSViewController {
  private let form: NSHostingController<SettingsView>
  private var height: NSKeyValueObservation?
  /// The height the form is shown at. It sits on a holder around the form: AppKit gives the
  /// form's own view a height of its preferred size, at a priority above the window's, which
  /// would pull the window to the form's full height if the form were tied to the window.
  private var shown: NSLayoutConstraint!

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
    let holder = NSView()
    holder.translatesAutoresizingMaskIntoConstraints = false
    form.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(holder)
    holder.addSubview(form.view)
    shown = holder.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      holder.topAnchor.constraint(equalTo: view.topAnchor),
      holder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      holder.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      shown,
      form.view.topAnchor.constraint(equalTo: holder.topAnchor),
      form.view.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
      form.view.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
      form.view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
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
    let frame = SettingsWindowFit.frame(
      window: window.frame, content: content.frame, preferred: size,
      visible: window.screen?.visibleFrame)
    shown.constant = frame.height - (window.frame.height - content.frame.height)
    guard frame != window.frame else { return }
    if window.isVisible {
      NSAnimationContext.runAnimationGroup { _ in window.animator().setFrame(frame, display: true) }
    } else {
      window.setFrame(frame, display: false)
    }
  }
}
