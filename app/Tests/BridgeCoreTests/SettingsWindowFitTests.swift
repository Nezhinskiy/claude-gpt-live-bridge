import CoreGraphics
import Testing

@testable import BridgeCore

/// The window's title bar and toolbar are 88 points tall: its frame less its content view's.
struct SettingsWindowFitTests {
  /// A 13-inch MacBook's main screen, below the menu bar and above a 70-point Dock.
  static let screen = CGRect(x: 0, y: 70, width: 1470, height: 849)

  static func fit(
    windowY: CGFloat, height: CGFloat = 400, content: CGFloat, on screen: CGRect? = screen,
    x: CGFloat = 100
  ) -> CGRect {
    SettingsWindowFit.frame(
      window: CGRect(x: x, y: windowY, width: 480, height: height),
      content: CGRect(x: 0, y: 0, width: 480, height: height - 88),
      preferred: CGSize(width: 480, height: content), visible: screen)
  }

  @Test func contentThatFitsKeepsItsHeightAndItsTopEdge() {
    #expect(Self.fit(windowY: 400, content: 500) == CGRect(x: 100, y: 212, width: 480, height: 588))
  }

  @Test func contentTallerThanTheScreenIsCappedAtTheVisibleHeight() {
    #expect(Self.fit(windowY: 400, content: 2000).height == 849)
  }

  @Test func aWindowLowOnTheScreenMovesUpAboveTheDock() {
    #expect(Self.fit(windowY: 100, content: 500).minY == 70)
  }

  @Test func aWindowUnderTheMenuBarMovesDown() {
    #expect(Self.fit(windowY: 600, content: 300).maxY == 919)
  }

  @Test func aCappedWindowFillsTheVisibleFrame() {
    let frame = Self.fit(windowY: 600, content: 2000)
    #expect(frame.minY == 70)
    #expect(frame.maxY == 919)
  }

  /// A second display, right of the main one and lower, with no Dock.
  @Test func aWindowOnASecondScreenIsFittedToThatScreen() {
    let second = CGRect(x: 1470, y: -200, width: 1280, height: 700)
    let frame = Self.fit(windowY: 0, content: 2000, on: second, x: 1500)
    #expect(frame == CGRect(x: 1500, y: -200, width: 480, height: 700))
  }

  @Test func aWindowOnNoScreenKeepsItsTopEdgeUncapped() {
    #expect(Self.fit(windowY: 400, content: 2000, on: nil).maxY == 800)
    #expect(Self.fit(windowY: 400, content: 2000, on: nil).height == 2088)
  }
}
