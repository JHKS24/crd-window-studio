import Foundation
import Darwin

/// Runs a short external command with a time limit. Call it off the main thread.
/// Output goes to private temporary files instead of pipes, so a verbose failure cannot
/// fill a pipe buffer and deadlock.
public enum BoundedProcess {
    public static let errorCodeKey = "CRDCompanionErrorCode"
    /// The machine-readable error code a failed run attached to `error`, if any.
    public static func errorCode(for error: Error) -> String? {
        (error as NSError).userInfo[errorCodeKey] as? String
    }
    /// Runs `executable` and returns its standard output.
    /// Throws `command_timeout` after `timeout` seconds (the command is terminated, then killed),
    /// and on a nonzero exit throws with the command's JSON `error` code and `message` when it printed them.
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                           environment: [String: String]? = nil) throws -> Data {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("CRDCommand-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        for file in [stdout, stderr] {
            guard files.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let output = try FileHandle(forWritingTo: stdout), errors = try FileHandle(forWritingTo: stderr)
        defer { try? output.close(); try? errors.close() }
        let process = Process(), done = DispatchSemaphore(value: 0)
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate() // Only the command we launched, never the host or helper.
            if done.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
            }
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                          userInfo: [errorCodeKey: "command_timeout"])
        }
        guard process.terminationStatus == 0 else {
            let data = (try? Data(contentsOf: stderr)) ?? Data()
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = (payload?["message"] as? String ?? String(data: data, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "CRDCompanionService", code: Int(process.terminationStatus),
                          userInfo: [errorCodeKey: payload?["error"] as? String ?? "command_failed",
                                     NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : L10n.text("창 도우미 작업을 완료하지 못했습니다. 잠시 후 다시 시도하세요.")])
        }
        return try Data(contentsOf: stdout)
    }
}
