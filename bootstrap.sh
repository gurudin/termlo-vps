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
scratch=$(mktemp -d) || scratch=''
if [ -n "$scratch" ]; then trap 'rm -rf -- "$scratch"' EXIT; fi
termlo_doctor "$source_dir" "$(cat "$source_dir/mutagen-releases.txt")" /etc/os-release "$scratch" "$@"
for arg do [ "$arg" != --check ] || exit 0; done
if [ "$#" = 0 ]; then exec </dev/tty; fi
if [ -f "$scratch/agent.tar.gz" ]; then export TERMLO_MUTAGEN_ARCHIVE="$scratch/agent.tar.gz"; fi
interpreter=$(find_python) || { echo 'Python 已不可用，请重新运行安装命令检查环境。' >&2; exit 1; }
"$interpreter" -B "$source_dir/bootstrap.py" install "$@"
