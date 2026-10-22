import Foundation
import Darwin

/// A read-only snapshot of the Chrome Remote Desktop host and the window helper:
/// the host version, whether the helper is installed and running, and whether it sees the host window.
public struct HostInspection: Sendable {
    public let version: String?
    public let patchInstalled: Bool
    public let running: Bool
    public let windowObserved: Bool
    public let detail: String
    public init(version: String?, patchInstalled: Bool, running: Bool, windowObserved: Bool, detail: String) {
        self.version = version; self.patchInstalled = patchInstalled; self.running = running
        self.windowObserved = windowObserved; self.detail = detail
    }
    /// The state shown before the first inspection.
    public static var unchecked: Self {
        .init(version: nil, patchInstalled: false, running: false, windowObserved: false, detail: L10n.text("확인 전"))
    }
    /// Reads the install receipt, the host's Info.plist and the helper's runtime status.
    /// The helper counts as running only when the receipt is active, the runtime status is live and
    /// newer than the install, and the process at its pid is the installed helper executable.
    /// `processMatches` replaces that process check in tests.
    public static func inspect(support supplied: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                               processMatches: ((Int32, String) -> Bool)? = nil) -> Self {
        let support = supplied ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CRDWindowPatch")
        func object(_ file: String, in directory: URL) -> [String: Any]? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let receipt = object("companion-install.json", in: support)
        let config = environment["CRD_WINDOW_CONFIG"] ?? receipt?["configPath"] as? String
        let runtimeDirectory = config.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).deletingLastPathComponent() } ?? support
        let host = URL(fileURLWithPath: environment["CRD_HOST_APP"]
                       ?? receipt?["originalHostPath"] as? String
                       ?? "/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app")
        let info = try? Data(contentsOf: host.appendingPathComponent("Contents/Info.plist"))
        let dict = info.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let version = dict?["CFBundleVersion"] as? String
        let companionPath = receipt?["companionPath"] as? String
        let installed = companionPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let runtime = object("runtime-status.json", in: runtimeDirectory)
        let pid = (runtime?["pid"] as? NSNumber)?.int32Value ?? 0
        var running = false
        if installed, receipt?["state"] as? String == "active", pid > 0,
           runtime?["fixture"] as? Bool == false,
           runtime?["backendKind"] as? String == "accessibility-overlay",
           runtime?["agentReady"] as? Bool == true,
           runtime?["observerReady"] as? Bool == true,
           (runtime?["lastEventTimestamp"] as? Double ?? 0) >= (receipt?["installedAt"] as? Double ?? 0),
           let companionPath {
            running = (processMatches ?? companionProcessMatches)(pid, companionPath + "/Contents/MacOS/CRDWindowAgent")
        }
        let detail: String
        if running { detail = L10n.text("창 도우미 실행 중") }
        else if installed { detail = L10n.text("창 도우미 꺼짐") }
        else { detail = version == nil ? L10n.text("Chrome 원격 데스크톱 설치 필요") : L10n.text("창 도우미가 설치되지 않음") }
        return .init(version: version, patchInstalled: installed, running: running,
                     windowObserved: running && runtime?["originalWindowDetected"] as? Bool == true, detail: detail)
    }
    /// True when `pid` is alive and runs exactly `executable`.
    private static func companionProcessMatches(_ pid: Int32, _ executable: String) -> Bool {
        // Only the external window agent is inspected. Fixtures can supply an identity matcher.
        guard kill(pid, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE (macro unavailable in Swift).
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer) == executable
    }
}
