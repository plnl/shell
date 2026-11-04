#!/usr/bin/env bash
# =====================================================================
#  ipblockbt.sh  v1.3  —  宝塔面板专用: IP 封禁 / 白名单 / lastb 自动封禁
#  由 ipblock.sh v2.7 派生, 相对通用版的差异:
#    · 全部资源独立命名, 可以和通用版同机共存, 互不干扰:
#        数据 /etc/ipblockbt      nft 表 inet ipblockbt      iptables 链 IPBBT
#        ipset ipbbt_*            cron ipblockbt-auto/-ddns/-health
#        systemd ipblockbt.service  锁 /var/lock/ipblockbt.lock
#    · 面向宝塔: 状态页直接显示 面板端口 / 系统防火墙后端 / fail2ban / SSH 端口
#    · 首次运行会询问是否开启"规则自愈"(宝塔保存防火墙规则会重建系统表)
#
#  为什么这样设计: 宝塔的"安全"页只负责下发, 底层仍是 ufw 或 firewalld;
#  它 reload 时会 iptables-restore 重建 filter 表, 但不会碰别人的 nft 表,
#  也不会碰 raw 表。所以规则放独立表/raw 表 + 自愈兜底, 是最省心的组合。
#
#  后端: 优先 nftables, 不支持时自动回退到 ipset + iptables (如 CentOS 7)
#  数据: /etc/ipblockbt/blacklist.txt  /etc/ipblockbt/whitelist.txt
#  规则挂在 PREROUTING(最早), 对本机入站和转发(docker/端口转发)都生效
#  白名单优先级高于黑名单
#
#  ---- 以下为继承自 ipblock.sh v2 的修复记录 ----
#  1. 数据文件里只要有一条空行/注释/非法条目, 整次 nft apply 会语法报错失败;
#     v1 的 do_whitelist 失败后不回滚 => 此后所有修改永久不生效。v2 先 sanitize。
#  2. nft 首次运行时直接 `delete table` 会报 "No such file or directory",
#      nft -f 是整体事务, 一条失败 => 整批规则不落地。v2 改为"先探测再删除"。
#   3. 任何写操作先快照, apply 失败自动回滚文件 + 恢复旧规则,
#      不再出现"文件里有记录、内核里没规则"的静默不一致。
#   4. 菜单 read 遇到 Ctrl-D / 终端断开(EOF) 时, v1 会 clear -> read -> clear 死循环
#      打满 CPU。v2 读到 EOF 直接退出。
#   5. lastb 自动封禁会把自己的 IP 封掉(NAT 出口 IP 被同事/自己输错密码 5 次,
#      或多个小时累积)。v2 增加安全阀: 当前 SSH IP / 已建立连接 / 近期成功登录过的
#      IP 一律不自动封禁。
#   6. count() 在空文件时先输出 "0" 再补一个 "0" => 菜单显示 "共 0 0 条"。
#   7. IPv6 校验过松(::: / 1::2::3 都能过), 进文件后每次都让 apply 失败; v2 严格校验。
#   8. 输入解析用未加引号的 ${input//,/ }, 遇到 * ? [ 会做路径展开; v2 加 set -f。
#   9. 解封时若 IP 被某个网段覆盖, v1 只提示"请输入该网段"; v2 直接询问是否解封整个网段。
#  10. 日志无上限; v2 启动时超 2MB 自动截断保留最后 2000 行。
#  11. --auto 依赖 flock, 无 flock 时静默啥也不做; v2 有降级路径。
#  12. 新增菜单 8: 检查系统现有防火墙规则(nftables/iptables/ipset/firewalld/ufw,
#      含 fail2ban 的 f2b-* 链与 set), 把其中的"源 IP"合并进黑名单/白名单统一管理。
#      只读扫描, 不修改也不删除任何原有规则; 会封到你当前 SSH IP 的条目自动跳过。
#
#  v2.1 (本轮 review 后):
#  13. 内核禁用 IPv6 但有 ip6tables 命令时(阿里云/AWS 常见, GRUB ipv6.disable=1),
#      ipset create family inet6 与 ip6tables 调用都会失败 => 整次 apply 回滚,
#      连 IPv4 都封不住。改为同时判断 /proc/net/if_inet6, 且 IPv6 失败不再拖累 IPv4。
#  14. 手工编辑后末行无换行符时, `while read` 会吞掉最后一行(查不到/删不掉);
#      全部改为 `while ... read || [[ -n $var ]]`。
#  15. 所有临时文件收进 mktemp -d 的 RUNDIR, EXIT/INT/TERM 统一清理, 不再残留。
#  16. 无 flock 时用 mkdir 原子锁降级, 并回收 kill -9 留下的僵尸目录锁(>2h)。
#  17. IPv6 补上网段包含判断(按半字节比较 32 位十六进制串), 白名单/解封不再只认精确值。
#  18. 空集合不再输出 elements = { }; systemd 改成 enable --now 并区分成功/失败。
#
#  v2.2 (第二轮 review 后):
#  19. IPv6 带前缀时按位清零主机位(2001:db8::1/64 -> 2001:db8::/64), 并剥离 /128。
#      之前原样存盘: nft 对非规范网段报 "prefix length doesn't match IP address",
#      整批 apply 回滚; /128 又让 grep -qxF 精确匹配失忆, 同一 IP 反复入表。
#      IPv6 统一走 v6_render 输出 RFC5952 压缩形式, 顺带解决多种写法无法去重。
#  20. 无 flock 时 LOCK_DIR_MADE 在 mkdir 之前就被赋值, 抢锁失败退出会 rm -rf
#      别人正持有的锁。改为 mkdir 成功才记录, 并写入 pid, 按 kill -0 判活。
#  21. peer_ips 改取最后一列(ss 版本差异会改变列位置), 去 ::ffff: 映射与端口;
#      sudo 会清掉 SSH_CLIENT, 增加 who -m 兜底, 否则防锁死检查全部失效。
#  22. 菜单 8 只导入"除 -s 和目标外没有任何条件"的规则; 带 -p/--dport/!/端口名 的
#      一律跳过并计数。之前会把"只封 22 端口"导成"封整个 IP", 更糟的是 `! -s 内网`
#      这类取反规则会被当成封禁内网, 语义完全反了。
#  23. ipset 改为"灌临时集合 + swap", 避免 flush/add 期间集合为空(短暂全放行)。
#  24. 危险范围拦截: 0.0.0.0/0、::/0、127/8 直接拒绝; /8 以宽(v6 /16)需二次确认。
#  25. 快照改放进程私有的 RUNDIR, 不再共用 blacklist.txt.bak;
#      cron 与交互菜单同时操作不会按对方的快照回滚。解封加白名单前补 snapshot。
#  26. del_line/sanitize_file 改用同目录 mktemp, 跨文件系统 mv 既非原子又会把权限变 600。
#  27. 无 raw 表的容器回退到 filter 的 INPUT/FORWARD; lastb 只统计最近 24 小时。
#
#  v2.3 (第三轮 review 后):
#  28. peer_ips 的 sed 顺序错了: 先按行尾剥 "]" 再剥端口, 而 "[v6]:22" 的 "]"
#      不在行尾, 结果留下 "2001:db8::1]" 匹配不上, 双栈 sshd 下所有 IPv4
#      客户端的"已建立连接"安全阀失效。改为先去端口再去方括号。
#  29. 白名单规则由 ACCEPT 改 RETURN。filter 回退模式下 IPBBT 是从 INPUT/FORWARD
#      跳进来的, 那里的 ACCEPT 会让白名单 IP 直接通过整个 INPUT(所有端口全通,
#      连 fail2ban/docker 规则都跳过), 所以换 RETURN 是实质修复。
#      注: nft 基础链里的 accept 只作用于本链, 同 hook 上优先级更低的链(如 docker
#      的 dstnat -100)照常执行, 不会"跳过整个钩子"; 基础链中 return 与 accept 等价,
#      那边改成 return 只是语义统一。(原先这里的说法是错的, 已更正)
#  30. 菜单 8 的规则过滤由"黑名单式"改为"白名单式": 只认
#      `-A 链 -s 地址 -j DROP|ACCEPT|REJECT` 和 `--match-set ... src -j ...`,
#      带任何附加条件(-m conntrack/state/limit/recent/connlimit/mac/time、-p、
#      --dport、! 取反...)一律跳过。列举"不该有的条件"永远列不完。
#  31. 白名单入口补范围检查: /0 直接拒绝(否则整个黑名单失效), 过宽网段二次确认。
#  32. SSH_IP 现在要过 normalize_entry(本地 X 会话的 who 输出 ":0" 之前能混进去);
#      cron 静默模式不再逐条记 SKIP 日志, "lastb 不支持 -s" 只记一次。
#
#  v2.4 (新增 DDNS 动态域名白名单):
#  33. 菜单 9: 把 DDNS 域名解析出来的 IP 自动并入白名单。策略借鉴端口转发脚本 v6.0:
#      三级降级解析(getent ahostsv4 -> getent hosts -> dig -> nslookup 过滤 Server 行)、
#      解析失败保留旧 IP 并标记 pending(绝不因为 DNS 抖动就撤规则)、
#      配置"临时文件+行数校验+原子替换"、IP 未变但白名单被手工删掉时自动补回。
#  34. --ddns 走命令行入口, 与 --auto 共用一把锁(两者都读写 whitelist.txt)。
#      cron 每 DDNS_MIN 分钟触发, 只在有变更/失败时写日志, 避免刷屏。
#
#  v2.5 (DDNS 缺陷修复):
#  35. ddns_del/ddns_update 里又用了 `grep -c . || echo 0`, 空文件会输出两行 "0\n0"
#      导致算术报错: 最后一个域名永远删不掉, 且白名单已改未回滚。全部改用 count()。
#      所有"放弃替换"的分支现在都先 restore 再 tx_done。
#  36. 共享 IP 的归属: 新记录遇到"IP 已在白名单"时, 若已有 owned=1 的记录则继承
#      owned=1, 否则两个域名都记 0, 最后谁都不负责撤, IP 永久留在白名单。
#      ddns_update 改成两遍: 循环只收集待撤销旧 IP, 跑完对着"新配置"判断是否还有人用
#      (原来在循环内查旧 conf, 两个域名同时换 IP 时会互相认为对方还在用)。
#  37. 用户手工把 DDNS 管的 IP 再加一次 => owned 置 0, 管理权交还用户。
#  38. DDNS cron 改 3-59/10 避开整点, 不再和 0 * * * * 的 lastb 任务抢锁;
#      抢锁失败写日志; _auto_lock 支持等待秒数。
#  39. 提交前加 cksum 守卫: 解析期间 conf 被菜单改过就放弃本轮(下轮自愈),
#      不再被慢解析期间的新增域名覆盖。行数校验改成"写出数 vs 处理数", 不再被注释/空行误判。
#  40. 域名匹配改用 awk 精确比较第一列(grep 的 . 是通配符); 多 A 记录统一排序取值,
#      并在有多条时提示; resolve_domain 用 "ip 个数" 两字段回传(子 shell 里赋值全局变量传不出去)。
#
#  v2.6 (按段聚合封禁):
#  41. lastb 自动封禁不再逐条封 /32, 改为按段聚合:
#      · 同一 C段(/24) 内不同 IP >= AGG_C_MIN(3) -> 封整个 /24
#      · 该 /16 之前已封过别的 /24、本轮又出现新 /24(即"后期再次出现") -> 围绕新 /24
#        前后各扩 AGG_NEIGHBOR(8) 个 /24, 只在本 /16 内扩
#      · 要覆盖的 /24 超过 AGG_B_HARD(20) -> 直接封整个 /16
#      · 被网段覆盖的单 IP 全部剔除(compact), 避免名单膨胀
#      安全阀: 段里含当前 SSH IP 时该段不封, 降级为逐个封里面的候选 IP。
#  42. 菜单 3 增加"预览本轮会封什么"(干跑, 不写规则)与聚合开关。
#
#  v2.7 (与 ufw / 宝塔面板共存):
#  43. 宝塔"安全"页保存规则会执行 ufw reload(内部 iptables-restore, 对 filter 等表
#      是"清空后重建"); ufw reset/disable/重装面板 甚至会把所有表一起清掉。
#      本脚本的规则刻意放在别人不会碰的位置: nft 用独立表 inet ipblockbt,
#      ipt 后端用 raw 表(ufw 的 user.rules 只含 filter/nat), 常见 reload 影响不到。
#  44. 新增 --health 自愈: 规则被清掉就重新加载, 配合 cron 每 HEALTH_MIN 分钟检查。
#      filter 回退模式(容器无 raw)最危险, 启动时和状态页都会红色警告。
#  45. systemd 服务加 After=… ufw.service, 避免 ufw 启动晚于本服务把规则覆盖掉。
#      只加 After 不加 Wants: Wants 会把已安装但停用的 ufw 拉起来。
#  46. 检测 ufw/firewalld/宝塔并在状态页与菜单 8 给出共存提示。
#
#  v1.1 (支持免下载直接运行, 与通用版 v2.8 同步):
#  47. `bash <(curl ...)` / `curl | bash` 运行时 $0 不是实体文件, 原 install_self
#      直接 cp 会失败, 导致 cron 与 systemd 指向一个不存在的路径且没有提示。
#      现在识别这种运行方式, 改为从仓库下载安装, 并对下载内容做 shebang + bash -n
#      校验; 安装失败时明确报错, 不再继续创建指向空路径的定时任务。
#
#  v1.2 (与通用版 v2.9 同步):
#  48. 同步聚合安全阀(protected_nets / seg_guard)、IPv6 候选补封、agg_compute 空文件
#      陷阱、DDNS owned 继承、去掉 Wants=ufw.service、修正 nft accept/return 注释。
#  49. 修正提示里的服务名: journalctl -u ipblock / systemctl enable --now ipblock
#      应为 ipblockbt —— 照着提示敲会操作到通用版的服务。导出文件头也写成 ipblock。
#  50. bt_ssh_port 现在会读 sshd_config.d/*.conf(被 Include 的配置)。
#  51. 手工封禁(菜单 1)遇到内网/本机网段时也提示一次, 需二次确认。
#
#  v1.3 (SSH 登录方式管理, 菜单 10, 与通用版 v2.10 同步):
#  52. 新增「SSH 登录管理」: 查看登录方式 / 安装密钥(粘贴或生成) / 切换 仅密钥·仅密码·
#      密钥+密码 / root 策略 / 查看删除密钥 / 改端口 / 登录记录 / 配置备份回滚。
#      改动顺序: 备份 -> 注释冲突行(含 Include 的 drop-in) -> 写托管块 -> sshd -t ->
#      重载 -> sshd -T 核对生效值, 失败自动回滚。
# =====================================================================
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -f                      # 关闭路径展开, 防止输入的 * ? [ 被 shell 解释

DATA_DIR=/etc/ipblockbt
BL=$DATA_DIR/blacklist.txt
WL=$DATA_DIR/whitelist.txt
LOG=/var/log/ipblockbt.log
THRESHOLD=${THRESHOLD:-5}          # lastb 中出现 >= 该次数则封禁
BAN_WINDOW=${BAN_WINDOW:--24hours} # lastb 只统计最近这段时间内的失败
SKIP_SUCCESS=${SKIP_SUCCESS:-1}    # 1=近期成功登录过的 IP 不自动封禁(防锁死)
# 按段聚合: 单 IP -> /24(C段) -> /16(B段), 防止爆破把黑名单撑成上千条
AGG_ENABLE=${AGG_ENABLE:-1}        # 1=启用聚合, 0=只按单 IP 封
AGG_C_MIN=${AGG_C_MIN:-3}          # 同一 /24 内不同 IP 数 >= 此值 -> 封整个 /24
AGG_B_HARD=${AGG_B_HARD:-20}       # 同一 /16 下要覆盖的 /24 数 > 此值 -> 直接封 /16
AGG_NEIGHBOR=${AGG_NEIGHBOR:-8}    # 第二波出现新 /24 时, 前后各扩多少个 /24(0=不扩)
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
# `bash <(curl ...)` 时 $0 是 /dev/fd/xx, `curl | bash` 时是 bash: 都不是实体文件,
# 没法直接 cp 自己, 这种情形要走下载安装(见 install_self)
SELF_IS_FILE=0
[[ -n $SELF && -f $SELF && -r $SELF ]] && SELF_IS_FILE=1
SRC_URL=${SRC_URL:-https://raw.githubusercontent.com/plnl/shell/main/ipblock-bt/ipblockbt.sh}
SRC_URL_FALLBACK=${SRC_URL_FALLBACK:-https://cdn.jsdelivr.net/gh/plnl/shell@main/ipblock-bt/ipblockbt.sh}
INSTALL_PATH=/usr/local/bin/ipblockbt.sh
CRON_FILE=/etc/cron.d/ipblockbt-auto
HEALTH_CRON=/etc/cron.d/ipblockbt-health
HEALTH_MIN=${HEALTH_MIN:-5}        # 规则自愈检查间隔(分钟)
DDNS_CONF=$DATA_DIR/ddns.conf
DDNS_CRON=/etc/cron.d/ipblockbt-ddns
DDNS_MIN=${DDNS_MIN:-10}           # DDNS 自动检测间隔(分钟)
SERVICE_FILE=/etc/systemd/system/ipblockbt.service
LOCK_FILE=/var/lock/ipblockbt.lock
SSH_IP=${SSH_CLIENT%% *}
[[ -z $SSH_IP ]] && SSH_IP=${SSH_CONNECTION%% *}

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
info(){ echo -e "${G}[+]${N} $*"; }
warn(){ echo -e "${Y}[!]${N} $*"; }
err(){  echo -e "${R}[x]${N} $*"; }
pause(){ read -rp "按回车继续..." _ || exit 0; }
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
count(){ local n=0; [[ -f $1 ]] && n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }

# ---------------------------------------------------------------------
# 临时目录 / 退出清理
#   所有 mktemp 产物统一放在 RUNDIR 下, 任何方式退出(Ctrl+C / TERM)都会清掉
# ---------------------------------------------------------------------
RUNDIR=""
LOCK_DIR_MADE=""
_LOCK_HELD=0
_cleanup(){
  [[ -n $RUNDIR && -d $RUNDIR ]] && rm -rf "$RUNDIR" 2>/dev/null
  [[ -n $LOCK_DIR_MADE && -d $LOCK_DIR_MADE ]] && rm -rf "$LOCK_DIR_MADE" 2>/dev/null
  return 0
}
# GNU/BSD stat 都能取 mtime, 取不到就退回当前时间
_mtime(){ stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date +%s; }
trap '_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
_rundir(){ [[ -n $RUNDIR && -d $RUNDIR ]] || RUNDIR=$(mktemp -d 2>/dev/null) || return 1; return 0; }

# ---------------------------------------------------------------------
# 初始化 / 后端检测
# ---------------------------------------------------------------------
[[ $EUID -eq 0 ]] || { err "请使用 root 运行"; exit 1; }
mkdir -p "$DATA_DIR" || exit 1
touch "$BL" "$WL" "$LOG" "$DDNS_CONF" 2>/dev/null

# IPv6 能力判定: 光有 ip6tables 命令不代表内核启用了 IPv6
# (阿里云/AWS 常见镜像装了 ip6tables 但 GRUB 里 ipv6.disable=1, 此时任何
#  ip6tables 调用都会失败; 只看 command -v 会让整次 apply 失败并回滚)
have_ipv6(){ [[ -f /proc/net/if_inet6 ]]; }
have_ip6tables(){ command -v ip6tables >/dev/null 2>&1 && have_ipv6; }

# 日志超过 2MB 时截断, 避免长期自动封禁把 /var 写满
if [[ -f $LOG ]]; then
  _sz=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  if (( ${_sz:-0} > 2097152 )); then
    tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
  fi
  unset _sz
fi

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
# 与系统上其它防火墙/面板共存
#   宝塔面板"安全"页保存规则时会执行 ufw reload(或 firewall-cmd --reload),
#   ufw reload 内部是 iptables-restore, 对 *filter 等表是"清空后重建";
#   ufw reset / disable / 面板重装防火墙 甚至会把所有表一起清掉。
#   本脚本刻意把规则放独立位置, 让常见 reload 碰不到:
#     nft 后端  -> 独立表 inet ipblockbt   (ufw/firewalld reload 不碰别人的表)
#     ipt 后端  -> raw 表 PREROUTING     (ufw 的 user.rules 只含 filter/nat)
#   filter 回退(容器无 raw)是最危险的情形, 会被 ufw reload 清掉, 因此提供自愈。
# ---------------------------------------------------------------------
FW_UFW=0; FW_FW=0; FW_BT=0
detect_stack(){
  FW_UFW=0; FW_FW=0; FW_BT=0
  if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | head -n 1 | grep -qi 'status:[[:space:]]*active' && FW_UFW=1
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then FW_FW=1; fi
  [[ -d /www/server/panel ]] && FW_BT=1
  return 0
}
stack_desc(){
  local s=""
  (( FW_UFW )) && s+="ufw(启用) "
  (( FW_FW ))  && s+="firewalld(启用) "
  (( FW_BT ))  && s+="宝塔面板 "
  echo "${s:-无其它防火墙}"
}
# 规则是否还在; 丢了就重载(供 --health / 定时任务用)
health_check(){
  is_applied && return 0
  log "HEALTH 规则已丢失(可能被 ufw/宝塔重载清掉), 重新加载 ($BACKEND/${IPT_TABLE:-nft})"
  sanitize_file "$BL"; sanitize_file "$WL"
  if apply; then log "HEALTH 已恢复"; return 0; fi
  log "HEALTH 恢复失败"; return 1
}

# ---------------------------------------------------------------------
# 宝塔面板适配
#   宝塔"安全"页只负责下发与展示, 底层仍是 ufw(Ubuntu/Debian) 或
#   firewalld(CentOS)。因此:
#     · 面板的端口规则归它管, 本脚本只管 IP 黑白名单, 两边不抢同一个开关
#     · 面板 reload 会重建系统防火墙的表 -> 规则放独立表 + 自愈兜底
#     · 面板若开了 SSH 防爆破(fail2ban), 会与本脚本的 lastb 自动封禁重复,
#       建议只留一套(菜单 3 可以关掉本脚本的自动封禁, 或关掉面板那个)
# ---------------------------------------------------------------------
BT_DIR=/www/server/panel
BT_DETECTED=0
bt_detect(){ [[ -d $BT_DIR ]] && BT_DETECTED=1 || BT_DETECTED=0; return 0; }
bt_panel_port(){ [[ -r $BT_DIR/data/port.pl ]] && tr -dc '0-9' < "$BT_DIR/data/port.pl" 2>/dev/null; }
bt_ssh_port(){
  # 主配置 + sshd_config.d/*.conf(被 Include 的) 都看一遍, 取第一个 Port
  local f p=""
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -r $f ]] || continue
    p=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' "$f" 2>/dev/null)
    [[ -n $p ]] && break
  done
  printf '%s' "${p:-22}"
}
bt_fw_backend(){
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -n 1 | grep -qi 'status:[[:space:]]*active'; then
    echo "ufw (已启用)"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    echo "firewalld (运行中)"
  elif command -v firewall-cmd >/dev/null 2>&1; then echo "firewalld (未运行)"
  elif command -v ufw >/dev/null 2>&1; then echo "ufw (未启用)"
  else echo "仅 iptables"
  fi
}
bt_jails(){ command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p'; }

bt_status(){
  bt_detect
  if (( ! BT_DETECTED )); then
    warn "未检测到宝塔面板 ($BT_DIR 不存在), 本机可能不需要这个专用版"
    return 1
  fi
  local port jail
  port=$(bt_panel_port)
  echo "  面板目录     : $BT_DIR"
  echo "  面板端口     : ${port:-未读取到}"
  echo "  系统 SSH 端口: $(bt_ssh_port)"
  echo "  面板防火墙   : $(bt_fw_backend)"
  jail=$(bt_jails)
  if [[ -n $jail ]]; then
    echo "  fail2ban     : $jail"
    warn "fail2ban 正在封禁 -> 与本脚本的 lastb 自动封禁重复, 建议只留一套"
  else
    echo "  fail2ban     : 未运行"
  fi
  if [[ $BACKEND == nft ]]; then
    echo "  本脚本规则   : nft 独立表 inet ipblockbt (面板 reload 碰不到)"
  else
    echo "  本脚本规则   : iptables ${IPT_TABLE:-raw} 表 IPBBT 链"
    [[ ${IPT_TABLE:-raw} == filter ]] && warn "filter 回退模式: 面板 reload 会清掉本链, 必须开启自愈"
  fi
  echo "  规则自愈     : $( [[ -f $HEALTH_CRON ]] && echo "已开启 (每 ${HEALTH_MIN} 分钟)" || echo "未开启" )"
  echo "  开机恢复     : $( [[ -f $SERVICE_FILE ]] && echo "已安装" || echo "未安装" )"
  return 0
}

# ---------------------------------------------------------------------
# IP 格式处理
# ---------------------------------------------------------------------
to_int(){
  local a b c d
  [[ $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$1"
  INT=$(( (10#$a<<24)|(10#$b<<16)|(10#$c<<8)|10#$d ))
  return 0
}

# IPv6 语法校验(含 /前缀); 允许大小写, 拒绝 ::: / 多个 :: / 组数越界
valid_v6(){
  local full=$1 ip m="" c=0 groups=0 g n
  local IFS=:
  [[ $full == */* ]] && { m=${full#*/}; ip=${full%%/*}; } || ip=$full
  [[ $ip == *:* ]] || return 1
  if [[ -n $m ]]; then
    [[ $m =~ ^[0-9]{1,3}$ ]] && (( 10#$m <= 128 )) || return 1
  fi
  [[ $ip =~ ^[0-9a-fA-F:]+$ ]] || return 1
  [[ $ip == *:::* ]] && return 1
  n=$ip
  while [[ $n == *::* ]]; do c=$((c+1)); n=${n/::/:}; done
  (( c <= 1 )) || return 1
  [[ $ip == :* && $ip != ::* ]] && return 1
  [[ $ip == *: && $ip != *:: ]] && return 1
  for g in $ip; do
    [[ -z $g ]] && continue
    [[ $g =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
    groups=$((groups+1))
  done
  if (( c == 0 )); then (( groups == 8 )) || return 1
  else (( groups <= 7 )) || return 1; fi
  return 0
}

# 32 个 hex 字符 -> RFC5952 规范压缩形式(最长连续 0 组用 :: 表示), 结果放 V6ADDR
v6_render(){
  local h=$1 i g run=-1 runlen=0 cur=-1 curlen=0 left="" right=""
  local -a gs=()
  for ((i=0;i<8;i++)); do
    g=${h:$((i*4)):4}
    while [[ $g == 0* && ${#g} -gt 1 ]]; do g=${g#0}; done
    gs+=("$g")
  done
  for ((i=0;i<8;i++)); do
    if [[ ${gs[i]} == 0 ]]; then
      (( cur < 0 )) && { cur=$i; curlen=0; }
      curlen=$((curlen+1))
      (( curlen > runlen )) && { run=$cur; runlen=$curlen; }
    else
      cur=-1; curlen=0
    fi
  done
  (( runlen < 2 )) && run=-1
  if (( run >= 0 )); then
    for ((i=0;i<run;i++)); do
      [[ -n $left ]] && left+=":"
      left+="${gs[i]}"
    done
    for ((i=run+runlen;i<8;i++)); do
      [[ -n $right ]] && right+=":"
      right+="${gs[i]}"
    done
    V6ADDR="${left}::${right}"
  else
    for ((i=0;i<8;i++)); do left+="${gs[i]}:"; done
    V6ADDR=${left%:}
  fi
  return 0
}

# 规范化并校验, 结果放入 $NORM; 失败返回 1
normalize_entry(){
  local e=$1 ip m="" a b c d n mask pfx full rem hx nib keep
  e=${e//[[:space:]]/}
  [[ -z $e ]] && return 1
  ip=${e%%/*}; [[ $e == */* ]] && m=${e#*/}
  if [[ $ip == *:* ]]; then
    valid_v6 "$e" || return 1
    pfx=128
    [[ -n $m ]] && pfx=$((10#$m))
    v6_expand "$ip" || return 1
    hx=$V6HEX
    if (( pfx < 128 )); then
      # 按前缀清零主机位: 2001:db8::1/64 必须落成 2001:db8::/64
      # (nft 对带主机位的网段报 "prefix length doesn't match IP address", 会让整批 apply 失败)
      full=$((pfx/4)); rem=$((pfx%4))
      hx=${V6HEX:0:full}
      if (( rem > 0 )); then
        nib=${V6HEX:full:1}
        keep=$(( (16#$nib >> (4-rem)) << (4-rem) ))
        printf -v nib '%x' "$keep"
        hx+=$nib
      fi
      while (( ${#hx} < 32 )); do hx+="0"; done
    fi
    v6_render "$hx"
    NORM=$V6ADDR
    (( pfx != 128 )) && NORM+="/$pfx"          # /128 等同单 IP, 去掉后缀便于精确匹配
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

# 把 IPv6 展开成 32 个十六进制字符, 结果放入 V6HEX; 失败返回 1
# 128 位没法用 bash 整数算, 但"按半字节比较字符串"足够做前缀匹配
v6_expand(){
  local ip=${1%/*} head tail g out="" i n=0
  ip=$(printf '%s' "$ip" | tr 'A-F' 'a-f')   # 统一小写, 保证大小写写法能去重、能比较
  local -a hg=() tg=()
  if [[ $ip == *::* ]]; then
    head=${ip%%::*}; tail=${ip#*::}
    [[ -n $head ]] && IFS=: read -r -a hg <<< "$head"
    [[ -n $tail ]] && IFS=: read -r -a tg <<< "$tail"
    n=$(( 8 - ${#hg[@]} - ${#tg[@]} ))
    (( n < 0 )) && return 1
  else
    IFS=: read -r -a hg <<< "$ip"
    (( ${#hg[@]} == 8 )) || return 1
  fi
  for g in "${hg[@]}"; do
    while (( ${#g} < 4 )); do g="0$g"; done
    out+=$g
  done
  for ((i=0; i<n; i++)); do out+="0000"; done
  for g in "${tg[@]}"; do
    while (( ${#g} < 4 )); do g="0$g"; done
    out+=$g
  done
  (( ${#out} == 32 )) || return 1
  V6HEX=$out
  return 0
}

# 网段 $1/$2 是否包含地址 $3
v6_match(){
  local pfx=$2 full rem a b nh ah
  [[ $pfx =~ ^[0-9]+$ ]] && (( 10#$pfx <= 128 )) || return 1
  pfx=$((10#$pfx))
  v6_expand "$1" || return 1; nh=$V6HEX
  v6_expand "$3" || return 1; ah=$V6HEX
  full=$(( pfx / 4 )); rem=$(( pfx % 4 ))
  (( full > 0 )) && [[ ${nh:0:full} != "${ah:0:full}" ]] && return 1
  if (( rem > 0 )); then
    a=${nh:full:1}; b=${ah:full:1}
    (( (16#$a >> (4-rem)) != (16#$b >> (4-rem)) )) && return 1
  fi
  return 0
}

# 条目 $1(IP或CIDR) 是否包含/等于条目 $2(IP或CIDR)
#   IPv4 用整数掩码比较, IPv6 按半字节比较展开后的十六进制串
ip_match(){
  [[ $1 == "$2" ]] && return 0
  [[ $1 == */* ]] || return 1
  local m=${1#*/} pm="" mask n
  [[ $2 == */* ]] && pm=${2#*/}
  if [[ $1 == *:* ]]; then
    [[ $2 == *:* ]] || return 1
    [[ $m =~ ^[0-9]+$ ]] || return 1
    if [[ -n $pm ]]; then
      [[ $pm =~ ^[0-9]+$ ]] || return 1
      (( 10#$m > 10#$pm )) && return 1      # 前缀更长 = 网段更小, 不可能包含对方
    fi
    v6_match "${1%/*}" "$m" "${2%/*}"; return $?
  fi
  [[ $2 == *:* ]] && return 1
  [[ $m =~ ^[0-9]+$ ]] || return 1
  if [[ -n $pm ]]; then
    [[ $pm =~ ^[0-9]+$ ]] || return 1
    (( 10#$m > 10#$pm )) && return 1
  fi
  to_int "${1%/*}" || return 1; n=$INT
  to_int "${2%/*}" || return 1
  mask=$(( (0xFFFFFFFF << (32-m)) & 0xFFFFFFFF ))
  (( ($INT & mask) == (n & mask) ))
}

# IP $2 是否已被文件 $1 中的某条目覆盖
in_list(){
  local e
  [[ -f $1 ]] || return 1
  grep -qxF -- "$2" "$1" 2>/dev/null && return 0
  # 只有带 "/" 的行才是网段, 先用 grep 滤掉单 IP 行, 避免上千条时纯 bash 逐行空转
  while IFS= read -r e || [[ -n $e ]]; do
    [[ $e == */* ]] || continue
    ip_match "$e" "$2" && return 0
  done < <(grep -F '/' "$1" 2>/dev/null)
  return 1
}

del_line(){
  local f=$1 t rc
  # 同目录建临时文件: 跨文件系统的 mv 是"复制+删除", 既不原子也会把权限变成 600
  t=$(mktemp "$(dirname "$f")/.ipblockbt.XXXXXX") || return 1
  grep -vxF -- "$2" "$f" > "$t" 2>/dev/null; rc=$?
  if (( rc <= 1 )); then mv -f "$t" "$f" && chmod 644 "$f"; else rm -f "$t"; return 1; fi
}

# 只输出有效条目: ver=4 输出 IPv4, ver=6 输出 IPv6；空行一律过滤
entries(){
  local f=$1 v=$2
  [[ -f $f ]] || return 0
  if [[ $v == 6 ]]; then grep ':' "$f" 2>/dev/null; else grep -v ':' "$f" 2>/dev/null; fi | grep -v '^[[:space:]]*$'
}

# 清洗数据文件: 去注释/空白/空行/重复, 丢弃非法条目(否则会让 apply 整体失败)
# 临时文件放在目标文件同目录, 保证 mv 是同文件系统内的原子改名
sanitize_file(){
  local f=$1 d t1 t2 line bad=0 kept=0
  [[ -f $f ]] || { : > "$f"; return 0; }
  d=$(dirname "$f")
  t1=$(mktemp "$d/.ipblockbt.XXXXXX") && t2=$(mktemp "$d/.ipblockbt.XXXXXX") || { rm -f "$t1"; return 1; }
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$f" 2>/dev/null | grep -v '^$' > "$t1"
  : > "$t2"
  while IFS= read -r line || [[ -n $line ]]; do
    if normalize_entry "$line"; then printf '%s\n' "$NORM" >> "$t2"; kept=$((kept+1))
    else bad=$((bad+1)); fi
  done < "$t1"
  awk '!seen[$0]++' "$t2" > "$t1" && mv -f "$t1" "$f" && chmod 644 "$f"
  if (( bad > 0 )); then
    warn "已从 $(basename "$f") 中移除 $bad 行无效/无法解析的条目"
    log "SANITIZE $(basename "$f"): removed $bad invalid line(s)"
  fi
  rm -f "$t2"
  return 0
}

# ---------------------------------------------------------------------
# 写操作快照 / 回滚 / 提交
#   快照放在本进程独立的 RUNDIR 里, 不再用固定的 blacklist.txt.bak:
#   cron 与交互菜单同时操作时不会互相覆盖对方的回滚点(否则会按别人的快照回滚)
# ---------------------------------------------------------------------
SNAP_BL=""; SNAP_WL=""
snapshot(){
  _rundir || return 1
  SNAP_BL=$RUNDIR/snap.blacklist; SNAP_WL=$RUNDIR/snap.whitelist
  cp -f "$BL" "$SNAP_BL" 2>/dev/null
  cp -f "$WL" "$SNAP_WL" 2>/dev/null
  return 0
}
restore(){
  [[ -n $SNAP_BL && -f $SNAP_BL ]] && cp -f "$SNAP_BL" "$BL" 2>/dev/null
  [[ -n $SNAP_WL && -f $SNAP_WL ]] && cp -f "$SNAP_WL" "$WL" 2>/dev/null
  return 0
}
# 本次修改结束(无需回滚)
tx_done(){ SNAP_BL=""; SNAP_WL=""; return 0; }
# 应用成功 -> 丢弃快照; 失败 -> 文件回滚并按旧文件重新加载, 保证"文件=内核规则"
commit(){
  if apply; then tx_done; return 0; fi
  warn "规则应用失败, 已回滚本次修改"
  restore
  apply >/dev/null 2>&1
  tx_done
  return 1
}

# ---------------------------------------------------------------------
# 后端: nftables
# ---------------------------------------------------------------------
nft_set(){ # name type file ver
  local list
  list=$(entries "$3" "$4" | paste -sd, - | sed 's/,/, /g')
  echo "  set $1 { type $2; flags interval; auto-merge;"
  # 空集合不输出 elements 行(老版本 nft 对 elements = { } 解析不一)
  [[ -n ${list//[[:space:]]/} ]] && echo "    elements = { $list }"
  echo "  }"
}
apply_nft(){
  local f rc; _rundir || return 1
  f=$(mktemp "$RUNDIR/nft.XXXXXX") || return 1
  {
    # 只在表确实存在时才 delete: nft -f 是整事务, delete 失败会让整批规则不落地
    nft list table inet ipblockbt >/dev/null 2>&1 && echo "delete table inet ipblockbt"
    echo "table inet ipblockbt {"
    nft_set wl4 ipv4_addr "$WL" 4
    nft_set wl6 ipv6_addr "$WL" 6
    nft_set bl4 ipv4_addr "$BL" 4
    nft_set bl6 ipv6_addr "$BL" 6
    echo "  chain pre {"
    echo "    type filter hook prerouting priority -300; policy accept;"
    # 白名单用 return 而不是 accept: accept 是在整个 prerouting 钩子上终结,
    # 会连带跳过 docker 挂在 prerouting(priority -100) 的 DNAT 规则,
    # 白名单 IP 就访问不到容器映射端口了; return 只结束本链, 语义与 iptables 侧一致
    echo "    ip saddr @wl4 return"
    echo "    ip6 saddr @wl6 return"
    echo "    ip saddr @bl4 counter drop"
    echo "    ip6 saddr @bl6 counter drop"
    echo "  }"
    echo "}"
  } > "$f"
  nft -f "$f"; rc=$?
  if (( rc != 0 )); then
    cp -f "$f" /tmp/ipblockbt.failed.nft 2>/dev/null
    warn "nft 报错, 失败的规则已保存到 /tmp/ipblockbt.failed.nft"
  fi
  rm -f "$f"; return $rc
}

# ---------------------------------------------------------------------
# 后端: ipset + iptables
# ---------------------------------------------------------------------
# 先灌临时集合再 swap: ipset restore 的 flush+add 不是原子的,
# 中途失败会留下被清空的集合(等于短暂全放行); swap 则是原子替换
gen_ipset(){ # name family file ver
  local tmp="$1_t"
  echo "create $1 $2 maxelem 1000000 -exist"
  echo "create $tmp $2 maxelem 1000000 -exist"
  echo "flush $tmp"
  entries "$3" "$4" | sed "s/^/add $tmp /"
  echo "swap $1 $tmp"
}

# raw 表在部分容器(OpenVZ/LXC)里不存在, 退回 filter 的 INPUT/FORWARD
ipt_pick_table(){
  if command -v iptables >/dev/null 2>&1 && iptables -t raw -L -n >/dev/null 2>&1; then
    echo raw
  else
    echo filter
  fi
}
ipt_chain(){ # cmd ver
  local cmd=$1 v=$2 tbl=${IPT_TABLE:-raw} h
  $cmd -t "$tbl" -N IPBBT 2>/dev/null
  $cmd -t "$tbl" -F IPBBT || return 1
  # 白名单必须用 RETURN, 不能用 ACCEPT:
  #   filter 回退模式下 IPBBT 是从 INPUT/FORWARD 跳进来的, 这里 ACCEPT 会让数据包
  #   直接通过整个 INPUT, 等于给白名单 IP 开了一个"访问所有端口"的全通后门,
  #   连 fail2ban、docker 的规则都会被跳过。RETURN 只是回到 INPUT 继续往下走,
  #   同时跳过本链后面那条黑名单 DROP, 语义正好。
  $cmd -t "$tbl" -A IPBBT -m set --match-set "ipbbt_wl$v" src -j RETURN || return 1
  $cmd -t "$tbl" -A IPBBT -m set --match-set "ipbbt_bl$v" src -j DROP || return 1
  if [[ $tbl == raw ]]; then
    $cmd -t raw -C PREROUTING -j IPBBT 2>/dev/null || $cmd -t raw -I PREROUTING 1 -j IPBBT || return 1
  else
    for h in INPUT FORWARD; do
      $cmd -t filter -C "$h" -j IPBBT 2>/dev/null || $cmd -t filter -I "$h" 1 -j IPBBT || return 1
    done
  fi
  return 0
}
apply_ipt(){
  local f; _rundir || return 1
  f=$(mktemp "$RUNDIR/ipt.XXXXXX") || return 1
  {
    gen_ipset ipbbt_wl4 "hash:net family inet"  "$WL" 4
    gen_ipset ipbbt_bl4 "hash:net family inet"  "$BL" 4
    if have_ip6tables; then
      gen_ipset ipbbt_wl6 "hash:net family inet6" "$WL" 6
      gen_ipset ipbbt_bl6 "hash:net family inet6" "$BL" 6
    fi
  } > "$f"
  # 内核禁用了 IPv6 时, create ... family inet6 也会让整批 restore 失败
  if ! ipset restore -exist < "$f"; then
    cp -f "$f" /tmp/ipblockbt.failed.ipset 2>/dev/null
    warn "ipset 报错, 失败的指令已保存到 /tmp/ipblockbt.failed.ipset"
    rm -f "$f"; return 1
  fi
  rm -f "$f"
  ipt_chain iptables 4 || return 1
  if have_ip6tables; then
    # IPv6 失败不拖累 IPv4: 告警后继续
    ipt_chain ip6tables 6 || warn "IPv6 规则加载失败, 已忽略(不影响 IPv4 封禁)"
  fi
  return 0
}

apply(){ if [[ $BACKEND == nft ]]; then apply_nft; else apply_ipt; fi; }
is_applied(){
  if [[ $BACKEND == nft ]]; then
    nft list table inet ipblockbt >/dev/null 2>&1
  elif [[ ${IPT_TABLE:-raw} == raw ]]; then
    iptables -t raw -C PREROUTING -j IPBBT >/dev/null 2>&1
  else
    iptables -t filter -C INPUT -j IPBBT >/dev/null 2>&1
  fi
}

# ---------------------------------------------------------------------
# 1. 封禁
# ---------------------------------------------------------------------
# 危险范围判定: 0=拒绝(会搞死本机或全网) 1=过宽(需二次确认) 2=正常
range_risk(){ # entry(已规范化)
  local e=$1 p
  case $e in
    127.*|::1|0.0.0.0) return 0 ;;          # 回环/全零地址: 封了会影响本机服务互访
  esac
  [[ $e == */* ]] || return 2
  p=$((10#${e#*/}))
  if [[ $e == *:* ]]; then
    (( p == 0 )) && return 0
    (( p <= 16 )) && return 1
    return 2
  fi
  (( p == 0 )) && return 0
  case ${e%/*} in
    127.*|0.*|255.*) return 0 ;;
  esac
  (( p <= 8 )) && return 1
  return 2
}

do_block(){
  local input tok e a ans risk; local -a added=()
  read -rp "输入要封禁的 IP / IP段 (如 1.2.3.4 或 1.2.3.0/24, 多个用空格或逗号分隔): " input || exit 0
  [[ -z $input ]] && return
  snapshot
  for tok in ${input//,/ }; do
    normalize_entry "$tok" || { warn "格式无效: $tok"; continue; }
    e=$NORM
    if grep -qxF -- "$e" "$BL"; then info "已在封禁列表: $e"; continue; fi
    range_risk "$e"; risk=$?
    if (( risk == 0 )); then
      err "$e 会切断本机回环/全部流量, 已拒绝"; continue
    elif (( risk == 1 )); then
      warn "$e 范围过大, 可能误封正常用户(含你自己的出口 IP)"
      read -rp "仍要封禁? (y/N): " ans || exit 0
      [[ $ans == [yY] ]] || continue
    fi
    # 私网/本机网段: 封了通常没意义, 还可能切断与内网/容器的互访, 至少提示一次
    if in_protected "$e"; then
      warn "$e 属于内网或本机网段 ($SEG_GUARD), 封禁后可能与内网/容器断连"
      read -rp "仍要封禁? (y/N): " ans || exit 0
      [[ $ans == [yY] ]] || continue
    fi
    if in_list "$WL" "$e"; then warn "$e 在白名单中,跳过"; continue; fi
    # 只对 CIDR 行做包含判断, 用 grep 先把非 CIDR 行滤掉, 避免 O(N) 的纯 bash 循环
    if [[ $e == */* ]]; then
      while IFS= read -r a || [[ -n $a ]]; do
        [[ -n $a ]] && ip_match "$e" "$a" && { warn "网段 $e 包含白名单 $a, 该 IP 仍会放行"; break; }
      done < <(grep -F '/' "$WL" 2>/dev/null)
    fi
    if [[ -n $SSH_IP ]] && ip_match "$e" "$SSH_IP"; then
      warn "$e 包含你当前的 SSH 连接 IP ($SSH_IP), 封禁后会立即断开!"
      read -rp "仍要封禁? (y/N): " ans || exit 0
      [[ $ans == [yY] ]] || continue
    fi
    echo "$e" >> "$BL"; added+=("$e")
  done
  if (( ${#added[@]} == 0 )); then warn "没有新增封禁"; tx_done; return; fi
  # 如果这次封的是网段, 顺手把被它覆盖的单 IP 条目清掉
  local hadseg=0 a2
  for a2 in "${added[@]}"; do [[ $a2 == */* ]] && hadseg=1; done
  (( hadseg )) && compact_bl
  if commit; then
    for a in "${added[@]}"; do info "已封禁: $a"; log "BAN(手动) $a"; done
  else
    err "本次封禁未生效, 已回滚"
  fi
}

# ---------------------------------------------------------------------
# 2 / 6. 查看列表 + 删除
# ---------------------------------------------------------------------
delete_items(){ # file input label
  local file=$1 input=$2 label=$3 tok i lo hi t l
  local -a lines=() targets=() removed=()
  while IFS= read -r l || [[ -n $l ]]; do lines+=("$l"); done < "$file"
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
  (( ${#targets[@]} )) || return
  snapshot
  for t in "${targets[@]}"; do
    if grep -qxF -- "$t" "$file"; then del_line "$file" "$t"; removed+=("$t")
    else warn "未找到: $t"; fi
  done
  if (( ${#removed[@]} )); then
    if commit; then
      for t in "${removed[@]}"; do
        info "已删除: $t"; log "DEL $t ($(basename "$file"))"
        # 删的是白名单, 而该 IP 仍在黑名单里 => 立刻会被封, 提醒一下
        [[ $file == "$WL" ]] && in_list "$BL" "$t" && warn "  注意: $t 仍在封禁列表中, 已立即生效"
      done
    else
      err "删除未生效, 已回滚"
    fi
  else
    tx_done
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
    read -rp "请选择: " ch || exit 0
    case $ch in
      1)
        [[ -s $file ]] || { warn "列表为空"; pause; continue; }
        read -rp "输入序号(可多个,支持范围如 1-3,空格或逗号分隔),或直接输入 IP/IP段: " in || exit 0
        [[ -n $in ]] && delete_items "$file" "$in" "$label"
        pause ;;
      0) return ;;
      "") return ;;
    esac
  done
}

# ---------------------------------------------------------------------
# 3. lastb 自动封禁
# ---------------------------------------------------------------------
# 当前已建立连接的对端 IP
# 取最后一列(不同版本 ss 对 State 列的输出不一致), 再依次去端口 -> 方括号 -> IPv4 映射前缀
# 注意顺序: 必须先剥端口再剥 "]", 否则 "[2001:db8::1]:22" 会剥成 "2001:db8::1]"
peer_ips(){
  command -v ss >/dev/null 2>&1 || return 0
  { ss -Htn state established 2>/dev/null || ss -tn state established 2>/dev/null | tail -n +2; } \
    | awk 'NF>0 {print $NF}' \
    | sed -E -e 's/:[0-9]+$//' -e 's/^\[//' -e 's/\]$//' -e 's/^::ffff://' -e 's/%.*$//'
}
# 近期成功登录过的 IP (防 NAT 出口 IP 被同事/自己误封)
login_ips(){
  command -v last >/dev/null 2>&1 || return 0
  last -i -n 200 2>/dev/null | awk 'NF>=4 && $3 ~ /^[0-9a-fA-F:.]+$/ && ($3 ~ /\./ || $3 ~ /:/) {print $3}' \
    | sed -e 's/^::ffff://' | sort -u
}
# 0 = 这个 IP 不该自动封
risky_ip(){
  local ip=$1
  [[ -n $SSH_IP && $SSH_IP == "$ip" ]] && return 0
  peer_ips  | grep -Fxq -- "$ip" && return 0
  (( SKIP_SUCCESS )) && login_ips | grep -Fxq -- "$ip" && return 0
  return 1
}

# ---------------------------------------------------------------------
# 3.5 按段聚合 (单 IP -> /24 -> /16)
#   规则(可在文件头调整):
#     · 同一 C段(/24) 里出现 >= AGG_C_MIN 个不同 IP -> 直接封整个 /24
#     · 同一 B段(/16) 下, 若"上一波已封过某 /24"且本轮又出现新的 /24
#       -> 围绕新 /24 前后各扩 AGG_NEIGHBOR 个 /24 (只在同一个 /16 内扩)
#     · 需要覆盖的 /24 超过 AGG_B_HARD 个 -> 直接封整个 /16
#     · 已被段覆盖的单 IP 一律从黑名单剔除(避免名单膨胀)
#   安全阀: 段里含当前 SSH IP 时不封段, 降级为逐 IP 封禁。
# ---------------------------------------------------------------------
agg_compute(){ # $1=候选IP文件  $2=现有黑名单  输出最终条目(每行一个)
  # 所有键统一用 "a.b" / "a.b.c" 点分格式, 不要和空格分隔混用(混用会导致 in 判断永远不成立)
  awk -v nmin="${AGG_C_MIN:-3}" -v nhard="${AGG_B_HARD:-20}" -v nneigh="${AGG_NEIGHBOR:-8}" '
  function add24(c,  q,b) {
    split(c, q, ".")                       # c = "a.b.c"
    b = q[1] "." q[2]
    if (!(c in seen24)) { seen24[c] = 1; arr[b] = arr[b] " " q[3]; nb[b]++ }
  }
  FILENAME == ARGV[1] {                    # 第一份: 本轮候选 IP
    ip = $0; gsub(/[ \t]/, "", ip)
    if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) next
    if (ip in seen) next
    seen[ip] = 1
    split(ip, o, ".")
    cnt[o[1] "." o[2] "." o[3]]++
    next
  }
  {                                        # 第二份: 现有黑名单, 用来识别"上一波"
    e = $0; gsub(/[ \t]/, "", e)
    if (e ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/24$/) {
      sub(/\/24$/, "", e); split(e, q, "."); old24[q[1] "." q[2] "." q[3]] = 1
    } else if (e ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/16$/) {
      sub(/\/16$/, "", e); split(e, q, "."); old16[q[1] "." q[2]] = 1
    } else if (e ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
      split(e, q, "."); old32[e] = 1; cnt[q[1] "." q[2] "." q[3]]++
    }
  }
  END {
    for (c in cnt) if (cnt[c] >= nmin) hot[c] = 1        # 本轮热点 /24
    for (c in old24) {                                   # 上一波封过的段也要纳入
      add24(c); split(c, q, "."); nold[q[1] "." q[2]]++
    }
    for (c in hot) if (!(c in old24)) add24(c)           # 本轮新热点
    for (c in hot) if (!(c in old24)) { split(c, q, "."); newhot[q[1] "." q[2]] = 1 }

    for (b in arr) {
      if (b in old16) { covb[b] = 1; continue }          # 整段已封
      delete U
      n = split(arr[b], a3, " ")
      for (i = 1; i <= n; i++) if (a3[i] != "") U[a3[i] + 0] = 1
      # 只有"后期又出现新的 /24"(该 /16 之前已封过别的 /24)才扩张;
      # 第一波只封观测到的 /24, 不主动扫邻居
      if ((b in newhot) && nold[b] >= 1 && nneigh > 0) {
        for (c in hot) {
          if (c in old24) continue
          split(c, q, ".")
          if (q[1] "." q[2] != b) continue
          v = q[3] + 0
          for (d = -nneigh; d <= nneigh; d++) {
            x = v + d
            if (x >= 0 && x <= 255) U[x] = 1
          }
        }
      }
      nu = 0; for (x in U) nu++
      if (nu > nhard) { print b ".0.0/16"; covb[b] = 1; continue }
      for (x in U) { print b "." x ".0/24"; cov24[b "." x] = 1 }
    }
    for (ip in seen) {                                   # 剩下的按单 IP
      split(ip, o, ".")
      c24 = o[1] "." o[2] "." o[3]
      if ((o[1] "." o[2]) in covb) continue
      if (c24 in cov24) continue
      if (ip in old32) continue
      if (c24 in hot) continue
      print ip
    }
  }' "$1" "$2"
}

# 把被已有网段覆盖的 /32 删掉(段封了就不用再留着单 IP)
compact_bl(){
  local t
  [[ -s $BL ]] || return 0
  t=$(mktemp "$DATA_DIR/.ipblockbt.XXXXXX") || return 1
  awk '
  { line[NR] = $0 }
  END {
    ns = 0
    for (i = 1; i <= NR; i++) if (index(line[i], "/") > 0) seg[++ns] = line[i]
    for (i = 1; i <= NR; i++) {
      l = line[i]
      if (index(l, "/") > 0) { print l; continue }
      if (l !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print l; continue }
      split(l, q, ".")
      ipn = q[1] * 16777216 + q[2] * 65536 + q[3] * 256 + q[4]
      cov = 0
      for (j = 1; j <= ns; j++) {
        s = seg[j]
        if (s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) continue
        split(s, p, "/"); split(p[1], w, ".")
        pfx = p[2] + 0
        if (pfx < 0 || pfx > 32) continue
        if (w[1] > 255 || w[2] > 255 || w[3] > 255 || w[4] > 255) continue
        sn = w[1] * 16777216 + w[2] * 65536 + w[3] * 256 + w[4]
        # 用整除代替位与, 避免依赖 gawk 的 and()
        d = int(ipn / (2 ^ (32 - pfx))); s2 = int(sn / (2 ^ (32 - pfx)))
        if (d == s2) { cov = 1; break }
      }
      if (!cov) print l
    }
  }' "$BL" > "$t"
  if [[ -s $t ]] || [[ ! -s $BL ]]; then
    mv -f "$t" "$BL"; chmod 644 "$BL" 2>/dev/null
  else
    : > "$t"; mv -f "$t" "$BL"   # 全被覆盖也不能留空文件以外的状态
  fi
  return 0
}

# 这些网段整体封禁会切断本机与内网/容器的互通, 聚合时必须避让:
#   本机各网卡地址所在网段 + 私网 / CGNAT / 链路本地 / 环回
protected_nets(){
  {
    if command -v ip >/dev/null 2>&1; then
      ip -o -4 addr show 2>/dev/null | awk '{print $4}'
      ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}'
    fi
    printf '%s\n' 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 \
                  169.254.0.0/16 fc00::/7 fe80::/10 ::1/128
  } | grep . | sort -u
}
# 两个条目是否相交(任一包含另一方)
net_intersects(){ ip_match "$1" "$2" || ip_match "$2" "$1"; }
# $1 是否落在受保护网段内; 命中时 SEG_GUARD 记下是哪个网段
in_protected(){
  local p
  while IFS= read -r p; do
    [[ -z $p ]] && continue
    if net_intersects "$1" "$p"; then SEG_GUARD=$p; return 0; fi
  done < <(protected_nets)
  return 1
}
# 段 $1 是否踩到保护对象: 受保护网段 / 当前 SSH IP / 在线会话 / 近期成功登录
# 命中返回 0, 原因写入 SEG_GUARD
seg_guard(){
  local ip
  in_protected "$1" && { SEG_GUARD="内网或本机网段 $SEG_GUARD"; return 0; }
  if [[ -n $SSH_IP ]] && ip_match "$1" "$SSH_IP"; then
    SEG_GUARD="当前 SSH IP $SSH_IP"; return 0
  fi
  while IFS= read -r ip; do
    [[ -z $ip ]] && continue
    if ip_match "$1" "$ip"; then SEG_GUARD="在线会话或成功登录 $ip"; return 0; fi
  done < <( { peer_ips; (( SKIP_SUCCESS )) && login_ips; } )
  return 1
}

agg_apply(){ # $1=候选IP文件 $2=quiet, 结果条数放 AGG_ADDED
  local f=$1 quiet=$2 e ip
  AGG_ADDED=0
  _rundir || return 1
  local out; out=$(mktemp "$RUNDIR/agg.XXXXXX") || return 1
  agg_compute "$f" "$BL" > "$out" 2>/dev/null

  while IFS= read -r e; do
    [[ -z $e ]] && continue
    if [[ $e == */* ]]; then
      # 段封禁前必须过安全阀: 私网/本机网段、当前 SSH、在线会话, 任一命中就降级成逐 IP
      if seg_guard "$e"; then
        log "AGG SKIP $e 与 $SEG_GUARD 相交, 降级为逐 IP"
        [[ $quiet ]] || warn "$e 涉及$SEG_GUARD, 改为逐个封禁候选 IP"
        while IFS= read -r ip; do
          [[ -z $ip || $ip == *:* ]] && continue
          ip_match "$e" "$ip" || continue
          # 降级后同样是私网/本机网段里的 IP 也不封(如 192.168.x 段里的候选)
          if in_protected "$ip"; then
            log "AGG SKIP $ip 位于内网/本机网段 $SEG_GUARD (段 $e 降级)"
            continue
          fi
          grep -qxF -- "$ip" "$BL" && continue
          echo "$ip" >> "$BL"; AGG_ADDED=$((AGG_ADDED+1))
          log "AGG BAN $ip (段 $e 降级)"
        done < "$f"
        continue
      fi
    else
      # 单 IP 落在内网/本机网段: 封了没意义, 还可能切断内部互通
      if in_protected "$e"; then
        log "AGG SKIP $e 位于内网/本机网段 $SEG_GUARD"
        continue
      fi
    fi
    grep -qxF -- "$e" "$BL" && continue
    echo "$e" >> "$BL"; AGG_ADDED=$((AGG_ADDED+1))
    log "AGG BAN $e"
    [[ $quiet ]] || info "封禁: $e"
  done < "$out"

  # agg_compute 只做 IPv4; IPv6 候选逐个封(候选阶段已过 risky_ip 过滤)
  while IFS= read -r ip; do
    [[ $ip == *:* ]] || continue
    if in_protected "$ip"; then
      log "AGG SKIP $ip 位于内网/本机网段 $SEG_GUARD"
      continue
    fi
    grep -qxF -- "$ip" "$BL" && continue
    echo "$ip" >> "$BL"; AGG_ADDED=$((AGG_ADDED+1))
    log "AGG BAN $ip (IPv6)"
    [[ $quiet ]] || info "封禁: $ip"
  done < "$f"

  rm -f "$out"
  (( AGG_ADDED > 0 )) && compact_bl
  return 0
}

# 从 lastb 收集候选 IP 写入 $1, 结果数放 CAND_N / CAND_SK
auto_candidates(){ # $1=输出文件 $2=quiet
  local out=$1 quiet=$2 ip cnt
  local -a largs=(-i -w)
  CAND_N=0; CAND_SK=0
  if ! command -v lastb >/dev/null 2>&1 || [[ ! -r /var/log/btmp ]]; then
    [[ $quiet ]] || warn "找不到 lastb 或 /var/log/btmp (没有登录失败记录)"
    return 1
  fi
  # btmp 会累积一整个月, 只统计最近 BAN_WINDOW 内的失败, 避免"半年错 5 次也被封"
  if lastb -i -w -s "$BAN_WINDOW" >/dev/null 2>&1; then
    largs=(-i -w -s "$BAN_WINDOW")
  elif [[ ! -f $DATA_DIR/.no_window ]]; then
    log "WARN lastb 不支持 -s, 退化为全量统计(仅记录一次)"
    : > "$DATA_DIR/.no_window" 2>/dev/null
  fi
  : > "$out"
  while read -r ip cnt; do
    [[ -z $ip ]] && continue
    normalize_entry "$ip" || continue
    ip=$NORM
    in_list "$WL" "$ip" && continue
    in_list "$BL" "$ip" && continue
    if risky_ip "$ip"; then
      CAND_SK=$((CAND_SK+1))
      # cron 每小时都会命中同一批 IP, 安静模式下不逐条写日志, 否则几天就把日志刷满
      [[ -z $quiet ]] && log "SKIP(auto) $ip 有成功登录/活动会话或属于当前 SSH, 不自动封禁"
      [[ $quiet ]] || warn "跳过 $ip (有成功登录或活动会话, 防误封)"
      continue
    fi
    echo "$ip" >> "$out"; CAND_N=$((CAND_N+1))
  done < <(lastb "${largs[@]}" 2>/dev/null | awk -v t="$THRESHOLD" '
      $1!="btmp" && NF>=3 && $3!="0.0.0.0" && $3 ~ /^[0-9a-fA-F:.]+$/ && ($3 ~ /\./ || $3 ~ /:/) {c[$3]++}
      END{for(i in c) if(c[i]>=t) print i, c[i]}')
  return 0
}

auto_scan(){ # [quiet]
  local quiet=$1 cand added=0 ip n sk
  _rundir || { err "创建临时目录失败"; return 1; }
  cand=$(mktemp "$RUNDIR/cand.XXXXXX") || { err "创建临时文件失败"; return 1; }
  auto_candidates "$cand" "$quiet" || { rm -f "$cand"; return 1; }
  n=$CAND_N; sk=$CAND_SK
  snapshot
  if (( n > 0 )); then
    if (( AGG_ENABLE )); then
      agg_apply "$cand" "$quiet"; added=$AGG_ADDED
      [[ $quiet ]] || info "聚合结果: 候选 $n 个 IP -> 新增 $added 条规则"
    else
      while IFS= read -r ip; do
        [[ -z $ip ]] && continue
        echo "$ip" >> "$BL"; added=$((added+1))
        log "AUTO-BAN $ip"
        [[ $quiet ]] || info "封禁 $ip"
      done < "$cand"
    fi
  fi
  rm -f "$cand"
  if (( added > 0 )); then
    commit || { err "自动封禁未能生效, 已回滚"; return 1; }
    log "AUTO 本轮新增 $added 条(候选 $n 个 IP, 跳过 $sk, 聚合=$( (( AGG_ENABLE )) && echo on || echo off ))"
  else
    tx_done
  fi
  [[ $quiet ]] || info "本轮新增 $added 条规则, 跳过 $sk 个 IP (阈值: >= $THRESHOLD 次)"
  return 0
}

agg_preview(){
  local cand e nnew=0 nold=0
  _rundir || { err "创建临时目录失败"; return 1; }
  cand=$(mktemp "$RUNDIR/cand.XXXXXX") || return 1
  auto_candidates "$cand" "" || { rm -f "$cand"; return 1; }
  clear
  echo -e "${C}========== 本轮聚合预览 (不会写入任何规则) ==========${N}"
  echo "  阈值: 同一 /24 内 >= $AGG_C_MIN 个不同 IP -> 封 /24"
  echo "        同一 /16 下 > $AGG_B_HARD 个 /24 -> 封 /16"
  echo "        第二波出现新 /24 时前后各扩 $AGG_NEIGHBOR 个 /24"
  echo "  候选: $CAND_N 个 IP (跳过 $CAND_SK 个: 已在名单/防误封)"
  echo "--------------------------------------------"
  if (( CAND_N == 0 )); then
    echo "   (没有满足阈值的失败 IP)"; rm -f "$cand"; return 0
  fi
  while IFS= read -r e; do
    [[ -z $e ]] && continue
    if grep -qxF -- "$e" "$BL"; then
      echo "   $e   ${Y}(已在黑名单)${N}"; nold=$((nold+1))
    else
      echo -e "   ${G}$e${N}"; nnew=$((nnew+1))
    fi
  done < <(agg_compute "$cand" "$BL")
  echo "--------------------------------------------"
  echo "  将新增 $nnew 条, 已存在 $nold 条"
  echo "  被上述网段覆盖的单 IP 条目会被自动剔除(compact)"
  rm -f "$cand"
  return 0
}

# 从仓库下载自身并安装; 供 `bash <(curl ...)` 这类无实体文件的运行方式使用
self_download(){
  local tmp url
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || return 1
  _rundir || return 1
  tmp=$RUNDIR/self.$$.sh
  for url in "$SRC_URL" "$SRC_URL_FALLBACK"; do
    rm -f "$tmp"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --connect-timeout 8 --max-time 30 -o "$tmp" "$url" 2>/dev/null || continue
    else
      wget -q -T 30 -O "$tmp" "$url" 2>/dev/null || continue
    fi
    # 至少要像个脚本, 且能过语法检查 —— 防止镜像/代理返回 HTML 错误页被当成脚本装上
    [[ -s $tmp ]] || continue
    head -n 1 "$tmp" | grep -q '^#!' || continue
    bash -n "$tmp" 2>/dev/null || continue
    cp -f "$tmp" "$INSTALL_PATH" 2>/dev/null && chmod 755 "$INSTALL_PATH" && return 0
  done
  return 1
}

install_self(){
  # 已经在安装路径上, 什么都不用做
  if [[ $SELF_IS_FILE -eq 1 && $SELF == "$INSTALL_PATH" ]]; then return 0; fi
  if [[ $SELF_IS_FILE -eq 1 ]]; then
    if cp -f "$SELF" "$INSTALL_PATH" 2>/dev/null && chmod 755 "$INSTALL_PATH"; then
      info "脚本已安装到 $INSTALL_PATH"
      return 0
    fi
    warn "复制到 $INSTALL_PATH 失败, 改用下载方式"
  else
    info "当前以管道方式运行(没有实体文件), 从仓库下载后安装到 $INSTALL_PATH"
  fi
  if self_download; then info "已下载并安装到 $INSTALL_PATH"; return 0; fi
  err "无法安装到 $INSTALL_PATH, 定时任务与开机恢复都不会生效"
  err "请手动执行: curl -fsSL -o $INSTALL_PATH $SRC_URL && chmod 755 $INSTALL_PATH"
  return 1
}

auto_menu(){
  local ch
  while true; do
    clear
    echo -e "${C}========== lastb 自动封禁 (失败 >= $THRESHOLD 次) ==========${N}"
    if [[ -f $CRON_FILE ]]; then echo -e "  定时任务: ${G}已开启 (每小时整点)${N}"; else echo -e "  定时任务: ${Y}未开启${N}"; fi
    if (( AGG_ENABLE )); then
      echo -e "  按段聚合: ${G}已开启${N}  (/24 内 >=${AGG_C_MIN} 个IP 封 /24; >${AGG_B_HARD} 个 /24 封 /16; 前后各扩 ${AGG_NEIGHBOR} 个)"
    else
      echo -e "  按段聚合: ${Y}已关闭${N}  (只按单 IP 封)"
    fi
    echo "  1. 立即检测一次"
    echo "  2. 预览本轮会封什么 (不写入规则)"
    echo "  3. 开启每小时自动检测"
    echo "  4. 关闭每小时自动检测"
    echo "  5. 开关按段聚合"
    echo "  6. 查看最近日志"
    echo "  0. 返回主菜单"
    read -rp "请选择: " ch || exit 0
    case $ch in
      1) auto_scan; pause ;;
      2) agg_preview; pause ;;
      3) install_self || { warn "脚本未安装成功, 定时任务未创建"; pause; continue; }
         # 末尾换行是 /etc/cron.d 的硬性要求
         printf '0 * * * * root %s --auto >/dev/null 2>&1\n' "$INSTALL_PATH" > "$CRON_FILE"
         chmod 644 "$CRON_FILE"; info "已开启: 每小时检测一次"; pause ;;
      4) rm -f "$CRON_FILE"; info "已关闭自动检测"; pause ;;
      5) if (( AGG_ENABLE )); then AGG_ENABLE=0; warn "已关闭(仅本次运行生效, 永久修改请改脚本头部的 AGG_ENABLE)"
         else AGG_ENABLE=1; info "已开启"; fi; pause ;;
      6) tail -n 30 "$LOG"; pause ;;
      0) return ;;
      "") return ;;
    esac
  done
}

# ---------------------------------------------------------------------
# 4. 手动解封
# ---------------------------------------------------------------------
do_unblock(){
  local input tok e c ans found; local -a removed=()
  read -rp "输入要解封的 IP / IP段 (多个用空格或逗号分隔): " input || exit 0
  [[ -z $input ]] && return
  snapshot
  for tok in ${input//,/ }; do
    normalize_entry "$tok" || { warn "格式无效: $tok"; continue; }
    e=$NORM
    if grep -qxF -- "$e" "$BL"; then
      del_line "$BL" "$e"; removed+=("$e"); continue
    fi
    found=""
    # 输入可以是 IP 也可以是 CIDR: 1.1.1.0/25 被 1.1.1.0/24 覆盖时同样要能提示
    while IFS= read -r c || [[ -n $c ]]; do
      [[ $c == */* ]] || continue
      [[ $c == "$e" ]] && continue
      if ip_match "$c" "$e"; then found=$c; break; fi
    done < <(grep -F '/' "$BL" 2>/dev/null)
    if [[ -n $found ]]; then
      warn "$e 属于已封禁网段 $found"
      read -rp "是否解封整个网段 $found ? (y/N): " ans || exit 0
      if [[ $ans == [yY] ]]; then del_line "$BL" "$found"; removed+=("$found"); fi
    else
      warn "不在封禁列表: $e"
    fi
  done
  if (( ${#removed[@]} == 0 )); then warn "没有可解封的条目"; tx_done; return; fi
  if commit; then
    for e in "${removed[@]}"; do info "已解封: $e"; log "UNBAN $e"; done
  else
    err "解封未生效, 已回滚"; return
  fi
  read -rp "是否同时加入白名单(防止被 lastb 自动再次封禁)? (y/N): " ans || exit 0
  if [[ $ans == [yY] ]]; then
    snapshot                                  # 第二次改动同样要有回滚点
    for e in "${removed[@]}"; do grep -qxF -- "$e" "$WL" || echo "$e" >> "$WL"; done
    commit && info "已加入白名单" || warn "白名单未生效, 已回滚"
  fi
}

# ---------------------------------------------------------------------
# 5. 设置白名单
# ---------------------------------------------------------------------
do_whitelist(){
  local input tok e ans rk; local -a added=()
  [[ -n $SSH_IP ]] && echo "提示: 你当前的 SSH 连接 IP 是 $SSH_IP"
  read -rp "输入要加入白名单的 IP / IP段 (多个用空格或逗号分隔): " input || exit 0
  [[ -z $input ]] && return
  snapshot
  for tok in ${input//,/ }; do
    normalize_entry "$tok" || { warn "格式无效: $tok"; continue; }
    e=$NORM
    # 白名单优先级最高: 放个 /0 进来等于把整个黑名单废掉, 必须拦
    case $e in
      0.0.0.0/0|::/0)
        err "$e 会让全部黑名单立即失效, 已拒绝"; continue ;;
    esac
    range_risk "$e"; rk=$?
    if (( rk == 1 )); then
      warn "$e 范围很宽, 会放行大量地址(含所有被封禁的同类来源)"
      read -rp "仍要加入白名单? (y/N): " ans || exit 0
      [[ $ans == [yY] ]] || continue
    fi
    if grep -qxF -- "$e" "$WL"; then
      info "已在白名单: $e"
      ddns_release_ip "$e"          # 用户显式加这个 IP => 从 DDNS 手里接管
      continue
    fi
    echo "$e" >> "$WL"; added+=("$e")
    ddns_release_ip "$e"
    if grep -qxF -- "$e" "$BL"; then del_line "$BL" "$e"; warn "已从封禁列表移除: $e"; fi
  done
  if (( ${#added[@]} == 0 )); then tx_done; return; fi
  if commit; then for e in "${added[@]}"; do info "已加入白名单: $e"; log "WHITELIST $e"; done
  else err "本次白名单未生效, 已回滚"; fi
}

# ---------------------------------------------------------------------
# 9. DDNS 动态域名白名单
#    场景: 家里/公司的公网 IP 是动态的, 用 DDNS 域名代替写死 IP。
#    策略(借鉴端口转发脚本 v6.0):
#      · 三级降级解析 getent ahostsv4 -> getent hosts -> dig -> nslookup(过滤 Server 行)
#      · 先登记 pending, 解析成功后再落 IP; 解析失败时保留旧 IP, 绝不删规则
#      · 配置文件走"临时文件 + 行数校验 + 原子替换", 防止中途被杀导致丢配置
#      · IP 没变但白名单里丢了(被手工删掉)会自动补回, 防状态漂移
#    注意: 只跟踪 A 记录(IPv4); 域名解析结果会直接进白名单, 只填你自己控制的域名。
# ---------------------------------------------------------------------
is_fqdn(){
  local d=$1
  (( ${#d} <= 253 )) || return 1
  [[ $d =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

# 过滤出合法 A 记录并去重排序(排序是为了让多 A 记录的选择稳定, 不同解析器结果一致)
_a_list(){ printf '%s\n' "$1" | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u; }

resolve_domain(){ # domain -> 输出 "IPv4 候选数" (失败输出 " 0")
  # 注意: 结果必须用 "ip 个数" 一起回传 —— 调用方是 $(...) 子 shell,
  # 函数里赋值全局变量传不出去(这个坑踩过一次)
  local d=$1 cand=""
  if command -v getent >/dev/null 2>&1; then
    cand=$(_a_list "$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}')")
    [[ -z $cand ]] && cand=$(_a_list "$(getent hosts "$d" 2>/dev/null | awk '{print $1}')")
  fi
  if [[ -z $cand ]] && command -v dig >/dev/null 2>&1; then
    cand=$(_a_list "$(dig +short +time=3 +tries=2 A "$d" 2>/dev/null)")
  fi
  # nslookup 第三级: 跳过 Server/本机 DNS 行, 只取 Name: 之后的 Address
  if [[ -z $cand ]] && command -v nslookup >/dev/null 2>&1; then
    cand=$(_a_list "$(nslookup "$d" 2>/dev/null | awk '/^Name:/{f=1} f && /^Address:/{print $2}')")
  fi
  [[ -z $cand ]] && { printf ' 0'; return 0; }
  local n; n=$(printf '%s\n' "$cand" | grep -c .)
  printf '%s %s' "$(printf '%s\n' "$cand" | head -1)" "$n"
}

# 域名匹配一律按第一列精确比较: grep "^${d}|" 会把域名里的 . 当通配符,
# a.b.com 能匹配到 axb.com; 用户输入 ".*" 还会误删第一条
ddns_lookup(){ awk -F'|' -v d="$1" '$1==d {print; exit}' "$DDNS_CONF" 2>/dev/null; }
ddns_exists(){ awk -F'|' -v d="$1" '$1==d {f=1} END{exit !f}' "$DDNS_CONF" 2>/dev/null; }
# 该 IP 是否已经有一条"由脚本写入"的记录(owned 缺省按 1 处理, 兼容旧格式)
ddns_ip_owned(){ awk -F'|' -v ip="$1" '$2==ip && $4!="0" {f=1} END{exit !f}' "$DDNS_CONF" 2>/dev/null; }
# 用户手工把某个 IP 加进白名单 => 把管理权交还用户, 以后域名换 IP 不再自动撤它
ddns_release_ip(){
  local ip=$1 n t
  [[ -s $DDNS_CONF ]] || return 0
  n=$(awk -F'|' -v ip="$ip" '$2==ip && $4!="0"' "$DDNS_CONF" 2>/dev/null | grep -c .)
  (( n > 0 )) || return 0
  t=$(mktemp "$DATA_DIR/.ddns.XXXXXX") || return 1
  awk -F'|' -v OFS='|' -v ip="$ip" '{$4 = ($2==ip ? 0 : (NF>=4 && $4!="" ? $4 : 1))} 1' "$DDNS_CONF" > "$t" \
    && mv -f "$t" "$DDNS_CONF" && chmod 644 "$DDNS_CONF" 2>/dev/null
  info "该 IP 已交回手工管理 (DDNS 不再自动撤销它)"
  log "DDNS OWNED-OFF $ip (用户手工添加)"
  return 0
}

ddns_ip_used_by_other(){ # 跳过某个域名后, 该 IP 是否还被别的 DDNS 记录使用
  local skip=$1 ip=$2 d i rest owned
  while IFS='|' read -r d i rest owned; do
    [[ -z $d || $d == \#* ]] && continue
    [[ $d == "$skip" ]] && continue
    [[ $i == "$ip" ]] && return 0
  done < "$DDNS_CONF"
  return 1
}

ddns_print_table(){
  local d i rest st n=0
  printf "  %-4s %-34s %-17s %-12s %s\n" "序号" "域名" "解析IP" "状态" "更新时间"
  printf "  %-4s %-34s %-17s %-12s %s\n" "----" "----------------------------------" "-----------------" "------------" "------------------"
  while IFS='|' read -r d i rest owned; do
    [[ -z $d || $d == \#* ]] && continue
    n=$((n+1))
    if [[ -z $i || $i == pending ]]; then st="待解析"
    elif in_list "$WL" "$i"; then st="已放行"
    else st="不在白名单"
    fi
    local ts=""
    [[ -n $rest && $rest =~ ^[0-9]+$ ]] && ts=$(date -d "@$rest" '+%m-%d %H:%M' 2>/dev/null)
    [[ $owned == 0 ]] && ts="${ts:--} (手工已在)"
    printf "  %-4s %-34s %-17s %-12s %s\n" "$n" "$d" "${i:-pending}" "$st" "${ts:--}"
  done < "$DDNS_CONF"
  (( n == 0 )) && echo "   (空)"
  return 0
}

ddns_add(){
  local d ip
  echo ""
  echo "=== 添加 DDNS 域名 ==="
  echo "  说明: 只跟踪 A 记录(IPv4); 解析结果会被自动加入白名单。"
  echo "        请只填你自己控制的域名 —— 该域名的解析结果会获得全局放行。"
  read -rp "输入域名 (如 home.example.com): " d || exit 0
  d=$(printf '%s' "$d" | tr 'A-Z' 'a-z' | tr -d '[:space:]')
  [[ -z $d ]] && { warn "域名不能为空"; return; }
  if normalize_entry "$d" >/dev/null 2>&1; then
    warn "$d 是 IP 而不是域名; 直接加白名单请用主菜单 5"; return
  fi
  is_fqdn "$d" || { warn "域名格式不正确: $d"; return; }
  if grep -q "^${d}|" "$DDNS_CONF" 2>/dev/null; then warn "$d 已存在, 请先删除"; return; fi

  echo "  正在解析 $d ..."
  read -r ip _amulti <<< "$(resolve_domain "$d")"
  normalize_entry "$ip" >/dev/null 2>&1 && ip=$NORM || ip=""
  (( ${_amulti:-0} > 1 )) && warn "$d 有 ${_amulti} 条 A 记录, 只放行 ${ip:-第一条} (其余未处理)"

  local owned=1
  snapshot
  if [[ -z $ip ]]; then
    warn "当前解析失败, 已登记为 pending; 开启自动更新后会继续重试"
    ip=pending
    tx_done
  else
    info "解析成功: $d -> $ip"
    # owned=1 表示这个 IP 是本脚本写进去的; =0 表示用户早就手工加过,
    # 以后域名换 IP / 删域名时不能把这个手工条目一起撤掉。
    # 注意: 若这个 IP 其实是被别的 DDNS 记录写进来的(共享 IP), 继承 owned=1,
    # 否则两边都记 0, 最后谁都不负责撤, 这个 IP 会永久留在白名单里。
    if in_list "$WL" "$ip"; then
      if ddns_ip_owned "$ip"; then
        owned=1; info "该 IP 已由其它 DDNS 记录写入, 继承管理权"
      else
        owned=0; info "该 IP 已在白名单中(手工添加), 不会重复写入也不会被本条目删除"
      fi
    else
      echo "$ip" >> "$WL"
    fi
    if ! commit; then err "写入白名单失败, 已回滚, 未登记该域名"; return; fi
  fi
  printf '%s|%s|%s|%s\n' "$d" "$ip" "$(date +%s)" "$owned" >> "$DDNS_CONF"
  chmod 644 "$DDNS_CONF" 2>/dev/null
  info "已登记: $d (当前IP: $ip)"
  log "DDNS ADD $d -> $ip owned=$owned"
  [[ -f $DDNS_CRON ]] || warn "自动更新未开启, 可用「5」开启(每 ${DDNS_MIN} 分钟检测一次)"
}

ddns_del(){
  local input d i ts owned hit="" tmp
  echo ""
  if [[ ! -s $DDNS_CONF ]]; then warn "DDNS 列表为空"; return; fi
  echo "=== 删除 DDNS 域名 ==="
  ddns_print_table
  echo ""
  read -rp "输入要删除的域名或序号 (0 取消): " input || exit 0
  [[ -z $input || $input == 0 ]] && return
  if [[ $input =~ ^[0-9]+$ ]]; then
    local n=0
    while IFS='|' read -r d i ts owned; do
      [[ -z $d || $d == \#* ]] && continue
      n=$((n+1)); (( n == input )) && { hit=$d; break; }
    done < "$DDNS_CONF"
    [[ -z $hit ]] && { warn "序号 $input 不存在"; return; }
  else
    hit=$(printf '%s' "$input" | tr 'A-Z' 'a-z' | tr -d '[:space:]')
  fi
  local entry
  entry=$(ddns_lookup "$hit")
  [[ -z $entry ]] && { warn "$hit 不在列表中"; return; }
  IFS='|' read -r d i ts owned <<< "$entry"
  [[ -z $owned ]] && owned=1     # 兼容旧的三段格式

  snapshot
  # 只有"是脚本写进去的"且"没被别的域名共用"时才撤掉这个 IP
  if [[ $owned == 1 && -n $i && $i != pending ]] && ! ddns_ip_used_by_other "$d" "$i"; then
    if grep -qxF -- "$i" "$WL"; then del_line "$WL" "$i"; info "已从白名单移除: $i"; fi
  fi
  tmp=$(mktemp "$DATA_DIR/.ddns.XXXXXX") || { err "创建临时文件失败"; restore; tx_done; return 1; }
  # awk 精确匹配第一列: 用 grep "^${d}|" 时域名里的 . 会变成通配符(a.b.com 能匹配 axb.com)
  awk -F'|' -v d="$d" '$1!=d' "$DDNS_CONF" > "$tmp" 2>/dev/null
  # 校验: 写出的行数必须正好等于"原有效行数 - 1"
  if (( $(count "$tmp") + 1 == $(count "$DDNS_CONF") )); then
    mv -f "$tmp" "$DDNS_CONF"; chmod 644 "$DDNS_CONF" 2>/dev/null
  else
    rm -f "$tmp"; err "配置替换异常, 已放弃"
    restore; tx_done                    # 白名单已经改过, 必须先回滚再收尾
    return 1
  fi
  commit && info "已删除: $d" || warn "白名单未生效, 已回滚"
  log "DDNS DEL $d"
}

ddns_update(){ # [quiet]
  local quiet=$1 changed=0 failed=0 healed=0 d oldip ts owned newip amulti
  local -a stale=()
  if [[ ! -s $DDNS_CONF ]]; then
    [[ $quiet ]] || info "DDNS 列表为空, 没有需要更新的域名"
    return 0
  fi
  local tmp sum0 nproc=0 nwrite=0
  tmp=$(mktemp "$DATA_DIR/.ddns.XXXXXX") || return 1
  sum0=$(cksum < "$DDNS_CONF" 2>/dev/null)
  snapshot
  while IFS='|' read -r d oldip ts owned; do
    [[ -z $d || $d == \#* ]] && continue
    [[ -z $owned ]] && owned=1          # 兼容旧的三段格式
    nproc=$((nproc+1))
    read -r newip amulti <<< "$(resolve_domain "$d")"
    normalize_entry "$newip" >/dev/null 2>&1 && newip=$NORM || newip=""
    (( ${amulti:-0} > 1 )) && {
      log "DDNS WARN $d 有 $amulti 条 A 记录, 只取排序后第一条 $newip"
      [[ $quiet ]] || warn "$d 有 $amulti 条 A 记录, 只放行 $newip (其余未处理)"
    }

    if [[ -z $newip ]]; then
      failed=$((failed+1))
      [[ $quiet ]] || warn "$d 解析失败, 保留旧 IP (${oldip:-无})"
      printf '%s|%s|%s|%s\n' "$d" "$oldip" "$ts" "$owned" >> "$tmp"
      nwrite=$((nwrite+1))
      continue
    fi

    if [[ $newip == "$oldip" ]]; then
      # 防状态漂移: 记录没变但白名单里被手工删了 => 补回
      if ! in_list "$WL" "$newip"; then
        echo "$newip" >> "$WL"; healed=$((healed+1)); changed=1; owned=1
        log "DDNS HEAL $d -> $newip (白名单中缺失, 已补回)"
        [[ $quiet ]] || info "补回: $d -> $newip"
      else
        [[ $quiet ]] || info "$d -> $newip (无变化)"
      fi
      printf '%s|%s|%s|%s\n' "$d" "$oldip" "$ts" "$owned" >> "$tmp"
      nwrite=$((nwrite+1))
      continue
    fi

    # IP 变了: 旧 IP 先记下来, 等整轮跑完再决定撤不撤
    log "DDNS CHANGE $d ${oldip:-pending} -> $newip"
    [[ $quiet ]] || info "变更: $d  ${oldip:-pending} -> $newip"
    [[ $owned == 1 && -n $oldip && $oldip != pending ]] && stale+=("$oldip")
    if in_list "$WL" "$newip"; then
      # 新 IP 已在白名单: 若已有其它 DDNS 记录在管它, 继承管理权
      # 旧 conf 里已有别的记录在管它, 或本轮前面的域名刚把它写进 $tmp -> 继承管理权
      if ddns_ip_owned "$newip" \
         || awk -F'|' -v ip="$newip" '$2==ip && $4!="0" {f=1} END{exit !f}' "$tmp"; then
        owned=1
      else
        owned=0
      fi
    else
      echo "$newip" >> "$WL"; owned=1
    fi
    printf '%s|%s|%s|%s\n' "$d" "$newip" "$(date +%s)" "$owned" >> "$tmp"
    nwrite=$((nwrite+1))
    changed=1
  done < "$DDNS_CONF"

  # 两遍处理: 必须对着"新配置"判断旧 IP 还有没有人用。
  # 循环内查的是旧 conf, 两个域名同时从 A 换到 B 时会互相看到对方还在用 A, 谁都不撤。
  if (( ${#stale[@]} > 0 )); then
    local ip
    for ip in "${stale[@]}"; do
      [[ -z $ip ]] && continue
      if ! awk -F'|' -v ip="$ip" '$2==ip {f=1} END{exit !f}' "$tmp"; then
        if grep -qxF -- "$ip" "$WL"; then
          del_line "$WL" "$ip"; changed=1
          log "DDNS RELEASE $ip (已无域名引用, 从白名单移除)"
        fi
      fi
    done
  fi

  # 提交前双重校验:
  #   1) 写出的行数必须等于处理的记录数(注释/空行不计入, 不会被误判)
  #   2) conf 在解析期间被菜单改过(cksum 变化)就放弃本轮, 让下一轮自愈
  if (( nwrite != nproc )); then
    log "ERROR DDNS 写出 $nwrite 行 != 处理 $nproc 条, 放弃替换"
    rm -f "$tmp"; restore; tx_done
    err "DDNS 配置写入异常, 已回滚"; return 1
  fi
  if [[ $(cksum < "$DDNS_CONF" 2>/dev/null) != "$sum0" ]]; then
    log "ERROR DDNS 配置在解析期间被修改, 放弃本轮(下轮自愈)"
    rm -f "$tmp"; restore; tx_done
    err "配置在处理期间被改动(可能同时在菜单里增删了域名), 本轮已放弃"; return 1
  fi
  mv -f "$tmp" "$DDNS_CONF"; chmod 644 "$DDNS_CONF" 2>/dev/null

  if (( changed > 0 )); then
    if ! commit; then err "规则未生效, 已回滚"; return 1; fi
    [[ $quiet ]] || info "本轮已同步 $(( changed - healed )) 个变更 / 补回 $healed 个"
    log "DDNS SYNC changed=$((changed-healed)) healed=$healed failed=$failed"
  else
    tx_done
  fi
  (( failed > 0 )) && [[ $quiet ]] && log "DDNS WARN $failed 个域名解析失败(保留旧IP)"
  return 0
}

ddns_cron_on(){
  install_self || return 1
  [[ -x $INSTALL_PATH ]] || { err "脚本未安装到 $INSTALL_PATH, 无法配置定时任务"; return 1; }
  # 从第 3 分钟起每 DDNS_MIN 分钟触发, 避开整点:
  # --auto 是 0 * * * *, 若 DDNS 也用 */10, 两者会在 :00 同秒抢锁,
  # 抢输的静默 exit 0 —— 输的若是 lastb 扫描, 这一小时就漏跑了
  local range
  if (( DDNS_MIN > 0 && DDNS_MIN < 60 )); then
    range="3-59/$DDNS_MIN"
  else
    range="3-59/10"; DDNS_MIN=10
  fi
  printf '%s * * * * root %s --ddns >/dev/null 2>&1\n' "$range" "$INSTALL_PATH" > "$DDNS_CRON"
  chmod 644 "$DDNS_CRON"
  if [[ -f $DDNS_CRON ]]; then
    info "已开启: 每 $DDNS_MIN 分钟自动检测一次 (分钟位 $range, 刻意错开整点的 lastb 任务)"
    log "DDNS CRON ON ($range)"
  else err "写入 $DDNS_CRON 失败"; fi
}

ddns_cron_off(){
  rm -f "$DDNS_CRON"
  info "已关闭自动检测 (已解析的 IP 会保留在白名单里)"
  log "DDNS CRON OFF"
}

ddns_view(){
  clear
  echo -e "${C}========== DDNS 动态域名白名单 ==========${N}"
  if [[ -f $DDNS_CRON ]]; then
    echo -e "  自动更新: ${G}已开启${N} (cron 每 ${DDNS_MIN} 分钟)"
  else
    echo -e "  自动更新: ${Y}未开启${N} (只会在手动检测时更新)"
  fi
  echo "  配置文件: $DDNS_CONF    白名单: $(count "$WL") 条"
  echo "--------------------------------------------"
  ddns_print_table
  echo ""
  local managed
  managed=$(awk -F'|' '$2 ~ /^[0-9]/ {print $2}' "$DDNS_CONF" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  echo "  DDNS 管理的 IP 共 ${managed:-0} 个 (删除域名/切换 IP 时只撤脚本自己写入的条目, 手工加的不动)"
  echo "--------------------------------------------"
  grep -i 'ddns' "$LOG" 2>/dev/null | tail -n 5 | sed 's/^/  /'
  pause
}

ddns_menu(){
  local ch
  while true; do
    clear
    echo -e "${C}========== DDNS 动态域名白名单 ==========${N}"
    if [[ -f $DDNS_CRON ]]; then
      echo -e "  自动更新: ${G}已开启${N} (cron 每 ${DDNS_MIN} 分钟)"
    else
      echo -e "  自动更新: ${Y}未开启${N}"
    fi
    echo "  已登记域名: $(count "$DDNS_CONF") 个"
    echo "--------------------------------------------"
    echo "  1. 查看域名与解析状态"
    echo "  2. 添加 DDNS 域名"
    echo "  3. 删除 DDNS 域名"
    echo "  4. 立即检测并更新"
    echo "  5. 开启自动检测 (每 ${DDNS_MIN} 分钟)"
    echo "  6. 关闭自动检测"
    echo "  0. 返回主菜单"
    read -rp "请选择: " ch || exit 0
    case $ch in
      1) ddns_view ;;
      2) ddns_add; pause ;;
      3) ddns_del; pause ;;
      4) echo ""; ddns_update; pause ;;
      5) ddns_cron_on; pause ;;
      6) ddns_cron_off; pause ;;
      0) return ;;
      "") return ;;
    esac
  done
}

# 10. SSH 登录方式 / 密钥管理
#   改 sshd 配置的顺序固定为: 备份 -> 注释冲突行 -> 写托管块 -> sshd -t 校验
#   -> 重载 -> 用 sshd -T 核对生效值。任一步失败立即回滚, 避免把人锁在门外。
# ---------------------------------------------------------------------
SSHD_CONFIG=/etc/ssh/sshd_config
SSH_BACKUP_DIR=/etc/ssh/ipblock-backup
SSH_BLOCK_BEGIN="# >>> ipblock managed >>>"
SSH_BLOCK_END="# <<< ipblock managed <<<"

ssh_bin(){ command -v sshd 2>/dev/null || echo /usr/sbin/sshd; }
ssh_t(){ "$(ssh_bin)" -t 2>&1; }
# 取 sshd 的"生效值"(不是配置文件里写的值), 这是唯一可信的判断依据
ssh_eff(){ "$(ssh_bin)" -T 2>/dev/null | awk -v k="$1" 'tolower($1)==tolower(k){print $2; exit}'; }
# 主配置 + 被 Include 的文件(sshd_config.d/*.conf 等)
ssh_conf_files(){
  printf '%s\n' "$SSHD_CONFIG"
  grep -hE '^[[:space:]]*Include[[:space:]]+' "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}' \
  | while IFS= read -r g; do
      for f in $g; do [[ -f $f ]] && printf '%s\n' "$f"; done
    done
}
ssh_user_home(){
  local h
  h=$(getent passwd "$1" 2>/dev/null | cut -d: -f6)
  [[ -z $h ]] && h=$(awk -F: -v u="$1" '$1==u{print $6}' /etc/passwd 2>/dev/null)
  printf '%s' "$h"
}
ssh_ak_file(){ local h; h=$(ssh_user_home "$1"); [[ -n $h ]] && printf '%s/.ssh/authorized_keys' "$h"; }
ssh_key_count(){ # user -> 有效公钥条数
  local f n=0
  f=$(ssh_ak_file "$1")
  [[ -f $f ]] && n=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null) && true
  printf '%s' "${n:-0}"
}

# 备份: 每个配置文件按序号复制到 /etc/ssh/ipblock-backup/<时间戳>/files/, 并记下原路径
# 用 cp 而不是 tar —— 不依赖归档工具的行为差异, 恢复就是逐个 cp 回去
ssh_backup(){
  local ts dir f i=0
  ts=$(date '+%Y%m%d-%H%M%S')
  dir=$SSH_BACKUP_DIR/$ts
  mkdir -p "$dir/files" 2>/dev/null || return 1
  chmod 700 "$SSH_BACKUP_DIR" "$dir" "$dir/files" 2>/dev/null
  : > "$dir/manifest"
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    i=$((i+1))
    if ! cp -p "$f" "$dir/files/$i" 2>/dev/null; then
      warn "备份 $f 失败, 已中止"
      rm -rf "$dir"
      return 1
    fi
    printf '%s|%s\n' "$i" "$f" >> "$dir/manifest"
  done < <(ssh_conf_files)
  if (( i == 0 )); then rm -rf "$dir"; return 1; fi
  SSH_LAST_BACKUP=$dir
  # 只保留最近 10 份
  ls -1dt "$SSH_BACKUP_DIR"/* 2>/dev/null | tail -n +11 | while IFS= read -r d; do rm -rf "$d"; done
  return 0
}
ssh_rollback(){
  [[ -n ${SSH_LAST_BACKUP:-} && -d $SSH_LAST_BACKUP ]] || { err "没有可回滚的备份"; return 1; }
  local i p
  while IFS='|' read -r i p; do
    [[ -z $i || -z $p ]] && continue
    [[ -f $SSH_LAST_BACKUP/files/$i ]] || continue
    if ! cp -p "$SSH_LAST_BACKUP/files/$i" "$p" 2>/dev/null; then
      err "恢复 $p 失败, 请手动从 $SSH_LAST_BACKUP/files/$i 复制回去"
      return 1
    fi
  done < "$SSH_LAST_BACKUP/manifest"
  ssh_reload >/dev/null 2>&1
  warn "已回滚到备份 $(basename "$SSH_LAST_BACKUP")"
  return 0
}
# 注释掉所有配置文件里的某指令(已注释的跳过), 这样后写的托管块才是"第一条匹配"
ssh_comment_key(){
  local k=$1 f
  while IFS= read -r f; do
    [[ -f $f ]] || continue
    sed -E "s/^([[:space:]]*)${k}([[:space:]=]+)(.*)$/# \1${k}\2\3/I" "$f" > "$f.ipbtmp" 2>/dev/null || { rm -f "$f.ipbtmp"; continue; }
    if cmp -s "$f" "$f.ipbtmp"; then rm -f "$f.ipbtmp"; continue; fi
    cat "$f.ipbtmp" > "$f" 2>/dev/null   # 保留原 inode 与权限
    rm -f "$f.ipbtmp"
  done < <(ssh_conf_files)
}
# 重写托管块(放在文件末尾; 冲突行已注释, 所以它是第一条匹配)
ssh_set_block(){
  local f=$SSHD_CONFIG
  awk -v a="$SSH_BLOCK_BEGIN" -v b="$SSH_BLOCK_END" \
      '$0==a{s=1;next} $0==b{s=0;next} !s{print}' "$f" > "$f.ipbtmp" 2>/dev/null || return 1
  cat "$f.ipbtmp" > "$f" 2>/dev/null
  rm -f "$f.ipbtmp"
  { printf '%s\n' "$SSH_BLOCK_BEGIN"; printf '%s\n' "$@"; printf '%s\n' "$SSH_BLOCK_END"; } >> "$f"
}
ssh_reload(){
  local u pid
  if command -v systemctl >/dev/null 2>&1; then
    for u in ssh sshd; do
      if systemctl is-active --quiet "$u" 2>/dev/null; then
        systemctl reload "$u" >/dev/null 2>&1 || systemctl restart "$u" >/dev/null 2>&1
        return $?
      fi
    done
  fi
  if command -v service >/dev/null 2>&1; then
    service ssh reload >/dev/null 2>&1 || service sshd reload >/dev/null 2>&1
  fi
  pid=$(cat /run/sshd.pid 2>/dev/null || cat /var/run/sshd.pid 2>/dev/null)
  [[ -n $pid ]] && kill -HUP "$pid" 2>/dev/null
  return 0
}
ssh_restart(){
  local u
  if command -v systemctl >/dev/null 2>&1; then
    for u in ssh sshd; do systemctl is-active --quiet "$u" 2>/dev/null && { systemctl restart "$u" >/dev/null 2>&1; return $?; }; done
  fi
  service ssh restart >/dev/null 2>&1 || service sshd restart >/dev/null 2>&1
  return 0
}
# 应用一组指令: ssh_apply "描述" Key Value [Key Value ...]
ssh_apply(){
  local desc=$1; shift
  local -a ks=() vs=() lines=()
  local i got rc
  [[ -f $SSHD_CONFIG ]] || { err "找不到 $SSHD_CONFIG"; return 1; }
  [[ -x $(ssh_bin) ]]   || { err "找不到 sshd 可执行文件"; return 1; }
  while (( $# >= 2 )); do ks+=("$1"); vs+=("$2"); shift 2; done
  (( ${#ks[@]} )) || { err "没有要修改的项"; return 1; }

  ssh_backup || { err "备份失败, 已中止(不改配置)"; return 1; }
  for ((i=0;i<${#ks[@]};i++)); do ssh_comment_key "${ks[i]}"; done
  for ((i=0;i<${#ks[@]};i++)); do lines+=("${ks[i]} ${vs[i]}"); done
  ssh_set_block "${lines[@]}" || { err "写入 $SSHD_CONFIG 失败"; ssh_rollback; return 1; }

  if ! rc=$(ssh_t); then
    err "sshd 语法检查失败, 已回滚:"
    printf '%s\n' "${rc:-}" | sed 's/^/    /'
    ssh_rollback
    return 1
  fi
  if (( SSH_NEED_RESTART )); then ssh_restart || { err "重启 sshd 失败"; ssh_rollback; return 1; }
  else ssh_reload || { err "重载 sshd 失败"; ssh_rollback; return 1; }
  fi
  # 核对真正生效的值: 有别的 drop-in 抢先匹配时这里会露馅
  for ((i=0;i<${#ks[@]};i++)); do
    got=$(ssh_eff "${ks[i]}")
    if [[ ${got:-} != "${vs[i]}" ]]; then
      err "生效值与预期不符: ${ks[i]} = ${got:-空}, 期望 ${vs[i]} (可能有其它配置优先生效)"
      ssh_rollback
      return 1
    fi
  done
  local summary=""
  for ((i=0;i<${#ks[@]};i++)); do summary+="${ks[i]}=${vs[i]} "; done
  info "$desc 已生效"
  log "SSH $desc ($summary)"
  return 0
}

# ---- 查看 ----
ssh_auth_desc(){
  local pw pk
  pw=$(ssh_eff passwordauthentication); pk=$(ssh_eff pubkeyauthentication)
  if [[ $pw == yes && $pk == yes ]]; then echo "密钥 + 密码 (都可以登录)"
  elif [[ $pw == yes ]]; then echo "${Y}仅密码${N}"
  elif [[ $pk == yes ]]; then echo "${G}仅密钥${N}"
  else echo "${R}两者都关闭(会无法登录, 除非已用密钥且 PubkeyAuthentication 未关)${N}"; fi
}
ssh_root_desc(){
  case $(ssh_eff permitrootlogin) in
    yes) echo "${Y}允许 root 用密码或密钥${N}" ;;
    prohibit-password|without-password) echo "只允许 root 用密钥" ;;
    no) echo "${G}禁止 root 登录${N}" ;;
    forced-commands-only) echo "仅允许 root 执行预置命令" ;;
    *) echo "未知" ;;
  esac
}
ssh_status(){
  local port u ak perms lb
  port=$(ssh_eff port); u=root; ak=$(ssh_ak_file "$u")
  echo -e "${C}========== SSH 登录方式 ==========${N}"
  echo "  配置文件      : $SSHD_CONFIG"
  [[ -f $SSHD_CONFIG ]] || { err "配置文件不存在"; return 1; }
  echo "  监听端口      : ${port:-未知}"
  echo "  登录方式      : $(ssh_auth_desc)"
  echo "  密码登录      : $( [[ $(ssh_eff passwordauthentication) == yes ]] && echo 开启 || echo 关闭 )"
  echo "  密钥登录      : $( [[ $(ssh_eff pubkeyauthentication) == yes ]] && echo 开启 || echo 关闭 )"
  echo "  root 登录     : $(ssh_root_desc)"
  echo "  当前 SSH IP   : ${SSH_IP:-未知}"
  echo "  空密码登录    : $( [[ $(ssh_eff permitemptypasswords) == yes ]] && echo "${R}允许(危险)${N}" || echo 禁止 )"
  echo "  root 已授权密钥: $(ssh_key_count root) 个"
  if [[ -f $ak ]]; then
    perms=$(stat -c '%a' "$ak" 2>/dev/null || stat -f '%Lp' "$ak" 2>/dev/null)
    echo "  authorized_keys: $ak ($perms)"
    [[ ${perms:-600} != 600 ]] && warn "权限应为 600, 当前 $perms (过宽时 sshd 可能拒绝使用该文件)"
    local d; d=$(dirname "$ak"); perms=$(stat -c '%a' "$d" 2>/dev/null || stat -f '%Lp' "$d" 2>/dev/null)
    [[ ${perms:-700} != 700 ]] && warn "$d 权限应为 700, 当前 $perms"
  else
    echo "  authorized_keys: 不存在(还没配密钥)"
  fi
  local lb; lb=$(ls -1dt "$SSH_BACKUP_DIR"/* 2>/dev/null | head -1)
  echo "  最近备份      : ${lb:-无}"
  echo "--------------------------------------------"
}

# ---- 密钥 ----
ssh_key_valid(){
  [[ $1 =~ ^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+AAAA[0-9A-Za-z+/]+={0,2}([[:space:]].*)?$ ]]
}
ssh_add_key(){ # user keyline -> 0=新增 2=已存在 1=失败
  local u=$1 k=$2 h f blob g
  h=$(ssh_user_home "$u"); [[ -n $h ]] || { err "用户 $u 不存在"; return 1; }
  f=$h/.ssh/authorized_keys
  mkdir -p "$h/.ssh" || return 1
  chmod 700 "$h/.ssh"; touch "$f"; chmod 600 "$f"
  blob=$(printf '%s' "$k" | awk '{print $2}')
  if awk -v b="$blob" '$2==b{f=1} END{exit !f}' "$f"; then
    info "该密钥已存在, 跳过"; return 2
  fi
  printf '%s\n' "$k" >> "$f"
  g=$(id -gn "$u" 2>/dev/null)
  chown -R "$u":"${g:-$u}" "$h/.ssh" 2>/dev/null
  log "SSH ADDKEY $u $(printf '%s' "$k" | awk '{print $1}')"
  return 0
}
ssh_gen_key(){ # user -> 打印私钥路径
  local u=$1 h dir k
  h=$(ssh_user_home "$u"); dir=$h/.ssh
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  k=$dir/id_ed25519_$(date '+%Y%m%d_%H%M%S')
  if ! ssh-keygen -t ed25519 -a 100 -N '' -f "$k" -C "ipblock@$(hostname)-$(date '+%Y%m%d')" >/dev/null 2>&1; then
    err "ssh-keygen 生成失败"; return 1
  fi
  chmod 600 "$k"; chmod 644 "$k.pub"
  ssh_add_key "$u" "$(cat "$k.pub")" >/dev/null
  printf '%s' "$k"
}
ssh_install_key(){
  local u ans ch line n=0 bad=0 k
  echo -e "${C}========== 安装密钥登录 ==========${N}"
  read -rp "为哪个用户配置? [root]: " u || exit 0
  u=${u:-root}
  [[ -n $(ssh_user_home "$u") ]] || { err "用户 $u 不存在"; return 1; }
  echo "  1. 粘贴已有的公钥 (推荐)"
  echo "  2. 从文件导入公钥"
  echo "  3. 直接生成一对新密钥 (私钥会显示出来, 自己保存)"
  read -rp "请选择 [1]: " ch || exit 0
  ch=${ch:-1}
  case $ch in
    2)
      read -rp "公钥文件路径: " k || exit 0
      [[ -r $k ]] || { err "读不到 $k"; return 1; }
      if grep -q 'PRIVATE KEY' "$k" 2>/dev/null; then err "这是私钥, 需要的是 .pub 公钥"; return 1; fi
      line=$(head -n 1 "$k" | tr -d '\r')
      if ssh_key_valid "$line"; then ssh_add_key "$u" "$line" && info "已导入公钥"
      else err "文件内容不是合法公钥"; return 1; fi
      ;;
    3)
      echo "  正在生成 ed25519 密钥 ..."
      k=$(ssh_gen_key "$u") || return 1
      info "已生成并写入授权: $k"
      echo ""
      echo -e "${Y}================= 私钥(只显示这一次, 请立即复制保存) =================${N}"
      cat "$k"
      echo -e "${Y}=====================================================================${N}"
      echo ""
      echo "  私钥文件: $k   (权限 600, 建议保存到自己电脑后删除服务器上的副本)"
      echo "  下载:     scp root@<本机IP>:$k ./"
      echo "  客户端用法: ssh -i 该文件 $u@<本机IP>"
      k=""
      ;;
    *)
      echo "  支持格式: ssh-ed25519 / ssh-rsa / ecdsa-sha2-* / sk-*"
      echo "  每行一个公钥, 粘贴完按一次空行结束:"
      while IFS= read -r line; do
        line=$(printf '%s' "$line" | tr -d '\r' | sed -E 's/[[:space:]]+$//')
        [[ -z $line ]] && break
        if printf '%s' "$line" | grep -q 'PRIVATE KEY'; then
          err "第 $((n+1)) 行看起来是私钥, 已忽略(需要的是 .pub 公钥)"; bad=$((bad+1)); continue
        fi
        if ssh_key_valid "$line"; then
          ssh_add_key "$u" "$line" >/dev/null && { n=$((n+1)); info "已添加: $(printf '%s' "$line" | awk '{print $1" ... "substr($2,1,16)"..."}')"; }
        else
          err "第 $((n+1)) 行不是合法公钥, 已跳过"; bad=$((bad+1))
        fi
      done
      ;;
  esac
  if (( $(ssh_key_count "$u") == 0 )); then
    warn "用户 $u 目前仍没有任何授权密钥"
    return 1
  fi
  info "用户 $u 现有 $(ssh_key_count "$u") 个授权密钥"
  echo ""
  read -rp "现在就切换成「仅密钥登录」吗? (y/N): " ans || exit 0
  if [[ $ans == [yY] ]]; then
    info "先别关掉当前窗口 —— 另开一个终端确认密钥能登录, 再关这个"
    ssh_apply "仅密钥登录" PasswordAuthentication no PubkeyAuthentication yes
  fi
}

# ---- 切换 ----
ssh_switch_auth(){
  local ch
  echo -e "${C}========== 修改登录方式 ==========${N}"
  echo "  当前: $(ssh_auth_desc)"
  echo "  1. 仅密钥登录 (关闭密码, 更安全)"
  echo "  2. 仅密码登录 (关闭密钥)"
  echo "  3. 密钥 + 密码 (都允许)"
  echo "  0. 返回"
  read -rp "请选择: " ch || exit 0
  case $ch in
    1)
      if (( $(ssh_key_count root) == 0 )); then
        err "root 没有任何授权密钥, 关闭密码后可能无法登录"
        err "请先用菜单 2 安装密钥并另开终端验证"
        return 1
      fi
      warn "关闭密码登录后, 只有持私钥的人能连。请保持当前会话, 另开终端验证"
      read -rp "确认切换? (y/N): " ch || exit 0
      [[ $ch == [yY] ]] || return 0
      ssh_apply "仅密钥登录" PasswordAuthentication no PubkeyAuthentication yes
      ;;
    2) ssh_apply "仅密码登录" PasswordAuthentication yes PubkeyAuthentication no ;;
    3) ssh_apply "密钥+密码登录" PasswordAuthentication yes PubkeyAuthentication yes ;;
    0|"") return 0 ;;
    *) warn "无效选择" ;;
  esac
}
ssh_root_login(){
  local ch
  echo -e "${C}========== root 登录设置 ==========${N}"
  echo "  当前: $(ssh_root_desc)"
  echo "  1. 允许 root 用密码或密钥登录      (PermitRootLogin yes)"
  echo "  2. 只允许 root 用密钥登录          (PermitRootLogin prohibit-password, 推荐)"
  echo "  3. 禁止 root 直接登录              (PermitRootLogin no, 需有普通用户可 sudo)"
  echo "  0. 返回"
  read -rp "请选择: " ch || exit 0
  case $ch in
    1) ssh_apply "root 允许密码登录" PermitRootLogin yes ;;
    2) ssh_apply "root 仅密钥登录"   PermitRootLogin prohibit-password ;;
    3) warn "禁止 root 登录前, 确认已有普通用户且能 sudo, 否则会失去管理权限"
       read -rp "确认? (y/N): " ch || exit 0
       [[ $ch == [yY] ]] && ssh_apply "禁止 root 登录" PermitRootLogin no ;;
    0|"") return 0 ;;
  esac
}

# ---- 已授权密钥 ----
ssh_keys_menu(){
  local u ch idx i f fp
  echo -e "${C}========== 已授权密钥 ==========${N}"
  read -rp "查看哪个用户? [root]: " u || exit 0
  u=${u:-root}
  f=$(ssh_ak_file "$u")
  if [[ ! -s $f ]]; then warn "用户 $u 没有 authorized_keys ($f)"; return 0; fi
  _rundir || return 1
  local -a lines=()
  while IFS= read -r line; do lines+=("$line"); done < <(grep -E '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null)
  if (( ${#lines[@]} == 0 )); then warn "文件里没有有效公钥"; return 0; fi
  for ((i=0;i<${#lines[@]};i++)); do
    fp=$(printf '%s\n' "${lines[i]}" > "$RUNDIR/k.$i" && ssh-keygen -lf "$RUNDIR/k.$i" 2>/dev/null | awk '{print $1" "$2}')
    printf "  %-3s %-40s %s\n" "$((i+1))" "${fp:--}" "$(printf '%s' "${lines[i]}" | awk '{$1="";$2="";print}' | sed 's/^ *//')"
  done
  echo ""
  echo "  d. 删除某个密钥   0. 返回"
  read -rp "请选择: " ch || exit 0
  if [[ $ch == [dD] ]]; then
    read -rp "要删除第几个? " idx || exit 0
    [[ $idx =~ ^[0-9]+$ ]] && (( idx>=1 && idx<=${#lines[@]} )) || { warn "序号无效"; return 0; }
    ssh_backup >/dev/null
    local blob; blob=$(printf '%s' "${lines[idx-1]}" | awk '{print $2}')
    awk -v b="$blob" '$2!=b' "$f" > "$f.ipbtmp" && cat "$f.ipbtmp" > "$f" && rm -f "$f.ipbtmp"
    info "已删除第 $idx 个密钥"
    log "SSH DELKEY $u idx=$idx"
  fi
}

# ---- 端口 ----
ssh_change_port(){
  local p cur
  cur=$(ssh_eff port)
  echo -e "${C}========== 修改 SSH 端口 ==========${N}"
  echo "  当前端口: ${cur:-未知}"
  read -rp "新端口 (1-65535, 回车取消): " p || exit 0
  [[ -z $p ]] && return 0
  [[ $p =~ ^[0-9]+$ ]] && (( p>=1 && p<=65535 )) || { err "端口无效"; return 1; }
  (( p == cur )) && { info "端口没变"; return 0; }
  echo ""
  warn "改端口后记得放行: 云厂商安全组 / ufw / firewalld / 本脚本白名单"
  warn "ufw 示例: ufw allow $p/tcp   firewalld 示例: firewall-cmd --add-port=$p/tcp --permanent"
  warn "改完当前连接不会立刻断, 但重连要用新端口; 建议保留当前会话直到验证成功"
  read -rp "确认改成 $p ? (y/N): " _ans || exit 0
  [[ $_ans == [yY] ]] || return 0
  SSH_NEED_RESTART=1
  ssh_apply "SSH 端口改为 $p" Port "$p"
  SSH_NEED_RESTART=0
  info "验证: ssh -p $p root@<本机IP>"
}

# ---- 登录记录 ----
ssh_last_log(){
  echo -e "${C}========== 最近登录 ==========${N}"
  echo "  当前在线:"
  who 2>/dev/null | sed 's/^/    /' || echo "    (无)"
  echo ""
  echo "  成功登录 (最近 10 条):"
  last -i -n 10 2>/dev/null | sed 's/^/    /' || echo "    (无记录)"
  echo ""
  echo "  失败登录 (最近 10 条):"
  lastb -i -n 10 2>/dev/null | sed 's/^/    /' || echo "    (无记录)"
}

# ---- 备份 / 回滚 ----
ssh_backup_menu(){
  local ch i f
  local -a list=()
  while IFS= read -r f; do list+=("$f"); done < <(ls -1dt "$SSH_BACKUP_DIR"/* 2>/dev/null)
  echo -e "${C}========== sshd 配置备份 ==========${N}"
  if (( ${#list[@]} )); then
    for ((i=0;i<${#list[@]};i++)); do
      printf "  %-3s %s  (%s 个文件)\n" "$((i+1))" "$(basename "${list[i]}")" "$(count "${list[i]}/manifest")"
    done
  else
    echo "  (暂无备份)"
  fi
  echo "  b. 立即备份     r. 回滚到某个备份     0. 返回"
  read -rp "请选择: " ch || exit 0
  case $ch in
    b|B) ssh_backup && info "已备份: $SSH_LAST_BACKUP" ;;
    r|R)
      (( ${#list[@]} )) || { warn "没有备份可选"; return 0; }
      read -rp "回滚到第几个? " i || exit 0
      [[ $i =~ ^[0-9]+$ ]] && (( i>=1 && i<=${#list[@]} )) || { warn "序号无效"; return 0; }
      SSH_LAST_BACKUP=${list[i-1]}
      read -rp "确认回滚到 $(basename "$SSH_LAST_BACKUP")? (y/N): " ch || exit 0
      [[ $ch == [yY] ]] && ssh_rollback
      ;;
  esac
}

ssh_menu(){
  local ch pw pk port rl
  while true; do
    clear
    pw=$(ssh_eff passwordauthentication); pk=$(ssh_eff pubkeyauthentication); port=$(ssh_eff port)
    echo -e "${C}========== SSH 登录管理 ==========${N}"
    echo -e "  端口 ${port:-?} | 密码 $( [[ $pw == yes ]] && echo 开 || echo 关 ) | 密钥 $( [[ $pk == yes ]] && echo 开 || echo 关 ) | root: $(ssh_eff permitrootlogin)"
    echo "--------------------------------------------"
    echo "  1. 查看当前登录方式 (详情)"
    echo "  2. 安装密钥登录 (粘贴公钥 / 自动生成)"
    echo "  3. 切换登录方式 (仅密钥 / 仅密码 / 密钥+密码)"
    echo "  4. root 登录设置"
    echo "  5. 查看 / 删除已授权密钥"
    echo "  6. 修改 SSH 端口"
    echo "  7. 查看最近登录记录"
    echo "  8. 备份 / 回滚 sshd 配置"
    echo "  0. 返回主菜单"
    read -rp "请选择: " ch || exit 0
    case $ch in
      1) ssh_status; pause ;;
      2) ssh_install_key; pause ;;
      3) ssh_switch_auth; pause ;;
      4) ssh_root_login; pause ;;
      5) ssh_keys_menu; pause ;;
      6) ssh_change_port; pause ;;
      7) ssh_last_log; pause ;;
      8) ssh_backup_menu; pause ;;
      0|"") return ;;
      *) ;;
    esac
  done
}
# ---------------------------------------------------------------------
# 7. 开机自启 / 状态
# ---------------------------------------------------------------------
health_menu_line(){
  if [[ -f $HEALTH_CRON ]]; then
    echo -e "  规则自愈    : ${G}已开启 (每 ${HEALTH_MIN} 分钟)${N}"
  else
    echo -e "  规则自愈    : ${Y}未开启${N}"
  fi
}
health_cron_on(){
  install_self || return 1
  [[ -x $INSTALL_PATH ]] || { err "脚本未安装到 $INSTALL_PATH, 无法配置定时任务"; return 1; }
  # 1-59/5 刻意错开 :00 的 lastb 任务和 :03/:13 的 DDNS 任务
  local range="1-59/$HEALTH_MIN"
  printf '%s * * * * root %s --health >/dev/null 2>&1\n' "$range" "$INSTALL_PATH" > "$HEALTH_CRON"
  chmod 644 "$HEALTH_CRON"
  if [[ -f $HEALTH_CRON ]]; then
    info "已开启规则自愈: 每 $HEALTH_MIN 分钟检查一次规则是否还在(分钟位 $range)"
    log "HEALTH CRON ON ($range)"
  else err "写入 $HEALTH_CRON 失败"; fi
}
health_cron_off(){ rm -f "$HEALTH_CRON"; info "已关闭规则自愈"; log "HEALTH CRON OFF"; }

sys_menu(){
  local ch
  while true; do
    clear
    detect_stack
    echo -e "${C}========== 系统安装 / 状态 ==========${N}"
    echo "  后端        : $BACKEND${IPT_TABLE:+ (iptables $IPT_TABLE 表)}"
    is_applied && echo -e "  规则状态    : ${G}已加载${N}" || echo -e "  规则状态    : ${R}未加载${N}"
    echo "  共存环境    : $(stack_desc)"
    [[ -f $SERVICE_FILE ]] && echo -e "  开机恢复    : ${G}已安装${N}" || echo -e "  开机恢复    : ${Y}未安装${N}"
    [[ -f $CRON_FILE ]]    && echo -e "  自动封禁    : ${G}已开启${N}" || echo -e "  自动封禁    : ${Y}未开启${N}"
    [[ -f $DDNS_CRON ]]    && echo -e "  DDNS 同步   : ${G}已开启 (每 ${DDNS_MIN} 分钟)${N}" || echo -e "  DDNS 同步   : ${Y}未开启${N}"
    health_menu_line
    bt_detect
    (( BT_DETECTED )) && echo "  宝塔面板    : ${G}已安装${N} ($(bt_fw_backend))  面板端口 $(bt_panel_port || echo '?')"
    echo "  数据目录    : $DATA_DIR"
    echo "  日志        : $LOG"
    echo "  DDNS 配置   : $DDNS_CONF ($(count "$DDNS_CONF") 个域名)"
    echo "  当前 SSH IP : ${SSH_IP:-未知}"
    if (( FW_UFW || FW_BT )) && [[ $BACKEND == ipt && ${IPT_TABLE:-raw} == filter ]]; then
      echo -e "  ${R}警告: 当前回退到 filter 表, ufw/宝塔 reload 会清掉本链, 请务必开启规则自愈${N}"
    elif (( FW_UFW || FW_BT )); then
      echo -e "  ${Y}提示: ufw/宝塔 reload 不会碰到本脚本的表, 但 reset/重装会; 建议开启规则自愈${N}"
    fi
    echo "  1. 安装开机自动恢复规则 (systemd)"
    echo "  2. 卸载开机自动恢复"
    echo "  3. 立即重新加载规则"
    echo "  4. 把当前 SSH IP 加入白名单 (防锁死, 推荐先做)"
    echo "  5. 开启/关闭规则自愈 (每 ${HEALTH_MIN} 分钟检查, 防被 ufw/宝塔清掉)"
    echo "  6. 宝塔环境检查 (面板端口/防火墙后端/fail2ban)"
    echo "  0. 返回主菜单"
    read -rp "请选择: " ch || exit 0
    case $ch in
      1) install_self || { warn "脚本未安装成功, 已取消(否则服务会指向不存在的路径)"; pause; continue; }
         if ! command -v systemctl >/dev/null 2>&1; then warn "未检测到 systemd"; pause; continue; fi
         cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ipblockbt restore firewall block rules (BT panel edition)
# ufw.service 必须排在前面: ufw 启动时会 iptables-restore, 晚于本服务会覆盖规则
After=network.target nftables.service firewalld.service iptables.service ufw.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH --init

[Install]
WantedBy=multi-user.target
EOF
         systemctl daemon-reload
         # CentOS 7 的 systemd 219 不认 enable --now, 拆成两步最稳
         if systemctl enable ipblockbt.service >/dev/null 2>&1; then
           if systemctl start ipblockbt.service >/dev/null 2>&1; then
             info "已安装并启用 ipblockbt.service (本次已立即加载规则)"
           else
             warn "已设置开机自启, 但本次立即启动失败; 请检查 journalctl -u ipblockbt"
           fi
         else
           warn "systemctl enable 失败, 请手动执行 systemctl enable --now ipblockbt"
         fi
         pause ;;
      2) systemctl disable ipblockbt.service >/dev/null 2>&1; rm -f "$SERVICE_FILE"
         command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload
         info "已卸载"; pause ;;
      3) apply && info "规则已重新加载" || err "加载失败"; pause ;;
      4) if [[ -z $SSH_IP ]]; then warn "无法识别当前 SSH IP (可能不是通过 SSH 登录)"; pause; continue; fi
         snapshot
         grep -qxF -- "$SSH_IP" "$WL" || echo "$SSH_IP" >> "$WL"
         grep -qxF -- "$SSH_IP" "$BL" && del_line "$BL" "$SSH_IP"
         commit && info "已加入白名单: $SSH_IP" || warn "未生效, 已回滚"
         pause ;;
      5) if [[ -f $HEALTH_CRON ]]; then health_cron_off; else health_cron_on; fi; pause ;;
      6) clear; echo -e "${C}========== 宝塔环境检查 ==========${N}"; bt_status; pause ;;
      0) return ;;
      "") return ;;
    esac
  done
}

# ---------------------------------------------------------------------
# 8. 检查系统原有防火墙规则, 导入合并统一管理
#    只读扫描: 不会修改 / 删除任何原有规则, 只把"源 IP"抄进本脚本的名单
# ---------------------------------------------------------------------
_emit_rule(){ # act(1=封禁 0=放行) addr source
  local out=$SCAN_ALW
  [[ $1 == 1 ]] && out=$SCAN_BAN
  printf '%s|%s\n' "$2" "$3" >> "$out"
}

nft_find_set(){ # set 名 -> "family table"
  nft list sets 2>/dev/null | awk -v want="$1" '
    /^table[ \t]/ { fam=$2; tbl=$3; sub(/[ \t]*\{.*/, "", tbl) }
    $1=="set" && $2==want { print fam, tbl; exit }
  '
}

nft_set_members(){ # family table name -> 每个元素一行
  nft list set "$1" "$2" "$3" 2>/dev/null | awk '
    /elements[ \t]*=[ \t]*\{/ { f=1; sub(/.*elements[ \t]*=[ \t]*\{/, "") }
    f { print; if ($0 ~ /\}/) f=0 }
  ' | tr -d '{}' | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'
}

scan_nft(){
  command -v nft >/dev/null 2>&1 || return 0
  local parsed kind addr pair fam tbl m act
  # 白名单式解析: 只认 "[ip|ip6] saddr <地址|@集合|{...}> [counter ...] <drop|reject|accept>"
  # 其余(iifname 限定、tcp/udp 端口、meta/ct、limit、daddr、!= 取反 ...)一律当"带附加条件"
  parsed=$(nft list ruleset 2>/dev/null | awk '
    function ok_tail(t) {
      return t ~ /^[ \t]*(counter([ \t]+packets[ \t]+[0-9]+[ \t]+bytes[ \t]+[0-9]+)?[ \t]+)?(drop|reject|accept)[ \t]*$/
    }
    function act_of(t) { return (t ~ /drop|reject/) ? "BAN" : "ALLOW" }
    {
      line=$0
      sub(/^[ \t]+/,"",line); sub(/[ \t]+$/,"",line)
      if (line ~ /^#/) next
      if (line ~ /^table inet ipblockbt \{/) { skip=1; next }        # 跳过本脚本自己的表
      if (skip) { if (line ~ /^\}/) skip=0; next }
      if (line !~ /saddr/) next
      if (line !~ /^(ip|ip6)?[ \t]*saddr[ \t]/) { print "COND|-"; next }
      rest=line
      sub(/^(ip|ip6)?[ \t]*saddr[ \t]+/,"",rest)
      if (substr(rest,1,2)=="!=") { print "COND|-"; next }          # saddr != x 是排除语义
      if (substr(rest,1,1)=="@") {
        split(rest,aa,/[ \t]+/); addr=aa[1]; tail=substr(rest,length(addr)+1)
        if (!ok_tail(tail)) { print "COND|-"; next }
        print act_of(tail) "SET|" substr(addr,2)
      } else if (substr(rest,1,1)=="{") {
        c=index(rest,"}")
        if (c==0) { print "COND|-"; next }
        inner=substr(rest,2,c-2); tail=substr(rest,c+1)
        if (!ok_tail(tail)) { print "COND|-"; next }
        gsub(/,/," ",inner); gsub(/[ \t]+/," ",inner)
        n=split(inner,b," "); act=act_of(tail)
        for(i=1;i<=n;i++) if(b[i]!="") print act "|" b[i]
      } else {
        split(rest,aa,/[ \t]+/); addr=aa[1]; tail=substr(rest,length(addr)+1)
        if (!ok_tail(tail)) { print "COND|-"; next }
        print act_of(tail) "|" addr
      }
    }')
  [[ -z $parsed ]] && return 0
  while IFS='|' read -r kind addr; do
    [[ -z $kind ]] && continue
    act=0; [[ $kind == BAN* ]] && act=1
    case $kind in
      COND) COND_SKIP=$((COND_SKIP+1)) ;;
      BAN|ALLOW)
        [[ -n $addr ]] && _emit_rule "$act" "$addr" "nft" ;;
      BANSET|ALLOWSET)
        pair=$(nft_find_set "$addr")
        [[ -z $pair ]] && continue
        fam=${pair%% *}; tbl=${pair#* }
        while IFS= read -r m; do
          [[ -n $m ]] && _emit_rule "$act" "$m" "nft-set($addr)"
        done < <(nft_set_members "$fam" "$tbl" "$addr") ;;
    esac
  done < <(printf '%s\n' "$parsed")
}

ipset_members(){ ipset save "$1" 2>/dev/null | awk '$1=="add"{print $3}'; }

scan_iptables(){
  local cmd line tgt a name m
  # 白名单式: 只认两种最朴素的形式, 其他一律跳过。
  # 列举"不该有的条件"是列不完的(-m conntrack/state/limit/recent/connlimit/mac/time...),
  # 只要漏一个就会把"仅某条件下的放行"升级成"整个 IP 放行/封禁"。
  local re_s='^-A[[:space:]]+[^[:space:]]+[[:space:]]+-s[[:space:]]+([^[:space:]]+)[[:space:]]+-j[[:space:]]+(DROP|ACCEPT|REJECT)([[:space:]]+--reject-with[[:space:]]+[^[:space:]]+)?[[:space:]]*$'
  local re_m='^-A[[:space:]]+[^[:space:]]+[[:space:]]+-m[[:space:]]+set[[:space:]]+--match-set[[:space:]]+([^[:space:]]+)[[:space:]]+src[[:space:]]+-j[[:space:]]+(DROP|ACCEPT|REJECT)([[:space:]]+--reject-with[[:space:]]+[^[:space:]]+)?[[:space:]]*$'
  for cmd in iptables-save ip6tables-save; do
    command -v "$cmd" >/dev/null 2>&1 || continue
    while IFS= read -r line; do
      case $line in
        "-A "*) ;;
        *) continue ;;
      esac
      # 跳过本脚本自己的链与 set
      case $line in
        *"-j IPBBT"*|*"ipbbt_bl"*|*"ipbbt_wl"*) continue ;;
      esac
      [[ $line == *"f2b-"* ]] && : > "$WORK/seen_f2b"
      if [[ $line =~ $re_s ]]; then
        a=${BASH_REMATCH[1]}; tgt=${BASH_REMATCH[2]}
        case $a in 0.0.0.0/0|::/0|0/0) continue ;; esac
        if [[ $tgt == ACCEPT ]]; then _emit_rule 0 "$a" "${cmd%-save}"
        else _emit_rule 1 "$a" "${cmd%-save}"; fi
        continue
      fi
      if [[ $line =~ $re_m ]]; then
        name=${BASH_REMATCH[1]}; tgt=${BASH_REMATCH[2]}
        [[ $name == ipbbt_* ]] && continue
        [[ $name == f2b-* ]] && : > "$WORK/seen_f2b"
        while IFS= read -r m; do
          [[ -z $m ]] && continue
          if [[ $tgt == ACCEPT ]]; then _emit_rule 0 "$m" "ipset($name)"
          else _emit_rule 1 "$m" "ipset($name)"; fi
        done < <(ipset_members "$name")
        continue
      fi
      # 走到这里的: 确实按源地址匹配, 但带了附加条件
      case $line in
        *"-s "*|*"--match-set"*)
          case $line in
            *"-j DROP"*|*"-j REJECT"*|*"-j ACCEPT"*) COND_SKIP=$((COND_SKIP+1)) ;;
          esac ;;
      esac
    done < <("$cmd" 2>/dev/null)
  done
}

scan_firewalld(){
  command -v firewall-cmd >/dev/null 2>&1 || return 0
  firewall-cmd --state >/dev/null 2>&1 || return 0
  local line act
  while IFS= read -r line; do
    [[ $line == *"source address="* ]] || continue
    case $line in
      *drop*|*reject*) act=1 ;;
      *accept*)        act=0 ;;
      *) continue ;;
    esac
    # 带端口/协议/服务的 rich rule 同样不能当整 IP 处理
    if [[ $line == *port* || $line == *protocol=* || $line == *service* ]]; then
      COND_SKIP=$((COND_SKIP+1)); continue
    fi
    if [[ $line =~ source[[:space:]]+address=\"([^\"]+)\" ]]; then
      _emit_rule "$act" "${BASH_REMATCH[1]}" "firewalld"
    fi
  done < <(firewall-cmd --list-all-zones 2>/dev/null)
  firewall-cmd --get-ipsets 2>/dev/null | grep . > "$WORK/seen_fw_ipset"
}

scan_ufw(){
  command -v ufw >/dev/null 2>&1 || return 0
  # 端口相关的 deny 形如 "22/tcp  DENY  1.2.3.4", 首字段带端口的一律跳过
  while IFS= read -r a; do
    if [[ $a == "COND" ]]; then COND_SKIP=$((COND_SKIP+1)); continue; fi
    [[ -n $a ]] && _emit_rule 1 "$a" "ufw"
  done < <(ufw status 2>/dev/null | awk '/DENY/ { if ($1 ~ /^[0-9]/) { print "COND"; next } print $NF }')
}

dedup_scan(){
  local f=$1 t
  [[ -s $f ]] || return 0
  t=$(mktemp) || return 1
  awk -F'|' '!seen[$1]++' "$f" > "$t" && mv -f "$t" "$f"
}

scan_rules(){
  _rundir || { err "创建临时目录失败"; return 1; }
  WORK=$RUNDIR/scan; mkdir -p "$WORK" 2>/dev/null
  SCAN_BAN=$WORK/ban.list; SCAN_ALW=$WORK/allow.list
  : > "$SCAN_BAN"; : > "$SCAN_ALW"
  COND_SKIP=0
  scan_nft
  scan_iptables
  scan_firewalld
  scan_ufw
  dedup_scan "$SCAN_BAN"; dedup_scan "$SCAN_ALW"
  return 0
}

# 统计某个扫描文件里"还值得导入"的条数(排除已存在/已被覆盖/被白名单保护)
count_importable(){ # file kind(ban|alw)
  local f=$1 kind=$2 n=0 a s e
  [[ -f $f ]] || { echo 0; return; }
  while IFS='|' read -r a s; do
    [[ -z $a ]] && continue
    normalize_entry "$a" || continue
    e=$NORM
    if [[ $kind == ban ]]; then
      grep -qxF -- "$e" "$BL" && continue
      in_list "$BL" "$e" && continue
      in_list "$WL" "$e" && continue
      range_risk "$e"; (( $? == 0 )) && continue
    else
      grep -qxF -- "$e" "$WL" && continue
      in_list "$WL" "$e" && continue
    fi
    n=$((n+1))
  done < "$f"
  echo "$n"
}

import_entries(){ # file kind(ban|alw)
  local f=$1 kind=$2 a s e rk n=0 dup=0 cov=0 prot=0 bad=0 moved=0 sshskip=0 wide=0
  [[ -s $f ]] || { warn "没有可导入的条目"; return 1; }
  snapshot
  while IFS='|' read -r a s; do
    [[ -z $a ]] && continue
    if ! normalize_entry "$a"; then bad=$((bad+1)); continue; fi
    e=$NORM
    if [[ $kind == ban ]]; then
      if grep -qxF -- "$e" "$BL"; then dup=$((dup+1)); continue; fi
      if in_list "$BL" "$e";    then cov=$((cov+1)); continue; fi
      if in_list "$WL" "$e";    then prot=$((prot+1)); continue; fi
      # 会封到你自己的 SSH IP 的规则一律拦下, 防止导入即锁死
      if [[ -n $SSH_IP ]] && ip_match "$e" "$SSH_IP"; then sshskip=$((sshskip+1)); continue; fi
      # 原规则里的 0.0.0.0/0、回环等危险条目不要带进来
      range_risk "$e"; rk=$?
      if (( rk == 0 )); then bad=$((bad+1)); log "IMPORT-SKIP danger $e ($s)"; continue; fi
      if (( rk == 1 )); then wide=$((wide+1)); log "IMPORT-WIDE $e ($s)"; fi
      echo "$e" >> "$BL"; n=$((n+1))
    else
      # 白名单优先级最高, /0 会把整个黑名单废掉
      case $e in 0.0.0.0/0|::/0) bad=$((bad+1)); log "IMPORT-SKIP danger $e ($s)"; continue ;; esac
      if grep -qxF -- "$e" "$WL"; then dup=$((dup+1)); continue; fi
      if in_list "$WL" "$e";      then cov=$((cov+1)); continue; fi
      echo "$e" >> "$WL"; n=$((n+1))
      if grep -qxF -- "$e" "$BL"; then del_line "$BL" "$e"; moved=$((moved+1)); fi
    fi
  done < "$f"
  if (( n > 0 )); then
    if ! commit; then err "导入未生效, 已回滚"; return 1; fi
  else
    tx_done
  fi
  if [[ $kind == ban ]]; then
    info "导入封禁 $n 条 (已存在 $dup, 已被现有网段覆盖 $cov, 受白名单保护 $prot, 无效 $bad)"
    (( sshskip > 0 )) && warn "已跳过 $sshskip 条会封禁你当前 SSH IP ($SSH_IP) 的规则, 需要的话请手动处理"
    (( wide > 0 ))    && warn "其中 $wide 条范围过大(/8 或更宽), 已按原规则导入, 请自查是否误封"
    log "IMPORT blacklist +$n (exists=$dup covered=$cov whitelisted=$prot invalid=$bad ssh=$sshskip)"
  else
    info "导入白名单 $n 条 (已存在 $dup, 已被覆盖 $cov, 从黑名单移出 $moved, 无效 $bad)"
    log "IMPORT whitelist +$n (exists=$dup covered=$cov unbanned=$moved invalid=$bad)"
  fi
  (( n > 0 ))
}

show_scan(){ # file title
  local f=$1 title=$2 n
  n=$(wc -l < "$f" 2>/dev/null | tr -d ' '); n=${n:-0}
  clear
  echo -e "${C}========== $title (共 $n 条) ==========${N}"
  if (( n == 0 )); then
    echo "   (无)"; pause; return
  fi
  awk -F'|' '{ printf "  %-44s %s\n", $1, $2 }' "$f" | head -n 100
  (( n > 100 )) && echo "  ...... 仅显示前 100 条, 完整清单请用「导出」"
  echo "--------------------------------------------"
  pause
}

export_scan(){
  local out=$DATA_DIR/import-scan-$(date '+%Y%m%d-%H%M%S').txt
  {
    echo "# ipblockbt 扫描结果 $(date '+%F %T')"
    echo "# 格式: 条目|来源"
    echo "## 封禁/拒绝候选 ($(count "$SCAN_BAN") 条)"
    cat "$SCAN_BAN" 2>/dev/null
    echo "## 放行/接受候选 ($(count "$SCAN_ALW") 条)"
    cat "$SCAN_ALW" 2>/dev/null
  } > "$out" 2>/dev/null
  if [[ -s $out ]]; then info "已导出: $out"; else warn "导出失败"; fi
  log "EXPORT scan -> $out"
}

import_menu(){
  [[ -t 0 ]] || { err "该功能需要交互式终端"; return 1; }
  _rundir || { err "创建临时目录失败"; return 1; }
  WORK=$RUNDIR/scan; mkdir -p "$WORK" 2>/dev/null
  clear
  echo "正在扫描系统现有防火墙规则 (只读, 不会改动任何原有规则)..."
  echo "  nftables / iptables / ipset / firewalld / ufw 都会检查一遍"
  scan_rules
  local ch nb na ib ia srcs ans
  ib=$(count_importable "$SCAN_BAN" ban)
  ia=$(count_importable "$SCAN_ALW" alw)
  while true; do
    clear
    nb=$(wc -l < "$SCAN_BAN" 2>/dev/null | tr -d ' '); nb=${nb:-0}
    na=$(wc -l < "$SCAN_ALW" 2>/dev/null | tr -d ' '); na=${na:-0}
    srcs=$(cat "$SCAN_BAN" "$SCAN_ALW" 2>/dev/null | awk -F'|' '{print $2}' | sed 's/(.*//; s/:.*//; s/-save$//' | sort -u | tr '\n' ' ')
    echo -e "${C}========== 检查 / 导入现有防火墙规则 ==========${N}"
    echo "  扫描到: 封禁/拒绝候选 $nb 条 (可导入 $ib)   放行/接受候选 $na 条 (可导入 $ia)"
    echo "  来源  : ${srcs:-无}"
    echo "  现有  : 黑名单 $(count "$BL") 条   白名单 $(count "$WL") 条"
    [[ -f $WORK/seen_f2b ]] && echo -e "  ${Y}检测到 fail2ban 的 f2b-* 链/ipset, 导入后建议停用对应 jail, 避免两套规则重复管理${N}"
    [[ -s $WORK/seen_fw_ipset ]] && echo -e "  ${Y}检测到 firewalld ipset, 其成员未自动展开(无法判定 drop/accept 语义), 请自行确认${N}"
    detect_stack
    if (( FW_BT )); then
      echo -e "  ${Y}检测到宝塔面板: 其\"安全\"页规则由 ufw/firewalld 维护, 此处只是抄一份, 原规则不会删;${N}"
      echo -e "  ${Y}              若它开了 SSH 防爆破(fail2ban), 两边会各自封一遍, 建议留一套${N}"
    elif (( FW_UFW )); then
      echo -e "  ${Y}检测到 ufw 已启用: 导入的只是源 IP 副本, ufw 的端口规则仍独立生效${N}"
    fi
    (( COND_SKIP > 0 )) && echo -e "  ${Y}已跳过 $COND_SKIP 条带端口/协议/接口等附加条件的规则(导入会把\"开放某端口\"变成\"整个 IP 放行/封禁\")${N}"
    echo "--------------------------------------------"
    echo "  1. 导入「封禁/拒绝」候选 -> 黑名单   (推荐)"
    echo "  2. 导入「放行/接受」候选 -> 白名单   (慎用: 会被全局放行)"
    echo "  3. 两者都导入"
    echo "  4. 查看封禁候选清单"
    echo "  5. 查看放行候选清单"
    echo "  6. 导出完整清单到文件"
    echo "  7. 重新扫描"
    echo "  0. 返回主菜单"
    read -rp "请选择: " ch || { rm -rf "$WORK"; exit 0; }
    case $ch in
      1) import_entries "$SCAN_BAN" ban
         ib=$(count_importable "$SCAN_BAN" ban); pause ;;
      2) if (( ia == 0 )); then warn "没有可导入的放行条目"; else
           warn "放行条目会优先生效(白名单高于黑名单), 确认这些来源可信再导入"
           read -rp "继续? (y/N): " ans || { rm -rf "$WORK"; exit 0; }
           [[ $ans == [yY] ]] && import_entries "$SCAN_ALW" alw
           ia=$(count_importable "$SCAN_ALW" alw); ib=$(count_importable "$SCAN_BAN" ban)
         fi; pause ;;
      3) import_entries "$SCAN_BAN" ban; import_entries "$SCAN_ALW" alw
         ib=$(count_importable "$SCAN_BAN" ban); ia=$(count_importable "$SCAN_ALW" alw); pause ;;
      4) show_scan "$SCAN_BAN" "封禁/拒绝候选" ;;
      5) show_scan "$SCAN_ALW" "放行/接受候选" ;;
      6) export_scan; pause ;;
      7) clear; echo "重新扫描中..."; scan_rules
         ib=$(count_importable "$SCAN_BAN" ban); ia=$(count_importable "$SCAN_ALW" alw)
         info "扫描完成"; sleep 1 ;;
      0) break ;;
      "") break ;;
    esac
  done
  rm -rf "$WORK"; WORK=""
  return 0
}

# ---------------------------------------------------------------------
# --auto 的互斥锁
#   优先 flock; 没有 flock 时用 mkdir 的原子性降级
#   注意: 只有 mkdir 成功才把目录记到 LOCK_DIR_MADE, 否则抢锁失败退出时
#         EXIT trap 会把正在持锁那个进程的锁删掉, 互斥直接失效
# ---------------------------------------------------------------------
_auto_lock(){ # [最多等待秒数, 默认 0=不等待]
  local wait=${1:-0}
  (( _LOCK_HELD )) && return 0        # 同进程已持锁, 直接复用, 避免重复 exec 把自己锁在外面
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE" 2>/dev/null || return 0    # 锁文件都建不了就当无锁运行, 不能因此不封禁
    if (( wait > 0 )); then
      flock -w "$wait" 9 || return 1
    else
      flock -n 9 || return 1
    fi
    _LOCK_HELD=1; return 0
  fi
  local d="$LOCK_FILE.d" opid="" age
  if mkdir "$d" 2>/dev/null; then
    LOCK_DIR_MADE=$d; _LOCK_HELD=1; echo $$ > "$d/pid" 2>/dev/null; return 0
  fi
  # 已被占用: 看持锁进程是否还活着
  [[ -r $d/pid ]] && read -r opid < "$d/pid" 2>/dev/null
  if [[ -n $opid ]] && kill -0 "$opid" 2>/dev/null; then return 1; fi
  age=$(( $(date +%s) - $(_mtime "$d") ))
  # 刚建出来还没写 pid 的, 当成有人在用, 别抢
  if [[ -z $opid ]] && (( age < 60 )); then return 1; fi
  rm -rf "$d" 2>/dev/null
  if mkdir "$d" 2>/dev/null; then
    LOCK_DIR_MADE=$d; _LOCK_HELD=1; echo $$ > "$d/pid" 2>/dev/null; return 0
  fi
  return 1
}

# sudo 会清掉 SSH_CLIENT, 用 who -m 兜底。
# 结果必须过 normalize_entry: 本地 X 会话下 who 会给出 ":0" 这类串,
# 它能通过宽松字符检查, 却会把白名单写脏, 让下一次 apply 失败并回滚。
resolve_ssh_ip(){
  local ip
  if [[ -n $SSH_IP ]]; then
    if normalize_entry "$SSH_IP"; then SSH_IP=$NORM; else SSH_IP=""; fi
    return 0
  fi
  command -v who >/dev/null 2>&1 || return 0
  ip=$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' | head -n 1)
  ip=${ip#::ffff:}
  if [[ -n $ip ]] && normalize_entry "$ip"; then SSH_IP=$NORM; else SSH_IP=""; fi
  return 0
}

# ---------------------------------------------------------------------
# 主菜单 / 命令行入口
# ---------------------------------------------------------------------
main_menu(){
  local ch auto ddns
  [[ -t 0 ]] || { err "菜单需要交互式终端, 用 --init / --auto 走命令行模式"; exit 1; }
  while true; do
    clear
    [[ -f $CRON_FILE ]] && auto="${G}已开启${N}" || auto="${Y}未开启${N}"
    [[ -s $DDNS_CONF ]] && ddns="域名 $(count "$DDNS_CONF")" || ddns="未配置"
    echo -e "${C}============ IP 封禁管理 [$BACKEND] ============${N}"
    echo -e "  封禁: $(count "$BL") 条   白名单: $(count "$WL") 条   自动封禁: $auto"
    echo -e "  DDNS: $ddns"
    echo "--------------------------------------------"
    echo "  1. 输入封禁 IP / IP段"
    echo "  2. 查看封禁 IP"
    echo "  3. 读取 lastb 自动封禁 (失败 >= $THRESHOLD 次, 按段聚合)"
    echo "  4. 手动解封 IP / IP段"
    echo "  5. 设置 IP 白名单"
    echo "  6. 查看 IP 白名单"
    echo "  7. 开机自启 / 系统状态"
    echo "  8. 检查并导入系统现有防火墙规则 (统一管理)"
    echo "  9. DDNS 动态域名白名单 (域名 IP 变化自动同步)"
    echo "  10. SSH 登录方式 / 密钥管理"
    echo "  0. 退出"
    read -rp "请选择: " ch || exit 0
    case $ch in
      1) do_block; pause ;;
      2) manage_list "封禁 IP 列表" "$BL" "封禁IP" ;;
      3) auto_menu ;;
      4) do_unblock; pause ;;
      5) do_whitelist; pause ;;
      6) manage_list "IP 白名单" "$WL" "白名单IP" ;;
      7) sys_menu ;;
      8) import_menu ;;
      9) ddns_menu ;;
      10) ssh_menu ;;
      0) exit 0 ;;
      "") exit 0 ;;
    esac
  done
}

# raw 表可能不存在(OpenVZ/LXC 等容器), 这里定一次, apply 与 is_applied 共用
IPT_TABLE=""
[[ $BACKEND == ipt ]] && IPT_TABLE=$(ipt_pick_table)
resolve_ssh_ip

case ${1:-} in
  --init)
    sanitize_file "$BL"; sanitize_file "$WL"
    apply && { log "INIT 规则已加载 ($BACKEND)"; exit 0; } || exit 1 ;;
  --auto)
    _auto_lock 20 || { log "AUTO SKIP 20s 内未取得锁(另一个实例在跑), 本轮跳过"; exit 0; }
    sanitize_file "$BL"; sanitize_file "$WL"   # 手改过的文件里若有脏行, 会让 apply 整体失败
    is_applied || apply
    auto_scan quiet; exit 0 ;;
  --ddns)
    # 与 --auto 共用同一把锁: 两者都会读写 whitelist.txt
    _auto_lock 20 || { log "DDNS SKIP 20s 内未取得锁(另一个实例在跑), 本轮跳过"; exit 0; }
    sanitize_file "$WL"; sanitize_file "$BL"
    is_applied || apply
    ddns_update quiet; exit 0 ;;
  --health)
    # 只做一件事: 规则被别的防火墙/面板清掉了就重新加载
    _auto_lock 10 || exit 0
    health_check; exit $? ;;
  --scan)
    _rundir || exit 1
    scan_rules
    echo "=== 现有防火墙规则扫描结果 ($(date '+%F %T')) ==="
    echo "封禁/拒绝候选: $(count "$SCAN_BAN") 条 (可导入 $(count_importable "$SCAN_BAN" ban))"
    echo "放行/接受候选: $(count "$SCAN_ALW") 条 (可导入 $(count_importable "$SCAN_ALW" alw))"
    (( COND_SKIP > 0 )) && echo "已跳过 ${COND_SKIP} 条带端口/协议等附加条件的规则(不能当整 IP 处理)"
    echo "--- 封禁/拒绝 ---"
    awk -F'|' '{printf "%-44s %s\n", $1, $2}' "$SCAN_BAN" 2>/dev/null | head -n 100
    echo "--- 放行/接受 ---"
    awk -F'|' '{printf "%-44s %s\n", $1, $2}' "$SCAN_ALW" 2>/dev/null | head -n 100
    rm -rf "$WORK"; WORK=""
    exit 0 ;;
  -h|--help)
    echo "用法: $0            进入菜单"
    echo "      $0 --init     加载规则(开机恢复)"
    echo "      $0 --auto     执行一次 lastb 检测(供 cron 使用)"
    echo "      $0 --ddns     执行一次 DDNS 解析并同步白名单(供 cron 使用)"
    echo "      $0 --health   检查规则是否还在, 丢了就重载(供 cron 使用)"
    echo "      $0 --scan     只扫描现有防火墙规则并打印(不修改任何东西)"
    echo "  环境变量:"
    echo "    THRESHOLD=5          lastb 中出现 >= 该次数则自动封禁"
    echo "    BAN_WINDOW=-24hours  lastb 只统计最近这段时间内的失败(不支持 -s 的旧系统会退化为全量)"
    echo "    SKIP_SUCCESS=1       近期成功登录过/有活动连接的 IP 不自动封禁(防误封 NAT 出口)"
    echo "    DDNS_MIN=10          DDNS 自动检测间隔(分钟)"
    echo "    HEALTH_MIN=5         规则自愈检查间隔(分钟)"
    echo "    AGG_ENABLE=1         按段聚合开关(1=开, 0=只封单 IP)"
    echo "    AGG_C_MIN=3          同一 /24 内不同 IP 达到该值 -> 封整个 /24"
    echo "    AGG_NEIGHBOR=8       出现新 /24 时前后各扩多少个 /24(仅在同一 /16 内)"
    echo "    AGG_B_HARD=20        同一 /16 下要覆盖的 /24 超过该值 -> 直接封 /16"
    exit 0 ;;
esac

# 交互模式启动: 先清洗数据, 再补加载规则
sanitize_file "$BL"; sanitize_file "$WL"
is_applied || apply
detect_stack
bt_detect
if (( FW_UFW || FW_BT )); then
  if [[ $BACKEND == ipt && ${IPT_TABLE:-raw} == filter ]]; then
    warn "检测到 $(stack_desc): 当前回退到 filter 表, ufw/宝塔 reload 会清掉本链!"
    warn "  强烈建议到菜单 7 -> 5 开启规则自愈, 否则面板一保存规则你的封禁就失效"
  elif [[ ! -f $HEALTH_CRON ]]; then
    warn "检测到 $(stack_desc): 常见 reload 不会影响本脚本的表, 但 reset/重装面板会;"
    warn "  可到菜单 7 -> 5 开启规则自愈(每 ${HEALTH_MIN} 分钟自动检查恢复)"
  fi
fi
# 宝塔环境首次运行: 主动问一次要不要开自愈(只问一次, 之后不再打扰)
if (( BT_DETECTED )) && [[ ! -f $HEALTH_CRON && ! -f $DATA_DIR/.bt_asked ]]; then
  echo ""
  echo -e "${C}检测到宝塔面板${N}: 在面板「安全」页保存防火墙规则时, 会重建系统防火墙的表。"
  echo "  本脚本的规则放在独立位置(正常不会被清), 但面板重置/重装仍会清掉。"
  echo "  开启规则自愈后, 每 ${HEALTH_MIN} 分钟检查一次, 发现规则丢失会自动恢复。"
  read -rp "是否现在开启规则自愈? (Y/n): " _ans || exit 0
  [[ $_ans == [nN] ]] || health_cron_on
  : > "$DATA_DIR/.bt_asked" 2>/dev/null
  sleep 1
fi
if [[ -n $SSH_IP ]] && in_list "$BL" "$SSH_IP" && ! in_list "$WL" "$SSH_IP"; then
  warn "警告: 你当前的 SSH IP ($SSH_IP) 在封禁列表中! 请到菜单 7 -> 4 加入白名单后再操作"
fi
main_menu
