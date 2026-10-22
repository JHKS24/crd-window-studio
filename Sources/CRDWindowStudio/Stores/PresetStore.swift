import Foundation
import CRDSettingsCore

/// The settings app's side of presets. Every change is one locked write of
/// `presets.json`; applying is one write of `config.json` that never touches mode or enabled.
@MainActor
final class PresetStore: ObservableObject {
    let repository: PresetRepository
    @Published private(set) var presets: [Preset] = []
    /// A one-time note (for example an unreadable file that was moved aside) or the last error.
    @Published var notice: String?
    @Published private(set) var loaded = false

    init(repository: PresetRepository) { self.repository = repository }

    var canSaveMore: Bool { presets.count < PresetRepository.countLimit }
    func isCurrent(_ preset: Preset, in store: SettingsStore) -> Bool { PresetRepository.matches(preset, store.values) }

    /// Reads the preset list again and reports a file that had to be set aside.
    func reload() {
        do { presets = try report(repository.load()).presets }
        catch { notice = error.localizedDescription }
        loaded = true
    }
    /// Shows the one notice for a file the repository had to set aside, whichever call found it.
    private func report(_ loaded: PresetRepository.Loaded) -> PresetRepository.Loaded {
        report(movedAside: loaded.movedAside, partial: loaded.partial)
        return loaded
    }
    private func report(movedAside: URL?, partial: Bool) {
        guard movedAside != nil else { return }
        notice = partial ? L10n.text("프리셋 파일의 일부를 읽을 수 없어 기존 파일을 따로 보관하고, 정상적인 프리셋만 불러왔습니다.")
            : L10n.text("프리셋 파일을 읽을 수 없어 기존 파일을 따로 보관했습니다. 필요한 프리셋을 다시 저장하세요.")
    }
    /// Saves the current window. Returns false (with `notice` set) when the name or limit is not accepted.
    @discardableResult
    func saveCurrent(name: String, from store: SettingsStore) -> Bool {
        perform { store.commitDraftsAndFlush(); let change = try repository.save(name: name, values: store.values); return (change.movedAside, change.partial) }
    }
    /// Renames a preset. Returns false with `notice` set when the name is not accepted.
    @discardableResult
    func rename(_ preset: Preset, to name: String) -> Bool {
        perform { let change = try repository.rename(id: preset.id, to: name); return (change.movedAside, change.partial) }
    }
    /// Replaces a preset's values with the current window, after committing text-field drafts.
    @discardableResult
    func overwrite(_ preset: Preset, from store: SettingsStore) -> Bool {
        perform { store.commitDraftsAndFlush(); let change = try repository.overwrite(id: preset.id, values: store.values); return (change.movedAside, change.partial) }
    }
    /// Deletes a preset.
    @discardableResult
    func delete(_ preset: Preset) -> Bool {
        perform { let change = try repository.delete(id: preset.id); return (change.movedAside, change.partial) }
    }
    /// One validated write: the preset's values merged into the configuration, saved at once.
    /// The position is made reachable on the display it will use before that write.
    @discardableResult
    func apply(_ preset: Preset, to store: SettingsStore) -> Bool {
        guard store.canSave else { return false }
        do {
            let loaded = report(try repository.load())
            presets = loaded.presets
            guard let current = loaded.presets.first(where: { $0.id == preset.id }) else { throw PresetError.notFound }
            var changes = try repository.validatedValues(current.values)
            let merged = store.values.merging(changes) { $1 }
            changes.merge(PresetRepository.reachablePlacement(merged, visibleFrames: store.screens.map(\.visibleFrame))) { $1 }
            store.update(changes)
            store.flush()
            return true
        } catch {
            notice = error.localizedDescription
            reload()
            return false
        }
    }
    /// Runs one repository change, then reloads the list and reports any recovery or error.
    private func perform(_ body: () throws -> (URL?, Bool)) -> Bool {
        do {
            let (movedAside, partial) = try body()
            reload(); report(movedAside: movedAside, partial: partial)
            return true
        } catch { notice = error.localizedDescription; reload(); return false }
    }
}
