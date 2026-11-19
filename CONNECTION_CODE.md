# Termlo VPS 连接码 v1

一个连接码描述一台 VPS 的 SSH 入口。用户从受信任的 VPS 控制台或已有 SSH 会话复制整行，在 Mac 的「添加服务器 → 连接码」中粘贴。SSH 登录使用该 VPS 已授权的 Mac 密钥。多个工作区可以共用这台服务器，各自选择本地目录、远端目录和同步方式。

## 格式

```text
termlo://connect/<payload>
```

生成端将下表中的字段序列化为 UTF-8 JSON，用 Base64URL 编码，去掉末尾的 `=`，再拼到固定前缀后面。整条码占一行。JSON 字段顺序自由。编码采用 [RFC 4648 §5](https://www.rfc-editor.org/rfc/rfc4648#section-5)。

| 字段 | 类型 | 生成规则 | 含义 |
| --- | --- | --- | --- |
| `version` | 整数 | 必填，固定为 `1` | 连接码格式版本 |
| `host` | 字符串 | 必填 | Mac 可以访问的 VPS 域名或 IP。端口单独填写 |
| `user` | 字符串 | 必填 | 实际用于 SSH 登录的远端用户名 |
| `fingerprint` | 字符串 | 必填 | VPS 的 SSH **主机公钥**指纹。格式为 `SHA256:` 加 43 个标准 Base64 字符，省略末尾填充 |
| `port` | 整数 | 可选，默认 `22` | Mac 连接的 SSH 端口，范围为 1 到 65535。经过端口映射时填对外端口 |
| `name` | 字符串 | 可选，默认使用 `host` | Mac 上显示的服务器名称，填写时须含非空白字符 |

生成端只输出上述连接参数。指纹取自 SSH 服务实际使用的一把主机公钥。例如，启用 Ed25519 主机密钥的 VPS 可以运行以下命令，取输出中的 `SHA256:…` 字段。[OpenSSH ssh-keygen](https://man.openbsd.org/ssh-keygen.1)

```sh
ssh-keygen -E sha256 -lf /etc/ssh/ssh_host_ed25519_key.pub
```

## 可粘贴的示例

下面是同一份配置的明文和完整连接码。示例域名和指纹仅供验证导入。

```json
{
  "version": 1,
  "host": "vps.example.com",
  "port": 2222,
  "user": "dev",
  "fingerprint": "SHA256:bbXpuKG6zhzdmnxq256TlqzFBzRl2f6OOg722cYNbU8",
  "name": "开发机"
}
```

```text
termlo://connect/eyJ2ZXJzaW9uIjoxLCJob3N0IjoidnBzLmV4YW1wbGUuY29tIiwicG9ydCI6MjIyMiwidXNlciI6ImRldiIsImZpbmdlcnByaW50IjoiU0hBMjU2OmJiWHB1S0c2emh6ZG1ueHEyNTZUbHF6RkJ6UmwyZjZPT2c3MjJjWU5iVTgiLCJuYW1lIjoi5byA5Y-R5py6In0
```

## Mac 导入规则

- 导入时校验版本、必填字段、字段类型和取值。遇到未知版本时提示更新，遇到未知 JSON 字段时忽略该字段。
- 为兼容已有输入，Mac 也接受原始 JSON。省略 `version` 时按 v1 解析，旧字段名 `hostFingerprint` 作为 `fingerprint` 的别名。新生成的码统一写 `version` 和 `fingerprint`。
- 测试或建立 SSH 连接时，Mac 检查服务器出示的主机公钥是否匹配指纹。指纹不匹配时停止连接，提示用户在 VPS 控制台核对。
