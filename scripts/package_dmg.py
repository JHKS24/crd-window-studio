#!/usr/bin/env python3
"""Build a universal, ad hoc signed release DMG without installing or launching it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "CRD Window Studio.app"
VOLUME_NAME = "CRD Window Studio"


# --- Public build and payload checks ---

def run(*args, **kwargs):
    """Run a packaging tool without a shell and return its captured output."""
    return subprocess.run([str(arg) for arg in args], check=True, text=True,
                          capture_output=True, **kwargs)


def clean_build(root):
    """Rebuild both architectures in the worktree's usual build folders with the public signer."""
    environment = os.environ.copy()
    for key in ("CODEX_HOME", "CRD_HOST_APP", "CRD_WINDOW_CONFIG"):
        environment.pop(key, None)
    environment["CRD_SIGN_IDENTITY"] = "-"
    for command in (("xcrun", "swift", "package", "clean"),
                    ("bash", root / "scripts/build.sh", "--all", "--universal")):
        result = run(*command, cwd=root, env=environment)
        print(result.stdout, end="", file=sys.stderr)
        print(result.stderr, end="", file=sys.stderr)


def executables(app):
    """Locate the settings executable and the helper shipped for GUI-driven preparation."""
    return (app / "Contents/MacOS/CRDWindowStudio",
            app / "Contents/Resources/Backend/OverlayAgent")


def verify_bundle(app):
    """Require a public signer, universal executables and a macOS 14 deployment target."""
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
        raise RuntimeError("The bundle version must be a dotted numeric release version.")
    if info.get("CRDSigningIdentity") != "-":
        raise RuntimeError("The public bundle must record CRDSigningIdentity=-.")
    if info.get("LSMinimumSystemVersion") != "14.0":
        raise RuntimeError("The public bundle must support macOS 14.0.")
    for binary in executables(app):
        if set(run("/usr/bin/lipo", "-archs", binary).stdout.split()) != {"arm64", "x86_64"}:
            raise RuntimeError(f"The release executable must be universal: {binary.name}")
        for architecture in ("arm64", "x86_64"):
            output = run("xcrun", "vtool", "-arch", architecture, "-show-build", binary).stdout
            if re.findall(r"\bminos\s+(\S+)", output) != ["14.0"]:
                raise RuntimeError(f"The release executable must target macOS 14.0: {binary.name}")
        signature = run("/usr/bin/codesign", "-d", "--verbose=4", binary)
        if "Signature=adhoc" not in signature.stderr.splitlines():
            raise RuntimeError(f"The public executable must be ad hoc signed: {binary.name}")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    return version


def check_public_files(app, root):
    """Reject local state, external symlinks and machine paths without printing their contents."""
    private_paths = {str(root.absolute()).encode(), str(root.resolve()).encode(), str(Path.home()).encode()}
    forbidden = {".DS_Store", "__pycache__", "config.json", "presets.json", "logs", "runtime-status.json"}
    for path in app.rglob("*"):
        if path.name in forbidden or path.suffix == ".pyc":
            raise RuntimeError("Local state found in the release bundle.")
        if path.is_symlink() and not path.resolve().is_relative_to(app.resolve()):
            raise RuntimeError("External symlink found in the release bundle.")
        if path.is_file():
            data = path.read_bytes()
            if any(marker in data for marker in private_paths):
                raise RuntimeError("Machine path found in the release bundle.")


# --- Disk image and checksum ---

def package_dmg(root, output_directory):
    """Stage only the app and Applications link, verify a compressed image, then publish its checksum.

    Staging and failed partial images are retained for inspection. Move build/dmg-stage to the
    Trash before another run. Existing release files are never replaced.
    """
    source = root / "dist" / APP_NAME
    version = verify_bundle(source)
    output_directory.mkdir(parents=True, exist_ok=True)
    image = output_directory / f"CRD-Window-Studio-{version}.dmg"
    checksum = image.with_suffix(".dmg.sha256")
    pending = image.with_suffix(".partial.dmg")
    if any(path.exists() for path in (image, checksum, pending)):
        raise RuntimeError("A release or partial image already exists; move it aside first.")
    stage = root / "build/dmg-stage"
    stage.mkdir()  # Refuse leftover content instead of including it in a release.
    app = stage / APP_NAME
    run("/usr/bin/ditto", "--norsrc", "--noextattr", "--noqtn", "--noacl", source, app)
    # Swift's linked debug symbols contain object-file paths. Strip those symbols, then sign
    # the changed executables and their containing app again with the public identity.
    for binary in executables(app):
        run("/usr/bin/strip", "-S", binary)
        run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", binary)
    run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", app)
    verify_bundle(app)
    check_public_files(app, root)
    (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
    run("/usr/bin/hdiutil", "create", "-volname", VOLUME_NAME, "-srcfolder", stage,
        "-fs", "HFS+", "-format", "UDZO", pending)
    run("/usr/bin/hdiutil", "verify", pending)
    pending.rename(image)
    digest = hashlib.sha256()
    with image.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    checksum.write_text(f"{digest.hexdigest()}  {image.name}\n")
    return {"image": str(image), "sha256": digest.hexdigest(), "checksum": str(checksum),
            "staging": str(stage)}


def main():
    """Create a release image from a clean universal build, without publishing it."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args()
    try:
        clean_build(ROOT)
        print(json.dumps(package_dmg(ROOT, args.output_directory.expanduser().resolve()), indent=2))
    except subprocess.CalledProcessError as error:
        parser.exit(1, f"Packaging tool failed ({error.returncode}): {error.stderr}\n")
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        parser.exit(1, f"Packaging failed: {error}\n")


if __name__ == "__main__":
    main()
