#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$source_dir/install.sh"}
mkdir -p -- "$(dirname -- "$output")"
stage=$(mktemp "$output.XXXXXX")
compat_stage=''
trap 'rm -f -- "$stage"; if [[ -n $compat_stage ]]; then rm -f -- "$compat_stage"; fi' EXIT

cat > "$stage" <<'HEADER'
#!/bin/sh
set -eu
termlo_unavailable_bundle() (
HEADER
# The checklist must still run when the payload cannot be unpacked.
cat "$source_dir/python-runtime.sh" "$source_dir/prerequisites.sh" "$source_dir/doctor.sh" >> "$stage"
printf "\nmanifest='%s'\n" "$(cat "$source_dir/mutagen-releases.txt")" >> "$stage"
cat >> "$stage" <<'HEADER'
scratch=''
if has mktemp && has rm; then scratch=$(mktemp -d) || scratch=''; fi
if [ -n "$scratch" ]; then trap 'rm -rf -- "$scratch"' EXIT; fi
termlo_doctor '' "$manifest" /etc/os-release "$scratch" "$@"
)
termlo_install() (
unpack_missing=''
unpack_error=''
for tool in mktemp base64 tar gzip cat dirname rm; do
    command -v "$tool" >/dev/null 2>&1 || unpack_missing="$unpack_missing $tool"
done
if [ -n "$unpack_missing" ]; then termlo_unavailable_bundle "$@"; exit 1; fi
bundle=$(mktemp -d) || { unpack_error='临时目录无法创建'; termlo_unavailable_bundle "$@"; exit 1; }
trap 'rm -rf -- "$bundle"' EXIT
if ! base64 -d > "$bundle/archive.tgz" <<'TERMLO_ARCHIVE'
HEADER
python3 - "$source_dir" >> "$stage" <<'PY'
import base64
import gzip
import io
from pathlib import Path
import sys
import tarfile

source = Path(sys.argv[1])
payload = io.BytesIO()
with gzip.GzipFile(fileobj=payload, mode="wb", mtime=0) as compressed:
    with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name in ("bootstrap.sh", "bootstrap.py", "python-runtime.sh", "prerequisites.sh", "doctor.sh", "sources.sh", "termlo.py", "connection_code.py", "pairing.py", "browser.py",
                     "native_browser.py", "sync_agent.py", "mutagen-releases.txt", "uninstall.py", "wizard.py"):
            data = (source / name).read_bytes()
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
sys.stdout.buffer.write(base64.encodebytes(payload.getvalue()))
PY
cat >> "$stage" <<'FOOTER'

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
FOOTER
chmod 755 "$stage"
if (( $# == 0 )); then
    # Existing curl commands use this path. Publish real, byte-identical files at both URLs.
    mkdir -p -- "$source_dir/dist"
    compat_stage=$(mktemp "$source_dir/dist/termlo-install.sh.XXXXXX")
    cp -p -- "$stage" "$compat_stage"
    mv -f -- "$compat_stage" "$source_dir/dist/termlo-install.sh"
fi
mv -f -- "$stage" "$output"
