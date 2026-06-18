#!/bin/bash
# =============================================
# Microsocks 一键安装 SOCKS5 代理脚本 - 支持 Alpine
# 用法: ./install-microsocks.sh [--port PORT] [--user USERNAME] [--passwd PASSWORD]
# =============================================

set -e

# 默认值
PORT=""
USERNAME=""
PASSWORD=""
BIND_IP="0.0.0.0"
STATIC_VERSION="1.0.2"
STATIC_ARCHIVE="microsocks-${STATIC_VERSION}-x86_64-static.xz"
STATIC_URL="https://github.com/rofl0r/microsocks/releases/download/v${STATIC_VERSION}/${STATIC_ARCHIVE}"
STATIC_SHA512="168e181b3a3fed3e40b994249270bfc6c8ee30b18922e1ce4ba2361730292f9923cb54a81e0efc0306f49c8e943cdf4b12c51ff9de35249f2c17f8e549c9cc2f"
INSTALL_BIN="/usr/local/bin/microsocks"

# ============== 参数解析 ==============
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        --user|--username)
            USERNAME="$2"
            shift 2
            ;;
        --passwd|--password|--pass)
            PASSWORD="$2"
            shift 2
            ;;
        --bind|--ip)
            BIND_IP="$2"
            shift 2
            ;;
        -h|--help)
            echo "用法: $0 [选项]"
            echo "  --port <端口>          (默认: 随机 20000-59999)"
            echo "  --user <用户名>        (默认: 随机生成)"
            echo "  --passwd <密码>        (默认: 随机强密码)"
            echo "  --bind <绑定IP>        (默认: 0.0.0.0)"
            echo "  -h, --help             显示此帮助"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

# 生成随机默认值
if [ -z "$PORT" ]; then
    PORT=$((20000 + RANDOM % 40000))
fi

if [ -z "$USERNAME" ]; then
    USERNAME="user$(head -c 4 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 6)"
fi

if [ -z "$PASSWORD" ]; then
    PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
fi

echo "=== Microsocks SOCKS5 一键安装脚本 ==="
echo "端口: $PORT"
echo "用户: $USERNAME"
echo "绑定IP: $BIND_IP"

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 或 sudo 运行此脚本"
    exit 1
fi

# ============== 包管理器检测与安装 ==============
IS_ALPINE=false
if command -v apk >/dev/null 2>&1; then
    IS_ALPINE=true
fi

download_file() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 10 --retry 3 -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$output" "$url"
    else
        echo "错误：未找到 curl 或 wget，无法下载预编译二进制文件。"
        return 1
    fi
}

ensure_fallback_tools() {
    if command -v xz >/dev/null 2>&1 && command -v sha512sum >/dev/null 2>&1; then
        return 0
    fi

    echo "安装下载和解压所需的小依赖..."
    if [ "$IS_ALPINE" = true ]; then
        apk add --no-cache curl ca-certificates xz
    elif command -v apt >/dev/null 2>&1; then
        apt update
        apt install -y --no-install-recommends curl ca-certificates xz-utils
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates xz
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates xz
    fi
}

install_static_microsocks() {
    local arch
    local tmpdir
    local archive_path
    local bin_path

    arch="$(uname -m)"
    if [ "$arch" != "x86_64" ]; then
        echo "错误：当前架构为 ${arch}，脚本内置的预编译 Microsocks 仅支持 x86_64。"
        echo "请在其它机器为 ${arch} 编译静态二进制后，放到 ${INSTALL_BIN} 再重新运行。"
        return 1
    fi

    ensure_fallback_tools

    if ! command -v xz >/dev/null 2>&1; then
        echo "错误：未找到 xz，无法解压预编译二进制文件。"
        return 1
    fi

    if ! command -v sha512sum >/dev/null 2>&1; then
        echo "错误：未找到 sha512sum，无法校验预编译二进制文件。"
        return 1
    fi

    tmpdir="$(mktemp -d)"
    archive_path="${tmpdir}/${STATIC_ARCHIVE}"
    bin_path="${tmpdir}/microsocks"

    echo "下载 Microsocks x86_64 静态二进制..."
    download_file "$STATIC_URL" "$archive_path"

    echo "${STATIC_SHA512}  ${archive_path}" | sha512sum -c -

    echo "安装 Microsocks 到 ${INSTALL_BIN}..."
    xz -dc "$archive_path" > "$bin_path"
    chmod 755 "$bin_path"
    mkdir -p "$(dirname "$INSTALL_BIN")"
    mv "$bin_path" "$INSTALL_BIN"
    rm -rf "$tmpdir"
}

# 1. 优先尝试通过系统包管理器直接安装 microsocks (极低内存与磁盘占用)
echo "尝试直接通过系统包管理器安装 Microsocks..."
INSTALLED_VIA_PKG=false

if [ "$IS_ALPINE" = true ]; then
    apk update
    if apk add --no-cache microsocks curl ca-certificates xz; then
        INSTALLED_VIA_PKG=true
    fi
elif command -v apt >/dev/null 2>&1; then
    apt update
    # Debian/Ubuntu 官方源包含 microsocks
    if apt install -y --no-install-recommends microsocks curl ca-certificates xz-utils; then
        INSTALLED_VIA_PKG=true
    fi
elif command -v dnf >/dev/null 2>&1; then
    # RedHat/Fedora 尝试直接安装
    if dnf install -y microsocks curl ca-certificates xz; then
        INSTALLED_VIA_PKG=true
    fi
elif command -v yum >/dev/null 2>&1; then
    # CentOS/RHEL 尝试直接安装
    if yum install -y microsocks curl ca-certificates xz; then
        INSTALLED_VIA_PKG=true
    fi
fi

# 2. 检查安装结果
if ! command -v microsocks >/dev/null 2>&1; then
    echo "未能通过系统包管理器安装 microsocks，尝试使用预编译静态二进制文件..."
    install_static_microsocks
else
    echo "Microsocks 已通过系统包管理器成功安装或已存在于系统中"
fi

# 3. 动态获取 microsocks 最终的可执行文件路径
MICROSOCKS_BIN=$(command -v microsocks || echo "/usr/local/bin/microsocks")
echo "Microsocks 可执行文件路径: ${MICROSOCKS_BIN}"

# ============== 创建服务 ==============
echo "创建服务..."

if [ "$IS_ALPINE" = true ] || ! command -v systemctl >/dev/null 2>&1; then
    # ==================== OpenRC (Alpine) ====================
    echo "检测到 OpenRC 系统，使用 OpenRC 服务"
    cat > /etc/init.d/microsocks <<EOF
#!/sbin/openrc-run

name="microsocks"
command="${MICROSOCKS_BIN}"
command_args="-i ${BIND_IP} -p ${PORT} -u ${USERNAME} -P ${PASSWORD}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
}

start_pre() {
    checkpath --directory --owner nobody /run
}
EOF

    chmod +x /etc/init.d/microsocks
    rc-update add microsocks default
    rc-service microsocks restart

else
    # ==================== systemd ====================
    cat > /etc/systemd/system/microsocks.service <<EOF
[Unit]
Description=Microsocks Lightweight SOCKS5 Proxy
After=network.target

[Service]
Type=simple
ExecStart=${MICROSOCKS_BIN} -i ${BIND_IP} -p ${PORT} -u ${USERNAME} -P ${PASSWORD}
Restart=always
RestartSec=3
User=nobody
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now microsocks
fi

# 防火墙
if command -v ufw >/dev/null 2>&1; then
    ufw allow ${PORT}/tcp
elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=${PORT}/tcp
    firewall-cmd --reload
elif command -v rc-service >/dev/null 2>&1 && command -v iptables >/dev/null 2>&1; then
    iptables -A INPUT -p tcp --dport ${PORT} -j ACCEPT
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

# 获取公网 IP
PUBLIC_IP=$(curl -s --max-time 8 https://ipinfo.io/ip 2>/dev/null | tr -d ' \n')
if [ -z "$PUBLIC_IP" ] || [[ ! $PUBLIC_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    PUBLIC_IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \n')
fi
[ -z "$PUBLIC_IP" ] && PUBLIC_IP="无法自动获取"

echo ""
echo "安装完成！"
echo "========================================"
echo "SOCKS5 地址 : ${PUBLIC_IP}:${PORT}"
echo "用户名      : ${USERNAME}"
echo "密码        : ${PASSWORD}"
echo ""
echo "完整连接字符串："
echo "socks5://${USERNAME}:${PASSWORD}@${PUBLIC_IP}:${PORT}"
echo ""
echo "管理命令："
if [ "$IS_ALPINE" = true ] || ! command -v systemctl >/dev/null 2>&1; then
    echo "  rc-service microsocks status"
    echo "  rc-service microsocks restart"
    echo "  rc-service microsocks stop"
else
    echo "  systemctl status microsocks"
    echo "  systemctl restart microsocks"
fi
echo "========================================"

# 显示服务状态
if [ "$IS_ALPINE" = true ] || ! command -v systemctl >/dev/null 2>&1; then
    rc-service microsocks status
else
    systemctl status microsocks --no-pager -l
fi
