#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    -h|--help) ;;
    *)
        if [[ $(uname -s) != Linux ]]; then
            echo "请在 VPS 的 Linux SSH 会话中运行安装器。" >&2
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
        echo "安装向导需要交互终端。请在 VPS 控制台或交互式 SSH 会话中运行。" >&2
        exit 1
    fi
    # With curl | bash, the shell reads program text from stdin. Dependencies may also prompt.
    exec </dev/tty
fi

source_dir=$(cd -- "$(dirname -- "$0")" && pwd)
if ! command -v python3 >/dev/null; then
    command -v apt-get >/dev/null || { echo "请先安装 Python 3.8 或更高版本。" >&2; exit 1; }
    TERMLO_INSTALL_NETWORK=$(bash "$source_dir/sources.sh" detect)
    export TERMLO_INSTALL_NETWORK
    (
        state=$(mktemp -d)
        trap 'rm -rf -- "$state"' EXIT
        bash "$source_dir/sources.sh" apt "${TERMLO_INSTALL_NETWORK%% *}" "$state" python3 >&2
    )
fi

exec python3 -B "$source_dir/termlo.py" install "$@"
