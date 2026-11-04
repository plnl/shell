# ipblock

单文件 IP 封禁 / 白名单管理脚本。交互式菜单，同时支持命令行模式供 cron 调用。

> 新机器从零部署，见 **[部署教程 DEPLOY.md](./DEPLOY.md)**（安装、首次运行顺序、验证、升级、卸载、排错）。

- **双后端**：优先 nftables；没有 nft 时自动回退 `ipset + iptables`（CentOS 7 这类老系统）
- **规则挂 PREROUTING**：本机入站和转发（docker / 端口转发）都拦得住
- **白名单优先**：白名单命中直接放行，不进黑名单判断
- **写操作事务化**：改文件前快照，`apply` 失败自动回滚文件并按旧文件重载规则，永远保持"文件 = 内核规则"

## 依赖

| 项 | 要求 |
|---|---|
| Shell | bash 3.2+（macOS 自带的那版也能跑，不依赖 bash 4 特性） |
| 权限 | root |
| 后端（二选一） | `nftables`，或 `ipset` + `iptables` |
| 可选 | `ss`、`last`、`lastb`、`dig`/`nslookup`、`systemctl`、`flock` |

Debian/Ubuntu：

```bash
apt install nftables            # 或 apt install ipset iptables
```

CentOS/RHEL：

```bash
yum install ipset iptables
```

## 安装

一行命令（推荐，会自动检查依赖、下载、校验、装到 `/usr/local/bin`，然后进菜单）：

```bash
bash <(curl -sL https://raw.githubusercontent.com/plnl/shell/main/ipblock/install.sh)
```

参数：`--no-run` 只装不进菜单，`--uninstall` 卸载（保留数据目录）。

手动安装：

```bash
cp ipblock.sh /usr/local/bin/ipblock.sh
chmod 755 ipblock.sh && chmod 755 /usr/local/bin/ipblock.sh
ipblock.sh
```

脚本自己也会在需要时（装 systemd 服务或 cron）把自己复制到 `/usr/local/bin/ipblock.sh`。

> **第一次用请先做这一步**：进菜单 `7 → 4`，把自己当前的 SSH IP 加入白名单。否则自动封禁有概率把你自己的出口 IP 也封掉。

## 菜单

```
1. 输入封禁 IP / IP段
2. 查看封禁 IP
3. 读取 lastb 自动封禁 (失败 >= 5 次, 按段聚合)
4. 手动解封 IP / IP段
5. 设置 IP 白名单
6. 查看 IP 白名单
7. 开机自启 / 系统状态
8. 检查并导入系统现有防火墙规则 (统一管理)
9. DDNS 动态域名白名单 (域名 IP 变化自动同步)
10. SSH 登录方式 / 密钥管理
0. 退出
```

### 3. lastb 自动封禁

```
1. 立即检测一次
2. 预览本轮会封什么 (不写入规则)   ← 建议先点这个
3. 开启每小时自动检测
4. 关闭每小时自动检测
5. 开关按段聚合
6. 查看最近日志
```

按段聚合规则（`AGG_ENABLE=1` 时生效）：

| 条件 | 动作 |
|---|---|
| 同一 /24 内不同 IP ≥ `AGG_C_MIN`（默认 3） | 封整个 /24 |
| 该 /16 已封过 /24，本轮又出现新 /24 | 围绕新 /24 前后各扩 `AGG_NEIGHBOR`（默认 8）个 /24，只在本 /16 内扩 |
| 要覆盖的 /24 超过 `AGG_B_HARD`（默认 20） | 直接封整个 /16 |
| 单 IP 落在已封网段内 | 从名单剔除 |

安全阀（`seg_guard`）：待封的段只要命中下面任何一条，就**不封段**，降级为逐个封段内候选 IP（降级后落在保护网段里的 IP 也会跳过）：

- 与**保护网段**相交：本机各网卡地址所在网段，以及 `10/8`、`172.16/12`、`192.168/16`、`100.64/10`、`169.254/16`、`fc00::/7`、`fe80::/10`、`::1/128` —— 避免把内网、docker 网段、链路本地整片封掉
- 含**当前 SSH IP**
- 含**正在连接的会话**或**近期成功登录**的 IP

单 IP 落在保护网段内同样跳过。IPv6 候选不走聚合，直接逐个封禁（同样受保护网段约束）。

### 8. 导入现有防火墙规则

只读扫描 nftables / iptables / ipset / firewalld / ufw（含 fail2ban 的 `f2b-*` 链与集合），把"源 IP"合并进黑名单/白名单统一管理。**不修改也不删除任何原有规则。**

只导入"除源地址和目标外没有任何附加条件"的规则；带 `-p`、`--dport`、`-m conntrack`、`!` 取反的一律跳过并计数——否则"只封 22 端口"会被导成"封整个 IP"，语义完全变了。

### 9. DDNS 动态域名白名单

```
1. 查看域名与解析状态
2. 添加 DDNS 域名
3. 删除 DDNS 域名
4. 立即检测并更新
5. 开启自动检测 (每 10 分钟)
6. 关闭自动检测
```

策略要点：

- 四级降级解析：`getent ahostsv4` → `getent hosts` → `dig` → `nslookup`（`nslookup` 会过滤掉 `Server:` 行，避免把本机 DNS 地址当成解析结果）
- 解析失败**保留旧 IP**并标记 `pending`，不因 DNS 抖动撤规则
- 记录里带 `owned` 字段：`1` 表示这个 IP 是脚本写进白名单的，`0` 表示用户手工加过同一个 IP。域名换 IP / 删域名时只撤 `owned=1` 的，不误删手工条目
- IP 未变但白名单条目被手工删掉 → 下一轮自动补回
- 只跟踪 A 记录（IPv4）

### 10. SSH 登录管理

```
1. 查看当前登录方式 (详情)
2. 安装密钥登录 (粘贴公钥 / 自动生成)
3. 切换登录方式 (仅密钥 / 仅密码 / 密钥+密码)
4. root 登录设置
5. 查看 / 删除已授权密钥
6. 修改 SSH 端口
7. 查看最近登录记录
8. 备份 / 回滚 sshd 配置
```

改配置的顺序是固定的，任一步失败自动回滚，不会把人锁在门外：

```
备份 -> 注释所有冲突行(含 Include 的 drop-in) -> 写托管块
     -> sshd -t 语法检查 -> 重载/重启 -> sshd -T 核对生效值
```

- **只有一个可信判据**：生效值取自 `sshd -T`，不是配置文件里写的。云镜像常在 `sshd_config.d/` 里放 `50-cloud-init.conf` 覆盖 `PasswordAuthentication yes`，只看主配置会误判；现在这些冲突行会被一并注释，写完再用 `sshd -T` 复核，不一致就回滚
- **托管块**：写入的内容包在 `# >>> ipblock managed >>>` 与 `# <<< ipblock managed <<<` 之间，重复执行会整块替换，不会越写越长
- **备份**：每次改动前把主配置和所有 `Include` 文件复制到 `/etc/ssh/ipblock-backup/<时间戳>/`（保留最近 10 份，`cp` 而非 tar，恢复就是逐个拷回）
- **关密码前自检**：切"仅密钥"会先检查 root 是否已有授权密钥，没有则拒绝；切换后提示保持当前会话、另开终端验证
- **密钥安装**三种方式：粘贴公钥（支持多行，自动校验格式、拒绝私钥、按密钥体去重）、从文件导入、直接生成 ed25519 密钥对（私钥只显示一次）
- **改端口**会提示放行安全组 / ufw / firewalld，并用 restart 而不是 reload

> 这一项会写 `/etc/ssh/sshd_config`，需要 root。第一次用建议先做菜单 8 备份，或在云控制台留一个 VNC 入口兜底。
>
> 只想做 SSH 加固、不需要 IP 封禁的机器，可以用独立版 [`sshmenu`](../sshmenu/README.md)（同一套实现，多了 `--status` 命令行）。

## 命令行模式

```bash
ipblock.sh --init      # 加载规则(开机动作用)
ipblock.sh --auto      # 执行一次 lastb 检测(cron 用)
ipblock.sh --ddns      # 执行一次 DDNS 同步(cron 用)
ipblock.sh --health    # 检查规则是否还在, 丢了就重载(cron 用)
ipblock.sh --scan      # 只打印扫描结果, 不改任何东西
ipblock.sh --help
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `THRESHOLD` | 5 | lastb 中出现 ≥ 该次数则自动封禁 |
| `BAN_WINDOW` | `-24hours` | lastb 只统计最近这段时间（老系统不支持 `-s` 时退化为全量） |
| `SKIP_SUCCESS` | 1 | 近期成功登录过 / 有活动连接 / 属于当前 SSH 的 IP 不自动封禁 |
| `AGG_ENABLE` | 1 | 按段聚合开关 |
| `AGG_C_MIN` | 3 | 同一 /24 内不同 IP 达到该值 → 封 /24 |
| `AGG_NEIGHBOR` | 8 | 扩张时前后各扩多少个 /24 |
| `AGG_B_HARD` | 20 | 同一 /16 下要覆盖的 /24 超过该值 → 封 /16 |
| `DDNS_MIN` | 10 | DDNS 检测间隔（分钟） |
| `HEALTH_MIN` | 5 | 规则自愈检查间隔（分钟） |

## 文件位置

| 路径 | 用途 |
|---|---|
| `/etc/ipblock/blacklist.txt` | 黑名单，每行一个 IP 或 CIDR |
| `/etc/ipblock/whitelist.txt` | 白名单，同上 |
| `/etc/ipblock/ddns.conf` | DDNS 记录，格式 `domain\|ip\|时间戳\|owned` |
| `/var/log/ipblock.log` | 操作日志（超过 2MB 自动截断保留最后 2000 行） |
| `/var/lock/ipblock.lock` | 命令行模式的互斥锁 |
| `/usr/local/bin/ipblock.sh` | 安装位置 |
| `/etc/cron.d/ipblock-auto` | lastb 自动封禁（`0 * * * *`） |
| `/etc/cron.d/ipblock-ddns` | DDNS 同步（`3-59/10`，错开整点） |
| `/etc/cron.d/ipblock-health` | 规则自愈（`1-59/5`） |
| `/etc/systemd/system/ipblock.service` | 开机恢复规则 |
| `/etc/ssh/ipblock-backup/<时间戳>/` | sshd 配置备份（菜单 10 改动前自动生成） |

数据文件可以手工编辑（每行一个条目，支持 `#` 注释），脚本启动时会做一次清洗：去空行、去注释、去重复、丢弃非法条目并告警。**非法条目一定要丢弃**，否则 `nft -f` 或 `ipset restore` 会整批失败，导致所有改动都不生效。

## 与系统已有防火墙共存

| 场景 | 影响 |
|---|---|
| ufw / firewalld 普通 reload | **碰不到本脚本的规则**——nft 后端用独立表 `inet ipblock`，ipt 后端用 `raw` 表（ufw 的 user.rules 只含 filter/nat） |
| `ufw reset` / 面板重装防火墙 | 会清掉全部表，规则丢失 → 靠 `--health` 自愈恢复 |
| 容器（OpenVZ/LXC）无 `raw` 表 | 回退到 `filter` 表的 INPUT/FORWARD，此时 ufw reload 会把链清掉，**必须开自愈** |

白名单的含义是"本脚本不拦"，**不是**绕过 ufw。若 ufw 没放行某端口，白名单里的 IP 照样连不上。

若机器上装了宝塔面板，建议改用 [`ipblock-bt`](../ipblock-bt) 版，两者资源命名完全隔离。

## 已知限制

- IPv6 支持封禁与网段匹配；自动聚合只针对 IPv4，IPv6 候选按单地址封禁
- DDNS 只跟踪 A 记录；一个域名有多个 A 记录时只放行排序后的第一条，并在日志里提示
- 手工封禁大段（`/8`、`/16`）不做聚合判断，由操作者自行确认（`/0`、`127/8` 会被拒绝）
- `lastb` 的 `-s` 时间窗口在极老的系统上不支持，会退化为全量统计并在日志里记一次

## 归档版本

| 文件 | 说明 |
|---|---|
| `archive/ipblock-v1.0.sh` | 最初版本，保留作对照（存在规则静默失效、把自己锁死等问题，不建议使用） |
| `archive/ipblock-v2.6.sh` | v2.6，功能完整但不含 ufw/宝塔共存检测与 `--health` 自愈 |

`archive/` 下的脚本与当前版本共用 `/etc/ipblock`、`inet ipblock` 表、`IPB` 链和 `ipblock.service`，**同一台机器只能装其中一个**。

## License

[MIT](../LICENSE)
