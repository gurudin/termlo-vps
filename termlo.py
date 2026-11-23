"""Termlo 远程开发环境安装器和用户命令。"""

import argparse
from contextlib import nullcontext
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import pkgutil
import pwd
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import zipfile

import browser
import native_browser
import pairing
import sync_agent
import uninstall
import wizard
from connection_code import connection_details, encode, validate_host


OS_RELEASE = Path("/etc/os-release")


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


def helper_source(*files):
    return b"\n".join(pkgutil.get_data("termlo", name) for name in files)


def shell_helper(function, *args, check=True, stdout=None):
    source = helper_source("prerequisites.sh") + ('\n' + function + ' "$@"\n').encode()
    return subprocess.run(["/bin/sh", "-s", "--", *args], input=source, stdout=stdout, check=check)


def verified_identity(settings, packages=None, *, require_key=False):
    def scan():
        probe = shell_helper("scan_ssh", str(settings["local_port"]), check=False, stdout=subprocess.PIPE)
        return [line.split() for line in probe.stdout.decode("ascii").splitlines()] if probe.returncode == 0 else []

    keys = scan()
    if not keys and packages is not None:
        if os.environ.get("SSH_CONNECTION"):
            raise ValueError("当前 SSH 会话的本机端口未返回主机公钥。请用 ssh-keyscan -p 端口 本机监听地址 检查 sshd。")
        if sys.platform == "linux" and not shutil.which("sshd"):
            packages.install(["openssh-server"])
        note("正在为 SSH 服务生成缺少的主机密钥并启用远程登录。")
        repair = shell_helper("prepare_sshd", check=False, stdout=sys.stderr)
        if repair.returncode == 0:
            for attempt in range(8):
                keys = scan()
                if keys:
                    break
                time.sleep(0.4)
    if not keys:
        if sys.platform == "darwin":
            raise ValueError("SSH 尚未能接受连接。请在「系统设置 → 通用 → 共享 → 远程登录」允许当前账号，然后重试。")
        raise ValueError("SSH 监听端口未返回公钥。运行 sudo sshd -t 检查配置，按提示修复后重试。")
    accepted = {" ".join(row[1:]): int(row[0]) for row in keys if len(row) == 3}
    key_file = settings.get("host_key")
    preferred = None
    if key_file:
        with Path(key_file).open(encoding="utf-8") as source:
            preferred = " ".join(source.readline().split()[:2])
        if preferred not in accepted:
            if require_key:
                raise ValueError("指定的 SSH 主机公钥与服务实际提供的密钥不符。请核对 --host-key 与监听端口。")
            settings["host_key"] = None
            preferred = None
    if preferred is None:
        preferred = next((key for key in accepted if key.startswith("ssh-ed25519 ")), next(iter(accepted), None))
    if not preferred:
        raise ValueError("SSH 服务没有提供可验证的主机公钥。")
    settings["local_port"] = accepted[preferred]
    return connection_details(settings["host"], settings["port"], settings["user"], name=settings["name"],
                              public_key=preferred, include_host_key=True)


def saved_connection(path):
    if not os.path.lexists(path):
        return {}
    if not path.is_file():
        raise ValueError("connection.json 需要是可读的普通文件")
    saved = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(saved, dict):
        raise ValueError("connection.json 需要是 JSON 对象")
    for field in ("host", "name", "host_key"):
        if saved.get(field) is not None and not isinstance(saved[field], str):
            raise ValueError(f"connection.json 的 {field} 需要是文本")
    if saved.get("host") is not None:
        validate_host(saved["host"])
    if saved.get("name") is not None and not saved["name"].strip():
        raise ValueError("connection.json 的 name 不能为空，请填写服务器名称或移除这个可选字段")
    for field in ("port", "local_port"):
        if saved.get(field) is not None:
            saved[field] = wizard.ssh_port(str(saved[field]))
        else:
            saved.pop(field, None)
    return saved


def connection_settings(args, terminal=None, region="global", egress=None):
    saved = saved_connection(config_dir() / "connection.json")
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
    validate_host(host)
    wizard.ssh_port(str(port))
    key = args.host_key
    if key is None and saved.get("host_key") and Path(saved["host_key"]).is_file():
        key = saved["host_key"]
    name = args.name if args.name is not None else saved.get("name")
    if name is not None and not name.strip():
        raise ValueError("服务器名称不能为空")
    local_port = internal_port if address is not None else saved.get("local_port", port)
    return dict(host=host, port=port, user=user, name=name, local_port=local_port,
                host_key=str(Path(key).expanduser().resolve()) if key else None)


def run_sources(*args, stdout):
    # The same Bash helper bootstraps Python and travels inside the installed zipapp.
    return subprocess.run(["bash", "-s", "--", *args], input=helper_source("prerequisites.sh", "sources.sh"),
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
    def __init__(self, region, state, receipt):
        self.region = region
        self.state = state
        self.receipt = receipt
        self._family = None
        self.trust_repaired = False

    @property
    def family(self):
        if self._family is None:
            self._family = ("formula" if sys.platform == "darwin" else
                            run_sources("manager", str(OS_RELEASE), stdout=subprocess.PIPE).stdout.decode().strip())
        return self._family

    def install(self, packages):
        if not packages:
            return
        family = self.family
        aliases = {
            "rpm": {"openssh-client": ["openssh-clients"], "adb": ["android-tools"],
                    "passwd": ["shadow-utils"]},
            "apk": {"openssh-client": ["openssh-client-default", "openssh-keygen"], "adb": ["android-tools"],
                    "passwd": ["shadow"], "util-linux": ["cmd:runuser"]},
        }
        names = [name for package in packages for name in aliases.get(family, {}).get(package, [package])]
        note("正在安装或修复系统包 " + "、".join(names))
        with self.receipt.observe_packages(family, names):
            if family == "formula":
                run_sources("brew", "formula", *packages, stdout=sys.stderr)
            else:
                run_sources("linux", family, self.region, self.state, *names, stdout=sys.stderr)

    def with_https_repair(self, action):
        try:
            return action()
        except subprocess.CalledProcessError as error:
            if (sys.platform != "linux" or self.trust_repaired or error.cmd[0] != "curl"
                    or error.returncode not in (60, 77)):
                raise
            for variable in ("CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR"):
                if os.environ.get(variable):
                    raise ValueError(f"HTTPS 证书校验失败。请检查当前账号设置的 {variable}。") from error
            if error.returncode == 60 and ssl.create_default_context().get_ca_certs():
                raise ValueError("HTTPS 无法验证下载站点的证书，请检查系统时间、网络代理和上方的 curl 错误。") from error
        self.trust_repaired = True
        note("HTTPS 下载缺少可用的系统信任证书，正在修复后重试。")
        self.install(["ca-certificates"])
        return action()

    def cask(self, name):
        with self.receipt.observe_packages("cask", [name]):
            run_sources("brew", "cask", name, stdout=sys.stderr)

    def install_chromium_snap(self):
        privilege = [] if os.getuid() == 0 else ["sudo" if shutil.which("sudo") else "doas"]
        if Path("/run/systemd/system").is_dir():
            subprocess.run([*privilege, "systemctl", "start", "snapd.socket"], check=True, timeout=60)
        subprocess.run([*privilege, "snap", "wait", "system", "seed.loaded"], timeout=240, check=True)
        with self.receipt.observe_packages("snap", ["chromium"]):
            subprocess.run([*privilege, "snap", "install", "chromium"], check=True)


def claude_available():
    return tool_works(["claude", "--version"])


def ensure_claude(packages):
    if not claude_available():
        note("正在为当前 SSH 用户安装 Claude Code 稳定版…")
        with tempfile.TemporaryDirectory() as folder:
            script = Path(folder) / "install-claude.sh"
            download = ["curl", "-q", "--proto", "=https", "--proto-redir", "=https", "-fsSL",
                        "--connect-timeout", "5", "--max-time", "45", "--retry", "2",
                        "-o", str(script), "https://claude.ai/install.sh"]
            packages.with_https_repair(lambda: subprocess.run(download, check=True))
            with packages.receipt.observe_claude():
                subprocess.run(["bash", str(script), "stable"], stdout=sys.stderr, check=True)
    subprocess.run(["claude", "--version"], stdout=sys.stderr, check=True)


def ensure_browser(packages):
    root_browser = sys.platform == "linux" and os.geteuid() == 0
    if root_browser:
        for command, package in (("useradd", "passwd"), ("runuser", "util-linux")):
            if not shutil.which(command):
                packages.install([package])
    with packages.receipt.observe_browser_user() if root_browser else nullcontext():
        if native_browser.executable():
            try:
                path = native_browser.check(prepare_root=True)
                note(f"已复用能渲染测试页的远程浏览器：{path}")
                return
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                note(f"现有浏览器检查未通过，正在修复。{error}")
        if sys.platform == "darwin":
            packages.cask("google-chrome")
        elif OS_RELEASE.is_file() and any(line.strip() in ("ID=ubuntu", 'ID="ubuntu"', "ID='ubuntu'")
                                          for line in OS_RELEASE.read_text().splitlines()):
            if not shutil.which("snap"):
                packages.install(["snapd"])
            packages.install_chromium_snap()
        else:
            packages.install(["chromium", "chromium-sandbox"] if packages.family == "apt" else ["chromium"])
        path = native_browser.check(prepare_root=True)
    note(f"远程浏览器已启动并渲染测试页：{path}")


def tool_works(command):
    try:
        return subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def ensure_base_tools(packages):
    checks = [["git", "--version"], ["tmux", "-V"], ["adb", "version"]]
    missing = [command[0] for command in checks if not tool_works(command)]
    if sys.platform == "darwin" and "adb" in missing:
        missing.remove("adb")
        packages.cask("android-platform-tools")
    packages.install(missing)
    for command in checks:
        subprocess.run(command, stdout=sys.stderr, check=True)
    note("正在准备并验证远程登录浏览器…")
    ensure_browser(packages)


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


def select_claude(terminal, packages):
    mainland = packages.region == "cn"
    description = ("官方服务尚未支持中国大陆，默认跳过。选装将访问 Anthropic 官方源。" if mainland
                   else "在当前远程设备上运行官方稳定版。")
    run_optional(terminal, "Claude Code", description, claude_available(),
                 lambda: ensure_claude(packages), default=2 if mainland else 1)


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
                output.write(("#!" + sys.executable + "\n").encode())
                with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, strict_timestamps=False) as bundle:
                    for name in ("termlo.py", "connection_code.py", "pairing.py", "browser.py", "native_browser.py",
                                 "sync_agent.py", "mutagen-releases.txt", "uninstall.py", "wizard.py", "sources.sh", "doctor.sh", "prerequisites.sh", "python-runtime.sh"):
                        bundle.write(Path(__file__).with_name(name), name)
                    bundle.writestr("__main__.py", "from termlo import main\nmain()\n")
        stage.chmod(0o755)
        os.replace(stage, target)
    finally:
        if stage.exists():
            stage.unlink()


def add_tool_paths():
    os.environ["PATH"] = f"{Path.home()}/.local/bin:{Path.home()}/.npm-global/bin:" + os.environ["PATH"]
    if sys.platform == "darwin":
        os.environ["PATH"] += ":/opt/homebrew/bin:/usr/local/bin"
    else:
        os.environ["PATH"] += ":/usr/sbin:/sbin"


def install(args, terminal=None, preflight_dir=None, interactive=False):
    add_tool_paths()
    directory = nullcontext(preflight_dir) if preflight_dir else tempfile.TemporaryDirectory(prefix="termlo-install-")
    with directory as state:
        install_in_directory(args, terminal, preflight_dir is not None, interactive, state)


def install_in_directory(args, terminal, checked, interactive, state):
    if not checked:
        flags = []
        for name in ("host", "port", "host_key", "name"):
            value = getattr(args, name)
            if value is not None:
                flags.extend(["--" + name.replace("_", "-"), str(value)])
        if args.sync_only:
            flags.append("--sync-only")
        if args.claude is not None:
            flags.append("--with-claude" if args.claude else "--without-claude")
        if getattr(args, "check", False):
            flags.append("--check")
        check_script = helper_source("python-runtime.sh", "prerequisites.sh", "doctor.sh") + b'\ntermlo_doctor "$@"\n'
        check_result = subprocess.run(["/bin/sh", "-s", "--", str(Path(__file__).parent),
                                       helper_source("mutagen-releases.txt").decode(), str(OS_RELEASE), state,
                                       str(int(interactive)), *flags],
                                      input=check_script)
        if check_result.returncode:
            raise ValueError("安装前体检未通过。")
    if getattr(args, "check", False):
        return
    region, egress = install_network()
    optional_failure = None
    folder = config_dir()
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    terminal_context = open("/dev/tty", encoding="utf-8") if interactive else nullcontext(terminal)
    with terminal_context as terminal, pairing.account_file(folder / "install.lock", replace=False).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        channels = {"cn": "中国大陆，按系统选择可用软件源", "global": "海外，优先使用系统源和官方源",
                    "auto": "未识别到出口地区，优先使用系统源"}
        note("下载线路：" + channels[region])
        settings = connection_settings(args, terminal, region, egress)
        receipt = uninstall.Receipt(folder)
        receipt.save()
        packages = SystemPackages(region, state, receipt)
        if any(not shutil.which(tool) for tool in ("ssh", "scp", "ssh-keygen", "ssh-keyscan")):
            packages.install(["openssh" if sys.platform == "darwin" else "openssh-client"])
        if sys.platform == "linux" and packages.family == "apt":
            shell_helper("restore_apt", stdout=sys.stderr)
        details = verified_identity(settings, packages, require_key=args.host_key is not None)
        note("\n2/3  准备远程开发环境")
        if not tool_works(["curl", "--version"]):
            packages.install(["curl"])
            subprocess.run(["curl", "--version"], stdout=subprocess.DEVNULL, check=True)
        note(f"正在准备 Mutagen {sync_agent.VERSION} 远端同步代理…")
        checked_archive = Path(state) / "agent.tar.gz"
        archive = checked_archive if checked_archive.is_file() else None
        agent = packages.with_https_repair(lambda: receipt.install_agent(archive))
        note(f"双向同步的远端代理已就绪：{agent}")
        if not args.sync_only:
            ensure_base_tools(packages)
            if terminal is not None:
                select_claude(terminal, packages)
            elif args.claude is True:
                try:
                    ensure_claude(packages)
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                    optional_failure = error
        install_cli()
        with tempfile.NamedTemporaryFile(dir=folder, mode="w", encoding="utf-8", delete=False) as out:
            json.dump(settings, out, ensure_ascii=False)
        os.replace(out.name, folder / "connection.json")
        code = encode(dict(details, version=2, pairing=pairing.issue()))
    if terminal is not None:
        note("\n3/3  复制连接码")
    note("在这台远程设备上卸载可运行 ~/.local/bin/termlo uninstall")
    note(("基础环境已就绪，选装的 Claude Code 安装失败。" if optional_failure else "安装完成。")
         + "将下面一整行粘贴到 Mac 的「添加服务器」，点「连接」。")
    note("连接码在 10 分钟内有效，可绑定一台 Mac。以后在这台 Mac 上点服务器名称即可连接。")
    print(code, flush=True)
    if optional_failure:
        raise ValueError(f"Claude Code 未完成：{optional_failure}。稍后运行 ~/.local/bin/termlo install --with-claude 重试。")


def add_endpoint_options(parser):
    parser.add_argument("--host", help="Mac 可达的域名或 IP，默认从 SSH 会话读取公网地址")
    parser.add_argument("--port", type=int, help="Mac 使用的对外 SSH 端口")
    parser.add_argument("--name", help="Mac 中显示的服务器名称")
    parser.add_argument("--host-key", help="sshd 使用的主机公钥文件（.pub）")


def main(preflight_dir=None):
    parser = argparse.ArgumentParser(prog="termlo", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    setup = commands.add_parser("install", help="安装或更新当前用户的远程开发环境")
    add_endpoint_options(setup)
    setup.add_argument("--check", action="store_true", help="仅显示安装前体检清单")
    mode = setup.add_mutually_exclusive_group()
    mode.add_argument("--sync-only", action="store_true", help="仅准备 SSH 和远端同步代理")
    mode.add_argument("--without-claude", dest="claude", action="store_false", default=None,
                      help="安装全部基础工具，跳过 Claude Code")
    mode.add_argument("--with-claude", dest="claude", action="store_true", default=None,
                      help="安装全部基础工具和 Claude Code")
    removal = commands.add_parser("uninstall", help="卸载当前账号的 Termlo，撤销配对并移除安装器新增的工具")
    removal.add_argument("--keep-tools", action="store_true", help="保留开发工具、浏览器和同步代理")
    add_endpoint_options(commands.add_parser("connection-code", help="生成可绑定一台 Mac 的新连接码"))
    redeem = commands.add_parser("redeem", help=argparse.SUPPRESS)
    redeem.add_argument("ticket")
    login = commands.add_parser("browser", help="临时打开或关闭 Claude 登录浏览器")
    login.add_argument("action", choices=["start", "stop", "check"], help="check 启动原生浏览器并验证页面渲染")
    login.add_argument("--session", type=browser.session_id, help="由 Mac 客户端分配的会话 UUID")
    args = parser.parse_args()
    try:
        with uninstall.account_lock(exclusive=args.command == "uninstall"):
            # A command loaded from the zipapp may have waited for removal to finish.
            if args.command != "uninstall" and not Path(sys.argv[0]).exists():
                raise ValueError("此账号的 Termlo 已卸载。")
            dispatch(args, preflight_dir)
    except (EOFError, KeyboardInterrupt):
        parser.exit(130, "\n操作已取消。\n")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Termlo：{error}\n")


def dispatch(args, preflight_dir=None):
    if args.command == "install":
        install(args, preflight_dir=preflight_dir, interactive=len(sys.argv) == 2)
    elif args.command == "uninstall":
        add_tool_paths()
        uninstall.run(config_dir(), args.keep_tools)
    elif args.command == "connection-code":
        add_tool_paths()
        details = verified_identity(connection_settings(args), require_key=args.host_key is not None)
        print(encode(dict(details, version=2, pairing=pairing.issue())))
    elif args.command == "redeem":
        print(pairing.redeem(args.ticket, os.environ.get("SSH_ORIGINAL_COMMAND", "")))
    elif args.action == "check":
        print("原生浏览器可启动并渲染测试页：" + native_browser.check())
    else:
        browser.manage(args.action, args.session, config_dir())


if __name__ == "__main__":
    main()
