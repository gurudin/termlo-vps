#!/bin/sh
set -eu
termlo_unavailable_bundle() (
find_python() {
    for interpreter in python3 python3.14 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
        command -v "$interpreter" >/dev/null 2>&1 || continue
        if [ "$(command -v "$interpreter")" = /usr/bin/python3 ] && [ "$(uname -s)" = Darwin ]; then
            /usr/bin/xcode-select -p >/dev/null 2>&1 || continue
        fi
        "$interpreter" -IB -c 'import ssl, sys, zlib; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1 || continue
        printf '%s\n' "$interpreter"
        return 0
    done
    return 1
}
# POSIX helpers shared by the installer, its read-only checks and the installed CLI.
has() { command -v "$1" >/dev/null 2>&1; }

linux_manager() (
    if [ -r "${1:-/etc/os-release}" ]; then
        . "${1:-/etc/os-release}"
        case " ${ID:-} ${ID_LIKE:-} " in
            *" debian "*|*" ubuntu "*) echo apt; return ;;
            *" alpine "*) echo apk; return ;;
            *" fedora "*|*" rhel "*|*" centos "*|*" alinux "*|*" amzn "*) echo rpm; return ;;
        esac
    fi
    if has apt-get || has dpkg; then echo apt
    elif has dnf || has yum || has microdnf; then echo rpm
    elif has apk; then echo apk
    else return 1; fi
)

as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"
    elif has sudo; then sudo "$@"
    elif has doas; then doas "$@"
    else echo "此操作需要管理员权限。请让管理员执行体检中列出的命令。" >&2; return 1; fi
}

apt_ready() { has apt-get && apt-get --version >/dev/null 2>&1; }

# Both the checklist and the installation use these distribution-signed sources.
china_sources() (
    [ -r "$1" ] || return 1
    . "$1"
    suite=${VERSION_CODENAME:-}
    arch=$2
    case $suite in ''|[!a-z]*|*[!a-z0-9-]*) return 1 ;; esac
    case $arch in ''|[!a-z0-9]*|*[!a-z0-9-]*) return 1 ;; esac
    mirror=https://mirrors.tuna.tsinghua.edu.cn
    case ${ID:-} in
        debian)
            archive=$mirror/debian; security=$mirror/debian-security
            components=main; keyring=/usr/share/keyrings/debian-archive-keyring.gpg ;;
        ubuntu)
            case $arch in amd64|i386) archive=$mirror/ubuntu ;; *) archive=$mirror/ubuntu-ports ;; esac
            security=$archive; components='main restricted universe multiverse'
            keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg ;;
        *) return 1 ;;
    esac
    options="arch=$arch signed-by=$keyring"
    printf 'deb [%s] %s %s %s\n' "$options" "$archive" "$suite" "$components" \
        "$options" "$archive" "$suite-updates" "$components" \
        "$options" "$security" "$suite-security" "$components"
)

cached_apt() (
    has dpkg && has dpkg-deb || return 1
    arch=$(dpkg --print-architecture) || return 1
    version=$(dpkg-query -W -f='${Version}' apt 2>/dev/null) || version=''
    for deb in /var/cache/apt/archives/apt_*.deb; do
        [ -f "$deb" ] || continue
        [ "$(dpkg-deb -f "$deb" Package)" = apt ] && [ "$(dpkg-deb -f "$deb" Architecture)" = "$arch" ] || continue
        [ -z "$version" ] || [ "$(dpkg-deb -f "$deb" Version)" = "$version" ] || continue
        printf '%s\n' "$deb"; return 0
    done
    return 1
)

# Recover apt itself from the distribution's authenticated package indexes.
# This still works when both apt and apt-get have been removed from a VPS.
indexed_apt() (
    has apt-cache && has dpkg && has awk || return 1
    [ -x /usr/lib/apt/apt-helper ] || { has curl && has sha256sum; } || return 1
    . /etc/os-release
    case ${ID:-} in
        debian) mirror=https://deb.debian.org/debian ;;
        ubuntu) case $(dpkg --print-architecture) in amd64|i386) mirror=https://archive.ubuntu.com/ubuntu ;; *) mirror=https://ports.ubuntu.com/ubuntu-ports ;; esac ;;
        *) return 1 ;;
    esac
    # Only accept a release path and digest from the same complete package stanza.
    metadata=$(apt-cache -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= show apt 2>/dev/null |
        awk -v RS='' '{
            file=""; sha=""
            for (i=1;i<NF;i++) {
                if ($i=="Filename:") file=$(i+1)
                if ($i=="SHA256:") sha=$(i+1)
            }
            if (file ~ /^pool\/main\/a\/apt\/apt_[[:alnum:].+:%~_-]+\.deb$/ && length(sha)==64 && sha ~ /^[a-fA-F0-9]+$/) {
                print file,sha; exit
            }
        }')
    [ -n "$metadata" ] || return 1
    read -r filename digest <<META
$metadata
META
    if [ "$#" = 0 ]; then printf '%s/%s %s\n' "$mirror" "$filename" "$digest"; return; fi
    dest=$(mktemp -d) || return 1
    trap 'rm -rf -- "$dest"' EXIT
    if [ -x /usr/lib/apt/apt-helper ]; then
        /usr/lib/apt/apt-helper download-file "$mirror/$filename" "$dest/apt.deb" "SHA256:$digest" || return 1
    else
        curl -qfL --proto '=https' --proto-redir '=https' --retry 2 -o "$dest/apt.deb" "$mirror/$filename" || return 1
        actual=$(sha256sum < "$dest/apt.deb") && [ "${actual%% *}" = "$digest" ] || return 1
    fi
    as_root dpkg -i "$dest/apt.deb"
)

apt_recovery_hint() {
    if ! dpkg --version >/dev/null 2>&1; then
        printf '%s\n' '请用同版本 Debian/Ubuntu 的救援环境挂载原系统，并取得匹配架构的 dpkg、apt 及依赖的官方 .deb。若原系统挂载在 /mnt，在放置这些包的目录以管理员身份运行 dpkg --root=/mnt -i ./*.deb。'
        return 1
    elif apt --version >/dev/null 2>&1; then printf '%sapt update && %sapt install -y --reinstall apt\n' "$1" "$1"
    elif aptitude --version >/dev/null 2>&1; then printf '%saptitude update && %saptitude reinstall -y apt\n' "$1" "$1"
    elif deb=$(cached_apt); then printf '%sdpkg -i "%s"\n' "$1" "$deb"
    elif metadata=$(indexed_apt); then
        read -r url sha <<META
$metadata
META
        if [ -x /usr/lib/apt/apt-helper ]; then
            printf '用发行版索引中的校验值恢复：(d=$(mktemp -d) && /usr/lib/apt/apt-helper download-file %s "$d/apt.deb" SHA256:%s && %sdpkg -i "$d/apt.deb")\n' "$url" "$sha" "$1"
        else
            printf '可从发行版软件源恢复。手动运行 (d=$(mktemp -d) && cd "$d" && curl -fLO %s && echo "%s  %s" | sha256sum -c - && %sdpkg -i %s)\n' "$url" "$sha" "${url##*/}" "$1" "${url##*/}"
        fi
    elif has python3 && python3 -B -c 'import apt' 2>/dev/null; then
        printf "%spython3 -c 'import apt; c=apt.Cache(); c.update(); c.open(); p=c[\"apt\"]; c._depcache.set_reinstall(p._pkg, True) if p.is_installed else p.mark_install(); c.commit()'\n" "$1"
    elif has pkcon && pkcon get-roles >/dev/null 2>&1 &&
        [ "$(dpkg-query -W -f='${db:Status-Status}' apt 2>/dev/null || :)" = not-installed ]; then
        printf '%spkcon --noninteractive install apt\n' "$1"
    else
        printf '从本机发行版、版本及架构对应的官方安装介质取出 apt 和所需依赖的 .deb，放入一个空目录。在该目录运行 %sdpkg -i ./*.deb && apt-get --version\n' "$1"
        return 1
    fi
}

# Probe only this machine. The address/port of the SSH session are the internal
# listener, even if the Mac reaches it through a different public NAT port.
scan_ssh() (
    has ssh-keyscan || return 1
    requested=${1:-22}
    if [ -n "${SSH_CONNECTION:-}" ]; then
        read -r client client_port address port <<ENDPOINT
$SSH_CONNECTION
ENDPOINT
        case $address in *[!a-zA-Z0-9:.%_-]*|-*|'') return 1 ;; esac
        ports=$port
        addresses=$address
    else
        ports=$requested
        [ "$requested" = 22 ] || ports="$ports 22"
        addresses='127.0.0.1 ::1'
    fi
    # A console install may target a daemon bound only to a LAN interface,
    # or expose a custom internal port through NAT. Never scan the public --host.
    if [ -z "${SSH_CONNECTION:-}" ]; then
        if has hostname; then addresses="$addresses $(hostname -I 2>/dev/null || :)"; fi
        if has ifconfig && has awk; then
            addresses="$addresses $(ifconfig -a 2>/dev/null | awk '$1=="inet" || $1=="inet6" { print $2 }')"
        fi
        if has sshd && has awk; then
            ports="$ports $("$(command -v sshd)" -T 2>/dev/null | awk '$1=="port" { print $2 }')"
        fi
    fi
    for port in $ports; do
        case $port in ''|*[!0-9]*) continue ;; esac
        for address in $addresses; do
            case $address in -*|*[!a-zA-Z0-9:.%_-]*) continue ;; esac
            result=$(ssh-keyscan -T 3 -p "$port" -t ed25519,ecdsa,rsa "$address" 2>/dev/null) || continue
            found=0
            while read -r server kind data comment; do
                case $kind in ssh-ed25519|ecdsa-sha2-*|ssh-rsa)
                    [ -n "$data" ] || continue
                    if has ssh-keygen; then
                        printf '%s %s\n' "$kind" "$data" | ssh-keygen -E sha256 -lf - >/dev/null 2>&1 || continue
                    fi
                    printf '%s %s %s\n' "$port" "$kind" "$data"
                    found=1 ;; esac
            done <<KEYS
$result
KEYS
            [ "$found" = 0 ] || return 0
        done
    done
    return 1
)

prepare_sshd() {
    # -A generates missing host identities and preserves all existing private keys.
    as_root ssh-keygen -A || return 1
    if [ "$(uname -s)" = Darwin ]; then
        as_root /usr/sbin/systemsetup -setremotelogin on || return 1
    else
        as_root install -d -m 0755 /run/sshd || return 1
        as_root "$(command -v sshd)" -t || return 1
        if [ -d /run/systemd/system ] && has systemctl; then
            as_root systemctl enable --now ssh.service || as_root systemctl enable --now sshd.service
        elif [ -f /run/openrc/softlevel ] && has rc-service; then
            as_root rc-update add sshd default && as_root rc-service sshd start
        else
            as_root "$(command -v sshd)"
        fi
    fi
}

restore_apt() {
    apt_ready && return 0
    if [ -x /usr/bin/apt-get ] && /usr/bin/apt-get --version >/dev/null 2>&1; then export PATH="/usr/bin:$PATH"; return 0; fi
    echo "正在恢复系统的 APT 工具。" >&2
    if command -v apt >/dev/null; then
        if as_root apt update && as_root apt install -y --reinstall apt && apt_ready; then return 0; fi
    fi
    if command -v aptitude >/dev/null; then
        if as_root aptitude update && as_root aptitude reinstall -y apt && apt_ready; then return 0; fi
    fi
    cached=
    if cached=$(cached_apt); then
        if as_root dpkg -i "$cached" && apt_ready; then return 0; fi
    fi
    if indexed_apt install && apt_ready; then return 0; fi
    if command -v python3 >/dev/null && python3 -B -c 'import apt' 2>/dev/null; then
        if as_root python3 -c 'import apt
cache = apt.Cache()
cache.update()
cache.open(None)
package = cache["apt"]
if package.is_installed:
    cache._depcache.set_reinstall(package._pkg, True)
else:
    package.mark_install()
cache.commit()' && apt_ready; then return 0; fi
    fi
    if command -v pkcon >/dev/null; then
        if as_root pkcon --noninteractive install apt && apt_ready; then return 0; fi
    fi
    echo "自动恢复 apt-get 失败。把与当前系统匹配的 apt 和依赖的官方 .deb 放在同一个空目录，再运行：" >&2
    if [ "$(id -u)" = 0 ]; then echo 'dpkg -i ./*.deb && apt-get --version' >&2
    else echo 'sudo dpkg -i ./*.deb && apt-get --version' >&2; fi
    return 1
}
# Preflight only reads the host and uses disposable package metadata. Every failure
# is recorded so a user can fix all blockers before running the same command again.
doctor_pass() { printf '  [通过] %s\n' "$1" >&2; passed=$((passed + 1)); }
doctor_block() {
    printf '  [未通过] %s\n           补齐方法  %s\n' "$1" "$2" >&2
    failed=$((failed + 1))
}

package_hint() {
    case $family in
        apt) printf '%sapt-get update && %sapt-get install -y %s' "$priv" "$priv" "$1" ;;
        rpm) printf '%s%s install -y %s' "$priv" "${manager:-dnf}" "$2" ;;
        apk) printf '%sapk add --no-cache %s' "$priv" "$3" ;;
        brew) printf 'brew install %s' "$4" ;;
        *) printf '请用系统软件管理器安装 %s，或使用 Debian/Ubuntu、RPM 系、Alpine 或 macOS。' "$1" ;;
    esac
}

writable_directory() (
    dir=$1
    case $dir in /*) ;; *) return 1 ;; esac
    while [ ! -e "$dir" ]; do
        [ ! -L "$dir" ] || return 1
        dir=${dir%/*}; [ -n "$dir" ] || dir=/
    done
    [ -d "$dir" ] && [ -w "$dir" ] && [ -x "$dir" ]
)

doctor_account_file() {
    if [ -e "$2" ] || [ -L "$2" ]; then
        if [ -n "$py" ] && [ -n "$payload" ]; then
            if ! reason=$("$py" -IB -c 'import sys; sys.path.insert(0, sys.argv[1])
from pathlib import Path
from pairing import account_file
try: account_file(Path(sys.argv[2]), replace=sys.argv[3] == "keys")
except (OSError, ValueError, RuntimeError) as error: sys.exit(str(error))' "$payload" "$2" "$3" 2>&1); then
                doctor_block "$1  $2" "$reason"; return
            fi
        elif [ -L "$2" ] || [ ! -f "$2" ] ||
             { [ "$3" = keys ] && [ ! -r "$2" ]; } || { [ "$3" = lock ] && [ ! -w "$2" ]; }; then
            doctor_block "$1  $2" '请确认此位置是当前账号可用的普通文件。若为链接，先按清单补齐 Python 和安装包以核验其目标。'; return
        fi
    fi
    doctor_pass "$1  $2 可用"
}

# These are tools Termlo installs. A missing tool passes only if its delivery
# route can be verified. Installer prerequisites themselves must already work.
doctor_component() {
    label=$1; shift
    packages_needed=1
    case $family in
        apt) names=$1 ;; rpm) names=$2 ;; apk) names=$3 ;; brew) names=$4 ;; *) names=$1 ;;
    esac
    if [ "$family" = brew ]; then
        case $names in '--cask '*) brew_cask=1 ;; *) brew_formula=1 ;; esac
    fi
    fix=$(package_hint "$@")
    if [ "$family" = apt ] && [ "$manager_ok" = 1 ]; then
        printf '  正在临时下载并校验 %s 软件包…\n' "$names" >&2
    fi
    if [ "$manager_ok" = 1 ] && package_available "$names"; then
        doctor_pass "$label 安装来源  已确认 $names 可用，安装时补齐"
    else
        doctor_block "$label 安装来源  无法确认 $names 可安装" "$fix"
    fi
}

apt_packages_available() (
    [ -n "$scratch" ] && has mkdir && has cat || return 1
    if [ ! -f "$scratch/apt.conf" ]; then
        mkdir -p "$scratch/apt-archives/partial" || return 1
        cat > "$scratch/apt.conf" <<'APT' || return 1
#clear APT::Update::Pre-Invoke;
#clear APT::Update::Post-Invoke;
#clear APT::Update::Post-Invoke-Success;
#clear DPkg::Pre-Install-Pkgs;
#clear DPkg::Pre-Invoke;
#clear DPkg::Post-Invoke;
Debug::NoLocking "true";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
APT::Update::Error-Mode "any";
Acquire::http::Timeout "8";
Acquire::https::Timeout "8";
APT
    fi
    # Work without sudo. A stale local index or an unreachable archive must not
    # pass. APT verifies downloads against the signed index, without running dpkg.
    routes='system cn'
    case ${TERMLO_INSTALL_NETWORK:-} in cn|cn' '*) routes='cn system' ;; esac
    if [ -s "$scratch/preferred" ]; then
        read -r preferred < "$scratch/preferred"
        case $preferred in cn) routes='cn system' ;; system) routes='system cn' ;; esac
    fi
    for route in $routes; do
        lists=$scratch/apt-$route
        if [ ! -d "$lists" ]; then
            mkdir -p "$lists/partial" || return 1
            if [ "$route" = cn ]; then
                arch=$(dpkg --print-architecture 2>/dev/null) && china_sources "$release" "$arch" > "$lists/sources.list" || continue
            fi
            if doctor_apt_get update; then : > "$lists/ready"; fi
        fi
        [ -f "$lists/ready" ] || continue
        doctor_apt_get --download-only --reinstall --no-remove --no-install-recommends -y install "$@" || continue
        # APT can exit zero if a damaged installed package has no downloadable candidate.
        set +f
        for package do
            found=0
            for deb in "$scratch/apt-archives/${package}_"*.deb; do
                if [ -s "$deb" ]; then found=1; break; fi
            done
            [ "$found" = 1 ] || continue 2
        done
        if [ "$route" != "${routes%% *}" ]; then printf '%s\n' "$route" > "$scratch/preferred" || return 1; fi
        return 0
    done
    return 1
)

doctor_apt_get() {
    if [ "$route" = cn ]; then
        set -- -o "Dir::Etc::sourcelist=$lists/sources.list" -o Dir::Etc::sourceparts=- "$@"
    fi
    apt-get -c "$scratch/apt.conf" -o "Dir::State::lists=$lists" \
        -o "Dir::Cache::archives=$scratch/apt-archives" -o "Dir::Log=$lists" \
        -o "Dir::State::extended_states=$lists/extended_states" "$@" >/dev/null 2>&1
}

package_available() (
    # Names and options come exclusively from doctor_component's fixed package lists.
    set -f
    set -- $1
    case $family in
        apt) apt_packages_available "$@" ;;
        apk) apk --no-cache --simulate add "$@" >/dev/null 2>&1 ;;
        brew)
            HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 "$@" >/dev/null 2>&1 ;;
        rpm)
            [ -n "$scratch" ] || return 1
            for pkg do
                if [ "$manager" = microdnf ]; then
                    output=$(microdnf --setopt="cachedir=$scratch/rpm" repoquery "$pkg" 2>/dev/null) &&
                        [ -n "$output" ] || return 1
                elif ! "$manager" -q --setopt="cachedir=$scratch/rpm" --setopt="logdir=$scratch" \
                        --setopt="persistdir=$scratch" list --available "$pkg" >/dev/null 2>&1; then
                    # The installer enables EPEL on supported EL derivatives when base repos lack a tool.
                    [ -r /etc/redhat-release ] && [ -r "$release" ] || return 1
                    . "$release"
                    major=${VERSION_ID%%.*}
                    case $major in ''|*[!0-9]*) return 1 ;; esac
                    "$manager" -q --setopt="cachedir=$scratch/rpm" --setopt="logdir=$scratch" \
                        --setopt="persistdir=$scratch" list --available epel-release >/dev/null 2>&1 || return 1
                    "$manager" -q --setopt="cachedir=$scratch/rpm" --setopt="logdir=$scratch" \
                        --setopt="persistdir=$scratch" \
                        --repofrompath="termlo-epel,https://dl.fedoraproject.org/pub/epel/$major/Everything/\$basearch/" \
                        list --available "$pkg" >/dev/null 2>&1 || return 1
                fi
            done ;;
        *) return 1 ;;
    esac
)

check_agent() (
    agent=$agent_dir/mutagen-agent
    if [ -f "$agent" ] && [ -x "$agent" ]; then
        if [ -z "$py" ] || [ -z "$payload" ]; then
            echo '先按清单补齐 Python 或修复安装包，再检查已有同步代理。'; return 1
        fi
        if "$py" -IB -c 'import sys; sys.path.insert(0, sys.argv[1])
from pathlib import Path
from sync_agent import correct_version
sys.exit(not correct_version(Path(sys.argv[2])))' "$payload" "$agent" 2>/dev/null; then
            printf 'Mutagen 同步代理  %s 已就绪\n' "$version"; return 0
        fi
    fi
    case $system in Linux) os=linux ;; Darwin) os=darwin ;; *) echo '请使用支持的 Linux 或 macOS 设备。'; return 1 ;; esac
    case $machine in x86_64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo '请选择支持的 64 位处理器。'; return 1 ;; esac
    while read -r target asset digest; do
        [ "$target" = "${os}_$arch" ] || continue
        name=mutagen_${target}_v$version.tar.gz
        url=https://github.com/mutagen-io/mutagen/releases/download/v$version/$name
        file=${TERMLO_MUTAGEN_ARCHIVE:-$scratch/agent.tar.gz}
        hint="请在可联网设备取得官方安装包：
             curl -fL -o $name $url
           将文件复制到远端，在文件所在目录设置：
             export TERMLO_MUTAGEN_ARCHIVE=\"\$PWD/$name\""
        if [ -z "${TERMLO_MUTAGEN_ARCHIVE:-}" ]; then
            [ -n "$scratch" ] || { echo "请修复临时目录。$hint"; return 1; }
            api=https://api.github.com/repos/mutagen-io/mutagen/releases/assets/$asset
            for source in "$url" "$api"; do
                if curl -qfsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 180 \
                        -H 'Accept: application/octet-stream' -o "$file" "$source" && archive_matches "$file" "$digest"; then
                    printf 'Mutagen 安装包  官方 %s 的 SHA-256 已核对\n' "$version"; return 0
                fi
            done
        elif [ -f "$file" ] && [ -r "$file" ] && archive_matches "$file" "$digest"; then
            printf 'Mutagen 安装包  离线包 %s 的 SHA-256 已核对\n' "$version"; return 0
        fi
        echo "下载或校验失败。$hint"; return 1
    done <<RELEASES
$manifest
RELEASES
    echo '请使用包含当前系统与架构的 Termlo 发行版本。'; return 1
)

archive_matches() (
    if has sha256sum; then actual=$(sha256sum < "$1") || return 1
    elif has shasum; then actual=$(shasum -a 256 < "$1") || return 1
    elif [ -n "$py" ]; then
        "$py" -IB -c 'import sys; sys.path.insert(0, sys.argv[1]); from sync_agent import verify_archive
from pathlib import Path
verify_archive(Path(sys.argv[2]), sys.argv[3], "Mutagen")' "$payload" "$1" "$2" >/dev/null 2>&1; return
    else return 1; fi
    [ "${actual%% *}" = "$2" ]
)

doctor_browser() {
    if [ -z "$payload" ]; then
        doctor_block '远程浏览器  无法读取试启动程序' '先修复上方安装包解压问题，再运行同一条安装命令。'; return
    fi
    if [ -z "$py" ]; then
        doctor_block '远程浏览器  缺少 Python，无法核验' "$(package_hint python3 python3.11 python3 python)"; return
    fi
    if browser=$("$py" -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import native_browser
try: native_browser.check_install_account()
except (OSError, ValueError) as error: print(error, file=sys.stderr); sys.exit(4)
try:
    if not native_browser.executable(): sys.exit(3)
    print(native_browser.check_for_install())
except (OSError, ValueError) as error: sys.exit(str(error))' "$payload" 2>&1); then
        doctor_pass "远程浏览器  已渲染测试页  $browser"; return
    else status=$?; fi
    if [ "$status" = 4 ]; then
        doctor_block "远程浏览器运行账号  $browser" '运行 getent passwd termlo-browser 核对账号。请管理员处理同名账号冲突，保留原有数据，再重试。'; return
    fi
    ubuntu=0
    if [ "$family" = apt ] && [ -r "$release" ] && ( . "$release"; [ "${ID:-}" = ubuntu ] ); then ubuntu=1; fi
    if [ "$ubuntu" = 1 ]; then fix="${priv}apt-get update && ${priv}apt-get install -y snapd && ${priv}systemctl enable --now snapd.socket && ${priv}snap install chromium"
    else fix=$(package_hint 'chromium chromium-sandbox' chromium chromium '--cask google-chrome'); fi
    if [ "$status" != 3 ]; then
        if [ "$ubuntu" = 1 ]; then
            fix="先修复或更新 Chromium。也可以安装可启动的 Google Chrome 后重新检查。
             ${priv}apt-get update && ${priv}apt-get install -y snapd && ${priv}systemctl enable --now snapd.socket
             if snap list chromium >/dev/null 2>&1; then ${priv}snap refresh chromium; else ${priv}snap install chromium; fi"
        else
            case $family in
                apt) fix="${priv}apt-get update && ${priv}apt-get install -y --reinstall chromium chromium-sandbox" ;;
                apk) fix="${priv}apk add --no-cache chromium && ${priv}apk fix --reinstall chromium" ;;
                rpm) fix="${priv}${manager:-dnf} -y install chromium && ${priv}${manager:-dnf} -y reinstall chromium" ;;
                brew) fix='从浏览器官网重新安装。通过 Homebrew 安装的 Chrome 可运行
             brew reinstall --cask --appdir="$HOME/Applications" google-chrome' ;;
            esac
        fi
        doctor_block "远程浏览器  $browser" "$fix"; return
    fi
    if [ "$ubuntu" = 0 ]; then
        doctor_component '远程浏览器 Chromium' 'chromium chromium-sandbox' chromium chromium '--cask google-chrome'
    elif [ ! -d /run/systemd/system ] && [ ! -S /run/snapd.socket ]; then
        doctor_block '远程浏览器安装来源  当前 Ubuntu 无法启动 Snap' '请在有 systemd 的设备上启用 snapd.socket，或安装可实际启动的 Google Chrome 后重试。'
    elif [ -n "$scratch" ] && { snap --version >/dev/null 2>&1 || package_available snapd; } &&
            curl -qfsSL --connect-timeout 5 --max-time 16 -H 'Snap-Device-Series: 16' \
            'https://api.snapcraft.io/v2/snaps/info/chromium' -o "$scratch/chromium.json" &&
            "$py" -IB -c 'import json,sys; sys.exit(not json.load(open(sys.argv[1])).get("channel-map"))' "$scratch/chromium.json" 2>/dev/null; then
        packages_needed=1; doctor_pass '远程浏览器安装来源  Snap 提供 Chromium'
    else doctor_block '远程浏览器安装来源  无法验证 Chromium 的 Snap 安装包' "$fix"; fi
}

termlo_doctor() (
    payload=$1; manifest=$2; release=$3; scratch=$4; interactive=$5; shift 5
    system=$(uname -s) || system=未知
    machine=$(uname -m) || machine=未知
    passed=0; failed=0; packages_needed=0; admin_needed=0; full=1; check_only=0
    port=22; key=''; claude='安装时可选择'; manager=''; manager_ok=0; brew_formula=0; brew_cask=0
    printf '\nTermlo 安装前体检清单\n' >&2
    if [ "$interactive" = 1 ]; then
        if ( : </dev/tty ) 2>/dev/null; then doctor_pass '交互终端  可用'
        else doctor_block '安装向导需要交互终端' '请在设备控制台或交互式 SSH 会话中运行安装命令。'; fi
    fi
    while [ "$#" -gt 0 ]; do
        case $1 in
            --check) check_only=1 ;;
            --sync-only) full=0 ;;
            --with-claude) claude='已选择安装' ;; --without-claude) claude='已选择跳过' ;;
            --port|--host-key|--host|--name)
                if [ "$#" -lt 2 ]; then doctor_block "安装参数 $1 缺少值" '补齐参数或运行原安装命令。'; break; fi
                case $1 in --port) port=$2 ;; --host-key) key=$2 ;; esac
                shift ;;
            --port=*) port=${1#*=} ;; --host-key=*) key=${1#*=} ;; --name=*|--host=*) ;;
            *) doctor_block "无法识别安装参数 $1" '移除该参数后重试。' ;;
        esac
        shift
    done
    case "$system/$machine" in Linux/x86_64|Linux/aarch64|Linux/arm64|Darwin/x86_64|Darwin/arm64)
        doctor_pass "远程系统  $system $machine" ;;
        未知/*|*/未知) doctor_block '远程系统  无法取得系统或处理器型号' '请恢复 uname 工具或系统 PATH，确认 uname -s 和 uname -m 都能输出结果。' ;;
        *) doctor_block "远程系统  $system $machine" '请使用 64 位 Intel/AMD 或 ARM 的 Linux 或 macOS 设备。' ;;
    esac
    uid=$(id -u) || uid=''
    priv=''
    if [ "$uid" != 0 ]; then
        if has sudo; then priv='sudo '
        elif has doas; then priv='doas '; fi
    fi
    if [ -z "$uid" ] || { [ "$system" = Darwin ] && [ "$uid" = 0 ]; } ||
       { [ "$uid" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; }; then
        doctor_block '安装账号  无法使用当前账号安装' '请使用平时登录这台设备的 SSH 账号，直接运行安装命令。'
    else doctor_pass "安装账号  UID $uid"; fi
    config=${XDG_CONFIG_HOME:-$HOME/.config}/termlo
    mutagen=${MUTAGEN_DATA_DIRECTORY:-$HOME/.mutagen}
    version=${manifest%%'
'*}
    agent_dir=$mutagen/agents/$version
    for path in "$config" "$HOME/.ssh" "$HOME/.local/bin" "$agent_dir"; do
        if writable_directory "$path"; then doctor_pass "安装目录  可写入 $path"
        else doctor_block "安装目录  无法写入 $path" "请确保 $path 是当前 SSH 用户可读写的目录，或恢复其上级目录的写权限。"; fi
    done
    if [ -d "$HOME/.local/bin/termlo" ]; then
        doctor_block '命令安装位置已被目录占用' '请移动该目录后重试：mv "$HOME/.local/bin/termlo" "$HOME/.local/bin/termlo-directory"'
    fi
    if [ "$system" = Darwin ]; then family=brew; else family=$(linux_manager "$release") || family=unknown; fi
    if [ -n "$payload" ]; then doctor_pass '安装程序  可读取'
    else
        if [ "$family" = brew ]; then unpack_fix='请恢复系统命令路径：export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"'
        else unpack_fix=$(package_hint 'coreutils tar gzip' 'coreutils tar gzip' 'busybox tar gzip' ''); fi
        for tool in ${unpack_missing:-}; do doctor_block "安装包解压工具  缺少 $tool" "$unpack_fix"; done
        if [ -n "${unpack_error:-}" ]; then doctor_block "$unpack_error" '检查临时目录可用空间和写权限，再运行原安装命令重新取得完整安装包。'; fi
    fi
    case $family in
        apt)
            if apt_ready; then manager_ok=1; doctor_pass '系统包管理器  apt-get'
            else hint=$(apt_recovery_hint "$priv") || :; doctor_block '系统包管理器  apt-get 不可用' "$hint"; fi ;;
        apk)
            if apk --version >/dev/null 2>&1; then manager_ok=1; doctor_pass '系统包管理器  apk'
            else doctor_block '系统包管理器  apk 不可用' '请从对应版本的 Alpine 安装介质恢复 apk-tools。'; fi ;;
        rpm)
            for tool in dnf yum microdnf; do
                if "$tool" --version >/dev/null 2>&1; then manager=$tool; break; fi
            done
            if [ -n "$manager" ]; then manager_ok=1; doctor_pass "系统包管理器  $manager"
            else doctor_block '系统包管理器  DNF/YUM 不可用' "请从同版本发行版取得管理器及其依赖的 RPM，在该目录运行 ${priv}rpm -Uvh --replacepkgs ./*.rpm。"; fi ;;
        brew) if brew --version >/dev/null 2>&1; then manager_ok=1; doctor_pass '系统包管理器  Homebrew'; fi ;;
        *) doctor_block '无法识别系统包管理器' '请使用 Debian/Ubuntu、RPM 系、Alpine Linux 或 macOS 安装。' ;;
    esac
    if bash -c ':' >/dev/null 2>&1; then doctor_pass 'Bash  可执行'
    else doctor_block 'Bash  缺少可执行的 Bash' "$(package_hint bash bash bash bash)"; fi
    py=$(find_python) || py=''
    if [ -n "$py" ]; then doctor_pass "Python  $("$py" -V 2>&1)，TLS 和压缩模块可用"
    else doctor_block 'Python  需要 3.8 或更高版本且含 TLS 和压缩模块' "$(package_hint python3 python3.11 python3 python)"; fi
    doctor_account_file '安装锁文件' "$config/install.lock" lock
    doctor_account_file 'SSH 配对锁文件' "$HOME/.ssh/.termlo-pair.lock" lock
    doctor_account_file 'SSH 授权文件' "$HOME/.ssh/authorized_keys" keys
    for record in connection.json installed-components.json; do
        if [ ! -e "$config/$record" ] && [ ! -L "$config/$record" ]; then continue; fi
        if [ -z "$payload" ] || [ -z "$py" ]; then
            doctor_block "已有文件 $record 无法核验" '按清单先修复安装包或 Python，再重新检查。'
        elif reason=$("$py" -IB -c 'import sys; sys.path.insert(0, sys.argv[1])
from pathlib import Path
from termlo import saved_connection
from uninstall import Receipt
folder = Path(sys.argv[2])
try:
    if sys.argv[3] == "connection.json": saved_connection(folder / sys.argv[3])
    else: Receipt(folder)
except (OSError, ValueError) as error: sys.exit(str(error))' "$payload" "$config" "$record" 2>&1); then
            doctor_pass "已有文件 $record  可读取"
        else doctor_block "已有文件 $record 无法使用  $reason" "请检查 $config/$record 的内容、所有者和读写权限，然后重试。"; fi
    done
    if curl --version >/dev/null 2>&1; then doctor_pass 'HTTPS 下载工具  curl'
    else doctor_block 'HTTPS 下载工具  curl 不可用' "$(package_hint 'curl ca-certificates' 'curl ca-certificates' 'curl ca-certificates' curl)"; fi

    if [ -n "$scratch" ] && [ -w "$scratch" ]; then doctor_pass '临时目录  可写入'
    else doctor_block '临时目录无法写入' '请恢复 TMPDIR 的写权限及可用空间后重试。'; fi

    ssh_fix=$(package_hint openssh-client openssh-clients 'openssh-client-default openssh-keygen' openssh)
    missing=''
    for tool in ssh scp ssh-keygen ssh-keyscan; do has "$tool" || missing="$missing $tool"; done
    if [ -z "$missing" ]; then doctor_pass 'SSH 客户端工具  ssh、scp、ssh-keygen、ssh-keyscan'
    elif [ -n "${SSH_CONNECTION:-}$key" ]; then doctor_block "SSH 客户端工具  缺少${missing}，无法核验现有连接" "$ssh_fix"
    else doctor_component "SSH 客户端工具（缺少${missing}）" openssh-client openssh-clients 'openssh-client-default openssh-keygen' openssh; fi
    if has ssh-keygen; then
        if [ -n "$scratch" ] && ssh-keygen -q -t ed25519 -N '' -C '' -f "$scratch/pairing-check" </dev/null >/dev/null 2>&1 &&
                ssh-keygen -E sha256 -lf "$scratch/pairing-check.pub" >/dev/null 2>&1; then
            doctor_pass 'SSH 配对密钥  可生成 Ed25519 密钥并核验指纹'
        else
            case $family in
                apt) fix="${priv}apt-get update && ${priv}apt-get install -y --reinstall openssh-client" ;;
                rpm) fix="${priv}${manager:-dnf} reinstall -y openssh" ;;
                apk) fix="${priv}apk fix --reinstall openssh-keygen" ;;
                brew) fix='先确认 /usr/bin/ssh-keygen 可用，或通过 Homebrew 恢复：
             if brew list --versions openssh >/dev/null; then brew reinstall openssh; else brew install openssh; fi
             export PATH="$(brew --prefix openssh)/bin:$PATH"' ;;
                *) fix='请修复系统 OpenSSH 中的 ssh-keygen' ;;
            esac
            doctor_block 'SSH 配对密钥  无法生成 Ed25519 密钥或核验指纹' "确认临时目录可写。若设备策略限制 Ed25519，请向管理员确认该设备能否用于配对。OpenSSH 损坏时可按以下方法修复：
             ${fix}"
        fi
    fi

    case "$port" in ''|*[!0-9]*) valid_port=0 ;; *) valid_port=$port ;; esac
    if ! { [ "$valid_port" -gt 0 ] && [ "$valid_port" -le 65535 ]; } 2>/dev/null; then
        doctor_block 'SSH 端口超出范围' '请将 SSH 端口设置为 1 到 65535 之间的实际端口。'
    elif keys=$(scan_ssh "$port"); then
        doctor_pass 'SSH 服务及主机密钥  已从本机 SSH 端口取得公钥'
    elif [ -n "${SSH_CONNECTION:-}" ]; then
        read -r client client_port address internal_port <<ENDPOINT
$SSH_CONNECTION
ENDPOINT
        doctor_block '当前 SSH 会话的本机端口未能出示主机公钥' "请确认 sshd 正在监听，修复后用 ssh-keyscan -T 3 -p $internal_port $address 验证。"
    else
        admin_needed=1
        if [ "$system" = Linux ] && ! has sshd; then
            doctor_component 'OpenSSH 服务端' openssh-server openssh-server openssh-server openssh
        elif [ "$system" = Darwin ] && [ ! -x /usr/sbin/systemsetup ]; then
            doctor_block 'SSH 服务配置工具不可用' '请在系统设置的「通用 → 共享 → 远程登录」中允许当前用户登录。'
        else doctor_pass 'SSH 服务配置工具  可在安装阶段生成主机密钥并启动服务'; fi
    fi
    if [ -n "$key" ]; then
        if [ -r "$key" ] && ssh-keygen -lf "$key" >/dev/null 2>&1; then
            read -r kind blob rest < "$key" || :
            case "${keys:-} " in *" $kind $blob "*|*" $kind $blob
"*) doctor_pass '指定 SSH 公钥  与服务一致' ;;
                *) doctor_block '指定公钥与 SSH 服务不匹配' '去掉 --host-key 后重试，或提供该端口实际出示的公钥。' ;; esac
        else doctor_block '指定的 SSH 公钥不可读或无效' '请修复公钥文件的路径和权限，或去掉 --host-key 让安装器自动识别。'; fi
    fi
    agent_target=$agent_dir/mutagen-agent
    if [ -d "$agent_target" ]; then
        doctor_block "Mutagen 同步代理  可执行文件路径被目录占用" "请将 $agent_target 目录移到其他位置，再重新运行安装命令。"
    elif agent=$(check_agent); then doctor_pass "$agent"
    else doctor_block 'Mutagen 同步代理  无法验证安装来源或版本' "$agent"; fi

    if [ "$full" = 1 ]; then
        if { [ "$system" != Darwin ] || [ "$(command -v git || :)" != /usr/bin/git ] || /usr/bin/xcode-select -p >/dev/null 2>&1; } && git --version >/dev/null 2>&1; then doctor_pass 'Git  可用'; else doctor_component Git git git git git; fi
        if tmux -V >/dev/null 2>&1; then doctor_pass 'tmux  可用'; else doctor_component tmux tmux tmux tmux tmux; fi
        if adb version >/dev/null 2>&1; then doctor_pass 'ADB  可用'; else doctor_component ADB adb android-tools android-tools '--cask android-platform-tools'; fi
        doctor_browser
        if [ "$system" = Linux ] && [ "$uid" = 0 ]; then
            if has useradd && has runuser; then doctor_pass '浏览器运行账号工具  可用'
            else doctor_component '浏览器运行账号工具' 'passwd util-linux' 'shadow-utils util-linux' 'shadow cmd:runuser' ''; fi
        fi
    fi
    if [ "$family" = brew ] && [ "$manager_ok" = 0 ]; then
        if [ "$packages_needed" = 1 ] || [ -z "$py" ]; then
            doctor_block '系统包管理器  缺少可用的 Homebrew' '运行 Homebrew 官方安装命令后按终端提示配置 PATH：/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        else doctor_pass '系统包管理器  当前组件均可复用，无需调用 Homebrew'; fi
    fi
    if [ "$brew_formula" = 1 ] && [ "$manager_ok" = 1 ]; then
        if cellar=$(brew --cellar) && writable_directory "$cellar"; then doctor_pass 'Homebrew 软件安装目录  可写入'
        else doctor_block 'Homebrew 软件安装目录不可写' '请使用拥有 Homebrew 安装目录权限的账号补齐上述软件，再回到当前 SSH 账号重试。'; fi
    fi
    if [ "$brew_cask" = 1 ] && [ "$manager_ok" = 1 ]; then
        if caskroom=$(brew --caskroom) && writable_directory "$caskroom" && writable_directory "$HOME/Applications"; then
            doctor_pass 'Homebrew 应用安装目录  可写入'
        else doctor_block 'Homebrew 应用安装目录不可写' '请确认 brew --caskroom 指向的目录和 ~/Applications 均可写，或请管理员安装清单中缺少的应用。'; fi
    fi
    if [ "$packages_needed" = 1 ] && [ "$family" != brew ]; then admin_needed=1; fi
    if [ "$packages_needed" = 1 ] && [ "$family" = apt ] && [ "$manager_ok" = 1 ] && ! dpkg --version >/dev/null 2>&1; then
        hint=$(apt_recovery_hint "$priv") || :
        doctor_block 'Debian 软件安装工具  dpkg 不可用' "$hint"
    fi
    if [ "$admin_needed" = 0 ]; then doctor_pass '安装权限  本次无需系统提权'
    elif [ "$uid" = 0 ]; then doctor_pass '安装权限  当前账号有系统安装权限'
    elif [ -z "$priv" ]; then doctor_block '安装权限  当前账号无法安装系统组件' '请让管理员以 root 身份补齐上方软件，或配置 sudo 或 doas 后回到当前 SSH 账号重试。'
    elif "${priv% }" -n true </dev/null >/dev/null 2>&1; then doctor_pass '安装权限  已验证系统安装权限'
    elif [ "$check_only" = 0 ] && [ "$failed" = 0 ] && ( : </dev/tty ) 2>/dev/null && as_root true </dev/tty; then doctor_pass '安装权限  管理员已授权'
    else doctor_block '安装权限  尚未取得系统安装权限' "请在交互式 SSH 终端运行 ${priv}true 完成管理员授权，或请管理员按清单补齐组件。"; fi
    if [ "$full" = 1 ]; then printf '  Claude Code（选装）  %s\n' "$claude" >&2; fi
    if [ "$failed" -gt 0 ]; then
        if [ "$uid" != 0 ] && [ -z "$priv" ]; then printf '上方涉及系统软件的补齐命令请由管理员执行，之后回到当前 SSH 账号重试。\n' >&2; fi
        printf '体检未通过。%s 项通过，%s 项未通过。按上方方法补齐后重新运行安装命令。\n' "$passed" "$failed" >&2
        return 1
    fi
    printf '体检通过。%s 项全部通过。\n' "$passed" >&2
)

manifest='0.18.1
linux_amd64 232224465 7735286c778cc438418209f24d03a64f3a0151c8065ef0fe079cfaf093af6f8f
linux_arm64 232224500 bcba735aebf8cbc11da9b3742118a665599ac697fa06bc5751cac8dcd540db8a
darwin_amd64 232224335 7d06f7d8fcfe90bc7e55cc834a2f2f20c2e0af9ea9bc35911fc4341ad56a9bbf
darwin_arm64 232224354 6f810416d9e5fc4fd5e18431146f8b3c5a2056ba5a24f76c1e66da86eb3257e2'
scratch=''
if has mktemp && has rm; then scratch=$(mktemp -d) || scratch=''; fi
if [ -n "$scratch" ]; then trap 'rm -rf -- "$scratch"' EXIT; fi
interactive=0
if [ "$#" = 0 ]; then interactive=1; fi
termlo_doctor '' "$manifest" /etc/os-release "$scratch" "$interactive" "$@"
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
H4sIAAAAAAAC/+y9eXdb1bkw3r/1KXZOnEoKljxkABzUW5MY8NtMKzEdruNX61g6ttXIktCRkjiO
7wqlmSAT8xQKtAlQKElKKQkZYK3fR7m1ZOcvvsLvGfbeZ+8zyA635d71XtKS6Oyzz573Mw/T9XrL
bzXdRt6f+8m/6M8g/Nm+dSv9C3/C/w4/un2L+s3lQ4Nbhrf/RAz+5Af40/ZbbhO6/8n/zj8bNwxM
V2oD/lzK91oi57VTfr3dLHnFcqVZ6Mvs3LV/dOKZgiiVRS4nnL4MFNfceY+fBp2sI376U9E4Ws6m
8lAQfDvQWGjN1Wu5ZrvWqsx7cLqcSI2m1/Sea1f8Ssvz4yqU66VWvUlv/AW/5c3DgNrcuy+GfzZQ
9o4M1NrValacOCFkjXQ6VXJ9T/Txs6jUxC63ebRSywqaiTNQb7QG5urz3nTTO4pzHxlo+82Bar3k
VumxD+s5YscOsVl9Q0Vcz6cv8G+q4vluKeUda9SbLVX3mX17xgbyRntcUGvM52ar9WmrFznWxaGR
3BIMNSXgT27uRC4351UbWXrEP41mpdaaEelN/qFaWqT9OagLx7ZahbURk7lcac4rHZ7CX3N1vyU6
V2523jtJzzSwzo2vO1ffWPnsRufSn3St3GFvQSzfvtu9cqdz6i8PXrlGb2h1O5cvrHx8cyotDukR
4J+0sP5A7aOV1lyuVHXbZU+cEPxcb7fMIn+hVsrVa9WFqcjA2zX5gE0d9rxGrlWvV/2ptO7VO1Zp
iUFYZyrR9WF99O9gkfy5ykxLP8GCeU04YfA3nJqZSq1c5BNJh2VReKW5ukh3LtxevX//wZWTqx89
L/bTe7El/5jonn2j++6XDz57a+Xc2e6Vv/zj5O9Wb9xa/fby6ofnhT0Jufii+/61lSsvQV1Yz5V3
fq8a61w/t/qnU52X7y/fvQqtpMXPfjq8g+c1tEMsGTP1SnD4jVE7IvekfR2gcL5azzcWHGPpnL6f
40FM0UH0S023VZqDCc8fhsPfELky3w1ZDpejMiMmRa6GLXOhI6Z2iNacVxOIBUS6OS9yzRm+36pK
Woz9enxih5ippGiEbqlVOeIVBrk1p2+jIwqwT6ohs84QfcVDL/KFtmblIFApuS17qvPtljvrAfTw
qh7cED/fOtZCWDPgtUoDdV+Vm7OQi8fdOrQuqRnozG3OinKdhgk/HbGhoPdsCteGz9gOqFPzEuZD
m/MEgZtWayFYhjWPlzoEt75Yvn2hc+nGymuffHfvPBylB2cudN+4yQfKPCLdP53Eg3TxRuePL8Qd
lzVOyLRG5nhIjMUxT0vKgv/mJ/9N+H9weEsU/28Z/hH//xB/HMfZWQcUXWt7eNjFdLtWrnpldWI8
uEAzcNZEpeWL/fsOjv8akJE3U63MzrWEWysLid8FUA/tRh5aS1XmCekA/k2lZpr1ecGXX8jyeRfw
XAr/zuiWiNiAD/JwQ4/kG/VGZiibTf3kxz//+j8RMu2Hv/9Dg9uHQ/d/aMvgj/f/B/ljoK5MViwS
QYJo08AzSENzjS3q3/zQ1uCnUToc/BwKfg7qn4/rX48hxtXkT6k+P4/QJHckTAQFVD5Q/D8dQuxa
kvAqoPUYa2cSW8kiPifyHXkdNZcpZF3oQ8VUUD1mFxTytyhg3cSxUr3s5XygQkrANDXWNUqgGtTP
MBoff1LkSiKtIKdf7Ufw2S+OVyvTO/BnHkmADP444jX9Sr1WrNRm6uIJkdnSLx7LZtPrGoHNRtiD
0JXgsd2siUEqIKLIKB1KLf0Ilv/fgv8hJvyHp/+Gt25/dCgM/4eHHv0R/v8g8h9J1aHAAUALcLdu
E8i/6QWiBjUV2E8EYNNzy8TMC2KgfKIAzXplsXP3eD415/qITGywPhQB5sjRpKoAoo4VoRowfE34
KpPSID2HrCLKRkJs35ITgc75pJoBiiF+UfQtju9CYQv+W9w9/osxfHCU7EX92eyIsjddcYFP3nwC
HtpAFrfa8JBlzs5ttHYomCilE8anbrVRqXlm7cM9as945XrTlR01YR/kz5JXa9V9+eDSMqmH+eO1
oPVmYz6udRIIGHgHVhS2BUeem/VaiB/wsdw4PKu4XDkxqu1VZf1ybUbVXWjPq5/zlVKzDq/MT2Ec
9qc0bbPpw/I9bITCJ8RMZ1Mp1y82gRPVJIhC6RU4PO2szY4TE2v15LfLdfkSf8bUKNddX9bAn2YN
GA2Nz+l+frX76oXl+1dYHrRy/cOVy6c7L7/Vfe+FB29fljKg638Oys99DOz78v1XgWtfvv155+yb
nTMo+9HSHofZd2uucOJhjYt4kxbojpibAvSI+pnLSUwfe2k2iifrrTm6enQTqxW/Fb6Mbgu/bvvE
18HfZajTrEy3sTjnV2ZrcFtZduDnU6W5Ss0tykd9C+UVhJtLohJNBKgbN8Rr6LcBeRT6Fn85duDg
+L69xZ37do3tHd2DV4veu02USQ2n9DXsoy+QrkynT0xucHPHp+Bg04/B3OO5KTjaqi8tZA0+xubM
b+GT9X0+X2k2683CXKvV8EcGBvjRz7eA/Mu3/Eptdq7t5r1yO1+qGd1JgGFACAYNWesi46BQ3tXH
rQ5wHSDevFK7WWkthF7kVLnVCMDLBlBctZZfQAZ5hzjsLQDNNltg0TOC5gFZ5KuGZMc5WZ6fbcya
YIAhlz1Wexnd+fL2rScqWx7bno3MQsI9loXHvyQRs2+ts5bI6rnLT3eYM0zjFGGj8FSWWnAY27UK
nnlPzLerLf6ZttrrtRpyMGushn0yUhacrDfwZvgFh48rLQ9fk9w0TEG2yCdeUdKwB2Jykz8lNvn8
fyasZVMOyRxpQCSNw0OPP4JFcAwRe8/Pcu1G2QUKbZ2fq5UPvjdLjAYQ9pZcgCHlIkAeffEVakCI
pH7ncLJhKMBrlaG6uRwtC+9BCzijdtPLRr6QYE1+lHuu7TUXRO5XIjdTSAMI4bdLaQSEER2P+jad
1nwqDgqO0cARtzlAExmADwfk8vn4UNych0oWuwlwbQbWAYolZIuwSoR89KyD2vvd0mEgVAgj4QgD
HjKm8qi5EPgF72tyn7njUEVOUtZKalsulGzW/mZNxg9b2LEWp5dFNHPAK9WPoBAQ5goUoFedESzT
m7MRShqQWBvRa6tScvEyN3ihYG/K3jHEMBvFxFwFUHWrAojsaL0J1ONRRMfTiMiweURfCvvNuUc8
Me15CB/mYQBl7tUVv9x/MJ/iNqMnFr+mM2AeW/XbPXo4chZhxY8xUw+MNh8caIJJYV5Kxs9wdaqq
HYA7w9u2+20gupZikGKIAF0PHgnjJSjO86t8vTkr4XwMTJft9rp8IfAe6kjekjy3lwewYAP8UHUC
9NHKNgJYL7TdKPYhH+GWSh7uvVAanYaLxwGOQrkyC6ghOG0+imgQclW9lqePF1A6teNuntG713IB
SLoAWoKTkKuLXZXmyMhOfBoZgaWi8kL4hd8sBe/8ufrRMAASJ/S88CgBS3PgIAAikV60cNRMpeoV
HLhdcE7gX/sdwKtMpTC0o/LE3qd2VB55RFG75h8gWDN9lULBeQpaQrnUiJPlVoEafmQom/zBwWdG
4WRidew7pvZSKvwdtiv+Qwz830a9Xj00gBj50IB7CK8B/VWcnBxxq7X2/MhU/pGRTf9RzE09cggP
Z98A3gcY4GxrLgPdZQuF7VuxCH5Tg5NubmY09xTSZo/0DcRNlM4rzawfPmItV8Jwl9JZdV+R/Fcb
HUeWImGNVOuMXD11jp54Ys/YxGhKf5uiR4PVCOn8ApA5YCB2vhGIQ1X7+Ju70BB1h2K5ylAa0cVa
o42qXPEbqW81GOEeUCrECCfVK9eP1qp1YN9py9VMBux5QN/4TZ4wjDpPanqRwSPrFLDXCCJzz83s
JkhUb9VFmgFHWhUASCxXmmYxtAa4fxivYqTzmAGG+6erCIDOrcIia7Asngg3llU4epFrb9okNi8x
3lRTi54juYWSL2VMkquEmybWldg5QpMLRWCjLCZ2g/wymZuzdi9k6AEM58prn3Qun2czBLGLUMHA
swykgdXsvv5y99KXrC/unv/d6v37nYvvr/zt7srd97+7d77z9VedS290vnmzc/7rB6cudP/wVfcP
v0fjBBzTP04+jxCuc+nF5W/eW/37G8i4Xn+r+8bXAmeG3O5L13Rjsu0rn4iB+VoLm77ySfe1b1bu
X1/99u3lO+92zp+C71fevd65//ry3WuaRV6989ny3fvScEKuBK5nAZvB9cwPbJbdpcMS6KGAg8eB
rrGExtJhbSaXceP5WSnAcwt07tQjwjm62ENOwM6qListNGJ5qH75k1DnXBh0CmNI7hcWo4AGEYok
z0a60Udxk+8YjdBx1M0YuNCglrKh46aAJd5dBNzJQPL7gCLzQOMxvvQynAI4yStf/rFz7/Xl25/j
Af7gwwefnu+cvNd9/o+dqxe+u/dOpmyDTFjF9cG0TSjVKQcgRIIvKKaNMG5wABl4/WD6xCjNucZu
RCCcOZ3OpRvLdy/qGa3eh8evuncu8yzgNHfPvdR58RN58GOmVCrjQMh4jiHnzO59gofKwij4Dc8A
9AKCE3VEOXsym/zYKSzC48aNmweWHHU6gpKwPkqLyJRaDO355M+cpZeCVUubFFE87IKR68+tb4H5
L+DCE8GVgaNYyvNF4d/1hlfDX41CafKQgxfEmcLyYtlr0HXI+x4CWnmLMo18ERahX0w020jozohG
vuIXA0E0CfYa+Xm3eViVckcolK4AkE4fqoUvHy3DYWCfaBHoB3AjALGqnh/RsP30pzHcYoidLU+P
HGy5rbaf43+ifC0inhHi4mr1Vi4Y/lQiZuBx5XK1es2weBIxIC2KpVUrcHjZVE0fYUAHjGQAITCi
QKvBO69ptMBmSst3X1r98hPEKmfu0FQ6r5zvnjv54MpJjUUIfwCKAPzQOXVt+fbJ5dufrvz5DiMH
uBqAOlZvXONHeUGCAy3xQawk1JpWBFGwbHWj2N+sT3uClBQtZDjnXZRtenlgPz3hlstNz/eJlRH1
GWIsDh58RvhQiCDebXpShAoLW3Or0B6KVr0aakC8I2jbxh/tAU4HoCccSx/4Yihq1tuzwLgAuTkz
4zWBDxaN9nS1UhJ7RycEdpdP+SW3VvT9OYtnhWcUVuG7GFoWjhP0DuADdRvDw0sGSYiE8CKMvbhz
3969YzsnxvftBfYyqhlRML5UreCo+J8iX0peDRoewP6xvbv27xvfO5Hqs5tN6RchAaL8HJhMFr6O
5v4d6P2R/CZgEzafyG0+kU4nSGLpLCLbWOjDfwJyjpv0oFz+jDnD/J1eHOsW6lK8UcPDTNjxF04f
M6rDw05Mf+mh4Ufzg/C/ITEyMpQ2acCNYhRFKj5AAX3L5l04Xm4TzyfsuevN11GS0Qa+lU9eHYp3
j+7lgzTjlrx+2RSwgGguDOvnAuT3W/V5fdh4H9RRgnOTF3s9FL7Q4cBTJ48UG/DmjcNwfJ2HQcI4
/BxpaklbBKvg9Onfoi+jqonceAzI2mFaNMiGKzOwUDMVU+gSQxQk9ae/zrl2f8Rxp/uGgMmFq8ys
iH7a7ohFyUz2DSOr6MSZXChNkT9X7j04+7D0ZWy7EvweoHVuInGA+N2aI1L/wGmgTYcrxB3aVjF0
zVSFdBp1HKTsyGoRX+RWkclrcDGD9bVajr3EOaVEse5xj74YvPjtKnK5JiCD5dmCZjG8irBcLeGV
h7dtG3q83yuVfbe/6btC770TkfNGBJg8M7hehUGr7OgcUn4KxPleE6/L4QqKj4B8Jf0zQLvI1IPp
U12YO45eDvEEDTGHZBesCL6A0UbFLoY8wpBFxI48egZxpWa9Wszxi6M2DQEEjtfRXZ4w2hK5MUkq
ilx1BgjF9VgE2ZKr1JqD0OPgfQ2NJ75Z2rah2MODQmdAPL8Y+83BVB+fpBQ92Ivs9FEjUkBjoMng
MGjxdawcu9H0GoDaEfmWNXe+UeRGgbwD1I6KFTFf8VEFSLBRVMooyW5VPDZxgO/pbMETrKZ3DEgC
rApLcwQZPTz2eUtcYG7LaASvK+X2eszOVIva+WSAHVvI3ha+9VooIW951fosfF2v9ZbSqNY0Kwr3
Zl4MPrptmxhotqFtBI+xchb5YTw0bMV+w6ipLFumUZflv6w3octAz6VWNQ5PqNVUdYRXc6erHhG/
R7H3PG5LpeRh/2vXLqvqBoPHg5zhQSIP0iwN+PWZVhUwbzUYZrOUk9/2GCdUkqw/QDZGNWVvxoVT
TfRsUEuNmqqg/VErmeXstfIxaAVoYFSp1uG0s3qED7u2OcCRWLfH4urxfCm6e0qz3mbpWuIQyxdK
fS29nQKVk6YdlOXFn1CgRMwzC5yQjxjdPyE6t651Tt1SthRqwMZCIA+SyJKiHEcuny0UMkuTRUOS
C+GFk/OLzCAwr7FHxVKfdQ4tLDeKvApLjx5maCxMKuhh8mOMkClucIHYhKs7D7kohvRJr/R6WrDX
U0kUjDP3fcUUxtzi5RSsD2f9rhJWcJmWV8hHElnsBYSTTSl9VIGXdxIFGM4U+hPJN5ZwYiTYl2T5
hvzOkHKkEDjwt+qtLd6Q49ISju9/gFnIsK5FXFMc8TCjYHiweubTzosSHmg5QOfqX1e/vIaytRdf
XL59sXP/1c45CS1Yvo0wQ4ok4kTaAgUSV1CaHpJJoDj79AUWRXx37x0L0iQaobGD13rEFmndXmBr
liYztXV/rVfpn2+GrX1s/4U2pr3tfx8dHNqy3bb/HXx0+4/+Hz+Y/a/25yLRBd5Sn6QNRAkjPGgj
e16u+I26TwSVAnZKTZAXY6j8EjNupdpueqmNooK2wqV6s0w2hsLFJpoCWcOZyjEioqer9dJhNDie
9oBl9dCPrIY0tanqJ2DkzrqVWj7F57TYcH02LVZsCfAHD06+s/rtmSnNmwxJu0usS4guw7/EI2Io
m0X7SdkYjUGTSEaL3Sufmo0a1Njqh9ce3L8MIKX7t9eF2aPTNxwADlwI7pl/cc9Im8mls/WEzIrO
uPMVWH/DPgQxs61fItgQUi9RmUEdbPKJQQPexDH+HXJMy4xmY95seZOf3MCiNM0eyZVrM0tyokZT
buOwPcjDRP0iQpAmGHZ7W6yv0Qk/+Byf9Ej4s61OyKJE1WXdKMN/1r9IrePbn7CoGhpAKfTZN5bv
fws1beXpP04+f2D/HgGfw69RtteGqigt3neQPG/NJSPGFXbvaLPSwhuA/ooeHqEFLculcAlDxnai
rhsN02DIbE0TKwhlAcak2CByHumjmyS0s2zV4N1u/S6W06LOF+HvTQObl3ZosYT+AN8P2OwxcWa6
DinIc0fDBcd0AXLR8ta4pRJw460iKt1se22awrA2XKNRD8cKIeUI0UtZ9UXP7gLq85xYVSJp0wE6
+WQ8yB+HPacWfHaXQiuiPBwkr9nKDJIzFbmWTg5NZdknFStUK9PKKXU/PKoXFTTzVC/MyaZazYUR
qySD32V068NT2X4YYaPqljztzjq5ZUoUCsJBIYEDJNwxMnjK7Ds4hvYN/eKXbrXtyd8H2AuTnrJA
YQkPf40YHmCtZobK0OXLWC9aZ7pbyIplE+RKJtjD8y0Ef8aLqtmzVIJUSDHLu61d3sBGibLA7nOR
6KctSDnh9NVeb2Czcj4aS2xmpyvS4IKKR4OKMbOKnxHBhg+vr16/2v386vL9Cyv3r3ffusEE4+qX
H3Uu3WJffNQ/v30dIH33jTMAP9jmYfn2nQevftO9eA3JwlNnu+fPdW+f6lx4nSG/juvwivLbP39q
+e617ge3UY196iugKLsfnEEAEllNm9A18JkauOBROazHmiCjfVJIYVQMMSG9qBk6+nkxqkVWWIGx
nc84HPmuFqBs2DFEzNBas94GlIEIeNpDM9rKTMUr58W49vK2/MBwoed9r4oSr/k2UgFVFh6g3abG
xdqMWEOBqjvtVQEM7jCCcUiM5xdrngfkQGFobZSHYjEfmkFISZhKFgxjAeEbWbAFCxiFyJKtEtga
Tdh2h5Km557xvBHOCcMbHh41QqL3HKAy/7BIQ8tYv4hPLNNUJUDEzLerbkjQqff8GIAsE/eTA0o2
fkSWXbHEvsX6YXw1lKgXFoKFKMu3v+y++dXy7ZfQXufrr9i+AiW3jCPhuP7nyY+YaqHpGURLxRxO
pF9iuOUM3CNA1hApqFoJjco+3XQsZCiU7nvXuncuC4yJwVdULbMOjyHrvfkV37gYLXbo1sc1333z
A6DQIj1wJbbfO+YYMjPkT/VJ1dMzHWHskClKLjh/GPG8fMAwJrGyXgkj5edkfoKariie4+ZIc2JU
zmlz9obbbFXcarwtHHb/s9hunngiPbp/Im19tbFU9dwmCtlGRp4linJkBFiB3HjtSP2wtyP+PcYN
WmeF3MF2qeT5vq64a//hWdUFQZ0cFMS/tjqQL8yugZRrQ9ne+m44AQgBnVaz7TnwIsbUVzihF4ap
L72zZkC4N7enXoZ3bm0BX5cALDbhFdotjoxMAIIGYCqcx8Lv/PDL/RO2GvlXAD2FjJFEjmoIxHEp
PEHholhYhipigNPtGtkX0C2T+8+wuFZvyfbweuVJTCohuq9Nonzmm/wWM1Ts7UXN9+sRKJYLxRCs
viAs4RfSUkhfqqVN+/WJsQN7du8rju89ODG6e3dx79jEr/Yd+AXbtEPdEyU0WURCV7ZSqklZfNqC
iUxE+MZBxTggQNV45WTrBV2FzDujH4Z1pro6DS1pTPwzGzPvWCgOG8N4FBWr/I1FqqOpCCAd8+Zy
NZv03cCkN9WOJ3UNMEC1et97A2pTbwiwS/EBDNbjsmNrY9FAzfQNJHKRTPUd7c7yMz1O5U+IT06y
JrcSHrtiLQAKBxyulLSNGO0TFWJbHhg/pVuPWTVBKxvqL5fTpoREP5l6AGJk2QuFf8sXORRwoHoZ
7lpuwYqwFNvlRrqoSIFROKfjXrNOYlRRducB65QNH2olX0GcUqvrO02gABooV3B18kHgM5jBIzOW
BYBqIaT3jlOhG05UCUinb1E2t1R0or5UNlfna7cquXtS/Utkmnt4R3jvNT8aq+0dsrdPDKdiv7MP
/wY07F7k6ylNvaNG/UwByS9+Fg+LjLtmjXttvyn7eIWdmntdUgrCmCOLeEJZY60SICy6VXisC7H3
TLmyGJURYPiFXODnrOzZlXy5FEso6H7RXBHQmoRoElQFzoa6nkSp6qwUYk+Q0e7u+myv5mS33rEW
3CuvXPTxWQ1gIFTMQd7CekhTyhYl5DaKvUQLomRR+kuipNGDS1mqtn0YLVx/EgSEmZy0j2S8cTtp
THwLaddmUsYG9q2DzYmnOXVEP0vAhmI1Q6SWy/kVZDekqjluHSJSNuuaYUzKJw+M/aq4d19x9NmJ
fcVn9+8anRgD9kXK4Gbq0MlvUdZyZHjN9pFJS8UYxhj0chLiImh1eDYRomhOBC+MCjuQiNvIj7fd
arTJ70bVzqGZBOx2wWEdJkrL1DmFoTsos6mz5a7TB4Nxwigw0UJHzpO77DVNLT/ZYM4o99zaYwsq
VOuz5msnFJ7T/BN8hEE94KDaH1K4gFzOPHM07d7OKeYfkk8YQeLY1MIXY/vHdqMVit9uoPwMrgs8
lz0ylEFQIH0+XQoB0aj7ogoXAJAgijDySTZWTfaqBKA857Z07EclOGyaJEnvHVBxC1T12Arz7m/r
TSOawfiuTZvym5di6/L9pi8iJnqJhq/mn/+Jh8FreFW9yjFWZD2X93/AhHp9iIcOwTvKfwsORybM
4YT7tfdtNc8RWRrN+m+BIiYf3EZ7egBrDfBeD5C+qwV08ezAoT48zYjqBnp1vc4r13N9Y2in9bjb
oos/BgkpYkjVwGOangp99I8VdJVKDFYNaWoqsxUDqihWun9cS/dZFXB8Lem+jMebKHBFPc631ztX
L2ixK6vtOWJq59YX3SvnOpfPdz+/tnz3TyuXT5siWGMpbYvgf5USAYMe82qrd6V6EzVGRanVT2mJ
PnDz4ZdRrUJE2i/XPtnKxRQN7uF9FebyoO4SZXCdm39dufspU8MqiMCOqHll2KDIDrC9G2MTZUXd
L3CUIgB4KuY2lJXZsJFlpbzNqzdusVKu+9qN7vnn0XCD2ghUcGL1+jedq2fsXYyJBSO9O3AUxx7b
Xty+lcOUFMjrncTFzfntW0+4WBi8xLLwgB6cPNd96c/BgKDG8v0Lnau/Z51ij5HYRsjKK8BHSpD9
S0P6PKeP67AL6mLdXyr2jAuB0suCvJzFvkX+eKl4RG1YHkrys8eD8ADNqvbZn6205trT5K2vrnel
rn4OqPDKA4rFHNCNDpDQNGW5tWsR0J5nJ0afHttbHD2w85nxX46N5AKyHw+mHFCAMlHiXXBgkdH+
5tKN1edfW7n/Mu+wdFA1XIzoar9jAz/lI4ecAg1MoMebWadz8zRrcRBEnP2qc/bm6rdXVj67IX1V
6VX33En4LT2PrqP3aqQjab4YP8/CIedQ3/5f7eK1OWR49xteGElLtBQP92Ip5UVlBwX3hIAeS/W1
C1UfLqhjRpayyRO3UQmCPDQqeeMUENXV8yzQyQWun/6N0OrMXrK0QDodQg9OkkhAuYX7Bx/GMRyu
QA0AYq4lxamPQdm8e4yexdBjg71Q/DMiPUpBJUZgGRpVDEeCxxm4Oa+V81twTefT7HGOZ9rRAbTZ
sJE51uI8bgYJu1Ql7eOfSBJHwK06zXA42QoNQC5CloPPjObQTB+R1ge3Oze+XhP89iAAYkyZ1aBN
Atko+T5z7DG3lY/urtz5Fn9+7+mZOmY696y+wiD87B6sLP/C5z5lOBEcGNs9Nnpw7GAKCdDKDEwk
pYsCAkNjHhhw5/JnphHh8u2LgYe81LZq90hOAmBSFOj5b6+kGbwwFCmG3aziYxUMOdkYo/2gjfgG
yB/YFbjQPRsxLS1CG/u9qZ8dIoHKITXEQlGuSzKRZNeLs6IwrCf6hSOPnRMmg7TdVZhvNVTv0XCD
CgtHw0EM25Yu0836UZ+CUi6GfO0SSVlLNZlGFPTJS92/X1r9+CzQEEotuXrjLqC91Ruvdy7f6Lz4
CVTp3LmUJupXgfsXTXS4+vGfOhdfevDm9Qd/fMs0VmVT1u57H4azTFgLYOp1A7r84ca9cu9O5+bL
khZHqyqaB1s94J7Yuu1IsOihUFHWSRihXPHAvud7nE1ZuUYCB7WHbLtjl+WZK5JCDGXXlOlpo2Na
5RBQZHOcfiaQcCDAjUJR1gjbvDVLvas5IsUfGggmmGi3WFBpWPtsyQaGiZnYsQNGDqy/1z3wNc2J
4oyILJV+5IAgsL/9Rff9V7t/fwkO9oMP/y5EnxyrE72PPnnDF/r+bUfI7IBf4G3c2vuMhofAN4Kt
e4yu8SyTizmQzOSUDcM/WpYpCXKylmA8xR9znE8dwUQyAJfhsinbodNfrHz6PFyC5W/fW3n97c7F
94H17L5+s3vhOl/OB2cuwBIk3UMOmlUYXNP2IyzYgsKMJb3awVCMworhtzJ215RQMUNkV0PhReZy
y56ETFSgMbTSXIoamoZeGMaifs1tlI0qSd5XWC3vo81vy6wNxbq10hzgi0p73gjMGmM4k1bVdP2c
79bK0/VjaRF5pS13Zuv12aqXo3IvnU06dhsKYku8RCN21UJaTVhBDcI5g1D3jZtipxwLHIjlr9+n
yCHXJMC+dENiAKA4nqYRcm1MwXSRc8SwfAO+tYnBH2anUmFynvaLRFl6hePdwMz9bXozTc+f05/s
4L3tdQRwf3qEYUlSq1jqle97ok3lb+JZc8KBnLWmxu42YgytWzTHcJjM4uM6ju2HbOLMfkJG2qY+
Oqa/mNrr7JhN7bBniiCiYC+wN8DP83nlkw3nlQ3oxTMy05pkGfCkqyN+6QbD5lSkD9Pdje9vLgfM
HIp5ZX610YC1g2tr3+7wyG3/+Mr68ImJQ9haLJGoMkHDYBLW0nrEKHWlAET6nwLbTNJ/Q0/3W3p/
UL434fNDEYchsz5iqISMUMZkIsM4cRC64JhmKJC5ck5a35SRaWRZEJC9UBdt9c3hsBF/ADGv/+HB
26d6w02JfiNckG2/t8jgLNGjlUKHRCweaWhothxSC9qSjrAEY5slwdhOYgpckNwuDz2BcweBI/L8
EXgVybpnCnKwc5jDTCtfqQ8cGaZt8wdQWztQ0qeIhBtKIKeK86jLdcKDjmUBsWa/prW1lBqL80gf
Zsjv0SS6s3k0c3BKcy7MugoTbThMUSaMokcQqbC18A6L8Ox9+HBBRffS5eVv3g0uVUBMPMQx5oML
zM3qjed1UyzdwD40Z5bWsIHNSK08d1oeIOlqMoxWwolCH0WGJ0qu0Ldlh87R17d1h5VAr2+btKYW
29jAIJwJ08x+2b3y6cr71zgaKkvGg4rzVFEVGzWlnxT6YrLf0uCOyD5AkVuer9SM5xnYPdwf5kTQ
bkoStXiICsPDFL28kAYimNNBFtLasheuMYvb07QgiIuoYmB0jB1YdtXqmSyvBy2HrUM1Ja3hbTl3
gWPysxrpkOGAKcG1lSgwjpzD0KhiJEj5J7LRI2ufy+U7V5fvvLJy9+zKZzeEtGVOWwRM6PjJsV5+
uXPjHucbMJvQcJIBY/fixyjTvnQTtWBUrXPvEgWuWr73zuqN95Zvfx7NJcgMiK25Ue5GFO40N9ti
fBUJOTMUJqpkxsSsudlDYTxrJPvM8ukYjFYxUoZmg4Nx6ws+Dzx+sr4MZxONqb16629AYqSjneAJ
PBGkOZU/T3B602ySoQkuSbUlhjVPZBMICgP9Dng9XCKWiXRO3kMmk3SV/A72SG7Gxfej+xFvBmcv
vZxBlm8Suz0Es8nSveLSWLsChhaxi1LYrBpdHNq4ubBkt4xvqW3zJWmfNsslLJA3m53BJBtaJyXj
Ot05+1lozWClVj6+++Dtq6s3rnGhha9j05fYqV21yLsk038S3BtQekBHqyMHWB14gh+k/k89kU6Q
VZSqnnyiV9leQg8WFgut/wy6NkbP0HVg84nNA/wzG4t9VFuSTiJVmAy4ChSPUj12/vBS59ItBgnS
J55BOgfHgKqyHQyyAdSS9HrQmZI7r5xXD/PiwQv3V+H/37yKuUruvtr9w5Xwykc2dK15B0J1qTQV
4wBgqwOje3aRQnf0wB7RW8Ub8dJpV9B7lv3uEWvhswz6jyyM+q3I70qZWPfBpHhnRn4Y/pzc79O2
7iSUJoYrUrKYdEysBClLpa6nAhc2Xhwzno9y5KGacoxLhqfcYuit4Q65ePDZXfuKzx4cO8DqQ9WU
LqZZUxSGGP+4OHyj5GN84KQmxPSLk/DX0JN8/TfUPL59l6I1vg04iLeNaCFAQPwdnrp3v+xevBaP
hiI0GF8oe0zPju8StA56tTkaHICjX+96GiPbPTX+dBG5v5GczKnNFZZkZmQme1hVAB8pDeyu0YnR
4q7xA2M7J/Yd+I3+VlZcspNSLCr6bNOmdCotrb60iUyhT2lLqcgfUFqtIJobhq8n5SiPDZlH7s/3
54IHnR1cG3NQLmQLFcMhi/obk5S2NefE0CByOVlJTDRI5/TbnVPXBH/RgxgJfSmhkfkxqaIBrix/
+x6XCO1QSacATTnOolclqjZOv61jQTPvxkCrc+orYPBW7nzMrzA4x+m3dW6lYNc1iFfxoyKLJvd7
LS0Gnz8Zt5S8QIFyWP3jZ9x/58IHSKOxs+jHdzFar4pKqpHSd/femT/So/+kNzm9X046RlwQBRJK
CEsSrQISulJIJkv6MlaaNEMITOBR1mrXDtfqR2u2cDPWsdomXuX2kxqKDg4rqNJRz7ue3pOAZJBt
KJJ8SOMqGaGF9mL11o3ON7+HVY2PEsV/qUBnI/w3h44K0dJGTxHxcL3ptVuVqo+WOGL2eAWFDrGF
021/Ybp+zCwyJMPqRpNzLTr8LMpOpdctgGS8rvFEotLZMYbW+rM+bAyPTTB+Z0eMLwNDf1mJlTaG
/UjY/9GsB9iYJcamxYj0dv7znQdvfomOy+raWbpEm1iVwjxpnHO++/qXemZxfEUvO/ewr084FJDB
9IW5fRXd55QO7aA9GOzMUHQoyMqIcn/Y8fhV8Am6KiM7QlCiRx9CZ21HPl/aHsxUwsb50QkeXjNM
2kNP+nDMhNczkcPmJAit370oIzuTVQMFWuP4F2aEZx176XCO3M/Vpve0+jevC9rdY8LAIFNgvIGQ
I+/EOhesQNXX7U0U3CZtlTy15g44cSupG/g+27Br71MDv3l2j3We5Fao3A7a0kRyATqWyaUXEXHq
4NoH9u9hk7ZwDG0p3IdNEblnj8yxrTNGomgcnvUpxBS8Uog2GoKFlO8Ay//JB1eJ/yOHJ8xlpE22
MdqSSZKuHcklzGlopUQ6Lh7AtOvPkfxzJJ0waWuaT2J1xJKc/zFRwMj1pJRA1cYtxBdRowkahf2X
EWO5gTSAkaubYFljwWKEwoY+9qGWdtRCm1b8ktX8cJomdh+kgBYXX1q59+fuJx923ntThaJImJtq
jCVXYkv+McEKzwefvcXnefn2a53Ln4mYpr+nvYgdN8OMwqIImAevPc92nmlNfg9INRJSaIcdii2S
3AoSsg9OXQDoaLWkyfeBvKTuMEbMulvsXjwL2DauOUyYVm9WjnvlIgWHoRgpgacxxc8i/2XWJaCl
L4rPA0fRXJDIj96E2QcdVkguRh+36Rjqn91xb+XxUYbI4UDfERso08Z/Id7MNUQlkbk+r4mQ/QrT
pgjJGOUHoFXqmgLBi61NkdjgwtSUh/j6f3nIoJaMzCIbdI/AhgZ7xnXaNaXQlNUOeCWv0milZurV
MhD0BRExgrOMhsLRhEJnwhmJ9JuRLQ+Y32b1hR5RI5D1/nnGQybrq45UUlQim3+NOxUBO9Kbg00+
URJpCBXmiFAvHxYROvuCmNJTnetfAy7pnjsJTa6ePAXwi9laTTWv/P4rU3AZz7uyQnANdGphlmcm
JvYfFDJ2i+QcsJVEFJP0gU24hhkkrFBycyU46ZUZStfopx+yGEslUA7hH1vFKoOKBYWxuhODVTHk
FomzNuubsgpLQjqxZ/+u8QPClDIgKWVyQqboOZgKQOY4vhJ1nhjVW6bRsB9hEnZBTsV9VsUcDDyt
nrMyHzFxkmY6U0U+Qx3hlxpmIHEjwD4xnnOUxpqpZ1TsycYwcxqHheJ3O8ICleNCV0nYEERbnet/
7J69tfLZDXWuoHu4FDAm/FuPKnjAcUU17tGkFJhIN4mVje2YKai+RTnmpZD56crFm3hNv/1D9+I1
subn/YuSLoEFRlw/3907G+3onPNP3vcdoWzsiakAki6UGVj+OSOvgsjtFem0yO2kv81gQzKgHSvw
HKnTJDDUI6GRVrwkpRdIaD/faE+vx404ctyY7urcOP3glWtSf/p+9+xlMSanx28ooBVuevf8mZU7
X6f/B1iI2fv//cy1rODessH1G5iFTcfso7eWHRdQV1JfpEO9G5uug3IByRU26NIZ2yJWgvRaOrxK
9OerYUViSocNvvRNobtrRQQNX6Kw1xaLE/sykpHFUB6wNgrkGoHo03GLslmuiHa6khqvffA9qdop
YZ0wb3UvQ7OoPDp6zmWUsrijTs4vxlEXDm9TSK4HyI3DFkqtzOdvrLx+DXHd2a9Ug7B7aEtw+WVt
08wtrd6QH62+cL9z+SPY5+U7F3l80KSadffC+533LrHNBpDky3evAbnB8W95lSIHoG8RlnEpLjeB
qbjlBCJhn/kjbrVSpuRUZDsg7CJOhROKJbVBatCCetqyQenLrFfAl23ftm3LNtbDJVsiRfcOccWl
P61+dapz5s7q+Rc6734pzTRunhbGe3IsXL59RwyJztmbsrPlr18CkoMCkqP5Gle1bdQQh6Jvj8wS
ptaolx0+M5hXLnRe/BDzeN6+ixndFAy99YXO8mYMT4p0T/0FKq0HXX+vhGIqo1XxoTOLhTQ4gYaJ
DV0wYifNiCfTvfIpHt4zd1au3pGz54kpfRXCNUqywcERV959uXP5L2S6Twzl5YtkbBiTuajPnoJO
k8QmYUjzxyRXMQ2khsI6k0Dpw9IpOp0bdFKqZCRpWI7qS0lbTnZCCtrL3Efregz7DCarrTfozCCR
1DNrcvnG4cTg/Kh9Q0IrJI7GXeEYznRvYIP/cfI8oBrcmP88/YronPrr8p3P6Ke0QyBV9D9OXgB4
3Dn1/Or129KJj1SQ6u3v4o2vwrfGHBizHlekJeCDt77qXv87g2bzYmFOXbI95QYSTAPwLpl0boiu
a+rXYZqOSCt6tTYRpS4i5bCCNZ/GZFwtcgekFlDbESWK4JLjYcewfQR/NzsyC1YfNeFsPmGXpJxA
VMvLBxipc/0dupV83YRA30laj+XbJ1fPfJmEX0MSX2qHm4AGRLAteEYopQM6xV282714zrBSEoZ6
lrTLZPCJ4nAGcGwfTDAB4S01L0W/NoaOYS15SMq2QQ3tAssgsC9A2K+flcJohiFUhwUPaMhMGk5M
iqlkBWjJE5nC6nVp6oaeS5TsggXfcbo1Ng9gr//1hOsoa5MCFWagtyNVfHgILbHmqfG8QspzFqUg
+rM6FFLB//FdwH+ovLj7BqvfTWldrKGImX+Zo5NkjMgl2TixtgyFkSQriJ+cad5rGv6iKRVJr9O6
4ZCMw+lDw8ZEq1HbCGiDAU5JRGrncJqttFT2V6ipyW8spvq65FipXvYAhle9UguRUwQ0oDE6NfdQ
4qan4QNlqrojgVXGOrP2f2FxcGsesFnul+vpkaqu1SVVivkr3K9bnhYPMdvRXU+u2TXWwWZhg5r1
SplVn6En5XWhShtVt4VGyvw6vSPOw0T6oK6HIgibisWFwUeaARNqoGuRyk/WrmFJ3MRjXSQNlGdZ
KicLTXq1AwBROlaikUWObFWgzJ9zy/WjOTa8iHkjSvPlETlyNL6Ii+tpW86EDU/io2QPJrnwhaza
jRCTD6O+iFV0aj0fx5UPFJ/aA9XwhDKCnbCN0uWLwFux6TegM8BcTJhIi853CAooNSUCEQ6Hgq4m
yjuk6R6VYT5wNVF1g4FYMOKH6lfpwgaeGRvdpRVjqGXsRSvFzVUSXHd/j+FW3juDZNPVC1JO8OYH
qBO8+QLSb5byN2Y3TQN/I8r4esKeo3zdq1ZddBWX7D4/U8TaWLs5fu/ECt7V1sgg6fGGdD3t+Xs0
wQQEtGEqsbsvXUMfqLB7HAu1iXZAaoLuGBuXL99+cfXbm9w6I9LOu39ABBvwSFw9JNROWHaEYd9j
zeGrZr0+b6y6LOmx7rKGk1gj6tG3lsgwWLY7r6GR6n9lw6JNhDZM8pGhCQukFS+/rE0d0cr6P6xZ
CHk3Tr/NZKDlVs5UByk4UbBE0APJVRpMj81LAGFyCxV83BCyzLNZ0x3fq821EhMwPyvDSvdEzHZc
qDUtthKEA2wFYt03hdVoEFHjrZjlNBfGTvAWYyHJ9xKt+//S/cuHDOqkuf6ly/DSkqdE0XivJk0j
bIALEuoaVWxZzXGdUClWkdKrcVaY8WnnVJsEx/moA1+ij+jy3WtsW75657Plu/c1FALcpaEQioUZ
U5FFPSrmyWIeENqa0CmYkJRmbxJLDrLOGMu/h55iHYt56wum7ddYRoBN2p3Jsr7HQ4+ecEZhD38w
M2GnMXaot/ZQA4Bw6wu2FElUe4bmePOd7pVPTZcRa5pCRluzvcWYwrANxmjEaOJ59rIeDI8kCrVC
sRn55FgK8CQmychTspPcuMRO4Gm+u3f2wUkc9Xf3zgXZ1NjPy7ESH2r6j7dFu67FBmoI3EGkDjp6
XdRw+Dx3vzrXufSilUsMkC/7dLHhMiYb+2uwDsQZoxzx65fWcdQPhbI4ms6L0lVRJZyD2pt88eDD
r/kRuuBHswKK4XnYJIaX41QBI2IZa5m0mxw9HWMdlWOkFcDcgJL2KEND7Jz65MELn+hCuw9sOZv6
yY9//of/UZHk/5UJQHvn/xyG/4bC+T8f3bbtx/yfP0j+zw1azOTVjpDZaWqjeBbTZU7XW3MqPac0
+Kz4IoiEgGKs6QVKMBPkrpCu2FLMlU9RPHyvXReNSsNDsJMinZ0hBrM9WyLqYYx4lAFugR0YMaPB
4pOjB58pHtz37IGdY5ODU0tOdsDKXgZnWYrtqvX64XbDjN9m9EtMdKL6LwjnEBPNYdiM5rBFPqDJ
p1857onHhh4f5uB0BpEQ0B3GEI6itDRxCKq3rVwv99y+HHQlSwvYbQuDRhSGuLMTYo4UAiUaQGx/
0TTa4fAL0YzY/oLfjyFlq5XpPK4xBlZEz+xQWR4ew3Eh+oUeLFkQNj2/AXyRTGGNmWOBRFCFeVRn
ZGDoW3RatCo0h7Wy4mc0J8P4cCirgiFgwDXoIj/dnpnxmnlkMD3+Kp20CYbOLoz0llKpsoeJcIAn
aGG2uyC3HWVoQpv6BVTVol66jVlq27VWE+2wRaWBf5PJvZoA1UbnLTqHWlZz9OjRfKlab5dnqm6T
0nUPlMq1XGm2MtBqwudhlS977Y8/dbCQLqQDtY8aRMS1gkoLfYv076a+9KFmeinGOgYbqNRwYlk9
jz6e1o4dMJ0sTikosHQnMujmE2TjCZMMJ2CS7YVNb3buDRK4lmqa4qs0gqCeIc3Rr399YmKIUqgC
VGL/Nk6QVa8tzKPtNKXTsVMHTI7m/n2K/gp6m63Wp93qWj2GUz4lbOD8QqWRrwBEy8MpkYE3saI0
5JNfLdK/AwMowBtZ0mTspOAlE4X/EP+XicbJyREfmHBvZGrqkfH9I8bj5szkYO5xNzczmnsqPzL1
SNas2n3v2uqZT5fvXLS/yD+S7RNTEeIY9pIh54GxPaMTO5+BCxqcCs5ZGqowbFSQebWwWnhTNz/4
6O3u7RubT2zufvO3B29+Aj8wVMXX38iSN05yycrzf9ocnDS5IaHtRqXuu/eNaqXIidjMHvXQJgfg
w8b/erLz/vsr9182PnTbrXpMrILk7q3zHWQKCtgS/tLh0xOCIHFEM44APkWYomJMKklLBKrIODBD
8HOWHJGHKUYihoaROcd0YqKCdMDHkAapIN7DFqM9mdmmkNGpzTI6tRkDTj6F2BVySpiIiMTgQSel
mnFgc76gEHlekB5JH7CkFG12dZtDnDQztBVk/6o5OWCdqS0bqOCsDGw6ydPkz4EGsICgnn+uLuLT
9xUeE+F3fugl5x3EDIPBi+2DWSOh1z7MFdaGe4EkUEOnUVdpjzjXiU5ojgwowHFM9UXZ0Gc8jBpc
plyreSv0TEaMoTN8AVnYLAlWJ0mvKxc1LiNk9L4b6/AILURSwqZIm042IV0CHRpafnvPUt8/vVxS
irh15ZzjobP7xRop52JWIpJaK6a55MxaCQHI8VBhOsmnvRacHWgjtxMGXms3CjMu0B3ZaM4LB9PC
SZ0AylYuPnj9SueFSyhVsdjziIlr+GspBbr1BUvkUIJBoozuncuRxiL7ShlK5QrwHuc54+9UYipu
JfIKWc5iRgNebLqXekWiCTYLbm0hIZ56MLeVL//Yuff66sVbKOqiOOCo/Lj5HkZPJtMClvHGTVKf
pXXkIBwxDpQ5fyduyTaKCSBtgASBseuI+JQ4UHJLdPiRr2z5AoOizVJG8XB+P9+69dEFjc9AaIZG
DGUtXEhMUBjeFEzoFWdRNI/HgJisXksR7JBOKix9UB5+gyKbEyMji0vXF0IvgRGeXERkZneNPTk+
urf41IF9eyfG9u4qAM1ohP56iHWGcrXUuMqHQpGV1r/mcVSDds/gJQ1UyHj8Ydk6751hO0e+BHrJ
gazs2xwsqOZkDHKj2ZgPURqSqBhSfryUXETMwso2UnakJa6vvEqQkvDQ1B9+aVSs2ljL3dvgQA1H
bFuATg7doRBPa31mZMrofn5VSDdgVMd88SGmAzKdbmFM/zj5PA6R3ILlMNWRjKbSwPnR2hCl8fNI
aBbys35O5r9OsNaTSwZIR1bLSsMTuarWixgPMiAE+hY3ysp4iIAaiIq8N1hnfvfO4uju3YWdViKu
hSBlljoaR2G5i2Wv4ReeQsRk5C9dNDp0ZCBM0fI8fetg6rnAr3Y2DpBsxLRvhz1oPoieiFs5ykYz
MqU9LC3mi8ujuEmUAVk2K9NtvDGYF+RIpeyV+0OtykTGlMSkQtpjBUupeUC1cHcZLKs0jShzArLD
F0cqfmW66tms4iw0JXJjz1VEulYXlMiBtt5tzrbhGrdOtDk2MvAS6H0tXK5zAiqrDvKPBDIxs1xm
hTiBaALhv5yTn05cyMTkX2y4KYKt2TwVWG/qeLBsumlbK3EZ2VA5FLtNrJWZbjIx4R6MTr1xSWgX
+6ZWB9IpSNKXnJBPnVr7oKpzaCWhw4seQevGQEPDmZoyVXI92ofvFtq1kh6u1cdS4sgZNHrHWk1X
gUMzBAZBU3Lcbk6LRv2o16S9SIqAEXdj8YCrjHEEUgygJ9yjhxEmVsoFp4/6ckQaIDrQ5HCzFmXC
3SUBGE8sUq7hDVS2lO6RvIYmg/Aol+No4DiCgmw+G/tJALHXm6ImedfXBE8AlmiIDJSSgFXchkWs
KBiqMmi2gGrC2AJCwCGRjvxMx3xl+XUCZ6/iN8Uy9jrDlsnBrzuUDnfwW6A+a241cghlOR7DgSNu
c6BamR5AsnSAyXR/YJJcbmIP5SSlEepTTfAdjt/uhyC3JEfIHtfICAJ3CIQSgsZeSQ+j/UbOFJq9
A9mN+Zbx4oeFLQwj6gFQcqTow1GQ2Ikk3SWfPYOMSq4ZiQC0BuFkblIigRGKJsTpeL0YauP7Exq9
YuYkEx4GkxIJbd/jNu6Iyfm+9j2M826M3sFQVBlJDxqu/0AbmvaLrBoXfZujxJ8VHcago8liLuGG
o6dEQaZ7DqhnO8AZQLaBOWWGqYOc6ahx0isx8GgzKF8y40rU1yjiF52blm/fkSYIe9yS6Jw53bka
eGtGeK+MvR0qkS+mTT7c8uYb9mEFyNsQaYM91B84aTH26/GJmFDo6832JiOmwx4AOTfM0cuD5mNS
vf3XTV5DVOVoGxe1RcENYH0B583OkdyODJN9CvBRQUgo2Xt8FQJu03BefVylfFRQQqZRuRruZjSK
NL88Erkge/ftHQcwemB05wRmHhwSgQ2wuTz6m6yJ5fhkEnRxOQjJmhCH6yn8m0rw5nXIMchZg+2R
belLuyNGjkgORihGRFt6Lfylvpw+bsBRyR8cnf0hLvmDHItt6xlpSJoZq9o2vwVXndHu4hD6RUms
y4rArLAVggpGSBIhK8KRGReHR3IhjLOkMUaVU6USoNghbNLBQi3koC6rrQOhBR+yb3foSwuA6eoE
5n40gflf/UeKuxsLP/nvsv/Z9ujWwUfD9j/bt2z/0f7nh/jjOI402WH32s69k51LL69cvNH54wva
RbHzynkZ4Vd76jkOkEdsIeI2Zxtu05f5HgkPH2sZkbIQPchS9clMqdaqqodKQ3pXp4wEJOp33U+O
viV/A1+BzkX68WhZ/fTnzBe+H/xsTwMxUjL69Bf0TyR/0JhHP1fm9e/jFX6lnpVrV3zSQTUiDpES
dKXyZqoSHR1MFRytHHebZb2gMqRXEf0Ag4ziuhgQlFup+v3AhWGNfo6ZAMRMER1OU6nUvoNFmQtV
BRpzQigEeHy0fKHshF5mHhYGBpgdMfIPyrJIpkMoqLb9ucJEs+2pRpjHQx+PjGxDUtjUd93PA7tY
adZrnDYmFN3byaKBB9bMI80M5PaAcGSob4ceZPhl2RkG/AE+slHHUcruZipetezDZMN92fEHnH7h
ONm8D+REK2OZHXEDWaRQtgYOCDoiW8h8SJ/gfKVRlD9lE5zOFIcmn1UQNuYSKORaEGjNbh1tac3V
2wu0Sr8YHpYTn/OqDa8plaSZzWR/Zi/3tHOo5uR/CyuTkZcEV6GI1lEZtYr9RBNmLeqQm1LrC/1U
i9xZZqZdozPXLzbDtYcjRxb0tPn9gi2xCjhMOQ6pGyuExupE7PWy4hGRSaOa5xGh+oCfaaJVoDib
57Mtd0nOL7jG+Wa7lpl0OH7NHO5rzqe/c44c6hTuQgOGx2PQo+V/1EQ4zYmcOaWprXjlYqWM7EFr
IeN7rRbcZJi3IqYKvCmb+wVNqOlhLEcWWsk1oDUsuTV1NvlK1adxWay1dVToDwcH19SdTTpEz3MA
EzxNPFTqI5hGsBT7x/ePZcMWbpNAa3rqpNNmYwFuNo1FWdGVPVplx/VLlYq6GlgT2N4pvBxcmxsl
cERWCkRzT06xlQaGF8C50ZzNrKf0AvlaTYlWfHqBazhicghrXNts6Ba6Feg+uEUZZz2BQ759rfPu
H8yoITLzZzgiSENGThGyAYoh0rlys/PeSSHDCGIAD0SKWXMOFFRSOgdTzEai9klAT5Nm5JQ/Olcp
ATzGJsLz0npileJ10rEDejgGLCHAHYgCjGgKHMRCu5hFo1nAlO3YGuZMWNoSOasNLIfTTuNOOJJB
NlxLc0YNho/QSEQ45rYQEaN6Fja4NutlHgstT/xZC7HfFOviIeTXiOzzftXzGpnB/NbI8R3pucNl
8vZ31jqdFFuC/HdWX7jfvXitc+lNjl/HJxA28B8nz5tRUSj8ybqCopgRUYLUHKFwlcbmxo6Nj3jo
pgR3hN2HSHBBsXVyLXkP2PAE3YbOn2M3Zh1nJ9y5W0LMh9ZfYhFYeMZRQDVNDo1MZUcIX+LT4FRW
Gn1hFDDebYmhoYjQ85YlBXQ46C4cBgk3GXQgCYQw2VHJlLXdGYGdVHBO6Ptg78jImQgW9S6bJwtn
wkQUarHdmsk95pBtM2OV0P01+tKT5IpkUoFwNaPJj8mR4SnrogSf4+mr1PSijYRlTAbqiZ716B7b
UU5MEKjjuHAUFQ6tgm6pBC2Wb19Y+ctHfEg5ZbIZ0wS+NQ+OfdCIGND4TO/JlLkLcctmblFQDmjD
RhnmJzXgMzK4Z3RypJGzPm+81Xk2zsEtJtCbU2EUnSzgV2oBKJNmRn0GhUTVWPBAdzqyxn3iJWWj
BF5STIDHHooaHqvrJRctHvmjE64c0qTufsokiaJsQcZedwcIoaCEmzVLUOaJJZT3KygmqdlUf4LZ
m96H9nS1UiISSA8P6a5StV1mboTembxCJG4xcnpZK1t6XUZnrnrHKn7LN2sYM19csjaHwjn7dG9N
yiu6Q+Hw2hzTHPPbUNQfpBzevg7AlwPhqO3BUcNu6KSYPCq61kXkdKNQwjo7QPkiTq8BMUxN9Yty
pdT6fuMU/+fgvr0CE5j/9UMnsM4hfgPPPsNApIZpE+HfACba+AxHQlCTvs2a5JkmW8Ijn6S6U0Sy
rkWXzUQmgUBokVpYCiYEKw20lqMXLBgXzyQbTzdaXK8cnDzycU2xPix2jvJbPvN5tEtpPNwZwmkR
MwUgE3A80GMrf74jAzF++BlGJGYo+/YnncsXVj7GnIEyMd63by/f/pTzY3Y+f7N7/e/xO0r3FnbS
AA7r30t7l8xdhBPNogcMUE/NUphvs0o2a0naY9rKN+oN7lVCTYtlwxqBmEDBKgVoMsxVKo2L5K6k
7txho32YtzeLLLbFacoLGQEnpiwChQfhyOmSHmGmvT8UurAQki5wcjqfArY3jtL6No62K2WUacBv
/JXN5htHi1q1j+cPoTZMK0+/UaUbPBiHj3ioyFHXGVVVIywymzEfejQiz4k1K30ZtF4r9mwQQzED
zPfQwBYhZBAM8m4mWvVQjYlOFgwKsYjLskTJD8+fA3px9f5HTNqil/JLfwFKlAOoPrj7FjTUOXkv
wjCpFYkeUXzTHwgT1BFtzwJz1OLrrjeQz4o6Ij0Pq2pPEkTM0zlr7JCDvtd/+VDaXANpxF+lzLEG
Y3R9zPIEVyGjFrtfzDjB7aePv7t3dpEHQzGn++V8jZuIBcFU5HHo0QWzGDe+7lx9g6kxaBS/6g9f
72zgJxi//BRoS0b15HconcMl0SIvvyidaZBpCwrn21VUqfqttdghyXQzKSlkdEHSYQMCvv7tgzfR
ll38cv9B0Xn/fYCXaMA5vh8d4a+ck0zKWx90bv4eg9RePg9/yyY45al9zOTuIFCTQ+V3Nu4IljsO
GtK6ZRXXYV5uxKkGQ6FXDPFK6GYz+qU3nPkhQFdMGWfjqBfuL1KX3hO+kYNhQd6M+dADSDAm1ORJ
uLrCivhiPcgwhNtMFCh7CbAWDNiGuPZ5Sxyygff4ZFtIBmkp2sQC3ySKHsznH6FUAf+SFC7+1W8M
qBD8jBK7moDFY6BYw2zeO9aANcJGgZuDoderR2DXsuoU0NgZETLea7ZryrUlI8WoLDKRy7pRTCin
IUoixDKXwMbAV+7YuDNQcMQjY1q/UvZC3tjHKw23IW0SkmSmaFPQU2C6luwWvgqiCDjZXjxCrMzV
5AaUwlp73/KKUFCgqDR/YuzAnt37iuN7D06M7t5d3Ds28at9B37hWJQ2fjpiRRxCp2NjBxzW7zuJ
otSwbJTpeZi1TLClkDS5exSoC0ulIP3sClxjcpDlqFSbhaGqFAm7Ug1bloROVqIc9CSUIS4Jq4UY
YxSHUCskEBnuoa9QV6sQr7LgoQxNRVPaRWA9jlwCx7ZPEb1UIwquRiURevAR8Ps9lCE2nofjU6pi
fJ2D5DO4X0pOAwl8sVipVVrFInDD1ZmASiCjPnykXDjGmLFaXu8c/7Bf0qc0Gfg3/B01Rx9ymh/r
dVFad4ZkH/Su1Wz7GA0LZaRE0JJMlQXrP4djCTextaBnxQ3RnELkv9lPLE0VGknG0YH4ekg2o15o
EWmTebOUGS3rMwItZHa9dy2r8E1En2EOP6XXQwnKeZOV/NxeGpYOmOcjximHWC61NtSX7ErfpGrF
9T08zLZlutNszDsjYtEJJYYYEZOhIh+lLI5bnqZ3ltl+kqDF4Sib9IEZXNOZWrI/cNzG4fWNQmUs
QagTyhzxTxgetRFE/qQ3RtBPa9yBrzniZFzZSSJFOK0y+1SgukrpjkyFpdwN5ndpo/rF4lKWnuUH
/WJS/prKTsVqTWQArbNvmOkfOudPCUc8Ipx/nHxeSnBpeMaJJEGxee/z9WnSzwQmo2pM/GlEfqtO
Glw0dQtj5LjmzUKDLtwyVR1wtuqsp/4lnhOKNM+71S/UuA1o2G9AP+iVZhTbpb6UuD5FMtqUcE1e
TzbOy66tXueKmQiqMIDHTqJ39vMTYY8gZVnE8NiCbhsCzRx8FAeDoZgaysPJRTyNX6CJqxN7CXRt
Q8El5feZ7YP94tFHs9kEIX1EBXbEbVbI/YhIg53PHthd3DlafPLZvbt2jznE5UHB2IGJ4lPjoYJd
4wecmG6iqlXVRTZeSRYjwuOkY6s3nl/++qPuBx8++PQ8u31KvQBpgkwFlA7sLxZVZ0vElAkyb6HF
Cm9RZAXhamwfZD7Kr+ZLTQ95NQm6itK4KEP3vVhyi5iszM9k16ML4dmYAcHZlXXls7dXfvc1OlHT
RFl2x5OTPoZvfvXgzS8BKqzcf3nl7hUOLd555TyHZsPpkhn0g9feXr1xI3G+8TgfKeIQiDJTvYVi
DfN4lr/9cPnuXT1aqQhO0r/pvgPVcijJm6lbDt9DfbXRPFfeZrIiGXkYoOhQDNp+BvNTYdlxHLST
HzDP1gvkKDZC+cYV/ZrbCJNJOiADopopeTeUFM+0a3BQ18l0ka2zx2JFo2PcS2fKJDSkoRXMRCbO
KMt/HeLtDesovSMh3myzHiLyWPRtqVUlhgv1V/QDJlbO+/XSYY8UOaY9TismakXvLqAxbPSoW+HG
ebj4ywPOG/UcXtkx4joNbx20ubiH2X7ZG5w8uUvO1EOthxys3Gs6H7qhON6S40oWtbNmyDYNSZsi
Mp0+XgaOQUkMsYxlixeCGwIqqd30ilwnE6IyJYWZ1FmMqYZhrCKtLNlDxQiUKVY++RuqbM+d/c+T
HzmhZVb2ivkJD00D3ebCLhVcOUO6ac7wGVraUpM5FDqlMgcoyseVJztPADn6kLuQ9IMv4MYhFsQ1
eo5Xihw88Cc7dxiF7PUReoWeH06yuMCJBF7Dr7Zxqyr8Gj5tlWXkQoI/h3u2Wlf2VbQEWdSHSY8S
OWe3YviKGHfassmJUjVVd3667I6ET61aMetI2hQZbaNuOXxj5DmLQWdJshx7dj5F3CYtbxhkRi9v
pMnYm7BmU9ZFkeaw4ZuCPl7qHXJZPeylGDB7AWTWEdaMNoL1QdpJ+lD1m7xDJuPIvAk4H8mtwBJl
HMWQ2OxKNkqqRyy3ZD8xuxM139IMSGrtXZeTKrJYMTxXRjqGZXUmxORahsh575hXarfCcCiW5uaR
w8gK4UZofzPK8AtHEwL6Ic1R59YXnBcArZxuf9F9/9Xu318CKuTBh39HuooMl3RSie/uvbOI3S7F
eBuH+HKDA4hLVtxvnuGD+mc4kXHSqDmfqB4Xk3w6/G6IsgKCapGaW1rD9i/WMkzvPZFRzmy9Plv1
coTEPCdrZ+kKhCeBXoCuhltbyLBtJ0tKmFcY31VoT7drrTac6DQ8OPIpDQccHtP8mE5w7Y7/YxqN
GsMJTB5sc9F13B3G4eu6OkzoOCHRZLheiODrpf2L6UKTDwYpkfNhkafrxxwptZUfGRy722g5ilA0
KJnUf+EyyaMYuiJ4nyj1GKZBte+TeXsY9BrUjA2hrAsfrxPQoBMge6Vmyuh2jf1y77O7dwOsh1kj
aAccgCoCm94cGsyGzTtTsZfWaFlGWBs71kAeKGrdI8WgFlpxfa9IAqkwZqHFJQnSpDPLpKyFvCYd
jIhBxb/kZ5RzwaOuM2UmaMaG5Jog/29gF4rywJ3J8x2z7lOpNaAC3WMaArYnOw1WQBbkOTRRhiqa
x8sCIvFpibSKInTmZdOBiUlkXiNJnIN5SNYiKiwpGzkmwxFmbtu0X9UnPSBykygIQ5PGQZbcqqH+
bgEQgvNY9pgIIqkVXDXfq7WU2AnfkvSgMBQQ7rJOxAZikRpcEuL/u0XZBZhAR8vad79EIwfCck6E
X9ZsfFwzGL2fmjlUE2LRGOqSrb+SSpbSXL3ue8Yc1fDlv0k3Jogfi6PppRoKC9niJrIm6j0AaAVu
8vdGxKGVkh5oSr4UxbXrWCiHZR94vVdv/Y1x+Mrdj1fufi5bv/xy58Y9J1jR4TjBURQKcT42RZ0H
/YVg0bxbqVXxShVMWo/1SihIrDlSaqEPAGljOEmUVKWTrXj3tRvd889zgNTO1Y8fvH0aJsLWNDwv
WCDOptC5eZrtJsRoDd3ZG5WSTDqlorDBkqlxxREALNHAy8pyPLqjnCyY0hBxhgFsUPOlgWgp4U46
BjvrhO5mlFmO4d8Ue5XAfRv7Z06P5zIU1i+XqhVFCcukhYWIy5mOzzCgHM6C6nlE27VWfv4winH4
wZdokKxUi3UTANp8+l533itrZv0ppOXQud1qGadTBZZHuhLhdWFcawBkTG2oOHh+SbYe2SiehwWR
notIPcqfQajuwYjgham0Ur2xEK7Zz/32Iq1Y+IO12GDeOTrtxM5Ay8x58By7O+Ns3IAaF471rfgW
VMEcqjmBH1iUcqVu1TT/vdKgheWmUaYFh06/HN9f3DX21O7RibFdxC1X4CIj3IJBz6uYQzRiIJPL
VS9eNm4qoJQ7Xb5BAoiQz6YslX6g8klRgvwUIg+xcG3S3AlcSWUzKimodOv0861jRP5oD1NZTwJL
fjCsN/pRkImiI/kQZ+zBQeJzTQb1ZPMxkjhWXkC5tXRSi8S9FItZFqHgCpJKLStlyKm1mkHphlMs
4g0vFuUUSLTOW6AcZPH9oRr+nckeqplybzqZpbn5ejkzWH9027bgVR1hMxl1ZKhWv7zuKroGQLKq
fa24MWmYHr5F9K5dA4bocEZBILdcJqK1iPS6/iTQykw6FAwGTXEBDxowaWkggEgjoRe1xnyODTPo
LV6faIupdTOnMaN5BOqNrBXIJkjDuo62VFbpEfrbsQF0vB2wjrGMwnNZZkRhsdwuw+vMWFZnnStY
whOr4axyNtEljER6yVmxeuVYQUIBHQ7UMcB/0De6C6H61DhIEi3BidbVQksQmr1pHWctgrRpCSO8
ni0Tvc6eGpF2bKk2VzQkbVV3lhitqVQ8WFSuB8pgXRstKneE0J3hdAMFAZfObaGZEA01ChhgQFw1
0a5dDw9uZ8urlYHBz+XwZpAdo7rmTpHYQCfLUlNqM2v7YZERJUFaDLMbclSkDtwGRjLD4HlYjaLx
OtEmmGJJHnC4LTw1OZUMK9QIU2hcB1CcqmZ1ai+hQ3sHkzUvSVLXXDdojfOkaZ1B2CIwghASMEeA
WtDfezp9qMb3pcgvlLN3qFtgyoCsQwnx+ty9tXFmgGmYpsr2r1faFZpgLFbNaiOlWPMmNI9Yb3f4
OfoXGNcP/dA207ZMrbcZttY0t8o6DuZiGuKZNV2pmUk6dyGaqSxgVNd51AxBrm2+R2bAIcvPVBC3
3a0WZRhX02aOlVZQYrp4GG8kcT6PocYBzw8OIm+2BqGuYKKyKUCjUyJhVUo/R0bZsPw/KzMm5IzK
5lWrFjMQ6sj1TVAvKUW3RFknWN4r5xvo6JAewGWWsEyiP0lzu0xyYxUDXGPclfwMFmbwr35Zsnvf
zl8Ux35tXngXKNgq2bchjzqCfg8W54kJi8nwAHjO7kt/ZmsEHXHeMGKFT7t/v9W5+gbmy7v3VufU
WTNePQa4fuW85k4TqF62gMWWrny6euN05+xnmHDvzJ3OpT+hC8X5O0ltO0shrau0oLjz7eqtG9/d
ewfxgZrrJJ/JKdNCgr2S+Iyt4auU7HoSmIMGZPgBLlOa13DdPNq6Z6JSPmjDtnDNJFiyWtintpCJ
yN6RNmLnavzFyNqX1twlUqwbpoDBE3raR/RiyYEK1rYmFWEbxal1R1FIksaHeVkzboERK9TpaSkn
vWdhwdcTBsQO/2E5hJgIPxyu4VBtGJ2rWCYaDcBk4/OQeNlQvxsmCmsrOfCjkBolqvSNthxnshuo
A2JMQKQoz5T6ij2MSMWiwbj+cuzAwfF9e5colMFnN9CF5/NrbE5lGztI4rMo85QoyQeTqQgWuT3g
2PKzx42MALp6uAGFFIMiQ7emvTaChrB5U4yXbAKgbrFCavRpRnaSjaxR59J5lELSzKVq9LMb0qLs
1hedm39dufspqniomaXoqehFofZQloQJ6t7+gIbZWG+5Z8jYNEr+2pLonppoYwZhgV/UveBfKZi2
E8lYBIlt0WdJGBMMdRIEgIwL+gVRLCSwCpMa8VJBe6Tkkl5uzzcMMEXeNnIdKbSPbCBO8FGXYsR+
ERAc8U6znKShTGvAUjlyvNLhyCTsKAxrgqagCJuK77dRiPcwvqgALbcQtLx6oXP2K/ZCXfngecfU
MQGoWf327c6lmyGZdefCbcxPckklP/6PgYh4N0DOZovQ5Pt3Vj48KSPiBbfxPMva0dDTNNQKaSwI
/0XOjJSvc1VKvRyKlvEIvL15GmiVB+/9cfn2ye7rX2Iaiy/eWv3ySyB8yDkSOv7HyfPdW3c7L36g
Pe7+cfICajd+9zW8UiFlLgRt8xrplYPFEkODonP29INX3u+cPoV2D6+fxfQtQMzdfblz/R3oG9YS
+4NGlu9ew2THaoVpFLC00FvI469z4W+00jKkjY68giwOB6gzQ8Ypu+TQIvXwMJwxdQmsSMM1RAgZ
bgUtjVc+QQvYHhsfJHoxWG5hmswGojvlCy5VHOQz5Xsq8gE/5LGiyiCB7LQUgiANUnCUZ+s336D3
sOHRqtU5y3cvGqGrVm/cxdxHp/6ycv9l6Wyc7dWZlLS0FhpeoYKKhKDbwGmZXIPZ5JD9g3s2KeNG
GA3d/rz71jcrV+9QXC1r83u3pKLF6NYogpAelxkLheNtfHfvbL7Rnka/aLUNJNKNigKtLWBHWPqd
H5X976c38GV9thBEvzMUUYUiCiKKxayZfsZnxz01GcQc9OQDnPNbBUdWczQFWDat6YDhbRD3wG1R
E/x9xjBc5aXQ/ifdd7/sviHzibNFqLaXiqEOY08ldWyMIbIRikWXsZodpooxGbwez/LdU7zJYREA
pYCXvc8z/A86mW+32iglLwI6hluOSg3KIpEJ6kcGE0jN1hqQpCPJvf2V81GK0enRS0hWRluPG6ge
7Z4pX5uhFSZBaypZXKT2j7OiM9Lo3LrWOYURuFhBayKKtQa6zlHK9fmvDxJWM2Z4ZHICSDnhBAcY
U59hxrOG+wciSI4wi0KDV64+eO3kg1MXEAB9/RXHPNFhZvHQ//EPCJ5oSPYYIquE6YWkdUvvU0NZ
QvnicMP/OPl8YFT1yvmY8xN7p2KXIKCMciXWbHOvHHQvBpEi4oaJGuSLmmbZ8+aTVprfqtY1aDv4
7P79B8YOHjSbCC1Uq0KuAcrxfrZSS+pD6h6Dhbv9JQZTOPcqrB1Apc6pvz1483N1SEIWO2b7oQHI
GOzIJNYrQGcXJg3vhVa94WiB4ZTqmR6FNHa7+D6upd4vZTj04MO/A3HEdnA9esfMMr7PAyCUqDSs
shiY+mDL/sphJ67/EUEuABYgjE5dQLREiFg8++z4LnVAmrMGYqB/sFOlZ7J4Gc6WrSU/SqZHQjgN
JFlmoMyvUJJhkKMj4YQF2k6LXTLYswhd/9nhH1DkgpjDXFjoyYHvMYaevMucyqriz0VSFVhD2GAN
QQeBYJbbMBxI0H0mhIb4/GoYKpA9FUGNaMS4csVvYBYtKWmztXSWSeHYvqcka/cLb2G67jbL4yiQ
bbYtp265XZxBfMtgP5oUdF8FtHYFB3Hpje5XaMeilcX/MobSGgcGhFEA8h1p4URDYGqn1xqYdE94
//AIqd2LKBpjG7OebMVq1UjszkEGjMAxPU5u0HGsOpaiKemLwVaFgSi/n1tGOM+Si159huHwOnru
JeFLEvdmH1rQx2zP9+aPe81ZIoWRUF+qDX5Nw84zFuiPDay778D40+N7R3cXd+7bs2d07y6Oih3p
meE4LzaB63C/ThhUX7rRw16ZNbExNtG6Y9OKQFXhiAIZY0DylEhw3m8pg/AOVTD2AzIwxSKNXRmO
OIF5HpyJ/7X5H6KWSj90/ofBR7duH7bzPwwNbd0+9GP+hx8o/wOKGzC6VlxAWCZjgXpF2YlE2EeG
hKZek1JBqPQIru9t39o70cNa6R2aXkzWBuUIQFC14S4gHaTirbstV0XmRDGor97HSUAxmgGM2AW2
wS9knH6EfSMA/JSZoVLxmo6iUnaA/oJ8eQYQlvFU8+1m1XdnAKZt36pgPownGwms3mR3HaegEX1M
CDKN2WFMqKHDwh4m3EFMn/H9R7aPyng8+JGMR+RsgvkNZZFsW2/YndhwbcD+r7z0F45kGZJgBSKl
zqWP4NCw979yfrf0KVJ50fTyM+1qldKlZprOpJubGc09NZh7fCQ/9Ujm30Y2Qcnx0dy/Q0kxn5t6
JPtvMkLemlHgcRUEi8y6H9zr3Lu0fPtC9/M/rXx43TGQW/wYZI9Twc98MTe1Odp1/ALJIJ8oT40L
XmcfKJmlIxQSU4XvDUKYcfSy/iAMGRt/URwzZQcWirQrD7kRl9cgGZOC3slFGRJPFDjWIPy7fdu2
LdtU6L/wcsECwTIVp+QPuVObD/XhVrUD8Wjieslo0sbh0RlnLl/4wULTaTcQvVrR0ElBVHC1xr2i
gkejittRkgFOqSpGRHArjrGua8as5qDVCKy8Utl36Zd/OGcp5qOzN4J1c6xdsQ9GThGq6XqEBLD6
kCaZX9kGAjmKQOLPucPbttNzdYZN63QgOWMuTeWtyGbdvU2c4p3NvGOmy5zO+CINnGQcqVBql4j1
E55oM9/LE2I44ZAffGYUJjYSHPFHBqYWt25Zwig5nNllaCrbU2nBQUZWr3+4cv3NCKIVi+o8LZGE
6PyZlTtfa1n6gnS5J/5BsQ1DDAl6xjgETn/WaxJ9XgiGqZYjDC5MDpW65CCTv5CR2nUMe/NQhoPX
x1zTmGY5tDK5RcpAuRIWyhpa1H/YI7q0BxQ0AKBcf6BInmxXqpStG4AoImCSLiPlQpuO4hASW6Bz
H/K5s03OJphHYsYYjUThDwWVpbWqpa1Yr24iURmhY9UaqohESXucIoKzDqxLMZUYctXp2VbZm6/3
lsR2rnzCOVRWv3m1c+bO6se/Xz3/AkcFxlwR37wU1ukmKJHappSScIYRifh7Kcci+jCtixPDww+t
G3tR68YeUiVGw0LkYk4uTiemFIWGsRtu2JjMYhADxdcQWComHzdxJGw7FjG0lsGpqLQmmBvnS6Cj
UvcHsWf77QC5UeMxFoYpHIVDEFJ8/u4dTlTBx0MGUCfik6fu9JKzhOGkc6SBtuDufAOwbak+LyPH
FobhjwSaTtk70hMZmfBUoYTp6V832r94evvxuePl+dqx56Bsovrc8aeePH6gOjyzfd++2UeHh0u/
2Tv97GMyeBEcOFJHwCZpQUvIPta07GlbwS3s9YIFYXtcwfdCxU9OuhYcc3d4OBJCPAizq4tTZszb
cJxjlaRNppIDWmBARaouymwahCAAVzgxQnGZVE7Dd922AqrGoQogqz5T2TUltOuSu9ri1v+NoqLA
J+2/K//n0NZHh4fC+T8f3bbtR/nPDyT/GUdZM7FSUgfpz8ENzFUrmFGhUjtSaTFxJOoAUUnLJFVY
aT+gohDe4MXNm+IgKf5JyAsqS2SQ2NjUoOvI/mmIh7wSANAgo+dc1TuWnPAzNstnKrV7/KmxifE9
mChz++Bgas/ogV+MHSC2AlFGA031mtOOdDXMkaz9hN9A55KRzCRwBW5uZmpxy/CSfJxaHOofgqc+
ADBjuxgq7j8w9tT4r6HNaefQscFB479pIxWR/Wp40EkdGNs5Nr5/Aglx2T0HDMwdGVbec5a/QIMI
ic3aPyCgjneSftUl5wDyb5AqQnYAojj+FLmcEmq1GygjKIvpBeG26vOVErRH/LailS24rr2pZToc
GQw9HlqbOrQ4eB3DROkojIIDniCz9ODVb4BsxIw9lz/qfPPpysUb6A5w91rn0otGbDUZjfKF+1CL
adzOqa9W3r3e/eBMbHhGCvfCSYT8hXn24aRbkpHrqRhF6bet9KDRaMO2y7gK/ac+r6MmA09mJuQA
Di9+Vdz3C3ECf/0afq2dXgfJo5uno0sDNMHllzmy0fLt10zzDFTSnH4bSax3rwOxwNQ4k5mwKtIG
iRYJkwou8hCXLOef0PyTph+TziB5Fisf30US6cIHmBlC9Sr0MDFfzrmvu9df1AQx0IOrN64t38cM
dOyLsnznopm4KZJuJG7tadEP4KJzokLaZiKK5GZkw0EzSuy95LCVnhP5zkER6alrzjrmvHr9z7HH
9er7i9zPEs8kZhdUCEMqB1jw8xBsRdiAlx0t3dstAO+V4/AT3TnUdpieseFACL4KAqgrxbhWJUU9
sEBS0Au2a0Cxf6Erk4y/lDyO0IoYo7AdGiLydgp0FYA6t1ycXmhh6CszDhaqrwGo+qHGJCxE2++9
9dZTMLRyjPRd9WC41y5QEiiG7fRagn5yjectNV72o/q7YsRZRuMRDPkDgJ3BOJmSVFq+mK7DOsG5
8dvzHIakPiOzSSgKgKCfV2vWq1VkXlUFYHrz649yQYvVK8ZFcoCLvO0GHNmPuoohwStPf8elMqD1
iA2OzOutpMr0NJkbmsrjBpLglTIqJ4Q70N3LWqnkCmoQqDeK1sV6ZCEdisYDMGgGTSVpLXCNa/Vw
HIxoAANKlpcy+Fc7hEEkToEMCRXcZOVHrk5BEXauyTHnAgWVjECnBdTTaXS0wrga/R6G9FqgYJ0F
Jx2NU8QkVt730D2GQ9lJ6TAsTRMXJxtOgi3HNF2pocS9KG0iMmzkoGKAKUMJJgTzz7XR+F35BveM
85IlsbSihlG5xy3beRap+cCP/NAhlHYfgj+o3ZOlaQy4l4aidCAORIhMkMZcQoqrVxBxs5dxsFoE
muO3Qe0CFY0YvhlqCcIrRRUnh6e0C3Movzazu63SHFO+hhw8aWMlsbt1yemXncBmw8rB155fchue
DofW25sZvphOO8LMyZmxZe7bH1vKphm8TY7QRPjgZZTbvm05kjANZ40eFIU/75Yc7sw6hdP1ejXD
TeMKS+Xv9PatckHpFYrazUthMwBaQtz0jtQPe0U0y3oYZCxTH/dEZSrb0uFwxSjulZemTS5ugwpX
1BTeZOBOUvR6E84SgHQeAebIJlNDVyAKZEE7jtKgFoycWH5M+MrInbBCTdJHSdg1Gw45nkTlIHIx
EWOYCvVQuiNj/VHP5hAYLUiaMTJaO0CwWkLUKnFPIscJi1UXEZREn0RxSgSj6xbMvIoVpuxCy0ro
Sxbb3AuVos8kJVcp+rBGoQTcVENHrbFgHoxT4QM2UBtJrT8MNVYIpzIj1I4vZOxpgG6ekxisPKxx
5LDTZEksrzIV7CULNvy1U/+akYEhUACdHFHBjJ6e6O5qkJakB2MlLnuD+u2ZmcqxjMNiz9CxZZWn
FX+eUwiRRjQmc6w0FmEum1AQuVqQmCPfAqBRK855xzJD27Op3vBeYsbUf+Wa1OpHOVtbhqJ84F8m
9UHYgIhVrPiIUIIUw9yS9dtQg8OEtJoz1Iiz6Teb5jeVNz2zac+mgw6HEWWkTK9lw0ZX0iAfIyQl
YKNF1ZmJjhblryUnbWCH5mHSyM2YMpWRRV6wpZFF2ftScCir7Ey8BpSQyGEkCWUT+88icMQUW6ay
4me4cgEwiSHoMSqPnLzG10RCEpEiT6N+5rmFAqaZGfLk3EZbBfmrX3DmZjqXAXoiM1JlQYrKRc+3
U9XBEZol5011Aktus1mBxWB8AcsDWKJeq8CWah2VHC0rTD2ULJKjPpsK5FPJqNvcqDjM7QRjNDUp
3FiCAYshuKMDaNCRyYbsSlmJbklK4hDjNinv73S1Pg1zUYSBvIrkQByhHrBuvzbPsf0kEZXgd1m0
0MeHEFUBG79F2zBgxR4USK8ZoipT539nTVLnzOfdC9fRjOF1I97j94UnM3QByt6xfn2DvFp73mvC
lDNxOHodNLCZQoZqM8caInYR3/EexzKBXH9oCqsBnYjCXUfdVn6Ht/UJCcYYDsZzhNMA1A9H3iAL
3vYt2TpRUXRZ4As4pq25is8JIJveb9nyQKCsFK5HS0HafEzDE/gdsNQ+UWO4ABSJAKmzGkp3q5jb
BRsjMaeQHnECnWWVEB+3EI3guWK0E2aKaeOmJMdik+FD2SmCQXLhHuEqXAPDSw1lR6YirZa9IxWy
b5ixCPNFvAlLJi0e5VOCjGyIQheK0yhLQYGPCowe4qdwW2V3EeidXZsIk2IVUpeiOMHqlUR+3HhS
GHshxfipBGM47Zx96wvWcaPr1a0vVr89073yPudYQr/tX1I2oBdZT95946a0xX1o9WQQcPK/S/83
vHVw+/aQ/ffg4NDwj/q/H0j/1z1/zkw+Qy4b7PtHMQae71x6s3PjNCK6b9/rvniVIh7IOPcPZf5t
afbmXB81evqx1WrkOQCQZRwe6AGTlHwY0kg/+dVkhZ+/4Fu6Pvm73a6gtdlGsRsDCx3E3BvoK0eB
3sTgo9umB6cffzxX9bdv7ReU0jpHYVwwZSyGciBACKBb7EIM2BTPtKcJ6Tz9zM4D+dT4ntGnx4q7
xp8eO0h6O7aOHNleHnYfK7vb3a3bylsHH9viPjr82KPDQ0Pu9qHHS+7w4zPl6W1Dj3nTnjvozWzb
PlwafnTL48PT7vDM9u2PP1YedrhhbLHql5r5Sn2AwiJR5pDmgMpC8HOEvuYQUjv3FvWXZRpwfj5f
duular1dXn8zu8eeHt35m+K6BjFSxWxiLSe1e/TJsd1Yu1KX0oc8OWw6qZ27R5/dNVZ8Zh+pXWOy
8Tg6veuTDK4YWBrGHlq1Sai1mZtxS4jQyhV3tlb3AZsBSnVbhGanPQmJvbJGgKguAdYa9o9tTBHd
l5DwBUToVtksUEX9Vm6jMlZkj6wKwG7i6cqj36isbSlC42zuGSNE7AMnFhoKQ0hn1PFdonPnNVTK
sVuqYWAvdcEqmjZQSbNoV6zSM7CpOBei00OjXgaiXcZnhCOhrYjJTJKqMXFGH0TUe1ZUMa4UIodw
deFkBJb/SAEBlvSqmM42cFYld2vYFVQq7Nw9LmDDgG2AJ6wDdw5wObEbCKxabYzZJlAwL6CCl09Z
FBwNuqBPuROmJNm1Oyal9K59O38xdgDO4sGJ+DDz+ltYnISPd+7bOzH264k4PUGp3WxyFKmIbEOO
lKNHoyBAJjdrcHJqJ5fDGGgu/V5czI/Jcfh5eZGfgXO+tOSsO1zkmobVQUIP+W9MyKVgIeXMtOF1
SNgRs4ImY4I+o8fgzseuWfj4kNtGeO1x0UfH9+q9i9ufoA782ju2c2J8315nrcNaqc3UY/aLzxht
0Ux9jfBoHFsu9lXiEpN59kw9nEglNkEqjyVBS4I+9sX6UQB3RQm8fBV1UPHwu71Zt7QgZF5iZk5c
AcAD0CC6TTXmPOTLqgGczItxqMjWnVRPqFQCG7XEeB5IK+HONj0PYC6cXY9d0BEuAxiuzM/LyO4B
8B3flZehgjCasimVIUyRWzQSNC7llMga7TlJjKbTVBBLasTLVEQuCbr/OVplGzbGAdG10x/FAsvY
M2hahCaB9ccMmC4PZ1ymWTa8DLwR0BCGrbLFIn+2hBGgTn0lTUHe/Hjl3Fnt08vIB7NRkMcO0n/9
ZCaUmG04tEdBVpI1J4yb9v+39/XNbRxnnv/zU4wnqRNgAyDAd9HBbckybbEiiyqSzsvRKBQIDEic
AAwWA4hiuKySNytbdmxLTry2E0vOKbHvUrEj+Xb3bFmy4+9yJ1DUX/kK189L93TP9ACgXPZu3REu
i8BMT79N99PP6+8ZtvE4i2CFiWOj2UPyWXdxQRb3kOHYN0nnOLQRqCsYrwOkplYiOUY1FjJamLUj
JUZRs2HgRgAL2zqs2got/ElRU9o/CUoJ61wTUBBSBw7K2ADdkqyoZGtZlgekCJlF3N5kIrSfAtHX
OSWuN40aLv6xODxAKGlIYwQ4jlVPSKIQqLiDAIjymtxtTA7rrkmm9ngIsBKDC41OGUhhY6udkDwP
7UFcs72niRui21KmDjd70c2EFW24yzW3NF4GyNDAjXtWaYEJ9YCJDq8tyWjFqZKhe6VrUSbX4OVd
IjSD218CEJAkNxSmpjIdO+eRyjoQjkLyFilEwEmMsdxkfkSCkBFUCvJTm7gEMbcpPj4npJtUpVlu
tABmQM6szjlrvDEWQvKPklDGkeJVxtElJNMjLpmPgNpMng8vDWUtJoaBio/NdIzFZGBnEngMmcfO
nDaCJtacRGJTa8cGrze6EAdQrzSbmxW0XafCmaUpJT87PYsS6d6ib0KHHpRYtBDvvodtcPTaickT
EBO9z+m1lXbDefTPNwa/vAYotLFDzophmHxU9REjCxu17cK0FZBddpu6RZiSAKL1zpc0BJ6f6CgO
3/oCAAOvv/Hg7mUagfWYjo9gKHGRQ+BGx00BO4paAmPaRS9lgzbqyPGJAaiqb6pyc/tgXvHMWOGj
ttjQRU1eJY9pyg9X9SRogNfcdQIfdO3kyAwyRweATOlgJCV7tdJGL1jcQ+0eFA/66M9Z7zeRO89p
tkXyph+f69FFwpBpmfjWop+NT5GhnTAc1JhjZ0dzKjq9SDQ4hXG7YtpUMlNICsGcKjrYsiEKT4mQ
juvHM+I+QAhpkDJCgWFvyFed0g7G04gX45ZIQjwLrGNA0uPefhovIh+JzAguVpOaa4v2MQaNSXIP
brwG7Pb9d2lYpPWnyEFnDyZ8nwPfrlwNue7IWc3DkSgCoeoqHCq/FHYNAM5an4ZzlHZhjcGO5Hyc
9wVPaU6HO53PFyZ71Q5d3ijplklZO05XAe7LK2L6N1zQUSx33BLyjIWp+Vxe/Fdwh3MGEag54APO
rK8DYAlBBXxz5dEtsTb+TLZXilr94EPAyEToh3C2vPZFGUPd6HktCYpRRFAMOtHFZcx9GV8fG+5S
+yJlgRVPQCEorLneXWQdw4tr6ysvlF9cW1p1cRYk1Ki0yaqS50+trf10ZfVZN3208X91b/DZ2ySI
kUU2th5wiBjbCAdI7A3AS3VLaRnzqKBQMSG2360VRRc3wu6pvPcAJldGM2QZjV4pcktH6t1ptMtV
r9tr1MFyaKZiIicB4pZQOwzmycBr1rOB2DZezdEezJENU9C+TY8souTUHjjgo4wcBLkOBNviQYw4
UiSA8nUEQTO3tnb2NOfegJ/nV1fWV06vnC2vn10rnz67vHRuPa0/RchTGLuIBE4XU2URxAjbLUu8
U1Hr6aXV9fK5lXPk4gJ2U8OWz4ZKIQ7QNG2cgOk+UdpfVBfkhIuLoWEzzCvDiSHr0p8htS1m3evS
hOuRqNE8K2G8OiTrCU0rOdw3p9XdlLYHMxzMsEGpmkohlziVkZNQ5L9DfLA1pHDZa/f5pXU4oSYx
TBpHUOS/pvijLQMj40YuAI80sQg6nteFQrCkK91dILwtOqNgC2ozYkHvN8mlrFlUKk6Jjt8OPPTQ
qvT6Ynq1jgz3nNZqqjYh7SiDiER9nVq+2PngAIP+OvN5LS1r7P6P1NNDoH4sPUVHGZrxPfcUO2Kg
ER8SpzxTCRpVdAuChbpvrp/I5o1pbafyefB3oEZFB2fy+bhoCh4+uy2/H5Rl58p6l/atom70IeDm
Z/IFu+BLdAQcU0SHAzQT6ONXIJiaCwMQF/WOMqHhB0MZ19bO5KwNSVweslHmyGqX0mcot+1dqjW2
YGSULs6cwYT1NyaFH1x5+fD23cEb3wgmgBR0oJETjMKvfv3w/k0CZDXDmWKRddFNv4QFQmksDI4J
gnCVoVte0/M6qXyOsyLauqvkI3BEmM87D//HrxE9/s8KGz+E9MHTGOV3UWTwl/cx2Q+wOYTHfvDe
5zrCuoT349elQP1kZoQnMxiuyLkgDLqnVBFRTQXlkdpps5ufXTkDh/MJVmKdYGc/PgpMFTSmVoTK
vmWiqe9BRX0UpRUOyUwaFMI9Ikrv4sT4WqrvWEMVURlM2DqlvKC1FtYgUwxwcqv9NrhRu6XFiaN0
+1t3WH8jBnEQDDvSqqIVIS1hpomhKtrUKjbDARZYHIsecQoNTJ5x8C+3AMfMqp2TyoVvoYIzaXtT
N0QBR75T6dYCQq0AsSPnYFSZJAyBg95yEHBcEeTfExX4fgd1RiFnaDhrB8CjhVzP4iLU6urabIra
DEtAASplTmq7AfJVuUPvYMPNou7u9JnVlReWgMcsAqXQPBtKlORCES9qaKMUWdGjVB3iF67FGsn/
vDKzoJ0pohst/WZUGtzc49mDxUNoN0ELCttOintIF8iGAkDdPIfYRLDdykL0QLGw5Y7dBk1SKCIV
lfDB95TUIYi9PsdKGTpWS0KAKaIQFFqAM46sumh60DNiY2pqJj1mgsi4Ovb88vmlkeoTc6NHcMoi
5vI4tmNdPrv4rawTEUI/msoM51mIIjDM7/W3BJPy6PLlwav34htchUrblRMTCSg74oFEsTMqc2q7
KzZC7Z6FdWXJR6uMsH0oDXPYmyjDJbhqT7FW47+wI5yPVIX9mEnU8Kfj0eZRrOb1pdUXzq6Un1ld
+anYhigYaIipcobt4Kj/H8Ml/z/3ieWd/3fA/5meKUTxn6dnp4/9f78n/9/nGhiHWSMY/F10ziFI
fnFQKVlPcnUAA4COPD0SxYXghJ6ziNJloP+MAd7T2aklePI2ttqVMZ157UA+qysr65K8IauhiXIy
04lUl4vBY6SNslwMSVqqJRbodFCLHgrEyNzI7+mMk3Kf932AWsCLyN+YFywMR8p9oVHt+oFf7zlL
NbIIR65gzc90wWXyGZWzJXIhbboqsaAJtmoGbTsVRoMEUGMkzti8vRjzVRGDzzikhoNaYS4svkYE
vaGk3BTkJnnKcSHTuIvNoJZWCMqTYimtrLniEtVp0xVJNB4tzDXEb6HgDDtQjgmdAc4mISiCma2+
qr3ILXxTWbzkZQP0VYtdp+Q19JBaVkbGEZwBw+3LRLHggZk9DkE+JsbIgxvOgjsZtCsdxDLQhhKf
FarfVloiq1/yquSel1JWWNSJtUGnrm8YGYvMbiK+35OHSZkdAVPExChjgCIpXa/eF2IXZKQRbBBo
OuBxUo2Atj8QzWz6lwQ3Dx2psWlAuhduVwKusO1zYiOKIPRRs0fR6TA9Nd8j6ErBy/Qa1UYHFHSi
NMPZSwQ8Rjsknc8kfEFc9xgdift7yx4VgZ6hnnpHvONU7EnD+fvH3m7EG0ny4ThbY6CwP3r1TUwk
BXo0lUMLNIWUI01NM8BA3fyQ+HUqTdhCGuqVoXWIeSaD3aJSY4kzwPTT9B1d7RFzln5T17PbvDGy
+C1bayBaqz9MFEV50kMPA3eyH3QnA1iVbZ8iBDLxt1Cyy1hHexUNhZiW6+yU+w1Mq5JH/LPw8pb9
shgVWPdwwZh3aBWykTxlHY4bvwC/KefccBRp3WD88J0/Pbr8DhhE92Ij3GcEKV0bKyQ0Paultq25
+2IXn19deQbDMMRJHng9J+v1J/qtSnDByc/PT1QF1fghqDPcCbB0FfE7AGduONlLTpyeOKWnQSVP
fj1VCKlxfwj6lrYaYvyZf3hyMkpS02hXK1LT9IQsMgkxx37bfdpBLayT7YgmoLTrPP00bbigUp2o
NybEokYXmB+mWheAaXCyNS46afIFlBwx9zP+iJnqdSsd54SgvNlu3clmxWNcmXvCWfrZ8joXAGBR
p3DCOfPieWf53LoDQtYEDlhsBTDqgAScFRsiAIKW3er0tV817yLqVPoBqJSy2bafRX+hLNBG/Mn6
abObzks4yLAeUH/BnmzXsm0y6oNHSXgfHPvEdm/3soTsx8CxWYTJBoSmcHBh3UIqzNYEoTgBpRZB
0TG53Ws1Mz/qNXpN7z9H5g/F9B9N0r0TE2H0DNlZVVZsPh+GMF3mKSf2s4eK+4iXWkxbMs7mH0qL
Ix5p5I5sOdo4jbI+OtF3OcL/qCP7gTj7gh6je0lOXzL4KiYKiDkCpIujGLyaKrBo0IAPsbOS4E2M
dPRNoMlu29/0a7sRNdHQftuPQnKICEH/pJJZ0DlSTIEbOyIB6hSRT0lz5TqEpT38fBwL8YQ8p4uu
jbJAugbcaJO9VodMPHCMxMcqFkZ1299pp/DwjJxVmcghlRhw3PXagv0ua0ybyb9JZDzqcop/0olt
okZwgq4I2Kj1OYNp3AC1NaO2u9m+a3Sd9JKCAUAYl/ZFLNOAf4HYoxo9zju4qDxGc3asprMrz587
xU9G75qVnD+1fqaI57PCAFvEn/gF/5Gnk1vSNzkKEBxI92RGub8CiTCMkphyDqPkgx6CkudgOWE0
uf4O0mkpBphI3BtwqWSkA4EKhwJTvPbXB3ffHFz9jCwuIRcIPtMkddL617lHlYpRcpF61m4OxQn9
vB6TlIVkwEpJ9TnUMXK4+aTFZnJkxmqNr3ucvQxXGuKbDC828k3iLd4onHZcw2wc4QoyOxHBwlD9
MAExqBHdXToErGpVLgGcuWopG2spbdj4gbqrp1qNdmo+r4FLgZyOsR/YoqgMO6bD1MeovDnhYK4J
l7ecR+VPNMRrQc+vebSMmvrc5wjGGDyvVC/2w9yabjoBegFygOIGgPNC+WLcfPXgxp8Pf/l1JIMh
7BBQZfztqw84KYpsPh1ZWDgdpJ6IzkQUqXDjSVnCFWzpNlJCgJ9DnjzjWA8TlyAeS7xbfbay6MYp
dCbgVsQC26kV0Rcr6NUa7aR4RauBK25wwOsTI+1lQvAut70dGYAYdzfGVxMUXQZOtGUMIE9lWRS4
Ce4DjKzfRqtNyhpOKdeZ1u91ur+EUCo1W9ZYyyKLA44GuQuNZrOzlZL1duBcJuVlbm35eRAAYuv9
PJU96/sX+h0Ll2P65MQYwCGjno21lTjkxdF828jR/Xg5amoac4SxUSYNzAyHDZBZbVe9lDc612/c
8hXf8aEjE/KJh59fOXjvcxaYEWTc8Fy69jpxh7onMj148N7Hg2/es/GLcKxLXYqRdModQ3JypRKB
lr7mAiSEsKYVg4w2h+GLjx7Lz51aP3XWlTg32AGGAEInRPCXB4cYWaAUSZIL+oCX2orQidbTG4uF
qXy+BFXJRsmGrd1wIVD0nc8FN6LoJszl7S/dYRqOkGUhwvuXPw7u3o0lkL1KIOd/++o1Me971M19
U6mB+tNjE9/QD+AJl8UJBSzUdwUBNML+l58vRO1/+ZnZ4/yv31v+D1IBoDqAcyZ5NeeFPqBCtyWA
WJdQATbRPAjqdVg4YqO22cdY+k8ZFsAIyM84BkGWK9TvC1uGWdA0Eg41C1a6hlVQWgkB6melXm9U
G4KEijPI6znLz5KhYO3MqezU7BxltgLo9Gbgq2HD7Jzf7W377Sx6mqls6bmJnyytri2vnBOiINaH
vAn1G4ShMqjMUjKxkODiWjSzWQYZCnK9Sz03niFWp+ETq0tnl06tLa2JqvdIA7/opMCRA1tMgz4B
nJEpioUKZGh08hYqowmmm1L2GecGdTy9H0btkVYIk6anzMy6BMcegdZ44cX1U88vnSs/Kw6a8rPL
q0un11dWf04hQlEIY54A14gRhsrBulfZDPxmv+cNT+Rpb47TWnJatPs3B3e+PPzizuCv/xSPkIGh
AGAyUL4A7I78EuGifEF4U6ku/S7odsq8Q8iEuBiVzTX7ZCy9R5KJkrsUhpxEwIQSXAKVHVMsKe6U
mxjtKBEI8gmZWBL5xGH9VGJfNKkmmksooZDFyQ1u82yrNMsS6VZKTrgzygCAItcBIwDB3mIakeNL
qXSu6e943ZTMdIegoXvupYW58twMBD9UWjXxJSO/GFegOF/rtvgaflFX9nGFc2OcAhF3GPmT6+qQ
/fIe1McO5KQrgYLMx8ldPDxNKDrcPrr8j6TOdMwGnD3uCGZDUYqb628c/OXjB/f/+PD6K6zEeeNK
uOiZEHiXwDVQbGqmCEXVoQ3qZ0n3e6/LfVBmirNfvrjH720/J8hrbusXNM5+t4nlJXDXVqO33d8E
Rn5SbqWGL79OSrI3WfN32sB4TobVTlK8I1Vb6TSMasXvnFa1EBX9YGgDRNQm9/DvvpHYU5LIyJRI
L0kxogy0L1NzU+wXAr9dlMK89VEF4M4THAkh0Xz/kVqQm393k5TAYn94lZaJkLqJ6O0UbdhNNSut
zVplkUsiZnSqkJ+acZ504I8gBZtu1FuD+pIjY08K61OEl+/pwSxPFKMjG7pa6YU5B//tFnh5yxB1
pV/k0PXb7x+8+2VkYRonTQqnuAEQsjTJOtaCyikVPZYmlNe/SZvpgTjp4vw44Q4euQDQUVcnRlqH
ZEKnx4j++IGzhrlNBN8EfEXNg0hq4qPg9KDOPQ1O7UKq8cCFgbaKI7oC4ZMq7RqdXxBXXqn2cuOB
sYPpIZJqSlorcjzDWVqQPR2wnb14JGZ7q6NZ3emd6a4+Kq8vI8qjvBp9yTaMLnZMlQf8qdXTZ5Z/
smSmbsL6IpmYVBewe1hC04YYKSFwV8gZBd/9qnjdGqB8VhyFPfRJLyLt0S4Kpo3cGfRb9bPsjA+I
u/B1yh3q6cARaVk+leGJBaqhVbmEV+HXXD6PF31GrucRRtINoInYwh08KQeIa9mKORF1VyZIDBv+
QcR3mGA0OO3o840eYF6uMtF1Tp1fdsjJgBAoHtz9M29/PKPE9h8TT8NU7SookCEDdbNnYMZOVYG5
WdTxjid9scd7WSKbLu7s0VMip0XCbGgMDvA20elCBntO7P75+QT/M3qCrMThc6nk4Q4rGzmT+G/S
sRTLqRRGnkW4XdPCSUIUnVOqCbe7KI5+pBBMHM3xbvbbtaYXkk7Y2C2vtSkOMLO1QLIR1oAEqkZw
1La0cQliAQut6qhh27DGHsUjE3CksqvepV5XkFJskjqA46yyn2LGnBL45m/+12J4G48Bt/sPcoJo
nPG+w9lOc4LiV0Ipng0qmCPGrCiZSliEfCd5joxB8qTrY6QKiP3AvN4ZTgdFrMklZk1qBh9gVfKT
i2PV7+zyrKRkhTWFxT8aJF3i5GEf4ikFE7iQhPcuZeV9J3kFUEvVbfHiUnh8p+PhdyZ3gU+M6hOD
9gCPrjqn9YFUm0RCAV/vxqekcDb7Fs/mxZyNJenfY+p/bMqI71f/l8/PzsxG/f/nj/3/v59PPldY
yBUm0IRfRqnYmZqempqamZmbFSfZ9OzUwlx1fn6hWp2ZXpgpLEzlT9anZmr56crcTH26ki/MFqoL
+blZr56ve/n5k9V6pZ4/OV2pz9UX6rJaEKO52tl83tmsblZEzRVvs75Q3awWCrXKyc3p+ZmpQmGh
Mjc3O3vyZKU6d3K+XsnPbVZn50UTlepCrVqbncnXNhcqE+SKb3R3elp0t5afq8/XFurVuncyv1md
92Znq9WF6ZnKVF38l69OeflK/aQnWqtOz54sFOpViD2p1GbnxKXNuqpX6+/07IwjhlLIzxTmaie9
WfFIvTbrFRZmpguFGXFnc7o6W5nKz85tVsTfmfr8XLXgzc3VKgtz3ub01Oy8N/Uf2QbRbzPL/x1m
ABi+/2cg23dU/z89c5z/+/vS/693gbPeAXz0nuZgfyJQ8nYXsmZ6FCQkeCKfgXm2fXHmVbcrbcFo
kt7/SJm+BcPd9sdJDhDJBHCEoCItObhpOehVeo8VXPSLBlsRZIYDstvKn2Y0neoQRRiE1UuTG7hb
nzr9YyHoomKfMOwrnZ676Oy5Ww2UDHut/iVUStY29WATI/CEAyXcfRI73W6nZa2iXev6jVq25/vN
wKhMPljpXHi8B0E32W9WYg/L+9VKQDXLqqRCM6zTjKuRD4L/HT6oN7kvTS5lcPSLZGenVJRPvZQz
/6b+bnEj+1QJflDKqNxT2dJT6b9Tmqg25AdtiWUQcnck7/K1ESKrPemydFtDtA7vUlU8ADK8jouF
EQRhckYhkUKir8CBYP5duQV56/GvjLgsqgKTPWFqV5pcIafkFcKdfHKSVx+lgUTtUs455zttbwe8
egPBYYNbL6kZA3HZEzudNEn1GgHkoyigGXHQiLFSXn125dzZn1N68pXQCGNx3dEhS+q1CGAJoqfJ
mSG/R+3+2pm0GbU0YQVjAk9ZBGCq15QRoSUmtdyol8UW7u3q9hqjb5S8uYUp2SfGy8ysXFe4KFtR
LB5DMDS4kkNap2JC8Fdu6dzK+tIL59d/nnH4wtLPltfWrT4sNCRW0mpDQVPlkfXMKJeNpWfGkuPp
mbErFjUziyl0W9M0S+hYcfiI7VImbM1e6kIDnNRIC/tkhpHjpUO94VyLR1ffm8RrFJToXGj7O9Ii
9TTnlWu06xC3CsAHwXajQx46FSDdF7y2bB8tghALggeZzFcKkbHg4Yo02ZJXd8OtdS5sZf++75Hi
L/tTUggWf7hX21xcQ0irLP3Zl4CkEyqFgaoe6bW1erijKSb/vt/wekMqQvptrQjuyGQFWBXJ1kPq
IsprrQxvZcDxN+i5JUvSXb2wkO93VGFy9Haecug1u9mCa/g3G4GSXMtGvpTWsVjPCCIElWI2l0YP
gAQhqcum7/cCiMPphAZ7OHYm+WwKuZmc1aQJXTBXGxLdsBM4KziaCLxXkok2dLkcAbZqhSs5e7p8
6uzZontaxvLKl4NRZbww4LWa+NJ2a6zVX1flS7BNhbWegoJVssO1mvNidFiuGckpZJgpeOzeQ343
wWdJdwbxgiSg56Sbhqzt8CiqzIA0iJIIrW8apCNuclp1hhbI3BM4ByZeLTq7uSrFq5HZRJy18Jjg
q7t6uM2u18u5dqBcM0dCFEh2+Ltx274kaYEYuDi8XHPc8LrYXD7EtD8cDznaJYndNwTUBlH+JcKf
q6bBjVWqFmV0QfLjFKeNoKxZ5GZgJYkVmQ3r1NchO28g8AtECChtItB6S3ptCgQRx2iX8xBfqm0l
+bz87NnnyQEFAyLR4wNqNY69PeIvvMBvXuQ2qDOTrE4MXFyfFPwhxgY1ZKDVtB7zHnrFSBcdGT8B
fQfwxFaHo4T6jVp4QC4j1E6dqKFMOIwcJwf1SoQZwRPiYVn3m2J1gF/QhYDgqikBE7rnyKPRYKA4
Pw5UmmtSYmmLNreXWysvrwkmMYVZbYIeIqlyFly6APG3TxSh/3AV6xMjb1GIoLwkY27DKR0Nu4yz
k8QkycyiDQragLq1HLzoHcu3o17aGNnP93IdP5btiDxE8A1G50V6NCMKca9c8y7CuOREwE8xXOTz
VIwxbG65GnhObCYRy/CJYRasMw5Qug2JCWyStNrzUxTqldE7FP5otP3wB7y18BeGockfW41aaSKW
2UN/81odlr7LqRTnIoRvBEJW9mrUV2BKkUNPR/zNY3bdcLCyng3ZLICVaQMBO2u5HZTSUWDVVkdy
sRoiEtWZNtMuv9TWlPUq6xtUoPO5cUnBTklljrtV8LjssLkFtnq5DEho5XIKWB0JhqlNIFzORbE2
QhobRvwGORiRaz7IXn17yols0SkAzjwfIiB872eUpxz82jcQ0GXjRqr5UdYRMtQc3v4McE/fv/Pw
Uwi4fPSbvx689bEBH5o4CNNQYvTDbjWSabxUMfuWNMjV6tLzI8mVBieq30Wc6P/k5P381NQ4lkt9
QiD+6LXLBzdeO7x85eDquwc3f/not9cHX/3j4O7dx5kcfNOVi4g6p6HjhzNhSz3f79WzC27ajiQZ
BmJgvRkEHMfh4286HeVyCqHgbc9SWbXY0lpdycV5LcrC48yvTCLwyuDqJ/pcP/aEalsHezahtiv8
xNnVOmY65SCIpfLMeQ7tsGg33uHI4PDdSA+dmgfJeEj+BYEh8p5s7mO6uR/5F/YaMx0CEsN/FPFL
qbFmuA3oQAACDbptslAeR7mj5lBJZnFyEBunDqpQ2S2YmbafSltLRsygan5iuIFxjO7QyNtvI3HC
9BztrdAjC4tHtXfybfqbCFlflkuUiXCoptCjMrlqIKdK8pDoQlhW5dAQF6TqdwPqKtns43TmJ+tH
IsoRRkIPiGfeT44hCxVpibNGCn/bOOQYG8N0N9gN6M9+lIBgxbZwMJZZiuHW2gjpQinxAZo9eIz4
BaxfvGry0aYySDWocxultGWFYZO4b9PhPlYwFUBt+LUPc1M0XBW1uBqr1yI62no7kGyNnMSJT+Sz
Szfz6zBSsUpjfpMoNcT87FAesjxtcurezqKdxm1IilvS2Ufmv9MlTKoRaiYnkmY2wvRgeNZYe48k
pihNFRfb1W3lkhiX4hBUBh919XFGJ1vWkx62SSyAIILTkj4hsGxR0lsUA+5FeVZdkMMr/D48GYUh
hT9DTN3XYjnJ2xNvyJaMB42uyNYkH/TtCAG4W/IEDeHwjLWvyqs1EiurzZvhimpzwAsHFhkokEfd
EJSr95vNVqVX3eYNREcdluMLKjzD7swEIsiuzgwDwwtLXv6EYAuqStzQGtlPct1SnWXdv/EuhyRF
JG5VPm1jVmP93nCVFWn5WUSu3dAkyoxiTYU8V7KPHvS//BZl5Kk23xvyS2lxVEdIwnY1yhClaAl0
hrdriSXr3eTyEZqi+q8v1qRXbW9wT3Z7UXZaUYb90SfGKBom9TWgd4lSMkadY2RGhE9Low+1gc1q
R6Ljg6TMddhOE5Tux4QUGtXmmAhD2DIyEKYyMy6whyUNdTQaBfHOEany49C4o8AWjT9BY8EZxcLg
7SoNbcVyyy8CnA4tWyF8ijUbRQdyt6KXxYUjJAcHBSKsnDVQaIiKEhWOZsNpZiVoQSpF7IgdxGFf
LV/ntLukCOGNgjiDpGTGy3YWEXScYtcTKH+Jj3sTkoaxddyaXwlcq+HJDfo136WDw7yBz/D5TaVK
CsCFGEzRO78LvDNnyEtRv4EdaAWGzk4aFpjUKk+QuOgr68xgjSgcg/VDT8ZnChNmOmF++khKmQd3
/4JpH0Kp+eHv/unw6zsP7n9uhJYxSE9ASe21dAa2HsRzGGE8X7IUYVMnehIjaQyxX6a5JudazqYH
gXMM9PL65weXX2YVwMt/GHz0JrgO374FUXSAas9oiZBz8+q7FFUaOmE42ewFz+uQA0tcQSB7a4ui
wHFKmJo4HCzdNx9E7xSOvBi8eReDqhis6eDdzwZ/+FC9nr999TtEpvk/l19mwAauMK7MSbBvh6ZW
sG4rmFb2NHF2tj2wvjkgTiPpViZ0DwYUQFQTQFiRL4p4ISj55izVL/dkdkzvUge5tG1PNQOZMmu1
BoRvQM43KR9WIMRk/QR0B5lLTLCZs6Uc10B1mCZAdnYxIhmtA9QG8kzw/JTizESChX5UI9JqP27t
ptl+VO1syq9hro5xqo9Y8kfVLy21IyfIdlDZLP9qy0TN//aKR5rTreZysME9s7r00/K5lfKpF9dX
VpdeWPnJUtEtWJSYQ0ybQxB3JfGj7Qfprm4LunBdbP3BtTsPvrktyMeD+x8/uPv6o3d+e3jnToR8
JNMO58E3Nx/+828HV/4nYM188fHgyhcmORFvmk+/iKpInoS2U7RRL/vdxhawOxywisFEQb9lRq1H
mUXNuSjCXWlSrJIC5WEVj33XNQKgAZath1UjSUNAW56A628d3Pz44IN/O3jzD6ACf/dVomYE9BKz
tChYNqnXi0wAqSwiTERd6qjD6eADSmMppLJDntkxOG/SpkI1BuFO6TMRWmwdFtQpfgcygpohV3IO
E0RZTQ1sUd2iIoLr50JaWWxNastHHv9afIo6IokbIONDzOaitxqauJ8o6jcsx5j2zgmeYXDt7Yfv
/H5w7f3BG+8iqFLYEdv7lzlvGm3Df2XUsg+Lxj0DubPjlFFFjdXGKioUWnmmj6yfAqCm0CtAKgza
ETiI2DBlO5mo9G3dMZrmBZcxP6PaLSl/DVzOSgMRW9LqDsCqBxvZqUVM65uSInVGG4z57oavd+4Q
a1lK6aE4IKcpl9ZpsLaNWLOaMsZcrPJqhDKZdf/pV4N71x5+cBsq/uJfiEhRVkZayObeMKmmPoek
/4MTEsdJ9ixdb5OOeVYkKYEAdTtRwYNx/BatkI2rHDLQwz98cvDBN0PHGh/vGArWcXSFfEBZtY+w
hgzFof4iRywwXTdom47B178ZvPamo88K4wjj3Izx+i1qCTUKdVh9y8VBzuO+RDIitYRDjgviPOhD
/oT+ZgDpV8XscKYONUOiJ17OkNVk6uuwP1J/HdMHJ8wrelaEGlf8aabrQJLGl4cokrGIMU8Wiqw0
sqMKGKQdGWNJIMcjr2rOJp0IabIQXONMMFR++snACCtj6ffGyTQRsgWJ+iZzh6YMDN8nQgxfAmQI
9SVPxBMfsN8DDx10T6UodY9kTwhLg0pKd+aNsQP3Pnlw/+sIO0Bo3Cy8J9JZY54iMzsMul2btfBg
Se4hpVx4rB7qWl4bbLEuOsGSAQGvlERTNZBtjVZqZCNU3ZFj4rjau/BlhTWUrEzcg7u/AYiiu/fD
Y1EmpiCUR51ASt3L4Nrrzh7UvD+SZPJ8SD1JKLJLDBWeJKWggJS1Fz2VHDTnnBJkF6ghZFAAZ/F6
ow0ZQCt1uAi6BpWqFGJHWEURA5hQcid6ypt5R6JwadVmI4IMdgSRCa5ygBnc4K92iUzTq6NviXzu
vzQ6z6mHEICATMCLE1Eb16ZLCbMJQYpj0wAD+qU2/JtKv6R5inGjqT3GIM51MN4hzK1dBjGar5bL
UEG5DD/3xUjwHOpJ/Ag8IlAzajHEw/qX5cQyRswdo740+omgLx/oNgComiir8SgGrJjPQWkqKYm0
eLkyrzQI42UUxsMXpzt2KUCzqAvw2ovPriCtFg3I6B6ChXdRhSIIz9B8Li6lziW+VaJ5AWgAQCwS
WeEEP6Tze/vrB/c/CnfOD8QS73S9iw2/HzR3JYhFTQvcbFV2nUoTYWUFAYKwMMEYcJpdiNHJxYkn
RgIV9eTUMkTYSE4N0URjBkzJU5WqQUQW29RbAklwbZv5r4+UA/sorZvqkxGlGbq72Rgq3XF2W0pB
3kfjvUkrxP/SXRw1EIDJRt+4Ubq7XQnKYQmprTCs/FzLRf8CGtNkViu6Ug6dPVD9haVsh9zBrz96
9M5lZ4+L7DsHN2/JZQlL8uCtqwc3fxkuQHms8JpJyGeuFw3KSGwNg1+jblRk8eCMWejitckWIVt5
GaK9ahJuPDDm8jtAnuf5k0DxVwDgAxNmK6joB1/97vDOzRgIffJojFAMoCz6EsAAFFxP4CYeTnpI
jsnRN61mMspzQYrvg/fvENZg1PeUun7jU9BsfvYKnd+gmbt3nawpD2/dPrz9UWgPuvZ6mHMlzJwi
Ox/tOAwm3EgxIhGz/kULRPR6ZvRQqMYj+sy6iFiQgK6zMZV/0iEgsf/xRnSLbDo2IEMKMNsyTLnW
fISRF5qJ0uKwtZQBvZZOdHY095tccWE9xkYcUQksQS3or9kwpTYUtqKMK1C8ZPb60c0PY8lIIHH8
1etiuZH8DZtIVBJifWvEcER/YenRNCVIoBERUicbEpQqad7iRzuPAxhkqTigU1xsD7HHKHX2wY03
B6/fYuPj9beAZb52Z/DKm3TqP7h7+eDTW4Mbf3p47xudAyAa8+jl90Ai0bJVEJkJtx/tdTmhbDZk
o4WLaZx3Gr+odGvfIfjHaPyf+dnpvIn/kZ+fm5o5xv/4nvA/fnJ+TW62628P7nwFO+3+1Yef3Dn8
628GVz4e/PqNwY3PBjcvD+7fO7x9G1aODvHd63VyYjuC7x5fanQqtVpXw9PQ8TuOgODd7zYhWqsL
KqygF4KL6BKHlFsuVpqY56UMWYiZk+tjvrsydybFfyPpTMWWlneAJvTbQcerovMsKjLCO03f7yAE
oXm51W/2GtVK0LNZZfTHBaUpEw6meQMsoF20JFGvsYzstJGROO6mAoMFau/GxUP2xBgPSjqsCAy0
y8kw0mHIskSUnvr2gNJhZqnRIadcVk1P6HOCWY4xra09zHcoN8n1AXveUe+mo5YO1hvjHm3qIqtp
qjFiLUZ6EWYwksWMTJ2ykMRP6G82G9WytwVXVQNdbwvy7LhbTX+z0pTroyZklEAsV0jnIVGVW7uN
jhir+Kft9SbD+LAG5FQhTFrEbtVhmOdm4In6bs7vbrlq9gEGGriWlGwmY1ZCIdbYMXRLqLY5kD5l
FMuobqaHvTKUDE0SkRM/UTZF9F65QqcZqDLoCEnAYumHJIQUuowFSHcwlZ9ZSMfhLcwIKngyveEC
L+eWNtxGx0WHM4TDLoaTjWOEsnGIfy1AesyliN1IW4IqJD2hN054MeMsOiN0sWsuuZGiktQzZ5z1
3Y68qB0JuTPr6+eXsAbxbtND9okZCIlhVP0t8CBAip4Kgm05jowTWdwZhxa/HosB3lfhI7bZ0G6T
7ki/ok0k5VOwpoKPkzKYQb1iQU7ZmgTCM3FnboyCxUi+2lKy/w1t3xtK31h/rdHQ+ovNQFaeTw9u
3Btc+fTh12/T0e4yEcdtCLudZhQ9C4bQF8UZyydjEyJvQKt/vHzwv341uPoZ2Gmp7VfvDa79UbC8
5Fp3+PWng2tvH7z3uQrIcx/jXT7WO4EuvXIlMh3h9HqBtVZ1FxBKwnmNVaStbVEKco/e+mTwym+d
FypVZ/Dlv8KIv/nw4K2PoRe///3g+puQq3H5vKs0Up3mbgpUSQ2cSXGutpRDC0FU0SXw+nNs0Mri
LCmCPjIKsSzzEnLVSPqamFFB5zngSlTOWVp5znAaBdnm2rsHn1+NZdqglCNM6DhxaHChjEeqNqhm
ZdMD0k8pjjOKoeNhBv065YGsu87GHpfaL6H7Lv9C9CrR3TB9JqMVUBA/jDochaTm0bnFboh55PZg
Qv/35Xvu6NyHsr9EoFEvA0uE+5Ye0c/0EOYiQedELx7awJvp2GuXsw1rH2koHR0SeuwZQP2DZDUA
S0I5tMmzExB8EVq+LdbgxTkDnB4yR/p1mQJIGmiUKRshnnTskw12oqY74BxK10t83V1EIyzejr8c
/LtRWMwWShOWqdZHpY0V5AFjrKpnjQAP3pTep0ZQa2xhOhy4BuYEetT5UdGZxWsF+ApzHd6Ym52d
no2RhLDMRKKun0QqUaegg1SN8+DLXz1679+kzl+IXYIm6hkSqts+AJuFaxRhxIvuw7c+A19g3H4A
ES94C9jmh1/86+E3r7pqKxULPA1H2QZil4k+7mFL+6LclLNH9Ysf2vajvWFkX9HoRuSt6tl3eCcA
ao3+FHUHNV8FEEXQmrTrBQk4OdGAEe3xKUSFIWiYsVB2GNpef0VAhafIefPgjdcGH3x4+PV/f/Tq
q2ABvv/+4e2PHl1+7dGtL+FVWfbecWa548/x5/hz/Dn+HH+OP8ef48/x5/hz/Dn+HH+OP8ef48/x
5/jz7/35v64jhfYAMAIA

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
