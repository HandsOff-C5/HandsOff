import XCTest
import CoreGraphics
@testable import DirectorSidecar

/// #150/#148: the native CGWindowList → CuaWindow mapping must produce rankable windows (so
/// AttentionRanking/the NBest chain accept them) and survive the real-world filters, all WITHOUT
/// the cua-driver. The live CGWindowListCopyWindowInfo read can't run headlessly, so we test the
/// pure `map` over fixture dictionaries shaped exactly like CGWindowList output.
final class NativeWindowSourceTests: XCTestCase {

    private func win(pid: Int, number: Int, app: String, layer: Int = 0, alpha: Double = 1,
                     x: Double = 0, y: Double = 0, w: Double = 100, h: Double = 100,
                     title: String = "") -> [String: AnyObject] {
        [
            (kCGWindowLayer as String): layer as AnyObject,
            (kCGWindowOwnerPID as String): pid as AnyObject,
            (kCGWindowNumber as String): number as AnyObject,
            (kCGWindowAlpha as String): alpha as AnyObject,
            (kCGWindowOwnerName as String): app as AnyObject,
            (kCGWindowName as String): title as AnyObject,
            (kCGWindowBounds as String): (["X": x, "Y": y, "Width": w, "Height": h] as NSDictionary) as AnyObject,
        ]
    }

    func test_map_ordersFrontmostFirst_andMarksFocused_andIsRankable() {
        // CGWindowList order is front-to-back: Cursor is frontmost.
        let raw = [win(pid: 11, number: 101, app: "Cursor", x: 0, y: 0, w: 800, h: 600),
                   win(pid: 22, number: 202, app: "Slack", x: 100, y: 100, w: 500, h: 400)]
        let windows = NativeWindowSource.map(raw)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].app, "Cursor")
        XCTAssertTrue(windows[0].focused)
        XCTAssertFalse(windows[1].focused)
        XCTAssertGreaterThan(windows[0].zIndex, windows[1].zIndex)   // HIGHER zIndex = frontmost
        XCTAssertEqual(windows[0].pid, 11)
        XCTAssertEqual(windows[0].windowId, 101)
        XCTAssertEqual(windows[0].id, "101")
        XCTAssertEqual(windows[0].bounds, CuaWindowBounds(x: 0, y: 0, width: 800, height: 600))
        // Must satisfy AttentionRanking.isRankable's availability/accessStatus gate.
        XCTAssertEqual(windows[0].availability, .available)
        XCTAssertEqual(windows[0].accessStatus, .accessible)
    }

    func test_map_excludesNonZeroLayer_ownPID_cuaDriver_andZeroBounds() {
        let raw = [
            win(pid: 11, number: 101, app: "Cursor", layer: 25),                 // overlay/menu layer
            win(pid: 99, number: 102, app: "Director", layer: 0),                // our own process
            win(pid: 33, number: 103, app: "Cua Driver", layer: 0),             // driver overlay
            win(pid: 44, number: 104, app: "Finder", layer: 0, w: 0, h: 0),     // empty bounds
            win(pid: 55, number: 105, app: "Slack", layer: 0, w: 400, h: 300),  // the only keeper
        ]
        let windows = NativeWindowSource.map(raw, excludingPID: 99)
        XCTAssertEqual(windows.map(\.app), ["Slack"])
        XCTAssertTrue(windows[0].focused)   // frontmost surviving window
    }

    func test_map_excludesZeroAlpha() {
        let raw = [win(pid: 1, number: 1, app: "Ghost", alpha: 0, w: 200, h: 200)]
        XCTAssertTrue(NativeWindowSource.map(raw).isEmpty)
    }

    func test_map_emptyInput_returnsEmpty() {
        XCTAssertTrue(NativeWindowSource.map([]).isEmpty)
    }
}
