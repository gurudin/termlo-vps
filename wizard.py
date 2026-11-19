"""VPS 安装向导的终端输入和地址建议。"""

import http.client
import ipaddress
import json
import shutil
import subprocess
import sys
import urllib.request

from connection_code import validate_host


def usable_address(address):
    return not (address.is_unspecified or address.is_loopback or address.is_multicast
                or address.is_link_local or address.is_reserved)


def local_addresses():
    if not shutil.which("hostname"):
        return []
    try:
        result = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode:
        return []
    addresses = []
    for field in result.stdout.split():
        try:
            address = ipaddress.ip_address(field)
        except ValueError:
            continue
        if usable_address(address):
            addresses.append(address)
    return addresses


def public_egress_address(region="global"):
    domestic = "https://myip.ipip.net/json"
    international = "https://api64.ipify.org"
    for url in ((domestic, international) if region == "cn" else (international, domestic)):
        try:
            with urllib.request.urlopen(url, timeout=3) as response:
                body = response.read(2048)
            value = json.loads(body)["data"]["ip"] if url == domestic else body.decode("ascii").strip()
            address = ipaddress.ip_address(value)
            if address.is_global and usable_address(address):
                return str(address)
        except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException):
            continue
    return None


def suggest_host(ssh_address, region="global", egress=None):
    if ssh_address and ssh_address.is_global and usable_address(ssh_address):
        return str(ssh_address), "当前 SSH 会话"
    addresses = local_addresses()
    for address in addresses:
        if address.is_global:
            return str(address), "本机公网地址"
    external = egress or public_egress_address(region)
    if external:
        return external, "检测到的公网出口，使用转发时请核对"
    if ssh_address and usable_address(ssh_address):
        return str(ssh_address), "当前 SSH 会话的内网地址"
    if addresses:
        return str(addresses[0]), "本机内网地址"
    return None, "请填写 Mac 平时连接的域名或 IP"


def reply(terminal, prompt):
    print(prompt + " ", file=sys.stderr, end="", flush=True)
    line = terminal.readline()
    if not line:
        raise EOFError("安装已取消。")
    return line.strip()


def ask_field(terminal, label, default, validate):
    suffix = f" [{default}]" if default is not None else ""
    while True:
        value = reply(terminal, label + suffix + " ›")
        try:
            return validate(value or (str(default) if default is not None else ""))
        except ValueError as error:
            print(str(error), file=sys.stderr)


def ssh_host(value):
    # Brackets are common when copying an IPv6 destination out of an SSH command.
    if value.startswith("[") and value.endswith("]") and ":" in value:
        value = value[1:-1]
    return validate_host(value)


def ssh_port(value):
    if value.isascii() and value.isdigit() and len(value) <= 5 and 1 <= int(value) <= 65535:
        return int(value)
    raise ValueError("请输入 1 到 65535 之间的 SSH 端口。")


def choose(terminal, first="现在安装", second="跳过", default=1):
    while True:
        value = reply(terminal, f"  1 {first}   2 {second}  [{default}] ›").lower()
        if not value:
            return default == 1
        if value in ("1", "y", "yes"):
            return True
        if value in ("2", "n", "no"):
            return False
        print("请输入 1 或 2，或按回车采用默认选项。", file=sys.stderr)
