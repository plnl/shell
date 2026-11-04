# shell

自用 Shell 脚本集合，偏运维方向。每个脚本一个目录，目录内含脚本本体、`README.md`（用法）与 `CHANGELOG.md`（变更日志）。

## 脚本清单

| 目录 | 说明 | 版本 | 适用环境 |
|---|---|---|---|
| [`ipblock/`](./ipblock) | IP 封禁 / 白名单管理，支持 lastb 自动封禁、按段聚合、DDNS 动态白名单、导入系统现有防火墙规则、SSH 登录方式管理 | v2.10 | Debian/Ubuntu/CentOS，nftables 或 ipset+iptables |
| [`ipblock-bt/`](./ipblock-bt) | 同上，但资源命名全部隔离，专供装了**宝塔面板 + ufw/firewalld** 的机器使用 | v1.3 | 宝塔面板共存场景 |
| [`sshmenu/`](./sshmenu) | SSH 登录方式与密钥管理：查看/切换登录方式、安装密钥、root 策略、改端口、配置备份回滚 | v1.0 | 任意装了 openssh-server 的 Linux |

## 文档

| 文档 | 内容 |
|---|---|
| **[ipblock 部署教程](./ipblock/DEPLOY.md)** | **全新 VPS 上从零装好，含验证、升级、卸载、排错** |
| [ipblock 功能说明](./ipblock/README.md) | 菜单、命令行、环境变量、文件位置、已知限制 |
| [ipblock 变更日志](./ipblock/CHANGELOG.md) | v1.0 → v2.10 全部改动 |
| [ipblock-bt 说明](./ipblock-bt/README.md) | 宝塔面板环境专用版，含命名隔离对照表 |
| [ipblock-bt 变更日志](./ipblock-bt/CHANGELOG.md) | v1.0 起 |
| [sshmenu 说明](./sshmenu/README.md) | SSH 登录管理：菜单、命令行、安全机制、排错 |
| [sshmenu 变更日志](./sshmenu/CHANGELOG.md) | v1.0 起 |

## 快速开始

一行装好并直接进菜单，详细步骤见 [ipblock/DEPLOY.md](./ipblock/DEPLOY.md)：

```bash
bash <(curl -sL https://raw.githubusercontent.com/plnl/shell/main/ipblock/install.sh)
```

进菜单后先按 `7` → `4` 把自己的 IP 加入白名单，再开自动封禁。

访问 GitHub 慢时可换镜像：把域名换成 `https://cdn.jsdelivr.net/gh/plnl/shell@main/ipblock/install.sh`。

要求系统有 `nftables`，或 `ipset` + `iptables`（CentOS 7 这类）：

```bash
apt install -y nftables              # Debian/Ubuntu
yum install -y ipset iptables        # CentOS/RHEL 7
```

脚本都是单文件，除系统自带的 `nft` / `iptables` / `ipset` 外无外部依赖，直接 `scp` 到服务器也能跑。

## 约定

- **只改本机，不做远程操作**：脚本只操作当前机器的防火墙与本地文件。
- **改动前先留后路**：涉及防火墙的脚本都带"先把自己 IP 加白"的入口，第一次用请先做这一步。
- **归档而非删除**：旧版本放在各目录的 `archive/` 下，方便回退。

## 免责

这些脚本会**直接修改系统防火墙规则**，配置不当可能导致自己连不上服务器。请先在测试机验证，并确保有 VNC / 控制台等带外访问方式。使用风险自负。

## License

[MIT](./LICENSE)
