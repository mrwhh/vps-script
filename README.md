# 代理服务安装脚本集合

本目录收集了几个用于快速部署代理服务的 Shell 脚本，适合在 Linux 服务器或轻量容器中使用。脚本通常会安装软件包、写入系统配置、创建系统服务并启动服务，因此需要使用 `root` 用户或 `sudo` 执行。

## 目录说明

| 目录 | 脚本 | 用途 |
| --- | --- | --- |
| `xray/` | `install-xray.sh` | 在 Alpine/OpenRC 环境安装 Xray VLESS Reality，并支持多个 VLESS 客户端、多个 SOCKS 出站和按用户路由。 |
| `microsocks/` | `install-microsocks.sh` | 安装轻量 SOCKS5 服务 Microsocks，支持 Alpine、Debian/Ubuntu、Fedora/RHEL/CentOS 等常见环境。 |
| `dante/` | `install-dante.sh` | 在 Debian/Ubuntu 类系统安装 Dante SOCKS5 服务，并创建用户名密码认证。 |

## 快速使用

进入对应目录后运行脚本：

```sh
cd xray
sudo sh install-xray.sh --help

cd ../microsocks
sudo bash install-microsocks.sh --help

cd ../dante
sudo bash install-dante.sh --port 20270 --user proxyuser --passwd proxypass
```

每个子目录都有独立的 `README.md`，请先阅读对应说明，确认目标系统、参数格式和脚本会写入的系统文件。

## 注意事项

- 脚本会修改系统服务配置，建议先在测试服务器或容器中验证。
- 请在云厂商安全组、防火墙和系统防火墙中放行对应端口。
- 用户名、密码、UUID、Reality shortId 等敏感信息请自行妥善保存。
- 不建议把真实服务器密码、代理密码或私钥提交到公开仓库。

