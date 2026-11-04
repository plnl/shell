# 变更日志

本目录从 [`ipblock`](../ipblock) v2.7 派生，功能基线即 v2.7，此处只记录**本版自身的改动**。功能层面的历史见 [`../ipblock/CHANGELOG.md`](../ipblock/CHANGELOG.md)。

---

## v1.3

**与通用版 v2.10 同步：SSH 登录方式管理（菜单 10）**

- 新增「SSH 登录管理」子菜单：查看登录方式 / 安装密钥 / 切换 仅密钥·仅密码·密钥+密码 / root 策略 / 查看删除密钥 / 改端口 / 登录记录 / 配置备份回滚
- 改动 sshd 的流程与通用版一致：备份 → 注释冲突行（含 `Include` 的 drop-in）→ 写托管块 → `sshd -t` → 重载 → `sshd -T` 核对，失败自动回滚
- 备份目录 `/etc/ssh/ipblock-backup/<时间戳>/`，两版共用同一结构但不互相覆盖

---

## v1.2

**与通用版 v2.9 同步**

- 同步聚合安全阀：`protected_nets` / `seg_guard`，私网、docker 网段、含在线会话或成功登录的段不再被整段封禁，改为逐个封候选 IP；手工封禁内网段也会二次确认
- 同步 IPv6 候选补封（聚合开启时 IPv6 原本永远不会被封）
- 同步 `agg_compute` 的空候选文件陷阱（`FNR==NR` → `FILENAME==ARGV[1]`）
- 同步 DDNS 同轮共享 IP 的归属继承
- 去掉 systemd 的 `Wants=ufw.service`，只保留 `After=`（避免把已停用的 ufw 拉起来）
- 修正提示里的服务名：`journalctl -u ipblock` / `systemctl enable --now ipblock` → `ipblockbt`；导出文件头也改为 `ipblockbt`
- `bt_ssh_port` 现在会读 `sshd_config.d/*.conf`（被 `Include` 的配置）

---

## v1.1

**与通用版 v2.8 同步：支持免下载直接运行**

- 修复：`bash <(curl ...)` / `curl | bash` 方式下 `$0` 不是实体文件，`install_self` 直接 `cp` 会失败，cron 与 systemd 指向不存在的路径且无提示
- 改为识别运行方式，非实体文件时从仓库下载安装；下载内容做 `#!` + `bash -n` 校验
- 主备下载源（raw.githubusercontent.com → jsDelivr）
- 安装失败明确报错，菜单 3→3、7→1 与 DDNS/自愈 cron 的开启流程都会中止而不是继续写空路径

---

## v1.0

**从 ipblock v2.7 派生，面向宝塔面板环境**

### 命名隔离

- 数据目录 `→ /etc/ipblockbt`
- nft 表 `inet ipblock` `→ inet ipblockbt`
- iptables 链 `IPB` `→ IPBBT`
- ipset `ipb_wl*` / `ipb_bl*` `→ ipbbt_wl*` / `ipbbt_bl*`
- 日志 `→ /var/log/ipblockbt.log`
- 锁 `→ /var/lock/ipblockbt.lock`
- 安装路径 `→ /usr/local/bin/ipblockbt.sh`
- cron `→ /etc/cron.d/ipblockbt-{auto,ddns,health}`
- systemd `→ ipblockbt.service`

> 批量改名用一次性 `perl` 替换完成。注意 `IPB → IPBBT` 只能跑一次，跑第二次会把 `IPBBT` 再替换成 `IPBBTBT`。

### 新增：宝塔环境适配

- `bt_detect` —— 通过 `/www/server/panel` 判断面板是否安装
- `bt_panel_port` —— 读 `data/port.pl`（兼容前后空白）
- `bt_ssh_port` —— 读 `sshd_config` 的第一个 `Port`（注释行会被忽略）
- `bt_fw_backend` —— 判断面板底层实际在用的防火墙（ufw / firewalld / 无）
- `bt_jails` —— 检测 fail2ban 是否有活跃 jail，有则提醒与本脚本重复封禁
- `bt_status` —— 汇总上述信息，输出到菜单 `7 → 6`
- 首次运行检测到宝塔且未开自愈时询问一次，写入 `.bt_asked` 标记，之后不再打扰

### 保留自 v2.7 的能力

- ufw / firewalld / 宝塔共存检测与状态页提示
- `--health` 规则自愈（cron `1-59/5`，菜单 `7 → 5` 开关）
- systemd 单元的 `After=… ufw.service` / `Wants=ufw.service`
- lastb 自动封禁 + 按段聚合（`AGG_*` 系列参数）
- DDNS 动态域名白名单（`owned` 归属、pending、自愈补回）
- 菜单 8 导入系统现有防火墙规则（白名单式过滤，只认无附加条件的规则）

### 说明

- 本版**只接管 IP 黑白名单**，不接管面板的端口规则
- `lastb` 自动封禁与面板 fail2ban 同时开启会重复封禁，建议只留一套
