#!/usr/bin/env bash
# Bootstrap installer for QiuXiaoye1112/xrayctl.

set -Eeuo pipefail

readonly SCRIPT_URL="https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/main/xrayctl.sh"
readonly TARGET="/usr/local/sbin/xrayctl"

info() { printf '[xrayctl] %s\n' "$*"; }
die() { printf '[xrayctl] 错误: %s\n' "$*" >&2; exit 1; }

[[ $(uname -s) == Linux ]] || die "仅支持 Linux。"
[[ $(id -u) -eq 0 ]] || die "请使用 root 运行，例如：curl ... | sudo bash"
command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装 curl。"
command -v install >/dev/null 2>&1 || die "缺少 install 命令（通常由 coreutils 提供）。"

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/xrayctl-bootstrap.XXXXXX")
cleanup() { rm -rf "$temp_dir"; }
trap cleanup EXIT

info "正在下载 xrayctl..."
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 120 "$SCRIPT_URL" -o "${temp_dir}/xrayctl"
grep -q '^# xrayctl - Xray Linux terminal manager' "${temp_dir}/xrayctl" \
  || die "下载内容校验失败。"

install -d -m 755 "$(dirname "$TARGET")"
install -m 755 "${temp_dir}/xrayctl" "$TARGET"

info "正在安装/修复 Xray 核心和快捷命令..."
"$TARGET" install "${1-}"

info "安装完成。运行 xrayctl 打开管理菜单。"
