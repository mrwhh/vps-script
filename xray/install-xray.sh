#!/bin/sh
# ============================================================
# Xray VLESS Reality installer for Alpine/OpenRC LXC
# Supports multiple VLESS clients, SOCKS outbounds and user routes.
#
# Example:
#   sh install-xray-vless-reality.sh \
#     --port 443 \
#     --server-name www.oracle.com,oracle.com \
#     --dest www.oracle.com:443 \
#     --socks hk:127.0.0.1:1080:hku:hkpass \
#     --socks jp:10.0.0.2:1080:jpu:jppass \
#     --client alice:auto:hk \
#     --client bob:auto:jp
# ============================================================

set -eu

XRAY_VERSION="${XRAY_VERSION:-latest}"
LISTEN="${LISTEN:-0.0.0.0}"
PORT="${PORT:-443}"
SERVER_NAMES="${SERVER_NAMES:-${SERVER_NAME:-www.oracle.com,oracle.com}}"
DEST="${DEST:-www.oracle.com:443}"
SHORT_ID="${SHORT_ID:-}"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/init.d/xray"
XRAY_BIN="${INSTALL_DIR}/xray"
CLIENTS_FILE="/tmp/xray-clients.$$"
SOCKS_FILE="/tmp/xray-socks.$$"
ROUTES_FILE="/tmp/xray-routes.$$"

: > "$CLIENTS_FILE"
: > "$SOCKS_FILE"
: > "$ROUTES_FILE"

cleanup() {
  rm -f "$CLIENTS_FILE" "$SOCKS_FILE" "$ROUTES_FILE"
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'EOF'
Usage:
  sh install-xray-vless-reality.sh [options]

Options:
  --port PORT                     VLESS Reality listen port. Default: 443
  --listen IP                     Listen address. Default: 0.0.0.0
  --server-name DOMAIN[,DOMAIN]   Reality SNI/serverNames. Default: www.oracle.com,oracle.com
  --dest HOST:PORT                Reality target. Default: www.oracle.com:443
  --short-id HEX                  Reality shortId. Default: random 8 bytes hex
  --version VERSION               Xray version, for example v25.6.8. Default: latest
  --socks TAG:HOST:PORT[:USER:PASS]
                                  Add a SOCKS outbound.
  --client EMAIL:UUID:OUTBOUND    Add a VLESS client and route it to OUTBOUND.
                                  Use UUID "auto" to generate one.
  --route EMAIL:OUTBOUND          Add or override a user route. Usually not needed
                                  when OUTBOUND is set in --client.
  -h, --help                      Show this help.

Examples:
  sh install-xray-vless-reality.sh \
    --port 443 \
    --server-name www.oracle.com,oracle.com \
    --dest www.oracle.com:443 \
    --socks hk:127.0.0.1:1080:user1:pass1 \
    --socks jp:10.0.0.2:1080:user2:pass2 \
    --client alice:auto:hk \
    --client bob:auto:jp

Client URI is printed after installation.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "please run as root"
}

download_file() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 15 --retry 3 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    die "curl or wget is required"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_string_array_csv() {
  csv="$1"
  first=1
  old_ifs="$IFS"
  IFS=,
  for item in $csv; do
    [ -n "$item" ] || continue
    if [ "$first" -eq 0 ]; then
      printf ', '
    fi
    first=0
    printf '"%s"' "$(json_escape "$item")"
  done
  IFS="$old_ifs"
}

valid_tag() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$'
}

valid_email() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.@+-]+$'
}

valid_hex() {
  printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]+$'
}

gen_uuid() {
  if command -v xray >/dev/null 2>&1; then
    xray uuid
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/'
  fi
}

gen_hex() {
  bytes="$1"
  od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

parse_client() {
  item="$1"
  fields="$(printf '%s' "$item" | awk -F: '{print NF}')"
  [ "$fields" -eq 3 ] || die "--client requires exactly EMAIL:UUID:OUTBOUND"
  email="$(printf '%s' "$item" | cut -d: -f1)"
  uuid="$(printf '%s' "$item" | cut -d: -f2)"
  outbound="$(printf '%s' "$item" | cut -d: -f3)"

  [ -n "$email" ] || die "--client requires EMAIL:UUID:OUTBOUND"
  [ -n "$uuid" ] || die "--client requires EMAIL:UUID:OUTBOUND"
  [ -n "$outbound" ] || die "--client requires EMAIL:UUID:OUTBOUND"
  valid_email "$email" || die "invalid client email: $email"
  valid_tag "$outbound" || die "invalid outbound tag in --client: $outbound"

  if [ "$uuid" = "auto" ]; then
    uuid="$(gen_uuid)"
  fi
  printf '%s' "$uuid" | grep -Eq '^[0-9a-fA-F-]{36}$' || die "invalid UUID for $email: $uuid"

  printf '%s|%s|%s\n' "$email" "$uuid" "$outbound" >> "$CLIENTS_FILE"
  printf '%s|%s\n' "$email" "$outbound" >> "$ROUTES_FILE"
}

parse_socks() {
  item="$1"
  fields="$(printf '%s' "$item" | awk -F: '{print NF}')"
  [ "$fields" -eq 3 ] || [ "$fields" -eq 5 ] || die "--socks requires TAG:HOST:PORT or TAG:HOST:PORT:USER:PASS"
  tag="$(printf '%s' "$item" | cut -d: -f1)"
  host="$(printf '%s' "$item" | cut -d: -f2)"
  port="$(printf '%s' "$item" | cut -d: -f3)"
  user="$(printf '%s' "$item" | cut -d: -f4)"
  pass="$(printf '%s' "$item" | cut -d: -f5)"

  [ -n "$tag" ] || die "--socks requires TAG:HOST:PORT[:USER:PASS]"
  [ -n "$host" ] || die "--socks requires TAG:HOST:PORT[:USER:PASS]"
  [ -n "$port" ] || die "--socks requires TAG:HOST:PORT[:USER:PASS]"
  valid_tag "$tag" || die "invalid socks tag: $tag"
  printf '%s' "$port" | grep -Eq '^[0-9]+$' || die "invalid socks port for $tag: $port"

  printf '%s|%s|%s|%s|%s\n' "$tag" "$host" "$port" "$user" "$pass" >> "$SOCKS_FILE"
}

parse_route() {
  item="$1"
  fields="$(printf '%s' "$item" | awk -F: '{print NF}')"
  [ "$fields" -eq 2 ] || die "--route requires exactly EMAIL:OUTBOUND"
  email="$(printf '%s' "$item" | cut -d: -f1)"
  outbound="$(printf '%s' "$item" | cut -d: -f2)"

  [ -n "$email" ] || die "--route requires EMAIL:OUTBOUND"
  [ -n "$outbound" ] || die "--route requires EMAIL:OUTBOUND"
  valid_email "$email" || die "invalid route email: $email"
  valid_tag "$outbound" || die "invalid route outbound: $outbound"

  printf '%s|%s\n' "$email" "$outbound" >> "$ROUTES_FILE"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    --listen)
      LISTEN="$2"
      shift 2
      ;;
    --server-name|--sni)
      SERVER_NAMES="$2"
      shift 2
      ;;
    --dest)
      DEST="$2"
      shift 2
      ;;
    --short-id)
      SHORT_ID="$2"
      shift 2
      ;;
    --version)
      XRAY_VERSION="$2"
      shift 2
      ;;
    --client)
      parse_client "$2"
      shift 2
      ;;
    --socks)
      parse_socks "$2"
      shift 2
      ;;
    --route)
      parse_route "$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

need_root

printf '%s' "$PORT" | grep -Eq '^[0-9]+$' || die "invalid listen port: $PORT"
[ -n "$SERVER_NAMES" ] || die "at least one server name is required"
[ -s "$CLIENTS_FILE" ] || die "at least one --client is required"
[ -s "$SOCKS_FILE" ] || die "at least one --socks outbound is required"

if [ -n "$SHORT_ID" ]; then
  valid_hex "$SHORT_ID" || die "short-id must be hex"
else
  SHORT_ID="$(gen_hex 8)"
fi

echo "Installing dependencies..."
if command -v apk >/dev/null 2>&1; then
  apk add --no-cache ca-certificates curl unzip
else
  die "this script is intended for Alpine Linux with apk"
fi

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) xray_arch="64" ;;
  aarch64|arm64) xray_arch="arm64-v8a" ;;
  armv7l) xray_arch="arm32-v7a" ;;
  *) die "unsupported architecture: $arch" ;;
esac

if [ "$XRAY_VERSION" = "latest" ]; then
  release_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${xray_arch}.zip"
else
  release_url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${xray_arch}.zip"
fi

tmpdir="$(mktemp -d)"
zipfile="${tmpdir}/xray.zip"
echo "Downloading Xray (${XRAY_VERSION}, ${xray_arch})..."
download_file "$release_url" "$zipfile"

echo "Installing Xray binary..."
unzip -q "$zipfile" -d "$tmpdir"
install -m 755 "${tmpdir}/xray" "$XRAY_BIN"
mkdir -p "$CONFIG_DIR" /var/log/xray
rm -rf "$tmpdir"

echo "Generating Reality key pair..."
key_output="$("$XRAY_BIN" x25519)"
PRIVATE_KEY="$(printf '%s\n' "$key_output" | awk -F': ' '/Private key:/ {print $2}')"
PUBLIC_KEY="$(printf '%s\n' "$key_output" | awk -F': ' '/Public key:/ {print $2}')"
[ -n "$PRIVATE_KEY" ] || die "failed to generate Reality private key"
[ -n "$PUBLIC_KEY" ] || die "failed to generate Reality public key"

echo "Writing Xray config..."
{
  cat <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "$(json_escape "$LISTEN")",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
EOF

  first=1
  while IFS='|' read -r email uuid outbound; do
    [ -n "$email" ] || continue
    if [ "$first" -eq 0 ]; then
      printf ',\n'
    fi
    first=0
    printf '          { "id": "%s", "email": "%s", "flow": "xtls-rprx-vision" }' \
      "$(json_escape "$uuid")" "$(json_escape "$email")"
  done < "$CLIENTS_FILE"

  cat <<EOF

        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$(json_escape "$DEST")",
          "xver": 0,
          "serverNames": [ $(json_string_array_csv "$SERVER_NAMES") ],
          "privateKey": "$(json_escape "$PRIVATE_KEY")",
          "shortIds": [ "$(json_escape "$SHORT_ID")" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
  ],
  "outbounds": [
EOF

  first=1
  while IFS='|' read -r tag host sport user pass; do
    [ -n "$tag" ] || continue
    if [ "$first" -eq 0 ]; then
      printf ',\n'
    fi
    first=0
    cat <<EOF
    {
      "tag": "$(json_escape "$tag")",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "$(json_escape "$host")",
            "port": $sport
EOF
    if [ -n "$user" ]; then
      cat <<EOF
            ,
            "users": [
              { "user": "$(json_escape "$user")", "pass": "$(json_escape "$pass")" }
            ]
EOF
    fi
    cat <<EOF
          }
        ]
      }
    }
EOF
  done < "$SOCKS_FILE"

  cat <<EOF
    ,
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
EOF

  first=1
  awk -F'|' 'NF >= 2 && $1 != "" { route[$1]=$2 } END { for (email in route) print email "|" route[email] }' "$ROUTES_FILE" |
  while IFS='|' read -r email outbound; do
    [ -n "$email" ] || continue
    if [ "$first" -eq 0 ]; then
      printf ',\n'
    fi
    first=0
    cat <<EOF
      {
        "type": "field",
        "inboundTag": [ "vless-reality" ],
        "user": [ "$(json_escape "$email")" ],
        "outboundTag": "$(json_escape "$outbound")"
      }
EOF
  done

  cat <<EOF
      ,
      {
        "type": "field",
        "protocol": [ "bittorrent" ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
} > "$CONFIG_FILE"

echo "Validating Xray config..."
"$XRAY_BIN" test -config "$CONFIG_FILE"

echo "Creating OpenRC service..."
cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="xray"
description="Xray proxy service"
command="${XRAY_BIN}"
command_args="run -config ${CONFIG_FILE}"
command_background=true
pidfile="/run/xray.pid"
output_log="/var/log/xray/xray.log"
error_log="/var/log/xray/xray.log"

depend() {
    need net
}

start_pre() {
    checkpath --directory --mode 0755 /run
    checkpath --directory --mode 0755 /var/log/xray
}
EOF

chmod +x "$SERVICE_FILE"
rc-update add xray default >/dev/null 2>&1 || true
rc-service xray restart

public_ip="$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \n' || true)"
[ -n "$public_ip" ] || public_ip="SERVER_IP"
primary_sni="$(printf '%s' "$SERVER_NAMES" | cut -d, -f1)"

echo
echo "Xray VLESS Reality installed."
echo "Listen      : ${LISTEN}:${PORT}"
echo "SNI         : ${SERVER_NAMES}"
echo "Dest        : ${DEST}"
echo "Public key  : ${PUBLIC_KEY}"
echo "Short ID    : ${SHORT_ID}"
echo "Config      : ${CONFIG_FILE}"
echo "Service     : OpenRC xray"
echo
echo "Clients:"
while IFS='|' read -r email uuid outbound; do
  [ -n "$email" ] || continue
  uri="vless://${uuid}@${public_ip}:${PORT}?encryption=none&security=reality&sni=${primary_sni}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${email}"
  echo "- ${email} -> ${outbound}"
  echo "  ${uri}"
done < "$CLIENTS_FILE"
echo
echo "Useful commands:"
echo "  rc-service xray status"
echo "  xray test -config ${CONFIG_FILE}"
