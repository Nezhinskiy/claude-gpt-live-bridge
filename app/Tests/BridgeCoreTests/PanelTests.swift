import CoreGraphics
import Foundation
import Testing

@testable import BridgeCore

struct PanelPlacementTests {
  /// A 1440 × 900 screen with a 24 pt menu bar and a 70 pt Dock.
  let main = PanelPlacement.Screen(
    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visible: CGRect(x: 0, y: 70, width: 1440, height: 806))
  /// A second screen to the left of it, 1920 × 1080, with its own menu bar and no Dock.
  let left = PanelPlacement.Screen(
    frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
    visible: CGRect(x: -1920, y: 0, width: 1920, height: 1056))
  let size = CGSize(width: 340, height: 400)

  /// The status item's button in the menu bar: 24 pt tall at the screen's top.
  func button(x: Double, on screen: PanelPlacement.Screen, width: Double = 32) -> CGRect {
    CGRect(x: x, y: screen.frame.maxY - 24, width: width, height: 24)
  }

  @Test func thePanelHangsUnderItsButtonRightAligned() {
    let anchor = button(x: 1000, on: main)
    let frame = PanelPlacement.frame(size: size, under: anchor, screens: [main, left])
    #expect(frame.maxX == anchor.maxX)
    #expect(frame.maxY == main.visible.maxY - PanelPlacement.gap)
    #expect(frame.size == size)
  }

  @Test func nearTheScreensRightEdgeItStaysOnTheScreen() {
    let anchor = button(x: 1430, on: main, width: 40)  // reaches past the right edge
    let frame = PanelPlacement.frame(size: size, under: anchor, screens: [main])
    #expect(frame.maxX == main.visible.maxX - PanelPlacement.margin)
    #expect(frame.width == size.width)
  }

  @Test func nearTheScreensLeftEdgeItStaysOnTheScreen() {
    let anchor = button(x: 20, on: main)
    let frame = PanelPlacement.frame(size: size, under: anchor, screens: [main])
    #expect(frame.minX == main.visible.minX + PanelPlacement.margin)
  }

  @Test func onASecondScreenItIsPlacedAndClampedThere() {
    let anchor = button(x: -60, on: left)  // the left screen's right edge
    let frame = PanelPlacement.frame(size: size, under: anchor, screens: [main, left])
    #expect(frame.maxX == anchor.maxX)
    #expect(frame.maxY == left.visible.maxY - PanelPlacement.gap)
    #expect(left.visible.contains(frame))
    let atItsLeftEdge = PanelPlacement.frame(
      size: size, under: button(x: -1910, on: left), screens: [main, left])
    #expect(atItsLeftEdge.minX == left.visible.minX + PanelPlacement.margin)
  }

  @Test func aPanelTallerThanTheScreenIsCutToIt() {
    let tall = CGSize(width: 340, height: 2000)
    let frame = PanelPlacement.frame(size: tall, under: button(x: 1000, on: main), screens: [main])
    #expect(frame.minY == main.visible.minY + PanelPlacement.margin)
    #expect(frame.maxY == main.visible.maxY - PanelPlacement.gap)
  }

  @Test func aMenuBarThatHidesStillLeavesTheGapUnderTheButton() {
    // with the menu bar hidden the visible frame reaches the screen's top
    let full = PanelPlacement.Screen(frame: main.frame, visible: main.frame)
    let anchor = button(x: 1000, on: full)
    let frame = PanelPlacement.frame(size: size, under: anchor, screens: [full])
    #expect(frame.maxY == anchor.minY - PanelPlacement.gap)
  }

  @Test func withoutAButtonThePanelOpensAtTheMenuBarScreensRight() {
    let frame = PanelPlacement.frame(size: size, under: nil, screens: [main, left])
    #expect(frame.maxX == main.visible.maxX - PanelPlacement.margin)
    #expect(frame.maxY == main.visible.maxY - PanelPlacement.gap)
  }

  @Test func theFrameIsInWholePoints() {
    let anchor = CGRect(x: 1000.4, y: 876.3, width: 31.7, height: 23.7)
    let frame = PanelPlacement.frame(
      size: CGSize(width: 340, height: 401.6), under: anchor, screens: [main])
    for value in [frame.minX, frame.minY, frame.width, frame.height] {
      #expect(value == value.rounded())
    }
  }

  @Test func theButtonsScreenIsTheOneHoldingIt() {
    #expect(PanelPlacement.screen(for: button(x: -60, on: left), in: [main, left]) == left)
    #expect(PanelPlacement.screen(for: button(x: 100, on: main), in: [main, left]) == main)
    #expect(PanelPlacement.screen(for: nil, in: [main, left]) == main)
    #expect(PanelPlacement.screen(for: nil, in: []) == nil)
  }
}

struct PanelMachineTests {
  @Test func theButtonTogglesThePanelAndItsHighlight() {
    var machine = PanelMachine()
    #expect(machine.handle(.statusItemPressed) == [.show, .highlight(true)])
    #expect(machine.isOpen && machine.highlighted)
    #expect(machine.handle(.statusItemPressed) == [.hide, .highlight(false)])
    #expect(!machine.isOpen && !machine.highlighted)
  }

  @Test(arguments: [
    PanelMachine.Event.click(.elsewhere), .escape, .otherAppActivated, .spaceChanged, .dismiss,
  ])
  func aDismissalClosesAnOpenPanel(_ event: PanelMachine.Event) {
    var machine = PanelMachine()
    _ = machine.handle(.statusItemPressed)
    #expect(machine.handle(event) == [.hide, .highlight(false)])
    #expect(machine.handle(event) == [])  // already closed
  }

  /// Clicks in the panel, on its button (which toggles by itself) and in its own confirmation
  /// alert leave it open: the panel never vanishes under its alert.
  @Test(arguments: [PanelMachine.Click.panel, .statusItem, .alert])
  func clicksThatAreNotOutsideLeaveItOpen(_ click: PanelMachine.Click) {
    var machine = PanelMachine()
    _ = machine.handle(.statusItemPressed)
    #expect(machine.handle(.click(click)) == [])
    #expect(machine.isOpen)
  }

  @Test func aNotificationClickOpensItOnce() {
    var machine = PanelMachine()
    #expect(machine.handle(.open) == [.show, .highlight(true)])
    #expect(machine.handle(.open) == [])
    #expect(machine.isOpen)
  }

  /// macOS 27: the system's session opens and closes the panel and draws the highlight.
  @Test func theSystemsSessionOpensAndClosesIt() {
    var machine = PanelMachine()
    #expect(machine.handle(.sessionBegan) == [.show])
    #expect(machine.isOpen && machine.inSession && !machine.highlighted)
    #expect(machine.handle(.sessionEnded) == [.hide])
    #expect(!machine.isOpen && !machine.inSession)
    #expect(machine.handle(.sessionEnded) == [])
  }

  /// The panel closed by the app itself cancels the system's session; the session's end that
  /// follows changes nothing.
  @Test(arguments: [
    PanelMachine.Event.click(.elsewhere), .escape, .otherAppActivated, .spaceChanged, .dismiss,
  ])
  func closingItEndsTheSystemsSession(_ event: PanelMachine.Event) {
    var machine = PanelMachine()
    _ = machine.handle(.sessionBegan)
    #expect(machine.handle(event) == [.hide, .cancelSession])
    #expect(machine.handle(.sessionEnded) == [])
    #expect(!machine.isOpen)
  }

  /// A panel a notification opened has no session; pressing the button begins one, which
  /// closes the panel as a second press would.
  @Test func aSessionBegunOverAnOpenPanelClosesIt() {
    var machine = PanelMachine()
    _ = machine.handle(.open)
    #expect(machine.handle(.sessionBegan) == [.hide, .highlight(false), .cancelSession])
    #expect(!machine.isOpen)
    #expect(machine.handle(.sessionEnded) == [])
    #expect(machine.handle(.sessionBegan) == [.show])
  }
}
