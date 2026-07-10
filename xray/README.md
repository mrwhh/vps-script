# Alpine LXC 安装 Xray-core

`install.sh` 将两种安装方式合并为同一个入口：

1. 同目录存在 `config.json` 时，校验并部署该配置，不进入交互。
2. 同目录不存在 `config.json` 时，通过交互引导生成 VLESS Reality 配置。
3. 无配置文件但传入生成参数时，以非交互方式生成配置，适合自动化部署。

脚本仅支持 Alpine Linux 和 OpenRC，需要使用 root 用户运行。Xray 内核、配置、
数据文件和日志统一安装到 `/opt/xray/`。

## 直接使用 config.json

项目目录：[github.com/mrwhh/vps-script/tree/main/xray](https://github.com/mrwhh/vps-script/tree/main/xray)。

在 VPS 上可以先进入 `config.json` 所在目录，再通过 `curl` 或 `wget` 下载脚本：

```sh
mkdir -p /opt/xray && cd /opt/xray
curl -fL -o install.sh https://raw.githubusercontent.com/mrwhh/vps-script/main/xray/install.sh
# 或：wget -O install.sh https://raw.githubusercontent.com/mrwhh/vps-script/main/xray/install.sh
chmod +x install.sh
./install.sh
```

如果配置文件还没有上传，可以先创建目录并上传自己的 `config.json`，再执行上面的
下载命令。脚本和 `config.json` 必须位于同一目录，脚本才会自动进入配置文件模式。

也可以直接使用本地脚本：

```sh
chmod +x install.sh
./install.sh
```

也可以显式指定其他配置文件：

```sh
./install.sh --config /opt/xray/config.json
```

配置文件模式会先使用刚下载的 Xray 内核校验配置，校验成功后才会部署。已有配置
发生变化时会备份为 `/opt/xray/config.json.bak`。

## 交互生成配置

确认脚本同目录没有 `config.json`，直接运行：

```sh
./install.sh
```

脚本会依次询问监听地址、端口、Reality 域名和目标地址，并引导添加 SOCKS 出站
及 VLESS 客户端。UUID、Reality 密钥和 shortId 均可自动生成。安装完成后会输出
每个客户端的 VLESS URI。

## 使用参数生成配置

生成模式保留了旧脚本的多客户端、多端口、SOCKS 出站和按用户路由能力。以下示例
使用项目规定的占位地址和凭据：

```sh
./install.sh \
  --server-name www.example.com,example.com \
  --dest www.example.com:443 \
  --socks proxy:10.0.0.1:1080:admin:admin \
  --client admin:auto:proxy:443
```

添加默认走直连的客户端：

```sh
./install.sh --vless admin:auto:443
```

如果客户端参数和 `--port` 都没有指定端口，脚本会从 `10000-50000` 中随机分配。
完整参数请运行：

```sh
./install.sh --help
```

> 同目录已有 `config.json` 时不能使用配置生成参数，避免误覆盖现有配置。请先移走
> 配置文件，或直接使用配置文件模式。

## 版本和服务启动

固定 Xray 版本：

```sh
./install.sh --version v26.3.27
```

仅安装、不立即启动：

```sh
./install.sh --no-start
```

仍然兼容环境变量：

```sh
XRAY_VERSION=v26.3.27 XRAY_START_SERVICE=0 ./install.sh
```

## 安装结果

- Xray 内核：`/opt/xray/bin/xray`
- Xray 配置：`/opt/xray/config.json`
- Geo 数据：`/opt/xray/share/`
- 日志目录：`/opt/xray/log/`
- OpenRC 服务：`/etc/init.d/xray`

常用管理命令：

```sh
rc-service xray status
rc-service xray restart
rc-service xray stop
/opt/xray/bin/xray run -test -config /opt/xray/config.json
```

部署配置的权限为 `600`。请勿将含有 Reality 私钥、UUID 或上游代理凭据的
`config.json` 提交到仓库。
