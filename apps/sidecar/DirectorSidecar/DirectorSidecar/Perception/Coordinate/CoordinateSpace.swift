import CoreGraphics

/// Coordinate-space conversion between AppKit/Cocoa (bottom-left origin) and CoreGraphics
/// (top-left origin), the single canonical space for all cursor/calibration math
/// (`CLAUDE.md I7`).
///
/// AppKit reports points/rects with the origin at the **bottom-left** of a screen and y
/// growing **up**; CoreGraphics (and the cursor/event APIs) use a **top-left** origin with
/// y growing **down**. Every Cocoa value is converted **at the boundary** here, using the
/// **menu-bar screen height** `h0` — the height of the screen that carries the menu bar
/// (`NSScreen.screens.first`), **not** `NSScreen.main` (which is the key-window screen and
/// moves around). Pure math, no AppKit dependency, so it unit-tests headless.
///
/// Worked values: `CLAUDE.md §5.1` (point) / `§5.2` (rect).
public enum CoordinateSpace {

    /// Flip a single point between Cocoa bottom-left and CG top-left (the conversion is its
    /// own inverse, so one function serves both directions). `x` is unchanged;
    /// `y' = h0 - y` (`CLAUDE.md §5.1`).
    ///
    /// - Parameters:
    ///   - point: a point in the source space (Cocoa or CG).
    ///   - h0: the menu-bar screen height.
    /// - Returns: the point in the other space. Applying `flipPoint` twice with the same
    ///   `h0` returns the original point exactly (no off-by-one).
    public static func flipPoint(_ point: CGPoint, h0: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: h0 - point.y)
    }

    /// Flip a rect between Cocoa bottom-left and CG top-left. Unlike a point, a rect needs
    /// the **three-term** flip: the origin sits at a *corner*, so flipping the y axis moves
    /// the origin from the bottom-left corner to the top-left corner and the rect's own
    /// height must be subtracted (`CLAUDE.md §5.2`):
    ///
    ///   `origin.y' = h0 - origin.y - height`
    ///
    /// The naive single-term flip (`h0 - origin.y`) is the classic off-by-rect-height bug.
    /// `origin.x` and `size` are unchanged. The conversion is its own inverse.
    public static func flipRect(_ rect: CGRect, h0: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: h0 - rect.origin.y - rect.size.height,
            width: rect.size.width,
            height: rect.size.height
        )
    }
}
