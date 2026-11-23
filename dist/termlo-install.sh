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
            daemon=$(command -v sshd)
            ports="$ports $({ "$daemon" -G 2>/dev/null || "$daemon" -T 2>/dev/null; } | awk '$1=="port" { print $2 }')"
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
    privileged=0
    if [ "$(id -u)" = 0 ]; then
        privileged=1
    elif [ -n "$priv" ] && "${priv% }" -n true </dev/null >/dev/null 2>&1; then
        set -- "${priv% }" -n "$daemon"
        privileged=1
    fi
    if reason=$(LC_ALL=C "$@" -t 2>&1 >/dev/null); then return 0; fi
    case $reason in *'no hostkeys available -- exiting.'*)
        if [ "$privileged" = 1 ]; then
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

check_sshd_auth_policy() (
    scratch=$1; priv=$2; uid=$3; user=$4
    daemon=$(command -v sshd) || return 0
    effective=''
    if [ "$uid" = 0 ]; then
        set -- "$daemon"
        can_eval=1
    elif [ -n "$priv" ] && "${priv% }" -n true </dev/null >/dev/null 2>&1; then
        set -- "${priv% }" -n "$daemon"
        can_eval=1
    else
        set -- "$daemon"
        can_eval=0
    fi
    if [ "$can_eval" = 1 ] && [ -n "$user" ]; then
        effective=$(LC_ALL=C "$@" -T -C "user=$user,host=localhost,addr=127.0.0.1" 2>/dev/null) || effective=''
        if [ -z "$effective" ] && [ -n "$scratch" ] && [ -f "$scratch/pairing-check" ]; then
            effective=$(LC_ALL=C "$@" -T -h "$scratch/pairing-check" -C "user=$user,host=localhost,addr=127.0.0.1" 2>/dev/null) || effective=''
        fi
    fi
    if [ -z "$effective" ]; then
        effective=$(LC_ALL=C "$@" -G 2>/dev/null) || return 0
    fi
    [ -n "$effective" ] || return 0
    pubkey=''; root_login=''; auth_files=''
    while IFS= read -r line; do
        line=${line%"$(printf '\r')"}
        case $line in
            'pubkeyauthentication '*) pubkey=${line#pubkeyauthentication } ;;
            'permitrootlogin '*) root_login=${line#permitrootlogin } ;;
            'authorizedkeysfile '*) auth_files=${line#authorizedkeysfile } ;;
        esac
    done <<CONFIG
$effective
CONFIG
    if [ "$pubkey" = no ]; then
        printf '%s\n' 'SSH 服务已禁用公钥登录（PubkeyAuthentication no）' '请在 sshd_config 中设置 PubkeyAuthentication yes 并重载 SSH 服务。'
        return 1
    fi
    if [ "$uid" = 0 ]; then
        case $root_login in
            no|forced-commands-only)
                printf '%s\n' "SSH 服务限制 root 登录（PermitRootLogin $root_login）" '请改用普通 SSH 账号安装，或在 sshd_config 中设置 PermitRootLogin prohibit-password 后重载 SSH 服务。'
                return 1 ;;
        esac
    fi
    if [ -n "$auth_files" ]; then
        matches=0
        set -f
        home_clean=${HOME%/}
        user_pattern=''
        if [ -n "$user" ]; then
            case $home_clean in
                *"/$user") user_pattern="${home_clean%"/$user"}/%u/.ssh/authorized_keys" ;;
            esac
        fi
        for entry in $auth_files; do
            case $entry in
                .ssh/authorized_keys|'~/.ssh/authorized_keys'|'%h/.ssh/authorized_keys'|"$home_clean/.ssh/authorized_keys")
                    matches=1; break ;;
                "$user_pattern")
                    [ -n "$user_pattern" ] && { matches=1; break; } ;;
            esac
        done
        set +f
        if [ "$matches" = 0 ]; then
            printf '%s\n' "SSH 服务未启用默认授权文件（AuthorizedKeysFile $auth_files）" '请在 sshd_config 的 AuthorizedKeysFile 中包含 .ssh/authorized_keys 并重载 SSH 服务。'
            return 1
        fi
    fi
    return 0
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
                        --setopt="persistdir=$scratch" list --showduplicates --available "$pkg" >/dev/null 2>&1; then
                    # The installer enables EPEL on supported EL derivatives when base repos lack a tool.
                    { [ -r /etc/redhat-release ] || [ -r /etc/alinux-release ] || [ -r /etc/anolis-release ]; } && [ -r "$release" ] || return 1
                    . "$release"
                    major=${VERSION_ID%%.*}
                    case ${PLATFORM_ID:-} in
                        platform:el[0-9]*|platform:al[0-9]*|platform:an[0-9]*)
                            major=${PLATFORM_ID#platform:??}
                            major=${major%%[^0-9]*} ;;
                    esac
                    case $major in ''|*[!0-9]*) return 1 ;; esac
                    "$manager" -q --setopt="cachedir=$scratch/rpm" --setopt="logdir=$scratch" \
                        --setopt="persistdir=$scratch" list --showduplicates --available epel-release >/dev/null 2>&1 ||
                        { [ -r /etc/alinux-release ] && "$manager" -q --setopt="cachedir=$scratch/rpm" \
                            --setopt="logdir=$scratch" --setopt="persistdir=$scratch" \
                            list --showduplicates --available epel-aliyuncs-release >/dev/null 2>&1; } || return 1
                    "$manager" -q --setopt="cachedir=$scratch/rpm" --setopt="logdir=$scratch" \
                        --setopt="persistdir=$scratch" \
                        --repofrompath="termlo-epel,https://dl.fedoraproject.org/pub/epel/$major/Everything/\$basearch/" \
                        list --showduplicates --available "$pkg" >/dev/null 2>&1 || return 1
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
            curl_status=0
            for source in "$url" "$api"; do
                if curl -qfsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 180 \
                        -H 'Accept: application/octet-stream' -o "$file" "$source"; then
                    if archive_matches "$file" "$digest"; then
                        printf 'Mutagen 安装包  官方 %s 的 SHA-256 已核对\n' "$version"; return 0
                    fi
                    curl_status=0
                else
                    curl_status=$?
                fi
            done
            if [ "$curl_status" = 60 ] || [ "$curl_status" = 77 ]; then
                case $family in
                    apt|rpm|apk)
                        ca_fix=$(package_hint ca-certificates ca-certificates ca-certificates '')
                        echo "HTTPS 证书校验失败（curl 错误码 $curl_status）。请先核对系统时间、网络代理或安装系统根证书（$ca_fix），再重试；或者$hint" ;;
                    *)
                        echo "HTTPS 证书校验失败（curl 错误码 $curl_status）。请先核对系统时间、网络代理或系统根证书，再重试；或者$hint" ;;
                esac
                return 1
            fi
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
except native_browser.SnapProbeDeferred as deferred: print(deferred); sys.exit(5)
except (OSError, ValueError) as error: sys.exit(str(error))' "$payload" 2>&1); then
        doctor_pass "远程浏览器  已渲染测试页  $browser"; return
    else status=$?; fi
    if [ "$status" = 4 ]; then
        doctor_block "远程浏览器运行账号  $browser" '运行 getent passwd termlo-browser 和 getent group termlo-browser 核对账号和组。请管理员处理同名冲突后再重试。'; return
    fi
    if [ "$status" = 5 ]; then
        if [ ! -d /run/systemd/system ] && [ ! -S /run/snapd.socket ]; then
            doctor_block '远程浏览器  当前 Ubuntu 无法启动 Snap' '请在有 systemd 的设备上启用 snapd.socket，或安装可实际启动的 Google Chrome 后重试。'
        else
            doctor_pass "远程浏览器  已安装 Snap，安装阶段创建专用账号后渲染核验  $browser"
        fi
        return
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
                if [ -n "$scratch" ]; then
                    for single in $missing_base; do rm -rf -- "$(apt_archive_group "$scratch" "$single")"; done
                fi
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
        if [ "$system" = Darwin ] && [ -x /usr/sbin/systemsetup ] &&
                [ -n "$priv" ] && "${priv% }" -n true </dev/null >/dev/null 2>&1; then
            mac_ssh=$(LC_ALL=C "${priv% }" -n /usr/sbin/systemsetup -getremotelogin 2>&1) || :
            case $mac_ssh in
                *'Full Disk Access'*)
                    doctor_block 'macOS 远程登录  当前终端无权限开启远程登录' '请在「系统设置 → 通用 → 共享 → 远程登录」手动开启并允许当前账号登录，或授予当前终端「完全磁盘访问权限」后重试。' ;;
            esac
        fi
    fi
    if has sshd; then
        user_name=$(id -un 2>/dev/null) || user_name=''
        if policy_err=$(check_sshd_auth_policy "$scratch" "$priv" "$uid" "$user_name"); then :
        else
            policy_title=${policy_err%%'
'*}
            policy_fix=${policy_err#*'
'}
            doctor_block "SSH 公钥登录策略  $policy_title" "$policy_fix"
        fi
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
system=$(uname -s 2>/dev/null) || system=''
case $system in Darwin) PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" ;; *) PATH="$PATH:/usr/sbin:/sbin" ;; esac
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
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
H4sIAAAAAAAC/+y9e3tTx7U43L/9KYaNqSRiSbbJrXbUUxechrcEeMBpew746NmWtm3VsqRqS4Bj
3Ie0JYGEW9rcQ5qkCUmaNEDTlJsheZ73o5xasv1XvsK7LjOzZ/ZFMrTNr7/3lDbWvsye65o1675m
6vWW32q6jZw//51/0r9h+Pfoww/TL/wL/+4aHn1MXfPzkeFdo8PfEcPf+Rb+tf2W24Tmv/O/89/2
bfmZSi3vzw/4XktkvfaAX283S16xXGkWBtO79xycmHqqIEplkc0KZzANj2vuosd3w07GEd/9rmgc
L2cGcvAg+DbfWGrN12vZZrvWqix6AF1OpETTa3q/aFf8Ssvz4wqU66VWvUlv/CW/5S1Ch9rcui9G
v58ve8fytXa1mhEnTwpZIpUaKLm+Jwb5XlRqYo/bPF6pZQSNxMnXG638fH3Rm2l6x3HsY/m238xX
6yW3SreDWM4R4+Nip/qGHnE5n77Av1TE893SgHeiUW+2VNmnDjw9mc8Z9fGDWmMxO1etz1it6E//
c+qpA/ufmXry8cKI7P/yyFh2Bbo/IOBfdv5kNjvvVRsZusV/jWal1poVqR3+0VpKpPx5KAugXK3C
fIkj2Wxp3istTOPVfN1vic7l6513TtE9tdi5drvz4Wvrn13rXPxAl8oueEti7dZq9/Kdzuk/bf72
Cr2hGe9cOr/+8fXplDiqe4D/UsL6B6WPV1rz2VLVbZc9cVLwfb3dMh/5S7VStl6rLk1HOt6uyRus
asHzGtlWvV71p1O6Ve9EpSWGYe7piS4P86Ovg0ny5yuzLX0HE+Y1AergL0DSbKVWLjKUEgAtC680
XxepzvlbG/fubV4+tfHRc+IgvRe7co+L7pnXum9/ufnZG+tnz3Qv/+lvp361ce3mxteXNt4/J+xB
yMkX3XevrF9+CcrCfK6/9RtVWefq2Y0PTndevre2+iHUkhLf/+7oOI9rZFysGCP1SrAhjF47Ivsz
0W7NPi6yP7S3CrxcrNZzjSXHmEJn8AcIpAMEpH6p6bZK8zDwxQXYGA2RLfO+kc9h41RmxRGRrWHN
/NAR0+OiNe/VBJ4QItVcFNnmLO99VSQlJn+2d2pczFYGqKduqVU55hWGuTZncLsjCrBeqiKzzAh9
xV0v8ma3RuUgwim5LXuoi+2WO+cBZvGqHuwUP9c60UI8lPdapXzdV8/NUchJ5GYdmpeBWWjMbc6J
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
++x99j7/93z+FxSjt3AA0AIA

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
