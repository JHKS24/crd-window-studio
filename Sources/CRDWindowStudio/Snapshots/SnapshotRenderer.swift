import AppKit
import CRDSettingsCore
import SwiftUI

/// `--render-snapshots <dir> [--only <prefix>] [--fit-check]`
/// Renders pages into PNG files at 2x from an offscreen window that is never
/// ordered on screen. The app is never activated and no helper command runs.
/// The UI language follows the process language (`-AppleLanguages "(en)"`).
struct SnapshotRequest {
    let output: URL
    var only: String?
    /// Every page at full height, at the default and the minimum width, to check that text fits.
    var fitCheck = false
    enum ArgumentError: LocalizedError {
        case missing
        var errorDescription: String? { "usage: CRDWindowStudio --render-snapshots <dir> [--only <prefix>] [--fit-check]" }
    }
    static func parse(_ args: [String]) throws -> Self? {
        guard let index = args.firstIndex(of: "--render-snapshots") else { return nil }
        guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else { throw ArgumentError.missing }
        var request = Self(output: URL(fileURLWithPath: args[index + 1], isDirectory: true))
        if let o = args.firstIndex(of: "--only"), args.indices.contains(o + 1) { request.only = args[o + 1] }
        request.fitCheck = args.contains("--fit-check")
        return request
    }
}

/// One page to render, with its fixture state, settings, size, themes and languages.
struct SnapshotJob {
    let page: String
    let state: String
    let fixture: FixtureState
    var config: [String: ConfigValue] = [:]
    var size = SnapshotJob.defaultSize
    var themes: [Bool] = [false, true]
    var languages: [String] = ["ko"]
    var chrome = true
    /// Written as the settings file instead of `config`, to show the invalid-file banner.
    var rawConfig: String?
    /// Presets saved (over the job's settings) before the page renders.
    var presets: [(name: String, values: [String: ConfigValue])] = []
    static let defaultSize = NSSize(width: 820, height: 740)
    static let minimumSize = NSSize(width: 660, height: 500)
}

/// Renders snapshot jobs offscreen and writes one PNG per job, theme and language.
@MainActor enum SnapshotRenderer {
    static let scale = 2
    /// Starts a background (accessory) application, renders, and exits with 0 on success or 1 on failure.
    static func run(_ request: SnapshotRequest) {
        AppRuntime.renderingSnapshots = true
        // Must be the first NSApplication reference so NSApp is this subclass.
        _ = SnapshotApplication.shared
        // Accessory: no Dock icon and no menu bar takeover. The app is never activated.
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await render(request); exit(0) }
            catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        NSApp.run()
    }

    /// Renders every job for the current language into the output folder, with a fresh temporary
    /// configuration for each job. `CRD_WINDOW_CONFIG` points at it, so the real configuration is never read.
    static func render(_ request: SnapshotRequest) async throws {
        let language = L10n.languageCode
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("CRDWindowStudio-snapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let configURL = scratch.appendingPathComponent("config.json")
        setenv("CRD_WINDOW_CONFIG", configURL.path, 1)
        let schema = try SettingsSchema.load()
        var count = 0
        let folder = request.output
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for job in (request.fitCheck ? SnapshotPlan.fitJobs() : SnapshotPlan.jobs()) where job.languages.contains(language) {
            for dark in job.themes {
                let name = "\(job.page)_\(job.state)_\(dark ? "dark" : "light")_\(language)"
                if let only = request.only, !name.hasPrefix(only) { continue }
                var config = schema.defaults
                config["mode"] = .string("custom")
                config.merge(job.config) { $1 }
                try? FileManager.default.removeItem(at: scratch.appendingPathComponent("presets.json"))
                let fixture = try await SnapshotFixture.make(state: job.fixture, config: config, configURL: configURL, raw: job.rawConfig.map { Data($0.utf8) })
                if !job.presets.isEmpty {
                    let presets = PresetRepository(configuration: fixture.store.repository)
                    for preset in job.presets { try presets.save(name: preset.name, values: fixture.store.values.merging(preset.values) { $1 }) }
                    fixture.store.presets.reload()
                }
                let view = SnapshotPlan.view(for: job, fixture: fixture)
                let bitmap = try await bitmap(view, dark: dark, size: job.size, chrome: job.chrome, title: SnapshotPlan.windowTitle(for: job), saveNote: job.page == "preview" && PreviewWindowNote.shows(fixture.store.values))
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: folder.appendingPathComponent("\(name).png"), options: .atomic)
                fixture.defaults.removePersistentDomain(forName: fixture.suite)
                count += 1
            }
        }
        print("rendered \(count) snapshots (\(language)) into \(request.output.path)")
    }

    private static var window: SnapshotWindow?
    /// Draws `view` in the reused offscreen window and returns it as a 2x bitmap, with the window
    /// frame when `chrome` is true.
    static func bitmap(_ view: AnyView, dark: Bool, size: NSSize, chrome: Bool, title: String, saveNote: Bool) async throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.controlActiveState, .key)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = NSHostingView(rootView: content)
        let style: NSWindow.StyleMask = chrome ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless]
        if window == nil || window?.styleMask != style {
            window?.close()
            // Far outside every display and never ordered in: nothing appears on screen.
            window = SnapshotWindow(contentRect: NSRect(x: -32000, y: -32000, width: size.width, height: size.height),
                                    styleMask: style, backing: .buffered, defer: false)
            window?.isReleasedWhenClosed = false
        }
        guard let window else { throw CocoaError(.fileWriteUnknown) }
        window.title = title
        // The same note below the title bar the real preview window gets, unless both locks are on.
        // A settings page leaves its split view toolbar on the reused window; the preview has none.
        if saveNote { window.toolbar = nil }
        PreviewWindowNote.remove(from: window)
        if saveNote { PreviewWindowNote.install(on: window) }
        window.appearance = appearance
        window.contentView = host
        window.setContentSize(size)
        host.appearance = appearance
        for _ in 0..<6 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            host.layoutSubtreeIfNeeded()
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        host.layoutSubtreeIfNeeded()
        // Native sidebar selection is emphasized while its table is first responder.
        func tables(_ view: NSView) -> [NSTableView] { (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables) }
        if let sidebar = tables(host).first { window.makeFirstResponder(sidebar) }
        let target: NSView = chrome ? (window.contentView?.superview ?? host) : host
        target.layoutSubtreeIfNeeded()
        let bounds = target.bounds
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width) * scale, pixelsHigh: Int(bounds.height) * scale,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = bounds.size
        appearance.performAsCurrentDrawingAppearance { target.cacheDisplay(in: bounds, to: bitmap) }
        return bitmap
    }
}

/// An offscreen window that draws as key and main without ever becoming key.
private final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Draw controls as in a key window without making the window key or activating the app.
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    // AppKit's private active-appearance queries; dev-only snapshot window.
    @objc func _hasActiveAppearance() -> Bool { true }
    @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc func _hasKeyAppearance() -> Bool { true }
}

/// Controls draw in their active (accent) style only when the application is
/// active. Reporting active here never activates the process or takes focus.
private final class SnapshotApplication: NSApplication {
    override var isActive: Bool { true }
}
