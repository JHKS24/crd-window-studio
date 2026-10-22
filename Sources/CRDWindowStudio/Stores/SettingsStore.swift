import AppKit
import Combine
import CRDSettingsCore

/// The settings app's model of `config.json`. Edits apply at once in memory and are written
/// shortly after, merged under the helper's lock. An invalid file blocks saving until it is recreated
/// with a backup. It also watches the file and the screens and inspects the host on request.
@MainActor
final class SettingsStore: ObservableObject {
    /// Why the configuration could not be read.
    enum LoadError: Equatable {
        case missing
        case invalid(String)
    }
    let schema: SettingsSchema
    let repository: ConfigurationRepository
    /// presets.json beside config.json, read when its section first appears.
    let presets: PresetStore
    @Published private(set) var values: [String: ConfigValue]
    @Published var errorMessage: String?
    @Published private(set) var loadError: LoadError?
    @Published private(set) var lastBackupURL: URL?
    @Published private(set) var savedAt: Date?
    @Published private(set) var screens: [NSScreen] = NSScreen.screens
    @Published private(set) var host = HostInspection.unchecked
    /// False until the first host inspection finishes, so an unchecked
    /// host is never shown as a missing Chrome Remote Desktop.
    @Published private(set) var hostChecked = false
    private var inspectingHost = false
    /// Edits still in a text field, committed before the app quits.
    private var draftCommits: [String: () -> Void] = [:]
    private var watcher: ConfigurationWatcher?
    private var screenObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var pendingSave: DispatchWorkItem?
    private var pendingChanges: [String: ConfigValue] = [:]
    private var hasReadFile = false
    private let inspectHost: @Sendable () -> HostInspection
    /// The last automatic hide delay, kept while "until I hide it" is selected.
    private let shrinkMemory: UserDefaults?
    private var rememberedShrink: Double?

    /// `inspectHost` lets snapshot fixtures supply host facts without reading the real support folder.
    /// `shrinkMemory` keeps the last automatic shrink delay across launches; nil keeps it for this session only.
    init(repository supplied: ConfigurationRepository? = nil,
         inspectHost: @escaping @Sendable () -> HostInspection = { HostInspection.inspect() },
         shrinkMemory: UserDefaults? = nil) {
        self.inspectHost = inspectHost
        self.shrinkMemory = shrinkMemory
        do {
            let schema = try supplied?.schema ?? SettingsSchema.load()
            self.schema = schema
            let repository = supplied ?? ConfigurationRepository(schema: schema)
            self.repository = repository
            presets = PresetStore(repository: PresetRepository(configuration: repository))
            do { values = try repository.load(); hasReadFile = FileManager.default.fileExists(atPath: repository.url.path) }
            catch {
                values = schema.defaults
                loadError = Self.loadFailure(error)
                errorMessage = error.localizedDescription
            }
            rememberShrink(from: values)
            watcher = ConfigurationWatcher(file: repository.url) { [weak self] in
                Task { @MainActor [weak self] in self?.reload() }
            }
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.screens = NSScreen.screens }
            }
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.commitDraftsAndFlush() }
            }
        } catch {
            // The schema is a required bundled app resource; a broken bundle cannot safely write settings.
            fatalError(L10n.format("기본 설정을 읽지 못했습니다(%@). 앱을 다시 설치하세요.", error.localizedDescription))
        }
    }

    // MARK: - Reading and editing values
    func string(_ key: String) -> String { values[key]?.string ?? "" }
    func number(_ key: String) -> Double { values[key]?.number ?? 0 }
    func bool(_ key: String) -> Bool { values[key]?.bool ?? false }
    func set(_ key: String, _ value: ConfigValue) { update([key: value]) }
    /// True when the file exists but is invalid; only an explicit recreate with backup can replace it.
    var requiresRecreation: Bool {
        if case .invalid = loadError { return true }
        return false
    }
    var canSave: Bool { loadError == nil }
    private static func loadFailure(_ error: Error) -> LoadError {
        if (error as? CocoaError)?.code == .fileReadNoSuchFile { return .missing }
        return .invalid(error.localizedDescription)
    }
    /// Validates and applies `changes` in memory, then schedules one merged write about 120 ms later.
    func update(_ changes: [String: ConfigValue]) {
        guard !requiresRecreation else { return }
        var next = values
        next.merge(changes) { _, new in new }
        guard next != values else { return }
        do { try schema.validateChanges(changes) }
        catch { errorMessage = error.localizedDescription; return }
        values = next
        rememberShrink(from: changes)
        pendingChanges.merge(changes) { _, new in new }
        scheduleSave()
    }
    /// Writes the pending changes about 120 ms from now, in place of a write already scheduled.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
    }
    /// Writes the pending changes now, merged into the file under the lock.
    /// On failure it reloads the file and shows the error.
    func flush() {
        pendingSave?.cancel(); pendingSave = nil
        guard canSave, !pendingChanges.isEmpty else { return }
        do {
            values = try repository.update(pendingChanges, requireExisting: hasReadFile)
            pendingChanges.removeAll()
            hasReadFile = true
            savedAt = Date()
        } catch { reload(); errorMessage = error.localizedDescription }
    }
    /// Applies a built-in shape's values and records the shape id.
    func chooseShape(_ id: String) {
        guard let preset = schema.shapes.first(where: { $0.id == id }) else { return }
        var changes = preset.values
        changes["shape"] = .string(id)
        update(changes)
    }
    /// Reads the file again, keeping any unsaved changes on top. A failed read stops pending saves
    /// and reports the error; an invalid file is never reloaded over, since recovery is explicit.
    /// When a missing file is back, the changes kept while it was gone are saved again.
    func reload() {
        guard !requiresRecreation else { return } // Recovery is an explicit, backed-up operation.
        let returning = loadError == .missing
        do {
            var next = try repository.load(allowMissing: !hasReadFile && loadError == nil)
            hasReadFile = hasReadFile || FileManager.default.fileExists(atPath: repository.url.path)
            if loadError != nil { errorMessage = nil }
            loadError = nil
            next.merge(pendingChanges) { _, new in new }
            if next != values { values = next; savedAt = Date(); rememberShrink(from: next) }
            if returning && !pendingChanges.isEmpty { scheduleSave() }
        } catch {
            pendingSave?.cancel(); pendingSave = nil
            loadError = Self.loadFailure(error)
            errorMessage = error.localizedDescription
        }
    }
    // MARK: - The display
    /// The display the helper places its window on: the saved one, or the first display when the saved
    /// one is not connected (the helper's `screens.firstObject`). Nil only when no display is reported.
    var selectedScreen: NSScreen? {
        screens.isEmpty ? nil : screens[Self.screenIndex(Int(number("screen")), count: screens.count)]
    }
    /// The requested display index, or 0 (the first display) when that display is not connected.
    nonisolated static func screenIndex(_ requested: Int, count: Int) -> Int {
        (0..<count).contains(requested) ? requested : 0
    }
    // MARK: - Hiding the Stop Sharing button that a double-click shows
    var shrinksAutomatically: Bool { ShrinkSetting.isAutomatic(values[ShrinkSetting.key]) }
    /// The seconds the automatic way uses: the current, the last remembered, or 5.
    var automaticShrinkSeconds: Double {
        ShrinkSetting.seconds(current: values[ShrinkSetting.key], remembered: rememberedShrink ?? shrinkMemory?.object(forKey: ShrinkSetting.memoryKey) as? Double)
    }
    /// Switches between the automatic delay and "until I hide it".
    func setShrinksAutomatically(_ automatic: Bool) {
        update([ShrinkSetting.key: .number(automatic ? automaticShrinkSeconds : ShrinkSetting.manualValue)])
    }
    /// Remembers an automatic delay in memory and in `shrinkMemory`.
    private func rememberShrink(from changes: [String: ConfigValue]) {
        guard let seconds = ShrinkSetting.automaticSeconds(changes[ShrinkSetting.key]) else { return }
        rememberedShrink = seconds
        shrinkMemory?.set(seconds, forKey: ShrinkSetting.memoryKey)
    }
    // MARK: - Host inspection and drafts
    /// Inspects the host off the main thread; ignored while an inspection is running.
    func refreshHost() {
        guard !inspectingHost else { return }
        inspectingHost = true
        Task {
            let inspect = inspectHost
            host = await Task.detached { inspect() }.value
            hostChecked = true
            inspectingHost = false
        }
    }
    /// A field with an uncommitted edit registers how to commit it; the closure
    /// keeps the field's own validation, so invalid text is not saved.
    func stageDraft(_ id: String, commit: @escaping () -> Void) { draftCommits[id] = commit }
    func clearDraft(_ id: String) { draftCommits[id] = nil }
    /// The termination contract: commit valid drafts, then write pending changes.
    func commitDraftsAndFlush() {
        let commits = draftCommits
        draftCommits.removeAll()
        for commit in commits.values { commit() }
        flush()
    }
    // MARK: - Reset and recovery
    /// Backs up and resets a valid configuration to the defaults.
    func restoreDefaults() {
        guard canSave else { return }
        do {
            lastBackupURL = try repository.resetToDefaults(requireExisting: hasReadFile)
            didReset()
        } catch { reload(); errorMessage = error.localizedDescription }
    }
    /// Backs up an invalid file's exact bytes and replaces it with the defaults.
    func recreateWithBackup() {
        guard requiresRecreation else { return }
        do {
            lastBackupURL = try repository.recreateWithBackup()
            didReset()
        } catch { errorMessage = error.localizedDescription }
    }
    private func didReset() {
        pendingSave?.cancel(); pendingSave = nil; pendingChanges.removeAll()
        hasReadFile = true
        loadError = nil; errorMessage = nil
        values = schema.defaults
        savedAt = Date()
    }
    deinit {
        pendingSave?.cancel()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }
    /// The appearance chosen in settings, or nil to follow the system.
    var preferredScheme: NSAppearance.Name? {
        switch string("appearance") { case "light": return .aqua; case "dark": return .darkAqua; default: return nil }
    }
}
