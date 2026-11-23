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
        mv /usr/bin/apt-get "$work/original-apt-get"
        # Exercise ssh-keygen on a host with sshd installed but no identity.
        mkdir original-keys
        for key in /etc/ssh/ssh_host_*_key*; do [ ! -f "$key" ] || mv "$key" original-keys/; done ;;
    alpine)
        # No Bash, Python, sshd, or pre-generated SSH identity.
        test ! -x /usr/sbin/sshd ;;
    rocky) : ;;  # The cloud guest is already connected over its stock SSH service.
    *) exit 1 ;;
esac
if [ "$ID" != rocky ]; then
    # Restrict this disposable test's SSH listener to loopback.
    mkdir -p /etc/ssh
    cat > /etc/ssh/sshd_config <<'SSH'
ListenAddress 127.0.0.1
PermitRootLogin prohibit-password
PasswordAuthentication no
Subsystem sftp internal-sftp
SSH
    test ! -e /etc/ssh/ssh_host_ed25519_key
fi
sed -i 's|^root:[^:]*:|root:*:|' /etc/shadow

install_termlo() {
    sh /src/install.sh --without-claude --host 127.0.0.1 --port 22 > "$work/code"
}

# Stop before pairing with a real truncated transfer, then repeat the same entry point.
printf incomplete > partial-download
export TERMLO_MUTAGEN_ARCHIVE="$work/partial-download"
if install_termlo 2>first-install.log; then echo "Unexpected success with an incomplete agent archive"; exit 1; fi
grep -q '校验失败' first-install.log || { cat first-install.log >&2; exit 1; }
grep -q '^  \[未通过\] Mutagen' first-install.log
grep -q '^  \[通过\] 远程系统' first-install.log
grep -q '^体检未通过。' first-install.log
test ! -s code
test ! -e "$HOME/.local/bin/termlo"
test ! -f "$HOME/.config/termlo/installed-components.json"
if [ "$ID" != rocky ]; then test ! -e /etc/ssh/ssh_host_ed25519_key; fi
unset TERMLO_MUTAGEN_ARCHIVE
case "$ID" in
    debian)
        test ! -x /usr/bin/apt-get
        grep -q '\[未通过\] 系统包管理器  apt-get' first-install.log
        grep -q 'apt install -y --reinstall apt' first-install.log
        apt update
        apt install -y --reinstall apt
        apt-get install -y --no-install-recommends curl ca-certificates python3 ;;
    alpine)
        grep -q '\[未通过\] Bash' first-install.log
        grep -q '\[未通过\] Python' first-install.log
        grep -q 'apk add --no-cache python3' first-install.log
        test ! -x /bin/bash
        test ! -x /usr/bin/python3
        apk add --no-cache bash python3 curl ca-certificates ;;
esac
sh /src/install.sh --check --host 127.0.0.1
if [ "$ID" != rocky ]; then test ! -e /etc/ssh/ssh_host_ed25519_key; fi
install_termlo
test -s /etc/ssh/ssh_host_ed25519_key
"$HOME/.local/bin/termlo" browser check

ssh-keygen -q -t ed25519 -N '' -f device
python3 - <<'PY'
import base64, json
from pathlib import Path
raw = Path("code").read_text().strip().split("/")[-1]
server = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
assert server["host"] == "127.0.0.1" and server["port"] == 22
Path("invite").write_text(server["pairing"]["key"])
Path("known_hosts").write_text("127.0.0.1 " + server["hostKey"] + "\n")
PY
mkdir -p "$HOME/.ssh"
cat > "$HOME/.ssh/config" <<EOF
Host termlo-test
  HostName 127.0.0.1
  Port 22
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
    # Recover with both frontends missing, without provisioning Python APT bindings.
    mv /usr/bin/apt "$work/original-apt"
    mv /usr/bin/apt-get "$work/recovered-apt-get"
    mv /usr/bin/tmux "$work/original-tmux"
    if install_termlo 2>missing-apt.log; then echo "Unexpected install with missing APT"; exit 1; fi
    grep -q '\[未通过\] 系统包管理器  apt-get' missing-apt.log
    test ! -x /usr/bin/apt-get
    test ! -x /usr/bin/tmux
    # Apply the distribution-signed recovery route identified in the checklist,
    # then rerun the installer and verify the already-paired SSH device.
    . /src/prerequisites.sh
    restore_apt
    install_termlo
    apt-get --version >/dev/null
    tmux -V
    test "$(ssh termlo-test 'printf paired')" = paired
fi
