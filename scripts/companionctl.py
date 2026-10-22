#!/usr/bin/env python3
"""Manage the external Accessibility overlay; Google host/services stay independent."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from xml.parsers.expat import ExpatError

SCRIPT_DIR = Path(__file__).resolve().parent
SUPPORT = Path.home() / "Library/Application Support/CRDWindowPatch"
BUNDLED = SCRIPT_DIR.name == "Backend"
if BUNDLED:
    # Imported helpers live inside the signed settings app. Never add unsealed .pyc files.
    sys.dont_write_bytecode = True
import file_operations

ROOT = SUPPORT / "staging" if BUNDLED else SCRIPT_DIR.parent
BINARY = SCRIPT_DIR / "OverlayAgent" if BUNDLED else ROOT / "build/OverlayAgent"
INSTALLED = SUPPORT / "CRD Window Host.app"
STAGE = ROOT / "dist/CRD Window Host.app"
RECEIPT = SUPPORT / "companion-install.json"
AGENT = Path.home() / "Library/LaunchAgents/local.crdwindow.host.plist"
LABEL = "local.crdwindow.host"
PERMISSION_LABEL = "local.crdwindow.permissionprobe"
RESTORE_LABEL = "local.crdwindow.restoreprobe"
ORIGINAL_LABEL = "org.chromium.chromoting"
BACKEND_KIND = "accessibility-overlay"
PROTOCOL = 3
EXECUTABLE = "CRDWindowAgent"
CANONICAL = Path("/Library/PrivilegedHelperTools/ChromeRemoteDesktopHost.app")
GOOGLE_REQUIREMENT = ('anchor apple generic and certificate leaf[subject.OU] = "EQHXZ8M8AV" '
                      'and identifier "com.google.chromeremotedesktop.me2me-host"')
DOMAIN = f"gui/{os.getuid()}"
COMMAND_DEADLINE = None
ARCHIVE_LIMIT = 5


# --- Command errors and execution ---

class CompanionError(RuntimeError):
    """Carry a stable error code alongside diagnostic text."""
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def error_payload(error):
    """Stable codes for localization; message is diagnostic detail, never a JSON string."""
    if isinstance(error, CompanionError):
        code = error.code
    elif isinstance(error, (TimeoutError, subprocess.TimeoutExpired)):
        code = "command_timeout"
    elif isinstance(error, PermissionError):
        code = "file_access_denied"
    elif isinstance(error, FileNotFoundError):
        code = "file_not_found"
    elif isinstance(error, OSError):
        code = "file_io_failed"
    elif isinstance(error, (ValueError, plistlib.InvalidFileException, ExpatError)):
        code = "invalid_data"
    else:
        code = "operation_failed"
    return {"error": code, "message": str(error)}


def command(*args, check=True, timeout=30, failure_code="command_failed"):
    """Run a captured command within the shared deadline and classify failures."""
    if COMMAND_DEADLINE is not None:
        timeout = min(timeout, COMMAND_DEADLINE - time.monotonic())
        if timeout <= 0:
            raise TimeoutError("Companion command deadline exceeded")
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise CompanionError(failure_code, f"{Path(str(args[0])).name} 실패 ({result.returncode}): {(result.stderr or result.stdout).strip()}")
    return result


# --- Atomic files and configuration paths ---

def read_json(path):
    """Return decoded JSON, or None when the file is unreadable or invalid."""
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def write_json(path, value):
    write_bytes(path, (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode())


def write_bytes(path, data, mode=0o600):
    """Replace a file atomically with the requested mode and remove pending output."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".pending-", dir=path.parent, delete=False) as temporary:
        temporary.write(data)
        pending = Path(temporary.name)
    try:
        pending.chmod(mode)
        pending.replace(path)
    finally:
        pending.unlink(missing_ok=True)


def config_path():
    """Resolve the selected config, rejecting overrides that conflict with an active receipt."""
    receipt = read_json(RECEIPT) or {}
    override = os.environ.get("CRD_WINDOW_CONFIG")
    selected = Path(override or receipt.get("configPath") or SUPPORT / "config.json").expanduser().resolve()
    if override and receipt.get("state") in ("active", "switching", "cleanup_failed") and receipt.get("configPath"):
        if selected != Path(receipt["configPath"]):
            raise CompanionError("config_path_mismatch", "CRD_WINDOW_CONFIG differs from the active helper's recorded configuration")
    return selected


def runtime_path(name):
    return config_path().parent / name


# --- Command budgets and event retention ---

@contextmanager
def command_deadline(seconds):
    """Temporarily bound subprocess timeouts without extending an enclosing deadline."""
    global COMMAND_DEADLINE
    previous = COMMAND_DEADLINE
    COMMAND_DEADLINE = min(previous or math.inf, time.monotonic() + seconds)
    try:
        yield
    finally:
        COMMAND_DEADLINE = previous


def prune_event_log():
    """Expire records and enforce the size limit under a file lock at existing access points."""
    path = runtime_path("logs/events.jsonl")
    if not path.exists():
        return
    with path.with_suffix(path.suffix + ".lock").open("a") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        with path.open("rb") as stream:
            size = stream.seek(0, 2)
            offset = max(0, size - 1024 * 1024)
            stream.seek(offset)
            raw = stream.read()
        if offset:
            raw = raw.partition(b"\n")[2]
        now = time.time()
        kept = []
        for line in raw.splitlines(keepends=True):
            try:
                value = json.loads(line)
                stamp = value.get("timestampSeconds") if isinstance(value, dict) else None
                if type(stamp) in (int, float) and math.isfinite(stamp) and now - 86400 < stamp <= now + 300:
                    kept.append(line if line.endswith(b"\n") else line + b"\n")
            except (ValueError, UnicodeError):
                pass
        data = b"".join(kept)
        while len(data) > 1024 * 1024:
            kept.pop(0)
            data = b"".join(kept)
        if offset or data != raw:
            write_bytes(path, data)


# --- Artifact discovery and signature verification ---

def digest(path):
    """Hash a file in bounded chunks and return its SHA-256 hex digest."""
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def host_path(explicit=None):
    """Resolve the host path from an explicit argument, environment, receipt or build metadata."""
    receipt = read_json(RECEIPT) or {}
    metadata = read_json(ROOT / "build/original-host.json") or {}
    value = explicit or os.environ.get("CRD_HOST_APP") or receipt.get("originalHostPath") or metadata.get("path")
    return Path(value).expanduser().resolve() if value else CANONICAL


def settings_app_candidates():
    """Return the containing settings app or ordered installation and build candidates."""
    if BUNDLED:
        return [SCRIPT_DIR.parents[2]]
    return [Path.home() / "Applications/CRD Window Studio.app",
            Path("/Applications/CRD Window Studio.app"), ROOT / "dist/CRD Window Studio.app"]


def settings_app_path():
    """Find the first candidate with the settings bundle identifier, skipping unreadable metadata."""
    for candidate in settings_app_candidates():
        try:
            if not candidate.is_dir():
                continue
            info = plistlib.loads((candidate / "Contents/Info.plist").read_bytes())
            if isinstance(info, dict) and info.get("CFBundleIdentifier") == "local.crdwindow.studio":
                return candidate.resolve()
        except (OSError, ValueError, plistlib.InvalidFileException, ExpatError):
            continue
    return None


def verify_original(path):
    """Observe the signed original without loading/copying any Google code."""
    path = path.expanduser().resolve()
    if not path.is_dir():
        raise CompanionError("host_not_found", f"원본 Google 호스트 앱이 없습니다: {path}")
    command("/usr/bin/codesign", "--verify", "--strict", "-R", "=" + GOOGLE_REQUIREMENT, path, failure_code="host_verification_failed")
    metadata = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    executable = path / "Contents/MacOS/remoting_me2me_host"
    signature = command("/usr/bin/codesign", "-dv", "--verbose=4", path, check=False).stderr
    identities = [line for line in signature.splitlines() if line.startswith(("Authority=", "TeamIdentifier=", "Identifier="))]
    return dict(path=str(path), version=metadata.get("CFBundleVersion"),
                hashes={executable.name: digest(executable)}, signature=identities,
                verification="strict Google app publisher; observation only; no version pin")


def signing_identity():
    """Read the explicit or bundled signing identity, defaulting to ad hoc signing."""
    if "CRD_SIGN_IDENTITY" in os.environ:
        return os.environ["CRD_SIGN_IDENTITY"]
    if BUNDLED:
        info = plistlib.loads((SCRIPT_DIR.parents[2] / "Contents/Info.plist").read_bytes())
        return info.get("CRDSigningIdentity", "-")
    return "-"


def sign_own(app):
    """Sign and strictly verify our bundle; a missing identity fails without ad hoc fallback."""
    command("/usr/bin/codesign", "--force", "--sign", signing_identity(), "--options", "0", "--timestamp=none", app, failure_code="signing_failed")
    command("/usr/bin/codesign", "--verify", "--strict", app, failure_code="helper_verification_failed")


def designated_requirement(path):
    """Extract a signed artifact's designated requirement or report a verification failure."""
    result = command("/usr/bin/codesign", "-d", "-r", "-", path, failure_code="helper_verification_failed")
    match = re.search(r"^designated => (.+)$", result.stdout + "\n" + result.stderr, re.MULTILINE)
    if not match:
        raise CompanionError("helper_verification_failed", "The helper has no readable designated requirement")
    return match[1]


def helper_identity(app):
    """Record the executable hash and requirement of a trusted, already signed artifact."""
    return {"sha256": digest(app / "Contents/MacOS" / EXECUTABLE),
            "requirement": designated_requirement(app)}


def verify_helper(app, identity):
    """Require the recorded executable fingerprint, signature and helper bundle identifier."""
    if (not isinstance(identity, dict) or not isinstance(identity.get("requirement"), str) or
            not identity["requirement"] or not isinstance(identity.get("sha256"), str) or
            digest(app / "Contents/MacOS" / EXECUTABLE) != identity["sha256"]):
        raise CompanionError("helper_verification_failed", "The retained helper does not match its signed preparation artifact")
    requirement = f'(identifier "{LABEL}") and ({identity["requirement"]})'
    command("/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, app,
            failure_code="helper_verification_failed")


def verify_installed_helper(receipt):
    """Verify the retained helper; authenticate receipts without a fingerprint using the trusted signer."""
    identity = receipt.get("helperIdentity")
    if identity is not None:
        verify_helper(INSTALLED, identity)
        return
    if receipt.get("schema", 2) >= 3:
        raise CompanionError("helper_verification_failed", "The installed helper fingerprint is missing")
    # Receipts without a fingerprint require the trusted current build's signer,
    # never the installed app's metadata. Normal restore does not launch code
    # and does not need to record a fingerprint.
    command("/usr/bin/codesign", "--verify", "--strict", BINARY, failure_code="helper_verification_failed")
    requirement = designated_requirement(BINARY)
    if "certificate leaf" not in requirement:
        raise CompanionError("helper_verification_failed", "Cannot authenticate an older unrecorded ad hoc helper for execution; retained files were left in place")
    requirement, replacements = re.subn(r'identifier "(?:[^"\\]|\\.)*"', f'identifier "{LABEL}"', requirement, count=1)
    if replacements != 1:
        raise CompanionError("helper_verification_failed", "The trusted build has no helper-compatible designated requirement")
    command("/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, INSTALLED,
            failure_code="helper_verification_failed")
    receipt.update(helperIdentity={"sha256": digest(INSTALLED / "Contents/MacOS" / EXECUTABLE), "requirement": requirement},
                   helperIdentityMigrated=True)
    write_json(RECEIPT, receipt)


# --- Signed helper preparation ---

def prepare(explicit=None):
    """Stage, sign and verify our helper, then publish it without executing it or altering Google files."""
    original = host_path(explicit)
    snapshot = verify_original(original)
    if not BINARY.is_file():
        raise CompanionError("helper_not_built", "먼저 ./scripts/build.sh --backend 로 OverlayAgent를 빌드하세요.")
    (ROOT / "build").mkdir(parents=True, exist_ok=True)
    STAGE.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="overlay-", dir=ROOT / "build") as temporary:
        app = Path(temporary) / STAGE.name
        contents = app / "Contents"
        macos, resources = contents / "MacOS", contents / "Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        shutil.copy2(BINARY, macos / EXECUTABLE)
        # These are our path strings, not copied Google resources/settings.
        paths = {"path": str(original)}
        settings_app = settings_app_path()
        if settings_app is not None:
            paths["settingsAppPath"] = str(settings_app)
        write_json(resources / "original-host.json", paths)
        icon = SCRIPT_DIR.parent / "AppIcon.icns" if BUNDLED else ROOT / "build/AppIcon.icns"
        if icon.is_file():
            shutil.copy2(icon, resources / "AppIcon.icns")
        legal_source = SCRIPT_DIR.parent / "Licenses" if BUNDLED else ROOT
        for relative in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "reference/LICENSE", "reference/README.md", "assets/README.md"):
            target = resources / "Licenses" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(legal_source / relative, target)
        info = dict(CFBundleExecutable=EXECUTABLE, CFBundleIdentifier=LABEL,
                    CFBundleName="CRD Window Host", CFBundleDisplayName="CRD Window Host",
                    CFBundleDevelopmentRegion="en", CFBundleLocalizations=["en", "ko"],
                    CFBundlePackageType="APPL", CFBundleVersion="3", CFBundleShortVersionString="3.0",
                    LSUIElement=True, LSMinimumSystemVersion="14.0", NSPrincipalClass="NSApplication",
                    CRDCompanionProtocolVersion=PROTOCOL, CRDBackendKind=BACKEND_KIND,
                    NSHighResolutionCapable=True, CRDLauncherSourceSHA256=digest(BINARY),
                    CRDSigningIdentity=signing_identity())
        if icon.is_file():
            info["CFBundleIconFile"] = "AppIcon"
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        (contents / "PkgInfo").write_bytes(b"APPL????")
        sign_own(app)
        identity = helper_identity(app)
        file_operations.replace_bundle(app, STAGE, ROOT / "build" / f"previous-overlay-{time.time_ns()}.app")
        # Retry retained copies only after the new stage is signed, verified and published.
        for previous in sorted((ROOT / "build").glob("previous-overlay-*.app")):
            file_operations.trash(previous)
    result = dict(companionPath=str(STAGE), backendKind=BACKEND_KIND, companionProtocolVersion=PROTOCOL,
                  original=snapshot, originalUnmodified=verify_original(original)["hashes"] == snapshot["hashes"],
                  executablePrepared=True, agentExecuted=False, helperIdentity=identity)
    write_json(ROOT / "dist/companion-prepare.json", result)
    return result


# --- User ownership and launchd jobs ---

def current_user():
    """Require the console user and reject root or sudo management commands."""
    if os.geteuid() == 0 or os.environ.get("SUDO_USER"):
        raise CompanionError("gui_user_required", "sudo 없이 현재 로그인한 사용자의 터미널에서 실행하세요.")
    if os.stat("/dev/console").st_uid != os.getuid():
        raise CompanionError("gui_user_required", "현재 GUI에 로그인한 사용자만 보조 에이전트를 관리할 수 있습니다.")


@contextmanager
def locked():
    """Serialize helper management and reject conflicting active configuration paths."""
    config_path()  # Reject a different active configuration before any job mutation.
    SUPPORT.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (SUPPORT / "companion.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise CompanionError("operation_in_progress", "Another helper management command is in progress") from error
        yield


def agent_snapshot(label):
    """Read a launchd job's loaded state and PID without changing it."""
    result = command("/bin/launchctl", "print", f"{DOMAIN}/{label}", check=False)
    match = re.search(r"^\s*pid = (\d+)\s*$", result.stdout, re.MULTILINE)
    return {"loaded": result.returncode == 0, "running": bool(match), "pid": int(match.group(1)) if match else None}


def manage_own_agent(action, probe=False, check=True, recovery=False):
    """Mutation entry point has no caller-supplied label or Google plist path."""
    label = RESTORE_LABEL if recovery else PERMISSION_LABEL if probe else LABEL
    plist = SUPPORT / "restore-probe.plist" if recovery else SUPPORT / "permission-probe.plist" if probe else AGENT
    if action == "bootstrap":
        if plistlib.loads(plist.read_bytes()).get("Label") != label:
            raise CompanionError("agent_identity_mismatch", "자체 LaunchAgent 식별자가 일치하지 않습니다.")
        return command("/bin/launchctl", "bootstrap", DOMAIN, plist, check=check)
    if action not in ("bootout", "enable", "disable"):
        raise ValueError("Unsupported own-agent action")
    return command("/bin/launchctl", action, f"{DOMAIN}/{label}", check=check)


# --- Process identity and runtime status ---

def owned_processes():
    """Find PIDs whose executable path exactly matches the installed helper."""
    expected = str(INSTALLED / "Contents/MacOS" / EXECUTABLE)
    found = {}
    for line in command("/bin/ps", "-ww", "-axo", "pid=,comm=").stdout.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and fields[1] == expected:
            found[int(fields[0])] = fields[1]
    return found


def original_processes(original):
    """Find host PIDs belonging to the current user at the selected executable path."""
    expected = str(Path(original) / "Contents/MacOS/remoting_me2me_host")
    found = []
    for line in command("/bin/ps", "-ww", "-axo", "uid=,pid=,comm=").stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and int(fields[0]) == os.getuid() and fields[2] == expected:
            found.append(int(fields[1]))
    return found


def runtime_status(since=0, original=None):
    """Combine the helper report with live process and job identity checks to confirm readiness."""
    value = read_json(runtime_path("runtime-status.json"))
    if not isinstance(value, dict):
        return {"confirmed": False, "reason": "runtime status unavailable"}
    pid = value.get("pid")
    live = type(pid) is int and owned_processes().get(pid) == str(INSTALLED / "Contents/MacOS" / EXECUTABLE)
    timestamp = value.get("lastEventTimestamp", 0)
    fresh = isinstance(timestamp, (int, float)) and timestamp >= since
    original_pid = value.get("originalPid")
    original_live = type(original_pid) is int and original_pid in original_processes(original or host_path())
    waiting_for_original = "originalPid" in value and original_pid is None
    job = agent_snapshot(LABEL)
    job_matches = job["running"] and job["pid"] == pid
    confirmed = (live and job_matches and fresh and (original_live or waiting_for_original) and value.get("fixture") is False and
                 value.get("backendKind") == BACKEND_KIND and value.get("agentReady") is True and
                 value.get("observerReady") is True)
    fields = ("pid", "originalPid", "backendKind", "agentReady", "observerReady", "originalWindowDetected",
              "originalHidden", "visible", "frame", "mode", "lastEventTimestamp", "fixture",
              "accessibility", "stopActionAvailable", "enabled", "effectiveMode", "detectionReason",
              "restorationPending", "restorationBlocked")
    result = {key: value.get(key) for key in fields}
    result.update(confirmed=confirmed, processMatchesCompanion=live, ownJobProcessMatches=job_matches,
                  originalProcessMatches=original_live, waitingForOriginal=waiting_for_original, fresh=fresh)
    return result


def request_reconcile(*, wait=True):
    """Documented notify(3) IPC to this user's exact running helper, never to Google.

    notifyutil registers for one acknowledgement before posting. The helper coalesces
    requests and acknowledges after writing status. Only this explicit command waits.
    """
    job = agent_snapshot(LABEL)
    if not job["running"]:
        return None
    pid = job["pid"]
    if owned_processes().get(pid) != str(INSTALLED / "Contents/MacOS" / EXECUTABLE):
        return False
    name = f"local.crdwindow.host.refresh.{os.getuid()}.{pid}"
    args = (["-1", name + ".done"] if wait else []) + ["-p", name]
    try:
        command("/usr/bin/notifyutil", *args, timeout=2)
        return True
    except (TimeoutError, subprocess.TimeoutExpired):
        return False


# --- Graceful shutdown and startup confirmation ---

def stop_companion(require_confirmation=True):
    """Stop only our helper, enforcing journal confirmation when required; never use SIGKILL."""
    if agent_snapshot(LABEL)["loaded"]:
        # launchd sends SIGTERM; the overlay restores its own hidden-window state.
        manage_own_agent("bootout")
    for _ in range(20):
        processes = owned_processes()
        if not processes:
            journal_path = runtime_path("restore-state.json")
            journal = read_json(journal_path)
            clear = isinstance(journal, dict) and journal.get("pending") is False
            if (require_confirmation or journal_path.exists()) and not clear:
                raise CompanionError("restoration_unconfirmed", "보조 앱은 종료됐지만 원본 창 표시 복구 상태가 확인되지 않았습니다.")
            return
        for pid in processes:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        time.sleep(0.25)
    # SIGKILL would bypass native restoration of the original window.
    raise CompanionError("helper_stop_failed", "보조 에이전트가 정상 종료되지 않았습니다. 원본 서비스에는 조작을 가하지 않았습니다.")


def wait_running(since, original=None, seconds=10):
    """Wait within a bounded startup deadline for a fresh, confirmed helper report."""
    deadline = time.monotonic() + seconds
    last = {}
    while time.monotonic() < deadline:
        with command_deadline(max(.001, deadline - time.monotonic())):
            last = runtime_status(since, original)
        if last["confirmed"]:
            return last
        time.sleep(0.5)
    raise CompanionError("helper_start_unconfirmed", "외부 보조 에이전트의 PID·AX 관찰 준비를 확인하지 못했습니다.")


# --- Independent permission probes ---

def permission_status(app, *, prompt=False):
    """Probe the helper's permission, prompting only on request, and verify job and process cleanup."""
    job = SUPPORT / "permission-probe.plist"
    output = SUPPORT / "permission-probe.json"
    output.unlink(missing_ok=True)
    if agent_snapshot(PERMISSION_LABEL)["loaded"]:
        manage_own_agent("bootout", probe=True)
    info = dict(Label=PERMISSION_LABEL,
                ProgramArguments=[str(app / "Contents/MacOS" / EXECUTABLE), "--crd-permission-status"] + (["--prompt"] if prompt else []),
                RunAtLoad=True, LimitLoadToSessionType=["Aqua"], StandardOutPath=str(output),
                StandardErrorPath=str(SUPPORT / "permission-probe.stderr.log"))
    write_bytes(job, plistlib.dumps(info))
    probe_pid = None
    try:
        manage_own_agent("bootstrap", probe=True)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            result = read_json(output)
            if isinstance(result, dict) and all(key in result for key in ("accessibility", "pid", "bundleId")):
                if result["bundleId"] != LABEL or type(result["accessibility"]) is not bool or type(result["pid"]) is not int or result["pid"] <= 0:
                    raise CompanionError("permission_probe_invalid", "권한 probe의 앱 식별자 또는 Bool 계약이 일치하지 않습니다.")
                result["executionContext"] = "independent per-user launchd job"
                probe_pid = result["pid"]
                return result
            time.sleep(0.25)
        raise CompanionError("permission_probe_timeout", "launchd 권한 probe가 10초 안에 유효한 상태를 반환하지 않았습니다.")
    finally:
        if probe_pid is None:
            probe_pid = agent_snapshot(PERMISSION_LABEL)["pid"]
        manage_own_agent("bootout", probe=True, check=False)
        if agent_snapshot(PERMISSION_LABEL)["loaded"]:
            raise CompanionError("permission_probe_cleanup_failed", "Permission probe cleanup failed: launchd job remains loaded")
        if probe_pid:
            process = command("/bin/ps", "-p", probe_pid, "-o", "comm=", check=False)
            if process.stdout.strip() == str(app / "Contents/MacOS" / EXECUTABLE):
                raise CompanionError("permission_probe_cleanup_failed", "Permission probe cleanup failed: probe process is still running")
        job.unlink(missing_ok=True)


def permission_preflight(app):
    """Authenticate the installed helper and require a positive, non-prompting permission check."""
    verify_installed_helper(read_json(RECEIPT) or {})
    result = permission_status(app)
    if result.get("accessibility") is not True:
        raise CompanionError("accessibility_required", "외부 보조 앱의 손쉬운 사용 권한이 필요합니다. 시스템 설정에서 직접 허용하세요.")
    return result


# --- Retained helper restoration ---

def cleanup_restoration_probe(probe_pid=None):
    """Unload the restoration probe and remove its plist only after confirming job and process exit."""
    job = SUPPORT / "restore-probe.plist"
    snapshot = agent_snapshot(RESTORE_LABEL)
    probe_pid = probe_pid or snapshot["pid"]
    if snapshot["loaded"]:
        manage_own_agent("bootout", recovery=True, check=False)
    if agent_snapshot(RESTORE_LABEL)["loaded"]:
        raise CompanionError("restoration_unconfirmed", "Restoration-only job cleanup failed; retry disable")
    if probe_pid:
        process = command("/bin/ps", "-p", probe_pid, "-o", "comm=", check=False)
        if process.stdout.strip() == str(INSTALLED / "Contents/MacOS" / EXECUTABLE):
            raise CompanionError("restoration_unconfirmed", "Restoration-only process cleanup failed; retry disable")
    job.unlink(missing_ok=True)


def recover_restoration(receipt):
    """One explicit retry, using the retained signed helper; never replace it or re-hide."""
    global COMMAND_DEADLINE
    verify_installed_helper(receipt)
    job = SUPPORT / "restore-probe.plist"
    output = SUPPORT / "restore-probe.json"
    executable = str(INSTALLED / "Contents/MacOS" / EXECUTABLE)
    cleanup_restoration_probe()
    output.unlink(missing_ok=True)
    info = dict(Label=RESTORE_LABEL,
                ProgramArguments=[executable, "--crd-restore-only", "--crd-host-app", receipt["originalHostPath"]],
                EnvironmentVariables={"CRD_WINDOW_CONFIG": str(config_path())},
                RunAtLoad=True, LimitLoadToSessionType=["Aqua"], StandardOutPath=str(output),
                StandardErrorPath=str(SUPPORT / "restore-probe.stderr.log"))
    write_bytes(job, plistlib.dumps(info))
    probe_pid = None
    try:
        with command_deadline(10):
            manage_own_agent("bootstrap", recovery=True)
            deadline = min(COMMAND_DEADLINE, time.monotonic() + 10)
            while time.monotonic() < deadline:
                result = read_json(output)
                if isinstance(result, dict) and type(result.get("restored")) is bool:
                    if result.get("bundleId") != LABEL or type(result.get("pid")) is not int or result["pid"] <= 0:
                        raise CompanionError("restoration_unconfirmed", "Invalid restoration-only helper result")
                    probe_pid = result["pid"]
                    journal = read_json(runtime_path("restore-state.json"))
                    if not result["restored"] or not isinstance(journal, dict) or journal.get("pending") is not False:
                        raise CompanionError("restoration_unconfirmed", "The original window restoration is still unconfirmed")
                    return
                time.sleep(0.25)
            raise CompanionError("restoration_unconfirmed", "Restoration-only helper did not confirm recovery within 10 seconds")
    finally:
        # Reserve bounded cleanup time even if bootstrap/readiness consumed the command budget.
        previous = COMMAND_DEADLINE
        try:
            COMMAND_DEADLINE = time.monotonic() + 5
            cleanup_restoration_probe(probe_pid)
        finally:
            COMMAND_DEADLINE = previous


# --- Archive generations and bundle publication ---

def archive_installed(reason, receipt):
    """Group the helper, agent and receipt in one archive; roll back partial moves on failure."""
    completed = SUPPORT / "archives" / f"{time.time_ns()}-{reason}"
    directory = completed.with_name(".pending-" + completed.name)
    directory.mkdir(parents=True)
    write_json(directory / RECEIPT.name, receipt)
    moved = []
    try:
        for path in (INSTALLED, AGENT):
            if path.exists():
                path.rename(directory / path.name)
                moved.append(path)
        directory.rename(completed)
    except OSError:
        for path in reversed(moved):
            (directory / path.name).rename(path)
        raise
    return str(completed)


def prune_archives():
    """Keep five completed generations; never prune during uncertain restoration."""
    receipt = read_json(RECEIPT) or {}
    journal_path = runtime_path("restore-state.json")
    journal = read_json(journal_path)
    if receipt.get("state") == "cleanup_failed" or (journal_path.exists() and
            (not isinstance(journal, dict) or journal.get("pending") is not False)):
        return
    generations = []
    for path in (SUPPORT / "archives").glob("*"):
        match = re.fullmatch(r"([0-9]+)-(permission-upgrade|previous|receipt-history|restored|failed)", path.name)
        if match and path.is_dir():
            generations.append((int(match[1]), path))
    for _, path in sorted(generations, reverse=True)[ARCHIVE_LIMIT:]:
        file_operations.trash(path)


def installed_info():
    return plistlib.loads((INSTALLED / "Contents/Info.plist").read_bytes()) if INSTALLED.exists() else {}


def installed_matches_source():
    """Compare installed protocol, backend, signer and build fingerprint to the prepared input."""
    info = installed_info()
    executable = INSTALLED / "Contents/MacOS" / EXECUTABLE
    return (info.get("CRDCompanionProtocolVersion") == PROTOCOL and info.get("CRDBackendKind") == BACKEND_KIND and
            info.get("CRDSigningIdentity", "-") == signing_identity() and
            executable.is_file() and BINARY.is_file() and info.get("CRDLauncherSourceSHA256") == digest(BINARY))


def copy_prepared(reason, identity, previous):
    """Verify a staged copy before archiving the installed generation and publishing the replacement."""
    pending = Path(tempfile.mkdtemp(prefix=".overlay-copy-", dir=SUPPORT)) / INSTALLED.name
    try:
        shutil.copytree(STAGE, pending, symlinks=True)
        verify_helper(pending, identity)
        if INSTALLED.exists() or AGENT.exists():
            archive_installed(reason, previous)
        pending.rename(INSTALLED)
    finally:
        shutil.rmtree(pending.parent, ignore_errors=True)


# --- Permission preparation ---

def permissions(explicit=None, *, prompt=False):
    """Prepare an inactive helper if needed and check its permission without replacing an active helper."""
    current_user()
    with locked():
        receipt = read_json(RECEIPT) or {}
        active = receipt.get("state") in ("active", "switching", "cleanup_failed") or agent_snapshot(LABEL)["loaded"] or bool(owned_processes())
        if not INSTALLED.exists() or not installed_matches_source() or (not active and not receipt.get("helperIdentity")):
            if not active:
                prepared = prepare(explicit)
                initialize_restore_journal()
                copy_prepared("permission-upgrade", prepared["helperIdentity"], receipt)
                receipt = dict(schema=3, state="prepared", backendKind=BACKEND_KIND,
                               companionProtocolVersion=PROTOCOL, companionPath=str(INSTALLED),
                               originalHostPath=prepared["original"]["path"], configPath=str(config_path()),
                               helperIdentity=prepared["helperIdentity"], startAttempted=False)
                write_json(RECEIPT, receipt)
            elif installed_info().get("CRDCompanionProtocolVersion") != PROTOCOL:
                raise CompanionError("helper_upgrade_blocked", "호환되지 않는 보조 에이전트가 실행 중입니다. 실행 중인 앱을 덮어쓰지 않습니다.")
        info = installed_info()
        if info.get("CRDCompanionProtocolVersion") != PROTOCOL:
            raise CompanionError("helper_not_prepared", "외부 보조 에이전트를 먼저 준비하세요.")
        verify_installed_helper(receipt)
        result = permission_status(INSTALLED, prompt=prompt)
        # The subsequent GUI status call can share the same coalesced reconciliation.
        result["runtimeRefreshRequested"] = request_reconcile(wait=False)
        result.update(companionProtocolVersion=PROTOCOL, backendKind=BACKEND_KIND,
                      identityLayoutUpgradeDeferred=bool(active and not installed_matches_source()))
        prune_archives()
        return result


# --- Installation records and failure recovery ---

def write_agent(original):
    """Write our per-user launchd job with the selected host and configuration paths."""
    AGENT.parent.mkdir(parents=True, exist_ok=True)
    info = dict(Label=LABEL, ProgramArguments=[str(INSTALLED / "Contents/MacOS" / EXECUTABLE), "--crd-host-app", str(original)],
                RunAtLoad=True, KeepAlive={"SuccessfulExit": False}, ThrottleInterval=5, LimitLoadToSessionType=["Aqua"],
                StandardOutPath=str(SUPPORT / "companion.stdout.log"), StandardErrorPath=str(SUPPORT / "companion.stderr.log"),
                EnvironmentVariables={"CRD_WINDOW_CONFIG": str(config_path())})
    write_bytes(AGENT, plistlib.dumps(info), 0o644)


def initialize_restore_journal():
    """Create a clear journal only when no recorded restoration obligation remains."""
    path = runtime_path("restore-state.json")
    if path.exists():
        existing = read_json(path)
        if not isinstance(existing, dict) or existing.get("pending") is not False:
            raise CompanionError("restoration_unconfirmed", "Existing restoration obligation must be resolved before starting")
        return
    previous = read_json(runtime_path("runtime-status.json")) or {}
    if not isinstance(previous, dict):
        raise CompanionError("restoration_unconfirmed", "Previous runtime status is malformed; cannot initialize restoration journal")
    if previous.get("originalHidden") is True or previous.get("restorationPending") is True:
        raise CompanionError("restoration_unconfirmed", "Previous hidden state is unconfirmed; cannot initialize restoration journal")
    # No helper is running during install. Every native hide writes pending first.
    write_json(path, {"pending": False})


def failure_cleanup(receipt, error):
    """Record an action failure, stopping and archiving the helper only when restoration is confirmed."""
    try:
        if AGENT.exists():
            manage_own_agent("disable")
        stop_companion(require_confirmation=receipt.get("startAttempted", False) or receipt.get("state") == "active")
        receipt["archivePath"] = archive_installed("failed", dict(receipt, state="rolled_back"))
        receipt["state"] = "rolled_back"
    except Exception as cleanup_error:
        receipt["state"] = "cleanup_failed"
        receipt["cleanupError"] = str(cleanup_error)
        receipt["cleanupErrorCode"] = error_payload(cleanup_error)["error"]
    receipt["error"] = str(error)
    receipt["errorCode"] = error_payload(error)["error"]
    write_json(RECEIPT, receipt)
    if receipt["state"] == "rolled_back":
        try:
            prune_archives()
        except OSError as cleanup_error:
            receipt.update(cleanupError=str(cleanup_error), cleanupErrorCode=error_payload(cleanup_error)["error"])
            write_json(RECEIPT, receipt)


# --- Helper lifecycle commands ---

def install(explicit=None):
    """Publish a recovery receipt, verify permission, start our helper and confirm readiness or clean up."""
    current_user()
    with locked():
        previous = read_json(RECEIPT) or {}
        if previous.get("state") in ("active", "switching", "cleanup_failed") or agent_snapshot(LABEL)["loaded"] or owned_processes():
            raise CompanionError("helper_already_active", "보조 에이전트가 실행 중이거나 정리 기록이 있습니다. status/restore를 먼저 확인하세요.")
        prepared = prepare(explicit)
        original = prepared["original"]
        initialize_restore_journal()
        started = time.time()
        receipt = dict(schema=3, state="switching", backendKind=BACKEND_KIND, companionProtocolVersion=PROTOCOL,
                       companionPath=str(INSTALLED), originalHostPath=original["path"], label=LABEL,
                       originalSnapshot=original, originalServiceObserved=agent_snapshot(ORIGINAL_LABEL),
                       installedAt=started, installedAtISO=datetime.now(timezone.utc).isoformat(),
                       configPath=str(config_path()), startAttempted=False, helperIdentity=prepared["helperIdentity"])
        # A recoverable record precedes any replacement or RunAtLoad publication.
        write_json(RECEIPT, receipt)
        try:
            copy_prepared("previous", prepared["helperIdentity"], previous)
            receipt["permissions"] = permission_preflight(INSTALLED)
            write_agent(original["path"])
            manage_own_agent("enable")
            receipt["startAttempted"] = True
            write_json(RECEIPT, receipt)
            manage_own_agent("bootstrap")
            receipt["runtime"] = wait_running(started, original["path"])
            receipt["state"] = "active"
            write_json(RECEIPT, receipt)
        except Exception as error:
            # Reserve time for cleanup even if the action used its whole deadline.
            global COMMAND_DEADLINE
            COMMAND_DEADLINE = time.monotonic() + 10
            failure_cleanup(receipt, error)
            raise CompanionError(error_payload(error)["error"], f"보조 에이전트 시작 실패; 정리 상태={receipt['state']}: {error}; {receipt.get('cleanupError', '')}") from error
        prune_archives()
        return receipt


def restore():
    """Stop our helper and archive it after restoration; retain recovery files if confirmation fails."""
    current_user()
    with locked():
        prune_event_log()
        receipt = read_json(RECEIPT)
        if not receipt:
            raise CompanionError("install_record_missing", "정리할 보조 에이전트 기록이 없습니다.")
        if receipt.get("backendKind") != BACKEND_KIND:
            if receipt.get("state") in ("restored", "rolled_back"):
                return dict(receipt, legacyReceipt=True, originalServiceUntouched=True)
            raise CompanionError("legacy_install_record", "이 도구가 지원하지 않는 설치 기록입니다. 원본 서비스를 자동 조작하지 않습니다.")
        if receipt.get("state") == "restored" and not agent_snapshot(LABEL)["loaded"] and not owned_processes():
            prune_archives()
            return receipt
        try:
            try:
                stop_companion()
            except CompanionError as error:
                if error.code != "restoration_unconfirmed" or receipt.get("state") != "cleanup_failed":
                    raise
                recover_restoration(receipt)
            if (SUPPORT / "restore-probe.plist").exists():
                cleanup_restoration_probe()
            receipt["archivePath"] = archive_installed("restored", dict(receipt, state="restored"))
        except Exception as error:
            receipt.update(state="cleanup_failed", cleanupError=str(error), cleanupErrorCode=error_payload(error)["error"])
            write_json(RECEIPT, receipt)
            raise
        receipt.update(state="restored", restoredAt=time.time(), originalServiceUntouched=True)
        for key in ("cleanupError", "error", "cleanupErrorCode", "errorCode"):
            receipt.pop(key, None)
        write_json(RECEIPT, receipt)
        prune_archives()
        return receipt


def restart():
    """Check permission before stopping our active helper, then restart it and verify readiness."""
    current_user()
    with locked():
        receipt = read_json(RECEIPT) or {}
        if receipt.get("state") != "active" or receipt.get("backendKind") != BACKEND_KIND:
            raise CompanionError("helper_not_active", "실행 중인 외부 보조 에이전트 기록이 없습니다.")
        receipt["originalSnapshot"] = verify_original(Path(receipt["originalHostPath"]))
        permission_preflight(INSTALLED)
        started = time.time()
        try:
            stop_companion()
            manage_own_agent("bootstrap")
            receipt["runtime"] = wait_running(started, receipt["originalHostPath"])
            receipt["installedAt"] = started
            write_json(RECEIPT, receipt)
        except Exception as error:
            global COMMAND_DEADLINE
            COMMAND_DEADLINE = time.monotonic() + 10
            failure_cleanup(receipt, error)
            raise
        return receipt


def status(explicit=None):
    """Prune expired events and return installation, host and refreshed helper status."""
    prune_event_log()
    receipt = read_json(RECEIPT) or {}
    original = host_path(explicit)
    try:
        observation = verify_original(original)
        old = receipt.get("originalSnapshot") or {}
        observation["changedSinceInstall"] = bool(old and observation["hashes"] != old.get("hashes"))
    except Exception as error:
        observation = {"path": str(original), "verified": False, "error": str(error), "errorCode": error_payload(error)["error"]}
    refreshed = request_reconcile()
    runtime = runtime_status(receipt.get("installedAt", 0), original)
    runtime["refreshConfirmed"] = refreshed
    if refreshed is False:
        runtime.update(confirmed=False, reason="Running helper did not acknowledge status refresh")
    return dict(receiptPath=str(RECEIPT), state=receipt.get("state", "not_installed"), backendKind=BACKEND_KIND,
                companionPath=str(INSTALLED), original=observation, companionService=agent_snapshot(LABEL),
                originalService=agent_snapshot(ORIGINAL_LABEL), runtime=runtime,
                configPath=str(config_path()), error=receipt.get("error"), cleanupError=receipt.get("cleanupError"),
                errorCode=receipt.get("errorCode"), cleanupErrorCode=receipt.get("cleanupErrorCode"),
                originalBundleModifiedByCompanion=False, originalServiceManaged=False)


# --- JSON command-line interface ---

class ArgumentParser(argparse.ArgumentParser):
    """Report invalid arguments as JSON with the controller's stable error contract."""
    def error(self, message):
        self.exit(2, json.dumps({"error": "invalid_arguments", "message": message}, ensure_ascii=False) + "\n")


def main():
    """Dispatch one bounded controller action and emit JSON results or classified errors."""
    parser = ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("action", choices=("prepare", "status", "permissions", "install", "restore", "restart"))
    parser.add_argument("--json", action="store_true", help="JSON 출력(기본값; GUI 호출 호환)")
    parser.add_argument("--host-app", type=Path, help="원본 Google 앱; 생략하면 CRD_HOST_APP 또는 기본 설치 경로")
    parser.add_argument("--prompt", action="store_true", help="Request macOS Accessibility permission (permissions only)")
    args = parser.parse_args()
    if args.prompt and args.action != "permissions":
        parser.error("--prompt is only supported with permissions")
    try:
        with command_deadline(60):
            if args.action == "permissions":
                result = permissions(args.host_app, prompt=args.prompt)
            else:
                result = globals()[args.action](args.host_app) if args.action in ("prepare", "status", "install") else globals()[args.action]()
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except Exception as error:
        print(json.dumps(error_payload(error), ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
