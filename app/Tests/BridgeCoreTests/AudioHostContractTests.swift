import AppKit
import Foundation
import Testing

@testable import BridgeCore

struct AudioHostContractTests {
  @Test func pageMessagesDecode() {
    #expect(AudioEvent(body: ["type": "speechStarted"]) == .speechStarted)
    #expect(AudioEvent(body: ["type": "speechEnded"]) == .speechEnded)
    #expect(AudioEvent(body: ["type": "level", "value": 0.25]) == .level(0.25))
    #expect(AudioEvent(body: ["type": "audioFailed", "reason": "r"]) == .failed(.other("r")))
    #expect(
      AudioEvent(body: ["type": "lineError", "code": "c", "message": "m"])
        == .lineError(code: "c", message: "m"))
    #expect(AudioEvent(body: ["type": "lineError"]) == .lineError(code: "", message: ""))
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

  @Test func aFakeLineIsNamedByItsPlace() {
    #expect(AudioPage.fakeLine(named: "fake-mic-0.wav") == 0)
    #expect(AudioPage.fakeLine(named: "fake-mic-12.wav") == 12)
    for other in ["fake-mic.wav", "fake-mic-.wav", "fake-mic--1.wav", "fake-mic-a.wav", "vad.js"] {
      #expect(AudioPage.fakeLine(named: other) == nil, "\(other)")
    }
  }

  /// `AudioHost` plays these with `?.play()`, so one that does not load is only silence.
  @Test(arguments: ["chime", "handoff"]) func soundLoads(_ name: String) throws {
    let file = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "../../Sources/LiveBridge/Resources/audio/\(name).wav")
    let sound = try #require(NSSound(contentsOf: file, byReference: true))
    #expect(sound.duration > 0)
  }
}
