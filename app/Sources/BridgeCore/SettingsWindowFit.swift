import CoreGraphics

/// The Settings window's frame for a tab. Pure, in screen coordinates (origin at the bottom left).
public enum SettingsWindowFit {
  /// The window's frame for content of `preferred` size, given the `window`'s frame and its
  /// `content` view's: as tall as the content, top edge still, but no taller than `visible`, the
  /// visible frame of the screen it is on, and moved up or down until its top and bottom are
  /// inside it; a capped tab scrolls in what it gets. Only the vertical extent is fitted: the
  /// width follows the content, and `origin.x` is left as it is. A window on no screen is only
  /// sized.
  public static func frame(
    window: CGRect, content: CGRect, preferred: CGSize, visible: CGRect?
  ) -> CGRect {
    var frame = window
    frame.size.width += preferred.width - content.width
    frame.size.height += preferred.height - content.height
    frame.origin.y = window.maxY - frame.height
    guard let visible else { return frame }
    frame.size.height = min(frame.height, visible.height)
    frame.origin.y = min(max(window.maxY - frame.height, visible.minY), visible.maxY - frame.height)
    return frame
  }
}
