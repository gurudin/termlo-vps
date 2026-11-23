"""Exercise the unchanged public installer on disposable GitHub runners."""
import base64
import errno
import hashlib
import ipaddress
import json
import os
import pathlib
import platform
import pty
import re
import select
import shlex
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
PUBLIC = "curl -fLO https://raw.githubusercontent.com/gurudin/termlo-vps/main/install.sh && sh install.sh"
ENTRY = PUBLIC if os.environ.get("REVIEW_CANDIDATE") != "yes" else "sh install.sh"
SSH = ["ssh", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes",
       "-o", "StrictHostKeyChecking=yes", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ConnectTimeout=6",
       "-o", "ClearAllForwardings=yes"]


def output(args):
    result = subprocess.run(list(map(str, args)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stderr[-650:]}")
    return result.stdout.strip()


def wizard(args):
    child, fd = pty.fork()
    if child == 0:
        os.execvp(args[0], args)
    data = bytearray()
    answered = 0
    marker = " ›".encode()
    deadline = time.monotonic() + 700
    try:
        while True:
            if time.monotonic() >= deadline:
                os.killpg(child, signal.SIGKILL)
                raise TimeoutError("Installer exceeded the test deadline")
            if not select.select([fd], [], [], 3)[0]:
                continue
            try:
                chunk = os.read(fd, 65536)
            except OSError as err:
                if err.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            data.extend(chunk)
            prompts = data.count(marker)
            if prompts > answered:
                if prompts > 5:
                    os.killpg(child, signal.SIGKILL)
                    raise RuntimeError("Repeated prompts prevented accepting defaults")
                os.write(fd, b"\n")
                answered = prompts
    finally:
        os.close(fd)
        _, status = os.waitpid(child, 0)
    return os.waitstatus_to_exitcode(status), data.decode(errors="replace").replace("\r", "")


def diagnostic(text):
    # Never copy an invitation or account keys into Actions logs.
    rows = [line for line in text.splitlines() if "termlo://" not in line and "PRIVATE KEY" not in line]
    return "\n".join(rows[-35:])


def checked_code(result):
    status, transcript = result
    if status:
        raise RuntimeError(f"Installer exited {status}\n{diagnostic(transcript)}")
    assert transcript.index("安装前体检") < transcript.index("体检通过") < transcript.index("1/3") < transcript.index("3/3")
    codes = re.findall(r"^termlo://connect/([A-Za-z0-9_-]+)$", transcript, re.M)
    assert len(codes) == 1, "Expected one invitation"
    encoded = codes[0]
    return json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))), transcript


def verify():
    os.umask(0o077)
    assert os.environ.get("GITHUB_ACTIONS") == "true", "A disposable GitHub runner is required"
    for name in ("SSH_CONNECTION", "SSH_CLIENT", "SSH_AUTH_SOCK", "GH_TOKEN", "GITHUB_TOKEN", "TERMLO_INSTALL_NETWORK"):
        os.environ.pop(name, None)
    mac = platform.system() == "Darwin"
    host = os.environ["REVIEW_HOST"]
    user = os.environ["REVIEW_USER"]
    assert ipaddress.ip_address(host).is_private and not ipaddress.ip_address(host).is_loopback
    assert PUBLIC in (ROOT / "README.md").read_text()
    expected = hashlib.sha256((ROOT / "install.sh").read_bytes()).hexdigest()
    with tempfile.TemporaryDirectory() as directory:
        work = pathlib.Path(directory).resolve()
        os.chdir(work)
        if mac:
            assert not (pathlib.Path.home() / ".config/termlo/connection.json").exists()
            assert not (pathlib.Path.home() / ".local/bin/termlo").exists()
            normal = work / "normal"
            output(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", normal])
            sshdir = pathlib.Path.home() / ".ssh"
            sshdir.mkdir(mode=0o700, exist_ok=True)
            with (sshdir / "authorized_keys").open("a") as out:
                out.write("\n" + normal.with_suffix(".pub").read_text())
            pin = work / "normal.known"
            pin.write_text(output(["ssh-keyscan", "-T", "3", "-t", "ed25519", host]) + "\n")
            normal_login = subprocess.run([*SSH, "-o", "UserKnownHostsFile=" + str(pin), "-i", normal, user + "@" + host, "printf ordinary"], capture_output=True, text=True)
            print("Ordinary SSH login before Termlo: " + ("passed" if normal_login.stdout == "ordinary" else "failed"), flush=True)
            for item in [pathlib.Path.home(), sshdir, sshdir / "authorized_keys"]:
                print("SSH directory or file:", item.name, oct(item.stat().st_mode & 0o777), "uid", item.stat().st_uid, flush=True)
            settings = output(["sudo","/usr/sbin/sshd","-T","-C", f"user={user},host=localhost,addr={host}"])
            print("\n".join(line for line in settings.splitlines() if line.split()[0] in
                ("strictmodes","pubkeyauthentication","authorizedkeysfile","authenticationmethods","allowusers","denyusers","allowgroups","denygroups")), flush=True)
            print(subprocess.run(["/usr/bin/dscl",".","-read","/Groups/com.apple.access_ssh","GroupMembership"],capture_output=True,text=True).stdout.strip(), flush=True)
            if ENTRY != PUBLIC:
                (work / "install.sh").write_bytes((ROOT / "install.sh").read_bytes())
            launch = ["/bin/sh", "-c", ENTRY]
        else:
            known = work / "bootstrap.known"
            known.write_text(host + " " + output(["docker", "exec", "termlo-review", "cat", "/etc/ssh/ssh_host_ed25519_key.pub"]) + "\n")
            login = [*SSH, "-o", "UserKnownHostsFile=" + str(known), "-i", os.environ["REVIEW_BOOTSTRAP"]]
            target = user + "@" + host
            launch = [*login, "-tt", target, ENTRY]
            output([*login, target, "test ! -e ~/.local/bin/termlo && test ! -e ~/.config/termlo/connection.json"])
            if ENTRY != PUBLIC:
                output(["docker", "cp", ROOT / "install.sh", "termlo-review:/root/install.sh"])
            status, report = wizard(launch)
            if not (status and "[未通过] Python" in report and "apt-get install -y python3" in report
                    and "1/3" not in report and "termlo://connect/" not in report):
                raise RuntimeError("Missing-runtime preflight did not stop with recovery instructions\n" + diagnostic(report))
            output([*login, target, "test ! -e ~/.local/bin/termlo && test ! -e ~/.config/termlo/installed-components.json && ! grep -q termlo-mac ~/.ssh/authorized_keys"])
            output([*login, target, "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y python3"])
            print("Real Debian: missing Python blocked installation; applied the listed apt-get repair", flush=True)
        payload, transcript = checked_code(wizard(launch))
        actual = hashlib.sha256((work / "install.sh").read_bytes()).hexdigest() if mac else output([*login, target, "sha256sum install.sh"]).split()[0]
        assert actual == expected, "Executed installer differs from the reviewed bytes"
        print("All wizard defaults accepted; exactly one code from reviewed installer " + actual, flush=True)
        optional_failed = "Claude Code 安装失败" in transcript
        if optional_failed:
            start = transcript.find("正在为当前 SSH 用户安装 Claude")
            end = transcript.find("跳过，继续安装向导", max(0,start))
            print("Optional Claude download result: " + diagnostic(transcript[max(0,start):end])[-2200:], flush=True)
        if payload["host"] != host or payload["port"] != 22:
            why = re.search(r"服务器地址（([^）]+)）", transcript)
            print("Returned endpoint matches known SSH login: no; address source: " + (why[1] if why else "unknown"), flush=True)
            raise AssertionError("Installer emitted a different endpoint from the reachable private SSH address")
        assert payload["user"] == user
        print("Accepted default endpoint matches the receiver's actual address and SSH port", flush=True)
        pin = work / "known_hosts"
        pin.write_text(host + " " + payload["hostKey"] + "\n")
        invite, device = work / "invitation", work / "device"
        invite.write_text(payload["pairing"]["key"])
        output(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", device])
        fixed = [*SSH, "-o", "UserKnownHostsFile=" + str(pin)]
        target = user + "@" + payload["host"]
        pubkey = device.with_suffix(".pub").read_text().split()[1]
        assert output([*fixed, "-i", invite, target, "termlo-pair " + pubkey]) == "termlo-paired-v2"
        connection = [*fixed, "-i", device, target]
        assert output([*connection, "printf paired"]) == "paired"
        assert output([*connection, "printf reconnected"]) == "reconnected"
        print("New client key bound using the emitted invitation, then reconnected with its own key", flush=True)
        result = output([*connection, '"$HOME/.local/bin/termlo" browser check && "$HOME/.mutagen/agents/0.18.1/mutagen-agent" version'])
        assert "0.18.1" in result and "原生浏览器" in result
        print("Installed remote browser rendered a page and the installed Mutagen agent ran", flush=True)
        if optional_failed:
            raise AssertionError("Default base binding passed but the optional official Claude Code installation failed")
        version = output([*connection, 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; claude --version'])
        assert "Claude" in version
        print("Official Claude Code verified by running " + version, flush=True)


if __name__ == "__main__":
    verify()
