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
        for name in ("bash", "base64", "tar", "dirname", "id", "mktemp", "rm", "scp", "ssh-keygen"):
            (tools / name).symlink_to(shutil.which(name))
        (tools / "python3").symlink_to(sys.executable)
        (tools / "curl").write_text("""#!/bin/bash
url=${!#}
case $url in
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
                        REAL_CURL=shutil.which("curl"), COUNTRY="US",
                        SSH_CONNECTION="10.0.0.1 51870 2606:4700:4700::1111 2202")
        if sys.platform == "linux":
            (tools / "uname").symlink_to(shutil.which("uname"))
        else:
            # Exercise the Linux installer on the Mac development machine without installing system packages.
            (tools / "uname").write_text("#!/bin/sh\necho Linux\n")
            (tools / "uname").chmod(0o755)
            (tools / "sitecustomize.py").write_text("import sys\nsys.platform = 'linux'\n")
            self.env["PYTHONPATH"] = str(tools)
        key = self.home / "host_key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
        config = self.home / "config/termlo"
        config.mkdir(parents=True)
        (config / "connection.json").write_text(json.dumps({"host_key": str(key) + ".pub"}))

    def run_wizard(self, args, channel):
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
                    os.write(master, b"\n\n2\n2\n")
                    answered = True
        finally:
            os.close(master)
            if time.monotonic() >= deadline:
                os.killpg(pid, signal.SIGKILL)
            _, status = os.waitpid(pid, 0)
        transcript = output.decode()
        self.assertEqual(status, 0, transcript)
        self.assertIn("下载线路：" + channel, transcript)
        self.assertFalse((self.home / "bad-url").exists())
        self.assertIn("3/3", transcript)
        codes = [line for line in transcript.splitlines() if line.startswith("termlo://connect/")]
        self.assertEqual(len(codes), 1, transcript)
        server = endpoint(codes[0])
        self.assertEqual(server["version"], 2)
        self.assertEqual((server["host"], server["port"]), ("2606:4700:4700::1111", 2202))
        cli = str(self.home / ".local/bin/termlo")
        self.assertEqual(endpoint(subprocess.check_output([cli, "connection-code"], env=self.env, text=True)), server)
        return server

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

    def test_missing_python_bootstraps_packages_and_reuses_one_region_lookup(self):
        tools = self.home / "bin"
        (tools / "python3").unlink()
        (tools / "env").symlink_to(shutil.which("env"))
        (tools / "sudo").write_text('#!/bin/sh\nexec "$@"\n')
        (tools / "sudo").chmod(0o755)
        (tools / "apt-get").write_text("""#!/bin/sh
echo "$*" >> "$HOME/apt-log"
case " $* " in *" --no-download "*) /bin/ln -s "$REAL_PYTHON" "$HOME/bin/python3" ;; esac
""")
        (tools / "apt-get").chmod(0o755)
        self.env.update(REAL_PYTHON=sys.executable, COUNTRY="CN")
        result = subprocess.run(["bash", str(self.bundle), "--sync-only"], env=self.env, text=True,
                                capture_output=True, check=True)
        self.assertTrue(result.stdout.startswith("termlo://connect/"))
        self.assertIn("下载线路：中国大陆", result.stderr)
        self.assertIn("python3", (self.home / "apt-log").read_text())
        self.assertEqual((self.home / "geo-log").read_text().splitlines(), ["probe"])

    def test_no_terminal_or_incomplete_download_does_not_start_install(self):
        script = self.bundle.read_bytes()
        for data, expected in [(script, "交互终端"), (script.split(b"\nTERMLO_ARCHIVE\n")[0], "")]:
            run = subprocess.run(["/bin/bash", "-s"], input=data, env=self.env, capture_output=True,
                                 start_new_session=True, timeout=10)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn(expected, run.stderr.decode())
            self.assertFalse((self.home / ".local/bin/termlo").exists())
