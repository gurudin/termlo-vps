#!/usr/bin/env bash
# Used both before Python is available and by the installed Termlo command.
set -euo pipefail

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

china_sources() (
    local release=$1 arch=$2 mirror=https://mirrors.tuna.tsinghua.edu.cn
    local suite components keyring archive security
    [[ -r $release ]] || return 1
    . "$release"
    suite=${VERSION_CODENAME:-}
    [[ $suite =~ ^[a-z][a-z0-9-]*$ && $arch =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
    case ${ID:-} in
        debian)
            archive=$mirror/debian
            security=$mirror/debian-security
            components=main
            keyring=/usr/share/keyrings/debian-archive-keyring.gpg ;;
        ubuntu)
            case $arch in amd64|i386) archive=$mirror/ubuntu ;; *) archive=$mirror/ubuntu-ports ;; esac
            security=$archive
            components='main restricted universe multiverse'
            keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg ;;
        *) return 1 ;;
    esac
    local options="arch=$arch signed-by=$keyring"
    printf 'deb [%s] %s %s %s\n' "$options" "$archive" "$suite" "$components" \
        "$options" "$archive" "$suite-updates" "$components" \
        "$options" "$security" "$suite-security" "$components"
)

install_packages() {
    local release=$1 region=$2 state=$3 route preferred=system arch
    shift 3
    local privilege=() options=() routes=(system cn)
    if (( EUID != 0 )); then privilege=(sudo); fi
    [[ $region != cn ]] || preferred=cn
    if [[ -s $state/preferred ]]; then read -r preferred < "$state/preferred"; fi
    if [[ $preferred == cn ]]; then routes=(cn system); fi

    for route in "${routes[@]}"; do
        options=(-o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8)
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
            if ! "${privilege[@]}" apt-get update "${options[@]}" -o APT::Update::Error-Mode=any; then
                echo "APT 索引获取失败，尝试其他可用源。" >&2
                continue
            fi
            : > "$state/$route.ready"
        fi
        # Try another source only before dpkg starts changing installed packages.
        if ! "${privilege[@]}" apt-get install --download-only -y --no-install-recommends "${options[@]}" "$@"; then
            rm -f -- "$state/$route.ready"
            echo "软件包下载失败，尝试其他可用源。" >&2
            continue
        fi
        printf '%s\n' "$route" > "$state/preferred"
        "${privilege[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install --no-download -y \
            --no-install-recommends "${options[@]}" "$@"
        return
    done
    echo "可用的 APT 源均未能获取软件包：$*" >&2
    return 1
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
    if [[ $kind == cask ]]; then
        brew install --cask --appdir="$HOME/Applications" "$@"
    else
        brew install "$@"
    fi
}

case ${1:-} in
    detect) detect_network ;;
    apt) shift; install_packages /etc/os-release "$@" ;;
    brew) shift; install_brew_packages "$@" ;;
esac
