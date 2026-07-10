#!/bin/sh

# Xray-core installer for Alpine/OpenRC.
# An adjacent config.json is deployed as-is. If it is absent, a VLESS Reality
# configuration can be generated interactively or from command-line options.

set -eu

readonly REPOSITORY="XTLS/Xray-core"
readonly XRAY_HOME="/opt/xray"
readonly INSTALL_DIR="${XRAY_HOME}/bin"
readonly CONFIG_DIR="${XRAY_HOME}"
readonly DATA_DIR="${XRAY_HOME}/share"
readonly LOG_DIR="${XRAY_HOME}/log"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly XRAY_BIN="${INSTALL_DIR}/xray"
readonly SERVICE_FILE="/etc/init.d/xray"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEFAULT_CONFIG_SOURCE="${SCRIPT_DIR}/config.json"
CONFIG_SOURCE=${XRAY_CONFIG:-${DEFAULT_CONFIG_SOURCE}}
CONFIG_EXPLICIT=0
[ -z "${XRAY_CONFIG+x}" ] || CONFIG_EXPLICIT=1

START_SERVICE=${XRAY_START_SERVICE:-1}
VERSION_REQUEST=${XRAY_VERSION:-latest}
LISTEN=${LISTEN:-0.0.0.0}
PORT=${PORT:-}
SERVER_NAMES=${SERVER_NAMES:-${SERVER_NAME:-www.example.com,example.com}}
DEST=${DEST:-www.example.com:443}
SHORT_ID=${SHORT_ID:-}
GENERATION_OPTIONS=0
MODE=""
TMP_DIR=""
CLIENTS_FILE=""
SOCKS_FILE=""
ROUTES_FILE=""
ROUTES_RENDER_FILE=""
PRIVATE_KEY=""
PUBLIC_KEY=""

info() {
    printf '%s\n' "[xray] $*"
}

fatal() {
    printf '%s\n' "[xray] ERROR: $*" >&2
    exit 1
}

cleanup() {
    if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
        rm -rf -- "${TMP_DIR}"
    fi
}

trap cleanup EXIT HUP INT TERM

usage() {
    cat <<'EOF'
用法：
  ./install.sh [选项]

运行模式：
  同目录存在 config.json 时，直接校验、部署并运行该配置。
  同目录不存在 config.json 时，无生成参数则进入交互引导；有生成参数则自动生成配置。

通用选项：
  --config FILE                  使用指定的 config.json
  --version VERSION              Xray 版本，例如 v26.3.27；默认 latest
  --no-start                     安装后不启动服务
  -h, --help                     显示帮助

生成模式选项（仅在没有 config.json 时使用）：
  --port PORT                    VLESS 默认监听端口；省略时为客户端随机分配
  --listen IP                    监听地址；默认 0.0.0.0
  --server-name DOMAIN[,DOMAIN]  Reality serverNames
  --dest HOST:PORT               Reality 目标地址
  --short-id HEX                 Reality shortId；默认随机生成
  --socks TAG:HOST:PORT[:USER:PASS]
                                 添加 SOCKS 出站
  --client EMAIL:UUID:OUTBOUND[:PORT]
                                 添加 VLESS 客户端及其出站；UUID 可写 auto
  --vless EMAIL:UUID[:PORT]      添加默认走 direct 的 VLESS 客户端
  --route EMAIL:OUTBOUND         覆盖客户端的出站规则

示例（项目示例统一使用占位信息）：
  ./install.sh --socks proxy:10.0.0.1:1080:admin:admin \
    --client admin:auto:proxy:443
EOF
}

require_value() {
    [ "$#" -ge 2 ] && [ -n "$2" ] || fatal "$1 缺少参数值"
}

valid_port() {
    printf '%s' "$1" | grep -Eq '^[0-9]+$' || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_tag() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+$'
}

valid_email() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.@+-]+$'
}

valid_record_field() {
    case "$1" in
        *'|'*) return 1 ;;
    esac
    ! printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

valid_server_names() {
    printf '%s' "$1" |
        grep -Eq '^([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+(,([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+)*$'
}

valid_uuid() {
    printf '%s' "$1" | grep -Eqi '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

valid_short_id() {
    value=$1
    printf '%s' "${value}" | grep -Eq '^[0-9a-fA-F]+$' || return 1
    [ "${#value}" -le 16 ] || return 1
    [ $(( ${#value} % 2 )) -eq 0 ]
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

json_string_array_csv() {
    csv=$1
    first=1
    old_ifs=$IFS
    IFS=,
    for item in ${csv}; do
        [ -n "${item}" ] || continue
        if [ "${first}" -eq 0 ]; then
            printf ', '
        fi
        first=0
        printf '"%s"' "$(json_escape "${item}")"
    done
    IFS=$old_ifs
}

gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n' |
            sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/'
    fi
}

gen_hex() {
    od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

gen_port() {
    number=$(od -An -N2 -tu2 /dev/urandom | tr -d ' \n')
    printf '%s\n' "$((10000 + number % 40001))"
}

parse_client() {
    item=$1
    fields=$(printf '%s' "${item}" | awk -F: '{ print NF }')
    [ "${fields}" -eq 3 ] || [ "${fields}" -eq 4 ] ||
        fatal "--client 格式应为 EMAIL:UUID:OUTBOUND[:PORT]"

    email=$(printf '%s' "${item}" | cut -d: -f1)
    uuid=$(printf '%s' "${item}" | cut -d: -f2)
    outbound=$(printf '%s' "${item}" | cut -d: -f3)
    client_port=$(printf '%s' "${item}" | cut -d: -f4)

    valid_email "${email}" || fatal "客户端标识无效：${email}"
    valid_tag "${outbound}" || fatal "客户端 ${email} 的出站标签无效"
    [ -z "${client_port}" ] || valid_port "${client_port}" || fatal "客户端 ${email} 的端口无效"
    if [ "${uuid}" = "auto" ]; then
        uuid=$(gen_uuid)
    fi
    valid_uuid "${uuid}" || fatal "客户端 ${email} 的 UUID 无效"
    ! awk -F'|' -v email="${email}" '$1 == email { found=1 } END { exit found ? 0 : 1 }' "${CLIENTS_FILE}" ||
        fatal "客户端标识重复：${email}"

    printf '%s|%s|%s|%s\n' "${email}" "${uuid}" "${outbound}" "${client_port}" >>"${CLIENTS_FILE}"
    printf '%s|%s\n' "${email}" "${outbound}" >>"${ROUTES_FILE}"
}

parse_vless() {
    item=$1
    fields=$(printf '%s' "${item}" | awk -F: '{ print NF }')
    [ "${fields}" -eq 2 ] || [ "${fields}" -eq 3 ] || fatal "--vless 格式应为 EMAIL:UUID[:PORT]"
    email=$(printf '%s' "${item}" | cut -d: -f1)
    uuid=$(printf '%s' "${item}" | cut -d: -f2)
    client_port=$(printf '%s' "${item}" | cut -d: -f3)
    parse_client "${email}:${uuid}:direct:${client_port}"
}

parse_socks() {
    item=$1
    fields=$(printf '%s' "${item}" | awk -F: '{ print NF }')
    [ "${fields}" -eq 3 ] || [ "${fields}" -eq 5 ] ||
        fatal "--socks 格式应为 TAG:HOST:PORT 或 TAG:HOST:PORT:USER:PASS"

    tag=$(printf '%s' "${item}" | cut -d: -f1)
    host=$(printf '%s' "${item}" | cut -d: -f2)
    socks_port=$(printf '%s' "${item}" | cut -d: -f3)
    user=$(printf '%s' "${item}" | cut -d: -f4)
    password=$(printf '%s' "${item}" | cut -d: -f5)

    valid_tag "${tag}" || fatal "SOCKS 标签无效：${tag}"
    [ -n "${host}" ] || fatal "SOCKS ${tag} 缺少地址"
    valid_record_field "${host}" || fatal "SOCKS ${tag} 的地址包含不支持的字符"
    valid_port "${socks_port}" || fatal "SOCKS ${tag} 的端口无效"
    [ -z "${user}" ] || [ -n "${password}" ] || fatal "SOCKS ${tag} 缺少密码"
    valid_record_field "${user}" && valid_record_field "${password}" ||
        fatal "SOCKS ${tag} 的凭据包含不支持的字符"
    ! awk -F'|' -v tag="${tag}" '$1 == tag { found=1 } END { exit found ? 0 : 1 }' "${SOCKS_FILE}" ||
        fatal "SOCKS 标签重复：${tag}"

    printf '%s|%s|%s|%s|%s\n' "${tag}" "${host}" "${socks_port}" "${user}" "${password}" >>"${SOCKS_FILE}"
}

parse_route() {
    item=$1
    fields=$(printf '%s' "${item}" | awk -F: '{ print NF }')
    [ "${fields}" -eq 2 ] || fatal "--route 格式应为 EMAIL:OUTBOUND"
    email=$(printf '%s' "${item}" | cut -d: -f1)
    outbound=$(printf '%s' "${item}" | cut -d: -f2)
    valid_email "${email}" || fatal "路由客户端标识无效：${email}"
    valid_tag "${outbound}" || fatal "路由出站标签无效：${outbound}"
    printf '%s|%s\n' "${email}" "${outbound}" >>"${ROUTES_FILE}"
}

prompt_default() {
    prompt=$1
    default_value=$2
    if [ -n "${default_value}" ]; then
        printf '%s' "${prompt} [${default_value}]: " >&2
    else
        printf '%s' "${prompt}: " >&2
    fi
    IFS= read -r answer || fatal "交互输入已结束"
    printf '%s\n' "${answer:-${default_value}}"
}

prompt_yes_no() {
    prompt=$1
    default_answer=$2
    while :; do
        if [ "${default_answer}" = "y" ]; then
            answer=$(prompt_default "${prompt} (Y/n)" "y")
        else
            answer=$(prompt_default "${prompt} (y/N)" "n")
        fi
        case "${answer}" in
            y | Y | yes | YES) return 0 ;;
            n | N | no | NO) return 1 ;;
            *) printf '%s\n' "请输入 y 或 n。" >&2 ;;
        esac
    done
}

interactive_config() {
    info "未找到 config.json，进入交互配置"
    LISTEN=$(prompt_default "监听地址" "${LISTEN}")
    PORT=$(prompt_default "默认 VLESS 端口" "443")
    valid_port "${PORT}" || fatal "VLESS 端口无效：${PORT}"
    SERVER_NAMES=$(prompt_default "Reality 域名，多个用逗号分隔" "${SERVER_NAMES}")
    primary_name=$(printf '%s' "${SERVER_NAMES}" | cut -d, -f1)
    DEST=$(prompt_default "Reality 目标地址" "${primary_name}:443")
    SHORT_ID=$(prompt_default "Reality shortId（留空自动生成）" "")

    while prompt_yes_no "是否添加 SOCKS 出站" "n"; do
        tag=$(prompt_default "SOCKS 标签" "proxy")
        host=$(prompt_default "SOCKS 地址" "10.0.0.1")
        socks_port=$(prompt_default "SOCKS 端口" "1080")
        user=$(prompt_default "SOCKS 用户名（留空表示无认证）" "admin")
        if [ -n "${user}" ]; then
            password=$(prompt_default "SOCKS 密码" "admin")
            parse_socks "${tag}:${host}:${socks_port}:${user}:${password}"
        else
            parse_socks "${tag}:${host}:${socks_port}"
        fi
    done

    another=y
    client_index=1
    while [ "${another}" = "y" ]; do
        if [ "${client_index}" -eq 1 ]; then
            default_email=admin
        else
            default_email="admin${client_index}"
        fi
        email=$(prompt_default "客户端标识" "${default_email}")
        uuid=$(prompt_default "客户端 UUID（auto 表示自动生成）" "auto")
        client_port=$(prompt_default "客户端端口" "${PORT}")
        outbound=$(prompt_default "出站标签（direct、block 或 SOCKS 标签）" "direct")
        parse_client "${email}:${uuid}:${outbound}:${client_port}"
        client_index=$((client_index + 1))
        if prompt_yes_no "是否继续添加客户端" "n"; then
            another=y
        else
            another=n
        fi
    done
}

outbound_exists() {
    tag=$1
    [ "${tag}" = "direct" ] || [ "${tag}" = "block" ] ||
        awk -F'|' -v tag="${tag}" '$1 == tag { found=1 } END { exit found ? 0 : 1 }' "${SOCKS_FILE}"
}

normalize_and_validate_generation() {
    [ -z "${PORT}" ] || valid_port "${PORT}" || fatal "默认监听端口无效：${PORT}"
    valid_record_field "${LISTEN}" || fatal "监听地址包含不支持的字符"
    valid_server_names "${SERVER_NAMES}" || fatal "Reality 域名格式无效"
    valid_record_field "${DEST}" || fatal "Reality 目标地址包含不支持的字符"
    dest_host=${DEST%:*}
    dest_port=${DEST##*:}
    [ -n "${dest_host}" ] && [ "${dest_host}" != "${DEST}" ] && valid_port "${dest_port}" ||
        fatal "Reality 目标地址格式应为 HOST:PORT"
    [ -s "${CLIENTS_FILE}" ] || fatal "至少需要一个 VLESS 客户端"

    normalized="${TMP_DIR}/clients.normalized"
    : >"${normalized}"
    while IFS='|' read -r email uuid outbound client_port; do
        [ -n "${email}" ] || continue
        if [ -z "${client_port}" ]; then
            if [ -n "${PORT}" ]; then
                client_port=${PORT}
            else
                attempts=0
                while :; do
                    client_port=$(gen_port)
                    if ! awk -F'|' -v port="${client_port}" '$4 == port { found=1 } END { exit found ? 0 : 1 }' "${normalized}"; then
                        break
                    fi
                    attempts=$((attempts + 1))
                    [ "${attempts}" -lt 100 ] || fatal "无法生成未占用的随机端口"
                done
            fi
        fi
        printf '%s|%s|%s|%s\n' "${email}" "${uuid}" "${outbound}" "${client_port}" >>"${normalized}"
    done <"${CLIENTS_FILE}"
    mv "${normalized}" "${CLIENTS_FILE}"

    awk -F'|' 'NF >= 2 && $1 != "" { route[$1]=$2 } END { for (email in route) print email "|" route[email] }' \
        "${ROUTES_FILE}" >"${ROUTES_RENDER_FILE}"
    while IFS='|' read -r email outbound; do
        [ -n "${email}" ] || continue
        awk -F'|' -v email="${email}" '$1 == email { found=1 } END { exit found ? 0 : 1 }' "${CLIENTS_FILE}" ||
            fatal "路由引用了不存在的客户端：${email}"
        outbound_exists "${outbound}" || fatal "客户端 ${email} 引用了不存在的出站：${outbound}"
    done <"${ROUTES_RENDER_FILE}"

    if [ -n "${SHORT_ID}" ]; then
        valid_short_id "${SHORT_ID}" || fatal "shortId 必须是长度不超过 16 的偶数位十六进制字符串"
    else
        SHORT_ID=$(gen_hex 8)
    fi
}

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xray-install.XXXXXX")
CLIENTS_FILE="${TMP_DIR}/clients"
SOCKS_FILE="${TMP_DIR}/socks"
ROUTES_FILE="${TMP_DIR}/routes"
ROUTES_RENDER_FILE="${TMP_DIR}/routes.render"
: >"${CLIENTS_FILE}"
: >"${SOCKS_FILE}"
: >"${ROUTES_FILE}"
: >"${ROUTES_RENDER_FILE}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            require_value "$@"
            CONFIG_SOURCE=$2
            CONFIG_EXPLICIT=1
            shift 2
            ;;
        --version)
            require_value "$@"
            VERSION_REQUEST=$2
            shift 2
            ;;
        --no-start)
            START_SERVICE=0
            shift
            ;;
        --port | --listen | --server-name | --sni | --dest | --short-id | --client | --vless | --vless-client | --reality-client | --socks | --route)
            option=$1
            require_value "$@"
            value=$2
            GENERATION_OPTIONS=1
            case "${option}" in
                --port) PORT=${value} ;;
                --listen) LISTEN=${value} ;;
                --server-name | --sni) SERVER_NAMES=${value} ;;
                --dest) DEST=${value} ;;
                --short-id) SHORT_ID=${value} ;;
                --client) parse_client "${value}" ;;
                --vless | --vless-client | --reality-client) parse_vless "${value}" ;;
                --socks) parse_socks "${value}" ;;
                --route) parse_route "${value}" ;;
            esac
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) fatal "未知选项：$1（使用 --help 查看帮助）" ;;
    esac
done

[ "${START_SERVICE}" = "0" ] || [ "${START_SERVICE}" = "1" ] || fatal "XRAY_START_SERVICE 只能是 0 或 1"
[ "$(id -u)" -eq 0 ] || fatal "请使用 root 用户运行此脚本"
[ -f /etc/alpine-release ] || fatal "仅支持 Alpine Linux"

if [ -r "${CONFIG_SOURCE}" ]; then
    [ "${GENERATION_OPTIONS}" -eq 0 ] || fatal "检测到 config.json 时不能同时使用配置生成参数"
    MODE=config
    info "检测到配置文件，将按配置文件安装：${CONFIG_SOURCE}"
elif [ "${CONFIG_EXPLICIT}" -eq 1 ]; then
    fatal "找不到指定的配置文件：${CONFIG_SOURCE}"
else
    MODE=generate
    if [ "${GENERATION_OPTIONS}" -eq 0 ]; then
        [ -t 0 ] || fatal "未找到 config.json，且当前不是交互终端；请提供生成参数或配置文件"
        interactive_config
    fi
    normalize_and_validate_generation
fi

case "$(uname -m)" in
    x86_64 | amd64) XRAY_ARCH=64 ;;
    i386 | i486 | i586 | i686) XRAY_ARCH=32 ;;
    aarch64 | arm64) XRAY_ARCH=arm64-v8a ;;
    armv7l | armv7) XRAY_ARCH=arm32-v7a ;;
    armv6l | armv6) XRAY_ARCH=arm32-v6 ;;
    s390x) XRAY_ARCH=s390x ;;
    riscv64) XRAY_ARCH=riscv64 ;;
    *) fatal "不支持的 CPU 架构：$(uname -m)" ;;
esac

info "安装运行依赖"
apk add --no-cache openrc ca-certificates curl unzip >/dev/null
update-ca-certificates >/dev/null 2>&1 || true

if [ "${VERSION_REQUEST}" = "latest" ]; then
    info "查询最新稳定版本"
    VERSION=$(
        curl -fsSL --retry 3 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            "https://api.github.com/repos/${REPOSITORY}/releases/latest" |
            sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            head -n 1
    )
    [ -n "${VERSION}" ] || fatal "无法获取最新稳定版本；可通过 --version 指定版本"
else
    VERSION=${VERSION_REQUEST}
    case "${VERSION}" in v*) ;; *) VERSION="v${VERSION}" ;; esac
fi
printf '%s' "${VERSION}" | grep -Eq '^v[0-9][0-9A-Za-z._-]*$' || fatal "Xray 版本号无效：${VERSION}"

ASSET="Xray-linux-${XRAY_ARCH}.zip"
BASE_URL="https://github.com/${REPOSITORY}/releases/download/${VERSION}"
info "下载 Xray-core ${VERSION} (${XRAY_ARCH})"
curl -fL --retry 3 --retry-delay 2 -o "${TMP_DIR}/${ASSET}" "${BASE_URL}/${ASSET}"
curl -fL --retry 3 --retry-delay 2 -o "${TMP_DIR}/${ASSET}.dgst" "${BASE_URL}/${ASSET}.dgst"

EXPECTED_SHA256=$(awk 'toupper($0) ~ /^SHA(2-)?256[[:space:]]*=/ { print $NF; exit }' "${TMP_DIR}/${ASSET}.dgst" | tr -d '\r')
case "${EXPECTED_SHA256}" in *[!0-9a-fA-F]* | '') fatal "官方校验文件中没有有效的 SHA-256" ;; esac
[ "${#EXPECTED_SHA256}" -eq 64 ] || fatal "官方 SHA-256 长度无效"
ACTUAL_SHA256=$(sha256sum "${TMP_DIR}/${ASSET}" | awk '{ print $1 }')
[ "$(printf '%s' "${EXPECTED_SHA256}" | tr 'A-F' 'a-f')" = "${ACTUAL_SHA256}" ] || fatal "安装包 SHA-256 校验失败"

mkdir -p "${TMP_DIR}/unpack"
unzip -q "${TMP_DIR}/${ASSET}" -d "${TMP_DIR}/unpack"
[ -x "${TMP_DIR}/unpack/xray" ] || fatal "安装包内缺少 xray 可执行文件"

if [ "${MODE}" = "generate" ]; then
    info "生成 Reality 密钥和 Xray 配置"
    key_output=$("${TMP_DIR}/unpack/xray" x25519)
    PRIVATE_KEY=$(printf '%s\n' "${key_output}" |
        awk -F': ' '/^(Private key|PrivateKey):/ { print $2; exit }')
    PUBLIC_KEY=$(printf '%s\n' "${key_output}" |
        awk -F': ' '/^(Public key|Password \(PublicKey\)):/ { print $2; exit }')
    [ -n "${PRIVATE_KEY}" ] && [ -n "${PUBLIC_KEY}" ] || fatal "无法生成 Reality 密钥"
    GENERATED_CONFIG="${TMP_DIR}/config.generated.json"

    {
        cat <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${LOG_DIR}/access.log",
    "error": "${LOG_DIR}/error.log"
  },
  "inbounds": [
EOF
        first_port=1
        awk -F'|' '$4 != "" { print $4 }' "${CLIENTS_FILE}" | sort -n | uniq |
            while IFS= read -r client_port; do
                [ -n "${client_port}" ] || continue
                [ "${first_port}" -eq 1 ] || printf ',\n'
                first_port=0
                cat <<EOF
    {
      "tag": "vless-reality-${client_port}",
      "listen": "$(json_escape "${LISTEN}")",
      "port": ${client_port},
      "protocol": "vless",
      "settings": {
        "clients": [
EOF
                first_client=1
                while IFS='|' read -r email uuid outbound port; do
                    [ "${port}" = "${client_port}" ] || continue
                    [ "${first_client}" -eq 1 ] || printf ',\n'
                    first_client=0
                    printf '          { "id": "%s", "email": "%s", "flow": "xtls-rprx-vision" }' \
                        "$(json_escape "${uuid}")" "$(json_escape "${email}")"
                done <"${CLIENTS_FILE}"
                cat <<EOF

        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$(json_escape "${DEST}")",
          "xver": 0,
          "serverNames": [ $(json_string_array_csv "${SERVER_NAMES}") ],
          "privateKey": "$(json_escape "${PRIVATE_KEY}")",
          "shortIds": [ "$(json_escape "${SHORT_ID}")" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
EOF
            done
        cat <<EOF
  ],
  "outbounds": [
EOF
        first_outbound=1
        while IFS='|' read -r tag host socks_port user password; do
            [ -n "${tag}" ] || continue
            [ "${first_outbound}" -eq 1 ] || printf ',\n'
            first_outbound=0
            cat <<EOF
    {
      "tag": "$(json_escape "${tag}")",
      "protocol": "socks",
      "settings": {
        "address": "$(json_escape "${host}")",
        "port": ${socks_port}
EOF
            if [ -n "${user}" ]; then
                cat <<EOF
        ,
        "user": "$(json_escape "${user}")",
        "pass": "$(json_escape "${password}")"
EOF
            fi
            cat <<EOF
      }
    }
EOF
        done <"${SOCKS_FILE}"
        [ "${first_outbound}" -eq 1 ] || printf ',\n'
        cat <<EOF
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
EOF
        first_rule=1
        while IFS='|' read -r email outbound; do
            [ -n "${email}" ] || continue
            [ "${first_rule}" -eq 1 ] || printf ',\n'
            first_rule=0
            cat <<EOF
      {
        "type": "field",
        "user": [ "$(json_escape "${email}")" ],
        "outboundTag": "$(json_escape "${outbound}")"
      }
EOF
        done <"${ROUTES_RENDER_FILE}"
        [ "${first_rule}" -eq 1 ] || printf ',\n'
        cat <<EOF
      {
        "type": "field",
        "protocol": [ "bittorrent" ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
    } >"${GENERATED_CONFIG}"
    CONFIG_SOURCE=${GENERATED_CONFIG}
fi

mkdir -p "${CONFIG_DIR}" "${DATA_DIR}" "${LOG_DIR}"
info "校验 Xray 配置"
XRAY_LOCATION_ASSET="${TMP_DIR}/unpack" "${TMP_DIR}/unpack/xray" run -test -config "${CONFIG_SOURCE}"

mkdir -p "${INSTALL_DIR}"
if [ -x "${XRAY_BIN}" ]; then
    cp -p "${XRAY_BIN}" "${TMP_DIR}/xray.previous"
fi
if [ -f "${CONFIG_FILE}" ]; then
    cp -p "${CONFIG_FILE}" "${TMP_DIR}/config.previous"
    if ! cmp -s "${CONFIG_SOURCE}" "${CONFIG_FILE}"; then
        install -m 0600 "${CONFIG_FILE}" "${CONFIG_FILE}.bak"
    fi
fi

install -m 0755 "${TMP_DIR}/unpack/xray" "${XRAY_BIN}"
for data_file in geoip.dat geosite.dat; do
    [ ! -f "${TMP_DIR}/unpack/${data_file}" ] || install -m 0644 "${TMP_DIR}/unpack/${data_file}" "${DATA_DIR}/${data_file}"
done
install -m 0600 "${CONFIG_SOURCE}" "${CONFIG_FILE}"

cat >"${TMP_DIR}/xray.init" <<'EOF'
#!/sbin/openrc-run

name="Xray"
description="XTLS/Xray-core service"
command="/opt/xray/bin/xray"
command_args="run -config /opt/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
output_log="/opt/xray/log/access.log"
error_log="/opt/xray/log/error.log"
export XRAY_LOCATION_ASSET="/opt/xray/share"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /opt/xray/log
    "${command}" run -test -config /opt/xray/config.json
}
EOF
install -m 0755 "${TMP_DIR}/xray.init" "${SERVICE_FILE}"

if ! XRAY_LOCATION_ASSET="${DATA_DIR}" "${XRAY_BIN}" run -test -config "${CONFIG_FILE}"; then
    if [ -f "${TMP_DIR}/xray.previous" ]; then
        install -m 0755 "${TMP_DIR}/xray.previous" "${XRAY_BIN}"
    else
        rm -f "${XRAY_BIN}"
    fi
    if [ -f "${TMP_DIR}/config.previous" ]; then
        install -m 0600 "${TMP_DIR}/config.previous" "${CONFIG_FILE}"
    else
        rm -f "${CONFIG_FILE}"
    fi
    fatal "部署后的最终校验失败，已恢复原有内核和配置"
fi

rc-update add xray default >/dev/null
if [ "${START_SERVICE}" = "1" ]; then
    info "启动 Xray 服务"
    if rc-service xray status >/dev/null 2>&1; then
        rc-service xray restart
    else
        rc-service xray start
    fi
    rc-service xray status
else
    info "已跳过启动（XRAY_START_SERVICE=0）"
fi

info "安装完成：$("${XRAY_BIN}" version | head -n 1)"
if [ "${MODE}" = "generate" ]; then
    public_ip=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null | tr -d ' \n' || true)
    [ -n "${public_ip}" ] || public_ip=10.0.0.1
    primary_sni=$(printf '%s' "${SERVER_NAMES}" | cut -d, -f1)
    printf '\n%s\n' "客户端连接信息："
    while IFS='|' read -r email uuid outbound client_port; do
        uri="vless://${uuid}@${public_ip}:${client_port}?encryption=none&security=reality&sni=${primary_sni}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${email}"
        printf '%s\n  %s\n' "- ${email} (${client_port}) -> ${outbound}" "${uri}"
    done <"${CLIENTS_FILE}"
fi
