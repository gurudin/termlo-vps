"""Track what this account's installer added and undo only those changes."""

from contextlib import contextmanager
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

import browser
import native_browser
import pairing
import sync_agent


PACKAGES = {
    "apt": {"git", "tmux", "adb", "chromium", "chromium-sandbox"},
    "formula": {"git", "tmux"},
    "cask": {"android-platform-tools", "google-chrome"},
    "snap": {"chromium"},
}
VERSION_NAME = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.+-]+)?")


def note(message):
    print(message, file=sys.stderr, flush=True)


@contextmanager
def account_lock(exclusive):
    # The home directory outlives every install and uninstall, including removal
    # of the old install/pairing lock files. No new persistent lock is needed.
    fd = os.open(Path.home(), os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        yield
    finally:
        os.close(fd)


def rmdir_if_empty(path):
    try:
        path.rmdir()
    except FileNotFoundError:
        pass
    except OSError as error:
        if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
            raise


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def package_present(kind, name, *, before_install=False):
    """True/False for a known result; never infer ownership from a broken package database."""
    if kind == "apt":
        command = ["dpkg-query", "-W", "-f=${db:Status-Status}", name]
    elif kind == "snap":
        command = ["snap", "list"]
    else:
        command = ["brew", "list", "--" + kind, "-1"]
    if not shutil.which(command[0]):
        # Homebrew can itself be bootstrapped by the cask/formula installer.
        return False if before_install and command[0] == "brew" else None
    result = subprocess.run(command, capture_output=True, text=True, env=dict(os.environ, LC_ALL="C"))
    if kind in ("snap", "formula", "cask"):
        if result.returncode == 0:
            return any(row.split()[0].split("/")[-1] == name for row in result.stdout.splitlines() if row.split())
        if kind == "snap" and (result.stderr or "").strip().startswith("No snaps are installed yet."):
            return False
        return None
    if result.returncode == 1 and "no packages found" in result.stderr.lower():
        return False
    if result.returncode:
        return None
    status = result.stdout.strip()
    if status == "installed":
        return True
    return False if status in ("config-files", "not-installed") else None


def claude_dirs():
    base = Path.home() / ".local/share"
    xdg = Path(os.environ.get("XDG_DATA_HOME") or base)
    return {path.resolve() / "claude/versions" for path in (base, xdg) if path.is_absolute()}


def browser_home_stamp(home, uid):
    """Identify the private home useradd created. Never follow links into other data."""
    try:
        info = home.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid or home.is_mount() or home != home.resolve():
            return None
        stamp = hashlib.sha256()
        entries = [home]
        while entries:
            path = entries.pop()
            item = path.lstat()
            if item.st_dev != info.st_dev or (path != home and path.is_mount()):
                return None
            fields = [str(path.relative_to(home)), item.st_dev, item.st_ino, item.st_mode, item.st_uid, item.st_gid]
            if stat.S_ISDIR(item.st_mode):
                entries.extend(sorted(path.iterdir()))
            else:
                fields.extend([item.st_size, item.st_mtime_ns])
            stamp.update(json.dumps(fields).encode() + b"\n")
        return stamp.hexdigest()
    except OSError:
        return None


class Receipt:
    def __init__(self, folder):
        self.path = folder / "installed-components.json"
        self.data = {"version": 1, "packages": {}, "agents": {}}
        if self.path.is_symlink():
            raise ValueError("安装记录是符号链接，请核对 installed-components.json。")
        if self.path.exists():
            info = self.path.stat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise ValueError("安装记录的所有者或权限异常，请核对 installed-components.json。")
            saved = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(saved, dict) or saved.get("version") != 1 or not isinstance(saved.get("packages"), dict) or not isinstance(saved.get("agents"), dict):
                raise ValueError("无法识别安装记录，请核对 installed-components.json。")
            self.data = saved

    def save(self):
        with tempfile.NamedTemporaryFile(mode="w", dir=self.path.parent, delete=False, encoding="utf-8") as stream:
            stage = Path(stream.name)
            try:
                json.dump(self.data, stream, ensure_ascii=False)
                stream.flush()
                os.fsync(stream.fileno())
                os.replace(stage, self.path)
            finally:
                stage.unlink(missing_ok=True)

    @contextmanager
    def observe_packages(self, kind, names):
        missing = {name for name in names if name in PACKAGES[kind]
                   and package_present(kind, name, before_install=True) is False}
        try:
            yield
        finally:
            added = {name for name in missing if package_present(kind, name) is True}
            if added:
                packages = self.data["packages"]
                packages[kind] = sorted(added.union(packages.get(kind, [])))
                self.save()

    def install_agent(self):
        target = sync_agent.installed_path()
        new = not os.path.lexists(target)
        path = sync_agent.install()
        if new:
            self.data["agents"][str(path.resolve())] = digest(path)
            self.save()
        return path

    @contextmanager
    def observe_claude(self):
        launcher = Path.home() / ".local/bin/claude"
        if os.path.lexists(launcher):
            yield
            return
        old_versions = {path: set(path.iterdir()) if path.is_dir() else set() for path in claude_dirs()}
        existing_dirs = {path for path in old_versions if path.exists()}
        try:
            yield
        finally:
            if launcher.is_symlink():
                target = launcher.resolve()
                versions = target.parent
                if versions in old_versions and VERSION_NAME.fullmatch(target.name) and target.is_file():
                    entry = {"versions": str(versions), "target": target.name}
                    if versions not in existing_dirs:
                        info = versions.stat()
                        entry["directoryID"] = [info.st_dev, info.st_ino]
                    elif target not in old_versions[versions]:
                        entry["sha256"] = digest(target)
                    self.data["claude"] = entry
                    self.save()
            elif launcher.is_file():
                self.data["claude"] = {"sha256": digest(launcher)}
                self.save()

    @contextmanager
    def observe_browser_user(self):
        home = Path("/home") / native_browser.ROOT_BROWSER_USER
        new_home = not os.path.lexists(home)
        try:
            pwd.getpwnam(native_browser.ROOT_BROWSER_USER)
        except KeyError:
            existed = False
        else:
            existed = True
        if existed:
            yield
            return
        try:
            yield
        finally:
            try:
                account = pwd.getpwnam(native_browser.ROOT_BROWSER_USER)
            except KeyError:
                pass
            else:
                self.data["browserUser"] = {"uid": account.pw_uid, "gid": account.pw_gid,
                                            "homeStamp": browser_home_stamp(home, account.pw_uid) if new_home else None}
                self.save()


def remove_packages(receipt):
    groups = receipt.data["packages"]
    privilege = [] if os.geteuid() == 0 else ["sudo"]
    for kind, recorded in list(groups.items()):
        if kind not in PACKAGES or not isinstance(recorded, list) or any(name not in PACKAGES[kind] for name in recorded):
            raise ValueError("安装记录中有无法识别的软件包。")
        present = []
        for name in recorded:
            state = package_present(kind, name)
            if state is None:
                raise ValueError(f"无法检查 {name} 的安装状态，请恢复包管理器后重试，或使用 uninstall --keep-tools。")
            if state:
                present.append(name)
        if present:
            note("正在卸载安装器新增的软件：" + "、".join(present))
            if kind == "apt":
                # dpkg refuses removal when an unlisted package depends on one of these names.
                # It cannot expand the removal to additional packages as APT's resolver can.
                command = [*privilege, "dpkg", "--remove", *present]
            elif kind == "snap":
                command = [*privilege, "snap", "remove", *present]
            else:
                command = ["brew", "uninstall", "--" + kind, *present]
            result = subprocess.run(command, env=dict(os.environ, HOMEBREW_NO_AUTOREMOVE="1"))
            if result.returncode:
                raise ValueError("软件包卸载未完成。可修复以上错误后重试，或用 uninstall --keep-tools 保留共用工具。")
        del groups[kind]
        receipt.save()


def remove_if_original(path, checksum):
    if not os.path.lexists(path):
        return
    if path.is_symlink() or not path.is_file() or digest(path) != checksum:
        note(f"已保留后来更换的文件：{path}")
        return
    path.unlink()


def remove_agents(receipt):
    for saved, checksum in receipt.data["agents"].items():
        path = Path(saved)
        if (not path.is_absolute() or path.name != "mutagen-agent" or not VERSION_NAME.fullmatch(path.parent.name)
                or path.parent.parent.name != "agents"):
            raise ValueError("同步代理的安装记录异常。")
        if path.parent.resolve() != path.parent:
            note(f"已保留路径发生变化的同步代理：{path}")
            continue
        remove_if_original(path, checksum)
        rmdir_if_empty(path.parent)
        rmdir_if_empty(path.parent.parent)


def remove_claude(entry):
    launcher = Path.home() / ".local/bin/claude"
    if "versions" not in entry:
        remove_if_original(launcher, entry["sha256"])
        return
    versions = Path(entry["versions"])
    if (not versions.is_absolute() or versions.parts[-2:] != ("claude", "versions")
            or not VERSION_NAME.fullmatch(entry["target"])):
        raise ValueError("Claude Code 的安装记录异常。")
    if versions.resolve() != versions:
        note("Claude Code 程序目录已更换，已保留。")
        return
    if versions.is_dir() and entry.get("directoryID"):
        info = versions.stat()
        if [info.st_dev, info.st_ino] != entry["directoryID"]:
            note("Claude Code 程序目录已被替换，已保留。")
            return
    if os.path.lexists(launcher):
        target = launcher.resolve()
        if not launcher.is_symlink() or target.parent != versions or not VERSION_NAME.fullmatch(target.name):
            note("当前 Claude Code 启动程序已更换，已保留。")
            return
        launcher.unlink()
    if versions.is_dir() and entry.get("directoryID"):
        # The official native updater puts subsequent binary versions here.
        for item in versions.iterdir():
            if VERSION_NAME.fullmatch(item.name) and item.is_file() and not item.is_symlink():
                item.unlink()
        rmdir_if_empty(versions)
        rmdir_if_empty(versions.parent)
    elif "sha256" in entry:
        remove_if_original(versions / entry["target"], entry["sha256"])


def remove_browser_user(entry):
    name = native_browser.ROOT_BROWSER_USER
    try:
        account = pwd.getpwnam(name)
    except KeyError:
        return
    if (sys.platform != "linux" or os.geteuid() != 0 or account.pw_uid != entry["uid"]
            or account.pw_gid != entry["gid"]):
        note(f"已保留身份发生变化的账号 {name}。")
        return
    try:
        native_browser.root_browser_account(False)
    except ValueError:
        note(f"已保留用途发生变化的账号 {name}。")
        return
    home = Path(account.pw_dir)
    command = ["userdel"]
    if os.path.lexists(home):
        if not entry.get("homeStamp") or browser_home_stamp(home, account.pw_uid) != entry["homeStamp"]:
            note(f"专用主目录已有其他内容，已保留 {name} 及 {home}。")
            return
        command.append("--remove")
    # userdel refuses active sessions. A later run can finish after the browser closes.
    subprocess.run([*command, name], check=True)


def installed_cli(path):
    if path.is_symlink() or not path.is_file() or not zipfile.is_zipfile(path):
        return False
    with zipfile.ZipFile(path) as archive:
        entry = b"from termlo import main\nmain()\n"
        return ({"termlo.py", "connection_code.py", "__main__.py"}.issubset(archive.namelist())
                and archive.getinfo("__main__.py").file_size == len(entry) and archive.read("__main__.py") == entry)


def run(folder, keep_tools):
    if os.getuid() == 0 and os.environ.get("SUDO_USER") not in (None, "", "root"):
        raise ValueError("请用安装 Termlo 的 SSH 账号运行卸载命令。")
    # A previously released installer may already hold its legacy lock.
    try:
        lock = (folder / "install.lock").open("rb")
    except FileNotFoundError:
        remove_installation(folder, keep_tools)
    else:
        with lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            remove_installation(folder, keep_tools)


def remove_installation(folder, keep_tools):
    cli = Path.home() / ".local/bin/termlo"
    ours = installed_cli(cli)
    receipt = Receipt(folder)
    has_receipt = receipt.path.exists()
    revoked = pairing.revoke_all()
    if revoked:
        note(f"已撤销 {revoked} 条 Termlo SSH 授权。")
    browser_lock = folder / "browser.lock"
    browsers_closed = True
    if browser_lock.exists():
        try:
            browsers_closed = browser.stop_owned_sessions(folder)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            note(f"未能清理旧版浏览器会话：{error}")
            browsers_closed = False
    if not has_receipt and (ours or (folder / "connection.json").exists()):
        note("这是没有安装记录的旧版本。将保留来源无法确认的软件及浏览器账号。")
    if has_receipt and not keep_tools:
        remove_packages(receipt)
        remove_agents(receipt)
        if receipt.data.get("claude"):
            remove_claude(receipt.data["claude"])
    if has_receipt and receipt.data.get("browserUser"):
        remove_browser_user(receipt.data["browserUser"])
    for name in ("connection.json", "install.lock"):
        (folder / name).unlink(missing_ok=True)
    if browsers_closed:
        browser_lock.unlink(missing_ok=True)
    if ours:
        cli.unlink()
    elif os.path.lexists(cli):
        note(f"已保留非 Termlo 安装器生成的程序：{cli}")
    receipt.path.unlink(missing_ok=True)
    if not folder.is_symlink():
        rmdir_if_empty(folder)
    if not browsers_closed:
        raise ValueError("Termlo 主程序已卸载。旧容器服务恢复后，可再运行一次在线卸载命令清理遗留的浏览器会话。")
    note("Termlo 卸载完成。")
