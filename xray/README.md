# Alpine LXC 安装 Xray VLESS Reality

`install-xray.sh` 适用于 Alpine/OpenRC LXC 容器，用于一键安装 Xray VLESS Reality。目标环境可以是 128 MB 内存左右的轻量容器。

## 功能

- 从 Xray 官方 GitHub Release 下载并安装 Xray core。
- 创建 OpenRC 服务，适配 Alpine/LXC 环境。
- 自动生成 VLESS Reality 所需的 x25519 密钥和 shortId。
- 支持多个 VLESS 客户端。
- 支持多个 SOCKS 出站。
- 支持按 VLESS 客户端 email 将不同客户端路由到不同出站。
- 阻断 BitTorrent 流量，降低代理被滥用风险。

## 支持环境

- Alpine Linux
- OpenRC
- 支持 `apk` 包管理器
- 支持架构：`x86_64`、`aarch64/arm64`、`armv7l`

脚本需要 `root` 权限，并会安装 `ca-certificates`、`curl`、`unzip`。

## 使用方式

查看帮助：

```sh
sudo sh install-xray.sh --help
```

示例：创建两个 VLESS 客户端，并分别路由到不同 SOCKS 出站：

```sh
sudo sh install-xray.sh \
  --port 443 \
  --server-name www.oracle.com,oracle.com \
  --dest www.oracle.com:443 \
  --socks hk:127.0.0.1:1080:user1:pass1 \
  --socks jp:10.0.0.2:1080:user2:pass2 \
  --client alice:auto:hk \
  --client bob:auto:jp
```

如果需要固定 Xray 版本，避免每次安装取到不同版本：

```sh
sudo sh install-xray.sh --version v25.6.8 ...
```

安装完成后，脚本会输出每个客户端的 VLESS Reality URI。将 URI 导入支持 VLESS Reality 的客户端即可使用。

## 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--port PORT` | VLESS Reality 入站监听端口。 | `443` |
| `--listen IP` | 监听地址。 | `0.0.0.0` |
| `--server-name DOMAIN[,DOMAIN]`、`--sni DOMAIN[,DOMAIN]` | Reality SNI/serverNames，可用英文逗号填写多个。 | `www.oracle.com,oracle.com` |
| `--dest HOST:PORT` | Reality 回落目标，通常与 `--server-name` 对应。 | `www.oracle.com:443` |
| `--short-id HEX` | Reality shortId，必须是十六进制字符串。 | 随机 8 字节十六进制 |
| `--version VERSION` | Xray 版本，例如 `v25.6.8`。 | `latest` |
| `--socks TAG:HOST:PORT[:USER:PASS]` | 添加一个 SOCKS 出站，`TAG` 用于路由引用；用户名密码可省略。 | 必填，至少一个 |
| `--client EMAIL:UUID:OUTBOUND` | 添加 VLESS 客户端，并将该客户端路由到指定出站；`UUID` 可写 `auto` 自动生成。 | 必填，至少一个 |
| `--route EMAIL:OUTBOUND` | 添加或覆盖某个客户端的路由规则。通常 `--client` 中已指定出站时不需要额外填写。 | 无 |
| `-h`、`--help` | 显示帮助信息。 | 无 |

## 参数格式

SOCKS 出站格式：

```text
TAG:HOST:PORT
TAG:HOST:PORT:USER:PASS
```

客户端格式：

```text
EMAIL:UUID:OUTBOUND
```

- `EMAIL` 用于 Xray 用户标识和路由匹配，只允许字母、数字、下划线、点、`@`、`+`、`-`。
- `UUID` 可以填写已有 UUID，也可以填写 `auto` 自动生成。
- `OUTBOUND` 必须对应某个 `--socks` 的 `TAG`。

## 配置结果

脚本会写入：

- Xray 二进制：`/usr/local/bin/xray`
- Xray 配置：`/usr/local/etc/xray/config.json`
- OpenRC 服务：`/etc/init.d/xray`
- 日志目录：`/var/log/xray`

常用命令：

```sh
rc-service xray status
rc-service xray restart
xray test -config /usr/local/etc/xray/config.json
```

如果服务器安全组或系统防火墙未放行 `--port` 指定的端口，客户端将无法连接。

