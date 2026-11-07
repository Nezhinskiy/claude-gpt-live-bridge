import AVFoundation
import AppKit
import BridgeCore
import WebKit

/// The audio side of the call: one `WKWebView` owning the microphone, local voice detection, the
/// pre-roll and the WebRTC peer (ADR 0001 (a), (c)). Its window is on screen but invisible (one
/// point, fully transparent, click-through, on every Space): WebKit holds back the microphone of
/// a page whose view is not visible. The page is the bundled `audio/index.html`, served under its
/// own scheme; it may not navigate anywhere else, and only its main frame may capture the
/// microphone.
@MainActor
final class AudioHost: NSObject, AudioSide {
  var onEvent: (AudioEvent) -> Void = { _ in }
  /// The input level while the line is open, 0 to 1.
  var onLevel: (Double) -> Void = { _ in }
  private let webView: WKWebView
  private let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless,
    backing: .buffered, defer: false)
  private let fakeMic: URL?
  /// The page's own load; a navigation the lock cancels is not it.
  private var navigation: WKNavigation?
  private var loaded = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  private let chimeSound = bundledSound("chime")
  private let handoffSound = bundledSound("handoff")

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
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.orderFrontRegardless()
    load()
  }

  private func load() { navigation = webView.load(URLRequest(url: AudioPage.url)) }

  /// A bundled `audio/<name>.wav`, which `scripts/render-sound.mjs` renders.
  private static func bundledSound(_ name: String) -> NSSound? {
    Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "audio")
      .flatMap { NSSound(contentsOf: $0, byReference: true) }
  }

  // MARK: AudioSide

  /// macOS's answer, asking it first if it never was (its prompt then shows); the fake
  /// microphone needs no permission.
  func microphoneProblem() async -> Problem? {
    guard fakeMic == nil else { return nil }
    var access: MicrophoneAccess =
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .authorized: .granted
      case .notDetermined: .undetermined
      case .restricted: .restricted
      default: .denied
      }
    if access.mustAsk {
      access = MicrophoneAccess(asked: await AVCaptureDevice.requestAccess(for: .audio))
    }
    return access.problem
  }

  func startListening() async {
    await run("return await LB.listen(fake)", ["fake": fakeMic != nil], failing: "start")
  }

  func stopListening() async { _ = try? await call("LB.stop()") }

  /// Fails closed: a page that cannot confirm the release ends the call, whose `LB.stop`
  /// releases the microphone, rather than showing Muted over an open microphone.
  func muteMicrophone() async { await run("LB.mute()", failing: "mute") }

  /// Waits for the microphone; the page reports a refusal itself, so only a page that cannot
  /// be reached fails here.
  func unmuteMicrophone() async { await run("return await LB.unmute()", failing: "unmute") }

  func makeOffer(preroll: Bool) async throws -> String {
    guard
      let sdp = try await call("return await LB.makeOffer(preroll)", ["preroll": preroll])
        as? String
    else {
      throw PageError(message: "The audio page returned no offer.")
    }
    return sdp
  }

  func applyAnswer(_ sdp: String) async throws {
    try await call("return await LB.applyAnswer(sdp)", ["sdp": sdp])
  }

  func flushPreroll() async { _ = try? await call("LB.flushPreroll()") }

  func closePeer() async { _ = try? await call("LB.closePeer()") }

  func chime() async { chimeSound?.play() }

  func confirmHandoff() async { handoffSound?.play() }

  func confirmAnswer() async { chimeSound?.play() }

  // MARK: The page

  /// A page call the call cannot go on without: its failure ends the call, saying which
  /// step the page did not do.
  private func run(_ body: String, _ arguments: [String: Any] = [:], failing verb: String)
    async
  {
    do { try await call(body, arguments) } catch {
      onEvent(.failed(.other("The audio page did not \(verb): \(Self.message(error))")))
    }
  }

  /// Runs `body` as an async function in the page once it has loaded; a rejected promise
  /// throws its message, and a page that failed to load throws (and loads again next time).
  @discardableResult
  private func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
    if !loaded, navigation == nil { load() }
    if !loaded { await withCheckedContinuation { waiting.append($0) } }
    guard loaded else { throw PageError(message: "The audio page did not load.") }
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
    guard message.frameInfo.isMainFrame, let event = AudioEvent(body: message.body) else {
      return
    }
    if case .level(let value) = event { onLevel(value) } else { onEvent(event) }
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
    settle(navigation, loaded: true)
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
  ) { settle(navigation, loaded: false) }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) { settle(navigation, loaded: false) }

  /// The page's load ended: whoever waits for it goes on, and fails if it did not load.
  private func settle(_ ended: WKNavigation?, loaded: Bool) {
    guard let ended, ended === navigation else { return }
    navigation = nil
    self.loaded = loaded
    for continuation in waiting { continuation.resume() }
    waiting = []
  }

  /// WebKit ended the page's process: the call cannot go on; the page is loaded again.
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    loaded = false
    onEvent(.failed(.other("The audio page stopped unexpectedly. Start again.")))
    load()
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
