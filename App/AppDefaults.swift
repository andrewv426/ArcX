import Foundation

/// The app's preferences. All app code reads and writes preferences through `store`, so scripted
/// test runs get a domain of their own (`app.arcx.ArcX.tests`) and never change the user's.
enum AppDefaults {
    /// UserDefaults is thread-safe, but this SDK does not mark it Sendable.
    nonisolated(unsafe) static let store: UserDefaults = {
        #if DEBUG
        if TestHost.isActive, let tests = UserDefaults(suiteName: TestHost.defaultsSuite) {
            return tests
        }
        #endif
        return .standard
    }()
}
