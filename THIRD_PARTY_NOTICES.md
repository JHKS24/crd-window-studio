# Third-party notices

The root [MIT license](LICENSE) covers original project material. It does not
relicense the third-party source files listed below.

## Chromium reference source

`reference/` contains selected Chromium source files that document the
host's sharing-window behavior and process boundaries. They retain their
original copyright headers and BSD-style license in
[reference/LICENSE](reference/LICENSE). The exact paths, source version and
file hashes are recorded in [reference/README.md](reference/README.md).

These reference files are not compiled into the settings app or overlay
agent. No Google executable, library, application resource, or authentication
configuration is bundled. The project observes a separately installed Google
host through macOS Accessibility APIs.

When redistributing reference files, keep their existing headers and license.
The application bundles also carry the notices and Chromium license under
`Contents/Resources/Licenses/` for attribution and redistribution convenience.

## System software

The macOS targets use Apple system frameworks, the Swift standard library,
and the Python standard library; no external Swift package is declared.
The optional Windows diagnostic uses the Windows SDK and C++ standard
library. These SDKs and operating-system frameworks are not supplied as
project source or vendored binaries.

## Artwork and translation

The independent project icon's source hash, format and licensing scope are recorded in
[assets/README.md](assets/README.md). Public exports contain only the declared
project icon and no Google/Chrome logos. Artwork is provided
under the project MIT license to the extent of contributors' rights; no
claim of exclusive trademark rights is made.

The Korean and English UI catalogs are original project material
under the MIT license; they are not copied Chrome interface resources.

The unofficial-project and trademark notice is in [NOTICE](NOTICE).
