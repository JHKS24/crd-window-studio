# Changelog

## Unreleased

- The two display modes are custom (the default) and original; a saved hidden mode loads as custom.
- Bundle replacement uses the macOS 14-compatible Foundation Trash API; replaced bundles remain recoverable.
- Retained helper execution checks its post-signing fingerprint and requirement, with certificate verification for recovery records without a fingerprint.
- Completed helper archives keep five generations, with restoration and Trash-failure exceptions documented in [Privacy](docs/PRIVACY.md).
- Native macOS sharing-indicator settings and independent Accessibility agent.
- Persistent geometry, shapes, system appearance, independent status-dot color and padding.
- Expandable status-dot capsule, menu bar controls, and dismissible context menus.
- Korean and English UI, previews, and bounded local change logs.
- Portable Apple Silicon/Intel builds and optional Windows diagnostic source.
- MIT license for original material, preserved Chromium notices, an independent project icon, bilingual build guides, and clean source exports.

No signed/notarized public binary or Windows customization backend is included in this source release.
