"""Exercise the actual single-file installer before granting it any system changes."""
import os
import re
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

from test_stream_install import INSTALL_COMMAND, StreamInstallTests as _Stream
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

    def assert_checklist(self, result):
        rows = re.findall(r"^  \[(通过|未通过)\] .+$", result.stderr, re.M)
        self.assertTrue(rows, result.stderr)
        failed = rows.count("未通过")
        remedies = re.findall(r"^           补齐方法  (.*)$", result.stderr, re.M)
        self.assertEqual(len(remedies), failed)
        self.assertTrue(all(hint.strip() for hint in remedies), result.stderr)
        if failed:
            self.assertIn(f"{len(rows)-failed} 项通过，{failed} 项未通过", result.stderr)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("体检通过。", result.stderr)
        else:
            self.assertIn(f"{len(rows)} 项全部通过", result.stderr)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_multiple_failures_are_reported_and_each_has_a_remedy(self):
        tools = self.home / "bin"
        (tools / "tmux").unlink()
        command(tools / "ssh-keyscan", "exit 1")
        command(tools / "chromium", "exit 2")
        command(tools / "apt-get", '[ "$1" = --version ] && exit 0; [ "$1" = -s ] && exit 100; echo mutation >> "$HOME/events"')
        result = self.run_installer("--without-claude")
        self.assert_checklist(result)
        for item in ("tmux 安装来源", "远程浏览器", "当前 SSH 会话"):
            self.assertIn("[未通过] " + item, result.stderr)
        self.assertIn("apt-get install -y tmux", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse((self.home / "events").exists())
        self.assertFalse((self.home / ".local").exists())
        self.assertFalse((self.home / "config/termlo/install.lock").exists())

    def test_unpack_tools_all_reported_before_install(self):
        for name in ("base64", "gzip"):
            (self.home / "bin" / name).unlink()
        result = self.run_installer("--without-claude")
        self.assert_checklist(result)
        for name in ("base64", "gzip"):
            self.assertIn("[未通过] 安装包解压工具  缺少 " + name, result.stderr)
        self.assertIn("[通过] 远程系统", result.stderr)
        self.assertIn("[未通过] 远程浏览器", result.stderr)
        self.assertFalse((self.home / ".local").exists())
        self.assertFalse((self.home / ".ssh").exists())

    def test_existing_invalid_connection_and_receipt_reported_together_without_overwriting_them(self):
        config = self.home / "config/termlo"
        connection = config / "connection.json"
        receipt = config / "installed-components.json"
        connection.write_text("[]")
        receipt.write_text("{")
        result = self.run_installer("--without-claude")
        self.assert_checklist(result)
        for path in (connection, receipt):
            self.assertIn("[未通过] 已有文件 " + path.name, result.stderr)
        self.assertEqual(connection.read_text(), "[]")
        self.assertEqual(receipt.read_text(), "{")
        self.assertFalse((config / "install.lock").exists())

    def test_empty_apt_indexes_are_resolved_in_private_storage(self):
        tools = self.home / "bin"
        (tools / "tmux").unlink()
        (tools / "mkdir").symlink_to(shutil.which("mkdir"))
        command(tools / "sudo", '[ "$1 $2" = "-n true" ]')
        command(tools / "apt-get", '''
[ "$1" != --version ] || exit 0
echo "$*" >> "$HOME/apt-calls"
case "$*" in
    *Dir::State::lists="$HOME"/*/apt-lists*) exit 0 ;;
    *) exit 1 ;;
esac''')
        result = self.run_installer("--check")
        self.assert_checklist(result)
        self.assertIn("[通过] tmux 安装来源", result.stderr)
        calls = (self.home / "apt-calls").read_text().splitlines()
        self.assertEqual(sum(line.endswith(" update") for line in calls), 1)
        self.assertTrue(all(line.startswith("-s ") or line.endswith(" update") for line in calls))
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

    def test_utf8_shell_prints_the_offline_repair_command_when_download_fails(self):
        self.env["LC_ALL"] = "en_US.UTF-8" if sys.platform == "darwin" else "C.UTF-8"
        (self.home / ".mutagen/agents/0.18.1/mutagen-agent").unlink()
        command(self.home / "bin/curl", '[ "$1" = --version ] || exit 6')
        result = self.run_installer("--check")
        self.assert_checklist(result)
        self.assertIn("curl -fL -o mutagen_linux_amd64_v0.18.1.tar.gz https://github.com/", result.stderr)
        self.assertIn("export TERMLO_MUTAGEN_ARCHIVE=", result.stderr)
        self.assertNotIn("unbound variable", result.stderr)

    def test_public_command_does_not_run_a_partial_or_stale_file_after_a_failed_download(self):
        installer = self.home / "install.sh"
        for code, partial in ((22, ""), (18, "echo 'echo partial > ran' > install.sh\n")):
            with self.subTest(code=code):
                installer.write_text("echo stale > ran\n")
                command(self.home / "bin/curl", partial + f"exit {code}")
                run = subprocess.run(["/bin/sh", "-c", INSTALL_COMMAND], cwd=self.home,
                                     env=self.env, capture_output=True)
                self.assertEqual(run.returncode, code)
                self.assertFalse((self.home / "ran").exists())

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
