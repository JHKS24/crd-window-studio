import Foundation

/// Process-wide flags of the running app.
enum AppRuntime {
    /// Set only by the offscreen snapshot renderer.
    @MainActor static var renderingSnapshots = false
}
