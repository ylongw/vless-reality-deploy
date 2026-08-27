#!/usr/bin/env bash

# Runs as root on a fresh Ubuntu VPS. It intentionally creates only one
# VLESS Reality client and one tokenized HTTP subscription URL.

set -euo pipefail

FORCE=false
if [ "${1:-}" = "--force" ]; then
    FORCE=true
    shift
fi

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 [--force] SERVER_ADDRESS SUB_PORT NODE_NAME REALITY_SNI SSH_PORT" >&2
    exit 1
fi

SERVER_ADDRESS=$1
SUB_PORT=$2
NODE_NAME=$3
REALITY_SNI=$4
SSH_PORT=$5

XRAY_BIN=/usr/local/bin/xray
XRAY_CONFIG=/usr/local/etc/xray/config.json
TOKEN_FILE=/var/lib/xray/subscription_token
SUB_DIR=/var/www/vless-sub
SUB_FILE=$SUB_DIR/clash.yaml
NGINX_SITE=/etc/nginx/sites-available/vless-sub
LOCAL_RESULT=/root/vless_subscription.txt

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This installer must run as root." >&2
    exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
    echo "[ERROR] This installer currently supports Ubuntu/Debian with apt-get." >&2
    exit 1
fi
if [[ "$SERVER_ADDRESS" =~ [[:space:]] ]] || [ -z "$SERVER_ADDRESS" ]; then
    echo "[ERROR] Invalid server address." >&2
    exit 1
fi
if [[ ! "$SUB_PORT" =~ ^[0-9]+$ ]] || [ "$SUB_PORT" -lt 1 ] || [ "$SUB_PORT" -gt 65535 ]; then
    echo "[ERROR] Invalid subscription port: $SUB_PORT" >&2
    exit 1
fi
if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "[ERROR] Invalid SSH port: $SSH_PORT" >&2
    exit 1
fi
if [[ ! "$REALITY_SNI" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "[ERROR] Invalid Reality SNI." >&2
    exit 1
fi

if [ -f "$XRAY_CONFIG" ] && [ "$FORCE" != true ]; then
    echo "[ERROR] Existing Xray config found: $XRAY_CONFIG" >&2
    echo "[ERROR] Re-run with --force only for an intentional destructive reinstall." >&2
    exit 1
fi

if [ -f "$XRAY_CONFIG" ]; then
    BACKUP_SUFFIX=$(date -u +%Y%m%dT%H%M%SZ)
    cp -p "$XRAY_CONFIG" "$XRAY_CONFIG.backup-$BACKUP_SUFFIX"
    if [ -f "$LOCAL_RESULT" ]; then
        cp -p "$LOCAL_RESULT" "$LOCAL_RESULT.backup-$BACKUP_SUFFIX"
    fi
    echo "[WARN] Previous Xray configuration backed up with suffix $BACKUP_SUFFIX."
fi

export DEBIAN_FRONTEND=noninteractive
echo "[1/7] Installing system dependencies..."
apt-get update
apt-get install -y ca-certificates curl nginx openssl python3 ufw

echo "[2/7] Enabling TCP BBR..."
cat > /etc/sysctl.d/99-vless-reality.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
modprobe tcp_bbr >/dev/null 2>&1 || true
sysctl --system >/dev/null

echo "[3/7] Installing Xray Core..."
XRAY_INSTALLER=$(mktemp /tmp/xray-install.XXXXXX)
XRAY_CONFIG_NEW=$(mktemp /tmp/xray-config.XXXXXX)
cleanup() {
    rm -f "$XRAY_INSTALLER" "$XRAY_CONFIG_NEW"
}
trap cleanup EXIT
curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$XRAY_INSTALLER"
bash "$XRAY_INSTALLER" install
systemctl stop xray >/dev/null 2>&1 || true

echo "[4/7] Generating the single Reality identity..."
KEY_OUTPUT=$($XRAY_BIN x25519)
PRIVATE_KEY=$(awk '/PrivateKey/ {print $NF; exit}' <<<"$KEY_OUTPUT")
PUBLIC_KEY=$(awk '/Public|Password/ {print $NF; exit}' <<<"$KEY_OUTPUT")
OWNER_UUID=$($XRAY_BIN uuid)
SHORT_ID=$(openssl rand -hex 4)
unset KEY_OUTPUT

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [[ "$PUBLIC_KEY" == *:* ]]; then
    echo "[ERROR] Failed to generate a valid Reality key pair." >&2
    exit 1
fi

export PRIVATE_KEY PUBLIC_KEY OWNER_UUID SHORT_ID REALITY_SNI XRAY_CONFIG_NEW
python3 <<'PY'
import json
import os

config = {
    "log": {"loglevel": "warning"},
    "inbounds": [
        {
            "tag": "vless-in",
            "listen": "0.0.0.0",
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": os.environ["OWNER_UUID"],
                        "flow": "xtls-rprx-vision",
                        "email": "owner@vps",
                    }
                ],
                "decryption": "none",
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": False,
                    "dest": f'{os.environ["REALITY_SNI"]}:443',
                    "xver": 0,
                    "serverNames": [os.environ["REALITY_SNI"]],
                    "privateKey": os.environ["PRIVATE_KEY"],
                    "shortIds": [os.environ["SHORT_ID"]],
                },
            },
        }
    ],
    "outbounds": [{"tag": "direct", "protocol": "freedom"}],
}

with open(os.environ["XRAY_CONFIG_NEW"], "w", encoding="utf-8") as target:
    json.dump(config, target, indent=2)
PY

$XRAY_BIN run -test -config "$XRAY_CONFIG_NEW"
install -d -m 750 /usr/local/etc/xray
if ! id -u xray >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin xray
fi
install -o root -g xray -m 640 "$XRAY_CONFIG_NEW" "$XRAY_CONFIG"
install -d -m 755 /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/override.conf <<'EOF'
[Service]
User=xray
Group=xray
EOF

echo "[5/7] Creating the tokenized Clash/Mihomo subscription..."
install -d -o root -g root -m 700 /var/lib/xray
install -d -o root -g root -m 755 "$SUB_DIR"
SUB_TOKEN=$(openssl rand -hex 16)
umask 077
printf '%s\n' "$SUB_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

export SERVER_ADDRESS SUB_PORT NODE_NAME SUB_FILE
python3 <<'PY'
import json
import os


def quote(value):
    return json.dumps(str(value), ensure_ascii=False)


content = f'''# Single-node VLESS Reality subscription
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://223.5.5.5/dns-query
    - https://1.1.1.1/dns-query

proxies:
  - name: {quote(os.environ["NODE_NAME"])}
    type: vless
    server: {quote(os.environ["SERVER_ADDRESS"])}
    port: 443
    uuid: {quote(os.environ["OWNER_UUID"])}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: {quote(os.environ["REALITY_SNI"])}
    reality-opts:
      public-key: {quote(os.environ["PUBLIC_KEY"])}
      short-id: {quote(os.environ["SHORT_ID"])}
    client-fingerprint: chrome

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - {quote(os.environ["NODE_NAME"])}
      - DIRECT

rules:
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,Proxy
'''

with open(os.environ["SUB_FILE"], "w", encoding="utf-8") as target:
    target.write(content)
PY
chmod 644 "$SUB_FILE"

cat > "$NGINX_SITE" <<EOF
server {
    listen $SUB_PORT;
    listen [::]:$SUB_PORT;
    server_name _;

    location = /$SUB_TOKEN {
        alias $SUB_FILE;
        default_type 'text/yaml; charset=utf-8';
        add_header Content-Disposition 'attachment; filename="clash.yaml"';
        add_header Cache-Control 'no-store' always;
    }

    location / {
        return 404;
    }
}
EOF

rm -f \
    /etc/nginx/sites-enabled/default \
    /etc/nginx/sites-enabled/clash-sub \
    /etc/nginx/sites-enabled/single-sub
ln -sfn "$NGINX_SITE" /etc/nginx/sites-enabled/vless-sub
nginx -t

echo "[6/7] Enabling services and firewall..."
systemctl daemon-reload
systemctl enable xray nginx >/dev/null
systemctl restart xray
systemctl restart nginx

ufw allow "$SSH_PORT/tcp" >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow "$SUB_PORT/tcp" >/dev/null
ufw --force enable >/dev/null

if [ "$(systemctl is-active xray)" != "active" ]; then
    echo "[ERROR] Xray failed to start. Run: journalctl -u xray -n 50" >&2
    exit 1
fi
if [ "$(systemctl is-active nginx)" != "active" ]; then
    echo "[ERROR] Nginx failed to start. Run: journalctl -u nginx -n 50" >&2
    exit 1
fi

echo "[7/7] Verifying the local subscription endpoint..."
HTTP_CODE=$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$SUB_PORT/$SUB_TOKEN")
if [ "$HTTP_CODE" != "200" ]; then
    echo "[ERROR] Subscription endpoint returned HTTP $HTTP_CODE." >&2
    exit 1
fi

URL_HOST=$SERVER_ADDRESS
if [[ "$URL_HOST" == *:* ]] && [[ "$URL_HOST" != \[*\] ]]; then
    URL_HOST="[$URL_HOST]"
fi
SUBSCRIPTION_URL="http://$URL_HOST:$SUB_PORT/$SUB_TOKEN"
umask 077
printf 'owner: %s\n' "$SUBSCRIPTION_URL" > "$LOCAL_RESULT"
chmod 600 "$LOCAL_RESULT"

echo "[OK] Xray Reality is active on TCP 443."
echo "[OK] One owner and one subscription were created."
echo "[OK] Subscription: http://$URL_HOST:$SUB_PORT/<token>"
echo "[OK] Full URL is stored root-only at $LOCAL_RESULT."
