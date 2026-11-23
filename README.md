# Termlo 远端安装器

在远程 Mac、Linux 电脑或 VPS 上，用平时连接这台设备的 SSH 账号运行安装器。默认准备 Git、tmux、ADB、Mutagen 远端同步代理和原生浏览器，只有 Claude Code 需要选择。安装器自动选择远端系统的软件源。同步代理支持 Intel/AMD 64 位和 ARM64。远程 Mac 使用 Homebrew 支持的 macOS 版本。

## 安装和连接

把安装脚本保存到远程设备，在脚本所在目录运行下面这条命令。[下载 install.sh](https://raw.githubusercontent.com/gurudin/termlo-vps/main/install.sh)

```sh
sh install.sh
```

首次安装和以后重装都会重新体检并显示清单。可用的组件直接复用，缺少的组件自动准备。发现需要手动处理的项目时，会在安装前停下并显示处理方法。只查看清单可运行 `sh install.sh --check`。

在全新服务器的 SSH 终端，可以先用下面的命令取得这个文件，再运行上面的安装命令。只有 wget 的设备可将 `curl -fLO` 换成 `wget`。

```sh
curl -fLO https://raw.githubusercontent.com/gurudin/termlo-vps/main/install.sh
```

<details>
<summary>从空服务器的终端一行下载安装</summary>

```sh
setup=$(curl -fsSL https://raw.githubusercontent.com/gurudin/termlo-vps/main/install.sh) && sh -c "${setup:?安装脚本为空}"
```

</details>

1. **确认 SSH 地址和端口。** 检查向导给出的建议值。使用 NAT 或端口映射时，填写你的 Mac 实际能访问的地址和对外端口。安装器核对本机 SSH 端口提供的公钥，新设备会自动安装 SSH 服务并生成缺少的主机密钥。已有服务保留原有身份。
2. **准备开发环境。** 向导复用已有软件，安装缺项并检查各项工具。它会运行同步代理确认版本，启动原生浏览器、渲染一张本地测试页，然后关闭测试实例。只有 Claude Code 可以选装或跳过。必需项出错时会停止，处理后可以用同一条命令重试。
3. **绑定 Mac。** 将最后一行连接码粘贴到 Termlo 的「服务器 → 添加服务器」，点「连接」。连接码在 10 分钟内有效，只能绑定一台 Mac。以后在这台 Mac 上点击设备名称即可重连。

重新生成连接码时，在远端运行 `~/.local/bin/termlo connection-code`。已有绑定可继续使用。[连接码说明](CONNECTION_CODE.md)

## 一键卸载

用当初安装 Termlo 的 SSH 账号，在同一个脚本所在目录运行下面的命令。

```sh
sh install.sh uninstall
```

这个脚本也可卸载旧版本。新版已经安装的设备还可直接运行 `~/.local/bin/termlo uninstall`。

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

运行 `bash bootstrap.sh` 可从源码打开向导。已有自动化可使用 `--host`、`--port`、`--host-key`，并用 `--without-claude` 或 `--with-claude` 明确选择 Claude Code。非交互选装 Claude Code 单独失败时，仍输出可用的基础环境连接码，同时返回失败状态并给出重试命令。`--sync-only` 保留为只准备 SSH 和同步代理的单独入口。

更新源码后运行 `bash build-installer.sh`，生成可独立分发的 `install.sh` 和兼容入口 `dist/termlo-install.sh`。运行 `python3 -B -m unittest discover -s tests -v` 检查安装器。
