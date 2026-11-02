# 变更日志

版本号规则：`v2.x` 为通用版主线，`v2.6` 之后拆出宝塔专用版（见 [`../ipblock-bt`](../ipblock-bt)）。

---

## v2.8

**主题：支持免下载直接运行（`bash <(curl ...)`）**

- 新增 `install.sh`：一条命令完成 检查依赖 → 下载 → 校验 → 安装 → 进菜单；支持 `--no-run`、`--uninstall`
- 修复：用 `bash <(curl -sL .../ipblock.sh)` 或 `curl | bash` 运行时，`$0` 是 `/dev/fd/xx` 或 `bash` 而不是实体文件，`install_self` 直接 `cp` 会失败，导致 cron 与 systemd 服务指向一个不存在的路径，而且没有任何提示
- 现在通过 `SELF_IS_FILE` 识别运行方式，非实体文件时改为从仓库下载安装；下载内容做 `#!` 首行 + `bash -n` 双重校验，防止镜像/代理返回 HTML 错误页被当成脚本装上
- 下载源支持主备：`raw.githubusercontent.com` 失败后自动尝试 jsDelivr
- 安装失败时明确报错并给出手动命令，不再继续创建指向空路径的定时任务（菜单 3→3、7→1，以及 DDNS/自愈 cron 的开启流程都加了失败拦截）

---

## v2.7

**主题：与 ufw / 宝塔面板共存**

- 新增 `detect_stack()`：检测 ufw、firewalld、宝塔面板是否在运行，状态页显示"共存环境"
- 新增 `--health` 自愈：规则被别的防火墙清掉就重新加载；配套 `/etc/cron.d/ipblock-health`（`1-59/5`），菜单 `7 → 5` 开关
- systemd 单元加 `After=… ufw.service` 与 `Wants=ufw.service`，避免 ufw 启动晚于本服务把规则覆盖掉
- 菜单 8 增加共存提示；`filter` 回退模式下启动与状态页红色警告
- 说明：宝塔"安全"页保存规则会触发 `ufw reload`（内部 `iptables-restore` 对 filter 等表是清空重建），`ufw reset` / 重装面板则清全部表

## v2.6

**主题：按段聚合封禁**

- lastb 自动封禁不再逐条封 `/32`，改为按段聚合：
  - 同一 /24 内不同 IP ≥ `AGG_C_MIN`(3) → 封整个 /24
  - 该 /16 已封过 /24、本轮又出现新 /24 → 围绕新 /24 前后各扩 `AGG_NEIGHBOR`(8) 个，只在本 /16 内
  - 要覆盖的 /24 超过 `AGG_B_HARD`(20) → 直接封整个 /16
  - 被网段覆盖的单 IP 全部剔除
- 安全阀：段内含当前 SSH IP 时该段不封，降级为逐个封段内候选 IP
- 菜单 3 增加"预览本轮会封什么"（干跑，不写规则）与聚合开关
- 修复：聚合用的 awk 键值格式不一致（`"102.220"` vs `"102 220"`）导致扩张与 /16 升级分支从未生效

## v2.5

**主题：DDNS 缺陷修复**

- 修复：`ddns_del` / `ddns_update` 用 `grep -c … || echo 0`，空文件输出两行 `0\n0` → 算术报错，最后一个域名永远删不掉，且白名单已改未回滚。统一改用 `count()`；所有"放弃替换"分支先 `restore` 再 `tx_done`
- 修复：共享 IP 的归属。新记录遇到"IP 已在白名单"时，若已有 `owned=1` 的记录则继承，否则两个域名都记 0，最后谁都不负责撤，IP 永久残留
- 修复：`ddns_update` 改两遍处理——循环只收集待撤旧 IP，跑完对着**新配置**判断是否还有人在用（原来在循环内读旧 conf，两域名同时换 IP 会互相认为对方还在用）
- 新增：用户手工把 DDNS 管的 IP 再加一次 → `owned` 置 0，管理权交还用户
- 新增：`_auto_lock` 支持等待秒数；DDNS cron 改 `3-59/10` 避开整点，不再和 lastb 任务抢锁；抢锁失败写日志
- 新增：提交前 `cksum` 守卫，解析期间配置被菜单改过就放弃本轮
- 修复：行数校验改为"写出数 vs 处理数"，不再被注释/空行误判
- 修复：域名匹配改用 `awk -F'|' '$1==d'`（`grep "^${d}|"` 里的 `.` 是通配符，`a.b.com` 会命中 `axb.com`）
- 修复：多 A 记录统一排序取值；`resolve_domain` 改为 `"ip 个数"` 两字段回传（子 shell 里赋值全局变量传不出去，多 A 告警原本根本不会触发）

> 升级注意：若之前开过 DDNS 自动检测，升级后需进菜单 `9 → 5` 重开一次，cron 行才会从 `*/10` 变成 `3-59/10`。

## v2.4

**主题：DDNS 动态域名白名单**

- 新增菜单 9，与命令 `--ddns`
- 四级降级解析；`nslookup` 过滤 `Server:` 行
- 解析失败保留旧 IP 并标记 `pending`
- 配置"临时文件 + 校验 + 原子替换"
- IP 未变但白名单条目被手工删除时自动补回
- 与 `--auto` 共用同一把锁（两者都读写 `whitelist.txt`）

## v2.3

**主题：第三轮 review 修复**

- 修复：`peer_ips` 的 sed 顺序错误（先剥 `]` 再剥端口，而 `[v6]:22` 的 `]` 不在行尾），双栈 sshd 下所有 IPv4 客户端的"已建立连接"安全阀失效
- 修复：白名单规则由 `ACCEPT` 改 `RETURN`。`filter` 回退模式下 `IPB` 是从 INPUT 跳进来的，`ACCEPT` 等于让白名单 IP 通过整个 INPUT（所有端口全通、连 fail2ban 规则都跳过）；nft 侧 `accept` 会终结整个 prerouting 钩子，连带跳过 docker 的 DNAT
- 菜单 8 规则过滤由"黑名单式"改为"白名单式"：只认 `-A 链 -s 地址 -j DROP|ACCEPT|REJECT` 与 `--match-set … src -j …`，列举"不该有的条件"永远列不完
- 白名单入口补范围检查：`/0` 直接拒绝（否则整个黑名单失效），过宽网段二次确认
- `SSH_IP` 过 `normalize_entry`（本地 X 会话的 `who` 输出 `:0` 之前能混进去）
- cron 静默模式不再逐条记 `SKIP` 日志，`lastb 不支持 -s` 只记一次

## v2.2

**主题：第二轮 review 修复**

- 修复：IPv6 带前缀时按位清零主机位（`2001:db8::1/64` → `2001:db8::/64`）并剥离 `/128`。原样存盘会让 nft 报 `prefix length doesn't match IP address` 整批回滚；`/128` 又让 `grep -qxF` 精确匹配失忆
- 修复：IPv6 统一走 `v6_render` 输出 RFC5952 压缩形式，顺带解决同一地址多种写法无法去重
- 修复：无 flock 时 `LOCK_DIR_MADE` 在 `mkdir` 之前赋值，抢锁失败退出会 `rm -rf` 别人正持有的锁
- 修复：`peer_ips` 改取最后一列（`ss` 版本差异会改变列位置）；sudo 会清掉 `SSH_CLIENT`，增加 `who -m` 兜底
- 菜单 8 只导入无附加条件的规则（`! -s 内网` 这类取反规则曾被当成封禁内网，语义完全反了）
- ipset 改为"灌临时集合 + swap"，避免 flush/add 期间集合为空
- 危险范围拦截：`0.0.0.0/0`、`::/0`、`127/8` 拒绝
- 快照改放进程私有 `RUNDIR`，cron 与交互菜单同时操作不会按对方快照回滚
- `del_line` / `sanitize_file` 改用同目录 `mktemp`（跨文件系统 `mv` 既非原子又会把权限变 600）
- 无 `raw` 表的容器回退到 `filter` 的 INPUT/FORWARD；lastb 只统计最近 24 小时

## v2.1

**主题：第一轮 review 修复**

- 修复：内核禁用 IPv6 但存在 `ip6tables` 命令时（阿里云/AWS 常见），`ipset create family inet6` 与 `ip6tables` 调用都失败 → 整次 apply 回滚，连 IPv4 都封不住。改为同时判断 `/proc/net/if_inet6`，且 IPv6 失败不拖累 IPv4
- 修复：手工编辑后末行无换行符时 `while read` 吞掉最后一行，改为 `while … read || [[ -n $var ]]`
- 临时文件统一收进 `RUNDIR`，`EXIT/INT/TERM` 统一清理
- 无 flock 时用 `mkdir` 原子锁降级，并回收 `kill -9` 留下的僵尸目录锁
- IPv6 补上网段包含判断（按半字节比较 32 位十六进制串）
- 空集合不再输出 `elements = { }`；systemd 改成拆开的 `enable` + `start`

## v2.0

**主题：相对 v1 的修复与新增**

- 数据文件里只要有一条空行/注释/非法条目，整次 nft apply 会语法报错失败；v1 的 `do_whitelist` 失败后不回滚 → 此后所有修改永久不生效。改为先 `sanitize`
- nft 首次运行时直接 `delete table` 会报 `No such file or directory`，而 `nft -f` 是整体事务 → 改为"先探测再删除"
- 任何写操作先快照，apply 失败自动回滚文件 + 恢复旧规则
- 菜单 `read` 遇 Ctrl-D / 终端断开时 v1 会死循环打满 CPU → 读到 EOF 直接退出
- lastb 自动封禁增加安全阀：当前 SSH IP / 已建立连接 / 近期成功登录过的 IP 不自动封
- `count()` 空文件时输出 `0\n0`，菜单显示"共 0 0 条"
- IPv6 校验过松（`:::` / `1::2::3` 都能过），进文件后每次都让 apply 失败
- 输入解析加 `set -f`，防止 `*` `?` `[` 被路径展开
- 解封时若 IP 被某网段覆盖，直接询问是否解封整个网段
- 日志超 2MB 自动截断
- `--auto` 依赖 flock，无 flock 时静默什么都不做 → 增加降级路径
- 新增菜单 8：导入系统现有防火墙规则

## v1.0

- 初始版本：nft / ipset+iptables 双后端、lastb 自动封禁、黑白名单管理
- 已知问题见 v2.0 的修复条目；保留在 `archive/` 仅作对照
