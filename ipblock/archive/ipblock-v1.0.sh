#!/usr/bin/env bash
# =====================================================================
#  ipblock.sh  —  IP 封禁 / 白名单 / lastb 自动封禁 管理脚本
#  后端: 优先 nftables, 不支持时自动回退到 ipset + iptables (如 CentOS 7)
#  数据: /etc/ipblock/blacklist.txt  /etc/ipblock/whitelist.txt (每行一个 IP 或 CIDR)
#  规则挂在 PREROUTING(最早), 对本机入站和转发(docker/端口转发)都生效
#  白名单优先级高于黑名单
# =====================================================================
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

DATA_DIR=/etc/ipblock
BL=$DATA_DIR/blacklist.txt
WL=$DATA_DIR/whitelist.txt
LOG=/var/log/ipblock.log
THRESHOLD=5                                   # lastb 中出现 >= 该次数则封禁
SELF=$(readlink -f "$0")
INSTALL_PATH=/usr/local/bin/ipblock.sh
CRON_FILE=/etc/cron.d/ipblock-auto
SERVICE_FILE=/etc/systemd/system/ipblock.service
SSH_IP=${SSH_CLIENT%% *}

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
info(){ echo -e "${G}[+]${N} $*"; }
warn(){ echo -e "${Y}[!]${N} $*"; }
err(){  echo -e "${R}[x]${N} $*"; }
pause(){ read -rp "按回车继续..." _; }
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
count(){ [[ -f $1 ]] && grep -c . "$1" || echo 0; }

# ---------------------------------------------------------------------
# 初始化 / 后端检测
# ---------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { err "请使用 root 运行"; exit 1; }
mkdir -p "$DATA_DIR"; touch "$BL" "$WL" "$LOG"

if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
  BACKEND=nft
elif command -v ipset >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
  BACKEND=ipt
else
  err "未找到可用后端。请安装 nftables,或安装 ipset + iptables:"
  echo "  Debian/Ubuntu: apt install nftables   (或 apt install ipset iptables)"
  echo "  CentOS/RHEL  : yum install ipset iptables"
  exit 1
fi

# ---------------------------------------------------------------------
# IP 格式处理
# ---------------------------------------------------------------------
to_int(){ local a b c d; IFS=. read -r a b c d <<<"$1"; INT=$(( (10#$a<<24)|(10#$b<<16)|(10#$c<<8)|10#$d )); }

# 规范化并校验,结果放入 $NORM。失败返回 1
normalize_entry(){
  local e=${1,,} ip m="" a b c d n mask
  ip=${e%%/*}; [[ $e == */* ]] && m=${e#*/}
  if [[ $ip == *:* ]]; then
    [[ $ip =~ ^[0-9a-f:]{2,39}$ && $ip == *:*:* ]] || return 1
    if [[ -n $m ]]; then [[ $m =~ ^[0-9]+$ ]] && (( 10#$m <= 128 )) || return 1; fi
    NORM=$ip; [[ -n $m ]] && NORM+="/$((10#$m))"
    return 0
  fi
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
  c=$((10#${BASH_REMATCH[3]})); d=$((10#${BASH_REMATCH[4]}))
  (( a<=255 && b<=255 && c<=255 && d<=255 )) || return 1
  if [[ -n $m ]]; then
    [[ $m =~ ^[0-9]+$ ]] && (( 10#$m <= 32 )) || return 1
    m=$((10#$m))
  fi
  if [[ -z $m || $m -eq 32 ]]; then
    NORM="$a.$b.$c.$d"
  else
    n=$(( (a<<24)|(b<<16)|(c<<8)|d ))
    mask=$(( (0xFFFFFFFF << (32-m)) & 0xFFFFFFFF ))
    n=$(( n & mask ))
    printf -v NORM '%d.%d.%d.%d/%d' $(( (n>>24)&255 )) $(( (n>>16)&255 )) $(( (n>>8)&255 )) $(( n&255 )) "$m"
  fi
  return 0
}

# 条目 $1(IP或CIDR) 是否包含/等于 IP $2 (IPv4 支持网段包含判断,IPv6 仅精确匹配)
ip_match(){
  [[ $1 == "$2" ]] && return 0
  [[ $1 == */* && $1 != *:* && $2 != *:* ]] || return 1
  local m=${1#*/} mask n
  to_int "${1%/*}"; n=$INT; to_int "$2"
  mask=$(( (0xFFFFFFFF << (32-m)) & 0xFFFFFFFF ))
  (( ($INT & mask) == (n & mask) ))
}

# IP $2 是否已被文件 $1 中的某条目覆盖
in_list(){
  local e
  grep -qxF -- "$2" "$1" 2>/dev/null && return 0
  [[ $2 == *:* ]] && return 1
  while IFS= read -r e; do
    [[ $e == */* && $e != *:* ]] || continue
    ip_match "$e" "$2" && return 0
  done < "$1"
  return 1
}

del_line(){ grep -vxF -- "$2" "$1" > "$1.tmp"; mv -f "$1.tmp" "$1"; }
entries(){ if [[ $2 == 6 ]]; then grep ':' "$1"; else grep -v ':' "$1"; fi; }

# ---------------------------------------------------------------------
# 后端: nftables
# ---------------------------------------------------------------------
nft_set(){ # name type file ver
  local list
  list=$(entries "$3" "$4" | paste -sd, - | sed 's/,/, /g')
  echo "  set $1 { type $2; flags interval; auto-merge;"
  [[ -n $list ]] && echo "    elements = { $list }"
  echo "  }"
}
apply_nft(){
  local f; f=$(mktemp)
  {
    echo "table inet ipblock"
    echo "delete table inet ipblock"
    echo "table inet ipblock {"
    nft_set wl4 ipv4_addr "$WL" 4
    nft_set wl6 ipv6_addr "$WL" 6
    nft_set bl4 ipv4_addr "$BL" 4
    nft_set bl6 ipv6_addr "$BL" 6
    echo "  chain pre {"
    echo "    type filter hook prerouting priority -300; policy accept;"
    echo "    ip saddr @wl4 accept"
    echo "    ip6 saddr @wl6 accept"
    echo "    ip saddr @bl4 counter drop"
    echo "    ip6 saddr @bl6 counter drop"
    echo "  }"
    echo "}"
  } > "$f"
  nft -f "$f"; local rc=$?
  [[ $rc -ne 0 ]] && cp -f "$f" /tmp/ipblock.failed.nft && warn "失败的规则已保存到 /tmp/ipblock.failed.nft"
  rm -f "$f"; return $rc
}

# ---------------------------------------------------------------------
# 后端: ipset + iptables
# ---------------------------------------------------------------------
gen_ipset(){ # name family file ver
  echo "create $1 hash:net family $2 maxelem 1000000 -exist"
  echo "flush $1"
  entries "$3" "$4" | sed "s/^/add $1 /"
}
ipt_chain(){ # cmd ver
  local cmd=$1 v=$2
  $cmd -t raw -N IPB 2>/dev/null
  $cmd -t raw -F IPB
  $cmd -t raw -A IPB -m set --match-set ipb_wl$v src -j ACCEPT
  $cmd -t raw -A IPB -m set --match-set ipb_bl$v src -j DROP
  $cmd -t raw -C PREROUTING -j IPB 2>/dev/null || $cmd -t raw -I PREROUTING 1 -j IPB
}
apply_ipt(){
  local f; f=$(mktemp)
  {
    gen_ipset ipb_wl4 inet  "$WL" 4
    gen_ipset ipb_bl4 inet  "$BL" 4
    if command -v ip6tables >/dev/null 2>&1; then
      gen_ipset ipb_wl6 inet6 "$WL" 6
      gen_ipset ipb_bl6 inet6 "$BL" 6
    fi
  } > "$f"
  ipset restore -exist < "$f" || { rm -f "$f"; return 1; }
  rm -f "$f"
  ipt_chain iptables 4 || return 1
  command -v ip6tables >/dev/null 2>&1 && ipt_chain ip6tables 6
  return 0
}

apply(){ if [[ $BACKEND == nft ]]; then apply_nft; else apply_ipt; fi; }
is_applied(){
  if [[ $BACKEND == nft ]]; then nft list table inet ipblock >/dev/null 2>&1
  else iptables -t raw -C PREROUTING -j IPB >/dev/null 2>&1; fi
}

# ---------------------------------------------------------------------
# 1. 封禁
# ---------------------------------------------------------------------
do_block(){
  local input tok e a ans; local -a added=()
  read -rp "输入要封禁的 IP / IP段 (如 1.2.3.4 或 1.2.3.0/24, 多个用空格或逗号分隔): " input
  [[ -z $input ]] && return
  for tok in ${input//,/ }; do
    normalize_entry "$tok" || { warn "格式无效: $tok"; continue; }
    e=$NORM
    if grep -qxF -- "$e" "$BL"; then info "已在封禁列表: $e"; continue; fi
    if [[ $e != */* ]] && in_list "$WL" "$e"; then warn "$e 在白名单中,跳过"; continue; fi
    if grep -qxF -- "$e" "$WL"; then warn "$e 在白名单中,跳过"; continue; fi
    if [[ -n $SSH_IP ]] && ip_match "$e" "$SSH_IP"; then
      warn "$e 包含你当前的 SSH 连接 IP ($SSH_IP),封禁后会断开!"
      read -rp "仍要封禁? (y/N): " ans
      [[ $ans == [yY] ]] || continue
    fi
    echo "$e" >> "$BL"; added+=("$e")
  done
  if (( ${#added[@]} == 0 )); then warn "没有新增封禁"; return; fi
  if apply; then
    for a in "${added[@]}"; do info "已封禁: $a"; log "BAN(手动) $a"; done
  else
    err "规则应用失败,回滚本次新增"
    for a in "${added[@]}"; do del_line "$BL" "$a"; done
    apply
  fi
}

# ---------------------------------------------------------------------
# 2 / 6. 查看列表 + 删除
# ---------------------------------------------------------------------
delete_items(){ # file input
  local file=$1 input=$2 tok i lo hi t
  local -a lines targets=() removed=()
  mapfile -t lines < "$file"
  for tok in ${input//,/ }; do
    if [[ $tok =~ ^[0-9]+$ ]]; then
      i=$((10#$tok))
      if (( i>=1 && i<=${#lines[@]} )); then targets+=("${lines[i-1]}"); else warn "序号无效: $tok"; fi
    elif [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
      lo=$((10#${BASH_REMATCH[1]})); hi=$((10#${BASH_REMATCH[2]}))
      for ((i=lo; i<=hi; i++)); do
        (( i>=1 && i<=${#lines[@]} )) && targets+=("${lines[i-1]}")
      done
    elif normalize_entry "$tok"; then
      targets+=("$NORM")
    else
      warn "无法识别: $tok"
    fi
  done
  for t in "${targets[@]}"; do
    if grep -qxF -- "$t" "$file"; then del_line "$file" "$t"; removed+=("$t")
    else warn "未找到: $t"; fi
  done
  if (( ${#removed[@]} )); then
    if apply; then
      for t in "${removed[@]}"; do info "已删除: $t"; log "DEL $t ($(basename "$file"))"; done
    else err "规则应用失败"; fi
  fi
}

manage_list(){ # title file label
  local title=$1 file=$2 label=$3 ch in
  while true; do
    clear
    echo -e "${C}========== $title (共 $(count "$file") 条) ==========${N}"
    if [[ -s $file ]]; then nl -ba -w4 -s'  ' "$file"; else echo "   (空)"; fi
    echo "--------------------------------------------"
    echo "  1. 删除${label}      0. 返回主菜单"
    read -rp "请选择: " ch
    case $ch in
      1)
        [[ -s $file ]] || { warn "列表为空"; pause; continue; }
        read -rp "输入序号(可多个,支持范围如 1-3,空格或逗号分隔),或直接输入 IP/IP段: " in
        [[ -n $in ]] && delete_items "$file" "$in"
        pause ;;
      0) return ;;
    esac
  done
}

# ---------------------------------------------------------------------
# 3. lastb 自动封禁
# ---------------------------------------------------------------------
auto_scan(){ # [quiet]
  local quiet=$1 n=0 ip cnt
  if ! command -v lastb >/dev/null 2>&1 || [[ ! -r /var/log/btmp ]]; then
    [[ $quiet ]] || warn "找不到 lastb 或 /var/log/btmp (没有登录失败记录)"
    return 1
  fi
  while read -r ip cnt; do
    [[ -z $ip ]] && continue
    normalize_entry "$ip" || continue
    ip=$NORM
    in_list "$WL" "$ip" && continue
    in_list "$BL" "$ip" && continue
    echo "$ip" >> "$BL"; n=$((n+1))
    log "AUTO-BAN $ip (lastb 失败 $cnt 次)"
    [[ $quiet ]] || info "封禁 $ip (失败 $cnt 次)"
  done < <(lastb -i -w 2>/dev/null | awk -v t="$THRESHOLD" '
      $1!="btmp" && NF>=3 && $3!="0.0.0.0" && $3 ~ /^[0-9a-fA-F:.]+$/ && ($3 ~ /\./ || $3 ~ /:/) {c[$3]++}
      END{for(i in c) if(c[i]>=t) print i, c[i]}')
  (( n > 0 )) && apply
  [[ $quiet ]] || info "本次新增封禁 $n 个 IP (阈值: >= $THRESHOLD 次)"
  return 0
}

install_self(){
  if [[ $SELF != "$INSTALL_PATH" ]]; then
    cp -f "$SELF" "$INSTALL_PATH" && chmod 755 "$INSTALL_PATH" && info "脚本已安装到 $INSTALL_PATH"
  fi
}

auto_menu(){
  local ch
  while true; do
    clear
    echo -e "${C}========== lastb 自动封禁 (失败 >= $THRESHOLD 次) ==========${N}"
    if [[ -f $CRON_FILE ]]; then echo -e "  定时任务: ${G}已开启 (每小时整点)${N}"; else echo -e "  定时任务: ${Y}未开启${N}"; fi
    echo "  1. 立即检测一次"
    echo "  2. 开启每小时自动检测"
    echo "  3. 关闭每小时自动检测"
    echo "  4. 查看最近日志"
    echo "  0. 返回主菜单"
    read -rp "请选择: " ch
    case $ch in
      1) auto_scan; pause ;;
      2) install_self
         echo "0 * * * * root $INSTALL_PATH --auto >/dev/null 2>&1" > "$CRON_FILE"
         chmod 644 "$CRON_FILE"; info "已开启: 每小时检测一次"; pause ;;
      3) rm -f "$CRON_FILE"; info "已关闭自动检测"; pause ;;
      4) tail -n 30 "$LOG"; pause ;;
      0) return ;;
    esac
  done
}

# ---------------------------------------------------------------------
# 4. 手动解封
# ---------------------------------------------------------------------
do_unblock(){
  local input tok e c ans found; local -a removed=()
  read -rp "输入要解封的 IP / IP段 (多个用空格或逗号分隔): " input
  [[ -z $input ]] && return
  for tok in ${input//,/ }; do
    normalize_entry "$tok" || { warn "格式无效: $tok"; continue; }
    e=$NORM
    if grep -qxF -- "$e" "$BL"; then
      del_line "$BL" "$e"; removed+=("$e"); continue
    fi
    found=""
    while IFS= read -r c; do
      [[ $c == */* ]] || continue
      if [[ $e != */* ]] && ip_match "$c" "$e"; then found=$c; break; fi
    done < "$BL"
    if [[ -n $found ]]; then warn "$e 属于已封禁网段 $found,请输入该网段整体解封"
    else warn "不在封禁列表: $e"; fi
  done
  (( ${#removed[@]} )) || return
  if apply; then
    for e in "${removed[@]}"; do info "已解封: $e"; log "UNBAN $e"; done
  else err "规则应用失败"; return; fi
  read -rp "是否同时加入白名单(防止被 lastb 自动再次封禁)? (y/N): " ans
  if [[ $ans == [yY] ]]; then
    for e in "${removed[@]}"; do grep -qxF -- "$e" "$WL" || echo "$e" >> "$WL"; done
    apply && info "已加入白名单"
  fi
}

# ---------------------------------------------------------------------
# 5. 设置白名单
# ---------------------------------------------------------------------
do_whitelist(){
  local input tok e; local -a added=()
  [[ -n $SSH_IP ]] && echo "提示: 你当前的 SSH 连接 IP 是 $SSH_IP"
  read -rp "输入要加入白名单的 IP / IP段 (多个用空格或逗号分隔): " input
  [[ -z $input ]] && return
  for tok in ${input//,/ }; do
    normalize_entry "$tok" || { warn "格式无效: $tok"; continue; }
    e=$NORM
    if grep -qxF -- "$e" "$WL"; then info "已在白名单: $e"; continue; fi
    echo "$e" >> "$WL"; added+=("$e")
    grep -qxF -- "$e" "$BL" && del_line "$BL" "$e" && warn "已从封禁列表移除: $e"
  done
  (( ${#added[@]} )) || return
  if apply; then for e in "${added[@]}"; do info "已加入白名单: $e"; log "WHITELIST $e"; done
  else err "规则应用失败"; fi
}

# ---------------------------------------------------------------------
# 7. 开机自启 / 状态
# ---------------------------------------------------------------------
sys_menu(){
  local ch
  while true; do
    clear
    echo -e "${C}========== 系统安装 / 状态 ==========${N}"
    echo "  后端        : $BACKEND"
    is_applied && echo -e "  规则状态    : ${G}已加载${N}" || echo -e "  规则状态    : ${R}未加载${N}"
    [[ -f $SERVICE_FILE ]] && echo -e "  开机恢复    : ${G}已安装${N}" || echo -e "  开机恢复    : ${Y}未安装${N}"
    [[ -f $CRON_FILE ]]    && echo -e "  自动封禁    : ${G}已开启${N}" || echo -e "  自动封禁    : ${Y}未开启${N}"
    echo "  数据目录    : $DATA_DIR    日志: $LOG"
    echo "  1. 安装开机自动恢复规则 (systemd)"
    echo "  2. 卸载开机自动恢复"
    echo "  3. 立即重新加载规则"
    echo "  0. 返回主菜单"
    read -rp "请选择: " ch
    case $ch in
      1) install_self
         if ! command -v systemctl >/dev/null 2>&1; then warn "未检测到 systemd"; pause; continue; fi
         cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ipblock restore firewall block rules
After=network.target nftables.service firewalld.service iptables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH --init

[Install]
WantedBy=multi-user.target
EOF
         systemctl daemon-reload && systemctl enable ipblock.service >/dev/null 2>&1
         info "已安装并启用 ipblock.service"; pause ;;
      2) systemctl disable ipblock.service >/dev/null 2>&1; rm -f "$SERVICE_FILE"
         command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
         info "已卸载"; pause ;;
      3) apply && info "规则已重新加载" || err "加载失败"; pause ;;
      0) return ;;
    esac
  done
}

# ---------------------------------------------------------------------
# 主菜单 / 命令行入口
# ---------------------------------------------------------------------
main_menu(){
  local ch auto
  while true; do
    clear
    [[ -f $CRON_FILE ]] && auto="${G}已开启${N}" || auto="${Y}未开启${N}"
    echo -e "${C}============ IP 封禁管理 [$BACKEND] ============${N}"
    echo -e "  封禁: $(count "$BL") 条   白名单: $(count "$WL") 条   自动封禁: $auto"
    echo "--------------------------------------------"
    echo "  1. 输入封禁 IP / IP段"
    echo "  2. 查看封禁 IP"
    echo "  3. 读取 lastb 自动封禁 (失败 >= $THRESHOLD 次, 每小时检测)"
    echo "  4. 手动解封 IP / IP段"
    echo "  5. 设置 IP 白名单"
    echo "  6. 查看 IP 白名单"
    echo "  7. 开机自启 / 系统状态"
    echo "  0. 退出"
    read -rp "请选择: " ch
    case $ch in
      1) do_block; pause ;;
      2) manage_list "封禁 IP 列表" "$BL" "封禁IP" ;;
      3) auto_menu ;;
      4) do_unblock; pause ;;
      5) do_whitelist; pause ;;
      6) manage_list "IP 白名单" "$WL" "白名单IP" ;;
      7) sys_menu ;;
      0) exit 0 ;;
    esac
  done
}

case $1 in
  --init) apply && log "INIT 规则已加载 ($BACKEND)"; exit $? ;;
  --auto)
    exec 9>/var/lock/ipblock.lock; flock -n 9 || exit 0
    is_applied || apply
    auto_scan quiet; exit 0 ;;
  -h|--help)
    echo "用法: $0            进入菜单"
    echo "      $0 --init     加载规则(开机恢复)"
    echo "      $0 --auto     执行一次 lastb 检测(供 cron 使用)"
    exit 0 ;;
esac

is_applied || apply
main_menu
