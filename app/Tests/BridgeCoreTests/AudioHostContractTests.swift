import Foundation
import Testing

@testable import BridgeCore

struct AudioHostContractTests {
  @Test func pageMessagesDecode() {
    #expect(AudioEvent(body: ["type": "speechStarted"]) == .speechStarted)
    #expect(AudioEvent(body: ["type": "speechEnded"]) == .speechEnded)
    #expect(AudioEvent(body: ["type": "level", "value": 0.25]) == .level(0.25))
    #expect(AudioEvent(body: ["type": "audioFailed", "reason": "r"]) == .failed("r"))
    #expect(AudioEvent(body: ["type": "audioFailed"]) != nil)  // a failure without a reason
    #expect(AudioEvent(body: ["type": "unknown"]) == nil)
    #expect(AudioEvent(body: "speechStarted") == nil)
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
