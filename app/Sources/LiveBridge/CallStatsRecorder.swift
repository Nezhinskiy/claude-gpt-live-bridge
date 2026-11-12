import BridgeCore
import Foundation
import WebKit
import os

/// Debug mode's recorder: puts `CallStats.pageScript` in the page, switches its reading and the
/// log to the setting, and hands what the page posts to `CallStatsLog`, which drops it while
/// debug mode is off.
@MainActor
final class CallStatsRecorder: NSObject, WKScriptMessageHandler {
  private weak var page: WKWebView?
  private let log = CallStatsLog(directory: CallStats.directory)
  private static let logger = Logger(subsystem: Paths.bundleID, category: "call-stats")

  /// Installs the script for the page's next load; it reads nothing until `set(on: true)`.
  init(page: WKWebView) {
    self.page = page
    super.init()
    let content = page.configuration.userContentController
    content.add(self, name: CallStats.handlerName)
    content.addUserScript(
      WKUserScript(
        source: CallStats.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
  }

  /// Switches the page's reading and the log; off, the call's file closes at once.
  func set(on: Bool) {
    log.set(on: on)
    page?.evaluateJavaScript(CallStats.switchScript(on: on))
  }

  func endCall() { log.endCall() }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame else { return }
    do {
      _ = try log.record(message.body, at: Date())
    } catch {
      Self.logger.error("call stats not written: \(error.localizedDescription, privacy: .public)")
    }
  }
}
