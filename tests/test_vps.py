import argparse
import base64
from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import browser
import native_browser
import sync_agent
import termlo
import wizard


def command(path, body):
    path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
    path.chmod(0o755)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.bin = self.home / "fixtures"
        self.bin.mkdir()
        self.key = self.home / "ssh host key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.key)], check=True)
        self.public = str(self.key) + ".pub"
        self.cli = self.home / ".local/bin/termlo"
        self.events = self.home / "events"
        self.events.touch()
        env = patch.dict(os.environ, {"HOME": str(self.home), "XDG_CONFIG_HOME": str(self.home / "config"),
                                      "PATH": str(self.bin), "EVENTS": str(self.events),
                                      "PYTHONPATH": str(self.bin),
                                      "TERMLO_INSTALL_NETWORK": "global"}, clear=True)
        env.start()
        self.addCleanup(env.stop)
        platform = patch.object(sys, "platform", "linux")
        platform.start()
        self.addCleanup(platform.stop)
        for name in ("env", "bash", "id", "dirname", "ssh", "ssh-keygen", "scp", "mkdir", "mktemp", "rm", "cp", "cat", "chmod", "touch", "sh"):
            (self.bin / name).symlink_to(shutil.which(name, path="/usr/bin:/bin"))
        (self.bin / "python3").symlink_to(sys.executable)
        (self.bin / "sitecustomize.py").write_text("import os, sys\nsys.platform = 'linux'\nos.geteuid = lambda: 501\n")
        command(self.bin / "uname", 'case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac')
        command(self.bin / "apt-get", 'test "$1" = --version')
        command(self.bin / "ssh-keyscan", 'printf "host "; cat "$HOME/ssh host key.pub"')
        command(self.bin / "curl", 'test "$1" = --version')
        agent = sync_agent.installed_path()
        agent.parent.mkdir(parents=True)
        command(agent, 'echo ' + sync_agent.VERSION)
        release = self.home / "os-release"
        release.write_text("ID=debian\n")
        for setting in (patch.object(termlo, "OS_RELEASE", release),
                        patch.object(os, "geteuid", return_value=501)):
            setting.start()
            self.addCleanup(setting.stop)

    def install(self, sync_only=True, terminal=None, **kwargs):
        args = dict(host="dev.example.org", port=2207, host_key=self.public,
                    name="开发机", sync_only=sync_only, claude=None)
        args.update(kwargs)
        output = io.StringIO()
        with redirect_stdout(output):
            termlo.install(argparse.Namespace(**args), terminal)
        return output.getvalue().strip()

    def decode(self, code):
        self.assertTrue(code.startswith("termlo://connect/"))
        payload = code.strip().split("/")[-1]
        fields = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        ticket = fields.pop("pairing")
        self.assertTrue(ticket["key"].startswith("-----BEGIN OPENSSH PRIVATE KEY-----"))
        self.assertGreater(ticket["expiresAt"], 0)
        return fields

    def test_sync_only_reprint_and_rotation(self):
        code = self.install()
        pin = subprocess.check_output(["ssh-keygen", "-E", "sha256", "-lf", self.public], text=True).split()[1]
        self.assertEqual(self.decode(code), dict(version=2, host="dev.example.org", port=2207,
                         user=termlo.pwd.getpwuid(os.getuid()).pw_name, name="开发机", fingerprint=pin,
                         hostKey=" ".join(Path(self.public).read_text().split()[:2])))
        reprint = [str(self.cli), "connection-code"]
        fresh = subprocess.check_output(reprint, text=True).strip()
        self.assertFalse(fresh == code, "Each invitation must be unique")
        self.assertEqual(self.decode(fresh), self.decode(code))
        self.assertEqual(self.decode(self.install(host=None, port=None, host_key=None, name=None)), self.decode(code))
        self.key.unlink()
        Path(self.public).unlink()
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(self.key)], check=True)
        self.assertNotEqual(self.decode(subprocess.check_output(reprint, text=True))["fingerprint"], pin)

    def test_nat_and_console_require_reachable_host_before_install(self):
        for ssh in ("", "10.0.0.1 54000 10.1.0.2 22"):
            with patch.dict(os.environ, SSH_CONNECTION=ssh), self.assertRaisesRegex(ValueError, "体检未通过"):
                self.install(host=None)
        self.assertFalse(self.cli.exists())
        self.assertFalse(termlo.config_dir().exists())
        with patch.dict(os.environ, SSH_CONNECTION="10.0.0.1 54000 2606:4700:4700::1111 2222"):
            payload = self.decode(self.install(host=None, port=None))
        self.assertEqual((payload["host"], payload["port"]), ("2606:4700:4700::1111", 2222))

    def test_invalid_update_preserves_usable_command_and_configuration(self):
        code = self.install()
        for override in [dict(host_key=str(self.key)), dict(port=65536), dict(host="dev.example.org:2207")]:
            with self.assertRaises(ValueError):
                self.install(**override)
        self.assertEqual(self.decode(subprocess.check_output([str(self.cli), "connection-code"], text=True)), self.decode(code))

    def test_late_reinstall_failures_preserve_previous_command_settings_and_authorizations(self):
        old = self.decode(self.install())
        cfg = termlo.config_dir() / "connection.json"
        keys = self.home / ".ssh/authorized_keys"
        paths = (self.cli, cfg, keys)
        before = [p.read_bytes() for p in paths]
        replace = os.replace
        for target in paths:
            def fail(source, destination):
                if Path(destination).resolve() == target.resolve():
                    raise OSError("injected write failure")
                return replace(source, destination)
            with self.subTest(target=target), patch.object(os, "replace", side_effect=fail):
                with self.assertRaisesRegex(OSError, "injected write failure"):
                    self.install(host="changed.example", name="更新")
            self.assertTrue(all(p.read_bytes() == data for p, data in zip(paths, before)))
        self.assertEqual(self.decode(subprocess.check_output([str(self.cli), "connection-code"], text=True)), old)

    def test_concurrent_connection_code_uses_the_committed_settings_after_reinstall_fails(self):
        old = self.decode(self.install())
        marker = self.home / "waiting-for-pair-lock"
        with (self.bin / "sitecustomize.py").open("a") as hooks:
            hooks.write("""
import fcntl
from pathlib import Path
flock = fcntl.flock
def trace_lock(file, operation):
    if operation == fcntl.LOCK_EX:
        (Path.home() / "waiting-for-pair-lock").touch()
    return flock(file, operation)
fcntl.flock = trace_lock
""")
        def fail_while_reissuing():
            self.reader = subprocess.Popen([str(self.cli), "connection-code"], text=True,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 10
            while not marker.exists() and time.monotonic() < deadline and self.reader.poll() is None:
                time.sleep(0.02)
            if not marker.exists():
                self.reader.kill()
                self.reader.communicate()
                self.fail("Reissuance never reached the pairing lock")
            raise OSError("interrupted publication")

        with patch.object(termlo, "install_cli", side_effect=fail_while_reissuing):
            with self.assertRaisesRegex(OSError, "interrupted publication"):
                self.install(host="uncommitted.example")
        output, error = self.reader.communicate(timeout=10)
        self.assertEqual(self.reader.returncode, 0, error)
        self.assertEqual(self.decode(output), old)

    def test_default_pin_uses_a_local_key_actually_offered_by_sshd(self):
        offered = self.home / "ssh_host_ecdsa_key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ecdsa", "-N", "", "-f", str(offered)], check=True)
        shutil.copyfile(self.public, self.home / "ssh_host_ed25519_key.pub")
        command(self.bin / "ssh-keyscan", 'printf "host "; cat "$HOME/ssh_host_ecdsa_key.pub"')
        with patch.dict(os.environ, SSH_CONNECTION="10.0.0.1 53900 10.1.0.2 22"):
            code = self.install(host_key=None)
        pin = subprocess.check_output(["ssh-keygen", "-lf", str(offered) + ".pub"], text=True).split()[1]
        self.assertEqual(self.decode(code)["fingerprint"], pin)

    def test_first_and_reissued_invitations_match_the_ssh_deadline_across_time_zones(self):
        command(self.bin / "ssh-keyscan", '''
banner="# dev.example.org:22 SSH-2.0-$PEER"
if [ "$STREAM" = stdout ]; then echo "$banner"; else echo "$banner" >&2; fi
printf "host "; cat "$HOME/ssh host key.pub"''')
        keys = self.home / ".ssh/authorized_keys"
        keys.parent.mkdir()
        existing = b"# Existing SSH configuration\n"
        keys.write_bytes(existing)
        cases = [("OpenSSH_9.1p1", "stderr", True), ("OpenSSH_10.2", "stdout", True),
                 ("OpenSSH_8.9p1", "stdout", False), ("unidentified", "stderr", False)]
        for index, (peer, stream, utc) in enumerate(cases):
            with self.subTest(peer=peer), patch.dict(os.environ, PEER=peer, STREAM=stream, TZ="EST5"):
                code = self.install() if index == 0 else subprocess.check_output(
                    [str(self.cli), "connection-code"], text=True)
                body = code.strip().split("/")[-1]
                invite = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))["pairing"]
                deadline = keys.read_text().splitlines()[-1].split('expiry-time="')[1].split('"')[0]
                self.assertEqual(deadline.endswith("Z"), utc)
                # Interpret the authorized_keys text as the service would, outside the issuing shell.
                system_env = dict(os.environ)
                del system_env["TZ"]
                parsed = subprocess.check_output([sys.executable, "-IS", "-c",
                    "import datetime as d,sys; s=sys.argv[1]; t=d.datetime.strptime(s[:14],'%Y%m%d%H%M%S'); "
                    "print(int((t.replace(tzinfo=d.timezone.utc) if s.endswith('Z') else t).timestamp()))",
                    deadline], env=system_env, text=True)
                self.assertEqual(int(parsed), invite["expiresAt"])
        subprocess.run([str(self.cli), "uninstall", "--keep-tools"], check=True, capture_output=True)
        self.assertEqual(keys.read_bytes(), existing)

    def test_port_discovered_after_first_sshd_start_is_used_unless_user_sets_public_port(self):
        (self.bin / "awk").symlink_to("/usr/bin/awk")
        command(self.bin / "sshd", 'echo "port 2248"')
        command(self.bin / "sudo", '[ "$1" != -n ] || shift; [ "$1" != true ] || exit 0; exec "$@"')
        command(self.bin / "ssh-keyscan",
                '[ -f "$HOME/up" ] && [ "$4" = 2248 ] || exit 1; printf "host "; cat "$HOME/ssh host key.pub"')
        helper = termlo.shell_helper

        def start_daemon(name, *args, **kwargs):
            if name == "prepare_sshd":
                (self.home / "up").touch()
                return subprocess.CompletedProcess([], 0)
            return helper(name, *args, **kwargs)

        with patch.object(termlo, "shell_helper", side_effect=start_daemon):
            for answers, expected in ((None, 2248), ("\n\n", 2248), ("\n22\n", 22)):
                terminal = io.StringIO(answers) if answers is not None else None
                settings = termlo.config_dir() / "connection.json"
                settings.unlink(missing_ok=True)
                (self.home / "up").unlink(missing_ok=True)
                code = self.install(port=None, host_key=None, terminal=terminal)
                self.assertEqual(self.decode(code)["port"], expected)
                self.assertEqual(json.loads(settings.read_text())["local_port"], 2248)

    def prepare_fake_linux_tools(self):
        command(self.bin / "sudo", '[ "$1" != -n ] || shift; [ "$1" != true ] || exit 0; exec "$@"')
        command(self.bin / "dpkg", '[ "$1" = --version ]')
        for name in ("tmux", "git", "adb", "claude"):
            command(self.home / name, 'exit 0')
        command(self.home / "chromium", '''
case " $* " in *" --no-sandbox "*) exit 1 ;; *" --dump-dom "*) ;; *) exit 1 ;; esac
test ! -e "$HOME/fail-browser"
echo '<html><head><title>termlo-browser-ready</title></head></html>' ''')
        command(self.bin / "apt-get", '''
[ "$1" != --version ] || exit 0
echo "apt $*" >> "$EVENTS"
case " $* " in *" --download-only "*)
    archives=''
    for arg do case "$arg" in Dir::Cache::archives=*) archives=${arg#*=} ;; esac; done
    if [ -n "$archives" ]; then
        for arg do case "$arg" in git|tmux|adb|chromium|chromium-sandbox) echo deb > "$archives/${arg}_1_amd64.deb" ;; esac; done
    fi
    exit 0 ;;
esac
if [ "$1" = install ]; then
    for tool in "$@"; do
        case "$tool" in
            git|tmux|adb|chromium) cp "$HOME/$tool" "$HOME/fixtures/$tool" ;;
        esac
    done
fi''')
        command(self.bin / "curl", '''
[ "$1" != --version ] || exit 0
while [ "$1" != -o ]; do shift; done
test "$3" = https://claude.ai/install.sh
cat > "$2" <<'SH'
set -eu
test "$1" = stable
test -p /dev/stdin
if IFS= read -r answer; then exit 4; fi
echo claude >> "$EVENTS"
mkdir -p "$HOME/.local/bin"
cp "$HOME/claude" "$HOME/.local/bin/claude"
SH''')

    def test_full_first_install_retry_and_reuse(self):
        self.prepare_fake_linux_tools()
        fail = self.home / "fail-browser"
        fail.touch()
        with self.assertRaisesRegex(ValueError, "渲染测试页"):
            self.install(sync_only=False)
        self.assertFalse(self.cli.exists())
        self.assertFalse((termlo.config_dir() / "connection.json").exists())
        fail.unlink()
        code = self.install(sync_only=False)
        events = self.events.read_text()
        for name in ("git", "tmux", "adb", "chromium"):
            self.assertIn(name, events)
        self.assertNotIn("claude\n", events)
        self.assertNotIn("podman", events)
        self.assertEqual(self.decode(self.install(sync_only=False, host=None, port=None, host_key=None, name=None)), self.decode(code))
        self.assertEqual(self.events.read_text(), events)

    def wizard_install(self, answers):
        return self.decode(self.install(sync_only=False, terminal=io.StringIO(answers), host=None, port=None, name=None))

    def test_wizard_retries_invalid_fields_and_skips_claude_only(self):
        self.prepare_fake_linux_tools()
        with patch.object(wizard, "suggest_host", return_value=(None, "请填写地址")):
            result = self.wizard_install("\nhttps://bad.example\n[2001:db8::54]\n70000\n3456\n2\n")
        self.assertEqual((result["host"], result["port"]), ("2001:db8::54", 3456))
        self.assertTrue((self.bin / "chromium").exists())
        self.assertFalse((self.home / ".local/bin/claude").exists())

    def test_wizard_accepts_ssh_defaults_and_reuses_required_tools(self):
        self.prepare_fake_linux_tools()
        with patch.dict(os.environ, SSH_CONNECTION="10.0.0.1 50000 2606:4700:4700::1111 2200"):
            result = self.wizard_install("\n\n2\n")
        self.assertEqual((result["host"], result["port"]), ("2606:4700:4700::1111", 2200))
        operations = self.events.read_text()
        self.assertIn("chromium", operations)
        with patch.object(wizard, "suggest_host", side_effect=AssertionError("should reuse saved address")):
            self.assertEqual(self.wizard_install("\n\n2\n"), result)
        self.assertEqual(operations, self.events.read_text())

    def test_wizard_installs_claude_and_requires_a_working_browser_independently(self):
        self.prepare_fake_linux_tools()
        with patch.object(wizard, "suggest_host", return_value=("dev.example.org", "检测到的地址")):
            self.wizard_install("\n\n1\n")
        self.assertTrue((self.home / ".local/bin/claude").is_file())
        self.assertTrue((self.bin / "tmux").exists())
        self.assertFalse((self.bin / "podman").exists())
        (self.home / "fail-browser").touch()
        with self.assertRaisesRegex(ValueError, "安装前体检未通过"):
            self.wizard_install("\n\n")

    def test_china_claude_is_optional_and_uses_only_the_official_installer(self):
        self.prepare_fake_linux_tools()
        command(self.bin / "curl", '[ "$1" != --version ] || exit 0; for url do :; done; echo "$url" >> "$EVENTS"; exit 7')
        with patch.dict(os.environ, TERMLO_INSTALL_NETWORK="cn"), \
             patch.object(wizard, "suggest_host", return_value=("dev.example.org", "当前 SSH 会话")):
            defaults = self.wizard_install("\n\n\n")
            self.assertNotIn("claude.ai", self.events.read_text())
            self.events.write_text("")
            explicit = self.wizard_install("\n\n1\n2\n")
        self.assertEqual(defaults, explicit)
        self.assertEqual(self.events.read_text().splitlines(), ["https://claude.ai/install.sh"])

    def test_explicit_optional_download_failure_returns_a_usable_base_connection(self):
        self.prepare_fake_linux_tools()
        command(self.bin / "curl", '[ "$1" = --version ] || exit 7')
        args = argparse.Namespace(host="dev.example.org", port=22, host_key=self.public,
                                  name=None, sync_only=False, claude=True)
        output = io.StringIO()
        with redirect_stdout(output), self.assertRaisesRegex(ValueError, "Claude Code 未完成"):
            termlo.install(args)
        self.assertEqual(self.decode(output.getvalue().strip())["host"], "dev.example.org")
        self.assertTrue(self.cli.exists())
        self.assertTrue((self.home / ".ssh/authorized_keys").is_file())

    def test_wizard_cancel_preserves_saved_config(self):
        self.prepare_fake_linux_tools()
        original = self.install()
        with self.assertRaises(EOFError):
            self.wizard_install("other.example.org\n")
        self.assertEqual(self.decode(subprocess.check_output([str(self.cli), "connection-code"], text=True)), self.decode(original))


class HostDetectionTests(unittest.TestCase):
    def test_mac_console_prefers_its_network_address_over_the_router_exit(self):
        state = "IPv4 network interface information\n   en1 : flags : 0x5\n         address : 192.168.31.8\n"
        interfaces = ("en0: flags=8843<UP,RUNNING>\n\tinet 10.8.0.3 netmask 0xffffff00\n"
                      "en1: flags=8843<UP,RUNNING>\n\tinet 192.168.31.8 netmask 0xffffff00\n")
        replies = {("/usr/sbin/scutil", "--nwi"): state, ("/sbin/ifconfig", "-au"): interfaces}
        def network_command(args, **kwargs):
            data = replies.get(tuple(args), "")
            return subprocess.CompletedProcess(args, 0 if data else 1, stdout=data, stderr="")
        with patch.object(sys, "platform", "darwin"), patch.object(subprocess, "run", side_effect=network_command), \
             patch.object(wizard, "public_egress_address", side_effect=AssertionError("unexpected public lookup")):
            for egress in ("8.8.8.8", None):
                self.assertEqual(wizard.suggest_host(None, egress=egress)[0], "192.168.31.8")

    def test_mac_console_uses_an_active_ipv6_interface_without_network_state(self):
        interfaces = ("lo0: flags=8049<UP,LOOPBACK>\n\tinet 10.9.0.7 netmask 0xff000000\n"
                      "en0: flags=8843<UP,RUNNING>\n\tinet 192.168.9.9 netmask 0xffffff00\n\tstatus: inactive\n"
                      "en1: flags=8843<UP,RUNNING>\n\tinet6 fe80::1%en1 prefixlen 64\n"
                      "\tinet6 fd12::2 prefixlen 64 tentative\n\tinet6 fd12::3 prefixlen 64 temporary\n"
                      "\tinet6 fd12::8 prefixlen 64\n\tstatus: active\n")
        def network_command(args, **kwargs):
            data = interfaces if args == ["/sbin/ifconfig", "-au"] else ""
            return subprocess.CompletedProcess(args, 0 if data else 1, stdout=data, stderr="")
        with patch.object(sys, "platform", "darwin"), patch.object(subprocess, "run", side_effect=network_command), \
             patch.object(wizard, "public_egress_address", side_effect=AssertionError("unexpected public lookup")):
            self.assertEqual(wizard.suggest_host(None)[0], "fd12::8")

    def test_mac_network_state_cannot_promote_a_temporary_or_unusable_address(self):
        state = "IPv6 network interface information\n   en0 : flags : 0x5\n         address : fd12::14\n"
        for flag in ("temporary", "tentative", "duplicated", "detached", "deprecated"):
            interfaces = ("en0: flags=8843<UP,RUNNING>\n"
                          f"\tinet6 fd12::14 prefixlen 64 {flag}\n"
                          "\tinet6 fd12::8 prefixlen 64 secured\n\tstatus: active\n")
            with self.subTest(flag=flag), patch.object(sys, "platform", "darwin"), \
                 patch.object(wizard, "network_output", side_effect=[state, interfaces]):
                self.assertEqual(wizard.suggest_host(None)[0], "fd12::8")

    @unittest.skipUnless(sys.platform == "darwin", "Checks a real macOS console")
    def test_mac_console_accepts_a_default_assigned_to_this_host(self):
        output = subprocess.check_output(["/sbin/ifconfig", "-au"], text=True)
        assigned = set()
        for line in output.splitlines():
            fields = line.split()
            if len(fields) >= 2 and fields[0] in ("inet", "inet6"):
                address = termlo.ipaddress.ip_address(fields[1].split("%", 1)[0])
                if wizard.usable_address(address):
                    assigned.add(address)
        if not assigned:
            self.skipTest("No assigned unicast network address on this Mac")
        args = argparse.Namespace(host=None, port=None, name=None, host_key=None)
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, HOME=home, XDG_CONFIG_HOME=home, SSH_CONNECTION=""), \
             redirect_stderr(io.StringIO()), patch.object(wizard, "public_egress_address", side_effect=AssertionError):
            settings = termlo.connection_settings(args, io.StringIO("\n\n"), egress="8.8.8.8", detected_port=2222)
        self.assertTrue(termlo.ipaddress.ip_address(settings["host"]) in assigned, "Suggested address is not assigned to this Mac")
        self.assertEqual(settings["port"], 2222)

    def test_private_ssh_suggests_egress_or_local_address_when_offline(self):
        private = termlo.ipaddress.ip_address("10.1.2.3")
        with patch.object(sys, "platform", "linux"), patch.object(wizard, "local_addresses", return_value=[]), \
             patch.object(wizard, "public_egress_address", side_effect=["8.8.8.8", None, None]):
            self.assertEqual(wizard.suggest_host(private)[0], "8.8.8.8")
            self.assertEqual(wizard.suggest_host(private)[0], str(private))
            self.assertIsNone(wizard.suggest_host(None)[0])

    def test_linux_ssh_wizard_uses_the_private_session_or_the_public_nat_endpoint(self):
        args = argparse.Namespace(host=None, port=None, name=None, host_key=None)
        cases = [
            ("192.168.10.4", "192.168.10.8", "192.168.10.8"),
            ("fd42::4", "fd42::8", "fd42::8"),
            ("100.64.0.4", "100.64.0.8", "100.64.0.8"),
            ("1.0.0.1", "192.168.10.8", "8.8.8.8"),
            ("unknown", "192.168.10.8", "8.8.8.8"),
        ]
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, HOME=home, XDG_CONFIG_HOME=home), \
             patch.object(sys, "platform", "linux"), patch.object(wizard, "local_addresses", return_value=[]):
            for client, server, expected in cases:
                with self.subTest(client=client), redirect_stderr(io.StringIO()), \
                     patch.dict(os.environ, SSH_CONNECTION=f"{client} 50123 {server} 2222"):
                    settings = termlo.connection_settings(args, io.StringIO("\n\n"), egress="8.8.8.8")
                    self.assertEqual((settings["host"], settings["port"]), (expected, 2222))

    def test_remote_mac_prefers_the_address_of_its_current_ssh_connection(self):
        private = termlo.ipaddress.ip_address("192.168.1.8")
        with patch.object(sys, "platform", "darwin"), patch.object(wizard, "public_egress_address", side_effect=AssertionError):
            self.assertEqual(wizard.suggest_host(private), (str(private), "当前 SSH 会话"))

    def test_direct_ssh_and_public_interface_avoid_external_lookup(self):
        address = termlo.ipaddress.ip_address("2606:4700:4700::1111")
        with patch.object(wizard, "public_egress_address", side_effect=AssertionError("unexpected lookup")), \
             patch.object(wizard, "local_addresses", return_value=[address]):
            self.assertEqual(wizard.suggest_host(address)[0], str(address))
            self.assertEqual(wizard.suggest_host(None)[0], str(address))

    def test_ipv4_nat_session_prefers_ipv4_address_over_ipv6(self):
        private_v4 = termlo.ipaddress.ip_address("10.0.0.5")
        client_v4 = termlo.ipaddress.ip_address("8.8.8.8")
        public_v6 = termlo.ipaddress.ip_address("2606:4700:4700::1111")
        public_v4 = termlo.ipaddress.ip_address("1.1.1.1")
        with patch.object(sys, "platform", "linux"), \
             patch.object(wizard, "local_addresses", return_value=[public_v6, public_v4]):
            self.assertEqual(wizard.suggest_host(private_v4, client=client_v4)[0], str(public_v4))
        with patch.object(sys, "platform", "linux"), \
             patch.object(wizard, "local_addresses", return_value=[private_v4]), \
             patch.object(wizard, "public_egress_address", return_value="1.1.1.1") as lookup:
            self.assertEqual(wizard.suggest_host(private_v4, "global", "2606:4700:4700::1111", client=client_v4)[0],
                             "1.1.1.1")
            lookup.assert_called_once_with("global", ipv4_only=True)


class BrowserTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        self.session = str(uuid.uuid4())
        self.containers = {}
        self.started = []
        for context in [patch.object(browser, "require_engine", return_value="podman"),
                        patch.object(subprocess, "run", side_effect=self.engine),
                        patch.object(browser, "wait_until_ready")]:
            self.ready = context.start()
            self.addCleanup(context.stop)

    def engine(self, args, **kwargs):
        op = args[1]
        if op == "image":
            return subprocess.CompletedProcess(args, 0)
        if op == "container":
            item = self.containers.get(args[-1])
            return subprocess.CompletedProcess(args, 0 if item else 1, json.dumps([item]), "")
        if op == "ps":
            return subprocess.CompletedProcess(args, 0, "\n".join(self.containers), "")
        if op == "run":
            self.started.append(args)
            name = args[args.index("--name") + 1]
            owner = args[args.index("--label") + 1].split("=", 1)[1]
            publish = args[args.index("-p") + 1]
            ip, port, inner = publish.split(":")
            self.assertEqual((ip, inner), ("127.0.0.1", "3001"))
            secret = kwargs["env"]["PASSWORD"]
            self.assertNotIn(secret, args)
            host_port = port or str(40000 + len(self.started))
            self.containers[name] = dict(Id=name + "-id", State={"Running": True},
                Config={"Labels": {browser.LABEL: owner}, "Env": ["CUSTOM_USER=termlo", "PASSWORD=" + secret]},
                NetworkSettings={"Ports": {"3001/tcp": [dict(HostIp=ip, HostPort=host_port)]}})
            return subprocess.CompletedProcess(args, 0, name + "-id\n")
        self.assertEqual(op, "rm")
        name = next(name for name, item in self.containers.items() if item["Id"] == args[-1])
        del self.containers[name]
        return subprocess.CompletedProcess(args, 0)

    def start(self, session):
        output = io.StringIO()
        with redirect_stdout(output):
            browser.manage("start", session, self.folder)
        self.assertTrue(output.getvalue().startswith("TERMLO_BROWSER "))
        return json.loads(output.getvalue().split(" ", 1)[1])

    def test_sessions_reuse_isolate_and_stop_independently(self):
        first = self.start(self.session)
        self.assertEqual(self.start(self.session), first)
        other = self.start(None)
        self.assertEqual(other["port"], 3001)
        self.assertNotEqual(other["password"], first["password"])
        browser.manage("stop", self.session, self.folder)
        browser.manage("stop", self.session, self.folder)
        self.assertEqual(self.start(None), other)
        self.assertEqual(len(self.started), 2)

    def test_start_failure_cleans_up_and_foreign_container_is_preserved(self):
        self.ready.side_effect = ValueError("timeout")
        with self.assertRaisesRegex(ValueError, "timeout"):
            self.start(self.session)
        self.assertFalse(self.containers)
        self.ready.side_effect = None
        self.start(self.session)
        container = next(iter(self.containers.values()))
        container["Config"]["Labels"].clear()
        with self.assertRaisesRegex(ValueError, "其他容器"):
            browser.manage("stop", self.session, self.folder)
        self.assertEqual(len(self.containers), 1)


class ReadinessTests(unittest.TestCase):
    def test_only_accepts_an_authenticated_https_endpoint(self):
        access = dict(port=40123, user="termlo", password="temp")
        for anonymous_status in (401, 200):
            with patch("http.client.HTTPSConnection") as https:
                response = https.return_value.getresponse
                response.side_effect = [argparse.Namespace(status=200), argparse.Namespace(status=anonymous_status)]
                if anonymous_status == 401:
                    browser.wait_until_ready(access)
                else:
                    with self.assertRaisesRegex(ValueError, "匿名访问"):
                        browser.wait_until_ready(access)
                authenticated, anonymous = https.return_value.request.call_args_list
                self.assertIn("Authorization", authenticated.kwargs["headers"])
                self.assertEqual(anonymous.kwargs["headers"], {})
                self.assertEqual(https.call_args.args[:2], ("127.0.0.1", 40123))


if __name__ == "__main__":
    unittest.main()
