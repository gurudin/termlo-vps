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
    if has apt; then printf '%sapt update && %sapt install -y --reinstall apt\n' "$1" "$1"
    elif has aptitude; then printf '%saptitude update && %saptitude reinstall -y apt\n' "$1" "$1"
    elif deb=$(cached_apt); then printf '%sdpkg -i "%s"\n' "$1" "$deb"
    elif metadata=$(indexed_apt); then
        read -r url sha <<META
$metadata
META
        printf '可从发行版软件源恢复。手动运行 (d=$(mktemp -d) && cd "$d" && curl -fLO %s && echo "%s  %s" | sha256sum -c - && %sdpkg -i %s)\n' "$url" "$sha" "${url##*/}" "$1" "${url##*/}"
    elif has python3 && python3 -B -c 'import apt' 2>/dev/null; then
        printf "%spython3 -c 'import apt; c=apt.Cache(); c.update(); c.open(); p=c[\"apt\"]; c._depcache.set_reinstall(p._pkg, True) if p.is_installed else p.mark_install(); c.commit()'\n" "$1"
    elif has pkcon; then printf '%spkcon --noninteractive install apt\n' "$1"
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

# These are tools Termlo installs. A missing tool passes only if its delivery
# route can be verified. Installer prerequisites themselves must already work.
doctor_component() {
    label=$1; shift
    packages_needed=1
    case $family in
        apt) names=$1 ;; rpm) names=$2 ;; apk) names=$3 ;; brew) names=$4 ;; *) names=$1 ;;
    esac
    fix=$(package_hint "$@")
    if [ "$manager_ok" = 1 ] && package_available "$names"; then
        doctor_pass "$label 安装来源  已确认 $names 可用，安装时补齐"
    else
        doctor_block "$label 安装来源  无法确认 $names 可安装" "$fix"
    fi
}

package_available() (
    # Names and options come exclusively from doctor_component's fixed package lists.
    set -f
    set -- $1
    case $family in
        apt) apt-get -s --no-remove --no-install-recommends install "$@" >/dev/null 2>&1 ;;
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
    version=${manifest%%'
'*}
    agent=$mutagen/agents/$version/mutagen-agent
    if [ -x "$agent" ] && [ "$("$agent" version 2>/dev/null)" = "$version" ]; then
        printf 'Mutagen 同步代理  %s 已就绪\n' "$version"; return 0
    fi
    case $system in Linux) os=linux ;; Darwin) os=darwin ;; *) echo '请使用支持的 Linux 或 macOS 设备。'; return 1 ;; esac
    case $machine in x86_64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo '请选择支持的 64 位处理器。'; return 1 ;; esac
    while read -r target asset digest; do
        [ "$target" = "${os}_$arch" ] || continue
        name=mutagen_${target}_v$version.tar.gz
        url=https://github.com/mutagen-io/mutagen/releases/download/v$version/$name
        file=${TERMLO_MUTAGEN_ARCHIVE:-$scratch/agent.tar.gz}
        hint="请在可联网设备运行 curl -fL -o $name $url，把文件放到远端后设置 export TERMLO_MUTAGEN_ARCHIVE=\"\$PWD/$name\"。"
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
    if [ "$status" != 3 ]; then doctor_block "远程浏览器  $browser" "$fix；按上面的错误修复后重试。"; return; fi
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
    payload=$1; manifest=$2; release=$3; scratch=$4; shift 4
    system=$(uname -s) || system=未知
    machine=$(uname -m) || machine=未知
    passed=0; failed=0; packages_needed=0; admin_needed=0; full=1; check_only=0
    port=22; key=''; claude='安装时可选择'; manager=''; manager_ok=0
    printf '\nTermlo 安装前体检清单\n' >&2
    if [ "$#" -eq 0 ]; then
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
        *) doctor_block "远程系统  $system $machine" '请使用 64 位 Intel/AMD 或 ARM 的 Linux 或 macOS 设备。' ;;
    esac
    uid=$(id -u) || uid=''
    priv=''
    if [ "$uid" != 0 ]; then
        if has doas && ! has sudo; then priv='doas '; else priv='sudo '; fi
    fi
    if [ -z "$uid" ] || { [ "$system" = Darwin ] && [ "$uid" = 0 ]; } ||
       { [ "$uid" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; }; then
        doctor_block '安装账号  无法使用当前账号安装' '请使用平时登录这台设备的 SSH 账号，直接运行安装命令。'
    else doctor_pass "安装账号  UID $uid"; fi
    config=${XDG_CONFIG_HOME:-$HOME/.config}/termlo
    mutagen=${MUTAGEN_DATA_DIRECTORY:-$HOME/.mutagen}
    for path in "$config" "$HOME/.ssh" "$HOME/.local/bin" "$mutagen/agents/${manifest%%'
'*}"; do
        if writable_directory "$path"; then doctor_pass "安装目录  可写入 $path"
        else doctor_block "安装目录  无法写入 $path" "请确保 $path 是当前 SSH 用户可读写的目录，或恢复其上级目录的写权限。"; fi
    done
    if [ -d "$HOME/.local/bin/termlo" ]; then
        doctor_block '命令安装位置已被目录占用' '请移动该目录后重试：mv "$HOME/.local/bin/termlo" "$HOME/.local/bin/termlo-directory"'
    fi
    if [ -e "$HOME/.ssh/authorized_keys" ] && ! { [ -f "$HOME/.ssh/authorized_keys" ] && [ -r "$HOME/.ssh/authorized_keys" ]; }; then
        doctor_block 'SSH 授权文件无法读取' '请将 ~/.ssh/authorized_keys 恢复为当前账号可读的普通文件。'
    else doctor_pass 'SSH 授权文件  可创建或读取'; fi
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
    if curl --version >/dev/null 2>&1; then doctor_pass 'HTTPS 下载工具  curl'
    else doctor_block 'HTTPS 下载工具  curl 不可用' "$(package_hint 'curl ca-certificates' 'curl ca-certificates' 'curl ca-certificates' curl)"; fi

    if [ -n "$scratch" ] && [ -w "$scratch" ]; then doctor_pass '临时目录  可写入'
    else doctor_block '临时目录无法写入' '请恢复 TMPDIR 的写权限及可用空间后重试。'; fi

    ssh_fix=$(package_hint openssh-client openssh-clients 'openssh-client-default openssh-keygen' openssh)
    missing=''
    for tool in ssh scp ssh-keygen ssh-keyscan; do has "$tool" || missing="$missing $tool"; done
    if [ -z "$missing" ]; then doctor_pass 'SSH 客户端工具  ssh、scp、ssh-keygen、ssh-keyscan'
    elif [ -n "${SSH_CONNECTION:-}$key" ]; then doctor_block "SSH 客户端工具  缺少$missing，无法核验现有连接" "$ssh_fix"
    else doctor_component "SSH 客户端工具（缺少$missing）" openssh-client openssh-clients 'openssh-client-default openssh-keygen' openssh; fi

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
    if agent=$(check_agent); then doctor_pass "$agent"
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
    if [ "$packages_needed" = 1 ] && [ "$family" != brew ]; then admin_needed=1; fi
    if [ "$admin_needed" = 0 ]; then doctor_pass '安装权限  本次无需系统提权'
    elif [ "$uid" = 0 ]; then doctor_pass '安装权限  当前账号有系统安装权限'
    elif "${priv% }" -n true </dev/null >/dev/null 2>&1; then doctor_pass '安装权限  已验证系统安装权限'
    elif [ "$check_only" = 0 ] && [ "$failed" = 0 ] && ( : </dev/tty ) 2>/dev/null && as_root true </dev/tty; then doctor_pass '安装权限  管理员已授权'
    else doctor_block '安装权限  尚未取得系统安装权限' "请在交互式 SSH 终端运行 ${priv}true 完成管理员授权，或请管理员按清单补齐组件。"; fi
    if [ "$full" = 1 ]; then printf '  Claude Code（选装）  %s\n' "$claude" >&2; fi
    if [ "$failed" -gt 0 ]; then
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
H4sIAAAAAAAC/+y9e3cb1dko3r/1KYbBqaTEki9JDCiopyYx4NUkzoqdlr6Oj9ZYGtnTyJLQSEmM
43eFtw1JIDcod0Jp2lAolCSllIRcYK3zUU4tX/7iK/yey9579p6L7NCW9/zOwV0lmj179n0/98ts
o9H22y2nmffnf/Rv+huEv5Fdu+hf+Av/O/zYbvWOy4cGdw6P/Mga/NH38Nfx204Luv/R/5t/jz4y
MOvVB/z5lO+2rZzbSfmNTqvslipeq9iX2bvv0OjUs0WrXLFyOcvuy0Bx3Vlw+WnQztrWj39sNU9U
sqk8FATfDjQX2/ONeq7Vqbe9BRdOlx2p0XJb7vMdz/farh9XodIotxsteuMv+m13AQbU4d79bKrs
+K7Vxy8sr27tc1onvHrWogHbA41me2C+seDOttwTOMXCQMdvDdQaZadGj31Yz7b27LG2y2+oiOv5
9AX+l6q4vlNOuSebjVZb1n124sDYQF5rjwvqzYXcXK0xa/Qixro0VMgtw1BTFvzl5k/lcvNurZml
R/xrtrx6u2qlt/lH62kr7c9DXTidtRosgTWdy5Xn3fKxGfw13/DbVvfqre77p+mZBta9+VX3+ptr
n97sXv6jqpU75i5aK3furV692z3zl43XPqQ3tIjdKxfXPro1k7aOqhHgX9oy/qD2Ca89nyvXnE7F
tU5Z/NzotPUif7FezjXqtcWZyMA7dfGATR1z3Wau3WjU/Jm06tU96bWtQVhnKlH1YX3U72CR/Hmv
2lZPsGBuCw4S/BcOR9WrV0p88LLWqVPWkuWW5xtWunvxzvqDBxtXT6//6UXrEL23duYft1bPvbn6
3hcbn769dv7c6tW//OP0f63fvL3+zZX1axcscxJi8a3VDz5cu/oK1IX1XHv3N7Kx7o3z63880331
wcq969BK2vrJj4f38LyG9ljL2kzdMpxxbdS2lXvKPPVQuFBr5JuLtrZ0dt9P8SCm6CD65ZbTLs/D
hBeOweFvWrkKTVeWp9Mpr2pNW7k6tsyFtjWzx2rPu3ULgb2Vbi1YuVaVr7GskrbGnhuf2mNVvRQP
osQ30BifjVCg7LTNQS902s6cC9fdrblw1v18+2QbgcOA2y4PNHxZro8Hp5SqQutOa86qNGC8dh/8
tK1Himq5Z3BafDz2QJ26yxOz+x61rSIcGTknWtcnByru8YF2e5FmwCtQDXocwAG28wDt83Mv2Nqn
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

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
