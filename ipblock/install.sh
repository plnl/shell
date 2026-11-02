#!/usr/bin/env bash
# =====================================================================
#  ipblock 安装 / 升级脚本
#
#  用法:
#    bash <(curl -sL https://raw.githubusercontent.com/plnl/shell/main/ipblock/install.sh)
#    bash <(curl -sL .../install.sh) --no-run      # 只装, 不进菜单
#    bash <(curl -sL .../install.sh) --uninstall   # 卸载
#
#  做的事: 检查依赖 -> 下载 ipblock.sh -> 校验 -> 装到 /usr/local/bin
#  可重复执行, 等同于升级(数据目录 /etc/ipblock 不动)
# =====================================================================
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

INSTALL_PATH=/usr/local/bin/ipblock.sh
DATA_DIR=/etc/ipblock
SRC_URL=${SRC_URL:-https://raw.githubusercontent.com/plnl/shell/main/ipblock/ipblock.sh}
SRC_URL_FALLBACK=${SRC_URL_FALLBACK:-https://cdn.jsdelivr.net/gh/plnl/shell@main/ipblock/ipblock.sh}
SELF_URL=${SELF_URL:-https://raw.githubusercontent.com/plnl/shell/main/ipblock/install.sh}

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
info(){ echo -e "${G}[+]${N} $*"; }
warn(){ echo -e "${Y}[!]${N} $*"; }
err(){  echo -e "${R}[x]${N} $*"; }

RUN_MENU=1
DO_UNINSTALL=0
for a in "$@"; do
  case $a in
    --no-run)    RUN_MENU=0 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    -h|--help)
      cat <<EOF
用法:
  bash <(curl -sL $SELF_URL)              # 安装并进入菜单
  bash <(curl -sL $SELF_URL) --no-run     # 只安装, 不进菜单
  bash <(curl -sL $SELF_URL) --uninstall  # 卸载(保留 $DATA_DIR)
可重复执行, 等同于升级; 数据目录 $DATA_DIR 不会被覆盖
EOF
      exit 0 ;;
    *) err "未知参数: $a"; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { err "请用 root 运行: sudo bash -c \"\$(curl -sL <本脚本地址>)\""; exit 1; }

# ---------------------------------------------------------------------
# 依赖检查
# ---------------------------------------------------------------------
check_deps(){
  local have_nft=0 have_ipt=0 pm=""
  command -v nft >/dev/null 2>&1 && have_nft=1
  command -v ipset >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1 && have_ipt=1
  if (( have_nft )); then info "后端: nftables"; return 0; fi
  if (( have_ipt )); then info "后端: ipset + iptables"; return 0; fi
  command -v apt    >/dev/null 2>&1 && pm=apt
  command -v dnf    >/dev/null 2>&1 && pm=dnf
  command -v yum    >/dev/null 2>&1 && pm=yum
  err "没有可用的防火墙后端, 需要 nftables 或 ipset + iptables"
  case $pm in
    apt) echo "    Debian/Ubuntu : apt update && apt install -y nftables";;
    dnf|yum) echo "    CentOS/RHEL   : $pm install -y ipset iptables";;
    *) echo "    请先安装 nftables, 或 ipset + iptables 后重试";;
  esac
  return 1
}

# ---------------------------------------------------------------------
# 下载 + 校验
# ---------------------------------------------------------------------
fetch(){
  local out=$1 url
  for url in "$SRC_URL" "$SRC_URL_FALLBACK"; do
    rm -f "$out"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --connect-timeout 8 --max-time 60 -o "$out" "$url" 2>/dev/null || continue
    elif command -v wget >/dev/null 2>&1; then
      wget -q -T 60 -O "$out" "$url" 2>/dev/null || continue
    else
      err "系统没有 curl 也没有 wget, 无法下载"
      return 1
    fi
    [[ -s $out ]] || continue
    # 防止镜像/代理返回 HTML 错误页被当成脚本装上
    head -n 1 "$out" | grep -q '^#!' || { warn "下载内容不像脚本, 换下一个源"; continue; }
    bash -n "$out" 2>/dev/null || { warn "下载内容语法检查失败, 换下一个源"; continue; }
    echo "$url"
    return 0
  done
  return 1
}

# ---------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------
do_uninstall(){
  echo -e "${R}即将从本机移除 ipblock${N}"
  echo "  将删除: $INSTALL_PATH, /etc/cron.d/ipblock-*, /etc/systemd/system/ipblock.service"
  echo "  并将卸载防火墙规则(nft 表 inet ipblock / iptables 链 IPB / ipset ipb_*)"
  echo "  数据目录 $DATA_DIR 会保留(里面有你的黑白名单)"
  read -rp "确认继续? 输入 yes: " ans || exit 1
  [[ $ans == yes ]] || { warn "已取消"; exit 0; }

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now ipblock.service >/dev/null 2>&1
    rm -f /etc/systemd/system/ipblock.service
    systemctl daemon-reload >/dev/null 2>&1
  fi
  rm -f /etc/cron.d/ipblock-auto /etc/cron.d/ipblock-ddns /etc/cron.d/ipblock-health

  if command -v nft >/dev/null 2>&1; then
    nft delete table inet ipblock 2>/dev/null
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -t raw -D PREROUTING -j IPB 2>/dev/null
    iptables -t raw -F IPB 2>/dev/null && iptables -t raw -X IPB 2>/dev/null
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t raw -D PREROUTING -j IPB 2>/dev/null
    ip6tables -t raw -F IPB 2>/dev/null && ip6tables -t raw -X IPB 2>/dev/null
  fi
  if command -v ipset >/dev/null 2>&1; then
    ipset destroy ipb_wl4 ipb_bl4 ipb_wl6 ipb_bl6 2>/dev/null
  fi
  rm -f "$INSTALL_PATH"
  info "已卸载。数据目录仍保留: $DATA_DIR (确认不再需要可手动 rm -rf)"
}

# ---------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------
printf '%s\n' "${C}=========== ipblock 安装 ===========${N}"

if (( DO_UNINSTALL )); then do_uninstall; exit 0; fi

check_deps || exit 1

tmp=$(mktemp) || { err "创建临时文件失败"; exit 1; }
trap 'rm -f "$tmp"' EXIT INT TERM

info "下载脚本..."
src=$(fetch "$tmp") || { err "下载失败: $SRC_URL"; err "可手动下载后放到 $INSTALL_PATH"; exit 1; }
info "来源: $src"

ver=$(sed -n '3p' "$tmp" | sed -n 's/.*  \(v[0-9.]*\)  .*/\1/p')
lines=$(wc -l < "$tmp" | tr -d ' ')
info "版本: ${ver:-未知}  ($lines 行)"

install -m 755 "$tmp" "$INSTALL_PATH" || { err "写入 $INSTALL_PATH 失败"; exit 1; }
info "已安装到 $INSTALL_PATH"

if command -v sha256sum >/dev/null 2>&1; then
  info "sha256: $(sha256sum "$INSTALL_PATH" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
  info "sha256: $(shasum -a 256 "$INSTALL_PATH" | cut -d' ' -f1)"
fi

echo ""
echo -e "${Y}接下来一定要做的第一件事${N}: 进菜单 7 → 4, 把当前 SSH IP 加入白名单。"
echo ""

if (( RUN_MENU )) && [[ -t 0 && -t 1 ]]; then
  exec "$INSTALL_PATH"
else
  echo "非交互环境, 已跳过菜单。手动运行: $INSTALL_PATH"
  echo "只加载规则: $INSTALL_PATH --init"
fi
