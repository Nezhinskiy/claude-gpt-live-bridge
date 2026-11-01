import AppKit
import BridgeCore
import Observation
import SwiftUI

/// What the popover knows of the panel that holds it: the visible height of the screen it opens
/// on, which caps its height (`PopoverLayout`), and how to resize or close it.
@MainActor @Observable
final class PopoverHost {
  var visibleHeight = 800.0
  /// The popover's measured height; the panel is fitted to it.
  @ObservationIgnored var fit: (Double) -> Void = { _ in }
  /// Closes the panel, as when the popover opens Settings.
  @ObservationIgnored var dismiss: () -> Void = {}
}

/// The menu bar item and its popover, the way macOS's own menu bar modules are built: an
/// `NSStatusItem` whose button shows the animated glyph, and under it a borderless,
/// non-activating panel whose one background is Liquid Glass (macOS 26 and later; the popover
/// material before) with `PopoverCorners.window` corners, a shadow that follows them, and the
/// SwiftUI popover inside. On macOS 27 the system's expanded interface session opens and closes
/// it; before, and for a panel a notification opened, the app does (`PanelMachine`).
@MainActor
final class StatusPanel: NSObject {
  private let model: AppModel
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let host = PopoverHost()
  private let panel = PopoverPanel()
  private let hosting: NSHostingView<PopoverView>
  private var machine = PanelMachine()
  private var contentHeight = 0.0
  private var monitors: [Any] = []

  /// `defaults write io.github.nezhinskiy.livebridge ExpandedInterfaceSession -bool NO` keeps
  /// the app's own handling on macOS 27 too, should the system's session misbehave.
  private static var usesSystemSession: Bool {
    UserDefaults.standard.object(forKey: "ExpandedInterfaceSession") as? Bool ?? true
  }

  init(model: AppModel) {
    self.model = model
    hosting = NSHostingView(rootView: PopoverView(model: model, host: host))
    super.init()
    // The panel is sized by hand, from the popover's measured height: the hosting view's own
    // size never moves the panel.
    hosting.sizingOptions = [.intrinsicContentSize]
    for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
      hosting.setContentHuggingPriority(.init(1), for: orientation)
      hosting.setContentCompressionResistancePriority(.init(1), for: orientation)
    }
    panel.contentView = Self.background(around: hosting)
    panel.onEscape = { [weak self] in self?.send(.escape) }
    host.fit = { [weak self] in self?.fit(height: $0) }
    host.dismiss = { [weak self] in self?.send(.dismiss) }

    if let button = item.button {
      button.imagePosition = .imageOnly
      button.target = self
      button.action = #selector(pressed)
      button.sendAction(on: [.leftMouseDown])  // as the system's own items open
    }
    #if compiler(>=6.4)
      if #available(macOS 27, *), Self.usesSystemSession {
        item.button?.action = nil
        item.expandedInterfaceDelegate = self
      }
    #endif
    showGlyph()
    observeDismissals()
  }

  /// Opens the panel, as a click on a notification does.
  func open() { send(.open) }

  @objc private func pressed() { send(.statusItemPressed) }

  private func send(_ event: PanelMachine.Event) {
    for effect in machine.handle(event) {
      switch effect {
      case .show: show()
      case .hide: hide()
      case .highlight:
        // after the button's own mouse tracking, which would undo it
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.item.button?.highlight(self.machine.highlighted)
        }
      case .cancelSession:
        #if compiler(>=6.4)
          if #available(macOS 27, *) { item.expandedInterfaceSession?.cancel() }
        #endif
      }
    }
  }

  // MARK: - Showing

  private func show() {
    let screen = PanelPlacement.screen(for: buttonFrame, in: Self.screens)
    host.visibleHeight = Double(screen?.visible.height ?? 800)
    hosting.layoutSubtreeIfNeeded()
    let measured = Double(hosting.intrinsicContentSize.height)
    if measured > 0 { contentHeight = measured }
    place()
    panel.makeKeyAndOrderFront(nil)
    reshadow()
    watchClicks()
  }

  private func hide() {
    stopWatchingClicks()
    panel.orderOut(nil)
  }

  private func fit(height: Double) {
    guard height > 0, abs(height - contentHeight) > 0.5 else { return }
    contentHeight = height
    if machine.isOpen { place() }
  }

  /// Under the button, sized to the popover; the shadow is recomputed from the new shape.
  private func place() {
    let size = CGSize(width: PopoverView.width, height: max(contentHeight, 1))
    let frame = PanelPlacement.frame(size: size, under: buttonFrame, screens: Self.screens)
    if frame != panel.frame { panel.setFrame(frame, display: true) }
    reshadow()
  }

  /// The window server builds a borderless window's shadow from what it has drawn when asked.
  /// Asked before the glass has drawn, it takes the whole rectangle, and a dark square rim shows
  /// past the rounded corners; so it is asked again once the panel has displayed.
  private func reshadow() {
    guard panel.isVisible else { return }
    panel.display()
    DispatchQueue.main.async { [panel] in panel.invalidateShadow() }
  }

  /// The status item's button in screen coordinates, if it is in the menu bar.
  private var buttonFrame: CGRect? {
    guard let button = item.button, let window = button.window else { return nil }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  private static var screens: [PanelPlacement.Screen] {
    NSScreen.screens.map { PanelPlacement.Screen(frame: $0.frame, visible: $0.visibleFrame) }
  }

  /// One translucent background with large corners: Liquid Glass, or before macOS 26 the
  /// popover material behind a rounded mask. Its shape is what the window's shadow follows.
  private static func background(around content: NSView) -> NSView {
    let radius = popoverCorners.window
    #if compiler(>=6.2)
      if #available(macOS 26, *) {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = radius
        glass.contentView = content
        return glass
      }
    #endif
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.maskImage = roundedMask(radius: radius)
    content.frame = effect.bounds
    content.autoresizingMask = [.width, .height]
    effect.addSubview(content)
    return effect
  }

  /// A stretchable rounded rectangle for `NSVisualEffectView.maskImage`.
  private static func roundedMask(radius: Double) -> NSImage {
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

  // MARK: - The glyph

  /// The button shows the glyph's current frame and the call's accessibility label.
  private func showGlyph() {
    withObservationTracking {
      item.button?.image = model.glyph.image
      item.button?.setAccessibilityLabel(model.presentation?.accessibilityLabel ?? "LiveBridge")
    } onChange: { [weak self] in
      Task { @MainActor in self?.showGlyph() }
    }
  }

  // MARK: - Dismissal

  /// Mouse clicks while the panel is open: in other apps (global) and in the app's own windows
  /// (local), where the panel, its button and a confirmation alert do not count as outside.
  private func watchClicks() {
    guard monitors.isEmpty else { return }
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let global = NSEvent.addGlobalMonitorForEvents(
      matching: clicks,
      handler: { [weak self] _ in
        MainActor.assumeIsolated { self?.send(.click(.elsewhere)) }
      })
    {
      monitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: clicks,
      handler: { [weak self] event in
        MainActor.assumeIsolated { self?.send(.click(self?.place(of: event) ?? .elsewhere)) }
        return event
      })
    {
      monitors.append(local)
    }
  }

  private func stopWatchingClicks() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
  }

  private func place(of event: NSEvent) -> PanelMachine.Click {
    guard let window = event.window else { return .elsewhere }
    if window === panel { return .panel }
    if window === item.button?.window { return .statusItem }
    if window === NSApp.modalWindow { return .alert }
    return .elsewhere
  }

  /// Another app coming to the front, or another Space, closes the panel.
  private func observeDismissals() {
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let other = app?.processIdentifier != ProcessInfo.processInfo.processIdentifier
      MainActor.assumeIsolated { if other { self?.send(.otherAppActivated) } }
    }
    workspace.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.send(.spaceChanged) }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.machine.isOpen else { return }
        self.place()
      }
    }
  }
}

#if compiler(>=6.4)
  /// macOS 27: the system tells the app when to show and hide its expanded interface, draws the
  /// button's highlight and takes part in the menu bar's keyboard navigation.
  @available(macOS 27, *)
  extension StatusPanel: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(
      _ statusItem: NSStatusItem,
      didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession
    ) {
      send(.sessionBegan)
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
      send(.sessionEnded)
    }
  }
#endif

/// A borderless, non-activating panel: it takes the keyboard (Escape, ⌘, and ⌘Q, the alerts'
/// return) without bringing LiveBridge in front of the app being used, and draws only its
/// content, so its corners and shadow are the glass's own.
final class PopoverPanel: NSPanel {
  /// A menu's level, as the menu bar's own modules; the popover's alerts stand above it.
  static let level = NSWindow.Level.popUpMenu
  var onEscape: () -> Void = {}

  init() {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: true)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = Self.level
    hidesOnDeactivate = false  // the panel's own rules close it
    isReleasedWhenClosed = false
    isMovable = false
    animationBehavior = .utilityWindow
    collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func cancelOperation(_ sender: Any?) { onEscape() }
}

/// The corners of the popover's panel and of its cards (`PopoverCorners`).
@MainActor let popoverCorners = PopoverCorners(glass: hasLiquidGlass)

@MainActor private var hasLiquidGlass: Bool {
  #if compiler(>=6.2)
    if #available(macOS 26, *) { return true }
  #endif
  return false
}
