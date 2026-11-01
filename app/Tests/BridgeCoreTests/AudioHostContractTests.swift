import Foundation
import Testing

@testable import BridgeCore

struct AudioHostContractTests {
  @Test func pageMessagesDecode() {
    #expect(PageMessage(body: ["type": "speechStarted"]) == .speechStarted)
    #expect(PageMessage(body: ["type": "speechEnded"]) == .speechEnded)
    #expect(PageMessage(body: ["type": "level", "value": 0.25]) == .level(0.25))
    #expect(PageMessage(body: ["type": "audioFailed", "reason": "r"]) == .audioFailed("r"))
    #expect(PageMessage(body: ["type": "unknown"]) == nil)
    #expect(PageMessage(body: "speechStarted") == nil)
  }

  /// Review Focus 5: a lost microphone or peer reaches the call as `failed` with its sentence.
  @Test func audioFailedMessageBecomesAudioEvent() {
    #expect(PageMessage.audioFailed("No microphone.").audioEvent == .failed("No microphone."))
    #expect(PageMessage(body: ["type": "audioFailed"])?.audioEvent != nil)
    #expect(PageMessage.level(0.5).audioEvent == nil)
  }

  @Test func navigationPolicyAllowsOnlyTheAppPage() {
    #expect(AudioPage.allowsNavigation(to: AudioPage.url, mainFrame: true))
    #expect(!AudioPage.allowsNavigation(to: AudioPage.url, mainFrame: false))
    for other in [
      "file:///Users/example/index.html", "https://example.com/",
      "livebridge-audio://other/index.html",
      "livebridge-audio://app/other.html",
    ] {
      #expect(!AudioPage.allowsNavigation(to: URL(string: other), mainFrame: true), "\(other)")
    }
    #expect(!AudioPage.allowsNavigation(to: nil, mainFrame: true))
  }

  @Test func pageServesOnlyItsOwnFiles() {
    #expect(AudioPage.resourceName(for: URL(string: "livebridge-audio://app/vad.js")!) == "vad.js")
    #expect(AudioPage.resourceName(for: URL(string: "livebridge-audio://app/../x.js")!) == nil)
    #expect(AudioPage.resourceName(for: URL(string: "livebridge-audio://evil/vad.js")!) == nil)
    #expect(AudioPage.resourceName(for: URL(string: "livebridge-audio://app/a/b.js")!) == nil)
  }
}
