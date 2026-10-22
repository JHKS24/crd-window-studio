import CRDSettingsCore
import Foundation

/// The command line developer tools that the controller's `/usr/bin/python3` comes from. Without
/// them that path is a stub that opens Apple's install prompt and fails, so the app checks first and
/// starts no controller command until the check passes.
enum DeveloperTools {
    /// The error code of a controller command that did not start because the tools are missing.
    static let missingCode = "developer_tools_missing"
    static let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")
    /// True when `xcode-select -p` names a developer folder (the Command Line Tools or Xcode's)
    /// whose `usr/bin/python3` is executable. Neither step can open the install prompt.
    /// Call it off the main thread; `xcodeSelect` lets tests use a fake.
    static func pythonInstalled(xcodeSelect: URL = DeveloperTools.xcodeSelect) -> Bool {
        guard let output = try? BoundedProcess.run(executable: xcodeSelect, arguments: ["-p"], timeout: 10),
              let folder = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              folder.hasPrefix("/") else { return false }
        return FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: folder).appendingPathComponent("usr/bin/python3").path)
    }
    /// Asks `xcode-select --install` to open Apple's installer, where the user confirms.
    /// `run` starts the command off the main thread; tests replace it.
    static func requestInstall(run: (URL, [String]) -> Void = { executable, arguments in
        Task.detached { _ = try? BoundedProcess.run(executable: executable, arguments: arguments, timeout: 30) }
    }) {
        run(xcodeSelect, ["--install"])
    }
}
