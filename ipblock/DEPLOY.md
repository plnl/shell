# 新机器部署教程

面向一台**全新的 VPS**，从零装好并跑通 [`ipblock.sh`](./ipblock.sh)。全程约 5 分钟。

> 已装宝塔面板的机器请用 [`ipblock-bt`](../ipblock-bt)，资源命名不同，两版可共存。

## TL;DR

一行装好并直接进菜单（推荐）：

```bash
bash <(curl -sL https://raw.githubusercontent.com/plnl/shell/main/ipblock/install.sh)
```

进菜单后依次按：`7`→`4`（把自己 IP 加白，**必做**）、`7`→`1`（开机恢复）、`3`→`2`（预览）、`3`→`3`（开启每小时自动封禁）。

服务器访问 GitHub 慢的话，把 `raw.githubusercontent.com` 换成镜像：

```bash
bash <(curl -sL https://cdn.jsdelivr.net/gh/plnl/shell@main/ipblock/install.sh)
```

---

## 一、前置条件

| 项 | 要求 |
|---|---|
| 权限 | root |
| Shell | bash 3.2+（系统自带即可） |
| 后端 | `nftables` 或 `ipset` + `iptables`，二选一 |
| 可选 | `ss` `last` `lastb` `dig`/`nslookup` `systemctl` `flock` |

检查一下现有环境：

```bash
id -u                                  # 应为 0
command -v nft ipset iptables lastb    # 看有哪些
cat /etc/os-release | head -2
```

## 二、安装依赖

Debian / Ubuntu：

```bash
apt update && apt install -y nftables
```

CentOS / RHEL 7（内核老，通常没有 nft）：

```bash
yum install -y ipset iptables
```

脚本运行时会自动判断用哪个后端：`nft list tables` 能跑就用 nftables，否则用 ipset + iptables。状态页第一行会显示实际后端。

## 三、安装脚本（三种方式，任选一种）

### 方式 A：一行命令（推荐）

```bash
bash <(curl -sL https://raw.githubusercontent.com/plnl/shell/main/ipblock/install.sh)
```

`install.sh` 会依次做：检查 root → 检查后端依赖 → 下载 `ipblock.sh` → 校验（shebang + `bash -n`）→ 装到 `/usr/local/bin/ipblock.sh` → 打印版本与 sha256 → 进菜单。

可重复执行，等同于升级（`/etc/ipblock` 里的黑白名单不动）。常用参数：

```bash
bash <(curl -sL .../install.sh) --no-run      # 只装不进菜单
bash <(curl -sL .../install.sh) --uninstall   # 卸载（保留数据目录）
```

### 方式 B：直接跑主脚本

```bash
bash <(curl -sL https://raw.githubusercontent.com/plnl/shell/main/ipblock/ipblock.sh)
```

也能用。这种运行方式下 `$0` 是 `/dev/fd/63` 而不是实体文件，脚本会自己识别这一点，在需要装 cron / systemd 时**从仓库重新下载一份**到 `/usr/local/bin/ipblock.sh`。只是每次都多下一次，不如方式 A 干净。

### 方式 C：手动下载放置

```bash
curl -fsSL -o /usr/local/bin/ipblock.sh \
  https://raw.githubusercontent.com/plnl/shell/main/ipblock/ipblock.sh
chmod 755 /usr/local/bin/ipblock.sh

# 可选：校验完整性
sha256sum /usr/local/bin/ipblock.sh
# 4183be2dde0ff3430a6d78642acbc4c96c6bc19f1f162c6204a8e84a8aba7947
```

放进 `/usr/local/bin` 有实际意义：装 systemd 服务和 cron 时，脚本会引用自己的安装路径，路径不对的话定时任务跑不起来。

### 为什么不能 `curl ... | bash`

管道方式下 **stdin 是管道不是终端**，菜单的 `read` 读不到键盘输入，脚本会直接报「需要交互式终端」退出。`bash <(curl ...)`（进程替换）只替换"脚本文件"这一项，stdin 仍是你的终端，所以菜单能正常用。

## 四、首次运行（按顺序点，别跳）

```bash
sudo ipblock.sh
```

### 1. `7` → `4` 把自己加入白名单

```
  当前 SSH IP : 203.0.113.5
  [+] 已加入白名单: 203.0.113.5
```

**这一步是安全绳**。不做的话，同事/你自己连续输错 5 次密码，或者办公室 NAT 出口被爆破，下一个整点就可能把整个出口 IP 封掉。

### 2. `7` → `1` 安装开机自动恢复

写 `/etc/systemd/system/ipblock.service` 并 `enable`，重启后规则自动回来（否则重启就全丢）。

### 3. `3` → `2` 预览本轮会封什么

干跑，只打印不写规则：

```
候选 15 个 IP
将新增: 102.220.160.0/24
        102.220.163.0/24
```

看懂这批候选是否合理，再决定下一步。

### 4. `3` → `3` 开启每小时自动检测

写入 `/etc/cron.d/ipblock-auto`（`0 * * * *`）。之后每个整点扫一次 `/var/log/btmp`，失败次数 ≥ 5 的 IP 按段聚合封禁。

### 5.（可选）`8` → `1` 导入现有防火墙规则

机器上已经有 fail2ban / ufw / 宝塔的手工封禁时，把它们导入统一管理。**只读扫描，不修改也不删除原有规则**；带端口条件的规则会被跳过并计数。

### 6.（可选）`9` → `2` 加 DDNS 域名

家宽动态 IP 时用。解析失败会标记 `pending` 而不是撤规则，自动检测默认每 10 分钟一次。

## 五、验证是否生效

```bash
# nft 后端
nft list table inet ipblock
nft list set inet ipblock bl4          # 黑名单元素

# ipset + iptables 后端
iptables -t raw -L IPB -n -v           # 看 packet 计数
ipset list ipb_bl4

# 通用
ipblock.sh --scan                      # 只读扫描现有规则
tail -f /var/log/ipblock.log
```

想看真的拦不拦得住：封一个测试 IP（如 `1.2.3.4`），然后从别处 `ping` / `ssh` 过去应该超时，`nft list set` 或 `iptables -v` 里的计数会增长。测完记得解封。

## 六、日常操作

| 想做的事 | 入口 |
|---|---|
| 封一个 IP 或网段 | 菜单 `1` |
| 解封（被网段覆盖时会问是否解整段） | 菜单 `4` |
| 加白名单（防自动封禁） | 菜单 `5` |
| 看/删黑名单、白名单 | 菜单 `2`、`6` |
| 看后端、规则状态、共存环境、自愈开关 | 菜单 `7` |
| 立刻跑一次 lastb 检测 | 菜单 `3` → `1` |

命令行入口（供 cron 或脚本调用）：

```bash
ipblock.sh --init     # 加载规则
ipblock.sh --auto     # 执行一次 lastb 检测
ipblock.sh --ddns     # 执行一次 DDNS 同步
ipblock.sh --health   # 规则丢了就重载
ipblock.sh --scan     # 只打印扫描结果
```

## 七、定时任务

| 文件 | 频率 | 作用 |
|---|---|---|
| `/etc/cron.d/ipblock-auto` | `0 * * * *` | lastb 自动封禁 |
| `/etc/cron.d/ipblock-ddns` | `3-59/10` | DDNS 同步（错开整点，避免抢锁） |
| `/etc/cron.d/ipblock-health` | `1-59/5` | 规则自愈 |

三个任务的分钟位是刻意错开的，同一时刻不会互相抢锁。状态在菜单 `7` 一眼能看到。

## 八、升级

数据在 `/etc/ipblock/`，升级不动它。重跑一次安装脚本即可（`--no-run` 表示不覆盖当前终端）：

```bash
bash <(curl -sL https://raw.githubusercontent.com/plnl/shell/main/ipblock/install.sh) --no-run
ipblock.sh --init        # 或进菜单 7 → 3 立即重新加载
```

也可以手动覆盖，效果一样：

```bash
curl -fsSL -o /usr/local/bin/ipblock.sh \
  https://raw.githubusercontent.com/plnl/shell/main/ipblock/ipblock.sh
chmod 755 /usr/local/bin/ipblock.sh && ipblock.sh --init
```

跨大版本升级时留意 `CHANGELOG.md` 里的"升级注意"，例如 v2.5 调整过 DDNS 的 cron 表达式，需要重进菜单 `9` → `5` 才会更新。

## 九、卸载

一键卸载（会二次确认，数据目录保留）：

```bash
bash <(curl -sL https://raw.githubusercontent.com/plnl/shell/main/ipblock/install.sh) --uninstall
```

手动卸载：

```bash
ipblock.sh               # 菜单 7 → 2 卸载 systemd 服务
rm -f /etc/cron.d/ipblock-{auto,ddns,health}

# nft 后端
nft delete table inet ipblock

# ipset + iptables 后端
iptables  -t raw -D PREROUTING -j IPB 2>/dev/null
iptables  -t raw -F IPB && iptables  -t raw -X IPB
ip6tables -t raw -D PREROUTING -j IPB 2>/dev/null
ip6tables -t raw -F IPB && ip6tables -t raw -X IPB
ipset destroy ipb_wl4 ipb_bl4 ipb_wl6 ipb_bl6

rm -rf /etc/ipblock /usr/local/bin/ipblock.sh
```

## 十、常见问题

**菜单提示"需要交互式终端"**
在 SSH 终端里直接跑，别用 `cron`、`nohup` 或 `curl | bash` 调菜单。

**菜单 `7` 里"当前 SSH IP：未知"**
`sudo` 会清掉 `SSH_CLIENT`，脚本用 `who -m` 兜底；如果还识别不到（例如 tmux / 跳板机），改用：

```bash
sudo -E ipblock.sh
```

实在不行，手动 `5` 把自己 IP 加白。

**封了 IP 但对方还能连**
按顺序查：① `nft list set inet ipblock bl4` 里有没有这条 → 没有说明没写进去，看 `/var/log/ipblock.log`；② 云厂商安全组是独立一层，两端都要看；③ 如果服务在 docker 里，确认没有更早的 hook 提前 accept。

**`nft list table inet ipblock` 报 No such file**
规则没加载。跑 `ipblock.sh --init`，或菜单 `7` → `3`。

**容器 / OpenVZ 上报 `iptables -t raw` 表不存在**
脚本会自动回退到 `filter` 表的 INPUT/FORWARD。这种模式最脆弱，别的防火墙一 reload 就没了 —— 一定要在菜单 `7` → `5` 开规则自愈。

**怕封太狠**
菜单 `3` → `2` 先预览；或调高 `AGG_B_HARD`（默认 20 个 /24 就升 `/16`）：

```bash
AGG_B_HARD=40 ipblock.sh        # 临时提高阈值，跑一次
```

**机器上还有宝塔面板**
换 [`ipblock-bt`](../ipblock-bt)，命名全部隔离，能避免面板 reload 把规则清掉。

更多细节见 [`README.md`](./README.md)（功能与参数）和 [`CHANGELOG.md`](./CHANGELOG.md)（版本历史）。
