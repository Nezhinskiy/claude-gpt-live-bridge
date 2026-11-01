import AppKit
import BridgeCore
import WebKit

/// The audio side of the call: one `WKWebView` in a window that is never shown, owning the
/// microphone, local voice detection, the pre-roll and the WebRTC peer (ADR 0001 (a), (c)).
/// The page is the bundled `audio/index.html`, served under its own scheme; it may not navigate
/// anywhere else, and only its main frame may capture the microphone.
@MainActor
final class AudioHost: NSObject, AudioSide {
  var onEvent: (AudioEvent) -> Void = { _ in }
  /// The input level while the line is open, 0 to 1.
  var onLevel: (Double) -> Void = { _ in }
  private let webView: WKWebView
  private let window = NSWindow(
    contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1), styleMask: .borderless,
    backing: .buffered, defer: true)
  private let fakeMic: URL?
  private var loaded = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  /// `fakeMic` (debug builds only) replaces the microphone with a WAV file.
  init(fakeMic: URL?) {
    self.fakeMic = fakeMic
    let config = WKWebViewConfiguration()
    config.preferences.inactiveSchedulingPolicy = .none  // a hidden page is not suspended
    config.mediaTypesRequiringUserActionForPlayback = []
    config.setURLSchemeHandler(PageFiles(fakeMic: fakeMic), forURLScheme: AudioPage.scheme)
    webView = WKWebView(frame: .zero, configuration: config)
    super.init()
    config.userContentController.add(self, name: "bridge")
    webView.navigationDelegate = self
    webView.uiDelegate = self
    window.contentView = webView
    webView.load(URLRequest(url: AudioPage.url))
  }

  // MARK: AudioSide

  func startListening() async {
    do { try await call("return await LB.listen(fake)", ["fake": fakeMic != nil]) } catch {
      onEvent(.failed("The audio page did not start: \(Self.message(error))"))
    }
  }

  func stopListening() async { _ = try? await call("LB.stop()") }

  func makeOffer() async throws -> String {
    guard let sdp = try await call("return await LB.makeOffer()") as? String else {
      throw PageError(message: "The audio page returned no offer.")
    }
    return sdp
  }

  func applyAnswer(_ sdp: String) async throws {
    try await call("return await LB.applyAnswer(sdp)", ["sdp": sdp])
  }

  func flushPreroll() async { _ = try? await call("LB.flushPreroll()") }

  func closePeer() async { _ = try? await call("LB.closePeer()") }

  func chime() async { NSSound(named: "Glass")?.play() }

  // MARK: The page

  /// Runs `body` as an async function in the page once it has loaded; a rejected promise
  /// throws its message.
  @discardableResult
  private func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
    if !loaded { await withCheckedContinuation { waiting.append($0) } }
    do {
      return try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
    } catch {
      throw PageError(message: Self.message(error))
    }
  }

  private static func message(_ error: any Error) -> String {
    let text =
      (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
      ?? error.localizedDescription
    return text.hasPrefix("Error: ") ? String(text.dropFirst(7)) : text
  }

  struct PageError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
  }
}

extension AudioHost: WKScriptMessageHandler {
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.frameInfo.isMainFrame, let decoded = PageMessage(body: message.body) else {
      return
    }
    if case .level(let value) = decoded { onLevel(value) }
    if let event = decoded.audioEvent { onEvent(event) }
  }
}

extension AudioHost: WKNavigationDelegate, WKUIDelegate {
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    let mainFrame = action.targetFrame?.isMainFrame ?? false
    return AudioPage.allowsNavigation(to: action.request.url, mainFrame: mainFrame)
      ? .allow : .cancel
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    loaded = true
    for continuation in waiting { continuation.resume() }
    waiting = []
  }

  /// WebKit ended the page's process: the call cannot go on; the page is loaded again.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    loaded = false
    onEvent(.failed("The audio page stopped unexpectedly. Start again."))
    webView.load(URLRequest(url: AudioPage.url))
  }

  func webView(
    _ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
    initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType
  ) async -> WKPermissionDecision {
    let ours = origin.protocol == AudioPage.scheme && origin.host == AudioPage.host
    return ours && frame.isMainFrame && type == .microphone ? .grant : .deny
  }
}

/// Serves the page's own files from the app bundle, and in debug builds the `--fake-mic` WAV.
private final class PageFiles: NSObject, WKURLSchemeHandler {
  private let directory = Bundle.module.url(forResource: "audio", withExtension: nil)
  private let fakeMic: URL?
  private static let types = ["html": "text/html", "js": "text/javascript", "wav": "audio/wav"]

  init(fakeMic: URL?) { self.fakeMic = fakeMic }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url, let name = AudioPage.resourceName(for: url),
      let file = name == "fake-mic.wav" ? fakeMic : directory?.appending(path: name),
      let data = try? Data(contentsOf: file)
    else { return task.didFailWithError(URLError(.fileDoesNotExist)) }
    task.didReceive(
      URLResponse(
        url: url, mimeType: Self.types[file.pathExtension] ?? "application/octet-stream",
        expectedContentLength: data.count, textEncodingName: "utf-8"))
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
