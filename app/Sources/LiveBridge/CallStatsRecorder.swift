#if DEBUG
  import BridgeCore
  import Foundation
  import WebKit

  /// `--call-stats`: puts `CallStats.pageScript` in the page and writes what it posts to one file
  /// per call. A debug build's own: see `CallStats`.
  @MainActor
  final class CallStatsRecorder: NSObject, WKScriptMessageHandler {
    private let log: CallStatsLog

    private init(log: CallStatsLog) { self.log = log }

    /// Nil without `--call-stats`, or when the folder cannot be made (it prints why, which only a
    /// terminal shows): the call goes on unrecorded.
    static func install(in config: WKWebViewConfiguration) -> CallStatsRecorder? {
      guard CommandLine.arguments.contains("--call-stats") else { return nil }
      do {
        let directory = try CallStats.directory()
        let recorder = CallStatsRecorder(log: CallStatsLog(directory: directory))
        config.userContentController.add(recorder, name: CallStats.handlerName)
        config.userContentController.addUserScript(
          WKUserScript(
            source: CallStats.pageScript + CallStats.switchScript(on: true),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        say("call stats: on, one file per call in \(directory.path)")
        return recorder
      } catch {
        say("call stats: off, \(error.localizedDescription)")
        return nil
      }
    }

    func endCall() { log.endCall() }

    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.frameInfo.isMainFrame else { return }
      do {
        if let file = try log.record(message.body, at: Date()) {
          Self.say("call stats: writing \(file.path)")
        }
      } catch {
        Self.say("call stats: not written, \(error.localizedDescription)")
      }
    }

    /// Unbuffered, so the line shows at once in the terminal `build-app.sh --run` started from.
    private static func say(_ text: String) {
      try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }
  }
#endif
