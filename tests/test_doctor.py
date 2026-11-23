"""Exercise the actual single-file installer before granting it any system changes."""
from pathlib import Path
import os
import re
import subprocess
import sys
import unittest
from unittest.mock import patch

from test_stream_install import ROOT, StreamInstallTests as _Stream
from test_vps import command
import native_browser


class DoctorTests(unittest.TestCase):
    setUp = _Stream.setUp

    def run_installer(self, *args):
        return subprocess.run(["/bin/sh", str(self.bundle), *args], env=self.env, text=True,
                              capture_output=True, start_new_session=True, timeout=30)

    def test_checks_work_with_only_versioned_python_and_do_not_create_a_binding(self):
        (self.home / "bin/python3").rename(self.home / "bin/python3.9")
        before = (self.home / "config/termlo/connection.json").read_bytes()
        check = self.run_installer("--check")
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertIn("已渲染测试页", check.stderr)
        self.assertIn("体检通过", check.stderr)
        self.assertEqual(check.stdout, "")
        self.assertEqual((self.home / "config/termlo/connection.json").read_bytes(), before)
        self.assertFalse((self.home / ".ssh").exists())
        self.assertFalse((self.home / ".local").exists())
        result = self.run_installer("--sync-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        cli_check = subprocess.run([str(self.home / ".local/bin/termlo"), "install", "--check"],
                                   env=self.env, capture_output=True, text=True)
        self.assertEqual(cli_check.returncode, 0, cli_check.stderr)
        self.assertEqual(cli_check.stdout, "")

    def test_blocked_normal_install_lists_every_issue_before_bootstrapping(self):
        tools = self.home / "bin"
        (tools / "python3").unlink()
        (tools / "apt-get").unlink()
        command(tools / "dpkg", '[ "$1" != --print-architecture ] || echo amd64')
        # The fixture provides neither a package manager nor a helper with apt bindings.
        (self.home / ".mutagen/agents/0.18.1/mutagen-agent").unlink()
        self.env["TERMLO_MUTAGEN_ARCHIVE"] = str(self.home / "missing archive")
        command(tools / "sudo", 'echo CALLED >> "$HOME/admin-actions"; exit 1')
        run = self.run_installer("--host", "test.example")
        self.assertNotEqual(run.returncode, 0)
        for expected in ("体检未通过", "apt-get", "dpkg -i ./*.deb", "python3", "校验失败", "远程浏览器"):
            self.assertIn(expected, run.stderr)
        self.assertEqual(run.stdout, "")
        self.assertFalse((self.home / ".ssh").exists())
        self.assertFalse((self.home / "config/termlo/installed-components.json").exists())

    def test_an_active_session_with_no_host_key_response_stops_before_changes(self):
        command(self.home / "bin/ssh-keyscan", "exit 1")
        run = self.run_installer("--sync-only")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("ssh-keyscan -T 3 -p 2202", run.stderr)
        self.assertNotIn("安装完成", run.stderr)
        self.assertFalse((self.home / ".local").exists())

    def test_browser_falls_back_to_a_working_candidate_after_render_failure(self):
        bad = self.home / "bin/chromium"
        good = self.home / "bin/google-chrome"
        command(bad, "exit 2")
        command(good, "echo '<title>termlo-browser-ready</title>'")
        with patch.dict(os.environ, self.env, clear=True), patch.object(sys, "platform", "linux"), \
             patch.object(os, "geteuid", return_value=501):
            self.assertEqual(native_browser.check(), str(good))
        checked = self.run_installer("--check")
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertIn("已渲染测试页  " + str(good), checked.stderr)

    def test_one_line_download_never_executes_an_empty_or_failed_transfer(self):
        readme = (ROOT / "README.md").read_text()
        invocation = re.search(r"^setup=.+$", readme, re.M).group()
        for code in (0, 37):
            with self.subTest(code=code):
                command(self.home / "bin/curl", ("printf '%s\\n' 'touch \"$HOME/partial-ran\"'\n" if code else "")
                        + f"exit {code}")
                run = subprocess.run(["/bin/sh", "-c", invocation], env=self.env, capture_output=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertFalse((self.home / "partial-ran").exists())
        local = invocation.replace("https://raw.githubusercontent.com/gurudin/termlo-vps/main/install.sh",
                                   self.bundle.as_uri())
        command(self.home / "bin/curl", 'exec "$REAL_CURL" "$@"')
        outcome = subprocess.run(["/bin/sh", "-c", local + " termlo --check --sync-only"], env=self.env,
                                 capture_output=True, text=True)
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        self.assertIn("体检通过", outcome.stderr)

    def test_normal_reinstall_rechecks_the_current_environment_before_changing_any_binding(self):
        first = self.run_installer("--sync-only")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("安装前体检", first.stderr)
        authorized = self.home / ".ssh/authorized_keys"
        before = authorized.read_bytes()
        command(self.home / "bin/ssh-keyscan", "exit 1")
        second = self.run_installer("--sync-only")
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("体检未通过", second.stderr)
        self.assertEqual(authorized.read_bytes(), before)
        self.assertEqual(second.stdout, "")



# unittest discovery also sees TestCase classes imported into this module.
del _Stream
