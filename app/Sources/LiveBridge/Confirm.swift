import AppKit
import BridgeCore

/// A native alert before the popover erases a conversation. It is app-modal rather than a sheet
/// on the menu bar window, which closes as soon as another window takes the focus.
@MainActor
enum Confirm {
  /// True when the owner chose the destructive button (Return); Cancel takes Escape.
  static func ask(_ confirmation: Confirmation) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = confirmation.title
    alert.informativeText = confirmation.message
    let confirm = alert.addButton(withTitle: confirmation.confirm)
    confirm.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    NSApp.activate()  // a menu bar app is not active, so its alert would open behind others
    return alert.runModal() == .alertFirstButtonReturn
  }
}
