"""Find and verify an installed Chromium browser on a remote Mac or Linux host."""

import os
from pathlib import Path
import pwd
import shutil
import signal
import subprocess
import sys


ROOT_BROWSER_USER = "termlo-browser"


def executable():
    if sys.platform == "darwin":
        apps = (("Chromium", "Chromium"), ("Google Chrome", "Google Chrome"),
                ("Microsoft Edge", "Microsoft Edge"), ("Brave Browser", "Brave Browser"))
        for folder in (Path("/Applications"), Path.home() / "Applications"):
            for app, binary in apps:
                path = folder / (app + ".app") / "Contents/MacOS" / binary
                if path.is_file() and os.access(path, os.X_OK):
                    return str(path)
    for name in ("chromium", "google-chrome-stable", "google-chrome", "chromium-browser"):
        path = shutil.which(name)
        if path:
            return path
    if sys.platform == "linux" and os.access("/snap/bin/chromium", os.X_OK):
        return "/snap/bin/chromium"
    return None


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
case "$1" in
    /snap/bin/chromium|*/chromium-browser) base="$HOME/snap/chromium/common"; mkdir -p "$base" ;;
esac
profile=$(mktemp -d "$base/termlo-browser-check.XXXXXXXX")
trap 'rm -rf -- "$profile"' EXIT
trap 'exit 1' HUP INT TERM
"$1" --headless --disable-gpu --disable-dev-shm-usage --no-first-run --no-default-browser-check \
    --disable-background-networking --disable-component-update --user-data-dir="$profile" \
    --dump-dom 'data:text/html,<title>termlo-browser-ready</title>'
"""


def check(path=None, *, prepare_root=False):
    path = path or executable()
    if not path:
        raise ValueError("找不到原生 Chromium 或 Chrome，请重新运行 Termlo 安装器。")
    command = ["bash", "-c", PROBE, "termlo-browser-check", path]
    if sys.platform == "linux" and os.geteuid() == 0:
        account = root_browser_account(prepare_root)
        command = ["runuser", "-u", account.pw_name, "--", "env", "-i", "HOME=" + account.pw_dir,
                   "USER=" + account.pw_name, "LOGNAME=" + account.pw_name,
                   "PATH=/usr/local/bin:/usr/bin:/bin:/snap/bin", *command]
    process = subprocess.Popen(command, cwd="/", stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True, text=True, errors="replace")
    try:
        output, errors = process.communicate(timeout=70)
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
        detail = errors.strip()[-500:] or "未收到测试页内容"
        raise ValueError(f"Chromium 未能正常渲染测试页（{path}）。{detail}")
    return path
