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


class StreamInstallTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)
        self.bundle = self.home / "termlo-install.sh"
        subprocess.run(["bash", str(ROOT / "build-installer.sh"), str(self.bundle)], check=True)
        tools = self.home / "bin"
        tools.mkdir()
        for name in ("bash", "base64", "tar", "dirname", "id", "mktemp", "rm", "scp", "ssh-keygen", "curl"):
            (tools / name).symlink_to(shutil.which(name))
        (tools / "python3").symlink_to(sys.executable)
        self.env = dict(HOME=str(self.home), PATH=str(tools), XDG_CONFIG_HOME=str(self.home / "config"),
                        PYTHONDONTWRITEBYTECODE="1", PYTHONUTF8="1", TMPDIR=str(self.home),
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

    def test_curl_pipe_reads_answers_from_terminal_and_emits_real_code(self):
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(self.home)
            os.execve("/bin/bash", ["bash", "-o", "pipefail", "-c", 'curl -fsSL "$1" | bash',
                                   "termlo-test", self.bundle.as_uri()], self.env)
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
        self.assertIn("3/3", transcript)
        codes = [line for line in transcript.splitlines() if line.startswith("termlo://connect/")]
        self.assertEqual(len(codes), 1, transcript)
        payload = codes[0].split("/")[-1]
        server = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        self.assertEqual((server["host"], server["port"]), ("2606:4700:4700::1111", 2202))
        cli = str(self.home / ".local/bin/termlo")
        self.assertEqual(subprocess.check_output([cli, "connection-code"], env=self.env, text=True).strip(), codes[0])

    def test_no_terminal_or_incomplete_download_does_not_start_install(self):
        script = self.bundle.read_bytes()
        for data, expected in [(script, "交互终端"), (script.split(b"\nTERMLO_ARCHIVE\n")[0], "")]:
            run = subprocess.run(["/bin/bash", "-s"], input=data, env=self.env, capture_output=True,
                                 start_new_session=True, timeout=10)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn(expected, run.stderr.decode())
            self.assertFalse((self.home / ".local/bin/termlo").exists())
