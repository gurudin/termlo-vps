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
