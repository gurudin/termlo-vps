"""Install the versioned Mutagen receiver used by an SSH synchronization session."""

import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile


VERSION = "0.18.1"
# Asset IDs and SHA256SUMS from github.com/mutagen-io/mutagen/releases/tag/v0.18.1.
RELEASES = {
    "linux_amd64": (232224465, "7735286c778cc438418209f24d03a64f3a0151c8065ef0fe079cfaf093af6f8f"),
    "linux_arm64": (232224500, "bcba735aebf8cbc11da9b3742118a665599ac697fa06bc5751cac8dcd540db8a"),
    "darwin_amd64": (232224335, "7d06f7d8fcfe90bc7e55cc834a2f2f20c2e0af9ea9bc35911fc4341ad56a9bbf"),
    "darwin_arm64": (232224354, "6f810416d9e5fc4fd5e18431146f8b3c5a2056ba5a24f76c1e66da86eb3257e2"),
}


def installed_path():
    data = Path(os.environ.get("MUTAGEN_DATA_DIRECTORY") or Path.home() / ".mutagen")
    if not data.is_absolute():
        raise ValueError("MUTAGEN_DATA_DIRECTORY 需要使用绝对路径。")
    return data / "agents" / VERSION / "mutagen-agent"


def correct_version(path):
    if not path.is_file() or not os.access(path, os.X_OK):
        return False
    try:
        result = subprocess.run([str(path), "version"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and result.stdout.strip() == VERSION


def install():
    target = installed_path()
    if correct_version(target):
        return target
    machine = platform.machine().lower()
    arch = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(machine)
    system = f"{sys.platform}_{arch}"
    if system not in RELEASES:
        raise ValueError(f"没有适用于 {sys.platform} {machine} 的 Termlo 同步代理安装包。")
    asset, expected_digest = RELEASES[system]
    name = f"mutagen_{system}_v{VERSION}.tar.gz"
    url = f"https://github.com/mutagen-io/mutagen/releases/download/v{VERSION}/{name}"
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Stage on the destination filesystem; a failed download leaves existing agents intact.
    with tempfile.TemporaryDirectory(dir=target.parent, prefix=".install-") as tmp:
        folder = Path(tmp)
        archive = folder / name
        local = os.environ.get("TERMLO_MUTAGEN_ARCHIVE")
        if local:
            archive = Path(local)
        else:
            download = ["curl", "-q", "--proto", "=https", "--proto-redir", "=https", "-fL", "--retry", "2",
                        "--connect-timeout", "8", "--max-time", "600", "-o", str(archive)]
            first = subprocess.run([*download, url], stdout=sys.stderr)
            if first.returncode:
                print("正在通过 GitHub Releases API 重试同一个官方同步包…", file=sys.stderr, flush=True)
                api = f"https://api.github.com/repos/mutagen-io/mutagen/releases/assets/{asset}"
                fallback = subprocess.run([*download, "-H", "Accept: application/octet-stream", api], stdout=sys.stderr)
                if fallback.returncode and first.returncode in (60, 77):
                    first.check_returncode()
                fallback.check_returncode()
        digest = hashlib.sha256()
        with archive.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != expected_digest:
            raise ValueError(f"{name} 校验失败，请重新下载官方安装包。")
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
