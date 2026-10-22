"""Packaging fixtures: no external tools, installed applications or host access."""
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "scripts"))
import file_operations


class PackageTests(unittest.TestCase):
    """Exercise packaging and source exports with isolated files and mocked build tools."""
    # --- Packaging fixtures and recoverable replacement ---

    def setUp(self):
        """Create a settings bundle fixture and mock icon, architecture, signing and Trash operations."""
        spec = importlib.util.spec_from_file_location("package_fixture", PROJECT / "scripts/package.py")
        self.package = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.package)
        temporary = tempfile.TemporaryDirectory(prefix="package-fixture-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin with spaces"
        self.bin.mkdir()
        (self.bin / "CRDWindowStudio").write_bytes(b"fixture executable")
        (self.root / "build").mkdir()
        self.icon = self.root / "build/AppIcon.icns"
        self.icon.write_bytes(b"fixture icon")
        for relative in ("Sources/CRDSettingsCore/Resources/SettingsSchema.json",
                         "Sources/CRDSettingsCore/Resources/Localization/en.json",
                         "Sources/CRDSettingsCore/Resources/Localization/ko.json",
                         "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md",
                         "reference/LICENSE", "reference/README.md", "assets/README.md",
                         "scripts/companionctl.py", "scripts/file_operations.py"):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((PROJECT / relative).read_bytes())
        (self.root / "build/OverlayAgent").write_bytes(b"stale fixture helper")
        self.app = self.root / "dist/CRD Window Studio.app"
        self.calls = []
        for context in (patch.object(self.package, "make_icon", return_value=self.icon),
                        patch.object(self.package, "run", side_effect=lambda *args: self.calls.append(args)),
                        patch.object(self.package.subprocess, "check_output", return_value="arm64\n"),
                        patch.object(file_operations, "trash", side_effect=AssertionError("real Trash forbidden")),
                        patch.dict(self.package.os.environ, {"CRD_SIGN_IDENTITY": "-"})):
            context.start()
            self.addCleanup(context.stop)

    def test_ui_only_omits_stale_helper_and_records_ad_hoc_default(self):
        """Check that UI-only packaging excludes stale helpers and records the default signer."""
        self.package.package(self.root, self.bin)
        self.assertFalse((self.app / "Contents/Resources/Backend/OverlayAgent").exists())
        info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CRDSigningIdentity"], "-")
        schema = json.loads((self.app / "Contents/Resources/SettingsSchema.json").read_bytes())
        self.assertEqual(schema["defaults"]["mode"], "custom")
        self.assertTrue(any("--verify" in call for call in self.calls))
        self.assertTrue((self.app / "Contents/Resources/Backend/file_operations.py").is_file())

    def test_rebuild_without_trash_executable_publishes_before_retiring_old_bundle(self):
        """Check that replacement preserves the old bundle without needing a Trash executable."""
        self.app.mkdir(parents=True)
        (self.app / "previous").write_text("old bundle")
        retired = self.root / "mock Trash.app"

        def move_to_trash(path):
            """Verify the new bundle is published before moving the old fixture to mock Trash."""
            self.assertTrue((self.app / "Contents/MacOS/CRDWindowStudio").is_file())
            self.assertEqual((path / "previous").read_text(), "old bundle")
            path.rename(retired)

        # Any attempted subprocess (including a missing /usr/bin/trash) fails.
        with patch.object(self.package.subprocess, "run", side_effect=FileNotFoundError("tool missing")), \
                patch.object(file_operations, "trash", side_effect=move_to_trash):
            self.package.package(self.root, self.bin)
        self.assertTrue((retired / "previous").is_file())

    def test_bundled_controller_import_does_not_write_inside_signed_app(self):
        """Check that importing the packaged controller leaves its signed bundle bytes unchanged."""
        self.package.package(self.root, self.bin)
        backend = self.app / "Contents/Resources/Backend"
        script = backend / "companionctl.py"
        before = {p.relative_to(self.app): p.read_bytes() for p in self.app.rglob("*") if p.is_file()}
        with patch.dict(sys.modules), patch.object(sys, "dont_write_bytecode", False), \
                patch.object(sys, "path", [str(backend)] + sys.path), \
                patch.object(sys, "argv", [str(script), "--help"]), patch.object(sys, "stdout", io.StringIO()), \
                patch.object(self.package.subprocess, "run", side_effect=AssertionError("no commands during import")):
            sys.modules.pop("file_operations", None)
            with self.assertRaises(SystemExit) as result:
                runpy.run_path(str(script), run_name="__main__")
            self.assertEqual(result.exception.code, 0)
            self.assertEqual(Path(sys.modules["file_operations"].__file__), backend / "file_operations.py")
        after = {p.relative_to(self.app): p.read_bytes() for p in self.app.rglob("*") if p.is_file()}
        self.assertEqual(after, before)
        self.assertFalse((backend / "__pycache__").exists())

    def test_trash_failure_keeps_replaced_bundle_and_new_bundle(self):
        """Check that Trash failure preserves the replaced bundle and usable replacement."""
        self.app.mkdir(parents=True)
        (self.app / "previous").write_text("old bundle")
        with patch.object(file_operations, "trash", side_effect=OSError("Trash unavailable")) as move:
            with self.assertRaisesRegex(OSError, "Trash unavailable"):
                self.package.package(self.root, self.bin)
        self.assertEqual((move.call_args.args[0] / "previous").read_text(), "old bundle")
        self.assertTrue((self.app / "Contents/MacOS/CRDWindowStudio").is_file())

    def test_publish_failure_restores_previous_destination(self):
        """Check rollback of the destination when staged bundle publication fails."""
        self.app.mkdir(parents=True)
        (self.app / "previous").write_text("old bundle")
        with self.assertRaises(FileNotFoundError):
            file_operations.replace_bundle(self.root / "missing.app", self.app, self.root / "old.app")
        self.assertEqual((self.app / "previous").read_text(), "old bundle")

    # --- Declared source exports ---

    def test_both_source_exports_use_the_canonical_schema(self):
        """Check that full and Windows source exports carry the canonical schema bytes."""
        spec = importlib.util.spec_from_file_location("source_package_fixture", PROJECT / "scripts/package_source.py")
        source = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(source)
        canonical = (PROJECT / "Sources/CRDSettingsCore/Resources/SettingsSchema.json").read_bytes()
        self.assertEqual(source.public_payload()["windows/schema/SettingsSchema.json"][0], canonical)
        self.assertEqual(source.public_payload(windows=True)["schema/SettingsSchema.json"][0], canonical)

    def test_source_export_has_only_the_custom_example_even_with_leftover_hidden_file(self):
        """Check that undeclared local examples cannot enter the source payload or manifest."""
        spec = importlib.util.spec_from_file_location("source_package_fixture", PROJECT / "scripts/package_source.py")
        source = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(source)
        payload = source.public_payload()
        self.assertEqual({name for name in payload if name.startswith("config/")}, {"config/custom.json"})
        self.assertIn("scripts/file_operations.py", payload)
        manifest = json.loads(payload["SOURCE-MANIFEST.json"][0])
        self.assertNotIn("config/hidden.json", manifest["files"])
        # Undeclared local examples must not enter the public export.
        export_root = self.root / "export-input"
        for name, (data, _) in payload.items():
            path = export_root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (export_root / "config/hidden.json").write_text('{"mode":"hidden"}')
        with patch.object(source, "ROOT", export_root):
            self.assertNotIn("config/hidden.json", source.public_payload())

    # --- Backend and signing contracts ---

    def test_explicit_backend_and_selected_signer_are_packaged(self):
        """Check that requested backend inclusion and signer metadata reach the bundle."""
        with patch.dict(self.package.os.environ, {"CRD_SIGN_IDENTITY": "Fixture Local Signing"}):
            self.package.package(self.root, self.bin, include_backend=True)
        self.assertTrue((self.app / "Contents/Resources/Backend/OverlayAgent").exists())
        info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CRDSigningIdentity"], "Fixture Local Signing")
        sign = next(call for call in self.calls if "--sign" in call)
        self.assertEqual(sign[sign.index("--sign") + 1], "Fixture Local Signing")

    def test_mismatched_architectures_are_rejected(self):
        """Check that incompatible settings and helper architectures prevent publication."""
        with patch.object(self.package.subprocess, "check_output", side_effect=["arm64\n", "arm64 x86_64\n"]):
            with self.assertRaisesRegex(RuntimeError, "architectures differ"):
                self.package.package(self.root, self.bin, include_backend=True)
        self.assertFalse(self.app.exists())

    def test_failed_signing_preserves_previous_bundle(self):
        """Check that signing failure preserves the usable destination without retrying another signer."""
        self.app.mkdir(parents=True)
        sentinel = self.app / "previous"
        sentinel.write_text("preserve")
        with patch.object(self.package, "run", side_effect=RuntimeError("requested signer unavailable")) as run:
            with self.assertRaisesRegex(RuntimeError, "signer unavailable"):
                self.package.package(self.root, self.bin)
        self.assertEqual(sentinel.read_text(), "preserve")
        self.assertEqual(run.call_count, 1)
