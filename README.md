# xrayctl

`xrayctl` 是一个面向 systemd Linux 服务器的单文件 Xray 管理脚本。交互界面按“先看对象、再直接操作”设计：进入入站管理就能看到全部入站，选中入站后可在同一页管理分享信息、用户、端口和传输方式。它使用 XTLS 官方安装器安装核心，使用 Xray 自带的 `run -test` 检查每次配置变更，并在服务重启失败时自动回滚配置。

当前版本：`1.2.14`

> Alpine Linux 使用独立的 OpenRC 包，不会覆盖本页的 systemd 版。请查看 [Alpine/OpenRC 安装说明](alpine/README.md)。

## 功能

- 安装、修复、指定版本安装、升级、保留配置卸载、彻底卸载
- VLESS、VMess、Trojan、SOCKS5、HTTP 入站
- 新建 SOCKS5/HTTP 入站时用户名可留空；留空即无认证，并自动跳过密码输入
- RAW、XHTTP、WebSocket、gRPC 传输
- REALITY、TLS、无传输安全（仅建议可信私网）
- 入站新增、重命名、修改监听信息、修改传输、安全方式、删除、JSON 高级编辑
- 删除入站时同步删除其中的全部用户、专属出站规则和其他入站路由引用
- 入站管理页直接显示完整配置文件路径，并可输出全部用户的原始分享链接
- 入站上传、下载和总流量统计，以及 VLESS、VMess、Trojan 用户级流量统计（Xray 本次运行期间累计）
- 多用户新增、重命名、更换 UUID/密码、删除；用户列表直接显示当前凭据
- 更换凭据时支持自定义输入；UUID 格式错误会要求重试，密码或 UUID 留空则自动生成
- 密码输入过程可见；留空时自动生成并在添加完成后显示（请避免在共享终端或录屏中操作）
- SOCKS5、HTTP 出站新增、入站绑定和删除
- VLESS、VMess、Trojan 分享链接及 Base64 订阅内容
- Let's Encrypt 域名/公网 IP 签发、自动续期、签发后应用到入站、已有证书导入
- IP 证书优先免 APT 创建 Certbot 环境；证书依赖安装均带硬超时，避免 NAT 主机无限等待软件源
- 配置校验、日志级别、systemd 服务与日志管理
- 配置校验失败时显示 Xray 核心的原始错误，便于准确定位问题
- UFW/firewalld 安装与端口管理、BBR 环境检测和启用、系统诊断
- 安装后通过 `xrayctl` 快捷命令启动
- 新增入站时自动探测公网地址；双栈同时列出 IPv4 和 IPv6，单栈只显示可用地址

## 交互菜单

主菜单只保留日常管理需要的六个入口。入站列表、服务状态、证书数量、BBR 和防火墙状态会直接显示，不再为“查看状态”单独占用一个选项。

```text
Xray Linux 管理脚本
├─ 入站管理（进入即显示入站列表）
│  ├─ 显示完整配置文件路径
│  ├─ 新增入站
│  ├─ 管理已有入站
│  │  ├─ 分享信息 / 客户端配置
│  │  ├─ 用户管理（进入即显示凭据与支持协议的用户流量）
│  │  ├─ 修改入站信息
│  │  │  ├─ 修改入站名称
│  │  │  ├─ 修改地址和端口
│  │  │  └─ 修改传输和安全方式
│  │  └─ 查看 JSON
│  ├─ 订阅链接（输出各入站用户的原始分享链接）
│  └─ 删除入站（同时删除该入站内的全部用户和关联规则）
├─ 出站管理
│  ├─ 查看入站当前出站规则
│  ├─ 选择入站并设置出站
│  ├─ 添加 SOCKS5/HTTP 出站
│  └─ 删除出站
├─ TLS 证书（签发、导入、查看、续期测试）
├─ 服务管理（启停、重启、自启、日志、更新修复）
├─ 系统工具
│  ├─ 防火墙（安装、放行、关闭端口）
│  ├─ BBR
│  ├─ 系统诊断
│  └─ 修复快捷命令
└─ 卸载
```

只有一个入站或一张证书时会自动选中；有多个时才显示选择列表。

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

推荐的新入站组合是 `VLESS -> RAW -> REALITY`。它不需要域名证书。

如果使用 TLS：

1. 选择自动探测到的公网 IPv4/IPv6，或选择“域名/其他地址”。
2. 在云平台安全组和系统防火墙开放 TCP 80。
3. 从“TLS 证书”签发或导入证书。
4. 新建 TLS 入站时选择托管证书；已有 TLS 入站可在该入站的“证书管理”中更换。
5. IP 证书使用 Let’s Encrypt shortlived 配置，需要 Certbot 5.4+，脚本会安装并启用自动续期定时器。

## 常用命令

```bash
xrayctl                          # 交互菜单
xrayctl status                   # 状态
xrayctl update                   # 升级核心
xrayctl inbound list             # 入站列表
xrayctl inbound add              # 新建入站
xrayctl inbound rename OLD NEW   # 修改入站名称
xrayctl inbound modify TAG       # 修改监听地址/端口/公网地址
xrayctl inbound transport TAG    # 修改传输和安全方式
xrayctl inbound delete TAG       # 删除入站
xrayctl outbound list            # 查看入站与出站规则
xrayctl outbound add             # 添加 SOCKS5/HTTP 出站
xrayctl outbound assign TAG OUT  # 为入站选择出站或 direct
xrayctl outbound delete OUT      # 删除出站
xrayctl client add TAG           # 添加用户
xrayctl client rename TAG OLD NEW
xrayctl client rotate TAG USER   # 重置 UUID/密码
xrayctl client delete TAG USER
xrayctl link TAG                 # 分享链接
xrayctl subscription             # 全部入站 Base64 订阅内容
xrayctl config check             # JSON + Xray 核心检查
xrayctl logs 100                 # 最近 100 行日志
xrayctl cert issue example.com admin@example.com
xrayctl firewall install
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
| 手动备份 | `/var/backups/xrayctl/` |
| 快捷命令 | `/usr/local/sbin/xrayctl`，并链接到 `/usr/local/bin/xrayctl` |

路径可通过 `XRAYCTL_*` 环境变量覆盖，脚本顶部列出了全部变量。

## 安全说明

- VLESS 或 Trojan 暴露在公网时不要选择“无传输安全”。这个选项只用于可信私网。
- SOCKS5/HTTP 无认证模式只应监听 `127.0.0.1`、`::1` 或受控内网。
- SOCKS5/HTTP 出站本身不加密，只应连接可信代理；HTTP 出站仅支持 TCP。
- 入站及用户流量由 Xray 内存统计，从服务本次启动开始累计，重启 Xray 后重新计数。
- 用户管理页会直接显示 UUID 或密码，请避免在录屏、截图和共享终端中泄露；VLESS、VMess、Trojan 用户名会保持全局唯一，避免 Xray 合并同名用户流量。
- 脚本不会在删除入站时自动关闭端口，避免误伤共享同一端口的其他服务；可用 `xrayctl firewall close PORT` 手动关闭。
- 分享链接、配置和手动备份含有 UUID 或密码，应按密钥材料保护。
- 云厂商安全组不受 UFW/firewalld 命令控制，需要在云控制台单独设置。
- VMess 和传统 Trojan 仍被支持，但新部署优先使用 VLESS + REALITY/TLS。Shadowsocks 已停止新增和分享；旧入站只保留查看与删除入口。
- 请遵守服务器所在地法律、服务商条款和网络使用政策。

## 回滚与卸载

新增、修改和删除不会创建永久备份。新配置通过核心检查后才会替换当前配置；如果原服务正在运行且重启失败，脚本会使用临时副本恢复旧配置，回滚完成后立即删除临时副本。

```bash
xrayctl uninstall               # 卸载核心，保留配置
xrayctl uninstall --purge       # 删除 Xray 配置、证书和日志
```

两种卸载方式都会先创建备份；备份目录默认保留，便于恢复。

## 安装卡在 APT

如果旧版安装过程停在 `0% [Waiting for headers]`，可按 `Ctrl+C` 中止后重新执行一键安装。当前版本会优先从 [jq 官方 GitHub 仓库](https://github.com/jqlang/jq/releases)下载并校验静态版 jq，从而绕过 APT；其他依赖仍会使用带连接超时、重试次数和 180 秒总超时的 APT，不再无限等待失效的软件源。

防火墙安装会复用已有软件索引；只有全新系统没有索引时才限时刷新，并始终保留包管理器的下载进度。每个阶段默认最多等待 20 秒，可通过 `XRAYCTL_SYSTEM_TOOL_TIMEOUT` 调整。NAT 容器没有 `NET_ADMIN` 权限时会立即跳过并提示使用服务商控制台。

IP 证书会优先使用现有 Python，通过 PyPA 引导 pip，不安装 `python3-venv` 系统包。只有免 APT 方式不可用时才回退包管理器；APT 默认最多等待 60 秒，pip 默认最多等待 120 秒，可分别通过 `XRAYCTL_CERT_APT_TIMEOUT`、`XRAYCTL_CERT_PIP_TIMEOUT` 调整。

脚本会自动检测 IPv4 连通性：IPv4 可用时 APT 使用 IPv4，只有 IPv6 时自动使用 IPv6，不需要额外安装参数。
