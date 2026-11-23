#!/bin/sh
set -eu
termlo_unavailable_bundle() (
find_python() {
    for interpreter in "$@" python3 python3.14 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
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

rpm_manager() (
    for tool in dnf yum microdnf; do
        if "$tool" --version >/dev/null 2>&1; then printf '%s\n' "$tool"; return 0; fi
    done
    return 1
)

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

doctor_arguments() {
    while [ "$#" -gt 0 ]; do
        case $1 in
            --check) check_only=1 ;;
            --sync-only) full=0 ;;
            --with-claude) claude='已选择安装' ;; --without-claude) claude='已选择跳过' ;;
            --port|--host-key|--host|--name)
                if [ "$#" -lt 2 ]; then doctor_block "安装参数 $1 缺少值" '请补齐这个参数的值，或运行原安装命令。'; break; fi
                case $2 in --*) doctor_block "安装参数 $1 缺少值" '请补齐这个参数的值，或运行原安装命令。'; shift; continue ;; esac
                case $1 in --port) port=$2 ;; --host-key) key=$2 ;; esac
                shift ;;
            --port=*) port=${1#*=} ;; --host-key=*) key=${1#*=} ;; --name=*|--host=*) ;;
            *) doctor_block "无法识别安装参数 $1" '移除该参数后重试。' ;;
        esac
        shift
    done
}

termlo_doctor() (
    payload=$1; manifest=$2; release=$3; scratch=$4; interactive=$5; shift 5
    system=$(uname -s 2>/dev/null) || system=未知
    machine=$(uname -m 2>/dev/null) || machine=未知
    passed=0; failed=0; packages_needed=0; admin_needed=0; full=1; check_only=0
    port=22; key=''; claude='安装时可选择'; manager=''; manager_ok=0; brew_formula=0; brew_cask=0
    printf '\nTermlo 安装前体检清单\n' >&2
    doctor_arguments "$@"
    argument_errors=$failed
    if [ "$interactive" = 1 ]; then
        if ( : </dev/tty ) 2>/dev/null; then doctor_pass '交互终端  可用'
        else doctor_block '安装向导需要交互终端' '请在设备控制台或交互式 SSH 会话中运行安装命令。'; fi
    fi
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
            if manager=$(rpm_manager); then manager_ok=1; doctor_pass "系统包管理器  $manager"
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
    connection_ok=1
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
        else
            doctor_block "已有文件 $record 无法使用  $reason" "请检查 $config/$record 的内容、所有者和读写权限，然后重试。"
            if [ "$record" = connection.json ]; then connection_ok=0; fi
        fi
    done
    listen_port=$port
    if [ "$argument_errors" = 0 ] && [ "$connection_ok" = 1 ] && [ -n "$py" ] && [ -n "$payload" ]; then
        if resolved=$("$py" -IB -c 'import sys; sys.path.insert(0, sys.argv[1])
from termlo import preflight_port
try: print(preflight_port(sys.argv[3:], sys.argv[2]))
except (OSError, ValueError, RuntimeError) as error: sys.exit(str(error))' "$payload" "$interactive" "$@" 2>&1); then
            listen_port=$resolved
            doctor_pass 'SSH 连接参数  可用于本次安装'
        else doctor_block 'SSH 连接参数无法使用' "$resolved
             请修正上方参数，或直接运行原安装命令进入向导。"; fi
    fi
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
    elif keys=$(scan_ssh "$listen_port"); then
        if [ -n "$scratch" ] && ! printf '%s\n' "${keys%% *}" > "$scratch/ssh-port"; then
            doctor_block 'SSH 监听端口无法记录' '请检查临时目录的可用空间和写权限。'
        else doctor_pass 'SSH 服务及主机密钥  已从本机 SSH 端口取得公钥'; fi
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
        case $key in '~/'*) key=$HOME/${key#\~/} ;; esac
        if [ -f "$key" ] && [ -r "$key" ] && ssh-keygen -lf "$key" >/dev/null 2>&1; then
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
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
48+3/fkvqbkQ7QBYAgA=

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
