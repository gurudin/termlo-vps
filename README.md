# Termlo 远端安装器

在远程 Mac、Linux 电脑或 VPS 上，用平时连接这台设备的 SSH 账号运行安装器。默认准备 Git、tmux、ADB、Mutagen 远端同步代理和原生浏览器，只有 Claude Code 需要选择。安装器自动选择远端系统的软件源。同步代理支持 Intel/AMD 64 位和 ARM64。远程 Mac 使用 Homebrew 支持的 macOS 版本。

## 安装和连接

在远程设备的控制台或交互式 SSH 终端执行：

```sh
(f=$(mktemp) && trap 'rm -f "$f"' EXIT && curl -fsSL --retry 2 -o "$f" https://raw.githubusercontent.com/gurudin/termlo-vps/main/install.sh && test -s "$f" && sh "$f")
```

也可以将仓库根目录的 `install.sh` 复制到远端，运行 `sh install.sh`。这两种方式使用同一份完整安装器。

只有 BusyBox 和 wget 的 Alpine 可使用同一地址执行 `(f=$(mktemp) && trap 'rm -f "$f"' EXIT && wget -O "$f" https://raw.githubusercontent.com/gurudin/termlo-vps/main/install.sh && test -s "$f" && sh "$f")`。安装器会通过 APK 准备 Bash。

安装器先显示环境体检清单。已有组件会跳过，可自动补齐的项目列出安装命令。需要人工处理的项目会在安装前阻止继续。只查看清单可运行 `sh install.sh --check`，已安装的设备也可运行 `~/.local/bin/termlo install --check`。

1. **确认 SSH 地址和端口。** 检查向导给出的建议值。使用 NAT 或端口映射时，填写你的 Mac 实际能访问的地址和对外端口。安装器核对本机 SSH 端口提供的公钥，新设备会自动安装 SSH 服务并生成缺少的主机密钥。已有服务保留原有身份。
2. **准备开发环境。** 向导复用已有软件，安装缺项并检查各项工具。它会运行同步代理确认版本，启动原生浏览器、渲染一张本地测试页，然后关闭测试实例。只有 Claude Code 可以选装或跳过。必需项出错时会停止，处理后可以用同一条命令重试。
3. **绑定 Mac。** 将最后一行连接码粘贴到 Termlo 的「服务器 → 添加服务器」，点「连接」。连接码在 10 分钟内有效，只能绑定一台 Mac。以后在这台 Mac 上点击设备名称即可重连。

重新生成连接码时，在远端运行 `~/.local/bin/termlo connection-code`。已有绑定可继续使用。[连接码说明](CONNECTION_CODE.md)

## 一键卸载

在远程设备上，用当初安装 Termlo 的 SSH 账号运行以下命令。新版和旧版都可以使用这个入口。

```sh
(f=$(mktemp) && trap 'rm -f "$f"' EXIT && curl -fsSL --retry 2 -o "$f" https://raw.githubusercontent.com/gurudin/termlo-vps/main/install.sh && test -s "$f" && sh "$f" uninstall)
```

新版也可以直接在远端运行 `~/.local/bin/termlo uninstall`，无需下载安装脚本。

卸载会撤销该账号的 Termlo 连接码和已配对 Mac 的 SSH 授权，清理 Termlo 命令与连接配置。新版安装器还会记录实际新增的 Git、tmux、ADB、浏览器、Mutagen 代理及选装的 Claude Code，卸载时按记录移除。若其他项目也在使用这些工具，可在命令末尾加 `--keep-tools`。移除系统软件包时可能需要 sudo。

旧版没有组件来源记录，共用工具会保留。用户的工程文件、其他 SSH 公钥、Claude 账号数据和会话历史均保留。Python、Homebrew、系统 SSH 和包管理器的依赖按共用组件处理。撤销配对对后续 SSH 连接生效，已经打开的终端可以正常退出。

Linux 的 root 安装若新增了专用浏览器账号，卸载会核对账号和主目录后清理。主目录已有额外内容时，保留该账号及其文件，并在终端说明。

## 各组件的安装方式

| 组件 | 安装方式 |
|---|---|
| Git、tmux、ADB | Debian、Ubuntu 使用 APT，RPM 系统使用 DNF 或 YUM，Alpine 使用 APK，远程 Mac 使用 Homebrew。ADB 命令行供远端开发工具调用，连接本机手机还需要建立对应工作区的设备通道。 |
| 原生浏览器 | 优先复用能渲染测试页的 Chromium 或 Chrome。Debian、RPM 系统和 Alpine 通过软件源安装 Chromium，Ubuntu 使用 Chromium Snap，macOS 缺少浏览器时安装 Google Chrome（Chromium 内核）。 |
| Mutagen 同步代理 | 从官方 v0.18.1 发布包提取当前系统和处理器对应的代理，校验 SHA-256 后安装到 SSH 用户的 Mutagen 版本目录。其他版本的代理可以共存。 |
| Claude Code | 选装时使用当前 SSH 用户运行 Anthropic 官方稳定版安装程序。中国大陆出口默认跳过。带参数的非交互安装仅在显式指定 `--with-claude` 时安装。 |

Ubuntu 的 Chromium 需要可用的 Snap 服务。Linux 用 root 安装时，安装器为浏览器准备无登录权限的 `termlo-browser` 系统账号，以普通用户身份运行 Chromium 并保留它的沙盒。SSH 连接和配对仍使用原账号。macOS 若需要安装 Homebrew 或系统工具，可能会要求管理员授权。

APT 会按远端网络选择系统源或清华镜像，下载失败时尝试另一条线路。国内镜像设置仅用于本次安装，沿用发行版签名校验。远端无法下载 Mutagen 时，可以先取得对应平台的官方压缩包，再执行 `TERMLO_MUTAGEN_ARCHIVE=/完整路径/文件名 bash install.sh`，安装器仍会验证同一个 SHA-256。[清华镜像](https://mirrors.tuna.tsinghua.edu.cn/) · [Mutagen 发布包](https://github.com/mutagen-io/mutagen/releases/tag/v0.18.1)

## 在服务器核验

```sh
~/.local/bin/termlo browser check
~/.mutagen/agents/0.18.1/mutagen-agent version
tmux -V
git --version
adb version
```

浏览器检查会在独立的临时配置中渲染测试页。新版 Mac 客户端的「登录 Claude」会检查远端环境并使用远端的原生浏览器。旧版 `termlo browser start/stop` 保留给已配置容器浏览器的设备。

双向同步由使用 Termlo 的 Mac 发起。在 Mac 上准备好 Mutagen 后，选择本机和远端的项目目录，开启工作区双向同步。Mac 端使用其他版本时，Mutagen 会通过 SSH 安装与客户端匹配的代理。[Mutagen SSH 文档](https://mutagen.io/documentation/transports/ssh/) · [Mac 端安装说明](https://mutagen.io/documentation/introduction/installation/)

## 从源码运行

运行 `bash bootstrap.sh` 可从源码打开向导。已有自动化可使用 `--host`、`--port`、`--host-key`，并用 `--without-claude` 或 `--with-claude` 明确选择 Claude Code。`--sync-only` 保留为只准备 SSH 和同步代理的单独入口。

更新源码后运行 `bash build-installer.sh`，生成可独立分发的 `install.sh` 和兼容入口 `dist/termlo-install.sh`。运行 `python3 -B -m unittest discover -s tests -v` 检查安装器。
