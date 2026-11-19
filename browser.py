"""按 SSH 用户启动临时的、受密码保护的 Chromium。"""

import argparse
import base64
import fcntl
import http.client
import json
import os
import secrets
import shutil
import ssl
import subprocess
import sys
import time
import uuid


# LinuxServer release 075b0b99-ls64, multi-architecture index on Docker Hub and GHCR.
IMAGE_DIGEST = "sha256:6d2a8da6a45d4083a7287211a619ca29fdb518ebea0ef562c27392ba2f6698d2"
IMAGE = "lscr.io/linuxserver/chromium@" + IMAGE_DIGEST
CN_IMAGE = "docker.m.daocloud.io/linuxserver/chromium@" + IMAGE_DIGEST
LEGACY_IMAGE = "lscr.io/linuxserver/chromium:latest"
LABEL = "io.termlo.login"


def session_id(value):
    try:
        return str(uuid.UUID(value))
    except ValueError:
        raise argparse.ArgumentTypeError("会话 ID 应为 UUID") from None


def available_engine():
    for engine in ("podman", "docker"):
        if not shutil.which(engine):
            continue
        # A developer may have pointed the CLI at another machine. The SSH tunnel ends here.
        if engine == "docker":
            endpoint = os.environ.get("DOCKER_HOST")
            if not endpoint or os.environ.get("DOCKER_CONTEXT"):
                current = subprocess.run(["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
                                         capture_output=True, text=True)
                endpoint = current.stdout.strip()
            if not endpoint.startswith("unix://"):
                continue
        elif os.environ.get("CONTAINER_HOST") or os.environ.get("CONTAINER_CONNECTION"):
            continue
        info = subprocess.run([engine, "info"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if info.returncode == 0:
            return engine
    return None


def require_engine():
    engine = available_engine()
    if not engine:
        raise ValueError("当前 SSH 用户无法运行 Podman 或 Docker。请在 VPS 安装向导中选择「Claude 登录浏览器」。")
    return engine


def local_image(engine):
    for image in (IMAGE, CN_IMAGE, LEGACY_IMAGE):
        if subprocess.run([engine, "image", "inspect", image], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0:
            return image
    return None


def prepare_image(engine, region):
    if local_image(engine):
        return
    first, fallback = (CN_IMAGE, IMAGE) if region == "cn" else (IMAGE, CN_IMAGE)
    print(f"正在从 {first.split('/')[0]} 下载 Chromium 镜像…", file=sys.stderr, flush=True)
    if subprocess.run([engine, "pull", first], stdout=sys.stderr).returncode:
        print(f"下载失败，改从 {fallback.split('/')[0]} 获取同一镜像。", file=sys.stderr, flush=True)
        subprocess.run([engine, "pull", fallback], stdout=sys.stderr, check=True)


def inspect_container(engine, name, owner):
    result = subprocess.run([engine, "container", "inspect", name], capture_output=True, text=True)
    if result.returncode:
        # Check presence separately so a runtime or permission error cannot turn into a successful stop.
        listing = subprocess.run([engine, "ps", "-a", "--format", "{{.Names}}"],
                                 capture_output=True, text=True, check=True)
        if name not in listing.stdout.splitlines():
            return None
        raise ValueError(result.stderr.strip() or "无法读取登录容器。")
    container = json.loads(result.stdout)[0]
    if (container["Config"].get("Labels") or {}).get(LABEL) != owner:
        raise ValueError(f"已有其他容器使用名称 {name}，请先核对。")
    return container


def credentials(container):
    bindings = (container["NetworkSettings"].get("Ports") or {}).get("3001/tcp") or []
    if len(bindings) != 1 or bindings[0]["HostIp"] != "127.0.0.1":
        raise ValueError("登录浏览器的 HTTPS 端口必须只绑定 VPS 回环地址。")
    env = dict(item.split("=", 1) for item in container["Config"]["Env"] if "=" in item)
    if env.get("CUSTOM_USER") != "termlo" or not env.get("PASSWORD"):
        raise ValueError("登录浏览器缺少会话凭据。")
    return dict(port=int(bindings[0]["HostPort"]), user="termlo", password=env["PASSWORD"])


def wait_until_ready(access):
    # The image serves a self-signed certificate. This probe only targets its local published port.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    auth = base64.b64encode(f"{access['user']}:{access['password']}".encode()).decode()
    def request(headers):
        connection = http.client.HTTPSConnection("127.0.0.1", access["port"], timeout=2, context=context)
        try:
            connection.request("GET", "/", headers=headers)
            return connection.getresponse().status
        finally:
            connection.close()

    deadline = time.monotonic() + 70
    while time.monotonic() < deadline:
        try:
            if 200 <= request({"Authorization": "Basic " + auth}) < 400:
                if request({}) == 401:
                    return
                raise ValueError("登录浏览器允许匿名访问，已拒绝打开。")
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(0.5)
    raise ValueError("Chromium 在 70 秒内未就绪，请核对 VPS 可用内存和容器运行时。")


def manage(action, session, folder):
    engine = require_engine()
    owner = f"{os.getuid()}-{session or 'default'}"
    name = "termlo-login-" + owner
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (folder / "browser.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        container = inspect_container(engine, name, owner)
        if action == "stop":
            if container:
                subprocess.run([engine, "rm", "-f", "-v", container["Id"]], stdout=sys.stderr, check=True)
            return

        if container and not container["State"]["Running"]:
            subprocess.run([engine, "rm", "-v", container["Id"]], stdout=sys.stderr, check=True)
            container = None
        created = None
        if not container:
            image = local_image(engine)
            if not image:
                raise ValueError("尚未准备 Chromium 镜像。请在 VPS 安装向导中选择「Claude 登录浏览器」。")
            # The legacy client forwards port 3001. Named sessions each get a free loopback port.
            publish = "127.0.0.1::3001" if session else "127.0.0.1:3001:3001"
            result = subprocess.run([engine, "run", "-d", "--rm", "--pull=never", "--name", name,
                                     "--label", f"{LABEL}={owner}", "-p", publish, "--shm-size=1g",
                                     "-e", "CUSTOM_USER=termlo", "-e", "PASSWORD", image],
                                    env=dict(os.environ, PASSWORD=secrets.token_urlsafe(24)),
                                    stdout=subprocess.PIPE, text=True, check=True)
            created = result.stdout.strip()
        try:
            if created:
                container = inspect_container(engine, name, owner)
            if not container:
                raise ValueError("登录容器启动后已退出。")
            access = credentials(container)
            wait_until_ready(access)
        except BaseException:
            if created:
                subprocess.run([engine, "rm", "-f", "-v", created], stdout=sys.stderr, stderr=subprocess.DEVNULL)
            raise
        print("TERMLO_BROWSER " + json.dumps(access, separators=(",", ":")))
