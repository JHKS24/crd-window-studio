# Contributing

Start with a focused issue or change explaining the observed behavior, the expected behavior, macOS/CRD versions, and how to reproduce it. Remove personal paths, account information and authentication data from examples. Contributions require review and behavioral verification.

## Development boundaries

- Keep SwiftUI presentation separate from configuration/persistence and the native agent.
- Treat `Sources/CRDSettingsCore/Resources/SettingsSchema.json` as canonical. Regenerate native headers and update the Windows schema copy when it changes.
- Keep the Korean and English catalogs aligned. Preserve user-written labels; do not translate arbitrary configuration values.
- Use system semantic colors for settings UI. Preserve Reduce Motion, keyboard use, and menu dismissal.
- Preserve a user-accessible sharing stop action. Never terminate or restart Google's services to implement a UI change.
- Identify the signed original host and the appropriate Accessibility control before acting. Ambiguous targets must not be guessed.
- Prefer lifecycle/file events to repeated polling. Keep logs local, bounded, and free of account/session text.

## Check a change

Follow [BUILDING.md](BUILDING.md). Run tests that cover the affected boundary. Native fixtures and Python lifecycle tests must not mutate a live Google service or TCC permission database. Test a real disconnection only when a person explicitly intends to end that remote session and can recover access.

Describe what was verified in a fixture, a build, and a real remote session separately. A successful universal build does not prove runtime behavior on both architectures.

Contributions to original project code and documentation are accepted under the repository MIT license. Keep third-party license notices intact and record any new dependency's source and license. Do not contribute vendor binaries, credentials, private logs, or copied brand assets.
