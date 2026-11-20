#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$source_dir/install.sh"}
mkdir -p -- "$(dirname -- "$output")"
stage=$(mktemp "$output.XXXXXX")
compat_stage=''
trap 'rm -f -- "$stage"; if [[ -n $compat_stage ]]; then rm -f -- "$compat_stage"; fi' EXIT

cat > "$stage" <<'HEADER'
#!/usr/bin/env bash
set -euo pipefail
termlo_install() (
bundle=$(mktemp -d)
trap 'rm -rf -- "$bundle"' EXIT
base64 -d <<'TERMLO_ARCHIVE' | tar -xz -C "$bundle"
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
        for name in ("bootstrap.sh", "sources.sh", "termlo.py", "connection_code.py", "pairing.py", "browser.py",
                     "native_browser.py", "sync_agent.py", "wizard.py"):
            data = (source / name).read_bytes()
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
sys.stdout.buffer.write(base64.encodebytes(payload.getvalue()))
PY
cat >> "$stage" <<'FOOTER'

TERMLO_ARCHIVE
bash "$bundle/bootstrap.sh" "$@"
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
