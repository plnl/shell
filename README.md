# shell

自用 Shell 脚本集合，偏运维方向。每个脚本一个目录，目录内含脚本本体、`README.md`（用法）与 `CHANGELOG.md`（变更日志）。

## 脚本清单

| 目录 | 说明 | 版本 | 适用环境 |
|---|---|---|---|
| [`ipblock/`](./ipblock) | IP 封禁 / 白名单管理，支持 lastb 自动封禁、按段聚合、DDNS 动态白名单、导入系统现有防火墙规则 | v2.7 | Debian/Ubuntu/CentOS，nftables 或 ipset+iptables |
| [`ipblock-bt/`](./ipblock-bt) | 同上，但资源命名全部隔离，专供装了**宝塔面板 + ufw/firewalld** 的机器使用 | v1.0 | 宝塔面板共存场景 |

## 使用方式

```bash
git clone https://github.com/plnl/shell.git
cd shell/ipblock
sudo ./ipblock.sh
```

脚本都是单文件、无外部依赖（除系统自带的 `nft` / `iptables` / `ipset` / `curl` 之类），直接 `scp` 到服务器也能跑。

## 约定

- **只改本机，不做远程操作**：脚本只操作当前机器的防火墙与本地文件。
- **改动前先留后路**：涉及防火墙的脚本都带"先把自己 IP 加白"的入口，第一次用请先做这一步。
- **归档而非删除**：旧版本放在各目录的 `archive/` 下，方便回退。

## 免责

这些脚本会**直接修改系统防火墙规则**，配置不当可能导致自己连不上服务器。请先在测试机验证，并确保有 VNC / 控制台等带外访问方式。使用风险自负。

## License

[MIT](./LICENSE)
