import Foundation
import CoreGraphics

/// #150 / #148: native on-screen window list via `CGWindowListCopyWindowInfo`, so point→window
/// targeting runs from the app's OWN process WITHOUT the external `cua-driver`. The driver returns
/// an empty list in the bundled app (its per-call spawn relies on a separate `com.trycua.driver`
/// TCC identity that is not granted — issue #148), which is the root of #150's live "Display 3 /
/// empty candidates" symptom. Reading the window list natively needs no Screen Recording grant
/// (only window *titles* do — ranking doesn't use titles).
///
/// Produces `CuaWindow` values shape-identical to `CuaDriverService.listWindows()` so
/// `AttentionRanking` and the perception NBest chain consume them unchanged.
///
/// Coordinate space: `kCGWindowBounds` is global, top-left origin, y-down, in POINTS — the same
/// convention the cursor / head-point pipeline uses. On scale-factor-1.0 displays points == px; a
/// Retina points↔px factor is a calibration knob, not a logic change (see #150 risks).
enum NativeWindowSource {
    /// Live frontmost-first, on-screen, layer-0 app windows mapped to `CuaWindow`
    /// (`zIndex` HIGHER = frontmost). Excludes our own process so the Director never targets itself.
    static func onScreenWindows(
        excludingPID excluded: Int = Int(ProcessInfo.processInfo.processIdentifier)
    ) -> [CuaWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]]
        else { return [] }
        return map(raw, excludingPID: excluded)
    }

    /// Pure mapping (CGWindowList dicts → `CuaWindow`), factored out for headless testing.
    /// `raw` is front-to-back (CGWindowList order); the frontmost surviving window is marked
    /// `focused` and given the highest `zIndex`.
    static func map(_ raw: [[String: AnyObject]], excludingPID excluded: Int = -1) -> [CuaWindow] {
        let count = raw.count
        var result: [CuaWindow] = []
        result.reserveCapacity(count)
        var markedFocused = false
        for (idx, info) in raw.enumerated() {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int, pid != excluded,
                  let windowNumber = info[kCGWindowNumber as String] as? Int
            else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
            guard alpha > 0 else { continue }
            let app = (info[kCGWindowOwnerName as String] as? String) ?? ""
            guard !app.lowercased().contains("cua driver") else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 0, rect.height > 0
            else { continue }

            let isFront = !markedFocused
            if isFront { markedFocused = true }
            result.append(CuaWindow(
                id: String(windowNumber),
                title: (info[kCGWindowName as String] as? String) ?? "",
                app: app,
                pid: pid,
                windowId: windowNumber,
                availability: .available,
                accessStatus: .accessible,
                focused: isFront,
                bounds: CuaWindowBounds(
                    x: Double(rect.origin.x), y: Double(rect.origin.y),
                    width: Double(rect.width), height: Double(rect.height)
                ),
                zIndex: count - idx
            ))
        }
        return result
    }
}
