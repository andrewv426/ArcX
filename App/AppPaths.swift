import Foundation

/// Where the app keeps its data.
///
/// Normally `~/Library/Application Support/ArcX/`, or `ARCX_DATA_DIR` when set. A self-test run
/// always uses `data/` inside its output folder and ignores `ARCX_DATA_DIR`, so a test can never
/// read or overwrite the user's session.
@MainActor
enum AppPaths {
    static let dataDirectory: URL = {
        #if DEBUG
        if let output = TestHost.selfTestOutput {
            return output.appendingPathComponent("data", isDirectory: true)
        }
        #endif
        if let custom = ProcessInfo.processInfo.environment["ARCX_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ArcX", isDirectory: true)
    }()

    static var sessionFile: URL { dataDirectory.appendingPathComponent("session.json") }
}
