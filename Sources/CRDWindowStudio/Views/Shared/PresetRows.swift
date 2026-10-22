import SwiftUI
import CRDSettingsCore

/// Saved looks and positions, right below the built-in window shapes: apply, save, rename,
/// overwrite and delete, with the naming alert, the delete confirmation and the one-time notice.
struct PresetRows: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var presets: PresetStore
    @State private var naming: Naming?
    @State private var name = ""
    @State private var deleting: Preset?

    enum Naming: Equatable {
        case new
        case rename(Preset)
    }

    static var footer: String { L10n.text("프리셋에는 창 모양, 크기, 표시 항목, 색상, 위치와 잠금이 저장됩니다. 표시 방식과 공유 창 바꾸기는 바뀌지 않습니다.") }

    var body: some View {
        Group {
            if presets.presets.isEmpty {
                Text(L10n.text("저장된 프리셋 없음")).foregroundStyle(.secondary)
            }
            ForEach(presets.presets) { preset in
                PresetRow(preset: preset, current: presets.isCurrent(preset, in: store),
                          apply: { _ = presets.apply(preset, to: store) },
                          rename: { name = preset.name; naming = .rename(preset) },
                          overwrite: { _ = presets.overwrite(preset, from: store) },
                          delete: { deleting = preset })
            }
            // Card footer buttons sit on the trailing edge, as in the Checklist and Settings File sections.
            HStack {
                Spacer(minLength: 0)
                Button(L10n.text("현재 창을 프리셋으로 저장")) { name = ""; naming = .new }
                    .disabled(!presets.canSaveMore || !store.canSave)
            }
        }
        .onAppear { if !presets.loaded { presets.reload() } }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(L10n.text("프리셋 이름"), text: $name)
            Button(L10n.text("저장")) { commitName() }
            Button(L10n.text("취소"), role: .cancel) { naming = nil }
        } message: {
            Text(L10n.format("프리셋 이름은 1~%@자로 입력하세요.", PresetRepository.nameLimit))
        }
        .confirmationDialog(L10n.format("'%@' 프리셋을 삭제할까요?", deleting?.name ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { preset in
            Button(L10n.text("삭제"), role: .destructive) { _ = presets.delete(preset); deleting = nil }
            Button(L10n.text("취소"), role: .cancel) { deleting = nil }
        } message: { _ in
            Text(L10n.text("삭제한 프리셋은 되돌릴 수 없습니다."))
        }
        .alert(L10n.text("프리셋"), isPresented: Binding(get: { presets.notice != nil }, set: { if !$0 { presets.notice = nil } })) {
            Button(L10n.text("확인"), role: .cancel) { presets.notice = nil }
        } message: { Text(presets.notice ?? "") }
    }

    private var namingTitle: String {
        if case .rename = naming { return L10n.text("프리셋 이름 변경") }
        return L10n.text("프리셋 저장")
    }
    /// Saves a new preset or renames one with the name typed in the alert.
    private func commitName() {
        switch naming {
        case .new: presets.saveCurrent(name: name, from: store)
        case .rename(let preset): presets.rename(preset, to: name)
        case nil: break
        }
        naming = nil
    }
}

/// One preset: a check mark when it matches the current window, Apply, and a menu of the other actions.
private struct PresetRow: View {
    let preset: Preset
    let current: Bool
    let apply: () -> Void
    let rename: () -> Void
    let overwrite: () -> Void
    let delete: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").foregroundStyle(.tint).opacity(current ? 1 : 0).accessibilityHidden(true)
            Text(preset.name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            // The applied preset says so instead of showing a disabled Apply button.
            if current { Text(L10n.text("적용됨")).foregroundStyle(.secondary) }
            else { Button(L10n.text("적용"), action: apply) }
            Menu {
                Button(L10n.text("이름 변경"), action: rename)
                Button(L10n.text("현재 창으로 덮어쓰기"), action: overwrite)
                Divider()
                Button(L10n.text("삭제"), role: .destructive, action: delete)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L10n.format("프리셋 작업: %@", preset.name))
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(current ? L10n.text("적용됨") : "")
    }
}
