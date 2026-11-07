import AppKit
import BridgeCore
import SwiftUI

/// The reset times beside a limit row. A window of its own, not a tooltip: over a menu a tooltip
/// can stay after the pointer has left, and it takes clicks. This one goes with the pointer and
/// clicks pass through it.
@MainActor
final class LimitHint {
  /// As long as the pointer rests on a row before its hint shows.
  private static let delay: TimeInterval = 0.4

  private let panel = NSPanel(
    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
    defer: true)
  private var showing: Timer?

  init() {
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle,
    ]
  }

  /// Shows `text` after the delay, beside the menu in `frame`, unless `hide` comes first. A timer
  /// in the common modes, not a task: a menu opened from the main actor holds it until it closes.
  func show(_ text: String, beside frame: NSRect) {
    showing?.invalidate()
    let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.present(text, beside: frame) }
    }
    RunLoop.main.add(timer, forMode: .common)
    showing = timer
  }

  func hide() {
    showing?.invalidate()
    showing = nil
    panel.orderOut(nil)
  }

  private func present(_ text: String, beside frame: NSRect) {
    let host = NSHostingView(rootView: Bubble(text: text))
    host.setFrameSize(host.fittingSize)
    panel.contentView = host
    let pointer = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    panel.setFrame(
      NSRect(
        origin: HintPlacement.origin(
          size: host.fittingSize, beside: frame, pointerY: pointer.y,
          on: screen?.visibleFrame ?? frame),
        size: host.fittingSize),
      display: true)
    panel.orderFront(nil)
  }

  private struct Bubble: View {
    let text: String

    var body: some View {
      Text(text)
        .font(MenuStyle.subtitle)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .rect(cornerRadius: MenuStyle.highlightRadius))
    }
  }
}
