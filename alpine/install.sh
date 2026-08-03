#!/bin/sh
# Bootstrap installer for the standalone xrayctl Alpine/OpenRC edition.

set -eu

SCRIPT_URL="${XRAYCTL_ALPINE_SCRIPT_URL:-https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/main/alpine/xrayctl.sh}"
CHECKSUM_URL="${XRAYCTL_ALPINE_CHECKSUM_URL:-https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/main/alpine/xrayctl.sha256}"
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

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-alpine-bootstrap.XXXXXX")
cleanup() { rm -rf "$temp_dir"; }
trap cleanup EXIT HUP INT TERM

info "正在下载 Alpine 管理脚本。"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
  --connect-timeout 15 --max-time 120 "$SCRIPT_URL" -o "${temp_dir}/xrayctl"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
  --connect-timeout 15 --max-time 60 "$CHECKSUM_URL" -o "${temp_dir}/checksum"

info "正在校验下载内容..."
(cd "${temp_dir}" && sha256sum -c checksum --status) \
  || die "SHA256 校验失败，下载内容可能已损坏。"
grep -q '^# xrayctl - Xray Alpine Linux terminal manager' "${temp_dir}/xrayctl" \
  || die "下载内容格式校验失败。"

install -d -m 755 "$(dirname "$TARGET")"
install -m 755 "${temp_dir}/xrayctl" "$TARGET"
info "正在安装或修复 Xray。"
"$TARGET" install "${1-}"
info "安装完成。运行 xrayctl 打开管理菜单。"
