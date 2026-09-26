#!/usr/bin/env python3
"""The push guard: Scripts/check-hooks-path.sh and the secret-scan pre-push hook.

check-hooks-path.sh is what makes the release path refuse while the hook is off, so it
is tested against every way the hook can be silently inactive. The hook is driven for
real: a `git push` to a local bare repository whose name marks it private or not, with
core.hooksPath set, so the test proves git runs it and what it decides.

Hermetic: throwaway repositories under a temp HOME with system config off. Nothing is
pushed anywhere but a local bare repository. The planted findings are assembled at run
time, so this file itself matches none of the patterns it plants.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / "Scripts" / "check-hooks-path.sh"
SCAN = ROOT / "Scripts" / "secret-scan.sh"
HOOK = ROOT / ".githooks" / "pre-push"

LAN_ADDRESS = "192." + "168.7.9"
KEY_ID = "AKIA" + "Z" * 16
HOST_NAME = "web" + "-07"
MIRROR_SCRIPT = "Scripts/" + "publish-repo.sh"
PRIVATE_NAME = "tandemclip" + "-private"

# Secret-shaped strings, fake and assembled here so no line of this file matches.
# Each one's body is distinctive, so a leak of any part of it is detectable.
FAKE_SECRETS = {
    "aws-access-key-id": "AKIA" + "QZ7XW3FAKETEST42",
    "github-token": "ghp" + "_" + "FakeScanFixture" + "0123456789xyz",
    "private-key": "-----BEGIN " + "RSA PRIVATE KEY-----",
    "dsn-with-key": "https://" + "fa4e" * 8 + "@o12345" + ".ingest.example.invalid/1",
}


class Sandbox:
    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name).resolve()
        home = self.base / "home"
        home.mkdir()
        self.env = {
            **os.environ,
            "HOME": str(home),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@example.invalid",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@example.invalid",
        }
        for var in ("GIT_CONFIG_GLOBAL", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
            self.env.pop(var, None)
        self.git(None, "config", "--global", "init.defaultBranch", "main")
        self.git(None, "config", "--global", "commit.gpgsign", "false")

    def git(self, repo: Path | None, *args: str, check: bool = True) -> subprocess.CompletedProcess:
        cmd = ["git"] + (["-C", str(repo)] if repo else []) + list(args)
        return subprocess.run(cmd, env=self.env, capture_output=True, text=True, check=check)

    def repo(self, name: str = "repo", commit: bool = True) -> Path:
        """A repository carrying this checkout's hook and scanner, one commit on main.

        With commit=False nothing is committed, so the caller's first commit is the
        repository's root commit.
        """
        path = self.base / name
        path.mkdir()
        self.git(path, "init", "-q")
        (path / "Scripts").mkdir()
        (path / ".githooks").mkdir()
        shutil.copy2(SCAN, path / "Scripts" / "secret-scan.sh")
        shutil.copy2(CHECK, path / "Scripts" / "check-hooks-path.sh")
        shutil.copy2(HOOK, path / ".githooks" / "pre-push")
        (path / "README.md").write_text("fixture\n")
        if commit:
            self.commit(path, "fixture")
        return path

    def commit(self, repo: Path, message: str) -> None:
        self.git(repo, "add", "-A")
        self.git(repo, "commit", "-qm", message)

    def run(self, repo: Path, argv: list[str], stdin: str = "") -> subprocess.CompletedProcess:
        return subprocess.run(argv, cwd=repo, env=self.env, input=stdin,
                              capture_output=True, text=True)

    def close(self) -> None:
        self.tmp.cleanup()


class HooksPathCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.box = Sandbox()
        self.repo = self.box.repo()

    def tearDown(self) -> None:
        self.box.close()

    def check(self, repo: Path | None = None) -> subprocess.CompletedProcess:
        repo = repo or self.repo
        return self.box.run(repo, ["bash", str(repo / "Scripts" / "check-hooks-path.sh"), str(repo)])

    def assert_refused(self, result: subprocess.CompletedProcess, reason: str) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("pre-push hook is not active", result.stderr)
        self.assertIn(reason, result.stderr)
        self.assertIn("config core.hooksPath .githooks", result.stderr, "the refusal must say how to fix it")

    def test_unset_is_refused(self) -> None:
        self.assert_refused(self.check(), "core.hooksPath is not set")

    def test_githooks_is_accepted(self) -> None:
        self.box.git(self.repo, "config", "core.hooksPath", ".githooks")
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hook active", result.stdout)

    def test_equivalent_spellings_are_accepted(self) -> None:
        for value in ("./.githooks", str(self.repo / ".githooks"), ".githooks/"):
            with self.subTest(value=value):
                self.box.git(self.repo, "config", "core.hooksPath", value)
                result = self.check()
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_another_directory_is_refused(self) -> None:
        for value in (".git/hooks", "hooks", str(self.box.base / "elsewhere")):
            with self.subTest(value=value):
                self.box.git(self.repo, "config", "core.hooksPath", value)
                self.assert_refused(self.check(), "not .githooks")

    def test_hook_without_execute_bit_is_refused(self) -> None:
        # git skips a hook that is not executable, so this is as good as unset.
        self.box.git(self.repo, "config", "core.hooksPath", ".githooks")
        (self.repo / ".githooks" / "pre-push").chmod(0o644)
        self.assert_refused(self.check(), "not executable")

    def test_missing_hook_is_refused(self) -> None:
        self.box.git(self.repo, "config", "core.hooksPath", ".githooks")
        (self.repo / ".githooks" / "pre-push").unlink()
        self.assert_refused(self.check(), "pre-push is missing")

    def test_missing_githooks_directory_is_refused(self) -> None:
        self.box.git(self.repo, "config", "core.hooksPath", ".githooks")
        shutil.rmtree(self.repo / ".githooks")
        self.assert_refused(self.check(), "no .githooks directory")

    def test_linked_worktree_inherits_the_setting(self) -> None:
        # core.hooksPath is shared config and a relative value resolves per worktree,
        # which is how git itself finds the hook when a lane pushes from its worktree.
        self.box.git(self.repo, "config", "core.hooksPath", ".githooks")
        lane = self.box.base / "lane"
        self.box.git(self.repo, "worktree", "add", "-q", "--detach", str(lane))
        result = self.check(lane)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_outside_a_repository_is_refused(self) -> None:
        plain = self.box.base / "plain"
        plain.mkdir()
        result = self.box.run(plain, ["bash", str(CHECK), str(plain)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a git working tree", result.stderr)


class SecretScanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.box = Sandbox()
        self.repo = self.box.repo()

    def tearDown(self) -> None:
        self.box.close()

    def scan(self, *args: str, stdin: str = "") -> subprocess.CompletedProcess:
        return self.box.run(self.repo, ["bash", "Scripts/secret-scan.sh", *args], stdin)

    def plant(self, path: str, text: str) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text + "\n")
        self.box.commit(self.repo, f"plant {path}")

    def test_clean_tree_passes(self) -> None:
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("clean", result.stdout)

    def test_manual_run_reports_without_talking_about_a_push(self) -> None:
        self.plant("notes.txt", f"host at {LAN_ADDRESS}")
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn("LAN IP  notes.txt", result.stdout)
        self.assertIn("findings above", result.stderr)
        self.assertNotIn("push", result.stderr)

    def test_private_destination_warns_and_allows(self) -> None:
        self.plant("notes.txt", f"host at {LAN_ADDRESS}")
        result = self.scan("--pre-push", "origin", f"https://github.com/someone/{PRIVATE_NAME}.git")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LAN IP  notes.txt", result.stdout)
        self.assertIn("PRIVATE repository", result.stderr)
        self.assertIn("before the next publish", result.stderr)
        # The wording of the model this replaced, where origin was public.
        self.assertNotIn("ALREADY in the public history", result.stderr)
        self.assertNotIn("backup", result.stderr)

    def test_any_other_destination_is_refused(self) -> None:
        self.plant("notes.txt", f"host at {LAN_ADDRESS}")
        for name, url in (("public", "https://github.com/someone/tandemclip.git"),
                          ("fork", "git@example.invalid:someone/other.git")):
            with self.subTest(url=url):
                result = self.scan("--pre-push", name, url)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"refusing to push to {name}", result.stderr)
                self.assertIn("treated as public", result.stderr)

    def test_unknown_url_fails_closed(self) -> None:
        self.plant("notes.txt", f"host at {LAN_ADDRESS}")
        result = self.scan("--pre-push", "origin")
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to push", result.stderr)

    def test_refusal_does_not_echo_the_remote_url(self) -> None:
        # A remote URL can carry a token in its userinfo.
        self.plant("notes.txt", f"host at {LAN_ADDRESS}")
        marker = "userinfo" + "marker42"
        result = self.scan("--pre-push", "public", f"https://{marker}@github.com/someone/tandemclip.git")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(marker, result.stdout + result.stderr)

    def test_a_secret_added_and_removed_in_the_pushed_range_is_refused(self) -> None:
        base = self.box.git(self.repo, "rev-parse", "HEAD").stdout.strip()
        self.plant("config.txt", f"key = {KEY_ID}")
        (self.repo / "config.txt").unlink()
        self.box.commit(self.repo, "remove it again")
        tip = self.box.git(self.repo, "rev-parse", "HEAD").stdout.strip()
        self.assertEqual(self.scan().returncode, 0, "the tree alone is clean")
        refs = f"refs/heads/main {tip} refs/heads/main {base}\n"
        result = self.scan("--pre-push", "public", "https://github.com/someone/tandemclip.git", stdin=refs)
        self.assertEqual(result.returncode, 1)
        self.assertIn("SECRET  config.txt:1  rule=aws-access-key-id  (in ", result.stdout)

    def test_a_new_branch_scans_its_history_not_nothing(self) -> None:
        # A new branch arrives with a zero remote sha, and its range is "<tip> --not
        # --remotes=origin". Passed as ONE argument that was an unknown revision, so
        # rev-list failed quietly and a secret added and removed on a new branch went
        # out unscanned.
        self.plant("config.txt", f"key = {KEY_ID}")
        (self.repo / "config.txt").unlink()
        self.box.commit(self.repo, "remove it again")
        tip = self.box.git(self.repo, "rev-parse", "HEAD").stdout.strip()
        refs = f"refs/heads/topic {tip} refs/heads/topic {'0' * 40}\n"
        result = self.scan("--pre-push", "public", "https://github.com/someone/tandemclip.git", stdin=refs)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("SECRET  config.txt:1  rule=aws-access-key-id  (in ", result.stdout)

    def test_mirror_script_is_exempt_from_the_name_check_only(self) -> None:
        self.plant(MIRROR_SCRIPT, f"guard pattern names {HOST_NAME}")
        self.plant("docs/elsewhere.md", f"deploy to {HOST_NAME}")
        result = self.scan()
        self.assertNotIn(f"INFRA   {MIRROR_SCRIPT}", result.stdout)
        self.assertIn("INFRA   docs/elsewhere.md", result.stdout)

        (self.repo / "docs" / "elsewhere.md").unlink()
        self.plant(MIRROR_SCRIPT, f"guard pattern names {HOST_NAME}\nkey = {KEY_ID}")
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"SECRET  {MIRROR_SCRIPT}", result.stdout)
        self.assertNotIn("INFRA", result.stdout)


class ManualModeNeverReadsStdin(unittest.TestCase):
    """A manual run finishes on its own whatever stdin is.

    An agent shell or CI step hands the scanner a stdin that is open, is not a
    terminal, and is never closed. When the scanner guessed hook mode from `! -t 0`
    it sat reading that pipe forever. Only `--pre-push` may read stdin now, so these
    runs keep the pipe open for the whole run and must still finish in seconds.
    """

    TIMEOUT = 5  # seconds; the scan of this fixture takes well under one

    def setUp(self) -> None:
        self.box = Sandbox()
        self.repo = self.box.repo()

    def tearDown(self) -> None:
        self.box.close()

    def scan_with_open_stdin(self, *args: str, feed: str = "") -> subprocess.CompletedProcess:
        proc = subprocess.Popen(["bash", "Scripts/secret-scan.sh", *args], cwd=self.repo,
                                env=self.box.env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            if feed:
                proc.stdin.write(feed)
                proc.stdin.flush()
            # stdin stays open until the scanner has exited: never send EOF.
            try:
                proc.wait(timeout=self.TIMEOUT)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                self.fail(f"the scan was still running after {self.TIMEOUT}s with stdin "
                          "open: it is reading stdin in manual mode")
            out, err = proc.stdout.read(), proc.stderr.read()
        finally:
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                stream.close()
        return subprocess.CompletedProcess(proc.args, proc.returncode, out, err)

    def test_open_empty_pipe_reports_the_tree(self) -> None:
        (self.repo / "notes.txt").write_text(f"host at {LAN_ADDRESS}\n")
        self.box.commit(self.repo, "a finding")
        result = self.scan_with_open_stdin()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("LAN IP  notes.txt:1  rule=lan-ip\n", result.stdout)
        self.assertIn("findings above", result.stderr)

    def test_open_empty_pipe_on_a_clean_tree(self) -> None:
        result = self.scan_with_open_stdin()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("secret-scan clean", result.stdout)

    def test_junk_on_stdin_is_ignored(self) -> None:
        # The junk includes a well-formed ref line whose range holds a secret that was
        # added and removed. Were stdin read, that range would be scanned and refused;
        # manual mode scans the tree only, and the tree is clean.
        base = self.box.git(self.repo, "rev-parse", "HEAD").stdout.strip()
        (self.repo / "config.txt").write_text(f"key = {KEY_ID}\n")
        self.box.commit(self.repo, "plant")
        (self.repo / "config.txt").unlink()
        self.box.commit(self.repo, "remove it again")
        tip = self.box.git(self.repo, "rev-parse", "HEAD").stdout.strip()
        junk = ("not a ref line\n\x01 control bytes\n"
                f"refs/heads/main {tip} refs/heads/main {base}\n"
                + "x" * 5000 + "\n")
        result = self.scan_with_open_stdin(feed=junk)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("secret-scan clean", result.stdout)
        self.assertNotIn("config.txt", result.stdout + result.stderr)

    def test_positional_arguments_without_the_flag_are_refused(self) -> None:
        # The old hook interface. Treated as manual it would skip the range scan without
        # a word, so it is a usage error: exit 2, stdin untouched, nothing scanned.
        result = self.scan_with_open_stdin("public", "https://github.com/someone/tandemclip.git")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("--pre-push", result.stderr)
        self.assertNotIn("clean", result.stdout)


class FindingsNeverEchoTheMatch(unittest.TestCase):
    """A finding names its place and rule, never the text it matched.

    The scanner runs in agent sessions and CI, so what it prints is copied into their
    transcripts and logs. Echoing a caught secret there leaks it again. Every path
    that reports a finding is driven here with fake secrets planted, and each one must
    report path:line and the rule, keep its exit code, and print no part of a secret.
    """

    def setUp(self) -> None:
        self.box = Sandbox()
        self.repo = self.box.repo()
        self.base = self.box.git(self.repo, "rev-parse", "HEAD").stdout.strip()

    def tearDown(self) -> None:
        self.box.close()

    def plant_all(self) -> None:
        # Line 1 is filler, so a finding's line number is not trivially 1.
        body = "filler\n" + "".join(f"value = {v}\n" for v in FAKE_SECRETS.values())
        body += f"host at {LAN_ADDRESS}\ndeploy to {HOST_NAME}\n"
        (self.repo / "cfg.txt").write_text(body)
        self.box.commit(self.repo, "plant fake secrets")

    def assert_no_part_echoed(self, result: subprocess.CompletedProcess) -> None:
        out = result.stdout + result.stderr
        for rule, secret in FAKE_SECRETS.items():
            self.assertNotIn(secret, out, f"{rule}: the matched text was printed")
            # Any distinctive part of it, not only the whole string.
            for part in ("QZ7XW3", "FakeScanFixture", "RSA PRIVATE", "fa4efa4e", "o12345"):
                self.assertNotIn(part, out, "part of a planted secret was printed")
        self.assertNotIn(LAN_ADDRESS, out)
        self.assertNotIn(HOST_NAME, out)
        self.assertNotIn("value = ", out, "a matched line's content was printed")

    def assert_tree_findings(self, stdout: str, suffix: str = "") -> None:
        for line, rule in enumerate(FAKE_SECRETS, start=2):
            self.assertIn(f"SECRET  cfg.txt:{line}  rule={rule}{suffix}\n", stdout)
        n = len(FAKE_SECRETS) + 2
        self.assertIn(f"LAN IP  cfg.txt:{n}  rule=lan-ip{suffix}\n", stdout)
        self.assertIn(f"INFRA   cfg.txt:{n + 1}  rule=internal-host{suffix}\n", stdout)

    def test_manual_scan(self) -> None:
        self.plant_all()
        result = self.box.run(self.repo, ["bash", "Scripts/secret-scan.sh"])
        self.assertEqual(result.returncode, 1)
        self.assert_no_part_echoed(result)
        self.assert_tree_findings(result.stdout)

    def test_pushed_range_including_a_removed_secret_and_a_commit_message(self) -> None:
        self.plant_all()
        planted = self.box.git(self.repo, "rev-parse", "HEAD").stdout.strip()
        (self.repo / "cfg.txt").unlink()
        self.box.commit(self.repo, "tidy\n\nrotated " + FAKE_SECRETS["aws-access-key-id"])
        tip = self.box.git(self.repo, "rev-parse", "HEAD").stdout.strip()
        refs = f"refs/heads/main {tip} refs/heads/main {self.base}\n"
        result = self.box.run(self.repo, ["bash", "Scripts/secret-scan.sh", "--pre-push", "public",
                                          "https://github.com/someone/tandemclip.git"], refs)
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to push", result.stderr)
        self.assert_no_part_echoed(result)
        self.assert_tree_findings(result.stdout, f"  (in {planted})")
        self.assertIn(f"SECRET  commit message {tip}:3  rule=aws-access-key-id\n", result.stdout)

    def test_private_destination_still_reports_and_allows(self) -> None:
        self.plant_all()
        result = self.box.run(self.repo, ["bash", "Scripts/secret-scan.sh", "--pre-push", "origin",
                                          f"https://github.com/someone/{PRIVATE_NAME}.git"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_part_echoed(result)
        self.assert_tree_findings(result.stdout)

    def push_to(self, bare_name: str) -> subprocess.CompletedProcess:
        self.box.git(self.repo, "config", "core.hooksPath", ".githooks")
        bare = self.box.base / bare_name
        self.box.git(None, "init", "-q", "--bare", str(bare))
        self.box.git(self.repo, "remote", "add", "dest", str(bare))
        return self.box.git(self.repo, "push", "dest", "HEAD:refs/heads/main", check=False)

    def test_real_push_through_the_hook_to_a_public_destination(self) -> None:
        self.plant_all()
        result = self.push_to("tandemclip.git")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to push to dest", result.stderr)
        self.assert_no_part_echoed(result)
        self.assert_tree_findings(result.stdout + result.stderr)

    def test_real_push_through_the_hook_to_the_private_repository(self) -> None:
        self.plant_all()
        result = self.push_to(f"{PRIVATE_NAME}.git")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_part_echoed(result)
        self.assert_tree_findings(result.stdout + result.stderr)


class EveryPushedCommitIsScanned(unittest.TestCase):
    """The range scan lists the new content of every kind of commit.

    Each case plants a secret in one commit and deletes it in the next, so the tree
    is clean and only the range scan can see it, then pushes through the real hook
    to a public destination. Each kind of commit here was once listed as empty, so
    its content went out unscanned while the push printed "clean".
    """

    # A fake key, assembled at run time. Both halves of its body are distinctive, and
    # neither may appear in the output.
    BODIES = ("RQ5ZV8RT", "ROOTFAKE")
    SECRET = "AKIA" + "".join(BODIES)

    def setUp(self) -> None:
        self.box = Sandbox()

    def tearDown(self) -> None:
        self.box.close()

    def head(self, repo: Path) -> str:
        return self.box.git(repo, "rev-parse", "HEAD").stdout.strip()

    def write_secret(self, repo: Path, path: str) -> None:
        # Line 1 is filler, so the reported line number is not trivially 1.
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"filler\nkey = {self.SECRET}\n")

    def remove(self, repo: Path, path: str) -> None:
        (repo / path).unlink()
        self.box.commit(repo, f"remove {path}")

    def push(self, repo: Path, ref: str = "HEAD:refs/heads/main") -> subprocess.CompletedProcess:
        bare = self.box.base / "tandemclip.git"   # a public name: findings refuse the push
        if not bare.exists():
            self.box.git(None, "init", "-q", "--bare", str(bare))
            self.box.git(repo, "remote", "add", "dest", str(bare))
        self.box.git(repo, "config", "core.hooksPath", ".githooks")
        return self.box.git(repo, "push", "dest", ref, check=False)

    def assert_refused_at(self, repo: Path, result: subprocess.CompletedProcess,
                          path: str, commit: str) -> None:
        out = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, out)
        self.assertIn("refusing to push to dest", result.stderr)
        self.assertIn(f"SECRET  {path}:2  rule=aws-access-key-id  (in {commit})\n", out)
        self.assertNotIn(self.SECRET, out)
        for part in self.BODIES:
            self.assertNotIn(part, out, "a fragment of the planted secret was printed")
        self.assertNotIn("key = ", out, "a matched line's content was printed")
        # The finding came from the range: the tree alone is clean.
        manual = self.box.run(repo, ["bash", "Scripts/secret-scan.sh"])
        self.assertEqual(manual.returncode, 0, manual.stdout + manual.stderr)

    def test_root_commit_of_a_new_repository(self) -> None:
        repo = self.box.repo(commit=False)
        self.write_secret(repo, "config.txt")
        self.box.commit(repo, "first commit")
        root = self.head(repo)
        self.remove(repo, "config.txt")
        self.assert_refused_at(repo, self.push(repo), "config.txt", root)

    def test_orphan_branch_pushed_as_a_new_branch(self) -> None:
        repo = self.box.repo()
        clean = self.push(repo)
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.box.git(repo, "checkout", "-q", "--orphan", "leak")
        self.write_secret(repo, "config.txt")
        self.box.commit(repo, "orphan root")
        root = self.head(repo)
        self.remove(repo, "config.txt")
        result = self.push(repo, "leak:refs/heads/leak")
        self.assert_refused_at(repo, result, "config.txt", root)

    def test_content_introduced_by_a_merge(self) -> None:
        repo = self.box.repo()
        self.box.git(repo, "checkout", "-q", "-b", "side")
        (repo / "side.txt").write_text("side\n")
        self.box.commit(repo, "side")
        self.box.git(repo, "checkout", "-q", "main")
        (repo / "main.txt").write_text("main\n")
        self.box.commit(repo, "main")
        self.box.git(repo, "merge", "-q", "--no-ff", "--no-commit", "side")
        self.write_secret(repo, "merged.txt")   # in neither parent: only the merge adds it
        self.box.commit(repo, "merge side")
        merge = self.head(repo)
        self.remove(repo, "merged.txt")
        self.assert_refused_at(repo, self.push(repo), "merged.txt", merge)

    def test_a_symlink_replaced_by_a_file(self) -> None:
        repo = self.box.repo()
        (repo / "key.txt").symlink_to("README.md")
        self.box.commit(repo, "link")
        (repo / "key.txt").unlink()
        self.write_secret(repo, "key.txt")
        self.box.commit(repo, "type change")
        changed = self.head(repo)
        self.remove(repo, "key.txt")
        self.assert_refused_at(repo, self.push(repo), "key.txt", changed)

    def test_a_non_ascii_path(self) -> None:
        repo = self.box.repo()
        self.write_secret(repo, "cl\u00e9.txt")
        self.box.commit(repo, "plant")
        planted = self.head(repo)
        self.remove(repo, "cl\u00e9.txt")
        self.assert_refused_at(repo, self.push(repo), "cl\u00e9.txt", planted)

    def test_a_rename_with_an_edit_even_with_rename_detection_configured(self) -> None:
        repo = self.box.repo()
        self.box.git(repo, "config", "diff.renames", "copies")
        (repo / "old.txt").write_text("filler\nplain\n")
        self.box.commit(repo, "plain file")
        self.box.git(repo, "mv", "old.txt", "moved.txt")
        self.write_secret(repo, "moved.txt")
        self.box.commit(repo, "rename with an edit")
        renamed = self.head(repo)
        self.remove(repo, "moved.txt")
        self.assert_refused_at(repo, self.push(repo), "moved.txt", renamed)


class PrePushHookTests(unittest.TestCase):
    """git itself runs .githooks/pre-push, with the remote name and URL, on a real push."""

    def setUp(self) -> None:
        self.box = Sandbox()
        self.repo = self.box.repo()
        self.box.git(self.repo, "config", "core.hooksPath", ".githooks")
        (self.repo / "notes.txt").write_text(f"host at {LAN_ADDRESS}\n")
        self.box.commit(self.repo, "a finding")

    def tearDown(self) -> None:
        self.box.close()

    def push_to(self, bare_name: str) -> subprocess.CompletedProcess:
        bare = self.box.base / bare_name
        self.box.git(None, "init", "-q", "--bare", str(bare))
        self.box.git(self.repo, "remote", "add", "dest", str(bare))
        return self.box.git(self.repo, "push", "dest", "HEAD:refs/heads/main", check=False)

    def test_push_to_private_repository_warns_and_lands(self) -> None:
        result = self.push_to(f"{PRIVATE_NAME}.git")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LAN IP  notes.txt", result.stdout + result.stderr)
        self.assertIn("allowing this push", result.stderr)

    def test_push_anywhere_else_is_refused_by_the_hook(self) -> None:
        result = self.push_to("tandemclip.git")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to push to dest", result.stderr)


if __name__ == "__main__":
    unittest.main()
