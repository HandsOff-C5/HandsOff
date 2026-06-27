import XCTest
@testable import DirectorSidecar

/// The live AX/driver window source for the perception NBest chain: it converts a cua-driver window
/// list into a cached `ScreenEvent` the bus ranks against, applying the same rankable gate the
/// intent-time `AttentionRanking` uses, and resolves a ranked id back to its driver window.
final class ScreenSnapshotProviderTests: XCTestCase {

    private func window(
        id: String,
        app: String = "TextEdit",
        availability: Contracts.SurfaceAvailability = .available,
        access: Contracts.SurfaceAccessStatus = .accessible,
        bounds: CuaWindowBounds? = CuaWindowBounds(x: 0, y: 0, width: 800, height: 600),
        zIndex: Int = 0
    ) -> CuaWindow {
        CuaWindow(id: id, title: id, app: app, pid: 1, windowId: 1,
                  availability: availability, accessStatus: access,
                  focused: false, bounds: bounds, zIndex: zIndex)
    }

    func test_currentIsNilBeforeFirstUpdate() {
        XCTAssertNil(ScreenSnapshotProvider().current(), "no snapshot until the first poll")
    }

    func test_update_convertsWindowsToScreenEventInGlobalPxSpace() throws {
        let provider = ScreenSnapshotProvider()
        provider.update(windows: [window(id: "w.a", bounds: CuaWindowBounds(x: 10, y: 20, width: 300, height: 200))])
        let event = try XCTUnwrap(provider.current())
        let ref = try XCTUnwrap(event.windows.first)
        XCTAssertEqual(ref.appBundleId, "w.a", "stable driver id carried so a ranked id resolves back")
        XCTAssertEqual(ref.frame, CGGlobalRect(x: 10, y: 20, width: 300, height: 200), "bounds map 1:1 into CG-global px")
        XCTAssertEqual(event.header.source, .screen_ax)
    }

    func test_update_filtersUnrankableWindows() throws {
        let provider = ScreenSnapshotProvider()
        provider.update(windows: [
            window(id: "ok"),
            window(id: "minimized", availability: .minimized),
            window(id: "restricted", access: .restricted),
            window(id: "noBounds", bounds: nil),
            window(id: "empty", bounds: CuaWindowBounds(x: 0, y: 0, width: 0, height: 0)),
            window(id: "driver", app: "Cua Driver"),
        ])
        let event = try XCTUnwrap(provider.current())
        XCTAssertEqual(event.windows.map(\.appBundleId), ["ok"], "only on-screen, AX-readable, measured, non-driver windows survive")
    }

    func test_surfaceForId_resolvesBackToDriverWindow() {
        let provider = ScreenSnapshotProvider()
        provider.update(windows: [window(id: "w.a"), window(id: "w.b")])
        XCTAssertEqual(provider.surface(forId: "w.b")?.id, "w.b")
        XCTAssertNil(provider.surface(forId: "nope"))
        XCTAssertNil(provider.surface(forId: "driver"), "filtered windows are not resolvable")
    }

    func test_update_replacesPreviousSnapshot() throws {
        let provider = ScreenSnapshotProvider()
        provider.update(windows: [window(id: "old")])
        provider.update(windows: [window(id: "new")])
        let event = try XCTUnwrap(provider.current())
        XCTAssertEqual(event.windows.map(\.appBundleId), ["new"], "a fresh poll replaces, never appends")
        XCTAssertNil(provider.surface(forId: "old"))
    }
}
