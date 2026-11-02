# 变更日志

本目录从 [`ipblock`](../ipblock) v2.7 派生，功能基线即 v2.7，此处只记录**本版自身的改动**。功能层面的历史见 [`../ipblock/CHANGELOG.md`](../ipblock/CHANGELOG.md)。

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
