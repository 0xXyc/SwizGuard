#!/bin/bash
#
# SwizGuard server setup
# Installs WireGuard + Xray-core (VLESS+REALITY) on a fresh VPS.
# Your WireGuard traffic becomes invisible — looks like HTTPS to microsoft.com.
#
# Usage: curl -sL <raw-url> | sudo bash
#    or: sudo bash setup-server.sh
#
# Supports: Debian 12/13, Ubuntu 22.04/24.04 (amd64 + arm64)

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────

R='\033[91m' G='\033[92m' Y='\033[93m' C='\033[96m' B='\033[1m' X='\033[0m'
info()  { echo -e "  ${C}[*]${X} $1"; }
ok()    { echo -e "  ${G}[+]${X} $1"; }
warn()  { echo -e "  ${Y}[!]${X} $1"; }
fail()  { echo -e "  ${R}[✗]${X} $1"; exit 1; }

banner() {
    echo -e "${C}${B}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║              SwizGuard server setup                 ║"
    echo "║     WireGuard + VLESS + REALITY = invisible VPN     ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${X}"
}

# ─── Checks ───────────────────────────────────────────────────────

banner

[ "$EUID" -ne 0 ] && fail "Run as root"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  XRAY_ARCH="64" ;;
    aarch64) XRAY_ARCH="arm64-v8a" ;;
    *)       fail "Unsupported architecture: $ARCH" ;;
esac

# ─── Config ───────────────────────────────────────────────────────

SWIZ_DIR="/etc/swizguard"
XRAY_DIR="/usr/local/etc/xray"
WG_PORT=51821
XRAY_PORT=443
WG_SUBNET="10.7.0"
WG_SUBNET6="fd07::7"
# Camouflage target — pick a major site that supports TLS 1.3 + H2
# Avoid apple/icloud — Xray warns these may get your IP flagged
CAMOUFLAGE_DEST="www.microsoft.com"
# MTU reduced for tunnel-in-tunnel overhead
WG_MTU=1280

mkdir -p "$SWIZ_DIR" "$XRAY_DIR"

# ─── Install WireGuard ────────────────────────────────────────────

info "Installing dependencies..."
apt update -qq
apt install -y -qq wireguard qrencode iptables unzip curl > /dev/null 2>&1
ok "Dependencies installed"

# ─── Generate WireGuard keys ─────────────────────────────────────

info "Generating WireGuard keys..."

wg genkey | tee "$SWIZ_DIR/server_private.key" | wg pubkey > "$SWIZ_DIR/server_public.key"
chmod 600 "$SWIZ_DIR/server_private.key"

SERVER_WG_PRIVKEY=$(cat "$SWIZ_DIR/server_private.key")
SERVER_WG_PUBKEY=$(cat "$SWIZ_DIR/server_public.key")

ok "Server WG keys generated"

# ─── Detect public IP ────────────────────────────────────────────

SERVER_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com)
[ -z "$SERVER_IP" ] && fail "Could not detect public IP"
ok "Server IP: $SERVER_IP"

# ─── Enable IP forwarding ────────────────────────────────────────

info "Enabling IP forwarding..."
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv6.conf.all.forwarding=1
sysctl -q -w net.ipv6.conf.default.forwarding=1

# Persist via /etc/sysctl.d. We do NOT use /etc/sysctl.conf because UFW ships
# /etc/ufw/sysctl.conf with ip_forward=0 and silently re-applies it on every
# reload/boot, overriding /etc/sysctl.conf without warning.
cat > /etc/sysctl.d/99-swizguard-forwarding.conf <<EOF
# SwizGuard requires IPv4+v6 forwarding for the WG-NAT path.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF

# Stop UFW from undoing the above on its next reload/boot.
if [ -f /etc/ufw/sysctl.conf ]; then
    sed -i -E 's|^#?\s*net/ipv4/ip_forward\s*=.*|net/ipv4/ip_forward=1|' /etc/ufw/sysctl.conf
    sed -i -E 's|^#?\s*net/ipv6/conf/default/forwarding\s*=.*|net/ipv6/conf/default/forwarding=1|' /etc/ufw/sysctl.conf
    sed -i -E 's|^#?\s*net/ipv6/conf/all/forwarding\s*=.*|net/ipv6/conf/all/forwarding=1|' /etc/ufw/sysctl.conf
    grep -q "^net/ipv4/ip_forward=1" /etc/ufw/sysctl.conf || echo "net/ipv4/ip_forward=1" >> /etc/ufw/sysctl.conf
    grep -q "^net/ipv6/conf/default/forwarding=1" /etc/ufw/sysctl.conf || echo "net/ipv6/conf/default/forwarding=1" >> /etc/ufw/sysctl.conf
    grep -q "^net/ipv6/conf/all/forwarding=1" /etc/ufw/sysctl.conf || echo "net/ipv6/conf/all/forwarding=1" >> /etc/ufw/sysctl.conf
fi

# UFW DEFAULT_FORWARD_POLICY ships as DROP. The wg-quick PostUp explicit FORWARD
# rule handles the wg1 path, but ACCEPT here keeps UFWs status display honest
# and avoids fighting future routed traffic.
if [ -f /etc/default/ufw ]; then
    sed -i 's|^DEFAULT_FORWARD_POLICY=.*|DEFAULT_FORWARD_POLICY="ACCEPT"|' /etc/default/ufw
fi

ok "IP forwarding enabled"

# ─── Detect default interface ────────────────────────────────────

DEFAULT_IF=$(ip -o -4 route show default | awk '{print $5}' | head -1)
[ -z "$DEFAULT_IF" ] && fail "Could not detect default network interface"
info "Default interface: $DEFAULT_IF"

# ─── WireGuard server config ─────────────────────────────────────

info "Configuring WireGuard..."

cat > /etc/wireguard/wg1.conf <<WGEOF
[Interface]
PrivateKey = $SERVER_WG_PRIVKEY
Address = ${WG_SUBNET}.1/24, ${WG_SUBNET6}1/64
ListenPort = $WG_PORT
MTU = $WG_MTU
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostUp = ip6tables -A FORWARD -i %i -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostDown = ip6tables -D FORWARD -i %i -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o $DEFAULT_IF -j MASQUERADE

# Peers added by SwizGuard add-client
WGEOF

chmod 600 /etc/wireguard/wg1.conf
ok "WireGuard configured on :$WG_PORT"

# ─── Install Xray-core ───────────────────────────────────────────

info "Installing Xray-core..."

XRAY_VERSION=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)
[ -z "$XRAY_VERSION" ] && fail "Could not fetch Xray version"
info "Xray version: $XRAY_VERSION"

XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
cd /tmp
curl -sLO "$XRAY_URL"
unzip -qo "Xray-linux-${XRAY_ARCH}.zip" -d /usr/local/bin/xray-tmp
mv /usr/local/bin/xray-tmp/xray /usr/local/bin/xray
chmod +x /usr/local/bin/xray
rm -rf /usr/local/bin/xray-tmp "Xray-linux-${XRAY_ARCH}.zip"

ok "Xray-core installed at /usr/local/bin/xray"

# ─── Generate REALITY keys ───────────────────────────────────────

info "Generating REALITY x25519 keypair..."

XRAY_KEYS=$(/usr/local/bin/xray x25519)
REALITY_PRIVKEY=$(echo "$XRAY_KEYS" | grep "^PrivateKey:" | awk '{print $2}')
# Handle both old (PublicKey:) and new (Password (PublicKey):) output formats
REALITY_PUBKEY=$(echo "$XRAY_KEYS" | grep -E "^(Password|PublicKey)" | awk '{print $NF}')

[ -z "$REALITY_PRIVKEY" ] && fail "Failed to parse REALITY private key from xray x25519"
[ -z "$REALITY_PUBKEY" ] && fail "Failed to parse REALITY public key from xray x25519"

CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)

ok "REALITY keys generated"

# ─── Xray server config ──────────────────────────────────────────

info "Configuring Xray VLESS+REALITY..."

cat > "$XRAY_DIR/config.json" <<XEOF
{
    "log": {
        "access": "none",
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": $XRAY_PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$CLIENT_UUID",
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
                    "dest": "${CAMOUFLAGE_DEST}:443",
                    "xver": 0,
                    "serverNames": ["$CAMOUFLAGE_DEST"],
                    "privateKey": "$REALITY_PRIVKEY",
                    "shortIds": ["$SHORT_ID"]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
XEOF

ok "Xray configured — camouflaged as $CAMOUFLAGE_DEST"

# ─── Systemd services ────────────────────────────────────────────

info "Setting up systemd services..."

cat > /etc/systemd/system/xray.service <<SVCEOF
[Unit]
Description=Xray VLESS+REALITY
After=network.target

[Service]
ExecStart=/usr/local/bin/xray run -config $XRAY_DIR/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now xray > /dev/null 2>&1
systemctl enable --now wg-quick@wg1 > /dev/null 2>&1

ok "Xray and WireGuard services started"

# ─── Firewall ────────────────────────────────────────────────────

info "Configuring firewall..."
# Prefer UFW when installed and active (rules persist across reboots).
# Fall back to direct iptables only when UFW is not present.
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "$XRAY_PORT/tcp" > /dev/null 2>&1
    info "UFW detected, added rule for $XRAY_PORT/tcp"
else
    iptables -A INPUT -p tcp --dport $XRAY_PORT -j ACCEPT
    warn "UFW not active. Added direct iptables rule for $XRAY_PORT/tcp (will NOT persist a reboot, run a hardening script first)"
fi

# WireGuard port does NOT need to be open externally — it runs over REALITY
ok "Port $XRAY_PORT/tcp open (REALITY)"

# ─── Save credentials ────────────────────────────────────────────

cat > "$SWIZ_DIR/credentials.env" <<CREDEOF
# SwizGuard server credentials — KEEP THIS SAFE
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

SERVER_IP=$SERVER_IP
XRAY_PORT=$XRAY_PORT
WG_PORT=$WG_PORT

# REALITY
REALITY_PRIVATE_KEY=$REALITY_PRIVKEY
REALITY_PUBLIC_KEY=$REALITY_PUBKEY
CLIENT_UUID=$CLIENT_UUID
SHORT_ID=$SHORT_ID
CAMOUFLAGE_DEST=$CAMOUFLAGE_DEST

# WireGuard
SERVER_WG_PUBLIC_KEY=$SERVER_WG_PUBKEY
SERVER_WG_PRIVATE_KEY=$SERVER_WG_PRIVKEY
WG_SUBNET=$WG_SUBNET
WG_MTU=$WG_MTU
CREDEOF

chmod 600 "$SWIZ_DIR/credentials.env"
ok "Credentials saved to $SWIZ_DIR/credentials.env"

# ─── Done ─────────────────────────────────────────────────────────

echo ""
echo -e "${G}${B}╔══════════════════════════════════════════════════════╗"
echo "║              SERVER SETUP COMPLETE                   ║"
echo -e "╚══════════════════════════════════════════════════════╝${X}"
echo ""
echo -e "  ${B}Server IP:${X}        $SERVER_IP"
echo -e "  ${B}REALITY port:${X}     $XRAY_PORT/tcp"
echo -e "  ${B}Camouflage:${X}       $CAMOUFLAGE_DEST"
echo -e "  ${B}Client UUID:${X}      $CLIENT_UUID"
echo -e "  ${B}REALITY pubkey:${X}   $REALITY_PUBKEY"
echo -e "  ${B}Short ID:${X}         $SHORT_ID"
echo -e "  ${B}WG server pubkey:${X} $SERVER_WG_PUBKEY"
echo ""
echo -e "  ${Y}Next: run add-client.sh to generate client configs${X}"
echo ""
