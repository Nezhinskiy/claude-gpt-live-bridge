import Foundation
import Testing

@testable import BridgeCore

struct MicrophoneAccessTests {
  /// Only an answer of macOS's own counts: undetermined is asked first, and every refusal is the
  /// problem whose menu opens the setting.
  @Test func eachAnswerMapsToItsProblem() {
    #expect(MicrophoneAccess.granted.problem == nil)
    #expect(MicrophoneAccess.undetermined.mustAsk)
    #expect(!MicrophoneAccess.granted.mustAsk && !MicrophoneAccess.denied.mustAsk)
    for refused in [MicrophoneAccess.denied, .restricted] {
      #expect(refused.problem == .microphoneDenied)
    }
    #expect(MicrophoneAccess(asked: true) == .granted && MicrophoneAccess(asked: false) == .denied)
  }

  /// The page's refusal is the same problem as the app's own: the page names it, and the app
  /// says it.
  @Test func thePagesRefusalIsTheSameProblem() throws {
    #expect(AudioEvent(body: ["type": "microphoneDenied"]) == .failed(.microphoneDenied))
    let page = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "../../Sources/LiveBridge/Resources/audio/audio.js").standardized
    #expect(try String(contentsOf: page, encoding: .utf8).contains("type: 'microphoneDenied'"))
  }
}
