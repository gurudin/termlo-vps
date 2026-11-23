"""Exercise the actual single-file installer before granting it any system changes."""
import json
import os
import re
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

from test_stream_install import INSTALL_COMMAND, StreamInstallTests as _Stream, endpoint
from test_vps import command
import native_browser


class DoctorTests(unittest.TestCase):
    setUp = _Stream.setUp
    run_in_terminal = _Stream.run_in_terminal

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

    def test_apt_repair_uses_working_tools_and_identifies_when_rescue_is_needed(self):
        tools = self.home / "bin"
        (tools / "apt-get").unlink()
        command(tools / "apt", "exit 127")
        command(tools / "dpkg", '[ "$1" != --print-architecture ] || echo amd64')
        result = self.run_installer("--sync-only")
        self.assert_checklist(result)
        self.assertIn("dpkg -i ./*.deb", result.stderr)
        self.assertNotIn("apt install -y --reinstall apt", result.stderr)
        command(tools / "dpkg", "exit 127")
        result = self.run_installer("--sync-only")
        self.assert_checklist(result)
        self.assertIn("救援环境", result.stderr)
        self.assertNotIn("目录运行 dpkg -i ./*.deb", result.stderr)

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
        self.assertIn("--reinstall chromium chromium-sandbox", result.stderr)
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

    def test_invalid_options_and_missing_noninteractive_host_stop_at_the_checklist(self):
        self.env.pop("SSH_CONNECTION")
        config = self.home / "config/termlo"
        before = (config / "connection.json").read_bytes()
        for args, hint in (
                (("--sync-only",), "--host"),
                (("--host", "bad host"), "域名或 IP"),
                (("--host", "valid.host", "--name", "  "), "名称不能为空"),
                (("--check", "--sync-only", "--with-claude"), "--with-claude"),
                (("--host", "--check"), "缺少值")):
            with self.subTest(args=args):
                result = self.run_installer(*args)
                self.assert_checklist(result)
                self.assertIn(hint, result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertEqual((config / "connection.json").read_bytes(), before)
                self.assertFalse((config / "install.lock").exists())
                self.assertFalse((self.home / ".ssh").exists())
        self.assertEqual(self.run_installer("--check").returncode, 0)

    def test_installed_reinstaller_reports_invalid_options_alongside_other_blockers(self):
        first = self.run_installer("--sync-only")
        self.assertEqual(first.returncode, 0, first.stderr)
        keys = self.home / ".ssh/authorized_keys"
        before = keys.read_bytes()
        command(self.home / "bin/ssh-keyscan", "exit 1")
        result = subprocess.run([str(self.home / ".local/bin/termlo"), "install", "--check",
                                 "--sync-only", "--with-claude"], env=self.env, capture_output=True, text=True)
        self.assert_checklist(result)
        self.assertIn("--with-claude", result.stderr)
        self.assertIn("[未通过] 当前 SSH 会话", result.stderr)
        self.assertEqual(keys.read_bytes(), before)

    def test_console_uses_detected_listener_and_preserves_explicit_nat_port(self):
        self.env.pop("SSH_CONNECTION")
        tools = self.home / "bin"
        (tools / "awk").symlink_to(shutil.which("awk"))
        command(tools / "sshd", 'echo "port 2248"')
        command(tools / "ssh-keyscan", '[ "$4" = 2248 ] || exit 1; printf "host "; cat "$HOME/host_key.pub"')
        for flags, public in (([], 2248), (["--port", "4443"], 4443), ([], 4443)):
            result = self.run_installer("--sync-only", "--host", "dev.example", *flags)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(endpoint(result.stdout)["port"], public)
            self.assertEqual(json.loads((self.home / "config/termlo/connection.json").read_text())["local_port"], 2248)

    def test_nested_receipt_errors_block_the_installer_before_writes(self):
        config = self.home / "config/termlo"
        receipt = config / "installed-components.json"
        for malformed in ({"packages": {"apt": "tmux"}}, {"agents": {"bad": "x"}},
                          {"claude": {"versions": 3}}, {"browserUser": {"uid": True, "gid": 10}}):
            saved = dict({"version": 1, "packages": {}, "agents": {}}, **malformed)
            receipt.write_text(json.dumps(saved))
            result = self.run_installer("--sync-only")
            self.assert_checklist(result)
            self.assertIn("[未通过] 已有文件 installed-components.json", result.stderr)
            self.assertFalse((config / "install.lock").exists())
            self.assertEqual(json.loads(receipt.read_text()), saved)

    def test_cli_runs_with_spaced_python_path_and_after_virtualenv_moves(self):
        venv = self.home / "Developer's Tools"
        subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(venv)], check=True)
        self.env["PATH"] = str(venv / "bin") + os.pathsep + self.env["PATH"]
        installed = self.run_installer("--sync-only")
        self.assertEqual(installed.returncode, 0, installed.stderr)
        cli = str(self.home / ".local/bin/termlo")
        for move in (False, True):
            if move:
                venv.rename(self.home / "moved environment")
            result = subprocess.run([cli, "connection-code"], env=self.env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(endpoint(result.stdout), endpoint(installed.stdout))

    def test_empty_apt_indexes_are_resolved_in_private_storage(self):
        tools = self.home / "bin"
        (tools / "tmux").unlink()
        (tools / "mkdir").symlink_to(shutil.which("mkdir"))
        command(tools / "dpkg", '[ "$1" = --version ]')
        command(tools / "sudo", '[ "$1 $2" = "-n true" ]')
        command(tools / "apt-get", '''
[ "$1" != --version ] || exit 0
echo "$*" >> "$HOME/apt-calls"
for arg do case "$arg" in Dir::Cache::archives=*) archives=${arg#*=} ;; esac; done
case " $* " in *" Dir::State::lists=$HOME/"*"/apt-system "*) ;; *) exit 1 ;; esac
case " $* " in
    *" update "*) exit 0 ;;
    *" --download-only "*) echo deb > "$archives/tmux_1_amd64.deb" ;;
    *) exit 100 ;;
esac''')
        result = self.run_installer("--check")
        self.assert_checklist(result)
        self.assertIn("[通过] tmux 安装来源", result.stderr)
        calls = (self.home / "apt-calls").read_text().splitlines()
        self.assertEqual(sum(line.endswith(" update") for line in calls), 1)
        self.assertTrue(all("--download-only" in line or line.endswith(" update") for line in calls))
        self.assertFalse((self.home / ".local").exists())

    def test_cached_apt_metadata_cannot_pass_an_unreachable_or_missing_download(self):
        tools = self.home / "bin"
        (tools / "tmux").unlink()
        (tools / "mkdir").symlink_to(shutil.which("mkdir"))
        command(tools / "sudo", '[ "$1 $2" = "-n true" ]')
        command(tools / "apt-get", '''
case "$1" in --version|-s) exit 0 ;; esac
case " $* " in
    *" update "*) [ "$FAIL" != index ] ;;
    *" --download-only "*) [ "$FAIL" = no_archive ] ;;
    *) echo unexpected > "$HOME/mutation"; exit 100 ;;
esac''')
        for failure in ("index", "download", "no_archive"):
            with self.subTest(failure=failure):
                self.env["FAIL"] = failure
                result = self.run_installer("--without-claude")
                self.assert_checklist(result)
                self.assertIn("[未通过] tmux 安装来源", result.stderr)
                self.assertIn("apt-get install -y tmux", result.stderr)
                self.assertFalse((self.home / "config/termlo/install.lock").exists())
                self.assertFalse((self.home / "mutation").exists())

    def test_lock_files_and_linked_ssh_keys_are_checked_before_the_wizard(self):
        config = self.home / "config/termlo"
        ssh = self.home / ".ssh"
        ssh.mkdir()
        install_lock = config / "install.lock"
        pair_lock = ssh / ".termlo-pair.lock"
        install_lock.mkdir()
        pair_lock.mkdir()
        link = ssh / "authorized_keys"
        keys = self.home / "previous-account/keys"
        link.symlink_to(keys)
        before = (config / "connection.json").read_bytes()
        status, transcript = self.run_in_terminal(["-c", INSTALL_COMMAND])
        self.assertNotEqual(status, 0, transcript)
        for label in ("安装锁文件", "SSH 配对锁文件", "SSH 授权文件"):
            self.assertIn("[未通过] " + label, transcript)
        self.assertNotIn("1/3", transcript)
        self.assertFalse((config / "installed-components.json").exists())
        self.assertFalse((self.home / ".local").exists())
        self.assertEqual((config / "connection.json").read_bytes(), before)
        self.assertFalse(keys.parent.exists())
        install_lock.rmdir()
        pair_lock.rmdir()
        keys.parent.mkdir()
        keys.write_text("# existing keys\n")
        result = self.run_installer("--sync-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(link.is_symlink())
        self.assertTrue(keys.read_bytes().startswith(b"# existing keys\n"))
        self.assertIn(b" termlo-pair:", keys.read_bytes())

    def test_agent_version_requires_successful_exit(self):
        agent = self.home / ".mutagen/agents/0.18.1/mutagen-agent"
        command(agent, "echo 0.18.1; exit 1")
        self.env["TERMLO_MUTAGEN_ARCHIVE"] = str(self.home / "missing.tar.gz")
        result = self.run_installer("--sync-only")
        self.assert_checklist(result)
        self.assertIn("[未通过] Mutagen 同步代理", result.stderr)
        self.assertFalse((self.home / "config/termlo/installed-components.json").exists())

    def test_pairing_requires_functional_ed25519_key_generation(self):
        keygen = self.home / "bin/ssh-keygen"
        self.env["REAL_KEYGEN"] = str(keygen.resolve())
        keygen.unlink()
        command(keygen, 'if [ "$1" = -q ]; then exit 1; fi\nexec "$REAL_KEYGEN" "$@"')
        result = self.run_installer("--sync-only")
        self.assert_checklist(result)
        self.assertIn("[通过] SSH 服务及主机密钥", result.stderr)
        self.assertIn("[未通过] SSH 配对密钥", result.stderr)
        self.assertIn("--reinstall openssh-client", result.stderr)
        self.assertFalse((self.home / ".ssh").exists())
        self.assertFalse((self.home / "config/termlo/installed-components.json").exists())

    def test_legacy_null_ports_and_invalid_saved_endpoints(self):
        connection = self.home / "config/termlo/connection.json"
        for invalid in ({"name": "   "}, {"host": "invalid host"}):
            with self.subTest(invalid=invalid):
                connection.write_text(json.dumps(invalid))
                result = self.run_installer("--sync-only")
                self.assert_checklist(result)
                self.assertIn("[未通过] 已有文件 connection.json", result.stderr)
                self.assertEqual(json.loads(connection.read_text()), invalid)
                self.assertFalse((self.home / ".ssh").exists())
        connection.write_text('{"port": null, "local_port": null}')
        result = self.run_installer("--sync-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(connection.read_text())["port"], 2202)

    def test_missing_uname_still_prints_the_checklist(self):
        (self.home / "bin/uname").unlink()
        result = self.run_installer("--sync-only")
        self.assert_checklist(result)
        self.assertIn("[未通过] 远程系统", result.stderr)
        self.assertIn("uname -s", result.stderr)
        self.assertFalse((self.home / ".local").exists())

    def test_directory_at_agent_destination_stops_before_creating_state(self):
        agent = self.home / ".mutagen/agents/0.18.1/mutagen-agent"
        agent.unlink()
        agent.mkdir()
        result = self.run_installer("--sync-only")
        self.assert_checklist(result)
        self.assertIn("可执行文件路径被目录占用", result.stderr)
        self.assertIn(str(agent), result.stderr)
        self.assertFalse((self.home / "config/termlo/install.lock").exists())
        self.assertFalse((self.home / ".ssh").exists())

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
