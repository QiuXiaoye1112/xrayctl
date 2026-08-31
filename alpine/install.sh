#!/bin/sh
# Alpine compatibility bootstrap for the unified xrayctl distribution.

set -eu

SCRIPT_URL="${XRAYCTL_ALPINE_SCRIPT_URL:-https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/main/dist/xrayctl}"
TARGET="${XRAYCTL_COMMAND_PATH:-/usr/local/sbin/xrayctl}"

info() { printf '[xrayctl-alpine] %s\n' "$*"; }
die() { printf '[xrayctl-alpine] 错误: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || die "仅支持 Linux。"
[ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"
if [ ! -r /etc/os-release ] || ! grep -q '^ID=alpine$' /etc/os-release; then
  die "此安装包仅支持 Alpine Linux。"
fi
command -v apk >/dev/null 2>&1 || die "未找到 apk。"

info "正在准备运行环境。"
apk add --no-cache bash curl ca-certificates unzip openssl
update-ca-certificates >/dev/null 2>&1 || true

tmp_base="${XRAYCTL_TMP_DIR:-/var/tmp}"
mkdir -p "$tmp_base" || die "无法创建引导安装临时目录。"
temp_dir=$(mktemp -d "$tmp_base/xrayctl-alpine-bootstrap.XXXXXX")
cleanup() { rm -rf "$temp_dir"; }
trap cleanup EXIT HUP INT TERM

info "正在下载统一 xrayctl 发行版。"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
  --connect-timeout 15 --max-time 120 "$SCRIPT_URL" -o "${temp_dir}/xrayctl"
grep -q '^# xrayctl - Xray Linux terminal manager' "${temp_dir}/xrayctl" \
  || die "下载内容校验失败。"
bash -n "${temp_dir}/xrayctl" || die "下载的 xrayctl 未通过 Bash 语法检查。"

[ ! -L "$TARGET" ] || die "目标路径是符号链接，拒绝覆盖：${TARGET}"
if [ -e "$TARGET" ] && ! grep -q '^# xrayctl - Xray Linux terminal manager' "$TARGET" 2>/dev/null; then
  die "${TARGET} 已存在且不是 xrayctl，拒绝覆盖。"
fi

install -d -m 755 "$(dirname "$TARGET")"
install -m 755 "${temp_dir}/xrayctl" "$TARGET"
info "正在安装或修复 Xray。"
"$TARGET" install "${1-}"
info "安装完成。运行 xrayctl 打开管理菜单。"
