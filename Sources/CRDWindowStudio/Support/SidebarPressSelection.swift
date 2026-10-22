import AppKit
import SwiftUI

// MARK: - Sidebar press selection

/// Switches the settings page while a sidebar row is still pressed. During mouse tracking the
/// sidebar's outline view selects the row under the pointer and posts its "selection is
/// changing" notification; SwiftUI commits that selection only on mouse-up. Following the
/// notification shows the page at the press, and a drag to another row follows the row under
/// the pointer. The release then commits the same page. Arrow keys, VoiceOver and the page
/// shortcuts keep their own paths.
@MainActor
final class SidebarPressSelection: ObservableObject {
    private weak var table: NSTableView?
    private weak var navigation: SettingsNavigation?
    private var observer: NSObjectProtocol?

    /// Observes `table`, the sidebar's own table, once. A table with a different row count is
    /// not the sidebar and is ignored.
    func attach(to table: NSTableView, navigation: SettingsNavigation) {
        self.navigation = navigation
        guard table !== self.table, table.numberOfRows == SettingsPage.allCases.count else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.table = table
        let name = table is NSOutlineView ? NSOutlineView.selectionIsChangingNotification : NSTableView.selectionIsChangingNotification
        observer = NotificationCenter.default.addObserver(forName: name, object: table, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionIsChanging() }
        }
    }

    /// Shows the page of the row the table selected during the press, when it differs from the current page.
    private func selectionIsChanging() {
        guard let table, let navigation, SettingsPage.allCases.indices.contains(table.selectedRow) else { return }
        let page = SettingsPage.allCases[table.selectedRow]
        if navigation.page != page { navigation.page = page }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// A zero-size view placed behind a sidebar row. When the row joins a window, it finds the
/// table that hosts it and hands it to `SidebarPressSelection`. It takes no clicks, focus or
/// accessibility role.
struct SidebarPressTracker: NSViewRepresentable {
    let selection: SidebarPressSelection
    let navigation: SettingsNavigation
    func makeNSView(context: Context) -> TrackerView { TrackerView(selection: selection, navigation: navigation) }
    func updateNSView(_ nsView: TrackerView, context: Context) {}

    final class TrackerView: NSView {
        private let selection: SidebarPressSelection
        private let navigation: SettingsNavigation
        init(selection: SidebarPressSelection, navigation: SettingsNavigation) {
            self.selection = selection; self.navigation = navigation
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is NSTableView) { ancestor = view.superview }
            if let table = ancestor as? NSTableView { selection.attach(to: table, navigation: navigation) }
        }
    }
}
