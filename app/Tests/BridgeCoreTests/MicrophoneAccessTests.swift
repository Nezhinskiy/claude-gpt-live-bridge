import Foundation
import Testing

@testable import BridgeCore

struct MicrophoneAccessTests {
  /// Only an answer of macOS's own counts: undetermined is asked first, and every refusal says
  /// where to allow the microphone.
  @Test func eachAnswerMapsToItsSentence() {
    #expect(MicrophoneAccess.granted.problem == nil)
    #expect(MicrophoneAccess.undetermined.mustAsk)
    #expect(!MicrophoneAccess.granted.mustAsk && !MicrophoneAccess.denied.mustAsk)
    for refused in [MicrophoneAccess.denied, .restricted] {
      #expect(refused.problem == MicrophoneAccess.deniedSentence)
    }
    #expect(MicrophoneAccess.deniedSentence.contains("Privacy & Security > Microphone"))
    #expect(MicrophoneAccess(asked: true) == .granted && MicrophoneAccess(asked: false) == .denied)
  }

  /// The popover offers to open the setting for the page's refusal as for the app's own.
  @Test func theSettingButtonFollowsTheDeniedSentence() throws {
    var status = StatusPresentationTests.status(.off, problem: MicrophoneAccess.deniedSentence)
    #expect(StatusPresentation(status).opensMicrophoneSettings)
    status.problem = "No microphone is connected."
    #expect(!StatusPresentation(status).opensMicrophoneSettings)
    let page = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "../../Sources/LiveBridge/Resources/audio/audio.js").standardized
    #expect(try String(contentsOf: page, encoding: .utf8).contains(MicrophoneAccess.deniedSentence))
    #expect(
      MicrophoneAccess.settingsURL.absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
  }
}
