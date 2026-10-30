# xrayctl

`xrayctl` 是一个同时支持 systemd 与 Alpine/OpenRC 的 Xray 管理工具。开发源码按领域保存在 `src/`，发布时构建为单文件 `dist/xrayctl`。交互界面按“先看对象、再直接操作”设计；每次生产配置变更都会先创建 candidate，执行 JSON/Xray 校验，再联合提交 config 与 metadata，服务重启失败时一起回滚。

当前版本：`1.4.0`

> Alpine/OpenRC 平台差异由 `platform.sh` 统一处理。参见 [Alpine/OpenRC 说明](alpine/README.md)。

## 功能

- 主菜单彻底删除受管理资源
- VLESS、SOCKS5、HTTP 入站
- 新建 SOCKS5/HTTP 入站时用户名可留空；留空即无认证，并自动跳过密码输入
- RAW、XHTTP、WebSocket 传输
- REALITY、TLS、无传输安全（仅建议可信私网）
- 入站新增、重命名、修改监听信息、修改传输、安全方式、删除、JSON 高级编辑
- 删除入站时同步删除其中的全部用户、专属出站规则和其他入站路由引用
- 入站管理页直接显示完整配置文件路径，并可输出全部用户的原始分享链接
- 首页直接显示全部入站的协议、端口、传输、安全方式
- 多用户新增、重命名、更换 UUID/密码、删除；用户列表直接显示当前凭据
- 更换凭据时支持自定义输入；UUID 格式错误会要求重试，密码或 UUID 留空则自动生成
- 密码输入过程可见；留空时自动生成并在添加完成后显示（请避免在共享终端或录屏中操作）
- SOCKS5、HTTP 出站新增、入站绑定和删除
- VLESS 分享链接与 Base64 订阅输出；SOCKS5、HTTP 客户端链接输出
- Let's Encrypt 域名/公网 IP 签发、自动续期、已有证书导入和安全删除
- IP 证书优先免 APT 创建 Certbot 环境；证书依赖安装均带硬超时，避免 NAT 主机无限等待软件源
- 配置校验、systemd/OpenRC 服务与日志管理
- 按入站累计 TCP/UDP 流量，展示统一的月度周期；可自定义每月起始日期和时间，只保留当前周期的记录
- VLESS 用户可分别查看流量并设置月度额度；超额后只限制对应用户，到期或手动重置后恢复
- 首次设置用户额度时自动启用额度检查；没有额度的用户不受用户级限制
- SOCKS5、HTTP 等协议继续支持入站级流量统计；用户限额管理页面按入站标签分组展示 VLESS 用户
- 配置校验失败时显示 Xray 核心的原始错误，便于准确定位问题
- BBR 环境检测和开启/关闭
- 通过 `xrayctl` 快捷命令启动
- 新增入站时自动探测公网地址；双栈同时列出 IPv4 和 IPv6，单栈只显示可用地址
- 新增入站按”协议 → 加密 → 传输 → 证书/REALITY → 地址端口 → 客户端地址 → 用户”排列
- TLS 自动读取证书域名/IP 作为 SNI；选择证书后直接使用该 SNI 作为客户端连接地址，不再重复选择
- 证书同时包含具体域名和通配符域名时，只显示可直接使用的具体域名

## 交互菜单

主菜单只保留日常管理需要的入口。入站列表、服务状态、证书数量、BBR 状态会直接显示。

```text
Xray Linux 管理脚本
├─ 入站管理（进入即显示入站列表）
│  ├─ 显示完整配置文件路径
│  ├─ 新增入站
│  ├─ 管理已有入站
│  │  ├─ 分享信息 / 客户端配置
│  │  ├─ 用户管理（进入即显示凭据列表）
│  │  ├─ 修改入站信息
│  │  │  ├─ 修改入站名称
│  │  │  ├─ 修改地址和端口
│  │  │  └─ 修改传输和安全方式
│  │  └─ 查看 JSON
│  ├─ 全部分享链接（输出各入站用户的原始分享链接）
│  └─ 删除入站（同时删除该入站内的全部用户和关联规则）
├─ 出站管理
│  ├─ 查看入站当前出站规则
│  ├─ 选择入站并设置出站
│  ├─ 添加 SOCKS5/HTTP 出站
│  ├─ 查看手动添加的代理出站详情
│  └─ 删除出站
├─ TLS 证书（签发、导入、查看、续期测试）
├─ 流量限制：按入站标签查看并管理 VLESS 用户额度
├─ 流量信息
│  ├─ 查看/刷新各入站当前月度周期流量
│  ├─ 设置统一月度统计起点
│  └─ 安装后自动开启每分钟采集
├─ 服务管理（启停、重启、自启、查看日志、BBR）
└─ 卸载
```

只有一个入站或一张证书时会自动选中；有多个时才显示选择列表。输入时按 `Ctrl+D` 可取消当前操作，不保存未完成的修改，也不会显示内部错误。

## 支持环境

- 使用 systemd 的 Linux：Debian、Ubuntu、RHEL、CentOS、Rocky Linux、AlmaLinux、Fedora、Arch Linux、openSUSE
- Alpine Linux + OpenRC
- systemd 平台使用 XTLS 官方安装器；Alpine/OpenRC 支持 x86_64、aarch64、armv7
- 以 root 身份运行写操作

### 与 sbctl 共存

xrayctl 可以与 sbctl/sing-box 同时安装。两者使用独立的命令、服务、配置、metadata、备份和 Certbot 环境。新增 Xray 入站时只依据当前 Xray 配置和 `ss`/`netstat` 的实时监听结果避开端口，自动端口同时固定避开 Hysteria2 默认跳跃范围 `30000-50000`。xrayctl 不读取 sbctl 的配置、metadata 或自定义跳跃范围；已停止服务的端口不作预留，之后重新启动时仍可能因端口已被占用而失败。

BBR 是主机全局开关，xrayctl 与 sbctl 都读取内核当前状态，也都可以开启或关闭。关闭时会清理两者的已知持久化文件，避免重启后被另一份配置重新开启；第三方 sysctl 配置不会被修改。两套证书环境保持隔离，但 Certbot 操作会通过 `/run/lock/certbot.lock` 串行执行，避免同时操作 80 端口/nginx；同一个域名仍建议只交给一个工具自动签发和续期，避免重复申请。

流量统计同样完全隔离：xrayctl 使用 `xrayctl_traffic` nftables 表（或 `XRAYCTL_TRAFFIC_IN/OUT` iptables 链），sbctl 使用自己的对象。脚本只删除带有自身注释的规则；检测到同名但不属于 xrayctl 的规则时会拒绝覆盖。

## 安装

通用 Linux（需要 root）：

```bash
curl -fsSL https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/main/install.sh | sudo bash
```

Alpine Linux（以 root 运行）：

```sh
wget -qO- https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/main/alpine/install.sh | sh
```

安装器会安装管理命令和 Xray 核心；运行 `xrayctl` 进入菜单，或使用 `xrayctl install [版本]` 安装或修复核心。bootstrap 下载的是仓库 main 分支的发行文件；本地修改发布到该分支后上述远程命令才会生效。

## 常用命令

```bash
xrayctl                          # 交互菜单
xrayctl status                   # 状态
xrayctl inbound list             # 入站列表
xrayctl inbound add              # 新建入站
xrayctl inbound rename OLD NEW   # 修改入站名称
xrayctl inbound modify TAG       # 修改监听地址/端口/公网地址
xrayctl inbound transport TAG    # 修改传输和安全方式
xrayctl inbound disable TAG --yes # 暂停该入站，保留配置和流量额度
xrayctl inbound enable TAG       # 恢复入站
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
xrayctl subscription [TAG]      # Base64 订阅内容
xrayctl config check             # JSON + Xray 核心检查
xrayctl logs 100                 # 最近 100 行日志
xrayctl traffic                  # 查看当前月度周期各入站总流量
xrayctl traffic period set 22 18:30 # 每月 22 日 18:30 开始新的统计周期
xrayctl traffic period show      # 查看当前周期起止时间
xrayctl traffic user enable      # 配置本机用户统计 API
xrayctl traffic user show        # 按入站查看 VLESS 用户流量
xrayctl traffic user set TAG USER 100 15 18:30 # 用户每月 100 GB
xrayctl traffic user remove TAG USER --yes # 取消用户额度
xrayctl traffic user reset TAG USER --yes  # 清零用户流量和当前额度周期
xrayctl cert issue example.com admin@example.com
```

完整命令帮助：

```bash
xrayctl help
```

“全部入站”独立累计当前统计周期的总流量。清空指定入站记录时，只清空该入站统计记录；已删除入站会移除整条记录。两种情况都不减少“全部入站”；清空全部记录时才会同时清空总量。进入新的月度统计周期后总量重新累计。升级会从现有记录初始化总量，升级前已经清空的数据无法恢复。

流量显示和月度限额按代理经过服务器的两段链路估算：入站端口收到及发出的字节之和再乘以 2。`/var/lib/xrayctl/traffic.json` 中的 `daily`、`cycles` 和限额 `usedBytes` 均采用此口径，`accountingMultiplier: 2` 标记已迁移的数据库。升级时旧记录只换算一次，额度 `quotaBytes` 不变。这个数值不是网卡精确账单；协议开销、重传及非代理流量可能造成差异。

用户级统计通过只监听 `127.0.0.1` 的 Xray StatsService 读取 VLESS 用户的上下行**代理载荷字节**。Xray 在[调度器](https://github.com/XTLS/Xray-core/blob/v26.3.27/app/dispatcher/default.go)中对每个方向的载荷只计一次，并没有分别统计两段网络链路；因此原始上下行数据各保存一次，显示与额度按入站现有约定估算两段链路，分别将上下行增量乘以 2。这是估算而非两段链路的实测值：用户统计不包含入站防火墙计数中的协议开销和重传，因此各用户用量之和不一定等于入站用量。首次进入流量限制页时会自动配置用户统计并开始累计；应用 API 配置可能重启一次 Xray。脚本为各 VLESS 用户生成互不冲突的内部统计标识，显示名称、UUID 和分享链接不变。原有本机 API 若有安全的直接本机监听会保留并复用；已有公开或无法确认安全性的 API 布局会拒绝自动修改。

流量限制只按用户额度执行，入站统计用于查看各入站和全部入站的用量。修改用户额度保留当前已用量，取消额度不删除用户，手动清零保留额度配置。用户超额时在现有路由前插入仅匹配该用户与入站的黑洞规则；规则保存在 Xray 配置中。当前应用和恢复这些规则需要通过配置事务重启 Xray，可能短暂中断其他连接。采集按现有定时周期执行，不是精确的字节级硬限额，实际使用可能超过额度。Xray 重启前未采集的用户流量无法追回；API 失败时保留上次用户累计和封禁状态，入站采集继续执行。

采样跨越周期边界时，无法将两次采样之间的流量精确拆分；该间隔归入采样时所在的新周期。第一次启用用户统计前的用户用量无法从入站历史中拆分。升级时保留已有入站统计历史与用户额度，并删除旧版本的入站额度数据。

## 默认路径

| 内容 | 路径 |
| --- | --- |
| Xray 核心 | `/usr/local/bin/xray` |
| Xray 配置 | `/usr/local/etc/xray/config.json` |
| 管理元数据 | `/usr/local/etc/xray/xrayctl.meta.json` |
| 托管证书 | `/usr/local/etc/xray/certs/` |
| 手动备份 | `/var/backups/xrayctl/` |
| 流量记录 | `/var/lib/xrayctl/traffic.json` |
| Xray 日志 | `/var/log/xray/` |
| 快捷命令 | `/usr/local/sbin/xrayctl`，并链接到 `/usr/local/bin/xrayctl` |

路径可通过 `XRAYCTL_*` 环境变量覆盖，脚本顶部列出了全部变量。

## 安全说明

- VLESS 暴露在公网时不要选择“无传输安全”。这个选项只用于可信私网。
- SOCKS5/HTTP 无认证模式只应监听 `127.0.0.1`、`::1` 或受控内网。
- 新建 VLESS、SOCKS5、HTTP 入站均默认监听 `0.0.0.0`；仅供本机使用时可手动填写 `127.0.0.1`。
- SOCKS5/HTTP 出站本身不加密，只应连接可信代理；HTTP 出站仅支持 TCP。
- 用户管理页和代理出站详情会直接显示 UUID 或密码，请避免在录屏、截图和共享终端中泄露。
- 分享链接、配置和手动备份含有 UUID 或密码，应按密钥材料保护。
- 流量统计依赖 nftables 或 iptables，并会创建独立计数/阻断规则；云厂商安全组仍需在控制台单独管理。
- 流量统计在安装后默认开启，每分钟自动采集；菜单和命令行不提供关闭开关。升级会自动恢复旧配置中的停用状态，并保留已有流量记录。
- 月度统计起点只影响流量展示，各入站的额度重置时间保持不变。旧记录按整日近似归入新周期，非零点起始时间的旧记录无法精确拆分；每月 29–31 日在短月份取该月最后一天。
- 进入下一月度统计周期后，上一周期的流量记录会在下次采集时清理；额度周期的已用量按各入站自己的重置时间处理。
- 云厂商安全组需要在云控制台单独设置。
- 配置校验只接受上述协议和传输；其他入站协议或传输会被拒绝。
- 请遵守服务器所在地法律、服务商条款和网络使用政策。

## 删除

主菜单“卸载”进入彻底删除确认，删除受管理资源和备份，并检查残留。资源归属和路径检查仍会保护无关数据。

## 开发、构建与测试

源码领域固定为 13 个模块：

```text
core + platform
state
security + certificate
protocols
inbound + outbound + share + traffic
service + uninstall
menu
```

`xrayctl.sh` 只是开发入口，所有模块加载集中在这里。模块自身禁止 `source` 其他文件。构建单文件：

```bash
bash scripts/build.sh
bash -n dist/xrayctl
```

完整检查：

```bash
bash tests/run.sh
```

测试覆盖 Bash syntax、ShellCheck、重复函数、模块 source 依赖、validator、协议 fixture、config/metadata 联合事务、migration 幂等、inbound/client/outbound 生命周期、流量统计与月度限额、防火墙隔离、CLI 与单文件构建。CI 还会下载并校验当前 Xray release，用真实核心检查默认配置和全部协议 fixture，并在 Alpine 容器复跑统一测试套件。本地已有 Xray 二进制时可执行：

```bash
XRAYCTL_REAL_XRAY_BIN=/path/to/xray bash tests/integration/test_real_xray.sh
```

同一 Certbot 数据目录存在多个 Let's Encrypt 账户时，已有证书优先沿用 lineage 记录的账户；非交互式新签发可通过 `XRAYCTL_CERTBOT_ACCOUNT=<账户ID>` 明确选择。重构前审计见 [`architecture-audit.md`](architecture-audit.md)。

NAT 容器没有 `NET_ADMIN` 权限时，请使用服务商控制台管理端口。

IP 证书会优先使用现有 Python，通过 PyPA 引导 pip，不安装 `python3-venv` 系统包。只有免 APT 方式不可用时才回退包管理器；APT 默认最多等待 60 秒，pip 默认最多等待 120 秒，可分别通过 `XRAYCTL_CERT_APT_TIMEOUT`、`XRAYCTL_CERT_PIP_TIMEOUT` 调整。

脚本会自动检测 IPv4 连通性：IPv4 可用时 APT 使用 IPv4，只有 IPv6 时自动使用 IPv6，不需要额外安装参数。
