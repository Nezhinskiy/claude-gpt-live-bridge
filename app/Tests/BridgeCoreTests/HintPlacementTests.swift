import CoreGraphics
import Testing

@testable import BridgeCore

struct HintPlacementTests {
  static let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
  static let size = CGSize(width: 200, height: 60)

  static func origin(menu: CGRect, pointerY: CGFloat = 400) -> CGPoint {
    HintPlacement.origin(size: size, beside: menu, pointerY: pointerY, on: screen)
  }

  @Test func sitsToTheRightOfTheMenu() {
    let menu = CGRect(x: 300, y: 200, width: 300, height: 400)
    #expect(Self.origin(menu: menu).x == 606)
  }

  @Test func goesLeftWhenTheRightHasNoRoom() {
    let menu = CGRect(x: 700, y: 200, width: 280, height: 400)
    #expect(Self.origin(menu: menu).x == 494)
  }

  @Test func staysLevelWithThePointer() {
    let menu = CGRect(x: 300, y: 200, width: 300, height: 400)
    #expect(Self.origin(menu: menu, pointerY: 400).y == 370)
  }

  /// A display left of the main one has negative x.
  @Test func staysOnAScreenLeftOfTheOrigin() {
    let left = CGRect(x: -1000, y: 0, width: 1000, height: 800)
    let menu = CGRect(x: -990, y: 0, width: 985, height: 800)
    let origin = HintPlacement.origin(size: Self.size, beside: menu, pointerY: 400, on: left)
    #expect(origin.x == -1000)
  }

  @Test func staysOnTheScreen() {
    let menu = CGRect(x: 0, y: 0, width: 990, height: 800)
    let top = Self.origin(menu: menu, pointerY: 795)
    #expect(top.y == 740)
    #expect(top.x == 0)
    #expect(Self.origin(menu: menu, pointerY: 5).y == 0)
  }
}
