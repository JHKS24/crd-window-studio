import AppKit
import Combine
import XCTest
@testable import CRDWindowStudio

/// The sidebar shows a page while its row is still pressed: the "selection is changing"
/// notification of the sidebar's own outline view sets the page, and nothing else does.
final class SidebarPressSelectionTests: XCTestCase {
    /// A flat outline view with `count` rows, standing in for the sidebar list.
    private final class Rows: NSObject, NSOutlineViewDataSource {
        let count: Int
        init(_ count: Int) { self.count = count }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { item == nil ? count : 0 }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { index as NSNumber }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    }
    @MainActor private func outline(_ rows: Rows) -> NSOutlineView {
        let view = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.addTableColumn(NSTableColumn(identifier: .init("page")))
        view.dataSource = rows
        view.reloadData()
        return view
    }
    @MainActor private func pressRow(_ row: Int, in view: NSOutlineView) {
        view.selectRowIndexes([row], byExtendingSelection: false)
        NotificationCenter.default.post(name: NSOutlineView.selectionIsChangingNotification, object: view)
    }

    @MainActor func testPressedRowShowsItsPageAndSameRowChangesNothing() {
        let rows = Rows(SettingsPage.allCases.count), view = outline(rows)
        let navigation = SettingsNavigation(), selection = SidebarPressSelection()
        selection.attach(to: view, navigation: navigation)
        var published: [SettingsPage] = []
        let observer = navigation.$page.dropFirst().sink { published.append($0) }
        defer { observer.cancel() }
        pressRow(2, in: view)
        XCTAssertEqual(navigation.page, .appearance)
        pressRow(3, in: view)
        XCTAssertEqual(navigation.page, .helper)
        pressRow(3, in: view)
        XCTAssertEqual(published, [.appearance, .helper], "pressing the row of the current page publishes nothing")
    }

    @MainActor func testOtherTablesAndOtherNotificationsAreIgnored() {
        let navigation = SettingsNavigation(), selection = SidebarPressSelection()
        let other = Rows(3), otherView = outline(other)
        selection.attach(to: otherView, navigation: navigation)
        pressRow(2, in: otherView)
        XCTAssertEqual(navigation.page, .display, "a table with another row count is not the sidebar")

        let rows = Rows(SettingsPage.allCases.count), view = outline(rows)
        selection.attach(to: view, navigation: navigation)
        view.selectRowIndexes([1], byExtendingSelection: false)
        NotificationCenter.default.post(name: NSOutlineView.selectionDidChangeNotification, object: view)
        XCTAssertEqual(navigation.page, .display, "a committed selection stays with SwiftUI's own binding")
        NotificationCenter.default.post(name: NSOutlineView.selectionIsChangingNotification, object: otherView)
        XCTAssertEqual(navigation.page, .display)
        pressRow(1, in: view)
        XCTAssertEqual(navigation.page, .position)
    }
}
