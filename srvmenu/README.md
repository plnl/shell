# srvmenu

**一台机器的运维入口**：把 systemd 服务、Docker 容器、init.d 老脚本三层摆在一张菜单里，一眼看清「装了什么、哪些在跑、哪个不正常」，并做常用启停与版本更新。

给「`systemctl` 看得见一半、`docker ps` 看得见另一半、nginx 还偏偏不归 systemd」的服务器用。

```
════ srvmenu 1.1.0  ·  myserver  ·  2026-11-05 15:50:02 ══
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
```

## 为什么需要它

一台机器上通常有三套托管机制，各查各的：

| 层 | 托管者 | 看它的命令 | 常见坑 |
|---|---|---|---|
| systemd | `blog-admin` / `xxx-web` / `zerotier-one` / `docker` | `systemctl` | 名字记不住，`is-failed` 不会主动告诉你 |
| Docker | 业务容器、数据库、面板 | `docker ps -a` | 停了的容器不在 `ps` 里，健康状态要看 `inspect` |
| init.d | `nginx` / `php-fpm` / `bt` | 直接命令 | **`systemctl is-active nginx` 恒为 `inactive`**，是假信号 |

`srvmenu` 把这三层按托管方式分组、配中文说明与探测方式，并且**登记表之外的东西会自动冒出来**——解决「半年后忘了自己装过什么」。

## 功能

| 菜单 | 作用 |
|---|---|
| 1 运行概览 | 主机/运行时长/负载/内存/磁盘/内网入口/三层服务计数/异常数 |
| 2 服务清单 | 三层分组，带中文说明、运行状态、开机自启 |
| 3 健康检查 | 逐项探测：HTTP 状态码 / TCP 端口 / docker health / ZeroTier / 关键链路 |
| 4 端口占用 | 端口 → 进程 → 归属备注 |
| 5 资源 Top | 内存 Top12、CPU Top8、`systemd-cgtop`、`docker stats` |
| 6 容器详情 | 状态、重启策略、端口映射、`docker system df` |
| 7 最近日志 | 子菜单选 unit 或容器，看最近 60 行 |
| 8 备份状态 | crontab 里的备份任务、备份新鲜度、备份日志尾 |
| 9 未登记项 | 自动发现没登记的新服务/新容器 |
| 10/11 启停 | systemd 服务 / Docker 容器 启动、停止、重启、看日志 |
| 12 nginx | 语法检查、重载、看生效配置、进程与端口 |
| 13 磁盘清理 | 悬空镜像 / 构建缓存 / 已停容器（均需手打 `YES`） |
| 14~17 更新 | 检查更新、执行更新、回滚、回滚点列表（见下） |

## 依赖与安装

```bash
# 依赖: bash 4.4+ / root / iproute2(ss) ；有 systemd 与 docker 时功能更全
bash <(curl -sL https://raw.githubusercontent.com/plnl/shell/main/srvmenu/install.sh)
```

GitHub 慢时用镜像，或手动装：

```bash
# 只装不进菜单
bash <(curl -sL https://raw.githubusercontent.com/plnl/shell/main/srvmenu/install.sh) --no-run

# 卸载
bash <(curl -sL .../srvmenu/install.sh) --uninstall

# 手动
curl -fsSL -o /usr/local/bin/srvmenu \
  https://raw.githubusercontent.com/plnl/shell/main/srvmenu/srvmenu.sh
chmod 755 /usr/local/bin/srvmenu
```

装完直接敲 `srvmenu`。只读页面不需要 root；启停、更新、回滚需要 root。

> Linux 专用（依赖 `/proc`、`ss`、`systemctl`、`docker`）。macOS 上跑不了。

## 命令行

菜单之外都能直出，方便丢进 cron 或临时查一条：

```bash
srvmenu overview | services | health | ports | top | containers | drift | backups
srvmenu health --quiet        # 只输出异常行，适合定时任务/告警
srvmenu logs                  # 交互选日志来源

srvmenu restart workbuddy-web                 # systemctl restart
srvmenu unit stop nginx2                      # 任意 unit 的 start/stop/restart
srvmenu docker restart workbuddy2api
srvmenu nginx check | reload

srvmenu update check | run | points | snapshot
srvmenu update rollback [时间戳]
```

## 登记表：让它认识你的服务

**机器相关的清单不写在脚本里**，而是 `/etc/srvmenu.conf`——脚本启动时 `source` 它，覆盖内置示例。这样 `install.sh` 升级只会替换 `/usr/local/bin/srvmenu`，**不会冲掉你的配置**。

```bash
# /etc/srvmenu.conf
UNITS=(
  "blog-admin|博客后台（写作/发布，8099）|http:http://127.0.0.1:8099/healthz:200|停掉=无法发文"
  "postgresql|本机数据库|port:5432|DANGER|停掉=业务直接报错"
  "zerotier-one|ZeroTier 组网|zt|DANGER|停掉=内网访问立刻断开"
)

# 名称|说明|风险|OPT（OPT=已停用/已卸载，缺失不算异常）
CONTAINERS=(
  "app-postgres|PostgreSQL 16|DANGER|停掉=业务直接报错"
  "old-app|已停用的旧容器||OPT"
)
```

- 没有这个文件也能用，只是清单里只有脚本内置的两条示例，其余全靠 `9) 未登记项` 提醒
- 临时换一份：`SRVMENU_CONF=/path/to/other.conf srvmenu`
- `2) 服务清单` 顶部会打印当前生效的是哪份登记表
- **换机器时把 `/etc/srvmenu.conf` 一起带走**，装完脚本即可恢复“认识自己的服务”

探测串写法：

| 写法 | 含义 |
|---|---|
| `http:<URL>:<允许码>` | 状态码落在允许码里算通过，多码用 `\|` 分隔（如 `200\|503`） |
| `port:<端口>` | 本机有监听算通过 |
| `zt` | `zerotier-cli info` 含 `ONLINE` |
| `docker` | `docker info` 可执行 |
| `none` | 只做状态显示，不探测 |

风险字段：留空 = 普通操作直接执行；`DANGER` / `ADAPTER` = 停之前必须手打 `YES`。第五段写「停掉会怎样」，会原样打印给操作者看。

**没登记的不会丢**：`9) 未登记项` 会把不在表里的运行中服务与容器列出来，提醒你补登记。判断「未登记」前会过滤系统自带 unit（`systemd-*`、`dbus`、`cron`、`ssh` 等）。

## 更新与回滚（WorkBuddy Manager）

菜单 14~17 是给 [`workbuddy-manager`](https://github.com/ithtelab/workbuddy-manager) 这类**宿主 systemd + 上游容器**部署用的。机器上没有 `/opt/workbuddy-manager` 时这几项无意义，可以不管。

真正的下载/验签/同步/重建交给官方 `deploy/update.py`（它核验发布页 sha256 与签名，不接受跳过）。`srvmenu` 只在外面加三件事：

1. **更新前打快照** → `/root/backups/workbuddy-manager/pre-update/<时间戳>/`
   - `manager-code.tar.gz`：`/opt/workbuddy-manager/{server,web,deploy,.version}`
   - `manager-venv.tar.gz`：`venv`（88M，回滚依赖需要）
   - `upstream-code.tar.gz`：`/opt/workbuddy2api` 源码（**刻意排除** `auths/`、`data/`、`config.json`）
   - `manifest.env`：更新前版本、时间、旧镜像标签
   - 旧上游镜像打上 `workbuddy2api-wb2api:pre-<时间戳>` 标签
   - 只留最近 3 个快照
2. **更新后校验** → 面板入口 200 / systemd active / 容器 running / 上游 `/healthz` 可应答 / 版本号
3. **校验不过可一键回滚** → 停面板 → 还原代码与 venv → 旧镜像打回 `latest` 并重建容器 → 修属主 → 起面板 → 再校验

```bash
srvmenu update check      # 对比 GitHub 最新 Release（支持镜像与 Token）
srvmenu update run        # 全流程：预检 → 快照 → 官方更新器 → 校验 → 失败询问回滚
srvmenu update points     # 列出回滚点
srvmenu update rollback   # 选一个回滚点（可选是否连上游一起回滚）
srvmenu update snapshot   # 只打快照不更新（更新前手动留个点）
```

**注意**：只有在 `srvmenu` 里执行更新才会留快照；直接在网页面板点「一键更新」不会产生快照（那时回滚要走官方发布包手工重建）。

国内容易卡在拉包，建议在安装目录 `.env` 里配镜像（面板「设置 → 系统 → GitHub 镜像加速」同理）：

```dotenv
WB_GITHUB_MIRROR=https://gh-proxy.com/
```

## 安全设计

- **只读优先**：1~9 全部只读，不碰任何服务；`健康检查` 也不会触发重启。
- **危险操作二次确认**：停 `docker`（连带全部容器）、`zerotier-one`（内网访问立断）、数据库容器，必须手打 `YES`。停 ZeroTier 时若检测到当前 SSH 来自 ZT 网段，会额外警告「你会当场断线」。
- **nginx 只 reload 不 restart**，且 reload 前强制 `nginx -t`，语法不过直接拒绝——避免把站点带下线。
- **不碰系统自带服务**：过滤掉 `systemd-*`、`dbus`、`cron`、`ssh` 等，菜单里只出现登记过的和你新装的。
- **更新不留快照就不动手**：快照失败直接中止更新。

## 排错

| 现象 | 原因 / 处理 |
|---|---|
| 服务清单里 nginx 显示未运行，但网站正常 | nginx 由 init.d 起，`systemctl is-active nginx` 恒为 `inactive`，这是 systemd 给 LSB 脚本生成的空壳。脚本看的是 master 进程，显示“运行中”才对 |
| 容器显示 `unhealthy` 但接口能用 | 有 healthcheck 的容器以自检为准；`workbuddy2api` 在账号池为空时 `/healthz` 返回 503，属正常态 |
| 健康检查里某行显示原始探测串 | 探测串写错（比如 `http:` 后面少了协议头），原样打印便于定位 |
| `update check` 取不到最新版本 | `api.github.com` 被限流（未认证 60 次/小时/IP）或网络不通。配 `WB_GITHUB_TOKEN`（只需读公共仓库 Releases）或 `WB_GITHUB_MIRROR` |
| 停掉服务后菜单报「未运行」但进程还在 | 该服务不是你登记的那个名字，用 `4) 端口占用` 反查真实进程名 |
| 回滚后仍不正常 | `journalctl -u workbuddy-web -n 80`；venv 已随快照还原，若仍报缺依赖，重跑 `update run` 升级到新版 |

## 约定

- **只读默认**：能看的一律不写，写操作显式选。
- **不猜**：状态来自 `systemctl` / `docker inspect` / `ss` 的真实输出，不做“看起来像”的判断。
- **可回退**：更新前必留快照，且快照本身在沙箱里验证过能完整还原。

## License

[MIT](../LICENSE)
