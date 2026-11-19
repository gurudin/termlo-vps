"""Issue and redeem short-lived invitations over the account's existing SSH port."""

import base64
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import tempfile
import time


LIFETIME = 600
MARKER = re.compile(rb" termlo-(pair|spent):([0-9a-f]{32}):([0-9]{1,12})$")
ED25519_PREFIX = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
RECEIPT = "termlo-paired-v2"


@contextmanager
def locked_authorized_keys():
    directory = Path.home() / ".ssh"
    directory.mkdir(mode=0o700, exist_ok=True)
    with (directory / ".termlo-pair.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = (directory / "authorized_keys").resolve()
        try:
            lines = path.read_bytes().splitlines(keepends=True)
        except FileNotFoundError:
            lines = []
        yield path, lines


def write_keys(path, lines, addition):
    # A single rename commits both consumption of the invitation and enrollment of the Mac.
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        stage = Path(out.name)
        try:
            out.writelines(lines)
            if addition:
                if lines and not lines[-1].endswith(b"\n"):
                    out.write(b"\n")
                out.write(addition + b"\n")
            out.flush()
            os.fsync(out.fileno())
            os.replace(stage, path)
        finally:
            stage.unlink(missing_ok=True)


def invitation_entry(line):
    if line.startswith(b'restrict,expiry-time="'):
        return MARKER.search(line.rstrip(b"\r\n"))
    return None


def issue():
    with tempfile.TemporaryDirectory() as temp:
        key = Path(temp) / "invite"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(key)],
                       check=True, stdout=subprocess.DEVNULL)
        public = key.with_suffix(".pub").read_bytes().strip()
        private = key.read_text(encoding="ascii")
    ticket = secrets.token_hex(16)
    command = shlex.quote(str(Path.home() / ".local/bin/termlo")) + " redeem " + ticket
    command = command.replace("\\", "\\\\").replace('"', '\\"')
    with locked_authorized_keys() as (path, lines):
        now = int(time.time())
        expires = now + LIFETIME
        deadline = time.strftime("%Y%m%d%H%M%S", time.localtime(expires))
        options = f'restrict,expiry-time="{deadline}",command="{command}"'
        marker = f"termlo-pair:{ticket}:{expires}"
        live = [line for line in lines if not (match := invitation_entry(line)) or int(match[3]) > now]
        write_keys(path, live, options.encode() + b" " + public + b" " + marker.encode())
    return dict(expiresAt=expires, key=private)


def redeem(ticket, request):
    # The original command carries only one canonical Ed25519 public key, never shell input.
    match = re.fullmatch(r"termlo-pair ([A-Za-z0-9+/]{68})", request)
    if not match or not re.fullmatch(r"[0-9a-f]{32}", ticket):
        raise ValueError("此连接码仅可用于绑定一台 Mac。")
    blob = match[1]
    wire = base64.b64decode(blob, validate=True)
    if len(wire) != len(ED25519_PREFIX) + 32 or not wire.startswith(ED25519_PREFIX):
        raise ValueError("Mac 提供的登录凭据无效。")
    with locked_authorized_keys() as (path, lines):
        for index, line in enumerate(lines):
            entry = invitation_entry(line)
            if entry and entry[2].decode() == ticket:
                if entry[1] == b"spent" or int(entry[3]) <= time.time():
                    break
                # A used invitation can only reach this same rejection until it expires.
                # This lets a retry receive an application error without failing SSH authentication.
                lines[index] = line[:entry.start(1)] + b"spent" + line[entry.end(1):]
                device = f"ssh-ed25519 {blob} termlo-mac".encode()
                already_bound = any(line.rstrip(b"\r\n") == device for line in lines)
                write_keys(path, lines, None if already_bound else device)
                return RECEIPT
    raise ValueError("连接码已使用或已过期。请在 VPS 上生成新码。")
