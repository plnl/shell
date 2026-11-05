#!/usr/bin/env bash
# ============================================================
# srvmenu —— 本机运维菜单（systemd + Docker + init.d 混管环境的统一入口）
#
# 目的：一眼看清「这台机器装了什么、哪些在跑、哪个不正常」，并做常用启停。
#
# 用法：
#   srvmenu                 交互菜单
#   srvmenu overview        直接输出某一节（可脚本化）
#        services | health | ports | top | containers | logs | backups | drift
#   srvmenu restart my-web            直接对某个 unit 操作（需 root）
#   srvmenu docker restart workbuddy2api
#   srvmenu nginx reload | check
#
# 环境约定（踩过的坑，写在这里防忘）：
#   · nginx 不归 systemd：master 由 /etc/init.d/nginx 起，`systemctl is-active nginx`
#     恒为 inactive（LSB 空壳）。判断在跑没跑一律看进程/端口，本脚本已内置。
#   · 改 nginx 只走 `nginx -t && nginx -s reload`，不 restart。
#   · 危险操作（停 docker / zerotier / postgres）需要手打 YES 确认。
# ============================================================
set -uo pipefail

VERSION="1.1.1"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-4}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'
  C_D=$'\033[2m'; C_0=$'\033[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_D=; C_0=
fi

# ── 服务登记表（通用示例）──────────────────────────────────────
# 这台机器真实的清单不写在这里，放 /etc/srvmenu.conf —— 由下面 source 读入并覆盖默认值。
# 这样升级（install.sh 直接覆盖 /usr/local/bin/srvmenu）不会冲掉本机配置。
#
# 格式：名称|说明|探测|风险|后果说明
#   探测： http:<URL>:<允许码，多码用 |>   port:<端口>   zt（ZeroTier 在线）  docker   none
#   风险： 留空=普通；DANGER / ADAPTER = 停之前必须手打 YES
UNITS=(
  "docker|容器引擎（所有容器的父进程）|docker|DANGER|停掉=下面所有容器一起停"
  "zerotier-one|ZeroTier 组网（没装可删掉这行）|zt|DANGER|停掉=内网访问立刻断开，可能连你也一起断"
  # ── 按需添加，格式同上 ────────────────────────────────────
  # "my-web|我的 Web 服务|http:http://127.0.0.1:8080/healthz:200|停掉=网站不可用"
  # "postgresql|本机数据库|port:5432|DANGER|停掉=业务直接报错"
)

# 容器登记表：名称|说明|风险|OPT（OPT=已停用/已卸载，缺失不算异常）
CONTAINERS=(
  # "myapp|我的应用容器（8080）||"
  # "old-app|已停用的旧容器||OPT"
)

# ── 本机配置覆盖 ──────────────────────────────────────────────
# 把机器相关的登记表写到 /etc/srvmenu.conf（里面直接写 UNITS=(...) / CONTAINERS=(...)）；
# 也可以用 SRVMENU_CONF=/path/to/conf 临时换一份配置。
SRVMENU_CONF="${SRVMENU_CONF:-/etc/srvmenu.conf}"
SRVMENU_CONF_SRC="内置示例"
if [[ -r "$SRVMENU_CONF" ]]; then
  # shellcheck disable=SC1090
  if source "$SRVMENU_CONF" 2>/dev/null; then
    SRVMENU_CONF_SRC="$SRVMENU_CONF"
  fi
fi

# 判断「未登记」时要忽略的系统自带 unit（比较前会去掉 .service 后缀）
IGNORE_UNIT_RE='^(systemd-|dbus|cron|ssh|apparmor|atd|exim4|e2scrub|fstrim|man-db|apt-daily|dpkg-db-backup|keyboard-setup|console-setup|ifupdown|qemu-guest-agent|networking|rsyslog|getty@|user@|serial-getty|polkit|modprobe|cgcr|blk-availability|user-runtime-dir|containerd|ufw|docker-)'

# ── 基础工具 ──────────────────────────────────────────────────
HOST="$(hostname -s 2>/dev/null || hostname)"
hr()   { printf '%s%s%s\n' "$C_D" "────────────────────────────────────────────────────────────" "$C_0"; }
head1(){ printf '\n%s▓ %s%s\n' "$C_B" "$1" "$C_0"; }
ok()   { printf '  %s[OK]%s %s\n' "$C_G" "$C_0" "$1"; }
warn() { printf '  %s[!!]%s %s\n' "$C_Y" "$C_0" "$1"; }
bad()  { printf '  %s[XX]%s %s\n' "$C_R" "$C_0" "$1"; }
dim()  { printf '  %s%s%s\n' "$C_D" "$1" "$C_0"; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

check_http() { # URL 允许码（形如 200 或 200|503）
  local url="$1" allow="$2" code
  code=$(curl -s -o /dev/null -m "$HTTP_TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null)
  [[ "|$allow|" == *"|$code|"* ]]
}
check_port() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }
zt_online()  { zerotier-cli info 2>/dev/null | grep -q ' ONLINE'; }
docker_ok()  { docker info >/dev/null 2>&1; }
unit_state()   { systemctl is-active "$1" 2>/dev/null || true; }
unit_enabled() { systemctl is-enabled "$1" 2>/dev/null || true; }

probe_desc() { # 把探测串翻译成人话
  local spec="$1" kind rest
  kind="${spec%%:*}"
  case "$kind" in
    http) rest="${spec#http:}"; printf '%s（期望 %s）' "${rest%:*}" "${rest##*:}" ;;
    port) printf 'TCP 端口 %s' "${spec#port:}" ;;
    zt)   printf 'ZeroTier 在线' ;;
    docker) printf 'docker 守护进程' ;;
    *)    printf '%s' "$spec" ;;
  esac
}

probe() { # 探测串 → 0 通过
  local spec="$1" kind rest url codes
  kind="${spec%%:*}"
  case "$kind" in
    http) rest="${spec#http:}"; url="${rest%:*}"; codes="${rest##*:}"; check_http "$url" "$codes" ;;
    port) check_port "${spec#port:}" ;;
    zt)   zt_online ;;
    docker) docker_ok ;;
    none|"") return 0 ;;
    *) return 0 ;;
  esac
}

container_state() { # 名称 → running/healthy/unhealthy/exited/无
  docker inspect -f '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null || echo "无"
}

nginx_running() { # 不用 systemctl，看进程
  pgrep -f 'nginx: master process' >/dev/null 2>&1
}

# ── 1. 运行概览 ───────────────────────────────────────────────
overview() {
  local load up mem_t mem_u mem_a sw_t sw_u dline
  load=$(awk '{printf "%s / %s / %s", $1, $2, $3}' /proc/loadavg)
  up=$(uptime -p 2>/dev/null | sed 's/^up //')
  read -r mem_t mem_u mem_a <<< "$(free -m | awk 'NR==2{print $2, $3, $7}')"
  read -r sw_t sw_u <<< "$(free -m | awk 'NR==3{print $2, $3}')"
  dline=$(df -hP / | awk 'NR==2{printf "%s 总 / %s 已用 / %s 可用 (%s)", $2, $3, $4, $5}')

  head1 "运行概览"
  printf '  主机    %s   运行 %s\n' "$HOST" "$up"
  printf '  负载    %s\n' "$load"
  printf '  内存    %sM 总 / %sM 已用 / %sM 可用   swap %sM 中已用 %sM\n' \
         "$mem_t" "$mem_u" "$mem_a" "$sw_t" "$sw_u"
  printf '  磁盘    /  %s\n' "$dline"
  local ztip wgip
  ztip=$(ip -4 -o addr show 2>/dev/null | awk '$2 ~ /^zt/ {print $4; exit}' | cut -d/ -f1)
  wgip=$(ip -4 -o addr show 2>/dev/null | awk '$2 ~ /^wg/ {print $4; exit}' | cut -d/ -f1)
  [[ -n "$ztip" ]] && printf '  入口    http://%s:7865   （ZeroTier，面板/网关）\n' "$ztip"
  [[ -n "$wgip" ]] && printf '          http://%s:7865   （WireGuard）\n' "$wgip"
  [[ -z "$ztip" && -z "$wgip" ]] && warn "没找到 zt/wg 网卡地址，远程入口需自行确认"
  [[ "$mem_a" -lt 300 ]] && warn "可用内存低于 300M，注意 OOM 风险"

  # 计数
  local u_run=0 u_all=${#UNITS[@]} c_run=0 c_all=0 row st
  for row in "${UNITS[@]}"; do
    st=$(unit_state "${row%%|*}")
    [[ "$st" == "active" ]] && u_run=$((u_run + 1))
  done
  if docker_ok; then
    local crow copt2
    for crow in "${CONTAINERS[@]}"; do
      IFS='|' read -r _ _ _ copt2 <<< "$crow"
      [[ "$copt2" == "OPT" ]] && continue
      c_all=$((c_all + 1))
      case "$(container_state "${crow%%|*}")" in
        running*) c_run=$((c_run + 1)) ;;
      esac
    done
  fi
  if nginx_running; then
    printf '  服务    systemd %s/%s 运行   容器 %s/%s 运行   nginx 运行中\n' "$u_run" "$u_all" "$c_run" "$c_all"
  else
    printf '  服务    systemd %s/%s 运行   容器 %s/%s 运行   nginx %s未运行%s\n' \
           "$u_run" "$u_all" "$c_run" "$c_all" "$C_R" "$C_0"
  fi

  # 异常汇总
  local n_bad=0 spec
  for row in "${UNITS[@]}"; do
    spec=$(printf '%s' "$row" | cut -d'|' -f3)
    if [[ "$(unit_state "${row%%|*}")" == "active" ]]; then
      probe "$spec" || n_bad=$((n_bad + 1))
    fi
  done
  if [[ $n_bad -eq 0 ]]; then
    ok "登记的服务全部通过探测"
  else
    warn "$n_bad 个服务在跑但探测不通过 —— 看「3) 健康检查」"
  fi

  local drift; drift=$(drift_count)
  if [[ "$drift" -gt 0 ]]; then
    warn "有 $drift 个未登记的服务/容器 —— 看「9) 未登记项」"
  fi
}

# ── 2. 服务清单 ───────────────────────────────────────────────
services() {
  head1 "systemd 服务"
  dim "登记表来源：$SRVMENU_CONF_SRC"
  printf '  %-5s %-9s %-22s %s\n' "STAT" "BOOT" "SERVICE" "说明"
  dim "STAT=RUN 运行 / STOP 停止 / FAIL 失败     BOOT=enabled 表示开机自启"
  local row n d spec risk st en mc mp
  for row in "${UNITS[@]}"; do
    IFS='|' read -r n d spec risk _ <<< "$row"
    st=$(unit_state "$n"); en=$(unit_enabled "$n")
    case "$st" in
      active) mc="$C_G"; mp="RUN" ;;
      failed) mc="$C_R"; mp="FAIL" ;;
      *)      mc="$C_D"; mp="STOP" ;;
    esac
    printf '  %s%-5s%s %-9s %-22s %s\n' "$mc" "$mp" "$C_0" "$en" "$n" "$d"
  done

  head1 "Docker 容器"
  printf '  %-5s %-22s %s\n' "STAT" "CONTAINER" "说明"
  dim "OK=健康 / UP=运行中 / BAD=不健康 / OFF=已停止 / GONE=容器不存在"
  local cname cdesc crisk cst mc mp
  for row in "${CONTAINERS[@]}"; do
    IFS='|' read -r cname cdesc crisk _ <<< "$row"
    cst=$(container_state "$cname")
    case "$cst" in
      running/healthy)   mc="$C_G"; mp="OK" ;;
      running)           mc="$C_G"; mp="UP" ;;
      running/unhealthy) mc="$C_Y"; mp="BAD" ;;
      exited|created)    mc="$C_D"; mp="OFF" ;;
      *)                 mc="$C_R"; mp="GONE" ;;
    esac
    printf '  %s%-5s%s %-22s %s\n' "$mc" "$mp" "$C_0" "$cname" "$cdesc"
  done
  local unreg; unreg=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -vxF -f <(printf '%s\n' "${CONTAINERS[@]}" | cut -d'|' -f1) || true)
  [[ -n "$unreg" ]] && dim "未登记的容器：$(echo "$unreg" | tr '\n' ' ')"

  head1 "非 systemd 托管（init.d / 面板）"
  local ngr="未运行"
  nginx_running && ngr="${C_G}运行中${C_0}（master + $(pgrep -c -f 'nginx: worker process') worker）"
  printf '  %-22s %s   %s\n' "nginx" "$ngr" "80/443/888/7865，改动只走 nginx -s reload"
  local mysql_st php_st
  mysql_st=$(ss -ltn 2>/dev/null | grep -q ':3306' && echo "在跑" || echo "未运行")
  php_st=$(pgrep -f 'php-fpm' >/dev/null 2>&1 && echo "在跑" || echo "未运行")
  printf '  %-22s %s   %s\n' "mysqld" "$mysql_st" "零业务库，已 stop+disable 是预期状态"
  printf '  %-22s %s   %s\n' "php-fpm-82" "$php_st" "宝塔面板的 PHP"
  printf '  %-22s %s   %s\n' "BT-Panel" "$([[ $(pgrep -c -f 'BT-Panel') -gt 0 ]] && echo 在跑 || echo 未运行)" "宝塔面板 31691"
}

# ── 3. 健康检查 ───────────────────────────────────────────────
health() {
  head1 "健康检查"
  local row n d spec risk st fails=0
  for row in "${UNITS[@]}"; do
    IFS='|' read -r n d spec risk _ <<< "$row"
    [[ "$spec" == "none" || -z "$spec" ]] && continue
    if [[ "$(unit_state "$n")" != "active" ]]; then
      printf '  %s[--]%s   %-24s %s（服务未启动）\n' "$C_D" "$C_0" "$n" "$d"
      continue
    fi
    if probe "$spec"; then
      printf '  %s[OK]%s   %-24s %s\n' "$C_G" "$C_0" "$n" "$(probe_desc "$spec")"
    else
      printf '  %s[XX]%s   %-24s %s\n' "$C_R" "$C_0" "$n" "$(probe_desc "$spec")"
      fails=$((fails + 1))
    fi
  done

  # 容器健康
  local cname cdesc crisk copt cst
  for row in "${CONTAINERS[@]}"; do
    IFS='|' read -r cname cdesc crisk copt <<< "$row"
    cst=$(container_state "$cname")
    case "$cst" in
      running/healthy) printf '  %s[OK]%s   %-24s docker health=healthy\n' "$C_G" "$C_0" "$cname" ;;
      running)         printf '  %s[OK]%s   %-24s docker 运行中（无 healthcheck）\n' "$C_G" "$C_0" "$cname" ;;
      running/unhealthy) printf '  %s[XX]%s   %-24s docker health=unhealthy\n' "$C_R" "$C_0" "$cname"; fails=$((fails + 1)) ;;
      exited|created)  printf '  %s[--]%s   %-24s 已停止（%s）\n' "$C_D" "$C_0" "$cname" "$cst" ;;
      *)
        if [[ "$copt" == "OPT" ]]; then
          printf '  %s[--]%s   %-24s 已卸载（登记为可选，忽略）\n' "$C_D" "$C_0" "$cname"
        else
          printf '  %s[XX]%s   %-24s 容器不存在\n' "$C_R" "$C_0" "$cname"; fails=$((fails + 1))
        fi ;;
    esac
  done

  # 关键链路
  head1 "关键链路"
  if check_http "http://127.0.0.1:7865/api/healthz" "200"; then
    ok "面板对外入口 127.0.0.1:7865"
  else
    bad "面板对外入口 127.0.0.1:7865 不通"; fails=$((fails + 1))
  fi
  if check_http "http://127.0.0.1:7863/healthz" "200|503"; then
    ok "WorkBuddy 上游 7863（503 表示账号池为空，属正常）"
  else
    bad "WorkBuddy 上游 7863 不通"; fails=$((fails + 1))
  fi
  if curl -skf -o /dev/null -m "$HTTP_TIMEOUT" --resolve "www.bende.site:443:127.0.0.1" \
        "https://www.bende.site/" 2>/dev/null; then
    ok "博客 HTTPS（www.bende.site 回源本机 443）"
  else
    bad "博客 HTTPS 不通"; fails=$((fails + 1))
  fi
  if nginx -t >/dev/null 2>&1; then
    ok "nginx 配置语法"
  else
    bad "nginx 配置语法有错（nginx -t 看详情）"; fails=$((fails + 1))
  fi
  if zt_online; then
    local peers; peers=$(zerotier-cli listpeers 2>/dev/null | awk 'NR>1 && $NF=="LEAF"{c++} END{print c+0}')
    ok "ZeroTier 在线（直连/中继 peer ${peers} 个）"
  else
    warn "ZeroTier 未在线"
  fi
  local duse; duse=$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')
  if [[ "${duse:-0}" -ge 85 ]]; then
    bad "根分区已用 ${duse}%"; fails=$((fails + 1))
  else
    ok "根分区已用 ${duse}%"
  fi

  hr
  if [[ $fails -eq 0 ]]; then
    ok "全部通过"
  else
    bad "有 $fails 项异常"
  fi
}

# ── 4. 端口占用 ───────────────────────────────────────────────
ports() {
  head1 "监听端口 → 进程"
  printf '  %-22s %-20s %s\n' "ADDRESS" "PROCESS" "备注"
  local addr proc note
  while read -r addr proc; do
    [[ -z "$addr" ]] && continue
    note=""
    case "${addr##*:}" in
      80|443|888|7865) note="nginx" ;;
      7863) note="WorkBuddy 上游容器" ;;
      7864) note="WorkBuddy 面板" ;;
      8097) note="博客评论" ;;
      8098) note="博客统计" ;;
      8099) note="博客后台" ;;
      27288) note="SSH" ;;
      9993) note="ZeroTier" ;;
      31691) note="宝塔面板" ;;
      10086) note="wgdashboard（WireGuard 面板）" ;;
      8080|8999) note="plnl-server 容器" ;;
      3306) note="MySQL（已停用会消失）" ;;
      25) note="exim4" ;;
    esac
    printf '  %-22s %-20s %s\n' "$addr" "$proc" "$note"
  done < <(ss -ltnp 2>/dev/null | awk 'NR>1{
      addr=$4; proc="-";
      if ($6 ~ /^users:/) { p=$6; sub(/^users:\(\("/, "", p); sub(/".*/, "", p); proc=p }
      print addr, proc
    }' | sort -t: -k2 -n)

  echo
  dim "只看某个端口：ss -ltnp | grep :端口"
  dim "容器内进程：docker top <容器名>"
}

# ── 5. 资源 Top ───────────────────────────────────────────────
top_procs() {
  head1 "内存 Top 12"
  ps -eo rss,user,args --sort=-rss 2>/dev/null | head -13 | \
    awk 'NR==1{printf "  %-8s %-10s %s\n","RSS(MB)","用户","命令"}
         NR>1{printf "  %-8.0f %-10s %s\n", $1/1024, $2, substr($0, index($0,$3), 68)}'
  head1 "CPU Top 8（瞬时快照）"
  ps -eo pcpu,rss,args --sort=-pcpu 2>/dev/null | head -9 | \
    awk 'NR==1{printf "  %-6s %-8s %s\n","CPU%","RSS(MB)","命令"}
         NR>1{printf "  %-6s %-8.0f %s\n", $1, $2/1024, substr($0, index($0,$3), 60)}'
  head1 "按服务看（systemd cgroup）"
  if command -v systemd-cgtop >/dev/null 2>&1; then
    timeout 3 systemd-cgtop -bn1 --depth=1 2>/dev/null | head -12 | sed 's/^/  /'
  else
    dim "未安装 systemd-cgtop"
  fi
  head1 "容器资源"
  if docker_ok; then
    docker stats --no-stream --format '  {{.Name}}  CPU={{.CPUPerc}}  MEM={{.MemUsage}}' 2>/dev/null
  fi
}

# ── 6. 容器详情 ───────────────────────────────────────────────
containers() {
  head1 "容器详情"
  printf '  %-18s %-32s %-8s %s\n' "NAME" "STATUS" "RESTART" "PORTS"
  local line
  while IFS= read -r line; do printf '  %s\n' "$line"; done < <(
    docker ps -a --format '{{.Names}}|{{.Status}}|{{.Label "com.docker.compose.project"}}|{{.Ports}}' 2>/dev/null |
    awk -F'|' '{printf "%-18s %-32s %-8s %s\n", $1, substr($2,1,31), ($3==""?"-":"compose"), $4}')
  echo
  head1 "Docker 占用"
  docker system df 2>/dev/null | sed 's/^/  /'
  head1 "重启策略（开机能不能自己起来）"
  local cname
  for row in "${CONTAINERS[@]}"; do
    cname="${row%%|*}"
    printf '  %-20s %s\n' "$cname" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cname" 2>/dev/null || echo '-')"
  done
}

# ── 7. 最近日志 ───────────────────────────────────────────────
logs_menu() {
  head1 "最近日志"
  local i=1 names=() kinds=()
  for row in "${UNITS[@]}"; do
    names+=("${row%%|*}"); kinds+=("unit"); i=$((i + 1))
    printf '  %2d) %-24s %s\n' "$((i - 1))" "${row%%|*}" "systemd"
  done
  local cname
  for row in "${CONTAINERS[@]}"; do
    cname="${row%%|*}"
    names+=("$cname"); kinds+=("docker")
    printf '  %2d) %-24s %s\n' "$i" "$cname" "docker"
    i=$((i + 1))
  done
  printf '   0) 返回\n'
  printf '选择（默认 1）: '
  local sel; read -r sel || return 0
  [[ -z "$sel" ]] && sel=1
  [[ "$sel" == "0" ]] && return 0
  [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 && "$sel" -le "${#names[@]}" ]] || { warn "无效"; return 1; }
  local idx=$((sel - 1))
  local nm="${names[$idx]}" kd="${kinds[$idx]}"
  hr
  printf '  %s最近 60 行：%s%s\n' "$C_D" "$nm" "$C_0"
  if [[ "$kd" == "unit" ]]; then
    journalctl -u "$nm" -n 60 --no-pager 2>/dev/null | sed 's/^/  /'
    dim "持续跟随：journalctl -u $nm -f"
  else
    docker logs --tail 60 "$nm" 2>&1 | sed 's/^/  /'
    dim "持续跟随：docker logs -f $nm"
  fi
}

# ── 8. 备份状态 ───────────────────────────────────────────────
backups() {
  head1 "定时任务里的备份"
  crontab -l 2>/dev/null | grep -E 'backup|wb|dump' | grep -v '^#' | sed 's/^/  /' || dim "root crontab 里没有备份任务"

  head1 "WorkBuddy 备份（/root/backups/workbuddy-manager）"
  if [[ -d /root/backups/workbuddy-manager ]]; then
    local cnt last size
    cnt=$(ls -1 /root/backups/workbuddy-manager/wbm-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
    last=$(ls -1t /root/backups/workbuddy-manager/wbm-*.tar.gz 2>/dev/null | head -1)
    if [[ -n "$last" ]]; then
      size=$(du -h "$last" | cut -f1)
      printf '  份数 %s   最新 %s（%s）\n' "$cnt" "$(basename "$last")" "$size"
      local age_h; age_h=$(( ($(date +%s) - $(stat -c %Y "$last")) / 3600 ))
      if [[ $age_h -le 26 ]]; then ok "上次备份 ${age_h} 小时前"; else warn "上次备份已是 ${age_h} 小时前，检查 cron"; fi
    else
      warn "目录存在但没有备份文件"
    fi
  else
    bad "备份目录不存在"
  fi

  head1 "博客备份"
  if [[ -f /home/blog/logs/backup.log ]]; then
    printf '  最近一条：\n'
    tail -2 /home/blog/logs/backup.log 2>/dev/null | sed 's/^/    /'
  else
    dim "未找到 /home/blog/logs/backup.log"
  fi
  dim "恢复演练日志：/var/log/blog-drill.log"
}

# ── 9. 未登记项（自动发现）────────────────────────────────────
list_drift_units() {
  local known
  known=$(printf '%s\n' "${UNITS[@]}" | cut -d'|' -f1)
  systemctl list-units --type=service --state=running --no-legend 2>/dev/null |
    awk '{print $1}' | sed 's/\.service$//' |
    grep -vE "$IGNORE_UNIT_RE" | grep -vxF "$known" || true
}
list_drift_containers() {
  local known
  known=$(printf '%s\n' "${CONTAINERS[@]}" | cut -d'|' -f1)
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -vxF "$known" || true
}
drift_count() {
  local n=0
  n=$((n + $(list_drift_units | grep -c . || true)))
  docker_ok && n=$((n + $(list_drift_containers | grep -c . || true)))
  echo "$n"
}
drift() {
  head1 "未登记的服务（systemd）"
  local u; u=$(list_drift_units)
  if [[ -z "$u" ]]; then ok "没有未登记的 systemd 服务"; else
    printf '%s\n' "$u" | sed 's/^/  - /'
    dim "如果是长期要用的，去 $0 的 UNITS 里加一行，以后就会带中文说明显示"
  fi
  head1 "未登记的容器"
  local c; c=$(list_drift_containers)
  if [[ -z "$c" ]]; then ok "没有未登记的容器"; else printf '%s\n' "$c" | sed 's/^/  - /'; fi
}

# ── 操作：systemd 启停 ────────────────────────────────────────
confirm_yes() { # 提示语
  local ans
  printf '%s%s%s\n  确认请输入 YES: ' "$C_Y" "$1" "$C_0"
  read -r ans || return 1
  [[ "$ans" == "YES" ]]
}

unit_action_menu() {
  need_root || { bad "需要 root（sudo srvmenu）"; return 1; }
  head1 "选择服务（systemd）"
  local i=1 row n d spec risk st
  for row in "${UNITS[@]}"; do
    IFS='|' read -r n d spec risk _ <<< "$row"
    st=$(unit_state "$n")
    printf '  %2d) %-22s %-8s %s\n' "$i" "$n" "$st" "$d"
    i=$((i + 1))
  done
  printf '   0) 返回\n选择: '
  local sel; read -r sel || return 0
  [[ "$sel" == "0" ]] && return 0
  [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 && "$sel" -le "${#UNITS[@]}" ]] || { warn "无效"; return 1; }
  row="${UNITS[$((sel - 1))]}"
  IFS='|' read -r n d spec risk rnote <<< "$row"

  printf '\n  %s → 1) 启动   2) 停止   3) 重启   4) 看日志   0) 返回\n选择: ' "$n"
  local act; read -r act || return 0
  case "$act" in
    1) systemctl start "$n" && ok "已启动 $n" || bad "启动失败，看：journalctl -u $n -n 30" ;;
    3) systemctl restart "$n" && ok "已重启 $n" || bad "重启失败" ;;
    2)
      if [[ -n "$risk" ]]; then
        warn "风险：${rnote:-$risk}"
        # 如果你正通过 ZT 连着，停 zerotier 会当场断线
        local ztnet
        ztnet=$(ip -4 -o addr show 2>/dev/null | awk '$2 ~ /^zt/ {print $4; exit}' | cut -d/ -f1 | cut -d. -f1-3)
        if [[ "$n" == "zerotier-one" && -n "$ztnet" && "${SSH_CONNECTION:-}" == "$ztnet".* ]]; then
          bad "你当前就是从 ZeroTier 网段（$ztnet.0/24）连进来的，停掉它会立刻断线，只能走控制台 VNC"
        fi
        [[ "$risk" == "DANGER" || "$risk" == "ADAPTER" ]] && { confirm_yes "确认停止 $n ?" || { warn "已取消"; return 0; }; }
      fi
      systemctl stop "$n" && ok "已停止 $n" || bad "停止失败" ;;
    4) journalctl -u "$n" -n 60 --no-pager | sed 's/^/  /' ;;
    *) return 0 ;;
  esac
}

# ── 操作：容器启停 ────────────────────────────────────────────
container_action_menu() {
  need_root || { bad "需要 root"; return 1; }
  head1 "选择容器"
  local i=1 row cname cdesc crisk cst
  for row in "${CONTAINERS[@]}"; do
    IFS='|' read -r cname cdesc crisk _ <<< "$row"
    printf '  %2d) %-20s %-22s %s\n' "$i" "$cname" "$(container_state "$cname")" "$cdesc"
    i=$((i + 1))
  done
  printf '   0) 返回\n选择: '
  local sel; read -r sel || return 0
  [[ "$sel" == "0" ]] && return 0
  [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 && "$sel" -le "${#CONTAINERS[@]}" ]] || { warn "无效"; return 1; }
  IFS='|' read -r cname cdesc crisk _ <<< "${CONTAINERS[$((sel - 1))]}"

  printf '\n  %s → 1) 启动   2) 停止   3) 重启   4) 看日志   0) 返回\n选择: ' "$cname"
  local act; read -r act || return 0
  case "$act" in
    1) docker start "$cname" >/dev/null && ok "已启动 $cname" ;;
    3) docker restart "$cname" >/dev/null && ok "已重启 $cname" ;;
    2)
      if [[ -n "$crisk" ]]; then
        warn "风险：$crisk"
        confirm_yes "确认停止 $cname ?" || { warn "已取消"; return 0; }
      fi
      docker stop "$cname" >/dev/null && ok "已停止 $cname"
      ;;
    4) docker logs --tail 60 "$cname" 2>&1 | sed 's/^/  /' ;;
    *) return 0 ;;
  esac
}

# ── 操作：nginx ───────────────────────────────────────────────
nginx_menu() {
  need_root || { bad "需要 root"; return 1; }
  head1 "nginx（不归 systemd，别用 systemctl）"
  printf '  1) 检查配置语法 (nginx -t)\n  2) 重载配置 (reload，不断连接)\n'
  printf '  3) 看当前生效的 workbuddy-manager 配置\n  4) 进程与端口\n  0) 返回\n选择: '
  local sel; read -r sel || return 0
  case "$sel" in
    1) nginx -t 2>&1 | sed 's/^/  /' ;;
    2)
      if nginx -t >/dev/null 2>&1; then
        nginx -s reload && ok "已重载（不动连接）"
      else
        bad "语法不过，拒绝重载 —— 先看 1)"
        nginx -t 2>&1 | sed 's/^/  /'
      fi ;;
    3) nginx -T 2>/dev/null | sed -n '/workbuddy-manager.conf:/,+26p' | sed 's/^/  /' ;;
    4) printf '  master/worker: %s\n' "$(pgrep -c -f 'nginx: ')"
       ss -ltnp 2>/dev/null | grep nginx | sed 's/^/  /' ;;
    *) return 0 ;;
  esac
}

# ── 操作：磁盘清理 ────────────────────────────────────────────
cleanup_menu() {
  need_root || { bad "需要 root"; return 1; }
  head1 "磁盘现状"
  df -hP / | sed 's/^/  /'
  [[ -d /root/backups/workbuddy-manager ]] && printf '  WorkBuddy 备份占用: %s\n' "$(du -sh /root/backups/workbuddy-manager | cut -f1)"
  head1 "Docker 占用"
  docker system df 2>/dev/null | sed 's/^/  /'
  head1 "可清理项"
  printf '  1) 悬空镜像（docker image prune，安全）\n  2) 构建缓存（docker builder prune，安全）\n'
  printf '  3) 已停止的容器（含 lsky-pro，会删容器不删卷）\n  0) 返回\n选择: '
  local sel; read -r sel || return 0
  case "$sel" in
    1) confirm_yes "清理悬空镜像？" && docker image prune -f | tail -2 | sed 's/^/  /' ;;
    2) confirm_yes "清理构建缓存？" && docker builder prune -f | tail -2 | sed 's/^/  /' ;;
    3) confirm_yes "删除所有已停止容器？" && docker container prune -f | tail -2 | sed 's/^/  /' ;;
    *) return 0 ;;
  esac
}

# ── 帮助 ─────────────────────────────────────────────────────
usage() {
  cat <<EOF
srvmenu ${VERSION} —— 本机运维菜单

交互：  srvmenu
直出：  srvmenu overview | services | health | ports | top | containers | drift | backups
日志：  srvmenu logs

更新（WorkBuddy Manager）：
  srvmenu update check              对比 GitHub 最新 Release
  srvmenu update run                执行更新（先自动快照，失败可回滚）
  srvmenu update points             列出回滚点
  srvmenu update rollback [时间戳]  回到某个回滚点
  srvmenu update snapshot           只打快照不更新（更新前手动留点）

直接操作（需 root）：
  srvmenu restart <unit>            systemctl restart 某个 unit
  srvmenu unit <start|stop|restart> <unit>
  srvmenu docker <start|stop|restart> <容器>
  srvmenu nginx check|reload
  srvmenu health --quiet            只输出异常项（可放进 cron / 监控）

三层托管的区别（记牢，排查时会救命）：
  systemd    业务服务、zerotier-one、docker …              用 systemctl
  Docker     workbuddy2api、plnl-*、wgdashboard …           用 docker
  init.d     nginx、php-fpm、bt、btwaf …                    用 service / 直接命令
             nginx 尤其不能用 systemctl：is-active 恒为 inactive

新增服务后：编辑本文件的 UNITS / CONTAINERS 数组加一行，
           之后「未登记项」就不会再提示，清单里也会带中文说明。
EOF
}

# ── 更新（WorkBuddy Manager）──────────────────────────────────
# 说明：真正的下载/验签/同步/重建都交给官方 deploy/update.py（它核验发布页 sha256 与签名，
# 不接受跳过）。本脚本只在它外面加三件事：更新前打快照、更新后做校验、失败能一键回滚。
# 快照落在 /root/backups/workbuddy-manager/pre-update/<时间戳>/，保留最近 3 个。
WBM_DIR="${WBM_DIR:-/opt/workbuddy-manager}"
WBM_UPSTREAM="${WBM_UPSTREAM:-/opt/workbuddy2api}"
WBM_REPO="ithtelab/workbuddy-manager"
WBM_IMAGE="${WBM_IMAGE:-workbuddy2api-wb2api:latest}"
WBM_SNAP_ROOT="/root/backups/workbuddy-manager/pre-update"
WBM_SVC="${WBM_SVC:-workbuddy-web}"

wbm_version_raw() { tr -d '[:space:]' < "$WBM_DIR/.version" 2>/dev/null; }
wbm_env() { # 从 .env 取一个键，取不到就静默返回空
  [[ -f "$WBM_DIR/.env" ]] || return 0
  sed -n "s/^$1=//p" "$WBM_DIR/.env" | head -1
}

gh_get() { # GitHub API 路径，直连失败自动走镜像
  local path="$1" out token mirror
  token=$(wbm_env WB_GITHUB_TOKEN)
  if out=$(curl -fsS -m 20 -H 'Accept: application/vnd.github+json' \
        ${token:+-H "Authorization: Bearer $token"} \
        "https://api.github.com${path}" 2>/dev/null); then
    printf '%s' "$out"; return 0
  fi
  mirror=$(wbm_env WB_GITHUB_MIRROR)
  mirror="${mirror:-https://gh-proxy.com/}"; mirror="${mirror%/}"
  out=$(curl -fsS -m 30 -H 'Accept: application/vnd.github+json' \
        "${mirror}/https://api.github.com${path}" 2>/dev/null) || return 1
  printf '%s' "$out"
}

wbm_latest() { # 输出三行：tag / 发布日 / 说明正文
  local json
  json=$(gh_get "/repos/${WBM_REPO}/releases/latest") || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("tag_name", ""))
print(d.get("published_at", "") or "")
print((d.get("body") or "").strip())
'
}

update_check() {
  head1 "检查更新：WorkBuddy Manager"
  local raw cur out tag pub body img cid
  raw=$(wbm_version_raw); cur="${raw#v}"
  printf '  当前版本  %s\n' "${raw:-未知}"
  printf '  安装目录  %s\n' "$WBM_DIR"
  img=$(docker image inspect "$WBM_IMAGE" --format '{{.Created}}' 2>/dev/null | cut -dT -f1)
  cid=$(docker inspect -f '{{.Image}}' workbuddy2api 2>/dev/null | cut -c8-19)
  printf '  上游镜像  %s   构建于 %s   容器镜像 %s\n' \
         "$WBM_IMAGE" "${img:-未知}" "${cid:-未运行}"

  if ! out=$(wbm_latest); then
    warn "查不到 GitHub Release（网络不通或 API 限流）"
    dim "手动看：https://github.com/${WBM_REPO}/releases"
    dim "配了镜像也很难提速时可设 WB_GITHUB_TOKEN（60→5000 次/小时）"
    return 1
  fi
  tag=$(printf '%s' "$out" | sed -n 1p)
  pub=$(printf '%s' "$out" | sed -n 2p)
  body=$(printf '%s' "$out" | sed -n '3,$p')

  printf '  最新版本  %s   发布于 %s\n' "$tag" "${pub%%T*}"
  if [[ -n "$cur" && "$cur" == "${tag#v}" ]]; then
    ok "已是最新"
    return 0
  fi
  if [[ -n "$cur" ]] && [[ "$(printf '%s\n%s\n' "$cur" "${tag#v}" | sort -V | tail -1)" == "$cur" ]]; then
    ok "本地不低于远端（${raw} ≥ ${tag}）"
    return 0
  fi
  warn "有新版本：${raw:-未知} → ${tag}"
  echo
  printf '%s\n' "$body" | head -14 | sed 's/^/    /'
  echo
  dim "下一步：菜单 15（执行更新），或 srvmenu update run"
}

update_points() {
  head1 "更新/回滚点"
  [[ -d "$WBM_SNAP_ROOT" ]] || { dim "还没有回滚点（用过菜单 15 更新才会生成）"; return 0; }
  local d ts ver size tag
  printf '  %-16s %-10s %-8s %s\n' "TIME" "VERSION" "SIZE" "UPSTREAM_IMAGE"
  for d in $(ls -1d "$WBM_SNAP_ROOT"/*/ 2>/dev/null | sort -r); do
    ts=$(basename "$d")
    ver=$(sed -n 's/^VERSION_BEFORE=//p' "$d/manifest.env" 2>/dev/null)
    size=$(du -sh "$d" 2>/dev/null | cut -f1)
    tag=$(sed -n 's/^IMAGE_TAG=//p' "$d/manifest.env" 2>/dev/null)
    printf '  %-16s %-10s %-8s %s\n' "$ts" "${ver:-?}" "${size:-?}" "${tag:-无}"
  done
  dim "保留最近 3 个；旧的在下次更新时自动清理"
}

# 打快照：管理端代码 + venv + 上游源码，并给当前上游镜像打 rollback 标签
wbm_snapshot() {
  local dir="$1" ts="$2" img_id
  mkdir -p "$dir" || return 1
  dim "打包管理端代码…"
  ( cd / && tar czf "$dir/manager-code.tar.gz" \
      opt/workbuddy-manager/server opt/workbuddy-manager/web \
      opt/workbuddy-manager/deploy opt/workbuddy-manager/.version 2>/dev/null )
  dim "打包 venv（88M，回滚依赖需要）…"
  ( cd / && tar czf "$dir/manager-venv.tar.gz" opt/workbuddy-manager/venv 2>/dev/null )
  dim "打包上游源码（不含 auths / data / config.json）…"
  ( cd / && tar czf "$dir/upstream-code.tar.gz" \
      --exclude='opt/workbuddy2api/auths' --exclude='opt/workbuddy2api/data' \
      --exclude='opt/workbuddy2api/config.json' opt/workbuddy2api 2>/dev/null )
  img_id=$(docker inspect -f '{{.Image}}' workbuddy2api 2>/dev/null || true)
  {
    printf 'TS=%s\n' "$ts"
    printf 'VERSION_BEFORE=%s\n' "$(wbm_version_raw)"
    printf 'CREATED=%s\n' "$(date '+%F %T')"
    if [[ -n "$img_id" ]]; then
      docker tag "$img_id" "workbuddy2api-wb2api:pre-$ts" 2>/dev/null \
        && printf 'IMAGE_TAG=workbuddy2api-wb2api:pre-%s\n' "$ts"
    fi
  } > "$dir/manifest.env"
  [[ -s "$dir/manager-code.tar.gz" ]] || return 1
  # 只留最近 3 个快照目录
  local keep=0 old
  for old in $(ls -1d "$WBM_SNAP_ROOT"/*/ 2>/dev/null | sort -r); do
    keep=$((keep + 1))
    [[ $keep -le 3 ]] && continue
    rm -rf "$old" && dim "清理旧快照 $(basename "$old")"
  done
  return 0
}

# 校验更新/回滚后的状态
wbm_verify() {
  local wait_s=${1:-60} i up=0 okall=0
  printf '\n%s── 校验 ──%s\n' "$C_B" "$C_0"
  for i in $(seq 1 $((wait_s / 2))); do
    if check_http "http://127.0.0.1:7865/api/healthz" 200; then up=1; break; fi
    sleep 2
  done
  if [[ $up -eq 1 ]]; then ok "面板入口 127.0.0.1:7865 返回 200"; else bad "面板入口不通"; okall=1; fi
  local st; st=$(unit_state "$WBM_SVC")
  if [[ "$st" == "active" ]]; then ok "systemd $WBM_SVC 运行中"; else bad "$WBM_SVC 状态 $st"; okall=1; fi
  local cst; cst=$(container_state workbuddy2api)
  case "$cst" in
    running/healthy|running) ok "上游容器 $cst" ;;
    *) bad "上游容器 $cst"; okall=1 ;;
  esac
  if check_http "http://127.0.0.1:7863/healthz" "200|503"; then
    ok "上游 7863 可应答（503=账号池空，正常）"
  else
    bad "上游 7863 不可应答"; okall=1
  fi
  printf '  当前版本  %s\n' "$(wbm_version_raw)"
  return $okall
}

update_run() {
  need_root || { bad "需要 root（sudo srvmenu）"; return 1; }
  head1 "执行更新：WorkBuddy Manager"
  local raw cur out tag target ts dir free_g rc i
  raw=$(wbm_version_raw); cur="${raw#v}"

  # 预检
  [[ -x "$WBM_DIR/venv/bin/python" ]] || { bad "缺少 $WBM_DIR/venv/bin/python"; return 1; }
  [[ -f "$WBM_DIR/deploy/update.py" ]] || { bad "缺少 deploy/update.py"; return 1; }
  docker_ok || { bad "docker 不可用，无法更新上游"; return 1; }
  free_g=$(df -P /root | awk 'NR==2{printf "%d", $4/1024/1024}')
  [[ "${free_g:-0}" -lt 2 ]] && { bad "根分区只剩 ${free_g}G，先清理再更新"; return 1; }
  if ! check_http "http://127.0.0.1:7865/api/healthz" 200; then
    warn "面板当前健康检查就不通过 —— 建议先修好，别在坏的版本上叠更新"
    confirm_yes "仍然继续？" || { warn "已取消"; return 0; }
  fi

  if out=$(wbm_latest); then
    tag=$(printf '%s' "$out" | sed -n 1p)
    printf '  当前 %s   →   最新 %s\n' "${raw:-未知}" "$tag"
    if [[ -n "$cur" && "$cur" == "${tag#v}" ]]; then
      warn "已经是最新版本，继续等于「重装同一版本」（可用于修复）"
      confirm_yes "确认重装？" || { warn "已取消"; return 0; }
    fi
  else
    warn "取不到最新版本号（可能网络/限流），仍可让官方更新器自行判断"
    tag="${raw:-未知}"
  fi

  printf '  更新范围：1) 全部（面板+上游，推荐）  2) 仅面板  3) 仅上游  0) 取消\n  选择: '
  local scope; read -r scope || return 0
  case "$scope" in
    1) target=both ;;
    2) target=manager ;;
    3) target=upstream ;;
    *) return 0 ;;
  esac

  confirm_yes "确认开始更新（$target）？会先做快照" || { warn "已取消"; return 0; }

  ts=$(date +%Y%m%d-%H%M%S)
  dir="$WBM_SNAP_ROOT/$ts"
  head1 "1/3 快照"
  if wbm_snapshot "$dir" "$ts"; then
    ok "快照完成：$dir（$(du -sh "$dir" 2>/dev/null | cut -f1)）"
  else
    bad "快照失败，已中止（不留快照就不更新）"
    return 1
  fi

  head1 "2/3 执行官方更新器"
  dim "cd $WBM_DIR && ./venv/bin/python deploy/update.py --target $target"
  pushd . >/dev/null 2>&1
  cd "$WBM_DIR" || { bad "进不去 $WBM_DIR"; return 1; }
  ./venv/bin/python deploy/update.py --target "$target" 2>&1 | tee -a "$dir/update.log"
  rc=${PIPESTATUS[0]}
  popd >/dev/null 2>&1
  echo
  if [[ $rc -eq 0 ]]; then
    ok "更新器退出码 0（日志：$dir/update.log）"
  else
    bad "更新器退出码 $rc（日志：$dir/update.log）"
  fi

  head1 "3/3 校验"
  local failed=0
  wbm_verify 60 || failed=1
  if [[ $rc -ne 0 ]]; then failed=1; fi

  if [[ $failed -eq 0 ]]; then
    ok "更新完成：$(wbm_version_raw)"
    dim "回滚点保留在 $dir，需要时可走菜单 16"
    return 0
  fi

  bad "更新后状态不正常"
  printf '  立刻回滚到更新前的快照？(Y/n): '
  local ans; read -r ans || ans=""
  if [[ "$ans" == "n" || "$ans" == "N" ]]; then
    warn "已跳过回滚。手动回滚：srvmenu update rollback $ts"
    return 1
  fi
  update_rollback_dir "$dir"
}

# 按快照目录执行回滚
update_rollback_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || { bad "快照目录不存在：$dir"; return 1; }
  need_root || { bad "需要 root"; return 1; }
  local tag st
  tag=$(sed -n 's/^IMAGE_TAG=//p' "$dir/manifest.env" 2>/dev/null)
  head1 "回滚到 $(basename "$dir")"
  printf '  目标版本  %s\n' "$(sed -n 's/^VERSION_BEFORE=//p' "$dir/manifest.env")"
  [[ -n "$tag" ]] && printf '  上游镜像  %s\n' "$tag"

  local with_up=1
  printf '  同时回滚上游容器？(Y/n): '
  local a; read -r a || a=""
  [[ "$a" == "n" || "$a" == "N" ]] && with_up=0

  confirm_yes "确认回滚？服务会短暂中断" || { warn "已取消"; return 0; }

  ok "停面板"
  systemctl stop "$WBM_SVC" 2>/dev/null

  ok "还原管理端代码"
  rm -rf /opt/workbuddy-manager/server /opt/workbuddy-manager/web /opt/workbuddy-manager/deploy
  tar xzf "$dir/manager-code.tar.gz" -C / || { bad "还原代码失败"; systemctl start "$WBM_SVC"; return 1; }
  if [[ -f "$dir/manager-venv.tar.gz" ]]; then
    ok "还原 venv（依赖一并回退）"
    rm -rf /opt/workbuddy-manager/venv
    tar xzf "$dir/manager-venv.tar.gz" -C /
  fi

  if [[ $with_up -eq 1 && -n "$tag" ]]; then
    ok "还原上游源码"
    tar xzf "$dir/upstream-code.tar.gz" -C / 2>/dev/null
    if docker image inspect "$tag" >/dev/null 2>&1; then
      ok "把旧镜像 $tag 打回 latest 并重建容器"
      docker tag "$tag" "$WBM_IMAGE" 2>/dev/null
      ( cd "$WBM_UPSTREAM" && docker compose up -d --force-recreate ) 2>&1 | tail -3 | sed 's/^/    /'
    else
      warn "旧镜像 $tag 不存在，上游保持更新后的样子"
    fi
  fi

  ok "修复目录属主（更新可能留下 root 文件）"
  chown -R workbuddy:workbuddy /opt/workbuddy-manager /opt/workbuddy2api 2>/dev/null

  ok "启动面板"
  systemctl start "$WBM_SVC"

  if wbm_verify 60; then
    ok "回滚后校验通过"
    dim "如需重新升级：srvmenu update run"
  else
    bad "回滚后仍不正常 —— 看 journalctl -u $WBM_SVC -n 80"
    return 1
  fi
}

update_rollback_menu() {
  need_root || { bad "需要 root"; return 1; }
  [[ -d "$WBM_SNAP_ROOT" ]] || { bad "还没有回滚点"; return 1; }
  head1 "选择要回滚到的快照"
  local i=1 d ts ver
  local dirs=()
  while IFS= read -r d; do
    ts=$(basename "$d"); ver=$(sed -n 's/^VERSION_BEFORE=//p' "$d/manifest.env" 2>/dev/null)
    dirs+=("$d")
    printf '  %2d) %-16s 版本 %-10s %s\n' "$i" "$ts" "${ver:-?}" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    i=$((i + 1))
  done < <(ls -1d "$WBM_SNAP_ROOT"/*/ 2>/dev/null | sort -r)
  printf '   0) 返回\n选择（默认 1）: '
  local sel; read -r sel || return 0
  [[ -z "$sel" ]] && sel=1
  [[ "$sel" == "0" ]] && return 0
  [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 && "$sel" -le "${#dirs[@]}" ]] || { warn "无效"; return 1; }
  update_rollback_dir "${dirs[$((sel - 1))]}"
}

# ── 主菜单 ───────────────────────────────────────────────────
main_menu() {
  while true; do
    printf '\n%s══ srvmenu %s  ·  %s  ·  %s ══%s\n' "$C_B" "$VERSION" "$HOST" "$(date '+%F %T')" "$C_0"
    cat <<'EOF'
  ── 查看 ────────────────────────────────────────
   1) 运行概览           2) 服务清单
   3) 健康检查           4) 端口占用
   5) 资源 Top           6) 容器详情
   7) 最近日志           8) 备份状态
   9) 未登记项
  ── 操作 ────────────────────────────────────────
  10) 服务 启/停/重启   11) 容器 启/停/重启
  12) nginx 检查/重载   13) 磁盘清理
  ── 更新（WorkBuddy Manager）─────────────────────
  14) 检查更新          15) 执行更新（自动快照）
  16) 回滚到更新点      17) 回滚点列表
  ── 其他 ────────────────────────────────────────
  18) 帮助
   0) 退出
EOF
    printf '请选择: '
    local c; read -r c || return 0
    case "$c" in
      1) overview ;;
      2) services ;;
      3) health ;;
      4) ports ;;
      5) top_procs ;;
      6) containers ;;
      7) logs_menu ;;
      8) backups ;;
      9) drift ;;
      10) unit_action_menu ;;
      11) container_action_menu ;;
      12) nginx_menu ;;
      13) cleanup_menu ;;
      14) update_check ;;
      15) update_run ;;
      16) update_rollback_menu ;;
      17) update_points ;;
      18) usage ;;
      0|q|quit|exit) return 0 ;;
      *) warn "无效选项：$c" ;;
    esac
    printf '\n%s按回车继续…%s' "$C_D" "$C_0"
    read -r _ || true
  done
}

# ── 入口 ─────────────────────────────────────────────────────
case "${1:-}" in
  "") main_menu ;;
  overview)   overview ;;
  services)   services ;;
  health)
    if [[ "${2:-}" == "--quiet" ]]; then
      out=$(health 2>&1) || true
      printf '%s\n' "$out" | grep -E '\[XX\]|异常'
      exit 0
    fi
    health ;;
  ports)      ports ;;
  top)        top_procs ;;
  containers) containers ;;
  drift)      drift ;;
  backups)    backups ;;
  logs)       logs_menu ;;
  usage|-h|--help|help) usage ;;
  version|-v|--version) echo "srvmenu $VERSION" ;;
  unit)
    need_root || { bad "需要 root"; exit 1; }
    [[ $# -ge 3 ]] || { bad "用法: srvmenu unit <start|stop|restart> <unit>"; exit 1; }
    systemctl "$2" "$3" && ok "已 $2 $3" ;;
  restart)
    need_root || { bad "需要 root"; exit 1; }
    [[ -n "${2:-}" ]] || { bad "用法: srvmenu restart <unit>"; exit 1; }
    systemctl restart "$2" && ok "已重启 $2" ;;
  docker)
    need_root || { bad "需要 root"; exit 1; }
    [[ $# -ge 3 ]] || { bad "用法: srvmenu docker <start|stop|restart> <容器>"; exit 1; }
    docker "$2" "$3" >/dev/null && ok "已 $2 $3" ;;
  nginx)
    case "${2:-}" in
      check)  nginx -t ;;
      reload) nginx -t && nginx -s reload && ok "已重载" ;;
      *) bad "用法: srvmenu nginx check|reload"; exit 1 ;;
    esac ;;
  update)
    case "${2:-check}" in
      check)    update_check ;;
      run)      update_run ;;
      points)   update_points ;;
      rollback)
        if [[ -n "${3:-}" ]]; then
          update_rollback_dir "$WBM_SNAP_ROOT/$3"
        else
          update_rollback_menu
        fi ;;
      snapshot)
        need_root || { bad "需要 root"; exit 1; }
        ts=$(date +%Y%m%d-%H%M%S)
        if wbm_snapshot "$WBM_SNAP_ROOT/$ts" "$ts"; then
          ok "快照完成：$WBM_SNAP_ROOT/$ts"
        else bad "快照失败"; exit 1; fi ;;
      *) bad "用法: srvmenu update check|run|rollback [时间戳]|points|snapshot"; exit 1 ;;
    esac ;;
  *) bad "未知参数：$1（试试 srvmenu help）"; exit 1 ;;
esac
