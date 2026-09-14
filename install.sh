#!/usr/bin/env bash
# ==============================================================================
# VPS Dual-Node Setup: Hysteria 2 + Xray VLESS-REALITY + WARP SOCKS5 Route
# Supported Platforms: Ubuntu / Debian (x86_64, ARM64)
# ==============================================================================

set -Eeuo pipefail
umask 077

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[错误] 请使用 root 权限运行此脚本！${PLAIN}"
    exit 1
fi

# 检查运行环境
if [[ ! -r /etc/os-release ]] || ! . /etc/os-release || [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
  echo -e "${RED}[错误] 仅支持 Ubuntu 或 Debian！${PLAIN}"
  exit 1
fi

for command_name in apt curl openssl systemctl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo -e "${RED}[错误] 缺少必要命令: ${command_name}${PLAIN}"
    exit 1
  fi
done

# 获取并校验公网 IPv4，首个接口返回异常内容时继续尝试备用接口。
get_public_ipv4() {
  local candidate endpoint
  for endpoint in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    candidate=$(curl -4fsS --max-time 5 "$endpoint" 2>/dev/null || true)
    if [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

if ! SERVER_IP=$(get_public_ipv4); then
    echo -e "${RED}[错误] 无法获取公网 IPv4 地址，请检查机器外网连接！${PLAIN}"
    exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo -e "${RED}[错误] 不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac

echo -e "${GREEN}>>> 1. 配置常用端口（不清空现有防火墙规则）...${PLAIN}"

if command -v ufw &>/dev/null; then
    ufw allow 443/tcp 2>/dev/null || true
    ufw allow 24443/udp 2>/dev/null || true
    ufw allow 27695/tcp 2>/dev/null || true
fi

if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save 2>/dev/null || true
fi

echo -e "${GREEN}>>> 2. 安装必要的基础工具链...${PLAIN}"
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y curl wget socat openssl jq libcap2-bin ca-certificates gnupg python3 procps iproute2 unzip psmisc

echo -e "${GREEN}>>> 3. 安装配置 WARP SOCKS5 本地出口 (127.0.0.1:40000)...${PLAIN}"
configure_warp() {
  if ss -ltnH 'sport = :40000' | grep -q .; then
    return 0
  fi

  if [[ "$ARCH" == "amd64" ]]; then
    # x86_64 官方稳定客户端
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg || return 1
    CODENAME="${VERSION_CODENAME:-}"
    [[ -n "$CODENAME" ]] || return 1
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null || return 1
    apt update -y || return 1
    apt install -y cloudflare-warp || return 1
    systemctl enable --now warp-svc || return 1
    sleep 2
    if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
      warp-cli --accept-tos registration new || return 1
    fi
    warp-cli --accept-tos mode proxy || return 1
    warp-cli --accept-tos proxy port 40000 || return 1
    warp-cli --accept-tos connect || return 1
  else
    # ARM64 原生轻量代理部署
    mkdir -p /opt/warp || return 1
    curl -fL --retry 3 -o /opt/warp/warp-plus.zip https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus_linux-arm64.zip || return 1
    unzip -p /opt/warp/warp-plus.zip warp-plus > /opt/warp/warp-go || return 1
    rm -f /opt/warp/warp-plus.zip
    chmod 700 /opt/warp/warp-go || return 1
    cat << 'EOF_WARP' > /etc/systemd/system/warp-socks.service
[Unit]
Description=WARP SOCKS5 Local Client
After=network.target

[Service]
ExecStart=/opt/warp/warp-go -b 127.0.0.1:40000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_WARP
    systemctl daemon-reload || return 1
    systemctl enable --now warp-socks.service || return 1
    systemctl is-active --quiet warp-socks.service || return 1
  fi
}

if ! configure_warp; then
  echo -e "${YELLOW}[提示] WARP 安装或启动失败，将使用直连兜底，AI 分流不会阻断节点。${PLAIN}"
fi

WARP_READY=0
WARP_TRACE=$(curl -fsS --proxy socks5h://127.0.0.1:40000 --connect-timeout 4 --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
if grep -q '^warp=' <<< "$WARP_TRACE"; then
  WARP_READY=1
  echo -e "${GREEN}[OK] WARP SOCKS5 (127.0.0.1:40000) 已成功联通！${PLAIN}"
else
  echo -e "${YELLOW}[提示] WARP 40000 暂未响应，REALITY 将使用直连兜底。${PLAIN}"
fi

echo -e "${GREEN}>>> 4. 安装官方 Xray-core 并部署 REALITY 节点...${PLAIN}"
if [[ -x /usr/local/bin/xray ]]; then
  XRAY_VERSION=$(/usr/local/bin/xray version | awk 'NR == 1 { first = $0 } END { print first }')
  echo -e "${YELLOW}检测到已有 Xray-core，跳过重复安装：${XRAY_VERSION}${PLAIN}"
else
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

if [[ ! -x /usr/local/bin/xray ]]; then
  echo -e "${RED}[错误] Xray-core 安装失败，未找到 /usr/local/bin/xray。${PLAIN}"
  exit 1
fi

# 直接调用刚安装的 xray 原生二进制，彻底杜绝手工计算密钥错误
if ! KEY_PAIR=$(/usr/local/bin/xray x25519 2>&1); then
  echo -e "${RED}[错误] Xray x25519 密钥生成失败：${KEY_PAIR}${PLAIN}"
  exit 1
fi
PRIV_KEY=$(printf '%s\n' "$KEY_PAIR" | awk 'tolower($0) ~ /private[[:space:]_-]*key|password/ { print $NF; exit }')
PUB_KEY=$(printf '%s\n' "$KEY_PAIR" | awk 'tolower($0) ~ /public[[:space:]_-]*key/ { print $NF; exit }')
if ! UUID=$(/usr/local/bin/xray uuid 2>&1); then
  echo -e "${RED}[错误] Xray UUID 生成失败：${UUID}${PLAIN}"
  exit 1
fi
SHORT_ID=$(openssl rand -hex 4)
SNI="www.microsoft.com"
if [[ -z "$PRIV_KEY" || -z "$PUB_KEY" || -z "$UUID" || -z "$SHORT_ID" ]]; then
  echo -e "${RED}[错误] 无法解析 Xray 密钥输出，请检查当前 Xray-core 版本的 x25519 输出格式。${PLAIN}"
  exit 1
fi

# 写入服务端完整配置（含 WARP 出站路由）
if [[ "$WARP_READY" -eq 1 ]]; then
  AI_OUTBOUND_TAG="warp-out"
else
  AI_OUTBOUND_TAG="direct"
fi

cat << EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIV_KEY}",
          "shortIds": [
            "",
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40000
          }
        ]
      },
      "tag": "warp-out"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "${AI_OUTBOUND_TAG}",
        "domain": [
          "domain:google.com",
          "domain:googleapis.com",
          "domain:gstatic.com",
          "domain:googleusercontent.com",
          "domain:googletagmanager.com",
          "domain:gemini.google.com",
          "domain:aistudio.google.com",
          "domain:generativelanguage.googleapis.com",
          "domain:openai.com",
          "domain:chatgpt.com",
          "domain:oaistatic.com",
          "domain:oaiusercontent.com",
          "domain:anthropic.com",
          "domain:claude.ai"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF

chmod 600 /usr/local/etc/xray/config.json
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
systemctl restart xray
systemctl enable xray
systemctl is-active --quiet xray
if ! ss -ltnH 'sport = :443' | grep -q .; then
  echo -e "${RED}[错误] Xray 未监听 TCP 443，请执行 journalctl -u xray -n 50 查看日志。${PLAIN}"
  exit 1
fi

echo -e "${GREEN}>>> 5. 安装配置 Hysteria 2 极速节点...${PLAIN}"
bash <(curl -fsSL https://get.hy2.sh/)

if [[ ! -x /usr/local/bin/hysteria ]]; then
  echo -e "${RED}[错误] Hysteria 2 安装失败，未找到 /usr/local/bin/hysteria。${PLAIN}"
  exit 1
fi

mkdir -p /etc/hysteria /etc/hysteria/cert
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/cert/server.key \
  -out /etc/hysteria/cert/server.crt \
  -subj "/CN=bing.com" -days 36500 2>/dev/null

HY2_PASS=$(openssl rand -hex 12)
if [[ ${#HY2_PASS} -lt 16 ]]; then
  echo -e "${RED}[错误] Hysteria 密码生成失败。${PLAIN}"
  exit 1
fi

cat << EOF > /etc/hysteria/config.yaml
listen: :24443
tls:
  cert: /etc/hysteria/cert/server.crt
  key: /etc/hysteria/cert/server.key
auth:
  type: password
  password: ${HY2_PASS}
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
ignoreClientBandwidth: false
EOF

chmod 600 /etc/hysteria/config.yaml /etc/hysteria/cert/server.key
systemctl restart hysteria-server
systemctl enable hysteria-server
systemctl is-active --quiet hysteria-server
if ! ss -lunH 'sport = :24443' | grep -q .; then
  echo -e "${RED}[错误] Hysteria 未监听 UDP 24443，请执行 journalctl -u hysteria-server -n 50 查看日志。${PLAIN}"
  exit 1
fi

echo -e "${GREEN}>>> 6. 更新并部署订阅服务 (端口 27695)...${PLAIN}"
systemctl stop nodes-sub.service 2>/dev/null || true
fuser -k 27695/tcp 2>/dev/null || true
SUB_DIR="/var/www/nodes_sub"
mkdir -p "$SUB_DIR"
SUB_TOKEN="$(date +%Y%m%d%H%M%S)-$(openssl rand -hex 4)"
SUB_FILE="$SUB_DIR/sub-${SUB_TOKEN}.txt"
find "$SUB_DIR" -maxdepth 1 -type f -name 'sub-*.txt' -delete
rm -f "$SUB_DIR/sub.txt"

HY2_URL="hysteria2://${HY2_PASS}@${SERVER_IP}:24443/?sni=bing.com&insecure=1#Oracle-Main-Hy2-Speed"
REALITY_URL="vless://${UUID}@${SERVER_IP}:443?security=reality&encryption=none&pbk=${PUB_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#Oracle-AI-SmartRoute-Reality"

SUB_CONTENT=$(printf "%s\n%s\n" "$HY2_URL" "$REALITY_URL")
SUB_TMP=$(mktemp "$SUB_DIR/.sub.txt.XXXXXX")
printf '%s' "$SUB_CONTENT" | base64 -w 0 > "$SUB_TMP"
chmod 600 "$SUB_TMP"
mv -f "$SUB_TMP" "$SUB_FILE"
chmod 600 "$SUB_FILE"
if [[ "$(base64 -d "$SUB_FILE")" != "$SUB_CONTENT" ]]; then
  echo -e "${RED}[错误] 订阅文件校验失败。${PLAIN}"
  exit 1
fi

cat << 'EOF_SUB_SERVER' > /usr/local/sbin/nodes-sub-server.py
#!/usr/bin/env python3
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from functools import partial


class SubscriptionHandler(SimpleHTTPRequestHandler):
  def end_headers(self):
    self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
    self.send_header("Pragma", "no-cache")
    self.send_header("Expires", "0")
    super().end_headers()


subscription_handler = partial(SubscriptionHandler, directory="/var/www/nodes_sub")
ThreadingHTTPServer(("0.0.0.0", 27695), subscription_handler).serve_forever()
EOF_SUB_SERVER
chmod 700 /usr/local/sbin/nodes-sub-server.py

cat << EOF > /etc/systemd/system/nodes-sub.service
[Unit]
Description=Lightweight Subscription Server
After=network.target

[Service]
Type=simple
WorkingDirectory=${SUB_DIR}
ExecStart=/usr/bin/python3 /usr/local/sbin/nodes-sub-server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nodes-sub.service
systemctl restart nodes-sub.service
systemctl is-active --quiet nodes-sub.service
if [[ ! -f "$SUB_FILE" ]] || [[ "$(curl -sS -o /tmp/nodes-sub-check -w '%{http_code}' "http://127.0.0.1:27695/sub-${SUB_TOKEN}.txt")" != "200" ]] || [[ ! -s /tmp/nodes-sub-check ]]; then
  echo -e "${RED}[错误] 订阅服务未能返回本次生成的订阅文件，当前目录内容：${PLAIN}"
  find "$SUB_DIR" -maxdepth 1 -type f -printf '%f\n' >&2
  systemctl status nodes-sub.service --no-pager >&2 || true
  exit 1
fi
rm -f /tmp/nodes-sub-check

echo -e "\n================================================================="
echo -e "${GREEN}恭喜！双节点与分流系统安装完成！${PLAIN}"
echo -e "================================================================="
echo -e "订阅地址 (直接复制到 v2rayN 订阅分组一键拉取):"
echo -e "${YELLOW}http://${SERVER_IP}:27695/sub-${SUB_TOKEN}.txt${PLAIN}"
echo -e "\n--- 节点明细 ---"
echo -e "1. Hysteria 2:"
echo -e "$HY2_URL"
echo -e "\n2. VLESS-REALITY (AI 分流):"
echo -e "$REALITY_URL"
echo -e "================================================================="
echo -e "${RED}[甲骨文安全列表提醒]${PLAIN} 务必放行入站规则："
echo -e "  - TCP: 443"
echo -e "  - UDP: 24443"
echo -e "  - TCP: 27695"
echo -e "================================================================="