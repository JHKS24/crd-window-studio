# Windows window diagnostic

[한국어](README.ko.md)

This optional source is a read-only Windows 10/11 CLI for identifying candidate CRD windows. It is not a Windows port of the settings app or a completed customization backend. If the host does not show a troublesome sharing indicator, there is no reason to install an additional resident helper.

## Build and optional use

Use Visual Studio 2022 C++ Build Tools with a Windows SDK and CMake 3.20 or later. In PowerShell, from this directory:

```powershell
.\build.ps1
.\build\Release\CRDWindowProbe.exe --once
# Optional event observation; Ctrl+C stops only this diagnostic.
.\build\Release\CRDWindowProbe.exe --watch
# Optionally restrict candidates to an exact executable path:
.\build\Release\CRDWindowProbe.exe --once --exe-path 'C:\path\to\remoting_host.exe'
```

The build script compiles only. It does not run or install the program, request elevation, create a service, or change policy/security settings. Watch mode uses an out-of-context WinEvent hook and message loop, not a periodic timer or DLL injection. After the initial snapshot it observes create/destroy/show/hide/location events and suppresses unchanged geometry/visibility. A new process without a window event may not be found until another `--once` run.

## Output and limits

UTF-8 NDJSON distinguishes candidate processes/windows and summaries. It does not print window titles/text, account addresses, command lines, or complete executable paths. Paths are inspected internally for optional exact-path matching and Authenticode checks.

- Candidate basenames are `remoting_host.exe` and `remoting_desktop.exe`, based on Chromium's [Windows BUILD.gn](https://raw.githubusercontent.com/chromium/chromium/155.0.8059.19/remoting/host/win/BUILD.gn). Recheck names when versions change.
- `authenticodeTrusted` is a cache-only WinVerifyTrust result. `googleSignerDisplayNameMatched` additionally checks the embedded signer's Google display name. Missing revocation cache, catalog-only signing or access restrictions can prevent confirmation. Name matching alone is insufficient.
- Every window remains a candidate. The CLI does not establish that it is a sharing indicator or that a remote session exists. `sharingSessionConfirmed` is always false. A process with zero candidate windows can be normal.
- Geometry comes from GetWindowRect and can include DPI virtualization or invisible resize borders. IsWindowVisible does not prove that a person can see the window through occlusion, minimization or other virtual desktops.
- Enumeration is limited to accessible top-level windows on the current user's desktop. Other sessions and secure desktops are not bypassed.
- Signature results are cached by PID and process creation time. If the on-disk file changes, start a new `--once` process. This is not a running-image integrity audit.

## A future Windows port

`schema/SettingsSchema.json` mirrors the macOS schema. The current CLI does not read or apply it. Keep it in sync when the canonical schema changes.

1. Reproduce an actual sharing-window problem on a specified Windows/CRD version. Establish a reliable UI Automation/owner-PID identity contract before manipulating anything.
2. Implement an independent Win32/WinUI/WPF panel with event-driven WinEvent/UIA/file-change observation. Do not create a resident panel when there is no original sharing indicator to manage.
3. Forward an explicit user stop action only to a validated original control, such as a supported UIA InvokePattern. Do not substitute service termination, injected input or Google library loading.
4. Determine supported hide/restore semantics and session/UAC/integrity/UIAccess boundaries separately. Do not assume macOS AXHidden has an equivalent Windows behavior. Preserve the original UI when ambiguous.

The current source has no window hiding/moving/resizing/closing, input injection, remote-disconnect, Google DLL-loading, service-management or auto-start changes. Windows compilation and runtime have not yet been verified; the macOS build does not validate this target.

## License

Original diagnostic code is MIT licensed. The repository root LICENSE is also included in the standalone Windows archive. No Google binaries or authentication material are supplied. This is an independent, unofficial tool.
