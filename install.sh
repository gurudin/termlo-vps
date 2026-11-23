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
            # The optional private file receives diagnostics for this endpoint only.
            # Only stdout supplies host keys.
            result=$(ssh-keyscan -T 3 -p "$port" -t ed25519,ecdsa,rsa "$address" 2>"${2:-/dev/null}") || continue
            found=0
            while read -r server kind data comment; do
                # Some ssh-keyscan releases emit the peer banner as a stdout comment.
                if [ "$server" = '#' ]; then
                    if [ -n "${2:-}" ]; then printf '# %s %s\n' "$kind" "$data" >> "$2"; fi
                    continue
                fi
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

prepare_sshd() (
    # A daemon started directly by this installer should use the system time zone.
    unset TZ
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
)

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
H4sIAAAAAAAC/+y9e3cT17kw3r/1KYbBVBJY8gVCUhP11AGn4VduC0jbU/DRGktjW7UsqRoJcIy7
SFMSSLglzY2ENCGBJM0FaJoGgiFZ6/0op5Zs/5Wv8Hsue+/Ze8+MbGib96z3hHMaS6M9+/rs536Z
qNdbQavpNfLB9I/+Tf8G4d/2bdvoL/yz/w4/un2r/MzPhwa3Dm//kTP4o+/hXztoeU0Y/kf/O/9t
3DAwUakNBNOpwG85Ob+dCurtZskvlivNQl9m564Do4efKjilspPLOW5fBh7XvFmfvw26Wdf58Y+d
xvFyNpWHB+G7A4251nS9lmu2a63KrA/Q5UZaNP2m/7t2Jai0/CCuQbleatWb9EswF7T8WZhQm0cP
nOGfDpT9YwO1drWadU6edESLdDpV8gLf6ePvTqXm7PKaxyu1rEMrcQfqjdbAdH3Wn2j6x3HtIwPt
oDlQrZe8Kn3tw3aus2OHs1m+Q4+4XUBv4H+piR94pZR/olFvtmTbp/bvHRvIa/3xg1pjNjdVrU8Y
o4i5zg+N5BZgqikH/uWmT+Zy0361kaWv+K/RrNRak056U3C0lnbSwTS0BbCtVmFvnCO5XGnaL82M
46fpetByOldudd45Rd9pYp2bX3euvb786c3OxQ9Uq9yMP+cs3VnsXrnbOf3Z6ivX6Rfa3c6l88sf
3RpPO0fVDPBf2jH+QevjldZ0rlT12mXfOenw93q7pT8K5mqlXL1WnRuPTLxdE1+wqxnfb+Ra9Xo1
GE+rUf0TlZYzCPtMT1R72B/1OdykYLoy2VLfYMP8JkAY/BegZrJSKxcZIglY5h2/NF130p3zd1bu
31+9cmrlw2edA/S7szX/mNM983r37S9XP31z+eyZ7pXP/nHqDys3b698e2nl6jnHXITYfKf77vXl
Ky9BW9jP5bf+KDvr3Di78sHpzsv3lxavQS9p56c/Ht7B6xra4SxoK/VLAPzarF0n94R5HeDhbLWe
b8y52ta5fT9DQEwRIAalptcqTcOCZ2cA+BtOrsx3QzyHy1GZdI44uRr2zA9dZ3yH05r2aw5SASfd
nHVyzUm+37JJ2hn79e7DO5zJSopm6JValWN+YZB7c/s2uk4Bzkl2pLcZord46kW+0MaqXEQqJa9l
LnW23fKmfMAeftWHGxLkWydaiGsG/FZpoB7I5/oqxObxsC7tS2oSBvOaU065TtOEj66zoaDObBz3
hmFsB7Sp+QnrocN5nNBNqzUXbsOa4CWB4PYXS3fOdy7eXH714+/unQNQWn3hfPf1WwxQOoh0PziF
gHThZuf95+LAZQ0ImVDEHIFE2xwdWlIG/tdf+b9E/weHt0bp/9bhH+j/9/HPdd2ddSDRtbaPwO5M
tGvlql+WEOPDBZoEWHMqrcA5sP/Q7l8DMfInq5Wp6Zbj1cqOoO8OcA/tRh56S1VmiegA/U2lJpv1
WYcvvyOez3pA51L434zqiZgNeCEPN/RYvlFvZIay2dSPfvj37/8XYdO+//s/NLj9Uev+D20dfPSH
+/99/NNIVybrzBNDgmRTozPIQxObwc22yr/5oW3hR+3pcPhxKPw4qD7+RH16DMmu4oFK9dlZRCm5
YzYnFLL6wPb/eAhJbEkgrZDhY9KdSewli0SdeHgUeORaxlF+oRelZEHtWGaQHIDBBqsuTpTqZT8X
ACtSAsmpsa5ZAusgP9q0fPcTTq7kpCX6DKr9iEP7nWeqlYkd+DGPfEAGPxzzm0GlXitWapN153En
s7XfeSybTa9rBqYsYU5CNYKv7WbNGaQHxBlpT4dSCz/g5v9n8L8lhH///N/WrVsfsfm/oeGhbT/g
/+9F/yO4OlQ4AFYB6dZrAvs3MUfcoOIC+4kBbPpemYR5hwSogDhAvV3Z2blndz417QVITEyMPhTB
4yjRpNrAcbbaRSHRwWsZFFCb/AJh5zx/Fnh6fveukdwC4mh+E3F0NpVqNmaLMBZIjU3sQ9ExVCkg
ASvXJp259qwzWyk16/DFoDxAO9w+bAloOCeQa3SyJAva6JPe2qEQ5g6J4aNIEyZZBUx8IjJNFslx
xagHskTcBTdChPJJLUNKSrKxI/aK/hb37P7FGH5xpZ5J/tvsOmV/ouIBkd98Er6IbXU3Z1mK9Rot
tT6hidFe9aqNSs3XW8/0aD3pl+tNTwzUBJgTH0t+rVUPxBePtkl+mX2mFvYOpxzXOyk/NPIKOwog
iDPPTfktJIP4tdyYmZISvVgYtfaroj3CiGiLoCI+hhATvgrzMF+lZetdz4jf4SAkBBBsABR4QbEJ
UrdityTnUoGL0s6aqgcS2I2Rgna5Ln7EjzEtynUvEC3wo94CZkPzc7ufX+v+6fzS/Sus+1q+cXX5
0vOdl9/svvPc6uVLQt914y/h87MfrVw9t3T/T90PTi3d+bxz5o3OC6jnUpotl1UVxlrhdsMeFxFr
zBE+0A8FrrP82OPOQReAobzSDNwYBxm0AJGK77BgqWOodABDngAMVK0ELcZMJa9Wq7eIBQJxk7FR
kKc5ec3SdOWYX5xq1tsNdROhq5Zf6INxQ2Xi7icPFfpTJuc0gDMXXQQDEhXQ26h22eziMW90nqi3
pmmShC1xXjbC9Fq46nZAsjf8twxtmpWJNj7OBZWpGqyH9Tswbxiu5hXFVzVnHVkCxCp0IzHFEJ99
0K7g0uZ/OXbw0O79+4o79+8a2ze6F1EC/Y6rKfQNpxT66KM3EHWm0yePbPByz4zDhaQPg7mf5Mbh
SsqxlCI8fBm709+FV9b3+myl2aw3C9OtViMYGRjgr0G+Bdx5vhVUalPTbS/vl9v5Uk0bTiA6DbMx
SssaCEicWKGPex3gNnDYfqndrLTmrB9y8rnRCUBRA3B7rRUUUImxw5nx5wAwpgpsHkDyOSAeBbIj
MXBOPM9PNaZ09MUY15yruY3ebHn7tpOVrY9tz0ZWIfA12yvifyQzQGDss9Kaq7WLV3foK0zjEuGg
ECpLLQDGdq2Cd9V3ZtvVFn9MG/312g0xmTV2w4SMlIHf6w28GUHBZXCl7eFrkpuAJYgeXeO6whk4
RzYF486mgP+fb6voyiW9ME2INKYI9Pgh3ARXM4P0fC3XbpQBAwTrfF3ufPi+/kTrAJFJyQMcUi4C
3lEXX5I0xKTycw4Xa2MB3qsMtc3laFv4DFoguLabfjbyhkDH4qXc79p+c87J/crJTRbSgEL414U0
IvCIHU6+m04rHgwnBWA0cMxrDtBCEH8OKPyJ+HhzHhoZPBngNeTK4LHAbBFJloimWnXYWpALoqQ4
w1DEj2k8qm8EvsHnmjxm7hloIhYpWiX1LTZKdGu+s6Zcjj3sWEsQJzJz0C/Vj6GiFtYKXLpfnQzJ
o05QgEJ6bWQLWpWSh5e5IehqpVb2TyCF2egcnq4Ai9GqAAE+Xm8Ch38c2YgJJGTYPZIvSbWnvWO+
M+H7iB9mYQJlHtVzfnngUD7FfUYhFt8mGNDBVn72js9EYBF2/ATrXKqVCQYc6ILFFd5K5ivg6lRl
P4B3hh/ZHrSBWVyIIYoW47weOmLTJXic55/y9eaUwPMxOF302+vyWejdGkjckjz3lwe0YCJ8qzkh
+mhjkwCsF9tudPajrOeVSj6evSOtbg0PwQFAoVyZAtIQQluAGjTEXFW/5SvwAk6n9oyXZ/LutzxA
kh6glhAScnVnV6U5MrITv42MwFbR84L9Q9Ashb8F0/XjNgJyTqp1ISiB2HnwECAiJz1v0KjJStUv
uC5yeR78NX8DfJWpFIZ2VB7f9+SOypYtkkvX/wGjnemrFAruk9ATcqUjbpZ7BS5+y1A2+YVDT40C
ZGJzHDum9ULKfg/7dX7vDPxXA0TNowNIkY8OeEfxGtB/ikeOjHjVWnt2ZDy/ZWTT74u58S1HETj7
BvA+wASnWtMZGC5bKGzfho/gM3V4xMtNjuaeRN5sS99A3EIJXmll/fASWyITpruQzsr7imKLPOg4
thQFAuRaJ8XuSTh6/PG9Y4dHU+rdFH3VRCTLLqsx5Bph5xuBNFT2j595CIVRQzkdnkbs5cZso2Zx
fEfYxDUBvgeWsgT4pHbl+vFate6Vc3TkciUD5jpgbHwnTxRGwpNcXmTyKPKFagFEkbnfTe4hTFRv
1Z00I460fAAosVxp6o+hN6D9w3gVI4PHTNAen64iIDqvCpus0LLzuN1ZVql3uPWmTc7mBaabcmlR
OBJHKORppiS5it01idwkhhKZnCuCGGUI3xvEm701P0nOOCAoL7/6cefSOXYVcXYRKRh4mpE0iMjd
117uXvySbfrdc39YuX+/c+Hd5b8tLi+++929c52vv+pcfL3zzRudc1+vnj7f/fNX3T//ER1IcE7/
OPUsYrjOxReXvnln5e+vo8B9483u6187uDKU0l+6rjoTfV/52BmYrbWw6ysfd1/9Zvn+jZVvLy/d
fbtz7jS8v/z2jc7915YWryvRfuXup0uL94Vzi9gJ3M8CdoP7mR/YLIZL2waCoVDzgBNdv/IMWzO7
jAfP36WTQm6O4E5+RTxHF3vIDcVZOWSlhY5GDzQuv2INzg/DQWEOyePCZhTQaUWy5NnIMAoUNwWu
1gmBo+pGo4Uat5S1wE0iS7y7iLiTkeTDoCIdoBGML74MUACQvPzl+517ry3d+RwB+L2rq5+c65y6
1332/c6189/deytTNlEm7OL6cNom1EaVQxQi0Bc8poPQbnCIGXj/YPkkKE172mlEMJy+nM7Fm0uL
F9SKVu7D16+6dy/xKgCau2df6rz4sQD8mCWVyjgRUjwz5pzcs9/hqbISDT7Dd0B6IcOJJrycuZhN
QewS5uHrxo2bBxZcCR3hE9tcqFR70mqJPpfiY84wG8KupXWOKB53wczV68a7IPwXcOOJ4coAKJby
fFH4c73h1/BTo1A6ctTFC+KO4/Ni2W/QdcgHPiJacYsyjXwRNqHfOdxsI6M76TTylaAYGgtIIdnI
z3rNGfmUB0JVXQWQdPpozb58tA0zID7RJtAHkEYAY1X9IGIA/fGPY6RFS5wtT4wcanmtdpDjP1G5
FgnPCElxtXorF05/PJEy8LxyuVq9pnmlOTEoLUqlZS8AvOxOqEAYyAETGSAITCjQs/Puq4ossCvZ
0uJLK19+jFTlhbu0lM4r57pnT61eOaWoCNEPIBFAHzqnry/dObV055Plv9xl4gBXA0jHys3r/FVc
kBCgBT2I1eAay4oQCtYJb3QONOsTvkOGpBYKnLMe6jb9PIifvuOVy00/CEiUceqTJFgcOvSUE8BD
RPFe0xcqVNjYmleF/lC16tfQSuUfQ/9DfmkvSDqAPQEsA5CL4VGz3p4CwQXYzclJvwlysNNoT1Qr
JWff6GEHh8ungpJXKwbBtCGzwndUVuFvMbwsgBOMDugDbTLDwwsaS4iM8DzMvbhz/759YzsP796/
j2xX4wk4vlSt4Kz4T5EvJe8GTQ9w/9i+XQf27953ONVndptSP1gKRPE6CJmsfB3N/Qb4/ZH8JhAT
Np/MbT6ZTidoYgkWUWws9OGfkJ3jLn14Lj7GwDC/pzbHuIXqKd6o4WFm7PgNt48F1eFhN2a89NDw
o/lB+L8hZ2RkKK3zgBudUVSpBIAF1C2b9QC8vCbCJ5y558/WUZPRBrmVIa8Oj/eM7mNAmvRKfr/o
CkRAdOmG/fMA8wet+qwCNj4HCUoAN3lnn4/KFwIOhDoBUuxkndeA4Zl1AoPAcfg68tSCtwh3we1T
n52+jGzm5HbHoKwdusOJ6LgyCRs1WdGVLjFMQdJ46u2cZ45HEne6bwiEXLjKLIqob9tdZ14Ik33D
KCq6cR4x0sIVTJd7T84Elr6M6faD7wO2zh1OnCC+t+aM5B+ABjp0uEI8oOm0RNdMNkin0cZBxo6s
UvFFbhW5JYcXM9xfo+fYS5yTRhTjHvcYiyEa8SqrnhGEm5VjyPsSRwZSkY9aWECK3lQNgKlSCthw
jojZr5UbddwjvDF5q1NSDgWtcr3dcoJ2owFYi8EWjQCB2Rrm366ioK3jUjihreg4xQcJJ9Zy/PLw
I48M/aTfL5UDr78ZeI4CPxeOE27Q8EhOHeqCm43VpfImw00vDBrPjk/zkhnbBn4Tb+5MBTVZwEmT
gRAQb+QUeLmH0O6oT186pzv+LJEXuPs+9Dfh1WqojQXglbsjOs7H6YWOkCkAZ4LoML0xHcujm/w9
0ZVhHXsormGjbuPApZHcQYqYn/4UPg6bOMG0bMVso3VFTcCkrQOoxF0RJ3eSTi6HDDHAKv4Ah5iN
HU8sRNMSJc7AxA54AlN+rcc2mdxYwn6c1PpycmOCiXdy1Ulg4dfjSrfGHkUmoebB4G7NJ75bguKh
2GuN5gBgCX4x9p+HUn18wVL0xdxkt486EaozjYEJ74YyLMRaGJAlmkL2CpAG8kblIuyZYpAYEoZ0
nTnp16Eh/q+ICKEIMIAvnYz+QuCS9BuDFP6atRa1wcn5mosQPdgjH6xDvY3LQqM8r4dJWugGIMNo
hnbIsLK+4R2ENwt9W3mjiJ0oROlOhEGksDrSGtIrrsUeYqdiEXCn8dsmB651DsNxAJ0/HoJhb62U
Gsbowxw19I4BFBjQ9PfsLI7u2VPYyQ6+uRYDu2bSE+gl4t/Ex879EHeZrtUJ+SN2dLxjXqXqTVQp
ThCVxmjnTW8OT3GjcfdGmSMrQXctHz1uArT0O2V/0gOgdipltFm1gLzkgc1DEb3e9FCEm9b6w3A2
r4pX4ni9XS3D56AOLOAMMXF0vu0mu1tglJrTrrUDmqBg8GjaDS/Q6JaE+aAAyyYRQ6cnsIs+iBEc
5RTZyJ8bdtEYTMWkCJ1LFD2qAqcUS3t4r/Fn4jHELjtppPtxdxOhAFtvlC0XSIkRrqcnPgH29Mnd
P0/1qdWlxJNEjQuwAtUy8sDIuDV95spQ8EI2GpjhSgsPV5wBORGIvce5wYEAlfSbzfy/aH82p1Hf
pBiREUeHO/2fOFK4SWjQKog922y9vbAjeZPxvU3AfEosf7QJfGTcZkfGT9r8XbtHf75v/6HDu3cS
TsfbldKfxTAPvAzDMhKl4MjEotUOzfBJ2NnpgZ2dntg59lT4ZOJ3Dudib1OkA0WMYmisKTXgNqie
knfCNrHz/rqkw1/69kbn2nlHIwcOaz+dp2Cxv4BZr9y+2fnmjxgZSj5yqD2Bz6RMVBqa1cU3V25c
099aPX1++f4NQ3ceUYtYC4rEZzKFI78C8XCg4VXQ04UDGd0Est4T0eemk7tbBxGIMRY34Op7TT5n
hctJjChXQMxo1QFlT/gAimQSbiJNIK55D7l7Ig9cKfmMBaoeWuXmefYbN25Op9ILIdlxRXD3AFxZ
aBh3AzVuJE39D+wVRAXJI6AWtEvjdJkkqAmOOAPNdg2BvJw++aBvon+LelsxHoORrbLhUKxzJEc7
xxDDkaCda39d+fK6UAjrPJm+14pvQSWI0HPQBvtlMT1AvxNC1RbG9QXTRCeF86FgdBwK5nsGbl5e
xFwjY3H4N6J/oNTqnikyTbgypNHkGQDzI6EGvgG/AhxA0JJbiKJnKCBK453JDthMlHSRXU+MjuxR
hesP8NIoQhHe9Vvor9Lyq/UpeLte620zlb0pwxCQolln8NFHHgkhJd7qKV6M1020Yt9htrAseqZZ
l8VfxgIkANF3ONQ4rY3cTdkGJHjBhtXqx3H0vLhnOP7arcuyuUb8eZKTPEm0CDSBMNQnW1X/mF8N
p9ks5cS7PeYJjYQhDoR85h8k04fa5bCVnDU1IeBOZkd67XyMkgeDB3zgAeE2sbMSG4aV5zLOxECt
ho0N4UtqwceVIUx/upZx0sgeId8W+SFiAguk//YHaN4l6sPmXyQ6owcOO53b1zunb0uPbDlhbSPQ
IpBoIEKrqtg+00SrP0021AqbAG9ckugQiiHmrNgGu86p2VbcyE+2LfdBpsam3YKaJn+NMfnGTS40
YnJz9wE3RbMFq51eTw/mfkr7ngZzD2s01NYWbzVk71T2tpSmQ36mrIfiKxkQ9wF1yaakd1iBt/cI
mhPdcczAIH4xTIUj4bkkWxvFe5rNMYXIgd+Vv5rGRjEvZW98eABmk9+6NnFN4+CDzILxwcoLn3Re
FPhAWeWYe0BL94svLt250Ln/p85ZgS3Y2wRxhjAQxjmYOGgevIK+LZaFEJ1Lnj/PhsHv7r1lYJrE
UBZOibEeI2Ja9RdGrKQp2GXdb6td+iFmtfc/lWPp3zhGz/jPocGhrUNW/CewV4/+kP/j+4r/VPk8
SAmHOCcgiYD4esRu7YDsQ0GjzmobibqlC1LeGUPHOmfSq1TbTT+10algrGip3ixT/JLjYRdN1AZg
jBaJBBPVemkGA06FRAjMZE0KhNKNmFCrN+VVavkUw2kRNXQUSiZlKBCXV0+9tfLtC+NKuz4kYtGw
LZHtDH9ytjhD2SzGlInOaA6K4dN67F75RO9U4y1Xrl5fvX8JEGT3b685+ohoWVFoCzeCR+ZPPDL6
PoitM30QWX816c1WYP81yRX5DNN3jTCd5bpGzzReZ1OQVnrl8O+Qq6uhmo1ZvedNQXIH8yJcdSRX
rk0uiIVqXXmNGXOSM8TLI3kT7t1mf1uNtzEJW/g6flMz4de2uZY6X7Zlv0umZuzbJTwaL3/MbjDQ
Aetolu5/Cy1Nx8x/nHr24IG9DrwOn0Y5hhWaoifK/kOUeUnfMpLc4fSONystvAFFJfUr2ZvS5Q1p
x4l+tKhtgymzp36skwWrOZU9gxJijVtxMMK0wb/Fyo00+Dz8d9PA5oUdyrCmXsDfB0wDD8mZqg0r
mI7bD06oBygliVvjlUp12MIimo/NGFZawrAKiqFZD8c6OEjjx1w4Fn335lD76sZq78hTV+mz+GU7
acZcwJkyUL+YB0Dym63MIOXRoNRCR4bGs5yTCBtUKxMyKdEB+Cp/IE2Y/EFfbKqFWh5j+fheRvU+
PJ7tR/131Sv5Kp3Rka3jTqHguKjycIEhPUHBFJn9h8bQd7rf+aVXbfvi80HOwkPfsmhB9vHTiJb8
o9XM0DPM9qHtF+0z3S0ULLMJWmAd7SF8Ow6/JvSgUthM0rlK0X+PccobWDEpHphjzhM3uBX5QLKv
hLa6pgKNBQ7hUQ1pcmHD42HDmFXFr4hww9UbKzeudT+/tnSf1Glv3mT2d+XLDzsXb3MuNvRtvXwD
MH339RcAf7A/9dKdu6t/+qZ74ToyuafPdM+d7d453Tn/GmN+ldfvFZm37dzppcXr3ffuoIvs6a+A
P+6+9wIikMhummy7Rs/kxB2elcs+cocpIJic3TAronNYZNFi7EiWMKmAoxwHROMCpuEoRbaAZMOJ
IWGG3pr1NpAMJMATPoboVSYrfjnv7FbaQCMPCG70bOBXUX8320YuoMqqEIwJU7RYhSgqLFD1Jvyq
FT8tKF5QrPl+Gc0ta5M8ivOGbhBTEqUSD4bxAdEb8WArPmASIp5sE8hW68LUvQoJhUdGeCOaY+Mb
nh7Hm6PJLQekLJghixu2L+I3tqLJJ8DEzLarnmVaU2d+AlCWTvtJDZ+Nn5ERsyiob7E+gz8NJfqc
Og6rhJbufNl946ulOy9hLMDXX7HvNvoeMI0EcP3vUx8y10LL05iWij6dyLikPhArCM27shdrViZ0
E1iIVJjdd653715yMCciX1G5zSo9omj3xld842I8ZK1bH9d99433gEOLjMCNODbohKv5pMou4dyL
eJ1iQFosnlwBCLydYWHgxwRQrB/S852I9i674llmf/mSoH+M/1gPSykqpW5bhpeG7TdoSaymKi1u
st6cVFEs+pDEuIEevP88GTZTA6rdL1IqhRTBdsZ6qpHbkfEIGfyZGwlI5qm2azO1+vGaScxQT40E
F5BjPMMhfnSGBrnvtdwxxGBCb8Pu7frwO0x6aimuY+Eab0r37DedM7c41wbytG/9Aa4Hgzjc7pWb
zzLNS6BVwNcqWrXy0QedCy+xjljX4rCOp/vO1TBVbYy9sof5lZaJqIIJxbhKQBJFBJLORWLxtNwT
AtztXDWR7MoD6pqddGMTLYcNskned2LqG3DuyP71dMBr+pi0A10+5uUkN4qR3YXYN+JPdenem8hd
UFoVVMOFS+ZzZaEFQFrZplduXleHA3zKyofPchtdBIITxlMFRHf6jPDbnz2GCrOj7lGeZJ9cwFE3
5mEepHzE62X4tXPpwuoLMCrGA7gJexFhFxk4euXmEUwLodoCipfa95EtffpXZ0Ednk6aFGIFUlme
sEFNcSVyr11qBWi5Wa+UOcW09U2Sd/kUGPgW0nP+OR1qIpOH0Ga11kc9NY5ijhRF1fO6RL0AKB/R
DIqW4gtmTrYlQsppwwHWZp4bM13yz9xsvJ11g+lqgEp99IhwY7iklvPT2JaPP54ePXA4bfS/sVT1
vSbaqEZGniYVxsjIgaaf2107Vp/xd8T/jonK19kgd6hdKvlBoBruOjAzJYcgNjcHD+J/NgYQP+hD
7/In2vBsX30PXGJkuV30znPhh5i4dce1ftDi1uk3YwUk7OX2Atl2XK82hz+XgA9vwk8YhDsycljQ
IPcx+7fA/vHAYTMm4lfArjsiKTtli0KpAbfCdwiDsq0J4x1AMGjXKFiG2DoBNsz81+ot6eGB/nFk
ZRQiRKDi+wJW1AXsCC1SF1H3/WoGUseHWny2/pNYEhTSwsZdqqX1ZAyHxw7u3bO/uHvfocOje/YU
940d/tX+g7/gBA3Q9mQJ429RsyJ6KdWEKTttMOHM4gS6u0vTnwQx2i8nh+KoJhSrHH3RDgBQzWlq
SXPij9mYdceKDXAwLLhhlAC/Y+iGKNVVQb9/OW6WslIeQSPCAAPWz4xLyAVfpWNpoGuOV3WTPRQ2
sO6IRo9nD7V+qVXvTjXcTtNDzF6qJZLhtfLZmBwgRm/qibNI30GO+67K9fJTNU+ZbAu/ucmxBRV7
7lI3Big3VNEKwjSi9U/ckemCb3p+TVpNExzjrfFyORVnSwoA3SxPmlhO0cKfxQ851NBjXALc3dyc
kSI+dsiNdPFRhUD56J/xm3WyajplbxZoWFlLAikNBEihanWFI9jfFqhsBXcnb/gub5lMmc6K3IPl
VxgX1KFlGNKgGJ0zqYuFohtNLmRKP4HKMyROTHjdk27Bm4kETEQcEw0n+yHzyISUGHmPoULNV+pk
elw7dTs2FMhpjPCBSJQwnpCeUrzx03jkpw1lLHLtrEMm/NmpDHvdYuGojvkkiEaOtUpAIenaIdwX
Yi+iTASjNUaMEhRyYXZDmQ1C2oNLsZyJGheDfYGOChQqcFmYqku1EzQ8RKTyk9bXnvpUry7EUP6J
Flw2v8xyrBx0wHospFhLvNRtR1FecaOzjzQcqHsQGcY4TaJ/olRtBzBbwAkkcNscrMqaKC8czSkf
Ri5M6kEMfetQ3sWztapOiWE2QmORZijK5YIKKtGEO1jcPkRsR8Y9RGHmiYNjvyru218cffrw/uLT
B3aNHh4rDDnCsjRZh0F+ixaEY8Nr9o+qx1RMwJLGkidRM0JhM1OJKEfp1/CSyASjPeVOuFGNNmWq
ka1z6MoIp11w2c8IbUAS3mHqLnnic6w7CB8zU65NFxMjp8Q6echey1SKlA36inK/W3tuYYNqfUr/
2bWKDun/wpcwVTEAqvkiJdjM5XSYo2X3DpyJBkqGLrLsDhk4YwfG9lCgQruBiiq4LvC97JMzKwVP
cpY0j5K9NuqBU4ULAJQR5cd8Uuxbk33qARFPey1V0UZq4Jo6n9L7BGSmT9k8tsGs99t6U8v/uXvX
pk35zQsJXvt4v+mNSFBrYqi4qab5nwcMfsOvql2Oie7rub3/AxbU60UEOkTvFMfislI1hwvuV/nq
qnnOvdxo1n8LbDJlrWu0Jwaw1QCf9QB5cbSAWZ4aONqH0IykbqDX0Ou8cj33N4a5eqAIPiwU1bLC
EUX9KNMAz35kKzdvd2497+x9+vDoz8f2FYE+jBZ37T44tvPw/oP/6azcwIRJS3fuLi++07n5Ncd8
sBtB5+Lr3a/OdD+/1rn45uoLF5cWr7P+TbcrLr/1RxECIjNppHfEXxmaNTAT+McoeUVPNLkVBQJ6
Zprl5aNYdf4zSp3Phvhn1lLni2poieZO9KIgJaRSJLPyWEQp3P6ie+Vs59K57ufXlxY/WL70vLnw
BLXxv8uEjyXnGCrkb6V6E/01isJDMKXs6Zwe2vgxatOPGBnE3id7zOqGub0CFPXtQc8h1Ot3bv11
efET5tRletAd0TieiNvpBifqiSLnRUXVEoyEnNRbB9iV5+53nr/cOX1decv0uBzdcy90Lr1s2dHh
dUwrpl0XOHxeUjifxHQwmspf1WukqJusUw8KnAgero0s4QjPymwZs640X8Xuqze7555FdTrHFCmP
HrzXnWsv9LiPkuZRIhqcxYnHthe3b+OMygVK0EnW5+bs9m0nPXwY/ojP7Amtnjrbfekv4YSgxdL9
851rf2QXpR4zMZMUyAQmAbLgnArPcg9y+7gNZ8ubrwcLxZ4pbNEYWhDYptg3zy8vFI9JCMzDk/zU
M2Em02ZVpRedqrSm2xOUWFTiq0pdfhyQCREGpMA/oDodIBtsysjAqRR8EtxGD+58avcvx0ZyodyG
ECQmFPIqaEAvoGEEnZMv3lx59tXl+y/zCYtcelo2JMJVb5lUR6bzQhGNJuZgci69DdwCdgpBnHfm
q86ZWyvfXln+9KZIq0c/dc+egs8iSRLRjchAIrYjfp0FtL8c+NUu3pujWiJSLWFM0hYtxCPyWBFl
XjqJS1MSOwkoGtWHG+rqyftNvtBrVMJ8tI1KXoMCYnd7wgJBbjDQR38jQhLL8qy7EfnRYAQ3SVkj
M1gGhx4khyVcgRogyZy05j4Gz2a9E/TdGXpssBdv9ZSTHqX8tyOwDRjMTGF/AyBG+61c0IJrOpvm
5JgI066qx8hRH8L6MouHQapH2UilI02URSL0Q0IzACe76AMNQcxy6KnRHOatQCr83h3AwmvSkx6c
V0ycl5y0LploTx5mjT3Wtvzh4vLdb/HjQy9PN7ET3LM3DEbrciZDGRZhw31KC8Q+OLZnbPTQ2KEU
cv6VSVhISj0KOSZFeWDCnUuf6hEWS3cuhMk8hfOWihPmmrI6i4RJSs2d1OvDWEmtOSNUfFrVoRiz
Xlg8BP4T2wGlLvQc3Oienei+ItbBPjQ7t8NJYNtIJzonbZjJXJ/ZLs4pU3PG7HdcAXauzdcpN25b
YaAZuqMVXSQVjmauHTYdZyea9eMB1f2Zt9KCJfLmhu9AGknQxy91/35x5aMzwENIL6eVm4tA9lZu
vta5dLPz4sfQpHP3YprYeYnuX9TJIfuArL5xY/X9N+N9QKyixcYG6G5ioaDxYPNevne3c+tlIVwg
20nrYCdKPBPTVS5SdnDIepR1E2Yodjz0U3oI2BSNa6TpkWfIrsDmszyLo0J7JN2kMz1dfnUnX/Z2
8rkJMUg4Ec6NkdUKAG7L0uhyjSjCWBPBesXtFmuINefhrdkwziETO3egyGFo3LonvqZ3cpxPsuEY
FAEQRPZ3vui++6fu318CwF69+nfH6RNzdaP3MaDEnYW+/9hheTHyD3gbt/WGUXsKfCNYyNGGRlgm
rxpgmSl/JEz/eFm4seVEK3QOlg3Y78L6nemYkKBeObe8+EcuuKRSMgsx4RJcyfOd579Y/uTZzqUL
cE+VP07sleRU/4XBNbxKzYJrmt5QkAXRzZC9l/zc8EIlx1aRcmghGp5i/aCFmAQ1r1HWmiRFoGOz
fICRQi29NTxWvZWmgSxU2rNaiasYd9u0bKba5wKvVp6on0g7kZ+UQ9BUvT5V9XP03E9nk6BrQ8HZ
Gq+Jid01y5QMO6gwNded775+y9kp5gKHvfT1u5TL+LrAyyBzM6IHxuLnNENu7QuXLXid9TLwrsnz
fT8nlbK5djovUhWqHY73ntTPt+lPNv1gWr0i3Cl7gQCeT4/E0ElmK8N89bAQrVvcE2HNjUsFRJYw
c9hICJXqUZ/DDAXTxQ0cOw550uvjWKFduhNAzHgxrdc5MDvo48iU01iiWJBiQGxneGXIBnjlsDvn
KYBmMtnxDwjpEsRB3icUnIqMoYf88/3N5UBmQzW68NAcDSU4uLbm7bZnbmbsrKyPbOikgn3ME3kn
HTUMJhGn0NMwwkRJBJH+l+A2ncPf0DMFCf1+SPyu4+cH4gGtYACSmxxRM4G5QcZxziEYgqssoN7l
ylnhQlVG2ZBVPsDdQluM8NOnI5SZCmPe+PPq5dO98aYgrTF1M5J0gzhg0VIQsmrwJCkFjRaaljB8
qnq1zWlaqIDhATrP2DQxqQh5vEfCNGhnMNYqxur7r9GpPGLoVLbHqFRQlYKnmdvlYyqX3CGQ2vxg
BBqn8TdX/02vyjXi9Kn9irNFpXXVFLaE/Zps5Sv1gWPDBKHBABr+B0rqwpC6RqoY5eP8bykXWMwG
xQq22Lp//cYKk92WQkXAOnw5hSLONkXpCSlRhi7DIr8N9BCwQeBrLDdy/3G9ZHB+eWS/M/ItUwxG
Fv1ogq1TE4kTdsnVj2QNO4gd/7WjJ+9vIgaECad78dLSN29rUOAoeoAIbfnjv3VuvLV89oxJ+nsj
6rhoIQ6lWMc4CrWHhpkwhAj2t43JfgMl58sYX6pflJtqMbqP5JAesnmSHKdjy3L50CI69kWTCeZy
qDchrz+gsXAEhcFoEwSpXKnqtcs+9EZ/C2mQsdhIwXtBHqjcFO5zcuuV238DCp2ODoIQfZLTnmMm
L/ER/qB2OzH4Arek2nKGbTd+cWwSgf+h+9ot3CLWHHRO3eOIF7ZSYn2bO59wI8xgcuoeY3+h1rjw
blShEe/YFx7GMCXbzgGu/n7mQwFlO3qn8TZBRex4lpKTi9jIcPezGHArnsZ2xBFssYdY2Cw7nR/a
uLmwYPaMv1Lf+o9kU9osjrxAFnez9LO9j1Jz9XznzKfWnsJOLn+0uHr5Gga80EODPMfGlqgVhR6L
cCNZ7C7yyEqdKrAbxfRJ3S4F9Qk5uNC3dUeYAnjbDkdL0lPoe0QG/z3CjnEiPbDKTBcJPxMtulc+
WX73OkfAMMkPX5qNvCSbaG+JbBaY/4ezSwzuiOBWeOSVZys17bvIctyqNxroYhhMcxeIKIZ26JiF
1QZ07sPDVNW2kAbAVPdfRmUCM8WIIE3bhxIBNQwDRnEAIyZWfqeo2UEj2cbRmlSNMxCcPc81ptkJ
4aiWCshGr6Hjp3xUJN1TUOjjDdJZbe0I40VxLLTnjIj4vlZrzslGyZpBt9JLd68t3X1lefHM8qc3
ZUhbugcFEjuIBvSb97jqtt6F4nGZqe1e+AjNjhdvoecFNevcu0hlUJbuvbVy852lO58LbBJBJXYq
MyNhpgAsV9nZB5iXPclfJPcqvpGxm23vsp34xuxtL20eW0EcZdgPh9YuMMP3wOaTmwf4YzZWbJB9
CcmAbLyi6Bnw+NKm3vnzS52Lt3kjRSYsvmAc7ghNRT+YWg8wsogOVjcX1XbqRq4+d38F/v+bP2Gd
88U/df98xUY+EZy21rpDa5HwBnB2A1hWB0b37iJPhdGDe53evguRaPZ2BcOOOdsW4g38LgrvUrZy
8VkKnBWOHx5Mqjmi1Zbn1ynpVjoaNKuVmOeGVGg+HZMhTRgJaOjxMNWDDHXWIp1FwDu1FHNc0DJK
zFu/apHK84ee3rW/+PShsYNsF5ddqccc3Im512LySMTdUqn41WMxDb8XwTJpBsCv/4Ym9cuLVDHp
MtxcPjYyYcK15fcQ6t7+snvhevzljUQa8oUy5/T07l0O7UOYi53yFQNF/vWunxc5WXcR9R0jORES
yw0WBpggMhFiGxi8FO/so94VDRfMwtDzknJu2pROpYUfqfL3KUgHPHbgCAakuTZlJ6PGQtc4N1eF
9gKJcqNxvqZHAMBVrAMUpZWOizwWaiRyeCBkLZye+I1ecoP5pkBA+svkVgGoZOnbd/iJo3KN0MGj
W9IZdJRCMx37SskcemH+6NNfLd15cfnuR/wT8ozPX+Y00xh8GxYrlRZ6mSg2Gg/NR7yWRY5BTpQL
owQpwN+vvP8pj985/x4SM86j8tEiFsmTxcAUK/bdvbdmj/UYP+mXnDovNx2jE4viBWlpILVtAfkI
oQkWT/oy5CVWFPyHZs8gjCha2fH3minbsr2aVF4cP5lUCXDY2BqjJOqZWAToCvJqRVKCKvIkUjHS
WUhP07fi08Hyf2RG4xH+L+eItZgObaSIDaTe9NutSjVArzJn6pkKatZiH060g7mJ+gn9kWb+kJeY
8s5gaOK8GFQEbwMWxusaLzqZOQiULbgPO0OwCedPd77mx6jE5HhsgNTL4FjB9no7IMBsFtG9n0Qi
oL/cXX3jS8zpI6+dYRc3BTahsRaOZue6r32pVpbIgCUEy9hRhHbOT42nttQmaZnG87TKeqZCn8zM
DQQU5DHHEeFGGVyZl42uysgOC0v0GMNZunNe8LzQh/CjMQP/0a4RXeDMmvmQH3jRMzELXs9CZvRF
ECVfvCAKKpKHDmVU5tRwemFFlWR1hvMDyEPvGTqE5V6FsNSXgV8lusquuWg3bvIqHOFhVr5r35MD
//n0XuMIxeplFWPlqCR4bZVZ7+KLSKtUGcmDB/ayR6RdLVIYjWClTu7pY9Mco4B50RozUwGlb4Wf
JG2LJgQk3w1An/9iWJFmpch52bx8WtdPRHvSGb+18wra/LwydqXjslNNeME0KZpH0gmLNpb5BDZH
wsSpRKIspFgQtxPqKtkajxB/iPrc0CzM/2jVBBtIdicrtXJROOCQ1WHOEDdsPzETqEVcgaM8c37J
XiIATYf3HKL0ahdeWr73l+7HVzvvvCEToyWsTXbGUrWzNf+Yw4b01U/fZHheuvNq59KnTkzXD+lu
ZGZx03MCSp5h9dVn2U04rZjcAWGeRKZoxqVMd8m9IO+4evo8ICSjJ8UkD+QFQ4Upa9bdY/fCGSBw
cd15bVhbs/KMTzVaApcy9knxAk09cAvpnoWpCSjDKyU8UC3IPhBGgueUATOgX2wuXiW+FBvUx33a
Vb0ivwqQkurSHZGERJZbnR4HMxfvOW0xKxTSwvvkiHEd3U0NuQkZK6PcNxQjgJddebex447ulWFJ
1P/2pJZmmq3AO+ZTkRtxZtymXZPGc9HsIFaGbLRSk3Uq7lRwIn6Vhh+ane/Sggl3JDJuRvQ8YNil
1CUfkTMQ7f51/mi60ClBKilvpilGxkFFKBW4603t1QO6BFFxVHEiJM0MOI51DxySE093bnwNtKZ7
9hR0uXLqNOA3ljQVI7v8x6+ScznJiH2xDYXIXdbumoYFBuNSWChunesxF9mIoIoHi6Esda2hzqGT
CYfRUg8+aJI6ulZBvXqMEvP9S9PUNWTCbFogu4KyU6X5S3hXto6Ma91iSNm/LQ+soekW+fDiIds4
JLlXibBP1GPl2z93LwijjNR5L92lMuWfCa/hnipwuw8d5LkgV8wsHA5b6X7+gfBjpldZfWIo00wx
beXbtzunr7O63VCiaNUbyPNhDRbT2ISnDh8+cMgR2TWFAIu9JLJdSS+Y8pMtp2ODkpcrAUBWJtFh
yQ/SD/gYnwpGJdXLn0SkfQ4fxto6NIlZU58lrlpvr6vMDN384b0Hdu0+6OjKLhQvdIFct/uFS8EK
dDHqDXSZwCpSooi6+RUWYT7IyTpD8jEXn0rL71k9WZ1kbHWlB7RxglJDL1ylFQcm/Qdqyl2h2ECj
nujMlUnuhNJjh63XQzZFNEk4ELxInRvvd8/cXv70poQrGB4IAcwJ/6tmFX7BeaUjoRzRkuR90FZ5
G22wiu7iQoxnvNqeSnU3drosi6gEgAtWHMDyhVtI0AhbkMMJn7rbKxtfzDjf3TsTHeis+y+GFl2v
2LNIcdI11Muf/U4rhO3k9jnptJPbSf/tUQEwOTNpnEtTYuHjhP7zjfbEehJpRICUJZjOzedXX7ku
KMa73TOXnDGxPP6FEhXjoXfPvbB89+v0/wAfXvP8H86h1ihBJTpcvwuw7dxrgt5anrYgkwj7psoN
rB26SrYMNNR2uWX0HAlllSoZkfJBEM1ATitS+ch2yVU3he6uUenBvkR2+CzrwvsyQiWEXBbsjUTU
Wrm0dNymbBY7oqJfhYV2P7xPBnUu86nf6l6uwFFjShTORfbpOFCnKEQN1B2Xj8lSSgNJFGle2Yr4
+evLr11HCnnmK9khnB56DFx6WYWNcE8rN8VLGNt/6UNm0Xh+0KVcdff8u513LrI/BwiymM3izktc
14R3KQIAffOwjQtxFfR0RwMubW5njTnmVStlZjUHhQ+s9oheslM2bhAW37Cdcp6TsoLxU9V3tj/y
yNZH2G6c7JMYPTukFRc/WPnqdOeFuyvnnuu8/WVapQnRfpeZQUAi6Zy5JQZb+volYFSobBY6GHNT
zZQLC0EaiUGWWAsXL4qo2Muct5tdJ4HYEK0aih2LaEM9vxsCMnW9lpKDF//2y51Ln/G8hdLzxi2A
QcGqRQwmuNQEm4ml2LCs2Kx+unK+8+JVYPOW7ix2r9xVdOH2FxgZAGLElbvalgsby+nPoFFoV+nN
vCRn9BSUnv8UubpHuQwiR8AeXjWvyk8ff3xs364D+3fvO5zqM/tPqR8SzKqh2ZfddLDCBK1KbPCV
T/BSvnB3+dpdsQO8OGlERnxNJS45mT8fDlx0oV66dIHc3EPGy8kddrZins0+cwl9cmXs06qkfrO0
qe4qFsk1GFpiWX8toFBwN+Vk4NJiFhSyoWMnLydJxag6bHN9X+2g9GT3kQ2qLmek8Ov4uq4Dz5RL
8DIDadmI8FQ44TbhAzjgf5w6ByQUD+a/n3/F6Zz+69LdT+mj8Acil5B/nDoPdKZz+tmVG3dElDj5
Bchf/xDjZBNuc5wX39C6rpq+Epbcrgjf59U3v+re+DvTKP02Ai/GYRLcQYJPD14+FhNiK2dglW+k
Ab8fSEt3UU40jkhr49HfDywkBDxMqn61bAPhA51vraq2a/OlEgfMVGplLD02gcqhFoW6Uw9o/Yzy
mQLHYsJhImmbXVgZ9tBHXbibT5pPUm5oR+KDwIw5N94ihMA33XEwLwDt7NKdUysvfJnEsljmKOqH
u4AOnPCAETypliMGfF9Y7F44q/nqOpq7BnmbkCc92uoYv3JQDKEjxOvUvbBLmYcTI+PzlKR7k5za
eVaG4lhATF47k9aKq3Mb1npi9A55PAAB0eupR5eACYtYrXP5Y65yyVa5OFs7OyBxRpv15NYqqyRF
MoVO7yDh+FxOypzGS+N1Wc40rMdFjsIY0BFE9aNFrO9w+qulxdfZHUc3G8T6irkhLRSpxDJaOrRs
bPkFzluVpLSJX5xQ31xjfPW6dHyTnVkKJrcPPYvjXWyNxP/oMQx8/LFKvR0URd1A03NX331ZAcT5
eaXlTIn/KRkkuXlrFghX+J/cL5Obju56gusEwP/sfu20kKLUUosqNOlFmOBZnbIkU2Fx32k1vVrg
sTI9ZaEWlmEHjIIHhGVAMB3YTInNU7HFKqxN41QTvHFuYgrRsKyukZPVGDwOZnAxy4t/7Fw6I4rq
OWaFBgxMvnMKI9W5sk5MetCIS91afQqtsN4tOteSX4HK7htYea1DQVP+tTp99/rylZfYc2H11csr
N2/yFUO6jZ1ynG2jXq2U5uxXKVy/c+ry6qmz0j3iRa630b2LXK/izkIbS0SWTSiKocOiSC2xHj7M
dpSNq12DLASW3cRQYqBv5CRsZyJYh8o7TIkg/E+RiTjzdmfxLvlenzfc3pN1c3Y/3IVgTMQ00zKf
QjDtlevHc+yWxl+cdHpHTN51qjTfrmEHvSfPOJSHEy9EvfbXNf2YntIOTjXH6eq0j+nSbHlEtbFW
EMNWRd0H48uADSZlG7ACQrR05A9i/Y71nVGuI1w4L/SlUTkxtKBtLf0ae5peutA9d5YjHYAJAX6D
GVPhiv8W6aek54sLpIwTtGFIqozubHrHReIx3E20/GNqOMxBJseV7hUDT42N7lK+Fui40kssjVur
4NAX/4gJ4N55ASGeAJ1V1Ohmcus5RByGP1HMaepRMIYtc+26bmie8qtVD/3FhN6Lv1NFg1jvZ/7d
jbVbyaMRZYLi3aF72u56dMFsH/Sh+0V1X7qO4dp2JD/bhIjjQx6Qk1BS1NzSnRdXvr3FvTNu7rz9
Z2SLQqGam1s2oYRtx2Cjh9hzeKtZr89quy6e9Nh30cJNbBFNPrCW7jzctruvYnTBP3Ng0S6sAxOK
B2vBIt2ncljH8JjfG6twxN14/rKIb9RT2HC8GPnHoIaVsAcKGTSZHoeXgMLEEUr8uMHyrzZ1GTse
qs+1Ki+yAkSUHelpNDYzVa7pd5ugTWLHQuO+SUGeJhF1wY3ZTn1jDNIR5+fO9xLDstCgz6hOxFld
vAQ/GtbDKAfSq0s9egbwgsC6WhPTMvmMqhgd69ndq3MWWBjaaRTG42mZ/laB6NLidQ4KWrn76dLi
fYWFgHYpLIT2EaZUFAqFfl0U6oT5mNbCTuGChFlnk7PgouoEa0etXUqw12be/oIVe2tsI+AmFeBp
+dlIgUE97BH+SGkegyLtlTZ3aLf2VEOEcPsLdj5M9Bqw1njrre6VT/RYP2OZjsj/agZHModh+iDT
jNFR/8wlNRmeSRRrWemvGXIMft7YV10hl0hSlHefeAfaFtmRy6zHJhl9iRrWY17VlXycNY0U9noV
VdbwKfwbVfUhrWZVX684KHs0kTKBbIfCPc3yWTt3lu8S83ssRIl3ObPuK+eQkeagOHJRM8+N9OC5
loNpschr0k2gGBGVg1YUdyeFLzs762X/u3tnQICDTfnu3llMwM1WFI5vpiq4OyK8OF8RlbIhNr9X
GFMpNJZR1CWnI/bjq7MgPxqF64ERIngTnktY2f6vIUySbgmNAF+/tA60I2KmDVFDTYBjq698wucG
rTcFzurVr/krDMFf9QbhMZJtUMxT5hmLVU3xxnK8uqvto4zkTsoDbs7SmmLn9Merz32sHppjYM/Z
1I9++Pfg/2SdpWD63zfGIPzbvm0b/YV/1t/hwW3DQ/KZeP7oo9u3/sgZ/D42oA1iYhOG/F96/hs3
KP8Qv3aMAj1SG52n4Vo5E/XWtDPhg/zqyzoQlcAJ1YdYbWpijuo9hqXfRDoHUQk7n6LKUX677jQq
DR8xQYps+1qlbDN8M+JGgpVtMiBMcWA+1vuaf2L00FPFQ/ufPrhz7Mjg+IKbHTCq1wMsC710tV6f
aTf0hLvauKRjSHQTCLNixSS7GtaTXW0VXzDIIqg84zuPDf1kmLMJazxUyJZpUziOqszEKcjRtnG7
3O/252Ao8bSAw7Ywg1ZhiAc76UyTlatEE4gdT8axJA4pG5he0v1YA6BamcjjHmMmbEpRZT7Lw1cz
adXQeL+jJmvmr2Jvca/lUb1ofphHG10Gpr5V1UqvQnfYKuv8lNakOUAPZWX6FcyQC0PkJ9qTk34z
j/K3z2+lkw5Bs4HbdAjzOPmYeAxEptbxenMmLARPBVMxim0ODZrovwJ8JcXXNDHyyak08L8U5JZS
rF+DI5QJDpUq6/jx4/lStd4uT1a9pk86rFK5litNVQZaTXjdZv04gdTuJw8V0oV0aMuUk4gky6en
hb55+rupL320mV6I8aITRlpYWFato4+XtWMHLCeLSwofWDprypL+ODltwyLteqiiP9tFb+e+rCLz
pZpiwiqNMAu7ZQ799a9PHh6iCj6AlTiIm+vV1mtzsxitRNUozSJbR0Zzvxmn/4SjcUXwtUa0K7Am
HODsXKWRrwBGywOUiEzp2FC4CYu35unvwADqN0cWFGd5xOEtcwq/d/6L+bgjR0aCBhz8yPj4lt0H
RrSvmzNHBnM/8XKTo7kn8yPjW7J60+4711de+GTp7gXzjfyWbJ8zHuFX4SwZcx4c2zt6eOdTcEFD
qCCwtRsMaw1EmVtsZh/q5tUPL3fv3Nx8cnP3m7+tvvExfMDENV9/I568foqfLD/7weYQ0sSBWMeN
ThJv39ealSIQsZkzxUCfS9++s/zaZez8r6c67767fP9l7UWv3arHpKFKHt6A79DZKpQU+E2XoScV
UwTd4mNxBvAq4hSZFFwqoiJYRWSeGoKPU5RgY5iSWmMyKlECWJXtLIjEMpShjvJLp8KEXlu1XkUl
yEJG1RvOqHrDjD4ZFnFAFGGwWCfZCsKhSjUNbHOBQymP/bCEqAKzpLrJZvNQgutZoxxfEhXKteGp
LLksY6y6VIVToxBvlE9WK49gS7G4sG96J9qvti3cJC6LnPLk10TJI3p56ILYZ7lt4mBUmehsaFE3
5q8Kvh75GXA8xiLUOefqTnzt8MJjjv1bYP3IRc+xvHn4w/bBrGYD34+FhduABZDhU5FOqsI010Ck
4t/IqaEEDFQL6wKTrW3Sx6IWZWwwmzfSbmWcMUxpU0AZOkta9nUdh3GGYgu20B4k1G3Vu3OzCTXJ
6EbQnpsHlXr4AtRJRaTXVZWaLxBbbdcoSh2zB5HaujHdJZfWTSiKkyMXh5GRn/stABjoI7cTJl6D
6zzpAWuVjRaWI4u/sAqhdu3C6mtXOs9dRJWOoRSIePvbbws94O0vWI+EehPNDG92FjlXxh+8A3zG
xHLOxZ8x+3wIrCGCB2a9OaeEa+XC9nBq0EtQKcMFbQUiC1MbL7kUqmPwTAhdMqmyQgWzOEGScHiS
pVo+ply4co+WGlkrwgFLgDEkEKZQx/U0/QznjGGDub31sl/wanMJ7iLhxi9/+X7n3msrF26jJpYK
56By8dY7WG6E/JXYBBF3AgrQ11FCfUSDdv1w3LjzhLMB1hJYQJi7KiFFdc+FtEo3E+V6PJZprzaF
DjqR8uSBgYeiGxpfQF1PMm4VXZ9LrK9uHwrStjg3RRsE4rciPCFhGzp3WkQYPvgBRQ4nRm0YV0zc
IuyhU7HYRFQm7Bp7YvfovuKTB/fvOzy2b1cBeHYtPPUB9hmey63GXT5qJS1d/57HcW2KZPOWhh4O
CP6wbZ13XmC/bb4EasuBre/bHG6okiQ1dq/ZmLU4PcHUDcnMJVSNz+bitPYyZhB5OB9DsuCTSCIa
l01Gr/bW/fyaI3KRoAHvi6tYo1Mtrlyb/MepZ+fas5yYRBSVliASrQWHzAjNlXiRn0XysVGml9/B
T9gowSVXLAEolGiWFdFAYpXGDzEpz4BV6JvfKBrjoQK/ENXKbzBgcM/O4uiePYWdRgnfubDYrjyq
48DJFct+Iyg8iVRMAaWr4gYZijjHutPyfXULYOm5MLPHlBtLTcb2gMAO3Yf5pFEnM1orN+uVsnAe
hK3FStN5VL85ZaCszcpEGyEYk7AfAzpT7rd6DSpTNUBoVIWvQs4GErdR90Cr4C4xmpQF3qXfoHOs
ElQmqr5JpKagKyc39ruKk67VHapERkcvg/ZPtrnqB8hWmP/F8bjNSWgsB8hvCXWE+nNR1uwkom3E
x2JNQTpxIxPLBrMLpRMezebx0EVbVTpg/2yPt5hzNYln5A3qqsLAPWtaH0ks1Q2zk794pMSM/aVW
Bz4rLO+dXMpbQq0JqBIOjfLVeMsjZFabqDWd8XHdgtujf3hvrl0rqekaYywkzpxRlX+i1fQketJl
MJbrME1Mc8Jp1I/7TTqLpBqPcTcWAVzWmiaUEqKXk453fAaVm5VywWUm33XSgGGBxYKbNT8JYnu5
MLTgAAVy5lFZ5GygZwvpHtUXaTGIj3I5rnODMxAyhJuNfYWEwQeqsZh86muiJ0BLNEVGSknIKu7A
IiZUxqqMmg2kmjC3kDC7pOISrzGXCsSP9fkJmg6ZtDFW0aFKxOq6jHXnz+MBfgvcYM2rRoBQPKeK
4Me85kC1MjGAbOIAs83BwBEKVYwFSiGPyi74Dscf9wOwP0J8VGIDipLAuCBq7FUuPTpuBKYwtgXY
4CK6M8HFt5VPjCPqIVJyhRLINZUvdkI7R2NrkltG0v6twcjoh5TIYFgpBLGeB+eNsrmNh2c0Enez
J+OhCQ2Rok09bmOcRLf2PYyLCo/eQSuvnWAGtUwrWMJec3cVTvh9m6PMn5GfTuNrycEy4YZjOBTc
b4ubNbOaAmYbmJZeuyqzqUoVK6K5w0hgzYRFXn+J9ivJ+WLw5NKdu8JLYq9XcjovPN+5Fka5R2Sh
jHkcMtYD+OvZGRDTGyawAuZtOGlNXFMvuGln7Ne7D6eiFXbWW1pHFOKBMwB2bpiL1YTdxxRt+ec9
pC2ucrSNm9qiVDKwv0DzpqZJs0d+7AEFEVQQEwpxG3+ykNsEwGuAu5SPKi7Iky5Xw9OM5tjnH49F
Lsi+/ft2Axo9OLrzMJbOHnJCl3F9e9Q7WZ3KMWQSduFonLVFGm4n6W8qIQuCS9F/7hpij+hLXdod
MUpHiiJEnSPW5lI6IRrL7eMOXFnWzFV1zeLKmom5mM5ckY6EV7psbcpbcNWZ7M4PYfCjoLpsGM06
poFU4gglgtrpmOeHR3IWxVlQFIMaZ2X5E5N1MEgLJfYQzdZB0MIXOSeG9aaBwFRzQnP/y/w/hC64
Mfej/1v+P48OD27fbvv/bN+67Qf/n+/jn+u6wmWHw9U79051Lr68fOFm5/3nVNwtFqnlNPYq/NR1
gR1gDxGvOdXwmoEo0E1050RLy0M5BjLXoRZctn4HMaNoIN+eLNVaVfml0hCJC1JamTX5uR4kp7mU
qflmpjD8Sn09XpYfm778FExX/RPhF719EIQf2xNAnkvaVII59REZAnT3Ud8rs+rzMxX+SX6XYX3x
daTlRDnZUjiULIUun6jsnPLB8cozXrOstlzmTCzV0RrBTbTHgLK9SjXoB7kEW/Rz9hUg70WMs9a+
IoVPpVL7DxVFtXuZ99O1cCwIwegqQ/Wn/cws7BPMNzuiVZgWzyK1rOFBtR1MFw43277shIUgjJnJ
iD4EC0pj14M8yFOVZr2Wn/JbGdcqc+Fm0SMEW+aRqQR+dMBxRc0Ll76IogRiMMwkBoJWo46zFMNN
VvxqOYDF2mOZCUDcfsd1s/kA6G0rY/gpcQdZJOHbwoAOlSDV8jdScJ6vNIrio+iCC9bj1MR3mROV
2WjKGhnmihyxau0Fgb57+4CY9zvDw2Lh03614TeFyTGzmRzWzO2ecI/W3PxvYWcy4irhLhTRnSoj
d7GfmKaswT5xV3J/YZxqkQfLTLZrBIL9zmbAEwCB5AVPh9/vsOtWAacp5iGMOQVrrm7EwS/rbHEy
abRLbHHkGPAxTcQcHmfzDOrilMT6wludb7ZrmSMuJ8aaxnPNBfTfnCumOo6n0IDp8RzUbPmPXAiX
6BMrl0bqYqWM/HNrLhP4rRZcbFi35DYKfCib+x1aEIjpmB6DtDpiD2gPS15Nwia5gKHHnUQ7+X2w
7eXDPl5zrzn3ZAULvaODXbU+ZQFEsz6Bu2kciStTEbm4pqaa4xGX+GTOS4RACN3l8YTlWmmS4T6E
e3lg94GxSLQ6jZ3njceTGIkmUONDOQI7TV1bYojMHvOT/BCK1n7ZefrwTtgdrwx8ok/qcitpNWvO
gXO2euKESyS7THiAFJsOSOUl33JdFQmC0MoLm+Y55Qp6FOIjEexlyjIyAgxdGPOBjzb7THPC/a+N
ztFDW9AzPzd8ND+YE6soZo6W54f6ty5kj+bVx8x/FBonj+SOBuMn+7Iubzi5QWYROvJ7wz1tt0pF
kKErIBIWULiqZuTwKBe32g0AgVmvkQG80a+mS9pKkM+zWeenBSfzk35nKJu1XR+P4GZKjEaXuiqq
3PIBCvfKsk+3yfWCUqUiUSCdQyYL5xfOj31X8DT6zVkzSEuciYVLsRHNX3HilYB+wCsyoktIa2Dl
rIVkvQqAQYgkM+56EjN9+2rn7T/rWZkwARuGYlgZlxoiO5UjOqAcTZ0rtzrvnHJEJAyGriCTlNXX
QJmGq14LJS/KkE3SDhkoaNHMiuSPT1cAkFwKKcqOxJZSzQuYBfxlJkxyNVJBdDlUhWgpY9YTEWTm
LtJXwtqmCE5p4HNAZjTvBIShWICsGR9FGexDREGuQCMR5aDXQvyH5mI44NqUn3ksG0UpveHOwlCU
3OcBdPnI5uWDqu83MoP5bRFQHul52mVKVOWuBamUTIdC31aeu0+Jkt/gHKgMjXCY/zh1Ts9ARamm
1pWASs8+FZYjs5KDawcdOzcjX5y8NeF94QguUuLI+C2+E+yxgxF3585yRFhM1gwe3Cshk4O+cs68
6wh2BPjlI0Mj49kRYo3w2+B4VrjIYSZJRiaCGYNHxIltXZDIiEsgADAIWsdoBJlfJBxiYM1Lj1BQ
KoQTer8HX0f0mZhV2TibJ3d4F0gC0WbmIqLgpg86oZbLrYkYIJLNKJ7zyAjwhzY2tvnDMKv407UK
trQzidu0WmNFYsh0BBBkdRRMem/mgdLxJyeo5MA/LaMTHbRDggtNJmXwDHIz8FIhgRew8E/POHGW
Kh8XZ8PiFFkYqE4IcenO+eXPPuS7F1kJ5vLS74N5f4idVayVArVxHbjigECHvPA5UEaTKuqv1ECe
ziDk0YUQfv3qGjEE59kfCgGVqEtOZhh2s8BtUA/AWzcz8jV4SHy5gebUoCNroAneUnY64S3FurEc
s6xIjsQaYtPi+VAMyxdTOqKGH1dVJ9Q7onVknyItCgkDSR0nCspGHQQpPWfM03Qxp7/Vuf4ERWl8
QrWRw8ekbh3vT3Cu1GGiPVGtlEg6UOtGkaRUbZdZbqffWIzWGDol6+s8GQtmdgEO1KRkR/QDrotq
CFX/BPDMgd5CG2J+wQAKKp8QENbTZZYoZNi1JbhgD9ZLpKxxyJRdvgG0jAOEJVjgrOFAVEV7nhXh
xiJqkjIk6VFm9XZrMveYa8IsyIzILgG/n6Gu+oGxL7Uebp7O/3do/z4HsMDKX6+K6eGNI0kd7xyT
FJQj6Zjhb0hiTPYAZ0JEiN7N6pyv4gjtmR+htuMkta3F8k5GFoHIb556WAgXBDsNbGzoZx/Oi1eS
jWfJDfWRmJy4FHFdsak1do3iXb4VeXR5ajwYDOGySA0BqBpYJmB1l/9yV+RGvvopJqdl7H75486l
88sfYUFlUV5cVGnHctadz9/o3vh7/InSzYaT1HDF+s/SPCX9FAGiWYeH1ZdEvRAUxrUmmrBGBXGi
feUb9QaPKrC1oezAFqGCTWIziYoyrI+RxjyhlxBuGS7Hx8C6/SlUToVaC5AKgQsvAmvrNyWDzxYh
X6Rz1tU54u5GMI+u8EMNnV0tSHCCrBnrtxL0FiwVXirCklHIQQH1v3gujePtShm1iPAZP2Wz+cbx
ovI2EUzTL/w5ArEYLikKhWHd39tfAIO9cuOW5C1ECWBObBSbuTHC/Bja1wz+h5eEFwrJH5xTnj6j
+0P4RbtNZOOL3F2pTcLKBXLnzJ3EDmUOZLs741BVcXg5H/V6+KXHfMQd0uei8ISyJsdeGxJjJ92j
taGBrY4jMhWFdWSO1ni/2TzhOPO4ewtUWvzcWZBMVu5/yEIUpi946TM4E073vrr4JnTUOXUvIqbL
vY3eXlaVKw2lvL3tKRDJW4wJFcDyNZK3p+c9lv0JHpU1Ce4aZ+1iUobProqwCOBW+a2UPtdwjl6A
BVUBS2TkZvc7k26IGOnl7+6dmefJUIWMfrFeDUnhA2Ov5LlH90qASo/xWdK9+XXn2uvMPSOO1RO8
uuvgkdCC7M1OlD2OeR3hHYKZcdQqyt1Gl7x5Nt6lxj2R7cMtB9/qt0fLhpHZOqgpgqjjV4PMaBeV
XkD1e13lMEcGTMQ0IgoLH87ChauUvKC1luZB6LpYvHFE5mJynQHm7Ma3q29gvI3zywOHnM677wIt
Rb/x3QcwRciVs0If8OZ7nVt/xJoCl87Bf0UXOcpGb94zAZ5I8MRUFTqw4T2J6QiBUQPE6EtxNJaO
IStVAzqGRU5Nk/oJgNw16ABzGbpYqHIpy6LOVKrqyrPLr11H3yuqX7W0eN3KZhwyYSTAaWBhIXZm
J+kXLskXsl8sYWbjuHFeaaQt/U78k9gGNulM6l96IHbm7BS7bTeXQI0/rIe5s3g1naUTo4Rc2MMT
M7wh2ho0xo7vLP4+PGwKVSAyEMgVGCsSo8P3GylOAf8jRD22mISdFsKPUYymxDiES6k/yuZBbIOt
I3YgmxdV0YBtkcBBS2J+j9m7ZrsmIwkzws7GSlex2yKaDY+HCsGy1jb00gpkgg+yJjRhbygcgWLb
TCPJM5WG1xBeXUlGNfTK6mlRW8u4B2+FeWncbC9CEGuU003L0uVH5XPgHaEsfFFz7+Gxg3v37C/u
3nfo8OiePcV9Y4d/tf/gL1xDoMRXR4wUf2gD0k7AZWhzE01ltlGFxVZYtSiSLPWRFMBWoCEMm7OI
2S5wiyOD45zfGVuzOUU+RfmlVMOeBT+fFewDxqaLTODEoVh6J1SiUi+kRh3uofiUN64Qb9PmqQyN
RyuBR8gWzlxg63ZAKTRlJ5JERBV9avIRSvIQ1nKTZwPwKVUx0dohitM8IGwvoYm2WKzUKq1iMRP4
1cmQ4yO3aPxKtUuzuiKqOplXJ8cfzB/pVVoM/LXfo+7oRS7LavxcFP7xlmqRfms12wGmn0QrCwlj
bGulRj8DsISb2JpTq+KOaE2WlKuPE8vzWTPJuCrzbQ97SDToN6LM1W+WDERgy3XoppJd713LSjIU
MYTq00+p/ZCmNj5kaYEzt4aVYDp8xIQZkmZB7g2NJYZSN6la8TCtfMGK7XGbjVl3xJl3rZJkI84R
61GA6kbXK0/Qb0bgU5LG0eWM2/SCnnXbHV8wX3C9xsz6ZiFr5SHWsWqW/QumR32EKbbpFy3LtjHv
MHsJ0mTc2SPEoaCCR0aloZ1bWp91jxZxGqzWoYPqd+YXsvRdvNDvHBGfxrPjsXZXkYTxzOt64bHO
udOO62xx3H+celZYe2h6GkSSNUm/9/n6BFl4Q6d7OSd+NWIekZAGF03ewhgziX6z0CUWj0w2B5ot
B+tpwY0XmCLd82n1O3LeGjbs17AfjEorih1SXUrcnyK5vQu8Jq4nuzdn1/a/4oaZCKnQkMdO4ncO
8LckxZAM3TCw24bQto+MZgwOhsfUUR4gF+k0voFBAm7sJVCtNRO5MI9ltg/2O48+ms0m2MAiRvRj
XrNCAZzEGux8+uCe4s7R4hNP79u1Z8wlKRYejB08XHxyt/Vg1+6DbswwUecMOUQ23rQeo6nmIrkr
N59d+vrD7ntXVz85x4HswuxG9mPdbK1KLznzcrCFRKuimGRkB+FqbB9k8Sqo5ktNHyVLqaASPqoZ
uu/FklfE4rpBJrseUyOvRuRHJYsXB+cvf3p5+Q9fY84KWqiwjtLiRIj2G1+tvvElYIXl+y8vL17h
CiydV85x/k1cLgWScPWKxPXG03zkiC0UpZcmtpL783yWvr26tLioZitcSZKs9mrs0DnFKkqse6fY
91BdbQxwELeZ3AxHHgQpupT0vZ/R/LhtIonDduIFltl6oRwpRsjo4mJQ8xo2m6SS3iCpGRd3Qyqd
OcMNsd9AzNrlOvNFptcPPpY8Oiaadsd1RkN44sJKRGmzsvjrksivuc+qE7Fks81qiihj0bulVpUE
LjQP0wdYWDkf1EszPlk0dYfNVkxmoN5DQGfY6XGvwp3zdPGTD/I3mvP8sqtlChzeNmhKcQ9y/GI0
gDxxSu74A+2HmKw4a4IP1VGcbMnJg8OKOpbzMrI2RRQ6A7wMnGiYBGLhoIcXgjsCLqnd9IvcJmNx
mYLDTBosxtlLc3cTfvsc46dlQ3aWP/4bekScPfPfpz50swmOpsrHdJesZsCOppP1atm36GBQarKE
QlDKLci2I3Nz8AJQorcCLkVmjwIeHFJB3KPf8U5RiBx+5PA47SHHzVk/YexcD72xG0nliW89wr3K
hJ74bZt4RkF4+HG4Z6916UlLW5BFs6+IyRNr9ipatJ12pw2vvihXw7rtERtq5Y4ZIJmN+iOpnu0b
I+Ashpwl6XLM1QVU4oLcHWyUGb28kS5jbwJ1Vanp4tuusV/ue3rPnjUGCVHH0KB1nUSQhX2fMJZW
/uYUevplMvr2Q/ytMntqfURkQTPGI8953yUB8UqUSDCTTXD8FLWQ1uH7KWSj8aw9vtmhlIzW7lAT
q0SnvcFILJDNlll7W5iKaRE/GUtqNnfJP+GX2i0bscUy8Tx9mFkhdqsz0hcVZ2NREcus2Ln9BVf2
QWfLO1903/1T9+8vAVuzevXvyKiR/6Sq/PTdvbfmcdiFmAQQlqAf64sXMon9+qU4pD729NLTZr18
4Ra6Vcl5MQ+pkrZbrBpwaPPU3cIa7sixDqrq7Ikvc6fq9amqnyOqqCfRI3OW6RDcngAobxdluFCM
wkbzEc72dv8VcG3QU0msdWoaByYRKCf+xh2P9Qh+yFESnM6Z6NJ4WDBkafG8cJwUXrLwQ1hJRveW
1IUd5PsxHN7B+jvcl0pBFXU4tNdr8as9bZzRrVLcj8YJ5QLAWxP1E+64VlQwyGsKB6/RciWfqzFi
qX/i6grAty4k3l4qVdv5+ivr9up3lWmCdqwinYA4SAO9xJs0xAu9aFQJVo00BwgRWjgilMkG8FQs
itB6Fkk4x9CBzy9HffCEFpfWpspYFkmJYi2w0mPxWoeulmVOHJFBSMSL6Hedkj42xQkAFtRY2tF3
KpcDgI79W60xm2OdPzVQvoQ0qLJqkudhHoGhRqoONZymUSdhQs4BaDXsBbkGsq1E+DIGfuMhEJ/Z
95Fozgq8E2baClSZaa+FXJ6o9VpQ3pWw09WGWqRNvr3aXCbSUj4gfSEz1/2OdiTEnoiByIGNmoSZ
b2lK2VhlmIt1qZqVssgZEIID8qCuxVJJSAtsroruL+3VEXeKhT2DvTviYtYtevxL/o6aYPiq2vCG
yXqq0FG4PFqSzAJSqcnBohhbQnfoIJxkd8CeaArYnxh0xC5Wm+d0hBlqqGMwgypKVbYcR+i0pRHP
Qqui69DXMLKukSTZeh146AF45Yi2mlKkAC5lrZUePaJQbigsJvHYmkWa0y96Vc1NplVpVclhkIUJ
0v4Czg98jFvzRKSo0MIVhkIEJtpE/MLmqcMFx/k/t6n+EdNcjGt5+0t0/CLmzo3onZQ6LK4bLDtF
3RytOc68NtUF0w4sjJWl6Xo98LU1yumLv0moO8zsj7PpZWK1ldVxC1mT4zwI7Bgc/kPzn9ZOCadG
qaeNspjr2CiXdYjk+HX7b8y6Li9+tLz4uej90sudm/dCv8HCcDYxiFQnhwHwnKWWlHLD8SyMNetV
alW8eAVdxGH7LCrka67Q/ikAIKsmVzcVnioUqdV99Wb33LOcur5z7aPVy8/DQtjDkNcFG8Slpzq3
nmdXKme0hol1GpWSqJYq87PClsl5xbGZrBnEy8osIt3RlRvfwMWl+pnsb4odKv1OyCQm3ElXUwu5
1t2MKp1i9CBSTZGgxdLOT18er2XI9tMoVStSAFR0M5G7GJCR/WFzwTLkZ2dQHcpfAoH9KKihWNe1
E2sGVmOaHaNnXE7Vb/lCcsHrwkyfhraxkrrUhPGP5EoV46kMGyIyRqAGV3wMi6gMRhSYzJKV6o05
u2U/j9uLx2clKrYS0WnHRXSavQJle+LJc1WVCXfjBhEwf7QWIwQbjW0fH/IvyjUZC5FbT7SDEoAF
ufghH5HhYi9SK9DvwBF4LdRDYYiny6xI+LtrxCslBVeFAXaYBST/uzZitQYHElKOSnT0yqNZBeMJ
M+GESL3RWGPNGfdorYH1QjA3apGXTLbecApbHFdk6XXXcG91KZlZWmRn4YiNMH+v8Nfamn9sC0uO
SQXZhIWJErpgVUrO8EZ5MDG579HaWvNI4x6L0tG5J+DDoCuSLHAnRrKF6AYRyEkQ/02lQZeKdw3t
AnBs6sfdB4q7xp7cM3p4bBepC+AoiggtALCzMvMlQetEu1au+vFyuG7Elzkr8g1S4lp5UsRTkXtF
fJPiKH+zZFR8uLZTshumbxHdzLbxytVk7pQg3zpBDLLK6iLaCULJXzQPuH40BqH6XXyJc5iLuWAj
iXPlDRRQS1iqSA6jxWKW1dC4g+SWkBV2uNRa3aB6xy0WEbsXi2IJZJ7kI5BJafD3ozX8byZrIBHG
SqXp2Xo5M1h/9JFHki1MpIwmVEdCBmIa21AVdQYSHHLYax2pPbnbcWf9goDIzHFAG6smouYpisg4
Gy/Tb+1atVKbyUiaRiF8wbQe+CJFtzAxSEy8nk3/hDAXEyeTWpfNBmmYNMh4ATWlFkY06bFKvR1I
oqWaEMGVv7pWTgYjVFDsXiK5GhYt+tVg/biwav14MZibxX2TV3z9WU+IOMsn/c4sVjUgnGKHBMYQ
bToxK7CYYgzL7dmGlriF2/VL7oZCrmMnKhEJFkz1y0UrNwkbzjg/gUI5nO+1WKkdq7Qof1/GTmBQ
0KACOwibjlh5/FGxJPI7ZchdWQGWkLALw2rkQtiNhbLtW1EWGWD0u9FTMW/wcXEK8ScAA47Rx8gi
EiBLwksCQtOmHEJW3HyTXZU09lFd4WSHGiFy4E6Li+6Vy6x/I4WTxA30BRUZ0rk7XkOWZd34Gmqy
tVUaI4aGFXmnFsBXZn26q/FsKvImW7+Ix6KFZcLA2ojD05pzwOECOXagDRm6Dx1xKe/reKgpC/wG
s2smW0Y/ZS3JIT6eURUqQu8I8UxLVGokXrJPkcU/iUVRZa0Zs4yOszJYXz1h6aYXUsbmlRMFwaKo
ChauJpeEYzO+aulZccQ9A3KrmllbYK1ej4owNkE4LeuqG6KlmDYpM1n1pgKtufJxliGe0uy/JsOf
wLiEnA3m9JpIH63xjhT5B5nQS9y8AORI1EyvL5GXiqoI2RsW4rJr8HHWYmIZOJWGIxvrjYzejL0H
MfZ0M210mHSMje1hJUlceGw2rSTDU+fs+Wi9Z9cWt3uCD0EBZx2IAIvpm8INw0nRYsgLKhXPmMs4
eRldrSKSZOy8hexFQJ8SAnmqUdZUxf4lBmGr6eW9BhJgzPGPMhrFKElC4hYJhggk3QL+jCdsBwrK
MCli+LEGkJW1yBoFm1GpIDfaBStNkmdt94X4ISeLl1udsJKI2wAXLJsZg5r76NIBuiIPW7b30NxW
06nG4Qs3aGNWYqzOnRDjK2LJYA4YxK1BWDarENKDTVYzwpuxHBQqZoUBpcKaaV61KKqi6AEUguku
GMkptV+Ehol4ThBYBgeRu1pD2yT3QTqYIqUjPQzljW615mJYV6Item7tiF+F7NXQaFkDeYFOFgT/
KXxROFYwFDLCGiy0zeJOSEs9T9hzRcbB0ox26zGXa34SH2bwP/3iyZ79O39RHPt1CDJYlKvmU56V
eVS0jmBAs6E+7Z47y16oq6fOdl/6Cys+VLU3LaIJXu3+/Xbn2uvw0tK9Nzunz+i14rB+0yvnlIo1
QXzncCjs6conHI/ZOXOr88LdzsUPMDb63N2kvt0FywVPuNPe/Xbl9s3v7r2FiEOu9QjDpGYIl2kJ
pdDFQI8ngDEThBnDwpJGAGM0d4TsS0uLEoa6UEiXbKBiQ8MwwkiyHDP/TULGCDvK3c4DYXzTTTAy
lClUfxzkZ9Jr0G6bx2jNTNT+Bn2Y0VmZhCiscIGwX1wJCFX5gYg1LJGPhxaoEn7D7HEWuq7NZSJe
VtgnaxHxE5ld5UjrTuK3dpyUY0ffWF4smu2UphE7n1gvMZr/uE1JI2bRNZ1dZM5O4e5y9pulO+fh
LtkBL9IGik+jji+c3yHi/ZLg9rJGasUkDxVbT6H7LmkFVNyewS8xuhvY/PWkgTXTvxoB6DqRtPM5
Hq0NYx4MNtVGM3a7EWcC0wdZetcmejPFOQHhSxagRX06oz33UMLFe3gLC6NujHb2MuPtzGs61V+O
HTy0e/++Bcpv+OlNTDbw+XWOljB9mQVXKgsMR9Es9weCf37qGa2EoWpudwB7aj3qiU2pe926mOzh
KxGd8hLFVzNikGxkjzoXz6FxlFYuHBU/vSkCRm5/0bn11+XFT9AFirpZiEJFL661h6eHjR96p27R
okJ6m2OtWLIoS2wayHuqn7QV2HbIqC7o32kvN8vyGiymGbAjNHcPrSt+gDw6gD62Evq4Bkj5K86g
s/zes67uCwJ3b+Xby52Ltyzbcuf8HawwevGm8F78/UDEDBsSdL1H6PLdu8tXT4maAiF4nmObOKJ4
PTDB8iwgqhjZRGEH56Y3znXPXLJ8IYGwdG49D+zY6jvvL9051X3tS5j08hdvrnz5JdIjzGsCA//j
1Lnu7cXOi++pxBP/OHUevRD+8DX8JBOvng/75j1SOweb5QwNOp0zz6++8m7n+dPolvvaGSzACvzq
4sudG2/B2LCXOB50srR4HQij2mGaBWwtjGYlvuic/xvttEj8qvKToqTECfz1HPpSbWptUg8VwaRu
82eHF9xDRBl2LxhZt/wxRnz1OPiwVKsmlzp6iFioJ5V5u4QrAuUIwJRXUmeKX/LYUNacRJlTqAuQ
QBdcmZTmm28w04qWjEa5XSwtXtCSPXOi0s7pz5bvvywSJWV7DSZ0Eq25hl+ghNrhsGHCJUr1wyE2
nO+nZ5ciHaDW0Z3Pu29+s3ztLmWiNg6/d08yy4zqjfLsqnnpqTU5jeJ3987kAblgTif9GCSlkacA
SKbd0BShkWPiBjJTZ7sRmZkUy0W5I5d5qBaAqJrr0uJpXrWtosKy4K+Jhc8yQgwHmW232miMA4xX
ArBHiyylNs+E7SOTCXUta01IcBrEtQKTGeEp3B6jWBoWcp5pFcIIF3Nkqo+uuTORIjaVrIAsSAR3
+uPV5z5mLNq5fb1zGhM3s2eRjjnXmug6Zyn255+fJDqsm9MTVlGllCbJVU7TVDIb6IBzE9Hn/Kho
foB+yQApnoKZTztafFU/ATBNTiQo9MjM6E1MNP1juu0u7iIIdMS/N0kWFleR/uC2BuGkzdS1PeVm
I3OitlSynwxSsDjzPVxSwkhNEZuwlreTbOlRM8eDbaCq7aF5fxWKqIIvFnkqwvdU2w7cPOSL6FuQ
EUDFzVwl35T1UDC80rRH3Bd1we9ntKhLHawAsXff/rL7+i0WDTmcUcXmxMg+ybhN7Ohs/RgwSQmT
CDkYNQ3me6yIDPbKQT3VK9dWXz21evo8EoSvv+LUoqpwEs77/T8juaAb4RpziFxSLBAtfId7I61v
31l+7TKvnTsGyTqMinjlXAz6ikXpsVsQAnCuxB6BPCqXDYhhbJCRItcjxU7KZZZ9fzZpp/lX2buC
zkNPHzhwcOzQIb0La6NaFQpNlvnApiq1pDGE3064cXe+xLx0Z/8EeweA1Tn9t9U3Ppc4yvJ01vu3
JiCq6KEUW6+AIFA4okVPt+oNV+mox+XI9NUR0SoX3sW9VOclHa5Xr/4dmFUOZOkxOtYGDgKeALEo
0jtJPC5WyuGR/ZUz+N14H28N0DVgVE+fRzaBGCPn6ad373JjvBJJh6zqdrHrgtAkByPRQi+WkTFM
XCedE4dGhsdR83JE3fJxFf447+bYbMeOPAt5Qo2BkIFUF8MjcZFXsSZb2/kvnFxBrSLv4yjFUIX+
EIbabGzKk9AUos+9X1k6MLeW/IXTa6HBwzQnm/7fSUQoa3mAxK4sVLJKbT+p5xUrxbonGYOA2jFN
isvalUFVsAJH7nMCCswQx3nhqHjONBadx4B//B0LNAiUyzXjQcaN1AQ1prDBmIICE1bdaH6xCY5Y
CYkFP79mI28KFyDkHg2jK1eCBparV5Q7cjhSdzC2/0mhIviFPzdR95rl3bj9zbaR+0ucHTpMZoa2
DgK0H611/wTM7xWcxMXXu1+hm7byh/u3KSaMeWAOWEnH3hIO/DQF5it67YHOYdjnhyAkTy/irhDb
mfHNdM+IuSwpS0sUC7nhwIkYIrwYHFoTGvn6uWckx0KF32NMm1yuY+QH8hYzoXu9CuckLjT7wHrn
yIT/hU5r/yrHtVAx0uukBMcxYr0m18U/0y7lmcXoj607tf/g7p/v3je6p7hz/969o/t2cU3ArD2y
4O0JRIgXsMd1bT7g4s0e0azsoRATMasG1v3aZBNOl5fRJiRgW/AK/YZxG29+BRMboraiWKS5S49e
N4yZAUj+0Q///h/5F/WJ/77r/w4++ujQsFn/d2ho2yOP/lD/93uq/4vKUkzrHVcdiYU+kPVQ8yv4
pmNDjpL1kkoBy+K3XuBv39a7uu9aNX21yr1hTV4ZlExEo+HNITsqy2d6LU+Wi0FX7kD+HufCjcYV
mLEHjH5QyLj9iMxHAJvLgBbpg2NERrMggNl9+PIMIHLmpebbzWrgTQKS3r5NkjSYT6RiV77Jvhlu
QfFbMenNFYMFc0IbPj7sESgaZuDdfeDY9lGRPRdfEhHx7iYXa0CqEP51JMmNT3l+/rXllz7jxOeW
/j1UiHcufghAw7n6ZKo6wzwqbJFNPz/ZrlZniddsuke83ORo7snB3E9G8uNbMv8xsgmePDOa+w08
KeZz41uy/yFqE6xZ9RF3wWGFf/e9e517F5funO9+/sHy1RuuRq3j5yBGHA8/5ou58c3RoXvkhGdr
UFzWfBOgsEcbCMJSIIajpT1RmBpMsDguPog92ny0DzdJe32NKibyaq88d5/9n1Q1E04fdgmNYqsf
vt75/I3lzz7EDGOfv9G9iYtZuvNS58wry3e/1c08MbWzwrTpPK/+MPU5+yNT7nTpmmzVuBJXVauI
pckfSWUBkqqqiJ0cch4vcLZ3+Lv9kUe2PrLGTonybxGLz78/770KglfrjyZgDgsQyl0TnnpRd0IW
LKyKhmbFMcCfsolWg9Ao+qXa6oXluLIcIlG/VA48+hTMoKqk1+q10gkc5qjciPjaWmYtdXmSfMFN
R64c5TENpr3hR7bT9+ok+/YqX2ttLQItk2MSyMK9Hbjjc774J/TMNaqwuPDgFtmorQriEfduNAbo
ZcUfd4ZlwQ8LBRx6ahQWNhIigC0D4/Pbti5grl0uID40nu1pChZJiW5cXb7xRoQBcOYlPC2Qnvfc
C8t3v1YWyjmRuI/ENimtDfHd7lkpYRIg0m+SIFQIpym3w0YAugKDhuQKFr8Q5RRVUK8OlFq5zKRr
GtMt1yGj7ESzRrCPaKFsLjM+8cs98JqG0sT+A6f0RLtSLTueMwtoERkDMlEiR0WHjtoy0mqhEx+q
QaaaJOoGeWSy/v/2vr27jePKc//mp+i0kxVgAyBI8SHR4c7IEm3xWBZ1SDpxQuPgNIAGiRGARtCA
JJrhOcoksmRHtmTHsZOxncSJPcnmIXkzs7Ys+fFddgVK+itfYes+qrqquxoA5dgzO4fwsQh0V1fX
89Z9/q7WGmYt9kVn2Vs+q5uNxjUSpVqFVPYizSaUaq61WYQoz+lY5v7UHDTu0LpqfisYbk8ZvPMH
yuV8//OfDS7fvv/7n9y/+mPKEwV5aj//adxTJsU039dtDVEuMDpDH8rlIOFloDwcnOnpfXscvKw8
DvbpaIDNgsNF75zN00C6X2he0jBhS5xq1ELFRyi3pTYFJnEh7oWbCPRgiGu82nZI7UGbQKUpy0WJ
bXJm3p9swhWSdKXyjIImOGwEe/s2ZZOl5cHZBpEppq67cd2Urt6K00n3XAcC5bxWR5y21aDFWWgW
p8WHiaZb888NPYx0eiqPhErluU7/6afmXth6odZqX/iBuLbe/MELTz7xwmpzuj63srI5Pz1d/d7p
yrNHGAJZLDg0KopJUhqtWGCF7kDYN8AvzfECRAIMOnJoX8iEUmnbgrzap6cTOeWiUBF1eULPnBNP
3wTHJOMk+73qpOAFJmXusjKnvMUDQpwVNssXTVdE31XdkqhqiyqirGpNZUcq8MdSy5va+K9SJxeh
H3x1Oobh+p+p+eLsnKn/Kc7Pz00d6H++Jv3Pchj2SWRhi324JVZ6vtmA3J2Rvj10ACcOjX1sSTwU
RtwK7GvYIAVdHcTqHxT92R6pKXn4Cqd0kc9gxJD8EYT7UQ/5VUGolHIJEV4sqiN5ZVt9lcZf9bvR
gsDuU8tPLq0vP7PkQKaA4sQzx1afXlpFTh6odAe8vrsVl/Et8mhH+GHYgeDShcyGYMS9fL20c3h6
l3+WdqZyU+LXN8WeXjpBhOjM6tKTy89h5vfnLxSL2v8VLUW3eWu66E6sLh1fWj6zDrwvv56Q/vPn
piVgnxHb1cGz+1EVyxUxpMfRMcHDQC6MRWOjLYX7oU8SphyDapx+BwTqmlPZdrxe0GpURX0o4kr2
1CClCr6CkQw5i5mdQOpWzew4KVjrrkqf4BDUJ8gnD372ueDUIKP09X8dfP7He6/ehNCtOx8Mrr2c
iC0RIrYoRWzl4NJH996+sfeby9a8CgxOCc7+DFXB8M0ZHk8pmzGGgLRMJ9MEmRhVErNfPh6AlQYW
aSaGOCVufLe88rTzQ/j2nPg2Ov0zcCQfvpgcGnEMX3+NEITv3npD92sCA9SLvwSu5u0b4nwmBpg4
OzEq7H+Fg3T31m1nh5q4a2QujPU/rfuW9ITpvbj3+zvAlbzyG9BTybc6qpmQWvGlT/ZuvKx4UMGC
3b/5wd3PXrn32Q2KG7x7+1U9sXgifsg29jjoqzDoKJ/TNCMfwpORjaP0VSnS1CV3YzfxnAva0ksf
uGP0+f6N/2ldru//eofes0s9scyCzD2A1wUt+McYmQXakGZzXkggHsRBKUKJ3q8KWcJg02DWDJIU
vQXq1ajYVxh2yrC26e2IjYjWCjNUKaF6BwVZGJE6r1aubPf8EGIwQRGBtzPgUCCIahirjGkhANqc
DnpPiqbVLIp4+QYton4bk5QTbcfbTPoRj6mskDL4JnrFNjTfWnDngSg8QdiJjKNzT6MXOpVAjJNY
N2G/RbiHQZ3TQEpmAKmf3+4GzSbIi7KAkDML48Pq4WANA9VLR9QrmJH/ifkIJCYbjTz+a8tB2EgF
oaHxlopc/LWRnyoVYAJR11kBBWEaJI2GmZcGlccFZCPAhJQsC+Uw1COTgOmpg4s7jgWMcTvIjEDy
yTkm2nAC4SoBY8VRmtFOltARchWUxcx1t3F0IzMF/NJ1wpVDEE4JYG45cgnBLBuL7qEkMCqxWIXQ
h8A3rFYqZMXQdGFwDBqH1iRGwG6QUwr7e2TIgUNCE0snEEdH/RsKyiOBJbOoCZaMMdj5qGYTBwir
j7Ajnn8eFMzPiw8Y+vjqIfdQzjkkLh2KNHBAkZHS6EMIX0VTbb1n4N0ekmb7NMhZwEsLWpCZHIL4
SGHBjemSAjOJwPwiNGTQNRPnq6me0yaWmd2Z3e//g5vj14jpFmMnnvfDqteJEMqHA6SIJyqHXEdj
hZ2MqeieO7KbPUQEbmMBu0JLL5Mt2fxiUjrijniD5PFbXtWllxnrsBIEzQxVDWPMluDK3AwPKd4C
/ba+LUwRQKllu/654KxfBle5/RzHQOxRDz/kMJP5k8/GCyZPX942fQxfLcrToi1PTiLvqLoOumI1
CaJOLah6bXL/9Bw4BEm7Da3U+AUty3Wohc/CyIFSL7ErUBzBTdFo00Np52s2ni1smG+dfjQmcNFB
pcKB9PhmvQl0MDDXmGhtKeaTS0MIphx6k5PHH+oViUMJH0meKokzXdWQ0xz2GsTbxYYVDzC+bMov
eBXioREsohyKMYql38ASBiaaonqinRJwOdxidz/E68zgd98GaSgaGF1L0H9Ciup161iL+63vfav1
rdq3Tn7rmW+tfd8l8PLCZkt/BR8IjzgrCF6CsXDoP9oBVYBYhlMz+Vpjs9ET/AWZMWEKgVUhWHys
03lBDGCBK3paMGlYoAoJILuHQmf9+1ClJ8gcG6ZgZZzf8gVbJMqBRgQWZAiaWqfRU+vbXf8+Om1E
PoSJzAXiupmDGnASMzq8QFMrugE1loakqqBEQ2SNzBgraCOOpevml9fQClqNq5XdSD+Sg8F5nFWi
5twc0ufmEE8Nnp54Gx6InP9LWfGJvweOXzmJJc1sCl465xajXisUk4nxFoqbaEy0VOzSkMWhlQkH
+bU+ari26qBD4yVLgwLR1JPKWoFscoY08WbfTQU8jVu0KTkaxpvwqYUXTqMrKnw7rr7VGQUNDByl
VAvCPqFTyc5KTgIEahD26/XGhYxLavUYhdbmT2ZJpETXaHFXeDWRpwI7SZFKCfktjAdF9V6hJ87H
dnnLv5CZmstODGdumA1U0IY5JUZpM8yB3eeRp+KFjgtHKfNx/YBRWBR6zJF6QUaHZ7KyOBYV1FCn
oMJ6Cgu1I6vd1TioHf626x5ivX/3LFpt67oScGGHOr27sMMN2OWTnzAtRhxoGWZkFtIYzFhsCuat
6DGLc7iUBW8aGCa4kTgc+XRE/YBfk+Ky1BZNWM+5JmLO8ZAp1hSlJYLWprWoftOoxACpDV6YxGY0
xfEIHestqskC7yJeoYaqMgW29BFx+vI5wD5U2IMuskIkIItTCOyvFb933heHhhCq+l67yhp3cb/i
iSNWV0fx+MSg21OEetNb35bWSQxxAtSUwExZngP9f0YnaWMg2NqDAFK9/ZluR7cUu4tO99LfHjwE
fOVe94izvgWqVXF+A66F3OZVr9ttiBVL/GcbTup20G4Icq8MzbwoyOvBB7MFAvyQv09hIl0U0HeS
TRJwozbq5lCqzO6go5sC8HDSJNP0YCXpcQAB6lKHaUGUYCJZaQYV0RcpaPBMIthIQhqBsjnlHWdC
SABrCs9lIQoLfsSkFLG/DitHJCg4RKIZ1kPYD3vXrt/9/G3Q46I5eHD5L3uv3ABfpJ9rKSselo0H
+ibOAv9CTpE5v91v+V1Ij2Xj+ceQqvUdiqVJBxYTnzEPE86xVa1E5acwGlLInWAuwshvchKAe0xE
tWPIrmOqiJPzbOIOKPUEI6ob7pAU4WYRT4hl2ttqhE4I+r6u/0/kPuSA9UVsj5487AqWitfhuSax
1ZgYlVCLQNprg72oCWmeoTI0nDiMjeAAjoi0EMIUQoQSFUy+hNRsOHEl1oGYYv1UtoSkngfuMSpC
JQCeciq7UErUWvPPNdBJqW4I+juwE3Z12T6p+VDnXBOzo5UroJ0FFXJ726qfgmnl1yWO2OxooU6j
6aigNN6KRgSqPC0BpcOGwYkUL1aFW/PxX8lRBaKgP/7r/S8u773za0q3DpA238HE4C+Ts8vemx+y
o/9B3M9/vU+U2uI/yv9jeqY4F/P/mCoWp6YP/D++Jv+PvasvGb7+EINISAmIkPWjwbW3BjdfBF7k
i3f3Xn4f8bo4ree+wn8Mz44tLwSPDvWz1+sUCNTSCA6K/EDSnDwAxFL9CpvjOXyAgwd/7/cb4NX7
iHMKMCPXILExhKwjzrdTnJ+tFCtHj+ab4dxMzmn1m71GHlH5ANoUgMjwrBKnq3MCmJSuc7JfQb7g
qZPHVwsTy88ce2qpfGL5qaU1dNYgL/SFudq0d6TmzXkzs7WZ4pHD3vz0kfnpqSlvbupo1Zs+Wq9V
ZqeO+BXfK/r12bnp6vT84aPTFW+6Pjd39Eht2qWKocZmWO0WGsEkIl5iWubupEy6+o9wQOpNmDh+
uqyerGGDC61CzQuqzaBfG7+aU0tPHTv+vfJYjVgAvJuw506cOvbE0iko3QhY4VxAeAt34vipY8+e
WCqfXEFfG0vudPBpEb/C0HmCyBWdZ5pTnfJnQe6nm697VeA5ag1vsx2EguEQXI/XQ06o4vNhKZgk
yaOAVshrABQvac+AI6uCbCJ4Fa9J7tcyt5wE2WA08CFJZHvdDKyuAqBsGNjhQ2Ku6NBO+GGvb3fk
Ic7QHcsnnMHtN8ATg0A8tAArdgCSOdsEI7sJ8Rsy9yMF2dBFCHrrBDUhVzEU/1nIFM6dQnd0LEb8
Mz6wMDTbOBXKLiSQKcTK8Cd0JlUwMn4z6IghV5gRCE4jZgW0r8dPLTse5EIl2VpwZ1vAbqFECMSq
1wdQZQessY4o4JsCNDV6Ua1yN87sExCOqXzFCO8TK8efXloVa3Ft3Z7MUD0rBifl4eMrp9eXnlu3
GYer/W6XQEETOj5uKeWpAoUYfG20Badb5WyqAG/r4fedncIStyMs8EY+Kdb57q5bGiND1XgBLFG2
UP5rQdCMBpJ7pgJcYko/ywjqsiNAN1wQe946ZvHlg2F78bGHQT+2fFrNnW1+ojLi2+ml4+vLK6fd
UYu10a4HlvmiNYZTVA9GoN0SbLD1VuoQYxhMPRieGF2Fg0BbUkzjgEhUDs4Lcldm4hVKnG2pZjnl
b3rVbYfO35DkR88RxEMcgxA229nyQXRuRnSy4CyLguRFj+UcmbDyEWUkbAnWyvE2u74vaK5Yuz4h
wQBdFmS40WqRMUIjvssnChMStKdxQdds4kmR36GMNIKmZrK7eWmlBL95VCerZKioNdAA7SWTi7bN
v48rkUkbbUTUmsJ+NLG0rkHd8z6NrB/RaDovzqylbrLmRFFf4P1I0S/ODj22C/illz5i/7+3fn/v
pSsKpIIOH8h5itGQwP/l0DfUCo+teR/IOYpy347sMEzasI3XoTwvHhPHRrOH5LPu4oJc3EGGY9ck
nePQRqCu4LEUIjW1EskxqrGQ0alZO/B1PDsKdNwIFGTztlWhpIWZKmpK+ydFb2Qda0LnQ+rAwW8b
oP6TFZVsb5blMf0ToUW6Kam10pCaVWI9nVPierOohOQfC8MDMdO6NEaA+1j1RCQKM4l0EM9aXpO7
jclh3TXJ1A53AVZieLbRKQMpbGy2LYtAuQBwzfaWpm6IbkuZ/Nz8OTcXVbThLtfcUmlEevCYfZ/2
rFLUE2oQEx1eW5LRSlIlQz1O1+JMrsHLu0RoBjc+AdhESW4SWU+RyjoQ9kfyFumswDOYkYiZ1FOv
HEGlHvzxagxoJ+Ery8fnhPSN9ZrlRgtwc+TI6pyzxhtjIST/KAnlHCle5RxdQjLdoNP5CKjN5Pnw
0lDWYsi22AfTMRaTgY1J4TE6AGcvVoc5bJSMQ/MMTAytPXlPvdGFeKu6R7YxSNURjSwNKTlX67m6
ST0anwkdOFumFgC8kx18B0cJH5o8BJgYuw5lb1HaDefBz98Z/PgaJBVIHHJWBO70o6qPiKL4Utsu
zFoze8lmU7MIER0gR9/4hLrA4xPvxf1XPwa46+tX7966SD2wHtPJHgwlLrIL/NLRtETlGRtKLYEx
7aKPhUEbdS+L1EB/1TZVubl94A0pB3g8TH94irVHHAqTEcs89MF0y6AxfnPbCQMwh1D0CsgcHYDh
p4OR7CBVr42hD2T/7EHxsI9O/PV+E7nzgpERiPzOxuV6dJEwYlomvrToZ+NTZAg9dAeNGtjY0ZyK
Ti9SbYIRPoIYNik+woBKThWjKthWiKdERMf14xlxfyBUP8wYkAuwN+RUZ7SD8TgCoLklkhBPAesY
kvS4s5vFi8hHIjOCi9Wk5tqifYhO193Bx3/de+clYLfvvEndIsMMRWg7OzDguxxgfOlKxHXHzmru
jsRfiVRXUVd5UthFBhMgacNwmvKirTFYoByPM4HgKc3hcA8Xi1OTvWqHLm+UdOOxrB2Hawruyyti
+Ddc0FEsd9wS8oxT0/OFovhvyh3OGcSAeYEPOLm+DoBVhDP0xaUH74m18UcyjxM6wNu/AlBohP6J
Rovc7dDxo9HzWxIUaRFBkehEB5fARtuxrI8Nd6l9TrQcPPsW0bEPCmv+1udYx/Ds2vrKM+Vn15ZW
XRwFia0tzeaq5Jlja2vfXVk94Wb31/9Pbw8+fI0EMTKaJ9YDdhFjyOEASczAGYQPz8rYcoX93fHC
UCyC2iI6G6rmlSQtB0zXMlqKy2iXzFAsElLvTqNdrvrdXqMOxl0zryr5cRC3hNphsCCHfrOeD8W2
8WuO9mCBzMyC9lV8MlpTJFPoQGAKchAyVYp4ECNOJzT0W3TDahbW1k4dZ/xb+HlmdWV95fjKqfL6
qbXy8VPLS6fXs/pT7DkJ8dxI4HQxVRZBjM3tskxOIGo9vrS6Xj69cpocwcC0bbhbsC1ZiAM0TBuH
YLgPlXYX1AU54OJiZHuO0oqyg1ldupxktsSo+10acD3iP54IMcIFgbyskWmlgPvmeJRhRtuDOY5g
26CUnKWIS5zOyUFY5L9DAm+0BOWy1e5TS+uY9RfhKLAHi/w3hmAcLQMDSL8QghOyWAQd3+9CIVjS
XncbCG+LzijYgtqIWJIxmeRS1iwqFadEJ2iHPnoqej1IHq01ZHi4jFZTtRlAHRNxr0D042gFYueD
jxJ6rs2TR/35LYipTdz/tnp6CNSbpaXoy0QjvuMeY18Z9LOAzIZPeGGjig5ysFB3zfUT27wJre10
sQguKfRS0cCZYtECxd0O2tutoB+WZePKepN2raJu/CHg5meKU3bBl+gI+A6JBofkpK31X2FRa14m
QFzUHOUiww+Gsq+tnSxYXyRx2chGWSCrXUYfocKWf6HW2ISeUe5ncwRT1t+YFH5w6Uf3b9waXP1C
MAGkoAONnGAUfvr6vTvvEny9GcOaCKeOb3rluZgAOQnDaJWhV3XT9zuZYmE2O5HWXCUfga/IfNG5
9/vXMffRH1VmpwguDU9jlN9FkcFffoHZOIHNoWxCe299pAPHSbxamWdaotTKTFiP5jBGnVN7GXRP
qSLimgpyuT3fZldZu3IGDudDrMQ6xA6zfBSYKmjYQVjZl8wE+zWoqPejtMIumWkuI/xizGmwMDG+
luor1lDFVAYTtkapwBftDWuQ+A84udV+GyJn3NLCxH6a/aUbrM+IQRwEw+6RR7QNITNlpImhWrSp
VWyGAyywMBY94gRwmPpt76/vAY6lVTsnlQtfQgVn0vambogCjvy8162FhA4EYkfBwVBiSRhCBx0a
AWXCE+TfFxUEQQd1RhFnaAQthMCjRVzPwgLU6urabArVj0pAASplDmq7AfJVuUNzsOHmUXd3/OTq
yjNLwGNi0nDNs6FEKdoU8aIXbZRiK3qUqkP8wrVYI/mfV2YetDOL6OlMvxn9Czf3ePZg8RDaTdCC
wraTxR2kC2RDgbQmPIb4inCrlYeAscWpTXfsd9AgRSLSohI++J6SOgSx18dYKUPHehOEEKEQFFmA
c46setGMJGHE3sz0TDY7Xu1JdeyZ5TNLI9Un5kaP4UHGzOVJbN+6fHbhS1knYoR+NJUZzrMQRWDc
+uuvCiblwcWLg8u3kxtc4WPYlRMTKWhmkOo6TeyMy5za7kr0ULtnYV1Z8tEqIww1hILUWhNnuFKC
QkZN2D7OR6rCfsykavizSYiRePKB9aXVZ06tlJ9YXfmu2IYoGGiI2XKE7eDYB37A/3U+sZwSX4kb
8Cj8t5n5w3H8/8NzMwf+v1+T/++TDQy9r1EamW10zqHMOOKgUrKe5OoA+wUdeXokigvBCT1nEQ3R
QH/b7Hb2gePWOV9LceptbLa95pcBcltdWVmXlA65Dk2qkynipOZcjAPGRSkjhi29fM3rnm+09VQ/
nQ4q1CPZGPkc+T2bczLuU0EAUDt4EVkd84KF98i4zzSq3SAM6j1nqUbG4dgVrPmJLnhPPqGS3cUu
ZE2vJZY5wWzNOJnHotidEGqMoUyYtxcSbiui8zmHNHJQK4yFxe2IoJeUwJuBbGGPOW5B/HXxNaiw
FTLzpFhVK2uuuER12tRGEo1NAzmI8LsolMYOlGbGgILfSQSKo7vgZNyqNpGbOFN5vOTnQ3RbS1yn
rH/0kFpWRg4wHAHDA8xEMeKOmS2OQJ5SlyO6XbuxUXAnw7bXQSwbrSvJUaH6baVlkg0FG5BRBllU
j7VBva5vGBmMKv0O0R9EVleGF2Qk7jVApkZe9NFWk/fJQoJSDBlRVKsSbtaRqr7XJW8BsxLW6uTx
LtmsXOmTLqe9659roPQnpt58urrlgaNxvuWB/LOhQ6nzLeTl6fENWVyDaUBzI12lGmU7IE4QG4wx
rXqJbiPkAi6vNYuyNfaMPpziWYI/ji6JtYkJ/Rjmk5rL4yNEArCXiu4pE5+Qidys3YqrnCyN4Wcn
oSDoSVaizG6gGWJhlSlIHShdv94XQjekBRRMMOi54HFSjIGtJxRNrQQXhCwHQ1Bjw5B0Lt3yQq6w
HXASUArxDVCvS3A00Nla4BNAtOBke41qowPqWVGao7Ul/i1jCpPGbxK+YFaXxNGR9PaXLVqEIwyt
FOfFus0knjRc/5/2t2O+aFIKw9EaIwfLg8uvYNJV0KKqfLOgJ6Z01mqYAfnx3V+RtEalCU5QA7o0
dE4Jv3SwWnk11jcQLgd9x0ALRHan39T0/BbTwjx+y9caiIkeDFNEoDbBR/8Sd7IfdidDIETtgOJD
cslZKNkl7P1NRUOBpBY658v9BmaJKyLkaXR5034ZkokKsoQLxrxDq5BdJDLW7rjJC/Cb0oMPz9Wg
uwvce+MPDy6+AebwnUQPdxk0UtfFC/lcLJr7N3+esBdz88UuPrO68gQG4Qg+LvR7Tt7vT/RbXnjW
Kc7PT1TFQfFNUGa5E2DnXMTvAE+94eQvOMkjxCk9DgYZ8uqqQkCV+03QtrVVF5PP/PDRyfgpmkWr
6iK9mp6QRSYBFCBou487qIN38h3xCijtOo8/Thsu9KoT9caEWNToAPXNTOss8IlOvsZFJ01WkPLY
F57jjxgpQaY7ziFx2Oa7dSefF49xZe4hZ+m55XUuAPDdztQh5+SzZ5zl0+sOiNgT2GFIbevVmqD/
yIsNEQJBy292+tqvmn8ONWr9EBSK+Xw7yKO3WB5oI/6U55jRTOd57GRUDyg/YU+2a/k2uXSAP1F0
H9w6xXZv9/IE5svw7HlMRgGgjFHnorr7rU6+JgjFISi1AGquya1eq5n7dq/Ra/r/IzZ+qKT59iTd
OzQRxU6RlV0m55bnwxA+22RsxH720WwT81FM6MrG2fxDaXGqz7IQaaDmze6ImkfWbuVfRu/7668g
9K5luwOOwp2fgHcgekuJYuJ0UPp2Bvi98vbgzu3B9atYz8/Ap/bOT9LOAetZTga3iX2wBDTnYkbl
vP9nne9HBEcQ9hjmVEq/UuhVcYJwxGFyFsGggKefB1sJnVog5F8eA6MXUspJ5baDSlDbdve7khIM
AjkJRejHaiHc/DkpayG0AyGR9XOCeQdzPzuUx2M41zAWGlYskbZByCBVFJKfyV6rQ2ZPOFyTfQ0A
50ywrBlkKWIneC52dKfiJHT9dg2SZEfSiynISIhganKGfzIfQ95JxHvYmI99bJ2HbYfJilhaJF1d
KEdsDBPe3qtHZTW6WX1fTNJQUJvEEiTnfsGcEuMvViSTqdevSrok3fbAgNOiuMkNV/xG/rIB/wJL
gKY26oOLRiV0c4maR5YP99TKU6ePcen4XRtr6p45tn5yERk4hQu7gD/xC/4j2RdXeUGS55q0PhvS
Phjv+jGtANk9Vc54jFCmRYHQceJevw1wVGJLbUJUHi8yDqhjSgUUieuOaE+tG3TK6lFUT7lKHZcD
4vt8m0YGNw7OoROB9i3MlJ5vi80GRjhk8sMMlQbzAWyt7PNtd5i5zA0gzXBPFM1oj9DFPl/sq4ug
ZTjXiUADZ0q5qDEzC6Wsm9g7Q0EN493PJRcEaH/MtW3RwcUKQS/ETtGWZEnfbhtqiqEZfdfyViHr
uPEatKMS9VEcoo0bkgIrYIcY+xJziiNETtjDtEIFIMoIJaNTkGxWapXMXDobcKlkJPSDCodu4Jc+
v3vrlcGVD8mWH0mYEI1DSkw6RXTJVIrZSkKNtrUK8ow8iB+SIRhBefUx1FEI+fXjkViDqiapNo5e
jiuNsHyHFxs5k3iLCTrAKPW7OgT8CCfD2YkYEJZqh4mGRS/R1WoR+m3LuwAJidSb8ok3ZQ3vMeCR
1FOtRjszX9SQakHti1GF+EZRGTZMTzSV4JXMAQdHgGh5y3FUnqpD/OGihZzTNRxr6mtq4hF97AuU
FQV8elUrdv/26b9wuiY3m4K7JLh32gDAdSkvv3cv773zx/s//iyW7B12CGjG//bp25zWUL4+G1tY
OByk7Y6PRBz4fONRWcIVIu+WopIo7+ccK0vmEmJ8iXdrwPZ73e0B3dT4LWKBna8topdv2Ks12mmR
8FbXiaQpG69PjPTE8Lq9cts/L0Pbk4EsODXhoss47LacXxQDI4sCTy4BdUXP+m30B8hYA/XlOtPa
vU73lxBHTQyK4NorgdetLQMqcbff6dkWWTJ/QVg422g2O5sZWW8HDmmyhRXWlp8C5UJivZ+hsqeC
4Gy/Y5EVTG/PhBg1pNeziXeldnkMMXpk755ejjsxjNnDRC/TOmYCLYTISLWrfsYnGpGctYUhPhXJ
HR+5yCKre/+jS3tvfcTKOMxZZPjEXnuZZCw9xoUe3Hvrg8EXb9mkLmI1SU9rpI11x9DKuFJBSUtf
cy71BD9pRYmlzWFEeWEszJPH1o+dciXIHTaA8f/QvR0sC+BqKQuUNHBryFgKukbBSEpCJ96e3ViY
mi4WS1CVfCl5R2k3XIAgeOMjwY0ougljeeMTd5j2NGJZiPD+5XeDW7di5Pdvn16hnEl/+/QlMe47
1MxdU2GK5rj/EvZ/SCJSFucIMDpfFQTcCP+P4vzUVBz/bWb2IP/f15b/j4RIFDY5N6mQNJ/pQyqY
tsT47BIqTAXdQ8DABgtHbKc2x5hI/1nDAyQG8jaOFwhz/+r32U3DF8T0DBnqC+J1DVcQ6RoCUG8r
9Xqj2hCETpwUfs9ZPkGmwrWTx/LTs3OUQRYkxmYYqG7D6JzZ7m0F7Tx6GgM/1WxsbvUKE99ZWl1b
XjktBDasDzkIajeILGVQmmdkAk/Ba7VoZPMMMhcWehd6ror6kuDnBqWdWF06tXRsbWlNVL1DNrgF
ByVofGMWdGcQjEJRjFQgR72Tt9AcRbl5KDW2Qd2p4dndKGqbNKBlmCuViUR0ROVgikErPfPs+rGn
lk6XT4jjoHxieXXp+PrK6vfI3B7PWsID4BoYEWhyb4RlrxIGzX7PgL21AAhbX8fp4zn98J13Bzc/
uf/xzcHnP0lGSEJXIEcKUL4QnE14EuGinCC8qYwXQRf0mGXeIeQ3shCXoDWnlEROvzS/FIsfgwEm
l+ISrpxXxJLiRrmp0e4SgaaYkn4xlZsb1k4lnMWT16OKkDwNLE7OcJtHWwY9KsR/Kd/gzigDAJZc
B4wAB3uLaUSBL2WyhWZw3u9mZEZpxPXecS8cmSvPzUDwm9eqiS85+cW4AsX5WrfF1/CLurKLK5xf
xqnGKXkIxhPpSovd8g7UxwFEpNGAgsxtyV081MRLARcPLv4zqe4d8wXODjcETT5KvXL96t5fPrh7
53f3rr/Iqparl6JFz4TAvwCu4WJTM0VYVA3aoHaW9LinutwHZaY4u+VzOzxvuwVBXgubL1A/+90m
lpfAjZuN3la/Auz2pNxKjUB+nZRkb1I6nkxG1U5SvDtV63UaRrXid0GrWgh0QTj0BUTUJnfwL1cq
sRmZRMaGRHrJix7l4P28Hjn2Fx1qzkmR2/qoytnEAxwLIdRiv5BaUJhXt0IGD7E/fK9lgphXMGET
RZt3M02vVal5C1wSc2dkporTM86jDvwRpKDixl30qC0FMvdmsD5FePmeHsz4jcV4z4auVpowZ+83
70GUj4QoUVpAhi658Yu9Nz+JLUzjpMngEDcA5Z0GWcfaUYlk48fShIr6MmkzPZAkXZwUM9rBIxcA
OnfpxEhrkMzi+hDRf484a5jQMKBcRDUfkDSIj4LTgxr3OAQ1CdnDBycm2iqOaAqEz6u0y3R+cX6i
wnhJacDMFssvKy1zBR7hPC3Inp64hl03Ze6aVkczfdGc6f6dMIx6EimUKuOTbMNo5MAEecAfWz1+
cvk7S2a+Vqwvln5VNQGbhyWGpcVQIwoWpSr4u0WJdfLiKOxhTNIi0h7tomDayKFJv1U/xcFYAIoP
X6fdob5OHJGc51MZnjhCNbS8C3gVfs0Vi3gx4Aw+3MNYhjF0ErFwB4/KDuJatmIOxcNVCBLJhn8T
ix0hGCWwHX9x2Xmq0QPM41Umus6xM8sOuRkRAtHdW3/k7Y9nlNj+Y+IpmQpYBQU1pKNu/iSM2LEq
MDcLekqCyUDs8V6eyKaLO3v0kMhhkTBLGoMDvE18uJDBnhO7f34+xemYniCPiOi5THp3h5WNnUn8
N+1YSiRSjSKPY9yuac0nIYrOKfUKt7sgjn6kEEwczf5W+u1a049IJ2zslt+qiAPMfFso2QhrQBpV
IzhqW67oFLGAhVZ11LAfhMYeJSPTsKeyqf4FcMrt4SupAdjPKjun58whgW9B5Z8Wo9t4DLjdH8oB
on4m2w5nO40Jil8ppZRXNBQsEGO2KJlKTLFEd9LHyOgkD7reR6qA2I+g362iXRRywBJrcoFZk5rB
B1hV8WTphgx2PCoZWWFNpcsZncdE4qRiG5J5xFO4kJR5l7LyrpO+AuhN1S0xcRk8vrPJ8GuTu8An
RrWJQduAR1eN09pACkgioYCv+s6fSS1sti2Zwpc5G0um74fU/9iUEV+v/q9YnJ2Zjcd/zc8ePtD/
fR2fYmHqSGFqAg3tZZSKnenD09PTMzNzs+IkOzw7fWSuOj9/pFqdOXxkZurIdPFofXqmVjzszc3U
D3vFqdmp6pHi3KxfL9b94vzRat2rF48e9upz9SN1WS2I0VztbLHoVKoVT9Ts+ZX6kWqlOjVV845W
Ds/PTE9NHfHm5mZnjx71qnNH5+teca5SnZ0Xr/CqR2rV2uxMsVY54k1Q/JXR3MOHRXNrxbn6fO1I
vVr3jxYr1Xl/drZaPXJ4xpuui/+K1Wm/6NWP+uJt1cOzR6em6qJTM1NebXZOXKrUVb1aew/Pzjii
K1PFmam52lF/VjxSr836U0dmDk9NzYg7lcPVWW+6ODtX8cTfmfr8XHXKn5ureUfm/Mrh6dl5f/o/
s6Wg32aW/yvMADN8/8+IvR6P/ywenjmI//y69P/rGIV0HvJj9LQQm0Ohkre7jler+RQkKniigIHZ
toLQxygkwWiS3h/V+wwSpmn4Y0lX+apguNvBOMlhYplg9hFJ2vVTLAc9r/dQEaUvNNiKIDPckHVV
/jSjqVWDKMYoql6a3CDg4tjxp4Wgi4p9ymHidXrugrPjbjZQMuy1+hdQKVmr6BGGRrQhh0q5uyR2
ut1Oy1pFu9YNGrV8LwiaoVGZfNDrnH24B0E32W96iYfl/aoXUs2yKqnQjOo0gynlg+BgiQ/qr9yV
JpcyOHRSEkcIbACGlhIulh57vmD+zfzDwkb+sRL8oKyOhcfypcey/yDYLcJ6sFWDeRvnZnaVukrw
g8Azh2HEApJQzNdGyLX2BMTSAw0hnfwLVfEACPo6eCIGGkVJ24XYCnlRQwcQX7blPuX9yb/0bNWY
eMFrcoVBHbVOQgKUT07yEqX08KiCKkBi07Z/HtzcQ8hH2qYk4uBH2PZ9QQ5I3VSvURYVlBc0Sw9a
OlbKqydWTp/6nvND+qUsNRYvHB3Xql6LoVpRWlQeGXJh1O6vncya8awTVsQ+cB1HlL56TVkaWmJQ
y416Wezz3rZu1DHahspaLJsxDChPipE6HfSehHibmDeK8kLhomxqsTj/QNfgSgEJogodw1+FpdMr
60vPnFn/Xs7hC0vPLa+tW91RqEusydW6gvbMfSujUXgbSxmNJcdTRmNTLLpolmXotqaOlvji4oQS
26VMAMy9zNkG+JuRqvbRHHtDywgTw08Wz7e+P4nXKFzdOdsOzkuz1eOcH7bRrgO4AaDjhFuNDjnb
eEDfz/pt+X40G0LIGJ52PHfQFnRWRcKtoa8p3zu31jm7mf9B3yftYP67pDVc/OZOrbKwhriHefqz
K1GrJ1SeG1U9EnVr9XBH017+oN/we0MqQiJvrQjuyIw2WBUJ4EPqIvJsrQxv5cCHN+y58lldVaQX
rnT986owOUk7jzk0zW5+yjVclQ2neq5lo1gyvOpPCiIElaJDfaMHaLOQ+asSBL0QwvU6kVUfzqZJ
PsAilqdgtXtCE8zVRqHYqhE4KtibGAZkmh038p4cgchtxbQ6dbx87NSpRfe4RHmQk4PBp7wwYFrN
JAR2k+3weG/bUFjrmVLRD3ZMb3NcjAbLNSPZiRxzDg/desjTKpgx6fMgJkiiPk+62Y085eFFvRrC
AATnMf+KabWOebxp1RmqInNP4BiYoObotwaOHTQORvorcdbCY4L57urxZ9t+r+Da4/DNsME42vjw
uXHbgSRpoei4OLxcs98wXWxTH2L/Hw6aH2+SBHgdgnyGqWAkDKyrhiGJ+WCNONQeJwQPRO7OIzcD
K0msyHxUp74O2cMD0cHA2V+pHIHWs0lJd2ChcCBxjHYZmuFCbTPNMea5E0+RlwrGTaNbCNRqHHs7
xF/4YdA8x++gxkyyzjF0cX1SHIfoG9SQg7dmdTSUyHVG+vHIUAhoOyDstjocNgfBLuqAXEY8tjpR
QwiZgRgB5Dg59l/CkAmeEA/LetAUqwOch86GlNOAsvShD488Gg0GipOoQaWFJkxSJmtR+fYKa+Xl
NcEkZjD1WdhDuO0s5cemCxCB9o1FaD9cxfpEz1sUSSwvydD8aEhHY/Pj6KQxSTJDeIPiL6DuyAxH
jq58O+5wjZgvfK/QCRIp8ciNBGcwPi7SORmh6nvlmn8O+iUHAn6K7iKfp6AIYHPL1cBjkk0NPE4E
cNaBdcYOSt8iMYBNEml7Aa6crODqtAZFPxrtIPoBsxb9wvAy+WOzUStNJNI/6TOv1WFpuxxKcS5C
JEYoBGq/Rm0FphQ59GzMdTxh/I06K+vZkK8FREutI2CMLbfDUjaOvt3qSC5Wg82jOrMKyh1TlT/f
ToauUQU6n5uUFOyUVCZCXQW3zA7bZGCrl8sQqVcuZ4DVkYjJ2gDC5UIchSmisREwQFiAHrnmg+z6
t6M8zRacKUhGwocISOi7OeVOB792jTQZ8uWwMMPtFlCOkWYdl6w59298CODYv7h5788QHfrgZ5/v
vfqBgTGd2gnTmmK0w25akrkeVTH7ljTI1erSUyPJlYY5rd/FZAL/3SkGxenpccyb+oBAKNFLF/fe
een+xUt7V97ce/fHD355ffDpPw9u3XqYwcGZ9s4hNKmWQiUaCRDvyphRAVd3o7256PZ79fwRN7bd
8BEhyGF0VAbrtBTgBYW3CcH5H2FEG9WW39sKampZxyoy+MAMispR7AYWyWH2Cxzm3naHL9JRLNcu
BEWGLGdjHlcssxF5UWLykmTUCjl0xl9IdaudkNUakF6cN4osPHIryBw4Lw6u/ElfBQ8z1QgC57Ua
zW2S65Bd4iFQ3SgBOW0lN4gYdXpW6imUAjPZX6w8h4GNdvMvSOOCQbc8hi4vNIZaxiH5rg1qQsmA
bMO3ZcdxE6i7ESaONpaKJS7sUP2QEAxyYN7/7ObdOx8Nrl4aXHnr/nt/sIymYACo1eiwEfZb2pDy
VKcMaNevBt0auERBMfJrk9XZYbyjgZIv0wZLFCBtZqHebzZbXg8kZC42lgeFfWTYzYyGgyzY5Fg9
eP2qdJtPEFvmYV01FvEkzIJDlCRgQxYujegzPsW75qH7Q/1ghj9JB6HtxP65FCoLDQXhLeLGeUHi
rdS0nPFm09bnmrMjZg2f2JClSymuHUM67BwnnPHjcMjETg77nMm+R91M76LpDciNVQ+WsvGwungB
7n16ngxJ3/lFPEyccMEQdnBqnr9QLNJKE6wrMz+OQrsER8deuJGfXkDanpGrLad1Nt1DJUnZtOkk
94v4dOr2ieSk8jOl7N93Vu/94aeD29fuvX0DgLlfv0p+JfYpVqaE5RPDZrmBkmFvm2UY0XT9wdIY
C1/WwMcAjA+EgMvL6G88LQ8CPLDb8dO57XzbKRKpR92zfPTvO3Y4anu/uSzO2CQlYzn6WUB2GI+c
6U/sh6YZQxEts7P+doJroRkRd0qQnIdGSPwi5YfgNdGoJv5kvwTh17ohD0MrRktcitY2CIiNa3A5
uQypNPcKwSlQaxZnm6DUCGqJZf6+Hb17605yUSi+FKYZueO4iBUxrJLNzU7YEZIwlYXyz34SvfHQ
e/A8YyFFzLf00675kJKXDBygEY4x4rYgAt3pE2k1xw4kGQwrBVDSbdSfHL8DGhCCxhqDdxZjAEca
gAq8Dq2gFldXIRnVwSAum4W8T5DJWkvGnOHU+CSyByQzdUWufv02Sp+YpLO9GfnlkxASM8/K6Q4q
mLiuLFlElrIjO5SOoMFVg7ysVMsGl6oyaeo8LdRVspE0UuqkG8Bi1i/OhxaSUnQ3Pd4/spSmjhq5
fdj6IfvYGGacw2ZAe3bjOx8rtoXus1J6MZISdaEk9QEaPXiMFEJYv5hqitRjth4JKTZuo5S1rDB8
JW5sbaMruEJggXnahwWrGAErWnS1NXYFw63885BynUIFSRHIygnd2VNHkE5UmoieQfYrEW2BzJbl
aVMV659fsIvrkSij6wdZwZotYWrNyPQ8kTayMa0WhtKPtfeIZ4sTXXGxXd1SrGhSTY/gosTu6f2M
D7asJztsk8QSVSNZatakZzAsW1TlL4gO9+JKSV1Tj1d4PnwZiyu1+4YdYlfD3aCYH7wh32Q8aDRF
vk0qur4cIYCgGx6gISo8Y+2r8mqNJMpq42YEJNn4yqhjsY4CeUxht7lSIkVQji+oIF07CylZuZ1I
OMCQu4z8CSG3zMMvONpLdtMc+FVjpdyoz2W6Xz2rI+XTNm1kot0xFh20+ZrJIKd0j412ULL3Hgz8
PIsSJUQb7w35pbQwqiFSdo0oQ5yipdAZqQuQjGR6+RhNUe3XF2vaVNtfuCObvSAbrSjD7ugTYxQN
kwY5MKzFKRmjj3NSBoTRzmIknZGhxY5IzgdJmeuwnSZovhkTRHXUO8fEVMU3IwNhWquTFpmopOFv
gF5feGefVPlhaNx+gFrHH6CxAFwTkEV2m5W2Yg35EpctSHwLCTxUlAAXYmCdY6ZrkxGLkQS3kG5R
jiEpMitBC1JpeUbsIA7+bwU6p90lSxdvFIKiRC8CvGxnERXuI6Ll8XFvwgcyDqJbC7zQtXoWuWG/
FnDKBPMGPsPnN5UqKbA9YjClWpdgjwQRoXZLHbBpx0DPkdHqdFmnpkpB7blNQU7ssM6wy6f3ZXUT
kjAmf4yMD7o63BT/mf2P8AnjOVVkC5KZjBHVIV2KsNmLfYlnOZa+n3pAIVYOh6wDxhaB8r380d7F
H7El5Ue/Hbz/CgSQ3XgPsBQgtx2j5gO29pU3CVsk8rJ18vmzvt8hN2arrg1ba4ulxX5KSMFkJhi6
bz6I7sccfzt45RaG1jOw5t6bHw5++ys1PX/79F8QRfD/XvwRg2txhdlEA1McGCNfOnBfVOk62JXY
Ob/lg3uVA+I0km7lI+lDh0KIbQeNDjkbiwlBybdgqX4ZUW9hBfsXOsilbfnqNb0AZMUGBPFC5ncp
H3oQaLx+CJqDzGUXqihYMiPqAIhMEwRRhB7JmG2gNoDIyuNTSjITKS6Yo14i3TLHrd30yxxVO/tq
1jBj5zjVx1w1R9UvXfFGDpDtoLK5dqotE/fvtFc80l/S6g8JTlZPrC59t3x6pXzs2fWV1aVnVr6z
tOhOucl1P8R3bYj2UNkCcftB0usbgi5cF1t/cO3m3S9uCPJx984Hd2+9/OCNX96/eTNGPtJph3P3
i3fv/fyXg0v/C3ABP/5gcOljk5yImebTL6Yqkieh7RRt1MtBt7EJ7A7DlsSsgXzwxZlFzXs8xl1p
UqySAuVhlURA0jUCoOqXb4+qRpKGCQ54AK6/uvfuB3tv//veK78FH4c3LxM1I1C+hCuNgtCVer1o
AIYYVvXQCh4+QacDgNf1JEmpoVm34BxDPze/JsUwLQwDfIu3xKhzbV6b3OA6W9thAxAvJGC2DMNo
tOXbQgBvrPWr5IUsM7Kx6zFTSVb3nEmahGOAUzFTWKGANgqpOBbvMgxksiqHNQcUVg45tkwkgGHw
W/u0Eifgt0jpoy9UejbG7NWlb4ZpWDdZv3T7Og+gbSXE3FLkomZEl8gT8xuL+g3LYaytXLaIX3vt
3hu/Hlz7xeDqmwjjGQV921axzN/baPcNX8R2zevWHOPt8o+EAVDgZUM0IPrjCRaD3ZjwVfFkGCsQ
4UdzI7ZEO2irNqnVDQsJqkEfevS17Xcj4MBYfdGmCQUjLU5ywZL0EOC+6xco9zftsqhgxW8G7U1M
EAbpNjA2Y4zUGkKiQACM4erXxFTbBDY7fvQq5CJu0a/s0PcnDNvkgka3hy0tfXl99rPBS6/QMmJ7
FDKz9967cf/G+3t/eZ/WFuy4z16599kNSAEmV2TagrMuutEnxoTJ1VrWjSWcivuXHbOcKm5QB1b9
ojKIh3zfel/Ts8HuwGEZA/meXFyrZT2JNI1mimPEhO7coDR7CSqu7uzbc+GhPRAsKMaavVyJS0Ts
ydMwIuyaktMkn/Jq7MQ369YdFz7+Kx3++kI2OSGTG9HHkPTqQA81A7SuD80mXNLTlKuQ1SxVcYoo
aRZtq01aG9LR+7/9097bXwzta7K/YxguxtHBM/23avXReVJXyOsTOWKB6Tp323AQPTNdMSgjEY7N
GNNvUfepXigm8EsuDmINA4kTS+o+hzy+BdvUh/yU/Uro/6APo8PJb9UI4aFm6EDQz1/Qm6g90i6U
sLOkjCu6pEeWDPxpZsBFksaXhxhosIgxThaKrCwdowoY5B0FzoTr3FDyqsZs0omRJgvBNc4EQ5Wu
nwyMXzmW3nycTJ4R35SqxzV3aMbIY/KNKI8Jwd1FeshvJFMpscM4dx10uqU4dY8lXopKg6pXdxRM
MKi3/3T3zmcxBpX8eVgplkpnjXGKjeyodFc8atHBkt5CSmn5UC3UrSe21C26SgKWTE1l6bXQVLSV
JHKz2p2aMKJrXK14NFlRDSWrWEEJ+pQTkp74k5DudQIpdZqDay87O1Dz7kiSyeMh9Y+RKkwiVPIg
KcWfV0UayDjfIQrGSA0hQyVIwvVGuxFuOV4dLoJQIBPIYdA9C7UJ+D6lz8EQYzOvaxyMutpsxHCX
96GKgKsM3wE3+Ktd06HZq9BnSz73/UbnSfUQwruRa8XCRNx2XHExgpySMEiUEsiD83wb/s0Y2bP4
pZkdzsNS6GCgOONEitEug3qKr5bLUEG5DD93RU/wHOpJdD48ItDiYHFwgfUvy4lljIimRn1Z9L/C
ICiQMMFTkyir8ShG+pvPQWkqKYm0mFzyvc05oOQqo5Irmjg9IkbBRcdjJ9eePbGCtFq8QMIiUGos
F1WTgvAMzZcLegrQpiHfKrGS0f157SQnyOUEyqRLf+2zu3fej3bOI2KJdyBZdtAPURpGiLSaBovT
8rYdr4mpNQQBAjwNwRg0/U2vuo1gGYUk8UQIBcHIJ2KwQGw5K2YggmEYE2lCnqpUDeJd2obeEoGP
axteG0t3pCFxwD8xLI44WRnv7aZackRpTl/UbAyV7miz0DYK+ugUY9IK8b9UO5GOb1HGzUkXcTo6
vLAclZDaJcN7hms5F5z1SStDWcPpSjlyokK1MpayHXJ7r7//4I2Lzg4X2XX23n1PLktYknuvXtl7
98fRApTHCq+ZaMnIoxeXjF40LCOxNQzpjbpRkSX0LaFHSdYm3xj2gk4ZVDE1mXIpNMbyK8i+xeMn
k2VdAvjEt34P3u0yXc7dT//l/s13E4m40ntjxLADZdGXAPog43qC+Npo0CNyTBGSWTWScZ7Lvf/F
L/d+cZOQ3ONBe9R0dMwffPgind+g8b59XVfsRHbWay/H0vgaQne84dCZaCMliETCqh4vENPDmrAL
kdqV6DPrIhIhTbrOxlTWSkeb1PYnX6J7OmQTHTKkAPNdhotEdiJujs4kJjQXp8XR2zIGsHU21YnY
3G9yxUX1GBtxRCWwBDW0lGbDlNpQ2IozrkDx0tlryLUaT8goOO29K9dV9AhsIlFJlO9II4Yj2mvG
51gk0JgIqZMNCfmbNm7Jo537AQyyVBzQKS62h9hjgkEGo/g7rwxefo+N+tdfBZb52s3Bi6/QqX/3
1sW9P783eOcP925/oXMARGMe/OgtkEi0jH1EZqLtR3tdDiib49kYKIr8f4H/d77xgtetfYXgj6Px
X+dnDxdN/Mfi/Nz0Af7j14X/+J0za5IcXH9tcPNTTCV/5d6fbt7//GeDSx8MXr86eOfDwbsXB3du
379xA9a2nuKp1+sUBMEAr12+1Oh4tVpXw1PU8Rv3kcGp320CEEcXlGxhLwKX1GUiKVnJqBshgUNR
5DX7IaQFLnNjMvyX6RGLXEB05B2gWv122PGr6DaPqpboTjMIOghBb15u9Zu9RtULe7Zwcf1xQQvL
lAfBvAG+D100RlKrsYxstK/YNKuDGnQWziM3KcCyD9Z4qYSiijCJcnoaoQiNSmYUmv7yCYWi/L+j
0YS4rBqeyNuM4rB9xDS0ITgN5Xe5PhAgOmpuOmrpYL0J/tam0LJa1hoj1mKsFVGeWVlMX7GqkITG
61eajWrZ34Sr6gVdfxOyobqbzaDiNeX6qAkpKhTLFZIuyqw6re1GR/RV/NP2e5MR9EcDMl9SThLM
3aGn4ZmbgSfq24Wgu+mq0Yc0QMBXZeRrcmYlhJ6FDUPzdbXNGGkZo1hONTM7bMpQdjVJREH8ROkZ
s7fIFXqYExWEHSGrWHx8KkFtm1CpsABpN6aLM0eySeRCExwDnsxuuMBtuqUNt9Fx0dUU0yEtRoON
fYSyyRRvGvbVmEsRm5G1hFNJekIzTlCg4yw6A5Wmay65kcKc1ITnnPXtjryoHQmFk+vrZ5awBjG3
2SH7xMS4wQjL/ib4DiFFz4ThluxHzokt7pxDi1+PwgILdfSIbTS026Td0q9oA0n59My05IQTbqG6
MIJ6xYKcsr0LxHviH90EBUuQfLWlZPsb2r431NKJ9lqBrvSJzUHu1D/vvXN7cOnP9z57jY52l4k4
bkPY7TSi6CI0hL4o3l0+mRgQeQPe+ruLe//7p4MrH4Ilmd59+fbg2u8EU05Otfc/+/Pg2mt7b32k
vIvch5jLh5oTaNKLl2LDEQ2vH1prVXcBfDIa10RF2toWpUTvBu/9afDiL51nvKoz+OTfoMdf/Grv
1Q+gFb/+9eD6K3tX3nSWz7hKZ9ZpbmdA2dXAkRTnaku5SBH6MF0Cf1/HllpHnCWLoDGNp9iR2eO5
aiR9Tcyop/MccCUuiS2tPGm4i4P0de3NvY+uJFy9KOUkEzrqkBeeLeORqnWq6VV8IP1+3RMnd04x
dNzNsF+vNy5gOjhnY4dL7ZbQcZ9/GXHk5JpPw0/4bNDrqBeSmsfHFpshxpHfBwP6fy7edkdnqFdh
31QzaI5giXDbsiPamR3CXKRoxWji4R14M5uYdjnasPaRhtLRIV0fnwDUd0hWCoiTYIQRpzL6dEMG
F0wt1hZr8NyckZxMnKfg0M0pYKUJSRnbEb1Xh7Xc4PAJugNu4XS9xNfdBTQT4+3k5ODfjamF/FRp
wjLUeq+0voI8YPRVtawR4sGb0dvUCGuNTUyHCtfA4EGPAqTCLF6bgq8w1tGNudnZw7MJkhCVmUi1
RpBIJeoUdJCqce5+8tMHb/27tEoIsUvQRD1DXnUrAMzqaI1iGqlF996rH0IUAG4/SBEmeAvY5vc/
/rf7X1x21VZanOJh2M82ELtMtHEH37Qryk07O1S/+KFtP9obRvZNjW7EZlXPvso7YVGH2ZLTRLq5
KRBF0N61DaBao6FpzcenEfCTUD/HAlDl1Gb6FAEVnia37b2rLw3e/tX9z/71weXLYKO+84v7N95/
cPGlB+99AlNl2Xv/7eBz8Dn4HHwOPgefg8/B5+Bz8Dn4HHwOPgefg8/B5+Bz8Dn4HHz+gz//DxQA
BmUAgAIA

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
