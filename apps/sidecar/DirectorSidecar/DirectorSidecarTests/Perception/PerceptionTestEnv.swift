import Foundation

/// Test-environment gating for the perception suite.
enum PerceptionTestEnv {
    /// True on a headless CI runner. The few tests that invoke a REAL Vision request
    /// (`VNDetectFaceLandmarksRequest` / hand pose) hang indefinitely there — the Vision analysis
    /// service needs a GUI/login session the runner lacks — so they are skipped on CI and run only
    /// locally (where they pass in milliseconds). Everything else uses synthetic signals and runs
    /// everywhere. Detected via the standard `CI` / `GITHUB_ACTIONS` env vars.
    static let isHeadlessCI: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["CI"] != nil || env["GITHUB_ACTIONS"] != nil
    }()
}
