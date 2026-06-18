# Microsocks SOCKS5 一键安装脚本

`install-microsocks.sh` 用于安装并启动 Microsocks 轻量 SOCKS5 代理服务。脚本支持通过系统包管理器安装；如果包管理器不可用或没有 `microsocks` 包，会在 `x86_64` 架构下尝试下载预编译静态二进制文件。

## 支持环境

- Alpine/OpenRC
- Debian/Ubuntu/systemd
- Fedora/RHEL/CentOS/systemd
- 其它没有 `systemctl` 的环境会按 OpenRC 风格处理

脚本需要 `root` 权限。执行过程中可能安装 `curl`、`ca-certificates`、`xz` 或 `xz-utils` 等依赖。

## 使用方法

查看帮助：

```sh
sudo bash install-microsocks.sh --help
```

使用随机端口、随机用户名和随机密码：

```sh
sudo bash install-microsocks.sh
```

指定端口、用户名、密码和监听地址：

```sh
sudo bash install-microsocks.sh \
  --port 2080 \
  --user proxyuser \
  --passwd strongpass \
  --bind 0.0.0.0
```

安装完成后，脚本会输出 SOCKS5 地址、用户名、密码和完整连接字符串，例如：

```text
socks5://proxyuser:strongpass@SERVER_IP:2080
```

## 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--port <端口>` | SOCKS5 服务监听端口。 | 随机生成 `20000-59999` 范围内端口 |
| `--user <用户名>`、`--username <用户名>` | SOCKS5 认证用户名。 | 随机生成 |
| `--passwd <密码>`、`--password <密码>`、`--pass <密码>` | SOCKS5 认证密码。 | 随机生成 16 位强密码 |
| `--bind <IP>`、`--ip <IP>` | 服务绑定地址。 | `0.0.0.0` |
| `-h`、`--help` | 显示帮助信息。 | 无 |

## 服务管理

Alpine/OpenRC：

```sh
rc-service microsocks status
rc-service microsocks restart
rc-service microsocks stop
```

systemd：

```sh
systemctl status microsocks
systemctl restart microsocks
systemctl stop microsocks
```

## 脚本写入内容

- Microsocks 二进制：通常来自系统包管理器；静态二进制 fallback 安装到 `/usr/local/bin/microsocks`
- OpenRC 服务：`/etc/init.d/microsocks`
- systemd 服务：`/etc/systemd/system/microsocks.service`

脚本还会尝试通过 `ufw`、`firewall-cmd` 或 `iptables` 放行 TCP 监听端口。

## 连接测试

替换为安装完成后输出的实际信息：

```sh
curl --socks5 proxyuser:strongpass@SERVER_IP:2080 https://ifconfig.me
```

