import BridgeCore
import SwiftUI

/// The menu bar popover: the call, the sessions, the target's context line and last lines (each
/// session has its own conversation with the voice), the minutes, and the app's own settings.
/// Liquid Glass on macOS 26 and later, materials before. Like macOS's own menu bar modules, the
/// window has one translucent background with large corners, and the cards inside are subtle
/// fills concentric with it. It never grows past the screen's visible height (a taller menu bar
/// window leaves a transparent band at its top): the sessions (five rows), the last lines and
/// what was sent scroll inside their own caps, and past the screen the whole popover scrolls.
struct PopoverView: View {
  @Bindable var model: AppModel
  @State private var showContext = false
  /// The command just copied, which its button says for two seconds.
  @State private var copied: String?
  @State private var showHelp = false
  /// The popover's own height, which its window is fitted to.
  @State private var height = 0.0
  /// The tallest session row, measured; the list shows five of them.
  @State private var rowHeight = 0.0
  /// The window's own background was found and reshaped; otherwise the popover draws one.
  @State private var systemBackground = true
  @Environment(\.openSettings) private var openSettings

  /// Opens Settings in front: the app is activated first, as a menu bar app is not active.
  private func showSettings() {
    NSApp.activate()
    openSettings()
  }

  private var layout: PopoverLayout {
    PopoverLayout(visibleHeight: Double(NSScreen.main?.visibleFrame.height ?? 800))
  }

  var body: some View {
    GlassGroup {
      CappedScroll(cap: layout.maxHeight) { content }
    }
    .frame(width: 340)
    .background {
      if !systemBackground { PopoverBackground(radius: popoverCorners.window) }
    }
    .clipShape(.rect(cornerRadius: popoverCorners.window, style: .circular))
    .onGeometryChange(for: Double.self) {
      Double($0.size.height)
    } action: {
      height = $0
    }
    .background(WindowFitter(height: height))
    .background(
      WindowStyler(radius: popoverCorners.window, foundSystemBackground: $systemBackground))
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let shown = model.presentation {
        call(shown)
        if let problem = model.problem {
          problemBanner(
            problem, opensSettings: shown.opensMicrophoneSettings, help: shown.codexHelp)
        }
        sessions(shown)
        context
        if !(model.status?.recentTranscript.isEmpty ?? true) { lastLines }
        footer(shown)
      } else {
        if let problem = model.problem { problemBanner(problem) } else { ProgressView() }
        Button("Quit LiveBridge") { NSApplication.shared.terminate(nil) }
      }
    }
    .padding(12)
  }

  private func call(_ shown: StatusPresentation) -> some View {
    HStack(spacing: 10) {
      Image(nsImage: model.glyph.image)
        .renderingMode(.template)
        .foregroundStyle(tint(shown.tint))
        .frame(width: 36, height: 36)
        .background(tint(shown.tint).opacity(0.18), in: .circle)
      VStack(alignment: .leading, spacing: 2) {
        Text(shown.headline).font(.headline)
        Text(shown.detail).font(.caption).foregroundStyle(.secondary)
        if shown.unheard > 0 {
          Label("\(shown.unheard) unheard — speak to hear", systemImage: "circle.fill")
            .font(.caption2).foregroundStyle(.tint)
        }
      }
      Spacer()
      Button(shown.action == .start ? "Start" : "Stop") { model.perform(shown.action) }
        .capsule(prominent: shown.action == .start)
        .disabled(!shown.canAct)
    }
    .card()
  }

  private func problemBanner(
    _ problem: String, opensSettings: Bool = false, help: CodexHelp? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(problem, systemImage: "exclamationmark.triangle.fill")
        .font(.callout).symbolRenderingMode(.multicolor).lineLimit(6)
      if opensSettings {
        Button("Open Microphone Settings", systemImage: "mic") {
          NSWorkspace.shared.open(MicrophoneAccess.settingsURL)
        }
        .capsule(prominent: false)
      }
      if let help {
        Button(help.button, systemImage: showHelp ? "chevron.up" : "questionmark.circle") {
          showHelp.toggle()
        }
        .capsule(prominent: false)
        if showHelp {
          VStack(alignment: .leading, spacing: 8) {
            Text(help.steps).font(.caption).fixedSize(horizontal: false, vertical: true)
            Text(help.command).font(.caption.monospaced()).textSelection(.enabled)
            copyButton(help.command, title: help.copy)
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        }
      }
    }
    .card()
  }

  private func sessions(_ shown: StatusPresentation) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Sessions").font(.caption).foregroundStyle(.secondary)
      if shown.offersJoinCommand {
        HStack {
          Text("No session has joined.")
            .font(.callout).foregroundStyle(.secondary)
          Spacer()
          copyButton(
            StatusPresentation.joinCommand, title: "Copy \(StatusPresentation.joinCommand)"
          )
          .help("Copy \(StatusPresentation.joinCommand), then run it in a Claude Code session")
        }
      }
      CappedScroll(cap: PopoverLayout.sessionsCap(rowHeight: rowHeight, spacing: 4)) {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(shown.rows) { row in
            HStack(spacing: 4) {
              targetButton(row)
              Button {
                model.remove(row)
              } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .frame(width: 22, height: 22).contentShape(.rect)
              }
              .buttonStyle(.plain)
              .help("Remove from LiveBridge and erase its conversation; /live on joins it again")
              .accessibilityLabel("Remove \(row.label) from LiveBridge")
            }
            .onGeometryChange(for: Double.self) {
              Double($0.size.height)
            } action: {
              if $0 > rowHeight { rowHeight = $0 }
            }
          }
        }
      }
    }
    .card()
  }

  /// Copies `command`, to paste into a Claude Code session or Terminal; says so for two seconds.
  private func copyButton(_ command: String, title: String) -> some View {
    Button(
      copied == command ? "Copied" : title,
      systemImage: copied == command ? "checkmark" : "doc.on.doc"
    ) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(command, forType: .string)
      copied = command
      Task {
        try? await Task.sleep(for: .seconds(2))
        if copied == command { copied = nil }
      }
    }
    .capsule(prominent: false)
  }

  private func targetButton(_ row: SessionRowPresentation) -> some View {
    Button {
      model.setTarget(row.id)
    } label: {
      HStack {
        Image(systemName: row.isTarget ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(row.isTarget ? Color.accentColor : .secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(row.label).lineLimit(1)
          Label(row.detail, systemImage: Self.symbol(of: row.activity))
            .font(.caption)
            .foregroundStyle(row.activity == .approval ? .orange : .secondary)
        }
        Spacer()
      }
      .padding(6)
      .background(
        row.isTarget ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 8)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(row.isTarget ? .isSelected : [])
  }

  private static func symbol(of activity: SessionActivity) -> String {
    switch activity {
    case .idle: "moon.zzz"
    case .working: "arrow.triangle.2.circlepath"
    case .approval: "exclamationmark.circle"
    }
  }

  private var context: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button(model.contextLoad.title, systemImage: model.contextLoad.symbol) {
          model.loadContext()
        }
        .disabled(!model.contextLoad.isEnabled)
        .help("Ask the target session for a summary of its work, for the voice")
        Button("New conversation", systemImage: "square.and.pencil") { model.newConversation() }
          .help("Erase the voice's conversation with the target session")
      }
      .capsule(prominent: false)
      if let sent = model.status?.lastContext {
        DisclosureGroup("What was sent", isExpanded: $showContext) {
          CappedScroll(cap: layout.sent) {
            Text(sent).font(.caption).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.top, 4)
        }
        .font(.caption)
      }
    }
    .card()
  }

  /// The target's label; the context line and the last lines are its conversation's.
  private var target: String? { model.status?.sessions.first(where: \.isTarget)?.label }

  private var lastLines: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(target.map { "Last lines with \($0)" } ?? "Last lines")
        .font(.caption).foregroundStyle(.secondary)
      CappedScroll(cap: layout.lastLines) {
        VStack(alignment: .leading, spacing: 4) {
          let lines = (model.status?.recentTranscript ?? []).map(TranscriptLine.init)
          ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            HStack(alignment: .firstTextBaseline) {
              Text(line.speaker).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
              Text(line.text).lineLimit(4).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
          }
        }
      }
    }
    .card()
  }

  private func footer(_ shown: StatusPresentation) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(shown.minutes).font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Settings…", systemImage: "gearshape") { showSettings() }
          .keyboardShortcut(",")
        Spacer()
        Button("Quit LiveBridge") { NSApplication.shared.terminate(nil) }
          .keyboardShortcut("q")
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 4)
  }

  private func tint(_ tint: Tint) -> Color {
    switch tint {
    case .quiet: .secondary
    case .active: .teal
    case .attention: .orange
    case .problem: .red
    }
  }
}

/// Fits the menu bar window to the popover's height, keeping its top edge under the menu bar.
/// A MenuBarExtra window grows with its content but never shrinks: after a session is removed
/// it keeps its old height, and the popover sits in its middle between transparent bands.
private struct WindowFitter: NSViewRepresentable {
  let height: Double

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    let height = height
    DispatchQueue.main.async {  // the view joins its window after this update
      guard let window = view.window, height > 0 else { return }
      let content = window.contentRect(forFrameRect: window.frame)
      guard abs(content.height - height) > 0.5 else { return }
      var frame = window.frameRect(
        forContentRect: NSRect(
          x: content.minX, y: content.maxY - height, width: content.width, height: height))
      frame.origin.y = window.frame.maxY - frame.height
      window.setFrame(frame, display: true)
      window.invalidateShadow()  // the shadow follows the rounded background's new height
    }
  }
}

/// The corners of the popover's window and of its cards (`PopoverCorners`).
@MainActor private let popoverCorners = PopoverCorners(glass: hasLiquidGlass)

@MainActor private var hasLiquidGlass: Bool {
  #if compiler(>=6.2)
    if #available(macOS 26, *) { return true }
  #endif
  return false
}

/// Gives the menu bar window the shape of macOS's own menu bar modules: a transparent window
/// whose one background is the system's own, reshaped to `radius`, with a shadow that follows it.
/// MenuBarExtra draws that background as an `NSVisualEffectView` (or, with Liquid Glass, an
/// `NSGlassEffectView`) behind the popover: an effect view gets a rounded mask, a glass view
/// the radius. When neither is found, `foundSystemBackground` turns false and the popover draws
/// its own (`PopoverBackground`).
private struct WindowStyler: NSViewRepresentable {
  let radius: Double
  @Binding var foundSystemBackground: Bool

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ view: NSView, context: Context) {
    let radius = radius
    let found = $foundSystemBackground
    DispatchQueue.main.async {  // the view joins its window after this update
      guard let window = view.window else { return }
      window.isOpaque = false
      window.backgroundColor = .clear
      window.hasShadow = true
      let reshaped = Self.reshapeBackgrounds(of: window, around: view, radius: radius)
      if reshaped != found.wrappedValue { found.wrappedValue = reshaped }
      window.invalidateShadow()
    }
  }

  /// The window's own background views: those around the popover's hosting view, not the
  /// popover's own effects inside it. Returns whether any was found.
  private static func reshapeBackgrounds(of window: NSWindow, around view: NSView, radius: Double)
    -> Bool
  {
    var ancestors: [NSView] = []
    var next = view.superview
    while let current = next {
      ancestors.append(current)
      next = current.superview
    }
    guard let hosting = ancestors.last(where: { $0.className.contains("HostingView") }),
      let root = ancestors.last
    else { return false }
    var found = false
    var queue = [root]
    while let current = queue.popLast() {
      guard current !== hosting else { continue }  // the popover's own views are left alone
      found = reshape(current, radius: radius) || found
      queue += current.subviews
    }
    return found
  }

  private static func reshape(_ view: NSView, radius: Double) -> Bool {
    #if compiler(>=6.2)
      if #available(macOS 26, *), let glass = view as? NSGlassEffectView {
        if glass.cornerRadius != radius { glass.cornerRadius = radius }
        return true
      }
    #endif
    guard let effect = view as? NSVisualEffectView else { return false }
    if effect.maskImage?.capInsets.top != CGFloat(radius) {
      effect.maskImage = roundedMask(radius: radius)
    }
    return true
  }

  /// A stretchable rounded rectangle for `NSVisualEffectView.maskImage`.
  static func roundedMask(radius: Double) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}

/// The popover's own background, used only when the window's could not be found: Liquid Glass
/// where the system has it, the popover material before, both rounded to `radius`.
private struct PopoverBackground: NSViewRepresentable {
  let radius: Double

  func makeNSView(context: Context) -> NSView {
    #if compiler(>=6.2)
      if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        glass.cornerRadius = radius
        return glass
      }
    #endif
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.maskImage = WindowStyler.roundedMask(radius: radius)
    return effect
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

/// A vertical scroll view as tall as its content, up to `cap` points; past it, it scrolls. A
/// plain ScrollView in a menu bar window takes no height of its own, so the content's height is
/// measured.
private struct CappedScroll<Content: View>: View {
  let cap: Double
  @ViewBuilder var content: Content
  @State private var height = 0.0

  var body: some View {
    ScrollView(.vertical) {
      content.onGeometryChange(for: Double.self) {
        Double($0.size.height)
      } action: {
        height = $0
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(height: min(height, cap))
  }
}

/// Liquid Glass where the system has it (macOS 26 and later), materials before. Its symbols
/// exist only in the macOS 26 SDK (Swift 6.2, Xcode 26), so an older Xcode builds the materials.
private struct GlassGroup<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    #if compiler(>=6.2)
      if #available(macOS 26, *) { GlassEffectContainer(spacing: 10) { content } } else { content }
    #else
      content
    #endif
  }
}

extension View {
  /// A section, as Control Center's modules draw theirs: a subtle fill on the window's one
  /// background, its corners concentric with the window's.
  @MainActor fileprivate func card() -> some View {
    frame(maxWidth: .infinity, alignment: .leading).padding(10)
      .background(.fill.tertiary, in: .rect(cornerRadius: popoverCorners.card, style: .circular))
  }

  @ViewBuilder fileprivate func capsule(prominent: Bool) -> some View {
    #if compiler(>=6.2)
      if #available(macOS 26, *) {
        if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
      } else {
        buttonStyle(.bordered).buttonBorderShape(.capsule)
      }
    #else
      buttonStyle(.bordered).buttonBorderShape(.capsule)
    #endif
  }
}
