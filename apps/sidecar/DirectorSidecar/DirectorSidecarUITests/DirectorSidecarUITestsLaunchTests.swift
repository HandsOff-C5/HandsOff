//
//  DirectorSidecarUITestsLaunchTests.swift
//  DirectorSidecarUITests
//
//  Created by Jason Dijols on 6/24/26.
//

import XCTest

final class DirectorSidecarUITestsLaunchTests: XCTestCase {

    // Must stay false. When true, Xcode runs `testLaunch()` once per UI configuration and, to
    // render the Dark configuration, switches the MACHINE's system appearance to Dark — which it
    // leaves applied if the run is interrupted, stranding the developer's Mac in dark mode. We
    // don't snapshot light/dark here, so sweeping configurations only risks that side effect.
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
