import CRDSettingsCore
import AppKit
import SwiftUI

/// SwiftUI owns layout; this bridge only handles the settings window's first AppKit setup:
/// autosave name, centering, title and identifier, and hiding it at launch when not wanted.
struct MainWindowReader: NSViewRepresentable {
    private static var explicitPresentationRequested = false
    static func markExplicitPresentation() { explicitPresentationRequested = true }
    let center: Bool
    let showAtLaunch: Bool
    func makeNSView(context: Context) -> WindowView { WindowView(center: center, showAtLaunch: showAtLaunch) }
    func updateNSView(_ nsView: WindowView, context: Context) {}
    final class WindowView: NSView {
        let centerOnFirstAttach: Bool
        private static var launched = false
        private let showAtLaunch: Bool
        private var configured = false
        init(center: Bool, showAtLaunch: Bool) { centerOnFirstAttach = center; self.showAtLaunch = showAtLaunch; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Snapshot rendering owns its offscreen window; never move, autosave or hide it.
            guard !configured, !AppRuntime.renderingSnapshots, let window else { return }
            configured = true
            window.setFrameAutosaveName("CRDWindowStudioSettings")
            if centerOnFirstAttach { window.center() }
            window.title = L10n.text("설정 창")
            window.identifier = NSUserInterfaceItemIdentifier("CRDWindowStudioSettings")
            if !Self.launched {
                Self.launched = true
                if !showAtLaunch {
                    DispatchQueue.main.async { [weak window] in
                        // A native menu/Dock reopen may arrive after this hide
                        // was queued but before it runs. Explicit requests win.
                        guard !MainWindowReader.explicitPresentationRequested else { return }
                        window?.orderOut(nil)
                    }
                }
            }
        }
    }
}
