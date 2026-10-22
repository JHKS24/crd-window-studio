#!/usr/bin/env python3
"""Package a SwiftPM settings executable as an independently runnable macOS app."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

from file_operations import replace_bundle


# --- Packaging tools and artwork ---

def run(*args):
    """Run a packaging tool, suppressing routine sips output and raising on failure."""
    subprocess.run([str(arg) for arg in args], check=True,
                   stdout=subprocess.DEVNULL if args[0] == "/usr/bin/sips" else None)


def make_icon(root: Path) -> Path:
    """Resize the declared PNG into the required icon sizes and assemble an ICNS file."""
    png = root / "assets/AppIcon.png"
    if not png.is_file():
        raise RuntimeError(f"App icon is missing: {png}")
    icon = root / "build/AppIcon.icns"
    icon.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="icon-", dir=root / "build") as temporary:
        iconset = Path(temporary) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                suffix = "@2x" if scale == 2 else ""
                run("/usr/bin/sips", "-z", pixels, pixels, png, "--out",
                    iconset / f"icon_{points}x{points}{suffix}.png")
        run("/usr/bin/iconutil", "-c", "icns", iconset, "-o", icon)
    return icon


# --- Signed settings bundle ---

def package(root: Path, bin_dir: Path, include_backend=False):
    """Assemble and sign a settings bundle, then replace the destination while retaining recovery copies."""
    executable = bin_dir / "CRDWindowStudio"
    if not executable.is_file():
        raise RuntimeError(f"Build the settings executable first: {executable}")
    icon = make_icon(root)
    destination = root / "dist/CRD Window Studio.app"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="studio-package-", dir=root / "build") as temporary:
        app = Path(temporary) / destination.name
        contents = app / "Contents"
        macos = contents / "MacOS"
        resources = contents / "Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(executable, macos / "CRDWindowStudio")
        shutil.copy2(root / "Sources/CRDSettingsCore/Resources/SettingsSchema.json", resources)
        shutil.copytree(root / "Sources/CRDSettingsCore/Resources/Localization", resources / "Localization")
        for language, display_name in (("ko", "CRD 공유 창 설정"), ("en", "CRD Window Studio")):
            localized = resources / f"{language}.lproj"
            localized.mkdir()
            (localized / "InfoPlist.strings").write_text(
                f'"CFBundleDisplayName" = "{display_name}";\n"CFBundleName" = "CRD Window Studio";\n'
            )
        shutil.copy2(icon, resources / "AppIcon.icns")
        legal = resources / "Licenses"
        for relative in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "reference/LICENSE", "reference/README.md", "assets/README.md"):
            target = legal / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / relative, target)
        backend = resources / "Backend"
        backend.mkdir()
        shutil.copy2(root / "scripts/companionctl.py", backend / "companionctl.py")
        shutil.copy2(root / "scripts/file_operations.py", backend / "file_operations.py")
        companion = root / "build/OverlayAgent"
        if include_backend:
            if not companion.is_file():
                raise RuntimeError("The requested backend is missing; build with --all.")
            architectures = lambda path: set(subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split())
            if architectures(companion) != architectures(executable):
                raise RuntimeError("Settings and helper architectures differ; build both with --all.")
            shutil.copy2(companion, backend / "OverlayAgent")
        # Keep SwiftPM resources available as well as the direct schema resource.
        for bundle in bin_dir.glob("*.bundle"):
            shutil.copytree(bundle, resources / bundle.name)
        info = dict(CFBundleExecutable="CRDWindowStudio",
                    CFBundleIdentifier="local.crdwindow.studio",
                    CFBundleName="CRD Window Studio", CFBundleDisplayName="CRD Window Studio",
                    CFBundleDevelopmentRegion="en", CFBundleLocalizations=["en", "ko"],
                    CFBundlePackageType="APPL", CFBundleVersion="2",
                    CFBundleShortVersionString="2.0", CFBundleIconFile="AppIcon",
                    CFBundleIconName="AppIcon", NSPrincipalClass="NSApplication",
                    LSMinimumSystemVersion="14.0", NSHighResolutionCapable=True,
                    CRDSigningIdentity=os.environ.get("CRD_SIGN_IDENTITY", "-"))
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        (contents / "PkgInfo").write_bytes(b"APPL????")
        # Sign and verify the staged result before replacing a usable bundle.
        run("/usr/bin/codesign", "--force", "--sign", info["CRDSigningIdentity"], "--timestamp=none", app)
        run("/usr/bin/codesign", "--verify", "--strict", app)
        replace_bundle(app, destination, root / "build" / f"previous-studio-{time.time_ns()}.app")
    print(destination)


# --- Command-line entry ---

def main():
    """Package the selected Swift build with an optional matching native helper."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--include-backend", action="store_true", help="Include an explicitly built helper of matching architecture.")
    args = parser.parse_args()
    package(args.root.resolve(), args.bin_dir.resolve(), args.include_backend)


if __name__ == "__main__":
    main()
