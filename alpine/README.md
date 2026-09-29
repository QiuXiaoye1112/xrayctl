# xrayctl Alpine/OpenRC 安装说明

Alpine Linux 不再维护独立业务脚本。`alpine/install.sh` 只负责通过 `apk` 准备运行环境，然后安装仓库统一生成的 `dist/xrayctl`。

## 一键安装

```sh
commit=$(wget -qO- "https://api.github.com/repos/QiuXiaoye1112/xrayctl/git/ref/heads/main?xrayctl_cache=$(date +%s)" | sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p')
if [ "${#commit}" -eq 40 ]; then
  wget -qO- "https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/${commit}/alpine/install.sh" | sh
else
  echo '无法确认 xrayctl main 提交版本，安装已取消。' >&2
fi
```

已经安装 curl 时也可以运行：

```sh
commit=$(curl -fsSL "https://api.github.com/repos/QiuXiaoye1112/xrayctl/git/ref/heads/main?xrayctl_cache=$(date +%s)" | sed -n 's/.*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p')
if [ "${#commit}" -eq 40 ]; then
  curl -fsSL "https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/${commit}/alpine/install.sh" | sh
else
  echo '无法确认 xrayctl main 提交版本，安装已取消。' >&2
fi
```

安装后运行：

```sh
xrayctl
```

## 平台实现

- 依赖安装：`apk`
- 服务管理：OpenRC (`rc-service` / `rc-update`)
- Xray core：下载官方 release asset 并校验 SHA-256
- 支持架构：x86_64、aarch64、armv7
- 配置、协议、用户、出站、分享、证书、事务和卸载逻辑：与 systemd 平台共用同一份源码和发行文件

Alpine LXC/NAT 主机上的端口与 BBR 管理能力取决于宿主机授予的内核权限。
