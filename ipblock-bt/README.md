# ipblock-bt

[`ipblock`](../ipblock) 的**宝塔面板专用版**（当前 v1.1，功能基线为通用版 v2.8）。功能完全一致，区别只有两点：**所有资源命名隔离**，以及**多了宝塔环境检查**。

## 为什么单独一个版本

装了宝塔面板的机器上，面板的"安全"页会在保存规则时调用 `ufw reload` 或 `firewall-cmd --reload`，极端情况下（重置防火墙、重装面板）会把所有表一起清空。同时宝塔还可能带 fail2ban 做 SSH 防爆破，与 lastb 自动封禁重复。

这个版本做两件事：

1. **命名全隔离** —— 可以和通用版 `ipblock` 装在同一台机器上，互不覆盖
2. **专门针对面板的行为做适配** —— 检测面板端口 / 防火墙后端 / fail2ban，规则放在面板 reload 碰不到的位置，并提供 5 分钟一次的自愈

## 与通用版的命名差异

| 资源 | 通用版 `ipblock` | 本版 `ipblock-bt` |
|---|---|---|
| 数据目录 | `/etc/ipblock` | `/etc/ipblockbt` |
| nft 表 | `inet ipblock` | `inet ipblockbt` |
| iptables 链 | `IPB` | `IPBBT` |
| ipset | `ipb_wl*` / `ipb_bl*` | `ipbbt_wl*` / `ipbbt_bl*` |
| 日志 | `/var/log/ipblock.log` | `/var/log/ipblockbt.log` |
| 锁 | `/var/lock/ipblock.lock` | `/var/lock/ipblockbt.lock` |
| 安装路径 | `/usr/local/bin/ipblock.sh` | `/usr/local/bin/ipblockbt.sh` |
| cron | `ipblock-auto` / `-ddns` / `-health` | `ipblockbt-auto` / `-ddns` / `-health` |
| systemd | `ipblock.service` | `ipblockbt.service` |

## 安装

```bash
cp ipblockbt.sh /usr/local/bin/ipblockbt.sh
chmod 755 /usr/local/bin/ipblockbt.sh
ipblockbt.sh
```

进去后按这个顺序：

1. `7 → 4` 把当前 SSH IP 加入白名单（**别跳过**）
2. `7 → 6` 看一眼宝塔环境，确认面板端口、SSH 端口、防火墙后端读对了
3. `7 → 1` 装开机自启（单元里已带 `After=… ufw.service`）
4. 首次运行会问一次是否开启规则自愈，建议同意（写 `.bt_asked` 标记，之后不再问）

## 菜单

主菜单与通用版一致（1–9），差别在 `7. 开机自启 / 系统状态` 多一项：

```
1. 安装开机自动恢复规则 (systemd)
2. 卸载开机自动恢复
3. 立即重新加载规则
4. 把当前 SSH IP 加入白名单 (防锁死, 推荐先做)
5. 开启/关闭规则自愈 (每 5 分钟检查, 防被 ufw/宝塔清掉)
6. 宝塔环境检查 (面板端口/防火墙后端/fail2ban)
```

`7 → 6` 的输出示例：

```
面板目录     : /www/server/panel
面板端口     : 18888
系统 SSH 端口: 27288
面板防火墙   : ufw (已启用)
fail2ban     : sshd
本脚本规则   : nft 独立表 inet ipblockbt (面板 reload 碰不到)
规则自愈     : 已开启 (每 5 分钟)
开机恢复     : 已安装
```

## 宝塔相关注意事项

- **不要点面板里的"重置防火墙"**，那会清掉所有表，本脚本规则也会没。丢了靠自愈恢复，最多 5 分钟窗口
- **面板上的端口规则仍归面板管**，本脚本只接管 IP 黑白名单。这样面板上看到的状态永远是对的，不会出现"面板显示已放行但实际不通"
- **两边都开防爆破会重复封禁**：面板的 fail2ban 与本脚本的 lastb 会各封一遍。建议留一套——要么关掉面板的 SSH 防爆破，要么菜单 `3 → 4` 关掉本脚本自动封禁、改用菜单 8 把 fail2ban 的封禁导入进来统一查看
- **白名单 ≠ 绕过 ufw**：白名单只是"本脚本不拦"，uvf 没放行的端口照样连不上

## 与通用版的选择

| 场景 | 用哪个 |
|---|---|
| 干净系统，只有 sshd / nginx | `ipblock` |
| 装了宝塔面板 | `ipblock-bt` |
| 两者都想装在同一台机器 | 可以，命名不冲突（但没必要，功能一样） |

## 其他

用法、命令行模式、环境变量、文件位置、已知限制，与 [`ipblock`](../ipblock/README.md) 完全一致，把命令里的 `ipblock.sh` 换成 `ipblockbt.sh` 即可。新机器部署步骤见 [`ipblock/DEPLOY.md`](../ipblock/DEPLOY.md)。

## License

[MIT](../LICENSE)
