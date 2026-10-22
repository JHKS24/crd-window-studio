import Foundation
import Darwin

/// Reads and writes `config.json` under the lock the helper also takes.
/// The path comes from `CRD_WINDOW_CONFIG`, else the CRDWindowPatch folder in Application Support.
public struct ConfigurationRepository: Sendable {
    public let url: URL
    public let schema: SettingsSchema
    public init(url: URL? = nil, schema: SettingsSchema) {
        self.schema = schema
        self.url = url ?? ProcessInfo.processInfo.environment["CRD_WINDOW_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CRDWindowPatch/config.json")
    }
    private func read(allowMissing: Bool) throws -> [String: ConfigValue] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile where allowMissing { return schema.defaults }
        return try JSONDecoder().decode([String: ConfigValue].self, from: data)
    }
    /// Loads and validates the configuration; a missing file reads as the defaults when `allowMissing` is true.
    public func load(allowMissing: Bool = true) throws -> [String: ConfigValue] {
        try schema.validate(read(allowMissing: allowMissing))
    }
    /// Validates and writes a whole configuration.
    /// The existing file must load first, so a plain save never replaces an invalid file.
    public func save(_ input: [String: ConfigValue]) throws {
        let value = try schema.validate(input)
        try transaction {
            _ = try load() // An ordinary replacement cannot erase an invalid existing file.
            try write(value)
        }
    }
    /// Merge only the edited fields while holding the same lock as the native helper.
    @discardableResult
    public func update(_ changes: [String: ConfigValue], requireExisting: Bool = false) throws -> [String: ConfigValue] {
        try transaction {
            var latest = try load(allowMissing: !requireExisting)
            try schema.validateChanges(changes) // Validate the disk state before applying even a repairing edit.
            latest.merge(changes) { _, new in new }
            try write(latest)
            return latest
        }
    }
    /// Reset only a readable, valid configuration (or a genuinely new first run).
    public func resetToDefaults(requireExisting: Bool) throws -> URL? {
        try transaction {
            _ = try load(allowMissing: !requireExisting)
            let backup = try copyBackup()
            try write(schema.defaults)
            return backup
        }
    }
    /// Explicit recovery: preserve the exact existing bytes before replacing them.
    public func recreateWithBackup() throws -> URL {
        try transaction {
            _ = try Data(contentsOf: url) // A missing/unreadable file cannot be backed up safely.
            guard let backup = try copyBackup() else { throw CocoaError(.fileReadNoSuchFile) }
            try write(schema.defaults)
            return backup
        }
    }
    /// Runs `body` while holding the exclusive flock on `config.json.lock`, the lock the helper
    /// also takes. `presets.json` is written under the same lock.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    /// Writes the configuration atomically as sorted, pretty-printed JSON. Called under the lock.
    private func write(_ value: [String: ConfigValue]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
    /// Copies the current files to a backup under the lock; nil when there is no configuration file.
    public func backup() throws -> URL? {
        try transaction { try copyBackup() }
    }
    /// Copies `config.json` to a uniquely named backup. Called under the lock.
    /// `presets.json`, when present, is copied with the same identifier, so a backup holds the
    /// presets too; the live preset file stays as it is.
    private func copyBackup() throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let folder = url.deletingLastPathComponent(), identifier = UUID().uuidString
        let backup = folder.appendingPathComponent("config-backup-\(identifier).json")
        try FileManager.default.copyItem(at: url, to: backup)
        let presets = folder.appendingPathComponent("presets.json")
        if FileManager.default.fileExists(atPath: presets.path) {
            try FileManager.default.copyItem(at: presets, to: folder.appendingPathComponent("presets-backup-\(identifier).json"))
        }
        return backup
    }
}
