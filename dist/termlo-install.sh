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
    if [ "$manager_ok" = 1 ]; then
        if [ "$family" = apt ]; then printf '  正在临时下载并校验 %s 软件包…\n' "$names" >&2
        else printf '  正在核验 %s 软件源…\n' "$names" >&2; fi
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
                        list --showduplicates --available "$pkg" >/dev/null 2>&1 ||
                    "$manager" -q --setopt="cachedir=$scratch/rpm" --setopt="logdir=$scratch" \
                        --setopt="persistdir=$scratch" \
                        --repofrompath="termlo-epel-cn,https://mirrors.tuna.tsinghua.edu.cn/epel/$major/Everything/\$basearch/" \
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
            curl_flags='-qfsSL'
            if [ -t 2 ] || [ "${interactive:-0}" = 1 ]; then curl_flags='-qfL'; fi
            printf '  正在下载并校验 Mutagen %s 同步代理（约 100 MB）…\n' "$version" >&2
            curl_status=0
            timed_out_partial=0
            attempt=0
            for source in "$url" "$api"; do
                attempt=$((attempt + 1))
                if [ "$attempt" = 2 ]; then
                    printf '  主下载线路失败，正在通过 GitHub Releases API 重试…\n' >&2
                fi
                rm -f -- "$file"
                if curl "$curl_flags" --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 180 \
                        -H 'Accept: application/octet-stream' -o "$file" "$source"; then
                    printf '  正在核对 Mutagen %s 安装包 SHA-256…\n' "$version" >&2
                    if archive_matches "$file" "$digest"; then
                        printf 'Mutagen 安装包  官方 %s 的 SHA-256 已核对\n' "$version"; return 0
                    fi
                    curl_status=0
                else
                    curl_status=$?
                    # If the transfer already connected and timed out mid-download, retrying
                    # the GitHub API redirects to the same CDN and wastes another 3 minutes.
                    if [ "$curl_status" = 28 ] && [ -s "$file" ]; then
                        rm -f -- "$file"
                        timed_out_partial=1
                        break
                    fi
                fi
            done
            if [ "$timed_out_partial" = 1 ]; then
                echo "下载超时（GitHub 线路过慢，已停止重复等待）。$hint"
                return 1
            fi
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
    printf '  正在核验远程浏览器…\n' >&2
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
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
7H32Pv/f/Pw/PesV4ADQAgA=

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
