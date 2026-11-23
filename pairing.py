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
import sys
import tempfile
import time


LIFETIME = 600
MARKER = re.compile(rb" termlo-(pair|spent):([0-9a-f]{32}):([0-9]{1,12})$")
ED25519_PREFIX = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
RECEIPT = "termlo-paired-v2"


def check_authorization_directories():
    try:
        home = Path.home().resolve()
        ssh = home / ".ssh"
        paths = {home: '"$HOME"', ssh.resolve(): '"$HOME/.ssh"'}
        # StrictModes walks the real path of authorized_keys, stopping at the
        # account home (or at the root for a link outside the account home).
        for parent in (ssh / "authorized_keys").resolve().parents:
            paths.setdefault(parent, shlex.quote(str(parent)))
            if parent == home:
                break
    except (OSError, RuntimeError) as error:
        raise ValueError("请检查 ~/.ssh 和 authorized_keys 的链接是否循环、当前账号能否访问链接目标。") from error

    problems = []
    for path, label in paths.items():
        if not path.is_dir():
            continue
        info = path.stat()
        if info.st_uid not in (0, os.getuid()):
            problems.append(f"{label} 属于其他账号。请让管理员核对所有者，将 SSH 授权文件保存在该账号的专用目录。")
        elif info.st_mode & 0o022:
            if path != home and home not in path.parents:
                problems.append(f"SSH 授权文件经过可被其他用户写入的外部目录 {label}。请将授权文件迁入账号的专用目录并更新链接。")
            else:
                command = "chmod" if info.st_uid == os.getuid() else "sudo chmod"
                problems.append(f"{label} 允许组或其他用户写入。请收紧目录权限后重试：\n             {command} go-w {label}")
    if problems:
        raise ValueError("\n           ".join(problems))


def account_file(path, *, replace):
    """Check a lock opened for append or a key file updated by atomic rename."""
    try:
        target = path.resolve()
    except (OSError, RuntimeError) as error:
        raise ValueError(f"请检查 {path} 的链接是否循环，以及当前 SSH 账号能否访问其目标。") from error
    if path.is_symlink() and (replace or not target.exists()):
        if not target.parent.is_dir() or not os.access(target.parent, os.W_OK | os.X_OK):
            raise ValueError(f"请将 {path} 的链接指向现有且当前账号可写的目录中的文件。当前目标为 {target}。")
    if target.exists():
        if not target.is_file():
            raise ValueError(f"请移开占用 {target} 的目录或特殊文件，使该位置可用于普通文件。")
        if not os.access(target, os.R_OK if replace else os.W_OK):
            access = "读取" if replace else "写入"
            raise ValueError(f"请让当前 SSH 账号能够{access}文件 {target}。")
    return target


@contextmanager
def locked_authorized_keys():
    directory = Path.home() / ".ssh"
    directory.mkdir(mode=0o700, exist_ok=True)
    with account_file(directory / ".termlo-pair.lock", replace=False).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = account_file(directory / "authorized_keys", replace=True)
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


def binding_command(ticket):
    command = shlex.quote(str(Path.home() / ".local/bin/termlo")) + " redeem " + ticket
    return command.replace("\\", "\\\\").replace('"', '\\"')


def managed_key(line):
    line = line.rstrip(b"\r\n")
    entry = invitation_entry(line)
    if entry:
        command = binding_command(entry[2].decode()).encode()
        match = re.fullmatch(rb'restrict,expiry-time="[0-9]{14}Z?",command="' + re.escape(command)
                             + rb'" ssh-ed25519 ([A-Za-z0-9+/]{68})', line[:entry.start()])
    else:
        match = re.fullmatch(rb"ssh-ed25519 ([A-Za-z0-9+/]{68}) termlo-mac", line)
    return bool(match and base64.b64decode(match[1]).startswith(ED25519_PREFIX))


def revoke_all():
    directory = Path.home() / ".ssh"
    keys = directory / "authorized_keys"
    lock = directory / ".termlo-pair.lock"
    count = 0
    # An account with only ordinary keys can have a read-only .ssh directory.
    if keys.is_file() and any(managed_key(line) for line in keys.read_bytes().splitlines()):
        with locked_authorized_keys() as (path, lines):
            remaining = [line for line in lines if not managed_key(line)]
            count = len(lines) - len(remaining)
            if count:
                write_keys(path, remaining, None)
    if lock.is_file() and not lock.is_symlink() and lock.stat().st_size == 0:
        lock.unlink()
    return count


def ssh_expiry_time(expires, utc_expiry):
    if utc_expiry:
        return time.strftime("%Y%m%d%H%M%SZ", time.gmtime(expires))
    # Older sshd interprets a 14-digit deadline in the system time zone.
    # Keep the caller's TZ intact, including when other threads use it.
    if "TZ" in os.environ:
        system_env = os.environ.copy()
        del system_env["TZ"]
        return subprocess.check_output(
            [sys.executable, "-IS", "-c",
             "import sys,time; print(time.strftime('%Y%m%d%H%M%S', time.localtime(int(sys.argv[1]))))",
             str(expires)], text=True, env=system_env).strip()
    return time.strftime("%Y%m%d%H%M%S", time.localtime(expires))


@contextmanager
def pending_invitation(locked_keys, *, utc_expiry=False):
    check_authorization_directories()
    with tempfile.TemporaryDirectory() as temp:
        key = Path(temp) / "invite"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", str(key)],
                       check=True, stdout=subprocess.DEVNULL)
        public = key.with_suffix(".pub").read_bytes().strip()
        private = key.read_text(encoding="ascii")
    ticket = secrets.token_hex(16)
    command = binding_command(ticket)
    path, lines = locked_keys
    now = int(time.time())
    expires = now + LIFETIME
    deadline = ssh_expiry_time(expires, utc_expiry)
    options = f'restrict,expiry-time="{deadline}",command="{command}"'
    marker = f"termlo-pair:{ticket}:{expires}"
    live = [line for line in lines if not ((match := invitation_entry(line))
            and int(match[3]) <= now and managed_key(line))]
    existed = path.exists()
    write_keys(path, live, options.encode() + b" " + public + b" " + marker.encode())
    try:
        yield dict(expiresAt=expires, key=private)
    except BaseException:
        # No other Termlo writer can enroll a Mac between issuance and rollback.
        if existed:
            write_keys(path, lines, None)
        else:
            path.unlink()
        raise


def issue():
    with locked_authorized_keys() as keys, pending_invitation(keys) as invitation:
        return invitation


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
