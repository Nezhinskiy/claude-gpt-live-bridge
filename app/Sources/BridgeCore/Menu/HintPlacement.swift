import CoreGraphics

/// Where a hint beside a menu goes. Pure, in screen coordinates (origin at the bottom left).
public enum HintPlacement {
  /// Between the menu and the hint.
  public static let gap: CGFloat = 6

  /// A hint of `size` to the right of `menu`, or to its left when the right has no room, level
  /// with the pointer and inside `screen`.
  public static func origin(
    size: CGSize, beside menu: CGRect, pointerY: CGFloat, on screen: CGRect
  ) -> CGPoint {
    let right = menu.maxX + gap
    let x = right + size.width <= screen.maxX ? right : menu.minX - gap - size.width
    return CGPoint(
      x: min(max(x, screen.minX), screen.maxX - size.width),
      y: min(max(pointerY - size.height / 2, screen.minY), screen.maxY - size.height))
  }
}
