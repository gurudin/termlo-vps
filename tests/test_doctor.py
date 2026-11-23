"""Exercise the actual single-file installer before granting it any system changes."""
import json
import os
from pathlib import Path
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

    def test_writable_ssh_directories_stop_first_install_before_authorization(self):
        ssh = self.home / ".ssh"
        ssh.mkdir(mode=0o700)
        keys = ssh / "authorized_keys"
        keys.write_bytes(b"# an existing authorization\n")
        for folder, mode, label in ((ssh, 0o777, '"$HOME/.ssh"'), (self.home, 0o770, '"$HOME"')):
            original = folder.stat().st_mode & 0o777
            with self.subTest(folder=label):
                folder.chmod(mode)
                result = self.run_installer("--sync-only")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("[未通过] SSH 授权目录权限", result.stderr)
                self.assertIn("chmod go-w " + label, result.stderr)
                self.assertFalse(result.stdout)
                self.assertEqual(keys.read_bytes(), b"# an existing authorization\n")
                self.assertFalse((self.home / ".local/bin/termlo").exists())
                self.assertEqual(folder.stat().st_mode & 0o777, mode)
                folder.chmod(original)
        result = self.run_installer("--sync-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("termlo://connect/"))

    def test_linked_authorization_file_checks_the_directories_sshd_will_read(self):
        ssh = self.home / ".ssh"
        ssh.mkdir(mode=0o700)
        shared = self.home / "shared keys"
        folder = shared / "account"
        folder.mkdir(parents=True)
        target = folder / "keys"
        target.write_bytes(b"# existing\n")
        (ssh / "authorized_keys").symlink_to(target)
        shared.chmod(0o777)
        result = self.run_installer("--sync-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[未通过] SSH 授权目录权限", result.stderr)
        self.assertFalse(result.stdout)
        self.assertEqual(target.read_bytes(), b"# existing\n")
        shared.chmod(0o755)
        result = self.run_installer("--sync-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((ssh / "authorized_keys").is_symlink())

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

    @unittest.skipIf(os.getuid() == 0, "the root account can write read-only directories")
    def test_readonly_agent_directory_is_required_to_be_writable_only_for_repair(self):
        folder = self.home / ".mutagen/agents/0.18.1"
        folder.chmod(0o555)
        self.addCleanup(folder.chmod, 0o755)
        agent = folder / "mutagen-agent"
        before = agent.read_bytes()
        first = self.run_installer("--sync-only")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("已就绪", first.stderr)
        self.assertEqual(agent.read_bytes(), before)
        keys = self.home / ".ssh/authorized_keys"
        saved = keys.read_bytes()
        command(agent, "echo old")
        second = self.run_installer("--sync-only")
        self.assert_checklist(second)
        self.assertIn("能写入 " + str(folder), second.stderr)
        self.assertEqual(keys.read_bytes(), saved)

    def test_stopped_daemon_rejects_its_invalid_configuration_during_preflight(self):
        self.env.pop("SSH_CONNECTION")
        tools = self.home / "bin"
        command(tools / "ssh-keyscan", "exit 1")
        command(tools / "sudo", 'if [ "$1" = -n ]; then shift; fi; if [ "$1" = true ]; then exit 0; fi; exec "$@"')
        command(tools / "sshd", 'echo "sshd_config line 3: Badly formatted port number." >&2; exit 255')
        result = self.run_installer("--sync-only", "--host", "dev.example")
        self.assert_checklist(result)
        self.assertIn("[未通过] SSH 服务配置", result.stderr)
        self.assertIn("sshd_config line 3", result.stderr)
        self.assertIn("sshd -t", result.stderr)
        self.assertFalse((self.home / "config/termlo/install.lock").exists())

    def test_only_the_standard_missing_sshd_runtime_directory_can_be_prepared(self):
        self.env.pop("SSH_CONNECTION")
        tools = self.home / "bin"
        command(tools / "ssh-keyscan", "exit 1")
        command(tools / "sudo", 'shift; if [ "$1" = true ]; then exit 0; fi; exec "$@"')
        command(tools / "sshd", 'printf "Missing privilege separation directory: %s\\r\\n" "$RUNTIME" >&2; exit 255')
        for runtime in ("/run/sshd", "/var/run/sshd", "/run/sshd-custom"):
            with self.subTest(runtime=runtime):
                self.env["RUNTIME"] = runtime
                result = self.run_installer("--check", "--sync-only", "--host", "dev.example")
                self.assert_checklist(result)
                self.assertEqual(result.returncode == 0, runtime != "/run/sshd-custom", result.stderr)
                self.assertFalse((self.home / "config/termlo/install.lock").exists())

    def test_missing_custom_host_key_is_not_replaced_by_the_preflight_key(self):
        daemon = shutil.which("sshd", path=os.defpath + ":/usr/sbin")
        if not daemon:
            self.skipTest("requires OpenSSH server")
        config = self.home / "sshd_config"
        config.write_text(f'HostKey "{self.home}/missing-custom-key"\n')
        self.env.update(DAEMON=daemon, SERVER_CONFIG=str(config))
        self.env.pop("SSH_CONNECTION")
        tools = self.home / "bin"
        command(tools / "ssh-keyscan", "exit 1")
        command(tools / "sudo", 'shift; if [ "$1" = true ]; then exit 0; fi; exec "$@"')
        command(tools / "sshd", 'exec "$DAEMON" -f "$SERVER_CONFIG" "$@"')
        result = self.run_installer("--sync-only", "--host", "dev.example")
        self.assert_checklist(result)
        self.assertIn("[未通过] SSH 服务配置", result.stderr)
        self.assertIn("missing-custom-key", result.stderr)
        self.assertFalse((self.home / "config/termlo/install.lock").exists())

    def test_apt_must_be_able_to_install_the_missing_base_tools_together(self):
        tools = self.home / "bin"
        for name in ("git", "tmux"):
            (tools / name).unlink()
        (tools / "mkdir").symlink_to(shutil.which("mkdir"))
        command(tools / "dpkg", '[ "$1" = --version ]')
        command(tools / "sudo", '[ "$1 $2" = "-n true" ]')
        command(tools / "apt-get", '''
[ "$1" != --version ] || exit 0
for arg do case $arg in Dir::Cache::archives=*) archives=${arg#*=} ;; esac; done
case " $* " in
    *" update "*) exit 0 ;;
    *" --download-only "*)
        n=0
        for arg do case $arg in git|tmux) n=$((n+1)); echo deb > "$archives/${arg}_1_amd64.deb" ;; esac; done
        [ "$n" -eq 1 ] ;;
    *) echo unexpected > "$HOME/mutation"; exit 1 ;;
esac''')
        result = self.run_installer("--without-claude")
        self.assert_checklist(result)
        for label in ("Git", "tmux"):
            self.assertIn("[通过] " + label + " 安装来源", result.stderr)
        self.assertIn("[未通过] APT 组合安装", result.stderr)
        self.assertIn("apt-get -s --no-remove", result.stderr)
        self.assertFalse((self.home / "mutation").exists())
        self.assertFalse((self.home / "config/termlo/install.lock").exists())

    def test_missing_scp_can_be_installed_during_an_active_ssh_session(self):
        tools = self.home / "bin"
        (tools / "scp").unlink()
        for name in ("mkdir", "chmod", "env"):
            (tools / name).symlink_to(shutil.which(name))
        command(tools / "dpkg", '[ "$1" = --version ]')
        command(tools / "sudo", 'if [ "$1" = -n ]; then shift; fi; exec "$@"')
        # sudo may also run the shell builtin true in the permission check.
        (tools / "true").symlink_to(shutil.which("true"))
        command(tools / "apt-get", '''
[ "$1" != --version ] || exit 0
for arg do case $arg in Dir::Cache::archives=*) archives=${arg#*=} ;; esac; done
case " $* " in
    *" update "*) exit 0 ;;
    *" --download-only "*) [ -z "${archives:-}" ] || echo deb > "$archives/openssh-client_1.deb" ;;
    *" --no-download "*) if [ -f "$HOME/provide-scp" ]; then echo "#!/bin/sh" > "$HOME/bin/scp"; chmod +x "$HOME/bin/scp"; fi ;;
    *) exit 1 ;;
esac''')
        check = self.run_installer("--check", "--sync-only")
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertIn("[通过] SSH 服务及主机密钥", check.stderr)
        self.assertFalse((self.home / "config/termlo/install.lock").exists())
        incomplete = self.run_installer("--sync-only")
        self.assertNotEqual(incomplete.returncode, 0)
        self.assertIn("仍找不到 scp", incomplete.stderr)
        self.assertEqual(incomplete.stdout, "")
        (self.home / "provide-scp").touch()
        complete = self.run_installer("--sync-only")
        self.assertEqual(complete.returncode, 0, complete.stderr)
        self.assertTrue(complete.stdout.startswith("termlo://connect/"))

    def test_hung_local_tool_does_not_hide_the_rest_of_the_checklist(self):
        override = self.home / ".local/bin/tmux"
        override.parent.mkdir(parents=True)
        command(override, 'exec "' + shutil.which("sleep") + '" 60')
        result = self.run_installer("--without-claude")
        self.assert_checklist(result)
        self.assertIn("[未通过] tmux  优先执行的", result.stderr)
        self.assertIn('mv -i "$HOME/.local/bin/tmux"', result.stderr)
        self.assertIn("[通过] ADB", result.stderr)
        self.assertFalse((self.home / "config/termlo/install.lock").exists())
        override.rename(override.with_name("tmux.disabled"))
        retry = self.run_installer("--without-claude")
        self.assertEqual(retry.returncode, 0, retry.stderr)

    def test_link_to_a_broken_private_tool_blocks_before_installing_the_system_package(self):
        original = self.home / "old-tmux"
        command(original, "exit 13")
        link = self.home / ".local/bin/tmux"
        link.parent.mkdir(parents=True)
        link.symlink_to(original)
        blocked = self.run_installer("--without-claude")
        self.assert_checklist(blocked)
        self.assertIn("[未通过] tmux  优先执行的", blocked.stderr)
        self.assertIn('mv -i "$HOME/.local/bin/tmux"', blocked.stderr)
        self.assertFalse((self.home / "config/termlo/install.lock").exists())
        link.rename(link.with_name("tmux.disabled"))
        recovered = self.run_installer("--without-claude")
        self.assertEqual(recovered.returncode, 0, recovered.stderr)

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

    def test_unprivileged_check_on_stopped_sshd_does_not_misreport_root_host_keys(self):
        self.env.pop("SSH_CONNECTION")
        tools = self.home / "bin"
        command(tools / "ssh-keyscan", "exit 1")
        command(tools / "sudo", "exit 1")
        command(tools / "sshd", '''
case " $* " in
    *" -h "*) exit 0 ;;
    *" -t "*) echo "Could not load host key: /etc/ssh/ssh_host_ed25519_key" >&2
              echo "sshd: no hostkeys available -- exiting." >&2
              exit 255 ;;
    *" -G "*) echo "pubkeyauthentication yes"
              echo "authorizedkeysfile .ssh/authorized_keys" ;;
esac''')
        result = self.run_installer("--check", "--sync-only", "--host", "dev.example")
        self.assert_checklist(result)
        self.assertIn("[未通过] 安装权限", result.stderr)
        self.assertIn("[通过] SSH 服务配置", result.stderr)
        self.assertNotIn("HostKey 路径或权限", result.stderr)

    def test_sshd_auth_policy_blocks_disabled_pubkey_or_custom_authorized_keys(self):
        tools = self.home / "bin"
        for output, expected in (
            ("pubkeyauthentication no\nauthorizedkeysfile .ssh/authorized_keys\n", "PubkeyAuthentication yes"),
            ("pubkeyauthentication yes\nauthorizedkeysfile /etc/ssh/keys/%u\n", "AuthorizedKeysFile"),
        ):
            with self.subTest(expected=expected):
                command(tools / "sshd", f'printf "{output}"')
                result = self.run_installer("--check", "--sync-only")
                self.assert_checklist(result)
                self.assertIn("[未通过] SSH 公钥登录策略", result.stderr)
                self.assertIn(expected, result.stderr)
        # Verify forced-commands-only is blocked for root, while %u home paths are accepted.
        prereq = str(Path(__file__).resolve().parents[1] / "prerequisites.sh")
        command(tools / "sshd", 'printf "pubkeyauthentication yes\\npermitrootlogin forced-commands-only\\nauthorizedkeysfile .ssh/authorized_keys\\n"')
        root_blocked = subprocess.run(["sh", "-ec", '. "$1"; check_sshd_auth_policy "" "" 0 root', "check", prereq],
                                      env=self.env, capture_output=True, text=True)
        self.assertNotEqual(root_blocked.returncode, 0)
        self.assertIn("forced-commands-only", root_blocked.stdout)
        command(tools / "sshd", "printf '%s\\n' 'pubkeyauthentication yes' 'authorizedkeysfile /home/%u/.ssh/authorized_keys'")
        user_ok = subprocess.run(["sh", "-ec", '. "$1"; HOME=/home/alice check_sshd_auth_policy "" "" 1000 alice', "check", prereq],
                                 env=self.env, capture_output=True, text=True)
        self.assertEqual(user_ok.returncode, 0, user_ok.stdout)

    def test_mutagen_tls_failure_mentions_ca_certificates(self):
        (self.home / ".mutagen/agents/0.18.1/mutagen-agent").unlink()
        command(self.home / "bin/curl", '[ "$1" = --version ] || exit 60')
        result = self.run_installer("--check", "--sync-only")
        self.assert_checklist(result)
        self.assertIn("ca-certificates", result.stderr)
        self.assertIn("curl 错误码 60", result.stderr)

    def test_rpm_preflight_uses_showduplicates_for_reinstall_candidates(self):
        tools = self.home / "bin"
        (tools / "apt-get").unlink()
        (tools / "tmux").unlink()
        command(tools / "dnf", '''
[ "$1" != --version ] || exit 0
case " $* " in *" list --showduplicates --available tmux "*) exit 0 ;; *) exit 1 ;; esac''')
        release = self.home / "os-release"
        release.write_text('ID=rocky\nVERSION_ID="9.4"\nPLATFORM_ID="platform:el9"\n')
        probe = subprocess.run(
            ["sh", "-ec", '. "$1"; . "$2"; family=rpm; manager=dnf; scratch=$3; release=$4; package_available tmux',
             "check", str(Path(__file__).resolve().parents[1] / "prerequisites.sh"),
             str(Path(__file__).resolve().parents[1] / "doctor.sh"), str(self.home), str(release)],
            env=self.env, capture_output=True, text=True)
        self.assertEqual(probe.returncode, 0, probe.stderr)

# unittest discovery also sees TestCase classes imported into this module.
del _Stream
