import BridgeCore
import Foundation
import WebKit
import os

/// Debug mode's recorder: puts `CallStats.pageScript` in the page, switches its reading to the
/// setting, and writes what it posts to one file per call. The folder is made by the first
/// sample, so a run with debug mode off leaves nothing on disk.
@MainActor
final class CallStatsRecorder: NSObject, WKScriptMessageHandler {
  private weak var page: WKWebView?
  private var log: CallStatsLog?
  private var isOn = false
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

  /// Switches the page's reading; off, the call's file closes at once, and a sample the page
  /// posted before the switch reached it is dropped.
  func set(on: Bool) {
    isOn = on
    page?.evaluateJavaScript(CallStats.switchScript(on: on))
    if !on { endCall() }
  }

  func endCall() { log?.endCall() }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard isOn, message.frameInfo.isMainFrame else { return }
    do {
      if log == nil { log = CallStatsLog(directory: try CallStats.directory()) }
      _ = try log?.record(message.body, at: Date())
    } catch {
      Self.logger.error("call stats not written: \(error.localizedDescription)")
    }
  }
}
