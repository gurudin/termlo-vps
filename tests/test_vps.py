import argparse
import base64
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
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
                                      "TERMLO_INSTALL_NETWORK": "global"}, clear=True)
        env.start()
        self.addCleanup(env.stop)
        platform = patch.object(sys, "platform", "linux")
        platform.start()
        self.addCleanup(platform.stop)
        for name in ("env", "bash", "id", "dirname", "ssh", "ssh-keygen", "scp", "mkdir", "mktemp", "rm", "cp", "cat", "chmod", "touch", "sh"):
            (self.bin / name).symlink_to(shutil.which(name, path="/usr/bin:/bin"))
        (self.bin / "python3").symlink_to(sys.executable)
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
            with patch.dict(os.environ, SSH_CONNECTION=ssh), self.assertRaisesRegex(ValueError, "--host"):
                self.install(host=None)
        self.assertFalse(self.cli.exists())
        with patch.dict(os.environ, SSH_CONNECTION="10.0.0.1 54000 2606:4700:4700::1111 2222"):
            payload = self.decode(self.install(host=None, port=None))
        self.assertEqual((payload["host"], payload["port"]), ("2606:4700:4700::1111", 2222))

    def test_invalid_update_preserves_usable_command_and_configuration(self):
        code = self.install()
        for override in [dict(host_key=str(self.key)), dict(port=65536), dict(host="dev.example.org:2207")]:
            with self.assertRaises(ValueError):
                self.install(**override)
        self.assertEqual(self.decode(subprocess.check_output([str(self.cli), "connection-code"], text=True)), self.decode(code))

    def test_default_pin_uses_a_local_key_actually_offered_by_sshd(self):
        offered = self.home / "ssh_host_ecdsa_key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ecdsa", "-N", "", "-f", str(offered)], check=True)
        shutil.copyfile(self.public, self.home / "ssh_host_ed25519_key.pub")
        command(self.bin / "ssh-keyscan", 'printf "host "; cat "$HOME/ssh_host_ecdsa_key.pub"')
        with patch.dict(os.environ, SSH_CONNECTION="10.0.0.1 53900 10.1.0.2 22"):
            code = self.install(host_key=None)
        pin = subprocess.check_output(["ssh-keygen", "-lf", str(offered) + ".pub"], text=True).split()[1]
        self.assertEqual(self.decode(code)["fingerprint"], pin)

    def prepare_fake_linux_tools(self):
        command(self.bin / "sudo", '[ "$1" != -n ] || shift; [ "$1" != true ] || exit 0; exec "$@"')
        for name in ("tmux", "git", "adb", "claude"):
            command(self.home / name, 'exit 0')
        command(self.home / "chromium", '''
case " $* " in *" --no-sandbox "*) exit 1 ;; *" --dump-dom "*) ;; *) exit 1 ;; esac
test ! -e "$HOME/fail-browser"
echo '<html><head><title>termlo-browser-ready</title></head></html>' ''')
        command(self.bin / "apt-get", '''
[ "$1" != --version ] || exit 0
echo "apt $*" >> "$EVENTS"
case " $* " in *" --download-only "*) exit 0 ;; esac
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
        with self.assertRaisesRegex(ValueError, "渲染测试页"):
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
    def test_private_ssh_suggests_egress_or_local_address_when_offline(self):
        private = termlo.ipaddress.ip_address("10.1.2.3")
        with patch.object(sys, "platform", "linux"), patch.object(wizard, "local_addresses", return_value=[]), \
             patch.object(wizard, "public_egress_address", side_effect=["8.8.8.8", None, None]):
            self.assertEqual(wizard.suggest_host(private)[0], "8.8.8.8")
            self.assertEqual(wizard.suggest_host(private)[0], str(private))
            self.assertIsNone(wizard.suggest_host(None)[0])

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
