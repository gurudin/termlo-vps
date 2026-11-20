#!/usr/bin/env bash
set -euo pipefail

system=$(uname -s)
if [[ $system == Darwin ]]; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
else
    export PATH="$PATH:/usr/sbin:/sbin"
fi
case "${1:-}" in
    -h|--help) ;;
    *)
        if [[ $system != Linux && $system != Darwin ]]; then
            echo "请在远程 macOS 或 Linux 设备上运行安装器。" >&2
            exit 1
        fi
        if [[ $system == Darwin && $(id -u) == 0 ]]; then
            echo "请用平时连接远程 Mac 的普通账号运行安装器。" >&2
            exit 1
        fi
        if [[ $(id -u) == 0 && -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then
            echo "请用连接这台 VPS 的 SSH 账号运行安装器。安装系统包时会自动调用 sudo。" >&2
            exit 1
        fi
        ;;
esac

if (( $# == 0 )); then
    if ! ( : </dev/tty ) 2>/dev/null; then
        echo "安装向导需要交互终端。请在设备控制台或交互式 SSH 会话中运行。" >&2
        exit 1
    fi
    # With curl | bash, the shell reads program text from stdin. Dependencies may also prompt.
    exec </dev/tty
fi

source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
usable_python() {
    local name
    for name in python3 python3.11 python3.9; do
        command -v "$name" >/dev/null || continue
    # The system python3 on a fresh Mac is a developer-tools launcher.
        if [[ $system == Darwin && $(command -v "$name") == /usr/bin/python3 ]]; then
            /usr/bin/xcode-select -p >/dev/null 2>&1 || continue
        fi
        if "$name" -B -c 'import ssl, sys, zlib; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
            interpreter=$name
            return 0
        fi
    done
    return 1
}
if [[ ${1:-} == uninstall || ${1:-} == --uninstall ]]; then
    shift
    usable_python || { echo "卸载需要可运行的 Python 3.8 或更高版本。" >&2; exit 1; }
    exec "$interpreter" -B "$source_dir/termlo.py" uninstall "$@"
fi
if ! usable_python; then
    if [[ $system == Darwin ]]; then
        bash "$source_dir/sources.sh" brew formula python >&2
        hash -r
    else
        family=$(bash "$source_dir/sources.sh" manager)
        TERMLO_INSTALL_NETWORK=$(bash "$source_dir/sources.sh" detect)
        export TERMLO_INSTALL_NETWORK
        (
            state=$(mktemp -d)
            trap 'rm -rf -- "$state"' EXIT
            package=python3
            if [[ $family == rpm ]] && command -v python3 >/dev/null; then package=python3.11; fi
            bash "$source_dir/sources.sh" linux "$family" "${TERMLO_INSTALL_NETWORK%% *}" "$state" "$package" >&2
            if [[ $family == rpm ]] && ! usable_python; then
                bash "$source_dir/sources.sh" linux rpm "${TERMLO_INSTALL_NETWORK%% *}" "$state" python3.11 >&2
            fi
        )
    fi
    usable_python || { echo "安装后仍未找到可用的 Python 3.8 或更高版本。" >&2; exit 1; }
fi

exec "$interpreter" -B "$source_dir/termlo.py" install "$@"
