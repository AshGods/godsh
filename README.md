# Debian 入站端口白名单防火墙

适用于 Debian 11、12、13。

脚本使用 nftables 管理入站流量：

- 自动识别并放行 SSH TCP 端口。
- 放行远程端口文件中的端口，同时支持 TCP 和 UDP。
- 屏蔽 IPv4/IPv6 Ping 请求。
- 其他未放行的入站端口全部丢弃。
- 每分钟从 GitHub 同步一次端口文件。
- 不修改 `/etc/nftables.conf`，使用独立规则和 systemd 服务。
- 保留 DHCP、DHCPv6 及必要 ICMP/ICMPv6 流量，避免影响云主机网络。

## 文件地址

安装脚本：

```text
https://raw.githubusercontent.com/AshGods/godsh/refs/heads/main/setup-inbound-firewall.sh
```

远程端口文件：

```text
https://raw.githubusercontent.com/AshGods/godsh/refs/heads/main/inbound-firewall-ports.conf
```

## 端口文件格式

每行只能填写一个端口号。允许空行和以 `#` 开头的注释。

```text
# 节点端口
13610
13611
31501
59993
```

每个端口都会同时放行 TCP 和 UDP。端口范围必须是 `1-65535`，最多允许 1024 个端口。

SSH 端口不需要写入远程端口文件，脚本会单独检测并保存。

## 安装前检查

请先确认以下条件：

1. 当前机器可以访问 GitHub Raw。
2. SSH 服务正在正常监听。
3. AWS、Google Cloud 等平台的安全组已经放行 SSH 和需要使用的业务端口。
4. 机器没有同时使用 UFW 或 firewalld。
5. 首次安装时保留当前 SSH 会话，并准备云平台控制台或 Session Manager 作为恢复入口。

检查 SSH 监听端口：

```bash
sudo ss -lntp | grep sshd
sudo /usr/sbin/sshd -T | grep '^port '
```

## 一键安装

确认 GitHub 上已经上传最新版脚本后执行：

```bash
curl -fsSL https://raw.githubusercontent.com/AshGods/godsh/refs/heads/main/setup-inbound-firewall.sh | sudo bash
```

如果 SSH 使用特殊端口，可以明确指定。该选项可以重复使用：

```bash
curl -fsSL https://raw.githubusercontent.com/AshGods/godsh/refs/heads/main/setup-inbound-firewall.sh -o /tmp/setup-inbound-firewall.sh
sudo bash /tmp/setup-inbound-firewall.sh --ssh-port 2222
```

安装完成后不要立即关闭原 SSH 会话。请打开另一个终端，确认能够重新登录。

## 查看运行状态

查看当前规则：

```bash
sudo nft list table inet inbound_guard
```

查看开机加载服务：

```bash
sudo systemctl status inbound-firewall-load.service --no-pager
```

查看定时同步器：

```bash
sudo systemctl status inbound-firewall-sync.timer --no-pager
sudo systemctl list-timers inbound-firewall-sync.timer --no-pager
```

查看最近的同步日志：

```bash
sudo journalctl -u inbound-firewall-sync.service -n 100 --no-pager
```

## 手动同步

修改 GitHub 端口文件后，可以等待一分钟自动同步，也可以立即执行：

```bash
sudo /usr/local/sbin/inbound-firewall-sync --sync
```

端口没有变化时，脚本不会重复加载 nftables 规则。

## 修改 SSH 端口

SSH 端口保存在：

```text
/etc/inbound-firewall/ssh-ports.conf
```

更换 SSH 端口时，推荐按照以下顺序操作：

1. 先把新端口加入 `/etc/inbound-firewall/ssh-ports.conf`。
2. 执行一次手动同步。
3. 修改 sshd 配置并重启 SSH 服务。
4. 使用新端口建立第二个 SSH 会话。
5. 确认新端口正常后，再从缓存文件和 sshd 配置中删除旧端口。
6. 再执行一次手动同步。

示例：先放行 TCP 2222。

```bash
echo 2222 | sudo tee -a /etc/inbound-firewall/ssh-ports.conf
sudo /usr/local/sbin/inbound-firewall-sync --sync
```

定时同步会合并持久化 SSH 端口和当前 sshd 配置，不会从远程业务端口文件删除 SSH 端口。

## 本地文件

```text
/usr/local/sbin/inbound-firewall-sync
/etc/inbound-firewall/ports.conf
/etc/inbound-firewall/ssh-ports.conf
/etc/inbound-firewall/rules.nft
/etc/systemd/system/inbound-firewall-load.service
/etc/systemd/system/inbound-firewall-sync.service
/etc/systemd/system/inbound-firewall-sync.timer
```

原运行时规则的备份位置会在安装成功时输出，文件名类似：

```text
/var/backups/nftables-before-inbound-guard-20261014-120000.nft
```

## 冲突保护

检测到以下情况时，脚本会停止安装或同步，不会应用新规则：

- UFW 正在运行或已设置开机启动。
- firewalld 正在运行或已设置开机启动。
- iptables/ip6tables 存在 INPUT 过滤规则。
- nftables 存在其他 input 基础链。
- 远程端口文件下载失败、格式错误、过大或端口过多。
- 生成的 nftables 规则语法检查失败。

## 紧急恢复

如果安装后连接异常，请通过云平台控制台或 Session Manager 执行：

```bash
sudo systemctl disable --now inbound-firewall-sync.timer
sudo systemctl disable --now inbound-firewall-load.service
sudo nft delete table inet inbound_guard 2>/dev/null || true
```

这组命令只删除本脚本创建的 `inbound_guard` 表，不会清空整台机器的其他 nftables 规则。

需要恢复安装前的完整运行规则时，使用安装输出中的备份文件：

```bash
sudo nft -f /var/backups/nftables-before-inbound-guard-时间戳.nft
```

## 完整卸载

```bash
sudo systemctl disable --now inbound-firewall-sync.timer
sudo systemctl disable --now inbound-firewall-load.service
sudo nft delete table inet inbound_guard 2>/dev/null || true
sudo rm -f /etc/systemd/system/inbound-firewall-sync.timer
sudo rm -f /etc/systemd/system/inbound-firewall-sync.service
sudo rm -f /etc/systemd/system/inbound-firewall-load.service
sudo rm -f /usr/local/sbin/inbound-firewall-sync
sudo rm -rf /etc/inbound-firewall
sudo systemctl daemon-reload
```

卸载 nftables 软件包不是必需的，因为系统中的其他程序可能仍然需要它。

## 注意事项

- 远程端口文件只控制业务端口，不会更新脚本本身。
- GitHub 上更新脚本后，已经安装的机器不会自动升级脚本，需要重新执行安装命令。
- 本脚本只管理入站流量，不限制出站流量和转发流量。
- nftables 放行端口不代表云平台安全组已经放行；两边都必须允许才能从公网访问。
- 不要同时使用多个防火墙管理器维护入站规则。
