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

    def repo(self, name: str = "repo") -> Path:
        """A repository carrying this checkout's hook and scanner, one commit on main."""
        path = self.base / name
        path.mkdir()
        self.git(path, "init", "-q")
        (path / "Scripts").mkdir()
        (path / ".githooks").mkdir()
        shutil.copy2(SCAN, path / "Scripts" / "secret-scan.sh")
        shutil.copy2(CHECK, path / "Scripts" / "check-hooks-path.sh")
        shutil.copy2(HOOK, path / ".githooks" / "pre-push")
        (path / "README.md").write_text("fixture\n")
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
        result = self.scan("origin", f"https://github.com/someone/{PRIVATE_NAME}.git")
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
                result = self.scan(name, url)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"refusing to push to {name}", result.stderr)
                self.assertIn("treated as public", result.stderr)

    def test_unknown_url_fails_closed(self) -> None:
        self.plant("notes.txt", f"host at {LAN_ADDRESS}")
        result = self.scan("origin")
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to push", result.stderr)

    def test_refusal_does_not_echo_the_remote_url(self) -> None:
        # A remote URL can carry a token in its userinfo.
        self.plant("notes.txt", f"host at {LAN_ADDRESS}")
        marker = "userinfo" + "marker42"
        result = self.scan("public", f"https://{marker}@github.com/someone/tandemclip.git")
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
        result = self.scan("public", "https://github.com/someone/tandemclip.git", stdin=refs)
        self.assertEqual(result.returncode, 1)
        self.assertIn("SECRET  config.txt (in ", result.stdout)

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
