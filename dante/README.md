# Dante SOCKS5 一键安装脚本

`install-dante.sh` 用于在 Debian/Ubuntu 类系统上安装 `dante-server`，创建用户名密码认证的 SOCKS5 代理，并启动 `danted` 服务。

## 支持环境

- Debian/Ubuntu 或其它可使用 `apt` 安装 `dante-server` 的系统
- 支持 systemd 的环境
- 无可用 systemd 时会尝试使用传统 `service danted restart`

脚本需要 `root` 权限，并会执行 `apt update` 和安装软件包。

## 使用方法

必须显式指定端口、用户名和密码：

```sh
sudo bash install-dante.sh \
  --port 20270 \
  --user proxyuser \
  --passwd strongpass
```

安装完成后，脚本会输出公网地址、监听地址、用户名、密码、出口网卡和服务模式，并给出测试命令。

## 参数说明

| 参数 | 说明 | 是否必填 |
| --- | --- | --- |
| `--port <端口>` | Dante SOCKS5 监听端口。 | 是 |
| `--user <用户名>` | SOCKS5 认证用户名。脚本会创建该系统用户；如果用户已存在，则更新密码。 | 是 |
| `--passwd <密码>` | SOCKS5 认证密码。 | 是 |

如果缺少任一参数，脚本会退出并显示：

```text
Usage: ./install-dante.sh --port 20270 --user USER --passwd PASS
```

## 脚本行为

脚本会执行以下操作：

- 检测服务模式：优先使用 systemd，否则使用 `service`
- 自动检测默认出口网卡，检测失败时使用 `eth0`
- 通过 `apt` 安装 `dante-server`、`curl`、`ca-certificates`
- 创建或更新指定系统用户，并设置密码
- 写入 `/etc/danted.conf`
- 在 systemd 环境中写入精简版 `/etc/systemd/system/danted.service`
- 启用并重启 `danted` 服务
- 尝试通过 `ipinfo.io` 或 `api.ipify.org` 获取公网 IP

## 服务管理

systemd：

```sh
systemctl status danted
systemctl restart danted
systemctl stop danted
```

传统 service：

```sh
service danted status
service danted restart
service danted stop
```

## 连接测试

替换为安装完成后输出的实际信息：

```sh
curl --socks5 proxyuser:strongpass@SERVER_IP:20270 https://ifconfig.me
```

