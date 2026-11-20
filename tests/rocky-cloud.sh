#!/usr/bin/env bash
# Boot the distributor's VPS image, including its own kernel and Chromium sandbox.
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && -n ${RUNNER_TEMP:-} ]] || exit 1
repo=$PWD
cd "$(mktemp -d "$RUNNER_TEMP/termlo-rocky.XXXXXXXX")"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils cloud-image-utils
base=https://download.rockylinux.org/pub/rocky/9/images/x86_64
image=Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
curl -fsSL --retry 3 -o CHECKSUM "$base/CHECKSUM"
digest=$(awk -v image="($image)" '$1 == "SHA256" && $2 == image {print $4}' CHECKSUM)
[[ $digest =~ ^[0-9a-f]{64}$ ]]
curl -fsSL --retry 3 -o guest.qcow2 "$base/$image"
printf '%s  guest.qcow2\n' "$digest" | sha256sum -c -
qemu-img resize guest.qcow2 14G
ssh-keygen -qt ed25519 -N '' -f guest-key
cat > user-data <<EOF
#cloud-config
disable_root: false
users:
  - name: termlotest
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat guest-key.pub)
write_files:
  - path: /etc/termlo-disposable-cloud-test
    content: "Termlo CI"
EOF
cloud-localds seed.img user-data
sudo qemu-system-x86_64 -accel kvm -cpu host -smp 2 -m 4096 -display none -monitor none \
    -serial "file:$PWD/console.log" -daemonize -pidfile "$PWD/guest.pid" \
    -drive "file=$PWD/guest.qcow2,if=virtio,format=qcow2" -drive "file=$PWD/seed.img,if=virtio,format=raw" \
    -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:22022-:22
trap 'sudo kill "$(sudo cat guest.pid)" || true' EXIT
transport=(ssh -i "$PWD/guest-key" -p 22022 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$PWD/known" \
           -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=3)
guest=("${transport[@]}" termlotest@127.0.0.1)
for ((attempt=0; attempt<90; attempt++)); do
    if "${guest[@]}" 'test -f /etc/termlo-disposable-cloud-test' 2>/dev/null; then break; fi
    sleep 2
done
"${guest[@]}" 'test -f /etc/termlo-disposable-cloud-test' || { sudo tail -80 console.log; exit 1; }
git -C "$repo" archive HEAD | "${guest[@]}" 'sudo mkdir -p /src && sudo tar -xf - -C /src'
"${guest[@]}" 'sudo install -d -m 700 /root/.ssh && sudo tee -a /root/.ssh/authorized_keys >/dev/null' < guest-key.pub
"${transport[@]}" root@127.0.0.1 'TERMLO_DISPOSABLE_INSTALL_TEST=1 sh /src/tests/clean-install.sh'
