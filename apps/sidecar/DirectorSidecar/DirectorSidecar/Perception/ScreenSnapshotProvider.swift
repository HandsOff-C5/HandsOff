// ScreenSnapshotProvider — the live AX/driver window source for the perception NBest chain.
//
// NBestCluster ranks a screen-plane hit against a `ScreenEvent` (the candidate window set). The bus
// fans frames at camera FPS off per-plugin queues, so it can NOT call the async cua-driver per
// frame; instead this provider keeps a thread-safe CACHED `ScreenEvent`, refreshed off the hot path
// (`update(windows:)`, fed by a periodic `CuaDriverService.listWindows()` poll the host owns), that
// the bus reads synchronously via `current()` while ranking.
//
// The window set is filtered to the SAME rankable gate the live `AttentionRanking` uses (on-screen,
// AX-readable, not the cua-driver's own overlay, measured non-empty bounds) so the perception
// cluster and the intent-time ranker agree on which windows are candidates. Each
// `PerceptionWindowRef.appBundleId` carries the stable `CuaWindow.id`, so a ranked
// `WindowOrRegionRef.id` resolves back to the originating surface (`surface(forId:)`).

import Dispatch
import Foundation

final class ScreenSnapshotProvider {

    private let lock = NSLock()
    private var cachedEvent: ScreenEvent?
    private var cachedWindows: [String: CuaWindow] = [:]
    private let now: () -> MonotonicInstant

    init(now: @escaping () -> MonotonicInstant = ScreenSnapshotProvider.monotonicNow) {
        self.now = now
    }

    static func monotonicNow() -> MonotonicInstant {
        MonotonicInstant(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    /// Synchronous read for the bus route — the last cached snapshot, or nil before the first poll.
    func current() -> ScreenEvent? {
        lock.lock()
        defer { lock.unlock() }
        return cachedEvent
    }

    /// Resolve a ranked `WindowOrRegionRef.id` back to its originating driver window/surface.
    func surface(forId id: String) -> CuaWindow? {
        lock.lock()
        defer { lock.unlock() }
        return cachedWindows[id]
    }

    /// Replace the cache from a fresh driver window list. Call OFF the camera path (the async poll).
    func update(windows: [CuaWindow]) {
        let rankable = windows.filter(Self.isRankable)
        let event = Self.screenEvent(from: rankable, now: now())
        var index: [String: CuaWindow] = [:]
        for w in rankable { index[w.id] = w }
        lock.lock()
        cachedEvent = event
        cachedWindows = index
        lock.unlock()
    }

    /// Build a `ScreenEvent` from already-filtered driver windows. The window frame (global
    /// virtual-desktop px) maps 1:1 into the perception `CGGlobalRect` space NBestCluster ranks in.
    static func screenEvent(from windows: [CuaWindow], now: MonotonicInstant) -> ScreenEvent {
        let refs: [PerceptionWindowRef] = windows.compactMap { w in
            guard let b = w.bounds else { return nil }
            return PerceptionWindowRef(
                appBundleId: w.id,
                title: w.title,
                frame: CGGlobalRect(x: b.x, y: b.y, width: b.width, height: b.height),
                display: 0)
        }
        let focused = windows.first(where: \.focused)
        let header = EventHeader(source: .screen_ax, tSrc: now, conf: 1, nBest: 0, taint: .trusted)
        return ScreenEvent(
            header: header,
            windows: refs,
            displays: [],
            focusedField: focused.map { FieldRef(role: "window", value: $0.title, editable: false) })
    }

    /// The same gate `AttentionRanking.isRankable` applies: on-screen, AX-readable, not the
    /// cua-driver's own overlay, with measured non-empty bounds.
    private static func isRankable(_ window: CuaWindow) -> Bool {
        guard let b = window.bounds, b.width > 0, b.height > 0 else { return false }
        return window.availability == .available
            && window.accessStatus == .accessible
            && !window.app.lowercased().contains("cua driver")
    }
}
