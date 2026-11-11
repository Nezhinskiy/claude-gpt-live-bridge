import AppKit
import BridgeCore

/// A native alert before an action the owner may not mean: the menu's items that erase a
/// conversation (the menu has closed by then, `StatusMenu.closeThen`), and the reconnect of an
/// open voice line that Connect over TCP asks, from Settings or the menu's Quick Settings. The
/// alert is app-modal and stands above other apps' windows.
@MainActor
enum Confirm {
  /// True only when the owner clicks the destructive button. Cancel is the default button, as
  /// the macOS guidelines ask of a destructive alert: Return and Escape both cancel.
  static func ask(_ confirmation: Confirmation) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = confirmation.title
    alert.informativeText = confirmation.message
    alert.addButton(withTitle: "Cancel")  // the first button takes Return
    let confirm = alert.addButton(withTitle: confirmation.confirm)
    confirm.hasDestructiveAction = true
    // Cancel holds Return, so Escape has no button of its own: it ends the alert as a cancel.
    let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard event.keyCode == 53 else { return event }
      NSApp.abortModal()
      return nil
    }
    defer { escape.map(NSEvent.removeMonitor) }
    alert.layout()
    alert.window.level = .modalPanel
    NSApp.activate()  // a menu bar app is not active, so its alert would open behind others
    return alert.runModal() == .alertSecondButtonReturn
  }
}
