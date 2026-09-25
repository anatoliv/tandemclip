#!/usr/bin/env python3
"""Prove one TandemClip Crashbox rollout from the artifacts that actually run.

The controller owns the facts. It never accepts a project, release, reporting
mode, rollback result, protected key path, proof UUID, or timestamp from the
operator. It derives those values from the signed candidate and retained
reporting-disabled rollback, performs the switch itself, and gives the bounded
receipt pair to Crashbox's installed protected publisher and signer.

``preflight`` is read-only. ``prove`` restarts TandemClip twice, briefly runs
the reporting-disabled rollback, restores the exact original candidate bundle,
and publishes the records. A mode-0600 journal is written before mutation. On
failure the controller restores the original candidate and retains the journal.
"""

from __future__ import annotations

import argparse
import copy
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import tempfile
import time
import uuid
from typing import Any, Iterator


PROJECT = "tandemclip-macos"
PROTECTED_KEY_PATH = "/protected/crashbox/project-keys/tandemclip-macos.key"
UNIT = "TandemClip.app"
BUNDLE_ID = "com.tandemclip"
INSTALLED_APP = Path("/Applications/TandemClip.app")
PUBLISHER = "/usr/local/libexec/crashbox-publish-receipts"
PUBLISH_HOST_ENV = "TANDEMCLIP_CRASHBOX_PUBLISH_HOST"
MAX_REQUEST_BYTES = 64 * 1024
MAX_APP_ENTRIES = 20_000
MAX_APP_BYTES = 1024 * 1024 * 1024
COMMIT = re.compile(r"^[0-9a-f]{40}$")
VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+)*$")
BUILD = re.compile(r"^[0-9]+$")
TEAM = re.compile(r"^[A-Z0-9]{10}$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
RECEIPT_TOKEN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+~-]{0,199}$")


class Refused(Exception):
    """A stable refusal that does not disclose a DSN or command output."""


def _run(
    arguments: list[str],
    *,
    input_bytes: bytes | None = None,
    timeout: int = 60,
) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            arguments,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
            timeout=timeout,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "C",
                "LC_ALL": "C",
            },
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise Refused("command_failed") from exc


def _canonical(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("ascii")


def _receipt_archive(pair: dict[str, object]) -> str:
    configuration = _canonical(pair["configuration"])
    rollback = _canonical(pair["rollback"])
    return "sha256:" + hashlib.sha256(
        b"crashbox-rollout-receipt-archive-v1\0"
        + configuration
        + b"\0"
        + rollback
    ).hexdigest()


def _timestamp(moment: dt.datetime | None = None) -> str:
    value = (moment or dt.datetime.now(dt.UTC)).astimezone(dt.UTC)
    rendered = value.strftime("%Y-%m-%dT%H:%M:%S")
    if value.microsecond:
        rendered += f".{value.microsecond:06d}"
    return rendered + "Z"


def _regular(path: Path, *, maximum: int = MAX_APP_BYTES) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise Refused("artifact_unavailable") from exc
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or not 0 < metadata.st_size <= maximum
    ):
        raise Refused("artifact_invalid")
    return metadata


def _tree_digest(root: Path) -> str:
    try:
        root_metadata = root.lstat()
    except OSError as exc:
        raise Refused("app_unavailable") from exc
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        raise Refused("app_invalid")
    entries: list[Path] = []
    total = 0
    for directory, names, files in os.walk(root, followlinks=False):
        base = Path(directory)
        for name in sorted((*names, *files), key=os.fsencode):
            entries.append(base / name)
            if len(entries) > MAX_APP_ENTRIES:
                raise Refused("app_too_large")
    digest = hashlib.sha256()
    for path in sorted(entries, key=lambda item: os.fsencode(str(item.relative_to(root)))):
        relative = os.fsencode(str(path.relative_to(root)))
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISLNK(metadata.st_mode):
            kind = b"link"
            body = os.fsencode(os.readlink(path))
        elif stat.S_ISDIR(metadata.st_mode):
            kind = b"directory"
            body = b""
        elif stat.S_ISREG(metadata.st_mode):
            kind = b"file"
            total += metadata.st_size
            if total > MAX_APP_BYTES:
                raise Refused("app_too_large")
            file_digest = hashlib.sha256()
            with path.open("rb") as handle:
                while chunk := handle.read(1024 * 1024):
                    file_digest.update(chunk)
            body = file_digest.digest()
        else:
            raise Refused("app_entry_invalid")
        for value in (kind, relative, str(mode).encode("ascii"), body):
            digest.update(len(value).to_bytes(8, "big"))
            digest.update(value)
    return "sha256:" + digest.hexdigest()


def _codesign_team(app: Path) -> str:
    _run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    result = _run(["/usr/bin/codesign", "-d", "--verbose=4", str(app)])
    text = result.stderr.decode("utf-8", "replace")
    matches = [
        line.removeprefix("TeamIdentifier=")
        for line in text.splitlines()
        if line.startswith("TeamIdentifier=")
    ]
    if len(matches) != 1 or TEAM.fullmatch(matches[0]) is None:
        raise Refused("signer_identity_invalid")
    return matches[0]


def _identity_from_info(info: dict[str, Any], *, reporting: bool) -> dict[str, object]:
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    source = info.get("TandemClipSourceCommit")
    configured = info.get("CrashboxDSN")
    if (
        info.get("CFBundleIdentifier") != BUNDLE_ID
        or not isinstance(version, str)
        or VERSION.fullmatch(version) is None
        or not isinstance(build, str)
        or BUILD.fullmatch(build) is None
        or not isinstance(source, str)
        or COMMIT.fullmatch(source) is None
        or "SentryDSN" in info
    ):
        raise Refused("app_identity_invalid")
    if reporting:
        if not isinstance(configured, str) or not configured.strip():
            raise Refused("candidate_reporting_not_configured")
    elif configured not in (None, ""):
        raise Refused("rollback_reporting_not_disabled")
    return {
        "version": version,
        "build": build,
        "source_commit": source,
        "release": f"com.tandemclip@{version}+{build}.{source}",
        "reporting_configured": reporting,
    }


def _verify_app(app: Path, *, reporting: bool) -> dict[str, object]:
    info_path = app / "Contents/Info.plist"
    _regular(info_path, maximum=1024 * 1024)
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise Refused("app_metadata_invalid") from exc
    if not isinstance(info, dict):
        raise Refused("app_metadata_invalid")
    identity = _identity_from_info(info, reporting=reporting)
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or "/" in executable:
        raise Refused("app_identity_invalid")
    binary = app / "Contents/MacOS" / executable
    _regular(binary)
    _run(["/usr/bin/lipo", str(binary), "-verify_arch", "arm64"])
    team = _codesign_team(app)
    _run(["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)])
    _run(["/usr/bin/xcrun", "stapler", "validate", str(app)], timeout=120)
    return {**identity, "team_id": team, "tree_sha256": _tree_digest(app)}


@contextlib.contextmanager
def _mounted_app(
    dmg: Path, *, reporting: bool
) -> Iterator[tuple[Path, dict[str, object]]]:
    _regular(dmg)
    _run(["/usr/bin/codesign", "--verify", str(dmg)])
    _run(["/usr/bin/hdiutil", "verify", str(dmg)], timeout=180)
    _run(["/usr/bin/xcrun", "stapler", "validate", str(dmg)], timeout=120)
    mount = Path(tempfile.mkdtemp(prefix="tandemclip-rollout-mount.", dir="/tmp"))
    try:
        _run(
            [
                "/usr/bin/hdiutil",
                "attach",
                "-readonly",
                "-nobrowse",
                "-owners",
                "off",
                "-mountpoint",
                str(mount),
                str(dmg),
            ],
            timeout=120,
        )
        apps = [
            item
            for item in mount.iterdir()
            if item.suffix == ".app" and not item.is_symlink()
        ]
        if len(apps) != 1:
            raise Refused("dmg_app_invalid")
        yield apps[0], _verify_app(apps[0], reporting=reporting)
    finally:
        subprocess.run(
            ["/usr/bin/hdiutil", "detach", str(mount)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
            check=False,
        )
        with contextlib.suppress(OSError):
            mount.rmdir()


def _repository_commit(root: Path, commit: str) -> None:
    if COMMIT.fullmatch(commit) is None:
        raise Refused("source_commit_invalid")
    _run(["/usr/bin/git", "-C", str(root), "cat-file", "-e", f"{commit}^{{commit}}"])


def _controller_commit(root: Path) -> str:
    head = _run(["/usr/bin/git", "-C", str(root), "rev-parse", "HEAD"]).stdout.decode().strip()
    if COMMIT.fullmatch(head) is None:
        raise Refused("controller_repository_invalid")
    dirty = _run(["/usr/bin/git", "-C", str(root), "status", "--porcelain"]).stdout
    if dirty:
        raise Refused("controller_repository_dirty")
    return head


def _remote_preflight(host: str) -> str | None:
    result = _run(["/usr/bin/ssh", host, "sudo", PUBLISHER, "preflight"], timeout=30)
    try:
        value = json.loads(result.stdout)
    except (UnicodeError, ValueError) as exc:
        raise Refused("publisher_preflight_invalid") from exc
    previous = value.get("previous_receipts_archive") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or set(value) != {"ready", "previous_receipts_archive"}
        or value.get("ready") is not True
        or (
            previous is not None
            and (not isinstance(previous, str) or SHA256.fullmatch(previous) is None)
        )
    ):
        raise Refused("publisher_preflight_invalid")
    return previous


def _receipt_pair(
    candidate: dict[str, object],
    *,
    proof_id: str,
    candidate_at: str,
    rollback_at: str,
    changed_at: str,
) -> dict[str, object]:
    try:
        parsed = uuid.UUID(proof_id)
    except (TypeError, ValueError) as exc:
        raise Refused("proof_id_invalid") from exc
    if str(parsed) != proof_id:
        raise Refused("proof_id_invalid")
    release = candidate.get("release")
    if (
        not isinstance(release, str)
        or not release.startswith("com.tandemclip@")
        or RECEIPT_TOKEN.fullmatch(release) is None
    ):
        raise Refused("candidate_identity_invalid")
    moments = []
    for value in (candidate_at, rollback_at, changed_at):
        try:
            moments.append(dt.datetime.fromisoformat(value))
        except (TypeError, ValueError) as exc:
            raise Refused("receipt_timestamp_invalid") from exc
    if (
        not moments[0] < moments[1] < moments[2]
        or moments[2] - moments[1] > dt.timedelta(hours=24)
    ):
        raise Refused("receipt_chronology_invalid")
    return {
        "configuration": {
            "schema_version": 1,
            "proof_id": proof_id,
            "project": PROJECT,
            "candidate_identity": release,
            "protected_key_path": PROTECTED_KEY_PATH,
            "reporting_mode": "enabled",
            "asset_origin": None,
            "candidate_first_activated_at": candidate_at,
            "configuration_changed_at": changed_at,
        },
        "rollback": {
            "schema_version": 1,
            "proof_id": proof_id,
            "project": PROJECT,
            "candidate_identity": release,
            "unit": UNIT,
            "target": "reporting-disabled",
            "mode": "reporting-disabled",
            "result": "reporting-disabled-verified",
            "health": "ready",
            "completed_at": rollback_at,
        },
    }


REMOTE_PUBLISHER = r'''
import hashlib,json,os,pathlib,subprocess,sys,tempfile
publisher="/usr/local/libexec/crashbox-publish-receipts"
producer="/usr/local/libexec/crashbox-rollout-evidence"
state=pathlib.Path("/var/lib/crashbox-rollout-evidence")
signed=pathlib.Path("/protected/crashbox/signed-records")
raw=sys.stdin.buffer.read(65537)
if os.geteuid()!=0 or not 0<len(raw)<=65536: raise SystemExit(2)
request=json.loads(raw.decode("ascii"))
if set(request)!={"schema_version","expected_previous_archive","configuration","rollback"} or request["schema_version"]!=1: raise SystemExit(2)
c=request["configuration"]; r=request["rollback"]
if c.get("project")!="tandemclip-macos" or c.get("protected_key_path")!="/protected/crashbox/project-keys/tandemclip-macos.key" or c.get("asset_origin") is not None or r.get("unit")!="TandemClip.app" or r.get("mode")!="reporting-disabled" or r.get("target")!="reporting-disabled": raise SystemExit(2)
canonical=lambda v:(json.dumps(v,sort_keys=True,separators=(",",":"))+"\n").encode("ascii")
cb=canonical(c); rb=canonical(r)
digest=lambda b:"sha256:"+hashlib.sha256(b).hexdigest()
previous=request["expected_previous_archive"]
prevarg=previous if previous is not None else "none"
recover=subprocess.run([publisher,"recover","--configuration-sha256",digest(cb),"--rollback-sha256",digest(rb),"--previous-archive",prevarg],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
recovered=json.loads(recover.stdout) if recover.returncode==0 else None
if not isinstance(recovered,dict) or recovered.get("state")!="published":
    work=pathlib.Path(tempfile.mkdtemp(prefix=".controller.",dir=state)); os.chmod(work,0o700)
    try:
        for name,body in (("configuration.json",cb),("rollback.json",rb)):
            path=work/name; fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
            try: os.write(fd,body); os.fsync(fd)
            finally: os.close(fd)
        result=subprocess.run([publisher,"publish","--configuration",str(work/"configuration.json"),"--rollback",str(work/"rollback.json"),"--expected-previous-archive",prevarg],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
        if result.returncode!=0: print(result.stdout.strip()); raise SystemExit(2)
    finally:
        for name in ("configuration.json","rollback.json"):
            try: (work/name).unlink()
            except FileNotFoundError: pass
        work.rmdir()
export=subprocess.run([producer],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
if export.returncode!=0: raise SystemExit(2)
document=json.loads(export.stdout)
if document.get("exported") is not True or document.get("schema_version")!=1: raise SystemExit(2)
proof=c["proof_id"]
def durable(path,body,replace):
    tmp=path.with_name(path.name+".publishing")
    fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o644)
    try: os.write(fd,body); os.fsync(fd)
    finally: os.close(fd)
    if replace: os.replace(tmp,path)
    else:
        try: os.link(tmp,path)
        except FileExistsError:
            if path.read_bytes()!=body: raise
        tmp.unlink()
    d=os.open(path.parent,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)); os.fsync(d); os.close(d)
for label,stem in (("configuration_readback","configuration-readback"),("rollback_readback","rollback-readback")):
    record=document[label]; body=canonical(record)
    canonical_path=signed/(stem+".json")
    if canonical_path.exists():
        old=json.loads(canonical_path.read_text(encoding="ascii")); oldproof=old.get("payload",{}).get("proof_id")
        if isinstance(oldproof,str): durable(signed/(stem+"."+oldproof+".json"),canonical(old),False)
    durable(signed/(stem+"."+proof+".json"),body,False)
    durable(canonical_path,body,True)
print(json.dumps({"published":True,"proof_id":proof,"configuration_record":str(signed/("configuration-readback."+proof+".json")),"rollback_record":str(signed/("rollback-readback."+proof+".json"))},sort_keys=True,separators=(",",":")))
'''


def _remote_publish(
    host: str, pair: dict[str, object], previous: str | None
) -> dict[str, object]:
    request = _canonical(
        {
            "schema_version": 1,
            "expected_previous_archive": previous,
            **pair,
        }
    )
    if len(request) > MAX_REQUEST_BYTES:
        raise Refused("publisher_request_invalid")
    remote_command = " ".join(
        shlex.quote(value)
        for value in ("sudo", "/usr/bin/python3", "-c", REMOTE_PUBLISHER)
    )
    try:
        result = subprocess.run(
            ["/usr/bin/ssh", host, remote_command],
            input=request,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=60,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "C",
                "LC_ALL": "C",
            },
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise Refused("publisher_command_failed") from exc
    if result.returncode != 0:
        try:
            failure = json.loads(result.stdout)
        except (UnicodeError, ValueError):
            failure = None
        if (
            isinstance(failure, dict)
            and set(failure) == {"completed", "error"}
            and failure.get("completed") is False
            and isinstance(failure.get("error"), str)
            and RECEIPT_TOKEN.fullmatch(failure["error"]) is not None
        ):
            raise Refused("publisher_" + failure["error"])
        raise Refused("publisher_failed")
    try:
        value = json.loads(result.stdout)
    except (UnicodeError, ValueError) as exc:
        raise Refused("publisher_result_invalid") from exc
    configuration = pair.get("configuration")
    if (
        not isinstance(value, dict)
        or not isinstance(configuration, dict)
        or value.get("published") is not True
        or value.get("proof_id") != configuration.get("proof_id")
    ):
        raise Refused("publisher_result_invalid")
    return value


def _running_instances() -> dict[int, dt.datetime]:
    result = _run(["/bin/ps", "-axo", "pid=,lstart=,comm="])
    expected = str(INSTALLED_APP / "Contents/MacOS/tandemclip")
    instances: dict[int, dt.datetime] = {}
    for line in result.stdout.decode("utf-8", "replace").splitlines():
        fields = line.strip().split(None, 6)
        if len(fields) == 7 and fields[6] == expected:
            try:
                started = dt.datetime.strptime(
                    " ".join(fields[1:6]), "%a %b %d %H:%M:%S %Y"
                ).astimezone(dt.UTC)
                instances[int(fields[0])] = started
            except (ValueError, OverflowError):
                raise Refused("app_process_identity_invalid") from None
    return instances


def _running_pids() -> set[int]:
    return set(_running_instances())


def _candidate_started_at() -> dt.datetime:
    instances = _running_instances()
    if len(instances) != 1:
        raise Refused("candidate_process_ambiguous")
    return next(iter(instances.values()))


def _wait_running(expected: bool, *, previous: set[int] | None = None) -> set[int]:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        observed = _running_pids()
        if expected and observed and (previous is None or observed.isdisjoint(previous)):
            time.sleep(2)
            if _running_pids() == observed:
                return observed
        if not expected and not observed:
            return set()
        time.sleep(0.25)
    raise Refused("app_health_timeout")


def _quit() -> None:
    _run(["/usr/bin/osascript", "-e", 'tell application id "com.tandemclip" to quit'])
    _wait_running(False)


def _launch(previous: set[int]) -> None:
    _run(["/usr/bin/open", "-a", str(INSTALLED_APP)])
    _wait_running(True, previous=previous)


def _copy_app(source: Path, destination: Path) -> None:
    if destination.exists() or destination.is_symlink():
        raise Refused("rollout_slot_exists")
    _run(["/usr/bin/ditto", str(source), str(destination)], timeout=180)


def _replace_with_rollback(
    rollback: Path, proof_id: str, candidate: dict[str, object]
) -> tuple[Path, Path]:
    parent = INSTALLED_APP.parent
    candidate_slot = parent / f".TandemClip.rollout.{proof_id}.candidate.app"
    rollback_slot = parent / f".TandemClip.rollout.{proof_id}.rollback.app"
    _copy_app(rollback, rollback_slot)
    copied = _verify_app(rollback_slot, reporting=False)
    if copied["tree_sha256"] != _tree_digest(rollback):
        raise Refused("rollback_copy_changed")
    previous = _running_pids()
    if not previous:
        raise Refused("candidate_not_running")
    _quit()
    os.rename(INSTALLED_APP, candidate_slot)
    os.rename(rollback_slot, INSTALLED_APP)
    _launch(previous)
    installed = _verify_app(INSTALLED_APP, reporting=False)
    if installed["team_id"] != candidate["team_id"]:
        raise Refused("rollback_signer_mismatch")
    return candidate_slot, rollback_slot


def _restore_candidate(
    candidate_slot: Path, rollback_slot: Path, candidate: dict[str, object]
) -> None:
    if INSTALLED_APP.exists():
        try:
            installed = _verify_app(INSTALLED_APP, reporting=True)
        except Refused:
            # The expected state during the proof is the deliberately
            # reporting-disabled rollback. It cannot pass candidate validation,
            # but that is the reason restoration is required, not a reason to
            # abandon it in /Applications.
            pass
        else:
            if installed.get("tree_sha256") == candidate.get("tree_sha256"):
                return
    previous = _running_pids()
    if previous:
        _quit()
    if INSTALLED_APP.exists():
        os.rename(INSTALLED_APP, rollback_slot)
    if not candidate_slot.exists():
        raise Refused("candidate_recovery_unavailable")
    os.rename(candidate_slot, INSTALLED_APP)
    _launch(previous)
    installed = _verify_app(INSTALLED_APP, reporting=True)
    if installed.get("tree_sha256") != candidate.get("tree_sha256"):
        raise Refused("candidate_recovery_failed")


def _write_json(path: Path, value: dict[str, object], *, exclusive: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    raw = _canonical(value)
    if exclusive:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(descriptor, raw)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    else:
        temporary = path.with_name(path.name + ".writing")
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(descriptor, raw)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, path)


def _inspect(
    args: argparse.Namespace,
) -> tuple[dict[str, object], dict[str, object], str | None, str]:
    root = Path(__file__).resolve().parents[1]
    controller = _controller_commit(root)
    with _mounted_app(args.candidate_dmg, reporting=True) as (_, candidate), _mounted_app(
        args.rollback_dmg, reporting=False
    ) as (_, rollback):
        if candidate["team_id"] != rollback["team_id"]:
            raise Refused("rollback_signer_mismatch")
        _repository_commit(root, str(candidate["source_commit"]))
        _repository_commit(root, str(rollback["source_commit"]))
        installed = _verify_app(INSTALLED_APP, reporting=True)
        if installed["tree_sha256"] != candidate["tree_sha256"]:
            raise Refused("installed_candidate_mismatch")
        _candidate_started_at()
        previous = _remote_preflight(args.publish_host)
        return candidate, rollback, previous, controller


def _preflight(args: argparse.Namespace) -> dict[str, object]:
    candidate, rollback, previous, controller = _inspect(args)
    return {
        "completed": True,
        "dry_run": True,
        "project": PROJECT,
        "candidate_identity": candidate["release"],
        "candidate_source": candidate["source_commit"],
        "rollback_source": rollback["source_commit"],
        "controller_commit": controller,
        "previous_receipts_archive": previous,
        "restart_required": True,
    }


def _aliased_candidate_identity(candidate: dict[str, object]) -> str:
    version = candidate.get("version")
    build = candidate.get("build")
    source = candidate.get("source_commit")
    if not all(isinstance(value, str) for value in (version, build, source)):
        raise Refused("candidate_identity_invalid")
    return f"com.tandemclip:{version}:{build}:{source}"


def _resume_journal(
    state_directory: Path,
    *,
    candidate: dict[str, object],
    rollback: dict[str, object],
    previous: str | None,
) -> tuple[Path, dict[str, object], dict[str, object]]:
    eligible: list[tuple[Path, dict[str, object], dict[str, object]]] = []
    try:
        paths = sorted(state_directory.glob("proof-*.json"))
    except OSError as exc:
        raise Refused("resume_journal_unavailable") from exc
    for path in paths:
        try:
            metadata = path.lstat()
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_ISLNK(metadata.st_mode)
                or metadata.st_uid != os.getuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or not 0 < metadata.st_size <= MAX_REQUEST_BYTES
            ):
                continue
            value = json.loads(path.read_text(encoding="ascii"))
        except (OSError, UnicodeError, ValueError):
            continue
        if not isinstance(value, dict):
            continue
        proof_id = value.get("proof_id")
        candidate_at = value.get("candidate_first_activated_at")
        rollback_at = value.get("rollback_completed_at")
        changed_at = value.get("configuration_changed_at")
        if not all(
            isinstance(item, str)
            for item in (proof_id, candidate_at, rollback_at, changed_at)
        ):
            continue
        try:
            corrected = _receipt_pair(
                candidate,
                proof_id=proof_id,
                candidate_at=candidate_at,
                rollback_at=rollback_at,
                changed_at=changed_at,
            )
        except Refused:
            continue
        alias = copy.deepcopy(corrected)
        alias_identity = _aliased_candidate_identity(candidate)
        alias["configuration"]["candidate_identity"] = alias_identity
        alias["rollback"]["candidate_identity"] = alias_identity
        expected_previous = value.get("previous_receipts_archive")
        if (
            value.get("phase") != "failed"
            or value.get("project") != PROJECT
            or value.get("candidate_source") != candidate.get("source_commit")
            or value.get("rollback_source") != rollback.get("source_commit")
            or (
                expected_previous is not None
                and (
                    not isinstance(expected_previous, str)
                    or SHA256.fullmatch(expected_previous) is None
                )
            )
            or previous not in (expected_previous, _receipt_archive(corrected))
            or value.get("receipts") not in (alias, corrected)
            or "publication" in value
        ):
            continue
        eligible.append((path, value, corrected))
    if len(eligible) != 1:
        raise Refused("resume_journal_ambiguous")
    return eligible[0]


def _resume(args: argparse.Namespace) -> dict[str, object]:
    candidate, rollback, previous, controller = _inspect(args)
    journal, transaction, pair = _resume_journal(
        args.state_directory,
        candidate=candidate,
        rollback=rollback,
        previous=previous,
    )
    proof_id = transaction["proof_id"]
    assert isinstance(proof_id, str)
    rollback_slot = INSTALLED_APP.parent / f".TandemClip.rollout.{proof_id}.rollback.app"
    if rollback_slot.exists():
        retained = _verify_app(rollback_slot, reporting=False)
        if retained.get("tree_sha256") != rollback.get("tree_sha256"):
            raise Refused("retained_rollback_changed")
    expected_previous = transaction.get("previous_receipts_archive")
    assert expected_previous is None or isinstance(expected_previous, str)
    published = _remote_publish(args.publish_host, pair, expected_previous)
    transaction.update(
        phase="published",
        candidate_identity=candidate["release"],
        receipts=pair,
        publication=published,
        resumed_by_controller_commit=controller,
    )
    _write_json(journal, transaction, exclusive=False)
    if rollback_slot.exists():
        shutil.rmtree(rollback_slot)
    return {
        "completed": True,
        "dry_run": False,
        "restarted": False,
        "resumed": True,
        "proof_id": proof_id,
        "project": PROJECT,
        "candidate_identity": candidate["release"],
        "configuration_record": published.get("configuration_record"),
        "rollback_record": published.get("rollback_record"),
        "journal": str(journal),
    }


def _superseded_journal(
    state_directory: Path,
    *,
    candidate: dict[str, object],
    rollback: dict[str, object],
    current_archive: str | None,
) -> tuple[Path, dict[str, object]]:
    eligible: list[tuple[Path, dict[str, object]]] = []
    try:
        paths = sorted(state_directory.glob("proof-*.json"))
    except OSError as exc:
        raise Refused("superseded_journal_unavailable") from exc
    for path in paths:
        try:
            metadata = path.lstat()
            if (
                not stat.S_ISREG(metadata.st_mode)
                or stat.S_ISLNK(metadata.st_mode)
                or metadata.st_uid != os.getuid()
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or not 0 < metadata.st_size <= MAX_REQUEST_BYTES
            ):
                continue
            value = json.loads(path.read_text(encoding="ascii"))
        except (OSError, UnicodeError, ValueError):
            continue
        if not isinstance(value, dict):
            continue
        proof_id = value.get("proof_id")
        candidate_at = value.get("candidate_first_activated_at")
        rollback_at = value.get("rollback_completed_at")
        changed_at = value.get("configuration_changed_at")
        if not all(
            isinstance(item, str)
            for item in (proof_id, candidate_at, rollback_at, changed_at)
        ):
            continue
        try:
            exact = _receipt_pair(
                candidate,
                proof_id=proof_id,
                candidate_at=candidate_at,
                rollback_at=rollback_at,
                changed_at=changed_at,
            )
        except Refused:
            continue
        alias = copy.deepcopy(exact)
        alias_identity = _aliased_candidate_identity(candidate)
        alias["configuration"]["candidate_identity"] = alias_identity
        alias["rollback"]["candidate_identity"] = alias_identity
        publication = value.get("publication")
        if (
            value.get("phase") != "published"
            or value.get("project") != PROJECT
            or value.get("candidate_source") != candidate.get("source_commit")
            or value.get("rollback_source") != rollback.get("source_commit")
            or value.get("candidate_identity") != alias_identity
            or value.get("receipts") != alias
            or current_archive != _receipt_archive(alias)
            or not isinstance(publication, dict)
            or publication.get("published") is not True
            or publication.get("proof_id") != proof_id
        ):
            continue
        eligible.append((path, value))
    if len(eligible) != 1:
        raise Refused("superseded_journal_ambiguous")
    return eligible[0]


def _supersede(args: argparse.Namespace) -> dict[str, object]:
    candidate, rollback, previous, controller = _inspect(args)
    source_journal, source = _superseded_journal(
        args.state_directory,
        candidate=candidate,
        rollback=rollback,
        current_archive=previous,
    )
    proof_id = str(uuid.uuid4())
    pair = _receipt_pair(
        candidate,
        proof_id=proof_id,
        candidate_at=str(source["candidate_first_activated_at"]),
        rollback_at=str(source["rollback_completed_at"]),
        changed_at=str(source["configuration_changed_at"]),
    )
    journal = args.state_directory / f"proof-{proof_id}.json"
    transaction: dict[str, object] = {
        "schema_version": 1,
        "phase": "prepared",
        "proof_id": proof_id,
        "supersedes_proof_id": source["proof_id"],
        "supersedes_journal": str(source_journal),
        "project": PROJECT,
        "candidate_identity": candidate["release"],
        "candidate_source": candidate["source_commit"],
        "rollback_source": rollback["source_commit"],
        "controller_commit": controller,
        "previous_receipts_archive": previous,
        "candidate_first_activated_at": source["candidate_first_activated_at"],
        "rollback_completed_at": source["rollback_completed_at"],
        "configuration_changed_at": source["configuration_changed_at"],
        "receipts": pair,
    }
    _write_json(journal, transaction, exclusive=True)
    try:
        published = _remote_publish(args.publish_host, pair, previous)
    except Exception as error:
        transaction.update(
            phase="failed",
            error=(
                error.args[0]
                if isinstance(error, Refused) and error.args
                else "rollout_failed"
            ),
        )
        with contextlib.suppress(Exception):
            _write_json(journal, transaction, exclusive=False)
        raise
    transaction.update(phase="published", publication=published)
    _write_json(journal, transaction, exclusive=False)
    return {
        "completed": True,
        "dry_run": False,
        "restarted": False,
        "superseded": source["proof_id"],
        "proof_id": proof_id,
        "project": PROJECT,
        "candidate_identity": candidate["release"],
        "configuration_record": published.get("configuration_record"),
        "rollback_record": published.get("rollback_record"),
        "journal": str(journal),
    }


def _prove(args: argparse.Namespace) -> dict[str, object]:
    candidate, rollback, previous, controller = _inspect(args)
    proof_id = str(uuid.uuid4())
    journal = args.state_directory / f"proof-{proof_id}.json"
    transaction: dict[str, object] = {
        "schema_version": 1,
        "phase": "prepared",
        "proof_id": proof_id,
        "project": PROJECT,
        "candidate_identity": candidate["release"],
        "candidate_source": candidate["source_commit"],
        "rollback_source": rollback["source_commit"],
        "controller_commit": controller,
        "previous_receipts_archive": previous,
    }
    _write_json(journal, transaction, exclusive=True)
    candidate_slot = INSTALLED_APP.parent / f".TandemClip.rollout.{proof_id}.candidate.app"
    rollback_slot = INSTALLED_APP.parent / f".TandemClip.rollout.{proof_id}.rollback.app"
    try:
        # This is the real launch time of the exact currently running bundle,
        # not an operator-entered or reconstructed rollout timestamp.
        candidate_at = _timestamp(_candidate_started_at())
        with _mounted_app(args.rollback_dmg, reporting=False) as (rollback_app, _):
            candidate_slot, rollback_slot = _replace_with_rollback(
                rollback_app, proof_id, candidate
            )
        rollback_at = _timestamp()
        transaction.update(
            phase="rollback_ready",
            candidate_first_activated_at=candidate_at,
            rollback_completed_at=rollback_at,
        )
        _write_json(journal, transaction, exclusive=False)
        _restore_candidate(candidate_slot, rollback_slot, candidate)
        changed_at = _timestamp()
        pair = _receipt_pair(
            candidate,
            proof_id=proof_id,
            candidate_at=candidate_at,
            rollback_at=rollback_at,
            changed_at=changed_at,
        )
        transaction.update(
            phase="candidate_reactivated",
            configuration_changed_at=changed_at,
            receipts=pair,
        )
        _write_json(journal, transaction, exclusive=False)
        published = _remote_publish(args.publish_host, pair, previous)
        transaction.update(phase="published", publication=published)
        _write_json(journal, transaction, exclusive=False)
        if rollback_slot.exists():
            shutil.rmtree(rollback_slot)
        return {
            "completed": True,
            "dry_run": False,
            "proof_id": proof_id,
            "project": PROJECT,
            "candidate_identity": candidate["release"],
            "configuration_record": published.get("configuration_record"),
            "rollback_record": published.get("rollback_record"),
            "journal": str(journal),
        }
    except Exception as error:
        with contextlib.suppress(Exception):
            _restore_candidate(candidate_slot, rollback_slot, candidate)
        transaction.update(
            phase="failed",
            error=(
                error.args[0]
                if isinstance(error, Refused) and error.args
                else "rollout_failed"
            ),
        )
        with contextlib.suppress(Exception):
            _write_json(journal, transaction, exclusive=False)
        raise


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action", choices=("preflight", "prove", "resume", "supersede")
    )
    parser.add_argument("--candidate-dmg", type=Path, required=True)
    parser.add_argument("--rollback-dmg", type=Path, required=True)
    # The SSH host that runs Crashbox's protected publisher. There is no default:
    # the host is operator configuration, so it comes from the flag or from
    # TANDEMCLIP_CRASHBOX_PUBLISH_HOST, and the run refuses when neither is set.
    parser.add_argument(
        "--publish-host",
        default=os.environ.get(PUBLISH_HOST_ENV) or None,
        help=f"SSH host for the Crashbox publisher (or set {PUBLISH_HOST_ENV})",
    )
    parser.add_argument(
        "--state-directory",
        type=Path,
        default=(
            Path.home()
            / "Library/Application Support/TandemClip/CrashboxRolloutProof"
        ),
    )
    return parser


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = _parser()
    args = parser.parse_args(argv)
    if not args.publish_host:
        parser.error(f"--publish-host is required (or set {PUBLISH_HOST_ENV})")
    return args


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    try:
        if args.action == "preflight":
            value = _preflight(args)
        elif args.action == "resume":
            value = _resume(args)
        elif args.action == "supersede":
            value = _supersede(args)
        else:
            value = _prove(args)
    except Refused as error:
        print(
            _canonical({"completed": False, "error": str(error)}).decode("ascii"),
            end="",
        )
        return 2
    except Exception:
        print('{"completed":false,"error":"rollout_failed"}')
        return 2
    print(_canonical(value).decode("ascii"), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
