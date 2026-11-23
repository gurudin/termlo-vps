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
    if [ "$family" = brew ]; then
        case $names in '--cask '*) brew_cask=1 ;; *) brew_formula=1 ;; esac
    fi
    fix=$(package_hint "$@")
    if [ "$manager_ok" = 1 ] && package_available "$names"; then
        doctor_pass "$label 安装来源  已确认 $names 可用，安装时补齐"
    else
        doctor_block "$label 安装来源  无法确认 $names 可安装" "$fix"
    fi
}

apt_packages_available() (
    if apt-get -s --no-remove --no-install-recommends install "$@" >/dev/null 2>&1; then return 0; fi
    # Minimal images can have empty indexes. Resolve against temporary lists;
    # do not update the host's APT state or run its post-update hooks.
    [ -n "$scratch" ] && has mkdir || return 1
    if [ ! -d "$scratch/apt-lists" ]; then
        mkdir -p "$scratch/apt-lists/partial" || return 1
        cat > "$scratch/apt.conf" <<'APT'
#clear APT::Update::Pre-Invoke;
#clear APT::Update::Post-Invoke;
#clear APT::Update::Post-Invoke-Success;
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
APT::Update::Error-Mode "any";
Acquire::http::Timeout "8";
Acquire::https::Timeout "8";
APT
        if apt-get -c "$scratch/apt.conf" -o "Dir::State::lists=$scratch/apt-lists" update >/dev/null 2>&1; then
            : > "$scratch/apt-ready"
        fi
    fi
    [ -f "$scratch/apt-ready" ] &&
        apt-get -s -c "$scratch/apt.conf" -o "Dir::State::lists=$scratch/apt-lists" \
            --no-remove --no-install-recommends install "$@" >/dev/null 2>&1
)

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
        hint="请在可联网设备运行 curl -fL -o $name ${url}，把文件放到远端后设置 export TERMLO_MUTAGEN_ARCHIVE=\"\$PWD/$name\"。"
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
    if [ "$status" != 3 ]; then doctor_block "远程浏览器  $browser" "${fix}；按上面的错误修复后重试。"; return; fi
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
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
PssACAIA

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
