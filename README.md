# VLESS + Reality 单用户一键部署

面向个人使用的极简部署脚本：一台 Ubuntu VPS、一个 `owner`、一个 VLESS Reality 节点和一个订阅链接。

公开版不包含多服务器管理、Cloudflare、域名、用户分配、流量统计、限额或超额拦截。用户只需要填写一个不会进入 Git 的 `config.yaml`，然后运行 `./deploy.sh`。

## 自动完成的工作

- 在全新 Ubuntu VPS 上安装 Xray Core。
- 生成一个 VLESS Reality UUID、密钥和 short ID。
- 在 TCP 443 上运行单个 Reality 入站。
- 开启 BBR，并放行 SSH、443 和订阅端口。
- 生成一个兼容 Clash Verge Rev / Mihomo 的静态订阅。
- 使用随机 token 通过裸 IP HTTP 地址提供订阅。
- 把完整订阅地址保存到本机 `output/subscription.txt`。

## 使用条件

- 本机：macOS 或 Linux，具备 Bash、Python 3、SSH 和 SCP。
- VPS：全新的 Ubuntu 22.04/24.04，能够以 `root` 登录。
- VPS 的 TCP 443 和订阅端口（默认 8443）未被其他服务占用。
- 推荐提前把 SSH 公钥添加到 VPS；也支持 IP + root 密码模式。

## 快速开始：SSH 密钥/别名模式（推荐）

### 1. 克隆并创建本地配置

```bash
git clone https://github.com/ylongw/vless-reality-deploy.git
cd vless-reality-deploy
cp config.yaml.example config.yaml
chmod 600 config.yaml
```

`config.yaml` 已被 `.gitignore` 排除。Git 中只保留不含真实信息的 `config.yaml.example`。

### 2. 准备 SSH 别名

先确保本机可以免密登录 VPS，例如在 `~/.ssh/config` 中配置：

```sshconfig
Host my-vps
  HostName 1.2.3.4
  User root
  IdentityFile ~/.ssh/id_ed25519
```

确认连接：

```bash
ssh my-vps
```

### 3. 填写 `config.yaml`

```yaml
server:
  name: "My Reality"
  sub_port: 8443
  address: ""
  reality_sni: "www.samsung.com"

ssh:
  mode: "key"
  host: "my-vps"
  user: ""
  port: ""
  password: ""
```

密钥模式下，`ssh.host` 可以直接使用 `~/.ssh/config` 中的 Host 别名。`server.address` 留空时，脚本会通过 `ssh -G` 解析该别名的 `HostName`，并将它用于节点和订阅地址；如 HostName 不是 VPS 的公网地址，请显式填写 `server.address`。

### 4. 检查并部署

```bash
./deploy.sh --dry-run
./deploy.sh
```

`--dry-run` 只检查本机依赖、SSH、root 身份、远端服务和端口，不会上传或修改服务器。

部署成功后：

```bash
cat output/subscription.txt
```

把输出的 URL 添加到 Clash Verge Rev 或其他兼容 Mihomo/Clash Meta 的客户端即可。

## IP + root 密码模式

如果 VPS 还没有配置 SSH 公钥，可以把同一份 `config.yaml` 改为：

```yaml
server:
  name: "My Reality"
  sub_port: 8443
  address: ""
  reality_sni: "www.samsung.com"

ssh:
  mode: "password"
  host: "1.2.3.4"
  user: "root"
  port: 22
  password: "你的 root 密码"
```

密码模式下 `server.address` 同样可以留空，脚本会直接使用 `ssh.host` 的 VPS IP，因此 IP 只需要填写一次。

密码模式要求本机已安装 `sshpass`。脚本通过 `SSHPASS` 环境变量调用它，不会把密码放进 SSH 命令参数或终端日志；但密码仍以明文保存在本地 `config.yaml` 中，因此推荐优先使用密钥模式，并保持文件权限为 `600`。

安装好 `sshpass` 后使用同样的命令：

```bash
./deploy.sh --dry-run
./deploy.sh
```

## 配置字段

| 字段 | 必填 | 说明 |
|---|---|---|
| `server.name` | 否 | 客户端显示的节点名称，默认 `Reality` |
| `server.sub_port` | 否 | 裸 IP HTTP 订阅端口，默认 `8443` |
| `server.address` | 否 | 节点/订阅使用的公网 IP、IPv6 或域名；留空时从 SSH 配置推导 |
| `server.reality_sni` | 否 | Reality 握手目标，默认 `www.samsung.com` |
| `ssh.mode` | 是 | `key` 或 `password` |
| `ssh.host` | 是 | 密钥模式为 SSH Host 别名；密码模式为 VPS IP/主机名 |
| `ssh.user` | 密码模式 | 密码模式默认 `root`；密钥模式留空可沿用 SSH config |
| `ssh.port` | 否 | 密钥模式留空可沿用 SSH config；密码模式默认填写 `22` |
| `ssh.password` | 密码模式 | VPS root 密码；真实配置不会进入 Git |

## 防止误覆盖

`./deploy.sh` 默认只接受全新 VPS。如果发现 `/usr/local/etc/xray/config.json`，脚本会停止，防止覆盖现有 Reality 私钥、UUID 和订阅。

只有确定要完全重装并让客户端重新导入时才运行：

```bash
./deploy.sh --force
```

强制重装前，远端脚本会保留带 UTC 时间戳的旧 Xray 配置和旧订阅文件备份。

## 文件说明

| 文件 | 说明 |
|---|---|
| `config.yaml.example` | 可公开的配置模板 |
| `config.yaml` | 用户本地真实配置，已被 Git 忽略 |
| `deploy.sh` | 用户执行的本地一键部署入口 |
| `read_config.py` | 无第三方依赖的精简 YAML 配置读取器 |
| `install_vless.sh` | 由 `deploy.sh` 临时上传并在 VPS 上执行的安装脚本 |
| `output/subscription.txt` | 本地生成的完整订阅地址，已被 Git 忽略且权限为 `600` |

## 安全说明

- VLESS Reality 节点流量本身使用 Reality/TLS；订阅 URL 是另一条独立链路。
- 为了保持裸 IP 和零域名依赖，订阅使用 HTTP。随机 token 可以防止地址被轻易猜中，但不能防止链路上的被动监听。
- 不要公开 `config.yaml`、`output/subscription.txt` 或 VPS 上的 `/root/vless_subscription.txt`。
- 如需加密订阅分发，应自行增加 HTTPS/域名；本仓库刻意不包含 Cloudflare 和证书自动化。
- 远端安装会启用 UFW，并在启用前放行配置中的 SSH 端口、443 和订阅端口。

## License

MIT
