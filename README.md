# xrayctl

`xrayctl` 是一个面向 systemd Linux 服务器的单文件 Xray 管理脚本。它使用 XTLS 官方安装器安装核心，使用 Xray 自带的 `run -test` 检查每次配置变更，并在服务重启失败时自动回滚配置。

## 功能

- 安装、修复、指定版本安装、升级、保留配置卸载、彻底卸载
- VLESS、VMess、Trojan、Shadowsocks、SOCKS5、HTTP 入站
- RAW、XHTTP、WebSocket、gRPC 传输
- REALITY、TLS、无传输安全（仅建议可信私网）
- 节点新增、修改监听信息、修改传输、安全方式、删除、JSON 高级编辑
- 多用户新增、重命名、重置凭据、删除
- VLESS、VMess、Trojan、Shadowsocks 分享链接及 Base64 订阅内容
- Let's Encrypt 独立模式签发、自动续期部署钩子、已有证书导入
- 配置校验、日志级别、systemd 服务与日志管理
- UFW/firewalld 端口管理、BBR、系统诊断
- 配置/元数据/托管证书的完整备份和安全恢复
- 安装后通过 `xrayctl` 快捷命令启动

## 支持环境

- 使用 systemd 的 Linux
- Debian、Ubuntu、RHEL、CentOS、Rocky Linux、AlmaLinux、Fedora、Arch Linux、openSUSE
- x86_64、ARM 等具体架构范围由 XTLS 官方安装器决定
- 以 root 身份运行写操作

## 快速开始

一键安装：

```bash
curl -fsSL https://github.com/QiuXiaoye1112/xrayctl/raw/refs/heads/main/install.sh | sudo bash
```

指定 Xray 版本：

```bash
curl -fsSL https://github.com/QiuXiaoye1112/xrayctl/raw/refs/heads/main/install.sh | sudo bash -s -- 26.3.27
```

如果希望先检查脚本再执行，可以手动下载：

```bash
curl -fLO https://github.com/QiuXiaoye1112/xrayctl/raw/refs/heads/main/xrayctl.sh
chmod +x xrayctl.sh
sudo ./xrayctl.sh install
xrayctl
```

推荐的新节点组合是 `VLESS -> RAW -> REALITY`。它不需要域名证书，但应认真选择 REALITY 目标；脚本会提示不要使用可能导致开放转发风险的 CDN 目标。

如果使用 TLS：

1. 确认域名的 A/AAAA 记录已经指向服务器。
2. 在云平台安全组和系统防火墙开放 TCP 80。
3. 从“TLS 证书管理”签发证书。
4. 新建 TLS 节点时选择生成的 `.crt` 和 `.key` 文件。
5. 开放节点实际监听端口，通常是 TCP 443。

## 常用命令

```bash
xrayctl                          # 交互菜单
xrayctl status                   # 状态
xrayctl update                   # 升级核心
xrayctl inbound list             # 节点列表
xrayctl inbound add              # 新建节点
xrayctl inbound modify TAG       # 修改监听地址/端口/公网地址
xrayctl inbound transport TAG    # 修改传输和安全方式
xrayctl inbound delete TAG       # 删除节点
xrayctl client add TAG           # 添加用户
xrayctl client rename TAG OLD NEW
xrayctl client rotate TAG USER   # 重置 UUID/密码
xrayctl client delete TAG USER
xrayctl link TAG                 # 分享链接
xrayctl subscription             # 全部节点 Base64 订阅内容
xrayctl config check             # JSON + Xray 核心检查
xrayctl logs 100                 # 最近 100 行日志
xrayctl backup                   # 完整备份
xrayctl restore /path/backup.tar.gz
xrayctl cert issue example.com admin@example.com
xrayctl diagnose
```

完整命令帮助：

```bash
xrayctl help
```

## 默认路径

| 内容 | 路径 |
| --- | --- |
| Xray 核心 | `/usr/local/bin/xray` |
| Xray 配置 | `/usr/local/etc/xray/config.json` |
| 管理元数据 | `/usr/local/etc/xray/xrayctl.meta.json` |
| 托管证书 | `/usr/local/etc/xray/certs/` |
| 配置备份 | `/var/backups/xrayctl/` |
| 快捷命令 | `/usr/local/sbin/xrayctl`，并链接到 `/usr/local/bin/xrayctl` |

路径可通过 `XRAYCTL_*` 环境变量覆盖，脚本顶部列出了全部变量。

## 安全说明

- VLESS 或 Trojan 暴露在公网时不要选择“无传输安全”。这个选项只用于可信私网。
- SOCKS5 无认证模式只应监听 `127.0.0.1`、`::1` 或受控内网。
- 脚本不会在删除节点时自动关闭端口，避免误伤共享同一端口的其他服务；可用 `xrayctl firewall close PORT` 手动关闭。
- 分享链接、配置和备份含有 UUID 或密码，应按密钥材料保护。
- 云厂商安全组不受 UFW/firewalld 命令控制，需要在云控制台单独设置。
- VMess、传统 Trojan 和 Shadowsocks 仍被支持，但当前 Xray 核心会提示这些方案不再是首选；新部署优先使用 VLESS + REALITY/TLS。
- 请遵守服务器所在地法律、服务商条款和网络使用政策。

## NAT 主机

创建或修改节点时，脚本会分别询问：

- **监听端口（内网端口）**：Xray 在主机内部实际监听的端口。
- **客户端公网端口**：NAT 服务商分配给你的外部映射端口。

例如服务商映射 `公网 45678 -> 内网 12345`，节点的监听端口填 `12345`，客户端公网端口填 `45678`。分享链接和订阅会自动使用 `45678`，防火墙则放行本机的 `12345`。

NAT 主机还需要注意：

- 必须在服务商面板建立对应的 TCP 端口映射，脚本无法替你修改服务商的 NAT 面板。
- 推荐使用 VLESS + REALITY，通常不需要申请域名证书。
- Let's Encrypt 独立签发要求公网 TCP 80 能映射到本机 80；没有 80 端口时请使用 REALITY 或导入已有证书。
- 如果是纯 IPv6 出站网络，请按下方说明设置 `XRAYCTL_APT_FORCE_IPV4=0`。

## 回滚与卸载

每次应用配置前会在 `/var/backups/xrayctl/` 创建带时间戳的配置备份。新配置通过核心检查后才会替换当前配置；如果原服务正在运行且重启失败，脚本会恢复上一份配置。

```bash
xrayctl uninstall               # 卸载核心，保留配置
xrayctl uninstall --purge       # 删除 Xray 配置、证书和日志
```

两种卸载方式都会先创建备份；备份目录默认保留，便于恢复。

## 安装卡在 APT

如果旧版安装过程停在 `0% [Waiting for headers]`，可按 `Ctrl+C` 中止后重新执行一键安装。当前版本会优先从 [jq 官方 GitHub 仓库](https://github.com/jqlang/jq/releases)下载并校验静态版 jq，从而绕过 APT；其他依赖仍会使用带连接超时、重试次数和 180 秒总超时的 APT，不再无限等待失效的软件源。

仅有 IPv6 网络的服务器可以关闭 IPv4 强制模式：

```bash
curl -fsSL https://github.com/QiuXiaoye1112/xrayctl/raw/refs/heads/main/install.sh | sudo env XRAYCTL_APT_FORCE_IPV4=0 bash
```
