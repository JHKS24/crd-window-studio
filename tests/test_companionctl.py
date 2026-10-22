"""External-overlay lifecycle tests; all jobs, signatures, PIDs and permissions are mocked.

Run: python3 -m unittest discover -s tests -p 'test_*.py'
No original Google service, real process, launchd job or TCC setting is touched.
"""
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "scripts"))


class CompanionSafetyTests(unittest.TestCase):
    """Exercise helper lifecycle and recovery with isolated files and mocked system operations."""
    # --- Isolated files and system mocks ---

    def setUp(self):
        """Create isolated host and helper fixtures and block real commands and process signals."""
        spec = importlib.util.spec_from_file_location("companionctl_under_test", PROJECT / "scripts/companionctl.py")
        self.controller = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.controller)
        self.temporary = tempfile.TemporaryDirectory(prefix="overlay-safety-")
        self.addCleanup(self.temporary.cleanup)
        base = Path(self.temporary.name)
        c = self.controller
        c.ROOT = base / "project"
        c.SUPPORT = base / "user/Library/Application Support/CRDWindowPatch"
        c.INSTALLED = c.SUPPORT / "CRD Window Host.app"
        c.STAGE = c.ROOT / "dist/CRD Window Host.app"
        c.RECEIPT = c.SUPPORT / "companion-install.json"
        c.AGENT = base / "user/Library/LaunchAgents/local.crdwindow.host.plist"
        c.BINARY = c.ROOT / "build/OverlayAgent"
        c.DOMAIN = "gui/12345"
        c.BINARY.parent.mkdir(parents=True)
        c.BINARY.write_bytes(b"own overlay fixture; never executed")
        for relative in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "reference/LICENSE", "reference/README.md", "assets/README.md"):
            target = c.ROOT / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((PROJECT / relative).read_bytes())
        c.SUPPORT.mkdir(parents=True)
        self.original = base / "vendor/ChromeRemoteDesktopHost.app"
        (self.original / "Contents/MacOS").mkdir(parents=True)
        (self.original / "Contents/MacOS/remoting_me2me_host").write_bytes(b"untouched Google executable")
        self.original_hashes = self.vendor_hashes()
        self.snapshot = {"path": str(self.original), "version": "test-version", "hashes": self.original_hashes}
        self.calls = []
        self.trashed = []
        self.start_patch(c.file_operations, "trash", side_effect=self.fake_trash)
        self.services = {c.ORIGINAL_LABEL: {"loaded": True, "pid": 111}, c.LABEL: {"loaded": False, "pid": None}}
        self.fail_overlay_bootstrap = False
        # Any missed mock fails before an external command or process signal.
        self.start_patch(c.subprocess, "run", side_effect=AssertionError("real subprocess forbidden"))
        self.start_patch(c.os, "kill", side_effect=AssertionError("real process signal forbidden"))
        self.real_command = c.command
        self.start_patch(c, "command", side_effect=self.fake_command)
        self.start_patch(c, "current_user")
        self.start_patch(c, "host_path", return_value=self.original)
        self.real_verify_original = c.verify_original
        self.start_patch(c, "verify_original", return_value=self.snapshot)
        self.real_settings_candidates = c.settings_app_candidates
        self.start_patch(c, "settings_app_candidates", return_value=[])

    def start_patch(self, target, name, **options):
        """Install a mock and register its cleanup with the test case."""
        context = patch.object(target, name, **options)
        result = context.start()
        self.addCleanup(context.stop)
        return result

    def vendor_hashes(self):
        return {p.name: self.controller.digest(p) for p in (self.original / "Contents/MacOS").iterdir() if p.is_file()}

    def fake_trash(self, path):
        """Move fixture files into a temporary Trash while rejecting active recovery paths."""
        c = self.controller
        self.assertNotIn(path, (c.INSTALLED, c.AGENT, c.runtime_path("restore-state.json")))
        self.assertIn(Path(self.temporary.name), path.parents)
        destination = Path(self.temporary.name) / "mock-trash" / f"{len(self.trashed)}-{path.name}"
        destination.parent.mkdir(exist_ok=True)
        path.rename(destination)
        self.trashed.append(path)

    def fake_command(self, *args, **options):
        """Simulate signatures, launchd and process queries; reject changes to foreign jobs."""
        args = tuple(str(arg) for arg in args)
        self.calls.append(args)
        c = self.controller
        if args[:4] == ("/usr/bin/codesign", "-d", "-r", "-"):
            return subprocess.CompletedProcess(args, 0, "", 'designated => identifier "local.crdwindow.host" and certificate leaf = H"0000000000000000000000000000000000000000"\n')
        if args[0] == "/bin/launchctl":
            action = args[1]
            if action == "print":
                label = args[-1].rsplit("/", 1)[-1]
                state = self.services.get(label, {"loaded": False, "pid": None})
                text = f"pid = {state['pid']}\n" if state["pid"] else ""
                return subprocess.CompletedProcess(args, 0 if state["loaded"] else 3, text, "")
            label = (plistlib.loads(Path(args[-1]).read_bytes())["Label"] if action == "bootstrap"
                     else args[-1].rsplit("/", 1)[-1])
            if label not in (c.LABEL, c.PERMISSION_LABEL, c.RESTORE_LABEL):
                raise AssertionError("Google/foreign LaunchAgent mutation is forbidden: " + repr(args))
            if action == "bootstrap":
                if label == c.LABEL and self.fail_overlay_bootstrap:
                    raise RuntimeError("simulated overlay bootstrap failure")
                self.services[label] = {"loaded": True, "pid": 222}
                if label == c.LABEL:
                    c.write_json(c.runtime_path("restore-state.json"), {"pending": False})
            elif action == "bootout":
                self.services[label] = {"loaded": False, "pid": None}
        if args[0] == "/bin/ps":
            if args[1] == "-p":
                return subprocess.CompletedProcess(args, 1, "", "")
            if args[-1] == "uid=,pid=,comm=":
                text = f"{c.os.getuid()} 111 {self.original}/Contents/MacOS/remoting_me2me_host\n"
            else:
                pid = self.services[c.LABEL]["pid"]
                text = f"{pid} {c.INSTALLED}/Contents/MacOS/{c.EXECUTABLE}\n" if pid else ""
            return subprocess.CompletedProcess(args, 0, text, "")
        return subprocess.CompletedProcess(args, 0, "", "")

    def mutations(self):
        return [args for args in self.calls if args[0] == "/bin/launchctl" and args[1] != "print"]

    def assert_google_untouched(self):
        """Require the original service, executable bytes and mutation boundary to remain intact."""
        c = self.controller
        self.assertEqual(self.services[c.ORIGINAL_LABEL], {"loaded": True, "pid": 111})
        self.assertEqual(self.vendor_hashes(), self.original_hashes)
        self.assertFalse(any(c.ORIGINAL_LABEL in arg for call in self.mutations() for arg in call))

    def make_installed(self, protocol, data=b"previous signed overlay"):
        """Create a helper bundle fixture with the requested protocol metadata and executable bytes."""
        c = self.controller
        executable = c.INSTALLED / "Contents/MacOS" / (c.EXECUTABLE if protocol == 3 else "remoting_me2me_host")
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_bytes(data)
        (c.INSTALLED / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CRDCompanionProtocolVersion": protocol, "CRDBackendKind": c.BACKEND_KIND if protocol == 3 else "legacy",
            "CRDLauncherSourceSHA256": c.digest(c.BINARY),
        }))
        return executable

    def ready(self, *args, **kwargs):
        """Return a helper-ready fixture that does not claim a detected sharing window."""
        return {"confirmed": True, "pid": 222, "backendKind": self.controller.BACKEND_KIND,
                "agentReady": True, "observerReady": True, "originalWindowDetected": False}

    # --- Command errors and permission boundaries ---

    def test_ax_denial_does_not_change_any_host_service(self):
        """Check that permission denial rolls back without changing any host service."""
        c = self.controller
        with patch.object(c, "permission_status", return_value={"accessibility": False}) as probe:
            with self.assertRaisesRegex(RuntimeError, "손쉬운 사용"):
                c.install()
            probe.assert_called_once_with(c.INSTALLED)
        self.assertEqual(self.mutations(), [])
        self.assertEqual(c.read_json(c.RECEIPT)["state"], "rolled_back")
        self.assert_google_untouched()

    def test_install_cli_reports_permission_code_and_cleanup_codes_as_json(self):
        """Check that permission and cleanup failures remain separate machine-readable errors."""
        c = self.controller
        for cleanup_fails in (False, True):
            with self.subTest(cleanup_fails=cleanup_fails):
                c.RECEIPT.unlink(missing_ok=True)
                stdout, stderr = io.StringIO(), io.StringIO()
                failure = c.CompanionError("restoration_unconfirmed", "fixture cleanup") if cleanup_fails else None
                with patch.object(c, "permission_status", return_value={"accessibility": False}), \
                     patch.object(c, "stop_companion", side_effect=failure), \
                     patch.object(c.sys, "argv", ["companionctl.py", "install"]), \
                     patch.object(c.sys, "stdout", stdout), patch.object(c.sys, "stderr", stderr):
                    self.assertEqual(c.main(), 1)
                result = json.loads(stderr.getvalue())
                self.assertEqual(result["error"], "accessibility_required")
                self.assertNotIn('{"accessibility"', result["message"])
                self.assertEqual(stdout.getvalue(), "")
                status = c.status()
                self.assertEqual(status["errorCode"], "accessibility_required")
                self.assertEqual(status["state"], "cleanup_failed" if cleanup_fails else "rolled_back")
                self.assertEqual(status["cleanupErrorCode"], "restoration_unconfirmed" if cleanup_fails else None)
        self.assert_google_untouched()

    def test_cli_argument_errors_are_json_without_running_an_action(self):
        """Check that invalid arguments return JSON before any system command runs."""
        c = self.controller
        stderr = io.StringIO()
        with patch.object(c.sys, "argv", ["companionctl.py", "unknown"]), patch.object(c.sys, "stderr", stderr):
            with self.assertRaises(SystemExit) as failure:
                c.main()
        self.assertEqual(failure.exception.code, 2)
        self.assertEqual(json.loads(stderr.getvalue())["error"], "invalid_arguments")
        self.assertEqual(self.calls, [])

    def test_permissions_cli_prompt_is_opt_in_and_preserves_result(self):
        """Check CLI forwarding of explicit prompt requests and host paths containing spaces."""
        c = self.controller
        host = c.ROOT / "host with spaces.app"
        result = {"accessibility": False, "pid": 333, "bundleId": c.LABEL,
                  "executionContext": "independent per-user launchd job",
                  "companionProtocolVersion": 3, "backendKind": c.BACKEND_KIND,
                  "identityLayoutUpgradeDeferred": False}
        for prompt in (False, True):
            with self.subTest(prompt=prompt):
                stdout, stderr = io.StringIO(), io.StringIO()
                args = ["companionctl.py", "permissions", "--json", "--host-app", str(host)]
                if prompt:
                    args.append("--prompt")
                with patch.object(c, "permissions", return_value=result) as permissions, \
                     patch.object(c.sys, "argv", args), patch.object(c.sys, "stdout", stdout), \
                     patch.object(c.sys, "stderr", stderr):
                    self.assertEqual(c.main(), 0)
                permissions.assert_called_once_with(host, prompt=prompt)
                self.assertEqual(json.loads(stdout.getvalue()), result)
                self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(self.calls, [])

    def test_prompt_rejects_other_actions_and_abbreviations_before_execution(self):
        """Check that prompt flags cannot trigger unrelated actions or abbreviated options."""
        c = self.controller
        cases = [[action, "--prompt"] for action in ("prepare", "status", "install", "restore", "restart")]
        cases += [["permissions", flag] for flag in ("--p", "--prom")]
        for args in cases:
            with self.subTest(args=args):
                stderr = io.StringIO()
                with patch.object(c.sys, "argv", ["companionctl.py"] + args), patch.object(c.sys, "stderr", stderr):
                    with self.assertRaises(SystemExit) as failure:
                        c.main()
                self.assertEqual(failure.exception.code, 2)
                self.assertEqual(json.loads(stderr.getvalue())["error"], "invalid_arguments")
        self.assertEqual(self.calls, [])

    def test_error_codes_cover_command_timeout_io_and_unexpected_failures(self):
        """Check stable error classification for timeouts, file failures and command failures."""
        c = self.controller
        for failure, code in [
            (TimeoutError("deadline"), "command_timeout"),
            (subprocess.TimeoutExpired("fixture", 1), "command_timeout"),
            (PermissionError("fixture"), "file_access_denied"),
            (FileNotFoundError("fixture"), "file_not_found"),
            (OSError("fixture"), "file_io_failed"),
            (ValueError("fixture"), "invalid_data"),
            (plistlib.InvalidFileException("fixture"), "invalid_data"),
            (RuntimeError("fixture"), "operation_failed"),
        ]:
            with self.subTest(code=code, failure=type(failure).__name__):
                self.assertEqual(c.error_payload(failure), {"error": code, "message": str(failure)})
        for code in ("command_failed", "signing_failed", "helper_verification_failed", "host_verification_failed"):
            with patch.object(c.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "fixture failure")):
                with self.assertRaises(c.CompanionError) as failure:
                    self.real_command("/fixture", failure_code=code)
            self.assertEqual(c.error_payload(failure.exception)["error"], code)

    # --- Lifecycle and signed helper identity ---

    def test_bootstrap_failure_cleans_only_own_agent(self):
        """Check that failed startup archives our helper without touching the host service."""
        c = self.controller
        self.fail_overlay_bootstrap = True
        with patch.object(c, "permission_status", return_value={"accessibility": True}):
            with self.assertRaisesRegex(RuntimeError, "rolled_back"):
                c.install()
        receipt = c.read_json(c.RECEIPT)
        self.assertEqual(receipt["state"], "rolled_back")
        self.assertFalse(self.services[c.LABEL]["loaded"])
        self.assertFalse(c.INSTALLED.exists())
        self.assertTrue(Path(receipt["archivePath"]).is_dir())
        self.assertTrue(any(call[1] == "disable" for call in self.mutations()))
        self.assert_google_untouched()

    def test_install_restart_restore_need_ax_only_and_manage_own_job_only(self):
        """Check the full lifecycle with Accessibility alone and changes limited to our job."""
        c = self.controller
        with patch.object(c, "permission_status", return_value={"accessibility": True, "screenCapture": False}), patch.object(c, "wait_running", side_effect=self.ready):
            receipt = c.install()
            self.assertEqual(receipt["state"], "active")
            agent = plistlib.loads(c.AGENT.read_bytes())
            self.assertEqual(agent["ProgramArguments"], [str(c.INSTALLED / "Contents/MacOS" / c.EXECUTABLE), "--crd-host-app", str(self.original)])
            self.assertEqual(agent["KeepAlive"], {"SuccessfulExit": False})
            self.assertEqual(agent["ThrottleInterval"], 5)
            self.assertEqual(c.restart()["state"], "active")
            self.assertEqual(c.restore()["state"], "restored")
        self.assertTrue(self.mutations())
        self.assert_google_untouched()

    def test_signed_artifact_fingerprint_survives_update_and_rejects_replacement(self):
        """Check that signed bytes remain trusted across source updates but reject helper replacement."""
        c = self.controller
        source = c.BINARY.read_bytes()
        real_sign = c.sign_own

        def sign(app):
            """Simulate signing that changes executable bytes after the build fingerprint is recorded."""
            real_sign(app)
            (app / "Contents/MacOS" / c.EXECUTABLE).write_bytes(source + b"signed bundle seal")

        with patch.object(c, "sign_own", side_effect=sign), \
                patch.object(c, "permission_status", return_value={"accessibility": True}), \
                patch.object(c, "wait_running", side_effect=self.ready):
            receipt = c.install()
        binary = c.INSTALLED / "Contents/MacOS" / c.EXECUTABLE
        self.assertEqual(receipt["helperIdentity"]["sha256"], c.digest(binary))
        self.assertNotEqual(receipt["helperIdentity"]["sha256"], c.digest(c.BINARY))
        self.assertEqual(c.installed_info()["CRDLauncherSourceSHA256"], c.digest(c.BINARY))
        c.BINARY.write_bytes(b"new settings app build")
        c.verify_installed_helper(receipt)  # Retained identity is independent of the new build.
        binary.write_bytes(b"another ad hoc app with the same identifier")
        with patch.object(c, "permission_status", side_effect=AssertionError("must not execute replaced helper")):
            with self.assertRaises(c.CompanionError) as error:
                c.permissions()
        self.assertEqual(error.exception.code, "helper_verification_failed")
        with patch.object(c, "cleanup_restoration_probe", side_effect=AssertionError("must not start recovery")):
            with self.assertRaises(c.CompanionError):
                c.recover_restoration(receipt)

    def test_new_receipt_cannot_silently_adopt_a_missing_fingerprint(self):
        """Check that a schema-3 receipt without its fingerprint cannot launch recovery."""
        c = self.controller
        self.pending_restoration()
        receipt = c.read_json(c.RECEIPT)
        receipt["schema"] = 3
        c.write_json(c.RECEIPT, receipt)
        with self.assertRaises(c.CompanionError) as error:
            c.restore()
        self.assertEqual(error.exception.code, "helper_verification_failed")
        self.assertTrue(c.INSTALLED.is_dir())
        self.assertTrue(c.read_json(c.runtime_path("restore-state.json"))["pending"])
        self.assertFalse(self.mutations())

    def test_legacy_recovery_checks_trusted_certificate_before_recording_identity(self):
        """Check that unrecorded helper identity requires the trusted current certificate."""
        c = self.controller
        self.pending_restoration()
        receipt = c.read_json(c.RECEIPT)

        def reject_retained_signature(*args, **kwargs):
            """Reject the retained helper after checking that certificate verification is requested."""
            if args[0] == "/usr/bin/codesign" and "--verify" in args and args[-1] == c.INSTALLED:
                self.assertIn("certificate leaf", args[args.index("-R") + 1])
                raise c.CompanionError("helper_verification_failed", "different certificate")
            return self.fake_command(*args, **kwargs)

        with patch.object(c, "command", side_effect=reject_retained_signature):
            with self.assertRaises(c.CompanionError):
                c.recover_restoration(receipt)
        self.assertNotIn("helperIdentity", c.read_json(c.RECEIPT))
        self.assertTrue(c.read_json(c.runtime_path("restore-state.json"))["pending"])
        self.assertFalse(self.mutations())

    def test_schema_two_normal_restore_then_new_ad_hoc_install(self):
        """Check restoration of a schema-2 install followed by a fingerprinted ad hoc install."""
        c = self.controller
        self.make_installed(3)
        c.write_json(c.RECEIPT, {"schema": 2, "state": "active", "backendKind": c.BACKEND_KIND,
                               "originalHostPath": str(self.original)})
        self.services[c.LABEL] = {"loaded": True, "pid": 222}
        c.write_json(c.runtime_path("restore-state.json"), {"pending": False})
        with patch.object(c, "designated_requirement", side_effect=AssertionError("normal restore launches no helper")):
            self.assertEqual(c.restore()["state"], "restored")
        with patch.object(c, "designated_requirement", return_value='cdhash H"0000000000000000000000000000000000000000"'), \
                patch.object(c, "permission_status", return_value={"accessibility": True}), \
                patch.object(c, "wait_running", side_effect=self.ready):
            receipt = c.install()
        self.assertEqual(receipt["schema"], 3)
        self.assertEqual(receipt["helperIdentity"]["sha256"], c.digest(c.INSTALLED / "Contents/MacOS" / c.EXECUTABLE))
        self.assertEqual(c.status()["state"], "active")
        self.assert_google_untouched()

    def test_prepare_install_restart_status_restore_keep_config_and_presets(self):
        # Presets sit beside config.json; the controller never moves, rewrites or reports them.
        """Check that lifecycle actions preserve configuration and preset bytes, paths and timestamps."""
        c = self.controller
        config, presets = c.SUPPORT / "config.json", c.SUPPORT / "presets.json"
        config.write_bytes(b'{"mode": "custom"}\n')
        presets.write_bytes(b'{"schema": 1, "presets": [{"id": "a", "name": "Small dot", "values": {"width": 42}}]}\n')
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in (config, presets)}
        with patch.object(c, "permission_status", return_value={"accessibility": True, "screenCapture": False}), patch.object(c, "wait_running", side_effect=self.ready):
            c.prepare()
            self.assertEqual(c.install()["state"], "active")
            self.assertEqual(c.restart()["state"], "active")
            status = c.status()
            self.assertEqual(c.restore()["state"], "restored")
        for path, (data, mtime) in before.items():
            with self.subTest(path=path.name):
                self.assertEqual(path.read_bytes(), data)
                self.assertEqual(path.stat().st_mtime_ns, mtime)
        self.assertNotIn("presets", json.dumps(status))
        self.assertEqual(status["configPath"], str(config.resolve()))
        self.assertFalse([path for path in (c.SUPPORT / "archives").rglob("*") if path.name in ("config.json", "presets.json")])
        self.assert_google_untouched()

    # --- Runtime readiness and permission reports ---

    def test_runtime_allows_waiting_but_requires_exact_job_valid_pid_and_ready_nonfixture(self):
        """Check readiness against process identity, job PID, freshness and non-fixture state."""
        c = self.controller
        exact = str(c.INSTALLED / "Contents/MacOS" / c.EXECUTABLE)
        valid = dict(pid=42, originalPid=111, fixture=False, backendKind=c.BACKEND_KIND, agentReady=True,
                     observerReady=True, originalWindowDetected=False, lastEventTimestamp=100)
        cases = [({}, {42: exact}, [111], 99, True),
                 ({}, {}, [111], 99, False), ({}, {42: "/different/app"}, [111], 99, False),
                 ({}, {42: exact}, [], 99, False),
                 ({"originalPid": None}, {42: exact}, [], 99, True),
                 ({"originalPid": 999}, {42: exact}, [111], 99, False),
                 ({}, {42: exact}, [111], 101, False),
                 ({"fixture": True}, {42: exact}, [111], 99, False),
                 ({"backendKind": "legacy"}, {42: exact}, [111], 99, False),
                 ({"observerReady": False}, {42: exact}, [111], 99, False),
                 ({"agentReady": False}, {42: exact}, [111], 99, False)]
        for overrides, processes, originals, since, expected in cases:
            with self.subTest(overrides=overrides, since=since, expected=expected):
                c.write_json(c.SUPPORT / "runtime-status.json", dict(valid, **overrides))
                with patch.object(c, "owned_processes", return_value=processes), patch.object(c, "original_processes", return_value=originals), patch.object(c, "agent_snapshot", return_value={"running": True, "pid": 42}):
                    status = c.runtime_status(since, self.original)
                    self.assertEqual(status["confirmed"], expected)
                    if overrides.get("originalPid", 111) is None:
                        self.assertTrue(status["waitingForOriginal"])
                        self.assertFalse(status["originalProcessMatches"])
        c.write_json(c.SUPPORT / "runtime-status.json", valid)
        with patch.object(c, "owned_processes", return_value={42: exact}), patch.object(c, "original_processes", return_value=[111]), patch.object(c, "agent_snapshot", return_value={"running": True, "pid": 999}):
            self.assertFalse(c.runtime_status(99, self.original)["confirmed"])

    def test_permissions_do_not_replace_an_active_overlay(self):
        """Check that a permission refresh preserves a running helper across build changes."""
        c = self.controller
        executable = self.make_installed(protocol=3)
        before = executable.read_bytes()
        c.BINARY.write_bytes(b"newer overlay input")
        c.write_json(c.RECEIPT, {"state": "active", "backendKind": c.BACKEND_KIND})
        with patch.object(c, "prepare", wraps=c.prepare) as prepare, patch.object(c, "permission_status", return_value={"accessibility": True}):
            result = c.permissions()
        prepare.assert_not_called()
        self.assertEqual(executable.read_bytes(), before)
        self.assertTrue(result["identityLayoutUpgradeDeferred"])
        self.assertEqual(self.mutations(), [])
        self.assert_google_untouched()

    def test_runtime_passes_permission_and_detection_fields_even_when_not_ready(self):
        """Check that readiness failure does not discard permission, detection or restoration fields."""
        c = self.controller
        reported = dict(accessibility=False, stopActionAvailable=False, enabled=True,
                        effectiveMode="original", detectionReason="accessibility-required",
                        restorationPending=True, restorationBlocked=True)
        c.write_json(c.runtime_path("runtime-status.json"), dict(reported, agentReady=False))
        status = c.runtime_status()
        self.assertFalse(status["confirmed"])
        for key, value in reported.items():
            self.assertEqual(status[key], value)
        c.write_json(c.runtime_path("runtime-status.json"), {"agentReady": False})
        status = c.runtime_status()
        for key in reported:
            self.assertIsNone(status[key])
        self.assert_google_untouched()

    def test_legacy_restored_receipt_is_safe_and_inactive_protocol_two_upgrades(self):
        """Check that restored legacy records are inert and inactive protocol-2 helpers can be replaced."""
        c = self.controller
        self.make_installed(protocol=2)
        c.write_json(c.RECEIPT, {"state": "restored", "initialOriginalEnabled": True, "initialOriginalRunning": True})
        self.assertTrue(c.restore()["legacyReceipt"])
        self.assertEqual(self.mutations(), [])
        with patch.object(c, "permission_status", return_value={"accessibility": True}):
            result = c.permissions()
        info = plistlib.loads((c.INSTALLED / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CRDCompanionProtocolVersion"], 3)
        self.assertEqual(result["companionProtocolVersion"], 3)
        self.assertTrue(list((c.SUPPORT / "archives").glob("*permission-upgrade")))
        self.assertEqual(self.mutations(), [])
        self.assert_google_untouched()

    # --- Preparation, archive retention and settings discovery ---

    def test_prepare_contains_only_own_agent_no_vendor_links_and_executes_nothing(self):
        """Check helper bundle identity, notices and contents without executing any agent."""
        c = self.controller
        result = c.prepare()
        info = plistlib.loads((c.STAGE / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleName"], "CRD Window Host")
        self.assertEqual(info["CFBundleDisplayName"], "CRD Window Host")
        self.assertEqual(info["CFBundleIdentifier"], "local.crdwindow.host")
        self.assertEqual(info["CFBundleExecutable"], "CRDWindowAgent")
        self.assertEqual(info["CFBundleVersion"], "3")
        self.assertEqual(info["CFBundleShortVersionString"], "3.0")
        macos = c.STAGE / "Contents/MacOS"
        self.assertEqual({p.name for p in macos.iterdir()}, {c.EXECUTABLE})
        self.assertFalse(any(p.is_symlink() for p in c.STAGE.rglob("*")))
        self.assertFalse(result["agentExecuted"])
        for relative in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "reference/LICENSE", "reference/README.md", "assets/README.md"):
            self.assertEqual((c.STAGE / "Contents/Resources/Licenses" / relative).read_bytes(),
                             (PROJECT / relative).read_bytes())
        self.assertTrue(result["originalUnmodified"])
        self.assertTrue(all(call[0] == "/usr/bin/codesign" for call in self.calls))
        sign_targets = [Path(call[-1]) for call in self.calls if "--sign" in call]
        self.assertTrue(sign_targets)
        self.assertTrue(all(self.original not in target.parents and target != self.original for target in sign_targets))
        self.assert_google_untouched()

    def test_original_requirement_includes_google_signer_and_exact_host_identifier(self):
        """Check that host verification requires both the Google signer and exact host identifier."""
        c = self.controller
        (self.original / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "fixture"}))
        self.real_verify_original(self.original)
        requirement = next(call[call.index("-R") + 1] for call in self.calls if "-R" in call)
        self.assertIn('certificate leaf[subject.OU] = "EQHXZ8M8AV"', requirement)
        self.assertIn('identifier "com.google.chromeremotedesktop.me2me-host"', requirement)
        self.assert_google_untouched()


    def test_prepare_keeps_old_stage_until_signing_succeeds_and_retires_obsolete_copies(self):
        """Check that staging preserves a usable bundle until signing succeeds, then retires copies."""
        c = self.controller
        c.prepare()
        old = (c.STAGE / "Contents/MacOS" / c.EXECUTABLE).read_bytes()
        obsolete = c.ROOT / "build/previous-overlay-1.app"
        obsolete.mkdir()
        c.BINARY.write_bytes(b"new signed stage")
        with patch.object(c, "sign_own", side_effect=c.CompanionError("signing_failed", "fixture")):
            with self.assertRaises(c.CompanionError):
                c.prepare()
        self.assertEqual((c.STAGE / "Contents/MacOS" / c.EXECUTABLE).read_bytes(), old)
        self.assertTrue(obsolete.is_dir())
        self.assertEqual(self.trashed, [])
        c.prepare()
        self.assertEqual((c.STAGE / "Contents/MacOS" / c.EXECUTABLE).read_bytes(), b"new signed stage")
        self.assertEqual(list((c.ROOT / "build").glob("previous-overlay-*.app")), [])
        self.assertIn(obsolete, self.trashed)
        self.assertFalse(any("/usr/bin/trash" in call for call in self.calls))

    def test_prepare_trash_failure_keeps_old_bundle_and_new_verified_stage(self):
        """Check that Trash failure retains both generations and a later prepare retries cleanup."""
        c = self.controller
        c.prepare()
        old = (c.STAGE / "Contents/MacOS" / c.EXECUTABLE).read_bytes()
        c.BINARY.write_bytes(b"new stage")
        with patch.object(c.file_operations, "trash", side_effect=OSError("Trash unavailable")):
            with self.assertRaisesRegex(OSError, "Trash unavailable"):
                c.prepare()
        previous, = (c.ROOT / "build").glob("previous-overlay-*.app")
        self.assertEqual((previous / "Contents/MacOS" / c.EXECUTABLE).read_bytes(), old)
        self.assertEqual((c.STAGE / "Contents/MacOS" / c.EXECUTABLE).read_bytes(), b"new stage")
        c.prepare()
        self.assertEqual(list((c.ROOT / "build").glob("previous-overlay-*.app")), [])

    def test_many_lifecycle_cycles_bound_grouped_archives_and_preserve_user_files(self):
        """Check the five-generation archive bound across repeated installs without changing user files."""
        c = self.controller
        config, presets = c.SUPPORT / "config.json", c.SUPPORT / "presets.json"
        config.write_bytes(b'{"mode":"custom"}\n')
        presets.write_bytes(b'{"schema":1,"presets":[]}\n')
        before = {p: p.read_bytes() for p in (config, presets)}
        with patch.object(c, "permission_status", return_value={"accessibility": True}), \
                patch.object(c, "wait_running", side_effect=self.ready):
            for generation in range(12):
                c.BINARY.write_bytes(f"build {generation}".encode())
                c.prepare()
                c.permissions()
                c.install()
                self.assertEqual(c.restore()["state"], "restored")
                archives = list((c.SUPPORT / "archives").iterdir())
                self.assertLessEqual(len(archives), c.ARCHIVE_LIMIT)
                for archive in archives:
                    self.assertTrue((archive / c.INSTALLED.name).is_dir())
                    self.assertIsNotNone(c.read_json(archive / c.RECEIPT.name).get("helperIdentity"))
                self.assertEqual(list((c.ROOT / "build").glob("previous-overlay-*.app")), [])
        self.assertEqual(len(archives), 5)
        self.assertGreater(len(self.trashed), 24)
        self.assertEqual({p: p.read_bytes() for p in before}, before)
        self.assertFalse(c.read_json(c.runtime_path("restore-state.json"))["pending"])
        self.assert_google_untouched()

    def seed_archives(self, count):
        """Create completed receipt-only archives in the isolated support folder."""
        c = self.controller
        paths = [c.SUPPORT / "archives" / f"{index + 1}-receipt-history" for index in range(count)]
        for path in paths:
            c.write_json(path / c.RECEIPT.name, {"state": "restored"})
        return paths

    def test_retention_pauses_for_retained_recovery_and_resumes_after_restore(self):
        """Check that pending restoration protects recovery files and pauses archive pruning."""
        c = self.controller
        archives = self.seed_archives(7)
        journal = self.pending_restoration()
        c.prune_archives()
        with patch.object(c, "recover_restoration", side_effect=c.CompanionError("restoration_unconfirmed", "fixture")):
            with self.assertRaises(c.CompanionError):
                c.restore()
        self.assertEqual(self.trashed, [])
        self.assertTrue(c.INSTALLED.is_dir())
        self.assertEqual(c.read_json(c.runtime_path("restore-state.json")), journal)
        self.assertTrue(all(path.exists() for path in archives))
        c.write_json(c.runtime_path("restore-state.json"), {"pending": False})
        self.assertEqual(c.restore()["state"], "restored")
        self.assertEqual(len(list((c.SUPPORT / "archives").iterdir())), 5)
        self.assertFalse(archives[0].exists())
        self.assertTrue(c.runtime_path("restore-state.json").is_file())
        self.assert_google_untouched()

    def test_archive_trash_failure_reports_error_without_rolling_back_new_install(self):
        """Check that archive pruning failure leaves a successfully started helper active."""
        c = self.controller
        self.seed_archives(5)
        with patch.object(c, "permission_status", return_value={"accessibility": True}), \
                patch.object(c, "wait_running", side_effect=self.ready):
            c.permissions()
            def trash(path):
                """Fail archive pruning while allowing staged fixture bundles to move to mock Trash."""
                if path.parent == c.SUPPORT / "archives":
                    raise OSError("archive Trash unavailable")
                return self.fake_trash(path)
            with patch.object(c.file_operations, "trash", side_effect=trash):
                with self.assertRaisesRegex(OSError, "archive Trash unavailable"):
                    c.install()
        self.assertEqual(c.read_json(c.RECEIPT)["state"], "active")
        self.assertTrue(self.services[c.LABEL]["loaded"])
        self.assertTrue(c.INSTALLED.is_dir())
        self.assertEqual(len(list((c.SUPPORT / "archives").iterdir())), 6)
        self.assert_google_untouched()

    def test_restore_trash_failure_keeps_archive_and_retries_without_restarting_helper(self):
        """Check that a restore retry prunes retained archives without restarting the helper."""
        c = self.controller
        archives = self.seed_archives(5)
        with patch.object(c, "permission_status", return_value={"accessibility": True}), \
                patch.object(c, "wait_running", side_effect=self.ready):
            c.install()
        with patch.object(c.file_operations, "trash", side_effect=OSError("archive Trash unavailable")):
            with self.assertRaisesRegex(OSError, "archive Trash unavailable"):
                c.restore()
        receipt = c.read_json(c.RECEIPT)
        self.assertEqual(receipt["state"], "restored")
        self.assertTrue((Path(receipt["archivePath"]) / c.INSTALLED.name).is_dir())
        self.assertTrue(all(path.exists() for path in archives))
        mutations = self.mutations()
        self.assertEqual(c.restore()["state"], "restored")
        self.assertEqual(self.mutations(), mutations)
        self.assertEqual(len(list((c.SUPPORT / "archives").iterdir())), 5)

    def test_partial_archive_move_rolls_back_helper_and_keeps_journal(self):
        """Check rollback of a partial archive move while retaining the restoration journal."""
        c = self.controller
        self.make_installed(3)
        c.write_agent(self.original)
        c.write_json(c.runtime_path("restore-state.json"), {"pending": False})
        receipt = {"state": "active", "backendKind": c.BACKEND_KIND}
        c.write_json(c.RECEIPT, receipt)
        rename = Path.rename
        def move(path, destination):
            """Fail only the LaunchAgent archive move to simulate a partial transaction."""
            if path == c.AGENT:
                raise OSError("fixture agent archive failure")
            return rename(path, destination)
        with patch.object(Path, "rename", move):
            with self.assertRaisesRegex(OSError, "fixture agent archive failure"):
                c.restore()
        self.assertTrue(c.INSTALLED.is_dir())
        self.assertTrue(c.AGENT.is_file())
        self.assertEqual(c.read_json(c.RECEIPT)["state"], "cleanup_failed")
        self.assertEqual(c.read_json(c.runtime_path("restore-state.json")), {"pending": False})
        self.assertEqual(self.trashed, [])
        self.assertTrue(all(p.name.startswith(".pending-") for p in (c.SUPPORT / "archives").iterdir()))

    def test_source_settings_metadata_prefers_installed_apps_and_verifies_bundle_id(self):
        """Check ordered settings-app discovery and rejection of invalid bundle metadata."""
        c = self.controller
        user_home = c.SUPPORT.parents[2]
        with patch.object(c, "BUNDLED", False), patch.object(c.Path, "home", return_value=user_home):
            self.assertEqual(self.real_settings_candidates(), [user_home / "Applications/CRD Window Studio.app",
                Path("/Applications/CRD Window Studio.app"), c.ROOT / "dist/CRD Window Studio.app"])
        candidates = [c.ROOT / name / "CRD Window Studio.app" for name in ("user-apps", "system-apps", "dist")]
        def make_info(app, identifier):
            """Write a candidate bundle identifier into an isolated settings-app fixture."""
            (app / "Contents").mkdir(parents=True, exist_ok=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        make_info(candidates[0], "unrelated.app")
        make_info(candidates[1], "local.crdwindow.studio")
        make_info(candidates[2], "local.crdwindow.studio")
        with patch.object(c, "settings_app_candidates", return_value=candidates):
            c.prepare()
            paths = c.read_json(c.STAGE / "Contents/Resources/original-host.json")
            self.assertEqual(paths, {"path": str(self.original), "settingsAppPath": str(candidates[1].resolve())})
            make_info(candidates[0], "local.crdwindow.studio")
            self.assertEqual(c.settings_app_path(), candidates[0].resolve())
            (candidates[0] / "Contents/Info.plist").write_bytes(b'<?xml version="1.0"?><plist><dict>')
            self.assertEqual(c.settings_app_path(), candidates[1].resolve())
            make_info(candidates[0], "wrong.user.app")
            make_info(candidates[1], "wrong.system.app")
            self.assertEqual(c.settings_app_path(), candidates[2].resolve())
            make_info(candidates[2], "wrong.source.app")
            c.prepare()
            self.assertEqual(c.read_json(c.STAGE / "Contents/Resources/original-host.json"), {"path": str(self.original)})
        self.assert_google_untouched()

    def test_bundled_settings_metadata_uses_owning_app_only_when_identifier_matches(self):
        """Check that a bundled controller references only its correctly identified containing app."""
        c = self.controller
        app = c.ROOT / "Installed Settings.app"
        script_dir = app / "Contents/Resources/Backend"
        script_dir.mkdir(parents=True)
        for relative in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "reference/LICENSE", "reference/README.md", "assets/README.md"):
            target = script_dir.parent / "Licenses" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((PROJECT / relative).read_bytes())
        info_path = app / "Contents/Info.plist"
        info_path.write_bytes(plistlib.dumps({"CFBundleIdentifier": "local.crdwindow.studio"}))
        with patch.object(c, "BUNDLED", True), patch.object(c, "SCRIPT_DIR", script_dir), patch.object(c, "settings_app_candidates", side_effect=self.real_settings_candidates):
            self.assertEqual(c.settings_app_candidates(), [app])
            c.prepare()
            self.assertEqual(c.read_json(c.STAGE / "Contents/Resources/original-host.json")["settingsAppPath"], str(app.resolve()))
            info_path.write_bytes(plistlib.dumps({"CFBundleIdentifier": "unrelated.app"}))
            c.prepare()
            self.assertNotIn("settingsAppPath", c.read_json(c.STAGE / "Contents/Resources/original-host.json"))
        self.assert_google_untouched()

    # --- Installation failure and retained restoration ---

    def test_initial_receipt_failure_publishes_no_bundle_or_launchagent(self):
        """Check that failure to write the recovery receipt prevents helper publication."""
        c = self.controller
        original_write = c.write_json
        def fail_receipt(path, value):
            """Reject receipt writes while allowing unrelated fixture writes."""
            if path == c.RECEIPT:
                raise OSError("fixture receipt write")
            return original_write(path, value)
        with patch.object(c, "write_json", side_effect=fail_receipt):
            with self.assertRaisesRegex(OSError, "receipt write"):
                c.install()
        self.assertFalse(c.INSTALLED.exists())
        self.assertFalse(c.AGENT.exists())
        self.assertEqual(self.mutations(), [])

    def test_plist_failure_after_copy_rolls_back_and_keeps_receipt(self):
        """Check that a LaunchAgent write failure archives the helper and records rollback."""
        c = self.controller
        with patch.object(c, "permission_status", return_value={"accessibility": True}), patch.object(c, "write_agent", side_effect=OSError("fixture plist write")):
            with self.assertRaisesRegex(RuntimeError, "rolled_back"):
                c.install()
        self.assertEqual(c.read_json(c.RECEIPT)["state"], "rolled_back")
        self.assertFalse(c.INSTALLED.exists())
        self.assertFalse(c.AGENT.exists())
        self.assert_google_untouched()

    def test_final_receipt_failure_stops_started_job_and_archives(self):
        """Check cleanup when recording a successful startup fails after the job starts."""
        c = self.controller
        original_write = c.write_json
        def fail_active(path, value):
            """Reject only the final active-state receipt write."""
            if path == c.RECEIPT and value.get("state") == "active":
                raise OSError("fixture active receipt")
            return original_write(path, value)
        with patch.object(c, "write_json", side_effect=fail_active), patch.object(c, "permission_status", return_value={"accessibility": True}), patch.object(c, "wait_running", side_effect=self.ready):
            with self.assertRaisesRegex(RuntimeError, "rolled_back"):
                c.install()
        self.assertEqual(c.read_json(c.RECEIPT)["state"], "rolled_back")
        self.assertFalse(self.services[c.LABEL]["loaded"])
        self.assertFalse(c.AGENT.exists())
        self.assert_google_untouched()

    def test_stop_requires_clear_restoration_journal_not_missing_runtime(self):
        """Check that stopping requires an explicit clear journal, not missing or invalid evidence."""
        c = self.controller
        journal = c.runtime_path("restore-state.json")
        for content in (None, b"{invalid", b'{"pending":true}', b'{}'):
            journal.unlink(missing_ok=True)
            if content:
                journal.write_bytes(content)
            with self.subTest(content=content), self.assertRaises(RuntimeError):
                c.stop_companion()
        c.write_json(journal, {"pending": False})
        c.stop_companion()

    def pending_restoration(self, state="cleanup_failed"):
        """Create a retained helper, receipt and pending restoration obligation for recovery tests."""
        c = self.controller
        self.make_installed(3)
        c.write_json(c.RECEIPT, {"state": state, "backendKind": c.BACKEND_KIND,
                               "originalHostPath": str(self.original)})
        intent = {"pending": True, "pid": 111, "birth": "fixture-birth",
                  "executable": str(self.original / "Contents/MacOS/remoting_me2me_host")}
        c.write_json(c.runtime_path("restore-state.json"), intent)
        return intent

    def test_explicit_cleanup_retry_uses_retained_helper_only_then_archives(self):
        self.check_cleanup_retry(pinned=False)

    def test_fingerprinted_ad_hoc_recovery_survives_new_build(self):
        """Check that a recorded ad hoc requirement permits recovery after the source build changes."""
        c = self.controller
        with patch.object(c, "designated_requirement", return_value='cdhash H"0000000000000000000000000000000000000000"'):
            self.check_cleanup_retry(pinned=True)

    def check_cleanup_retry(self, pinned):
        """Exercise a failed restore followed by bounded recovery of the retained signed helper."""
        c = self.controller
        self.pending_restoration("active")
        if pinned:
            receipt = c.read_json(c.RECEIPT)
            receipt.update(schema=3, helperIdentity=c.helper_identity(c.INSTALLED))
            c.write_json(c.RECEIPT, receipt)
        self.services[c.LABEL] = {"loaded": True, "pid": 222}
        with self.assertRaises(c.CompanionError):
            c.restore()
        self.assertEqual(c.read_json(c.RECEIPT)["state"], "cleanup_failed")
        self.assertFalse(any(c.RESTORE_LABEL in str(call) for call in self.mutations()))
        c.BINARY.write_bytes(b"new build must not replace retained helper")
        retained = (c.INSTALLED / "Contents/MacOS" / c.EXECUTABLE).read_bytes()

        def commands(*args, **kwargs):
            """Validate the restoration-only job and publish a successful fixture result and clear journal."""
            if args[:2] == ("/bin/launchctl", "bootstrap"):
                info = plistlib.loads(Path(args[-1]).read_bytes())
                self.assertEqual(info["Label"], c.RESTORE_LABEL)
                self.assertEqual(info["ProgramArguments"], [str(c.INSTALLED / "Contents/MacOS" / c.EXECUTABLE),
                                                            "--crd-restore-only", "--crd-host-app", str(self.original)])
                self.assertEqual(info["EnvironmentVariables"], {"CRD_WINDOW_CONFIG": str(c.config_path())})
                self.assertNotIn("KeepAlive", info)
                self.assertNotIn("--prompt", info["ProgramArguments"])
                c.write_json(Path(info["StandardOutPath"]), {"restored": True, "pid": 333, "bundleId": c.LABEL})
                c.write_json(c.runtime_path("restore-state.json"), {"pending": False})
            return self.fake_command(*args, **kwargs)

        with patch.object(c, "command", side_effect=commands), \
             patch.object(c, "prepare", side_effect=AssertionError("must retain installed helper")), \
             patch.object(c, "permission_status", side_effect=AssertionError("no probe or prompt during recovery")):
            result = c.restore()
        self.assertEqual(result["state"], "restored")
        self.assertEqual(bool(result.get("helperIdentityMigrated")), not pinned)
        self.assertEqual((Path(result["archivePath"]) / c.INSTALLED.name / "Contents/MacOS" / c.EXECUTABLE).read_bytes(), retained)
        self.assertFalse(self.services[c.RESTORE_LABEL]["loaded"])
        self.assertFalse((c.SUPPORT / "restore-probe.plist").exists())
        self.assert_google_untouched()

    def test_recovery_denied_unknown_or_timed_out_keeps_obligation_and_files(self):
        """Check that failed or uncertain recovery preserves the journal, helper and cleanup state."""
        c = self.controller
        for outcome in ("denied", "unknown", "invalid", "timeout"):
            with self.subTest(outcome=outcome):
                intent = self.pending_restoration()
                clock = [0.0]
                def commands(*args, **kwargs):
                    """Simulate denied, uncertain, malformed or absent restoration results."""
                    if args[:2] == ("/bin/launchctl", "bootstrap") and outcome != "timeout":
                        c.write_json(c.SUPPORT / "restore-probe.json",
                                     {"restored": outcome == "unknown", "pid": 333,
                                      "bundleId": "foreign" if outcome == "invalid" else c.LABEL})
                    return self.fake_command(*args, **kwargs)
                with patch.object(c, "command", side_effect=commands), \
                     patch.object(c.time, "monotonic", side_effect=lambda: clock[0]), \
                     patch.object(c.time, "sleep", side_effect=lambda delay: clock.__setitem__(0, clock[0] + delay)):
                    with self.assertRaises(c.CompanionError) as failure:
                        c.restore()
                self.assertEqual(failure.exception.code, "restoration_unconfirmed")
                self.assertEqual(c.read_json(c.runtime_path("restore-state.json")), intent)
                self.assertEqual(c.read_json(c.RECEIPT)["state"], "cleanup_failed")
                self.assertTrue(c.INSTALLED.exists())
                self.assertFalse(self.services[c.RESTORE_LABEL]["loaded"])
                self.assertLessEqual(clock[0], 10)
                self.assertIsNone(c.COMMAND_DEADLINE)
        self.assert_google_untouched()

    def test_recovery_cleanup_failure_retains_job_and_blocks_archive_then_retry_cleans(self):
        """Check that a surviving recovery job or process prevents archiving until cleanup succeeds."""
        c = self.controller
        for surviving in ("job", "process"):
            with self.subTest(surviving=surviving):
                self.pending_restoration()
                def commands(*args, **kwargs):
                    """Publish successful restoration but simulate a recovery job or process surviving cleanup."""
                    if args[:2] == ("/bin/launchctl", "bootstrap"):
                        c.write_json(c.SUPPORT / "restore-probe.json", {"restored": True, "pid": 333, "bundleId": c.LABEL})
                        c.write_json(c.runtime_path("restore-state.json"), {"pending": False})
                    if args[:2] == ("/bin/launchctl", "bootout") and str(args[-1]).endswith(c.RESTORE_LABEL) and surviving == "job":
                        return subprocess.CompletedProcess(args, 1, "", "fixture cleanup failure")
                    if args[:2] == ("/bin/ps", "-p") and surviving == "process":
                        return subprocess.CompletedProcess(args, 0, str(c.INSTALLED / "Contents/MacOS" / c.EXECUTABLE), "")
                    return self.fake_command(*args, **kwargs)
                with patch.object(c, "command", side_effect=commands):
                    with self.assertRaises(c.CompanionError):
                        c.restore()
                self.assertTrue(c.INSTALLED.exists())
                self.assertTrue((c.SUPPORT / "restore-probe.plist").exists())
                self.assertEqual(c.read_json(c.RECEIPT)["state"], "cleanup_failed")
                self.assertEqual(c.restore()["state"], "restored")
                self.assertFalse((c.SUPPORT / "restore-probe.plist").exists())
        self.assert_google_untouched()

    def test_revoked_restart_does_not_unload_before_preflight(self):
        """Check that revoked permission prevents restart before the active job is stopped."""
        c = self.controller
        self.pending_restoration("active")
        self.services[c.LABEL] = {"loaded": True, "pid": 222}
        with patch.object(c, "permission_status", return_value={"accessibility": False}):
            with self.assertRaises(c.CompanionError) as failure:
                c.restart()
        self.assertEqual(failure.exception.code, "accessibility_required")
        self.assertEqual(self.mutations(), [])
        self.assertTrue(self.services[c.LABEL]["loaded"])

    # --- Independent permission probe cleanup ---

    def test_probe_cleanup_failure_is_reported_and_plist_preserved(self):
        """Check that a loaded permission job leaves its plist and reports cleanup failure."""
        c = self.controller
        app = c.INSTALLED
        def commands(*args, **kwargs):
            """Return permission success but refuse to unload the temporary probe job."""
            if args[:2] == ("/bin/launchctl", "bootstrap"):
                c.write_json(c.SUPPORT / "permission-probe.json", {"accessibility": True, "pid": 333, "bundleId": c.LABEL})
            if args[:2] == ("/bin/launchctl", "bootout") and c.PERMISSION_LABEL in str(args[-1]):
                return subprocess.CompletedProcess(args, 1, "", "fixture bootout failure")
            return self.fake_command(*args, **kwargs)
        for prompt in (False, True):
            with self.subTest(prompt=prompt), patch.object(c, "command", side_effect=commands):
                with self.assertRaises(c.CompanionError) as failure:
                    c.permission_status(app, prompt=prompt)
                self.assertEqual(failure.exception.code, "permission_probe_cleanup_failed")
                self.assertIn("job remains loaded", str(failure.exception))
                self.assertTrue((c.SUPPORT / "permission-probe.plist").exists())
                self.services[c.PERMISSION_LABEL] = {"loaded": False, "pid": None}
        self.assert_google_untouched()

    def test_probe_live_process_blocks_cleanup_even_after_job_unloaded(self):
        """Check that a surviving probe process blocks cleanup even when its job is unloaded."""
        c = self.controller
        executable = str(c.INSTALLED / "Contents/MacOS" / c.EXECUTABLE)
        def commands(*args, **kwargs):
            """Return permission denial and report the exact probe process as still alive."""
            if args[:2] == ("/bin/launchctl", "bootstrap"):
                c.write_json(c.SUPPORT / "permission-probe.json", {"accessibility": False, "pid": 333, "bundleId": c.LABEL})
            if args[:2] == ("/bin/ps", "-p"):
                self.assertEqual(args[2], 333)
                return subprocess.CompletedProcess(args, 0, executable + "\n", "")
            return self.fake_command(*args, **kwargs)
        for prompt in (False, True):
            with self.subTest(prompt=prompt), patch.object(c, "command", side_effect=commands):
                with self.assertRaises(c.CompanionError) as failure:
                    c.permission_status(c.INSTALLED, prompt=prompt)
                self.assertEqual(failure.exception.code, "permission_probe_cleanup_failed")
                self.assertIn("process is still running", str(failure.exception))
                self.assertFalse(self.services[c.PERMISSION_LABEL]["loaded"])
                self.assertTrue((c.SUPPORT / "permission-probe.plist").exists())
        self.assert_google_untouched()

    def test_permissions_probe_uses_own_bundle_arguments_and_cleans_up_in_both_modes(self):
        """Check probe attribution, arguments and cleanup with and without an explicit prompt."""
        c = self.controller
        self.make_installed(3)
        for prompt in (False, True):
            for trusted in (False, True):
                with self.subTest(prompt=prompt, trusted=trusted):
                    def commands(*args, **kwargs):
                        """Validate the independent probe job and write its simulated permission result."""
                        if args[:2] == ("/bin/launchctl", "bootstrap"):
                            self.assertEqual(args[2], c.DOMAIN)
                            self.assertEqual(args[3], c.SUPPORT / "permission-probe.plist")
                            info = plistlib.loads(Path(args[3]).read_bytes())
                            self.assertEqual(info["Label"], c.PERMISSION_LABEL)
                            self.assertEqual(info["ProgramArguments"],
                                             [str(c.INSTALLED / "Contents/MacOS" / c.EXECUTABLE), "--crd-permission-status"]
                                             + (["--prompt"] if prompt else []))
                            self.assertEqual(info["LimitLoadToSessionType"], ["Aqua"])
                            self.assertTrue(info["RunAtLoad"])
                            self.assertNotIn("KeepAlive", info)
                            c.write_json(Path(info["StandardOutPath"]), {"accessibility": trusted, "pid": 333, "bundleId": c.LABEL})
                        return self.fake_command(*args, **kwargs)
                    with patch.object(c, "command", side_effect=commands):
                        result = c.permissions(prompt=prompt)
                    self.assertEqual(result, {"accessibility": trusted, "pid": 333, "bundleId": c.LABEL,
                                              "executionContext": "independent per-user launchd job",
                                              "companionProtocolVersion": 3, "backendKind": c.BACKEND_KIND,
                                              "identityLayoutUpgradeDeferred": False, "runtimeRefreshRequested": None})
                    self.assertFalse(self.services[c.PERMISSION_LABEL]["loaded"])
                    self.assertFalse((c.SUPPORT / "permission-probe.plist").exists())
        self.assertEqual({call[1] for call in self.mutations()}, {"bootstrap", "bootout"})
        self.assertFalse(self.services[c.LABEL]["loaded"])
        self.assert_google_untouched()

    def test_permissions_probe_errors_keep_json_codes_and_cleanup_in_both_modes(self):
        """Check probe error codes and retained cleanup files for both prompt modes."""
        c = self.controller
        self.make_installed(3)
        for prompt in (False, True):
            for code in ("permission_probe_invalid", "permission_probe_timeout", "permission_probe_cleanup_failed"):
                with self.subTest(prompt=prompt, code=code):
                    def commands(*args, **kwargs):
                        """Inject invalid results, missing output or a probe unload failure."""
                        if args[:2] == ("/bin/launchctl", "bootstrap") and code != "permission_probe_timeout":
                            c.write_json(c.SUPPORT / "permission-probe.json",
                                         {"accessibility": False, "pid": 333,
                                          "bundleId": "wrong.bundle" if code == "permission_probe_invalid" else c.LABEL})
                        if args[:2] == ("/bin/launchctl", "bootout") and code == "permission_probe_cleanup_failed":
                            return subprocess.CompletedProcess(args, 1, "", "fixture bootout failure")
                        return self.fake_command(*args, **kwargs)
                    stdout, stderr = io.StringIO(), io.StringIO()
                    args = ["companionctl.py", "permissions"] + (["--prompt"] if prompt else [])
                    with patch.object(c, "command", side_effect=commands), \
                         patch.object(c, "command_deadline"), \
                         patch.object(c.time, "monotonic", side_effect=[0, 11] if code == "permission_probe_timeout" else [0, 0]), \
                         patch.object(c.time, "sleep", side_effect=AssertionError("real wait forbidden")), \
                         patch.object(c.sys, "argv", args), patch.object(c.sys, "stdout", stdout), patch.object(c.sys, "stderr", stderr):
                        self.assertEqual(c.main(), 1)
                    error = json.loads(stderr.getvalue())
                    self.assertEqual(set(error), {"error", "message"})
                    self.assertEqual(error["error"], code)
                    self.assertEqual(stdout.getvalue(), "")
                    self.assertEqual((c.SUPPORT / "permission-probe.plist").exists(), code == "permission_probe_cleanup_failed")
                    self.services[c.PERMISSION_LABEL] = {"loaded": False, "pid": None}
        self.assert_google_untouched()

    # --- Configuration paths, runtime refresh and deadlines ---

    def test_config_override_reaches_launchagent_runtime_and_status(self):
        """Check that the selected config path propagates through job, runtime and status paths."""
        c = self.controller
        config = c.ROOT / "config with spaces/settings.json"
        with patch.dict(c.os.environ, {"CRD_WINDOW_CONFIG": str(config)}):
            c.write_agent(self.original)
            info = plistlib.loads(c.AGENT.read_bytes())
            self.assertEqual(info["EnvironmentVariables"]["CRD_WINDOW_CONFIG"], str(config.resolve()))
            self.assertEqual(c.runtime_path("runtime-status.json"), config.resolve().parent / "runtime-status.json")
            self.assertEqual(c.status()["configPath"], str(config.resolve()))

    def test_status_requests_exact_helper_and_returns_acknowledged_permission_state(self):
        """Check targeted refresh acknowledgement before returning the helper's current permission state."""
        c = self.controller
        self.make_installed(3)
        self.services[c.LABEL] = {"loaded": True, "pid": 222}
        c.write_json(c.RECEIPT, {"state": "active", "installedAt": 99})
        runtime = dict(pid=222, originalPid=111, fixture=False, backendKind=c.BACKEND_KIND,
                       agentReady=True, observerReady=True, accessibility=True, lastEventTimestamp=100)
        c.write_json(c.runtime_path("runtime-status.json"), runtime)
        def commands(*args, **kwargs):
            """Validate the refresh address and publish revoked permission before acknowledging."""
            if args[0] == "/usr/bin/notifyutil":
                name = f"local.crdwindow.host.refresh.{c.os.getuid()}.222"
                self.assertEqual(args[1:], ("-1", name + ".done", "-p", name))
                self.assertEqual(kwargs["timeout"], 2)
                c.write_json(c.runtime_path("runtime-status.json"), dict(runtime, accessibility=False, agentReady=False))
            return self.fake_command(*args, **kwargs)
        with patch.object(c, "command", side_effect=commands), \
             patch.object(c, "permission_status", side_effect=AssertionError("status must not run a permission probe")), \
             patch.object(c.time, "sleep", side_effect=AssertionError("status must not poll")):
            result = c.status()["runtime"]
        self.assertTrue(result["refreshConfirmed"])
        self.assertFalse(result["accessibility"])
        self.assertFalse(result["confirmed"])
        self.assertEqual(self.mutations(), [])
        self.assert_google_untouched()

    def test_refresh_timeout_does_not_return_stale_confirmed_readiness(self):
        """Check that a missed refresh acknowledgement invalidates stale readiness."""
        c = self.controller
        self.services[c.LABEL] = {"loaded": True, "pid": 222}
        def commands(*args, **kwargs):
            """Simulate a timeout only for the helper refresh acknowledgement."""
            if args[0] == "/usr/bin/notifyutil":
                raise subprocess.TimeoutExpired(args, 2)
            return self.fake_command(*args, **kwargs)
        with patch.object(c, "command", side_effect=commands), \
             patch.object(c, "runtime_status", return_value={"confirmed": True, "agentReady": True}), \
             patch.object(c.time, "sleep", side_effect=AssertionError("no polling")):
            runtime = c.status()["runtime"]
        self.assertFalse(runtime["confirmed"])
        self.assertFalse(runtime["refreshConfirmed"])
        self.assertIn("acknowledge", runtime["reason"])

    def test_refresh_skips_absent_or_mismatched_helper_and_permissions_post_without_wait(self):
        """Check process identity before refresh and nonblocking refresh after permission checks."""
        c = self.controller
        self.assertIsNone(c.request_reconcile())
        self.services[c.LABEL] = {"loaded": True, "pid": 222}
        with patch.object(c, "owned_processes", return_value={222: "/foreign/executable"}):
            self.assertFalse(c.request_reconcile())
        self.assertFalse(any(call[0] == "/usr/bin/notifyutil" for call in self.calls))
        self.make_installed(3)
        with patch.object(c, "permission_status", return_value={"accessibility": True}):
            result = c.permissions()
        self.assertTrue(result["runtimeRefreshRequested"])
        notification = [call for call in self.calls if call[0] == "/usr/bin/notifyutil"]
        self.assertEqual(notification, [("/usr/bin/notifyutil", "-p", f"local.crdwindow.host.refresh.{c.os.getuid()}.222")])
        self.assert_google_untouched()

    def test_deadline_bounds_each_subprocess_and_running_check_is_not_duplicated(self):
        """Check command timeout bounds and avoid duplicate job queries after confirmed readiness."""
        c = self.controller
        with patch.object(c.time, "monotonic", return_value=100), patch.object(c.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            with c.command_deadline(2):
                self.real_command("/fixture", timeout=30)
            self.assertEqual(run.call_args.kwargs["timeout"], 2)
        with patch.object(c, "runtime_status", return_value={"confirmed": True, "pid": 222}), patch.object(c, "agent_snapshot") as snapshot:
            self.assertEqual(c.wait_running(0)["pid"], 222)
            snapshot.assert_not_called()

    # --- Log retention, signing and durable state ---

    def test_status_and_restore_prune_expired_log_but_keep_recent_records(self):
        """Check opportunistic event expiry while retaining records within 24 hours."""
        c = self.controller
        path = c.runtime_path("logs/events.jsonl")
        path.parent.mkdir(parents=True)
        now = c.time.time()
        records = [{"event": "expired", "timestampSeconds": now - 86401}, {"event": "recent", "timestampSeconds": now - 10}]
        path.write_text("".join(c.json.dumps(value) + "\n" for value in records))
        c.status()
        self.assertEqual([c.json.loads(line)["event"] for line in path.read_text().splitlines()], ["recent"])
        c.write_json(c.RECEIPT, {"state": "restored", "backendKind": c.BACKEND_KIND})
        c.restore()
        self.assertEqual([c.json.loads(line)["event"] for line in path.read_text().splitlines()], ["recent"])

    def test_requested_signer_is_used_and_never_falls_back_on_error(self):
        """Check that the requested signer is recorded and failures never trigger ad hoc fallback."""
        c = self.controller
        with patch.dict(c.os.environ, {"CRD_SIGN_IDENTITY": "Fixture Local Signing"}):
            c.prepare()
            info = plistlib.loads((c.STAGE / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["CRDSigningIdentity"], "Fixture Local Signing")
            signs = [call for call in self.calls if "--sign" in call]
            self.assertEqual(signs[-1][signs[-1].index("--sign") + 1], "Fixture Local Signing")
            with patch.object(c, "command", side_effect=RuntimeError("identity unavailable")) as run:
                with self.assertRaisesRegex(RuntimeError, "unavailable"):
                    c.sign_own(c.STAGE)
                self.assertEqual(run.call_count, 1)

    def test_bundled_signer_survives_missing_shell_environment(self):
        """Check that GUI-driven preparation uses the signing identity stored in its app bundle."""
        c = self.controller
        app = c.ROOT / "Signed Settings.app"
        backend = app / "Contents/Resources/Backend"
        backend.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CRDSigningIdentity": "Fixture Local Signing"}))
        with patch.object(c, "BUNDLED", True), patch.object(c, "SCRIPT_DIR", backend), patch.dict(c.os.environ, {}, clear=True):
            self.assertEqual(c.signing_identity(), "Fixture Local Signing")

    def test_failed_start_with_pending_restore_keeps_bundle_and_reports_both_errors(self):
        """Check that startup and restoration failures retain the helper and remain separately reported."""
        c = self.controller
        def unconfirmed(*args):
            """Record pending restoration before simulating a readiness failure."""
            c.write_json(c.runtime_path("restore-state.json"), {"pending": True, "pid": 111, "birth": "fixture"})
            raise RuntimeError("fixture readiness failure")
        with patch.object(c, "permission_status", return_value={"accessibility": True}), patch.object(c, "wait_running", side_effect=unconfirmed):
            with self.assertRaisesRegex(RuntimeError, "cleanup_failed"):
                c.install()
        self.assertTrue(c.INSTALLED.exists())
        self.assertFalse(self.services[c.LABEL]["loaded"])
        result = c.status()
        self.assertEqual(result["state"], "cleanup_failed")
        self.assertIn("readiness failure", result["error"])
        self.assertTrue(result["cleanupError"])
        self.assert_google_untouched()

    def test_journal_initialization_never_discards_previous_obligation(self):
        """Check that journal initialization refuses to overwrite pending restoration."""
        c = self.controller
        path = c.runtime_path("restore-state.json")
        c.write_json(path, {"pending": True})
        before = path.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "restoration obligation"):
            c.initialize_restore_journal()
        self.assertEqual(path.read_bytes(), before)

    def test_atomic_write_failure_keeps_previous_file_and_no_pending_file(self):
        """Check that failed atomic replacement preserves the destination and removes pending output."""
        c = self.controller
        path = c.SUPPORT / "fixture.json"
        c.write_json(path, {"old": True})
        before = path.read_bytes()
        with patch.object(c.Path, "replace", side_effect=OSError("fixture replace failure")):
            with self.assertRaises(OSError):
                c.write_json(path, {"new": True})
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(c.SUPPORT.glob(".pending-*")), [])

    def test_different_active_config_is_rejected_before_any_job_mutation(self):
        """Check that active config-path conflicts stop every lifecycle action before job changes."""
        c = self.controller
        c.write_json(c.RECEIPT, {"state": "active", "configPath": str(c.SUPPORT / "config.json"), "backendKind": c.BACKEND_KIND})
        with patch.dict(c.os.environ, {"CRD_WINDOW_CONFIG": str(c.ROOT / "other config.json")}):
            for action in (c.restore, c.restart, c.permissions):
                with self.subTest(action=action.__name__), self.assertRaisesRegex(RuntimeError, "differs"):
                    action()
        self.assertEqual(self.mutations(), [])


if __name__ == "__main__":
    unittest.main()
