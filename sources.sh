#!/usr/bin/env bash
# Used both before Python is available and by the installed Termlo command.
set -euo pipefail
if ! command -v linux_manager >/dev/null; then . "$(dirname -- "${BASH_SOURCE[0]}")/prerequisites.sh"; fi

lookup() {
    if command -v curl >/dev/null; then
        curl -qfsS --connect-timeout 2 --max-time 3 --max-filesize 8192 "$1" 2>/dev/null
    elif command -v wget >/dev/null; then
        timeout 4 wget -qO- --timeout=3 --tries=1 "$1" | head -c 8192
    elif command -v python3 >/dev/null; then
        python3 -c 'import sys, urllib.request
with urllib.request.urlopen(sys.argv[1], timeout=3) as response:
    data = response.read(8193)
    if len(data) > 8192: sys.exit(1)
    sys.stdout.buffer.write(data)' "$1" 2>/dev/null
    else
        return 1
    fi
}

detect_network() {
    local reply key value country='' ip='' place
    if reply=$(lookup https://www.cloudflare.com/cdn-cgi/trace); then
        while IFS='=' read -r key value; do
            value=${value%$'\r'}
            case $key in loc) country=$value ;; ip) ip=$value ;; esac
        done <<< "$reply"
        case $country in
            CN) printf 'cn %s\n' "$ip"; return ;;
            XX|T1) ;; # Unknown or anonymized exit.
            [A-Z][A-Z]) printf 'global %s\n' "$ip"; return ;;
        esac
    fi
    reply=$(lookup https://myip.ipip.net) || reply=''
    reply=${reply//：/:}
    if [[ $reply =~ ^当前[[:space:]]+IP:[[:space:]]*([0-9a-fA-F.:]+)[[:space:]]+来自于:[[:space:]]*(.+)$ ]]; then
        ip=${BASH_REMATCH[1]}
        place=${BASH_REMATCH[2]}
        case $place in
            *香港*|*澳门*|*台湾*|*澳門*|*台灣*) country=global ;;
            中国*) country=cn ;;
            *未知*|*保留*|*局域网*) country=auto ;;
            *) country=global ;;
        esac
        printf '%s %s\n' "$country" "$ip"
        return
    fi
    printf 'auto\n'
}

install_packages() {
    local release=$1 region=$2 state=$3 route preferred=system arch
    shift 3
    local options=() routes=(system cn)
    [[ $region != cn ]] || preferred=cn
    if [[ -s $state/preferred ]]; then read -r preferred < "$state/preferred"; fi
    if [[ $preferred == cn ]]; then routes=(cn system); fi

    for route in "${routes[@]}"; do
        options=(-o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 -o DPkg::Lock::Timeout=60)
        # Only use the preflight archives when the same privileged user fetched them.
        if (( EUID == 0 )) && [[ -d $state/apt-archives/partial ]]; then
            options+=(-o "Dir::Cache::archives=$state/apt-archives")
        fi
        if [[ $route == cn ]]; then
            arch=$(dpkg --print-architecture 2>/dev/null) || continue
            china_sources "$release" "$arch" > "$state/termlo.list" || continue
            options+=(-o "Dir::Etc::sourcelist=$state/termlo.list" -o Dir::Etc::sourceparts=-
                      -o APT::Get::List-Cleanup=false)
            echo "APT 使用清华镜像。" >&2
        else
            echo "APT 使用系统已配置的软件源。" >&2
        fi
        if [[ ! -f $state/$route.ready ]]; then
            if ! as_root apt-get update "${options[@]}" -o APT::Update::Error-Mode=any; then
                echo "APT 索引获取失败，尝试其他可用源。" >&2
                continue
            fi
            : > "$state/$route.ready"
        fi
        # Try another source only before dpkg starts changing installed packages.
        if ! as_root apt-get install --no-remove --reinstall --download-only -y --no-install-recommends "${options[@]}" "$@"; then
            rm -f -- "$state/$route.ready"
            echo "软件包下载失败，尝试其他可用源。" >&2
            continue
        fi
        printf '%s\n' "$route" > "$state/preferred"
        as_root env DEBIAN_FRONTEND=noninteractive apt-get install --no-remove --reinstall --no-download -y \
            --no-install-recommends "${options[@]}" "$@"
        return
    done
    echo "可用的 APT 源均未能获取软件包：$*" >&2
    return 1
}

install_rpm() {
    local state=$1 manager name group
    shift
    local missing=() repair=()
    manager=$(rpm_manager) || { echo "此 RPM 系统没有可用的 dnf、yum 或 microdnf。" >&2; return 1; }
    for name in "$@"; do
        if rpm -q "$name" >/dev/null 2>&1; then repair+=("$name"); else missing+=("$name"); fi
    done
    if (( ${#missing[@]} )); then
        if ! as_root env LC_ALL=C "$manager" -y --setopt=install_weak_deps=False install "${missing[@]}" 2>&1 | tee "$state/rpm-install.log"; then
            # EL keeps Chromium and Android tools in EPEL. Use distribution-provided,
            # signed repository packages and leave other package failures visible.
            grep -Eqi 'no match for argument|unable to find a match|no package .+ available|no package matches|nothing provides' "$state/rpm-install.log" || return 1
            case " ${missing[*]} " in *" chromium "*|*" android-tools "*|*" tmux "*) ;; *) return 1 ;; esac
            [[ -r /etc/redhat-release || -r /etc/alinux-release || -r /etc/anolis-release ]] || return 1
            as_root "$manager" -y install epel-release || {
                [[ -r /etc/alinux-release ]] && as_root "$manager" -y install epel-aliyuncs-release
            } || return 1
            local extra=()
            for group in crb powertools; do
                if LC_ALL=C "$manager" repolist --all 2>/dev/null | awk -v id="$group" '$1 == id {found=1} END {exit !found}'; then
                    extra+=("--enablerepo=$group")
                    break
                fi
            done
            as_root "$manager" -y --setopt=install_weak_deps=False "${extra[@]}" install "${missing[@]}" || return 1
        fi
    fi
    if (( ${#repair[@]} )); then as_root "$manager" -y reinstall "${repair[@]}"; fi
}

linux_packages() {
    local family=$1 region=$2 state=$3 name
    shift 3
    case $family in
        apt)
            local journal
            for journal in /var/lib/dpkg/updates/[0-9]*; do
                [[ -f $journal ]] || break
                as_root env DEBIAN_FRONTEND=noninteractive dpkg --configure --pending || return 1
                break
            done
            restore_apt && install_packages /etc/os-release "$region" "$state" "$@" ;;
        rpm) install_rpm "$state" "$@" ;;
        apk)
            local missing=() repair=()
            for name in "$@"; do
                if apk info -e "$name" >/dev/null; then repair+=("$name"); else missing+=("$name"); fi
            done
            if (( ${#missing[@]} )); then as_root apk add --no-cache "${missing[@]}" || return 1; fi
            if (( ${#repair[@]} )); then as_root apk fix --reinstall "${repair[@]}"; fi ;;
        *) echo "无法使用此包管理器安装 $*。" >&2; return 1 ;;
    esac
}

install_brew_packages() {
    local kind=$1
    shift
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    if ! command -v brew >/dev/null; then
        echo "正在为当前 Mac 准备 Homebrew。" >&2
        (
            installer=$(mktemp)
            trap 'rm -f -- "$installer"' EXIT
            curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 -o "$installer" \
                https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
            # Authenticate through the user's terminal before the noninteractive bootstrap.
            if ! sudo -n -v 2>/dev/null; then sudo -v; fi
            NONINTERACTIVE=1 /bin/bash "$installer"
        )
    fi
    local name action
    for name in "$@"; do
        action=install
        if brew list --"$kind" "$name" >/dev/null 2>&1; then action=reinstall; fi
        if [[ $kind == cask ]]; then brew "$action" --cask "--appdir=$HOME/Applications" "$name"
        else brew "$action" --formula "$name"; fi
    done
}

case ${1:-} in
    detect) detect_network ;;
    manager) linux_manager "${2:-/etc/os-release}" ;;
    linux) shift; linux_packages "$@" ;;
    apt) shift; install_packages /etc/os-release "$@" ;;
    brew) shift; install_brew_packages "$@" ;;
esac
