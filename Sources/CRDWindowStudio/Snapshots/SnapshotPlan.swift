import AppKit
import CRDSettingsCore
import SwiftUI

/// Every page and state the snapshot renderer draws. Pages render in light and dark
/// unless a job says otherwise; English and the minimum size cover one page each.
    /// The built-in dot shape.
@MainActor enum SnapshotPlan {
    static let dotConfig: [String: ConfigValue] = ["shape": .string("dot"), "layout": .string("dot"), "width": .number(40), "height": .number(40),
                                                    "radius": .number(20), "showText": .bool(false), "showStopButton": .bool(false), "dotDiameter": .number(10)]
    /// A small custom dot at a custom position, with auto-shrink off.
    static let smallDotConfig: [String: ConfigValue] = ["shape": .string("custom"), "layout": .string("dot"), "width": .number(42), "height": .number(42),
                                                      "radius": .number(21), "dotDiameter": .number(12), "placement": .string("custom"), "x": .number(1370), "y": .number(49),
                                                      "showText": .bool(false), "showStopButton": .bool(false), "stopRevealSeconds": .number(0)]
    /// A wide bar at the top with text and the Stop button.
    static let wideBar: [String: ConfigValue] = ["shape": .string("bar"), "layout": .string("row"), "width": .number(440), "height": .number(48), "radius": .number(12),
                                                  "showText": .bool(true), "showStopButton": .bool(true), "placement": .string("top")]
    static let previewSize = NSSize(width: 440, height: 48)

    /// The standard snapshot set.
    static func jobs() -> [SnapshotJob] {
        var jobs: [SnapshotJob] = []
        for page in ["display", "helper"] {
            for state in [FixtureState.running, .off, .permission] {
                jobs.append(.init(page: page, state: state.rawValue, fixture: state))
            }
        }
        jobs.append(.init(page: "display", state: "waiting", fixture: .waiting, themes: [false]))
        jobs.append(.init(page: "display", state: "missing", fixture: .missing, themes: [false]))
        jobs.append(.init(page: "helper", state: "restoration-blocked", fixture: .blocked, themes: [false], languages: ["ko", "en"]))
        jobs.append(.init(page: "display", state: "restoration-blocked", fixture: .blocked, themes: [false], languages: ["ko", "en"]))
        jobs.append(.init(page: "display", state: "invalid-config", fixture: .running, themes: [false], languages: ["ko", "en"], rawConfig: "{ not json"))
        for page in ["position", "appearance"] { jobs.append(.init(page: page, state: "default", fixture: .running)) }
        jobs.append(.init(page: "appearance", state: "dot", fixture: .running, config: dotConfig, themes: [false]))
        // The lock toggles with the hide row set to Automatically (5 seconds), and the presets section, whole pages in both languages.
        jobs.append(.init(page: "position", state: "locked", fixture: .running, config: ["draggable": .bool(false), "resizable": .bool(false)],
                          size: NSSize(width: 820, height: 1100), languages: ["ko", "en"]))
        jobs.append(.init(page: "appearance", state: "presets", fixture: .running, config: smallDotConfig, size: NSSize(width: 820, height: 1700),
                          languages: ["ko", "en"], presets: [("Small dot", [:]), ("Wide bar", wideBar)]))
        // The other way to hide the Stop Sharing button: Until I Hide It (0).
        jobs.append(.init(page: "position", state: "hide-manual", fixture: .running, config: ["stopRevealSeconds": .number(0)], size: NSSize(width: 820, height: 1100),
                          languages: ["ko", "en"]))
        jobs.append(.init(page: "appearance", state: "presets-empty", fixture: .running, size: NSSize(width: 820, height: 900), themes: [false]))
        jobs.append(.init(page: "display", state: "running", fixture: .running, themes: [false], languages: ["en"]))
        jobs.append(.init(page: "appearance", state: "default", fixture: .running, themes: [false], languages: ["en"]))
        jobs.append(.init(page: "position", state: "running-min", fixture: .running, size: SnapshotJob.minimumSize, themes: [false]))
        // The whole troubleshooting page, to show what sits below the fold.
        jobs.append(.init(page: "helper", state: "full", fixture: .running, size: NSSize(width: 820, height: 1500), themes: [false]))
        // The helper's own window for each built-in shape.
        jobs.append(.init(page: "sharing", state: "shapes", fixture: .running, size: NSSize(width: 820, height: 500), chrome: false))
        jobs.append(.init(page: "sharing", state: "shapes-gray", fixture: .running, config: ["stopStyle": .string("gray")],
                          size: NSSize(width: 820, height: 500), languages: ["ko", "en"], chrome: false))
        // The Stop style row next to the Stop label, with the grey style chosen.
        jobs.append(.init(page: "appearance", state: "stop-style-gray", fixture: .running, config: ["stopStyle": .string("gray")],
                          size: NSSize(width: 820, height: 1700), languages: ["ko", "en"]))
        // The real-size preview window with its save note under the title.
        jobs.append(.init(page: "preview", state: "bar", fixture: .running, size: previewSize))
        jobs.append(.init(page: "preview", state: "border-nohandle", fixture: .running,
                          config: ["borderWidth": .number(3), "accent": .string("orange"), "showHandle": .bool(false)], size: previewSize))
        jobs.append(.init(page: "preview", state: "locked", fixture: .running,
                          config: ["draggable": .bool(false), "resizable": .bool(false)], size: previewSize))
        // The filled accent button in an active and an inactive window, enabled and disabled.
        jobs.append(.init(page: "contrast", state: "buttons", fixture: .permission, size: NSSize(width: 560, height: 150), chrome: false))
        return jobs
    }

    /// The text-fit set: each page whole, at the minimum and the default width,
    /// in both languages, with the states that add rows or longer text.
    static func fitJobs() -> [SnapshotJob] {
        var jobs: [SnapshotJob] = []
        let variants: [(String, String, FixtureState, [String: ConfigValue])] = [
            ("display", "running", .running, [:]), ("display", "permission", .permission, [:]), ("display", "off", .off, ["enabled": .bool(false)]),
            ("position", "custom", .running, ["placement": .string("custom"), "constrainToScreen": .bool(false)]),
            ("appearance", "default", .running, [:]), ("appearance", "dot", .running, dotConfig),
            ("helper", "running", .running, [:]), ("helper", "missing", .missing, [:]),
            // The checklist with Not Allowed and both permission buttons at the minimum width.
            ("helper", "permission", .permission, [:]),
        ]
        for (page, state, fixture, config) in variants {
            for (width, tag) in [(SnapshotJob.minimumSize.width, "min"), (SnapshotJob.defaultSize.width, "default")] {
                jobs.append(.init(page: page, state: "\(state)-fit-\(tag)", fixture: fixture, config: config,
                                  size: NSSize(width: width, height: 1500), themes: [false], languages: ["ko", "en"]))
            }
        }
        jobs.append(.init(page: "preview", state: "fit", fixture: .running, size: previewSize, themes: [false, true], languages: ["ko", "en"]))
        return jobs
    }

    /// The title of the window the job is drawn in.
    static func windowTitle(for job: SnapshotJob) -> String {
        job.page == "preview" ? L10n.text("공유 창 미리보기") : L10n.text("설정 창")
    }

    /// The view a job renders: a settings page, the preview, the shape gallery or the contrast check.
    static func view(for job: SnapshotJob, fixture: SnapshotFixture) -> AnyView {
        switch job.page {
        case "sharing": return AnyView(HelperShapeGallery(schema: fixture.store.schema, stopStyle: fixture.store.string("stopStyle")))
        case "preview": return AnyView(HelperWindowPreview(store: fixture.store).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        case "contrast": return AnyView(ContrastCheck(companion: fixture.companion, store: fixture.store))
        default:
            let navigation = SettingsNavigation(page: SettingsPage(rawValue: job.page) ?? .display)
            let env = SettingsEnvironment(store: fixture.store, preferences: fixture.preferences, companion: fixture.companion,
                                          openPreview: {}, navigation: navigation)
            return AnyView(SettingsContent(environment: env))
        }
    }
}

/// The status row's main action as it draws in a key window and in a window in
/// the background, plus the disabled state.
private struct ContrastCheck: View {
    @ObservedObject var companion: CompanionService
    @ObservedObject var store: SettingsStore
    var body: some View {
        let status = StudioStatus.make(companion: companion, store: store)
        let title = status.actionTitle ?? L10n.text("확인")
        VStack(alignment: .leading, spacing: 14) {
            row("key", title: title, state: .key, enabled: true)
            row("inactive", title: title, state: .inactive, enabled: true)
            row("disabled", title: title, state: .key, enabled: false)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private func row(_ label: String, title: String, state: ControlActiveState, enabled: Bool) -> some View {
        HStack(spacing: 16) {
            Text(label).font(.callout.monospaced()).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Button(title) {}.buttonStyle(.prominent).disabled(!enabled)
            Button(title) {}.buttonStyle(.prominent).controlSize(.small).disabled(!enabled)
        }
        .environment(\.controlActiveState, state)
    }
}
