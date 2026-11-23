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
    agent=$agent_dir/mutagen-agent
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
Abz3AZgACAIA

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
