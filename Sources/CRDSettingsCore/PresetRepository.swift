import Foundation

/// A saved look and position of the custom window.
public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var values: [String: ConfigValue]
    public init(id: String, name: String, values: [String: ConfigValue]) {
        self.id = id; self.name = name; self.values = values
    }
}

/// A preset operation failure with a localized message.
public enum PresetError: LocalizedError, Equatable {
    case invalidName, duplicateName, limitReached, notFound, invalidValues
    public var errorDescription: String? {
        switch self {
        case .invalidName: return L10n.format("프리셋 이름은 1~%@자로 입력하세요.", PresetRepository.nameLimit)
        case .duplicateName: return L10n.text("같은 이름의 프리셋이 이미 있습니다. 다른 이름을 입력하세요.")
        case .limitReached: return L10n.format("프리셋은 %@개까지 저장할 수 있습니다. 쓰지 않는 프리셋을 삭제하세요.", PresetRepository.countLimit)
        case .notFound: return L10n.text("프리셋을 찾을 수 없습니다. 목록을 다시 확인하세요.")
        case .invalidValues: return L10n.text("프리셋 설정이 올바르지 않아 적용하지 못했습니다. 프리셋을 다시 저장하세요.")
        }
    }
}

/// `presets.json` next to `config.json`, written atomically under the same `config.json.lock`.
/// A missing file is an empty list. A file that cannot be read is moved aside (like config
/// backups) and reported, and never blocks the configuration or the helper.
public struct PresetRepository: Sendable {
    public static let nameLimit = 40
    public static let countLimit = 20
    public static let fileSchema = 1
    /// A preset never holds these: the file version, the switch, the display mode and logging.
    public static let excludedKeys: Set<String> = ["schema", "enabled", "mode", "loggingEnabled"]

    /// The presets read from disk and any recovery the read made.
    public struct Loaded: Equatable, Sendable {
        public let presets: [Preset]
        /// Where the original bytes of an unreadable or partly unreadable file were kept, so the app can say so once.
        public let movedAside: URL?
        /// True when the readable presets were kept and only a copy of the original bytes was set aside.
        public let partial: Bool
        public init(presets: [Preset], movedAside: URL?, partial: Bool = false) {
            self.presets = presets; self.movedAside = movedAside; self.partial = partial
        }
    }
    /// A change's result plus any recovery the same locked read had to make.
    public struct Change<Value> {
        public let value: Value
        public let movedAside: URL?
        public let partial: Bool
    }

    public let configuration: ConfigurationRepository
    public init(configuration: ConfigurationRepository) { self.configuration = configuration }
    public var url: URL { configuration.url.deletingLastPathComponent().appendingPathComponent("presets.json") }
    private var schema: SettingsSchema { configuration.schema }

    /// Every settings key a preset stores: the look, the position, the locks and auto-shrink.
    public var storedKeys: [String] { schema.defaults.keys.filter { !Self.excludedKeys.contains($0) }.sorted() }

    /// Trims a preset name and checks it is 1 to `nameLimit` characters long.
    public static func normalizedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...nameLimit).contains(name.count) else { throw PresetError.invalidName }
        return name
    }
    /// The current window as preset values (excluded keys removed).
    public func values(from configuration: [String: ConfigValue]) -> [String: ConfigValue] {
        configuration.filter { schema.defaults[$0.key] != nil && !Self.excludedKeys.contains($0.key) }
    }
    /// Unknown and excluded keys are dropped; any invalid kept value rejects the preset.
    public func validatedValues(_ raw: [String: ConfigValue]) throws -> [String: ConfigValue] {
        let kept = values(from: raw)
        guard !kept.isEmpty else { throw PresetError.invalidValues }
        do { try schema.validateChanges(kept) } catch { throw PresetError.invalidValues }
        return kept
    }
    /// True when every value of a non-empty preset equals the configuration's value.
    public static func matches(_ preset: Preset, _ configuration: [String: ConfigValue]) -> Bool {
        !preset.values.isEmpty && preset.values.allSatisfy { configuration[$0.key] == $0.value }
    }

    /// Loads the presets under the configuration lock, recovering an unreadable file.
    public func load() throws -> Loaded { try configuration.transaction { try readLocked() } }
    /// Adds a new preset with a unique name, up to `countLimit` presets.
    @discardableResult
    public func save(name: String, values raw: [String: ConfigValue]) throws -> Change<Preset> {
        let name = try Self.normalizedName(name), values = try validatedValues(raw)
        return try mutate { presets in
            guard presets.count < Self.countLimit else { throw PresetError.limitReached }
            guard !presets.contains(where: { $0.name == name }) else { throw PresetError.duplicateName }
            let preset = Preset(id: UUID().uuidString, name: name, values: values)
            presets.append(preset)
            return preset
        }
    }
    /// Renames a preset; the new name must be unique.
    @discardableResult
    public func rename(id: String, to raw: String) throws -> Change<Void> {
        let name = try Self.normalizedName(raw)
        return try mutate { presets in
            guard let index = presets.firstIndex(where: { $0.id == id }) else { throw PresetError.notFound }
            guard !presets.contains(where: { $0.name == name && $0.id != id }) else { throw PresetError.duplicateName }
            presets[index].name = name
        }
    }
    /// Replaces a preset's values with validated `raw` values.
    @discardableResult
    public func overwrite(id: String, values raw: [String: ConfigValue]) throws -> Change<Void> {
        let values = try validatedValues(raw)
        return try mutate { presets in
            guard let index = presets.firstIndex(where: { $0.id == id }) else { throw PresetError.notFound }
            presets[index].values = values
        }
    }
    /// Removes a preset.
    @discardableResult
    public func delete(id: String) throws -> Change<Void> {
        return try mutate { presets in
            guard let index = presets.firstIndex(where: { $0.id == id }) else { throw PresetError.notFound }
            presets.remove(at: index)
        }
    }
    /// The validated values to merge into the configuration; mode and enabled are never among them.
    public func values(forPreset id: String) throws -> [String: ConfigValue] {
        guard let preset = try load().presets.first(where: { $0.id == id }) else { throw PresetError.notFound }
        return try validatedValues(preset.values)
    }

    /// Reads, changes and writes the presets in one locked transaction.
    private func mutate<T>(_ change: (inout [Preset]) throws -> T) throws -> Change<T> {
        try configuration.transaction {
            let loaded = try readLocked()
            var presets = loaded.presets
            let result = try change(&presets)
            try write(presets)
            return Change(value: result, movedAside: loaded.movedAside, partial: loaded.partial)
        }
    }
    /// Reads the presets. Called under the lock. An unreadable file is moved aside whole. A partly unreadable file
    /// (skipped entries or dropped keys) keeps its exact bytes in the same kind of copy before the
    /// readable presets are written back, so nothing is lost silently and it is reported once.
    private func readLocked() throws -> Loaded {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return Loaded(presets: [], movedAside: nil) }
        let aside = url.deletingLastPathComponent().appendingPathComponent("presets-corrupt-\(UUID().uuidString).json")
        guard let parsed = Self.parse(data, using: self) else {
            try FileManager.default.moveItem(at: url, to: aside)
            return Loaded(presets: [], movedAside: aside)
        }
        guard parsed.dropped else { return Loaded(presets: parsed.presets, movedAside: nil) }
        try data.write(to: aside, options: .withoutOverwriting)
        try write(parsed.presets)
        return Loaded(presets: parsed.presets, movedAside: aside, partial: true)
    }
    /// nil means the file itself is unreadable. Entries with a bad id, name or value are skipped,
    /// as the helper skips them, and at most `countLimit` entries are kept; `dropped` says whether
    /// anything (an entry, or an unknown or excluded key) was left out.
    static func parse(_ data: Data, using repository: PresetRepository) -> (presets: [Preset], dropped: Bool)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["schema"] as? NSNumber, !Self.isBoolean(version), version.intValue == fileSchema,
              version.doubleValue == Double(fileSchema), let entries = root["presets"] as? [Any] else { return nil }
        var presets: [Preset] = []
        var dropped = false
        for item in entries {
            guard presets.count < countLimit, let entry = item as? [String: Any],
                  let id = entry["id"] as? String, !id.isEmpty, let rawName = entry["name"] as? String,
                  let name = try? normalizedName(rawName), let rawValues = entry["values"] as? [String: Any],
                  !presets.contains(where: { $0.id == id }) else { dropped = true; continue }
            var values: [String: ConfigValue] = [:]
            var valid = true
            for (key, value) in rawValues {
                guard let converted = configValue(value) else {
                    if repository.schema.defaults[key] != nil && !excludedKeys.contains(key) { valid = false }
                    dropped = true
                    continue
                }
                values[key] = converted
            }
            guard valid, let checked = try? repository.validatedValues(values) else { dropped = true; continue }
            if checked.count != rawValues.count { dropped = true }
            presets.append(Preset(id: id, name: name, values: checked))
        }
        return (presets, dropped)
    }
    /// The placement changes that keep a preset reachable on the display it will use, even with
    /// constrainToScreen off: a valid screen (else 0), and a custom position clamped inside that
    /// screen's visible frame when the placement would put it outside. The same rule as the helper.
    public static func reachablePlacement(_ values: [String: ConfigValue], visibleFrames: [CGRect]) -> [String: ConfigValue] {
        guard !visibleFrames.isEmpty else { return [:] }
        let requested = Int(values["screen"]?.number ?? 0)
        let valid = visibleFrames.indices.contains(requested)
        let visible = visibleFrames[valid ? requested : 0].size
        let width = values["width"]?.number ?? 0, height = values["height"]?.number ?? 0, inset = values["edgeInset"]?.number ?? 0
        var x = (visible.width - width) / 2, y = (visible.height - height) / 2
        switch values["placement"]?.string {
        case "top": y = inset
        case "bottom": y = visible.height - inset - height
        case "custom": x = values["x"]?.number ?? 0; y = values["y"]?.number ?? 0
        default: break
        }
        let cx = max(0, min(x, visible.width - width)), cy = max(0, min(y, visible.height - height))
        var changes: [String: ConfigValue] = [:]
        if !valid { changes["screen"] = .number(0) }
        if abs(cx - x) > 0.01 || abs(cy - y) > 0.01 {
            changes["placement"] = .string("custom"); changes["x"] = .number(cx); changes["y"] = .number(cy)
        }
        return changes
    }
    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
    /// Converts a JSON value to a configuration value; nil for anything but a string, number or Boolean.
    private static func configValue(_ value: Any) -> ConfigValue? {
        if let string = value as? String { return .string(string) }
        guard let number = value as? NSNumber else { return nil }
        return isBoolean(number) ? .bool(number.boolValue) : .number(number.doubleValue)
    }
    /// Writes the preset file atomically. Called under the lock.
    private func write(_ presets: [Preset]) throws {
        struct File: Encodable { let schema: Int; let presets: [Preset] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(schema: Self.fileSchema, presets: presets)).write(to: url, options: .atomic)
    }
}
