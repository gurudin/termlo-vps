"""Exercise the published shell bundle with script bytes and keyboard input on separate streams."""

import base64
import errno
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALL_URL = "https://raw.githubusercontent.com/gurudin/termlo-vps/main/install.sh"
INSTALL_COMMAND = f"curl -fLO {INSTALL_URL} && sh install.sh"

def endpoint(code):
    payload = code.strip().split("/")[-1]
    server = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    del server["pairing"]
    return server


class StreamInstallTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.bundle = self.home / "termlo-install.sh"
        subprocess.run(["bash", str(ROOT / "build-installer.sh"), str(self.bundle)], check=True)
        tools = self.home / "bin"
        tools.mkdir()
        for name in ("sh", "cat", "gzip", "bash", "base64", "tar", "dirname", "id", "mktemp", "rm", "ssh", "scp", "ssh-keygen"):
            (tools / name).symlink_to(shutil.which(name))
        (tools / "ssh-keyscan").write_text('#!/bin/sh\nprintf "host "; cat "$HOME/host_key.pub"\n')
        (tools / "ssh-keyscan").chmod(0o755)
        (tools / "apt-get").write_text('#!/bin/sh\ntest "$1" = --version\n')
        (tools / "apt-get").chmod(0o755)
        (tools / "python3").symlink_to(sys.executable)
        for name in ("git", "tmux", "adb", "chromium"):
            tool = tools / name
            tool.write_text("#!/bin/sh\n" + ("echo '<title>termlo-browser-ready</title>'\n" if name == "chromium" else "exit 0\n"))
            tool.chmod(0o755)
        agent = self.home / ".mutagen/agents/0.18.1/mutagen-agent"
        agent.parent.mkdir(parents=True)
        agent.write_text("#!/bin/sh\necho 0.18.1\n")
        agent.chmod(0o755)
        (tools / "curl").write_text("""#!/bin/bash
url=${!#}
case $url in
    --version) exec "$REAL_CURL" --version ;;
    "$INSTALL_URL") exec "$REAL_CURL" "$1" "$FIXTURE_INSTALL_URL" ;;
    file://*) exec "$REAL_CURL" "$@" ;;
    https://www.cloudflare.com/cdn-cgi/trace)
        echo probe >> "$HOME/geo-log"
        [[ -n $COUNTRY ]] && printf 'loc=%s\\nip=8.8.8.8\\n' "$COUNTRY" ;;
    https://myip.ipip.net) exit 6 ;;
    *) echo "unexpected URL $url" >> "$HOME/bad-url"; exit 60 ;;
esac
""")
        (tools / "curl").chmod(0o755)
        self.env = dict(HOME=str(self.home), PATH=str(tools), XDG_CONFIG_HOME=str(self.home / "config"),
                        PYTHONDONTWRITEBYTECODE="1", PYTHONUTF8="1", TMPDIR=str(self.home),
                        REAL_CURL=shutil.which("curl"), COUNTRY="US", INSTALL_URL=INSTALL_URL,
                        FIXTURE_INSTALL_URL=(ROOT / "install.sh").as_uri(),
                        SSH_CONNECTION="10.0.0.1 51870 2606:4700:4700::1111 2202")
        if sys.platform == "linux":
            (tools / "uname").symlink_to(shutil.which("uname"))
        else:
            # Exercise the Linux installer on the Mac development machine without installing system packages.
            (tools / "uname").write_text('#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac\n')
            (tools / "uname").chmod(0o755)
        (tools / "sitecustomize.py").write_text("import os, sys\nsys.platform = 'linux'\nos.geteuid = lambda: 501\n")
        self.env["PYTHONPATH"] = str(tools)
        key = self.home / "host_key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
        config = self.home / "config/termlo"
        config.mkdir(parents=True)
        (config / "connection.json").write_text(json.dumps({"host_key": str(key) + ".pub"}))

    def run_in_terminal(self, args):
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(self.home)
            os.execve("/bin/bash", ["bash", *args], self.env)
        output = bytearray()
        answered = False
        deadline = time.monotonic() + 20
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([master], [], [], remaining)[0]:
                    self.fail("等待管道安装向导超时\n" + output.decode(errors="replace"))
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
                if not answered and "[2606:4700:4700::1111]".encode() in output:
                    os.write(master, b"\n\n2\n")
                    answered = True
        finally:
            os.close(master)
            if time.monotonic() >= deadline:
                os.killpg(pid, signal.SIGKILL)
            _, status = os.waitpid(pid, 0)
        return status, output.decode()

    def run_wizard(self, args, channel):
        status, transcript = self.run_in_terminal(args)
        self.assertEqual(status, 0, transcript)
        self.assertIn("下载线路：" + channel, transcript)
        self.assertFalse((self.home / "bad-url").exists())
        self.assertLess(transcript.index("安装前体检"), transcript.index("1/3"))
        self.assertIn("3/3", transcript)
        codes = [line for line in transcript.splitlines() if line.startswith("termlo://connect/")]
        self.assertEqual(len(codes), 1, transcript)
        server = endpoint(codes[0])
        self.assertEqual(server["version"], 2)
        self.assertEqual((server["host"], server["port"]), ("2606:4700:4700::1111", 2202))
        cli = str(self.home / ".local/bin/termlo")
        self.assertEqual(endpoint(subprocess.check_output([cli, "connection-code"], env=self.env, text=True)), server)
        return server

    def test_public_install_command_rechecks_and_exits_before_a_blocked_reinstall(self):
        readme = (ROOT / "README.md").read_text()
        invocation = readme.split("```sh\n", 1)[1].split("\n```", 1)[0]
        self.assertEqual(invocation, INSTALL_COMMAND)
        self.run_wizard(["-c", invocation], "海外")
        self.assertEqual((self.home / "install.sh").read_bytes(), self.bundle.read_bytes())
        keys = self.home / ".ssh/authorized_keys"
        before = keys.read_bytes()

        (self.home / "bin/ssh-keyscan").write_text("#!/bin/sh\nexit 1\n")
        status, transcript = self.run_in_terminal(["-c", invocation])
        self.assertNotEqual(status, 0)
        self.assertIn("体检未通过", transcript)
        self.assertIn("ssh-keyscan -T 3 -p 2202", transcript)
        self.assertNotIn("1/3", transcript)
        self.assertNotIn("termlo://connect/", transcript)
        self.assertEqual(keys.read_bytes(), before)

    def test_curl_pipe_reads_answers_from_terminal_and_emits_real_code(self):
        self.run_wizard(["-o", "pipefail", "-c", 'curl -fsSL "$1" | bash',
                         "termlo-test", self.bundle.as_uri()], "海外")

    def test_downloaded_file_runs_alone_in_china_and_without_region_services(self):
        entry = self.home / "downloaded installer.sh"
        shutil.copyfile(ROOT / "install.sh", entry)
        self.env["COUNTRY"] = "CN"
        code = self.run_wizard([str(entry)], "中国大陆")
        self.env["COUNTRY"] = ""
        cli = str(self.home / ".local/bin/termlo")
        result = subprocess.run([cli, "install", "--sync-only"], env=self.env, text=True,
                                capture_output=True, check=True)
        self.assertIn("未识别到出口地区", result.stderr)
        self.assertEqual(endpoint(result.stdout), code)

    def test_published_entry_points_match_the_built_bundle(self):
        self.assertEqual((ROOT / "install.sh").read_bytes(), (ROOT / "dist/termlo-install.sh").read_bytes())
        self.assertEqual(self.bundle.read_bytes(), (ROOT / "install.sh").read_bytes())

    def test_installed_uninstall_and_repeat_via_piped_bundle(self):
        cli = self.home / ".local/bin/termlo"
        folder = self.home / "config/termlo"
        keys = self.home / ".ssh/authorized_keys"
        keys.parent.mkdir()
        original = (self.home / "host_key.pub").read_bytes()
        keys.write_bytes(original)
        subprocess.run(["bash", str(self.bundle), "--sync-only"], env=self.env, capture_output=True, check=True)
        self.assertIn(b"termlo-pair:", keys.read_bytes())
        self.assertTrue((folder / "installed-components.json").is_file())
        result = subprocess.run([str(cli), "uninstall"], env=self.env, capture_output=True, text=True, check=True)
        self.assertIn("卸载完成", result.stderr)
        self.assertFalse(cli.exists())
        self.assertEqual(keys.read_bytes(), original)
        self.assertFalse(folder.exists())
        self.assertTrue((self.home / ".mutagen/agents/0.18.1/mutagen-agent").exists())
        geo = (self.home / "geo-log").read_bytes()
        subprocess.run(["bash", "-s", "--", "uninstall"], input=self.bundle.read_bytes(),
                       env=self.env, capture_output=True, check=True, start_new_session=True)
        self.assertEqual((self.home / "geo-log").read_bytes(), geo)
        self.assertFalse((self.home / "bad-url").exists())
        self.assertFalse(folder.exists())

    def test_standalone_uninstaller_cleans_legacy_install_without_bootstrapping(self):
        cli = self.home / ".local/bin/termlo"
        subprocess.run(["bash", str(self.bundle), "--sync-only"], env=self.env, capture_output=True, check=True)
        (self.home / "config/termlo/installed-components.json").unlink()
        result = subprocess.run(["bash", "-s", "--", "uninstall"], input=self.bundle.read_text(),
                                env=self.env, capture_output=True, text=True, check=True, start_new_session=True)
        self.assertIn("旧版本", result.stderr)
        self.assertFalse(cli.exists())
        self.assertFalse((self.home / "config/termlo/connection.json").exists())
        self.assertTrue((self.home / ".mutagen/agents/0.18.1/mutagen-agent").exists())

    def test_missing_runtime_blocks_all_install_changes_until_supplied(self):
        tools = self.home / "bin"
        (tools / "python3").unlink()
        (tools / "apt-get").write_text('#!/bin/sh\n[ "$1" = --version ] || echo "$*" >> "$HOME/apt-log"\n')
        self.env["COUNTRY"] = "CN"
        status, transcript = self.run_in_terminal(["-c", INSTALL_COMMAND])
        self.assertNotEqual(status, 0)
        for row in ("[未通过] Python", "[未通过] 远程浏览器", "apt-get install -y python3", "[通过] 安装权限"):
            self.assertIn(row, transcript)
        self.assertNotIn("1/3", transcript)
        self.assertFalse((self.home / "apt-log").exists())
        self.assertFalse((self.home / ".ssh").exists())
        self.assertFalse((self.home / ".local").exists())
        (tools / "python3").symlink_to(sys.executable)
        result = subprocess.run(["bash", str(self.bundle), "--sync-only"], env=self.env, text=True,
                                capture_output=True, check=True)
        self.assertTrue(result.stdout.startswith("termlo://connect/"))
        self.assertIn("下载线路：中国大陆", result.stderr)
        self.assertFalse((self.home / "apt-log").exists())
        self.assertEqual((self.home / "geo-log").read_text().splitlines(), ["probe"])

    def test_no_terminal_or_incomplete_download_does_not_start_install(self):
        script = self.bundle.read_bytes()
        for data, expected in [(script, "交互终端"), (script.split(b"\nTERMLO_ARCHIVE\n")[0], "")]:
            run = subprocess.run(["/bin/bash", "-s"], input=data, env=self.env, capture_output=True,
                                 start_new_session=True, timeout=10)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn(expected, run.stderr.decode())
            self.assertFalse((self.home / ".local/bin/termlo").exists())
