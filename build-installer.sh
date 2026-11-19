#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
output=${1:-"$source_dir/dist/termlo-install.sh"}
mkdir -p -- "$(dirname -- "$output")"
stage=$(mktemp "$output.XXXXXX")
trap 'rm -f -- "$stage"' EXIT

cat > "$stage" <<'HEADER'
#!/usr/bin/env bash
set -euo pipefail
termlo_install() (
bundle=$(mktemp -d)
trap 'rm -rf -- "$bundle"' EXIT
base64 -d <<'TERMLO_ARCHIVE' | tar -xz -C "$bundle"
HEADER
COPYFILE_DISABLE=1 tar -C "$source_dir" -czf - install.sh termlo.py connection_code.py browser.py wizard.py | base64 | fold -w 76 >> "$stage"
cat >> "$stage" <<'FOOTER'

TERMLO_ARCHIVE
bash "$bundle/install.sh" "$@"
)
termlo_install "$@"
FOOTER
chmod 755 "$stage"
mv -f -- "$stage" "$output"
