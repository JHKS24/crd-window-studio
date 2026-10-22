import AppKit
import Combine
import CRDSettingsCore
import SwiftUI

/// The preview's own record of a user press. A move or resize counts as the user's only
/// while a left press that started in this window is still held (a title-bar drag), or during a
/// live resize (an edge drag). Everything else (tiling, arrangement, display changes, code) is the system's.
final class PreviewWindow: NSWindow {
    private(set) var userPressActive = false
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { userPressActive = true }
        super.sendEvent(event)
        if event.type == .leftMouseUp { userPressActive = false }
    }
    /// The press ended outside normal dispatch (for example after a title-bar drag).
    func endUserPressIfReleased(buttonDown: Bool) { if !buttonDown { userPressActive = false } }
}

/// Shows the settings as a real-size window and saves the user's own moves and resizes back
/// to the configuration. The window follows every settings change.
@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    private var window: NSWindow?
    private var changes: AnyCancellable?
    private var applyingFrame = false
    private var synchronizedContent: CGRect?
    /// Geometry this window just reported. While the user is still
    /// dragging or resizing, it is not fed back as a frame change; rounding and
    /// screen containment are applied when the gesture ends.
    private var reportedContent: CGRect?
    private var correctionPending = false
    var gestureActive: (NSWindow) -> Bool = { $0.inLiveResize || NSEvent.pressedMouseButtons & 1 != 0 }
    init(store: SettingsStore) {
        self.store = store
        super.init()
        changes = Publishers.CombineLatest(store.$values, store.$screens).dropFirst().sink { [weak self] _ in
            // @Published emits before the new value is assigned.
            DispatchQueue.main.async { self?.synchronize() }
        }
    }
    /// Creates the preview window on first use, then brings it to the front.
    func show() {
        if window == nil {
            let window = PreviewWindow(contentRect: .init(x: 0, y: 0, width: store.number("width"), height: store.number("height")), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.text("공유 창 미리보기")
            window.isReleasedWhenClosed = false
            // The preview draws what the helper draws (HelperWindowPreview mirrors its Layout()).
            window.contentView = NSHostingView(rootView: HelperWindowPreview(store: store).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentMinSize = NSSize(width: 1, height: 1)
            // No full screen, zoom or tiling arrangement; only the user's own move and resize count.
            window.collectionBehavior.insert(.fullScreenNone)
            window.delegate = self
            window.setFrameAutosaveName("CRDSharingPreview")
            // Moving or resizing this window saves position and size at once; a note below the title bar says so.
            PreviewWindowNote.install(on: window)
            self.window = window
        }
        synchronize()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Applies the settings to the window: title, note, appearance, level, shadow, locks, and the frame
    /// computed the way the helper places its window. While the user's own gesture is still running,
    /// the frame is left alone and checked again 0.3 s later.
    private func synchronize() {
        guard let window else { return }
        if StudioMode.customInEffect(store) { window.title = L10n.text("공유 창 미리보기") }
        else { window.title = L10n.text("공유 창 미리보기(원격 연결 시 원래 공유 창)") }
        PreviewWindowNote.update(on: window, values: store.values)
        window.appearance = store.preferredScheme.flatMap(NSAppearance.init(named:))
        window.level = store.bool("alwaysOnTop") ? .floating : .normal
        window.hasShadow = store.bool("shadow")
        window.isMovable = store.bool("draggable")
        window.isMovableByWindowBackground = store.bool("draggable")
        if store.bool("resizable") { window.styleMask.insert(.resizable) }
        else { window.styleMask.remove(.resizable) }
        guard let screen = store.selectedScreen else { return }
        let visible = screen.visibleFrame
        let size = CGSize(width: store.number("width"), height: store.number("height"))
        var origin: CGPoint
        switch store.string("placement") {
        case "top": origin = CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - store.number("edgeInset"))
        case "bottom": origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + store.number("edgeInset"))
        case "custom": origin = CGPoint(x: visible.minX + store.number("x"), y: visible.maxY - store.number("y") - size.height)
        default: origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        if store.bool("constrainToScreen") {
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        let contentTarget = CGRect(origin: origin, size: size)
        let current = window.contentRect(forFrameRect: window.frame)
        guard Self.appliesFrame(reportedByWindow: reportedContent == current, gestureActive: gestureActive(window)) else {
            synchronizedContent = current
            if !correctionPending {
                correctionPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.correctionPending = false; self?.synchronize() }
            }
            return
        }
        reportedContent = nil
        synchronizedContent = contentTarget
        let target = window.frameRect(forContentRect: contentTarget)
        if window.frame != target {
            applyingFrame = true
            window.setFrame(target, display: true)
            applyingFrame = false
        }
    }
    /// External edits always apply; the window's own report waits for the gesture to end.
    nonisolated static func appliesFrame(reportedByWindow: Bool, gestureActive: Bool) -> Bool { !(reportedByWindow && gestureActive) }
    /// Only a move or resize made by the user's own gesture is saved: an edge drag
    /// (live resize) or a title-bar drag (a press that began in this window and is still held).
    /// Sizes are not evidence either way. System and programmatic changes are undone instead.
    nonisolated static func isUserGesture(liveResize: Bool, pressStartedInWindow: Bool, buttonDown: Bool) -> Bool {
        liveResize || (pressStartedInWindow && buttonDown)
    }
    // MARK: - Window delegate
    // Zoom is refused; the end of a resize and closing the window write pending changes.
    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool { false }
    func windowDidEndLiveResize(_ notification: Notification) { store.flush(); synchronize() }
    func windowWillClose(_ notification: Notification) { store.flush() }
    func windowDidResize(_ notification: Notification) { recordGeometry(resized: true) }
    func windowDidMove(_ notification: Notification) { recordGeometry(resized: false) }
    /// Saves the window's content frame as a custom position (and size after a resize) when the
    /// user's own gesture moved it; any other change is undone by restoring the stored frame.
    private func recordGeometry(resized: Bool) {
        guard !applyingFrame, let window, window.isVisible else { return }
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return }
        let index = store.screens.firstIndex(of: screen) ?? 0
        // The real overlay is borderless. The preview has a native title bar, so save
        // content bounds, measured from selected NSScreen.visibleFrame's top-left, in points.
        let content = window.contentRect(forFrameRect: window.frame)
        guard content != synchronizedContent else { return }
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0
        let pressed = (window as? PreviewWindow)?.userPressActive ?? false
        (window as? PreviewWindow)?.endUserPressIfReleased(buttonDown: buttonDown)
        guard Self.isUserGesture(liveResize: window.inLiveResize, pressStartedInWindow: pressed, buttonDown: buttonDown) else {
            // Tiling, arrangement, a display change or code moved it: never saved, the stored frame comes back.
            reportedContent = nil
            DispatchQueue.main.async { [weak self] in self?.synchronize() }
            return
        }
        var changes: [String: ConfigValue] = [
            "placement": .string("custom"), "screen": .number(Double(index)),
            "x": .number((content.minX - screen.visibleFrame.minX).rounded()),
            "y": .number((screen.visibleFrame.maxY - content.maxY).rounded())
        ]
        if resized {
            changes["width"] = .number(max(1, content.width.rounded()))
            changes["height"] = .number(max(1, content.height.rounded()))
            changes["shape"] = .string("custom")
        }
        reportedContent = content
        store.update(changes)
    }
}
