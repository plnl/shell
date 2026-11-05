# 变更日志

## v1.1.1

**登记表外置到 `/etc/srvmenu.conf`，脚本内置只留通用示例**

- 机器相关的服务清单不再写死在脚本里：启动时 `source /etc/srvmenu.conf` 覆盖内置示例，
  也可用 `SRVMENU_CONF=/path/to/conf` 临时换一份
- 升级（`install.sh` 直接覆盖 `/usr/local/bin/srvmenu`）不再冲掉本机配置；
  `install.sh` 会提示检测到 / 未检测到该文件
- `2) 服务清单` 顶部显示当前生效的登记表来源
- 内置示例精简为 `docker` / `zerotier-one` 两条，其余以注释形式给出写法
- 依赖基线明确为 bash 4.4+（空数组在 `set -u` 下的展开行为）

## v1.1

**新增「更新 / 回滚」四个菜单（14~17），给宿主 systemd + Docker 上游的面板类项目用**

- **检查更新**：对比 GitHub Release；直连失败自动回退镜像（`WB_GITHUB_MIRROR`），支持
  `WB_GITHUB_TOKEN` 绕过 60 次/小时的未认证限流；同时显示当前上游镜像的构建日期与容器镜像 ID
- **执行更新**：预检（root / 磁盘 ≥2G / 更新器存在 / 当前健康）→ 快照 → 调官方
  `deploy/update.py` → 事后校验 → 校验不过询问是否立刻回滚；范围可选「全部 / 仅面板 / 仅上游」
- **回滚**：按快照还原管理端代码与 `venv`，旧镜像打回 `latest` 并重建容器，修属主后启动再校验；
  可选「只回滚面板、不动上游」
- **快照**：`/root/backups/workbuddy-manager/pre-update/<时间戳>/`
  （管理端代码 8M + venv 25M + 上游源码 1M + manifest），保留最近 3 个；旧镜像打
  `workbuddy2api-wb2api:pre-<时间戳>` 标签，防止被 `image prune` 带走
- 新增命令：`srvmenu update check|run|points|rollback [ts]|snapshot`

## v1.0

**第一版：把三层托管的服务摆进一张菜单**

- 三层分组展示：systemd / Docker / init.d，各带中文说明、运行状态、开机自启
- 登记表（`UNITS` / `CONTAINERS`）+ 自动发现未登记项，顶部过滤系统自带 unit
- 健康检查：HTTP 状态码 / TCP 端口 / `docker health` / ZeroTier 在线 / 关键链路（含 nginx 语法、磁盘余量）
- 运行概览：负载、内存、磁盘、内网入口（自动识别 zt/wg 网卡）、三层服务计数、异常数
- 端口占用：端口 → 进程 → 归属备注
- 资源 Top：内存 Top12、CPU Top8、`systemd-cgtop`、`docker stats`
- 容器详情：状态、重启策略、端口映射、`docker system df`
- 日志与备份：按 unit/容器看最近 60 行；crontab 备份任务与备份新鲜度
- 启停：systemd 与容器；危险服务（docker / zerotier / 数据库）停之前必须手打 `YES`，
  停 ZeroTier 时若当前 SSH 来自 ZT 网段会额外警告「你会当场断线」
- nginx 单独一页：检查 / 重载（reload 前强制 `nginx -t`）/ 看生效配置 / 进程与端口
- 磁盘清理：悬空镜像、构建缓存、已停容器
- 直出命令：`overview` / `services` / `health` / `ports` / `top` / `containers` / `drift` /
  `backups`；`health --quiet` 只输出异常行，可直接挂 cron
