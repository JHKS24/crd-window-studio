"""Release image fixtures; build, signing and disk-image tools are all mocked."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import package_dmg
import package_source


class DiskImageTests(unittest.TestCase):
    """Check public identity, payload isolation and failures before publishing a release."""

    def setUp(self):
        """Create an isolated bundle and replace every external command with a fixture."""
        temporary = tempfile.TemporaryDirectory(prefix="dmg fixture ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "build").mkdir()
        self.app = self.root / "dist" / package_dmg.APP_NAME
        for binary in package_dmg.executables(self.app):
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(b"universal executable fixture")
        self.info = {"CFBundleShortVersionString": "2.0", "LSMinimumSystemVersion": "14.0",
                     "CRDSigningIdentity": "-"}
        self.write_info()
        self.output = self.root / "release with spaces"
        self.calls = []
        self.architectures = "arm64 x86_64\n"
        self.minimum = "14.0"
        self.signature = "Signature=adhoc\n"
        self.verify_failure = False
        context = patch.object(package_dmg, "run", side_effect=self.tool)
        context.start()
        self.addCleanup(context.stop)

    def write_info(self):
        """Persist the current fixture's bundle metadata."""
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def tool(self, *args, **kwargs):
        """Supply tool results and mimic only the file outputs needed by packaging."""
        self.calls.append((args, kwargs))
        stdout, stderr = "", ""
        if args[0] == "/usr/bin/lipo":
            stdout = self.architectures
        elif args[:2] == ("xcrun", "vtool"):
            stdout = f"platform MACOS\nminos {self.minimum}\nsdk 27.0\n"
        elif args[:2] == ("/usr/bin/codesign", "-d"):
            stderr = self.signature
        elif args[0] == "/usr/bin/ditto":
            shutil.copytree(args[-2], args[-1], symlinks=True)
        elif args[:2] == ("/usr/bin/hdiutil", "create"):
            Path(args[-1]).write_bytes(b"compressed image fixture")
        elif args[:2] == ("/usr/bin/hdiutil", "verify") and self.verify_failure:
            raise subprocess.CalledProcessError(1, args, stderr="image failed verification")
        return subprocess.CompletedProcess(args, 0, stdout, stderr)

    def test_clean_build_forces_public_identity_and_universal_targets(self):
        """A local identity or worker environment cannot leak into the public build."""
        with patch.dict(os.environ, {"CRD_SIGN_IDENTITY": "private fixture identity",
                                    "CODEX_HOME": "worker fixture", "CRD_HOST_APP": "host fixture",
                                    "CRD_WINDOW_CONFIG": "config fixture"}):
            package_dmg.clean_build(self.root)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.calls[0][0], ("xcrun", "swift", "package", "clean"))
        self.assertEqual(self.calls[1][0][-2:], ("--all", "--universal"))
        for _, kwargs in self.calls:
            self.assertEqual(kwargs["env"]["CRD_SIGN_IDENTITY"], "-")
            self.assertFalse({"CODEX_HOME", "CRD_HOST_APP", "CRD_WINDOW_CONFIG"} & kwargs["env"].keys())

    def test_image_contains_only_app_and_applications_and_gets_a_checksum(self):
        """Use the plist version, HFS+/UDZO, a fixed volume name and a verified image checksum."""
        self.info["CFBundleShortVersionString"] = "2.7.1"
        self.write_info()
        result = package_dmg.package_dmg(self.root, self.output)
        image = Path(result["image"])
        self.assertEqual(image.name, "CRD-Window-Studio-2.7.1.dmg")
        stage = Path(result["staging"])
        self.assertEqual({p.name for p in stage.iterdir()}, {package_dmg.APP_NAME, "Applications"})
        self.assertEqual(os.readlink(stage / "Applications"), "/Applications")
        self.assertEqual(Path(result["checksum"]).read_text(),
                         f"{hashlib.sha256(image.read_bytes()).hexdigest()}  {image.name}\n")
        create = next(args for args, _ in self.calls if args[:2] == ("/usr/bin/hdiutil", "create"))
        self.assertEqual(create[create.index("-volname") + 1], "CRD Window Studio")
        self.assertEqual(create[create.index("-format") + 1], "UDZO")
        self.assertEqual(create[create.index("-fs") + 1], "HFS+")
        self.assertEqual(self.calls[-1][0][:2], ("/usr/bin/hdiutil", "verify"))
        for binary in package_dmg.executables(stage / package_dmg.APP_NAME):
            strip = next(i for i, (args, _) in enumerate(self.calls) if args == ("/usr/bin/strip", "-S", binary))
            sign = next(i for i, (args, _) in enumerate(self.calls) if args ==
                        ("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", binary))
            self.assertLess(strip, sign)

    def test_local_signing_identity_is_rejected(self):
        """Never ship an identity that exists only on the build machine."""
        self.info["CRDSigningIdentity"] = "private fixture identity"
        self.write_info()
        with self.assertRaisesRegex(RuntimeError, "CRDSigningIdentity"):
            package_dmg.package_dmg(self.root, self.output)
        self.assertFalse(self.calls)

    def test_single_architecture_is_rejected(self):
        """Require both architectures in each bundled executable."""
        self.architectures = "arm64\n"
        with self.assertRaisesRegex(RuntimeError, "universal"):
            package_dmg.verify_bundle(self.app)

    def test_newer_minimum_os_is_rejected(self):
        """Check deployment commands as well as the bundle's declared minimum."""
        self.minimum = "15.0"
        with self.assertRaisesRegex(RuntimeError, "target macOS 14.0"):
            package_dmg.verify_bundle(self.app)
        self.minimum = "14.0"
        self.info["LSMinimumSystemVersion"] = "15.0"
        self.write_info()
        with self.assertRaisesRegex(RuntimeError, "support macOS 14.0"):
            package_dmg.verify_bundle(self.app)

    def test_non_ad_hoc_executable_is_rejected(self):
        """A public plist cannot disguise an executable signed with a private local identity."""
        self.signature = "Authority=fixture certificate\n"
        with self.assertRaisesRegex(RuntimeError, "ad hoc"):
            package_dmg.verify_bundle(self.app)

    def test_machine_paths_and_local_state_are_rejected(self):
        """Retain staging without making an image when unexpected private content is present."""
        extra = self.app / "Contents/extra.txt"
        extra.write_text(str(self.root))
        with self.assertRaisesRegex(RuntimeError, "Machine path"):
            package_dmg.package_dmg(self.root, self.output)
        self.assertFalse(list(self.output.glob("*.dmg")))
        extra.unlink()
        (self.app / "Contents/.DS_Store").write_bytes(b"local fixture data")
        with self.assertRaisesRegex(RuntimeError, "Local state"):
            package_dmg.check_public_files(self.app, self.root)

    def test_existing_release_and_staging_are_preserved(self):
        """Reruns cannot overwrite a published image or include leftover staging files."""
        self.output.mkdir()
        image = self.output / "CRD-Window-Studio-2.0.dmg"
        image.write_bytes(b"previous release")
        with self.assertRaisesRegex(RuntimeError, "already exists"):
            package_dmg.package_dmg(self.root, self.output)
        self.assertEqual(image.read_bytes(), b"previous release")
        image.unlink()
        stage = self.root / "build/dmg-stage"
        stage.mkdir()
        (stage / "private fixture").write_bytes(b"keep")
        with self.assertRaises(FileExistsError):
            package_dmg.package_dmg(self.root, self.output)
        self.assertEqual((stage / "private fixture").read_bytes(), b"keep")

    def test_failed_image_verification_publishes_no_release_or_checksum(self):
        """A failed image remains partial and inspectable; no success checksum is written."""
        self.verify_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            package_dmg.package_dmg(self.root, self.output)
        self.assertTrue((self.output / "CRD-Window-Studio-2.0.partial.dmg").exists())
        self.assertFalse((self.output / "CRD-Window-Studio-2.0.dmg").exists())
        self.assertFalse(list(self.output.glob("*.sha256")))

    def test_version_cannot_escape_the_output_directory(self):
        """Reject a filename path supplied in place of a version."""
        self.info["CFBundleShortVersionString"] = "../../elsewhere"
        self.write_info()
        with self.assertRaisesRegex(RuntimeError, "version"):
            package_dmg.verify_bundle(self.app)

    def test_source_export_contains_release_script_and_tests(self):
        """A clean public tree can build and test its DMG without private files."""
        payload = package_source.public_payload()
        self.assertIn("scripts/package_dmg.py", payload)
        self.assertIn("tests/test_package_dmg.py", payload)


if __name__ == "__main__":
    unittest.main()
