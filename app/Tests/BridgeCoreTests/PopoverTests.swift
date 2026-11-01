import Foundation
import Testing

@testable import BridgeCore

struct ContextLoadsTests {
  let a = SessionID(rawValue: "00000000-0000-0000-0000-000000000001")
  let b = SessionID(rawValue: "11111111-0000-0000-0000-000000000002")
  let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func aPressIsPendingUntilItsContextArrives() {
    var loads = ContextLoads()
    #expect(loads.state(of: a, at: t0) == .ready)
    loads.pressed(a, at: t0)
    #expect(loads.state(of: a, at: t0 + 30) == .loading)
    #expect(loads.state(of: b, at: t0 + 30) == .ready)  // per session
    loads.arrived(a, at: t0 + 30)
    #expect(loads.state(of: a, at: t0 + 32.9) == .loaded)
    #expect(loads.state(of: a, at: t0 + 33) == .ready)
  }

  @Test func aPressGivesUpAfterSixtySeconds() {
    var loads = ContextLoads()
    loads.pressed(a, at: t0)
    #expect(loads.state(of: a, at: t0 + 59.9) == .loading)
    #expect(loads.state(of: a, at: t0 + 60) == .ready)
    loads.arrived(a, at: t0 + 61)  // too late to count as the press's
    #expect(loads.state(of: a, at: t0 + 61) == .ready)
  }

  @Test func aContextNobodyPressedForShowsNothing() {
    var loads = ContextLoads()
    loads.arrived(a, at: t0)  // as when automatic context asks a new target for it
    #expect(loads.state(of: a, at: t0) == .ready)
  }

  @Test func aSessionThatLeftIsForgotten() {
    var loads = ContextLoads()
    loads.pressed(a, at: t0)
    loads.pressed(b, at: t0)
    loads.keep(only: [b])
    #expect(loads.state(of: a, at: t0) == .ready)
    #expect(loads.state(of: b, at: t0) == .loading)
    loads.arrived(a, at: t0 + 1)
    #expect(loads.state(of: a, at: t0 + 1) == .ready)
  }

  @Test func theNextChangeIsTheEarliestDeadline() {
    var loads = ContextLoads()
    #expect(loads.nextChange(after: t0) == nil)
    loads.pressed(a, at: t0)
    loads.pressed(b, at: t0 + 10)
    #expect(loads.nextChange(after: t0) == t0 + 60)
    loads.arrived(b, at: t0 + 20)
    #expect(loads.nextChange(after: t0 + 20) == t0 + 23)
    #expect(loads.nextChange(after: t0 + 23) == t0 + 60)
    #expect(loads.nextChange(after: t0 + 60) == nil)
  }

  @Test func theButtonSaysWhatIsHappening() {
    #expect(ContextLoadState.ready.title == "Load context")
    #expect(ContextLoadState.ready.isEnabled)
    #expect(ContextLoadState.loading.title == "Loading context…")
    #expect(!ContextLoadState.loading.isEnabled)
    #expect(ContextLoadState.loaded.title == "Context loaded")
    #expect(!ContextLoadState.loaded.isEnabled)
  }
}

struct PopoverLayoutTests {
  @Test func aLineNamesItsSpeaker() {
    let line = TranscriptLine("Claude: [OK] Alpha: Done.")
    #expect(line.speaker == "Claude")
    #expect(line.text == "[OK] Alpha: Done.")
    #expect(TranscriptLine("no speaker here").speaker == "")
    #expect(TranscriptLine("no speaker here").text == "no speaker here")
  }

  @Test func aLongLineIsFlattenedAndCapped() {
    let paragraph = String(repeating: "word ", count: 200)
    let line = TranscriptLine("Claude: [QUESTION] Alpha: \(paragraph)\n\n\(paragraph)")
    #expect(!line.text.contains("\n"))
    #expect(!line.text.contains("  "))
    #expect(line.text.count == TranscriptLine.maxCharacters)
    #expect(line.text.hasSuffix("…"))
    #expect(line.text.hasPrefix("[QUESTION] Alpha: word word"))
  }

  @Test func aShortLineIsKeptAsItIs() {
    let text = "[OK] Alpha: Tests pass."
    #expect(TranscriptLine("Voice: \(text)").text == text)
  }

  /// The popover never grows past the screen: its sections' caps leave room for the rest.
  @Test(arguments: [300.0, 600, 768, 875, 1080, 1400, 2200])
  func thePopoverFitsTheScreen(_ visible: Double) {
    let layout = PopoverLayout(visibleHeight: visible)
    #expect(layout.maxHeight <= visible - PopoverLayout.screenMargin)
    #expect(layout.maxHeight > 0)
    #expect(
      layout.sessions + layout.lastLines + layout.sent + PopoverLayout.fixedChrome
        <= max(layout.maxHeight, PopoverLayout.minimumSections + PopoverLayout.fixedChrome))
    for cap in [layout.sessions, layout.lastLines, layout.sent] { #expect(cap >= 60) }
  }

  @Test func aTallScreenKeepsSectionsModest() {
    let layout = PopoverLayout(visibleHeight: 2200)
    #expect(layout.lastLines <= 220)
    #expect(layout.sent <= 180)
    #expect(layout.sessions <= 280)
  }
}

struct ConfirmationTests {
  @Test func newConversationSaysWhatIsErased() {
    let ask = Confirmation.newConversation(label: "Alpha")
    #expect(ask.title == "Erase the conversation with Alpha?")
    #expect(ask.message.contains("what the voice remembers"))
    #expect(ask.message.contains("loaded context"))
    #expect(ask.confirm == "Erase")
  }

  @Test func removeSaysHowToJoinAgain() {
    let ask = Confirmation.remove(label: "Alpha")
    #expect(ask.title == "Remove Alpha from LiveBridge?")
    #expect(ask.message.contains("erased"))
    #expect(ask.message.contains("/live on"))
    #expect(ask.confirm == "Remove")
  }
}
