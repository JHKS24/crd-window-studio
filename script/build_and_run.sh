#!/bin/bash
# Build and launch only this checkout's settings app.
set -euo pipefail
# --- Run mode and architecture options ---

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in
  run|--verify|--debug) [ "$#" -eq 0 ] || shift ;;
  --universal) MODE=run ;;
  *) echo 'usage: script/build_and_run.sh [run|--verify|--debug] [--universal]' >&2; exit 2 ;;
esac
# Only the optional UI architecture flag is forwarded.
for argument in "$@"; do
  [ "$argument" = --universal ] || { echo "Unsupported run option: $argument" >&2; exit 2; }
done
# --- Build and replace this checkout's settings process ---

# Finish the build before closing the running settings app.
"$ROOT/scripts/build.sh" --ui "$@"
APP="$ROOT/dist/CRD Window Studio.app"
# Only terminate settings executables belonging to this checkout. No host process
# or another checkout's settings process is touched.
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command_line" in
    "$APP/Contents/MacOS/CRDWindowStudio"|"$APP/Contents/MacOS/CRDWindowStudio "*) kill "$pid" 2>/dev/null || true ;;
  esac
done < <(pgrep -x CRDWindowStudio || true)
# --- Launch, verify or debug the settings app ---

case "$MODE" in
  run) /usr/bin/open -n "$APP" ;;
  --verify)
    /usr/bin/open -n "$APP"
    sleep 2
    found=0
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      case "$command_line" in
        "$APP/Contents/MacOS/CRDWindowStudio"|"$APP/Contents/MacOS/CRDWindowStudio "*) echo "CRDWindowStudio running: $pid"; found=1 ;;
      esac
    done < <(pgrep -x CRDWindowStudio || true)
    [ "$found" -eq 1 ] || { echo 'Settings app did not remain running.' >&2; exit 1; }
    ;;
  --debug) xcrun lldb -- "$APP/Contents/MacOS/CRDWindowStudio" ;;
esac
