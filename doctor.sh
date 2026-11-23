# Sourced with prerequisites.sh. Every check runs before installing system packages.
doctor_row() { printf '  [%s] %s\n' "$1" "$2" >&2; }
doctor_hint() { printf '           %s\n' "$1" >&2; }
doctor_block() { doctor_row 需处理 "$1"; doctor_hint "$2"; blocked=1; }

package_hint() {
    case $family in
        apt) printf '%sapt-get update && %sapt-get install -y %s' "$priv" "$priv" "$1" ;;
        rpm) printf '%s%s install -y %s' "$priv" "${manager:-dnf}" "$2" ;;
        apk) printf '%sapk add --no-cache %s' "$priv" "$3" ;;
        brew) printf 'brew install %s' "$4" ;;
        *) printf '请让设备管理员安装 %s，然后重新运行安装器。' "$1" ;;
    esac
}
doctor_package() {
    doctor_row 自动安装 "$1"
    doctor_hint "$(package_hint "$2" "$3" "$4" "$5")"
    packages_needed=1
}
writable_directory() (
    dir=$1
    case $dir in /*) ;; *) return 1 ;; esac
    while [ ! -e "$dir" ]; do dir=${dir%/*}; [ -n "$dir" ] || dir=/; done
    [ -d "$dir" ] && [ -w "$dir" ] && [ -x "$dir" ]
)

# BusyBox systems can validate an offline release before even Bash or Python exists.
check_agent() (
    version=${manifest%%'
'*}
    agent=$mutagen/agents/$version/mutagen-agent
    if [ -x "$agent" ] && [ "$("$agent" version 2>/dev/null)" = "$version" ]; then
        echo "Mutagen $version 同步代理已就绪"; return 0
    fi
    case "$machine" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;; esac
    case "$system" in Darwin) os=darwin ;; Linux) os=linux ;; *) return 1 ;; esac
    while read -r target asset digest; do
        [ "$target" = "${os}_$arch" ] || continue
        name=mutagen_${target}_v$version.tar.gz
        url=https://github.com/mutagen-io/mutagen/releases/download/v$version/$name
        if [ -n "${TERMLO_MUTAGEN_ARCHIVE:-}" ]; then
            if [ -r "$TERMLO_MUTAGEN_ARCHIVE" ]; then
                if has sha256sum; then checksum=$(sha256sum < "$TERMLO_MUTAGEN_ARCHIVE")
                elif has shasum; then checksum=$(shasum -a 256 < "$TERMLO_MUTAGEN_ARCHIVE")
                else echo '需要 SHA-256 校验工具。请安装 coreutils 或使用系统 shasum。'; return 1; fi
                if [ "${checksum%% *}" = "$digest" ]; then echo "Mutagen $version 同步代理（离线包 SHA-256 已核对）"; return 0; fi
            fi
            echo "离线包无法读取或校验失败。下载命令：curl -fL -o $name $url"; return 1
        fi
        api=https://api.github.com/repos/mutagen-io/mutagen/releases/assets/$asset
        cmd="curl -fL --retry 2 -o $name $url"
        for source in "$url" "$api"; do
            if has curl; then
                if curl -qfsIL --connect-timeout 5 --max-time 15 -H 'Accept: application/octet-stream' "$source" >/dev/null 2>&1; then
                    echo "Mutagen $version 同步代理（官方下载地址可访问）"; return 0
                else status=$?; fi
                if [ "$os" = linux ] && [ -z "${CURL_CA_BUNDLE:-}${SSL_CERT_FILE:-}${SSL_CERT_DIR:-}" ]; then
                    case $status in
                        77) repair_ca=1 ;;
                        60) if [ -n "$py" ] && "$py" -IB -c 'import ssl,sys; sys.exit(bool(ssl.create_default_context().get_ca_certs()))'; then repair_ca=1; fi ;;
                    esac
                fi
            elif has wget; then
                if wget --spider -T 8 "$source" >/dev/null 2>&1; then echo "Mutagen $version 同步代理（官方下载地址可访问）"; return 0; fi
            else echo "Mutagen $version 同步代理（安装 curl 后校验官方下载包）"; return 0; fi
        done
        if [ "${repair_ca:-0}" = 1 ]; then echo "Mutagen $version（需要先修复系统 ca-certificates）"; return 0; fi
        echo "两个官方下载入口均不可达。在可联网设备运行 $cmd，复制到远端后设置 export TERMLO_MUTAGEN_ARCHIVE=\"\$PWD/$name\"。"; return 1
    done <<RELEASES
$manifest
RELEASES
    return 1
)

termlo_doctor() (
    payload=$1; manifest=$2; release=$3; shift 3
    system=$(uname -s); machine=$(uname -m)
    blocked=0; packages_needed=0; admin_needed=0; full=1; check_only=0
    port=22; key=''; claude=选装
    while [ "$#" -gt 0 ]; do
        case $1 in
            --check) check_only=1 ;;
            --sync-only) full=0 ;;
            --with-claude) claude=已选择安装 ;;
            --without-claude) claude=已跳过 ;;
            --port|--host-key|--host|--name)
                [ "$#" -ge 2 ] || { echo "$1 缺少参数。" >&2; return 2; }
                case $1 in --port) port=$2 ;; --host-key) key=$2 ;; esac
                shift ;;
            --port=*) port=${1#*=} ;; --host-key=*) key=${1#*=} ;;
            --name=*|--host=*) ;;
            *) printf '未知安装参数 %s。运行 sh install.sh --help 查看用法。\n' "$1" >&2; return 2 ;;
        esac
        shift
    done
    printf '\nTermlo 安装前体检\n' >&2
    case "$system/$machine" in Linux/x86_64|Linux/aarch64|Linux/arm64|Darwin/x86_64|Darwin/arm64)
        doctor_row 就绪 "远程系统  $system $machine" ;;
        *) doctor_block "远程系统  $system $machine" "请在 64 位 Intel/AMD 或 ARM 的 Linux 或 macOS 设备上运行。" ;;
    esac
    uid=$(id -u); priv=''
    if [ "$uid" != 0 ]; then
        if has doas && ! has sudo; then priv='doas '; else priv='sudo '; fi
    fi
    if { [ "$system" = Darwin ] && [ "$uid" = 0 ]; } ||
       { [ "$uid" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; }; then
        doctor_block '安装账号  当前为提权后的账号' "请回到平时登录这台设备的 SSH 账号，直接运行安装命令。"
    else doctor_row 就绪 "安装账号  UID $uid"; fi
    config=${XDG_CONFIG_HOME:-$HOME/.config}/termlo
    mutagen=${MUTAGEN_DATA_DIRECTORY:-$HOME/.mutagen}
    for path in "$config" "$HOME/.ssh" "$HOME/.local/bin" "$mutagen/agents"; do
        writable_directory "$path" || doctor_block "安装目录  $path 无法写入" "请用拥有此目录的 SSH 账号安装，并检查目录权限：ls -ld \"$path\""
    done
    if [ -d "$HOME/.local/bin/termlo" ]; then
        doctor_block '命令安装位置已被目录占用' '请移动该目录后重试：mv "$HOME/.local/bin/termlo" "$HOME/.local/bin/termlo-directory"'
    fi
    if [ -e "$HOME/.ssh/authorized_keys" ] && ! { [ -f "$HOME/.ssh/authorized_keys" ] && [ -r "$HOME/.ssh/authorized_keys" ]; }; then
        doctor_block 'SSH 授权文件无法读取' '请在此账号检查 ls -l "$HOME/.ssh/authorized_keys"'
    fi
    if [ "$system" = Darwin ]; then family=brew; else family=$(linux_manager "$release") || family=unknown; fi
    manager=''
    if [ "$family" = rpm ]; then
        for tool in dnf yum microdnf; do if has "$tool"; then manager=$tool; break; fi; done
    fi
    if has bash; then doctor_row 就绪 Bash; else doctor_package Bash bash bash bash bash; fi
    py=$(find_python) || py=''
    if [ -n "$py" ]; then doctor_row 就绪 "Python  $($py -V 2>&1)"
    else doctor_package 'Python 3.8 或更高版本（含 TLS 支持）' python3 python3.11 python3 python; fi
    if curl --version >/dev/null 2>&1; then doctor_row 就绪 'HTTPS 下载工具  curl'
    else doctor_package 'HTTPS 下载工具  curl' 'curl ca-certificates' 'curl ca-certificates' 'curl ca-certificates' curl; fi
    for tool in ssh scp ssh-keygen ssh-keyscan; do
        if ! has "$tool"; then doctor_package "SSH 工具  缺少 $tool" openssh-client openssh-clients 'openssh-client-default openssh-keygen' openssh; break; fi
    done
    if [ -n "$key" ] && { [ ! -r "$key" ] || { has ssh-keygen && ! ssh-keygen -lf "$key" >/dev/null 2>&1; }; }; then
        doctor_block '指定的 SSH 公钥不可读或无效' '移除 --host-key 参数重试，安装器会识别 SSH 服务实际使用的密钥。'
    fi
    case "$port" in ''|*[!0-9]*) valid_port=0 ;; *) valid_port=$port ;; esac
    if ! { [ "$valid_port" -gt 0 ] && [ "$valid_port" -le 65535 ]; } 2>/dev/null; then
        doctor_block 'SSH 端口超出范围' '请将 --port 设置为 1 到 65535 之间的对外端口。'
    elif keys=$(scan_ssh "$port"); then
        doctor_row 就绪 'SSH 服务及主机密钥  已从本机 SSH 端口取得公钥'
        if [ -n "$key" ] && [ -r "$key" ]; then
            read -r kind blob rest < "$key" || :
            case "$keys " in *" $kind $blob "*|*" $kind $blob
"*) ;; *) doctor_block '指定公钥与 SSH 服务不匹配' '请去掉 --host-key 后重试，让安装器读取实际提供连接的公钥。';; esac
        fi
    elif has ssh-keyscan && [ -n "${SSH_CONNECTION:-}" ]; then
        read -r client client_port address internal_port <<ENDPOINT
$SSH_CONNECTION
ENDPOINT
        doctor_block '当前 SSH 会话的本机端口未能出示主机公钥' "检查服务监听地址：ssh-keyscan -T 3 -p $internal_port $address"
    else
        doctor_row 自动准备 'SSH 服务及主机密钥  安装 OpenSSH、生成缺少的密钥并验证监听端口'
        doctor_hint "${priv}ssh-keygen -A"
        if [ "$system" = Linux ] && ! has sshd; then
            doctor_package 'OpenSSH 服务端' openssh-server openssh-server openssh-server openssh
        fi
        admin_needed=1
        if [ "$system" = Darwin ]; then doctor_hint '若 macOS 要求手动授权，打开「系统设置 → 通用 → 共享 → 远程登录」，允许此 SSH 账号登录。'; fi
    fi

    agent=$(check_agent) && agent_ok=1 || agent_ok=0
    if [ "$agent_ok" = 0 ]; then doctor_block "Mutagen 同步代理  $agent" '修复网络或设置正确的离线包后重试。'
    else
        case $agent in
            *已就绪*) doctor_row 就绪 "$agent" ;;
            *ca-certificates*) doctor_package "$agent" ca-certificates ca-certificates ca-certificates ca-certificates ;;
            *) doctor_row 自动安装 "$agent" ;;
        esac
    fi

    if [ "$full" = 1 ]; then
        if { [ "$system" != Darwin ] || [ "$(command -v git || :)" != /usr/bin/git ] || /usr/bin/xcode-select -p >/dev/null 2>&1; } && git --version >/dev/null 2>&1; then doctor_row 就绪 Git; else doctor_package Git git git git git; fi
        if tmux -V >/dev/null 2>&1; then doctor_row 就绪 tmux; else doctor_package tmux tmux tmux tmux tmux; fi
        if adb version >/dev/null 2>&1; then doctor_row 就绪 ADB; else doctor_package ADB adb android-tools android-tools '--cask android-platform-tools'; fi
        if [ -z "$py" ]; then
            doctor_row 待核验 '远程浏览器  Python 就绪后试启动，能渲染测试页就直接复用'
            if [ "$family" = apt ] && [ -r "$release" ] && ( . "$release"; [ "${ID:-}" = ubuntu ] ); then
                doctor_hint "缺少时安装 Chromium：${priv}snap install chromium"
            else doctor_hint "缺少时运行：$(package_hint 'chromium chromium-sandbox' chromium chromium '--cask google-chrome')"; fi
        elif browser=$("$py" -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import native_browser
try: print(native_browser.check())
except (OSError, ValueError) as error: sys.exit(str(error))' "$payload" 2>&1); then
            doctor_row 就绪 "远程浏览器  已渲染测试页  $browser"
        else
            doctor_hint "$browser"
            if [ "$family" = apt ] && [ -r "$release" ] && ( . "$release"; [ "${ID:-}" = ubuntu ] ); then
                if [ ! -d /run/systemd/system ] && [ ! -S /run/snapd.socket ] && [ -n "$py" ] &&
                   ! "$py" -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import native_browser; sys.exit(not native_browser.executable())' "$payload"; then
                    doctor_block 'Ubuntu Chromium 需要 Snap 服务或已安装的原生浏览器' '在启用 systemd 的 Ubuntu 上运行 sudo systemctl enable --now snapd.socket，或安装可运行的 Google Chrome 后重试。'
                else doctor_row 自动准备 '原生浏览器  安装并验证 Chromium'; doctor_hint "${priv}snap install chromium"; packages_needed=1; fi
            else doctor_package '远程浏览器  安装或修复后实际渲染测试页' 'chromium chromium-sandbox' chromium chromium '--cask google-chrome'; fi
        fi
        if [ "$system" = Linux ] && [ "$uid" = 0 ]; then
            for tool in useradd runuser; do
                if ! has "$tool"; then doctor_package "浏览器运行账号工具  $tool" 'passwd util-linux' 'shadow-utils util-linux' 'shadow cmd:runuser' ''; break; fi
            done
        fi
        if claude --version >/dev/null 2>&1; then doctor_row 就绪 'Claude Code'
        else
            doctor_row "$claude" 'Claude Code'
            doctor_hint '基础环境装好后可运行 ~/.local/bin/termlo install --with-claude'
        fi
    fi
    case $family in
        apt)
            if apt_ready; then doctor_row 就绪 '系统包管理器  apt-get'
            elif hint=$(apt_recovery_hint "$priv"); then doctor_row 自动修复 '系统包管理器  缺少 apt-get'; doctor_hint "$hint"; admin_needed=1
            else doctor_block '系统包管理器  缺少 apt-get，未找到自动恢复工具' "$hint"; fi ;;
        apk|rpm)
            if [ "$family" = apk ] && has apk; then doctor_row 就绪 '系统包管理器  apk'
            elif [ -n "$manager" ]; then doctor_row 就绪 "系统包管理器  $manager"
            else doctor_block '缺少发行版软件管理器' "请管理员用同版本官方安装介质恢复软件包，RPM 系统可在含 dnf 及其依赖的目录运行 ${priv}rpm -Uvh --replacepkgs ./*.rpm。"; fi ;;
        brew)
            if has brew; then doctor_row 就绪 Homebrew
            elif [ "$packages_needed" = 1 ]; then
                doctor_row 自动安装 Homebrew
                doctor_hint "安装器会运行官方程序，需要管理员授权。手动运行："
                cat >&2 <<'BREW_COMMAND'
           (f=$(mktemp) && trap 'rm -f "$f"' EXIT && curl -fsSL -o "$f" https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh && test -s "$f" && /bin/bash "$f")
BREW_COMMAND
                admin_needed=1
            fi ;;
        *) if [ "$packages_needed" = 1 ]; then doctor_block '无法识别系统包管理器' '请使用 Debian/Ubuntu、RPM 系、Alpine Linux 或 macOS 安装。'; fi ;;
    esac
    if [ "$packages_needed" = 1 ] && [ "$family" != brew ]; then admin_needed=1; fi
    if [ "$admin_needed" = 1 ] && [ "$uid" != 0 ]; then
        if { has sudo && sudo -n true </dev/null; } 2>/dev/null || { has doas && doas -n true </dev/null; } 2>/dev/null; then
            doctor_row 就绪 '系统组件安装权限'
        elif { has sudo || has doas; } && ( : </dev/tty ) 2>/dev/null; then
            doctor_row 需授权 '安装系统组件前将请求管理员授权'
            if [ "$check_only" = 0 ] && [ "$blocked" = 0 ]; then
                as_root true </dev/tty || doctor_block '未获得管理员权限' '请让管理员执行上面列出的系统组件命令，再用当前账号重试。'
            fi
        else doctor_block '当前账号无法安装系统组件' '请管理员执行上面列出的命令，或在交互式 SSH 终端运行 sudo -v 后重试。'; fi
    fi
    if [ "$blocked" != 0 ]; then echo '体检未通过。处理以上项目后，重新运行安装命令。' >&2; return 1; fi
    if [ "$check_only" = 1 ]; then echo '体检通过。正常运行安装命令即可补齐缺项。' >&2
    else echo '体检通过。已安装且可用的组件会直接复用。' >&2; fi
)
