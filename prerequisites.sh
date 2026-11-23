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
