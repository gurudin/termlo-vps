#!/bin/sh
# Runs inside a fresh, disposable Linux image with the checkout mounted at /src.
set -eu
{ [ -f /.dockerenv ] || [ -f /etc/termlo-disposable-cloud-test ]; } &&
    [ -f /src/install.sh ] && [ "${TERMLO_DISPOSABLE_INSTALL_TEST:-}" = 1 ] || {
    echo "Run this check inside its disposable CI guest." >&2
    exit 1
}
umask 077
cd "$(mktemp -d)"
work=$PWD
export TERMLO_INSTALL_NETWORK=global
. /etc/os-release
case "$ID" in
    debian)
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server
        mv /usr/bin/apt-get "$work/original-apt-get" ;;
    rocky) dnf -y install openssh-server ;;
    alpine) apk add --no-cache openssh-server openssh-keygen ;;
    *) exit 1 ;;
esac
mkdir -p /run/sshd
ssh-keygen -A
# The test SSH service accepts keys on container loopback only.
sed -i 's|^root:[^:]*:|root:*:|' /etc/shadow
/usr/sbin/sshd -e -o ListenAddress=127.0.0.1 -p 2222 -o PasswordAuthentication=no -o PermitRootLogin=prohibit-password

install_termlo() {
    cat /src/install.sh | sh -s -- --without-claude --host 127.0.0.1 --port 2222 > "$work/code"
}

# Stop before pairing with a real truncated transfer, then repeat the same entry point.
printf incomplete > partial-download
export TERMLO_MUTAGEN_ARCHIVE="$work/partial-download"
if install_termlo 2>first-install.log; then echo "Unexpected success with an incomplete agent archive"; exit 1; fi
grep -q '校验失败' first-install.log || { cat first-install.log >&2; exit 1; }
test ! -s code
test ! -e "$HOME/.local/bin/termlo"
unset TERMLO_MUTAGEN_ARCHIVE
install_termlo
"$HOME/.local/bin/termlo" browser check

ssh-keygen -q -t ed25519 -N '' -f device
python3 - <<'PY'
import base64, json
from pathlib import Path
raw = Path("code").read_text().strip().split("/")[-1]
server = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
assert server["host"] == "127.0.0.1" and server["port"] == 2222
Path("invite").write_text(server["pairing"]["key"])
Path("known_hosts").write_text("[127.0.0.1]:2222 " + server["hostKey"] + "\n")
PY
mkdir -p "$HOME/.ssh"
cat > "$HOME/.ssh/config" <<EOF
Host termlo-test
  HostName 127.0.0.1
  Port 2222
  User root
  IdentityFile "$work/device"
  IdentitiesOnly yes
  BatchMode yes
  UserKnownHostsFile "$work/known_hosts"
  StrictHostKeyChecking yes
EOF
key=$(awk '{print $2}' device.pub)
ssh -i "$work/invite" termlo-test "termlo-pair $key" | grep -qx termlo-paired-v2
test "$(ssh termlo-test 'printf paired')" = paired

mkdir mac-project vps-project
printf first > mac-project/file
install_termlo
test "$(ssh termlo-test 'printf paired')" = paired
test -f mac-project/file
test "$(grep -c ' termlo-mac$' "$HOME/.ssh/authorized_keys")" = 1

# Use the official client matching the installed agent. These jobs run on amd64.
curl --fail --location --retry 2 -o client.tar.gz \
    https://github.com/mutagen-io/mutagen/releases/download/v0.18.1/mutagen_linux_amd64_v0.18.1.tar.gz
printf '%s  client.tar.gz\n' 7735286c778cc438418209f24d03a64f3a0151c8065ef0fe079cfaf093af6f8f | sha256sum -c -
tar -xzf client.tar.gz mutagen
export MUTAGEN_DATA_DIRECTORY="$work/client-data"
./mutagen sync create --name=termlo-test "$work/mac-project" "termlo-test:$work/vps-project"
./mutagen sync flush termlo-test
test "$(ssh termlo-test "cat '$work/vps-project/file'")" = first
ssh termlo-test "printf returned > '$work/vps-project/file'"
./mutagen sync flush termlo-test
test "$(cat mac-project/file)" = returned
./mutagen sync terminate termlo-test

if [ "$ID" = debian ]; then
    # Exercise the library fallback when both APT frontends are missing.
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-apt
    mv /usr/bin/apt "$work/original-apt"
    mv /usr/bin/apt-get "$work/recovered-apt-get"
    mv /usr/bin/tmux "$work/original-tmux"
    install_termlo
    apt-get --version >/dev/null
    tmux -V
    test "$(ssh termlo-test 'printf paired')" = paired
fi
