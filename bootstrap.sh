#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$source_dir/python-runtime.sh"
. "$source_dir/prerequisites.sh"
. "$source_dir/doctor.sh"
system=$(uname -s)
case $system in Darwin) PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" ;; *) PATH="$PATH:/usr/sbin:/sbin" ;; esac
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
case ${1:-} in
    -h|--help)
        printf '%s\n' 'sh install.sh [--check] [--host 地址] [--port 对外端口] [--host-key 主机公钥] [--name 名称]' \
            '              [--with-claude | --without-claude | --sync-only]' 'sh install.sh uninstall [--keep-tools]'
        exit 0 ;;
    uninstall|--uninstall)
        shift
        interpreter=$(find_python) || { echo '卸载需要 Python 3.8 或更高版本。请运行 sh install.sh --check 查看本机的 Python 安装命令。' >&2; exit 1; }
        exec "$interpreter" -B "$source_dir/termlo.py" uninstall "$@" ;;
esac
termlo_doctor "$source_dir" "$(cat "$source_dir/mutagen-releases.txt")" /etc/os-release "$@"
for arg do [ "$arg" != --check ] || exit 0; done
if [ "$#" = 0 ]; then
    if ! ( : </dev/tty ) 2>/dev/null; then
        echo '安装向导需要交互终端。请在设备控制台或交互式 SSH 会话中运行。' >&2; exit 1
    fi
    exec </dev/tty
fi
family=brew
[ "$system" = Darwin ] || family=$(linux_manager) || family=unknown
if [ "$family" = apt ] && ! apt_ready; then restore_apt; fi
if ! has bash; then
    case $family in
        apk) as_root apk add --no-cache bash ;;
        apt) as_root apt-get update && as_root apt-get install -y bash ;;
        rpm) for manager in dnf yum microdnf; do has "$manager" && break; done; as_root "$manager" -y install bash ;;
        *) echo '缺少 Bash。请按体检列出的命令安装后重试。' >&2; exit 1 ;;
    esac
fi
if ! interpreter=$(find_python); then
    if [ "$system" = Darwin ]; then
        bash "$source_dir/sources.sh" brew formula python >&2
    else
        if [ -z "${TERMLO_INSTALL_NETWORK:-}" ]; then TERMLO_INSTALL_NETWORK=$(bash "$source_dir/sources.sh" detect); fi
        export TERMLO_INSTALL_NETWORK
        (
            state=$(mktemp -d)
            trap 'rm -rf -- "$state"' EXIT
            package=python3
            if [ "$family" = rpm ] && has python3; then package=python3.11; fi
            bash "$source_dir/sources.sh" linux "$family" "${TERMLO_INSTALL_NETWORK%% *}" "$state" "$package" >&2
            if [ "$family" = rpm ] && ! find_python >/dev/null; then
                bash "$source_dir/sources.sh" linux rpm "${TERMLO_INSTALL_NETWORK%% *}" "$state" python3.11 >&2
            fi
        )
    fi
    interpreter=$(find_python) || { echo 'Python 未通过运行检查，请按体检列出的 Python 命令修复后重试。' >&2; exit 1; }
    # Repeat the checks that need a working interpreter (browser, checksum and HTTPS).
    termlo_doctor "$source_dir" "$(cat "$source_dir/mutagen-releases.txt")" /etc/os-release "$@"
fi
exec "$interpreter" -B "$source_dir/bootstrap.py" install "$@"
