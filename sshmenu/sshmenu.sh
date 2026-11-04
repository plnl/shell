#!/usr/bin/env bash
# =====================================================================
#  sshmenu.sh  v1.0  —  SSH 登录方式 / 密钥管理 独立脚本
#
#  功能: 查看登录方式 · 安装密钥 · 切换 仅密钥/仅密码/密钥+密码 · root 策略
#        查看删除已授权密钥 · 改端口 · 查看登录记录 · sshd 配置备份回滚
#
#  安全: 改 sshd 的顺序固定为 备份 -> 注释冲突行(含 Include 的 drop-in)
#        -> 写托管块 -> sshd -t 语法检查 -> 重载/重启 -> sshd -T 核对生效值
#        任一步失败自动回滚。关闭密码登录前会检查是否已有授权密钥。
#
#  用法: ./sshmenu.sh            进入菜单
#        ./sshmenu.sh --status   只打印当前登录方式(适合脚本/cron)
#        ./sshmenu.sh --backup   备份一次 sshd 配置
#        ./sshmenu.sh --help
#
#  依赖: bash 3.2+, root, openssh(sshd/ssh-keygen)
#  与 ipblock 的菜单 10 是同一套实现, 两者改的是同一个 sshd, 互相可见。
#  变更历史见同目录 CHANGELOG.md
# =====================================================================
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
set -f

LOG=/var/log/sshmenu.log
SSH_IP=${SSH_CLIENT%% *}
[[ -z $SSH_IP ]] && SSH_IP=${SSH_CONNECTION%% *}

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
info(){ echo -e "${G}[+]${N} $*"; }
warn(){ echo -e "${Y}[!]${N} $*"; }
err(){  echo -e "${R}[x]${N} $*"; }
pause(){ read -rp "按回车继续..." _ || exit 0; }
log(){ echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; }
count(){ local n=0; [[ -f $1 ]] && n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }

[[ $EUID -eq 0 ]] || { echo "请使用 root 运行" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")" 2>/dev/null; touch "$LOG" 2>/dev/null
# 日志超 2MB 截断
if [[ -f $LOG ]] && (( $(wc -c < "$LOG" 2>/dev/null || echo 0) > 2097152 )); then
  tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi

RUNDIR=""
_cleanup(){ [[ -n $RUNDIR && -d $RUNDIR ]] && rm -rf "$RUNDIR" 2>/dev/null; return 0; }
trap '_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
_rundir(){ [[ -n $RUNDIR && -d $RUNDIR ]] || RUNDIR=$(mktemp -d 2>/dev/null) || return 1; return 0; }

# 当前 SSH IP: sudo 会清掉 SSH_CLIENT, 用 who -m 兜底并校验
if [[ -z $SSH_IP ]] && command -v who >/dev/null 2>&1; then
  SSH_IP=$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' | head -n 1)
  SSH_IP=${SSH_IP#::ffff:}
  [[ $SSH_IP =~ ^[0-9a-fA-F:.]+$ ]] || SSH_IP=""
fi

# SSH 登录方式 / 密钥管理
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
# 入口
# ---------------------------------------------------------------------
case ${1:-} in
  --status) ssh_status; exit 0 ;;
  --backup)
    ssh_backup || { err "备份失败"; exit 1; }
    info "已备份: $SSH_LAST_BACKUP"; exit 0 ;;
  -h|--help)
    cat <<EOF
用法: $0            进入菜单
      $0 --status   打印当前登录方式(只读)
      $0 --backup   备份一次 sshd 配置
      $0 --help
备份目录: $SSH_BACKUP_DIR (保留最近 10 份)
EOF
    exit 0 ;;
  "") ;;
  *) err "未知参数: $1 (用 --help 看用法)"; exit 2 ;;
esac

[[ -t 0 ]] || { err "菜单需要交互式终端; 只读查看请用 --status"; exit 1; }
[[ -f $SSHD_CONFIG ]] || { err "找不到 $SSHD_CONFIG, 这台机器可能没装 openssh-server"; exit 1; }
ssh_menu
