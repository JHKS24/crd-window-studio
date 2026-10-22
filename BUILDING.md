# Building and installing

[한국어](BUILDING.ko.md) | [Overview](README.md)

## Requirements

Use macOS 14 or later with Swift 5.9 or later, Apple Command Line Tools or Xcode, and Python 3. The scripts use `swift`, `clang++`, `python3`, `sips`, `iconutil`, and `codesign`. Install Apple's tools with `xcode-select --install` if needed. No developer account, external Swift package, or Google binary is required to build.

## Build

From the extracted source or repository root:

```sh
./scripts/build.sh --all --universal
open "dist/CRD Window Studio.app"
```

Omit `--universal` to build only the current architecture. `--ui` builds the settings app without a helper, `--backend` builds the native agent, and `--all` builds both and bundles the matching agent/controller with the app. A UI-only build never reuses an old helper from `build/`. Paths containing spaces are supported.

Outputs are `dist/CRD Window Studio.app` and `build/OverlayAgent`. The PNG icon is converted into ICNS, localization/schema resources and legal notices are included, and the result is locally ad hoc signed. This is not a Developer ID signature or notarized public release. Do not disable macOS security protections as part of installation.

Replacing an existing bundle uses Foundation's Trash API on macOS 14 and later; it does not need `/usr/bin/trash`, Finder, or an Automation prompt. The old bundle stays recoverable until the new signed bundle is published, then moves to the Trash. If Trash fails, the command reports the retained path instead of deleting it.

Public builds default to ad hoc signing (`CRD_SIGN_IDENTITY=-`). For repeated local installs, opt into an existing code-signing certificate:

```sh
export CRD_SIGN_IDENTITY="Your Local Signing Identity"
./scripts/build.sh --all
python3 scripts/companionctl.py prepare
```

The same setting signs both products. The packaged settings app records the chosen identity, so its GUI-driven helper preparation uses it without a shell environment. An unavailable requested identity is an error; there is no ad hoc fallback. Keep the same certificate/private key and bundle identifiers (`local.crdwindow.studio`, `local.crdwindow.host`) across rebuilds. A certificate with the same display name but a different key is a different signer. Check the resulting designated requirements with `codesign -dr - "path/to/app"` before replacing installed bundles. This opt-in does not make a build notarized or grant Accessibility permission.

## Install the helper

First configure the official Chrome Remote Desktop host and confirm that a remote connection works. The default host location is `/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app`.

Keep the settings app in a stable location, such as `~/Applications/CRD Window Studio.app`. Stop a previously running settings app before replacing its bundle. Do not overwrite a running helper.

In the settings app, the first **Turn On Window Helper** asks macOS for the permission first and installs the helper only after the check succeeds. If access is still missing, it offers the permission settings instead. The commands below are the command-line route.

From the source root:

```sh
python3 scripts/companionctl.py prepare
python3 scripts/companionctl.py permissions --prompt
```

`prepare` reads the original host's signature/version and creates our helper bundle. `permissions --prompt` prepares the fixed helper installation path and requests Accessibility access from an independent per-user launchd probe running **CRD Window Host** itself. The request belongs to the helper, not the settings app, Terminal or Python.

On first install, allow **CRD Window Host** in **System Settings > Privacy & Security > Accessibility**, or **Privacy & Security > Device Control and Data Access** on macOS 27 and later. The request is asynchronous: the command reports current trust and exits, so `"accessibility": false` immediately after requesting is expected until you grant access. Plain `permissions` never requests a prompt. The controller cleans up the temporary probe job in both modes; it does not keep a background permission watcher. The project does not edit the permission database. Screen Recording permission is not requested.

After permission is granted, run the plain check:

```sh
python3 scripts/companionctl.py permissions
```

Continue only when it reports `"accessibility": true`; a successful check command can also report `false`.

```sh
python3 scripts/companionctl.py install
python3 scripts/companionctl.py status
```

Check for the helper's ready state and a detected sharing window during a real session. A running helper alone does not prove a remote connection. The status may correctly report waiting for the original host when no host process is present.

For a nonstandard host path, pass `--host-app "/path/to/ChromeRemoteDesktopHost.app"` to `prepare`, `permissions`, and `install`, or set `CRD_HOST_APP`. The publisher check still applies. Do not use `sudo`.

The helper is installed at `~/Library/Application Support/CRDWindowPatch/CRD Window Host.app`. Its user LaunchAgent is `~/Library/LaunchAgents/local.crdwindow.host.plist`. The menu bar belongs to the helper, so closing the settings app leaves it available. The settings app's login option controls the settings app separately.

## Updating a local build

Build and verify the new source before replacing anything. Back up the configuration. Then use `restore` to stop only this helper, replace the settings app if desired, and repeat `permissions` and `install` using the new build. An ad hoc rebuild may require removing/re-adding this helper's existing permission entry in Accessibility, or Device Control and Data Access on macOS 27 and later. Do not change the Google host's permission entry.

## Recovery and removal

```sh
python3 scripts/companionctl.py restart   # restart only this helper
python3 scripts/companionctl.py restore   # stop it and restore the original indicator
```

Turning off **Replace Sharing Window** keeps the helper/menu bar running and restores the original indicator. **Turn Off Window Helper** or `restore` stops the helper itself. The controller groups the prior bundle, LaunchAgent and installation record in one archive generation and keeps the five newest completed generations. Older ones move to the Trash; settings stay in place. Recovery and Trash-failure exceptions are described in [Privacy](docs/PRIVACY.md).

On normal exit and detected errors the agent attempts to restore the original hidden state. After an unexpected failure, launchd can restart it with a minimum five-second throttle. Permission loss, a changed host structure, or another failure may prevent immediate restoration. Use `restore` while the helper still has its permission; if access must be regained, use **CRD Window Host** in **Privacy & Security > Accessibility**, or **Device Control and Data Access** on macOS 27 and later. When no helper can restore the UI, a person with local access may end the remote session through the original Google controls. Do not rely on this app as a guaranteed emergency control.

If `restore` reports `cleanup_failed`, keep the helper and its restoration journal. After restoring its permission, run `restore` again. The explicit retry uses the retained signed helper in a bounded restoration-only job; it does not start the overlay or re-hide the original. A confirmed dead/replaced original can be cleared without Accessibility permission. Unknown liveness or another failed unhide leaves recovery pending. Do not delete or edit the journal to bypass this check.

To remove the app completely, first run `restore` and verify the original indicator. Then remove the settings app and, if no longer needed, its support folder and permission entry in the pane named above. Back up settings or exported logs before deleting them. Google CRD is a separate installation.

## Verification

```sh
swift test
python3 -m unittest discover -s tests -p 'test_*.py'
./build/OverlayAgent --crd-overlay-self-test
codesign --verify --strict "dist/CRD Window Studio.app"
```

The native self-test creates isolated temporary fixture data and does not access a real Google host. Python lifecycle tests mock process, service, signature and permission operations. These checks are distinct from testing a remote session. Do not click the real Stop Sharing button unless you intend to disconnect.

For a resource sample, get the current helper PID from `status` and replace `12345`:

```sh
python3 scripts/measure_resources.py --pid 12345 --duration 20   --label overlay-idle --output build/overlay-idle-resources.json
```

CPU is calculated from CPU-time deltas as a percentage of one core. RSS is reported in MiB. Record whether a session or interactive UI was active.

## Localization

`Sources/CRDSettingsCore/Resources/Localization/{ko,en}.json` is shared by Swift and the native agent. `scripts/generate_localizations.py` validates keys and printf arguments and generates the native header. UI language follows macOS/per-app preferences; custom user text is kept intact. Raw technical CLI errors are not fully localized.

## Clean source export

```sh
python3 scripts/package_source.py --directory "dist/CRDWindowStudio-OpenSource"
python3 scripts/package_source.py --windows
```

The first command creates the full source ZIP plus a clean directory, with no Git history. The directory must not already exist. The second creates a separate Windows diagnostic ZIP. The exporter includes declared source/docs/licenses only, checks text for common private-path/credential markers, and adds a SHA-256 manifest. No scan can certify that arbitrary future content is safe: inspect the exact export before publishing. See [Releasing](docs/RELEASING.md).
