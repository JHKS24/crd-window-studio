#!/usr/bin/env python3
"""Export declared public sources, notices and artwork without local state/history."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DIRECT_FILES = (
    "Package.swift", "README.md", "README.ko.md", "BUILDING.md", "BUILDING.ko.md",
    "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "CONTRIBUTING.md", "SECURITY.md",
    "CHANGELOG.md", ".gitignore", "script/build_and_run.sh", "config/custom.json",
    "scripts/build.sh", "scripts/package.py", "scripts/package_source.py",
    "scripts/companionctl.py", "scripts/file_operations.py", "scripts/generate_schema.py", "scripts/measure_resources.py",
    "scripts/generate_localizations.py", "backend/OverlayMain.mm",
    "tests/test_companionctl.py", "tests/test_generate_localizations.py", "tests/test_package.py",
    "assets/AppIcon.png", "assets/README.md", "reference/LICENSE", "reference/README.md",
    "reference/agent_process_broker.cc", "reference/disconnect_window_base.cc",
    "reference/disconnect_window_mac.h", "reference/disconnect_window_mac.mm",
    "reference/host_main.cc", "reference/host_main.h", "reference/host_service_main.cc",
    "reference/host_window.h", "reference/remoting_me2me_host.cc",
)
TREES = {
    "Sources": {".swift", ".json"},
    "Tests/CRDSettingsCoreTests": {".swift"},
    "Tests/CRDWindowStudioTests": {".swift"},
    "generated": {".h"},
    "docs": {".md"},
}
WINDOWS_FILES = (
    "README.md", "README.ko.md", "CMakeLists.txt", "build.ps1",
    "src/WindowProbe.cpp", "schema/SettingsSchema.json",
)
PRIVATE_MARKERS = (
    re.compile(r"/Users/[A-Za-z0-9_.-]+"),
    re.compile(r"[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+"),
    re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"),
    re.compile(r"\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]{20,}\b"),
)


# --- Declared source payload and manifest ---

def source_files(windows=False):
    """Map archive-relative names to explicit source files; no generated icons."""
    if windows:
        files = {name: ROOT / "windows" / name for name in WINDOWS_FILES}
        files.update({name: ROOT / name for name in ("LICENSE", "NOTICE")})
    else:
        files = {name: ROOT / name for name in DIRECT_FILES}
        for directory, suffixes in TREES.items():
            for path in (ROOT / directory).rglob("*"):
                if path.is_file() and path.suffix in suffixes:
                    files[path.relative_to(ROOT).as_posix()] = path
        files.update({"windows/" + name: ROOT / "windows" / name for name in WINDOWS_FILES})
    for name, path in files.items():
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(ROOT.resolve()):
            raise RuntimeError(f"Missing, symlinked, or external source: {name}")
    return dict(sorted(files.items()))


def public_payload(windows=False):
    """Validate declared files and return their bytes, modes and a source hash manifest."""
    payload = {}
    manifest = {"formatVersion": 1, "project": "CRD Window Studio", "target": "windows-diagnostic" if windows else "full-source", "files": {}}
    for name, path in source_files(windows).items():
        data = path.read_bytes()
        if path.suffix != ".png":
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError as error:
                raise RuntimeError(f"Unexpected binary source: {name}") from error
            if any(pattern.search(text) for pattern in PRIVATE_MARKERS):
                raise RuntimeError(f"Review private-path or credential marker in: {name}")
        elif not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError(f"Invalid PNG asset: {name}")
        mode = 0o755 if os.access(path, os.X_OK) else 0o644
        payload[name] = (data, mode)
        manifest["files"][name] = {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "executable": mode == 0o755}
    payload["SOURCE-MANIFEST.json"] = ((json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode(), 0o644)
    return payload


# --- Atomic directory and ZIP exports ---

def write_directory(destination, payload):
    """Publish the complete payload through a staged directory without overwriting an existing export."""
    if destination.exists():
        raise RuntimeError("Export directory already exists; choose a new path.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="public-export-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "source"
        staged.mkdir()
        for name, (data, mode) in payload.items():
            path = staged / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            path.chmod(mode)
        staged.rename(destination)


def main():
    """Export a deterministic ZIP and, optionally, a new source directory for the selected target."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--windows", action="store_true", help="Export only the standalone Windows diagnostic.")
    parser.add_argument("--output", type=Path, help="Override output ZIP path.")
    parser.add_argument("--directory", type=Path, help="Also write a new clean directory; never overwrite an existing directory.")
    args = parser.parse_args()
    archive_root = "CRDWindow-Windows-Diagnostics-Source" if args.windows else "CRDWindowStudio-Source"
    output = (args.output or ROOT / "dist" / (archive_root + ".zip")).expanduser().resolve()
    payload = public_payload(args.windows)
    if args.directory:
        write_directory(args.directory.expanduser().resolve(), payload)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix="source-", suffix=".zip", dir=output.parent, delete=False) as temporary:
        pending = Path(temporary.name)
    try:
        with zipfile.ZipFile(pending, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name, (data, mode) in payload.items():
                info = zipfile.ZipInfo(f"{archive_root}/{name}", date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | mode) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        pending.replace(output)
    finally:
        pending.unlink(missing_ok=True)
    print(json.dumps({"archive": str(output), "files": len(payload), "bytes": output.stat().st_size,
                      "sha256": hashlib.sha256(output.read_bytes()).hexdigest()}, indent=2))


if __name__ == "__main__":
    main()
