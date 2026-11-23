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
            stalled=0
            attempt=0
            for source in "$url" "$api"; do
                attempt=$((attempt + 1))
                if [ "$attempt" = 2 ]; then
                    printf '  主下载线路中断或停滞，正在通过 GitHub Releases API 重试…\n' >&2
                fi
                rm -f -- "$file"
                if curl "$curl_flags" --proto '=https' --proto-redir '=https' --connect-timeout 10 \
                        --speed-time 30 --speed-limit 1024 \
                        -H 'Accept: application/octet-stream' -o "$file" "$source"; then
                    printf '  正在核对 Mutagen %s 安装包 SHA-256…\n' "$version" >&2
                    if archive_matches "$file" "$digest"; then
                        printf 'Mutagen 安装包  官方 %s 的 SHA-256 已核对\n' "$version"; return 0
                    fi
                    curl_status=0
                else
                    curl_status=$?
                    if [ "$curl_status" = 28 ] && [ -s "$file" ]; then
                        stalled=1
                    fi
                    rm -f -- "$file"
                fi
            done
            if [ "$stalled" = 1 ]; then
                echo "下载停滞超时（连续 30 秒几乎无数据传输）。$hint"
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
77P32fvsffY+/9/8/D840XFwANACAA==

TERMLO_ARCHIVE
then unpack_error='安装包编码损坏'; termlo_unavailable_bundle "$@"; exit 1; fi
if ! tar -xzf "$bundle/archive.tgz" -C "$bundle"; then
    unpack_error='无法解压安装包'; termlo_unavailable_bundle "$@"; exit 1
fi
sh "$bundle/bootstrap.sh" "$@"
)
termlo_install "$@"
