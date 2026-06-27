import CoreGraphics

#if canImport(ApplicationServices)
import ApplicationServices  // CGDisplayCreateUUIDFromDisplayID
#endif

/// Multi-monitor geometry: the union ("global desktop") bounds across all displays and the
/// mapping from a point local to one monitor into union-normalized `[0,1]×[0,1]`
/// coordinates. Ported from the legacy `display-map.ts`, which shipped without a test
/// oracle (D1) — the tests here are fresh Swift units over the pure `CGRect` math.
///
/// Negative-origin displays are real (`CLAUDE.md I7`): a monitor placed to the left of, or
/// above, the primary has a negative `origin.x`/`origin.y`, so the union must be computed
/// from each screen's actual `frame.origin` (a min/max sweep), never assumed to start at
/// `(0,0)`.
public enum DisplayMap {

    /// The union (bounding box) of all display frames — the global desktop rect. Computed
    /// as the min of the origins and the max of the far corners, so negative origins are
    /// preserved. Returns `.zero` for an empty input (no displays).
    public static func unionBounds(_ frames: [CGRect]) -> CGRect {
        guard let first = frames.first else { return .zero }
        var minX = first.minX
        var minY = first.minY
        var maxX = first.maxX
        var maxY = first.maxY
        for frame in frames.dropFirst() {
            minX = Swift.min(minX, frame.minX)
            minY = Swift.min(minY, frame.minY)
            maxX = Swift.max(maxX, frame.maxX)
            maxY = Swift.max(maxY, frame.maxY)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Map a point given in one monitor's **local** coordinates into the union, normalized
    /// to `[0,1]×[0,1]`.
    ///
    /// The local point is first shifted by the monitor's origin to get its global desktop
    /// position, then expressed as a fraction of the union extent:
    ///
    ///   `nx = (monitorFrame.origin.x + localPoint.x - union.minX) / union.width`
    ///   `ny = (monitorFrame.origin.y + localPoint.y - union.minY) / union.height`
    ///
    /// A zero-area union yields the corresponding normalized component of `0` (avoids a
    /// divide-by-zero on a degenerate/empty display set).
    public static func monitorLocalToUnionNormalized(
        localPoint: CGPoint, monitorFrame: CGRect, union: CGRect
    ) -> CGPoint {
        let globalX = monitorFrame.origin.x + localPoint.x
        let globalY = monitorFrame.origin.y + localPoint.y
        let nx = union.width == 0 ? 0 : (globalX - union.minX) / union.width
        let ny = union.height == 0 ? 0 : (globalY - union.minY) / union.height
        return CGPoint(x: nx, y: ny)
    }

    // MARK: - UUID resolution (thin live-display wrapper; not unit-tested headlessly)

    #if canImport(ApplicationServices)
    /// Stable per-display UUID string for a live `CGDirectDisplayID`, used to persist
    /// per-monitor calibration across reconnects/reorderings (display IDs are not stable,
    /// UUIDs are).
    ///
    /// CoreFoundation **create rule**: `CGDisplayCreateUUIDFromDisplayID` returns a
    /// `+1`-retained `CFUUID` that the caller owns, so it is released here via
    /// `takeRetainedValue()` (ARC consumes the +1 on the bridged `CFUUID`, and the derived
    /// `CFString` is likewise create-ruled and consumed the same way). This live path can't
    /// be exercised in a headless unit test — it stays a thin wrapper; the pure
    /// union/normalization math above carries the test coverage.
    public static func displayUUIDString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }
        let cfString = CFUUIDCreateString(kCFAllocatorDefault, uuid)
        return cfString as String?
    }
    #endif
}
