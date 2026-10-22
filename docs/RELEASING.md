# Preparing a source release

Release preparation is separate from publishing a repository or binary. The source exporter does not contact GitHub, create a repository, change visibility, or carry over Git history.

## Create the public tree

From the working source:

```sh
python3 scripts/package_source.py --directory "dist/CRDWindowStudio-OpenSource"
python3 scripts/package_source.py --windows
```

The output directory must not already exist. The complete export includes original source, bilingual docs, licenses, the public PNG, tests, Windows diagnostic source and identified Chromium references. The standalone Windows ZIP includes its build/porting docs and MIT license. Both contain a SHA-256 source manifest.

The exporter uses declared paths and extension sets. It excludes local evidence, build outputs, Git history, editor state, undeclared sources and vendor binaries. It rejects symlinked files and common credential/private-home-path markers in text. It includes only `assets/AppIcon.png`; packaging rebuilds ICNS files from that declared source.

Review the resulting files, manifest and archive. Automated pattern checks cannot replace a review of any newly added content. Publish from the clean export tree. Configure the desired public repository name and author identity separately; this script does not choose them.

## Verify the exact export

Extract the ZIP into a fresh directory, preferably containing spaces. Run the instructions in BUILDING.md with `CRD_HOST_APP` pointing to a nonexistent path during the build. A real host is not required for compilation, tests or previews.

Check the universal architectures, minimum OS, strict code signatures, project icon and bundled notices. Run Swift/Python tests and the native fixture. Confirm that relative documentation links resolve. Record checks performed on real hardware/session separately from fixture and build checks. Windows remains diagnostic-only until someone actually builds/runs it on Windows and records the result.

## Before a public release

- Keep LICENSE, NOTICE, THIRD_PARTY_NOTICES.md and the Chromium headers/license intact.
- Update CHANGELOG.md and the tested-version/limitations table to match the released source.
- Keep the unofficial-project statement. Do not add Chrome/Google logos or imply Google endorsement.
- Enable a private security-reporting route for the chosen repository and update SECURITY.md if a dedicated contact is established.
- Source builds are ad hoc signed. A downloadable trusted binary is a separate Developer ID signing/notarization workflow; do not describe this source bundle as notarized.

No API key, signing certificate, personal account file, machine log or Google binary belongs in the public tree.

## Build a public DMG

From a clean source checkout on macOS with the build tools in BUILDING.md:

```sh
python3 scripts/package_dmg.py --output-directory "$HOME/Desktop/CRD-releases"
```

The script cleans Swift build products in `.build`, then runs `scripts/build.sh --all --universal` with `CRD_SIGN_IDENTITY=-`. It does not install or launch either program. The packaged app records `CRDSigningIdentity=-`, so a helper prepared on another Mac also uses ad hoc signing. This public artifact is separate from any installation signed with a local certificate.

The DMG contains only `CRD Window Studio.app` and an `Applications` link. Its volume is named `CRD Window Studio`; its filename takes `CFBundleShortVersionString` from the app, for example `CRD-Window-Studio-2.0.dmg`. HFS+ with UDZO compression opens on macOS 14. Both executables must contain arm64 and x86_64 slices and target macOS 14.0. Packaging strips debug object-file paths, signs again, checks the payload and strict signatures, verifies the image with `hdiutil`, and writes a `.dmg.sha256` checksum beside it.

Before publishing, mount the result read-only without opening Finder, inspect its contents, and verify the mounted copy:

```sh
mkdir -p build/dmg-mount
hdiutil verify "$HOME/Desktop/CRD-releases/CRD-Window-Studio-2.0.dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$PWD/build/dmg-mount" \
  "$HOME/Desktop/CRD-releases/CRD-Window-Studio-2.0.dmg"
codesign --verify --deep --strict "build/dmg-mount/CRD Window Studio.app"
lipo -archs "build/dmg-mount/CRD Window Studio.app/Contents/MacOS/CRDWindowStudio"
lipo -archs "build/dmg-mount/CRD Window Studio.app/Contents/Resources/Backend/OverlayAgent"
spctl --assess --type execute --verbose=4 "build/dmg-mount/CRD Window Studio.app"
hdiutil detach "$PWD/build/dmg-mount"
```

Gatekeeper rejection is expected: an ad hoc build has no Developer ID signature or notarization. Record that result; do not describe the download as notarized. The script retains `build/dmg-stage` for inspection and refuses to overwrite an existing image, checksum or staging folder. Move staging and any failed `.partial.dmg` to the Trash before rerunning. Publishing, tagging and uploading remain separate steps.
