#!/usr/bin/env bash
# =====================================================================
#  srvmenu 安装 / 升级脚本
#
#  用法:
#    bash <(curl -sL https://raw.githubusercontent.com/plnl/shell/main/srvmenu/install.sh)
#    bash <(curl -sL .../install.sh) --no-run        # 只装，不进菜单
#    bash <(curl -sL .../install.sh) --uninstall     # 卸载
#
#  做的事: 检查环境 -> 下载 srvmenu.sh -> bash -n 校验 -> 装到 /usr/local/bin
#  可重复执行，等同于升级。脚本本身无配置文件，所有登记表在脚本内。
# =====================================================================
set -euo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

INSTALL_PATH=${INSTALL_PATH:-/usr/local/bin/srvmenu}
SRC_URL=${SRC_URL:-https://raw.githubusercontent.com/plnl/shell/main/srvmenu/srvmenu.sh}
SRC_FALLBACK=${SRC_FALLBACK:-https://cdn.jsdelivr.net/gh/plnl/shell@main/srvmenu/srvmenu.sh}

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
info() { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[x]${N} $*"; }
die()  { err "$*"; exit 1; }

RUN_MENU=1
for arg in "$@"; do
  case "$arg" in
    --no-run)    RUN_MENU=0 ;;
    --uninstall)
      [[ -f "$INSTALL_PATH" ]] || { warn "没装：$INSTALL_PATH 不存在"; exit 0; }
      rm -f "$INSTALL_PATH"
      info "已删除 $INSTALL_PATH"
      exit 0 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "未知参数：$arg（--no-run / --uninstall / --help）" ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "需要 root：sudo bash install.sh"

# bash 版本（数组与 [[ ]] 至少 3.2，CentOS 7 自带 4.2 也够）
if [[ -n "${BASH_VERSINFO:-}" ]] && (( BASH_VERSINFO[0] < 3 )); then
  die "bash 版本过低：${BASH_VERSION}"
fi

# 下载器
if command -v curl >/dev/null 2>&1; then
  DL="curl -fsSL --max-time 60 -o"
elif command -v wget >/dev/null 2>&1; then
  DL="wget -q -T 60 -O"
else
  die "需要 curl 或 wget"
fi

fetch() { # url dest
  local url=$1 dest=$2
  if [[ "$DL" == curl* ]]; then
    curl -fsSL --max-time 60 -o "$dest" "$url"
  else
    wget -q -T 60 -O "$dest" "$url"
  fi
}

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

info "下载 srvmenu.sh"
if ! fetch "$SRC_URL" "$TMP" || [[ ! -s "$TMP" ]]; then
  warn "直连失败，改用 jsDelivr 镜像"
  fetch "$SRC_FALLBACK" "$TMP" || die "两个源都下不来，检查网络或手动 scp 上传"
fi
[[ -s "$TMP" ]] || die "下载到的文件是空的"

bash -n "$TMP" 2>/dev/null || die "下载到的脚本语法检查不通过，已中止（不安装来路不明的文件）"
info "语法检查通过（$(wc -l < "$TMP" | tr -d ' ') 行）"

install -m 755 -o root -g root "$TMP" "$INSTALL_PATH"
info "已安装到 $INSTALL_PATH"

# 环境概览：不阻断，只提示能探测到什么
command -v systemctl >/dev/null 2>&1 || warn "没有 systemctl（非 systemd 系统），服务页会空白"
command -v docker    >/dev/null 2>&1 || warn "没有 docker，容器相关页会空白"
command -v ss        >/dev/null 2>&1 || warn "没有 ss（iproute2），端口页不可用"

echo
info "用法：直接敲 srvmenu 进菜单；srvmenu help 看全部命令"
echo

if [[ $RUN_MENU -eq 1 ]]; then
  exec "$INSTALL_PATH"
fi
