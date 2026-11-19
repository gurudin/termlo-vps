# Termlo VPS 端

在 Ubuntu 22.04 及以上或 Debian 12 及以上的 VPS 上，以将来从 Termlo 登录的 SSH 账号运行安装器。先确认 Mac 能用密钥登录这个账号。首次从云控制台准备 VPS 时，可以通过云厂商的 SSH 密钥管理添加 Mac 公钥。

## 安装和连接

在 VPS 控制台或交互式 SSH 终端粘贴下面这一行，即可打开中文安装向导。

```sh
curl -fsSL https://raw.githubusercontent.com/gurudin/termlo-vps/main/install.sh | bash
```

如果 VPS 访问不了 GitHub，可以从能访问的电脑下载仓库根目录的 `install.sh` 传到 VPS，也可以从自己的下载站取得同一文件。在 VPS 上执行：

```sh
bash install.sh
```

文件内已包含完整的 Termlo 安装向导。两种入口会在**执行脚本的 VPS** 上自动判断下载线路，使用同一套交互选项。

1. **确认地址和端口。** 向导显示建议值，回车采用，也可以直接修改。地址优先使用上次的配置或当前 SSH 会话的公网地址。只有内网地址时，也会尝试从网卡或公网出口推断。如果经过端口映射，请确认显示的是 Mac 平时连接的地址和对外端口。登录用户和 SSH 主机指纹自动读取。
2. **选择工具。** tmux 和 Claude Code 各自显示安装状态。已有的直接复用，缺少的选「现在安装」或「跳过」。两项都跳过也能连接 VPS 和同步代码。有 Claude Code 时还可以选择准备远程登录浏览器，该选项默认跳过。
3. **复制连接码。** 安装完成后，将最后一行粘贴到 Mac 端。以后重新运行同一个向导，就能修改地址或补装工具。

## 自动选源

安装器通过 Cloudflare 的出口地区代码识别中国大陆（CN），查询失败时尝试 IPIP。查询均有短超时。可用的公网出口 IP 会复用为地址建议，SSH 会话与网卡上的公网地址优先。

| 下载项目 | 中国大陆出口 | 海外出口 |
|---|---|---|
| Python 3、OpenSSH、tmux、Podman 等 APT 包 | 清华 Debian / Ubuntu 镜像，Ubuntu ARM 使用 ubuntu-ports | VPS 已配置的系统源 |
| 可选 Chromium 登录浏览器 | DaoCloud 的 Docker Hub 镜像 | LinuxServer 官方仓库 |
| 可选 Claude Code | 已安装则复用，缺少时默认跳过。主动选装会连接 Anthropic 官方源 | Anthropic 官方稳定版 |

无法判断地区时先用系统源和官方镜像。APT 索引或包下载失败、容器镜像拉取失败时会自动尝试另一条线路。国内 APT 源仅对这次安装生效，沿用发行版签名校验。两个 Chromium 源使用同一个上游多架构镜像摘要。已备好依赖时，直接运行下载的脚本、跳过可选工具也能生成连接码。[清华镜像](https://mirrors.tuna.tsinghua.edu.cn/) · [DaoCloud 镜像](https://github.com/DaoCloud/public-image-mirror)

Claude 的服务可用地区以 Anthropic 公布的范围为准。[官方支持地区](https://www.anthropic.com/supported-countries)

## 在 Mac 上连接

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

安装 tmux 后，工作区能接回已有会话。安装 Claude Code 后，工作区会启动 Claude Code。两个工具都跳过时，可以在远端工程目录使用 Shell。选择 Claude Code 时，向导从 `https://claude.ai/install.sh` 下载并执行官方稳定版安装命令。如果 VPS 访问不了官方源，选择「跳过，继续安装向导」即可继续配置 SSH 和同步。[Claude Code 安装文档](https://code.claude.com/docs/en/setup)

点击「登录 Claude」时，VPS 才会启动临时 Chromium。安装器优先使用当前用户可用的本机 Podman 或 Docker，缺少运行时时通过 apt 安装 Podman。使用新版 Mac 客户端打开浏览器，首次出现容器的自签名证书提示时，核对地址为 Termlo 面板显示的本机回环地址。浏览器访问用户名为 `termlo`，点「复制临时密码」即可填写。然后在远程 Chromium 中打开 Claude 终端给出的授权链接，按官方页面提示完成登录。「结束登录」会关闭隧道并清理本次容器。[Chromium 镜像文档](https://docs.linuxserver.io/images/docker-chromium/) · [Claude 登录说明](https://code.claude.com/docs/en/authentication)

## 从源码运行

在源码目录运行 `bash bootstrap.sh` 可调试安装器。修改源码后运行 `bash build-installer.sh`，同时生成可单独分发的 `install.sh` 和兼容旧链接的 `dist/termlo-install.sh`，两份内容相同。国内下载站可以原样托管同一文件。运行 `python3 -B -m unittest discover -s tests -v` 验证交互安装和下载线路。
