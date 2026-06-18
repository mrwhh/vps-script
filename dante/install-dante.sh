#!/usr/bin/env bash
set -e

PORT=""
SOCKS_USER=""
SOCKS_PASS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    --user)
      SOCKS_USER="$2"
      shift 2
      ;;
    --passwd)
      SOCKS_PASS="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [ -z "$PORT" ] || [ -z "$SOCKS_USER" ] || [ -z "$SOCKS_PASS" ]; then
  echo "Usage: $0 --port 20270 --user USER --passwd PASS"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if command -v systemctl >/dev/null 2>&1 && systemctl >/dev/null 2>&1; then
  SERVICE_MODE="systemd"
else
  SERVICE_MODE="service"
fi

IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
IFACE="${IFACE:-eth0}"

apt update
DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends dante-server curl ca-certificates

if id "$SOCKS_USER" >/dev/null 2>&1; then
  echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd
else
  useradd -M -s /usr/sbin/nologin "$SOCKS_USER"
  echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd
fi

cat >/etc/danted.conf <<EOF
logoutput: syslog

internal: 0.0.0.0 port = $PORT
external: $IFACE

socksmethod: username
clientmethod: none

user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect bind udpassociate
}
EOF


if [ "$SERVICE_MODE" = "systemd" ]; then
  # 解决 LXC 容器中由于 Mount Namespacing 等安全沙箱限制导致服务启动失败（status=226/NAMESPACE）的问题
  # 我们通过直接在 /etc/systemd/system/ 下重写一个精简且无沙箱安全指令的 danted.service 来彻底覆盖默认配置
  rm -rf /etc/systemd/system/danted.service.d 2>/dev/null || true
  
  cat >/etc/systemd/system/danted.service <<'EOF'
[Unit]
Description=SOCKS (v4 and v5) proxy daemon (danted)
Documentation=man:danted(8) man:danted.conf(5)
After=network.target

[Service]
Type=simple
PIDFile=/run/danted.pid
ExecStartPre=/bin/sh -c "uid=\`sed -n -e 's/[[:space:]]//g' -e 's/#.*//' -e '/^user.privileged/{s/[^:]*://p;q;}' /etc/danted.conf\`; if [ -n \"\$uid\" ]; then touch /run/danted.pid; chown \$uid /run/danted.pid; fi"
ExecStart=/usr/sbin/danted -D
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable danted
  systemctl restart danted
else
  service danted restart
fi

PUBLIC_IP=$(curl -s --max-time 8 https://ipinfo.io/ip 2>/dev/null | tr -d ' \n')
if [ -z "$PUBLIC_IP" ] || ! echo "$PUBLIC_IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  PUBLIC_IP=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \n')
fi
if [ -z "$PUBLIC_IP" ] || ! echo "$PUBLIC_IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  PUBLIC_IP="0.0.0.0"
fi

echo
echo "SOCKS5 installed successfully"
echo "Address : $PUBLIC_IP:$PORT"
echo "Listen  : 0.0.0.0:$PORT"
echo "User    : $SOCKS_USER"
echo "Pass    : $SOCKS_PASS"
echo "Iface   : $IFACE"
echo "Service : $SERVICE_MODE"
echo
echo "Test:"
echo "curl --socks5 $SOCKS_USER:$SOCKS_PASS@$PUBLIC_IP:$PORT https://ifconfig.me"