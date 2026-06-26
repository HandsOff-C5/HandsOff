//
//  FnHotkeyService.swift
//  DirectorSidecar
//
//  Track E (ADR 0005): the global capture trigger on the bare `fn` (Globe) key, folded
//  in from `apps/desktop/src-tauri/src/commands/hotkey.rs`. A listen-only CGEventTap on
//  `kCGEventFlagsChanged` watches the `maskSecondaryFn` bit; the gesture grammar is:
//    * press-hold (>= holdThresholdMs) → `start` on commit, `stop` on release
//    * double-tap (two taps within multiTapWindowMs) → `toggle`
//    * a lone single tap emits nothing (it's only ever half of a potential double-tap).
//
//  Two seams from the sidecar are DELETED in-process: the Tauri `app.emit("hotkey://capture",
//  {phase})` becomes an `AsyncStream<CapturePhase>` the host consumes directly; there is no
//  webview. The pure `FnGesture` state machine is unit-tested 1:1 with the Rust tests; the
//  CGEventTap layer just feeds it real fn transitions plus a recurring hold tick.
//
//  Permission trade-off (unchanged from Rust): a listen-only tap needs the app to be a
//  trusted Accessibility client (AXIsProcessTrusted) and, on recent macOS, Input Monitoring.
//  macOS also swallows the bare fn press unless System Settings > Keyboard > "Press fn (Globe)
//  key to" is "Do Nothing". Verify from the bundled .app, never `tauri dev`.
//

import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid

/// Capture phase emitted to consumers — the same vocabulary the old `hotkey://capture`
/// `{ phase }` payload carried.
enum CapturePhase: String, Sendable, Equatable {
    case start
    case stop
    case toggle
}

/// Pure gesture state machine. No I/O: takes monotonic-millisecond instants and returns
/// the phase to emit. Fully unit-tested; the CGEventTap layer feeds it fn transitions and
/// a recurring tick for hold detection.
struct FnGesture: Equatable {
    /// A press held this long (without release) commits to press-hold — kept above a firm
    /// tap (~120 ms) so taps aren't misread as holds.
    static let holdThresholdMs: UInt64 = 250
    /// Max gap between the first tap's release and the second tap's press.
    static let multiTapWindowMs: UInt64 = 300

    private enum State: Equatable {
        case idle
        /// fn down; not yet committed (could become a hold or the first tap).
        case down(pressAt: UInt64)
        /// fn up; one tap recorded; waiting for a second tap within the window.
        case tapPending(releasedAt: UInt64)
        /// fn down on the second tap (commits to toggle on release, or a hold if held past
        /// the threshold).
        case secondDown(pressAt: UInt64)
        /// Committed to press-hold; emitted `start`; waiting for release → `stop`.
        case holding
    }

    private var state: State = .idle

    /// Monotonic, never-negative elapsed delta (mirrors Rust `saturating_sub`).
    private static func elapsed(_ now: UInt64, since earlier: UInt64) -> UInt64 {
        now >= earlier ? now - earlier : 0
    }

    /// fn transitioned to pressed at `now`.
    mutating func onPress(now: UInt64) -> CapturePhase? {
        switch state {
        case .idle:
            state = .down(pressAt: now)
        case .tapPending(let releasedAt):
            if Self.elapsed(now, since: releasedAt) <= Self.multiTapWindowMs {
                state = .secondDown(pressAt: now) // second tap inside the double-tap window
            } else {
                state = .down(pressAt: now) // pending tap expired → a fresh first press
            }
        // Spurious press without an intervening release (e.g. other modifiers firing
        // flagsChanged with the fn bit still set); stay put.
        case .down, .secondDown, .holding:
            break
        }
        return nil
    }

    /// fn transitioned to released at `now`.
    mutating func onRelease(now: UInt64) -> CapturePhase? {
        switch state {
        case .down:
            state = .tapPending(releasedAt: now) // released before the hold threshold → a tap
            return nil
        case .secondDown:
            state = .idle
            return .toggle // second quick tap complete → double-tap toggle
        case .holding:
            state = .idle
            return .stop
        case .idle, .tapPending:
            return nil
        }
    }

    /// Recurring tick; the only place "held long enough" can be decided.
    mutating func onTick(now: UInt64) -> CapturePhase? {
        switch state {
        case .down(let pressAt), .secondDown(let pressAt):
            if Self.elapsed(now, since: pressAt) >= Self.holdThresholdMs {
                state = .holding
                return .start
            }
            return nil
        case .idle, .tapPending, .holding:
            return nil
        }
    }
}

/// Owns the CGEventTap worker thread + the gesture machine, surfacing capture phases as an
/// `AsyncStream`. Modeled like `HeadPointerService`: Xcode 16.2 has no `nonisolated class`,
/// so it opts out per-member (`nonisolated` methods, `nonisolated(unsafe)` self-synchronized
/// state) and is `@unchecked Sendable`. The tap callback + hold timer run on the worker run
/// loop; the `FnGesture` is guarded by an `NSLock`.
final class FnHotkeyService: @unchecked Sendable {
    /// Stream of capture phases. Multiple `for await` consumers are not supported — there is
    /// one host consumer (mic + head tracking), exactly as the single webview listener before.
    let phases: AsyncStream<CapturePhase>

    private let continuation: AsyncStream<CapturePhase>.Continuation
    private let lock = NSLock()
    private nonisolated(unsafe) var gesture = FnGesture()
    private let epochNanos: UInt64 = DispatchTime.now().uptimeNanoseconds

    // Written on the worker thread before the run loop spins; only read on that same thread
    // (in the callback, to re-enable after a disable meta-event). Single-threaded access.
    private nonisolated(unsafe) var tapPort: CFMachPort?
    private nonisolated(unsafe) var started = false

    /// CGEventTap callback granularity; the worst-case extra latency for hold detection.
    private static let holdTickInterval: TimeInterval = 0.05

    init() {
        var sink: AsyncStream<CapturePhase>.Continuation!
        phases = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { sink = $0 }
        continuation = sink
    }

    /// Surface the two consent prompts the fn hotkey needs (Accessibility to create the tap,
    /// Input Monitoring to observe keys), then spawn the worker that owns the tap for the app's
    /// lifetime. Idempotent. Each prompt is a no-op once granted; a fresh grant usually needs a
    /// restart before the tap can install.
    nonisolated func start() {
        guard !started else { return }
        started = true

        let accessibility = PermissionsService.promptAccessibility()
        let inputMonitoring = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if !accessibility || !inputMonitoring {
            FileHandle.standardError.write(Data(
                "handsoff: fn hotkey consent — Accessibility \(accessibility), Input Monitoring \(inputMonitoring). Approve in System Settings > Privacy & Security, then restart so the CGEventTap can install.\n".utf8
            ))
        }

        let thread = Thread { [weak self] in self?.runWorker() }
        thread.name = "handsoff-fn-hotkey"
        thread.start()
    }

    private nonisolated func nowMs() -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds &- epochNanos) / 1_000_000
    }

    private nonisolated func emit(_ phase: CapturePhase) {
        continuation.yield(phase)
    }

    /// Drive the machine from a real fn up/down transition (called on the worker run loop).
    fileprivate nonisolated func handleFlags(fnDown: Bool) {
        let now = nowMs()
        let phase: CapturePhase?
        lock.lock()
        phase = fnDown ? gesture.onPress(now: now) : gesture.onRelease(now: now)
        lock.unlock()
        if let phase { emit(phase) }
    }

    /// Hold-detection tick (called on the worker run loop).
    fileprivate nonisolated func handleTick() {
        let now = nowMs()
        lock.lock()
        let phase = gesture.onTick(now: now)
        lock.unlock()
        if let phase { emit(phase) }
    }

    /// Re-enable the tap after macOS auto-disables it (timeout / user input).
    fileprivate nonisolated func reenableTap() {
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
    }

    private nonisolated func runWorker() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly, // never suppresses or rewrites events
            eventsOfInterest: mask,
            callback: fnTapCallback,
            userInfo: userInfo
        ) else {
            FileHandle.standardError.write(Data(
                "handsoff: fn hotkey CGEventTap FAILED to install — grant Accessibility (System Settings > Privacy & Security > Accessibility), set Keyboard > \"Press fn (Globe) key to\" to \"Do Nothing\", and restart.\n".utf8
            ))
            return
        }
        tapPort = tap

        let runLoop = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let timer = Timer(timeInterval: Self.holdTickInterval, repeats: true) { [weak self] _ in
            self?.handleTick()
        }
        RunLoop.current.add(timer, forMode: .common)

        FileHandle.standardError.write(Data("handsoff: fn hotkey CGEventTap installed (press-hold / double-tap on fn)\n".utf8))
        CFRunLoopRun() // blocks the worker thread for the app lifetime
    }
}

/// The `@convention(c)` tap callback — cannot capture context, so it reconstructs the service
/// from `userInfo`. Runs on the worker run loop (single-threaded with the timer above).
private nonisolated func fnTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<FnHotkeyService>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        service.reenableTap()
        return Unmanaged.passUnretained(event)
    }
    if type == .flagsChanged {
        service.handleFlags(fnDown: event.flags.contains(.maskSecondaryFn))
    }
    return Unmanaged.passUnretained(event)
}
