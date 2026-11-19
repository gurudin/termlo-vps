# Termlo VPS 端

在 Ubuntu 22.04 及以上或 Debian 12 及以上的 VPS 上，以将来从 Termlo 登录的 SSH 账号运行安装器。先确认 Mac 能用密钥登录这个账号。首次从云控制台准备 VPS 时，可以通过云厂商的 SSH 密钥管理添加 Mac 公钥。

## 安装和连接

在 VPS 控制台或交互式 SSH 终端粘贴下面这一行，即可打开中文安装向导。

```sh
curl -fsSL https://raw.githubusercontent.com/gurudin/termlo-vps/main/dist/termlo-install.sh | bash
```

1. **确认地址和端口。** 向导显示建议值，回车采用，也可以直接修改。地址优先使用上次的配置或当前 SSH 会话的公网地址。只有内网地址时，也会尝试从网卡或公网出口推断。如果经过端口映射，请确认显示的是 Mac 平时连接的地址和对外端口。登录用户和 SSH 主机指纹自动读取。
2. **选择工具。** tmux 和 Claude Code 各自显示安装状态。已有的直接复用，缺少的选「现在安装」或「跳过」。两项都跳过也能连接 VPS 和同步代码。有 Claude Code 时还可以选择准备远程登录浏览器，该选项默认跳过。
3. **复制连接码。** 安装完成后，将最后一行粘贴到 Mac 端。以后重新运行同一个向导，就能修改地址或补装工具。

在 Mac 的「服务器 → 添加服务器 → 连接码」粘贴 `termlo://connect/…` 并测试连接。选择工作区的本地工程、这台 VPS 和远端目录，把同步方式选为「双向同步」后连接。Mac 需要能找到 Mutagen，可在设置里选择已有的程序。它经 SSH 传送并运行远端同步代理。[Mutagen SSH 文档](https://mutagen.io/documentation/transports/ssh/)

Mac 上首次安装 Mutagen 可以使用 Homebrew。[Mutagen 安装文档](https://mutagen.io/documentation/introduction/installation/)

```sh
brew install mutagen-io/mutagen/mutagen
```

以后只需重新输出连接码时，在 VPS 上运行下面的命令。指纹每次从本机公钥读取。

```sh
~/.local/bin/termlo connection-code
```

## Claude Code 和登录浏览器

安装 tmux 后，工作区能接回已有会话。安装 Claude Code 后，工作区会启动 Claude Code。两个工具都跳过时，可以在远端工程目录使用 Shell。向导安装 Claude Code 时使用官方稳定通道。[Claude Code 安装文档](https://code.claude.com/docs/en/setup)

点击「登录 Claude」时，VPS 才会启动临时 Chromium。安装器优先使用当前用户可用的本机 Podman 或 Docker，缺少运行时时通过 apt 安装 Podman。使用新版 Mac 客户端打开浏览器，首次出现容器的自签名证书提示时，核对地址为 Termlo 面板显示的本机回环地址。浏览器访问用户名为 `termlo`，点「复制临时密码」即可填写。然后在远程 Chromium 中打开 Claude 终端给出的授权链接，按官方页面提示完成登录。「结束登录」会关闭隧道并清理本次容器。[Chromium 镜像文档](https://docs.linuxserver.io/images/docker-chromium/) · [Claude 登录说明](https://code.claude.com/docs/en/authentication)

## 从源码运行

在 VPS 端源码目录运行 `bash install.sh` 即可进入向导。运行 `bash build-installer.sh` 生成可独立执行的 `dist/termlo-install.sh`，发布时让远程安装命令指向这个文件的 GitHub Raw 或 Release 下载地址。运行 `python3 -B -m unittest discover -s tests -v` 验证管道安装、交互选项、重试和浏览器会话生命周期。
