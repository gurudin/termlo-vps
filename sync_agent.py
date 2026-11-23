"""Install the versioned Mutagen receiver used by an SSH synchronization session."""

import hashlib
import os
from pathlib import Path
import platform
import pkgutil
import shutil
import subprocess
import sys
import tarfile
import tempfile


# Official asset IDs and SHA-256 values, also used by the Python-free preflight.
VERSION, *assets = pkgutil.get_data(__name__, "mutagen-releases.txt").decode("ascii").splitlines()
RELEASES = {system: (int(asset), digest) for system, asset, digest in (line.split() for line in assets)}


def installed_path():
    data = Path(os.environ.get("MUTAGEN_DATA_DIRECTORY") or Path.home() / ".mutagen")
    if not data.is_absolute():
        raise ValueError("MUTAGEN_DATA_DIRECTORY 需要使用绝对路径。")
    return data / "agents" / VERSION / "mutagen-agent"


def correct_version(path):
    if not path.is_file() or not os.access(path, os.X_OK):
        return False
    try:
        result = subprocess.run([str(path), "version"], capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and result.stdout.strip() == VERSION.encode("ascii")


def release_info():
    machine = platform.machine().lower()
    arch = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(machine)
    system = f"{sys.platform}_{arch}"
    if system not in RELEASES:
        raise ValueError(f"没有适用于 {sys.platform} {machine} 的 Termlo 同步代理安装包。")
    asset, expected_digest = RELEASES[system]
    name = f"mutagen_{system}_v{VERSION}.tar.gz"
    url = f"https://github.com/mutagen-io/mutagen/releases/download/v{VERSION}/{name}"
    api = f"https://api.github.com/repos/mutagen-io/mutagen/releases/assets/{asset}"
    return system, expected_digest, name, url, api


def verify_archive(path, expected_digest, name):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != expected_digest:
        raise ValueError(f"{name} 校验失败，请重新下载官方安装包。")


def install(verified_archive=None):
    target = installed_path()
    if correct_version(target):
        return target
    system, expected_digest, name, url, api = release_info()
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Stage on the destination filesystem; a failed download leaves existing agents intact.
    with tempfile.TemporaryDirectory(dir=target.parent, prefix=".install-") as tmp:
        folder = Path(tmp)
        archive = folder / name
        local = verified_archive or os.environ.get("TERMLO_MUTAGEN_ARCHIVE")
        if local:
            archive = Path(local)
        else:
            download = ["curl", "-q", "--proto", "=https", "--proto-redir", "=https", "-fL", "--retry", "2",
                        "--connect-timeout", "8", "--max-time", "600", "-o", str(archive)]
            first = subprocess.run([*download, url], stdout=sys.stderr)
            if first.returncode:
                print("正在通过 GitHub Releases API 重试同一个官方同步包…", file=sys.stderr, flush=True)
                fallback = subprocess.run([*download, "-H", "Accept: application/octet-stream", api], stdout=sys.stderr)
                if fallback.returncode and first.returncode in (60, 77):
                    first.check_returncode()
                fallback.check_returncode()
        verify_archive(archive, expected_digest, name)
        stage = folder / "mutagen-agent"
        with tarfile.open(archive, "r:gz") as release:
            bundle = release.getmember("mutagen-agents.tar.gz")
            if not bundle.isfile():
                raise ValueError("Mutagen 安装包缺少同步代理。")
            with release.extractfile(bundle) as contents, tarfile.open(fileobj=contents, mode="r|gz") as agents:
                for member in agents:
                    if member.name == system and member.isfile():
                        with agents.extractfile(member) as source, stage.open("xb") as dest:
                            shutil.copyfileobj(source, dest)
                        break
        if not stage.exists():
            raise ValueError(f"Mutagen 安装包缺少 {system} 同步代理。")
        stage.chmod(0o700)
        if not correct_version(stage):
            raise ValueError("下载的 Mutagen 同步代理未能通过版本检查。")
        os.replace(stage, target)
    return target
