# xrayctl Alpine/OpenRC 版

这是与仓库根目录 systemd 版完全分离的 Alpine Linux 包。它使用 `apk` 管理依赖、使用 OpenRC 管理 Xray 服务，不会改动根目录的 `install.sh` 和 `xrayctl.sh`。

当前版本：`1.0.1-alpine`

## 一键安装

Alpine 默认自带 BusyBox `wget`，可直接运行：

```sh
wget -qO- https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/main/alpine/install.sh | sh
```

如果已经安装 curl：

```sh
curl -fsSL https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/main/alpine/install.sh | sh
```

安装后运行：

```sh
xrayctl
```

## 支持范围

- Alpine Linux + OpenRC
- x86_64、aarch64、armv7
- VLESS、VMess、Trojan、SOCKS5、HTTP
- RAW、XHTTP、WebSocket、gRPC、TLS、REALITY
- 新建 TLS 入站时选择托管证书；已有 TLS 入站在入站页面内更换证书
- OpenRC 服务管理、用户流量、出站、证书、UFW、BBR 能力检测

Alpine LXC/NAT 主机上的防火墙和 BBR 是否可用取决于宿主机授予的内核权限。
