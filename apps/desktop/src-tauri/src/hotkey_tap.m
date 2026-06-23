// Right Option + ? global hotkey, owned by the app process (#95).
//
// The CGEventTap MUST live in the app (stable bundle identity com.handsoff.desktop)
// rather than the adhoc-signed head-track sidecar: macOS will not grant Input
// Monitoring to a no-Team-ID child helper, so the tap silently fails there. Here
// the app already gets TCC prompts, so we actively request Accessibility + Input
// Monitoring, install the tap, retry until it arms, and forward raw key events to
// Rust, which owns the pure hold-state machine and drives capture start/stop.

#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <dispatch/dispatch.h>

// kind: 0 = flagsChanged, 1 = keyDown. Rust decides start/stop from (kind, keyCode, flags).
typedef void (*HandsOffHotkeyCallback)(int kind, long long key_code, unsigned long long flags);

static CFMachPortRef g_tap = NULL;
static CFRunLoopSourceRef g_source = NULL;
static HandsOffHotkeyCallback g_callback = NULL;

static CGEventRef hotkey_tap_callback(CGEventTapProxy proxy,
                                      CGEventType type,
                                      CGEventRef event,
                                      void *userInfo) {
  (void)proxy;
  (void)userInfo;

  // Re-enable if macOS disables the tap (timeout / user input).
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    if (g_tap != NULL) {
      CGEventTapEnable(g_tap, true);
    }
    return event;
  }

  int kind = -1;
  if (type == kCGEventFlagsChanged) {
    kind = 0;
  } else if (type == kCGEventKeyDown) {
    kind = 1;
  } else {
    return event;
  }

  if (g_callback != NULL) {
    long long keyCode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    unsigned long long flags = (unsigned long long)CGEventGetFlags(event);
    g_callback(kind, keyCode, flags);
  }
  return event;
}

// Raise the two TCC prompts the event tap needs. Returns nothing; the caller
// retries tap install until macOS lets it through after the user grants.
void handsoff_hotkey_request_permissions(void) {
  IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
  NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES};
  AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

// Try to install the tap once. Must run on the main thread (the CFMachPort source
// is added to the main run loop, which Cocoa keeps running). Returns 1 on success.
static int hotkey_try_install_main_thread(void) {
  if (g_tap != NULL) {
    return 1;
  }
  CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventKeyDown);
  CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap,
                                       kCGHeadInsertEventTap,
                                       kCGEventTapOptionDefault,
                                       mask,
                                       hotkey_tap_callback,
                                       NULL);
  if (tap == NULL) {
    fputs("handsoff-hotkey: CGEventTapCreate failed (Accessibility/Input Monitoring not granted yet)\n", stderr);
    return 0;
  }
  g_tap = tap;
  g_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
  if (g_source != NULL) {
    CFRunLoopAddSource(CFRunLoopGetMain(), g_source, kCFRunLoopCommonModes);
  }
  CGEventTapEnable(tap, true);
  fputs("handsoff-hotkey: armed Right Option + ? tap\n", stderr);
  return 1;
}

// Install the event tap, retrying on the MAIN run loop every 1.5s until macOS
// lets it through (so granting Accessibility/Input Monitoring after launch arms
// without a relaunch). Safe to call from any thread; work is hopped to main.
void handsoff_hotkey_install(HandsOffHotkeyCallback callback) {
  g_callback = callback;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (hotkey_try_install_main_thread() == 1) {
      return;
    }
    // Retry on the main run loop until it arms.
    __block CFRunLoopTimerRef timer = NULL;
    timer = CFRunLoopTimerCreateWithHandler(
        kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 1.5,
        1.5,
        0,
        0,
        ^(CFRunLoopTimerRef t) {
          if (hotkey_try_install_main_thread() == 1) {
            CFRunLoopTimerInvalidate(t);
          }
        });
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
  });
}
