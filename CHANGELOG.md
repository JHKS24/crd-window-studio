# Changelog

## 2.0 (2026-10-23)

- Shutdown restores the original notice before a nonblocking geometry save; busy saves retry while the helper runs.
- The Stop capsule keeps a fold dot when the window dot is hidden and closes before a display change repositions its anchor.
- The inline Stop gate also covers the delayed release of a rejected press.
- Remote pointer jitter up to 4 pt remains a click on the window and grips; a double-click during capsule closing can reopen it.
- The settings app saves edits kept while config.json was missing once it returns, and the position map falls back to the first display.
- The settings app checks for the command line developer tools before running the helper controller and offers Apple's installer.
- The two display modes are custom (the default) and original; a saved hidden mode loads as custom.
- Bundle replacement uses the macOS 14-compatible Foundation Trash API; replaced bundles remain recoverable.
- Retained helper execution checks its post-signing fingerprint and requirement, with certificate verification for recovery records without a fingerprint.
- Completed helper archives keep five generations, with restoration and Trash-failure exceptions documented in [Privacy](docs/PRIVACY.md).
- Native macOS sharing-indicator settings and independent Accessibility agent.
- Persistent geometry, shapes, system appearance, independent status-dot color and padding.
- Expandable status-dot capsule, menu bar controls, and dismissible context menus.
- A double-click at a screen edge or corner opens the Stop capsule moved inside the screen, not a Stop menu.
- Korean and English UI, previews, and bounded local change logs.
- Portable Apple Silicon/Intel builds and optional Windows diagnostic source.
- MIT license for original material, preserved Chromium notices, an independent project icon, bilingual build guides, and clean source exports.

The app in the release DMG is ad hoc signed and not notarized. No Windows customization backend is included in this source release.
