# Privacy and local data

The app and helper have no project telemetry, analytics, network client, account sign-in, or update-download service. The independently installed Google CRD host still handles networking and has its own data practices.

## Permission and inspection

Accessibility permission lets the helper inspect and act on the Google host's UI. macOS describes this permission broadly; the implementation scopes actions by verified host identity and sharing-window structure. The app reads process paths, publisher signatures, window/control structure and state. It may read the original sharing label to display the default status text, but does not write that label to its event log. The helper does not request Screen Recording permission or collect typed keys, account/PIN configuration, or Google authentication files.

## Stored files

| Location under `~/Library/Application Support/CRDWindowPatch/` | Contents |
|---|---|
| `config.json` | Display/geometry settings and any custom text the user enters |
| `logs/events.jsonl` | Allowlisted before/after settings, geometry, lifecycle and error events |
| `runtime-status.json` | Local process IDs, readiness and sharing-window state |
| `restore-state.json` | Pending restoration, verified host path, PID and process start time; cleared after restoration is confirmed or that process ends |
| `companion-install.json` | Installation record, local paths, original host version/signature/hash, service observations and the helper's post-signing fingerprint/requirement |
| `archives/` | Up to five completed generations, each grouping a prior helper bundle, its LaunchAgent when present, and its installation record; recovery exceptions below |
| `staging/` | Prepared helper and build inputs; obsolete `previous-overlay-*.app` copies move to the Trash after a new signed stage is published |
| `companion.stdout.log`, `companion.stderr.log`, probe files | Local launchd/diagnostic output |

The settings app also uses its own macOS preferences for window/startup options. Custom text and filesystem paths can be private even though the event log excludes session labels and account information.

The **event log** is enabled by default and capped at 1 MiB, removing oldest records first when space is needed. While the helper runs, a one-shot expiry timer removes records after 24 hours. The helper also prunes on startup; the controller prunes on `status` and `restore`. While the helper is stopped, records can remain beyond 24 hours until one of those access points runs. There is no separate cleanup service. Disabling the helper prunes expired records and preserves those still inside 24 hours.

The controller keeps the five newest completed archive generations at the end of `install`, `permissions`, `restore`, and successful failure cleanup. Older generations move to the Trash, where macOS and the user control their lifetime. Separate `receipt-history` folders count individually toward this limit. Pruning pauses during `cleanup_failed` or while the restoration journal is pending or unreadable; the installed helper and journal stay in place. An interrupted archive may leave an incomplete `.pending-*` folder outside the completed-generation limit. A Trash failure is reported and leaves that item recoverable in place; the next eligible operation retries pruning. There is no background archive cleanup or automatic emptying of the Trash.

Event files/directories use restrictive local permissions. The event-log and archive bounds do not apply to launchd diagnostic output, configuration, restoration state, or exported log copies. Those files remain until the user removes them. Disabling event logging stops new event recording; it is not a command to delete every support file.

Log export is a local save operation. The app does not upload the result. Review any support material before attaching it to an issue; avoid sharing a complete support folder. To remove local data, stop the helper safely as described in [Building](../BUILDING.md#recovery-and-removal), back up anything needed, and remove the unwanted files.
