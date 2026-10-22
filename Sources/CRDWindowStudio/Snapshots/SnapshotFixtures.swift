import AppKit
import CRDSettingsCore

/// Fixed helper states for offscreen snapshots. They replace companionctl.py and
/// the support-folder reads; nothing here touches the real helper or CRD host.
enum FixtureState: String, CaseIterable, Sendable {
    case running, waiting, off, permission, missing, blocked
    /// The controller's `status` JSON for this state.
    var companionJSON: [String: Any]? {
        let service: [String: Any] = ["loaded": true, "running": true, "pid": 4242]
        let stopped: [String: Any] = ["loaded": false, "running": false]
        let original: [String: Any] = ["loaded": true, "running": true, "pid": 812]
        func status(_ state: String, _ companion: [String: Any], _ runtime: [String: Any]) -> [String: Any] {
            ["state": state, "companionPath": "~/Library/Application Support/CRDWindowPatch/CRD Window Host.app",
             "companionService": companion, "originalService": original, "runtime": runtime,
             "originalBundleModifiedByCompanion": false]
        }
        let ready: [String: Any] = ["confirmed": true, "agentReady": true, "observerReady": true, "accessibility": true,
                                    "backendKind": "accessibility-overlay", "fixture": false, "pid": 4242, "mode": "custom"]
        switch self {
        case .running:
            return status("active", service, ready.merging(["originalWindowDetected": true, "visible": true, "originalHidden": true, "originalPid": 812]) { $1 })
        case .waiting:
            return status("active", service, ready.merging(["originalWindowDetected": false, "visible": false, "originalHidden": false]) { $1 })
        case .off:
            return status("restored", stopped, ["confirmed": false])
        case .permission:
            return status("active", service, ["confirmed": false, "agentReady": false, "observerReady": true,
                                               "backendKind": "accessibility-overlay", "originalWindowDetected": false,
                                               "fixture": false, "pid": 4242, "mode": "custom", "accessibility": false])
        case .missing:
            return status("not_installed", stopped, ["confirmed": false])
        case .blocked:
            // The original sharing window could not be shown again.
            return status("active", service, ready.merging(["agentReady": false, "accessibility": false, "originalWindowDetected": true,
                                                            "restorationPending": true, "restorationBlocked": true, "refreshConfirmed": true]) { $1 })
        }
    }
    /// What the fake controller prints for `status`.
    var statusData: Data {
        (try? JSONSerialization.data(withJSONObject: companionJSON ?? [:])) ?? Data()
    }
    /// The host inspection result for this state.
    var host: HostInspection {
        switch self {
        case .running: return .init(version: "155.0.8059", patchInstalled: true, running: true, windowObserved: true, detail: L10n.text("창 도우미 실행 중"))
        case .waiting: return .init(version: "155.0.8059", patchInstalled: true, running: true, windowObserved: false, detail: L10n.text("창 도우미 실행 중"))
        case .off, .permission, .blocked: return .init(version: "155.0.8059", patchInstalled: true, running: false, windowObserved: false, detail: L10n.text("창 도우미 꺼짐"))
        case .missing: return .init(version: nil, patchInstalled: false, running: false, windowObserved: false, detail: L10n.text("Chrome 원격 데스크톱 설치 필요"))
        }
    }
}

/// One fresh set of stores per rendered page, backed by a temporary config file.
@MainActor struct SnapshotFixture {
    let store: SettingsStore
    let preferences: AppPreferences
    let companion: CompanionService
    let preview: PreviewWindowController
    let defaults: UserDefaults
    let suite: String
    /// Writes `config` (or `raw` bytes) to `configURL`, builds the stores with a fake controller and
    /// fixed host facts, and waits up to about two seconds for the first status and host results.
    static func make(state: FixtureState, config: [String: ConfigValue], configURL: URL, raw: Data? = nil) async throws -> Self {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (raw ?? encoder.encode(config)).write(to: configURL, options: .atomic)
        let schema = try SettingsSchema.load()
        let host = state.host
        let store = SettingsStore(repository: ConfigurationRepository(url: configURL, schema: schema), inspectHost: { host })
        let suite = "local.crdwindow.studio.snapshot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = AppPreferences(defaults: defaults, readsLoginItem: false)
        // The backend's executor seam: a fake controller that only answers `status`. No process runs.
        let data = state.statusData
        let companion = CompanionService(script: URL(fileURLWithPath: "/fixture/companionctl.py"), includesRuntime: true) { _, _ in data }
        companion.refresh()
        store.refreshHost()
        var waited = 0
        while (companion.busy || store.host.detail != host.detail) && waited < 400 {
            try await Task.sleep(nanoseconds: 5_000_000); waited += 1
        }
        return Self(store: store, preferences: preferences, companion: companion,
                    preview: PreviewWindowController(store: store), defaults: defaults, suite: suite)
    }
}
