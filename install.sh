#!/usr/bin/env bash
# Bootstrap installer for QiuXiaoye1112/xrayctl.

set -Eeuo pipefail

readonly SCRIPT_OVERRIDE="${XRAYCTL_SCRIPT_URL:-}"
readonly TARGET="${XRAYCTL_COMMAND_PATH:-/usr/local/sbin/xrayctl}"

info() { printf '[xrayctl] %s\n' "$*"; }
die() { printf '[xrayctl] 错误: %s\n' "$*" >&2; exit 1; }

[[ $(uname -s) == Linux ]] || die "仅支持 Linux。"
[[ $(id -u) -eq 0 ]] || die "请使用 root 运行，例如：curl ... | sudo bash"
command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装 curl。"
command -v install >/dev/null 2>&1 || die "缺少 install 命令（通常由 coreutils 提供）。"

bootstrap_tmp_dir() {
  local base=${XRAYCTL_TMP_DIR:-/var/tmp}
  mkdir -p "$base" && mktemp -d "$base/xrayctl-bootstrap.XXXXXX"
}

temp_dir=$(bootstrap_tmp_dir) || die "无法创建引导安装临时目录。"
cleanup() { rm -rf "$temp_dir"; }
trap cleanup EXIT

info "正在下载 xrayctl..."
if [[ -n $SCRIPT_OVERRIDE ]]; then
  download_url=$SCRIPT_OVERRIDE
else
  ref_json=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 \
    --connect-timeout 15 --max-time 30 \
    "https://api.github.com/repos/QiuXiaoye1112/xrayctl/git/ref/heads/main?xrayctl_cache=$(date +%s)") \
    || die "无法查询 xrayctl main 的提交版本。"
  commit=$(printf '%s\n' "$ref_json" | sed -nE 's/.*"sha":[[:space:]]*"([0-9a-f]{40})".*/\1/p')
  [[ $commit =~ ^[0-9a-f]{40}$ ]] || die "无法确认 xrayctl main 的提交版本，拒绝安装可能过期的文件。"
  download_url="https://raw.githubusercontent.com/QiuXiaoye1112/xrayctl/${commit}/dist/xrayctl"
fi
if [[ $download_url == *\?* ]]; then
  download_url="${download_url}&xrayctl_cache=$(date +%s)"
else
  download_url="${download_url}?xrayctl_cache=$(date +%s)"
fi
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 120 "$download_url" -o "${temp_dir}/xrayctl"
grep -q '^# xrayctl - Xray Linux terminal manager' "${temp_dir}/xrayctl" \
  || die "下载内容不是有效的 xrayctl 发行版。"
bash -n "${temp_dir}/xrayctl" || die "下载的 xrayctl 未通过 Bash 语法检查。"

[[ ! -L $TARGET ]] || die "目标路径是符号链接，拒绝覆盖：${TARGET}"
if [[ -e $TARGET ]] && ! grep -q '^# xrayctl - Xray Linux terminal manager' "$TARGET" 2>/dev/null; then
  die "${TARGET} 已存在且不是 xrayctl，拒绝覆盖。"
fi

install -d -m 755 "$(dirname "$TARGET")"
install -m 755 "${temp_dir}/xrayctl" "$TARGET"

info "正在安装/修复 Xray 核心和快捷命令..."
"$TARGET" install "${1-}"

info "安装完成。运行 xrayctl 打开管理菜单。"
