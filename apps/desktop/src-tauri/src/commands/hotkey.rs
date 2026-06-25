// Capture trigger: the bare `fn` (Globe) key (#95).
//
// The previous binding used tauri-plugin-global-shortcut (Carbon
// RegisterEventHotKey), which has no `fn` modifier and can't see the fn key at
// all (it emits no normal keyDown). Both bindings now collapse onto the one key,
// observed directly with a listen-only CGEventTap on `kCGEventFlagsChanged`
// watching the `kCGEventFlagMaskSecondaryFn` bit:
//
//   * press-hold (hold >= HOLD_THRESHOLD_MS) -> emits `start` when the hold
//     commits, `stop` on release. (Press-hold has ~HOLD_THRESHOLD_MS latency
//     before `start` so a quick tap is never mistaken for a hold.)
//   * double-tap (two quick taps within MULTI_TAP_WINDOW_MS) -> emits `toggle`.
//
// A single tap is just the first half of a potential double-tap and emits
// nothing. The webview drives mic + head tracking from the same
// `hotkey://capture` `{ phase }` payload it always has.
//
// Permission trade-off (reverses the original "no extra permission" choice,
// which was the explicit reason for Carbon): a listen-only CGEventTap needs the
// app to be a trusted Accessibility client (AXIsProcessTrusted); recent macOS
// may also require Input Monitoring. macOS also swallows the bare fn press for
// its emoji/dictation action unless System Settings > Keyboard > "Press fn
// (Globe) key to" is set to "Do Nothing". Verify from the bundled .app, never
// `tauri dev`.

use tauri::AppHandle;

pub const EVENT_NAME: &str = "hotkey://capture";

/// A press held this long (without release) commits to press-hold. Kept above a
/// firm tap duration (~120 ms) so taps aren't misread as holds.
const HOLD_THRESHOLD_MS: u64 = 250;
/// Max gap between the first tap's release and the second tap's press.
const MULTI_TAP_WINDOW_MS: u64 = 300;

/// Capture phase emitted to the webview — same vocabulary the frontend already
/// consumes (`start` / `stop` / `toggle`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Start,
    Stop,
    Toggle,
}

impl Phase {
    fn as_str(self) -> &'static str {
        match self {
            Phase::Start => "start",
            Phase::Stop => "stop",
            Phase::Toggle => "toggle",
        }
    }
}

// ---- Pure gesture state machine ----------------------------------------------
// No I/O: takes monotonic-millisecond instants and returns the phase to emit.
// Fully unit-tested below; the CGEventTap layer just feeds real fn transitions
// (and a recurring tick for hold detection) into it.

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
enum Gesture {
    #[default]
    Idle,
    /// fn is down; not yet committed (could become a hold or the first tap).
    Down { press_at: u64 },
    /// fn is up; one tap recorded; waiting for a second tap within the window.
    TapPending { released_at: u64 },
    /// fn is down; this is the second tap (commits to toggle on release, or to a
    /// hold if held past the threshold).
    SecondDown { press_at: u64 },
    /// Committed to press-hold; emitted `start`; waiting for release -> `stop`.
    Holding,
}

#[derive(Debug, Default)]
pub struct FnGesture {
    gesture: Gesture,
}

impl FnGesture {
    pub fn new() -> Self {
        Self::default()
    }

    /// fn key transitioned to pressed at `now_ms`.
    pub fn on_press(&mut self, now_ms: u64) -> Option<Phase> {
        match self.gesture {
            Gesture::Idle => {
                self.gesture = Gesture::Down { press_at: now_ms };
                None
            }
            Gesture::TapPending { released_at } => {
                if now_ms.saturating_sub(released_at) <= MULTI_TAP_WINDOW_MS {
                    // Second tap landed inside the double-tap window.
                    self.gesture = Gesture::SecondDown { press_at: now_ms };
                } else {
                    // Pending tap expired; this is a fresh first press.
                    self.gesture = Gesture::Down { press_at: now_ms };
                }
                None
            }
            // Spurious press without an intervening release; stay put.
            Gesture::Down { .. } | Gesture::SecondDown { .. } | Gesture::Holding => None,
        }
    }

    /// fn key transitioned to released at `now_ms`.
    pub fn on_release(&mut self, now_ms: u64) -> Option<Phase> {
        match self.gesture {
            // Released before the hold threshold fired -> it's a tap.
            Gesture::Down { .. } => {
                self.gesture = Gesture::TapPending {
                    released_at: now_ms,
                };
                None
            }
            Gesture::SecondDown { .. } => {
                // Second quick tap complete -> double-tap toggle.
                self.gesture = Gesture::Idle;
                Some(Phase::Toggle)
            }
            Gesture::Holding => {
                self.gesture = Gesture::Idle;
                Some(Phase::Stop)
            }
            Gesture::Idle | Gesture::TapPending { .. } => None,
        }
    }

    /// Recurring timer tick; the only place "held long enough" can be decided.
    pub fn on_tick(&mut self, now_ms: u64) -> Option<Phase> {
        match self.gesture {
            Gesture::Down { press_at } | Gesture::SecondDown { press_at } => {
                if now_ms.saturating_sub(press_at) >= HOLD_THRESHOLD_MS {
                    self.gesture = Gesture::Holding;
                    Some(Phase::Start)
                } else {
                    None
                }
            }
            Gesture::Idle | Gesture::TapPending { .. } | Gesture::Holding => None,
        }
    }
}

// ---- macOS CGEventTap wiring --------------------------------------------------

#[cfg(target_os = "macos")]
#[allow(non_upper_case_globals)] // constants mirror Apple's CGEventTypes.h
mod platform {
    use super::{FnGesture, Phase, EVENT_NAME};
    use serde_json::json;
    use std::ffi::c_void;
    use std::sync::Mutex;
    use std::thread;
    use std::time::Instant;
    use tauri::{AppHandle, Emitter};

    // CGEventTapLocation / Placement / Options / EventType / EventFlags
    // constants. Names mirror Apple's CGEventTypes.h verbatim to aid
    // cross-referencing (the module-level allow silences the naming lint).
    const kCGSessionEventTap: u32 = 1; // CGEventTapLocation
    const kCGHeadInsertEventTap: u32 = 0; // CGEventTapPlacement
    const kCGEventTapOptionListenOnly: u32 = 1; // CGEventTapOptions
    const kCGEventFlagsChanged: u32 = 12; // CGEventType
    const kCGEventTapDisabledByTimeout: u32 = 0xFFFF_FFFE;
    const kCGEventTapDisabledByUserInput: u32 = 0xFFFF_FFFF;
    const kCGEventFlagMaskSecondaryFn: u64 = 1 << 23; // CGEventFlags (0x800000)

    /// CGEventTap callback interval (s). Sets the granularity (and thus the
    /// worst-case extra latency) for press-hold detection.
    const HOLD_TICK_INTERVAL_SECS: f64 = 0.05;

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGEventTapCreate(
            location: u32,
            placement: u32,
            options: u32,
            event_mask: u64,
            callback: unsafe extern "C" fn(
                proxy: *const c_void,
                type_: u32,
                event: *const c_void,
                user_info: *mut c_void,
            ) -> *const c_void,
            user_info: *mut c_void,
        ) -> *const c_void; // CFMachPortRef

        fn CGEventGetFlags(event: *const c_void) -> u64;
        fn CGEventTapEnable(tap: *const c_void, enable: u8);
    }

    // Accessibility trust (HIServices, via ApplicationServices). The CGEventTap
    // needs the app to be a trusted Accessibility client.
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        static kAXTrustedCheckOptionPrompt: *const c_void; // CFStringRef
        fn AXIsProcessTrustedWithOptions(options: *const c_void) -> u8; // Boolean
    }

    // Input Monitoring consent (IOKit). Keyboard-observation via the tap needs
    // this on macOS 10.15+.
    #[link(name = "IOKit", kind = "framework")]
    extern "C" {
        // IOHIDRequestType: kIOHIDRequestTypeListenEvent == 1 (observe input).
        fn IOHIDRequestAccess(request_type: i32) -> u8; // bool
    }
    const kIOHIDRequestTypeListenEvent: i32 = 1;

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        static kCFRunLoopCommonModes: *const c_void;
        static kCFBooleanTrue: *const c_void;
        fn CFMachPortCreateRunLoopSource(
            allocator: *const c_void,
            port: *const c_void,
            order: isize,
        ) -> *const c_void; // CFRunLoopSourceRef
        fn CFRunLoopGetCurrent() -> *const c_void;
        fn CFRunLoopAddSource(rl: *const c_void, source: *const c_void, mode: *const c_void);
        fn CFRunLoopAddTimer(rl: *const c_void, timer: *const c_void, mode: *const c_void);
        fn CFRunLoopRun();
        fn CFRelease(cf: *const c_void);
        fn CFDictionaryCreate(
            allocator: *const c_void,
            keys: *const *const c_void,
            values: *const *const c_void,
            num_values: isize,
            key_callbacks: *const c_void,
            value_callbacks: *const c_void,
        ) -> *const c_void;
        fn CFRunLoopTimerCreate(
            allocator: *const c_void,
            fire_date: f64,
            interval: f64,
            flags: u64,
            order: isize,
            callout: unsafe extern "C" fn(timer: *const c_void, info: *mut c_void),
            context: *mut CFRunLoopTimerContext,
        ) -> *const c_void;
        fn CFAbsoluteTimeGetCurrent() -> f64;
    }

    #[repr(C)]
    struct CFRunLoopTimerContext {
        version: isize,
        info: *mut c_void,
        retain: Option<unsafe extern "C" fn(*const c_void) -> *const c_void>,
        release: Option<unsafe extern "C" fn(*const c_void)>,
        copy_description: Option<unsafe extern "C" fn(*const c_void) -> *const c_void>,
    }

    struct FnTapCtx {
        app: AppHandle,
        gesture: Mutex<FnGesture>,
        epoch: Instant,
        // Set right after CGEventTapCreate, before the run loop spins. Read in
        // the callback (same thread) only to re-enable after a disable meta-event.
        tap: std::cell::UnsafeCell<*const c_void>,
    }

    fn now_millis(epoch: Instant) -> u64 {
        Instant::now().duration_since(epoch).as_millis() as u64
    }

    fn emit(app: &AppHandle, phase: Phase) {
        let _ = app.emit(EVENT_NAME, json!({ "phase": phase.as_str() }));
    }

    unsafe extern "C" fn flags_changed_callback(
        _proxy: *const c_void,
        type_: u32,
        event: *const c_void,
        user_info: *mut c_void,
    ) -> *const c_void {
        // The run loop delivers these meta-events when the tap is auto-disabled.
        if type_ == kCGEventTapDisabledByTimeout || type_ == kCGEventTapDisabledByUserInput {
            let ctx_ptr = user_info as *mut FnTapCtx;
            if !ctx_ptr.is_null() {
                // SAFETY: ctx lives on this worker thread; the callback runs here.
                let ctx = &*ctx_ptr;
                let tap = *ctx.tap.get();
                if !tap.is_null() {
                    CGEventTapEnable(tap, 1);
                }
            }
            return event;
        }

        if type_ != kCGEventFlagsChanged || event.is_null() {
            return event;
        }
        let ctx_ptr = user_info as *mut FnTapCtx;
        if ctx_ptr.is_null() {
            return event;
        }
        // SAFETY: ctx is owned by the worker thread and the callback is invoked
        // on that thread's CFRunLoop, so access is single-threaded.
        let ctx = &*ctx_ptr;
        let fn_down = (CGEventGetFlags(event) & kCGEventFlagMaskSecondaryFn) != 0;
        let now_ms = now_millis(ctx.epoch);
        let phase = {
            let mut gesture = ctx.gesture.lock().unwrap();
            if fn_down {
                gesture.on_press(now_ms)
            } else {
                gesture.on_release(now_ms)
            }
        };
        if let Some(phase) = phase {
            emit(&ctx.app, phase);
        }
        event
    }

    unsafe extern "C" fn hold_tick_callback(_timer: *const c_void, user_info: *mut c_void) {
        let ctx_ptr = user_info as *mut FnTapCtx;
        if ctx_ptr.is_null() {
            return;
        }
        // SAFETY: same single-threaded guarantee as the flags-changed callback.
        let ctx = &*ctx_ptr;
        let now_ms = now_millis(ctx.epoch);
        let phase = ctx.gesture.lock().unwrap().on_tick(now_ms);
        if let Some(phase) = phase {
            emit(&ctx.app, phase);
        }
    }

    /// Surface the Accessibility consent prompt (no-op if already granted).
    /// Returns the current trust state. Neither call blocks.
    fn prompt_for_accessibility() -> bool {
        // SAFETY: builds a 1-entry CFDictionary { kAXTrustedCheckOptionPrompt:
        // kCFBooleanTrue } with NULL callbacks. Safe because both the key (a
        // CFString constant) and value (kCFBooleanTrue) are immortal global CF
        // objects that are never released.
        unsafe {
            let keys: [*const c_void; 1] = [kAXTrustedCheckOptionPrompt];
            let values: [*const c_void; 1] = [kCFBooleanTrue];
            let options = CFDictionaryCreate(
                std::ptr::null(),
                keys.as_ptr(),
                values.as_ptr(),
                1,
                std::ptr::null(),
                std::ptr::null(),
            );
            let trusted = AXIsProcessTrustedWithOptions(options) != 0;
            if !options.is_null() {
                CFRelease(options);
            }
            trusted
        }
    }

    /// Surface the Input Monitoring consent prompt (no-op if already decided).
    /// Returns whether access is currently granted.
    fn prompt_for_input_monitoring() -> bool {
        // SAFETY: IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) is the public
        // request for keyboard-observation (Input Monitoring) consent. It shows
        // the system prompt when the state is undetermined and returns the
        // current decision without blocking.
        unsafe { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) != 0 }
    }

    /// Spawn the worker thread that owns the CGEventTap. Lives for the app's
    /// lifetime; failures are surfaced (not swallowed) so "nothing happens on fn"
    /// has a clue.
    pub fn install(app: AppHandle) {
        // Surface both consent prompts the fn hotkey needs up front: Accessibility
        // to create the CGEventTap, Input Monitoring to observe keyboard events.
        // Each is a no-op once granted; a fresh grant usually needs a restart
        // before the tap can install.
        let accessibility = prompt_for_accessibility();
        let input_monitoring = prompt_for_input_monitoring();
        if !accessibility || !input_monitoring {
            eprintln!(
                "handsoff: fn hotkey consent — Accessibility {accessibility}, Input Monitoring \
                 {input_monitoring}. Approve in System Settings > Privacy & Security, then \
                 restart the app so the CGEventTap can install."
            );
        }
        thread::Builder::new()
            .name("handsoff-fn-hotkey".into())
            .spawn(move || worker(app))
            .expect("handsoff: failed to spawn fn-hotkey worker thread");
    }

    fn worker(app: AppHandle) {
        let ctx = Box::new(FnTapCtx {
            app,
            gesture: Mutex::new(FnGesture::new()),
            epoch: Instant::now(),
            tap: std::cell::UnsafeCell::new(std::ptr::null()),
        });
        // Leaked for the app lifetime (the run loop below never returns); the
        // raw pointer is handed to both CG/CF callbacks as `userInfo`.
        let ctx_ptr: *mut FnTapCtx = Box::into_raw(ctx);

        let event_mask = 1u64 << kCGEventFlagsChanged;
        // SAFETY: CGEventTapCreate returns a CFMachPortRef, or NULL when the
        // process is not a trusted Accessibility client. Listen-only => the tap
        // never suppresses or rewrites events.
        let tap = unsafe {
            CGEventTapCreate(
                kCGSessionEventTap,
                kCGHeadInsertEventTap,
                kCGEventTapOptionListenOnly,
                event_mask,
                flags_changed_callback,
                ctx_ptr as *mut c_void,
            )
        };
        if tap.is_null() {
            eprintln!(
                "handsoff: fn hotkey CGEventTap FAILED to install — grant Accessibility \
                 (System Settings > Privacy & Security > Accessibility), set Keyboard > \
                 \"Press fn (Globe) key to\" to \"Do Nothing\", and restart."
            );
            // Reclaim the box so we don't leak on the failure path.
            unsafe { drop(Box::from_raw(ctx_ptr)) };
            return;
        }
        // SAFETY: written before the run loop starts; only read on this thread.
        unsafe {
            *(*ctx_ptr).tap.get() = tap;
        }

        // SAFETY: standard CF run-loop wiring on the current (worker) thread.
        let run_loop = unsafe { CFRunLoopGetCurrent() };
        let source = unsafe { CFMachPortCreateRunLoopSource(std::ptr::null(), tap, 0) };
        unsafe { CFRunLoopAddSource(run_loop, source, kCFRunLoopCommonModes) };

        // SAFETY: a recurring one-shot-style timer; the context struct is copied
        // by value into the timer, so the local may drop after creation.
        let timer = unsafe {
            let mut context = CFRunLoopTimerContext {
                version: 0,
                info: ctx_ptr as *mut c_void,
                retain: None,
                release: None,
                copy_description: None,
            };
            CFRunLoopTimerCreate(
                std::ptr::null(),
                CFAbsoluteTimeGetCurrent() + HOLD_TICK_INTERVAL_SECS,
                HOLD_TICK_INTERVAL_SECS,
                0,
                0,
                hold_tick_callback,
                &mut context,
            )
        };
        unsafe { CFRunLoopAddTimer(run_loop, timer, kCFRunLoopCommonModes) };

        eprintln!("handsoff: fn hotkey CGEventTap installed (press-hold / double-tap on fn)");
        // SAFETY: blocks the worker thread for the app lifetime.
        unsafe { CFRunLoopRun() };
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use tauri::AppHandle;

    pub fn install(_app: AppHandle) {
        eprintln!("handsoff: fn hotkey CGEventTap is macOS-only; skipped on this platform");
    }
}

/// Install the global fn-key capture trigger. macOS wires a CGEventTap; other
/// platforms are a no-op.
pub fn install(app: AppHandle) {
    platform::install(app);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_name_is_unchanged_frontend_contract() {
        assert_eq!(EVENT_NAME, "hotkey://capture");
    }

    #[test]
    fn phase_strings_match_frontend_vocabulary() {
        assert_eq!(Phase::Start.as_str(), "start");
        assert_eq!(Phase::Stop.as_str(), "stop");
        assert_eq!(Phase::Toggle.as_str(), "toggle");
    }

    #[test]
    fn press_hold_emits_start_then_stop() {
        let mut g = FnGesture::new();
        assert_eq!(g.on_press(0), None); // down
        assert_eq!(g.on_tick(200), None); // below threshold -> still a possible tap
        assert_eq!(g.on_tick(250), Some(Phase::Start)); // hold commits
        assert_eq!(g.on_tick(1_000), None); // already holding
        assert_eq!(g.on_release(1_200), Some(Phase::Stop));
    }

    #[test]
    fn double_tap_emits_toggle() {
        let mut g = FnGesture::new();
        assert_eq!(g.on_press(0), None); // tap 1 down
        assert_eq!(g.on_release(80), None); // tap 1 up -> TapPending
        assert_eq!(g.on_press(200), None); // tap 2 down (within 300 ms window)
        assert_eq!(g.on_release(280), Some(Phase::Toggle));
    }

    #[test]
    fn single_tap_emits_nothing() {
        let mut g = FnGesture::new();
        assert_eq!(g.on_press(0), None);
        assert_eq!(g.on_release(80), None); // pending
                                            // No second tap arrives; ticks on TapPending never emit.
        assert_eq!(g.on_tick(500), None);
        assert_eq!(g.on_tick(10_000), None);
    }

    #[test]
    fn expired_pending_tap_is_not_a_double_tap() {
        let mut g = FnGesture::new();
        assert_eq!(g.on_press(0), None);
        assert_eq!(g.on_release(80), None); // TapPending
                                            // A press well past the 300 ms window is a fresh first press, not toggle.
        assert_eq!(g.on_press(500), None);
        assert_eq!(g.on_release(560), None); // TapPending again, still no emit
    }

    #[test]
    fn hold_then_separate_tap_does_not_toggle() {
        let mut g = FnGesture::new();
        assert_eq!(g.on_press(0), None);
        assert_eq!(g.on_tick(250), Some(Phase::Start));
        assert_eq!(g.on_release(400), Some(Phase::Stop));
        // A later quick tap is its own gesture, never a toggle.
        assert_eq!(g.on_press(500), None);
        assert_eq!(g.on_release(560), None);
    }

    #[test]
    fn second_tap_held_long_becomes_hold() {
        let mut g = FnGesture::new();
        assert_eq!(g.on_press(0), None);
        assert_eq!(g.on_release(80), None); // TapPending
        assert_eq!(g.on_press(200), None); // second tap down (SecondDown)
                                           // Holding the second press past the threshold flips it to a hold.
        assert_eq!(g.on_tick(500), Some(Phase::Start));
        assert_eq!(g.on_release(700), Some(Phase::Stop));
    }

    #[test]
    fn spurious_release_is_a_noop() {
        let mut g = FnGesture::new();
        assert_eq!(g.on_release(0), None); // Idle
        assert_eq!(g.on_press(10), None);
        assert_eq!(g.on_release(20), None); // -> TapPending
        assert_eq!(g.on_release(30), None); // release while TapPending: noop
    }

    #[test]
    fn fn_bit_idempotent_signals_are_absorbed() {
        // Repeated press-while-down (e.g. other modifiers firing flagsChanged
        // with the fn bit still set) must not advance or emit.
        let mut g = FnGesture::new();
        assert_eq!(g.on_press(0), None);
        assert_eq!(g.on_press(5), None); // spurious
        assert_eq!(g.on_press(10), None); // spurious
        assert_eq!(g.on_release(80), None);
    }
}
