#!/bin/bash
# Build the settings app without requiring Chrome Remote Desktop.
set -euo pipefail
# --- Build options and deployment target ---

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_UI=1
BUILD_BACKEND=0
UNIVERSAL=0
HOST_APP="${CRD_HOST_APP:-}"
# Keep Swift build engines from inheriting the current SDK as deployment minimum.
export MACOSX_DEPLOYMENT_TARGET=14.0
export CRD_SIGN_IDENTITY="${CRD_SIGN_IDENTITY:--}"
usage() {
  # Print the supported product, architecture and host metadata options.
  cat <<'HELP'
Usage: scripts/build.sh [--ui|--backend|--all] [--universal] [--host-app PATH]
  --ui          Build the settings app only (default; no Google app required).
  --backend     Build the independent companion launcher only (no Google app required).
  --all         Build both products.
  --universal   Build arm64 + x86_64 instead of this Mac's native architecture.
  --host-app    Optional runtime original-host metadata; CRD_HOST_APP is also accepted.
HELP
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ui) BUILD_UI=1; BUILD_BACKEND=0; shift ;;
    --backend) BUILD_UI=0; BUILD_BACKEND=1; shift ;;
    --all) BUILD_UI=1; BUILD_BACKEND=1; shift ;;
    --universal) UNIVERSAL=1; shift ;;
    --host-app)
      [ "$#" -ge 2 ] || { echo 'Missing --host-app value.' >&2; exit 2; }
      HOST_APP="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
# --- Toolchain and architecture selection ---

[ "$(uname -s)" = Darwin ] || { echo 'macOS 14 or later is required.' >&2; exit 1; }
xcrun --find clang++ >/dev/null
command -v python3 >/dev/null
mkdir -p "$ROOT/build" "$ROOT/dist"
ARCH_ARGS=(-arch "$(uname -m)")
SWIFT_ARCH_ARGS=(--arch "$(uname -m)")
if [ "$UNIVERSAL" -eq 1 ]; then
  ARCH_ARGS=(-arch arm64 -arch x86_64)
  SWIFT_ARCH_ARGS=(--arch arm64 --arch x86_64)
fi
# --- Independent helper build ---

if [ "$BUILD_BACKEND" -eq 1 ]; then
  python3 "$ROOT/scripts/generate_schema.py"
  python3 "$ROOT/scripts/generate_localizations.py"
  # The production overlay never links or loads Google's code.
  xcrun clang++ -std=c++17 -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
    "${ARCH_ARGS[@]}" -mmacosx-version-min=14.0 -I"$ROOT/generated" \
    "$ROOT/backend/OverlayMain.mm" -framework Cocoa -framework Security -framework ApplicationServices -o "$ROOT/build/OverlayAgent"
  if [ -n "$HOST_APP" ]; then
    python3 - "$ROOT/build/original-host.json" "$HOST_APP" <<'PY_METADATA'
import json
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(json.dumps({"path": str(Path(sys.argv[2]).expanduser().resolve())}, indent=2) + "\n")
PY_METADATA
  fi
  /usr/bin/codesign --force --sign "$CRD_SIGN_IDENTITY" --timestamp=none "$ROOT/build/OverlayAgent"
  echo "Built overlay backend: $ROOT/build/OverlayAgent"
fi
# --- Settings app build and packaging ---

if [ "$BUILD_UI" -eq 1 ]; then
  xcrun swift build --package-path "$ROOT" -c release --product CRDWindowStudio "${SWIFT_ARCH_ARGS[@]}"
  BIN_DIR="$(xcrun swift build --package-path "$ROOT" -c release --show-bin-path "${SWIFT_ARCH_ARGS[@]}")"
  PACKAGE_ARGS=()
  if [ "$BUILD_BACKEND" -eq 1 ]; then PACKAGE_ARGS+=(--include-backend); fi
  python3 "$ROOT/scripts/package.py" "$ROOT" --bin-dir "$BIN_DIR" "${PACKAGE_ARGS[@]}"
  echo "Built settings app: $ROOT/dist/CRD Window Studio.app"
fi
