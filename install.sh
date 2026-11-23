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

ubuntu_release() ( [ -r "$1" ] && . "$1" && [ "${ID:-}" = ubuntu ]; )

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

# Package names come from the installer's fixed lists and cannot contain commas.
apt_archive_group() (
    state=$1; shift
    IFS=,
    printf '%s/apt-archives/%s\n' "$state" "$*"
)

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

can_generate_sshd_key() (
    case $1 in
        /etc/ssh/ssh_host_rsa_key|/etc/ssh/ssh_host_ecdsa_key|/etc/ssh/ssh_host_ed25519_key)
            [ ! -e "$1" ] && [ ! -L "$1" ] ;;
        *) return 1 ;;
    esac
)

check_sshd_config() (
    scratch=$1; system=$2; priv=$3
    daemon=$(command -v sshd) || return 1
    set -- "$daemon"
    if [ -n "$priv" ] && "${priv% }" -n true </dev/null >/dev/null 2>&1; then
        set -- "${priv% }" -n "$daemon"
    fi
    if reason=$(LC_ALL=C "$@" -t 2>&1 >/dev/null); then return 0; fi
    case $reason in *'no hostkeys available -- exiting.'*)
        # ssh-keygen -A only creates missing default identities. A temporary -h
        # key alone would also make a configuration with unusable custom keys pass.
        generates=0; listed=0
        if effective=$(LC_ALL=C "$@" -G 2>/dev/null); then
            while IFS= read -r line; do
                case $line in 'hostkey '*) can_generate_sshd_key "${line#hostkey }" && generates=1 ;; esac
            done <<CONFIG
$effective
CONFIG
        else
            # Older sshd reports each explicitly configured unusable key on stderr.
            while IFS= read -r line; do
                case $line in *'load host key: '*)
                    listed=1; path=${line#*load host key: }; can_generate_sshd_key "${path%"$(printf '\r')"}" && generates=1 ;;
                esac
            done <<DIAGNOSTICS
$reason
DIAGNOSTICS
            if [ "$listed" = 0 ]; then
                for path in /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ed25519_key; do
                    can_generate_sshd_key "$path" && generates=1
                done
            fi
        fi
        if [ "$generates" = 0 ]; then
            printf '%s\n' "$reason" '请修复 sshd_config 中的 HostKey 路径或权限，或恢复发行版默认的 HostKey 配置。'
            return 1
        fi
        [ -n "$scratch" ] && [ -f "$scratch/pairing-check" ] || return 0
        if reason=$(LC_ALL=C "$@" -t -h "$scratch/pairing-check" 2>&1 >/dev/null); then return 0; fi ;;
    esac
    # prepare_sshd creates this directory before starting the Linux service.
    last=${reason##*'
'}
    case "$system/${last%"$(printf '\r')"}" in
        'Linux/Missing privilege separation directory: /run/sshd'|'Linux/Missing privilege separation directory: /var/run/sshd') return 0 ;;
    esac
    printf '%s\n' "${reason:-sshd 配置检查失败}"
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

doctor_base_tool() {
    label=$1; package=$2; shift 2
    selected=$(command -v "$package" || :)
    if [ -n "$selected" ] && { [ "$system" != Darwin ] || [ "$selected" != /usr/bin/git ] || /usr/bin/xcode-select -p >/dev/null 2>&1; }; then
        if [ -n "$py" ] && [ -n "$payload" ]; then
            probe=$("$py" -IB -c 'import sys; sys.path.insert(0, sys.argv[1])
from termlo import base_tool_state
print(base_tool_state(sys.argv[2:]))' "$payload" "$@" 2>/dev/null) || probe=unknown
        elif has timeout; then
            if timeout 10 "$@" </dev/null >/dev/null 2>&1; then probe=ready; else probe=unknown; fi
        else
            doctor_block "$label  已找到命令，暂时无法验证" '请按清单补齐 Python 或安装包解压工具，再运行同一条命令。'
            return
        fi
        if [ "$probe" = ready ]; then doctor_pass "$label  可用"; return; fi
        case $selected in
            "$HOME/.local/bin/$package"|"$HOME/.npm-global/bin/$package")
                if [ "$probe" != repair ]; then
                    relative=${selected#"$HOME/"}
                    doctor_block "$label  优先执行的 $selected 无法使用" "请修复该命令。若要使用系统软件包，可先运行 mv -i \"\$HOME/$relative\" \"\$HOME/$relative.disabled\" 后重试。"
                    return
                fi ;;
        esac
    fi
    missing_base="${missing_base:+$missing_base }$package"
    if [ "$package" = adb ]; then doctor_component "$label" adb android-tools android-tools '--cask android-platform-tools'
    else doctor_component "$label" "$package" "$package" "$package" "$package"; fi
}

apt_packages_available() (
    [ -n "$scratch" ] && has mkdir && has cat || return 1
    group=$(apt_archive_group "$scratch" "$@") || return 1
    if [ ! -f "$scratch/apt.conf" ]; then
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
        archives=$group/$route
        mkdir -p "$archives/partial" || return 1
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
            for deb in "$archives/${package}_"*.deb; do
                if [ -s "$deb" ]; then found=1; break; fi
            done
            [ "$found" = 1 ] || continue 2
        done
        : > "$archives/verified" || return 1
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
        -o "Dir::Cache::archives=$archives" -o "Dir::Log=$lists" \
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
    case $mutagen in /*) ;; *) echo '请将 MUTAGEN_DATA_DIRECTORY 设置为绝对路径，或取消此变量以使用当前账号的默认目录。'; return 1 ;; esac
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
    if ! writable_directory "$agent_dir"; then
        printf '请让当前账号能写入 %s，或将 MUTAGEN_DATA_DIRECTORY 指向当前账号可写的绝对路径。\n' "$agent_dir"
        return 1
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
        doctor_block "远程浏览器运行账号  $browser" '运行 getent passwd termlo-browser 和 getent group termlo-browser 核对账号和组。请管理员处理同名冲突后再重试。'; return
    fi
    ubuntu=0
    if [ "$family" = apt ] && ubuntu_release "$release"; then ubuntu=1; fi
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
    else
        case $machine in x86_64) snap_arch=amd64 ;; aarch64|arm64) snap_arch=arm64 ;; *) snap_arch=$machine ;; esac
        if [ -n "$scratch" ] && { snap --version >/dev/null 2>&1 || package_available snapd; } &&
                curl -qfsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 16 \
                -H 'Snap-Device-Series: 16' -H "Snap-Device-Architecture: $snap_arch" \
                'https://api.snapcraft.io/v2/snaps/info/chromium' -o "$scratch/chromium.json" &&
                "$py" -IB -c 'import json,sys; sys.path.insert(0, sys.argv[1])
from native_browser import stable_chromium_snap
with open(sys.argv[2]) as response: sys.exit(not stable_chromium_snap(json.load(response), sys.argv[3]))' \
                    "$payload" "$scratch/chromium.json" "$snap_arch" 2>/dev/null; then
            packages_needed=1; doctor_pass "远程浏览器安装来源  Snap 提供 $snap_arch 的 Chromium 稳定版"
        else doctor_block "远程浏览器安装来源  无法验证 $snap_arch 的 Chromium 稳定版" "$fix"; fi
    fi
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
    passed=0; failed=0; packages_needed=0; admin_needed=0; check_stopped_sshd=0; full=1; check_only=0
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
    for path in "$config" "$HOME/.ssh" "$HOME/.local/bin"; do
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
    elif [ -n "${SSH_CONNECTION:-}$key" ] && { ! has ssh-keygen || ! has ssh-keyscan; }; then
        doctor_block "SSH 客户端工具  缺少${missing}，无法核验现有连接" "$ssh_fix"
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
        elif has sshd; then check_stopped_sshd=1
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
    else doctor_block 'Mutagen 同步代理  无法复用或安装' "$agent"; fi

    if [ "$full" = 1 ]; then
        missing_base=''; previous_failures=$failed
        doctor_base_tool Git git git --version
        doctor_base_tool tmux tmux tmux -V
        doctor_base_tool ADB adb adb version
        # The installer passes these missing tools to APT in one transaction.
        case "$family/$missing_base" in apt/*' '*)
            if [ "$previous_failures" = "$failed" ]; then
                if package_available "$missing_base"; then doctor_pass "APT 组合安装  $missing_base 可一同安装"
                else doctor_block "APT 组合安装  $missing_base 无法一同安装" "运行 apt-get -s --no-remove --reinstall install $missing_base 查看依赖错误，再用 apt-cache policy $missing_base 核对候选版本及软件源。修复后重试。"; fi
            fi ;;
        esac
        doctor_browser
        if [ "$system" = Linux ] && [ "$uid" = 0 ]; then
            if has useradd || id -u termlo-browser >/dev/null 2>&1; then doctor_pass '浏览器账号  可创建或复用'
            else doctor_component '浏览器账号创建工具 useradd' passwd shadow-utils shadow ''; fi
            if has runuser; then doctor_pass '浏览器运行工具 runuser  可用'
            else doctor_component '浏览器运行工具 runuser' util-linux util-linux 'cmd:runuser' ''; fi
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
    if [ "$check_stopped_sshd" = 1 ]; then
        if reason=$(check_sshd_config "$scratch" "$system" "$priv"); then
            doctor_pass 'SSH 服务配置  已检查，安装时生成缺少的主机密钥并启用服务'
        else doctor_block "SSH 服务配置无法通过检查  $reason" "请按上方提示核对配置文件和行号，然后运行 ${priv}sshd -t 复查。"; fi
    fi
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
H4sIAAAAAAAC/+y9e3cT17k43L/1KYbBVBKx5AuEpCbqqQNOw1sCLCBtzwH/tMbS2FYtS4pGAoxx
F2lCgHBNmntIc4MkzQVomgaCIVnr/Sinlmz/la/wPpe99+y9Z0Y2tMnvrPeENiCN9uzrs5/7ZaJe
bwWtptfIB9M/+4H+DMKfbVu30r/wx/53+JFtW+Rnfj40uGV428+cwZ/9CH/aQctrwvA/+9/5Z+OG
gYlKbSCYTgV+y8n57VRQbzdLfrFcaRb6Mjt27hs9+GTBKZWdXM5x+zLwuObN+vxt0M26zs9/7jSO
lrOpPDwI3x1ozLWm67Vcs11rVWZ9gC430qLpN/1n2pWg0vKDuAbleqlVb9IvwVzQ8mdhQm0ePXCG
fzlQ9o8M1NrVatY5ccIRLdLpVMkLfKePvzuVmrPTax6t1LIOrcQdqDdaA9P1WX+i6R/FtY8MtIPm
QLVe8qr0tQ/buc727c5m+Q494nYBvYF/UxM/8Eop/1ij3mzJtk/ufWpsIK/1xw9qjdncVLU+YYwi
5jo/NJJbgKmmHPiTmz6Ry0371UaWvuKfRrNSa0066U3B4VraSQfT0BbAtlqFvXEO5XKlab80M46f
putBy+lcudl55yR9p4l1bnzTufra8mc3Opc+VK1yM/6cs3R7sXvlTufU56svX6NfaHc7ly8sf3xz
PO0cVjPAP2nH+AOtj1Za07lS1WuXfeeEw9/r7Zb+KJirlXL1WnVuPDLxdk18wa5mfL+Ra9Xr1WA8
rUb1j1VaziDsMz1R7WF/1Odwk4LpymRLfYMN85sAYfA3QM1kpVYuMkQSsMw7fmm67qQ7F26v3Lu3
euXkykfPOvvod2dL/lGne+a17ttfrX72xvLZM90rn//z5J9Wbtxa+e7yyvvnHXMRYvOd7rvXlq+c
g7awn8tvPS8761w/u/Lhqc5L95YWr0IvaeeXPx/ezusa2u4saCv1SwD82qxdJ/e4eR3g4Wy1nm/M
udrWuX2/QkBMESAGpabXKk3DgmdnAPgbTq7Md0M8h8tRmXQOObka9swPXWd8u9Oa9msOUgEn3Zx1
cs1Jvt+ySdoZ+/2ug9udyUqKZuiVWpUjfmGQe3P7NrpOAc5JdqS3GaK3eOpFvtDGqlxEKiWvZS51
tt3ypnzAHn7VhxsS5FvHWohrBvxWaaAeyOf6KsTm8bAu7UtqEgbzmlNOuU7ThI+us6Ggzmwc94Zh
bDu0qfkJ66HDeYzQTas1F27DmuAlgeDWl0u3L3Qu3Vh+5ZPv754HUFo9faH72k0GKB1Euh+eREC6
eKPzwXNx4LIGhEwoYo5Aom2ODi0pA//rr/xfov+Dw1ui9H/L8E/0/8f447rujjqQ6FrbR2B3Jtq1
ctUvS4jx4QJNAqw5lVbg7Nt7YNfvgRj5k9XK1HTL8WplR9B3B7iHdiMPvaUqs0R0gP6mUpPN+qzD
l98Rz2c9oHMp/DujeiJmA17Iww09km/UG5mhbDb1s5/+/PB/Imzaj3//hwa3PWLd/6Etg4/8dP9/
jD8a6cpknXliSJBsanQGeWhiM7jZFvlvfmhr+FF7Ohx+HAo/DqqPv1CfHkWyq3igUn12FlFK7ojN
CYWsPrD9Px9CElsSSCtk+Jh0ZxJ7ySJRJx4eBR65lnGUX+hFKVlQO5YZJAdgsMGqi2OletnPBcCK
lEByaqxrlsA6yI82Ld/1uJMrOWmJPoNqP+LQfud4tTKxHT/mkQ/I4IcjfjOo1GvFSm2y7jzmZLb0
O49ms+l1zcCUJcxJqEbwtd2sOYP0gDgj7elQauEn3Pz/G/xvCeE/Pv+3ZXjLtiEb/w8P/cT//Tj6
H8HVocIBsApIt14T2L+JOeIGFRfYTwxg0/fKJMw7JEAFxAHq7crOjt278qlpL0BiYmL0oQgeR4km
1QaOs9UuCokOXsuggNrkFwg75/mzwNPzu3aO5BYQR/ObiKOzqVSzMVuEsUBqbGIfio6hSgEJWLk2
6cy1Z53ZSqlZhy8G5QHa4fZhS0DDOYFco5MlWdBGn/TWdoUwt0sMH0WaMMkqYOJjkWmySI4rRj2Q
JeIuuBEilE9qGVJSko0dsVf0b3H3rt+M4RdX6pnkn82uU/YnKh4Q+c0n4IvYVndzlqVYr9FS6xOa
GO1Vr9qo1Hy99UyP1pN+ud70xEBNgDnxseTXWvVAfPFom+SX2eO1sHc45bjeSfmhkVfYUQBBnHlu
ym8hGcSv5cbMlJToxcKotV8V7RFGRFsEFfExhJjwVZiH+SotW+96RvwOByEhgGADoMALik2QuhW7
JTmXClyUdtZUPZDAbowUtMt18SN+jGlRrnuBaIEf9RYwG5qf2/3iavfPF5buXWHd1/L195cvv9B5
6Y3uO8+tvnlZ6Luu/zV8fvbjlffPL937c/fDk0u3v+iceb1zGvVcSrPlsqrCWCvcbtjjImKNOcIH
+qHAdZYfe9w56AIwlFeagRvjIIMWIFLxHRYsdQyVDmDIY4CBqpWgxZip5NVq9RaxQCBuMjYK8jQn
r1marhzxi1PNeruhbiJ01fILfTBuqEzc9cSBQn/K5JwGcOaii2BAogJ6G9Uum1085o3O4/XWNE2S
sCXOy0aYXgtX3Q5I9oa/y9CmWZlo4+NcUJmqwXpYvwPzhuFqXlF8VXPWkSVArEI3ElMM8dkH7Qou
bf63Y/sP7Nq7p7hj786xPaNPIUqg33E1hb7hlEIfffQGos50+sShDV7u+DhcSPowmPtFbhyupBxL
KcLDl7E7/V14ZX2vz1aazXqzMN1qNYKRgQH+GuRbwJ3nW0GlNjXd9vJ+uZ0v1bThBKLTMBujtKyB
gMSJFfq41wFuA4ftl9rNSmvO+iEnnxudABQ1ALfXWkEBlRjbnRl/DgBjqsDmASSfA+JRIDsSA+fE
8/xUY0pHX4xxzbma2+jNlrdtPVHZ8ui2bGQVAl+zvSL+RzIDBMY+K625Wrt4dbu+wjQuEQ4KobLU
AmBs1yp4V31ntl1t8ce00V+v3RCTWWM3TMhIGfi93sCbERRcBlfaHr4muQlYgujRNa4rnIFzaFMw
7mwK+P98W0VXLumFaUKkMUWgxw/hJriaGaTna7l2owwYIFjn63Lnw/f1J1oHiExKHuCQchHwjrr4
kqQhJpWfc7hYGwvwXmWobS5H28Jn0ALBtd30s5E3BDoWL+WeafvNOSf3Oyc3WUgDCuFfF9KIwCN2
OPluOq14MJwUgNHAEa85QAtB/Dmg8Cfi4815aGTwZIDXkCuDxwKzRSRZIppq1WFrQS6IkuIMQxE/
pvGovhH4Bp9r8pi549BELFK0SupbbJTo1nxnTbkce9i+liBOZGa/X6ofQUUtrBW4dL86GZJHnaAA
hfTayBa0KiUPL3ND0NVKrewfQwqz0Tk4XQEWo1UBAny03gQO/yiyERNIyLB7JF+Sak97R3xnwvcR
P8zCBMo8quf8dt+BfIr7jEIsvk0woIOt/OwdnYnAIuz4Mda5VCsTDDjQBYsrvJXMV8DVqcp+AO8M
P7wtaAOzuBBDFC3GeT10xKZL8DjPP+XrzSmB52Nwuui31+Wz0Ls1kLglee4vD2jBRPhWc0L00cYm
AVgvtt3o7EVZzyuVfDx7R1rdGh6CA4BCuTIFpCGEtgA1aIi5qn7LV+AFnE7tuJdn8u63PECSHqCW
EBJydWdnpTkysgO/jYzAVtHzgv1D0CyFvwXT9aM2AnJOqHUhKIHYuf8AICInPW/QqMlK1S+4LnJ5
Hvxr/gb4KlMpDG2vPLbnie2Vhx6SXLr+BxjtTF+lUHCfgJ6QKx1xs9wrcPEPDWWTXzjw5ChAJjbH
sWNaL6Ts97Bf54/OwP9pgKh5eAAp8uEB7zBeA/qreOjQiFettWdHxvMPjWz6YzE3/tBhBM6+AbwP
MMGp1nQGhssWCtu24iP4TB0e8nKTo7knkDd7qG8gbqEEr7SyfniJLZEJ011IZ+V9RbFFHnQcW4oC
AXKtk2L3JBw99thTYwdHU+rdFH3VRCTLLqsx5Bph5xuBNFT2j595CIVRQzkdnkbs5cZso2ZxfEfY
xDUBvgeWsgT4pHbl+tFate6Vc3TkciUD5jpgbHwnTxRGwpNcXmTyKPKFagFEkblnJncTJqq36k6a
EUdaPgCUWK409cfQG9D+YbyKkcFjJmiPT1cREJ1XhU1WaNl5zO4sq9Q73HrTJmfzAtNNubQoHIkj
FPI0U5Jcxe6aRG4SQ4lMzhVBjDKE7w3izd6anyRnHBCUl1/5pHP5PLuKODuJFAw8zUgaROTuqy91
L33FNv3u+T+t3LvXufju8t8Xlxff/f7u+c43X3cuvdb59vXO+W9WT13o/uXr7l+eRwcSnNM/Tz6L
GK5z6cWlb99Z+cdrKHBff6P72jcOrgyl9HPXVGei7yufOAOztRZ2feWT7ivfLt+7vvLdm0t33u6c
PwXvL799vXPv1aXFa0q0X7nz2dLiPeHcInYC97OA3eB+5gc2i+HStoFgKNQ84ETXrzzD1swu48Hz
d+mkkJsjuJNfEc/RxR5yQ3FWDllpoaPRfY3Lr1iD88NwUJhD8riwGQV0WpEseTYyjALFTYGrdULg
qLrRaKHGLWUtcJPIEu8uIu5kJPkgqEgHaATjSy8BFAAkL3/1Qefuq0u3v0AAfu/91U/Pd07e7T77
Qefqhe/vvpUpmygTdnF9OG0TaqPKIQoR6Ase00FoNzjEDLx/sHwSlKY97TQiGE5fTufSjaXFi2pF
K/fg69fdO5d5FQDN3bPnOi9+IgA/ZkmlMk6EFM+MOSd373V4qqxEg8/wHZBeyHCiCS9nLmZTELuE
efi6cePmgQVXQkf4xDYXKtWetFqiz6X4mDPMhrBraZ0jisddMHP1uvEuCP8F3HhiuDIAiqU8XxT+
XG/4NfzUKJQOHXbxgrjj+LxY9ht0HfKBj4hW3KJMI1+ETeh3DjbbyOhOOo18JSiGxgJSSDbys15z
Rj7lgVBVVwEknT5csy8fbcMMiE+0CfQBpBHAWFU/iBhAf/7zGGnREmfLEyMHWl6rHeT4n6hci4Rn
hKS4Wr2VC6c/nkgZeF65XK1e07zSnBiUFqXSshcAXnYnVCAM5ICJDBAEJhTo2XnnFUUW2JVsafHc
ylefIFU5fYeW0nn5fPfsydUrJxUVIfoBJALoQ+fUtaXbJ5duf7r81ztMHOBqAOlYuXGNv4oLEgK0
oAexGlxjWRFCwTrhjc6+Zn3Cd8iQ1EKBc9ZD3aafB/HTd7xyuekHAYkyTn2SBIsDB550AniIKN5r
+kKFChtb86rQH6pW/Rpaqfwj6H/ILz0Fkg5gTwDLAORieNSst6dAcAF2c3LSb4Ic7DTaE9VKydkz
etDB4fKpoOTVikEwbcis8B2VVfhbDC8L4ASjA/pAm8zw8ILGEiIjPA9zL+7Yu2fP2I6Du/buIdvV
eAKOL1UrOCv+p8iXkneDpge4f2zPzn17d+05mOozu02pHywFongdhExWvo7m/gv4/ZH8JhATNp/I
bT6RTidoYgkWUWws9OE/ITvHXfrwXHyMgWF+T22OcQvVU7xRw8PM2PEbbh8LqsPDbsx46aHhR/KD
8L8hZ2RkKK3zgBudUVSpBIAF1C2b9QC8vCbCJ5y558/WUZPRBrmVIa8Oj3eP7mFAmvRKfr/oCkRA
dOmG/fMA8wet+qwCNj4HCUoAN3lnj4/KFwIOhDoBUuxkndeA4fg6gUHgOHwdeWrBW4S74Papz05f
RjZzcrtiUNZ23eFEdFyZhI2arOhKlximIGk89XbOM8cjiTvdNwRCLlxlFkXUt22uMy+Eyb5hFBXd
OI8YaeEKpsu9J2cCS1/GdPvB9wFb5w4mThDfW3NG8h+ABjp0uEI8oOm0RNdMNkin0cZBxo6sUvFF
bhW5JYcXM9xfo+fYS5yTRhTjHvcYi9FL0K6ilKsjMtieLei1xLsI29Vy/PLwww8P/aLfL5UDr78Z
eI46ezei540oMHllcL0Kg8azo9PI+UkUF/hNvC4zFVQfAftKVjnAdpGlh8untrB2nL2Y4gmaYg7Z
LtgR/AFmG1W7aPoITRcRO/MoDOJOTfm1GPCL4zY1BQTO11VDntD6cnJjglV0ctVJYBTX47Blaq5S
a05CzYPP1ZpPfLd0bEOxwINKZyA8vxn7zwOpPoakFH0xN9nto06EgkYjkyEwKPV1rB4bCe8UEnHg
NpECl4uwZ4oMMyQM6ZpZ0uJCQ/yviGiwCDCAL52I/kLgkvQbgxT+mrUWtcHJ+ZojCj3YLR+sQ4mK
y0LTL6+HEWdobJbBGkPbZfBS3/B2PMsjhb4tvFFEtApR7BZhQyh4i3RT9IprMSHYqVgEECH8tskB
0pPDoA9AGo+FYNhb96GGMfowRw19MODOBzT93TuKo7t3F3awG2muxcCuIRRB5CJeNHzs3A/xMOla
nSgjYjHHO+JVqt5ElaLRUDWJ1sT05vAUNxp3b5Tpfgm6a/no1xGgPRmk+UkPgNqplNEy0qr4QR6Y
CRQE600PBYVprT8MmvKqeCWO1tvVMnwO6sBozBCrQOfbbrJRH2OhnHatHdAEBRtB0254QZBXfUqY
DwqwbGJkdQQKu+gDs8qxNJGN/LWBlWMwFeNedGFQCLgK9LgHssWfiZKJXXbSSF3i7iZCAbbeKFsu
kKgcrqcnPgEm6Ildv071qdWlxJNEuX6js7daRk4L2YOmz7Qf2Xtk1oDlqrTwcMUZkKla7D3ODQ4k
aMHbzfy/aX82p1GrQbCIA4w4Otzpf8SRwk1Cs0lB7Nlm6+2F7cmbjO9tAhZHYvnDTeBW4jY7Mn7S
5u/cNfrrPXsPHNy1g3A63q6U/swiiIjdeRmG/j0VJSNNtg2hsTcJOzs9sLPTEzvHngqfTPzO4Vzs
bYp0oIhRDI01eVPcBtVT8k7YhlzeX5c0xUvfXe9cveBo5MBhHZvzJCz2NzDrlVs3Ot8+j/GH5ImF
Mjp8JpWV0gOsLr6xcv2q/tbqqQvL964bGtqI8G0tKBIFyBSOrNfi4UDDq6A/BYfLuQlkvSeiz00n
d7cOIhBjkmzA1feafM4Kl5MWoVxp+hhfOOdM+ACKZHhsIk0guWw3ORUi+1kp+YwFqh7afuZ59hs3
bk6n0gsh2XFFCPEAXFloGHcDNW4kTf0PPCWICpJHQC1o/cTpMklQExxxBprtGgJ5OX3ift9ELwr1
tmI8BiNbZcOhWOdIjnaOIYbjDTtX/7by1TWhdtR5Mn2vlcVkI1JSdQ8UGSVcFtJQsg/D+8Tvwzfg
J4BCBy25RFS+IzXMGyYck1zbTI50lFxPpIbsUQVtD/BpUpwavOu30Guh5VfrU/B2vdbbciZ7U+YB
IBWzzuAjDz8cnmS87Uu8GC+htmLfYbatLHqmWZfFv3xLSUCh76VWNU52l7sp2zh+TbBJtfpRHD0v
7gGOv3brsmyuEWee5CRPEvXCTUDc9clW1T/iV8NpNks58W6PeUIjYY4BaZPpu2TKUMcYtpKzpiZ0
u5PZhV47HyPqL6RS6OYGaEO4rDCwK/9VnImB+gxLC8KX1IWOK3OI/nQtE5WRQ0C+LbIExLiXSy/e
D9HIR9SBjYBIFEb3HXQ6t651Tt2SfrlywtpGoF440UyAtjWxfaahTn+abK4TmmHeuCTWPhQTzFmx
JW6dU7NteZGfbIve/UyNDXwFNU3+GmP4i5tcaMri5u59bopmEVQ7vZ4ezP2UVh4N5h7UdKStLd52
xD6K7HMnDUj8TNmQxFcyI+0Bviubkj5CBd7eQ2hUcscxDl/8YhiMRsJzSbY5ifc0y1MKkQO/K381
TU5iXsrq9OAAzIafdW3imiai+5kF44OV0592XhT4QNlmmLqjvfPFF5duX+zc+3PnrMAW7HOAOEOY
ieLcDBw0El1BDwfLToQuBi9cYPPQ93ffMjBNYkADJ0ZYjykprfoL4xbSFPKw7rfVLv0UuZj0R+XY
+QHH6Bn/NzQ4tGXIyv8AjNUjP8X//VjxfyqfA6nHENsEJDERR494rY2mn3IlaNRZoSKRtnRByTtj
6FjlTHqVarvppzY6FYwVLNWbZYpfcTzsoolyOsbokDAwUa2XZjDgUMhqwEbWpKgm3UgJqXpTXqWW
TzGcFlF3RqFEUroBQXb15Fsr350eV3rvIRGLhG2JYGf4k/OQM5TNYkyR6IzmoFg9rcfulU/1TjWu
cuX9a6v3LgNq7P79VUcf0e0bDhEgbgSPzJ94ZOQxxdaZPmisWZr0Ziuw/5pMiRyG6btEOM5yXaJn
GpezKUgrjW/475CrK4iajVm9501BcgfzIlxxJFeuTS6IhWpdeY0Zc5IzxMUjYRPuvWZ/W4y3MQlX
+Dp+UzPh17a6lqJdtmW/O6Zj7NsjPNre/ITdIKAD1p4s3fsOWpqOef88+ez+fU858Dp8GuUYRmiK
ngh7D1DmHX3LSKaG0zvarLTwBhSVPK60+ZQubUg7TvSjRD0YTJk9tWON7KyAVJYGSog0bsVBCKMD
/xYrMdLg8/D3poHNC9uVyUu9gL8PmKYXkjBVG1b9HLUfHFMPUBsgbo1XKtVhC4vo0GXGMNIShlVQ
BM16ONbALc0Sc+FY9N2bQ72oG6tXI09NpWnil+2kCXMBZ0pAzV8eAMlvtjKDlEeBUsscGhrPck4a
bFCtTMikNPvgq/yBdFTyB32xqRbqX4zl43sZ1fvweLYfNdNVr+SrdDaHtow7hYLjorLDBVb0GDnT
Z/YeGEPf2X7nt1617YvP+zkLC33LAqfo+PhpREv+0Gpm6Blme9D2i/aZ7haKlNkE/ayO9hC+HYdf
ExpKKWYmaUOl0L/bOOUNrDIUD8wx54kP3IIcIFk+QitaU4HGAodwqIY0ubDh0bBhzKriV0S44f3r
K9evdr+4unSPFF1v3GDGd+WrjzqXbnEuLvRtfPM6YPrua6cBf7A/7dLtO6t//rZ78Rqyt6fOdM+f
7d4+1bnwKmN+ldftZZm36/yppcVr3fduo4vkqa+BM+6+dxoRSGQ3TYZdo2dy4g7PymUfqYMUEErO
TpgVzzkosigxdiQblVS9UYw70biAaTjKjy0g2XBiSJiht2a9DSQDCfCEjyFalcmKX847u1SWJyMP
BG70bOBXUXM320YuoMpKEIwJUrRYhagpLFD1JvyqFT8rKF5QrPl+GQ0ha5M8ivOFbhBTEqUSD4bx
AdEb8WALPmASIp5sFchW68LUigrZhEdGeCOaY+Mbnh7HG6MxLAekLJghWxi2L+I3tm/JJ8DEzLar
nmX0Umd+DFCWTvtJQZ6Nn5ERsyaob7E+gz8NJfocOg4rg5Zuf9V9/eul2+fQF/ybr9l3F70CmEYC
uP73yY+Ya6HlaUxLRZ9OZFxSHIgVhIZX2Ys1KxO6CSxEKsTuO9e6dy47mBOPr6jcZpUeT7R7/Wu+
cTEektatj+u++/p7wKFFRuBGHBtyzNV0f7JLOPciXqcYkBaLJyM9gbczLEzvmACINUN6vgvR3mVX
LMsgL18S9I/xH2tgKUWh1GrL8MKw/QYtidFUpcVN1puTKIpFH5AYN9CD818nw2ZqOLX7RQqlTxFs
Z6ynGrkdGY+QwV9FHZV4qu3aTK1+tGYSM9RQI8EF5BjPcIgfnaFB7nstRwkxmNDYsHuzPvx2k55a
KutYuMab0j37befMTc61gDztW3+C68EgDrd75cazTPMSaBXwtYpWrXz8YefiOdYO6/ob1u5033k/
TFUaY0nsYRilZSKqYEIxrhJQRBGBpHORWCwt94AAdztXSSS77oC6Zifc2ES7YYPYqDxt6htw7sj+
Jdq3eSMwaQM6Y8zLSW4UI7sLsW/En+rS3TeQu6C0GqiAC5fM58pCC4C0shqv3LimDgf4lJWPnuU2
uggEJ4ynCoju1Bnhtz17BFVlh93DPMk+uYDDbszDPEj5iNfL8Gvn8sXV0zAq+oO7CXsRYRcZOHrl
ZhFMC6HaAoqX2veRh/r0r86COjydNCnECqSyPGGDmuJK5F671ArQcrNeKXOKYeubJO/yKTDwLaTn
/HM61EEmD6HNaq2PemoUxRwpiqrn9Yja5ykfzQyKluILZs61JULKacIBtmaeEzNdLvAf8RbWDaYT
AKrz0VfBjeGSWs4vY1s+9lh6dN/BtNH/xlLV95ponRoZeZpUGCMj+5p+blftSH3G3x7/OyaqXmeD
3IF2qeQHgWq4c9/MlByC2NwcPIj/2RhA/KAPvdOfaMOzPfXdcImR5XbRb86FH2Lilh3X+kGLW6bf
jBWQsJd7Csi243q1Ofy5BHx4E37CIMyRkYOCBrmP2r8F9o/7Dpo+8b8Ddt0RSbkpWxBKDbgVvkMY
lK1M6O8OgkG7RsESxNYJsGHmv1ZvSd8L9Fwj+6IQIQIV3xWwoi5osQaPU9dQ9/1qBlLHh/p7tvuT
WBIU0sK6Xaql9WD8g2P7n9q9t7hrz4GDo7t3F/eMHfzd3v2/4QB9aHuihPGXqFkRvZRqwoidNphw
ZnEC3RGl6U+CGO2Xk0MxVBOKVY2+aDuAq+Y0taQ58cdszLpjxQY4GBbc0Euc3zF0Q5TqqKDfvxw3
S1kpb6ARYYAB62fGJeQFrtJxNNBpxqu6yb4JG1h3RKPHs4dav9Sqd6cabqfpIWYv1RLJ8Fr5TEwO
EKP39MRJpO+gPAauyvXxSzVPmWwJv7nJbu4Ve+5SNwYoN1TRCsI0ovVP3JEZlmH6ZE1aTRNc1q3x
cjkVZ0kKAN0gT5pYTtHBn8UPOdTQo+893N3cnJEiPHbIjXTxUYVA+ciP+8062TOdsjcLNKysJQGU
BgKkULW6whHsCQtUtoK7kze8ih+aTJluhNyD5fEXF1+gZZjRoBjdJqmLhaIbTS5jSj+ByjMjTkz4
w5NuwZvZbp93xGXQcH8fMo9MSImR9xgq1HylTqbHtVO3Y0OB3LkIH4hA+fGE9ITijV/GIz9tKGOR
a2edMeHPTmXX6xYLF3LMJ0A0cqxVAgpJ1w7hvhB7EWUiEK0xYpSgkAuz28lsANISXIrlTNS4GOwJ
dFSgUIHLwlRNqp2g4SEilZ+0vnbXp3p1IYbyj7XgsvlllmPloAPWYyHFWuKlbjuK8oobnT2k4UDd
g8gwxWny/GOlajuA2QJOIIHb5mBV1jx54WhO+TCmYFIPL+hbh/Iunq1VdSoMsxEaizRDUS4XVFCJ
JhzB4vYhYjsy7iEKM4/vH/tdcc/e4ujTB/cWn963c/TgWGHIEZalyToM8ge0IBwZXrN/VD2mYkKJ
NJY8iZoRCpuZSkQ5Sr+Gl0QmmOwpd8KNarQpU4lsnUMnRjjtgsseRmgDkvAOU3fJR55jnUH4mJly
bbqYGNMk1slD9lqmUqRs0FeUe2btuYUNqvUp/WfXKjqj/wlfwlS1AKjmi5RgMZfTYY6W3TukxQwx
OKinlBSOkIEztm9sN4UQtBuoqILrAt/LPrmxIioQWbI8SvbZqAdOFS4AUEaUH/NJUWlN9nYHRDzt
tVRFE6mBa+p8Su8TkJkeZfPYBrPeH+pNLf/jrp2bNuU3LyT40+P9pjciQY2JocKmmuZ/HjD4Db+q
djkm7q7n9v4PWFCvFxHoEL1ThInLStUcLrhf5Sur5jn3bqNZ/wOwyZS1rNGeGMBWA3zWA+TF0QJm
eWrgcB9CM5K6gV5Dr/PK9dzfGObqvmLrsFBQywoUFPWDTAM8e5Ct3LjVufmC89TTB0d/PbanCPRh
tLhz1/6xHQf37v9PZ+U6JsxZun1nefGdzo1vOBqD3Qg6l17rfn2m+8XVzqU3Vk9fWlq8xvo33a64
/NbzIjhDZlJIb4+/MjRrYCbwH6PkET3R5FYUCOiZaZaXj2LV+ceVOp8N8cfXUueLaliJ5k70oiAl
pFIks/JYxA/c+rJ75Wzn8vnuF9eWFj9cvvyCufAEtfEPZcLHkmMMFfK3Ur2J/hpF4RuYUvZ0Tg9s
/Bi16UeMDGLvk31ldcPcUwIU9e1BzyHU63du/m158VPm1GV6yO3RCJuIw+kGJ+qJIudFRbUSjISc
1FkH2JXn7nVeeLNz6prylulxObrnT3cuv2TZ0eF1TCulXRc4fF5SOJ/EdCCayl/V66N4mKxTDwqc
CByujSzhB8/KbBmzrjRfxe4rN7rnn0V1Okf7KI8evNedq6d73EdJ8ygRCc7i2KPbitu2ckbdAiVo
JOtzc3bb1hMePgx/xGf2hFZPnu2e+2s4IWixdO9C5+rz7KLUYyZmvLxMYBEgC86p0Cz3ILeP23C2
tPl6sFDsmcIUjaEFgW2KffP88kLxiITAPDzJTx0PM1k2qyq95FSlNd2eoMSSEl9V6vLjgKzWNiAF
/gHV6QDZYFNGBkal4JPgNrp/x5O7fjs2kgvlNoQgMaGQV0EDegENI+iWfOnGyrOvLN97iU9Y5FLT
suEQrnrLpDoynROKaDQxB5Mz6W3gFrBTCOK8M193ztxc+e7K8mc3RFo1+ql79iR8FklyiG5EBhJR
HfHrLKD9Zd/vdvLeHNYSUWoJQ5K2aCEekceKKPPSPVyakthJQNGoPtxQV0/ebvKFXqMS5iNtVPIa
FBC72xMWCHKDgT76NyIksSzPuhuRHwtGcJOUNTKDYXDgfnIYwhWoAZLMSWvuo/Bs1jtG352hRwd7
8VZPOulRyn86AtuAYcYUkDcAYrTfygUtuKazaU6OiDDtqnp8HO8hrC+zeBikepSNVDrKRFkkQj8k
NANwsnM+0BDELAeeHM1hRgmkwu/dBiy8Jj3pwXnFRHjJSeuSifbkQdbYY23LHy0u3/kOPz7w8nQT
O8E9e8NgHC1nspMBETbcp7QQ6f1ju8dGD4wdSCHnX5mEhaTUo5BjUpQHJty5/JkeW7F0+2KYzFE4
b6kIXq4pqrNImKTS3Em9PoiV1JgzAsWn1RyKMeuFxSPgr9gOKHWd5+BG9+xE9xWxDvaB2bntTgLb
RjrROWnDTOb6zHZxTpmaM2a/4wqwc22+Trlx2woDzdAdreghqXA0c+mw6Tg70awfDajuy7yVFiqR
Nzd8B9JIgj451/3HpZWPzwAPIb2cVm4sAtlbufFq5/KNzoufQJPOnUtpYuclun9RJ4fsA7L6+vXV
D96I9wGxitYaG6C7iYWCxv3Ne/nunc7Nl4RwgWwnrYOdKPFMTFe5SNm5IetR1k2Yodjx0E/pAWBT
NK6RpkeeIbsCm8/yLI4K7ZF0k870dPnVnXzZ28nnJsQg4UQ4a0VWKwC3NUujyzWiCGNNBOvVtlus
Idach7dkwziHTOzcgSKHQXHrnvia3slxPsmGY1AEQBDZ3/6y++6fu/84B4C9+v4/HKdPzNWN3seA
EjcW+v5ju+XFyD/gbdzaG0btKfCNYCFHGxphmbxqgGWm/IEw/aNl4caWE63QOVg2YL8L63emY0KC
evn88uLzXHBHpeQVYsJluJIXOi98ufzps53LF+GeKn+c2CvJqd4Lg2t4lZoFtzS9oSALopshey/5
ueGFSo6tIhnQQjQ8xfpBCzEJal6jrDVJij3HZvkAI4Vaemt4rHorTQNZqLRntRJHMe62adlMtc8F
Xq08UT+WdiI/KYegqXp9qurn6LmfziZB14aCsyVeExO7a5YpGXZQYWquO9597aazQ8wFDnvpm3cp
l+01gZdB5mZED4zFr2mG3NoXLlvwOutl4F2T5/txTiplc+10XqQqVDsc7z2pn2/Tn2z6wbR6RbhT
9gIBPJ8eiYGTzFaG+epBIVq3uCfCmhuXpIcsYeawkRAq1aM+hxkKposbOHYc8qTXx7FCu3QngJjx
Ylqvc2B20MeRKaetRLEgxYDYzvDKkA3wymF3zpMAzWSy4x8Q0iWIg7xPKDgVGUMP9uf7m8uBzIZq
dOGhORpKcHBtzdttz9zM2FhZH9nQSQX7mCfyTjpqGEwiTqGnYYSJkggi/W/BbTqHv6Fn8hH6/YD4
XcfP98UDWsEAJDc5Imc+c4OM45wDMARn2Ue9y5WzwoWqjLIhq3yAu4W2GOGnT0coMxXGvP6X1TdP
9cabgrTG1E1I0g3igEVLQciqwROkFDRaaFrC8Knq1TanaaEChgfoPGPTxHQi5PEeCdOgncFYqxir
779Hp/KwoVPZFqNSQVUKnmZup49JXHIHQGrzgxFonMbfXP03vSrTiNOn9ivOFpXWVVPYEvZrspWv
1AeODBOEBgNo+B8oqQtD6hqpYpSP83+gLF0xGxQr2GLr/vUbK0x2WwoVAevw5RSKONsUJQ6kFBm6
DIv8NtBDwAaBr7HcyP3H9ZLB+eWR/c7It0wxGFn0wwm2Tk0kTtglVz+SNewgdvzX9p68v4kYECac
7qXLS9++rUGBo+gBIrTlT/7euf7W8tkzJunvjajjooU4lGId4yjUbqQPki5Rzak2JrQNlJwvY3yp
fk1uqsXoPpJDeMjmSXKcKC3L5SOL6NgXTfOXy6HehLz+gMbCERQGo00QpHKlqtcu+9Ab/VtIg4zF
RgreC/JA5aZwn5Nbr9z6O1DodHQQhOgTnPYac3iJj/AParcTgy9wS6otZ9h24xfHJhH4n7qv3sQt
Ys1B5+RdjnhhKyXWN7n9KTfC3CUn7zL2F2qNi+9GFRrxjn3hYQxTsuUc4OofZz4UULa9dxpnE1TE
jmcpObWIjQx3P4sBt+JpbEccwRZ7iIXNstP5oY2bCwtmz/gr9a3/SDalzeLIC2RxN0v/2vsoNVcv
dM58Zu0p7OTyx4urb17FgBd6aJDn2NgStaLQYxFuJIvdRR5ZqVMFdqOYPqnbpaA+IQcX+rZsD5Pz
bt3uaOl5Cn0Py+C/h9kxTiTuVTnpIuFnokX3yqfL717jCBgm+eFLs5GXZBPtLZHNAjP/cHaJwe0R
3AqPvPJspaZ9F/mHW/VGA10Mg2nuAhHF0HYds7DagM59eJiqmhbSAJjq/suoTGCmGBGkaftQIqCG
YcAoDmDExMrvFDU7aCTbOFyTqnEGgrMXuMYwOyEc1pIA2eg1dPyUj4qkewoKfbxBOqutHWG8KI6F
1pwREd/Xas052ShZM+hWeunO1aU7Ly8vnln+7IYMaUv3oEBiB9GAfuMuV13Wu1A8LjO13Ysfo9nx
0k30vKBmnbuXqAzG0t23Vm68s3T7C4FNIqjETmJmpLIUgOUqO/sA87In+IvkXsU3Mnaz7V22E9+Y
ve2lzWMriKMM++HQ2gVm+B7YfGLzAH/MxooNsi8hGZCNVxS9Ah5f2tQ7fznXuXSLN1LkwOILxuGO
0FT0g0n1ACOL6GB1c1Ftp27k6nP3VuD/3/4Z61wv/rn7lys28ongtLXWHVqLhDeAswvAsjow+tRO
8lQY3f+U09t3IRLN3q5g2DHn2UK8gd9F4VXKIy4+S4GzwvHDg0k1J7Ta4vw6pdtKR4NmtRLj3JAK
jadjcqMJIwENPR6mepChzlqkswh4p5ZijgtaRol561ctUnn+wNM79xafPjC2n+3isiv1mIM7Meta
TB6JuFsqFb96LKbh9yJYJs0A+M3f0aT+5iJVzHkTbi4fG5kw4dryewh1b3/VvXgt/vJGIg35Qplz
enrXTof2IcySTpmEgSL/fuevi5xGu4j6jpGcCInlBgsDTBCZCLENDF6Kd/ZR74qGC2Zh4HlJOTdt
SqfSwo9U+fsUpAMeO3AEA9Jcm7LTRGOhY5ybq0J7gUS50Thf0yMA4CrWAYoSPsdFHgs1Ejk8ELIW
Tk/8Ri+5wXxTICD9ZXKrAFSy9N07/MRRuUbo4NEt6Qw6SqGZjn2lZPa8MLPzqa+Xbr+4fOdj/gl5
xhfe5ATQGHwbFquUFnqZIjYaD81HvJZFjkFOlIuiBCnA36988BmP37nwHhIzzqPy8SIWSZPFoBQr
9v3dt2aP9Bg/6ZecOi83HaMTi+IFaWkgtW0B+QihCRZP+jLkJVYU/IdmzyCMKFrZ8feaKduyvZpU
Xhw/mVQJcNjYGqMk6plYBOgK8mpFUoIq8iSSMNJZSE/Tt+ITwfJfMpfxCP/N2WEtpkMbKWIDqTf9
dqtSDdCrzJk6XkHNWuzDiXYwN1E/pj/SzB/yElPeGQxNnBeDiuBtwMJ4XeNFJzMHgbIF92FnCDbh
/OnO1/wYlZgcjw2Qmi+UHWyvtwMCzGYR3ftJJAL6653V17/CnD7y2hl2cVNgExpr4Wh2vvvqV2pl
iQxYQrCMHUVoZ/vUeGpLbZKWCTxPqaxnKvTJzNxAQEEecxwRbpRBlXnZ6KqMbLewRI8xnKXbFwTP
C30IPxoz8B/tGtEFzqyZCfm+Fz0Ts+D1LGRGXwRR8sWLoqAeeehQLmVODacX1lPpVWc4P4A89J6h
Q1juUwhLfRn4VaKr7JqLduMmr8IRHmTlO/c8MfCfTz9lHKFYvaxiqxyVBK+tMutdehFplSojuH/f
U+wRaVcLFEYjWKmTe/rINMcoYF60xsxUQIlb4SdJ26IJAcl3A9DnvxlWpFkpcl42L5/W9RPRnnTG
b+28gjY/r4xd6bjsVBNeME2K5pF0wqKNZT6OzZEwcSqRKAspFsTthLpKtsYjxB+iPjc0C/MvrZpc
A8nuZKVWLgoHHLI6zBnihu0nZgK1iCtwlGfOb9lLBKDp4O4DlF7t4rnlu3/tfvJ+553XZWK0hLXJ
zliqdrbkH3XYkL762RsMz0u3X+lc/syJ6foB3Y3MLG56TkDJM6y+8iy7CacVkzsgzJPIFM24lOku
uRfkHVdPXQCEZPSkmOSBvGCoMGXNunvsXjwDBC6uO68Na2tWjvtUPSVwKWOfFC/Q1AO3kO5ZmJqA
MrxSwgPVguwDYSR4ThkwA/rF5uJV4kuxQX3cp11vK/KrACmpLt0eSUhkudXpcTBz8Z7TFrNCIS28
T44Y19Hd1JCbkLEyyn1DMQJ42ZV3Gzvu6F4ZlkT9gye1NNNsBd4Rn8rPiDPjNu2aNJ6LZvv9kl9p
tFKTdSq7VHAifpWGH5qd79KCCXckMm5G9Dxg2KXUJR+RMxDt/n3+aLrQKUEqKW+mKUbGQUUoFbjr
Te3VA7oEUXFU2SAkzQw4jnUPHJITT3WufwO0pnv2JHS5cvIU4DeWNBUju/z818m5nGTEvtiGQuQu
a3dNwwKDcSksFLfO9XiLbERQxWPFUJa61lDn0MmEw2ipB+83SR1dq6BePUKJ+f6taeoaMmE2LZBd
Qdmp0vwlvCtbRsa1bjGk7AfLA2toukU+vHjINg5J7lUi7BP1WPnuL92Lwigjdd5Ld6hM9efCa7in
CtzuQwd5LpUVMwuHw1a6X3wo/JjpVVafGMo0U0xb+e7tzqlrrG43lCha3QbyfFiDxTQ24cmDB/cd
cER2TSHAYi+JbFfSC6b8ZMvp2KDk5UoAkJVJdFjyg/R9PsanglFJ9fInEWmfw4extg5NYtbUZ4mr
1tvrKjNDN3/wqX07d+13dGUXihe6QK7b/cKlYG24GPUGukxg/ShRRNv8CoswH+RkhSH5mMtOpeX3
rJ6sTjK2utID2jhBqaGXrNLK65L+AzXlrlBsoFFPdObKJHdC6bHd1ushmyKaJBwIXqTO9Q+6Z24t
f3ZDwhUMD4QA5oR/q1mFX3Be6UgoR7QkdR+0Vd5GG6xyuLiQDXZV9DWU6m7sdFkWUQkAF6w4gOWL
N5GgEbYghxM+dbdXNr6Ycb6/eyY60Fn33wwtul6xZ/ngpGuoFz57RqvF7OT2OOm0k9tBf/eozZec
mTTOpSmxJHFC//lGe2I9iTQiQMoSTOfGC6svXxMU493umcvOmFge/0KJivHQu+dPL9/5Jv0/wIfX
PP8Hc6g1ik+JDtfvAmw795qgt5anLcgkwr6pcgNrh66SLQMNtV1uGT1HQlmlSkakfBBEM5DTitQ8
sl1y1U2hu2tUerAvkR0+y7rwvoxQCSGXBXsjEbVWKC0dtymbxY6o6Fdhod0L75NBnQtw6re6lytw
1JgShXORfToO1CkKUQN1x+VjspTSQBJFmle2In7x2vKr15BCnvladginhx4Dl19SYSPc08oN8RLG
9l/+iFk0nh90KVfdvfBu551L7M8Bgixms7h9juua8C5FAKBvHrZxIa52nu5owEXH7awxR7xqpcys
5qDwgdUe0Ut2ysYNwuIbtlPOc1JWMH6q+s62hx/e8jDbjZN9EqNnh7Ti0ocrX5/qnL6zcv65zttf
pVWaEO13mRkEJJLOmZtisKVvzgGjQgWz0MGYm2qmXFgI0kgMssQqtXhRRC1d5rzd7DoJxIZoPU/s
WEQb6vndEJCp67WUHLz4t1/qXP6c5y2UntdvAgwKVi1iMMGlJthMLMWGZcVm9dOVC50X3wc2b+n2
YvfKHUUXbn2JkQEgRly5o225sLGc+hwahXaV3sxLckZPQen5nyJX9yiXQeQI2MOr5lX56WOPje3Z
uW/vrj0HU31m/yn1Q4JZNTT7spsOVpigVYkNvvIpXsrTd5av3hE7wIuTRmTE11TckpP58+HARRfq
pcsXyc09ZLyc3EFnC+bZ7DOX0CdXxj6tSuo3i5rqrmKRXIOhJZb11wIKBXdTTgYuLWZBIRs6dvJy
klSM6sI21/fVDkpPdh/ZoCpyRkq+jq/rOvBMuTguM5CWjQhPhRNuEz6AA/7nyfNAQvFg/vuFl53O
qb8t3fmMPgp/IHIJ+efJC0BnOqeeXbl+W0SJk1+A/PVPMU424TbHefENreuq6Sthye2K8H1efePr
7vV/MI3SbyPwYhwmwR0k+PTg5WMxIbZyBtbfRhrwx4G0dBflROOItDYe/uPAQkLAw6TqV8s2ED7Q
+daqars2XypxwEylVsbSYxOoHGpRqDv1gNbPKJ8pcCwmHCaSttmFlWEPfdSFu/mE+STlhnYkPgjM
mHP9LUIIfNMdB/MC0M4u3T65cvqrJJbFMkdRP9wFdOCEB4zgSVUcMeD74mL34lnNV9fR3DXI24Q8
6dFWx/iVg2IIHSFep+6FXco8nBgZn6ck3Zvk1C6wMhTHAmLy6pm0Vvac27DWE6N3yOMBCIhe6Ty6
BExYxGqdNz/h+pZslYuztbMDEme0WU9urbJKUiRT6PQOEo7P5aTMabw0XpflTMN6XOQojAEdQVQ/
XsT6Dqe+Xlp8jd1xdLNBrK+YG9JCkUoso6VDy8aWX+C8VUlKm/jFCfXNVcZXr0nHN9mZpWBy+9Cz
ON7F1kj8jx7DwMcfqdTbQVHUDTQ9d/XdlxVAnF9XWs6U+E/JIMnNW7NAuMK/cr9Nbjq683GuEwD/
2f3aaSFFqaUWVWjSizDBszplSaaS4r7Tanq1wGNlespCLSzDDhgFDwjLgGA6sJkSm6dii1VYm8ap
Jnjj3MQUomFBXSMnqzF4HMzgYpYXn+9cPiOK6jlmhQYMTL59EiPVubJOTHrQiEvdWn0KrbDeLTrX
kl+Byu4bWHmtQ0FT/mt1+u615Svn2HNh9ZU3V27c4CuGdBs75TjbRr1aKc3Zr1K4fufkm6snz0r3
iBe53kb3DnK9ijsLbSwRWTahKIYOiyK1xHr4MNtRNq52DbIQWHYTQ4mBvpGTsJ2JYB0q7zAlgvA/
RSbizNudxTvke33BcHtP1s3Z/XAXgjER00zLfArBtFeuH82xWxp/cdLp7TF516nGfLuGHfSePONQ
Hk68EPXaX9f0Y3pKOzjVHKer0z6mS7PlEdXGWkEMWxV1H4wvAzaYlG3ACgjR0pHfj/U71ndGuY5w
4bzQl0blxNCCtrX0a+xpevli9/xZjnQAJgT4DWZMhSv+W6Sfkp4vLpAyTtCGIakyurPpHRWJx3A3
0fKPqeEwB5kcV7pXDDw5NrpT+Vqg40ovsTRurYJDX3weE8C9cxohngCdVdToZnLzOUQchj9RzGnq
UTCGLXPtum5onvKrVQ/9xYTei79TRYNY72f+3Y21W8mjEWWC4t2he9ruenTBbB/0oftFdc9dw3Bt
O5KfbULE8SEPyEkoKWpu6faLK9/d5N4ZN3fe/guyRaFQzc0tm1DCtmOw0QPsObzVrNdntV0XT3rs
u2jhJraIJh9YS3cebtudVzC64F85sGgX1oEJxYO1YJHuUzmsY3jMH41VOOJuvPCmiG/UU9hwvBj5
x6CGlbAHChk0mR6Hl4DCxBFK/LjB8q82dRnbH6jPtSovsgJElB3paTQ2M1Wu6XeboE1ix0LjvklB
niYRdcGN2U59YwzSEefnzvcSw7LQoM+oTsRZXboMPxrWwygH0qtLPXoG8ILAuloT0zJ5XFWMjvXs
7tU5CywM7TQK4/G0TH+rQHRp8RoHBa3c+Wxp8Z7CQkC7FBZC+whTKgqFQr8uCnXCfExrYadwQcKs
s8lZcFF1grWj1i4l2Gszb33Jir01thFwkwrwtPxspMCgHvYIf6Q0j0GR9kqbO7Rbe6ohQrj1JTsf
JnoNWGu8+Vb3yqd6rJ+xTEfkfzWDI5nDMH2QacboqH/mspoMzySKtaz01ww5Bj9v7KuukEskKcq7
T7wDbYvsyGXWY5OMvkQN6zGv6ko+zppGCnu9iipr+BT+jar6kFazqq9XHJQ9mkiZQLZD4Z5m+ayd
P8t3ifk9FqLEu5xZ9+XzyEhzUBy5qJnnRnrwXMvBtFjkNekmUIyIykEriruDwpedHfWy//3dMyDA
waZ8f/csJuBmKwrHN1MV3O0RXpyviErZEJvfK4ypFBrLKOqS0xH78fVZkB+NwvXACBG8Cc8lrGz/
txAmSbeERoBvzq0D7YiYaUPUUBPg2Oorn/K5QetNgbP6/jf8FYbgr3qD8BjJNijmKfOMxaqmeGM5
Xt3V9lFGciflATdnaU2xc+qT1ec+UQ/NMbDnbOpnP/25/z+yzlIw/cONMQh/tm3dSv/CH+vf4cGt
w0PymXj+yCPbtvzMGfwxNqANYmIThvxfev4bNyj/EL92hAI9Uhudp+FaORP11rQz4YP86ss6EJXA
CdWHWG1qYo7qPYal30Q6B1EJO5+iylF+u+40Kg0fMUGKbPtapWwzfDPiRoKVbTIgTHFgPtb7mn98
9MCTxQN7n96/Y+zQ4PiCmx0wqtcDLAu9dLVen2k39IS72rikY0h0EwizYsUkuxrWk11tEV8wyCKo
HPedR4d+MczZhDUeKmTLtCkcRVVm4hTkaFu5Xe6ZvTkYSjwt4LAtzKBVGOLBTjjTZOUq0QRix5Nx
LIlDygaml3Q/1gCoVibyuMeYCZtSVJnP8vDVTFo1NN7vqMma+avYW9xreVQvmh/m0UaXgalvUbXS
q9Adtso6v6Q1aQ7QQ1mZfgUz5MIQ+Yn25KTfzKP87fNb6aRD0GzgNh3CPE4+Jh4Dkal1tN6cCQvB
U8FUjGKbQ4Mm+q8AX0nxNU2MfHIqDfybgtxSivVrcIQywaFSZR09ejRfqtbb5cmq1/RJh1Uq13Kl
qcpAqwmv26wfJ5Da9cSBQrqQDm2ZchKRZPn0tNA3T/9u6ksfbqYXYrzohJEWFpZV6+jjZW3fDsvJ
4pLCB5bOmrKkP0ZO27BIux6q6M920duxJ6vIfKmmmLBKI8zCbplDf//7EweHqIIPYCUO4uZ6tfXa
3CxGK1E1SrPI1qHR3H+N01/haFwRfK0R7QqsCQc4O1dp5CuA0fIAJSJTOjYUbsLirXn6d2AA9Zsj
C4qzPOTwljmFPzr/h/m4Q4dGggYc/Mj4+EO79o1oXzdnDg3mfuHlJkdzT+RHxh/K6k2771xbOf3p
0p2L5hv5h7J9zniEX4WzZMy5f+yp0YM7noQLGkIFga3dYFhrIMrcYjP7UDevfvRm9/aNzSc2d7/9
++rrn8AHTFzzzbfiyWsn+cnysx9uDiFNHIh13Ogk8fY9rVkpAhGbOVMM9Ln03TvLr76Jnf/tZOfd
d5fvvaS96LVb9Zg0VMnDG/AdOluFkgK/6TL0pGKKoFt8LM4AXkWcIpOCS0VUBKuIzFND8HGKEmwM
U1JrTEYlSgCrsp0FkViGMtRRfulUmNBri9arqARZyKh6wxlVb5jRJ8MiDogiDBbrJFtBOFSppoFt
LnAo5bEflhBVYJZUN9lsHkpwPWuU40uiQrk2PJUll2WMVZeqcGoU4o3yyWrlEWwpFhf2Te9E+9W2
hZvEZZFTnvyaKHlILw9dEPsst00cjCoTnQ0t6sb8VcHXQ78CjsdYhDrnXN2Jrx1eeNSxfwusH7no
OZY3D3/YNpjVbOB7sbBwG7AAMnwq0klVmOYaiFT8Gzk1lICBamFdYLK1TfpY1KKMDWbzRtqtjDOG
KW0KKENnScu+ruMwzlBswUO0Bwl1W/Xu3GxCTTK6EbTn5kGlHrwAdVIR6XVVpeYLxFbbNYpSx+xB
pLZuTHfJpXUTiuLkyMVhZOTXfgsABvrI7YCJ1+A6T3rAWmWjheXI4i+sQqhdu7j66pXOc5dQpWMo
BSLe/vbbQg9460vWI6HeRDPDm51FzpXxB+8AnzGxnHPxZ8w+HwJriOCBWW/OKeFaubA9nBr0ElTK
cEFbgcjC1MZLLoXqGDwTQpdMqqxQwSxOkCQcnmSplo8pF67co6VG1opwwBJgDAmEKdRxPU0/wzlj
2GDuqXrZL3i1uQR3kXDjl7/6oHP31ZWLt1ATS4VzULl48x0sN0L+SmyCiDsBBejrKKE+okG7fjhu
3HnC2QBrCSwgzF2VkKK650JapZuJcj0ey7RXm0IHnUh58sDAQ9ENjS+gricZt4quzyXWV7cPBWlb
nJuiDQLxWxGekLANnT8lIgzv/4AihxOjNowrJm4R9tCpWGwiKhN2jj2+a3RP8Yn9e/ccHNuzswA8
uxaeeh/7DM/lVuMuH7aSlq5/z+O4NkWyeUtDDwcEf9i2zjun2W+bL4HacmDr+zaHG6okSY3dazZm
LU5PMHVDMnMJVeOzuTitvYwZRB7Ox5As+CSSiMZlk9GrvXW/uOqIXCRowPvyfazRqRZXrk3+8+Sz
c+1ZTkwiikpLEInWgkNmhOZKvMivIvnYKNPLM/ATNkpwyRVLAAolmmVFNJBYpfFDTMozYBX65jeK
xniowC9EtfIbDBjcvaM4unt3YYdRwncuLLYrj+oocHLFst8ICk8gFVNA6aq4QYYizrHutHxf3QJY
ei7M7DHlxlKTsd0gsEP3YT5p1MmM1srNeqUsnAdha7HSdB7Vb04ZKGuzMtFGCMYk7EeAzpT7rV6D
ylQNEBpV4auQs4HEbdQ90Cq4S4wmZYF36TfoHKkElYmqbxKpKejKyY09U3HStbpDlcjo6GXQ/ok2
V/0A2QrzvzgetzkBjeUA+YdCHaH+XJQ1O4FoG/GxWFOQTtzIxLLB7ELphEezeTx00VaVDtg/2+Mt
5lxN4hl5g7qqMHDPmtaHEkt1w+zkLx4pMWN/qdWBzwrLeyeX8pZQawKqhEOjfDXe8giZ1SZqTWd8
XLfg9ugf3ptr10pqusYYC4kzZ1TlH2s1PYmedBmM5TpME9OccBr1o36TziKpxmPcjUUAl7WmCaWE
6OWE4x2dQeVmpVxwmcl3nTRgWGCx4GbNT4LYXi4MLThAgZx5VBY5G+jZQrpH9UVaDOKjXI7r3OAM
hAzhZmNfIWHwvmosJp/6mugJ0BJNkZFSErKKO7CICZWxKqNmA6kmzC0kzC6puMRrzKUC8WN9foKm
QyZtjFV0qBKxui5j3fnzeIA/ADdY86oRIBTPqSL4Ea85UK1MDCCbOMBsczBwiEIVY4FSyKOyC77D
8cd9H+yPEB+V2ICiJDAuiBp7lUuPjhuBKYxtATa4iO5McPFt5RPjiHqIlFyhBHJN5Yud0M7R2Jrk
lpG0f2swMvohJTIYVgpBrOfBeaNsbuPBGY3E3ezJeGhCQ6RoU4/bGCfRrX0P46LCo3fQymsnmEEt
0wqWsNfcXYUTft/mKPNn5KfT+FpysEy44RgOBffb4mbNrKaA2QampdeuymyqUsWKaO4wElgzYZHX
X6L9SnK+GDy5dPuO8JJ4yis5ndMvdK6GUe4RWShjHoeM9QD+enYGxPSGCayAeRtOWhPX1Atu2hn7
/a6DqWiFnfWW1hGFeOAMgJ0b5mI1YfcxRVv+dQ9pi6scbeOmtiiVDOwv0LypadLskR97QEEEFcSE
QtzGnyzkNgHwGuAu5aOKC/Kky9XwNKM59vnHI5ELsmfvnl2ARveP7jiIpbOHnNBlXN8e9U5Wp3IM
mYRdOBpnbZGG20n6m0rIguBS9J+7htgj+lKXdnuM0pGiCFHniLW5lE6IxnL7uANXljVzVV2zuLJm
Yi6mM1ekI+GVLlub8hZcdSa780MY/CioLhtGs45pIJU4Qomgdjrm+eGRnEVxFhTFoMZZWf7EZB0M
0kKJPUSzdRC08EXOiWG9aSAw1ZzQ3P8y/w+hC27M/ez/lv/PI4PbHtlm+/9s2zr0k//Pj/HHdV3h
ssPh6p27JzuXXlq+eKPzwXMq7haL1HIaexV+6rrADrCHiNecanjNQBToJrpzrKXloRwDmetACy5b
v4OYUTSQb0+Waq2q/FJpiMQFKa3MmvxcD5LTXMrUfDNTGH6lvh4ty4/BdNU/Fn7RWwVB+LE9AUS5
pE0gmFMfkQ1AJx/1vTKrPh+v8E/yuwzmi68eLafHKZbCoWQBdPlE5eSUD45WjnvNstpomSmxVEcb
BDfRHgOi9irVoB+kEWzRzzlXgKgXMbpa+4p0PZVK7T1QFDXuZbZP18KsIPqigwxVnfYzs7BPMN/s
iFZXWjyLVLCGB9V2MF042Gz7shMWfTBSJiP6EIwnjV0P8iBFVZr1Wn7Kb2Vcq7iFm0U/EGyZR1YS
uNABxxWVLlz6IkoRiMEwfxiIV406zlIMN1nxq+UAFmuPZab9cPsd183mA6CyrYzhncQdZJFwbw3D
OFRaVMvLSEF3vtIoio+iCy5Tj1MT32UmVGaeKVdkmCFyxKqwFwT67u0BEt7vDA+LhU/71YbfFIbG
zGZyUzO3e8I9XHPzf4CdyYgLhLtQRCeqjNzFfmKVsgbTxF3J/YVxqkUeLDPZrhEI9jubATsABJLv
Ox1+v8MOWwWcppiHMOEUrLm6Ebe+rPOQk0mjNeIhR44BH9NEwuFxNs+gLk5JrC+81flmu5Y55HI6
rGk811xAf+dcMdVxPIUGTI/noGbL/8iFcGE+sXJpmi5Wysg1t+Yygd9qwcWGdUseo8CHsrnfoQWB
cI5JMUiXI/aA9rDk1SRs8pWqT+C2GHvrykxCLk6uqQY75BKby2mFEJp4qjRGuIxwK/bt2jeWtR3h
DgEL5ktIp8OuipqnNBfpbFf2aZddLyhVKvJqYEuQBscp2Jxac6eEnci8T6zooXF2b8DUGrg2WrNe
zZ5+QHFPMWiVgH7APRzRGec1rm3WuoVeBYYPb1HGXU++nu9e6bz9Fz1Zj6jVbifiaYikRY7ogFL3
dK7c7Lxz0hEBEhjRgLQzq6+BEtBWvRYy5JQ4mZhg0lvToplW5Y9OV0qAjynSJDsSW2EzL4gFALiZ
R8fVcAkh7lBC1jKJrCdQxExpo6+ElRARWG3gc4B2mncCSCoakTXDZiixuQVCIxGdkddCuoxWRDjg
2pSfedTannhYs6RSyvNyH2pdpP35oOr7jcxgfmsEfEd6nnCZcha5a0En5VWhKKiV5+5RztzXOR0m
QyAc4D9PnteTEVHWoXXlItITEYWVqaw80drhxs7NSB0mb0p4RziYh+R5GcrD94CdNzD46vxZDg6K
SaDAg3slpHzoNuXMg2TLNAqYqENDI+PZEaKX+G1wPCu8pTCpIJ+2oNDwiMjzlgWJdDgbPgCDwJuM
OpAjQpwsBtYctgjtpEI4ofd7EHtyjiYORjbO5skz2m1OuOQHzaQlCm76oBNqudyafAAQw2YUI3Jo
BJgGGxXbTEOYYPrpWgVb2kmlbf2MRp+iM4wCgiyUgfnPzZRAOs7kXIUcA6Yl96GDdoibpcnotybc
DLxUmBdFwMK/POPEWarUTJwYibMlYcwyIcGl2xeWP/+I715kJZjWSb8P5v0hHkeRaQVq4zpwxQGB
Dnnhc6CGJiXUX6mBaJVByKMLIVy81TViCM6zawwCKlGUnEw262aBbaAegOFqZuRr8JCYNQPNqUFH
1kATvKXsf8BbiiVEOXxVkRmJNcSmxfM0GKEtpnRIDT+uChCod0TryD5FWhQSBtKZx6g8lTGP0sXc
7lbP+hMUrvAJ1cgNH5Pabbw/wclOHW17olopEbOoVowcaqnaLrMYR7/pUlWkzALKy9kR/ezqIuc9
iMSVoBXoLbSVzy8Y501J8gNCaDqPGj10u4IAl2XBqniUGwx5rDevA5niMFB54jhrOBBVt5xnRWiv
iPqCDHH2lD+73ZrMPeqa4AgyAnI/NRAbqKt+p1wptR5sns7/c2DvHgcu+Mrf3hfTw8tEkhleJ6YW
KDfQIcK/IfUwKT/OhOgLvZvVGVnF4NkzP0Rtx4m5X4uDnYwsAvHaPPWwEC4Idhq40tCbOpwXryQb
z2Eb6gIxOQHycV2xQS12jeJdhvk8OrY07g+GcFkkdgIWBm4IONflv94RGXDf/wxTkDLifvOTzuUL
yx9j2VxRRFrU4saixZ0vXu9e/0f8idK9hZPU0MD6z9I8Jf0UAaJZZ4M1dkRVCJTZtCbZrKGqj+kr
36g3eFSBiA3hFluEChWJqySiybD8LU02Qg4VxneXoyBg3f4UKiNCKRXkN2Cqi8C1+k3Jr7Pe3xdJ
e3XxXdzdCObRFTyokbFrwggmjzUh/VYa1oKlsklFuC1yLC+glg/PpXG0XSmj1gg+46dsNt84WlQ+
BYIf+o0/RyAWwwBFoTCs7nrrS+CdV67flGyDKPTK6Wti8/NF+BpD25bBv3hJeKGQssE55ekzGrnD
L9ptIvE5cnel9gDz08udM3cSO5SZbu3ujENVJcDlfNTr4Zce8xF3SJ+LwhPKZhh7bUgqnXQP14YG
tjiOyEcTVgs5XOP9ZiW048zj7i1QAenzZ0HoWLn3EctHGKR+7nM4E07qvbr4BnTUOXk3InXLvY3e
XlaNKo2UvL3tKZCwW4wJFcDyNZK3p+c9lv0J9pMVA+4aZ+1i6P3n7wvnd2BE+a2UPtdwjl6AZTMB
S2TkZvc7k26IGOnl7++emefJUB2EfrFeDUnhA2Ov5LlH90qASo/xWYi98U3n6mvMGCOO1dN4umtx
QMKJxJudKHsc2TjCOwQz49hEFKmNLnnzbLxLjXsi2wdbDr7Vb4+WDeNvdVBTBFHHrwaZ0S4qvYDq
1rrKVI0MmIhcQxQWPpyFC1cpeUFrLaWCUF2x5OKI/LTkIAHM2fXvVl/HqArnt/sOOJ133wVait7B
u/ZhIogrZ4Wo/8Z7nZvPY+b4y+fhb9FFjnKOm/dMgCcSPDFVhQ5seE9iOkJg1AAx+lIcjaVjyEqp
X8ewyKlpAj0BkLsGHWAuQ5f4VMZcWbqXChJdeXb51WvoYUNVipYWr1k5a0MmjGQzDSwsxM7sJP3C
hddC9ouFx2wcN84rjbSl34l/EtvAKvxJ/UsPxM6cnWK37eYSqPGH9TB3Fq+ms3RilJALe3BihjdE
W4PG2PGdxd+Hhw1eCkUGArkCY0VidPh+I8Up4F9CkMO/+rV5FsKPUYym5DSES6kayub9Yw3YOmIH
snlR+wrYFgkctCTm95i9a7ZrMl4sI+wqrEMVuy1ilvB4qNwnK2FDX5xApnHAA4MHR3xyOqcIJjOL
w/FKw2sI350kIwr63vS0oKxlzIG3wuwjbrYXIYg1wuhCr3TsUFH7vCOUay1q3js4tv+p3XuLu/Yc
ODi6e3dxz9jB3+3d/xvXECjx1REjkRsmK9BOwGVocxNtK7axhMVWWLUohStVjRSmVKAhDBujiMwt
cItDg2xYodZsHZFPUX4p1bBnwc9nBfuAEcgi3zNxKJZKCfWj1AtpSId76DTljSvE2zB5KkPj0XrP
EbKFMxfYuh1QokTZiSQRUR2emnyEkjyAddTk2QB8SlVMp3WAovH2CVNKaJIrFiu1SqtYzAR+dTLk
+Mj5Fb9ShcqsrmOqTubVyfEH80d6lRYD/9rvUXf0IhffNH4uCi9oS2tIv7Wa7QCTDKLRhIQxEtrY
0vYrAEu4ia05tSruiNZkSbn6OLE8nzWTjKvym/YwdURDOyN6Wv1mSXdzNnCGbgnZ9d61rCRDEQOn
Pv2U2g9pOeNDlgY1c2tYCabDR0wwGWkW5N7QWGIodZOqFQ+ThxesCA632Zh1R5x51yo8NeIcsh4F
qEx0vfIE/WaEtyTpE13Oq0wv6LmV3fEF8wXXa8ysbxayIhpiHasy1b9hetRHmEiZftFyKRvzDnNU
IE3GnT1EHAoqeGTsEdqvpTFZ92AQp8FqHTqofmd+IUvfxQv9ziHxaTw7HmtGFan2zryml5fqnD/l
uM5DjvvPk88KQw5NT4NIMhTp9z5fnyCDbehaLefEr0YsHxLS4KLJWxhjAdFvFjo+4pHJ5kCz5WA9
DbLxAlOkez6tfkfOW8OG/Rr2g1FpRbFDqkuJ+1Mk52aB18T1ZCfW7Nr+NtwwEyEVGvLYQfzOPv6W
pBiSDvoGdtsQmuqR0YzBwfCYOsoD5CKdxjfQFdyNvQSqtWbxFpavzLbBfueRR7LZBPNWxCZ+xGtW
KEyPWIMdT+/fXdwxWnz86T07d4+5JMXCg7H9B4tP7LIe7Ny1340ZJuprIYfIxlvNYzTVXAp15caz
S9981H3v/dVPz3O4srCokWlYt0irAjvOvBxsIdFgKCYZ2UG4GtsGWbwKqvlS00fJUiqohCdihu57
seQVsYRqkMmux4rIqxFZMMmYxSHYy5+9ufynbzAzAS1UGD5pcSIQ9/WvV1//CrDC8r2XlhevcJ2N
zsvnOcsiLpfCBbhGQeJ642k+csQWitIL0Fop3Hk+S9+9v7S4qGYrPEOSDPJq7NDXxCo9qzub2PdQ
XW10Yxe3mdzKRu4HKbqU2ruf0fy4bSKJw3biBZbZeqEcKUbIGNJiUPMaNpukUpsgqRkXd0MqnXVH
JxedH5gvMp148LHk0TGdsDuuMxrC8xJWIgpYlcW/Lon8mrukOhFLNtuspogyFr1balVJ4ELLL32A
hZXzQb0045O9UnfQa8Xkf+k9BHSGnR71Ktw5Txc/+SB/oznPL7taPrjhrYOmFHc/xy9GA8gTp+SO
39d+iMmKsyb4UB3FyZacIjasm2I5qyJrU0ShM8DLwOlkSSAWKcLxQnBHwCW1m36R22QsLlNwmEmD
xfhuad5rwjubI7m0nLfO8id/R2eHs2f+++RHrrXN0p85f9BH12GvObdT5qzPkIPIZL1a9i06GJSa
LKEQlHILsu3IDAy8AJTorbA6kb+hgAeHVBD36BneKQqEwo8cBKU95Ogo6yeMkOqhN3YjCRvxrYe5
V5m2Eb9tFc8o1Ao/DvfstS4dLmkLsmj2FZFXYs1eRYup0u604aQX5WpYtz1iQ63cMQMks1FXI9Wz
fWMEnMWQsyRdjrm6gAoZkDODjTKjlzfSZexNoK4qNV182zn22z1P7969xiAh6hgatK6TcKq37xNG
TMrfnEJPN0tG336Iv1X+Rq2PiCxo+vTnObu3JCBeidLFZbIJfpyi4s06XDmFbDSetcc3O5SS0dod
amKV6LQ3GIkFstkya28LUzEtriNjSc3mLvnH/FK7ZSO2WCaepw8zK8RudUa6luJsLCpimRU7t77k
+i3oR3n7y+67f+7+4xywNavv/wMZNXKNVPV9vr/71jwOuxAT5m8J+rFudiGT2K9figPqY08HPG3W
XABdzYt5SJWa22LVgEObp+4W1vAujvU9VWdPfJk7Va9PVf0cUUU9VRqZs0z/3vYEQHm7KMNDYhQ2
mstvtrc3r4Brg55KYq1T0zgwiUA58TfueKyz7wOOkuBDzkSXxsOyEEuLF4RPpHCAhR/CeiG6I6Qu
7CDfj0HPDlZZ4b5UoqGoL6G9Xotf7WnjjG6V4n40TigXAN6aqB9zx7XScUFeUzh4jZYr+VyNEUv9
C1dXAL51IfH2UkFSrBJv3l79rjJN0I5VBI2LgzTQS7xJQ7zQi0aVYNVIc4AQoYUjQplsAE/Fogit
Z5FqcexYA0W4qA+e0OLS2lSxwiIpUawFVnosXuvQ1XKJiSMyCIl4EV2qU9LHpjgBwIIaSzvaSkXs
A+jYv9UasznW+VMD5UtIgyqrJnke5hEYaqTqUMNpGnUSJuQcgFbDXpBrINtKhC9j4DceAPGZfR+K
ZibAO2EmJ0CVmfZayOWJip4F5V0JO11tqEXa5NurzWUiLeUD0hcyc93vaEdC7IkYiBzYqEmY35Sm
lI1VhrlYfahZKYvI8BAckAd1LZZKQlpgc1V0f2mvDrlTLOwZ7N0hF3Mr0ePf8nfUBMNX1YY3TFbN
hI7C5dGSZK6HSk0OFsXYErpD398kuwP2RFPA/sSgI3ZJ0jwnnctQQx2DGVRRqrLlOEKnLY14FloV
XYe+hpF1jSTJ1uvAQ/fBK0e01ZQIA3Apa630wBCFckNhMYnH1izSnGTPq2puMq1Kq0oOgyxMkPYX
cH4Al1yqb5WbWGEoRGCiTcQvbJ46XHCc//cWVblhmoshK29/hY5fxNy5Eb2TUofFdYPFhaibwzXH
mdemumDagYWxsjRdrwe+tkY5ffFvEuoO87fjbHqZWG1lddxC1uQ49wM7Bof/wPyntVPCqVHqaaMs
5jo2ymUdIjl+3fo7s67Lix8vL34her/8UufG3dBvsDAcp4CNksMAeM5SS0q54XgWxpr1KrUqXryC
LuKwfRYV8jVXaP8UAJBVk2tYCk8VCsLqvnKje/5ZTlDeufrx6psvwELYw5DXBRvEBYY6N19gVypn
tIbpUxqVkqiJKbNwwpbJecWxmawZxMvKLCLd0ZXr38LFpSqJ7G+KHSr9TsgkJtxJV1MLudbdjCqd
YvQgUk2RoMXSzk9fHq9lyPbTKFUrUgBUdDORuxiQkdxhc8Ey5GdnUB3KXwKB/SiooVjXtROmvmuP
N+uXldLrCXShwmQqRs+4nKrf8oXkgteFmT4NbWO9bKkJ4x/JlSrGUxk2RGQIQA2u+BiWyhiMKDCZ
JSvVG3N2y34etxePz0pUbCUCz46KwDN7Bcr2xJPn2hkT7sYNIkD6cC1GCDYa2z4+5F+UazIWIree
aAclAAty8UM+IsMlPaRWoN+BI/BaqIfCuiMusyLh764RipQUNxXGzmHWh/wzbcRqDY4RpEyE6OiV
R7MKhgpmwgmReqOxxpoz7uFaA6tCYAbMIi+ZbL3hFB5yXJGL1V3DvdWllFVpkYODIzbCLK3CX2tL
/tGHWHJMKrslLEyUtgNrD3IeL8p2iClcD9fWmkca91gUCM49Dh8GXRFUz50YwfXRDSKQkyD+X5UG
XSreNbQLwLGpH3ftK+4ce2L36MGxnaQugKMoIrQAwM7K/IYErRPtWrnqx8vhuhFf5ijIN0iJa+XF
EE9Frg3xTYqj/M2SUfHh2k7JbpiuQ3Qz28YrV5O5MoJ86xgxyCqLh2gnCCV/0Tzg+tEYhOp38SXO
YS7mgo0kzpU3UEAtYakiOYwWi1lWQ+MOkltCVtjhUmt1g+odt1hE7F4siiWQeZKPQCYhwd8P1/Dv
TNZAIoyVStOz9XJmsP7Iww8nW5hIGU2ojoQMxDS2oSrqDCQ45LDXOlJ7crfjzvoFAZH5wYA2Vk1E
zVMUkXE2Xqbf2rVqpTaTkTSNYvSCaT3wRYpuYSIIETto0zwhwMXExqTWZadBuiWNMF5ATamFERx6
pFJvB5JQqSZEZOWvrpVWwQgPFDuWSKKGRYt+NVg/LqxaP1oM5mZxr+S1TjBAJRFk+aTfmcV89YRH
7DDAGEJNp2TFCVNcYbk929CSc3C7fsnRUAR17EQl8sBSmH656LXhEjax+FCR6AcNip/6VUuRybNY
qR2ptCgzG7r8BtQyfDZipWJHrZFI1pMhX2SVwUeIz4VhNUQh7MbCxzbIl/Ns+NYBv6fW3WDS4rTd
jwN6G6OPkUUkgJAEjARspU05BKG4+Sb7IWm8obqfyd4yKri3LMUJr1xm5Rppk+TFpy+opZCe2/Hq
rywrvtfQga2trxgx1KfIGLUAkDLrU0yNZ1ORN9m0RQwULSwTRs1GvJnWnAMOF8ixA23I0DfokEup
O8dDNVjgN5gXM3ku+ilriQXxwYqq1gy6PohnWq5JI4uOfYos26lS7AXDUmV0nJVB9uoJiy69sC82
rxwrCP5DFSFwNaEjHJsRU0vPYCPuGdBS1czaAmv1esiDsQnCI1nXyxChxDyVmcmqNxVozZUDs4zf
lDb9Nbn5BK4kZFswQdNE+nCNd6TIP8jsTOLmBSAkotp5fVmZVMhEyLuwhJZdg0mzFhPLnan0GdlY
V2N0Vew9iLGnm2mjwwxSbEkPiwHiwjULQa8QGcHbn70QLdnr2rJ0T/AhKOCcARFgMR1PuGE4KVoM
uTil4rluGQQvQ6dVuJEMjLeQvYjWUxIeTzXKd6rAvsQIazW9vNdASotp2lEAowAkSUjcIsEQgaRb
wJ/xhO0oQBkDRdw8lnGxMgxZo2AzqvbiRrtgjUjyrO2+ED/kZP1pqxPWAHEbYHFlM2NQcx9dOkBY
so4Ok4bmtprCNA5fuEEbE8tigeWEAF4RKAZzwAhtDcKyWYWQ7m+ymoXdDNSgODArxicVlr3yqkVR
2EKPjhDcdcHINKj9ItRHxFyCNDI4iNzVGqokuQ/SexQpHSlZKPVvqzUXw6MSbdHTI0ecJmSvhrrK
GsgLdLIgGE3haMKBgKE0EZbRoG0Wd0Ka4XnCHiuFsIl26zEdZ34SH2bwr37xZPfeHb8pjv0+BBms
q1TDADJMzVQCtgGjlQ3daPf8WXYxXT15tnvur6zVUAW7tHAleLX7j1udq69hkfO7b3ROndHLfWEJ
npfPK/1pgmzOsU7Y05VPOdgSq6SfvtO59CEGPp+/k9S3u2D51wlf2Tvfrdy68f3dtxBxyLUeYpjU
rNx4X/wawRhHaRLQ4wlgQARhxrA2oBGdGE0MIfvScp6EcSwUryUbqMDPMEYwkuSGoX6NdBB2CLud
5MH4pttXZJxSqNvYz8+kS6DdNo+hmJmocQ36MEOvMgkhVuECYb+4mAvq6QMRSFgiBw4tCiX8hlnf
LHRdm8tEXKiwT1YR4ieyqcqR1p1wb+0gKMcOrbFcVDTDKE0jdj6xLmA0/3GbkkZsnmt6suyF+VGY
O/uynP126fYFuEt2NIs0cOLTqFcLJ2+IuLYk+LSskQYxyf3EVkjojklaDQy3Z2SLELFhw9eTx9PM
32lElOuE0c63eLg2jIkt2PYaTbTsRrwDTKdi6S6b6J4U59WDL1nAFXXSjPbcQ6sW77ItTIa6ddl5
ipltZ15Tkv52bP+BXXv3LFAuws9uYPaAL65x+IPpnCw4UVkXNopauT8Q9vNTx7XKc6q53QEWQTcf
9cSg1L1uLkx22ZXITbl94qsZMUg2skedS+fR2kkrF56Hn90QESC3vuzc/Nvy4qfo00TdLEShohen
2sN1w8YJvXOxaGEeve2rVnBYlA02Ld49VU7aCmzDYlT/80MawM1qqgZbaUbgCG3dfSl/7yMZDqCM
LYQyrgLy/ZrT4Cy/96yrO3TAfVv57s3OpZuWgbhz4TYWg7x0Q7gg/nEgYksNCbfeI3T57p3l90+K
9O8hSJ5nwzaicj26wHIPIOoX2ThhzOam1893z1y2HBqBgHRuvgBs1+o7HyzdPtl99SuY9PKXb6x8
9RXSHUxOAgP/8+T57q3FzovvqewR/zx5AV0J/vQN/CQTo14I++Y9UjsHm+UMDTqdMy+svvxu54VT
6Fv76hmslQl86eJLnetvwdiwlzgedLK0eA0IoNphmgVsLYxmZa/oXPg77bRIzKryh6JExFnX9cTn
Uj1qbVIPVcCkbrhnrxXcQ0QTdi8YHrf8CYZt9Tj4sKqmJn86epxXqA+VybeEPwEF+mPeKqkbxS95
bCjLA6JsKdQCSIgLrsws8+23mC5FyyijfCeWFi9qCZg5kWjn1OfL914S2Y6yvQYTuofWXMMvVNBq
Hw4bZk2ifD0cJ8NJe3p2KXL6aR3d/qL7xrfLV+9Qdmjj8Hv3JFPFqN4oD66al576knMhfn/3TB4Q
CiZm0o9BUhd5CoBY2g1N4Rk5Jm4gM2m2G5GZSfFbVKZxmVdqAYiquS4tnuJV26oorOD8qlj4LCPB
cJDZdquNFrUiIGkAe1XWPRO2j0wm1KmsNSHBXRB3CsxkhI9we4xiaVLIA6ZVCMNUzJGplLXmk0QK
11SyorEgEdypT1af+4SxaOfWtc4pTKzM7kE65lxrouucpdiff32S6HVuTk+YNpXymSRUOU1TmWyg
A04wRJ/zo6L5PvolA+R3CmY+7WhBUv0EwDQ5kWXQI7uhNzHR9I/oxri4iyDQEf/eJJlXXEX6B7c1
CCdtppbtKR8b6Q+1pZKdZJAivpnX4ToARn6J2ISyvJ1kEI+aM+5vA1VBBs2Fq1BEVXuxyFMRDqTa
duDmIS9E34KMACpu5iqZpqzHc+GVpj3ivqgLfj+jhU7qYAWIvfv2V93XbrIIyDGJKsAmRt5Jxm1i
R2frR4BJSphEyMGoaTDfY4VVsGsN6qNevrr6ysnVUxeQIHzzNecHVTVucN4f/AXJBd0I15hD5JJi
LV/hANwbaX33zvKrb/LauWOQoMPQhpfPx6CvWJQeuwUhAOdK7NbHo3Iq/xjGBhkp8h9S7KRcZtn3
Z5N2mn+VvSvoPPD0vn37xw4c0LuwNqpVofhimdRrqlJLGkM434Qbd/srTC539s+wdwBYnVN/X339
C4mjLHdlvX9rAqLgGUqu9Qow/4VDWgh0q95wlS56XI5MXx0RcnLxXdxLdV7Sa3r1/X8As8rRKD1G
xzKuQcATIBZFuhiJx8VKOTyyv3Eavusf4K0BugaM6qkLyCYQY+Q8/fSunW6MayHpilWJJfZFEBrj
IBJfFTEmhtnnpIfh0MjwOGpYDqlbPq5iGOfdHJvn2BtnIU+oMRByj+pieCQufCrWNGt78IWTK6hV
5H0cpRiqyh/AIJuNzVsSmjz0ufcriwYmyJK/cI4sNGyYZmPTiTuJCGUtT4/YlYXKVKnVJzW8YqVY
3yQDCVALpklxWbuIo4o44PB7ziKBad44uRsQozlnGuuDY9Q+/o4FFATK5fLeINdGyjcaU9hgTEGB
CatrNOfWBG+qhOyAX1y1kTf5/BNyj8bClStBAyuLK8odORypLxjb+4RQC/zGn5uoe83yLtz+ZttI
4CXODr0eM0NbBgHaD9e6fwbm9wpO4tJr3a/R11o5tf1gyghjHpjIVdKxt4QXPk2B+Ypee6BzGPb5
IQjJ04u4JcR2Znwz3TBiLkvK0gzFQm44cCKGCC8Gx8eExrx+7hnJsVDV9xjTJpfrGPm+3L9M6O6l
WE7iPLP3rV+OTPJBPM/+Xd5nodaj1zEIdmLEek0ugH+m7cgz/9AfW+hp7/5dv961Z3R3ccfep54a
3bOTq7Rl7ZEF407nT4TeHte1ifylGz3iTdnNICamVQ2sO6fJJpzQLqNNSACuYAT6DQs1XusKph5E
VUSxSHOXPrduGNUCYPqv13+Mekv/2PU/Bx95ZGjYrP85NLT14Ud+qv/5I9X/RA0cJnyOK4nDkgQI
EKhOFMT4yJCjBIikUqCyDKYX+Nu29q7uuVZNz6YfU51ThqsSsmp4c8jjyEJ6XsuThUTQ4TeQv8c5
+qKWHmbsAfcYFDJuPyKREcAiMtRBOnAYMbPMXWLeF748A4gUeKn5drMaeJOAHLZtlagU5hMp05Rv
smHfLSgiHpP4WlFtmBMagPFhjxDCMDfrrn1Hto2KvKr4koiVdjfB+oayKrh7HelT45NhX3h1+dzn
nBLbUuqGWtbOpY8AaDiLm0xiZtjZhFGr6ecn29XqLDEwTfeQl5sczT0xmPvFSH78ocx/jGyCJ8dH
c/8FT4r53PhD2f8QWevXLO+Hu+CwFrn73t3O3UtLty90v/hw+f3rrkYl4ucgRhwPP+aLufHN0aF7
ZAtnE0NcPnUToLBHGwjCIhGGl549UZgaTLA4Lj6IPdp8uA83SXt9jfoW8mqvPHePnWdUnQtOLHUZ
LS2rH73W+eL15c8/wtxTX7zevYGLWbp9rnPm5eU73+m2g5iaSWFCbZ5Xf5gUm51ZKau29Gu1yhuJ
q6oVQ9KY2qSE8Un1NsRODjmPFTgPOPy77eGHtzy8xk6Jml8RM8IPnxFdhUer9UdT84ZV5+SuCTev
qC8ac6tWGTuz2BTgT9lEKzxnlINSbfVqYlxODJGoXyoHHn0KZlD+7rV6Lak+B8ApHxS+tpatRF2e
JEdi0wsoRxkug2lv+OFt9L06yY6hylFXW4tAy+TVAgJWb+/f+GwgIMlrelRVYli4/4o8xVYt4Yhv
MGqY9QLDjznDshSEhQIOPDkKCxsJEcBDA+PzW7csYBZWLiU8NJ7taV8U6Wquv798/fUIA+DMS3ha
IOXh+dPLd75RZq85kdKNxAUpJQzx3e6ZQ38SINJvEgNeCKcpt8NGALpUTENybYPfiBp6KtxTB0qt
RmLSNY3plitUUd6aWSNSRLRQivwZn/jlHnhNQ2li/4FTerxdqZYdz5kFtIiMAdm9kKOiQ0cVDKlK
0AMMZeupJolYQR6ZLG02grW4LzwrXK2zui1ivZaHRFODqmujGRoSbYBxZgYubrkuG3JidRK3Z19l
f7beW0nfufIJF+1d+fbPndN3Vj5+fuX8c1xBCIuTfnvOdr9IsPe2dQV2WCWKaegD2bEjpmtlNneG
h+/bjP2iMmPfp/WapoXERV9cnPla2vQ1F1s8sDFRXzIGi6+hMZVSPB7iiO3CGYkSEMmP6WnNYXGb
L4EqYNUfljzpNyvCZCM+dayAkzQKp+AIy8rbd7iEKIOHqENHTDEv3bV1IrpaxcaT7pEGRll5sw2g
tqX6rKhPUhiGPwJpumX/SE9ipONTSRImJn7faP/m19uOTx8vz9aOPQPPDlafOf7E48f3V4cnt+3d
O/XI8HDpP/dMPP2oSI4LAEeWKjgkpUmxvPJ1T7S2kRbR3C+MVaeIFYfvhSw1lHQt2CV6eDhSbSyM
M1CPU3pNFbuwD5JJkUHXb5UGgBcYkFWtiqLOKREIoBVx5hQ+rhC/q74lUtWAKsSsCqaya2qF16Xr
NVW8P6QuKIyL/+F0DL31P0MPP7xt0NT/DD7yyE/6nx9N/7MrCNossggzcDANkJ6rVrCqY6jnDRzM
IEYWJGGeSgcht4L3Gi9IXlcHCfUPif7CyKUpecQTUexDvkPhJvJLPbgf9ZBfAkSllEv/X3vf3t3G
ceW5f/NTdNrJCrABEHxLTLgzskRbPJFEHZJOnKVxcBpAg8QIQGPQgCQOw3OUyciWHcmSHcdOxnYS
J/Ykk4fkzczasuTHd9kVKOmv+Qpb91HVVd3VACjH3tk9hI9FoLu6up637vN3EfvDojriK9KMqH43
WhAKfHrlmeWNlTPLDgDHFyfOHF/77vIasu9AmjvgM9ytuAx3kEel9Q/DDoQjLmY2Bfft5eul3Znp
Pf5Z2p3KTYlf3xQbefkkUZ9za8vPrDyPOb5fuFQsav9XtGTM5q3pojuxtnxieeXcBjC8/HoCfs9f
mJb4bUY0UAcP7CdV9E/EhZ5AE7eHoT8YvcTmPwoQQ+8WzECFmdL7HZCia05lx/F6QatRFfWhXCt5
UoN+KmQDBrbjpFZ2qqjbx7LjZOSsuwpN3yHkRxBKHv30c8GeQYLhm/8y+PwPD169DcE+9z4Y3Hgl
EY0g5GpRinjJwZWPHrx9a//XL1lh9hmrEFzFGcWA0XwzPJ5SIOOoc2njTGaNMSGLJIS7fDwAkwCs
zEwMgEjc+H559bvOD+Hb8+Lb6GzAwIZ8+GJyaMTZe/M1ApS9f+cN3UMGrB0v/gJYmbdviUOZuF5i
58SosCcPDtL9O3edXWrinpHILtb/tO5bstWl9+LB7+4BK3L916Cckm91VDMh097Ln+zfekUxnoLv
enj7g/ufXX/w2S2KNLt/91U9z3Qi4sQ29jjoazDoKJTTNCPzwZORjYO2VSk20SXHVTfxnAsq0isf
uGP0+eGtf7Uu1/d/tUvv2aOeWGZBQtHjdUEL/jZGW4E2pFkvFxMx8nEYg1CCuatClsDJNNQtgyRF
b4F6NSr2FQYqMsppejtiI6K1wgx0SejbQSsWRqTOq5UrOz0/hKg90D7g7QyYpgVRDWOVMS0ErJOz
Qe8Z0bSaRfsu36DFYO9gzmqi7XibST/C85QVtgLfRP/KhualCY4hELclCDuRcXQTafRCpxKIcRLr
Juy3CAYvqHNWQMkBIPXz292g2QQhURYQwmVhfJQ1HKxhGGvpAGsFM1Y8MR+BhOiikcd/bSnpGqmw
JTTeUnuLvzbzU6UCTCAqOCugFUwDMdEg1NKQ07iAbATYjZJloRwGDWQSwC51cJbGsYAxbgeZEdgv
OccEn00AHiVQjTiuL9rJEmxAroKymLnuDo5uZJuAX7oiuHIEAvAA2yvnA7bxDiZdWHKPJHEyicUq
hD6ETWG1UgsrhqYLg2PQODQhMSByg1wd2LkgQ94CEqlWehw4OgjcUBgXiTOYRfWv5IbBuEc1m8gx
WH2ENvDCC6BVfkF8wLrHV4+4R3LOEXHpSKR2A4qMlEYfQvgqmmrrPeOw9pA026dBzgJeWtRClOQQ
xEcKC25OlxT8RYTtFoHjgoKZOF9N35w2sczszu65OX6JmGwxcuJpP6x6nQiuejighniicsR1NEbY
yZi67fmje9kjRN42F7EjtPAy2ZLNBSOlG+6IN0gOv+VVXXqZsQorQdDMUNUwwmz8rczP8oDiLVBp
65vCFACUJrbrXwjO+2VwuTrIYQykHlXvQ44ymUz3fLxg8uzlTdPH0MeiPCva8twk4o7a6qAr1pIg
6dSCqtcmN0LPgSOQFNrQSo1b0FIeh1roJYwc6PESewKFEdwSjTY9lHa6ZuOpo4b5aOkHYwIkG7Qo
HHiNb9abQMcC84yJ1pZivp00hGC9oTc5efyhXpE4kvCR5JmSONFVDTnNCaxBnF1sWPH44sum9IJX
IZYWwQXKoRijWC4GLGFgaCmaJ9qZwl1a3M54KtD7bHE8ODsFYhfPaK2g6zjXkHiJ76ZCB8YtgJRm
CJ2+ecvjhbPoMgbfTqhvdYYcAoVwKVXjekAQQrJLkVGVoonDfr3euJRxSQ0ZW95kgjTyjVHKWLRQ
KnCIyLLLTiUkjeNRhUFZqA4p9ARxaZe3/UuZqfnsxPBzgU9QhSOWUxyoNpkcXXmRUnNnEBsK/lEu
cJjMAB6CQk85UqXCOMtkTRZ3CVSq163jw+63fvCt1rdq3zr1rTPfWncJw5yOZrzNlWZ10Bd4RT3l
PNqVL9IPpF3+tuceYc1p9zzaveq6RmVxl4Zhb3GX37rHhJTCy0fQhwyfC4tpp3XMZRwx4Xt8YsyU
suCPAAMHNxK0hokNClt+TcoeUvSesJKNJkI+8ZCpcx5ZT4KtpdWpftOoxMBeDcaCZBA0ZvAIHe8t
8bccrNIlXrOG3icFNfAJQcwcIXuIiWAvFOxBF08WkjbE2QIWrIrfu+j7bUdwqH2vXWWdpbhf8QTF
0mV7Hp8YLHKKhGQ61NpSpoghTmAKEpYgM8egQc3oRG4MpMgD+ukyDY5uKe4B3WWlpyzYWP3QzAgv
WrCF4eZy41e9brchViwd52INi6EO2g2x15SpjhcF2Y19UPwivgZ5TBQm0jkrfSfZGCs3aqNuUKLK
7C4Oul4VKYPG5qfHEEibLcSNSoWQJdCbyWalGVREXyTfxjOJcf8J5g7K5pR/kRnZDSc9PJeF4Aj4
EWP6xP6aUa4cUHAIgzish7Af9m/cvP/526AUQ4Pa4KU/71+/Bd4cP9Pg4B+XKwL6Jk4H/1JOkTm/
3W/5XUg9Y2OhxhBR9B2KpUmhEJNFMMcJzrFVRqfyUxikJNh40L1jQCaZWeEeE1HtYLIL7BVxlp5P
3AENST80TB9IinCziCfEMu1tN0InBOVJ1/87csBwQJUttkdPHn8FS8Ub8FxTHMrILMMAIIAIMM9t
UL43IYUqVIZaaIdDlh0I75c2FphCCCKggsmXkM4CJ67EAqUpJU1lS0jqeeCeoiJUAtDhprKLpUSt
Nf9CA9086obctAs7YU8XlZJiZJT4HDMPlSug6gJ9XHvHKuzDtPLrEkdsdjSPrNF01PYYb0WNLFWe
ltzNYSvLRIofoIKT+PgvZOqH4MSP//Lwi5f23/kVpTIGpInvYdLdV8hdYP/ND9lV+q/hsf/X/USg
5/+37L/Ts8X5+Zj/f7E4NX1o//2a7L/71142fH0h9oXCbxF25UeDG28Nbr8IJ+kX7+6/8j6CwHDC
twO5/xuW3W0vBIuu+tnrdQqEiGYEB0R24DQjLyCgqV9hM93gG+6Ehq2Xv/f7DfDqe8I5DYBj65Dy
EuIgESTWKS7MVYqVY8fyzXB+Nue0+kIYySO8E+DiAboNUlpxNjgn4YjtOqf6FTzVnj11Yq0wsXLm
+LPL5ZMrzy6vo92WvFAX52vT3tGaN+/NztVmi0dnvIXpowvTU1Pe/NSxqjd9rF6rzE0d9Su+V/Tr
c/PT1emFmWPTFW+6Pj9/7Ght2qWKocZmWO0WGsEkwqVhws7upEzH97dA3vUmTJw4W1ZP1rDBhVah
5gXVZtCvjV/N6eVnj5/4QXmsRiwCiELYcydOH396+TSUbgSsfSpgzLQ7ceL08edOLpdPraLZ3ZJV
F8zb4lcYOk8TuSJqrDnVKNM2nt3dfN2rwolZa3hb7SAUx6U4s70enuMVn0m9OOLlCQsKDa8BOI7k
ywv8RBU4a3HSek1yv5RZh2TkNkPJDkkv2OtmYHUVIHTbAJ4dEnNBR07CD3NjpyOPII4HXznpDO6+
AUZZigzXAizYF0Bm8xFs2Bb4b8usYORkTxch6KUT1IRUwDjO5yGHLHcK3VGxGHF/+MDi0Dy0VCi7
mAh3FivDn9BZLHEM+82gI4ZcBSIj4oGYFTAqnTi94niQJY8kQ8FbbAOzgPIMEKteHxA5HTDMOKKA
b4p/1OgltcrdOKtK6AqEUm5EFp5cPfHd5TWxFtc37Gmu1LNicFIePrF6dmP5+Q2bnaja73YJXS6h
s+KWUgYTUPBwkvKOoDQUdA/YiB5+390tLHM7wgJv5FNine/tuaUxcpeM58Ae5ZHjvxYotmgguWfK
wT2mxLKMoC75QDzwJbHnrWMWXz4YthMfexj04ytn1dzZ5icqI76dXT6xsbJ61h21WBvtemCZL1pj
OEX1YARsImFOWm+lDjG6wdeD4SlzlTs4tCXFSgYwF+XgoiB3ZSZeoQRplUqC0/6WV91x6PwNSfrx
HEE8xDEIYXOdbR8Ev2ZEJwvOiihIXrRYzpGpzJ5QFoOWYK0cb6vr+4LmirXrE7wA0GVBhhutFqV0
0ojvysnChESCaFzS9XJ4UuR3KZ0BJurey0uTBfjNonpUpclDmVdDQ5ZMLho6/jpeBSZttBFRa3Lj
0cTSugZ1z9s0sn5Uo+m8OLO2XMno4BpFfYAjFHm/O7v02B6A4l35iF2B3vrdg5evquBoOnwgGx5G
QwH/l0M3MSu2qmaIlHMUZUUc2WGYtGEbr0NJAjwmjo1mD8ln3cUFubSLDMeeSTrHoY1AXcF5IURq
aiWSY1RjIaNTc3YE1Ti0PnTcCBRiW9diWjJrDjNT1JT2T4rWwzrWBPmE1IGDXzZBeSUrKtneLMtj
7hCCIHNT8rKkQX6qlEs6p8T1ZlGFxj8WhwdipXVpjADXseqJSBTC0HcQGFVek7uNyWHdNcnULncB
VmJ4vtEpAylsbLVTctajPZBrtrc0dUN0W8qE5eYvuLmook13peaWSiMSx8aMfbRnlZqZYCmY6PDa
koxWkioZyl26FmdyDV7eJUIzuPUJYHFJcpPIh4dU1oGwH5K3SOMCToIMb8mknnrlCCr16A/XYgAP
Cbc5Pj4npJuc1yw3WoDXIEdW55w13hgLIflHSSjnSPEq5+gSkukRmc5HQG0mz4eXhrIWQ7bFAZiO
sZgMbEwKjyETupvDRkjumpNQYmjtmR/qjS7EW9Q9suwAzns0sjSk5GepZ3El5V58JnQ0VolRDXgH
u/gOjhI8MnkEYuL3HIL+V9oN59HP3hn8+AagUycOOSusa/pR1UeYOnypbRdmrWlhZLOpWQSzCzh2
b3xCXeDxiffi4asfA4bqzWv371ymHliP6WQPhhIX2QV+6WhaopLUDKWWwJh20UvdoI16XpDUQF/V
NlW5uX3gDSkHeDxMd3h+nicc8pin/NRVX4JG+M0dJwxAmU+O7CBzdADbmQ5G0uJXvTZ6QZP1rgfF
wz7689b7TeTOC0Y6CXJCGZfr0UXCiGmZ+NKin41PkSG00B1UyWNjR3MqOr1ItWhF8dFi2KT4CAMq
OVV0sGZLF54SER3Xj2fE/YBQ3TBjhFzD3pBTndEOxhMIvOOWSEI8DaxjSNLj7l4WLyIficwILlaT
mmuL9jE6XXcHH/9l/52Xgd2+9yZ1i8wKFKHp7MKA73GA4ZWrEdcdO6u5OxJ/IVJdRV3lSWGXD8ye
oQ3DWUqqs85oVHI8zgWCpzSHw50pFqcme9UOXd4s6aZPWTsO1xTcl1fE8G+6oKNY6bgl5BmnphcK
RfHflDucM4ihPQIfcGpjAwBrCGfkiyuP3hNr4w9k3KXo4Ld/CUijCP0RjZbfviBj1Rs9vyVBUZYQ
FIVOdHEZlrZlfWy6y+0LouWAxrKEaCxQWHO9vMA6hufWN1bPlJ9bX15zcRQkYKs0+qqS546vr39/
de2kmz1Y/z+9O/jwNRLEyOSbWA/YRYwhhQMkMQPnEJM2K2NLFaBsxwtDsQhqS6KJm1HzSpKWA1Bg
Ge2cZbSqZSgsAal3p9EuV/1ur1EH06SZlI+8EIhbQu0w2D9Dv1nPh2Lb+DVHe7BARlJB+yo+mVwp
qCF0wEcdOQiJuS8exIizCQ1SEShn2Cysr58+waCK8PPc2urG6onV0+WN0+vlE6dXls9uZPWnCMIL
Y0SRwOliqiyCIG47ZYl4LWo9sby2UT67epYcm8AwazgLsCVUiAM0TJtHYLiPlPYW1QU54OJiZDmN
ctKxw1RdOkxktsWo+10acD3iN55FK8IFgKR+kWmlgPvmRJSqQNuDOQ5m2aR8bqWIS5zOyUFY4r9D
fPC1NLay1e6zyxuYMhLD0bEHS/w3BosZLQMDnbkQgkeiWAQd3+9CIVjSXncHCG+LzijYgtqIWLJ6
mORS1iwqFadEJ2iHPnreeT3IPKo1ZLjnvFZTtRlAHRNWL7dWIHY+eNig39UCudde3IbwusT976in
h0A9WVqKnjg04rvucfb0QC8BSIv1tBc2qujeBQt1z1w/sc2b0NpOF4vgUEEvFQ2cLRYt+K7toL3T
CvphWTaurDdpzyrqxh8Cbn62OGUXfImOgOeLaHCIZgK9/wrgVPORAOKi5igXGX4wlHV9/VTB+iKJ
y0Q2ygJZ7TL6CBW2/Uu1xhb0jBKHmiOYsv7GpPCDKz96eOvO4NoXggkgBR1o5ASj8JPXH9x7lzCR
zXC2RGRlfNMrv7sEyEEYRqsMHTKbvt/JFAucmdvWXCUfgafDQtF58LvXMaHGH1S6kAguCU9jlN9F
kcGff46p3IDNoRQV+299pANHSZxEmaRUoiPKlCpP5jBclXPEGHRPqSLimgpyGL3YZkdPu3IGDucj
rMQ6wu6efBSYKmjYQVjZl0wj+DWoqA+itMIumTnSItxMBMpenBhfS/UVa6hiKoMJW6OUF7z2hnXI
IAWc3Fq/DW70bmlx4iDN/tIN1mfEIA6CYffIn9eGkJcy0sRQLdnUKjbDARZYHIsecVYhzCe0/5f3
AMfOqp2TyoUvoYIzaXtTN0QBR37R69ZCQgcBsaPgYFShJAyhg+54EHDuCfLviwqCoIM6o4gzNJzw
Q+DRIq5ncRFqdXVtNkXtRiWgAJUyB7XdAPmq3KE52HTzqLs7cWpt9cwy8JiYcVbzbChR3h9FvOhF
m6XYih6l6hC/cC3WSP7nlZkH7cwS+unSb0b/wc09nj1YPIR2E7SgsO1kaRfpAtlQACufxxBfEW63
8hA9sjS15Y79DhqkSERaUsIH31NShyD2+hgrZehYbxICzBIKQZEFOOfIqpfMyAhG7MxMz2az49We
VMeeWzm3PFJ9Ym70GB5czFyexPasy2cXv5R1IkboR1OZ4TwLUQTGS775qmBSHl2+PHjpbnKDq1B5
u3JiIgXNCPKkpomdcZlT212JHmr3LKwrSz5aZYShhFBwWmviDFdKSMOoCTvA+UhV2I+ZVA1/Nok2
EAe93lheO3N6tfz02ur3xTZEwUBDzJUjbAfH/c/nxXr4edxPDMv8K3EDHoH/tDC7MBPH/56Znz30
//2a/H+faWAcbo3yFOygcw6lWxAHlZL1JFcHMBDoyNMjUVwITug5i2hoBvrTVrdzABynzsVailNv
Y6vtjenXa8d0Wltd3ZCUDrkOTaqTeYek5lyMA0b1KCPGkITOWv6ITgcV6pFsjHyO/J7NORn32SAA
1A28iKyOecHCe2TcM41qNwiDes9ZrpFxOHYFa366C96TT6sMSrELWdNriWVOMFszTt7xKPIkhBpj
Iefm7cWE24rofM4hjRzUCmNhcTsiFBYl8GYgBc1TjlsQf118DSpshcw8KVbV6rorLlGdNrWRBGbS
Ip4jKB8KBLFjJpkRjOB3EuFj6C44GbeqTeQWzlQeL/n5EN3WEtcplRQ9pJaVkVgGR8DwADMBTbhj
ZosjvJeJMVJlR6PgToZtr4OwFlpXkqNC9dtKS5D9S36VPPUyyiCL6rE2qNf1DSNDKaXfIfqDyOrK
8IKMxL3NOboXfbTV5H2ykKAUQ0YU1aqEm3Wkqu91yVvArIS1Onm8SzYrV/qky2nv+hcaKP2JqTef
rm574Gicb3kg/2zqUMp8C3l5enxTFndL+qRm+CrVKNsBUW7YYIzI1Et0GyEXcHmtWZStsWf04RTP
EvxpdEmsTcwSxTB/1FweHyESgL1UdE+Z+CAteNZuxVVOlsbws5NQEPQkK1FmN9AMsbDKFKQOlK5f
7wuhG3JNCSYY9FzwOCnGwNYTiqZWgktCloMhqLFhSDqXbnshV9gOOLMcBagGqNclbArobC3wCSBW
cLK9RrXRAfWsKM2xxhL/kjFFSeM3CV8wq0Pi6Eh6+8sWLcERhlaKi2LdZhJPGq7/3/V3Yr5oUgrD
0RojB8Ojl65jJj/QoqokhqAnphypapgBBO7dX5K0RqUJWUzDvDN0Tgm/dLBaeTXWNwja0/NZ54CB
FojsTL+p6fltpoV5/JavNRATORimiEBtgo/+Je5kP+xOhkCI2gHFh+SSs1CyS9gHm4qGwkssdC6W
+w3MTlRE9MPo8pb9MmSoE2QJF4x5h1Yhu0hkrN1xkxfgN+WcHY7VrrsLPHjj948uvwHm8N1ED/cY
P07XxQv5XE/zrO1hbr7YxefWVp/GIBzBx4V+z8n7/Yl+ywvPO8WFhYmqOCi+CcosdwLsnEv4HeBp
N538JSd5hDilb4NBhry6qhBQ5X4TtG1t1cXkMz98cjJ+imbRqrpEr6YnZJFJCGkP2u63HdTBO/mO
eAWUdp1vf5s2XOhVJ+qNCbGo0QHqm5nWeeATnXyNi06arCAlRy48zx8xUoJMd5wj4rDNd+tOPi8e
48rcI87y8ysbXADge52pI86p5845K2c3HBCxJ7DDkC/RqzVB/5EXGyIEgpbf6vS1XzX/AmrU+iEo
FPP5dpBHb7E80Eb8Kc8xo5nOC9jJqB5QfsKebNfybXLpAH+i6D64dYrt3u7lCdeT4ZnzCEYP+GxR
56K6+61OviYIxREotQhqrsntXquZ+06v0Wv6/y02fqik+c4k3TsyEcVOkZVdZnyV58MQPttkbMR+
9tFsE/NRTOjKxtn8Q2lxqs+yEGmg5q3uiJpH1m7lX0bv+5vXEYXTst0BBeDeP4F3IHpLiWLidFD6
dsb6vPr24N7dwc1rWM9Pwaf23j+lnQPWs1zLxzwmS0BzLmZUzvt/1vl+QnAEYY8RD6X0K4VeFScI
RxwmZxAMCnj6ebCV0KkFAtblMTB6IaWcVG47qAS1HfegKynBIJCTUASEqhbC7Z+RshZCOxAdVT8n
mHcw97NDOP7DuYax0J1i2VkNQgapYpD8TPZaHTJ7wuGa7GsAWbcFy5pBliJ2gudiR3dqlH/Xb9cg
82okvZiCjEQLpSZn+CfzMeSdRLyHjfk4wNZ53HaYrIilRdLVhXITxuCh7b16Ulajm9UPxCQNhWRJ
LEFy7hfMKTH+kCmcyNTr1yRdkm57YMBpUdzkpit+I3/ZgH+BJUBTG/XBRaMSurlEzSPLh3t69dmz
x7l0/K6NNXXPHd84tYQMnIKIXMSf+AX/keyLq7wgyXNNWp8NaR+Md/2YVoDsnioRMUYo06JAKDRx
r98GMCWxpbYgKo8XGQfUMaUCisR1R7Sn1g06ZfUoqqdcpY7LAfF9oU0jgxsH51BPAz1beqEtNhsY
4ZDJDzNUGswHsLWyL7TdYeYyN4D0lj1RNKM9Qhf7fLGvLoKW4UInyho8W8pFjZldLGXdxN7ZhPuR
dgKWxMo6rgyAbIx1P5dcEKD9Mde2RQcXKwS9EDtFW5IlfbttqimGZvRdy1uFrOPGa9COStRHcYg2
bkgKrIAdYuxLTFSLAC9hD9OKFIAoIxCKTkGyWalVMnNpbMKlkpHQCyocuoFf/vz+neuDqx+SLT+S
MCEah5SYdIrokqlK4Cwl1GhbqyDPyIP4MRmCEZRXH0MdVY9fPx6JNahqkmrj6OW40gjYc3ixkTOJ
t5igAwhQv6ujQY9wMpybiME4qXaYWE70El2tFkFhtrxLkJBEvSmfeFPW8B4DHkk91Wq0MwtFDbYS
1L4YVYhvFJVhw/REMwleyRxwcASIlrccR+WpOsQfTs/KfbA83PrYFyhBAvj0qlbsRRm53WwKahBk
DscNAFyX8vJ796X9d/7w8MefxZIMww4Bzfh/fPo2pzWTr8/GFhYOB2m74yMRx0DefFKWcIXIu62o
JMr7OcfKkrkEHl3i3Rqw/V53e0A3NX6LWGAXa0vo5Rv2ao12WiS81XUiacrG6xMjPTG8bq/c9i/K
0PZkIAtOTbjkMiSzLecPxcDIosCTcxugZ/02+gNkrIH6cp1p7d6g+8uIAlaz5Zq3LLIklHlYON9o
NjtbGVlvBw5psoUV1leeBeVCYr2fo7Kng+B8v2ORFUxvz4QYNaTXc4l3pXZ5DDF6ZO++uxJ3Yhiz
h4lepnXMBFoIkZFqV/2MTzQiOWuLQ3wqkjs+cpFFVvfhR1f23/qIlXGYvsTwib3xCslYeowLPbj/
1geDL96ySV3EapKe1kgb6Y6hlXGlgpKWvuZc6gl+0opxSpvDiPLCWJhnjm8cP+1KiDZsAKPXoXs7
WBbA1VIWiAwjlLEQdI2CkZSETrw9u7k4NV0slqAq+VLyjtJuuABB8MZHghtRdBPG8tYn7jDtacSy
EOH9828Hd+4kcrxfpfQp//Hpy2Lcd6mZe6bCFM1x/1/Y/yGfQFmcI8DofFUQcCP8P4oLU1Nx/LfZ
ualD/4+vK/8XCZEobHJuQiFpnulDVoi2RKjsEipMBd1DwMAGC0dspzbHmEj/WcMDJAbyNo4XCHP/
6vf5LcMXxPQMGeoL4nUNVxDpGgJQb6v1eqPaEIROnBR+z1k5SabC9VPH89Nz85RBEiTGZhiobsPo
nNvpbQftPHoaAz/VbGxt9woT31teW19ZPSsENqwPOQhqN4gsZVCaZ2QCP8FrtWhk8wwyFxZ6l3pu
MkO8Tmkn1pZPLx9fX14XVe+SDW7RQQka35gF3RkEo1AUIxXIUe/kLTRHUZoOSo1rUHdqeHYvitom
DWgZ5kqlJRAdUelYYtBKZ57bOP7s8tnySXEclE+urC2f2Fhd+wGZ2+MpDHgAXAMjAk3ujbDsVcKg
2e/5wxNm21/H6aM5/ei9dwe3P3n48e3B5/+UjJCErkDCBKB8ITib8CTCRTlBeFMZL4Iu6DHLvEPI
b2QxLkFrTimJ9F5pfikWPwYDTC7FJVw5r4glxY1yU6PdJQJNMSUTWyo3N6ydSjiLJ69GFSF5Glic
nOE2j7YMelQI9lK+wZ1RBgAsuQ4YAQ72FtOIAl/KZAvN4KLfzciMsohKveteOjpfnp+F4DevVRNf
cvKLcQWK87Vui6/hF3VlD1c4v4xTDeMOo3giXWmxV96F+jiAiDQaUJC5LbmLh6fjxoCLR5f/kVT3
jvkCZ5cbgiYfpV65eW3/zx/cv/fbBzdfZFXLtSvRomdC4F8C13CxqZkiLKkGbVI7S3rcU13ugzJT
nL3yhV2et72CIK+FrX+gfva7TSwvgRu3Gr3tfgXY7Um5lRqB/Dopyd6kdDyZjKqdpHh3qtbrNIxq
xe+CVrUQ6IJw6AuIqE3u4t89I4G2JJGxIZFe8qJHOXg/r0eO/UWHmgtS5LY+qhK48ADHQgi12C+k
FhTm1a2QwUPsD99rmRDcFczeQtHm3UzTa1Vq3iKXxFwQmani9KzzpAN/BCmouHEXPWpLgcy9GaxP
EV6+pwczfmMp3rOhq5UmzNn/9XsQ5SMhSpQWkKFLbv18/81PYgvTOGkyOMQNwCinQdaxdlROyfix
NKGivkzaTA8kSRfnx4t28MgFgM5dOjHSGiQTOj5G9N8TzjrmNhN8E/AVNR+QNIiPgtODGvdtCGoS
socPTky0VRzRFAifV2lX6fwCnbxX7RXGS7ICZrZYqklpmSvwCOdpQfb0RCzsuilzsbQ6mumL5kz3
74Rh1DPKoFQZn2QbRiMHJsgD/vjaiVMr31s2UzdifbFMjKoJ2DwsMSypgxpRsChVwd8tShSTF0dh
D2OSlpD2aBcF00YOTfqt+mkOxgJId/g67Q71deKI5DyfyvDEUaqh5V3Cq/BrvljEiwFnpOEextIN
oZOIhTt4UnYQ17IVcygerkKQSDb8m1jsCMEocXrvZxs9wDxeY6LrHD+34pCbESEQ3b/zB97+eEaJ
7T8mnpKpgFVQUEM66uZPwYgdrwJzs6gD6k8GYo/38kQ2XdzZo4dEDouEWdIYHOBt4sOFDPa82P0L
CylOx/QEeUREz2XSuzusbOxM4r9px1Iip2IUeRzjdk1rPglRdE6pV7jdRXH0I4Vg4mj2t9Jv15p+
RDphY7f8VkUcYObbQslGWAPSqBrBUdvSxqaIBSy0qqOG/SA09igZmYY9lU31L4FTbg9fSQ3AflbZ
OT1nDgl8Cyp/txTdxmPA7f5QDhD1M9l2ONtpTFD8SimlvKKhYIEYsyXJVGKCILqTPkZGJ3nQ9T5S
BcR+BP1uFe2ikA6SWJNLzJrUDD7AqoonS3c16OzwqGRkhTWV7GV0Fg6Jk4ptSKYUTuFCUuZdysp7
TvoKoDdVt8XEZfD4zibDr03uAp8Y1SYGbQMeXTVOawMpIImEAr7qO38itbDZtmQ2T+ZsLEl/H1P/
Y1NGfL36v2JxbnYuHv+1MDdzqP/7Oj7FwtTRwtQEGtrLKBU70zPT09Ozs/Nz4iSbmZs+Ol9dWDha
rc7OHJ2dOjpdPFafnq0VZ7z52fqMV5yam6oeLc7P+fVi3S8uHKvWvXrx2IxXn68frctqQYzmaueK
RadSrXiiZs+v1I9WK9WpqZp3rDKzMDs9NXXUm5+fmzt2zKvOH1uoe8X5SnVuQbzCqx6tVWtzs8Va
5ag3QfFXRnNnZkRza8X5+kLtaL1a948VK9UFf26uWj06M+tN18V/xeq0X/Tqx3zxturM3LGpqbro
1OyUV5ubF5cqdVWv1t6ZuVlHdGWqODs1Xzvmz4lH6rU5f+ro7MzU1Ky4U5mpznnTxbn5iif+ztYX
5qtT/vx8zTs671dmpucW/On/zJaCfptZ/q8wA8zw/T8r9no8/rM4M3sY//l16f83MArpIuTH6Gkh
NkdCJW93IWu2T0GigicKGJhtOwh9jEISjCbp/VG9zyBhmoY/li+UrwqGux2MkxwmlgnmAJGkXT/F
ctDzeo8VUfoPDbYiyAw3ZF2VP81oatUgijGKqpcmNwi4OH7iu0LQRcU+5TDxOj130dl1txooGfZa
/UuolKxV9AhDI9qQQ6XcPRI73W6nZa2iXesGjVq+FwTN0KhMPuh1zj/eg6Cb7De9xMPyftULqWZZ
lVRoRnWawZTyQXCwxAf1V+5Jk0sZHDopBSEENgBDS+kCS0+9UDD/Zv5mcTP/VAl+UE7CwlP50lPZ
vxHsFmE92KrBrIPzs3tKXdWGJOItsVYiFpCEYr42Qq61586VHmgI6eRfqooHQNDXwRMx0CjK4CzE
VsjqGTqA+LIj9ynvT/4Fnpqiqho6h0LiBa/JFQZ11DoJCVA+OclLlHJFowqqAGk52/5FcHMPIZtm
mzIKgx9h2/cFOSB1U71GWVRQXtAsPWjpWC2vnVw9e/oHzg/pl7LUWLxwdFyrei2GakVJPXlkyIVR
u79+KmvGs05YEfvAdRxR+uo1ZWloiUEtN+plsc97O7pRx2gbKmuxbMYwoDwjRups0HsG4m1i3ijK
C4WLsqnF4vwDXYMrBSSIKnQMfxWWz65uLJ85t/GDnMMXlp9fWd+wuqNQl1iTq3UF7ZkHVkaj8DaW
MhpLjqeMxqZYdNEsy9BtTR0t8cXFCSW2S5kAmHuZ8w3wNyNV7ZM59oaWESaGnyyeb31/Eq9RuLpz
vh1clGarb3N200a7DuAGgI4Tbjc65GzjAX0/77fl+9FsCCFjeNrJpOYAnwDOqki4NfQ15Xvn1jrn
t/J/3/dJO5j/PmkNl765W6ssriPuYZ7+7EnU6gmV50ZVj0TdWj3c0bSXf99v+L0hFSGRt1YEd2RG
G6yKBPAhdRF5tlaGt3Lgwxv2XPmsrirSC1e6/kVVmJyknaccmmY3P+UarsqGUz3XslksGV71pwQR
gkrRob7RA7RZyPxVCYJeCOF6nciqD2fTJB9gEctTsNo9oQnmaqNQbNUIHBXsTQwDMs2OG3lPjkDk
tmJanT5RPn769JJ7QqI8yMnB4FNeGDCtZhICu8l2eLy3bSis9Uyp6Ac7prc5LkaD5ZqR7ESOOYfH
bj1kGRXMmPR5EBMkUZ8n3exmnrLIol4NYQCCi5h/xbRaxzzetOoMVZG5J3AMTFBz9FtzVX53I/2V
OGvhMcF8d/X4sx2/V3Dtcfhm2GAcbXz43LjtQJK0UHRcHF6u2W+YLrapD7H/DwfNjzdJArwOQT7D
VDASBtZVw5DEfLBGHGqPE4IHInfnkZuBlSRWZD6qU1+H7OGB6GDg7K9UjkDr2aSkO7BQOJA4RrsM
zXCptpXmGPP8yWfJSwXjptEtBGo1jr1d4i/8MGhe4HdQYyZZ5xi6uD4pjkP0DWrIwVuzOhpK5Doj
/XhkKAS0HRB2Wx0Om4NgF3VAriAeW52oIWduJ46TY/8lDJngCfGwrAdNsTrAeeh8SDkNKEsf+vDI
o9FgoDiJGlRaaMIkZbIWlW+vsF5eWRdMYgZTn4U9hNvOUnZnugARaN9YgvbDVaxP9LxFkcTykgzN
j4Z0NDY/jk4akyTzWzco/gLqjsxw5OjKt5Op48UDfK/QCRIp8ciNBGcwPi7SORmh6nvlmn8B+iUH
An6K7iKfp6AIYHPL1cBjkk0NPE4EcNaBdcYOSt8iMYBNEml7Aa6crODqtAZFPxrtIPoBsxb9wvAy
+WOrUStNJNI/6TOv1WFpuxxKcS5CJEYoBGq/Rm0FphQ59GzMdTxh/I06K+vZlK8FREutI2CMLbfD
UjaOvt3qSC5Wg82jOrMKyh0Tbb/QToauUQU6n5uUFOyUVCZCXQO3zA7bZGCrl8sQqVcuZ4DVkYjJ
2gDC5UIchSmisREwQFiAHrnmg+z6t6s8zRadKUhGwocISOh7OeVOB7/2jDQZ8uWwMMOdFlCOkWYd
l6w5D299CODYP7/94E8QHfrop5/vv/qBgTGd2gnTmmK0w25akrkeVTH7ljTI1drysyPJlYY5rd/F
ZAL/1SkGxenpccyb+oBAKNHLl/ffefnh5Sv7V9/cf/fHj35xc/DpPw7u3HmcwcGZ9i4gNKmWQiUa
CRDvyphRAVd3o7215PZ79fxRN7bd8BEhyGF0VAbrtBTgBYW3CcH5b2FEG9WW39sOampZxyoy+MAM
ispR7AYWyWH2Cxzm3k6HL9JRLNcuBEWGLGdjHlcssxl5UWLykmTUCjl0xl9IdaudkNUakF6cN4os
PHIryBw4Lw6u/lFfBY8z1QgC57UazR2S65Bd4iFQ3SgBOW0lN4gYdXpW6imUAjPZX6w8h4GNdvMv
SOOCQbc8hi4vNIZaxiH5rk1qQsmAbMO3ZcdxE6i7ESaONpaKJS7sUv2QEAxyYD787Pb9ex8Nrl0Z
XH3r4Xu/t4ymYACo1eiwEfZb2pDyVKcMaNevBt0auERBMfJrk9XZYbyjgZIv0wZLFCBtZqHebzZb
Xg8kZC42lgeFfWTYzYyGgyzY5Fg9eP2adJtPEFvmYV01FvEkzIJDlCRgUxYujegzPsW75rH7Q/1g
hj9JB6HtxP65FCoLDQXhLeLGeUHirdS0nPFm09bnmrMjZg2f2JSlSymuHUM67JwgnPETcMjETg77
nMm+R91M76LpDciNVQ+WsvGwungB7n16ngxJ3/lFPEyccMEQdnBqXrhULNJKE6wrMz+OQrsER8de
uJmfXkTanpGrLad1Nt1DJUnZtOkk94v4dOr2ieSk8jOl7F93Vh/8/ieDuzcevH0LgLlfv0Z+JfYp
VqaElZPDZrmBkmFvh2UY0XT9wdIYC1/WwMcAjA+EgMvL6G88LQ8CPLDb8dO57XzHKRKpR92zfPSv
O3Y4avu/fkmcsUlKxnL0c4DsMB450584CE0zhiJaZuf9nQTXQjMi7pQgOQ+NkPhFyg/Ba6JRTfzJ
fgnCr3VDHoZWjJa4FK1tEBAb1+FychlSae4VglOg1izONkGpEdQSy/x1O3r/zr3kolB8KUwzcsdx
EStiWCWbm52wIyRhKgvln/0MeuOh9+BFxkKKmG/pp13zISUvGThAIxxjxG1BBLrTJ9Jqjh1IMhhW
CqCk26g/OX4HNCAEjTUG7yzFAI40ABV4HVpBLa6uQjKqg0FcNgt5nyCTtZaMOcOp8UlkD0hm6opc
/fptlD4xSWd7K/LLJyEkZp6V0x1UMHFdWbKILGVHdigdQYOrBnlZqZYNLlVl0tR5WqirZCNppNRJ
N4DFrF+cDy0kpeheerx/ZClNHTVy+7D1Q/axMcw4h82A9uzFdz5WbAvdZ6X0UiQl6kJJ6gM0evAY
KYSwfjHVFKnHbD0SUmzcZilrWWH4StzY2kZXcIXAAvO0DwtWMQJWtOhqa+wKhlv5FyHlOoUKkiKQ
lRO6s6eOIJ2oNBE9g+xXItoCmS3L06Yq1r+4aBfXI1FG1w+ygjVbwtSakel5Im1kY1otDKUfa+8R
zxYnuuJiu7qtWNGkmh7BRYnd0/sZH2xZT3bYJoklqkay1KxJz2BYtqjKXxQd7sWVkrqmHq/wfPgy
Fldq9w07xJ6Gu0ExP3hDvsl40GiKfJtUdH05QgBBNzxAQ1R4xtpX5dUaSZTVxs0ISLLxlVHHYh0F
8pjCbnOlRIqgHF9QQbp2FlKycruRcIAhdxn5E0JumYdfdLSX7KU58KvGSrlRn8t0v3pWR8qnbdrI
RLtjLDpo8zWTQU7pHhvtoGTvPRj4eRYlSog23pvyS2lxVEOk7BpRhjhFS6EzUhcgGcn08jGaotqv
L9a0qba/cFc2e1E2WlGGvdEnxigaJg1yYFiLUzJGH+ekDAijncVIOiNDix2RnA+SMtdhO03QfDMm
iOqod46JqYpvRgbCtFYnLTJRScPfAL2+8M4BqfLj0LiDALWOP0BjAbgmIIvsNittxRryJS5bkPgW
E3ioKAEuxsA6x0zXJiMWIwluMd2iHENSZFaCFqTS8ozYQRz83wp0TrtLli7eKARFiV4EeNnOIirc
R0TL4+PehA9kHES3Fniha/UscsN+LeCUCeYNfIbPbypVUmB7xGBKtS7BHgkiQu2WOmDTjoGeI6PV
6bJOTZWC2nObgpzYYZ1hl08fyOomJGFM/hgZH3R1uCn+M/sf4RPGc6rIFiQzGSOqQ7oUYbMX+xLP
cix9P/WAQqwcDlkHjC0C5Xvlo/3LP2JLyo9+M3j/OgSQ3XoPsBQgtx2j5gO29tU3CVsk8rJ18vnz
vt8hN2arrg1ba4ulxX5KSMFkJhi6bz6I7sccfzu4fgdD6xlYc//NDwe/+aWanv/49J8RRfB/X/4R
g2txhdlEA1McGCNfOnBfVOk62JXYubjtg3uVA+I0km7lI+lDh0KIbQeNDjkbiwlBybdgqX4FUW9h
BfuXOsilbfvqNb0AZMUGBPFC5ncpH3oQaLxxBJqDzGUXqihYMiPqAIhMEwRRhB7JmG2gNoDIyuNT
SjITKS6Yo14i3TLHrd30yxxVO/tq1jBj5zjVx1w1R9UvXfFGDpDtoLK5dqotE/fvtFc80l/S6g8J
TlZPry1/v3x2tXz8uY3VteUzq99bXnKn3OS6H+K7NkR7qGyBuP0g6fUtQRduiq0/uHH7/he3BPm4
f++D+3deefTGLx7evh0jH+m0w7n/xbsPfvaLwZX/AbiAH38wuPKxSU7ETPPpF1MVyZPQdoo26uWg
29gCdodhS2LWQD744syi5j0e4640KVZJgfKwSiIg6RoBUPXLt0dVI0nDBAc8ADdf3X/3g/23/33/
+m/Ax+HNl4iaEShfwpVGQehKvV40AEMMq3poBQ+foNMBwOt6kqTU0KxbcI6jn5tfk2KYFoYBvsXb
YtS5Nq9NbnCd7Z2wAYgXEjBbhmE02vJtIYA31vpV8kKWGdnY9ZipJKt7ziVNwjHAqZgprFBAG4VU
HIt3GQYyWZXDmgMKK4ccWyYSwDD4rQNaiRPwW6T00RcqPRtj9urSN8M0rJusX7p9nQfQthJibily
UTOiS+SJ+Y0l/YblMNZWLlvEb7z24I1fDW78fHDtTYTxjIK+batY5u9ttPuGL2K75nVrjvF2+UfC
ACjwsiEaEP3xBIvBbkz4qngyjFWI8KO5EVuiHbRVm9TqhoUE1aAPPfra9rsRcGCsvmjThIKRFie5
YEl6CHDf9QuU+5t2WVSw4jeD9hYmCIN0GxibMUZqDSFRIADGcPVrYqptApsdP3oNchG36Fd26PsT
hm1yQaPbw5aWvrw+++ng5eu0jNgehczsg/duPbz1/v6f36e1BTvus+sPPrsFKcDkikxbcNZFN/rE
mDC5Wsu6sYRTcf+yY5ZTxQ3qwKpfVAbxkB9Y72t6NtgdOCxjIN+Ti2u1rCeRptFMcYyY0J0blGYv
QcXVnQN7Ljy2B4IFxVizlytxiYg9eRpGhF1TcprkU16Nnfhm3brjwsd/ocNfX8gmJ2RyI/oYkl4d
6KFmgNb1odmES3qachWymqUqThElzaJttUlrQzr68Dd/3H/7i6F9TfZ3DMPFODp4pv9WrT46T+oK
eX0iRywwXeduGw6iZ6YrBmUkwrEZY/ot6j7VC8UEfsnFQaxhIHFiSd3nkMe3YJv6kJ+yXwn9v+/D
6HDyWzVCeKgZOhD08xf0JmqPtAsl7Cwp44ou6ZElA3+aGXCRpPHlIQYaLGKMk4UiK0vHqAIGeUeB
M+E6N5S8qjGbdGKkyUJwjTPBUKXrJwPjV46lNx8nk2fEN6Xqcc0dmjHymHwjymNCcHeRHvIbyVRK
7DDOXQedbilO3WOJl6LSoOrVHQUTDOrdP96/91mMQSV/HlaKpdJZY5xiIzsq3RWPWnSwpLeQUlo+
Vgt164ktdYuukoAlU1NZei00FW0lidysdqcmjOgaVyseTVZUQ8kqVlCCPuWEpCf+JKR7nUBKnebg
xivOLtS8N5Jk8nhI/WOkCpMIlTxISvHnVZEGMs53iIIxUkPIUAmScL3RboTbjleHiyAUyARyGHTP
Qm0Cvk/pczDE2MzrGgejrjYbMdzlA6gi4CrDd8AN/mrXdGj2KvTZks/990bnGfUQwruRa8XiRNx2
XHExgpySMEiUEsiD80Ib/s0Y2bP4pZldzsNS6GCgOONEitEug3qKr5bLUEG5DD/3RE/wHOpJdD48
ItDiYHFwgfUvy4lljIimRn1Z9L/CICiQMMFTkyir8ShG+pvPQWkqKYm0mFzyvc05oOQqo5Irmjg9
IkbBRcdjJ9efO7mKtFq8QMIiUGosF1WTgvAMzZcLegrQpiHfKrGS0f15/RQnyOUEyqRLf+2z+/fe
j3bOE2KJdyBZdtAPURpGiLSaBovT8nYcr4mpNQQBAjwNwRg0/S2vuoNgGYUk8UQIBcHIJ2KwQGw5
L2YggmEYE2lCnqpUDeJd2obeEoGPaxteG0t3pCFxwD8xLI44WRnv7aZackRpTl/UbAyV7miz0DYK
+ugUY9IK8b9UO5GOb0nGzUkXcTo6vLAclZDaJcN7hmu5EJz3SStDWcPpSjlyokK1MpayHXL7r7//
6I3Lzi4X2XP2331PLktYkvuvXt1/98fRApTHCq+ZaMnIoxeXjF40LCOxNQzpjbpRkSX0LaFHSdYm
3xj2gk4ZVDE1mXIpNMbyK8i+xeMnk2VdAfjEt34H3u0yXc79T//54e13E4m40ntjxLADZdGXAPog
43qC+Npo0CNyTBGSWTWScZ7LffjFL/Z/fpuQ3ONBe9R0dMwffPgind+g8b57U1fsRHbWG6/E0vga
Qne84dCZaCMliETCqh4vENPDmrALkdqV6DPrIhIhTbrOxlTWSkeb1PYnX6J7OmQTHTKkAPNdhotE
diJujs4kJjQXp8XR2zIGsHU21YnY3G9yxUX1GBtxRCWwBDW0lGbDlNpQ2IozrkDx0tlryLUaT8go
OO39qzdV9AhsIlFJlO9II4Yj2mvG51gk0JgIqZMNCfmbNm7Jo537AQyyVBzQKS62h9hjgkEGo/g7
1wevvMdG/ZuvAst84/bgxet06t+/c3n/T+8N3vn9g7tf6BwA0ZhHP3oLJBItYx+RmWj70V6XA8rm
eDYGiiL/T+D/XWz8g9etfYXgj6PxXxfmZoom/mNxYX76EP/x68J//N65dUkObr42uP0pppK/+uCP
tx9+/tPBlQ8Gr18bvPPh4N3Lg3t3H966BWtbT/HU63UKgmCA1y5fanS8Wq2r4Snq+I0HyODU7zYB
iKMLSrawF4FL6jKRlKxk1I2QwKEo8pr9ENICl7kxGf7L9IhFLiA68g5QrX477PhVdJtHVUt0pxkE
HYSgNy+3+s1eo+qFPVu4uP64oIVlyoNg3gDfhy4aI6nVWEY22ldsmtVBDToL55GbFGDZB2u8VEJR
RZhEOT2NUIRGJTMKTX/5hEJR/t/RaEJcVg1P5G1Gcdg+YhraEJyG8rtcHwgQHTU3HbV0sN4Ef2tT
aFkta40RazHWiijPrCymr1hVSELj9SvNRrXsb8FV9YKuvwXZUN2tZlDxmnJ91IQUFYrlCkkXZVad
1k6jI/oq/mn7vckI+qMBmS8pJwnm7tDT8MzPwhP1nULQ3XLV6EMaIOCrMvI1ObMSQs/ChqH5utpm
jLSMUSynmpkdNmUou5okoiB+ovSM2VvkCp3hRAVhR8gqFh+fSlDbIVQqLEDajeni7NFsErnQBMeA
J7ObLnCbbmnTbXRcdDXFdEhL0WBjH6FsMsWbhn015lLEZmQt4VSSntCMExToOIvOQKXpmktupDAn
NeE5Z2OnIy9qR0Lh1MbGuWWsQcxtdsg+MTFuMMKyvwW+Q0jRM2G4LfuRc2KLO+fQ4tejsMBCHT1i
Gw3tNmm39CvaQFI+PTMtOeGEW6gujKBesSCnbO8C8Z74RzdBwRIkX20p2f6Gtu8NtXSivVagK31i
c5A79U/779wdXPnTg89eo6PdZSKO2xB2O40ouggNoS+Kd5dPJgZE3oC3/vby/v/8yeDqh2BJpne/
dHdw47eCKSen2oef/Wlw47X9tz5S3kXuY8zlY80JNOnFK7HhiIbXD621qrsAPhmNa6IibW2LUqJ3
g/f+OHjxF84Zr+oMPvk36PEXv9x/9QNoxa9+Nbh5ff/qm87KOVfpzDrNnQwouxo4kuJcbSkXKUIf
pkvg7+vYUuuIs2QJNKbxFDsyezxXjaSviRn1dJ4DrsQlseXVZwx3cZC+bry5/9HVhKsXpZxkQkcd
8sLzZTxStU41vYoPpN+ve+LkzimGjrsZ9uv1xiVMB+ds7nKpvRI67vMvI46cXPNp+AmfDXod9UJS
8/jYYjPEOPL7YED/1+W77ugM9Srsm2oGzREsEW5bdkQ7s0OYixStGE08vANvZhPTLkcb1j7SUDo6
pOvj04D6DslKAXESjDDiVEafbsjggqnF2mINXpg3kpOJ8xQcujkFrDQhKWM7ovfqsJabHD5Bd8At
nK6X+Lq7iGZivJ2cHPy7ObWYnypNWIZa75XWV5AHjL6qljVCPHgzepsaYa2xhelQ4RoYPOhRgFSY
w2tT8BXGOroxPzc3M5cgCVGZiVRrBIlUok5BB6ka5/4nP3n01r9Lq4QQuwRN1DPkVbcDwKyO1iim
kVpyH7z6IUQB4PaDFGGCt4Bt/vDjf3v4xUuu2kpLUzwMB9kGYpeJNu7im/ZEuWlnl+oXP7TtR3vD
yL6p0Y3YrOrZV3knLOkwW3KaSDc3BaII2rt2AFRrNDSt+fg0An4S6udYAKqc2kyfIqDC0+S2vX/t
5cHbv3z42b88euklsFHf+/nDW+8/uvzyo/c+gamy7L3/cvg5/Bx+Dj+Hn8PP4efwc/g5/Bx+Dj+H
n8PP4efwc/g5/Bx+Dj+Hn8PP4efwc/g5/Bx+Dj+Hn8PP1/j5P8iy3gcAgAIA

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
