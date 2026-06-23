import AppKit
import CoreGraphics
import Foundation

// Entry point for the gesture-overlay sidecar.
//
// `--selftest` is invoked by the build script: it enumerates displays via CoreGraphics,
// reports the count on stdout, and exits — verifying the binary launches and links without
// needing a running app or camera. Without the flag, it runs as an accessory (no Dock icon,
// never steals focus) with the OverlayController as delegate, reading cursor commands on
// stdin until the host closes the pipe.

if CommandLine.arguments.contains("--selftest") {
    let count = enumerateDisplays().count
    let payload = try? JSONSerialization.data(
        withJSONObject: ["kind": "selftest", "displays": count]
    )
    if var data = payload {
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
    exit(0)
}

let app = NSApplication.shared
let controller = OverlayController()
app.delegate = controller
app.run()
