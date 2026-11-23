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
    if [ -n "$py" ] && [ -n "$payload" ]; then
        if reason=$("$py" -IB -c 'import sys; sys.path.insert(0, sys.argv[1])
from pairing import check_authorization_directories
try: check_authorization_directories()
except (OSError, ValueError) as error: sys.exit(str(error))' "$payload" 2>&1); then
            doctor_pass 'SSH 授权目录权限  可保存配对公钥'
        else doctor_block 'SSH 授权目录权限  无法安全保存配对公钥' "$reason"; fi
    fi
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
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
D/89/Pfw38N//9n+/R+rDHWAAIACAA==

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
