"""Termlo 的 Linux VPS 安装器和用户命令。"""

import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import pkgutil
import pwd
import shutil
import subprocess
import sys
import tempfile
import zipfile

import browser
import pairing
import wizard
from connection_code import connection_details, encode


SYSTEM_CA_BUNDLE = Path("/etc/ssl/certs/ca-certificates.crt")
SSH_KEY_DIRECTORY = Path("/etc/ssh")


def note(message):
    print(message, file=sys.stderr, flush=True)


def config_dir():
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "termlo"


def ssh_endpoint():
    fields = os.environ.get("SSH_CONNECTION", "").split()
    if len(fields) == 4:
        try:
            return ipaddress.ip_address(fields[2]), int(fields[3])
        except ValueError:
            pass
    return None, 22


def system_host_key(address, port):
    keys = [SSH_KEY_DIRECTORY / f"ssh_host_{kind}_key.pub" for kind in ("ed25519", "ecdsa", "rsa")]
    keys = [key for key in keys if key.is_file()]
    if not keys:
        raise ValueError("找不到 SSH 主机公钥，请用 --host-key 指定 sshd 使用的 .pub 文件。")
    if address is not None and shutil.which("ssh-keyscan"):
        scan = subprocess.run(["ssh-keyscan", "-T", "3", "-p", str(port), str(address)],
                              capture_output=True, text=True, timeout=12)
        served = {line.split()[2] for line in scan.stdout.splitlines()
                  if not line.startswith("#") and len(line.split()) >= 3}
        if served:
            for key in keys:
                fields = key.read_text().split()
                if len(fields) >= 2 and fields[1] in served:
                    return key
            raise ValueError("当前 sshd 使用自定义主机密钥，请用 --host-key 指定对应的 .pub 文件。")
    return keys[0]


def connection_settings(args, terminal=None, region="global", egress=None):
    path = config_dir() / "connection.json"
    saved = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    address, internal_port = ssh_endpoint()
    user = pwd.getpwuid(os.getuid()).pw_name
    host = args.host if args.host is not None else saved.get("host")
    port = args.port if args.port is not None else saved.get("port", internal_port)
    if terminal is not None:
        note(f"\n1/3  确认 SSH 连接\n登录用户  {user}    按回车接受方括号中的默认值。")
        if host is None:
            host, source = wizard.suggest_host(address, region, egress)
        else:
            source = "指定地址" if args.host is not None else "上次使用的地址"
        host = wizard.ask_field(terminal, f"服务器地址（{source}）", host, wizard.ssh_host)
        port = wizard.ask_field(terminal, "SSH 对外端口", port, wizard.ssh_port)
    elif host is None:
        if address is None or not address.is_global or address.is_multicast:
            raise ValueError("请用 --host 指定 Mac 可访问的 VPS 域名或 IP。有端口映射时同时指定 --port。")
        host = str(address)
    key = args.host_key or saved.get("host_key") or system_host_key(address, internal_port)
    return dict(host=host, port=port, user=user, host_key=str(Path(key).expanduser().resolve()),
                name=args.name if args.name is not None else saved.get("name"))


def run_sources(*args, stdout):
    # The same Bash helper bootstraps Python and travels inside the installed zipapp.
    return subprocess.run(["bash", "-s", "--", *args], input=pkgutil.get_data("termlo", "sources.sh"),
                          stdout=stdout, check=True)


def install_network():
    hint = os.environ.get("TERMLO_INSTALL_NETWORK")
    if not hint:
        hint = run_sources("detect", stdout=subprocess.PIPE).stdout.decode("utf-8", "replace")
    parts = hint.split()
    region = parts[0] if parts and parts[0] in ("cn", "global") else "auto"
    egress = None
    if len(parts) == 2:
        try:
            address = ipaddress.ip_address(parts[1])
            if address.is_global and wizard.usable_address(address):
                egress = str(address)
        except ValueError:
            pass
    return region, egress


class SystemPackages:
    def __init__(self, region, state):
        self.region = region
        self.state = state

    def install(self, packages):
        if not packages:
            return
        if not shutil.which("apt-get") or (os.getuid() != 0 and not shutil.which("sudo")):
            raise ValueError("请先用系统包管理器安装 " + "、".join(packages) + "，再重试。")
        note("正在安装系统包 " + "、".join(packages))
        run_sources("apt", self.region, self.state, *packages, stdout=sys.stderr)


def ensure_tmux(packages):
    if not shutil.which("tmux"):
        packages.install(["tmux"])
    subprocess.run(["tmux", "-V"], stdout=sys.stderr, check=True)


def ensure_claude(packages):
    if not shutil.which("claude"):
        needed = [] if shutil.which("curl") else ["curl"]
        if not SYSTEM_CA_BUNDLE.is_file():
            needed.append("ca-certificates")
        packages.install(needed)
        note("正在为当前 SSH 用户安装 Claude Code 稳定版…")
        with tempfile.TemporaryDirectory() as folder:
            script = Path(folder) / "install-claude.sh"
            subprocess.run(["curl", "--proto", "=https", "--proto-redir", "=https", "-fsSL",
                            "--connect-timeout", "5", "--max-time", "45", "--retry", "2",
                            "-o", str(script), "https://claude.ai/install.sh"], check=True)
            subprocess.run(["bash", str(script), "stable"], stdout=sys.stderr, check=True)
    subprocess.run(["claude", "--version"], stdout=sys.stderr, check=True)


def ensure_browser(packages):
    engine = browser.available_engine()
    if not engine:
        packages.install(["podman", "uidmap", "slirp4netns", "fuse-overlayfs"])
    browser.prepare_image(engine or browser.require_engine(), packages.region)


def run_optional(terminal, title, description, present, action, default=1):
    if present:
        note(f"{title}  ·  已安装，直接复用")
        return True
    note(f"{title}  ·  未安装\n  {description}")
    if not wizard.choose(terminal, default=default):
        return False
    while True:
        try:
            action()
            return True
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            note(f"{title} 安装失败。{error}")
            if not wizard.choose(terminal, "重试", "跳过，继续安装向导", default=2):
                return False


def select_tools(terminal, packages):
    note("\n2/3  选择开发工具\nSSH 连接和代码同步可以独立使用。")
    run_optional(terminal, "tmux", "断开 SSH 后保留终端会话。",
                 shutil.which("tmux"), lambda: ensure_tmux(packages))
    mainland = packages.region == "cn"
    description = ("官方服务尚未支持中国大陆，默认跳过。选装将访问 Anthropic 官方源。" if mainland
                   else "在 VPS 上运行 Claude Code，使用官方稳定版。")
    has_claude = run_optional(terminal, "Claude Code", description, shutil.which("claude"),
                              lambda: ensure_claude(packages), default=2 if mainland else 1)
    if has_claude:
        engine = browser.available_engine()
        run_optional(terminal, "Claude 登录浏览器", "供 Mac 打开远端网页登录，需要容器运行时和 Chromium 镜像。",
                     engine and browser.local_image(engine), lambda: ensure_browser(packages), default=2)


def install_cli():
    target = Path.home() / ".local/bin/termlo"
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
        stage = Path(output.name)
    try:
        if zipfile.is_zipfile(sys.argv[0]):
            shutil.copyfile(sys.argv[0], stage)
        else:
            with stage.open("wb") as output:
                output.write(b"#!/usr/bin/env python3\n")
                with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, strict_timestamps=False) as bundle:
                    for name in ("termlo.py", "connection_code.py", "pairing.py", "browser.py", "wizard.py", "sources.sh"):
                        bundle.write(Path(__file__).with_name(name), name)
                    bundle.writestr("__main__.py", "from termlo import main\nmain()\n")
        stage.chmod(0o755)
        os.replace(stage, target)
    finally:
        if stage.exists():
            stage.unlink()


def install(args, terminal=None):
    if sys.platform != "linux":
        raise ValueError("请在 VPS 的 Linux SSH 会话中运行安装器。")
    if os.getuid() == 0 and os.environ.get("SUDO_USER") not in (None, "", "root"):
        raise ValueError("请用目标 SSH 账号直接运行安装器，安装系统包时会自动调用 sudo。")
    os.environ["PATH"] = f"{Path.home()}/.local/bin:{Path.home()}/.npm-global/bin:" + os.environ["PATH"]
    folder = config_dir()
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (folder / "install.lock").open("a") as lock, tempfile.TemporaryDirectory(prefix="termlo-apt-") as state:
        fcntl.flock(lock, fcntl.LOCK_EX)
        region, egress = install_network()
        channels = {"cn": "中国大陆，优先使用国内镜像", "global": "海外，优先使用系统源和官方镜像",
                    "auto": "未识别到出口地区，优先使用系统源，下载失败时尝试国内镜像"}
        note("下载线路：" + channels[region])
        packages = SystemPackages(region, state)
        if not shutil.which("ssh-keygen") or not shutil.which("scp"):
            packages.install(["openssh-client"])
        settings = connection_settings(args, terminal, region, egress)
        details = connection_details(**settings, include_host_key=True)
        if terminal is not None:
            select_tools(terminal, packages)
        elif not args.sync_only:
            # Preserve the original full installation for existing unattended commands.
            if not shutil.which("git"):
                packages.install(["git"])
            ensure_tmux(packages)
            ensure_claude(packages)
            ensure_browser(packages)
        install_cli()
        with tempfile.NamedTemporaryFile(dir=folder, mode="w", encoding="utf-8", delete=False) as out:
            json.dump(settings, out, ensure_ascii=False)
        os.replace(out.name, folder / "connection.json")
        code = encode(dict(details, version=2, pairing=pairing.issue()))
    if terminal is not None:
        note("\n3/3  复制连接码")
    note("安装完成。将下面一整行粘贴到 Mac 的「添加服务器」，点「连接」。")
    note("连接码在 10 分钟内有效，可绑定一台 Mac。以后在这台 Mac 上点服务器名称即可连接。")
    print(code)


def add_endpoint_options(parser):
    parser.add_argument("--host", help="Mac 可达的域名或 IP，默认从 SSH 会话读取公网地址")
    parser.add_argument("--port", type=int, help="Mac 使用的对外 SSH 端口")
    parser.add_argument("--name", help="Mac 中显示的服务器名称")
    parser.add_argument("--host-key", help="sshd 使用的主机公钥文件（.pub）")


def main():
    parser = argparse.ArgumentParser(prog="termlo", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("install", help="安装或更新当前用户的 VPS 开发环境")
    add_endpoint_options(setup)
    setup.add_argument("--sync-only", action="store_true", help="仅准备 SSH 和代码同步")
    add_endpoint_options(commands.add_parser("connection-code", help="生成可绑定一台 Mac 的新连接码"))
    redeem = commands.add_parser("redeem", help=argparse.SUPPRESS)
    redeem.add_argument("ticket")
    login = commands.add_parser("browser", help="临时打开或关闭 Claude 登录浏览器")
    login.add_argument("action", choices=["start", "stop"])
    login.add_argument("--session", type=browser.session_id, help="由 Mac 客户端分配的会话 UUID")
    args = parser.parse_args()
    try:
        if args.command == "install" and len(sys.argv) == 2:
            try:
                terminal = open("/dev/tty", "r", encoding="utf-8")
            except OSError:
                raise ValueError("安装向导需要交互终端。请在 VPS 控制台或交互式 SSH 会话中运行。") from None
            with terminal:
                install(args, terminal)
        elif args.command == "install":
            install(args)
        elif args.command == "connection-code":
            details = connection_details(**connection_settings(args), include_host_key=True)
            print(encode(dict(details, version=2, pairing=pairing.issue())))
        elif args.command == "redeem":
            print(pairing.redeem(args.ticket, os.environ.get("SSH_ORIGINAL_COMMAND", "")))
        else:
            browser.manage(args.action, args.session, config_dir())
    except (EOFError, KeyboardInterrupt):
        parser.exit(130, "\n安装已取消。\n")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Termlo：{error}\n")


if __name__ == "__main__":
    main()
