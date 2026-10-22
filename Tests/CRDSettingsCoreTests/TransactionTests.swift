import XCTest
@testable import CRDSettingsCore

/// Host inspection, concurrent configuration updates and bounded command runs.
final class TransactionTests: XCTestCase {
    func testInspectionKeepsInstallReceiptSeparateFromOverriddenConfiguration() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let support = folder.appendingPathComponent("install support")
        let custom = folder.appendingPathComponent("custom config")
        let host = folder.appendingPathComponent("Fixture Host.app")
        let helper = support.appendingPathComponent("Fixture Helper.app")
        let executable = helper.appendingPathComponent("Contents/MacOS/CRDWindowAgent")
        for directory in [support, custom, host.appendingPathComponent("Contents"), executable.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Synthetic process identity; no host, AX, launchd, process or TCC access.
        let matches: (Int32, String) -> Bool = { pid, path in pid == 42 && path == executable.path }
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "fixture-version"], format: .xml, options: 0)
        try info.write(to: host.appendingPathComponent("Contents/Info.plist"))
        let receipt: [String: Any] = ["state": "active", "originalHostPath": host.path,
                                      "companionPath": helper.path, "configPath": custom.appendingPathComponent("config.json").path]
        try JSONSerialization.data(withJSONObject: receipt).write(to: support.appendingPathComponent("companion-install.json"))
        let runtime: [String: Any] = ["pid": 42, "fixture": false, "backendKind": "accessibility-overlay",
                                      "agentReady": true, "observerReady": true, "lastEventTimestamp": 100, "originalWindowDetected": true]
        try JSONSerialization.data(withJSONObject: runtime).write(to: custom.appendingPathComponent("runtime-status.json"))
        try Data(#"{"agentReady":false}"#.utf8).write(to: support.appendingPathComponent("runtime-status.json"))
        let result = HostInspection.inspect(support: support, environment: ["CRD_WINDOW_CONFIG": custom.appendingPathComponent("config.json").path], processMatches: matches)
        XCTAssertTrue(result.patchInstalled)
        XCTAssertEqual(result.version, "fixture-version")
        XCTAssertTrue(result.running); XCTAssertTrue(result.windowObserved)
        // Without an environment override, the persisted selected folder still applies.
        XCTAssertTrue(HostInspection.inspect(support: support, environment: [:], processMatches: matches).running)
        // An explicit override wins over the recorded folder and does not read its status.
        let elsewhere = folder.appendingPathComponent("elsewhere/config.json")
        let missing = HostInspection.inspect(support: support, environment: ["CRD_WINDOW_CONFIG": elsewhere.path], processMatches: matches)
        XCTAssertTrue(missing.patchInstalled)
        XCTAssertFalse(missing.running); XCTAssertFalse(missing.windowObserved)
    }
    func testConcurrentPatchesPreserveBothFields() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = ConfigurationRepository(url: folder.appendingPathComponent("with spaces/config.json"), schema: try .load())
        try repository.save(repository.schema.defaults)
        let group = DispatchGroup()
        for field in ["width", "height"] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { for value in 100...150 { try repository.update([field: .number(Double(value))]) } }
                catch { XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try repository.load()["width"], .number(150))
        XCTAssertEqual(try repository.load()["height"], .number(150))
    }
    func testCommandOutputErrorsAndTimeoutAreBounded() throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        XCTAssertEqual(try BoundedProcess.run(executable: shell, arguments: ["-c", "printf fixture"], timeout: 2), Data("fixture".utf8))
        XCTAssertThrowsError(try BoundedProcess.run(executable: shell, arguments: ["-c", "printf failure >&2; exit 7"], timeout: 2)) {
            XCTAssertEqual(($0 as NSError).code, 7)
            XCTAssertEqual($0.localizedDescription, "failure")
            XCTAssertEqual(BoundedProcess.errorCode(for: $0), "command_failed")
        }
        XCTAssertThrowsError(try BoundedProcess.run(executable: shell, arguments: ["-c", #"printf '%s' '{"error":"accessibility_required","message":"fixture permission detail"}' >&2; exit 1"#], timeout: 2)) {
            XCTAssertEqual(BoundedProcess.errorCode(for: $0), "accessibility_required")
            XCTAssertEqual($0.localizedDescription, "fixture permission detail")
        }
        let start = Date()
        XCTAssertThrowsError(try BoundedProcess.run(executable: shell, arguments: ["-c", "exec /bin/sleep 20"], timeout: 0.1)) {
            XCTAssertEqual(BoundedProcess.errorCode(for: $0), "command_timeout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
