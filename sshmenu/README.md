# sshmenu

单文件的 **SSH 登录方式与密钥管理**工具。交互式菜单，改完自动校验、失败自动回滚。

从 [`ipblock`](../ipblock) 的「菜单 10」抽出来的独立版本，不依赖 ipblock，可以单独用在一台只做 SSH 加固的机器上。

## 功能

| 菜单 | 作用 |
|---|---|
| 1 | 查看当前登录方式（端口 / 密码 / 密钥 / root 策略 / 已授权密钥 / 配置备份） |
| 2 | 安装密钥：粘贴公钥、从文件导入、或现场生成一对 ed25519 |
| 3 | 切换登录方式：仅密钥 / 仅密码 / 密钥+密码 |
| 4 | root 登录策略：允许 / 只允许密钥 / 禁止 |
| 5 | 查看、删除已授权密钥（显示指纹，删除前自动备份） |
| 6 | 修改 SSH 端口（提示放行安全组/防火墙，用 restart 生效） |
| 7 | 查看最近登录记录（在线 / 成功 / 失败） |
| 8 | 备份与回滚 sshd 配置 |

## 依赖与安装

```bash
# 依赖: bash 3.2+ / root / openssh(sshd, ssh-keygen)
curl -fsSL -o /usr/local/bin/sshmenu.sh \
  https://raw.githubusercontent.com/plnl/shell/main/sshmenu/sshmenu.sh
chmod 755 /usr/local/bin/sshmenu.sh
sshmenu.sh
```

国内访问慢可换 jsDelivr：

```bash
curl -fsSL -o /usr/local/bin/sshmenu.sh \
  https://cdn.jsdelivr.net/gh/plnl/shell@main/sshmenu/sshmenu.sh
```

脚本没有 cron / systemd 依赖，放哪个目录都能跑。

## 命令行

```bash
sshmenu.sh --status    # 只读打印当前登录方式，适合脚本或监控
sshmenu.sh --backup    # 备份一次 sshd 配置
sshmenu.sh --help
```

`--status` 示例：

```
========== SSH 登录方式 ==========
  配置文件      : /etc/ssh/sshd_config
  监听端口      : 22
  登录方式      : 仅密钥
  密码登录      : 关闭
  密钥登录      : 开启
  root 登录     : 只允许 root 用密钥
  当前 SSH IP   : 203.0.113.5
  空密码登录    : 禁止
  root 已授权密钥: 2 个
  authorized_keys: /root/.ssh/authorized_keys (600)
  最近备份      : /etc/ssh/ipblock-backup/20261104-154256
--------------------------------------------
```

## 工作机制

改 sshd 的顺序是固定的，任一步失败自动回滚：

```
备份 → 注释所有冲突行（主配置 + 被 Include 的 sshd_config.d/*.conf）
     → 写托管块 # >>> ipblock managed >>>
     → sshd -t 语法检查
     → 重载(systemctl reload ssh/sshd, 改端口时 restart)
     → sshd -T 核对生效值 → 不一致就回滚
```

几个关键点：

**判断依据只认 `sshd -T`**。配置文件里写 `PasswordAuthentication no` 不代表生效——Debian/Ubuntu 云镜像常把 `Include /etc/ssh/sshd_config.d/*.conf` 放在主配置首行，再放个 `50-cloud-init.conf` 写 `yes` 覆盖它。OpenSSH 是"第一条匹配生效"，所以我们要先把所有文件里的同名行注释掉，写完再用 `sshd -T` 复核，不一致就回滚。

**托管块**。写入的内容包在 `# >>> ipblock managed >>>` 和 `# <<< ipblock managed <<<` 之间，重复执行整块替换，不会越写越长。

**备份**。每次改动前把主配置和所有被 Include 的文件复制到 `/etc/ssh/ipblock-backup/<时间戳>/`，用 `manifest` 记录原路径，恢复就是逐个拷回。保留最近 10 份。用 `cp` 而不是 tar，避免不同平台对绝对路径的处理差异。

**关密码前自检**。切「仅密钥」会先检查 root 有没有授权密钥，没有直接拒绝——否则等于把自己锁在门外。

> 备份目录和 [`ipblock`](../ipblock) 的菜单 10 共用（都是 `/etc/ssh/ipblock-backup`），时间戳不同，互不覆盖。两个工具改的是同一个 `sshd_config`，所以一方做的修改另一方能看到。

## 注意

- 这个脚本会写 `/etc/ssh/sshd_config`，**改错了会连不上**。第一次用先 `8` 备份一次，并确认云控制台有 VNC / 救援入口
- 切「仅密钥」后**不要关当前窗口**，另开一个终端用私钥登录成功了再关
- 生成的私钥只显示一次，记得当场保存；脚本会提示 `scp` 下载命令
- 只处理 IPv4 场景下的常规配置，`Match` 块里的指令不会被改写（那属于按用户/来源分流的高级用法）

## 常见问题

**改成「仅密钥」后连不上了**
还没断的会话里执行菜单 `8` → `r` 回滚。已经断线就用控制台 VNC / 救援模式：

```bash
cp /etc/ssh/ipblock-backup/<时间戳>/files/1 /etc/ssh/sshd_config
systemctl restart ssh    # CentOS: sshd
```

**`sshd -T` 报错**
说明当前配置本身有问题（不是本脚本改坏的，因为每次改完都会校验）。先手工 `sshd -t` 看报错行号。

**改了端口连不上**
安全组 / ufw / firewalld 都要放行新端口；`10`→`6` 的提示里有对应命令。旧会话不会立刻断，但重连要用新端口。

**authorized_keys 权限**
`~/.ssh` 必须 700、`authorized_keys` 必须 600，属主要是本人。权限过宽时 sshd 会静默忽略该文件。脚本写入时会自动设置，菜单 1 也会检查并提示。

## License

[MIT](../LICENSE)
