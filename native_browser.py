"""Find and verify an installed Chromium browser on a remote Mac or Linux host."""

import grp
import os
from pathlib import Path
import pwd
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT_BROWSER_USER = "termlo-browser"


def candidates():
    if sys.platform == "darwin":
        apps = (("Chromium", "Chromium"), ("Google Chrome", "Google Chrome"),
                ("Microsoft Edge", "Microsoft Edge"), ("Brave Browser", "Brave Browser"))
        for folder in (Path("/Applications"), Path.home() / "Applications"):
            for app, binary in apps:
                path = folder / (app + ".app") / "Contents/MacOS" / binary
                if path.is_file() and os.access(path, os.X_OK):
                    yield str(path)
    for name in ("chromium", "google-chrome-stable", "google-chrome", "chromium-browser"):
        path = shutil.which(name)
        if path:
            yield path
    if sys.platform == "linux" and os.access("/snap/bin/chromium", os.X_OK):
        yield "/snap/bin/chromium"


def executable():
    return next(candidates(), None)


def stable_chromium_snap(metadata, architecture):
    if metadata.get("name") != "chromium":
        return False
    track = metadata.get("default-track") or "latest"
    for revision in metadata.get("channel-map", []):
        channel = revision["channel"]
        if (channel.get("track") == track and channel.get("risk") == "stable"
                and channel.get("architecture") in (architecture, "all") and revision.get("download", {}).get("url")):
            return True
    return False


def root_browser_account(create):
    # Chromium refuses to run as root with its sandbox enabled. This account has
    # no login shell or SSH keys and does not participate in Termlo pairing.
    home = "/home/" + ROOT_BROWSER_USER
    try:
        account = pwd.getpwnam(ROOT_BROWSER_USER)
    except KeyError:
        if not create:
            raise ValueError("请重新运行安装器，准备 Chromium 的非登录运行账号。") from None
        subprocess.run(["useradd", "--system", "--user-group", "--create-home", "--home-dir", home,
                        "--shell", "/usr/sbin/nologin", ROOT_BROWSER_USER], check=True)
        account = pwd.getpwnam(ROOT_BROWSER_USER)
    if account.pw_uid == 0 or account.pw_gid == 0 or account.pw_dir != home or account.pw_shell not in ("/usr/sbin/nologin", "/sbin/nologin", "/bin/false"):
        raise ValueError(f"已有其他用途的 {ROOT_BROWSER_USER} 账号，请核对后重试。")
    return account


PROBE = """
set -eu
umask 077
cd "$HOME"
base=$HOME
if [ -x /snap/bin/chromium ]; then
    case "$1" in
        /snap/bin/chromium|*/chromium-browser) base="$HOME/snap/chromium/common"; mkdir -p "$base" ;;
    esac
fi
profile=$(mktemp -d "$base/termlo-browser-check.XXXXXXXX")
trap 'rm -rf -- "$profile"' EXIT
trap 'exit 1' HUP INT TERM
"$1" --headless --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check \
    --disable-background-networking --disable-component-update --user-data-dir="$profile" \
    --dump-dom 'data:text/html,<title>termlo-browser-ready</title>'
"""


def check_install_account():
    if sys.platform == "linux" and os.geteuid() == 0:
        try:
            pwd.getpwnam(ROOT_BROWSER_USER)
        except KeyError:
            try:
                grp.getgrnam(ROOT_BROWSER_USER)
            except KeyError:
                return False
            raise ValueError(f"已有名为 {ROOT_BROWSER_USER} 的组，无法为新浏览器账号创建同名专用组。") from None
        root_browser_account(False)
        return True
    return False


def check_for_install():
    if sys.platform == "linux" and os.geteuid() == 0:
        try:
            pwd.getpwnam(ROOT_BROWSER_USER)
        except KeyError:
            # Test the installed browser without creating its permanent service account.
            try:
                account = pwd.getpwnam("nobody")
            except KeyError:
                raise ValueError("缺少可用于浏览器试启动的普通账号，请准备 termlo-browser 系统账号。") from None
            with tempfile.TemporaryDirectory(prefix="termlo-browser-check-", dir="/tmp") as home:
                os.chown(home, account.pw_uid, account.pw_gid)
                return render_candidates(candidates(), account_prefix(account, home, probe=True))
        account = root_browser_account(False)
        return render_candidates(candidates(), account_prefix(account, account.pw_dir, probe=True))
    return check()


def account_prefix(account, home, *, probe=False):
    if account.pw_uid == 0 or account.pw_gid == 0:
        raise ValueError("浏览器试启动需要非 root 的账号和组。")
    environment = ["env", "-i", "HOME=" + home, "USER=" + account.pw_name, "LOGNAME=" + account.pw_name,
                   "PATH=/usr/local/bin:/usr/bin:/bin:/snap/bin"]
    if probe and not shutil.which("runuser"):
        # The checklist can render as the unprivileged account before installing runuser.
        drop_privileges = ("import os, sys\nname, uid, gid = sys.argv[1:4]\nos.initgroups(name, int(gid))\n"
                           "os.setgid(int(gid))\nos.setuid(int(uid))\nos.execvp(sys.argv[4], sys.argv[4:])")
        return [sys.executable, "-IS", "-c", drop_privileges, account.pw_name, str(account.pw_uid),
                str(account.pw_gid), *environment]
    return ["runuser", "-u", account.pw_name, "--", *environment]


def check(path=None, *, prepare_root=False):
    paths = list(dict.fromkeys(candidates())) if path is None else [path]
    if not paths:
        raise ValueError("找不到原生 Chromium 或 Chrome，请重新运行 Termlo 安装器。")
    prefix = []
    if sys.platform == "linux" and os.geteuid() == 0:
        account = root_browser_account(prepare_root)
        prefix = account_prefix(account, account.pw_dir)
    return render_candidates(paths, prefix)


def render_candidates(paths, prefix):
    paths = list(dict.fromkeys(paths))
    failures = []
    deadline = time.monotonic() + 75
    for index, candidate in enumerate(paths):
        remaining = max(1, deadline - time.monotonic())
        timeout = max(1, min(70, remaining / (len(paths) - index)))
        try:
            return render_page(candidate, prefix, timeout)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            failures.append(f"{candidate}：{error}")
    raise ValueError("已安装的浏览器均未能渲染测试页。" + "；".join(failures))


def render_page(path, prefix, timeout):
    command = [*prefix, "bash", "-c", PROBE, "termlo-browser-check", path]
    process = subprocess.Popen(command, cwd="/", stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, text=True, errors="replace")
    try:
        output, errors = process.communicate(timeout=timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
        if isinstance(error, KeyboardInterrupt):
            raise
        raise ValueError("Chromium 启动超时，请检查可用内存及系统浏览器的启动日志。") from None
    if process.returncode or "<title>termlo-browser-ready</title>" not in output:
        fatal = [line for line in errors.splitlines() if "FATAL" in line or "error while loading" in line]
        detail = "\n".join(fatal)[:1200] or errors.strip()[:1200] or "未收到测试页内容"
        raise ValueError(f"Chromium 未能正常渲染测试页（{path}）。{detail}")
    return path
