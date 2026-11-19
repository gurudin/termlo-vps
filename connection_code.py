"""从 VPS 的 SSH 主机公钥生成一行 Termlo v1 连接码。"""

import argparse
import base64
import ipaddress
import json
from pathlib import Path
import re
import subprocess


def encode(payload):
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return "termlo://connect/" + base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def validate_host(host):
    if ":" in host:
        try:
            ipaddress.IPv6Address(host.split("%", 1)[0])
        except ValueError:
            raise ValueError("请单独填写域名或 IP，SSH 端口另行设置") from None
        if not re.fullmatch(r"[a-fA-F0-9:.]+(?:%[a-zA-Z0-9_.-]+)?", host):
            raise ValueError("IPv6 地址格式不正确")
    elif not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._-]*", host):
        raise ValueError("请填写有效的 VPS 域名或 IP")
    return host


def connection_details(host, port, user, host_key, name=None, include_host_key=False):
    validate_host(host)
    if not 1 <= port <= 65535 or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*\$?", user):
        raise ValueError("请核对 SSH 端口和用户名")
    if name is not None and not name.strip():
        raise ValueError("服务器名称不能为空")

    with Path(host_key).open(encoding="utf-8") as key_file:
        public_key = key_file.readline()
    if not public_key.startswith(("ssh-", "ecdsa-", "sk-")):
        raise ValueError("--host-key 需要 OpenSSH 格式的主机公钥")
    result = subprocess.run(["ssh-keygen", "-E", "sha256", "-lf", "-"], input=public_key,
                            capture_output=True, text=True)
    fields = result.stdout.split()
    if result.returncode or len(fields) < 2 or not re.fullmatch(r"SHA256:[A-Za-z0-9+/]{43}", fields[1]):
        raise ValueError(f"无法计算 SSH 主机公钥 {host_key} 的指纹")
    payload = dict(version=1, host=host, port=port, user=user, fingerprint=fields[1])
    if include_host_key:
        payload["hostKey"] = " ".join(public_key.split()[:2])
    if name is not None:
        payload["name"] = name
    return payload


def make_code(host, port, user, host_key, name=None):
    """Build a metadata-only v1 code for existing integrations."""
    return encode(connection_details(host, port, user, host_key, name))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--host", help="Mac 可访问的 VPS 域名或 IP")
    source.add_argument("--demo", action="store_true", help="在本机输出规范中的示例连接码")
    parser.add_argument("--user", help="SSH 登录用户")
    parser.add_argument("--port", type=int, help="对外 SSH 端口，默认 22")
    parser.add_argument("--name", help="Mac 上显示的名称")
    parser.add_argument("--host-key", type=Path, help="SSH 主机公钥文件，默认使用系统的 Ed25519 主机公钥")
    args = parser.parse_args()
    if args.demo:
        if any(value is not None for value in (args.user, args.port, args.name, args.host_key)):
            parser.error("--demo 生成固定的示例，请单独使用")
        print(encode(dict(version=1, host="vps.example.com", port=2222, user="dev",
                          fingerprint="SHA256:bbXpuKG6zhzdmnxq256TlqzFBzRl2f6OOg722cYNbU8", name="开发机")))
        return
    if not args.user:
        parser.error("请通过 --user 指定 SSH 登录用户")
    port = 22 if args.port is None else args.port
    host_key = args.host_key or Path("/etc/ssh/ssh_host_ed25519_key.pub")
    try:
        print(make_code(args.host, port, args.user, host_key, args.name))
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
