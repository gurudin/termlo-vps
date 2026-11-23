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
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
PPw8/Dz8PPz8x/38X6i+/PgAgAIA

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
